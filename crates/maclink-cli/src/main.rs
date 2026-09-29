mod store;

use serde_json::{Value, json};
use std::{path::PathBuf, time::Duration};
use store::Store;

const HELP: &str = "MacLink — native Mac connections, Rust foundation\n\nUsage: maclink [--config-dir PATH] COMMAND\n\n  list                         List saved Macs as JSON\n  add --name NAME --host HOST [--port PORT]\n                               Save a Mac (default port 5900)\n  remove ID                    Remove a saved Mac\n  inspect ID                   Read the server's RFB greeting; no login\n  connect ID                   Open Apple Screen Sharing\n  connect-mode ID MODE         Request standard or high_performance\n  home-network                 Identify the local network without contacting a Mac\n  network-probe ID             Measure target TCP/RFB timing and route\n  network-evaluate JSON        Evaluate live probe metadata with state\n  doctor                       Report local capabilities and limitations\n  simulate                     Run simulated adaptive-quality scenarios\n\nMode requests use experimental native-exported Apple URL options.\nThey do not confirm video negotiation. MacLink has no custom video engine.\nNo passwords are stored. MACLINK_HOME overrides the connection directory.\n";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() || matches!(args[0].as_str(), "help" | "--help" | "-h") {
        print!("{HELP}");
        return;
    }
    match execute(&args) {
        Ok(value) => println!(
            "{}",
            serde_json::to_string_pretty(&value).expect("JSON value serialization")
        ),
        Err(error) => {
            eprintln!("MacLink: {error}");
            std::process::exit(1);
        }
    }
}

fn execute(args: &[String]) -> Result<Value, String> {
    let (directory, args) = if args.first().map(String::as_str) == Some("--config-dir") {
        let path = args
            .get(1)
            .filter(|p| !p.is_empty())
            .ok_or("--config-dir requires a path")?;
        (PathBuf::from(path), &args[2..])
    } else {
        (Store::default_path()?, args)
    };
    let store = Store::new(directory.clone());
    let command = args
        .first()
        .ok_or("A command is required; run maclink --help")?;
    let trailing = &args[1..];
    match command.as_str() {
        "list" => {
            require_count(trailing, 0)?;
            Ok(json!(store.list()?))
        }
        "add" => {
            let (name, host, port) = parse_add(trailing)?;
            Ok(json!(store.add(&name, &host, port)?))
        }
        "remove" => {
            require_count(trailing, 1)?;
            store.remove(&trailing[0])?;
            Ok(json!({"removed": trailing[0]}))
        }
        "inspect" => {
            require_count(trailing, 1)?;
            let connection = store.get(&trailing[0])?;
            Ok(json!(maclink_platform::inspect_host(
                &connection.host,
                connection.port,
                Duration::from_secs(3)
            )?))
        }
        "connect" => {
            require_count(trailing, 1)?;
            let connection = store.get(&trailing[0])?;
            maclink_platform::launch_apple(&connection.host, connection.port)?;
            Ok(
                json!({"status":"launched", "connection":connection, "note":"Apple Screen Sharing controls authentication and display mode. Launch is not confirmation of a connected session."}),
            )
        }
        "connect-mode" => {
            require_count(trailing, 2)?;
            let connection = store.get(&trailing[0])?;
            let mode = match trailing[1].as_str() {
                "standard" => maclink_platform::AppleMode::Standard,
                "high_performance" => maclink_platform::AppleMode::HighPerformance,
                _ => return Err("Mode must be standard or high_performance.".into()),
            };
            maclink_platform::launch_apple_with_mode(&connection.host, connection.port, mode)?;
            Ok(
                json!({"status":"requested", "mode":mode, "note":"Requested Apple's native exported-connection URL options. Launch does not confirm the negotiated mode."}),
            )
        }
        "home-network" => {
            require_count(trailing, 0)?;
            Ok(json!(maclink_platform::network_probe::local_network()))
        }
        "network-probe" => {
            require_count(trailing, 1)?;
            let connection = store.get(&trailing[0])?;
            let local_network = maclink_platform::network_probe::local_network();
            match maclink_platform::inspect_host(
                &connection.host,
                connection.port,
                Duration::from_millis(1500),
            ) {
                Ok(inspection) => {
                    let route =
                        maclink_platform::network_probe::target_route(inspection.resolved_address);
                    Ok(
                        json!({"status":"rfb_ready", "inspection":inspection, "route":route, "local_network":local_network}),
                    )
                }
                Err(error) => Ok(
                    json!({"status":"connect_failed", "error":error, "local_network":local_network}),
                ),
            }
        }
        "network-evaluate" => {
            require_count(trailing, 1)?;
            if trailing[0].len() > 65_536 {
                return Err("Network evaluation input exceeds 64 KiB.".into());
            }
            let request: maclink_core::network::NetworkEvaluationRequest =
                serde_json::from_str(&trailing[0])
                    .map_err(|error| format!("Invalid network evaluation request: {error}"))?;
            Ok(json!(maclink_core::network::evaluate_network(request)))
        }
        "doctor" => {
            require_count(trailing, 0)?;
            Ok(json!({
                "version":env!("CARGO_PKG_VERSION"),
                "os":std::env::consts::OS, "architecture":std::env::consts::ARCH,
                "config_directory":store::path_display(&directory),
                "apple_silicon":cfg!(all(target_os="macos",target_arch="aarch64")),
                "apple_backend":"launches native Screen Sharing; Apple manages display mode",
                "custom_streaming_backend":"not implemented",
                "automatic_quality":"menu-bar network policy uses live TCP/RFB checks; experimental Apple mode requests and Accessibility reconnects require setup",
                "inspection":"RFB greeting only; does not measure video latency, bandwidth or High Performance support",
                "password_storage":"none; Apple handles credentials"
            }))
        }
        "simulate" => {
            require_count(trailing, 0)?;
            Ok(
                json!({"simulated":true, "note":"Synthetic telemetry; these are not measured remote-desktop performance results", "scenarios":maclink_core::demo_scenarios()}),
            )
        }
        _ => Err(format!("Unknown command '{command}'; run maclink --help")),
    }
}

fn require_count(args: &[String], count: usize) -> Result<(), String> {
    if args.len() != count {
        return Err(format!("Expected {count} argument(s); run maclink --help"));
    }
    Ok(())
}

fn parse_add(args: &[String]) -> Result<(String, String, u16), String> {
    let mut name = None;
    let mut host = None;
    let mut port = None;
    let (chunks, remainder) = args.as_chunks::<2>();
    for pair in chunks {
        match pair[0].as_str() {
            "--name" if name.is_none() => name = Some(pair[1].clone()),
            "--host" if host.is_none() => host = Some(pair[1].clone()),
            "--port" if port.is_none() => {
                port = Some(
                    pair[1]
                        .parse::<u16>()
                        .ok()
                        .filter(|p| *p > 0)
                        .ok_or("Port must be between 1 and 65535")?,
                )
            }
            value => return Err(format!("Unknown or repeated option '{value}'")),
        }
    }
    if !remainder.is_empty() {
        return Err("Every add option requires a value".into());
    }
    Ok((
        name.ok_or("--name is required")?,
        host.ok_or("--host is required")?,
        port.unwrap_or(5900),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn args(input: &[&str]) -> Vec<String> {
        input.iter().map(|s| s.to_string()).collect()
    }
    #[test]
    fn cli_rejects_ambiguous_and_invalid_options() {
        for input in [
            vec!["--name", "Mac", "--host"],
            vec!["--name", "Mac", "--host", "mac.local", "--port", "0"],
            vec!["--name", "Mac", "--name", "Again", "--host", "mac.local"],
            vec![
                "--name",
                "Mac",
                "--host",
                "mac.local",
                "--password",
                "secret",
            ],
        ] {
            assert!(parse_add(&args(&input)).is_err());
        }
    }
    #[test]
    fn cli_defaults_to_screen_sharing_port() {
        assert_eq!(
            parse_add(&args(&["--name", "My Mac", "--host", "mac.local"])).unwrap(),
            ("My Mac".into(), "mac.local".into(), 5900)
        );
    }
}

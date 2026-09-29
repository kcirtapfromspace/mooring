mod store;

use serde_json::{Map, Value, json};
use std::{
    io::{BufRead, BufReader, Write},
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
    time::Duration,
};
use store::Store;

const HELP: &str = "MacLink — native Mac connections, Rust foundation\n\nUsage: maclink [--config-dir PATH] COMMAND\n\n  list                         List saved Macs as JSON\n  add --name NAME --host HOST [--port PORT]\n                               Save a Mac (default port 5900)\n  remove ID                    Remove a saved Mac\n  inspect ID                   Read the server's RFB greeting; no login\n  connect ID                   Open Apple Screen Sharing\n  connect-mode ID MODE         Request standard or high_performance\n  home-network                 Identify the local network without contacting a Mac\n  network-probe ID             Measure target TCP/RFB timing and route\n  network-evaluate JSON        Evaluate live probe metadata with state\n  doctor                       Report local capabilities and limitations\n  simulate                     Run simulated adaptive-quality scenarios\n  telemetry [--count N]        Stream live native-session measurements as JSON lines\n  tune OPTIONS                 Adjust the sharing Mac's stream while connected:\n                               --bitrate-mbps 1-80  --max-width 640-3840 (even)\n                               --fps 1-60  --in-flight 1-2  --keyframe-seconds 1-10\n                               --reset (restore defaults, then apply the rest)\n\nMode requests use experimental native-exported Apple URL options.\nThey do not confirm video negotiation. Telemetry and tuning use the running\napp's owner-only local socket; tuning from a viewer is sent to the sharing Mac\nover the encrypted session. No passwords are stored. MACLINK_HOME overrides\nthe connection directory.\n";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() || matches!(args[0].as_str(), "help" | "--help" | "-h") {
        print!("{HELP}");
        return;
    }
    match execute(&args) {
        Ok(Value::Null) => {} // streaming commands print as they go
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
                "custom_streaming_backend":"experimental native MacLink session; both Macs run MacLink",
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
        "telemetry" => {
            let count = match trailing {
                [] => None,
                [flag, value] if flag == "--count" => Some(
                    value
                        .parse::<usize>()
                        .ok()
                        .filter(|count| (1..=86_400).contains(count))
                        .ok_or("--count must be between 1 and 86400")?,
                ),
                _ => return Err("Usage: maclink telemetry [--count N]".into()),
            };
            stream_telemetry(&directory, count)?;
            Ok(Value::Null)
        }
        "tune" => send_tuning(&directory, parse_tune(trailing)?),
        _ => Err(format!("Unknown command '{command}'; run maclink --help")),
    }
}

const MAX_TELEMETRY_LINE: usize = 64 * 1024;

fn telemetry_socket(directory: &Path) -> Result<UnixStream, String> {
    let path = directory.join(maclink_platform::TELEMETRY_SOCKET);
    let stream = UnixStream::connect(&path).map_err(|_| {
        format!(
            "MacLink is not serving telemetry at {}. Open MacLink on this Mac first.",
            store::path_display(&path)
        )
    })?;
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .map_err(|e| format!("Cannot configure the telemetry socket: {e}"))?;
    Ok(stream)
}

fn read_line(reader: &mut impl BufRead) -> Result<String, String> {
    let mut line = String::new();
    let read = std::io::Read::take(&mut *reader, MAX_TELEMETRY_LINE as u64 + 1)
        .read_line(&mut line)
        .map_err(|e| format!("MacLink stopped sending telemetry: {e}"))?;
    if read == 0 {
        return Err("MacLink closed the telemetry socket".into());
    }
    if line.len() > MAX_TELEMETRY_LINE || !line.ends_with('\n') {
        return Err("MacLink sent an oversized telemetry line".into());
    }
    Ok(line.trim_end().to_owned())
}

/// One snapshot per second while MacLink runs; stops after `count` if given.
fn stream_telemetry(directory: &Path, count: Option<usize>) -> Result<(), String> {
    let mut reader = BufReader::new(telemetry_socket(directory)?);
    let mut printed = 0;
    loop {
        let line = read_line(&mut reader)?;
        if serde_json::from_str::<Value>(&line).is_err() {
            return Err("MacLink sent invalid telemetry".into());
        }
        println!("{line}");
        std::io::stdout()
            .flush()
            .map_err(|e| format!("Cannot write telemetry: {e}"))?;
        printed += 1;
        if count.is_some_and(|count| printed >= count) {
            return Ok(());
        }
    }
}

/// Builds the `{"tune": {...}}` request; the app validates the bounds.
fn parse_tune(args: &[String]) -> Result<Value, String> {
    let mut request = Map::new();
    let mut remaining = args;
    while let Some((flag, rest)) = remaining.split_first() {
        let (key, value, next) = match flag.as_str() {
            "--reset" => ("reset", json!(true), rest),
            "--bitrate-mbps" | "--max-width" | "--fps" | "--in-flight" | "--keyframe-seconds" => {
                let (value, next) = rest
                    .split_first()
                    .ok_or_else(|| format!("{flag} requires a value"))?;
                let key = &flag[2..];
                let value = if flag == "--bitrate-mbps" {
                    json!(
                        value
                            .parse::<f64>()
                            .ok()
                            .filter(|v| v.is_finite())
                            .ok_or("--bitrate-mbps must be a number")?
                    )
                } else {
                    json!(
                        value
                            .parse::<u32>()
                            .map_err(|_| format!("{flag} must be a whole number"))?
                    )
                };
                (key, value, next)
            }
            other => return Err(format!("Unknown tune option '{other}'; run maclink --help")),
        };
        let key = key.replace('-', "_");
        if request.insert(key, value).is_some() {
            return Err(format!("Repeated tune option '{flag}'"));
        }
        remaining = next;
    }
    if request.is_empty() {
        return Err("Give at least one tune option; run maclink --help".into());
    }
    Ok(json!({ "tune": request }))
}

fn send_tuning(directory: &Path, request: Value) -> Result<Value, String> {
    let stream = telemetry_socket(directory)?;
    let mut writer = stream
        .try_clone()
        .map_err(|e| format!("Cannot use the telemetry socket: {e}"))?;
    writeln!(writer, "{request}").map_err(|e| format!("Cannot send tuning: {e}"))?;
    let mut reader = BufReader::new(stream);
    // Snapshot lines may arrive first; wait for this command's reply.
    for _ in 0..16 {
        let reply: Value = serde_json::from_str(&read_line(&mut reader)?)
            .map_err(|_| "MacLink sent an invalid reply".to_string())?;
        if let Some(error) = reply.get("error").and_then(Value::as_str) {
            return Err(error.to_owned());
        }
        if let Some(ack) = reply.get("ack") {
            return Ok(
                json!({"status":"queued", "ack": ack, "note":"Applied on the sharing Mac within about a second while a native session is connected."}),
            );
        }
    }
    Err("MacLink did not acknowledge the tuning request".into())
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
    fn tune_options_build_one_request() {
        assert_eq!(
            parse_tune(&args(&[
                "--bitrate-mbps",
                "40.5",
                "--max-width",
                "2560",
                "--reset"
            ]))
            .unwrap(),
            json!({"tune": {"bitrate_mbps": 40.5, "max_width": 2560, "reset": true}})
        );
        assert_eq!(
            parse_tune(&args(&[
                "--fps",
                "30",
                "--in-flight",
                "1",
                "--keyframe-seconds",
                "4"
            ]))
            .unwrap(),
            json!({"tune": {"fps": 30, "in_flight": 1, "keyframe_seconds": 4}})
        );
        for input in [
            vec![],
            vec!["--fps"],
            vec!["--fps", "thirty"],
            vec!["--fps", "30", "--fps", "24"],
            vec!["--bitrate-mbps", "NaN"],
            vec!["--max-width", "-2"],
            vec!["--colour", "red"],
        ] {
            assert!(parse_tune(&args(&input)).is_err(), "{input:?}");
        }
    }
    #[test]
    fn telemetry_needs_a_running_app() {
        let missing =
            std::env::temp_dir().join(format!("maclink-no-telemetry-{}", std::process::id()));
        assert!(
            stream_telemetry(&missing, Some(1))
                .unwrap_err()
                .contains("not serving telemetry")
        );
        assert!(send_tuning(&missing, json!({"tune": {"fps": 30}})).is_err());
    }
    #[test]
    fn cli_defaults_to_screen_sharing_port() {
        assert_eq!(
            parse_add(&args(&["--name", "My Mac", "--host", "mac.local"])).unwrap(),
            ("My Mac".into(), "mac.local".into(), 5900)
        );
    }
}

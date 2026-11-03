mod store;

use mooring_platform::ServerKind;
use mooring_platform::ssh::{self as ssh_tunnel, SshOptions, SshRoute, TunnelConfig};
use serde_json::{Map, Value, json};
use std::{
    io::{BufRead, BufReader, Write},
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};
use store::{Connection, NewConnection, SshHop, Store};

const HELP: &str = "Mooring — native Mac connections, Rust foundation\n\nUsage: mooring [--config-dir PATH] COMMAND\n\n  list                         List saved Macs as JSON\n  add --name NAME --host HOST [--port PORT] [--server mac|vnc]\n                               Save a Mac (default port 5900). Use --server vnc\n                               for another VNC server, such as wayvnc on Linux\n  add --name NAME --ssh TARGET [--host HOST] [--port PORT] [--server mac|vnc]\n                               Reach the VNC server through SSH. TARGET is a\n                               ~/.ssh/config alias or user@host; HOST and PORT\n                               are as seen from the SSH host (127.0.0.1:5900)\n  remove ID                    Remove a saved Mac\n  inspect ID                   Read the server's RFB greeting; no login\n  connect ID                   Open Apple Screen Sharing\n  connect ID [--no-viewer] [--idle-seconds N] [--wait-seconds N]\n                               SSH connections: tunnel on 127.0.0.1 through\n                               /usr/bin/ssh, open Screen Sharing there, print\n                               JSON lines until the viewer has been gone N\n                               seconds (default 60) or Ctrl-C\n  connect-mode ID MODE         Request standard or high_performance (Macs only)\n  home-network                 Identify the local network without contacting a Mac\n  network-probe ID             Measure target TCP/RFB timing and route\n  network-evaluate JSON        Evaluate live probe metadata with state\n  doctor                       Report local capabilities and limitations\n  simulate                     Run simulated adaptive-quality scenarios\n  telemetry [--count N]        Stream live native-session measurements as JSON lines\n  tune OPTIONS                 Adjust the sharing Mac's stream while connected:\n                               --bitrate-mbps 1-80  --max-width 640-3840 (even)\n                               --fps 1-60  --in-flight 1-2  --keyframe-seconds 0-10\n                               (0: keyframes only when needed, the default)\n                               --reset (restore defaults, then apply the rest)\n\nMode requests use experimental native-exported Apple URL options.\nThey do not confirm video negotiation. Telemetry and tuning use the running\napp's owner-only local socket; tuning from a viewer is sent to the sharing Mac\nover the encrypted session. No passwords are stored. MOORING_HOME overrides\nthe connection directory. SSH uses your own keys, agent and ~/.ssh/config in\nbatch mode and never prompts; MOORING_SSH_CONFIG names an alternate config.\n";

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
            eprintln!("Mooring: {error}");
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
        .ok_or("A command is required; run mooring --help")?;
    let trailing = &args[1..];
    match command.as_str() {
        "list" => {
            require_count(trailing, 0)?;
            Ok(json!(store.list()?))
        }
        "add" => {
            let options = parse_add(trailing)?;
            Ok(json!(store.add_connection(NewConnection {
                name: &options.name,
                host: &options.host,
                port: options.port,
                server: options.server,
                ssh_target: options.ssh.as_deref(),
            })?))
        }
        "remove" => {
            require_count(trailing, 1)?;
            store.remove(&trailing[0])?;
            Ok(json!({"removed": trailing[0]}))
        }
        "inspect" => {
            require_count(trailing, 1)?;
            let connection = store.get(&trailing[0])?;
            if let Some(hop) = &connection.ssh {
                return inspect_through_ssh(&connection, hop);
            }
            Ok(json!(mooring_platform::inspect_host(
                &connection.host,
                connection.port,
                Duration::from_secs(3)
            )?))
        }
        "connect" => {
            let (id, options) = parse_connect(trailing)?;
            let connection = store.get(id)?;
            if let Some(hop) = &connection.ssh {
                return connect_through_ssh(&connection, hop, options);
            }
            if options != ConnectOptions::default() {
                return Err("--no-viewer, --idle-seconds and --wait-seconds apply only to connections saved with --ssh.".into());
            }
            mooring_platform::launch_apple(&connection.host, connection.port)?;
            Ok(
                json!({"status":"launched", "connection":connection, "note":"Apple Screen Sharing controls authentication and display mode. Launch is not confirmation of a connected session."}),
            )
        }
        "connect-mode" => {
            require_count(trailing, 2)?;
            let connection = store.get(&trailing[0])?;
            let mode = match trailing[1].as_str() {
                "standard" => mooring_platform::AppleMode::Standard,
                "high_performance" => mooring_platform::AppleMode::HighPerformance,
                _ => return Err("Mode must be standard or high_performance.".into()),
            };
            if connection.ssh.is_some() {
                return Err("Display modes are not requested through SSH tunnels, which carry only the standard VNC stream. Use mooring connect ID.".into());
            }
            let url = mooring_platform::viewer_url(
                connection.server,
                &connection.host,
                connection.port,
                Some(mode),
            )?;
            mooring_platform::launch_viewer_url(&url)?;
            Ok(
                json!({"status":"requested", "mode":mode, "note":"Requested Apple's native exported-connection URL options. Launch does not confirm the negotiated mode."}),
            )
        }
        "home-network" => {
            require_count(trailing, 0)?;
            Ok(json!(mooring_platform::network_probe::local_network()))
        }
        "network-probe" => {
            require_count(trailing, 1)?;
            let connection = store.get(&trailing[0])?;
            if connection.ssh.is_some() {
                return Err("network-probe measures a direct path. This connection goes through SSH; use mooring inspect ID.".into());
            }
            let local_network = mooring_platform::network_probe::local_network();
            match mooring_platform::inspect_host(
                &connection.host,
                connection.port,
                Duration::from_millis(1500),
            ) {
                Ok(inspection) => {
                    let route =
                        mooring_platform::network_probe::target_route(inspection.resolved_address);
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
            let request: mooring_core::network::NetworkEvaluationRequest =
                serde_json::from_str(&trailing[0])
                    .map_err(|error| format!("Invalid network evaluation request: {error}"))?;
            Ok(json!(mooring_core::network::evaluate_network(request)))
        }
        "doctor" => {
            require_count(trailing, 0)?;
            Ok(json!({
                "version":env!("CARGO_PKG_VERSION"),
                "os":std::env::consts::OS, "architecture":std::env::consts::ARCH,
                "config_directory":store::path_display(&directory),
                "apple_silicon":cfg!(all(target_os="macos",target_arch="aarch64")),
                "apple_backend":"launches native Screen Sharing; Apple manages display mode",
                "custom_streaming_backend":"experimental native Mooring session; both Macs run Mooring",
                "automatic_quality":"menu-bar network policy uses live TCP/RFB checks; experimental Apple mode requests and Accessibility reconnects require setup",
                "inspection":"RFB greeting only; does not measure video latency, bandwidth or High Performance support",
                "password_storage":"none; Apple handles credentials",
                "ssh_tunnel":"connect starts /usr/bin/ssh -W per viewer connection in batch mode with your keys, agent and ~/.ssh/config; listens on 127.0.0.1 only; never prompts for or stores a password",
                "ssh_available":Path::new(ssh_tunnel::SYSTEM_SSH).is_file()
            }))
        }
        "simulate" => {
            require_count(trailing, 0)?;
            Ok(
                json!({"simulated":true, "note":"Synthetic telemetry; these are not measured remote-desktop performance results", "scenarios":mooring_core::demo_scenarios()}),
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
                _ => return Err("Usage: mooring telemetry [--count N]".into()),
            };
            stream_telemetry(&directory, count)?;
            Ok(Value::Null)
        }
        "tune" => send_tuning(&directory, parse_tune(trailing)?),
        _ => Err(format!("Unknown command '{command}'; run mooring --help")),
    }
}

const MAX_TELEMETRY_LINE: usize = 64 * 1024;

fn telemetry_socket(directory: &Path) -> Result<UnixStream, String> {
    let path = directory.join(mooring_platform::TELEMETRY_SOCKET);
    let stream = UnixStream::connect(&path).map_err(|_| {
        format!(
            "Mooring is not serving telemetry at {}. Open Mooring on this Mac first.",
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
        .map_err(|e| format!("Mooring stopped sending telemetry: {e}"))?;
    if read == 0 {
        return Err("Mooring closed the telemetry socket".into());
    }
    if line.len() > MAX_TELEMETRY_LINE || !line.ends_with('\n') {
        return Err("Mooring sent an oversized telemetry line".into());
    }
    Ok(line.trim_end().to_owned())
}

/// One snapshot per second while Mooring runs; stops after `count` if given.
fn stream_telemetry(directory: &Path, count: Option<usize>) -> Result<(), String> {
    let mut reader = BufReader::new(telemetry_socket(directory)?);
    let mut printed = 0;
    loop {
        let line = read_line(&mut reader)?;
        if serde_json::from_str::<Value>(&line).is_err() {
            return Err("Mooring sent invalid telemetry".into());
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
            other => return Err(format!("Unknown tune option '{other}'; run mooring --help")),
        };
        let key = key.replace('-', "_");
        if request.insert(key, value).is_some() {
            return Err(format!("Repeated tune option '{flag}'"));
        }
        remaining = next;
    }
    if request.is_empty() {
        return Err("Give at least one tune option; run mooring --help".into());
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
            .map_err(|_| "Mooring sent an invalid reply".to_string())?;
        if let Some(error) = reply.get("error").and_then(Value::as_str) {
            return Err(error.to_owned());
        }
        if let Some(ack) = reply.get("ack") {
            return Ok(
                json!({"status":"queued", "ack": ack, "note":"Applied on the sharing Mac within about a second while a native session is connected."}),
            );
        }
    }
    Err("Mooring did not acknowledge the tuning request".into())
}

fn require_count(args: &[String], count: usize) -> Result<(), String> {
    if args.len() != count {
        return Err(format!("Expected {count} argument(s); run mooring --help"));
    }
    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
struct AddOptions {
    name: String,
    host: String,
    port: u16,
    server: ServerKind,
    ssh: Option<String>,
}

fn parse_add(args: &[String]) -> Result<AddOptions, String> {
    let mut name = None;
    let mut host = None;
    let mut port = None;
    let mut server = None;
    let mut ssh = None;
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
            "--server" if server.is_none() => server = Some(ServerKind::parse(&pair[1])?),
            "--ssh" if ssh.is_none() => ssh = Some(pair[1].clone()),
            value => return Err(format!("Unknown or repeated option '{value}'")),
        }
    }
    if !remainder.is_empty() {
        return Err("Every add option requires a value".into());
    }
    let host = match (host, &ssh) {
        (Some(host), _) => host,
        (None, Some(_)) => ssh_tunnel::DEFAULT_REMOTE_HOST.to_owned(),
        (None, None) => return Err("--host is required (or --ssh to go through SSH)".into()),
    };
    Ok(AddOptions {
        name: name.ok_or("--name is required")?,
        host,
        port: port.unwrap_or(ssh_tunnel::DEFAULT_REMOTE_PORT),
        server: server.unwrap_or_default(),
        ssh,
    })
}

#[derive(Debug, Default, PartialEq, Eq)]
struct ConnectOptions {
    no_viewer: bool,
    idle_seconds: Option<u64>,
    wait_seconds: Option<u64>,
}

fn parse_connect(args: &[String]) -> Result<(&str, ConnectOptions), String> {
    let (id, mut rest) = args
        .split_first()
        .filter(|(id, _)| !id.starts_with('-'))
        .ok_or("Usage: mooring connect ID [--no-viewer] [--idle-seconds N] [--wait-seconds N]")?;
    let mut options = ConnectOptions::default();
    let seconds = |flag: &str, value: Option<&String>| -> Result<u64, String> {
        value
            .and_then(|v| v.parse::<u64>().ok())
            .filter(|v| (1..=3600).contains(v))
            .ok_or_else(|| format!("{flag} must be between 1 and 3600"))
    };
    while let Some((flag, tail)) = rest.split_first() {
        rest = tail;
        match flag.as_str() {
            "--no-viewer" if !options.no_viewer => options.no_viewer = true,
            "--idle-seconds" if options.idle_seconds.is_none() => {
                options.idle_seconds = Some(seconds(flag, rest.first())?);
                rest = &rest[1..];
            }
            "--wait-seconds" if options.wait_seconds.is_none() => {
                options.wait_seconds = Some(seconds(flag, rest.first())?);
                rest = &rest[1..];
            }
            other => return Err(format!("Unknown or repeated connect option '{other}'")),
        }
    }
    Ok((id, options))
}

/// Set by SIGINT, SIGTERM or SIGHUP; the tunnel then shuts down in order.
static STOP: AtomicBool = AtomicBool::new(false);

extern "C" fn request_stop(_: libc::c_int) {
    STOP.store(true, Ordering::SeqCst);
}

fn install_stop_signals() {
    for signal in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP] {
        // SAFETY: the handler only stores to an atomic, which is
        // async-signal-safe; the sigaction struct is fully initialized.
        unsafe {
            let mut action: libc::sigaction = std::mem::zeroed();
            action.sa_sigaction = request_stop as extern "C" fn(libc::c_int) as libc::sighandler_t;
            action.sa_flags = libc::SA_RESTART;
            libc::sigemptyset(&mut action.sa_mask);
            libc::sigaction(signal, &action, std::ptr::null_mut());
        }
    }
}

/// One JSON object per line. A closed stdout (for example, the app that
/// started this process has gone) stops the tunnel.
fn emit(value: &Value) {
    let mut out = std::io::stdout().lock();
    if writeln!(out, "{value}").and_then(|()| out.flush()).is_err() {
        STOP.store(true, Ordering::SeqCst);
    }
}

fn ssh_options() -> Result<SshOptions, String> {
    let mut options = SshOptions::default();
    if let Some(path) = std::env::var_os("MOORING_SSH_CONFIG") {
        let path = PathBuf::from(path);
        if !path.is_absolute() || !path.is_file() {
            return Err(
                "MOORING_SSH_CONFIG must be the absolute path of an ssh config file.".into(),
            );
        }
        options.config_file = Some(path);
    }
    Ok(options)
}

fn route_for(connection: &Connection, hop: &SshHop) -> Result<SshRoute, String> {
    SshRoute::new(&hop.target, &connection.host, connection.port)
}

fn describe_connection(connection: &Connection, hop: &SshHop) -> Value {
    json!({"id":connection.id, "name":connection.name, "server":connection.server,
           "ssh_target":hop.target, "remote_host":connection.host, "remote_port":connection.port})
}

fn server_note(connection: &Connection, check: &ssh_tunnel::RouteCheck) -> Option<String> {
    match (connection.server, check.looks_like_mac) {
        (ServerKind::Mac, false) => Some(format!(
            "This server announces RFB {}, not a Mac's 003.889. If it is not a Mac, save it with --server vnc.",
            check.rfb_version
        )),
        (ServerKind::Vnc, true) => Some(
            "This server announces itself as a Mac. Save it with --server mac to allow Mac display modes on a direct connection.".into(),
        ),
        _ => None,
    }
}

fn inspect_through_ssh(connection: &Connection, hop: &SshHop) -> Result<Value, String> {
    let route = route_for(connection, hop)?;
    match ssh_tunnel::check_route(&route, &ssh_options()?, Duration::from_secs(20)) {
        Ok(check) => {
            let note = server_note(connection, &check);
            let mut value = json!(check);
            // The app's connection check reads host, port, rfb_version and note.
            value["host"] = json!(route.remote_host);
            value["port"] = json!(route.remote_port);
            if let Some(extra) = note {
                value["note"] = json!(format!("{} {extra}", check.note));
            }
            Ok(value)
        }
        Err(error) => {
            println!(
                "{}",
                json!({"status":"failed", "connection":describe_connection(connection, hop), "error":error})
            );
            Err(error.message)
        }
    }
}

fn connect_through_ssh(
    connection: &Connection,
    hop: &SshHop,
    options: ConnectOptions,
) -> Result<Value, String> {
    let mut config = TunnelConfig::new(route_for(connection, hop)?);
    config.ssh = ssh_options()?;
    if let Some(seconds) = options.idle_seconds {
        config.limits.idle_timeout_ms = seconds * 1000;
    }
    if let Some(seconds) = options.wait_seconds {
        config.limits.first_viewer_timeout_ms = seconds * 1000;
    }
    install_stop_signals();
    // If whoever started this exits, stop too, so no tunnel outlives it.
    let parent = std::os::unix::process::parent_id();
    let should_stop =
        || STOP.load(Ordering::SeqCst) || std::os::unix::process::parent_id() != parent;
    emit(
        &json!({"event":"starting", "connection":describe_connection(connection, hop),
                 "limits":config.limits, "local_only":true}),
    );
    let server = connection.server;
    let outcome = ssh_tunnel::run_tunnel(
        &config,
        &should_stop,
        &mut |ready| {
            if let Some(note) = server_note(connection, &ready.check) {
                emit(&json!({"event":"note", "note":note}));
            }
            if options.no_viewer {
                return Ok(None);
            }
            // Through SSH the viewer always gets a plain URL: Mac display
            // modes are not requested over a tunnel, and never for non-Macs.
            let url =
                mooring_platform::viewer_url(server, ready.local_host, ready.local_port, None)?;
            mooring_platform::launch_viewer_url(&url)?;
            Ok(Some(url))
        },
        &mut |event| emit(&json!(event)),
    );
    let failed = outcome.reason.is_failure();
    let mut summary = json!(outcome);
    summary["event"] = json!(if failed { "failed" } else { "closed" });
    emit(&summary);
    if failed {
        Err(outcome
            .error
            .map(|error| error.message)
            .unwrap_or_else(|| format!("The SSH tunnel closed: {:?}.", outcome.reason)))
    } else {
        Ok(Value::Null)
    }
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
            std::env::temp_dir().join(format!("mooring-no-telemetry-{}", std::process::id()));
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
            AddOptions {
                name: "My Mac".into(),
                host: "mac.local".into(),
                port: 5900,
                server: ServerKind::Mac,
                ssh: None
            }
        );
    }
    #[test]
    fn ssh_connections_default_to_the_ssh_hosts_loopback_vnc() {
        assert_eq!(
            parse_add(&args(&[
                "--name", "M1 Linux", "--ssh", "m1-linux", "--server", "vnc"
            ]))
            .unwrap(),
            AddOptions {
                name: "M1 Linux".into(),
                host: "127.0.0.1".into(),
                port: 5900,
                server: ServerKind::Vnc,
                ssh: Some("m1-linux".into())
            }
        );
        let custom = parse_add(&args(&[
            "--name", "Desk", "--ssh", "bastion", "--host", "desk.lan", "--port", "5901",
        ]))
        .unwrap();
        assert_eq!((custom.host.as_str(), custom.port), ("desk.lan", 5901));
        for input in [
            vec!["--name", "X"],
            vec!["--name", "X", "--ssh", "a", "--ssh", "b"],
            vec!["--name", "X", "--host", "h", "--server", "linux"],
            vec!["--name", "X", "--ssh"],
            vec!["--name", "X", "--ssh", "a", "--ssh-password", "secret"],
        ] {
            assert!(parse_add(&args(&input)).is_err(), "{input:?}");
        }
    }
    #[test]
    fn connect_options_are_bounded() {
        let parsed = args(&[
            "abc",
            "--no-viewer",
            "--idle-seconds",
            "5",
            "--wait-seconds",
            "30",
        ]);
        let (id, options) = parse_connect(&parsed).unwrap();
        assert_eq!(id, "abc");
        assert_eq!(
            options,
            ConnectOptions {
                no_viewer: true,
                idle_seconds: Some(5),
                wait_seconds: Some(30)
            }
        );
        assert_eq!(
            parse_connect(&args(&["abc"])).unwrap().1,
            ConnectOptions::default()
        );
        for input in [
            vec![],
            vec!["--no-viewer"],
            vec!["abc", "--idle-seconds"],
            vec!["abc", "--idle-seconds", "0"],
            vec!["abc", "--idle-seconds", "3601"],
            vec!["abc", "--wait-seconds", "-1"],
            vec!["abc", "--no-viewer", "--no-viewer"],
            vec!["abc", "extra"],
        ] {
            assert!(parse_connect(&args(&input)).is_err(), "{input:?}");
        }
    }
}

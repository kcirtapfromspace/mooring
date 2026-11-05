mod store;

use mooring_core::desktop::DesktopWatchLimits;
use mooring_platform::ServerKind;
use mooring_platform::ssh::{
    self as ssh_tunnel, DESKTOP_PROBE_TIMEOUT, SshOptions, SshRoute, TunnelConfig, TunnelEvent,
};
use serde_json::{Map, Value, json};
use std::{
    io::{BufRead, BufReader, Write},
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};
use store::{Connection, NewConnection, SshHop, Store};

const HELP: &str = "Mooring — native Mac connections, Rust foundation\n\nUsage: mooring [--config-dir PATH] COMMAND\n\n  list                         List saved VNC desktops as JSON\n  add --name NAME --ssh TARGET [--host HOST] [--port PORT]\n                               Save a VNC server, such as wayvnc on Linux, reached\n                               through SSH. TARGET is a ~/.ssh/config alias or\n                               user@host; HOST and PORT are as seen from the SSH\n                               host (127.0.0.1:5900)\n  remove ID                    Remove a saved connection\n  inspect ID                   Read the server's RFB greeting; no login\n  desktop-status ID            Whether the remote desktop is locked and its\n                               display on. Read-only over SSH\n  vnc-check ID                 Run Mooring's encrypted VNC sign-in handshake\n                               until the server asks for credentials, then stop.\n                               Sends none\n  connect ID [--idle-seconds N] [--wait-seconds N]\n                               Open the SSH tunnel on 127.0.0.1 for Mooring's\n                               viewer and print JSON lines (including whether\n                               the desktop is locked) until no viewer has been\n                               connected for N seconds (default 60) or Ctrl-C\n  doctor                       Report local capabilities and limitations\n  simulate                     Run simulated adaptive-quality scenarios\n  telemetry [--count N]        Stream live native-session measurements as JSON lines\n  tune OPTIONS                 Adjust the sharing Mac's stream while connected:\n                               --bitrate-mbps 1-80  --max-width 640-3840 (even)\n                               --fps 1-60  --in-flight 1-2  --keyframe-seconds 0-10\n                               (0: keyframes only when needed, the default)\n                               --reset (restore defaults, then apply the rest)\n\nMacs connect through Mooring's own pairing, not Apple Screen Sharing.\nTelemetry and tuning use the running app's owner-only local socket; tuning\nfrom a viewer is sent to the sharing Mac over the encrypted session. No\npasswords are stored. MOORING_HOME overrides the connection directory. SSH\nuses your own keys, agent and ~/.ssh/config in batch mode and never prompts;\nMOORING_SSH_CONFIG names an alternate config.\n";

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
        "desktop-status" => {
            require_count(trailing, 1)?;
            let connection = store.get(&trailing[0])?;
            let hop = connection.ssh.as_ref().ok_or(
                "desktop-status reads the remote desktop over SSH, so it applies only to connections saved with --ssh.",
            )?;
            desktop_status_through_ssh(&connection, hop)
        }
        "connect" => {
            let (id, options) = parse_connect(trailing)?;
            let connection = store.get(id)?;
            if let Some(hop) = &connection.ssh {
                return connect_through_ssh(&connection, hop, options);
            }
            let _ = options;
            Err(not_connectable(&connection))
        }
        "vnc-check" => {
            require_count(trailing, 1)?;
            let connection = store.get(&trailing[0])?;
            let hop = connection.ssh.as_ref().ok_or(
                "vnc-check goes through the SSH tunnel, so it applies only to connections saved with --ssh.",
            )?;
            vnc_check_through_ssh(&connection, hop)
        }
        "doctor" => {
            require_count(trailing, 0)?;
            Ok(json!({
                "version":env!("CARGO_PKG_VERSION"),
                "os":std::env::consts::OS, "architecture":std::env::consts::ARCH,
                "config_directory":store::path_display(&directory),
                "apple_silicon":cfg!(all(target_os="macos",target_arch="aarch64")),
                "mac_backend":"native Mooring session between paired Macs; Apple Screen Sharing is no longer used",
                "vnc_viewer":"Mooring's own viewer for VNC servers such as wayvnc on Linux, only through SSH; RSA-AES sign-in",
                "inspection":"RFB greeting only; does not measure video latency or bandwidth",
                "password_storage":"none; a VNC server's password is typed for each sign-in, sent once and never stored or logged",
                "ssh_tunnel":"connect starts /usr/bin/ssh -W per viewer connection in batch mode with your keys, agent and ~/.ssh/config; listens on 127.0.0.1 only; SSH never prompts for or stores a password",
                "ssh_available":Path::new(ssh_tunnel::SYSTEM_SSH).is_file(),
                "desktop_status":"for SSH connections, a fixed read-only script reports whether the remote desktop is locked and its display on (Hyprland, Omarchy lock screen, logind); Mooring never types a password into a lock screen"
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
    if ssh.is_none() {
        return Err("--ssh is required: Mooring's viewer reaches VNC servers only through SSH. To connect to a Mac, pair it with Mooring instead.".into());
    }
    Ok(AddOptions {
        name: name.ok_or("--name is required")?,
        host: host.unwrap_or_else(|| ssh_tunnel::DEFAULT_REMOTE_HOST.to_owned()),
        port: port.unwrap_or(ssh_tunnel::DEFAULT_REMOTE_PORT),
        server: server.unwrap_or(ServerKind::Vnc),
        ssh,
    })
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
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
    let options = ssh_options()?;
    match ssh_tunnel::check_route(&route, &options, Duration::from_secs(20)) {
        Ok(check) => {
            let note = server_note(connection, &check);
            let mut value = json!(check);
            // The app's connection check reads host, port, rfb_version and note.
            value["host"] = json!(route.remote_host);
            value["port"] = json!(route.remote_port);
            if let Some(extra) = note {
                value["note"] = json!(format!("{} {extra}", check.note));
            }
            // A failed desktop read does not fail the connection check.
            if connection.server == ServerKind::Vnc {
                match ssh_tunnel::probe_desktop(&route, &options, DESKTOP_PROBE_TIMEOUT, &|| false)
                {
                    Ok(status) => value["desktop"] = json!(status),
                    Err(error) => value["desktop_error"] = json!(error),
                }
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

fn desktop_status_through_ssh(connection: &Connection, hop: &SshHop) -> Result<Value, String> {
    let route = route_for(connection, hop)?;
    match ssh_tunnel::probe_desktop(&route, &ssh_options()?, DESKTOP_PROBE_TIMEOUT, &|| false) {
        Ok(status) => {
            let mut value = json!(status);
            value["connection"] = describe_connection(connection, hop);
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

/// Why a saved connection without an SSH hop can't be opened any more.
fn not_connectable(connection: &Connection) -> String {
    if connection.server.is_mac() {
        format!(
            "{} was saved for Apple Screen Sharing, which Mooring no longer uses. Pair it with Mooring instead: on that Mac, open Mooring and choose Share this Mac.",
            connection.name
        )
    } else {
        format!(
            "{} is a VNC server saved without SSH. Mooring's viewer reaches VNC servers only through SSH; remove it and add it again with --ssh.",
            connection.name
        )
    }
}

/// Open the tunnel, run the VNC handshake through it up to the credential
/// request, and close everything. No credentials exist or are sent.
fn vnc_check_through_ssh(connection: &Connection, hop: &SshHop) -> Result<Value, String> {
    if connection.server != ServerKind::Vnc {
        return Err(
            "vnc-check is for VNC servers that are not Macs (saved with --server vnc).".into(),
        );
    }
    let mut config = TunnelConfig::new(route_for(connection, hop)?);
    config.ssh = ssh_options()?;
    config.limits.first_viewer_timeout_ms = 30_000;
    config.limits.idle_timeout_ms = 1_000;
    install_stop_signals();
    let port = std::sync::Mutex::new(None::<u16>);
    let done = AtomicBool::new(false);
    let stop = || done.load(Ordering::SeqCst) || STOP.load(Ordering::SeqCst);
    let started = std::time::Instant::now();
    let (outcome, check) = std::thread::scope(|scope| {
        let tunnel = scope.spawn(|| {
            ssh_tunnel::run_tunnel(
                &config,
                &stop,
                &mut |ready| {
                    *port
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner) =
                        Some(ready.local_port);
                    Ok(None)
                },
                &mut |_| {},
            )
        });
        let deadline = started + Duration::from_secs(40);
        let local_port = loop {
            if let Some(port) = *port
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
            {
                break Some(port);
            }
            if tunnel.is_finished() || std::time::Instant::now() > deadline || stop() {
                break None;
            }
            std::thread::sleep(Duration::from_millis(20));
        };
        let check = local_port.map(|local_port| {
            let mut vnc = mooring_vnc::SessionConfig::new("127.0.0.1", local_port);
            vnc.check_only = true;
            let session = mooring_vnc::Session::start(vnc, None);
            let mut events = Vec::new();
            let deadline = std::time::Instant::now() + Duration::from_secs(30);
            loop {
                if let Some(event) = session.poll_event() {
                    let last = matches!(event, mooring_vnc::SessionEvent::Closed { .. });
                    events.push(event);
                    if last {
                        break;
                    }
                } else if std::time::Instant::now() > deadline || stop() {
                    break;
                } else {
                    std::thread::sleep(Duration::from_millis(10));
                }
            }
            drop(session);
            events
        });
        done.store(true, Ordering::SeqCst);
        (tunnel.join().ok(), check)
    });
    let describe = describe_connection(connection, hop);
    let Some(events) = check else {
        let error = outcome.and_then(|outcome| outcome.error);
        let message = error
            .as_ref()
            .map_or("The SSH tunnel did not become ready.".to_string(), |e| {
                e.message.clone()
            });
        println!(
            "{}",
            json!({"status":"failed", "connection":describe, "error":error})
        );
        return Err(message);
    };
    let requested = events
        .iter()
        .find(|e| matches!(e, mooring_vnc::SessionEvent::CredentialsRequested { .. }));
    let negotiated = events
        .iter()
        .find(|e| matches!(e, mooring_vnc::SessionEvent::Negotiated { .. }));
    let error = events.iter().find_map(|e| match e {
        mooring_vnc::SessionEvent::Closed { error } => error.clone(),
        _ => None,
    });
    let value = json!({
        "status": if requested.is_some() && error.is_none() { "ok" } else { "failed" },
        "connection": describe,
        "negotiated": negotiated,
        "credentials_requested": requested,
        "credentials_sent": false,
        "error": error,
        "duration_ms": started.elapsed().as_millis() as u64,
        "note": "Mooring's encrypted handshake reached the server's credential request and stopped there; no username or password was sent, so the server did not check a password."
    });
    if requested.is_some() && error.is_none() {
        Ok(value)
    } else {
        println!("{value}");
        Err(error.map_or(
            "The VNC handshake did not reach the credential request.".into(),
            |e| e.message,
        ))
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
    // Desktop lock reports start once the viewer is open, so the first one
    // follows `viewer_opened`, and end before the final line.
    let desktop_ready = AtomicBool::new(false);
    let tunnel_done = AtomicBool::new(false);
    let outcome = std::thread::scope(|scope| {
        if server == ServerKind::Vnc {
            scope.spawn(|| {
                let stop = || tunnel_done.load(Ordering::SeqCst) || should_stop();
                while !desktop_ready.load(Ordering::SeqCst) {
                    if stop() {
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(50));
                }
                let _ = ssh_tunnel::watch_desktop(
                    &config.route,
                    &config.ssh,
                    DesktopWatchLimits::default(),
                    DESKTOP_PROBE_TIMEOUT,
                    &stop,
                    &mut |event| emit(&json!(event)),
                );
            });
        }
        let outcome = run_tunnel_reporting(&config, connection, options, &should_stop, &|event| {
            if matches!(event, TunnelEvent::Ready(_)) {
                desktop_ready.store(true, Ordering::SeqCst);
            }
        });
        tunnel_done.store(true, Ordering::SeqCst);
        outcome
    });
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

/// Run the tunnel, printing each event, and pass each event to `observe`.
fn run_tunnel_reporting(
    config: &TunnelConfig,
    connection: &Connection,
    options: ConnectOptions,
    should_stop: &dyn Fn() -> bool,
    observe: &dyn Fn(&TunnelEvent),
) -> ssh_tunnel::TunnelOutcome {
    let server = connection.server;
    ssh_tunnel::run_tunnel(
        config,
        should_stop,
        &mut |ready| {
            if let Some(note) = server_note(connection, &ready.check) {
                emit(&json!({"event":"note", "note":note}));
            }
            // Mooring's own viewer connects to the local port; no other
            // viewer is launched. --no-viewer is kept for compatibility.
            let _ = (options, server);
            Ok(None)
        },
        &mut |event| {
            emit(&json!(event));
            observe(event);
        },
    )
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
    fn new_connections_need_ssh_and_are_never_macs() {
        // Mooring no longer opens Apple Screen Sharing: Macs are paired.
        let refused = parse_add(&args(&["--name", "My Mac", "--host", "mac.local"])).unwrap_err();
        assert!(
            refused.contains("--ssh is required") && refused.contains("pair"),
            "{refused}"
        );
        let mac = parse_add(&args(&[
            "--name", "My Mac", "--ssh", "mac", "--server", "mac",
        ]))
        .unwrap_err();
        assert!(mac.contains("Pair Macs"), "{mac}");
        // Without --server, an SSH connection is a VNC server.
        let linux = parse_add(&args(&["--name", "M1 Linux", "--ssh", "m1-linux"])).unwrap();
        assert_eq!(linux.server, ServerKind::Vnc);
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

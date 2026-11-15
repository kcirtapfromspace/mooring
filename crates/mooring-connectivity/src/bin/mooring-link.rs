//! Explicit experimental harness. Locators are public; private seeds never
//! appear in stdout, arguments, diagnostics, or Mooring's connection catalog.
use mooring_connectivity::{
    Config, ConnectivityMode, EndpointId, LinkService, SecretKey,
    blocking::{InternetBridge, InternetServer},
};
use std::{
    fs::{File, OpenOptions},
    io::{Read, Write},
    path::Path,
};
use zeroize::Zeroizing;

const HELP: &str = "Mooring experimental internet link\n\n  mooring-link identity KEY_FILE       Create a private transport identity; print its public ID\n  mooring-link id KEY_FILE             Print an existing transport identity's public ID\n  mooring-link serve --key KEY_FILE --allow PEER_ID --service native|ssh [--relay HTTPS_URL] [--relay-only]\n  mooring-link connect --key KEY_FILE --ticket FILE --service native|ssh [--relay HTTPS_URL] [--relay-only]\n  mooring-link proxy --key KEY_FILE --ticket FILE --service ssh [--relay HTTPS_URL] [--relay-only]\n      Use as SSH ProxyCommand; stdout carries only the SSH byte stream.\n  mooring-link ssh-session --key KEY_FILE --ticket FILE --service ssh --target SSH_ALIAS [--relay HTTPS_URL] [--relay-only] -- COMMAND [ARG...]\n      Own one SSH connection for all command channels; set MOORING_SSH_CONFIG.\n\nThe server permits only the explicit endpoint ID. The link carries Mooring's\nexisting authenticated session, or SSH to the host's own loopback SSH server.\nIt never authorizes desktop access on its own and does not publish discovery.\nDirect-only is the default. Tickets expire after ten minutes. Ctrl-C closes\nthe link; the host and client stop automatically after one hour.\n";
fn main() {
    match run() {
        Ok(0) => {}
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("Mooring link: {error}");
            std::process::exit(1);
        }
    }
}
fn key(path: &Path) -> Result<SecretKey, Box<dyn std::error::Error>> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let mut file = options.open(path)?;
    let meta = file.metadata()?;
    if !meta.is_file() || meta.file_type().is_symlink() || meta.len() != 32 {
        return Err("Identity must be a regular 32-byte seed file".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if meta.mode() & 0o077 != 0 || meta.uid() != unsafe { libc::getuid() } {
            return Err("Identity must be owned by this user with mode 0600".into());
        }
    }
    let mut data = Zeroizing::new([0u8; 32]);
    file.read_exact(data.as_mut())?;
    Ok(SecretKey::from_bytes(&data))
}
fn run() -> Result<i32, Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(command) = args.first() else {
        print!("{HELP}");
        return Ok(0);
    };
    if command == "--help" || command == "help" {
        print!("{HELP}");
        return Ok(0);
    }
    if command == "local-proxy" {
        if args.len() != 2 {
            return Err("local-proxy requires one loopback address".into());
        }
        let address: std::net::SocketAddr = args[1].parse()?;
        if !address.ip().is_loopback() || address.port() == 0 {
            return Err("local-proxy requires loopback".into());
        }
        pipe(address)?;
        return Ok(0);
    }
    if command == "identity" || command == "id" {
        if args.len() != 2 {
            return Err("Use identity KEY_FILE or id KEY_FILE".into());
        }
        let path = Path::new(&args[1]);
        if command == "identity" {
            let secret = SecretKey::generate();
            let bytes = Zeroizing::new(secret.to_bytes());
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options.open(path)?;
            file.write_all(bytes.as_ref())?;
            file.sync_all()?;
        }
        println!("{}", key(path)?.public());
        return Ok(0);
    }
    if !["serve", "connect", "proxy", "ssh-session"].contains(&command.as_str()) {
        return Err("Unknown command; use --help".into());
    }
    let mut options = std::collections::BTreeMap::new();
    let mut relay_only = false;
    let mut child_command = Vec::new();
    let mut i = 1;
    while i < args.len() {
        let flag = &args[i];
        if flag == "--" {
            child_command = args[i + 1..].iter().map(std::ffi::OsString::from).collect();
            break;
        }
        if flag == "--relay-only" {
            if relay_only {
                return Err("Duplicate flag".into());
            }
            relay_only = true;
            i += 1;
            continue;
        }
        if ![
            "--key",
            "--allow",
            "--service",
            "--relay",
            "--ticket",
            "--target",
        ]
        .contains(&flag.as_str())
        {
            return Err("Unknown option".into());
        }
        let value = args.get(i + 1).ok_or("Option needs a value")?;
        if options.insert(flag.as_str(), value.as_str()).is_some() {
            return Err("Duplicate option".into());
        }
        i += 2;
    }
    let required = |name| {
        options
            .get(name)
            .copied()
            .ok_or_else(|| format!("Missing {name}"))
    };
    let service = match required("--service")? {
        "native" => LinkService::NativeSession,
        "ssh" => LinkService::Ssh,
        _ => return Err("Service must be native or ssh".into()),
    };
    let relay = options.get("--relay").map(|s| s.parse()).transpose()?;
    let config = Config {
        mode: if relay_only {
            ConnectivityMode::RelayOnly
        } else if relay.is_some() {
            ConnectivityMode::Automatic
        } else {
            ConnectivityMode::DirectOnly
        },
        relay,
        ..Default::default()
    };
    if ["proxy", "ssh-session"].contains(&command.as_str()) && service != LinkService::Ssh {
        return Err("proxy and ssh-session permit only SSH".into());
    }
    if command != "ssh-session" && (!child_command.is_empty() || options.contains_key("--target")) {
        return Err("Only ssh-session accepts --target and a command after --".into());
    }
    if command == "ssh-session" {
        if child_command.is_empty() {
            return Err("Supply a command after --".into());
        }
        mooring_core::connection::validate_ssh_target(required("--target")?)?;
    }
    let session_ms = config.limits.session_ms;
    let secret = key(Path::new(required("--key")?))?;
    if command == "serve" {
        if options.contains_key("--ticket") {
            return Err("serve does not take a ticket".into());
        }
        let peer: EndpointId = required("--allow")?.parse()?;
        let mut server = InternetServer::start(secret, config, vec![peer], service)?;
        println!(
            "{}",
            serde_json::json!({"event":"ready","endpoint_id":server.id().to_string(),"ticket":server.ticket()?.encode()?})
        );
        std::io::stdout().flush()?;
        server.wait_for_shutdown();
    } else {
        if options.contains_key("--allow") {
            return Err("connect uses the endpoint ID in its ticket".into());
        }
        let mut data = String::new();
        File::open(required("--ticket")?)?
            .take(8193)
            .read_to_string(&mut data)?;
        let bridge = InternetBridge::dial(secret, config, data.trim(), service)?;
        if command == "proxy" {
            pipe(bridge.local_address())?;
            return Ok(0);
        }
        if command == "ssh-session" {
            let status = mooring_connectivity::ssh_session::run(
                bridge.local_address(),
                required("--target")?,
                &child_command,
                session_ms,
            )?;
            return Ok(status.code().unwrap_or(1));
        }
        println!(
            "{}",
            serde_json::json!({"event":"ready","local_address":bridge.local_address(),"path":bridge.path()})
        );
        std::io::stdout().flush()?;
        bridge.wait()?;
    }
    Ok(0)
}

fn pipe(address: std::net::SocketAddr) -> Result<(), Box<dyn std::error::Error>> {
    let mut socket =
        std::net::TcpStream::connect_timeout(&address, std::time::Duration::from_secs(2))?;
    socket.set_nodelay(true)?;
    let mut upstream = socket.try_clone()?;
    std::thread::spawn(move || {
        let _ = std::io::copy(&mut std::io::stdin().lock(), &mut upstream);
        let _ = upstream.shutdown(std::net::Shutdown::Write);
    });
    // SSH key-exchange records must flush without waiting for a newline.
    let mut stdout = std::io::stdout().lock();
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        let count = socket.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        stdout.write_all(&buffer[..count])?;
        stdout.flush()?;
    }
    Ok(())
}

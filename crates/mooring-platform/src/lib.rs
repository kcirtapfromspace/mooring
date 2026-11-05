//! Platform integration: host validation, the credential-free RFB greeting
//! check, the SSH tunnel and desktop check, and local network details.
//!
//! The greeting check reads only the initial RFB greeting. It never
//! authenticates or negotiates a session.

use serde::{Deserialize, Serialize};
use std::io::{self, Read};
use std::net::{IpAddr, Ipv6Addr, SocketAddr, TcpStream, ToSocketAddrs};
use std::path::PathBuf;
use std::time::{Duration, Instant};

pub mod network_probe;
pub mod ssh;

/// The app's owner-only local telemetry socket, relative to the data directory.
/// It lives in its own 0700 folder so no other user can reach it.
pub const TELEMETRY_SOCKET: &str = "telemetry/telemetry.sock";

/// Shared by the CLI and native session. Existing installations keep their
/// data directory so other running copies still use the same store and lock.
pub fn support_directory() -> Result<PathBuf, String> {
    support_directory_for(
        std::env::var_os("MOORING_HOME"),
        std::env::var_os("MACLINK_HOME"),
        std::env::var_os("HOME"),
    )
}

fn support_directory_for(
    override_path: Option<std::ffi::OsString>,
    legacy_override: Option<std::ffi::OsString>,
    home: Option<std::ffi::OsString>,
) -> Result<PathBuf, String> {
    if let Some(path) = override_path.or(legacy_override) {
        if path.is_empty() {
            return Err("MOORING_HOME must not be empty".into());
        }
        return Ok(PathBuf::from(path));
    }
    let base = PathBuf::from(home.ok_or("HOME is unavailable; set MOORING_HOME")?)
        .join("Library/Application Support");
    let existing = base.join("MacLink"); // Stable storage for previously paired Macs.
    Ok(if existing.exists() {
        existing
    } else {
        base.join("Mooring")
    })
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HostInspection {
    pub host: String,
    pub port: u16,
    /// Time spent establishing the successful TCP connection, excluding DNS.
    pub tcp_connect_ms: f64,
    pub rfb_greeting_ms: f64,
    pub resolved_address: IpAddr,
    /// The advertised version, such as `003.889`; not a capability claim.
    pub rfb_version: String,
    pub note: String,
}

/// Validate and normalize a host without accepting URLs or embedded credentials.
///
/// Supports ASCII DNS names, IPv4, and bracketed or unbracketed IPv6. Scoped IPv6
/// addresses are intentionally unsupported; use the Mac's DNS name instead.
pub fn validate_host(host: &str) -> Result<String, String> {
    const INVALID: &str =
        "Enter a hostname or IP address only, without a URL, user name, port, spaces, or path.";
    if host.is_empty() || !host.is_ascii() || host.len() > 254 {
        return Err(INVALID.into());
    }
    if host.starts_with('[') || host.ends_with(']') {
        let value = host
            .strip_prefix('[')
            .and_then(|s| s.strip_suffix(']'))
            .ok_or(INVALID)?;
        return value
            .parse::<Ipv6Addr>()
            .map(|ip| ip.to_string())
            .map_err(|_| INVALID.into());
    }
    if let Ok(ip) = host.parse::<IpAddr>() {
        return Ok(ip.to_string());
    }
    let name = host.strip_suffix('.').unwrap_or(host);
    if name.is_empty() || name.len() > 253 {
        return Err(INVALID.into());
    }
    // Do not let the system resolver interpret abbreviated or octal IPv4.
    if name.bytes().all(|b| b.is_ascii_digit() || b == b'.') {
        return Err("Use a complete IPv4 address, for example 192.168.1.10.".into());
    }
    // Some resolvers also accept hexadecimal IPv4 spellings.
    if name.split('.').all(|label| {
        label.bytes().all(|b| b.is_ascii_digit())
            || label
                .strip_prefix("0x")
                .or_else(|| label.strip_prefix("0X"))
                .is_some_and(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_hexdigit()))
    }) {
        return Err("Use a standard hostname or complete IPv4 address.".into());
    }
    for label in name.split('.') {
        if label.is_empty()
            || label.len() > 63
            || !label.as_bytes()[0].is_ascii_alphanumeric()
            || !label.as_bytes()[label.len() - 1].is_ascii_alphanumeric()
            || !label
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-')
        {
            return Err(INVALID.into());
        }
    }
    Ok(host.to_ascii_lowercase())
}

/// Inspect one explicitly supplied host by reading its 12-byte RFB greeting.
///
/// `timeout` is a shared deadline for TCP connection attempts and greeting reads
/// **after DNS resolution**. `std::net` delegates DNS to the system resolver,
/// which has no cancellable deadline. Call this off the UI thread; use an IP
/// address when a strict overall wall-clock bound is required. DNS results are
/// capped at 32 addresses. This does not test throughput, UDP, authentication,
/// the remote OS, or High Performance compatibility.
pub fn inspect_host(host: &str, port: u16, timeout: Duration) -> Result<HostInspection, String> {
    let host = validate_host(host)?;
    validate_port(port)?;
    if timeout.is_zero() {
        return Err("Inspection timeout must be greater than zero.".into());
    }
    let addresses: Vec<SocketAddr> = (host.as_str(), port)
        .to_socket_addrs()
        .map_err(|e| format!("Could not resolve {host}: {e}"))?
        .take(32)
        .collect();
    if addresses.is_empty() {
        return Err(format!("No network addresses were found for {host}."));
    }
    let deadline = Instant::now()
        .checked_add(timeout)
        .ok_or("Inspection timeout is too large.")?;
    let mut last_error = String::new();
    for (index, address) in addresses.iter().enumerate() {
        let budget = remaining(deadline)? / (addresses.len() - index) as u32;
        if budget.is_zero() {
            return Err("Inspection timed out.".into());
        }
        let start = Instant::now();
        match TcpStream::connect_timeout(address, budget) {
            Ok(mut stream) => {
                let tcp_connect_ms = start.elapsed().as_secs_f64() * 1000.0;
                let greeting_start = Instant::now();
                let greeting = read_greeting(&mut stream, deadline)?;
                let rfb_greeting_ms = greeting_start.elapsed().as_secs_f64() * 1000.0;
                return Ok(HostInspection {
                    host,
                    port,
                    tcp_connect_ms,
                    rfb_greeting_ms,
                    resolved_address: address.ip(),
                    rfb_version: greeting,
                    note: "RFB greeting received without authentication. This does not establish Apple High Performance support, available bandwidth, or session quality. TCP timing excludes DNS; the system DNS resolver is not covered by the timeout.".into(),
                });
            }
            Err(e) => last_error = e.to_string(),
        }
    }
    Err(format!("Could not connect to {host}:{port}: {last_error}"))
}

fn remaining(deadline: Instant) -> Result<Duration, String> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|duration| !duration.is_zero())
        .ok_or_else(|| "Inspection timed out.".into())
}

fn read_greeting(stream: &mut TcpStream, deadline: Instant) -> Result<String, String> {
    let mut bytes = [0_u8; 12];
    let mut count = 0;
    while count < bytes.len() {
        stream
            .set_read_timeout(Some(remaining(deadline)?))
            .map_err(|e| format!("Could not set the inspection timeout: {e}"))?;
        match stream.read(&mut bytes[count..]) {
            Ok(0) => return Err(format!("Incomplete RFB greeting ({count} of 12 bytes).")),
            Ok(size) => count += size,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                ) =>
            {
                return Err("Inspection timed out while reading the RFB greeting.".into());
            }
            Err(e) => return Err(format!("Could not read the RFB greeting: {e}")),
        }
    }
    parse_greeting(&bytes)
}

/// Validate a 12-byte `RFB xxx.yyy\n` greeting and return `xxx.yyy`.
pub(crate) fn parse_greeting(bytes: &[u8; 12]) -> Result<String, String> {
    if &bytes[..4] != b"RFB "
        || !bytes[4..7].iter().all(u8::is_ascii_digit)
        || bytes[7] != b'.'
        || !bytes[8..11].iter().all(u8::is_ascii_digit)
        || bytes[11] != b'\n'
    {
        return Err("The server did not send a valid RFB greeting.".into());
    }
    // Numeric ASCII was validated above; no server-controlled text is returned.
    String::from_utf8(bytes[4..11].to_vec()).map_err(|_| "Invalid RFB version.".into())
}

fn validate_port(port: u16) -> Result<(), String> {
    if port == 0 {
        return Err("The port must be between 1 and 65535.".into());
    }
    Ok(())
}

/// What kind of VNC server a saved connection reaches. Mooring's own viewer
/// opens `Vnc` servers (such as wayvnc on Linux) through SSH. `Mac` is kept
/// only so connections saved for Apple Screen Sharing still load: Mooring
/// now reaches Macs by pairing, and no longer opens Screen Sharing.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ServerKind {
    #[default]
    Mac,
    Vnc,
}

impl ServerKind {
    pub fn is_mac(&self) -> bool {
        *self == ServerKind::Mac
    }

    pub fn parse(value: &str) -> Result<Self, String> {
        match value {
            "vnc" => Ok(Self::Vnc),
            "mac" => Err("Mooring no longer opens Apple Screen Sharing. Pair Macs with Mooring instead (Pair a Mac in the app).".into()),
            _ => Err("Server must be vnc (a VNC server such as wayvnc on Linux).".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::net::TcpListener;
    use std::thread::{self, JoinHandle};

    #[test]
    fn branding_preserves_existing_storage_and_explicit_overrides() {
        let home = std::env::temp_dir().join(format!("mooring-storage-{}", std::process::id()));
        std::fs::create_dir_all(&home).unwrap();
        let select = |current, legacy| {
            support_directory_for(current, legacy, Some(home.clone().into_os_string()))
        };
        let base = home.join("Library/Application Support");
        assert_eq!(select(None, None).unwrap(), base.join("Mooring"));
        let existing = base.join("MacLink");
        std::fs::create_dir_all(&existing).unwrap();
        std::fs::write(existing.join("connections.json"), b"saved connections").unwrap();
        assert_eq!(select(None, None).unwrap(), existing);
        assert_eq!(
            std::fs::read(existing.join("connections.json")).unwrap(),
            b"saved connections"
        );
        assert_eq!(
            select(Some("new".into()), Some("old".into())).unwrap(),
            PathBuf::from("new")
        );
        assert_eq!(
            select(None, Some("old".into())).unwrap(),
            PathBuf::from("old")
        );
        assert!(select(Some("".into()), Some("old".into())).is_err());
        assert!(support_directory_for(None, None, None).is_err());
        std::fs::remove_dir_all(home).unwrap();
    }

    fn mock_server(action: impl FnOnce(TcpStream) + Send + 'static) -> (u16, JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = thread::spawn(move || action(listener.accept().unwrap().0));
        (port, handle)
    }

    #[test]
    fn validates_and_normalizes_hosts() {
        for (input, expected) in [
            ("Mac-Studio.local", "mac-studio.local"),
            ("mac.local.", "mac.local."),
            ("localhost", "localhost"),
            ("192.168.1.12", "192.168.1.12"),
            ("[2001:DB8::1]", "2001:db8::1"),
            ("::1", "::1"),
        ] {
            assert_eq!(validate_host(input).unwrap(), expected);
        }
    }

    #[test]
    fn rejects_urls_credentials_options_and_ambiguous_hosts() {
        for host in [
            "",
            " ",
            " mac.local",
            "mac.local\n",
            "vnc://mac.local",
            "https://mac.local",
            "user@mac.local",
            "user:pass@mac.local",
            "mac.local:5900",
            "mac.local/path",
            "mac.local?mode=fast",
            "mac.local#x",
            "mac%2elocal",
            "--args",
            "-mac.local",
            "mac-.local",
            "mac..local",
            ".mac.local",
            "mac_local",
            "mác.local",
            "[::1",
            "::1]",
            "[127.0.0.1]",
            "[::1]:5900",
            "fe80::1%en0",
            "[fe80::1%25en0]",
            "127.1",
            "0127.0.0.1",
            "999.1.1.1",
            "0x7f000001",
            "0x7f.0.0.1",
            "mac;touch",
            "$(id)",
            "`id`",
            "mac\\local",
        ] {
            assert!(validate_host(host).is_err(), "accepted {host:?}");
        }
        assert!(validate_host(&format!("{}.local", "a".repeat(64))).is_err());
        assert!(
            validate_host(&format!(
                "{}.{}.{}.{}",
                "a".repeat(63),
                "b".repeat(63),
                "c".repeat(63),
                "d".repeat(63)
            ))
            .is_err()
        );
    }

    #[test]
    fn only_vnc_servers_can_be_added() {
        assert_eq!(ServerKind::parse("vnc").unwrap(), ServerKind::Vnc);
        assert!(ServerKind::parse("mac").unwrap_err().contains("Pair Macs"));
        assert!(ServerKind::parse("linux").is_err());
        // Connections saved before the server field existed were Macs.
        assert_eq!(ServerKind::default(), ServerKind::Mac);
    }

    #[test]
    fn reads_greeting_without_sending_any_bytes() {
        let (port, server) = mock_server(|mut socket| {
            socket.write_all(b"RFB 003.889\n").unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            assert_eq!(socket.read(&mut [0_u8; 32]).unwrap(), 0);
        });
        let result = inspect_host("127.0.0.1", port, Duration::from_secs(1)).unwrap();
        assert_eq!(result.rfb_version, "003.889");
        assert_eq!(result.port, port);
        assert!(result.tcp_connect_ms.is_finite());
        assert!(result.note.contains("without authentication"));
        server.join().unwrap();
    }

    #[test]
    fn handles_fragmented_greetings() {
        let (port, server) = mock_server(|mut socket| {
            socket.write_all(b"RFB 00").unwrap();
            thread::sleep(Duration::from_millis(10));
            socket.write_all(b"3.008\n").unwrap();
        });
        assert_eq!(
            inspect_host("127.0.0.1", port, Duration::from_secs(1))
                .unwrap()
                .rfb_version,
            "003.008"
        );
        server.join().unwrap();
    }

    #[test]
    fn rejects_malformed_greetings() {
        for bytes in [
            *b"HTTP/1.1 200",
            *b"RFB 00a.008\n",
            *b"RFB 003-008\n",
            *b"RFB 003.008\r",
        ] {
            let (port, server) = mock_server(move |mut socket| socket.write_all(&bytes).unwrap());
            assert!(
                inspect_host("127.0.0.1", port, Duration::from_secs(1))
                    .unwrap_err()
                    .contains("valid RFB")
            );
            server.join().unwrap();
        }
    }

    #[test]
    fn reports_a_partial_greeting() {
        let (port, server) = mock_server(|mut socket| socket.write_all(b"RFB 003.").unwrap());
        assert!(
            inspect_host("127.0.0.1", port, Duration::from_secs(1))
                .unwrap_err()
                .contains("Incomplete")
        );
        server.join().unwrap();
    }

    #[test]
    fn times_out_a_silent_server() {
        let (port, server) = mock_server(|_socket| thread::sleep(Duration::from_millis(250)));
        let start = Instant::now();
        assert!(
            inspect_host("127.0.0.1", port, Duration::from_millis(50))
                .unwrap_err()
                .contains("timed out")
        );
        assert!(start.elapsed() < Duration::from_millis(200));
        server.join().unwrap();
    }

    #[test]
    fn deadline_applies_to_the_whole_greeting_not_each_byte() {
        let (port, server) = mock_server(|mut socket| {
            for byte in b"RFB 003.008\n" {
                if socket.write_all(&[*byte]).is_err() {
                    break;
                }
                thread::sleep(Duration::from_millis(30));
            }
        });
        let start = Instant::now();
        assert!(
            inspect_host("127.0.0.1", port, Duration::from_millis(80))
                .unwrap_err()
                .contains("timed out")
        );
        assert!(start.elapsed() < Duration::from_millis(250));
        server.join().unwrap();
    }

    #[test]
    fn rejects_invalid_probe_parameters_before_network_io() {
        assert!(inspect_host("localhost", 0, Duration::from_secs(1)).is_err());
        assert!(inspect_host("localhost", 5900, Duration::ZERO).is_err());
        assert!(inspect_host("vnc://localhost", 5900, Duration::from_secs(1)).is_err());
    }
}

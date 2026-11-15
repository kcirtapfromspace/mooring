//! Platform integration: host validation, the credential-free RFB greeting
//! check, the SSH tunnel and desktop check, and local network details.
//!
//! The greeting check reads only the initial RFB greeting. It never
//! authenticates or negotiates a session.

use serde::{Deserialize, Serialize};
use std::io::{self, Read};
use std::net::{IpAddr, SocketAddr, TcpStream, ToSocketAddrs};
use std::time::{Duration, Instant};

pub mod network_probe;
pub mod ssh;

pub use mooring_storage::{TELEMETRY_SOCKET, support_directory};

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

pub use mooring_core::connection::validate_host;

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

pub use mooring_core::connection::ServerKind;

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::net::TcpListener;
    use std::thread::{self, JoinHandle};

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

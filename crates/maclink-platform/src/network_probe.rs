//! Read the route of the actual address that answered the probe. A direct
//! interface does not exclude a tunnel implemented by an external router.
use serde::Serialize;
use std::net::IpAddr;

#[derive(Debug, Serialize, Default)]
pub struct TargetRoute {
    pub interface: Option<String>,
    pub gateway: Option<String>,
    pub tunnel: Option<bool>,
}

pub fn target_route(address: IpAddr) -> TargetRoute {
    #[cfg(target_os = "macos")]
    {
        use std::process::{Command, Stdio};
        use std::time::{Duration, Instant};
        let family = if address.is_ipv4() { "-inet" } else { "-inet6" };
        let Ok(mut child) = Command::new("/sbin/route")
            .args(["-n", "get", family, &address.to_string()])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
        else {
            return TargetRoute::default();
        };
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            match child.try_wait() {
                Ok(Some(status)) if status.success() => {
                    // route get emits a small, fixed table for one numeric address.
                    return child
                        .wait_with_output()
                        .ok()
                        .map(|out| parse_route(&String::from_utf8_lossy(&out.stdout)))
                        .unwrap_or_default();
                }
                Ok(None) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(10))
                }
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return TargetRoute::default();
                }
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = address;
        TargetRoute::default()
    }
}

fn parse_route(text: &str) -> TargetRoute {
    let mut route = TargetRoute::default();
    for line in text.lines().take(64) {
        let Some((key, value)) = line.trim().split_once(':') else {
            continue;
        };
        let value = value.trim();
        if value.is_empty() || value.len() > 128 {
            continue;
        }
        match key {
            "interface" if value.bytes().all(|c| c.is_ascii_alphanumeric()) => {
                route.interface = Some(value.into());
                route.tunnel = if value.starts_with("utun")
                    || value.starts_with("tun")
                    || value.starts_with("ppp")
                    || value.starts_with("ipsec")
                {
                    Some(true)
                } else if value.starts_with("en") {
                    Some(false)
                } else {
                    None
                };
            }
            "gateway" => route.gateway = Some(value.into()),
            _ => {}
        }
    }
    route
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn target_tunnel_is_distinct_from_direct_and_unknown_routes() {
        assert_eq!(
            parse_route("interface: utun4\ngateway: 100.64.0.1").tunnel,
            Some(true)
        );
        assert_eq!(parse_route("interface: en0").tunnel, Some(false));
        assert_eq!(parse_route("interface: lo0").tunnel, None);
        assert_eq!(parse_route("interface: unexpected/name").interface, None);
        assert_eq!(parse_route("").tunnel, None);
    }
}

//! Read-only local routing and cached-neighbor inspection. These are location
//! hints: an external router can bridge or tunnel a remote network.
use serde::Serialize;
use std::net::IpAddr;
use std::time::{Duration, Instant};

#[derive(Debug, Serialize, Default)]
pub struct TargetRoute {
    pub interface: Option<String>,
    pub gateway: Option<String>,
    pub tunnel: Option<bool>,
}

#[derive(Debug, Serialize, Default)]
pub struct LocalNetwork {
    pub fingerprint: Option<String>,
    pub description: String,
    pub interface: Option<String>,
    pub gateway: Option<String>,
}

/// This never resolves a saved host, probes a remote Mac, or populates ARP/NDP.
/// A fingerprint requires a physical-interface route AND a cached router MAC.
/// Common gateway IPs alone must never cause a hotel network to match home.
/// Total subprocess budget is two seconds; no Wi-Fi location permission.
pub fn local_network() -> LocalNetwork {
    #[cfg(target_os = "macos")]
    {
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut last =
            unavailable("No physical default route with a cached router address is available.");
        // The ordinary physical default is authoritative when present. IPv6 is
        // a fallback for IPv6-only networks and an uncached IPv4 gateway.
        for family in ["-inet", "-inet6"] {
            let route = route_command(&["-n", "get", family, "default"], deadline);
            if is_physical(route.interface.as_deref()) {
                let network = inspect_local_route(&route, deadline);
                if network.fingerprint.is_some() {
                    return network;
                }
                last = network;
            }
        }
        // Full-tunnel VPN defaults may hide the physical default. The kernel's
        // scoped default for an active en* interface still describes the local
        // router. Never use the utun/ppp gateway as the home identity.
        let Ok(nwi) = bounded_command("/usr/sbin/scutil", &["--nwi"], remaining(deadline)) else {
            return last;
        };
        let interfaces = physical_interfaces(&nwi);
        if interfaces.len() > 1 {
            return unavailable(
                "Multiple physical networks are active; disconnect one before marking Home.",
            );
        }
        let mut found: Option<LocalNetwork> = None;
        for interface in interfaces.iter().take(4) {
            for family in ["-inet", "-inet6"] {
                if Instant::now() >= deadline {
                    return unavailable(
                        "Local network inspection timed out; try again when the connection settles.",
                    );
                }
                let route = route_command(
                    &["-n", "get", family, "-ifscope", interface, "default"],
                    deadline,
                );
                if route.interface.as_deref() != Some(interface) {
                    continue;
                }
                let network = inspect_local_route(&route, deadline);
                if network.fingerprint.is_none() {
                    last = network;
                    continue;
                }
                if found.is_some() {
                    return unavailable(
                        "Multiple physical networks are active; disconnect one before marking Home.",
                    );
                }
                found = Some(network);
                break;
            }
        }
        found.unwrap_or(last)
    }
    #[cfg(not(target_os = "macos"))]
    {
        unavailable("Local network identification is available on macOS.")
    }
}

pub fn target_route(address: IpAddr) -> TargetRoute {
    #[cfg(target_os = "macos")]
    {
        let family = if address.is_ipv4() { "-inet" } else { "-inet6" };
        route_command(
            &["-n", "get", family, &address.to_string()],
            Instant::now() + Duration::from_secs(1),
        )
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = address;
        TargetRoute::default()
    }
}

fn unavailable(message: &str) -> LocalNetwork {
    LocalNetwork {
        description: message.into(),
        ..LocalNetwork::default()
    }
}

#[cfg(any(target_os = "macos", test))]
fn bounded_command(program: &str, args: &[&str], budget: Duration) -> Result<String, ()> {
    use std::io::Read;
    use std::process::{Command, Stdio};
    if budget.is_zero() {
        return Err(());
    }
    let deadline = Instant::now() + budget;
    let mut child = Command::new(program)
        .args(args)
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| ())?;
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => {
                // Only the fixed, small-output system commands below use this
                // helper. An output-filled pipe is killed by the same timeout.
                let mut bytes = Vec::new();
                child
                    .stdout
                    .take()
                    .ok_or(())?
                    .take(16_385)
                    .read_to_end(&mut bytes)
                    .map_err(|_| ())?;
                if bytes.len() > 16_384 {
                    return Err(());
                }
                return String::from_utf8(bytes).map_err(|_| ());
            }
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(5)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(());
            }
        }
    }
}

#[cfg(target_os = "macos")]
fn remaining(deadline: Instant) -> Duration {
    deadline
        .saturating_duration_since(Instant::now())
        .min(Duration::from_millis(400))
}

#[cfg(target_os = "macos")]
fn route_command(args: &[&str], deadline: Instant) -> TargetRoute {
    bounded_command("/sbin/route", args, remaining(deadline))
        .map(|text| parse_route(&text))
        .unwrap_or_default()
}

#[cfg(target_os = "macos")]
fn inspect_local_route(route: &TargetRoute, deadline: Instant) -> LocalNetwork {
    let Some(interface) = route
        .interface
        .as_deref()
        .filter(|name| is_physical(Some(name)))
    else {
        return unavailable(
            "A VPN or unknown interface cannot identify the physical home network.",
        );
    };
    let Some((address, gateway)) = route
        .gateway
        .as_deref()
        .and_then(|value| numeric_gateway(value, interface))
    else {
        return unavailable("The physical route does not expose a numeric router address.");
    };
    let output = if address.is_ipv4() {
        bounded_command(
            "/usr/sbin/arp",
            &["-n", "-i", interface, &gateway],
            remaining(deadline),
        )
    } else {
        bounded_command("/usr/sbin/ndp", &["-n", &gateway], remaining(deadline))
    };
    let mac = output
        .ok()
        .and_then(|text| cached_neighbor(&text, interface, address));
    format_local_network(interface, &gateway, mac.as_deref())
}

fn is_physical(interface: Option<&str>) -> bool {
    interface
        .and_then(|name| name.strip_prefix("en"))
        .is_some_and(|suffix| !suffix.is_empty() && suffix.bytes().all(|c| c.is_ascii_digit()))
}

fn numeric_gateway(value: &str, interface: &str) -> Option<(IpAddr, String)> {
    let (address, scope) = value
        .split_once('%')
        .map_or((value, None), |(ip, scope)| (ip, Some(scope)));
    let address: IpAddr = address.parse().ok()?;
    if address.is_unspecified() || address.is_loopback() || address.is_multicast() {
        return None;
    }
    if scope.is_some_and(|scope| !address.is_ipv6() || scope != interface) {
        return None;
    }
    let gateway = match address {
        IpAddr::V6(ip) if ip.is_unicast_link_local() => format!("{ip}%{interface}"),
        _ => address.to_string(),
    };
    Some((address, gateway))
}

fn normalize_mac(value: &str) -> Option<String> {
    let octets: Vec<_> = value.split(':').collect();
    if octets.len() != 6 {
        return None;
    }
    let mut bytes = [0u8; 6];
    for (index, octet) in octets.iter().enumerate() {
        if octet.is_empty() || octet.len() > 2 || !octet.bytes().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        bytes[index] = u8::from_str_radix(octet, 16).ok()?;
    }
    if bytes.iter().all(|byte| *byte == 0) || bytes[0] & 1 != 0 {
        return None;
    }
    Some(
        bytes
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<Vec<_>>()
            .join(":"),
    )
}

fn cached_neighbor(text: &str, interface: &str, address: IpAddr) -> Option<String> {
    for line in text.lines().take(16) {
        let fields: Vec<_> = line.split_whitespace().take(20).collect();
        if address.is_ipv4() {
            // arp: ? (192.0.2.1) at aa:bb:cc:dd:ee:ff on en0 ifscope
            if fields.len() >= 6
                && fields[2] == "at"
                && fields[4] == "on"
                && fields[5] == interface
                && fields[1].trim_matches(['(', ')']).parse::<IpAddr>().ok() == Some(address)
            {
                return normalize_mac(fields[3]);
            }
        } else if fields.len() >= 3
            && fields[2] == interface
            && numeric_gateway(fields[0], interface).map(|pair| pair.0) == Some(address)
        {
            // ndp: fe80::1%en0 aa:bb:cc:dd:ee:ff en0 23h59m S R
            return normalize_mac(fields[1]);
        }
    }
    None
}

fn format_local_network(interface: &str, gateway: &str, mac: Option<&str>) -> LocalNetwork {
    let mut network = LocalNetwork {
        interface: Some(interface.into()),
        gateway: Some(gateway.into()),
        ..LocalNetwork::default()
    };
    if !is_physical(Some(interface)) || numeric_gateway(gateway, interface).is_none() {
        network.description =
            "A physical interface and numeric router address are required.".into();
        return network;
    }
    match mac.and_then(normalize_mac) {
        Some(mac) => {
            network.fingerprint = Some(format!("v2|{interface}|{gateway}|{mac}"));
            network.description = format!("Local router identified on {interface}. Router bridges and VPNs can extend the same network.");
        }
        None => network.description = "The router is not in the local neighbor cache yet. Use this network normally, then check again; no remote Mac is required.".into(),
    }
    network
}

fn physical_interfaces(text: &str) -> Vec<String> {
    let mut interfaces = Vec::new();
    for line in text.lines().take(128) {
        // Read only scutil's active-interface inventory, not addresses or DNS.
        let Some(names) = line.trim().strip_prefix("Network interfaces:") else {
            continue;
        };
        for name in names.split_whitespace().take(16) {
            if is_physical(Some(name)) && !interfaces.iter().any(|item| item == name) {
                interfaces.push(name.into());
            }
        }
    }
    interfaces
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
                } else if is_physical(Some(value)) {
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
    #[test]
    fn v2_identity_requires_physical_interface_and_cached_mac() {
        assert_eq!(
            format_local_network("en0", "192.168.1.1", Some("2:3:4:5:6:7"))
                .fingerprint
                .as_deref(),
            Some("v2|en0|192.168.1.1|02:03:04:05:06:07")
        );
        assert_ne!(
            format_local_network("en0", "192.168.1.1", Some("02:03:04:05:06:07")).fingerprint,
            format_local_network("en0", "192.168.1.1", Some("02:03:04:05:06:08")).fingerprint
        );
        for interface in ["utun4", "ppp0", "bridge0", "lo0", "unknown"] {
            assert!(
                format_local_network(interface, "192.168.1.1", Some("02:03:04:05:06:07"))
                    .fingerprint
                    .is_none()
            );
        }
        for mac in [
            None,
            Some("(incomplete)"),
            Some("00:00:00:00:00:00"),
            Some("ff:ff:ff:ff:ff:ff"),
        ] {
            assert!(
                format_local_network("en0", "192.168.1.1", mac)
                    .fingerprint
                    .is_none()
            );
        }
    }
    #[test]
    fn ipv6_scopes_and_neighbor_cache_are_checked() {
        let address: IpAddr = "fe80::1".parse().unwrap();
        assert_eq!(numeric_gateway("fe80::1", "en0").unwrap().1, "fe80::1%en0");
        assert!(numeric_gateway("fe80::1%utun4", "en0").is_none());
        assert_eq!(
            cached_neighbor("fe80::1%en0 02:03:04:05:06:07 en0 12h S R", "en0", address).as_deref(),
            Some("02:03:04:05:06:07")
        );
        assert!(
            cached_neighbor("fe80::1%en0 02:03:04:05:06:07 en1 12h S R", "en0", address).is_none()
        );
        assert!(
            format_local_network("en0", "fe80::1%en0", Some("02:03:04:05:06:07"))
                .fingerprint
                .is_some()
        );
    }
    #[test]
    fn arp_entry_must_match_gateway_and_interface() {
        let ip = "192.168.1.1".parse().unwrap();
        let row = "? (192.168.1.1) at 2:3:4:5:6:7 on en0 ifscope [ethernet]";
        assert_eq!(
            cached_neighbor(row, "en0", ip).as_deref(),
            Some("02:03:04:05:06:07")
        );
        assert!(cached_neighbor(row, "en1", ip).is_none());
        assert!(cached_neighbor(row, "en0", "192.168.1.2".parse().unwrap()).is_none());
    }
    #[test]
    fn nwi_inventory_excludes_tunnels_and_unknown_interfaces() {
        assert_eq!(
            physical_interfaces("Network interfaces: utun4 en0 en1 bridge0 en0\n"),
            ["en0", "en1"]
        );
        assert!(physical_interfaces("en0 : flags : 0x5").is_empty());
    }
    #[test]
    fn subprocesses_time_out_and_report_errors() {
        let began = Instant::now();
        assert!(bounded_command("/bin/sleep", &["2"], Duration::from_millis(30)).is_err());
        assert!(began.elapsed() < Duration::from_secs(1));
        assert!(
            bounded_command("/missing/mooring-command", &[], Duration::from_millis(30)).is_err()
        );
        assert!(bounded_command("/bin/echo", &["ok"], Duration::ZERO).is_err());
        assert_eq!(
            bounded_command("/bin/echo", &["ok"], Duration::from_secs(1)).unwrap(),
            "ok\n"
        );
    }
}

//! This Mac's own network addresses, listed in its pairing codes after its
//! local name: so a viewer can still reach it where that name doesn't
//! resolve, by IP on the home network or over a VPN such as Tailscale.
//!
//! IPv4 only, from interfaces that are up and running: Ethernet and Wi-Fi
//! (`en*`) first, then tunnels (`utun*`), which is where VPNs live. Loopback,
//! link-local (169.254/16), and other interfaces such as virtual machines'
//! and Internet Sharing's bridges are left out.

use crate::pairing::MAX_ADDRESSES;
use serde::Serialize;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

/// One address of one interface, as `getifaddrs` reports it.
pub(crate) struct InterfaceAddress {
    pub name: String,
    pub address: IpAddr,
    pub up: bool,
    pub running: bool,
    pub loopback: bool,
}

/// The addresses worth listing, best first, at most seven.
pub(crate) fn ordered(interfaces: &[InterfaceAddress]) -> Vec<String> {
    let rank = |name: &str| {
        if name.starts_with("en") {
            Some(0)
        } else if name.starts_with("utun") {
            Some(1)
        } else {
            None
        }
    };
    let mut candidates: Vec<(usize, usize, Ipv4Addr)> = interfaces
        .iter()
        .enumerate()
        .filter(|(_, interface)| interface.up && interface.running && !interface.loopback)
        .filter_map(|(index, interface)| match interface.address {
            IpAddr::V4(address)
                if !address.is_loopback()
                    && !address.is_link_local()
                    && !address.is_unspecified()
                    && !address.is_multicast()
                    && !address.is_broadcast() =>
            {
                Some((rank(&interface.name)?, index, address))
            }
            _ => None,
        })
        .collect();
    candidates.sort_by_key(|(rank, index, _)| (*rank, *index));
    let mut listed: Vec<String> = Vec::new();
    for (_, _, address) in candidates {
        let text = address.to_string();
        if !listed.contains(&text) && listed.len() + 1 < MAX_ADDRESSES {
            listed.push(text);
        }
    }
    listed
}

/// This Mac's addresses now, best first. Empty if they can't be read.
fn interfaces() -> Vec<InterfaceAddress> {
    let mut interfaces = Vec::new();
    let mut list: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY: getifaddrs fills `list` on success; it is freed below.
    if unsafe { libc::getifaddrs(&mut list) } != 0 {
        return vec![];
    }
    let mut cursor = list;
    while !cursor.is_null() {
        // SAFETY: a non-null entry of the list getifaddrs returned.
        let entry = unsafe { &*cursor };
        cursor = entry.ifa_next;
        if entry.ifa_addr.is_null() || entry.ifa_name.is_null() {
            continue;
        }
        // SAFETY: ifa_addr is non-null and at least a sockaddr.
        let family = i32::from(unsafe { (*entry.ifa_addr).sa_family });
        let address = match family {
            libc::AF_INET => {
                // SAFETY: an AF_INET address is a sockaddr_in.
                let raw = unsafe {
                    (*entry.ifa_addr.cast::<libc::sockaddr_in>())
                        .sin_addr
                        .s_addr
                };
                IpAddr::V4(Ipv4Addr::from(u32::from_be(raw)))
            }
            libc::AF_INET6 => {
                // SAFETY: an AF_INET6 address is a sockaddr_in6.
                let raw = unsafe {
                    (*entry.ifa_addr.cast::<libc::sockaddr_in6>())
                        .sin6_addr
                        .s6_addr
                };
                IpAddr::V6(Ipv6Addr::from(raw))
            }
            _ => continue,
        };
        // SAFETY: ifa_name is a NUL-terminated interface name.
        let name = unsafe { std::ffi::CStr::from_ptr(entry.ifa_name) }
            .to_string_lossy()
            .into_owned();
        let flags = entry.ifa_flags;
        interfaces.push(InterfaceAddress {
            name,
            address,
            up: flags & libc::IFF_UP as u32 != 0,
            running: flags & libc::IFF_RUNNING as u32 != 0,
            loopback: flags & libc::IFF_LOOPBACK as u32 != 0,
        });
    }
    // SAFETY: the list getifaddrs returned, freed once.
    unsafe { libc::freeifaddrs(list) };
    interfaces
}

pub(crate) fn local_addresses() -> Vec<String> {
    ordered(&interfaces())
}

/// Labels describe address scope, not measured reachability or a VPN product.
pub(crate) fn description(address: &str) -> &'static str {
    match address.parse::<IpAddr>() {
        Ok(IpAddr::V4(ip)) if ip.is_loopback() => "IPv4 · this Mac only",
        Ok(IpAddr::V4(ip)) if ip.is_link_local() => "IPv4 · link-local",
        Ok(IpAddr::V4(ip)) if ip.is_private() => "IPv4 · private network",
        Ok(IpAddr::V4(ip)) if ip.octets()[0] == 100 && (64..=127).contains(&ip.octets()[1]) => {
            "IPv4 · shared address space"
        }
        Ok(IpAddr::V4(_)) => "IPv4",
        Ok(IpAddr::V6(ip)) if ip.is_loopback() => "IPv6 · this Mac only",
        Ok(IpAddr::V6(ip)) if ip.segments()[0] & 0xffc0 == 0xfe80 => "IPv6 · link-local",
        Ok(IpAddr::V6(ip)) if ip.segments()[0] & 0xfe00 == 0xfc00 => "IPv6 · private network",
        Ok(IpAddr::V6(_)) => "IPv6",
        Err(_) if address.ends_with(".local") => "Local hostname",
        Err(_) => "Hostname",
    }
}

#[derive(Serialize)]
pub(crate) struct NetworkAddress {
    pub interface: String,
    pub address: String,
    pub description: String,
    pub active: bool,
}

/// Presentation inventory, separate from the bounded IPv4 pairing candidates.
/// Include IPv6, link-local, loopback, bridges and inactive interfaces too.
pub(crate) fn network_info() -> Vec<NetworkAddress> {
    let mut entries = interfaces();
    entries.sort_by(|a, b| a.name.cmp(&b.name).then(a.address.cmp(&b.address)));
    entries.dedup_by(|a, b| a.name == b.name && a.address == b.address);
    entries
        .into_iter()
        .take(128)
        .map(|entry| {
            let description = description(&entry.address.to_string()).to_owned();
            let address = match entry.address {
                IpAddr::V6(ip) if ip.segments()[0] & 0xffc0 == 0xfe80 => {
                    format!("{ip}%{}", entry.name)
                }
                ip => ip.to_string(),
            };
            NetworkAddress {
                interface: entry.name,
                address,
                description,
                active: entry.up && entry.running,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn interface(name: &str, address: &str) -> InterfaceAddress {
        InterfaceAddress {
            name: name.into(),
            address: address.parse().unwrap(),
            up: true,
            running: true,
            loopback: name.starts_with("lo"),
        }
    }

    #[test]
    fn display_inventory_labels_scope_without_changing_connect_candidates() {
        for (address, expected) in [
            ("192.168.1.9", "IPv4 · private network"),
            ("100.64.1.9", "IPv4 · shared address space"),
            ("169.254.1.9", "IPv4 · link-local"),
            ("fe80::1", "IPv6 · link-local"),
            ("fd00::1", "IPv6 · private network"),
            ("::1", "IPv6 · this Mac only"),
            ("demo.local", "Local hostname"),
        ] {
            assert_eq!(description(address), expected);
        }
        let inventory = network_info();
        assert!(inventory.len() <= 128);
        for entry in inventory {
            assert!(!entry.interface.is_empty());
            assert!(
                entry
                    .address
                    .split('%')
                    .next()
                    .unwrap()
                    .parse::<IpAddr>()
                    .is_ok()
            );
        }
    }

    #[test]
    fn home_network_first_then_tunnels_never_loopback_or_link_local() {
        let mut down = interface("en1", "10.0.0.9");
        down.running = false;
        let interfaces = [
            interface("lo0", "127.0.0.1"),
            interface("utun4", "100.122.9.8"),
            interface("bridge0", "169.254.37.240"),
            interface("en0", "192.168.25.201"),
            interface("en0", "fe80::1"),
            interface("bridge100", "192.168.2.1"),
            interface("vmnet8", "172.16.1.1"),
            interface("en5", "169.254.1.2"),
            down,
            interface("utun6", "10.8.0.2"),
            interface("en7", "192.168.25.201"),
        ];
        assert_eq!(
            ordered(&interfaces),
            ["192.168.25.201", "100.122.9.8", "10.8.0.2"]
        );
    }

    #[test]
    fn at_most_seven_and_this_macs_own_list_is_valid() {
        let many: Vec<InterfaceAddress> = (1..=12)
            .map(|index| interface(&format!("en{index}"), &format!("10.0.0.{index}")))
            .collect();
        assert_eq!(ordered(&many).len(), MAX_ADDRESSES - 1);
        for address in local_addresses() {
            assert_eq!(
                crate::pairing::normalize_address(&address).as_deref(),
                Ok(address.as_str())
            );
        }
    }
}

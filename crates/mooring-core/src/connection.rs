//! Connection catalog language and endpoint validation, independent of persistence and OS APIs.
use serde::{Deserialize, Serialize};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
const MAX_TARGET_LENGTH: usize = 255;
const MAX_USER_LENGTH: usize = 64;
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

/// Validate an SSH destination: a `~/.ssh/config` host alias, a hostname or
/// IP address, optionally prefixed with `user@`. Ports, options, URLs and
/// spaces are refused; put those in `~/.ssh/config`.
pub fn validate_ssh_target(target: &str) -> Result<String, String> {
    const INVALID: &str = "Enter an SSH host alias or user@host only, without spaces, options, a port or a URL. Put the port and other settings in ~/.ssh/config.";
    if target.is_empty() || target.len() > MAX_TARGET_LENGTH || !target.is_ascii() {
        return Err(INVALID.into());
    }
    let (user, host) = match target.split_once('@') {
        Some((user, host)) => (Some(user), host),
        None => (None, target),
    };
    if let Some(user) = user {
        let first = user.as_bytes().first().copied().unwrap_or(b'-');
        if user.len() > MAX_USER_LENGTH
            || !(first.is_ascii_alphanumeric() || first == b'_')
            || !user
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
        {
            return Err(INVALID.into());
        }
    }
    if host.contains(':') {
        // Only a literal IPv6 address may contain a colon; never host:port.
        return host
            .parse::<Ipv6Addr>()
            .map(|_| target.to_owned())
            .map_err(|_| INVALID.into());
    }
    let first = host.as_bytes().first().copied().unwrap_or(b'-');
    if host.is_empty()
        || host.len() > 253
        || !first.is_ascii_alphanumeric()
        || host.contains("..")
        || !host
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
    {
        return Err(INVALID.into());
    }
    // Like validate_host: no abbreviated or octal IPv4 such as 127.1.
    if host.bytes().all(|b| b.is_ascii_digit() || b == b'.') && host.parse::<Ipv4Addr>().is_err() {
        return Err("Use a complete IPv4 address, for example 192.168.1.10.".into());
    }
    Ok(target.to_owned())
}

/// A saved VNC endpoint. With `ssh`, `host` and `port` are as seen from the
/// SSH host (usually 127.0.0.1:5900) and the viewer is pointed at a local
/// tunnel instead. The new fields are omitted when unset, so connections saved
/// before them are written back byte-for-byte unchanged.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Connection {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    #[serde(default, skip_serializing_if = "ServerKind::is_mac")]
    pub server: ServerKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh: Option<SshHop>,
}

/// The SSH destination: a `~/.ssh/config` alias or user@host. Keys, ports and
/// jump hosts stay in the user's SSH configuration; nothing secret is saved.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SshHop {
    pub target: String,
}

/// What `add` saves, before an ID is assigned.
pub struct NewConnection<'a> {
    pub name: &'a str,
    pub host: &'a str,
    pub port: u16,
    pub server: ServerKind,
    pub ssh_target: Option<&'a str>,
}

/// Port implemented by a catalog adapter. Native pairing credentials belong to
/// the pairing context and are intentionally absent from this catalog.
pub trait ConnectionRepository {
    fn list(&self) -> Result<Vec<Connection>, String>;
    fn get(&self, id: &str) -> Result<Connection, String>;
    fn add_connection(&self, new: NewConnection<'_>) -> Result<Connection, String>;
    fn remove(&self, id: &str) -> Result<(), String>;
}

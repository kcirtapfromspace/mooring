//! Connectivity policy. Reachability never establishes permission to view or
//! control a computer: the paired session or SSH still authenticates that.
use serde::{Deserialize, Serialize};

pub const MAX_TICKET_BYTES: usize = 8 * 1024;
pub const MAX_CONNECTIONS: usize = 4;
pub const MAX_PEERS: usize = 32;
pub const TICKET_LIFETIME_SECONDS: u64 = 600;
pub const MAX_IO_BYTES: usize = 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectivityMode {
    DirectOnly,
    Automatic,
    RelayOnly,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionPath {
    Direct,
    Relayed,
    Unknown,
}

/// Only these services may be carried. There is no arbitrary target host or
/// port supplied by an incoming peer, nor an IP-routing capability.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LinkService {
    NativeSession,
    Ssh,
}
impl LinkService {
    pub fn port(self) -> u16 {
        match self {
            Self::NativeSession => 45900,
            Self::Ssh => 22,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ConnectivityLimits {
    pub connect_ms: u64,
    pub stream_idle_ms: u64,
    pub session_ms: u64,
}
impl Default for ConnectivityLimits {
    fn default() -> Self {
        Self {
            connect_ms: 10_000,
            stream_idle_ms: 30_000,
            session_ms: 3_600_000,
        }
    }
}
impl ConnectivityLimits {
    pub fn validate(self) -> Result<Self, &'static str> {
        if !(100..=60_000).contains(&self.connect_ms)
            || !(100..=120_000).contains(&self.stream_idle_ms)
            || !(1_000..=86_400_000).contains(&self.session_ms)
        {
            return Err("Connectivity limits exceed the bounded policy");
        }
        Ok(self)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn limits_cannot_disable_deadlines() {
        assert!(ConnectivityLimits::default().validate().is_ok());
        assert!(
            ConnectivityLimits {
                connect_ms: 0,
                ..Default::default()
            }
            .validate()
            .is_err()
        );
        assert!(
            ConnectivityLimits {
                stream_idle_ms: u64::MAX,
                ..Default::default()
            }
            .validate()
            .is_err()
        );
        assert!(
            ConnectivityLimits {
                session_ms: 0,
                ..Default::default()
            }
            .validate()
            .is_err()
        );
    }
}

//! Policy prototypes for a future Mac remote desktop client.
//!
//! This crate does not capture, encode, transport, authenticate, or display video.
//! The quality scenarios contain simulated measurements, not benchmarks.

mod mailbox;
mod quality;
mod reconnect;

pub use mailbox::{LatestFrameMailbox, MailboxClosed, MailboxRead, MailboxStats};
pub use quality::{
    DecisionReason, NetworkSample, QualityController, QualityDecision, QualityLevel,
    QualityPreference, QualityProfile, ScenarioResult, ScenarioStep, TelemetryStatus,
    demo_scenarios,
};
pub use reconnect::{
    ReconnectConfig, ReconnectConfigError, ReconnectPolicy, RetryAttempt, RetrySchedule,
};

use serde::Serialize;

/// Network location is a performance hint, never evidence of peer identity.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum NetworkPath {
    LocalNetwork,
    Internet,
    Unknown,
}

/// An integration must derive `Paired` from verified, pinned device credentials.
/// This metadata type does not implement authentication or credential storage.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum PeerTrust {
    Unpaired,
    Paired { credential_id: String },
}

#[derive(Clone, Debug, Serialize)]
pub struct PeerContext {
    pub path: NetworkPath,
    pub trust: PeerTrust,
}

impl PeerContext {
    pub fn requires_pairing(&self) -> bool {
        matches!(self.trust, PeerTrust::Unpaired)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_network_is_not_trust() {
        let peer = PeerContext {
            path: NetworkPath::LocalNetwork,
            trust: PeerTrust::Unpaired,
        };
        assert!(peer.requires_pairing());
        let peer = PeerContext {
            path: NetworkPath::Internet,
            trust: PeerTrust::Paired {
                credential_id: "verified-device-key".into(),
            },
        };
        assert!(!peer.requires_pairing());
    }
}

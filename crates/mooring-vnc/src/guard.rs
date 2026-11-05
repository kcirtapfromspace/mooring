//! A budget for failed sign-ins, so Mooring never reaches a remote PAM
//! lockout (on the motivating host, three failures lock the account for ten
//! minutes). Pure policy: callers pass a monotonic clock in milliseconds.

use serde::Serialize;
use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct SignInLimits {
    /// Failures allowed within the window; the next attempt waits.
    pub max_failures: u32,
    pub window_ms: u64,
}

impl Default for SignInLimits {
    fn default() -> Self {
        Self {
            max_failures: 2,
            window_ms: 10 * 60 * 1000,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "decision", rename_all = "snake_case")]
pub enum SignInDecision {
    /// Try. `failures_so_far` recent failures; at most `remaining` more
    /// failures are allowed before Mooring waits.
    Allow {
        failures_so_far: u32,
        remaining: u32,
    },
    /// Too many recent failures: wait until `retry_after_ms` from now.
    Wait { retry_after_ms: u64 },
}

/// Failed sign-ins per host, kept in memory only.
#[derive(Debug, Default)]
pub struct SignInGuard {
    limits: SignInLimits,
    failures: BTreeMap<String, Vec<u64>>,
}

/// Hosts tracked at once; the oldest is forgotten beyond this.
const MAX_HOSTS: usize = 64;

impl SignInGuard {
    pub fn new(limits: SignInLimits) -> Self {
        Self {
            limits,
            failures: BTreeMap::new(),
        }
    }

    fn recent(&mut self, host: &str, now_ms: u64) -> &mut Vec<u64> {
        let window = self.limits.window_ms;
        let list = self.failures.entry(host.to_owned()).or_default();
        list.retain(|at| now_ms.saturating_sub(*at) < window);
        list
    }

    pub fn check(&mut self, host: &str, now_ms: u64) -> SignInDecision {
        let limits = self.limits;
        let recent = self.recent(host, now_ms);
        let count = recent.len() as u32;
        if count >= limits.max_failures {
            let oldest = recent.iter().copied().min().unwrap_or(now_ms);
            SignInDecision::Wait {
                retry_after_ms: (oldest + limits.window_ms).saturating_sub(now_ms).max(1),
            }
        } else {
            SignInDecision::Allow {
                failures_so_far: count,
                remaining: limits.max_failures - count,
            }
        }
    }

    /// The server rejected the username or password.
    pub fn failed(&mut self, host: &str, now_ms: u64) {
        self.recent(host, now_ms).push(now_ms);
        if self.failures.len() > MAX_HOSTS
            && let Some(oldest) = self
                .failures
                .iter()
                .min_by_key(|(_, list)| list.iter().max().copied().unwrap_or(0))
                .map(|(host, _)| host.clone())
        {
            self.failures.remove(&oldest);
        }
    }

    /// A successful sign-in clears the host's failures.
    pub fn succeeded(&mut self, host: &str) {
        self.failures.remove(host);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn two_failures_wait_out_the_window_and_success_resets() {
        let mut guard = SignInGuard::new(SignInLimits::default());
        let host = "m1-linux 127.0.0.1:5900";
        assert_eq!(
            guard.check(host, 0),
            SignInDecision::Allow {
                failures_so_far: 0,
                remaining: 2
            }
        );
        guard.failed(host, 1_000);
        assert_eq!(
            guard.check(host, 2_000),
            SignInDecision::Allow {
                failures_so_far: 1,
                remaining: 1
            }
        );
        guard.failed(host, 3_000);
        // A third try could lock the account: wait until the first ages out.
        assert_eq!(
            guard.check(host, 4_000),
            SignInDecision::Wait {
                retry_after_ms: 600_000 + 1_000 - 4_000
            }
        );
        assert!(matches!(
            guard.check(host, 601_000),
            SignInDecision::Allow {
                failures_so_far: 1,
                ..
            }
        ));
        // Other hosts are counted separately.
        assert!(matches!(
            guard.check("other", 4_000),
            SignInDecision::Allow {
                failures_so_far: 0,
                ..
            }
        ));
        guard.succeeded(host);
        assert!(matches!(
            guard.check(host, 4_000),
            SignInDecision::Allow {
                failures_so_far: 0,
                ..
            }
        ));
    }

    #[test]
    fn memory_is_bounded() {
        let mut guard = SignInGuard::new(SignInLimits::default());
        for i in 0..200 {
            guard.failed(&format!("host-{i}"), i);
        }
        assert!(guard.failures.len() <= MAX_HOSTS);
    }
}

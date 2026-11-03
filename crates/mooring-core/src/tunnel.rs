//! Lifecycle policy for a viewer that reaches a VNC server through SSH.
//!
//! This is a pure state machine: it starts no processes, opens no sockets and
//! reads no clock. Callers pass milliseconds from a monotonic clock and act on
//! the returned decisions. Every wait has a deadline and every retry a budget,
//! so a tunnel can never outlive its viewer by more than `idle_timeout_ms`.

use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct TunnelLimits {
    /// Attempts for the pre-flight RFB check, including the first one. Only
    /// transient failures (timeouts, resets) are retried.
    pub check_attempts: u32,
    /// Delay before the second check attempt; later attempts double it.
    pub check_retry_delay_ms: u64,
    /// The viewer must open its first connection within this time of `ready`.
    pub first_viewer_timeout_ms: u64,
    /// Keep listening this long after the last viewer connection closes, so a
    /// viewer that reconnects (for example after a sign-in prompt) still works.
    pub idle_timeout_ms: u64,
    pub max_concurrent_connections: u32,
    /// Lifetime cap on accepted viewer connections, so a looping client cannot
    /// start SSH sessions without limit.
    pub max_total_connections: u32,
    /// Close the tunnel after this many viewer connections in a row whose SSH
    /// leg failed on its own.
    pub max_consecutive_failures: u32,
}

impl Default for TunnelLimits {
    fn default() -> Self {
        Self {
            check_attempts: 2,
            check_retry_delay_ms: 1_000,
            first_viewer_timeout_ms: 120_000,
            idle_timeout_ms: 60_000,
            max_concurrent_connections: 4,
            max_total_connections: 64,
            max_consecutive_failures: 3,
        }
    }
}

/// Upper bounds for caller-supplied limits.
pub const MAX_CHECK_ATTEMPTS: u32 = 5;
pub const MAX_WAIT_MS: u64 = 60 * 60 * 1000;
pub const MAX_CONCURRENT_CONNECTIONS: u32 = 16;
pub const MAX_TOTAL_CONNECTIONS: u32 = 1_024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TunnelLimitsError {
    CheckAttempts,
    RetryDelay,
    FirstViewerTimeout,
    IdleTimeout,
    ConcurrentConnections,
    TotalConnections,
    ConsecutiveFailures,
}

impl TunnelLimits {
    pub fn validate(&self) -> Result<(), TunnelLimitsError> {
        use TunnelLimitsError as E;
        let wait = 1..=MAX_WAIT_MS;
        if !(1..=MAX_CHECK_ATTEMPTS).contains(&self.check_attempts) {
            return Err(E::CheckAttempts);
        }
        if self.check_retry_delay_ms > 60_000 {
            return Err(E::RetryDelay);
        }
        if !wait.contains(&self.first_viewer_timeout_ms) {
            return Err(E::FirstViewerTimeout);
        }
        if !wait.contains(&self.idle_timeout_ms) {
            return Err(E::IdleTimeout);
        }
        if !(1..=MAX_CONCURRENT_CONNECTIONS).contains(&self.max_concurrent_connections) {
            return Err(E::ConcurrentConnections);
        }
        if !(1..=MAX_TOTAL_CONNECTIONS).contains(&self.max_total_connections) {
            return Err(E::TotalConnections);
        }
        if !(1..=self.max_total_connections).contains(&self.max_consecutive_failures) {
            return Err(E::ConsecutiveFailures);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CloseReason {
    /// The pre-flight check failed permanently or exhausted its retries.
    CheckFailed,
    /// The viewer never connected after the tunnel became ready.
    NoViewer,
    /// The last viewer connection closed and none returned in time.
    SessionEnded,
    /// The user or the parent process asked to stop.
    Cancelled,
    /// Viewer connections kept failing on the SSH side.
    RepeatedFailures,
    /// The lifetime connection budget is spent and nothing is connected.
    ConnectionBudget,
    /// The tunnel was ready but the viewer could not be opened.
    ViewerLaunchFailed,
}

impl CloseReason {
    /// Whether this ending should be reported as an error.
    pub fn is_failure(&self) -> bool {
        matches!(
            self,
            Self::CheckFailed
                | Self::RepeatedFailures
                | Self::ConnectionBudget
                | Self::ViewerLaunchFailed
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "phase", rename_all = "snake_case")]
pub enum TunnelPhase {
    Checking {
        attempt: u32,
    },
    /// The check passed; waiting for the viewer's first connection.
    Ready,
    Active {
        connections: u32,
    },
    /// No viewer connection is open; the tunnel closes at the idle deadline.
    Idle,
    Closed {
        reason: CloseReason,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "decision", rename_all = "snake_case")]
pub enum CheckDecision {
    /// Run attempt `attempt` once `due_at_ms` is reached.
    Retry {
        attempt: u32,
        due_at_ms: u64,
    },
    Close {
        reason: CloseReason,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Admission {
    Accept,
    /// Too many connections are open; refuse this one, keep the tunnel.
    Busy,
    /// The lifetime budget is spent; refuse this one.
    BudgetSpent,
    /// The tunnel is not accepting viewers (checking or closed).
    NotReady,
}

pub struct TunnelLifecycle {
    limits: TunnelLimits,
    phase: TunnelPhase,
    deadline_ms: Option<u64>,
    open: u32,
    accepted: u32,
    consecutive_failures: u32,
    last_now_ms: u64,
}

impl TunnelLifecycle {
    pub fn new(limits: TunnelLimits, now_ms: u64) -> Result<Self, TunnelLimitsError> {
        limits.validate()?;
        Ok(Self {
            limits,
            phase: TunnelPhase::Checking { attempt: 1 },
            deadline_ms: None,
            open: 0,
            accepted: 0,
            consecutive_failures: 0,
            last_now_ms: now_ms,
        })
    }

    pub fn phase(&self) -> TunnelPhase {
        self.phase
    }

    pub fn limits(&self) -> TunnelLimits {
        self.limits
    }

    pub fn is_closed(&self) -> bool {
        matches!(self.phase, TunnelPhase::Closed { .. })
    }

    pub fn accepted_connections(&self) -> u32 {
        self.accepted
    }

    /// When the current wait expires, if one is running.
    pub fn deadline_ms(&self) -> Option<u64> {
        self.deadline_ms
    }

    fn clock(&mut self, now_ms: u64) -> u64 {
        // A regressing clock never extends or skips a deadline.
        self.last_now_ms = self.last_now_ms.max(now_ms);
        self.last_now_ms
    }

    fn close(&mut self, reason: CloseReason) -> CloseReason {
        if let TunnelPhase::Closed { reason } = self.phase {
            return reason;
        }
        self.phase = TunnelPhase::Closed { reason };
        self.deadline_ms = None;
        reason
    }

    /// The pre-flight check reached the VNC server through SSH.
    pub fn check_succeeded(&mut self, now_ms: u64) {
        let now = self.clock(now_ms);
        if matches!(self.phase, TunnelPhase::Checking { .. }) {
            self.phase = TunnelPhase::Ready;
            self.deadline_ms = Some(now.saturating_add(self.limits.first_viewer_timeout_ms));
        }
    }

    /// Permanent failures (authentication, unknown host, closed port) close at
    /// once; transient ones are retried within `check_attempts`.
    pub fn check_failed(&mut self, now_ms: u64, transient: bool) -> CheckDecision {
        let now = self.clock(now_ms);
        let TunnelPhase::Checking { attempt } = self.phase else {
            return CheckDecision::Close {
                reason: self.close(CloseReason::CheckFailed),
            };
        };
        if !transient || attempt >= self.limits.check_attempts {
            return CheckDecision::Close {
                reason: self.close(CloseReason::CheckFailed),
            };
        }
        let shift = (attempt - 1).min(16);
        let delay = self.limits.check_retry_delay_ms.saturating_mul(1 << shift);
        let next = attempt + 1;
        self.phase = TunnelPhase::Checking { attempt: next };
        CheckDecision::Retry {
            attempt: next,
            due_at_ms: now.saturating_add(delay),
        }
    }

    /// A viewer opened a TCP connection to the local listener.
    pub fn admit(&mut self, now_ms: u64) -> Admission {
        self.clock(now_ms);
        match self.phase {
            TunnelPhase::Ready | TunnelPhase::Idle | TunnelPhase::Active { .. } => {}
            _ => return Admission::NotReady,
        }
        if self.accepted >= self.limits.max_total_connections {
            return Admission::BudgetSpent;
        }
        if self.open >= self.limits.max_concurrent_connections {
            return Admission::Busy;
        }
        self.open += 1;
        self.accepted += 1;
        self.phase = TunnelPhase::Active {
            connections: self.open,
        };
        self.deadline_ms = None;
        Admission::Accept
    }

    /// An accepted connection ended. `failed` means its SSH leg exited with an
    /// error on its own, not because the viewer left or Mooring stopped it.
    pub fn connection_closed(&mut self, now_ms: u64, failed: bool) -> TunnelPhase {
        let now = self.clock(now_ms);
        if self.open == 0 || self.is_closed() {
            return self.phase;
        }
        self.open -= 1;
        if failed {
            self.consecutive_failures += 1;
        } else {
            self.consecutive_failures = 0;
        }
        if self.open > 0 {
            self.phase = TunnelPhase::Active {
                connections: self.open,
            };
            return self.phase;
        }
        if self.consecutive_failures >= self.limits.max_consecutive_failures {
            self.close(CloseReason::RepeatedFailures);
        } else if self.accepted >= self.limits.max_total_connections {
            self.close(CloseReason::ConnectionBudget);
        } else {
            self.phase = TunnelPhase::Idle;
            self.deadline_ms = Some(now.saturating_add(self.limits.idle_timeout_ms));
        }
        self.phase
    }

    /// The tunnel is ready but the viewer could not be started.
    pub fn viewer_launch_failed(&mut self) -> CloseReason {
        self.close(CloseReason::ViewerLaunchFailed)
    }

    /// Stop now. Open connections must be torn down by the caller.
    pub fn cancel(&mut self) -> CloseReason {
        self.close(CloseReason::Cancelled)
    }

    /// Apply deadlines. Returns the close reason once the tunnel has closed.
    pub fn poll(&mut self, now_ms: u64) -> Option<CloseReason> {
        let now = self.clock(now_ms);
        if let TunnelPhase::Closed { reason } = self.phase {
            return Some(reason);
        }
        let expired = self.deadline_ms.is_some_and(|deadline| now >= deadline);
        match self.phase {
            TunnelPhase::Ready if expired => Some(self.close(CloseReason::NoViewer)),
            TunnelPhase::Idle if expired => Some(self.close(CloseReason::SessionEnded)),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lifecycle() -> TunnelLifecycle {
        TunnelLifecycle::new(TunnelLimits::default(), 1_000).unwrap()
    }

    #[test]
    fn rejects_unbounded_or_empty_limits() {
        let base = TunnelLimits::default();
        assert!(base.validate().is_ok());
        for (limits, error) in [
            (
                TunnelLimits {
                    check_attempts: 0,
                    ..base
                },
                TunnelLimitsError::CheckAttempts,
            ),
            (
                TunnelLimits {
                    check_attempts: MAX_CHECK_ATTEMPTS + 1,
                    ..base
                },
                TunnelLimitsError::CheckAttempts,
            ),
            (
                TunnelLimits {
                    check_retry_delay_ms: 60_001,
                    ..base
                },
                TunnelLimitsError::RetryDelay,
            ),
            (
                TunnelLimits {
                    first_viewer_timeout_ms: 0,
                    ..base
                },
                TunnelLimitsError::FirstViewerTimeout,
            ),
            (
                TunnelLimits {
                    idle_timeout_ms: MAX_WAIT_MS + 1,
                    ..base
                },
                TunnelLimitsError::IdleTimeout,
            ),
            (
                TunnelLimits {
                    max_concurrent_connections: 0,
                    ..base
                },
                TunnelLimitsError::ConcurrentConnections,
            ),
            (
                TunnelLimits {
                    max_total_connections: MAX_TOTAL_CONNECTIONS + 1,
                    ..base
                },
                TunnelLimitsError::TotalConnections,
            ),
            (
                TunnelLimits {
                    max_consecutive_failures: 0,
                    ..base
                },
                TunnelLimitsError::ConsecutiveFailures,
            ),
        ] {
            assert_eq!(limits.validate(), Err(error));
            assert!(TunnelLifecycle::new(limits, 0).is_err());
        }
    }

    #[test]
    fn viewers_are_refused_until_the_check_passes() {
        let mut tunnel = lifecycle();
        assert_eq!(tunnel.phase(), TunnelPhase::Checking { attempt: 1 });
        assert_eq!(tunnel.admit(1_000), Admission::NotReady);
        // The check itself is bounded by the platform's per-attempt deadline.
        assert_eq!(tunnel.poll(10_000_000), None);
        tunnel.check_succeeded(10_000_000);
        assert_eq!(tunnel.phase(), TunnelPhase::Ready);
        assert_eq!(tunnel.deadline_ms(), Some(10_120_000));
        assert_eq!(tunnel.admit(10_000_001), Admission::Accept);
        assert_eq!(tunnel.phase(), TunnelPhase::Active { connections: 1 });
    }

    #[test]
    fn transient_check_failures_retry_with_backoff_then_close() {
        let limits = TunnelLimits {
            check_attempts: 3,
            ..TunnelLimits::default()
        };
        let mut tunnel = TunnelLifecycle::new(limits, 0).unwrap();
        assert_eq!(
            tunnel.check_failed(100, true),
            CheckDecision::Retry {
                attempt: 2,
                due_at_ms: 1_100
            }
        );
        assert_eq!(
            tunnel.check_failed(2_000, true),
            CheckDecision::Retry {
                attempt: 3,
                due_at_ms: 4_000
            }
        );
        assert_eq!(
            tunnel.check_failed(5_000, true),
            CheckDecision::Close {
                reason: CloseReason::CheckFailed
            }
        );
        assert_eq!(tunnel.poll(5_000), Some(CloseReason::CheckFailed));
        assert_eq!(tunnel.admit(5_000), Admission::NotReady);
    }

    #[test]
    fn permanent_check_failures_close_without_retrying() {
        let mut tunnel = lifecycle();
        assert_eq!(
            tunnel.check_failed(1_500, false),
            CheckDecision::Close {
                reason: CloseReason::CheckFailed
            }
        );
        assert!(tunnel.is_closed());
        // A late success cannot reopen a closed tunnel.
        tunnel.check_succeeded(1_600);
        assert!(tunnel.is_closed());
    }

    #[test]
    fn a_viewer_that_never_connects_closes_the_tunnel() {
        let mut tunnel = lifecycle();
        tunnel.check_succeeded(1_000);
        assert_eq!(tunnel.poll(120_999), None);
        assert_eq!(tunnel.poll(121_000), Some(CloseReason::NoViewer));
        assert_eq!(tunnel.admit(121_001), Admission::NotReady);
    }

    #[test]
    fn the_session_ends_after_the_last_connection_and_an_idle_grace() {
        let mut tunnel = lifecycle();
        tunnel.check_succeeded(1_000);
        assert_eq!(tunnel.admit(2_000), Admission::Accept);
        assert_eq!(tunnel.admit(2_100), Admission::Accept);
        // While connected there is no deadline, however long the session runs.
        assert_eq!(tunnel.poll(50_000_000), None);
        assert_eq!(
            tunnel.connection_closed(50_000_001, false),
            TunnelPhase::Active { connections: 1 }
        );
        assert_eq!(
            tunnel.connection_closed(50_000_002, false),
            TunnelPhase::Idle
        );
        assert_eq!(tunnel.deadline_ms(), Some(50_060_002));
        assert_eq!(tunnel.poll(50_060_001), None);
        assert_eq!(tunnel.poll(50_060_002), Some(CloseReason::SessionEnded));
    }

    #[test]
    fn a_reconnect_within_the_idle_grace_keeps_the_tunnel() {
        let mut tunnel = lifecycle();
        tunnel.check_succeeded(1_000);
        assert_eq!(tunnel.admit(2_000), Admission::Accept);
        tunnel.connection_closed(3_000, false);
        assert_eq!(tunnel.admit(30_000), Admission::Accept);
        assert_eq!(tunnel.deadline_ms(), None);
        assert_eq!(tunnel.poll(1_000_000), None);
    }

    #[test]
    fn concurrent_and_lifetime_connections_are_bounded() {
        let limits = TunnelLimits {
            max_concurrent_connections: 2,
            max_total_connections: 3,
            max_consecutive_failures: 3,
            ..TunnelLimits::default()
        };
        let mut tunnel = TunnelLifecycle::new(limits, 0).unwrap();
        tunnel.check_succeeded(0);
        assert_eq!(tunnel.admit(1), Admission::Accept);
        assert_eq!(tunnel.admit(2), Admission::Accept);
        assert_eq!(tunnel.admit(3), Admission::Busy);
        tunnel.connection_closed(4, false);
        assert_eq!(tunnel.admit(5), Admission::Accept);
        assert_eq!(tunnel.accepted_connections(), 3);
        tunnel.connection_closed(6, false);
        assert_eq!(tunnel.admit(7), Admission::BudgetSpent);
        assert_eq!(
            tunnel.connection_closed(8, false),
            TunnelPhase::Closed {
                reason: CloseReason::ConnectionBudget
            }
        );
    }

    #[test]
    fn repeated_ssh_failures_close_and_a_success_resets_the_count() {
        let mut tunnel = lifecycle();
        tunnel.check_succeeded(0);
        for now in [1, 2] {
            assert_eq!(tunnel.admit(now), Admission::Accept);
            assert_eq!(tunnel.connection_closed(now, true), TunnelPhase::Idle);
        }
        assert_eq!(tunnel.admit(3), Admission::Accept);
        assert_eq!(tunnel.connection_closed(3, false), TunnelPhase::Idle);
        for now in [4, 5] {
            assert_eq!(tunnel.admit(now), Admission::Accept);
            assert_eq!(tunnel.connection_closed(now, true), TunnelPhase::Idle);
        }
        assert_eq!(tunnel.admit(6), Admission::Accept);
        assert_eq!(
            tunnel.connection_closed(6, true),
            TunnelPhase::Closed {
                reason: CloseReason::RepeatedFailures
            }
        );
    }

    #[test]
    fn cancel_is_final_and_ignores_late_events() {
        let mut tunnel = lifecycle();
        tunnel.check_succeeded(0);
        assert_eq!(tunnel.admit(1), Admission::Accept);
        assert_eq!(tunnel.cancel(), CloseReason::Cancelled);
        assert_eq!(tunnel.admit(2), Admission::NotReady);
        assert_eq!(
            tunnel.connection_closed(3, true),
            TunnelPhase::Closed {
                reason: CloseReason::Cancelled
            }
        );
        // The first close reason is kept.
        assert_eq!(tunnel.cancel(), CloseReason::Cancelled);
        assert_eq!(tunnel.viewer_launch_failed(), CloseReason::Cancelled);
        assert!(!CloseReason::Cancelled.is_failure());
        assert!(!CloseReason::SessionEnded.is_failure());
        assert!(CloseReason::CheckFailed.is_failure());
        assert_eq!(tunnel.poll(u64::MAX), Some(CloseReason::Cancelled));
    }

    #[test]
    fn a_regressing_clock_never_moves_a_deadline() {
        let mut tunnel = lifecycle();
        tunnel.check_succeeded(10_000);
        assert_eq!(tunnel.deadline_ms(), Some(130_000));
        assert_eq!(tunnel.admit(5), Admission::Accept);
        tunnel.connection_closed(1, false);
        assert_eq!(tunnel.deadline_ms(), Some(70_000));
        assert_eq!(tunnel.poll(69_999), None);
        assert_eq!(tunnel.poll(70_000), Some(CloseReason::SessionEnded));
    }

    #[test]
    fn spurious_close_events_do_not_underflow() {
        let mut tunnel = lifecycle();
        tunnel.check_succeeded(0);
        assert_eq!(tunnel.connection_closed(1, true), TunnelPhase::Ready);
        assert_eq!(tunnel.admit(2), Admission::Accept);
        tunnel.connection_closed(3, false);
        assert_eq!(tunnel.connection_closed(4, true), TunnelPhase::Idle);
    }
}

use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct ReconnectConfig {
    pub initial_delay_ms: u64,
    pub maximum_delay_ms: u64,
    pub maximum_attempts: u32,
}

impl Default for ReconnectConfig {
    fn default() -> Self {
        Self {
            initial_delay_ms: 250,
            maximum_delay_ms: 8_000,
            maximum_attempts: 8,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReconnectConfigError {
    ZeroInitialDelay,
    CapBelowInitialDelay,
    ZeroAttempts,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct RetryAttempt {
    pub attempt: u32,
    pub due_at_ms: u64,
    pub delay_ms: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum RetrySchedule {
    Scheduled(RetryAttempt),
    Exhausted,
    Cancelled,
}

/// Bounded exponential retry scheduling, with deterministic injected jitter.
/// Times use a monotonic session clock. The PRNG spreads reconnect attempts; it
/// must never generate pairing secrets, credentials, or any cryptographic keys.
/// Call `schedule_after_failure` for connection failures, not authentication or
/// permission denials that require user action. This type makes no network calls.
pub struct ReconnectPolicy {
    config: ReconnectConfig,
    rng: u64,
    attempts: u32,
    pending: Option<RetryAttempt>,
    cancelled: bool,
    last_now_ms: u64,
}

impl ReconnectPolicy {
    pub fn new(seed: u64) -> Self {
        Self::with_config(ReconnectConfig::default(), seed)
            .expect("default retry settings are valid")
    }

    pub fn with_config(config: ReconnectConfig, seed: u64) -> Result<Self, ReconnectConfigError> {
        if config.initial_delay_ms == 0 {
            return Err(ReconnectConfigError::ZeroInitialDelay);
        }
        if config.maximum_delay_ms < config.initial_delay_ms {
            return Err(ReconnectConfigError::CapBelowInitialDelay);
        }
        if config.maximum_attempts == 0 {
            return Err(ReconnectConfigError::ZeroAttempts);
        }
        Ok(Self {
            config,
            rng: if seed == 0 {
                0x6a09_e667_f3bc_c909
            } else {
                seed
            },
            attempts: 0,
            pending: None,
            cancelled: false,
            last_now_ms: 0,
        })
    }

    /// Idempotent while an attempt is already scheduled. After `poll` returns an
    /// attempt, invoke this only after that attempt has actually failed.
    pub fn schedule_after_failure(&mut self, now_ms: u64) -> RetrySchedule {
        if self.cancelled {
            return RetrySchedule::Cancelled;
        }
        if let Some(attempt) = self.pending {
            return RetrySchedule::Scheduled(attempt);
        }
        if self.attempts >= self.config.maximum_attempts {
            return RetrySchedule::Exhausted;
        }
        let now_ms = now_ms.max(self.last_now_ms);
        self.last_now_ms = now_ms;
        let multiplier = 1_u64.checked_shl(self.attempts).unwrap_or(u64::MAX);
        let nominal = self
            .config
            .initial_delay_ms
            .saturating_mul(multiplier)
            .min(self.config.maximum_delay_ms);
        // Uniform integer jitter within +/- 20%, clipped so the actual delay
        // always respects the configured cap (including after randomization).
        let lower = nominal - nominal / 5;
        let upper = nominal
            .saturating_add(nominal / 5)
            .min(self.config.maximum_delay_ms);
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 7;
        self.rng ^= self.rng << 17;
        let width = u128::from(upper) - u128::from(lower) + 1;
        let delay_ms = lower + ((u128::from(self.rng) * width) >> 64) as u64;
        self.attempts += 1;
        let attempt = RetryAttempt {
            attempt: self.attempts,
            due_at_ms: now_ms.saturating_add(delay_ms),
            delay_ms,
        };
        self.pending = Some(attempt);
        RetrySchedule::Scheduled(attempt)
    }

    /// Consume one due attempt. Repeated polling cannot dispatch it twice.
    /// Regressing clock readings are ignored rather than triggering an attempt.
    pub fn poll(&mut self, now_ms: u64) -> Option<RetryAttempt> {
        if self.cancelled || now_ms < self.last_now_ms {
            return None;
        }
        self.last_now_ms = now_ms;
        if self
            .pending
            .is_some_and(|attempt| now_ms >= attempt.due_at_ms)
        {
            self.pending.take()
        } else {
            None
        }
    }

    /// A successful connection resets the budget, unless the user has cancelled
    /// this session. Late network callbacks cannot undo an explicit disconnect.
    pub fn reset_after_success(&mut self) {
        if !self.cancelled {
            self.attempts = 0;
            self.pending = None;
        }
    }

    pub fn cancel_by_user(&mut self) {
        self.cancelled = true;
        self.pending = None;
    }

    /// Only a new, explicit Connect action may reopen a cancelled session.
    pub fn start_new_session(&mut self) {
        self.cancelled = false;
        self.pending = None;
        self.attempts = 0;
        self.last_now_ms = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attempts_are_bounded_and_jitter_never_exceeds_delay_cap() {
        for seed in [0, 1, 9, 123456789, u64::MAX] {
            let mut policy = ReconnectPolicy::new(seed);
            let mut now = 0;
            for expected in 1..=8 {
                let RetrySchedule::Scheduled(attempt) = policy.schedule_after_failure(now) else {
                    panic!("expected retry")
                };
                assert_eq!(attempt.attempt, expected);
                assert!(attempt.delay_ms > 0 && attempt.delay_ms <= 8000);
                assert_eq!(policy.poll(attempt.due_at_ms - 1), None);
                assert_eq!(policy.poll(attempt.due_at_ms), Some(attempt));
                assert_eq!(policy.poll(attempt.due_at_ms), None);
                now = attempt.due_at_ms;
            }
            assert_eq!(policy.schedule_after_failure(now), RetrySchedule::Exhausted);
        }
    }

    #[test]
    fn identical_seeds_reproduce_the_schedule_and_different_seeds_spread_it() {
        fn schedule(seed: u64) -> Vec<RetryAttempt> {
            let mut policy = ReconnectPolicy::new(seed);
            let mut attempts = Vec::new();
            let mut now = 0;
            while let RetrySchedule::Scheduled(attempt) = policy.schedule_after_failure(now) {
                policy.poll(attempt.due_at_ms);
                now = attempt.due_at_ms;
                attempts.push(attempt);
            }
            attempts
        }
        assert_eq!(schedule(21), schedule(21));
        assert_ne!(schedule(21), schedule(999));
    }

    #[test]
    fn explicit_disconnect_cannot_be_undone_by_late_network_callbacks() {
        let mut policy = ReconnectPolicy::new(7);
        policy.schedule_after_failure(0);
        policy.cancel_by_user();
        policy.reset_after_success();
        assert_eq!(policy.poll(10000), None);
        assert_eq!(
            policy.schedule_after_failure(10000),
            RetrySchedule::Cancelled
        );
        policy.start_new_session();
        assert!(matches!(
            policy.schedule_after_failure(0),
            RetrySchedule::Scheduled(RetryAttempt { attempt: 1, .. })
        ));
    }

    #[test]
    fn duplicate_failure_callbacks_do_not_spend_retry_budget() {
        let mut policy = ReconnectPolicy::new(7);
        let first = policy.schedule_after_failure(0);
        assert_eq!(policy.schedule_after_failure(10), first);
        policy.reset_after_success();
        assert!(matches!(
            policy.schedule_after_failure(20),
            RetrySchedule::Scheduled(RetryAttempt { attempt: 1, .. })
        ));
    }

    #[test]
    fn rollback_does_not_fire_a_retry_or_move_its_deadline() {
        let mut policy = ReconnectPolicy::new(7);
        let RetrySchedule::Scheduled(attempt) = policy.schedule_after_failure(1000) else {
            panic!("expected retry")
        };
        assert_eq!(policy.poll(900), None);
        assert_eq!(
            policy.schedule_after_failure(800),
            RetrySchedule::Scheduled(attempt)
        );
        assert_eq!(policy.poll(attempt.due_at_ms), Some(attempt));
    }

    #[test]
    fn configuration_errors_and_extreme_delay_do_not_panic() {
        assert!(matches!(
            ReconnectPolicy::with_config(
                ReconnectConfig {
                    initial_delay_ms: 0,
                    ..Default::default()
                },
                0
            ),
            Err(ReconnectConfigError::ZeroInitialDelay)
        ));
        assert!(matches!(
            ReconnectPolicy::with_config(
                ReconnectConfig {
                    maximum_delay_ms: 1,
                    ..Default::default()
                },
                0
            ),
            Err(ReconnectConfigError::CapBelowInitialDelay)
        ));
        assert!(matches!(
            ReconnectPolicy::with_config(
                ReconnectConfig {
                    maximum_attempts: 0,
                    ..Default::default()
                },
                0
            ),
            Err(ReconnectConfigError::ZeroAttempts)
        ));
        let mut policy = ReconnectPolicy::with_config(
            ReconnectConfig {
                initial_delay_ms: u64::MAX,
                maximum_delay_ms: u64::MAX,
                maximum_attempts: 2,
            },
            1,
        )
        .unwrap();
        assert!(matches!(
            policy.schedule_after_failure(1),
            RetrySchedule::Scheduled(_)
        ));
    }
}

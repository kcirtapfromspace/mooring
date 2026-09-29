use serde::Serialize;

const SAMPLE_MAX_AGE_MS: u64 = 1_500;
const TELEMETRY_GRACE_MS: u64 = 2_500;
const UPGRADE_SAMPLES: u32 = 5;
const UPGRADE_DWELL_MS: u64 = 2_000;
const CHANGE_COOLDOWN_MS: u64 = 3_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum QualityPreference {
    Auto,
    Sharpest,
    Fastest,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum QualityLevel {
    Survival,
    Balanced,
    Native,
}

impl QualityLevel {
    fn next(self) -> Self {
        match self {
            Self::Survival => Self::Balanced,
            Self::Balanced | Self::Native => Self::Native,
        }
    }
}

/// All times use one monotonic, session-relative millisecond clock, not wall time.
/// `available_mbps` is an estimated sustainable video budget, not a Wi-Fi link rate.
#[derive(Clone, Copy, Debug, Serialize)]
pub struct NetworkSample {
    pub observed_at_ms: u64,
    pub rtt_ms: f64,
    pub jitter_ms: f64,
    pub loss_pct: f64,
    pub encoder_queue_ms: f64,
    pub available_mbps: f64,
}

impl NetworkSample {
    fn valid(self) -> bool {
        [
            self.rtt_ms,
            self.jitter_ms,
            self.loss_pct,
            self.encoder_queue_ms,
            self.available_mbps,
        ]
        .iter()
        .all(|v| v.is_finite() && *v >= 0.0)
            && self.loss_pct <= 100.0
            && self.available_mbps > 0.0
    }

    fn supported_level(self, preference: QualityPreference) -> QualityLevel {
        let strict = preference == QualityPreference::Fastest;
        let (native_rtt, native_jitter, native_loss, native_queue) = if strict {
            (14.0, 2.0, 0.2, 5.0)
        } else {
            (18.0, 3.0, 0.3, 8.0)
        };
        let (balanced_rtt, balanced_jitter, balanced_loss, balanced_queue) = if strict {
            (45.0, 8.0, 1.0, 12.0)
        } else {
            (60.0, 12.0, 1.5, 20.0)
        };
        if self.rtt_ms <= native_rtt
            && self.jitter_ms <= native_jitter
            && self.loss_pct <= native_loss
            && self.encoder_queue_ms <= native_queue
            && self.available_mbps >= 60.0
        {
            QualityLevel::Native
        } else if self.rtt_ms <= balanced_rtt
            && self.jitter_ms <= balanced_jitter
            && self.loss_pct <= balanced_loss
            && self.encoder_queue_ms <= balanced_queue
            && self.available_mbps >= 20.0
        {
            QualityLevel::Balanced
        } else {
            QualityLevel::Survival
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TelemetryStatus {
    Fresh,
    Missing,
    Stale,
    Invalid,
    OutOfOrder,
    Future,
    ClockRegression,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DecisionReason {
    Holding,
    Downgraded,
    UpgradePending,
    Upgraded,
    TelemetryIgnored,
    TelemetryFallback,
    ClockRegression,
}

/// Requests to a future encoder; codec support and output quality are not proven.
#[derive(Clone, Debug, Serialize)]
pub struct QualityProfile {
    pub target_fps: u32,
    pub max_video_mbps: f64,
    /// Scale physical capture pixels only. Never resize the logical desktop.
    pub capture_scale: f64,
    /// A preference requiring hardware/codec capability negotiation, not a guarantee.
    pub prefer_chroma_444: bool,
    pub logical_desktop_unchanged: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct QualityDecision {
    pub level: QualityLevel,
    pub preference: QualityPreference,
    pub profile: QualityProfile,
    pub reason: DecisionReason,
    pub telemetry_status: TelemetryStatus,
    pub pending_upgrade_samples: u32,
}

struct UpgradeEvidence {
    since_ms: u64,
    samples: u32,
}

/// A deterministic initial policy, deliberately isolated from any networking code.
/// A caller must feed measurements produced by its transport, not LAN heuristics.
/// A severe fresh sample downgrades immediately; upgrades require five consecutive
/// fresh samples, two seconds of evidence, and three seconds since the last change.
pub struct QualityController {
    preference: QualityPreference,
    level: QualityLevel,
    started_at_ms: u64,
    last_now_ms: u64,
    last_sample_at_ms: Option<u64>,
    last_available_mbps: Option<f64>,
    last_change_at_ms: u64,
    upgrade: Option<UpgradeEvidence>,
}

impl QualityController {
    pub fn new(preference: QualityPreference, now_ms: u64) -> Self {
        Self {
            preference,
            level: QualityLevel::Balanced,
            started_at_ms: now_ms,
            last_now_ms: now_ms,
            last_sample_at_ms: None,
            last_available_mbps: None,
            last_change_at_ms: now_ms,
            upgrade: None,
        }
    }

    pub fn set_preference(&mut self, preference: QualityPreference) {
        self.preference = preference;
        self.upgrade = None;
    }

    pub fn observe(&mut self, now_ms: u64, sample: Option<NetworkSample>) -> QualityDecision {
        if now_ms < self.last_now_ms {
            return self.decision(
                DecisionReason::ClockRegression,
                TelemetryStatus::ClockRegression,
            );
        }
        self.last_now_ms = now_ms;
        let status = match sample {
            None => TelemetryStatus::Missing,
            Some(s) if !s.valid() => TelemetryStatus::Invalid,
            Some(s) if s.observed_at_ms > now_ms => TelemetryStatus::Future,
            Some(s) if now_ms - s.observed_at_ms > SAMPLE_MAX_AGE_MS => TelemetryStatus::Stale,
            Some(s)
                if self
                    .last_sample_at_ms
                    .is_some_and(|last| s.observed_at_ms <= last) =>
            {
                TelemetryStatus::OutOfOrder
            }
            Some(_) => TelemetryStatus::Fresh,
        };
        if status != TelemetryStatus::Fresh {
            self.upgrade = None;
            let last_valid = self.last_sample_at_ms.unwrap_or(self.started_at_ms);
            let reason = if now_ms.saturating_sub(last_valid) >= TELEMETRY_GRACE_MS {
                if self.level != QualityLevel::Survival {
                    self.last_change_at_ms = now_ms;
                }
                self.level = QualityLevel::Survival;
                // Unknown network health must not restore a previous high bitrate.
                self.last_available_mbps = Some(self.last_available_mbps.unwrap_or(4.0).min(4.0));
                DecisionReason::TelemetryFallback
            } else {
                DecisionReason::TelemetryIgnored
            };
            return self.decision(reason, status);
        }
        let sample = sample.expect("fresh telemetry always contains a sample");
        // A large gap in arrivals cannot be counted as continuous good evidence.
        if self
            .last_sample_at_ms
            .is_some_and(|last| sample.observed_at_ms - last > SAMPLE_MAX_AGE_MS)
        {
            self.upgrade = None;
        }
        self.last_sample_at_ms = Some(sample.observed_at_ms);
        self.last_available_mbps = Some(sample.available_mbps);
        let candidate = sample.supported_level(self.preference);
        let reason = if candidate < self.level {
            self.level = candidate;
            self.last_change_at_ms = now_ms;
            self.upgrade = None;
            DecisionReason::Downgraded
        } else if candidate == self.level {
            self.upgrade = None;
            DecisionReason::Holding
        } else {
            let evidence = self.upgrade.get_or_insert(UpgradeEvidence {
                since_ms: sample.observed_at_ms,
                samples: 0,
            });
            evidence.samples = evidence.samples.saturating_add(1);
            if evidence.samples >= UPGRADE_SAMPLES
                && sample.observed_at_ms - evidence.since_ms >= UPGRADE_DWELL_MS
                && now_ms - self.last_change_at_ms >= CHANGE_COOLDOWN_MS
            {
                self.level = self.level.next();
                self.last_change_at_ms = now_ms;
                self.upgrade = None;
                DecisionReason::Upgraded
            } else {
                DecisionReason::UpgradePending
            }
        };
        self.decision(reason, status)
    }

    fn decision(&self, reason: DecisionReason, status: TelemetryStatus) -> QualityDecision {
        let (base_fps, bitrate, base_scale) = match self.level {
            QualityLevel::Survival => (30, 6.0_f64, 0.5),
            QualityLevel::Balanced => (45, 16.0_f64, 0.75),
            QualityLevel::Native => (60, 45.0_f64, 1.0),
        };
        let (target_fps, capture_scale) = match self.preference {
            QualityPreference::Auto => (base_fps, base_scale),
            QualityPreference::Sharpest => (
                match self.level {
                    QualityLevel::Survival => 20,
                    QualityLevel::Balanced => 30,
                    QualityLevel::Native => 60,
                },
                1.0,
            ),
            QualityPreference::Fastest => (
                if self.level == QualityLevel::Survival {
                    30
                } else {
                    60
                },
                base_scale,
            ),
        };
        QualityDecision {
            level: self.level,
            preference: self.preference,
            reason,
            telemetry_status: status,
            pending_upgrade_samples: self.upgrade.as_ref().map_or(0, |e| e.samples),
            profile: QualityProfile {
                target_fps,
                max_video_mbps: bitrate.min(self.last_available_mbps.unwrap_or(24.0) * 0.7),
                capture_scale,
                prefer_chroma_444: self.preference != QualityPreference::Fastest,
                logical_desktop_unchanged: true,
            },
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct ScenarioStep {
    pub at_ms: u64,
    pub telemetry: Option<NetworkSample>,
    pub decision: QualityDecision,
}

#[derive(Clone, Debug, Serialize)]
pub struct ScenarioResult {
    pub id: &'static str,
    pub name: &'static str,
    pub description: &'static str,
    pub simulated: bool,
    pub steps: Vec<ScenarioStep>,
}

fn healthy(at_ms: u64) -> NetworkSample {
    NetworkSample {
        observed_at_ms: at_ms,
        rtt_ms: 5.0,
        jitter_ms: 0.8,
        loss_pct: 0.05,
        encoder_queue_ms: 2.0,
        available_mbps: 120.0,
    }
}
fn adverse(at_ms: u64) -> NetworkSample {
    NetworkSample {
        observed_at_ms: at_ms,
        rtt_ms: 95.0,
        jitter_ms: 22.0,
        loss_pct: 4.0,
        encoder_queue_ms: 45.0,
        available_mbps: 8.0,
    }
}
fn scenario(
    id: &'static str,
    name: &'static str,
    description: &'static str,
    samples: impl IntoIterator<Item = (u64, Option<NetworkSample>)>,
) -> ScenarioResult {
    let mut controller = QualityController::new(QualityPreference::Auto, 0);
    ScenarioResult {
        id,
        name,
        description,
        simulated: true,
        steps: samples
            .into_iter()
            .map(|(at_ms, telemetry)| ScenarioStep {
                at_ms,
                telemetry,
                decision: controller.observe(at_ms, telemetry),
            })
            .collect(),
    }
}

/// Reproducible policy demonstrations only; none of these values were measured.
pub fn demo_scenarios() -> Vec<ScenarioResult> {
    let lan = (0..=6).map(|n| (n * 500, Some(healthy(n * 500))));
    let congestion = (0..=9).map(|n| {
        let t = n * 500;
        (t, Some(if n < 7 { healthy(t) } else { adverse(t) }))
    });
    let recovering = (0..=16).map(|n| {
        let t = n * 500;
        (t, Some(if n < 2 { adverse(t) } else { healthy(t) }))
    });
    let jittery = (0..=12).map(|n| {
        let t = n * 500;
        let mut s = healthy(t);
        if n % 3 == 2 {
            s.jitter_ms = 8.0;
        }
        (t, Some(s))
    });
    let missing = (0..=13).map(|n| {
        let t = n * 500;
        (t, if n <= 6 { Some(healthy(t)) } else { None })
    });
    vec![
        scenario(
            "home_lan",
            "Healthy home connection",
            "Sustained good telemetry gradually enables native capture at a requested 60 fps.",
            lan,
        ),
        scenario(
            "congestion",
            "Sudden Wi-Fi congestion",
            "Loss, latency, and encoder backlog reduce quality immediately without resizing the logical desktop.",
            congestion,
        ),
        scenario(
            "recovery",
            "Connection recovery",
            "Sustained recovery upgrades one level at a time after the cooldown.",
            recovering,
        ),
        scenario(
            "jitter",
            "Unstable connection",
            "Brief healthy bursts cannot repeatedly trigger upgrades.",
            jittery,
        ),
        scenario(
            "missing",
            "Telemetry disappears",
            "Hold briefly, then use conservative settings while network health is unknown.",
            missing,
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn promote(c: &mut QualityController) {
        for t in (0..=3000).step_by(500) {
            c.observe(t, Some(healthy(t)));
        }
    }

    #[test]
    fn healthy_connection_upgrades_only_after_dwell_and_cooldown() {
        let mut c = QualityController::new(QualityPreference::Auto, 0);
        for t in (0..3000).step_by(500) {
            assert_eq!(c.observe(t, Some(healthy(t))).level, QualityLevel::Balanced);
        }
        let result = c.observe(3000, Some(healthy(3000)));
        assert_eq!(result.level, QualityLevel::Native);
        assert_eq!(result.reason, DecisionReason::Upgraded);
        assert_eq!(result.profile.capture_scale, 1.0);
    }

    #[test]
    fn congestion_downgrades_immediately_then_recovers_one_level_at_a_time() {
        let mut c = QualityController::new(QualityPreference::Auto, 0);
        promote(&mut c);
        let result = c.observe(3500, Some(adverse(3500)));
        assert_eq!(result.level, QualityLevel::Survival);
        assert_eq!(result.reason, DecisionReason::Downgraded);
        assert!(result.profile.max_video_mbps <= 8.0 * 0.7);
        for t in (4000..6500).step_by(500) {
            assert_eq!(c.observe(t, Some(healthy(t))).level, QualityLevel::Survival);
        }
        assert_eq!(
            c.observe(6500, Some(healthy(6500))).level,
            QualityLevel::Balanced
        );
        for t in (7000..9500).step_by(500) {
            c.observe(t, Some(healthy(t)));
        }
        assert_eq!(
            c.observe(9500, Some(healthy(9500))).level,
            QualityLevel::Native
        );
    }

    #[test]
    fn jittery_good_bursts_do_not_upgrade() {
        let mut c = QualityController::new(QualityPreference::Auto, 0);
        for n in 0..100 {
            let t = n * 500;
            let mut sample = healthy(t);
            if n % 4 == 3 {
                sample.jitter_ms = 8.0;
            }
            assert_eq!(c.observe(t, Some(sample)).level, QualityLevel::Balanced);
        }
    }

    #[test]
    fn missing_telemetry_has_a_bounded_hold_and_conservative_fallback() {
        let mut c = QualityController::new(QualityPreference::Auto, 0);
        promote(&mut c);
        assert_eq!(c.observe(5000, None).level, QualityLevel::Native);
        let result = c.observe(5500, None);
        assert_eq!(result.level, QualityLevel::Survival);
        assert_eq!(result.reason, DecisionReason::TelemetryFallback);
        assert_eq!(result.telemetry_status, TelemetryStatus::Missing);
    }

    #[test]
    fn invalid_stale_future_and_duplicate_samples_never_count_as_evidence() {
        let mut c = QualityController::new(QualityPreference::Auto, 0);
        c.observe(0, Some(healthy(0)));
        let mut invalid = healthy(500);
        invalid.loss_pct = f64::NAN;
        assert_eq!(
            c.observe(500, Some(invalid)).telemetry_status,
            TelemetryStatus::Invalid
        );
        assert_eq!(
            c.observe(600, Some(healthy(700))).telemetry_status,
            TelemetryStatus::Future
        );
        assert_eq!(
            c.observe(700, Some(healthy(0))).telemetry_status,
            TelemetryStatus::OutOfOrder
        );
        let result = c.observe(2000, Some(healthy(0)));
        assert_eq!(result.telemetry_status, TelemetryStatus::Stale);
        assert_eq!(result.pending_upgrade_samples, 0);
        invalid = healthy(2500);
        invalid.available_mbps = f64::INFINITY;
        assert_eq!(
            c.observe(2500, Some(invalid)).reason,
            DecisionReason::TelemetryFallback
        );
    }

    #[test]
    fn bad_numeric_samples_are_rejected() {
        for value in [-1.0, f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let mut c = QualityController::new(QualityPreference::Auto, 0);
            let mut s = healthy(0);
            s.encoder_queue_ms = value;
            assert_eq!(
                c.observe(0, Some(s)).telemetry_status,
                TelemetryStatus::Invalid
            );
        }
        let mut s = healthy(0);
        s.loss_pct = 101.0;
        assert!(!s.valid());
        s = healthy(0);
        s.available_mbps = 0.0;
        assert!(!s.valid());
    }

    #[test]
    fn clock_regression_does_not_rewrite_session_history() {
        let mut c = QualityController::new(QualityPreference::Auto, 0);
        promote(&mut c);
        let result = c.observe(1000, Some(adverse(1000)));
        assert_eq!(result.telemetry_status, TelemetryStatus::ClockRegression);
        assert_eq!(result.level, QualityLevel::Native);
        assert_eq!(
            c.observe(3500, Some(healthy(3500))).level,
            QualityLevel::Native
        );
    }

    #[test]
    fn long_gaps_do_not_create_upgrade_evidence() {
        let mut c = QualityController::new(QualityPreference::Auto, 0);
        for t in [0, 5000, 10000, 15000, 20000, 25000] {
            let result = c.observe(t, Some(healthy(t)));
            assert_eq!(result.pending_upgrade_samples, 1);
            assert_eq!(result.level, QualityLevel::Balanced);
        }
    }

    #[test]
    fn preferences_keep_logical_desktop_stable_and_bandwidth_bounded() {
        for preference in [
            QualityPreference::Auto,
            QualityPreference::Sharpest,
            QualityPreference::Fastest,
        ] {
            let mut c = QualityController::new(preference, 0);
            let mut s = adverse(0);
            s.available_mbps = 0.1;
            let result = c.observe(0, Some(s));
            assert!(result.profile.logical_desktop_unchanged);
            assert!(result.profile.max_video_mbps <= 0.1 * 0.7);
            if preference == QualityPreference::Sharpest {
                assert_eq!(result.profile.capture_scale, 1.0);
            }
        }
    }

    #[test]
    fn demo_scenarios_are_explicitly_simulated() {
        let scenarios = demo_scenarios();
        assert_eq!(scenarios.len(), 5);
        assert!(scenarios.iter().all(|s| s.simulated && !s.steps.is_empty()));
    }
}

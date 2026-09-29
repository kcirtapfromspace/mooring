//! Conservative mode recommendations from target-specific TCP/RFB probes.
//!
//! These measurements establish target reachability and connection/greeting
//! timing only. They do not measure throughput, packet loss, video frame rate,
//! input latency, or Apple's High Performance transport. Callers must supply
//! real observations and keep separate state for each saved target.

use serde::{Deserialize, Serialize};

const MAX_PROBES: usize = 64;
const MAX_AGE_MS: u64 = 30_000;
const HEALTHY_SPAN_MS: u64 = 30_000;
const HEALTHY_SAMPLES: u32 = 8;
const UPGRADE_DWELL_MS: u64 = 30_000;
const BAD_SPAN_MS: u64 = 2_000;
const BAD_SAMPLES: u32 = 2;
const DOWNGRADE_DWELL_MS: u64 = 30_000;
const MAX_SWITCHES: u32 = 6;
const MAX_RETRIES: u32 = 6;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RemoteDesktopMode {
    Standard,
    HighPerformance,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NetworkTransport {
    Ethernet,
    Wifi,
    Cellular,
    Other,
    Unknown,
}

/// Describes the resolved target's route, not all VPN software on this Mac.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VpnStatus {
    Absent,
    Present,
    Unknown,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TransportContext {
    /// A baseline approved by the user or learned after an explicitly initiated,
    /// identified session and sustained healthy checks. Never derive this from
    /// a private IP, SSID, interface type, or Bonjour discovery alone.
    /// A travel router can reproduce a home SSID/address without being at home.
    pub trusted_home_baseline: bool,
    /// Explicit user approval to consider this known route, including a tunnel.
    /// This does not bypass missing telemetry or unknown target-route detection.
    pub allow_high_performance_override: bool,
    /// Supplied by actual host/client capability checks or explicit configuration;
    /// a successful RFB greeting does not establish High Performance support.
    pub high_performance_supported: bool,
    /// Permission to make an experimental request without claiming capability
    /// support. Trials require a familiar direct physical path and the same
    /// sustained evidence/dwell as confirmed support. Callers bound trial attempts
    /// and disable this after a failed request; exported mode is not negotiation.
    #[serde(default)]
    pub automatic_high_performance_trial: bool,
    pub transport: NetworkTransport,
    pub vpn: VpnStatus,
    /// Optional opaque current-route fingerprint. A change clears accumulated
    /// timing evidence. Equality is not authentication or proof of location.
    #[serde(default)]
    pub route_identity: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProbeStatus {
    RfbReady,
    ConnectFailed,
    GreetingFailed,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct TargetProbe {
    /// Monotonic session-relative/uptime milliseconds; never a wall-clock date.
    pub observed_at_ms: u64,
    pub status: ProbeStatus,
    /// TCP connection establishment duration to a resolved target address.
    /// This includes connection/host effects and is not a pure network RTT.
    pub tcp_connect_ms: Option<f64>,
    /// Elapsed time from connection completion to a complete valid RFB greeting.
    pub rfb_greeting_ms: Option<f64>,
}

impl TargetProbe {
    fn valid(self) -> bool {
        let values_valid = [self.tcp_connect_ms, self.rfb_greeting_ms]
            .into_iter()
            .flatten()
            .all(|value| value.is_finite() && value >= 0.0);
        values_valid
            && (self.status != ProbeStatus::RfbReady
                || (self.tcp_connect_ms.is_some() && self.rfb_greeting_ms.is_some()))
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NetworkEvaluationRequest {
    pub now_ms: u64,
    pub context: TransportContext,
    pub probes: Vec<TargetProbe>,
    pub state: Option<NetworkPolicyState>,
}

/// Persist the returned state unchanged and round-trip it in the next request.
/// Reset to `None` after an explicit new session, target change, or system reboot.
/// State is policy metadata, never an authorization credential. Field contents
/// are checked before reuse so malformed persisted state fails conservatively.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NetworkPolicyState {
    version: u32,
    mode: RemoteDesktopMode,
    last_evaluation_ms: u64,
    last_mode_change_ms: u64,
    last_probe_ms: Option<u64>,
    last_healthy_ms: Option<u64>,
    healthy_since_ms: Option<u64>,
    healthy_samples: u32,
    bad_since_ms: Option<u64>,
    bad_samples: u32,
    recent_connect_ms: Vec<f64>,
    last_context: Option<TransportContext>,
    target_ready: bool,
    retry_attempts: u32,
    retry_due_ms: Option<u64>,
    mode_switches: u32,
}

impl NetworkPolicyState {
    pub fn new(now_ms: u64) -> Self {
        Self {
            version: 1,
            mode: RemoteDesktopMode::Standard,
            last_evaluation_ms: now_ms,
            last_mode_change_ms: now_ms,
            last_probe_ms: None,
            last_healthy_ms: None,
            healthy_since_ms: None,
            healthy_samples: 0,
            bad_since_ms: None,
            bad_samples: 0,
            recent_connect_ms: Vec::new(),
            last_context: None,
            target_ready: false,
            retry_attempts: 0,
            retry_due_ms: None,
            mode_switches: 0,
        }
    }

    fn valid(&self) -> bool {
        self.version == 1
            && self.healthy_samples <= MAX_PROBES as u32
            && self.bad_samples <= MAX_PROBES as u32
            && self.retry_attempts <= MAX_RETRIES
            && self.mode_switches <= MAX_SWITCHES + 1
            && self.last_mode_change_ms <= self.last_evaluation_ms
            && self
                .last_probe_ms
                .is_none_or(|time| time <= self.last_evaluation_ms)
            && [
                self.last_healthy_ms,
                self.healthy_since_ms,
                self.bad_since_ms,
            ]
            .into_iter()
            .flatten()
            .all(|time| self.last_probe_ms.is_some_and(|last| time <= last))
            && self.recent_connect_ms.len() <= 4
            && self
                .recent_connect_ms
                .iter()
                .all(|value| value.is_finite() && *value >= 0.0)
            && ((self.healthy_samples == 0) == self.healthy_since_ms.is_none())
            && ((self.bad_samples == 0) == self.bad_since_ms.is_none())
    }

    fn clear_evidence(&mut self) {
        self.healthy_since_ms = None;
        self.healthy_samples = 0;
        self.bad_since_ms = None;
        self.bad_samples = 0;
        self.last_healthy_ms = None;
        self.recent_connect_ms.clear();
    }

    fn change_mode(&mut self, mode: RemoteDesktopMode, now_ms: u64) -> bool {
        if self.mode == mode {
            return false;
        }
        self.mode = mode;
        self.last_mode_change_ms = now_ms;
        self.mode_switches = self.mode_switches.saturating_add(1).min(MAX_SWITCHES + 1);
        true
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NetworkAction {
    KeepMode,
    SwitchMode,
    RetryLater,
    StopRetrying,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NetworkReason {
    AwaitingHealthyMeasurements,
    SustainedHealthyMeasurements,
    SustainedAdverseMeasurements,
    AwaitingFallbackDwell,
    TelemetryUnavailable,
    InvalidTelemetry,
    UnknownTargetRoute,
    RouteChanged,
    ExplicitApprovalRequired,
    TunnelOverrideRequired,
    HighPerformanceUnsupported,
    AutomaticTrialUnavailable,
    RetryBudgetExhausted,
    SwitchBudgetExhausted,
    ClockRegression,
    PersistedStateReset,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ProbeEvidence {
    pub accepted_samples: u32,
    pub successful_samples: u32,
    pub failed_samples: u32,
    pub ignored_samples: u32,
    pub tcp_connect_median_ms: Option<f64>,
    pub tcp_connect_p95_ms: Option<f64>,
    pub rfb_greeting_p95_ms: Option<f64>,
    /// Range of observed TCP connection timings; not packet-level jitter.
    pub tcp_connect_spread_ms: Option<f64>,
    pub consecutive_healthy_samples: u32,
    pub consecutive_bad_samples: u32,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NetworkEvaluation {
    pub recommended_mode: RemoteDesktopMode,
    /// Recommendations only: no app launching, switching, or probes happen here.
    pub action: NetworkAction,
    pub reason: NetworkReason,
    pub evidence: ProbeEvidence,
    /// Minimum wait before the next outage probe; Some(0) means it is due.
    /// A switch recommendation may also carry a retry wait.
    pub retry_after_ms: Option<u64>,
    pub retry_attempt: u32,
    pub mode_switches: u32,
    pub state: NetworkPolicyState,
}

fn eligibility(context: &TransportContext) -> Option<NetworkReason> {
    if !context.high_performance_supported {
        if !context.automatic_high_performance_trial {
            Some(NetworkReason::HighPerformanceUnsupported)
        } else if context.transport == NetworkTransport::Unknown
            || context.vpn == VpnStatus::Unknown
            || context
                .route_identity
                .as_ref()
                .is_none_or(|identity| identity.trim().is_empty())
        {
            Some(NetworkReason::UnknownTargetRoute)
        } else if context.vpn == VpnStatus::Present {
            // Trial permission is deliberately narrower than an override for
            // confirmed support. A fast tunnel is not a direct physical path.
            Some(NetworkReason::TunnelOverrideRequired)
        } else if !context.trusted_home_baseline {
            Some(NetworkReason::ExplicitApprovalRequired)
        } else if !matches!(
            context.transport,
            NetworkTransport::Wifi | NetworkTransport::Ethernet
        ) {
            Some(NetworkReason::AutomaticTrialUnavailable)
        } else {
            None
        }
    } else if context.transport == NetworkTransport::Unknown || context.vpn == VpnStatus::Unknown {
        Some(NetworkReason::UnknownTargetRoute)
    } else if context.vpn == VpnStatus::Present && !context.allow_high_performance_override {
        Some(NetworkReason::TunnelOverrideRequired)
    } else if !context.trusted_home_baseline && !context.allow_high_performance_override {
        Some(NetworkReason::ExplicitApprovalRequired)
    } else {
        None
    }
}

fn percentile(values: &mut [f64], percentage: usize) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    values.sort_by(f64::total_cmp);
    let index = (values.len() * percentage).div_ceil(100).saturating_sub(1);
    Some(values[index.min(values.len() - 1)])
}

fn finish(
    state: NetworkPolicyState,
    mut evidence: ProbeEvidence,
    reason: NetworkReason,
    switched: bool,
    now_ms: u64,
) -> NetworkEvaluation {
    evidence.consecutive_healthy_samples = state.healthy_samples;
    evidence.consecutive_bad_samples = state.bad_samples;
    let retry_after_ms = state.retry_due_ms.map(|due| due.saturating_sub(now_ms));
    let action = if switched {
        NetworkAction::SwitchMode
    } else if !state.target_ready
        && state.retry_attempts == MAX_RETRIES
        && state.retry_due_ms.is_none()
    {
        NetworkAction::StopRetrying
    } else if retry_after_ms.is_some() {
        NetworkAction::RetryLater
    } else {
        NetworkAction::KeepMode
    };
    NetworkEvaluation {
        recommended_mode: state.mode,
        action,
        reason,
        evidence,
        retry_after_ms,
        retry_attempt: state.retry_attempts,
        mode_switches: state.mode_switches,
        state,
    }
}

/// Evaluate up to 64 ordered target probes. Extra, duplicate, stale, and future
/// observations cannot accumulate promotion evidence. Healthy means <=20 ms TCP
/// setup and <=40 ms greeting, with <=12 ms spread over the last four connections.
/// These provisional thresholds screen routes; they cannot prove video quality.
///
/// Promotion needs eight healthy observations over thirty seconds plus thirty
/// seconds since the last mode change. Downgrade needs two adverse observations
/// spanning two seconds plus thirty seconds of dwell. Missing/invalid telemetry, unknown
/// routes, and lost eligibility force Standard immediately as a safety fallback.
/// After six changes in one policy session, further promotions are locked out.
/// Outage retries start at one second, double to eight seconds, and stop after
/// six retries; callers must stop automatic probing on `StopRetrying`.
pub fn evaluate_network(request: NetworkEvaluationRequest) -> NetworkEvaluation {
    let NetworkEvaluationRequest {
        now_ms,
        context,
        probes,
        state,
    } = request;
    let mut state = state.unwrap_or_else(|| NetworkPolicyState::new(now_ms));
    let mut evidence = ProbeEvidence::default();
    let mut reset = false;
    if !state.valid() {
        state = NetworkPolicyState::new(now_ms);
        reset = true;
    }
    if now_ms < state.last_evaluation_ms {
        state.clear_evidence();
        state.retry_due_ms = None;
        let last_time = state.last_evaluation_ms;
        let switched = state.change_mode(RemoteDesktopMode::Standard, last_time);
        return finish(
            state,
            evidence,
            NetworkReason::ClockRegression,
            switched,
            last_time,
        );
    }
    state.last_evaluation_ms = now_ms;
    let route_changed = state
        .last_context
        .as_ref()
        .is_some_and(|last| last != &context);
    if route_changed {
        state.clear_evidence();
        state.last_probe_ms = None;
        state.target_ready = false;
        // A new route is not a new user session; preserve exhausted retry/switch budgets.
        state.retry_due_ms = None;
    }
    state.last_context = Some(context.clone());
    let ineligible = eligibility(&context);
    let mut timings = Vec::new();
    let mut greetings = Vec::new();
    let mut invalid = false;
    let mut new_failure = false;
    evidence.ignored_samples = probes
        .len()
        .saturating_sub(MAX_PROBES)
        .min(u32::MAX as usize) as u32;
    for sample in probes.into_iter().take(MAX_PROBES) {
        if !sample.valid() || sample.observed_at_ms > now_ms {
            evidence.ignored_samples = evidence.ignored_samples.saturating_add(1);
            state.clear_evidence();
            invalid = true;
            continue;
        }
        if now_ms - sample.observed_at_ms > MAX_AGE_MS {
            evidence.ignored_samples = evidence.ignored_samples.saturating_add(1);
            continue;
        }
        if state
            .last_probe_ms
            .is_some_and(|last| sample.observed_at_ms <= last)
        {
            evidence.ignored_samples = evidence.ignored_samples.saturating_add(1);
            continue;
        }
        if state
            .last_probe_ms
            .is_some_and(|last| sample.observed_at_ms - last > MAX_AGE_MS)
        {
            state.clear_evidence();
        }
        state.last_probe_ms = Some(sample.observed_at_ms);
        evidence.accepted_samples += 1;
        let (healthy, bad) = if sample.status == ProbeStatus::RfbReady {
            evidence.successful_samples += 1;
            let tcp = sample.tcp_connect_ms.expect("validated ready sample");
            let greeting = sample.rfb_greeting_ms.expect("validated ready sample");
            timings.push(tcp);
            greetings.push(greeting);
            state.recent_connect_ms.push(tcp);
            if state.recent_connect_ms.len() > 4 {
                state.recent_connect_ms.remove(0);
            }
            let low = state
                .recent_connect_ms
                .iter()
                .copied()
                .fold(f64::INFINITY, f64::min);
            let high = state
                .recent_connect_ms
                .iter()
                .copied()
                .fold(0.0_f64, f64::max);
            state.target_ready = true;
            state.retry_attempts = 0;
            state.retry_due_ms = None;
            new_failure = false;
            (
                tcp <= 20.0 && greeting <= 40.0 && high - low <= 12.0,
                tcp >= 60.0 || greeting >= 120.0,
            )
        } else {
            evidence.failed_samples += 1;
            state.target_ready = false;
            state.recent_connect_ms.clear();
            new_failure = true;
            (false, true)
        };
        if healthy && ineligible.is_none() {
            state.last_healthy_ms = Some(sample.observed_at_ms);
            state.healthy_since_ms.get_or_insert(sample.observed_at_ms);
            state.healthy_samples = state
                .healthy_samples
                .saturating_add(1)
                .min(MAX_PROBES as u32);
            state.bad_since_ms = None;
            state.bad_samples = 0;
        } else {
            state.healthy_since_ms = None;
            state.healthy_samples = 0;
            if bad {
                state.bad_since_ms.get_or_insert(sample.observed_at_ms);
                state.bad_samples = state.bad_samples.saturating_add(1).min(MAX_PROBES as u32);
            } else {
                state.bad_since_ms = None;
                state.bad_samples = 0;
            }
        }
    }
    evidence.tcp_connect_median_ms = percentile(&mut timings, 50);
    evidence.tcp_connect_p95_ms = percentile(&mut timings, 95);
    evidence.rfb_greeting_p95_ms = percentile(&mut greetings, 95);
    evidence.tcp_connect_spread_ms = timings
        .first()
        .zip(timings.last())
        .map(|(low, high)| high - low);

    if new_failure && state.retry_due_ms.is_none_or(|due| due <= now_ms) {
        if state.retry_attempts < MAX_RETRIES {
            let delay = (1_000_u64 << state.retry_attempts).min(8_000);
            state.retry_attempts += 1;
            state.retry_due_ms = Some(now_ms.saturating_add(delay));
        } else {
            state.retry_due_ms = None;
        }
    }

    let telemetry_missing = state
        .last_probe_ms
        .is_none_or(|last| now_ms - last > MAX_AGE_MS);
    let mut recommended = state.mode;
    let mut reason = if let Some(reason) = ineligible {
        recommended = RemoteDesktopMode::Standard;
        state.clear_evidence();
        reason
    } else if route_changed {
        recommended = RemoteDesktopMode::Standard;
        NetworkReason::RouteChanged
    } else if invalid {
        recommended = RemoteDesktopMode::Standard;
        state.clear_evidence();
        NetworkReason::InvalidTelemetry
    } else if telemetry_missing {
        recommended = RemoteDesktopMode::Standard;
        state.clear_evidence();
        NetworkReason::TelemetryUnavailable
    } else if state.mode == RemoteDesktopMode::HighPerformance {
        let sustained_bad = state.bad_samples >= BAD_SAMPLES
            && state
                .bad_since_ms
                .zip(state.last_probe_ms)
                .is_some_and(|(start, last)| last - start >= BAD_SPAN_MS);
        if sustained_bad && now_ms - state.last_mode_change_ms >= DOWNGRADE_DWELL_MS {
            recommended = RemoteDesktopMode::Standard;
            NetworkReason::SustainedAdverseMeasurements
        } else if state
            .last_healthy_ms
            .is_none_or(|last| now_ms - last > MAX_AGE_MS)
        {
            recommended = RemoteDesktopMode::Standard;
            NetworkReason::TelemetryUnavailable
        } else if state.bad_samples > 0 {
            NetworkReason::AwaitingFallbackDwell
        } else if state.healthy_samples > 0 {
            NetworkReason::SustainedHealthyMeasurements
        } else {
            NetworkReason::AwaitingHealthyMeasurements
        }
    } else if state.mode_switches >= MAX_SWITCHES {
        NetworkReason::SwitchBudgetExhausted
    } else if state.healthy_samples >= HEALTHY_SAMPLES
        && state
            .healthy_since_ms
            .zip(state.last_probe_ms)
            .is_some_and(|(start, last)| last - start >= HEALTHY_SPAN_MS)
        && now_ms - state.last_mode_change_ms >= UPGRADE_DWELL_MS
    {
        recommended = RemoteDesktopMode::HighPerformance;
        NetworkReason::SustainedHealthyMeasurements
    } else {
        NetworkReason::AwaitingHealthyMeasurements
    };
    if reset {
        // Never promote based on malformed restored history.
        recommended = RemoteDesktopMode::Standard;
        reason = NetworkReason::PersistedStateReset;
    }
    let switched = state.change_mode(recommended, now_ms);
    if !switched
        && !state.target_ready
        && state.retry_attempts == MAX_RETRIES
        && state.retry_due_ms.is_none()
    {
        reason = NetworkReason::RetryBudgetExhausted;
    }
    finish(state, evidence, reason, switched, now_ms)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context() -> TransportContext {
        TransportContext {
            trusted_home_baseline: true,
            allow_high_performance_override: false,
            high_performance_supported: true,
            automatic_high_performance_trial: false,
            transport: NetworkTransport::Wifi,
            vpn: VpnStatus::Absent,
            route_identity: Some("explicitly-approved-target-route".into()),
        }
    }
    fn good(time: u64) -> TargetProbe {
        TargetProbe {
            observed_at_ms: time,
            status: ProbeStatus::RfbReady,
            tcp_connect_ms: Some(5.0),
            rfb_greeting_ms: Some(3.0),
        }
    }
    fn bad(time: u64) -> TargetProbe {
        TargetProbe {
            observed_at_ms: time,
            status: ProbeStatus::RfbReady,
            tcp_connect_ms: Some(90.0),
            rfb_greeting_ms: Some(150.0),
        }
    }
    fn failed(time: u64) -> TargetProbe {
        TargetProbe {
            observed_at_ms: time,
            status: ProbeStatus::ConnectFailed,
            tcp_connect_ms: None,
            rfb_greeting_ms: None,
        }
    }
    fn run(
        state: Option<NetworkPolicyState>,
        time: u64,
        probes: Vec<TargetProbe>,
        context: TransportContext,
    ) -> NetworkEvaluation {
        evaluate_network(NetworkEvaluationRequest {
            now_ms: time,
            context,
            probes,
            state,
        })
    }
    fn promote() -> NetworkEvaluation {
        let mut result = run(None, 0, vec![good(0)], context());
        for time in (3000..=30000).step_by(3000) {
            result = run(Some(result.state), time, vec![good(time)], context());
        }
        assert_eq!(result.recommended_mode, RemoteDesktopMode::HighPerformance);
        result
    }

    #[test]
    fn sustained_measurements_and_dwell_are_both_required_for_promotion() {
        let mut result = run(None, 0, vec![good(0)], context());
        for time in (3000..30000).step_by(3000) {
            result = run(Some(result.state), time, vec![good(time)], context());
            assert_eq!(result.recommended_mode, RemoteDesktopMode::Standard);
        }
        result = run(Some(result.state), 30000, vec![good(30000)], context());
        assert_eq!(result.action, NetworkAction::SwitchMode);
        assert_eq!(result.recommended_mode, RemoteDesktopMode::HighPerformance);
    }

    #[test]
    fn a_burst_of_fast_samples_cannot_substitute_for_sustained_evidence() {
        let probes = (0..64).map(|index| good(40000 + index)).collect();
        let result = run(Some(NetworkPolicyState::new(0)), 40064, probes, context());
        assert_eq!(result.recommended_mode, RemoteDesktopMode::Standard);
        assert_eq!(result.evidence.accepted_samples, 64);
    }

    #[test]
    fn two_bad_samples_and_thirty_second_dwell_prevent_reconnect_flapping() {
        let result = promote();
        let result = run(Some(result.state), 31000, vec![bad(31000)], context());
        assert_eq!(result.recommended_mode, RemoteDesktopMode::HighPerformance);
        let result = run(Some(result.state), 33000, vec![bad(33000)], context());
        assert_eq!(result.recommended_mode, RemoteDesktopMode::HighPerformance);
        assert_eq!(result.reason, NetworkReason::AwaitingFallbackDwell);
        let result = run(Some(result.state), 60000, vec![bad(60000)], context());
        assert_eq!(result.recommended_mode, RemoteDesktopMode::Standard);
        assert_eq!(result.reason, NetworkReason::SustainedAdverseMeasurements);
        assert_eq!(result.mode_switches, 2);
    }

    #[test]
    fn unapproved_fast_private_or_wifi_routes_never_imply_home() {
        let mut route = context();
        route.trusted_home_baseline = false;
        route.route_identity = Some("192.168.1.0-home-ssid-clone".into());
        let mut result = run(None, 0, vec![good(0)], route.clone());
        for time in (3000..=60000).step_by(3000) {
            result = run(Some(result.state), time, vec![good(time)], route.clone());
        }
        assert_eq!(result.recommended_mode, RemoteDesktopMode::Standard);
        assert_eq!(result.reason, NetworkReason::ExplicitApprovalRequired);
        assert_eq!(result.evidence.consecutive_healthy_samples, 0);
    }

    #[test]
    fn target_tunnel_needs_override_and_unknown_route_cannot_be_overridden() {
        let mut route = context();
        route.vpn = VpnStatus::Present;
        let result = run(None, 0, vec![good(0)], route.clone());
        assert_eq!(result.reason, NetworkReason::TunnelOverrideRequired);
        route.allow_high_performance_override = true;
        let mut result = run(None, 0, vec![good(0)], route.clone());
        for time in (3000..=30000).step_by(3000) {
            result = run(Some(result.state), time, vec![good(time)], route.clone());
        }
        assert_eq!(result.recommended_mode, RemoteDesktopMode::HighPerformance);
        route.vpn = VpnStatus::Unknown;
        let result = run(Some(result.state), 33000, vec![good(33000)], route);
        assert_eq!(result.recommended_mode, RemoteDesktopMode::Standard);
        assert_eq!(result.reason, NetworkReason::UnknownTargetRoute);
    }

    #[test]
    fn rfb_reachability_does_not_establish_high_performance_support() {
        let mut route = context();
        route.high_performance_supported = false;
        let result = run(Some(promote().state), 33000, vec![good(33000)], route);
        assert_eq!(result.recommended_mode, RemoteDesktopMode::Standard);
        assert_eq!(result.reason, NetworkReason::HighPerformanceUnsupported);
    }

    #[test]
    fn automatic_trial_requires_the_same_sustained_measurements_and_dwell() {
        for transport in [NetworkTransport::Wifi, NetworkTransport::Ethernet] {
            let mut route = context();
            route.high_performance_supported = false;
            route.automatic_high_performance_trial = true;
            route.transport = transport;
            let mut result = run(None, 0, vec![good(0)], route.clone());
            for time in (3000..30000).step_by(3000) {
                result = run(Some(result.state), time, vec![good(time)], route.clone());
                assert_eq!(result.recommended_mode, RemoteDesktopMode::Standard);
            }
            result = run(Some(result.state), 30000, vec![good(30000)], route);
            assert_eq!(result.recommended_mode, RemoteDesktopMode::HighPerformance);
            assert_eq!(result.reason, NetworkReason::SustainedHealthyMeasurements);
            assert!(
                !result
                    .state
                    .last_context
                    .unwrap()
                    .high_performance_supported
            );
        }
    }

    #[test]
    fn automatic_trial_never_overrides_tunnel_unknown_or_unfamiliar_paths() {
        let mut baseline = context();
        baseline.high_performance_supported = false;
        baseline.automatic_high_performance_trial = true;
        // This existing setting must not broaden unconfirmed trial eligibility.
        baseline.allow_high_performance_override = true;
        let cases = [
            (
                TransportContext {
                    vpn: VpnStatus::Present,
                    ..baseline.clone()
                },
                NetworkReason::TunnelOverrideRequired,
            ),
            (
                TransportContext {
                    vpn: VpnStatus::Unknown,
                    ..baseline.clone()
                },
                NetworkReason::UnknownTargetRoute,
            ),
            (
                TransportContext {
                    transport: NetworkTransport::Unknown,
                    ..baseline.clone()
                },
                NetworkReason::UnknownTargetRoute,
            ),
            (
                TransportContext {
                    transport: NetworkTransport::Cellular,
                    ..baseline.clone()
                },
                NetworkReason::AutomaticTrialUnavailable,
            ),
            (
                TransportContext {
                    transport: NetworkTransport::Other,
                    ..baseline.clone()
                },
                NetworkReason::AutomaticTrialUnavailable,
            ),
            (
                TransportContext {
                    trusted_home_baseline: false,
                    ..baseline.clone()
                },
                NetworkReason::ExplicitApprovalRequired,
            ),
            (
                TransportContext {
                    route_identity: None,
                    ..baseline.clone()
                },
                NetworkReason::UnknownTargetRoute,
            ),
            (
                TransportContext {
                    route_identity: Some("  ".into()),
                    ..baseline
                },
                NetworkReason::UnknownTargetRoute,
            ),
        ];
        for (route, reason) in cases {
            let mut result = run(None, 0, vec![good(0)], route.clone());
            for time in (3000..=60000).step_by(3000) {
                result = run(Some(result.state), time, vec![good(time)], route.clone());
            }
            assert_eq!(result.recommended_mode, RemoteDesktopMode::Standard);
            assert_eq!(result.reason, reason);
            assert_eq!(result.evidence.consecutive_healthy_samples, 0);
        }
    }

    #[test]
    fn disabling_automatic_trials_clears_an_unconfirmed_promotion() {
        let mut route = context();
        route.high_performance_supported = false;
        route.automatic_high_performance_trial = true;
        let mut result = run(None, 0, vec![good(0)], route.clone());
        for time in (3000..=30000).step_by(3000) {
            result = run(Some(result.state), time, vec![good(time)], route.clone());
        }
        assert_eq!(result.recommended_mode, RemoteDesktopMode::HighPerformance);
        route.automatic_high_performance_trial = false;
        let result = run(Some(result.state), 33000, vec![good(33000)], route);
        assert_eq!(result.recommended_mode, RemoteDesktopMode::Standard);
        assert_eq!(result.reason, NetworkReason::HighPerformanceUnsupported);
    }

    #[test]
    fn confirmed_support_retains_explicit_tunnel_override_behavior() {
        let mut route = context();
        route.automatic_high_performance_trial = true;
        route.vpn = VpnStatus::Present;
        route.transport = NetworkTransport::Other;
        route.trusted_home_baseline = false;
        route.allow_high_performance_override = true;
        let mut result = run(None, 0, vec![good(0)], route.clone());
        for time in (3000..=30000).step_by(3000) {
            result = run(Some(result.state), time, vec![good(time)], route.clone());
        }
        assert_eq!(result.recommended_mode, RemoteDesktopMode::HighPerformance);
    }

    #[test]
    fn missing_telemetry_expires_and_an_empty_initial_request_is_conservative() {
        let result = run(None, 0, vec![], context());
        assert_eq!(result.recommended_mode, RemoteDesktopMode::Standard);
        assert_eq!(result.reason, NetworkReason::TelemetryUnavailable);
        let result = run(Some(promote().state), 60001, vec![], context());
        assert_eq!(result.recommended_mode, RemoteDesktopMode::Standard);
        assert_eq!(result.evidence.tcp_connect_median_ms, None);
    }

    #[test]
    fn invalid_nonfinite_or_incomplete_timings_force_safe_fallback() {
        for value in [None, Some(-1.0), Some(f64::NAN), Some(f64::INFINITY)] {
            let mut probe = good(33000);
            probe.tcp_connect_ms = value;
            let result = run(Some(promote().state), 33000, vec![probe], context());
            assert_eq!(result.recommended_mode, RemoteDesktopMode::Standard);
            assert_eq!(result.reason, NetworkReason::InvalidTelemetry);
            assert_eq!(result.evidence.ignored_samples, 1);
        }
    }

    #[test]
    fn stale_duplicate_future_and_out_of_order_samples_cannot_promote() {
        let result = run(None, 40000, vec![good(0)], context());
        assert_eq!(result.evidence.ignored_samples, 1);
        let result = run(Some(result.state), 40000, vec![good(40000)], context());
        let result = run(
            Some(result.state),
            41000,
            vec![good(40000), good(39999)],
            context(),
        );
        assert_eq!(result.evidence.ignored_samples, 2);
        assert_eq!(result.evidence.consecutive_healthy_samples, 1);
        let result = run(Some(result.state), 42000, vec![good(43000)], context());
        assert_eq!(result.reason, NetworkReason::InvalidTelemetry);
        assert_eq!(result.evidence.consecutive_healthy_samples, 0);
    }

    #[test]
    fn clock_regression_keeps_clock_monotonic_and_falls_back() {
        let result = run(Some(promote().state), 100, vec![good(100)], context());
        assert_eq!(result.reason, NetworkReason::ClockRegression);
        assert_eq!(result.recommended_mode, RemoteDesktopMode::Standard);
        assert_eq!(result.state.last_evaluation_ms, 30000);
        assert!(result.state.valid());
    }

    #[test]
    fn route_changes_require_new_sustained_evidence_even_when_both_are_approved() {
        let result = promote();
        let mut route = context();
        route.route_identity = Some("different-route".into());
        let result = run(Some(result.state), 33000, vec![good(33000)], route);
        assert_eq!(result.evidence.consecutive_healthy_samples, 1);
        assert_eq!(result.recommended_mode, RemoteDesktopMode::Standard);
        assert_eq!(result.reason, NetworkReason::RouteChanged);
    }

    #[test]
    fn wide_connection_timing_variation_prevents_promotion() {
        let mut result = run(None, 0, vec![good(0)], context());
        for index in 1..30 {
            let time = index * 3000;
            let mut probe = good(time);
            probe.tcp_connect_ms = Some(if index % 2 == 0 { 1.0 } else { 19.0 });
            result = run(Some(result.state), time, vec![probe], context());
            assert_eq!(result.recommended_mode, RemoteDesktopMode::Standard);
        }
    }

    #[test]
    fn outage_retries_are_bounded_and_repeated_evaluation_does_not_spend_budget() {
        let mut result = run(None, 0, vec![failed(0)], context());
        assert_eq!(result.retry_attempt, 1);
        assert_eq!(result.retry_after_ms, Some(1000));
        result = run(Some(result.state), 500, vec![], context());
        assert_eq!(result.retry_attempt, 1);
        assert_eq!(result.retry_after_ms, Some(500));
        let mut time = 1000;
        for expected in 2..=6 {
            result = run(Some(result.state), time, vec![failed(time)], context());
            assert_eq!(result.retry_attempt, expected);
            let delay = result.retry_after_ms.unwrap();
            assert!(delay <= 8000);
            time += delay;
        }
        result = run(Some(result.state), time, vec![failed(time)], context());
        assert_eq!(result.action, NetworkAction::StopRetrying);
        assert_eq!(result.retry_after_ms, None);
        assert_eq!(result.reason, NetworkReason::RetryBudgetExhausted);
        let result = run(
            Some(result.state),
            time + 1000,
            vec![good(time + 1000)],
            context(),
        );
        assert_eq!(result.retry_attempt, 0);
        assert_eq!(result.retry_after_ms, None);
    }

    #[test]
    fn repeated_bad_good_cycles_lock_out_further_upgrades() {
        let mut result = run(None, 0, vec![good(0)], context());
        let mut time = 0;
        for _ in 0..3 {
            for _ in 0..20 {
                time += 3000;
                result = run(Some(result.state), time, vec![good(time)], context());
            }
            assert_eq!(result.recommended_mode, RemoteDesktopMode::HighPerformance);
            for _ in 0..11 {
                time += 3000;
                result = run(Some(result.state), time, vec![bad(time)], context());
            }
            assert_eq!(result.recommended_mode, RemoteDesktopMode::Standard);
        }
        assert_eq!(result.mode_switches, 6);
        for _ in 0..20 {
            time += 3000;
            result = run(Some(result.state), time, vec![good(time)], context());
        }
        assert_eq!(result.recommended_mode, RemoteDesktopMode::Standard);
        assert_eq!(result.reason, NetworkReason::SwitchBudgetExhausted);
    }

    #[test]
    fn invalid_persisted_state_is_reset_without_panic() {
        let mut state = promote().state;
        state.healthy_samples = u32::MAX;
        let result = run(Some(state), 33000, vec![good(33000)], context());
        assert_eq!(result.recommended_mode, RemoteDesktopMode::Standard);
        assert_eq!(result.reason, NetworkReason::PersistedStateReset);
        assert!(result.state.valid());
    }

    #[test]
    fn samples_and_reported_connection_statistics_are_bounded() {
        let probes = (0..100)
            .map(|time| {
                let mut sample = good(time);
                sample.tcp_connect_ms = Some(time as f64);
                sample
            })
            .collect();
        let result = run(None, 100, probes, context());
        assert_eq!(result.evidence.accepted_samples, 64);
        assert_eq!(result.evidence.ignored_samples, 36);
        assert_eq!(result.evidence.tcp_connect_median_ms, Some(31.0));
        assert_eq!(result.evidence.tcp_connect_p95_ms, Some(60.0));
        assert_eq!(result.evidence.tcp_connect_spread_ms, Some(63.0));
        assert_eq!(result.state.recent_connect_ms.len(), 4);
    }
}

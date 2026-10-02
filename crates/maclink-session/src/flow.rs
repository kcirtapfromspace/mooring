//! The sharing host's pacing against the connection.
//!
//! Video written to the socket waits in the kernel's send buffer, where a
//! newer frame can no longer replace it. Between two Macs on Wi-Fi, up to
//! 512 KiB queued there during a slowdown: about 200 ms at 20 Mbit/s. So the
//! host starts a frame only while little is queued, keeping the newest frame
//! waiting in the app instead, and adapts the bitrate: down quickly when
//! frames have to wait, back up slowly once the connection is clear.
//!
//! The bitrate is the encoder's target, not what it sends: a calm screen
//! needs far less. So a cut is measured against what the link carried while
//! video waited for it, which is the link's own rate, and the bitrate then
//! climbs back only to just below that rate. Every half minute without
//! trouble, the remembered rate rises a tenth, so a faster connection is
//! found again.

/// About 10 ms at 100 Mbit/s or 50 ms at 20 Mbit/s. The buffer also holds
/// sent bytes not yet acknowledged, about 60 KiB at 100 Mbit/s and 5 ms, so a
/// longer connection gets more: see `queue_limit`.
pub(crate) const QUEUE_LIMIT_BYTES: u32 = 128 * 1024;
const MAX_QUEUE_LIMIT_BYTES: u32 = 4 * 1024 * 1024;
/// On a slow link the 128 KiB floor is itself the delay: about 100 ms at
/// 10 Mbit/s. There the limit is what keeps the link busy, plus this much
/// time for the next frame, but never under the smaller floor.
const FRAME_HEADROOM_MS: u64 = 20;
const MIN_QUEUE_LIMIT_BYTES: u32 = 48 * 1024;
/// Below this round trip the connection is local, where 128 KiB drains in
/// milliseconds and absorbs Wi-Fi's bursts: the smaller limit is for
/// connections across the internet.
const LOCAL_ROUND_TRIP_MS: u32 = 10;
/// Floor for automatic reductions: text stays legible at this rate.
pub(crate) const MIN_BITRATE_KBPS: u32 = 4_000;
/// Clear seconds before each rise, and the smallest step.
const CLEAR_SECONDS: u32 = 3;
const MIN_STEP_KBPS: u32 = 500;
/// A second in which frames waited this long for the send buffer is
/// congested. A keyframe of about 500 kB drains in about 12 ms at 40 MB/s,
/// so ordinary bursts stay well below it.
pub(crate) const CONGESTED_WAIT_MS: u32 = 150;
/// Congested seconds among the last four that lower the bitrate.
const CONGESTED_OF_FOUR: u32 = 2;
/// Queued bytes above which video is waiting for the link, not just in
/// flight: the kernel is then sending as fast as the connection allows.
const BACKLOG_BYTES: u32 = 64 * 1024;
/// A second's link rate needs at least this much time backlogged.
const MIN_BACKLOG_MS: u64 = 40;
/// Nothing sent for this long while backlogged is a stall, as when Wi-Fi
/// pauses, not the link's pace: that time doesn't count. Shorter gaps, as
/// between packets on a slow link, do.
const STALL_MS: u64 = 50;
/// Clear seconds after which the remembered link rate rises a tenth.
const PROBE_SECONDS: u32 = 30;

/// Measures the link's rate while video waits for it in the send buffer.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct LinkMeter {
    pub last_ms: u64,
    pub last_sent: u64,
    pub busy_ms: u64,
    pub busy_bytes: u64,
    /// Backlogged time since bytes were last sent, not yet counted.
    pub idle_ms: u64,
    pub last_queued: u32,
    pub started: u32,
}

impl LinkMeter {
    /// One reading of the send buffer: what is queued in it, and the bytes
    /// the connection has sent so far. Time between two backlogged readings
    /// counts toward the link's rate, except a stall.
    pub(crate) fn sample(&mut self, now_ms: u64, sent_bytes: u64, queued_bytes: u32) {
        let backlogged = self.started != 0
            && now_ms > self.last_ms
            && sent_bytes >= self.last_sent
            && self.last_queued >= BACKLOG_BYTES
            && queued_bytes >= BACKLOG_BYTES;
        if !backlogged {
            self.idle_ms = 0;
        } else if sent_bytes == self.last_sent {
            self.idle_ms = self.idle_ms.saturating_add(now_ms - self.last_ms);
        } else {
            if self.idle_ms < STALL_MS {
                self.busy_ms = self.busy_ms.saturating_add(self.idle_ms);
            }
            self.idle_ms = 0;
            self.busy_ms = self.busy_ms.saturating_add(now_ms - self.last_ms);
            self.busy_bytes = self.busy_bytes.saturating_add(sent_bytes - self.last_sent);
        }
        (self.last_ms, self.last_sent, self.last_queued, self.started) =
            (now_ms, sent_bytes, queued_bytes, 1);
    }
    /// The link's rate in kbit/s over the backlogged time since the last
    /// call, then starts again; 0 when there was too little to measure.
    pub(crate) fn take_kbps(&mut self) -> u32 {
        let kbps = if self.busy_ms >= MIN_BACKLOG_MS {
            (self.busy_bytes.saturating_mul(8) / self.busy_ms).min(u64::from(u32::MAX)) as u32
        } else {
            0
        };
        (self.busy_ms, self.busy_bytes) = (0, 0);
        kbps
    }
}

/// The most that may be queued before a frame starts, from the fastest
/// recent round trip and the most sent in a recent second. On a fast or long
/// connection: one and a half times what is in flight, so it stays busy, and
/// at least 128 KiB. Over a 50 ms VPN at 3 MB/s that is 225 KiB; on a home
/// network it stays at 128 KiB. Across the internet (a round trip of 10 ms or
/// more), a slow link gets less: one and a half times what is in flight plus
/// 20 ms of sending for the next frame, at least 48 KiB. At 10 Mbit/s and
/// 28 ms that is about 77 kB rather than 128 KiB. Nothing sent yet: 128 KiB.
pub(crate) fn queue_limit(min_round_trip_ms: u32, sent_bytes_per_second: u64) -> u32 {
    let in_flight = sent_bytes_per_second.saturating_mul(u64::from(min_round_trip_ms)) / 1000;
    let busy = in_flight.saturating_mul(3) / 2;
    let fast = busy.clamp(
        u64::from(QUEUE_LIMIT_BYTES),
        u64::from(MAX_QUEUE_LIMIT_BYTES),
    );
    if sent_bytes_per_second == 0 || min_round_trip_ms < LOCAL_ROUND_TRIP_MS {
        return fast as u32;
    }
    let slow = busy
        .saturating_add(sent_bytes_per_second.saturating_mul(FRAME_HEADROOM_MS) / 1000)
        .max(u64::from(MIN_QUEUE_LIMIT_BYTES));
    slow.min(fast) as u32
}

pub(crate) fn admits_frame(queued_bytes: u32, limit: u32) -> bool {
    queued_bytes <= limit
}

/// Pacing history the host keeps between calls.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct FlowState {
    /// Congested flags for the last four seconds, the newest in bit 0.
    pub recent: u32,
    /// Clear seconds since the last change.
    pub clear_seconds: u32,
    /// The link's rate when it last ran out, in kbit/s; 0 if unknown.
    pub limit_kbps: u32,
    /// Clear seconds since the last cut or probe.
    pub held_seconds: u32,
    /// What the host sent, as a maximum that decays an eighth each clear second,
    /// kbit/s.
    pub peak_kbps: u32,
}

/// Once a second, from the milliseconds frames waited for the send buffer:
/// the bitrate for the next second, never above the tuned `ceiling_kbps`.
/// Two congested seconds of the last four lower it to three quarters; each
/// three clear seconds raise it 10% (at least 500 kbps). A single slow second
/// changes nothing.
///
/// `after_keyframe`: a keyframe went out this second or the one before. A
/// keyframe of a sharp 4:4:4 screen can be a megabyte, and draining it is the
/// keyframe's cost, not a sign of a slow connection: such a second, if
/// congested, is left out, neither lowering the bitrate nor counting as clear.
///
/// `link_kbps`: the link's rate measured this second while video waited for
/// it (LinkMeter), or 0. `sent_kbps`: what the host sent this second. The
/// link carries at least what it recently carried, so the link's rate is
/// taken as no less than the recent peak of what was sent: a slow trickle
/// after a stall isn't the link. A cut goes to three quarters of that rate
/// when that is lower than three quarters of the bitrate, and the rate is
/// remembered: climbing back stops at nine tenths of it. Each 30 clear
/// seconds the remembered rate rises a tenth; a measured rate above it
/// replaces it, and one the ceiling no longer reaches is forgotten.
pub(crate) fn next_bitrate(
    current_kbps: u32,
    ceiling_kbps: u32,
    state: FlowState,
    waited_ms: u32,
    after_keyframe: bool,
    link_kbps: u32,
    sent_kbps: u32,
) -> (u32, FlowState) {
    let floor = MIN_BITRATE_KBPS.min(ceiling_kbps);
    let ceiling = ceiling_kbps.max(floor);
    let current = current_kbps.clamp(floor, ceiling);
    let congested = waited_ms >= CONGESTED_WAIT_MS;
    // Decays only in clear seconds: a stall's trickle wears nothing down.
    let peak = if congested {
        sent_kbps.max(state.peak_kbps)
    } else {
        sent_kbps.max(state.peak_kbps - state.peak_kbps / 8)
    };
    let mut limit = state.limit_kbps;
    if limit > 0 && link_kbps > limit {
        limit = link_kbps;
    }
    if congested && after_keyframe {
        return (
            current,
            FlowState {
                recent: (state.recent << 1) & 0b1111,
                limit_kbps: limit,
                peak_kbps: peak,
                ..state
            },
        );
    }
    let recent = ((state.recent << 1) | u32::from(congested)) & 0b1111;
    if recent.count_ones() >= CONGESTED_OF_FOUR {
        let mut cut = current / 4 * 3;
        if link_kbps > 0 {
            let link = link_kbps.max(peak);
            cut = cut.min(link / 4 * 3);
            limit = link;
        }
        return (
            cut.max(floor),
            FlowState {
                limit_kbps: limit,
                peak_kbps: peak,
                ..FlowState::default()
            },
        );
    }
    let clear_seconds = if congested {
        0
    } else {
        state.clear_seconds.saturating_add(1)
    };
    let mut held_seconds = if congested {
        0
    } else {
        state.held_seconds.saturating_add(1)
    };
    if limit > 0 && held_seconds >= PROBE_SECONDS {
        limit = limit.saturating_add(limit / 10);
        held_seconds = 0;
    }
    if limit / 10 * 9 >= ceiling {
        limit = 0;
    }
    let next = FlowState {
        recent,
        clear_seconds,
        limit_kbps: limit,
        held_seconds,
        peak_kbps: peak,
    };
    if clear_seconds < CLEAR_SECONDS {
        return (current, next);
    }
    let cap = if limit > 0 {
        (limit / 10 * 9).clamp(floor, ceiling)
    } else {
        ceiling
    };
    let raised = current
        .saturating_add((current / 10).max(MIN_STEP_KBPS))
        .min(cap.max(current));
    (
        raised,
        FlowState {
            clear_seconds: 0,
            ..next
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIMIT: u32 = QUEUE_LIMIT_BYTES;

    #[test]
    fn frames_start_only_while_little_is_queued() {
        assert!(admits_frame(0, LIMIT) && admits_frame(LIMIT, LIMIT));
        assert!(!admits_frame(LIMIT + 1, LIMIT) && !admits_frame(u32::MAX, LIMIT));
    }

    #[test]
    fn the_queue_limit_follows_the_connection() {
        // Home network: 12 MB/s at 3 ms keeps the 128 KiB floor.
        assert_eq!(queue_limit(3, 12_000_000), QUEUE_LIMIT_BYTES);
        assert_eq!(queue_limit(0, 0), QUEUE_LIMIT_BYTES);
        // VPN: 3 MB/s at 50 ms is 150 kB in flight; one and a half times that.
        assert_eq!(queue_limit(50, 3_000_000), 225_000);
        assert_eq!(queue_limit(u32::MAX, u64::MAX), MAX_QUEUE_LIMIT_BYTES);
        // Away at 10 Mbit/s and 28 ms: 35 kB in flight, 52.5 kB to stay busy,
        // and 25 kB for the next frame, instead of 128 KiB.
        assert_eq!(queue_limit(28, 1_250_000), 77_500);
        // A slow, calm link keeps 48 KiB for a sudden large frame.
        assert_eq!(queue_limit(28, 125_000), MIN_QUEUE_LIMIT_BYTES);
        // At home, whatever the screen sends, 128 KiB as before.
        assert_eq!(queue_limit(3, 2_000_000), QUEUE_LIMIT_BYTES);
        assert_eq!(queue_limit(9, 125_000), QUEUE_LIMIT_BYTES);
        // Never more than the fast-network rule, whatever the rate.
        for (round_trip, rate) in [(10, 50_000_000), (12, 4_000_000), (80, 900_000)] {
            let limit = queue_limit(round_trip, rate);
            let in_flight = rate * u64::from(round_trip) / 1000;
            assert!(u64::from(limit) <= (in_flight * 3 / 2).max(u64::from(QUEUE_LIMIT_BYTES)));
            assert!(limit >= MIN_QUEUE_LIMIT_BYTES);
        }
    }

    fn run(kbps: u32, ceiling: u32, seconds: &[u32]) -> (u32, FlowState) {
        let plain: Vec<(u32, bool)> = seconds.iter().map(|waited| (*waited, false)).collect();
        run_keyed(kbps, ceiling, &plain)
    }
    /// Each second: how long frames waited, and whether it follows a keyframe.
    fn run_keyed(kbps: u32, ceiling: u32, seconds: &[(u32, bool)]) -> (u32, FlowState) {
        let linked: Vec<(u32, bool, u32)> = seconds
            .iter()
            .map(|(waited, keyframe)| (*waited, *keyframe, 0))
            .collect();
        run_linked(kbps, ceiling, FlowState::default(), &linked)
    }
    /// Each second: how long frames waited, whether it follows a keyframe,
    /// and the link's measured rate.
    fn run_linked(
        kbps: u32,
        ceiling: u32,
        state: FlowState,
        seconds: &[(u32, bool, u32)],
    ) -> (u32, FlowState) {
        let sent: Vec<(u32, bool, u32, u32)> = seconds
            .iter()
            .map(|(waited, keyframe, link)| (*waited, *keyframe, *link, 0))
            .collect();
        run_sent(kbps, ceiling, state, &sent)
    }
    /// As run_linked, with what was sent each second.
    fn run_sent(
        mut kbps: u32,
        ceiling: u32,
        mut state: FlowState,
        seconds: &[(u32, bool, u32, u32)],
    ) -> (u32, FlowState) {
        for (waited, keyframe, link, sent) in seconds {
            (kbps, state) = next_bitrate(kbps, ceiling, state, *waited, *keyframe, *link, *sent);
        }
        (kbps, state)
    }

    #[test]
    fn a_stall_isnt_taken_for_a_slow_link() {
        let slow = CONGESTED_WAIT_MS;
        // At home the content was sending 15 Mbps without trouble; then Wi-Fi
        // paused and only a trickle went out while frames waited.
        let mut seconds = vec![(0, false, 0, 15_000); 3];
        seconds.extend([(slow, false, 2_000, 1_500), (slow, false, 2_000, 1_000)]);
        let (kbps, state) = run_sent(25_000, 25_000, FlowState::default(), &seconds);
        assert_eq!((kbps, state.limit_kbps), (11_250, 15_000));
        // Away, what was sent and what was measured agree.
        let mut seconds = vec![(0, false, 0, 9_000); 3];
        seconds.extend([(slow, false, 9_500, 9_300), (slow, false, 9_400, 9_200)]);
        let (kbps, state) = run_sent(25_000, 25_000, FlowState::default(), &seconds);
        assert_eq!((kbps, state.limit_kbps), (7_050, 9_400));
    }

    #[test]
    fn a_cut_goes_below_what_the_link_carried_and_climbing_stops_short_of_it() {
        let slow = CONGESTED_WAIT_MS;
        // The target was 25 Mbps but the screen needed about 9, all the link
        // carries: a cut to three quarters of the target would change nothing.
        let (kbps, state) = run_linked(
            25_000,
            25_000,
            FlowState::default(),
            &[(slow, false, 9_500), (slow, false, 9_400)],
        );
        assert_eq!((kbps, state.limit_kbps), (7_050, 9_400));
        // Without a measured rate, the old rule.
        assert_eq!(run(25_000, 25_000, &[slow, slow]).0, 18_750);
        // Clear seconds climb back, but only to nine tenths of the link's rate.
        let (kbps, state) = run_linked(kbps, 25_000, state, &[(0, false, 0); 27]);
        assert_eq!((kbps, state.limit_kbps), (8_460, 9_400));
        // Every 30 clear seconds the remembered rate rises a tenth.
        let (kbps, state) = run_linked(kbps, 25_000, state, &[(0, false, 0); 3]);
        assert_eq!(state.limit_kbps, 10_340);
        let (kbps, _) = run_linked(kbps, 25_000, state, &[(0, false, 0); 3]);
        assert_eq!(kbps, 9_306);
        // A faster link, measured while video waited, is believed at once.
        let mut faster = FlowState {
            limit_kbps: 9_400,
            ..FlowState::default()
        };
        (_, faster) = next_bitrate(8_460, 25_000, faster, 50, false, 20_000, 0);
        assert_eq!(faster.limit_kbps, 20_000);
        // One the ceiling no longer reaches is forgotten.
        let (kbps, state) = run_linked(
            8_000,
            25_000,
            FlowState {
                limit_kbps: 30_000,
                ..FlowState::default()
            },
            &[(0, false, 0); 3],
        );
        assert_eq!((kbps, state.limit_kbps), (8_800, 0));
        // A keyframe's slow seconds keep what was learned.
        let (_, kept) = run_linked(8_000, 25_000, faster, &[(slow, true, 5_000)]);
        assert_eq!(kept.limit_kbps, 20_000);
    }

    #[test]
    fn the_link_is_measured_only_while_video_waits() {
        let mut meter = LinkMeter::default();
        let busy = BACKLOG_BYTES;
        // 125 kB over 100 ms backlogged: 10 Mbit/s.
        meter.sample(1_000, 0, busy);
        meter.sample(1_050, 62_500, busy);
        meter.sample(1_100, 125_000, busy);
        // Sending with little queued says nothing about the link.
        meter.sample(1_200, 200_000, 1_000);
        meter.sample(1_300, 260_000, busy);
        assert_eq!(meter.take_kbps(), 10_000);
        assert_eq!(meter.take_kbps(), 0, "each second starts again");
        // Too little backlogged time to measure.
        meter.sample(1_330, 300_000, busy);
        assert_eq!(meter.take_kbps(), 0);
        // A counter that went backwards, as after a new connection, is skipped.
        meter.sample(1_400, 10, busy);
        meter.sample(1_500, 125_010, busy);
        assert_eq!(meter.take_kbps(), 10_000);
        // A stall, nothing sent for 50 ms or more while frames wait, doesn't
        // count; short gaps between packets do.
        let mut meter = LinkMeter::default();
        meter.sample(0, 0, busy);
        meter.sample(50, 62_500, busy);
        for now in (60..=400).step_by(10) {
            meter.sample(now, 62_500, busy);
        }
        meter.sample(450, 125_000, busy);
        assert_eq!(meter.take_kbps(), 10_000, "a 350 ms stall left out");
        meter.sample(470, 125_000, busy);
        meter.sample(500, 150_000, busy);
        meter.sample(520, 150_000, busy);
        meter.sample(550, 162_500, busy);
        assert_eq!(
            meter.take_kbps(),
            3_000,
            "gaps under 50 ms are the link's pace"
        );
    }

    #[test]
    fn a_keyframes_slow_seconds_are_left_out() {
        let slow = CONGESTED_WAIT_MS;
        // A megabyte keyframe drains across its second and the next: no cut.
        assert_eq!(
            run_keyed(25_000, 25_000, &[(slow, true), (slow, true), (0, false)]).0,
            25_000
        );
        // Two keyframes close together, as at a session's start and its first
        // resize, cost nothing either.
        assert_eq!(
            run_keyed(
                25_000,
                25_000,
                &[
                    (slow, true),
                    (slow, true),
                    (0, false),
                    (slow, true),
                    (slow, true)
                ]
            )
            .0,
            25_000
        );
        // Left out, not clear: they don't count toward raising it.
        assert_eq!(
            run_keyed(
                10_000,
                25_000,
                &[(0, false), (slow, true), (0, false), (slow, true)]
            )
            .0,
            10_000
        );
        // A slow connection still shows between keyframes.
        assert_eq!(
            run_keyed(
                25_000,
                25_000,
                &[(slow, true), (slow, false), (slow, false)]
            )
            .0,
            18_750
        );
    }

    #[test]
    fn two_slow_seconds_of_four_lower_the_bitrate() {
        let slow = CONGESTED_WAIT_MS;
        // One slow second, as for one large keyframe, changes nothing.
        assert_eq!(run(25_000, 25_000, &[slow]).0, 25_000);
        // Two in a row, or two of four, lower it to three quarters.
        assert_eq!(run(25_000, 25_000, &[slow, slow]).0, 18_750);
        assert_eq!(run(25_000, 25_000, &[slow, 0, 0, slow]).0, 18_750);
        // Slow seconds further apart than four do not add up.
        assert_eq!(run(25_000, 25_000, &[slow, 0, 0, 0, slow]).0, 25_000);
        // Waits under the threshold, such as a keyframe draining in 12 ms, are not slow.
        assert_eq!(run(25_000, 25_000, &[CONGESTED_WAIT_MS - 1; 8]).0, 25_000);
        // After a cut the history starts again: the next cut takes two more.
        assert_eq!(run(25_000, 25_000, &[slow, slow, slow]).0, 18_750);
        assert_eq!(run(25_000, 25_000, &[slow, slow, slow, slow]).0, 14_061);
    }

    #[test]
    fn each_three_clear_seconds_raise_the_bitrate_once() {
        assert_eq!(run(10_000, 25_000, &[0, 0]).0, 10_000);
        assert_eq!(run(10_000, 25_000, &[0, 0, 0]).0, 11_000);
        // Not every second after the third: one step per three.
        assert_eq!(run(10_000, 25_000, &[0, 0, 0, 0, 0]).0, 11_000);
        assert_eq!(run(10_000, 25_000, &[0; 6]).0, 12_100);
        // A slow second restarts the count; the 500 kbps minimum step.
        assert_eq!(
            run(5_000, 25_000, &[0, 0, CONGESTED_WAIT_MS, 0, 0]).0,
            5_000
        );
        assert_eq!(run(5_000, 25_000, &[0, 0, 0]).0, 5_500);
        // Never above the ceiling.
        assert_eq!(run(24_900, 25_000, &[0, 0, 0]).0, 25_000);
    }

    #[test]
    fn a_periodic_slow_keyframe_still_converges() {
        // Every other second slow: cut, then cut again, until it stops.
        let mut seconds = Vec::new();
        for _ in 0..10 {
            seconds.extend([CONGESTED_WAIT_MS, 0]);
        }
        assert!(run(25_000, 25_000, &seconds).0 < 10_000);
    }

    #[test]
    fn bitrate_stays_within_the_floor_and_the_tuned_ceiling() {
        assert_eq!(run(25_000, 25_000, &[1_000; 40]).0, MIN_BITRATE_KBPS);
        // A lower tuned bitrate applies at once; a ceiling below the floor holds.
        assert_eq!(run(25_000, 8_000, &[0]).0, 8_000);
        assert_eq!(run(25_000, 2_000, &[1_000; 4]).0, 2_000);
        assert_eq!(run(0, 25_000, &[0]).0, MIN_BITRATE_KBPS);
        let state = FlowState {
            recent: u32::MAX,
            clear_seconds: u32::MAX,
            limit_kbps: u32::MAX,
            held_seconds: u32::MAX,
            peak_kbps: u32::MAX,
        };
        assert_eq!(
            next_bitrate(u32::MAX, u32::MAX, state, 0, false, 0, 0).0,
            u32::MAX / 4 * 3
        );
        let clear = FlowState {
            recent: 0,
            clear_seconds: u32::MAX,
            ..FlowState::default()
        };
        // One slow second after a clear history keeps the bitrate.
        assert_eq!(
            next_bitrate(
                u32::MAX,
                u32::MAX,
                clear,
                u32::MAX,
                false,
                u32::MAX,
                u32::MAX
            )
            .0,
            u32::MAX
        );
    }
}

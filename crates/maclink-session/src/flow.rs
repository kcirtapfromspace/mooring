//! The sharing host's pacing against the connection.
//!
//! Video written to the socket waits in the kernel's send buffer, where a
//! newer frame can no longer replace it. Between two Macs on Wi-Fi, up to
//! 512 KiB queued there during a slowdown: about 200 ms at 20 Mbit/s. So the
//! host starts a frame only while little is queued, keeping the newest frame
//! waiting in the app instead, and adapts the bitrate: down quickly when
//! frames have to wait, back up slowly once the connection is clear.

/// About 10 ms at 100 Mbit/s or 50 ms at 20 Mbit/s. The buffer also holds
/// sent bytes not yet acknowledged, about 60 KiB at 100 Mbit/s and 5 ms, so a
/// longer connection gets more: see `queue_limit`.
pub(crate) const QUEUE_LIMIT_BYTES: u32 = 128 * 1024;
const MAX_QUEUE_LIMIT_BYTES: u32 = 4 * 1024 * 1024;
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

/// The most that may be queued before a frame starts: one and a half times
/// what the connection carries in its fastest recent round trip, so a long
/// connection stays busy, and at least 128 KiB. Over a 50 ms VPN at 3 MB/s
/// that is 225 KiB; on a home network it stays at 128 KiB.
pub(crate) fn queue_limit(min_round_trip_ms: u32, sent_bytes_per_second: u64) -> u32 {
    let in_flight = sent_bytes_per_second.saturating_mul(u64::from(min_round_trip_ms)) / 1000;
    let limit = (in_flight.saturating_mul(3) / 2).clamp(
        u64::from(QUEUE_LIMIT_BYTES),
        u64::from(MAX_QUEUE_LIMIT_BYTES),
    );
    limit as u32
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
}

/// Once a second, from the milliseconds frames waited for the send buffer:
/// the bitrate for the next second, never above the tuned `ceiling_kbps`.
/// Two congested seconds of the last four lower it to three quarters; each
/// three clear seconds raise it 10% (at least 500 kbps). A single slow second,
/// as for one large keyframe, changes nothing.
pub(crate) fn next_bitrate(
    current_kbps: u32,
    ceiling_kbps: u32,
    state: FlowState,
    waited_ms: u32,
) -> (u32, FlowState) {
    let floor = MIN_BITRATE_KBPS.min(ceiling_kbps);
    let ceiling = ceiling_kbps.max(floor);
    let current = current_kbps.clamp(floor, ceiling);
    let congested = waited_ms >= CONGESTED_WAIT_MS;
    let recent = ((state.recent << 1) | u32::from(congested)) & 0b1111;
    if recent.count_ones() >= CONGESTED_OF_FOUR {
        return ((current / 4 * 3).max(floor), FlowState::default());
    }
    let clear_seconds = if congested {
        0
    } else {
        state.clear_seconds.saturating_add(1)
    };
    if clear_seconds < CLEAR_SECONDS {
        return (
            current,
            FlowState {
                recent,
                clear_seconds,
            },
        );
    }
    let raised = current
        .saturating_add((current / 10).max(MIN_STEP_KBPS))
        .min(ceiling);
    (
        raised,
        FlowState {
            recent,
            clear_seconds: 0,
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
    }

    fn run(mut kbps: u32, ceiling: u32, seconds: &[u32]) -> (u32, FlowState) {
        let mut state = FlowState::default();
        for waited in seconds {
            (kbps, state) = next_bitrate(kbps, ceiling, state, *waited);
        }
        (kbps, state)
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
        };
        assert_eq!(
            next_bitrate(u32::MAX, u32::MAX, state, 0).0,
            u32::MAX / 4 * 3
        );
        let clear = FlowState {
            recent: 0,
            clear_seconds: u32::MAX,
        };
        // One slow second after a clear history keeps the bitrate.
        assert_eq!(
            next_bitrate(u32::MAX, u32::MAX, clear, u32::MAX).0,
            u32::MAX
        );
    }
}

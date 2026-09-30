//! Places the host's capture timestamps on the viewer's clock, so the viewer
//! can measure how long a screen change takes to reach its display.
//!
//! Each clock reply is one sample: the viewer's times for sending a ping and
//! receiving the reply, and the host's time when it answered. As in NTP, the
//! sample with the shortest round trip gives the best offset, with an error of
//! at most half that round trip. Both Macs count CoreMedia host time, which
//! drifts only a few microseconds a second, so a window of recent samples
//! follows it.

use crate::{Error, Result};

pub(crate) const MAX_SAMPLES: usize = 32;
/// A slower round trip says little about the offset.
const MAX_ROUND_TRIP_US: u64 = 1_000_000;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct ClockSample {
    pub sent_us: u64,
    pub received_us: u64,
    pub host_us: u64,
}

/// Host time minus viewer time, and the error bound, both in microseconds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ClockEstimate {
    pub offset_us: i64,
    pub error_us: u64,
}

pub(crate) fn estimate(samples: &[ClockSample]) -> Result<ClockEstimate> {
    if samples.len() > MAX_SAMPLES {
        return Err(Error::Invalid);
    }
    let limit = i64::MAX as u64;
    samples
        .iter()
        .filter(|sample| {
            sample.received_us >= sample.sent_us
                && sample.received_us - sample.sent_us <= MAX_ROUND_TRIP_US
                && sample.received_us <= limit
                && sample.host_us <= limit
        })
        .min_by_key(|sample| sample.received_us - sample.sent_us)
        .map(|sample| {
            let round_trip = sample.received_us - sample.sent_us;
            let midpoint = sample.sent_us + round_trip / 2;
            ClockEstimate {
                offset_us: sample.host_us as i64 - midpoint as i64,
                error_us: round_trip.div_ceil(2),
            }
        })
        .ok_or(Error::Invalid)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(sent_us: u64, received_us: u64, host_us: u64) -> ClockSample {
        ClockSample {
            sent_us,
            received_us,
            host_us,
        }
    }

    #[test]
    fn the_fastest_round_trip_sets_the_offset() {
        // The host's clock is 5 s ahead. A queued reply (40 ms) would skew the
        // estimate by 20 ms; the 2 ms sample is used instead.
        let samples = [
            sample(1_000_000, 1_040_000, 6_001_000),
            sample(2_000_000, 2_002_000, 7_001_000),
            sample(3_000_000, 3_009_000, 8_004_000),
        ];
        assert_eq!(
            estimate(&samples),
            Ok(ClockEstimate {
                offset_us: 5_000_000,
                error_us: 1_000,
            })
        );
        // A host clock behind the viewer's gives a negative offset.
        assert_eq!(
            estimate(&[sample(9_000_000, 9_000_003, 1_000_000)]),
            Ok(ClockEstimate {
                offset_us: -8_000_001,
                error_us: 2,
            })
        );
    }

    #[test]
    fn unusable_samples_are_ignored_and_input_is_bounded() {
        assert_eq!(estimate(&[]), Err(Error::Invalid));
        for bad in [
            sample(10, 5, 100),                    // received before sent
            sample(0, MAX_ROUND_TRIP_US + 1, 100), // too slow
            sample(0, 10, u64::MAX),               // beyond the signed range
            sample(u64::MAX - 1, u64::MAX, 10),
        ] {
            assert_eq!(estimate(&[bad]), Err(Error::Invalid), "{bad:?}");
        }
        let good = sample(0, 10, 105);
        assert_eq!(
            estimate(&[sample(10, 5, 100), good]).map(|estimate| estimate.offset_us),
            Ok(100)
        );
        assert_eq!(estimate(&[good; MAX_SAMPLES + 1]), Err(Error::Invalid));
    }
}

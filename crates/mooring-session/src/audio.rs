//! The sharing Mac's sound, sent to a viewer that announced it plays it, and
//! the viewer's playout rule.
//!
//! Wire format: `[version=1, codec=1 (Opus), channels, 0, sequence:u32,
//! frames:u16, 0, 0]`, big-endian, then one Opus packet. Opus runs at 48 kHz;
//! `frames` is the packet's duration in samples (5, 10 or 20 ms). The sequence
//! counts packets, so the viewer can see a gap where the host dropped some.

use crate::{Error, Result};
use std::ops::Range;

const VERSION: u8 = 1;
pub(crate) const OPUS: u8 = 1;
const HEADER: usize = 12;
/// One Opus frame is at most 1275 bytes plus framing; this bounds a hostile
/// peer, not real packets, which are a few hundred bytes.
pub(crate) const MAX_AUDIO_PAYLOAD: usize = 1500;
pub(crate) const MAX_AUDIO: usize = HEADER + MAX_AUDIO_PAYLOAD;
pub(crate) const SAMPLE_RATE: u32 = 48_000;
const FRAME_SIZES: [u16; 3] = [240, 480, 960];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct AudioHeader {
    pub codec: u8,
    pub channels: u8,
    pub sequence: u32,
    pub frames: u16,
}

impl AudioHeader {
    fn is_valid(&self) -> bool {
        self.codec == OPUS && (1..=2).contains(&self.channels) && FRAME_SIZES.contains(&self.frames)
    }
}

pub(crate) fn encode(header: &AudioHeader, payload: &[u8]) -> Result<Vec<u8>> {
    if !header.is_valid() || payload.is_empty() || payload.len() > MAX_AUDIO_PAYLOAD {
        return Err(Error::Invalid);
    }
    let mut out = Vec::with_capacity(HEADER + payload.len());
    out.extend_from_slice(&[VERSION, header.codec, header.channels, 0]);
    out.extend_from_slice(&header.sequence.to_be_bytes());
    out.extend_from_slice(&header.frames.to_be_bytes());
    out.extend_from_slice(&[0, 0]);
    out.extend_from_slice(payload);
    Ok(out)
}

/// A received packet; the payload is a range of the caller's receive buffer.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct AudioPacket {
    pub header: AudioHeader,
    pub payload: Range<usize>,
}

impl AudioPacket {
    pub(crate) fn parse(data: &[u8]) -> Result<Self> {
        if data.len() <= HEADER || data.len() > MAX_AUDIO || data[0] != VERSION {
            return Err(Error::Protocol);
        }
        let header = AudioHeader {
            codec: data[1],
            channels: data[2],
            sequence: u32::from_be_bytes([data[4], data[5], data[6], data[7]]),
            frames: u16::from_be_bytes([data[8], data[9]]),
        };
        if !header.is_valid() || data[3] != 0 || data[10..12] != [0, 0] {
            return Err(Error::Protocol);
        }
        Ok(Self {
            header,
            payload: HEADER..data.len(),
        })
    }
}

/// Playback starts, and restarts after running dry, once this much is
/// buffered: enough to ride out ordinary Wi-Fi jitter.
pub(crate) const PLAYOUT_TARGET_FRAMES: u32 = SAMPLE_RATE / 25; // 40 ms
/// More than this, after a network stall or from clock drift between the two
/// Macs, drops the oldest sound back to the target so delay stays bounded.
pub(crate) const PLAYOUT_MAX_FRAMES: u32 = SAMPLE_RATE * 3 / 20; // 150 ms

/// After new sound is buffered: whether playback runs, and how many of the
/// oldest frames to drop. The player marks itself not playing when it runs dry.
pub(crate) fn playout(buffered: u32, playing: bool) -> (bool, u32) {
    if buffered > PLAYOUT_MAX_FRAMES {
        return (true, buffered - PLAYOUT_TARGET_FRAMES);
    }
    (playing || buffered >= PLAYOUT_TARGET_FRAMES, 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    const OPUS_PACKET: &[u8] = &[0xfc, 0xff, 0xfe];
    const TEN_MS: AudioHeader = AudioHeader {
        codec: OPUS,
        channels: 2,
        sequence: 7,
        frames: 480,
    };

    #[test]
    fn audio_round_trips_with_its_sequence() {
        let wire = encode(&TEN_MS, OPUS_PACKET).unwrap();
        let packet = AudioPacket::parse(&wire).unwrap();
        assert_eq!(packet.header, TEN_MS);
        assert_eq!(&wire[packet.payload], OPUS_PACKET);
        let largest = vec![1; MAX_AUDIO_PAYLOAD];
        assert_eq!(
            AudioPacket::parse(&encode(&TEN_MS, &largest).unwrap())
                .unwrap()
                .payload
                .len(),
            MAX_AUDIO_PAYLOAD
        );
    }

    #[test]
    fn invalid_audio_is_refused() {
        let with = |codec, channels, frames| AudioHeader {
            codec,
            channels,
            sequence: 0,
            frames,
        };
        for header in [
            with(2, 2, 480), // unknown codec
            with(OPUS, 0, 480),
            with(OPUS, 3, 480),
            with(OPUS, 2, 441), // not an Opus duration
            with(OPUS, 2, 120), // too short to be worth a message
        ] {
            assert_eq!(
                encode(&header, OPUS_PACKET),
                Err(Error::Invalid),
                "{header:?}"
            );
        }
        assert_eq!(encode(&TEN_MS, &[]), Err(Error::Invalid));
        assert_eq!(
            encode(&TEN_MS, &vec![0; MAX_AUDIO_PAYLOAD + 1]),
            Err(Error::Invalid)
        );
        let good = encode(&TEN_MS, OPUS_PACKET).unwrap();
        let mutate = |index: usize, value: u8| {
            let mut copy = good.clone();
            copy[index] = value;
            copy
        };
        let oversized = [&good[..HEADER], &vec![0; MAX_AUDIO_PAYLOAD + 1]].concat();
        for bad in [
            good[..HEADER].to_vec(), // no payload
            mutate(0, 2),
            mutate(1, 0),
            mutate(2, 3),
            mutate(3, 1),
            mutate(9, 0), // 256 frames
            mutate(11, 1),
            oversized,
        ] {
            assert_eq!(AudioPacket::parse(&bad), Err(Error::Protocol));
        }
    }

    #[test]
    fn playout_waits_for_the_target_and_bounds_delay() {
        assert_eq!(playout(0, false), (false, 0));
        assert_eq!(playout(PLAYOUT_TARGET_FRAMES - 1, false), (false, 0));
        assert_eq!(playout(PLAYOUT_TARGET_FRAMES, false), (true, 0));
        // Once playing, a thin buffer keeps playing until it runs dry.
        assert_eq!(playout(480, true), (true, 0));
        assert_eq!(playout(PLAYOUT_MAX_FRAMES, true), (true, 0));
        // A burst after a stall drops the oldest sound back to the target.
        for playing in [false, true] {
            assert_eq!(
                playout(PLAYOUT_MAX_FRAMES + 1, playing),
                (true, PLAYOUT_MAX_FRAMES + 1 - PLAYOUT_TARGET_FRAMES)
            );
        }
        assert_eq!(
            playout(u32::MAX, true),
            (true, u32::MAX - PLAYOUT_TARGET_FRAMES)
        );
    }
}

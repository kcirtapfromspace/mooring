//! One bounded H.264 access unit. Integers use network byte order. Header:
//! MLV1, flags:u8 (keyframe 0/1), AVCC length-size:u8 (=4), reserved:u16 (=0),
//! width:u32, height:u32, sequence:u64, capture timestamp in microseconds:u64,
//! SPS length:u32, PPS length:u32, AVCC length:u32; then SPS, PPS, AVCC.
//! Every packet carries its configuration; only IDR packets restart a chain.

use crate::{Error, Result};
use std::ops::Range;

pub(crate) const HEADER_BYTES: usize = 44;
pub(crate) const MAX_PACKET: usize = 12 * 1024 * 1024;
const MAGIC: &[u8; 4] = b"MLV1";
const MAX_PARAMETER_SET: usize = 4096;
const MAX_NALS: usize = 4096;

/// Even dimensions between 16 and 4096, at most one 4K UHD frame of pixels.
pub(crate) fn valid_dimensions(width: u32, height: u32) -> bool {
    (16..=4096).contains(&width)
        && (16..=4096).contains(&height)
        && width.is_multiple_of(2)
        && height.is_multiple_of(2)
        && u64::from(width) * u64::from(height) <= 3840 * 2160
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct VideoHeader {
    pub width: u32,
    pub height: u32,
    pub sequence: u64,
    pub timestamp_us: u64,
    pub keyframe: bool,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct VideoFrame<'a> {
    pub header: VideoHeader,
    pub sps: &'a [u8],
    pub pps: &'a [u8],
    pub avcc: &'a [u8],
}

/// A validated packet whose components are ranges within the received bytes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct VideoPacket {
    pub header: VideoHeader,
    pub sps: Range<usize>,
    pub pps: Range<usize>,
    pub avcc: Range<usize>,
}

impl VideoFrame<'_> {
    pub(crate) fn encoded_len(&self) -> usize {
        HEADER_BYTES + self.sps.len() + self.pps.len() + self.avcc.len()
    }

    /// Configuration arrives only in the bounded SPS/PPS fields: in-band
    /// parameter sets could change dimensions after validation.
    pub(crate) fn validate(&self) -> Result<()> {
        let header = &self.header;
        if !valid_dimensions(header.width, header.height)
            || !(1..=MAX_PARAMETER_SET).contains(&self.sps.len())
            || !(1..=MAX_PARAMETER_SET).contains(&self.pps.len())
            || self.sps[0] & 0x1f != 7
            || self.pps[0] & 0x1f != 8
            || self.avcc.is_empty()
            || self.encoded_len() > MAX_PACKET
        {
            return Err(Error::Invalid);
        }
        let (mut offset, mut nals, mut idr, mut slice) = (0, 0, false, false);
        while offset < self.avcc.len() {
            if self.avcc.len() - offset < 4 || nals >= MAX_NALS {
                return Err(Error::Invalid);
            }
            let size =
                u32::from_be_bytes(self.avcc[offset..offset + 4].try_into().unwrap()) as usize;
            offset += 4;
            if size == 0 || size > self.avcc.len() - offset || self.avcc[offset] & 0x80 != 0 {
                return Err(Error::Invalid);
            }
            let kind = self.avcc[offset] & 0x1f;
            if ![1, 5, 6, 9, 12].contains(&kind) {
                return Err(Error::Invalid);
            }
            idr |= kind == 5;
            slice |= kind == 1 || kind == 5;
            offset += size;
            nals += 1;
        }
        if !slice || idr != header.keyframe {
            return Err(Error::Invalid);
        }
        Ok(())
    }

    pub(crate) fn encode(&self) -> Result<Vec<u8>> {
        self.validate()?;
        let header = &self.header;
        let mut bytes = Vec::with_capacity(self.encoded_len());
        bytes.extend_from_slice(MAGIC);
        bytes.extend_from_slice(&[header.keyframe.into(), 4, 0, 0]);
        bytes.extend_from_slice(&header.width.to_be_bytes());
        bytes.extend_from_slice(&header.height.to_be_bytes());
        bytes.extend_from_slice(&header.sequence.to_be_bytes());
        bytes.extend_from_slice(&header.timestamp_us.to_be_bytes());
        for part in [self.sps, self.pps, self.avcc] {
            bytes.extend_from_slice(&(part.len() as u32).to_be_bytes());
        }
        for part in [self.sps, self.pps, self.avcc] {
            bytes.extend_from_slice(part);
        }
        Ok(bytes)
    }
}

impl VideoPacket {
    /// Any malformed authenticated video packet is a protocol violation.
    pub(crate) fn parse(bytes: &[u8]) -> Result<Self> {
        if bytes.len() < HEADER_BYTES
            || bytes.len() > MAX_PACKET
            || &bytes[..4] != MAGIC
            || bytes[4] > 1
            || bytes[5] != 4
            || bytes[6..8] != [0, 0]
        {
            return Err(Error::Protocol);
        }
        let word = |start: usize| u32::from_be_bytes(bytes[start..start + 4].try_into().unwrap());
        let long = |start: usize| u64::from_be_bytes(bytes[start..start + 8].try_into().unwrap());
        let header = VideoHeader {
            width: word(8),
            height: word(12),
            sequence: long(16),
            timestamp_us: long(24),
            keyframe: bytes[4] == 1,
        };
        let (sps, pps, avcc) = (word(32) as usize, word(36) as usize, word(40) as usize);
        let sps = HEADER_BYTES..HEADER_BYTES.checked_add(sps).ok_or(Error::Protocol)?;
        let pps = sps.end..sps.end.checked_add(pps).ok_or(Error::Protocol)?;
        let avcc = pps.end..pps.end.checked_add(avcc).ok_or(Error::Protocol)?;
        if avcc.end != bytes.len() {
            return Err(Error::Protocol);
        }
        VideoFrame {
            header,
            sps: &bytes[sps.clone()],
            pps: &bytes[pps.clone()],
            avcc: &bytes[avcc.clone()],
        }
        .validate()
        .map_err(|_| Error::Protocol)?;
        Ok(Self {
            header,
            sps,
            pps,
            avcc,
        })
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub(crate) const SPS: &[u8] = &[0x67, 0x64, 0x00, 0x28];
    pub(crate) const PPS: &[u8] = &[0x68, 0xee, 0x3c, 0x80];
    /// AUD + SEI + one IDR slice, each with a four-byte length prefix.
    pub(crate) const IDR: &[u8] = &[
        0, 0, 0, 2, 0x09, 0x10, 0, 0, 0, 2, 0x06, 0x05, 0, 0, 0, 3, 0x65, 0x88, 0x84,
    ];
    pub(crate) const P_SLICE: &[u8] = &[0, 0, 0, 3, 0x41, 0x9a, 0x02];

    pub(crate) fn frame(avcc: &[u8], keyframe: bool) -> VideoFrame<'_> {
        VideoFrame {
            header: VideoHeader {
                width: 1920,
                height: 1080,
                sequence: 7,
                timestamp_us: 123_456,
                keyframe,
            },
            sps: SPS,
            pps: PPS,
            avcc,
        }
    }

    #[test]
    fn packets_round_trip_with_exact_component_ranges() {
        for (avcc, keyframe) in [(IDR, true), (P_SLICE, false)] {
            let original = frame(avcc, keyframe);
            let bytes = original.encode().unwrap();
            assert_eq!(bytes.len(), original.encoded_len());
            let packet = VideoPacket::parse(&bytes).unwrap();
            assert_eq!(packet.header, original.header);
            assert_eq!(&bytes[packet.sps], SPS);
            assert_eq!(&bytes[packet.pps], PPS);
            assert_eq!(&bytes[packet.avcc], avcc);
        }
    }

    #[test]
    fn dimension_rules_match_the_hardware_codec_bounds() {
        for (width, height) in [(16, 16), (3840, 2160), (4096, 1080), (2160, 3840)] {
            assert!(valid_dimensions(width, height));
        }
        for (width, height) in [
            (0, 1080),
            (15, 16),
            (1921, 1080),
            (1920, 1081),
            (4098, 1080),
            (4096, 4096),
            (u32::MAX, 2),
        ] {
            assert!(!valid_dimensions(width, height));
        }
    }

    #[test]
    fn local_frames_reject_invalid_configuration_and_bitstreams() {
        let in_band_sps = [0, 0, 0, 2, 0x67, 0x64, 0, 0, 0, 2, 0x65, 0x88];
        let forbidden_bit = [0, 0, 0, 2, 0xe5, 0x88];
        let empty_nal = [0, 0, 0, 0, 0, 0, 0, 2, 0x65, 0x88];
        let overrun = [0, 0, 0, 9, 0x65, 0x88];
        let short_prefix = [0, 0, 0, 2, 0x65, 0x88, 0, 0];
        let sei_only = [0, 0, 0, 2, 0x06, 0x05];
        let cases: Vec<VideoFrame<'_>> = vec![
            frame(IDR, false),    // forged keyframe flag
            frame(P_SLICE, true), // keyframe flag without an IDR
            frame(&in_band_sps, true),
            frame(&forbidden_bit, true),
            frame(&empty_nal, true),
            frame(&overrun, true),
            frame(&short_prefix, true),
            frame(&sei_only, false),
            frame(&[], false),
            VideoFrame {
                sps: &[],
                ..frame(IDR, true)
            },
            VideoFrame {
                pps: &[0x67],
                ..frame(IDR, true)
            },
            VideoFrame {
                sps: &[0x68],
                ..frame(IDR, true)
            },
            VideoFrame {
                sps: &[0x67; MAX_PARAMETER_SET + 1],
                ..frame(IDR, true)
            },
            VideoFrame {
                header: VideoHeader {
                    width: 1921,
                    ..frame(IDR, true).header
                },
                ..frame(IDR, true)
            },
        ];
        for invalid in cases {
            assert_eq!(invalid.validate(), Err(Error::Invalid));
            assert!(invalid.encode().is_err());
        }
        let oversized = vec![0x41; MAX_PACKET];
        let mut avcc = (oversized.len() as u32 - 4).to_be_bytes().to_vec();
        avcc.extend_from_slice(&oversized[4..]);
        assert!(frame(&avcc, false).validate().is_err());
    }

    #[test]
    fn received_packets_reject_malformed_headers() {
        let valid = frame(IDR, true).encode().unwrap();
        let mut cases = vec![
            vec![],
            vec![0; HEADER_BYTES],
            valid[..valid.len() - 1].to_vec(),
            [&valid[..], &[0]].concat(),
        ];
        for (index, value) in [(0, b'X'), (4, 2), (5, 2), (6, 1), (7, 1), (8, 0x7f), (4, 0)] {
            let mut bytes = valid.clone();
            bytes[index] = value;
            cases.push(bytes);
        }
        let mut huge_length = valid.clone();
        huge_length[40..44].copy_from_slice(&u32::MAX.to_be_bytes());
        cases.push(huge_length);
        cases.push(vec![0; MAX_PACKET + 1]);
        for bytes in cases {
            assert_eq!(VideoPacket::parse(&bytes), Err(Error::Protocol));
        }
    }
}

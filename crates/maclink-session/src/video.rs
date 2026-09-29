//! One bounded access unit, H.264 or HEVC. Integers use network byte order.
//!
//! H.264 (MLV1, 44-byte header): flags:u8 (keyframe 0/1), length-size:u8 (=4),
//! reserved:u16 (=0), width:u32, height:u32, sequence:u64, capture timestamp
//! in microseconds:u64, SPS length:u32, PPS length:u32, data length:u32; then
//! SPS, PPS, data.
//!
//! HEVC (MLV2, 48-byte header): as MLV1, with a VPS length:u32 before the SPS
//! length, and the VPS before the SPS. Sent only to viewers that declared they
//! decode HEVC 4:4:4.
//!
//! Every packet carries its configuration; only key packets restart a chain.

use crate::{Error, Result};
use std::ops::Range;

pub(crate) const HEADER_BYTES: usize = 44;
const HEVC_HEADER_BYTES: usize = 48;
pub(crate) const MAX_PACKET: usize = 12 * 1024 * 1024;
const MAGIC: &[u8; 4] = b"MLV1";
const HEVC_MAGIC: &[u8; 4] = b"MLV2";

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum Codec {
    #[default]
    H264,
    Hevc,
}
impl Codec {
    pub(crate) fn from_raw(value: u8) -> Result<Self> {
        match value {
            0 | 1 => Ok(Self::H264),
            2 => Ok(Self::Hevc),
            _ => Err(Error::Invalid),
        }
    }
    pub(crate) fn raw(self) -> u8 {
        match self {
            Self::H264 => 1,
            Self::Hevc => 2,
        }
    }
}
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
    pub codec: Codec,
    pub width: u32,
    pub height: u32,
    pub sequence: u64,
    pub timestamp_us: u64,
    pub keyframe: bool,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct VideoFrame<'a> {
    pub header: VideoHeader,
    /// HEVC only; empty for H.264.
    pub vps: &'a [u8],
    pub sps: &'a [u8],
    pub pps: &'a [u8],
    pub avcc: &'a [u8],
}

/// A validated packet whose components are ranges within the received bytes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct VideoPacket {
    pub header: VideoHeader,
    pub vps: Range<usize>,
    pub sps: Range<usize>,
    pub pps: Range<usize>,
    pub avcc: Range<usize>,
}

impl VideoFrame<'_> {
    pub(crate) fn encoded_len(&self) -> usize {
        let header = match self.header.codec {
            Codec::H264 => HEADER_BYTES,
            Codec::Hevc => HEVC_HEADER_BYTES,
        };
        header + self.vps.len() + self.sps.len() + self.pps.len() + self.avcc.len()
    }

    /// Configuration arrives only in the bounded parameter-set fields: in-band
    /// parameter sets could change dimensions after validation.
    pub(crate) fn validate(&self) -> Result<()> {
        match self.header.codec {
            Codec::H264 => self.validate_h264(),
            Codec::Hevc => self.validate_hevc(),
        }
    }

    fn validate_h264(&self) -> Result<()> {
        let header = &self.header;
        if !self.vps.is_empty()
            || !valid_dimensions(header.width, header.height)
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

    /// HEVC NAL headers are two bytes: forbidden bit, six-bit type, layer
    /// and temporal ID. Parameter sets arrive only out of band; key packets
    /// carry an IRAP picture and others none.
    fn validate_hevc(&self) -> Result<()> {
        let header = &self.header;
        let parameter_set = |part: &[u8], kind: u8| {
            (3..=MAX_PARAMETER_SET).contains(&part.len()) && hevc_nal_type(part) == Some(kind)
        };
        if !valid_dimensions(header.width, header.height)
            || !parameter_set(self.vps, 32)
            || !parameter_set(self.sps, 33)
            || !parameter_set(self.pps, 34)
            || self.avcc.is_empty()
            || self.encoded_len() > MAX_PACKET
        {
            return Err(Error::Invalid);
        }
        let (mut offset, mut nals, mut irap, mut slice) = (0, 0, false, false);
        while offset < self.avcc.len() {
            if self.avcc.len() - offset < 4 || nals >= MAX_NALS {
                return Err(Error::Invalid);
            }
            let size =
                u32::from_be_bytes(self.avcc[offset..offset + 4].try_into().unwrap()) as usize;
            offset += 4;
            if size < 2 || size > self.avcc.len() - offset {
                return Err(Error::Invalid);
            }
            // VCL types 0-9 and 16-21 (IRAP), access unit delimiter and SEI.
            let kind = hevc_nal_type(&self.avcc[offset..offset + size]).ok_or(Error::Invalid)?;
            if !matches!(kind, 0..=9 | 16..=21 | 35 | 39 | 40) {
                return Err(Error::Invalid);
            }
            irap |= (16..=21).contains(&kind);
            slice |= kind <= 21;
            offset += size;
            nals += 1;
        }
        if !slice || irap != header.keyframe {
            return Err(Error::Invalid);
        }
        Ok(())
    }

    pub(crate) fn encode(&self) -> Result<Vec<u8>> {
        self.validate()?;
        let header = &self.header;
        let mut bytes = Vec::with_capacity(self.encoded_len());
        let parts: &[&[u8]] = match header.codec {
            Codec::H264 => {
                bytes.extend_from_slice(MAGIC);
                &[self.sps, self.pps, self.avcc]
            }
            Codec::Hevc => {
                bytes.extend_from_slice(HEVC_MAGIC);
                &[self.vps, self.sps, self.pps, self.avcc]
            }
        };
        bytes.extend_from_slice(&[header.keyframe.into(), 4, 0, 0]);
        bytes.extend_from_slice(&header.width.to_be_bytes());
        bytes.extend_from_slice(&header.height.to_be_bytes());
        bytes.extend_from_slice(&header.sequence.to_be_bytes());
        bytes.extend_from_slice(&header.timestamp_us.to_be_bytes());
        for part in parts {
            bytes.extend_from_slice(&(part.len() as u32).to_be_bytes());
        }
        for part in parts {
            bytes.extend_from_slice(part);
        }
        Ok(bytes)
    }
}

/// The NAL unit type of an HEVC NAL, if its two-byte header is well formed:
/// forbidden bit clear, layer 0 and a non-zero temporal ID.
fn hevc_nal_type(nal: &[u8]) -> Option<u8> {
    let (&first, &second) = (nal.first()?, nal.get(1)?);
    let layer = ((first & 0x01) << 5) | (second >> 3);
    (first & 0x80 == 0 && layer == 0 && second & 0x07 != 0).then_some((first >> 1) & 0x3f)
}

/// Reads chroma_format_idc from an HEVC SPS: 1 is 4:2:0, 2 is 4:2:2 and 3 is
/// 4:4:4. None when the SPS uses sub-layers or is malformed. Used to confirm
/// the encoder really produced 4:4:4 rather than trusting the requested profile.
pub(crate) fn hevc_chroma_format(sps: &[u8]) -> Option<u32> {
    if hevc_nal_type(sps)? != 33 {
        return None;
    }
    // Remove emulation-prevention bytes (00 00 03) from the payload.
    let mut rbsp = Vec::with_capacity(sps.len());
    let mut zeros = 0;
    for &byte in &sps[2..] {
        if zeros >= 2 && byte == 3 {
            zeros = 0;
            continue;
        }
        zeros = if byte == 0 { zeros + 1 } else { 0 };
        rbsp.push(byte);
    }
    // vps_id(4) max_sub_layers_minus1(3) temporal_id_nesting(1), then a
    // 12-byte profile_tier_level when there are no sub-layers.
    if (rbsp.first()? >> 1) & 0x07 != 0 || rbsp.len() < 14 {
        return None;
    }
    let mut bits = BitReader {
        bytes: &rbsp[13..],
        position: 0,
    };
    bits.exp_golomb()?; // sps_seq_parameter_set_id
    bits.exp_golomb()
}

struct BitReader<'a> {
    bytes: &'a [u8],
    position: usize,
}
impl BitReader<'_> {
    fn bit(&mut self) -> Option<u32> {
        let byte = *self.bytes.get(self.position / 8)?;
        let value = (byte >> (7 - self.position % 8)) & 1;
        self.position += 1;
        Some(value.into())
    }
    fn exp_golomb(&mut self) -> Option<u32> {
        let mut zeros = 0;
        while self.bit()? == 0 {
            zeros += 1;
            if zeros > 31 {
                return None;
            }
        }
        let mut value = 1_u64;
        for _ in 0..zeros {
            value = (value << 1) | u64::from(self.bit()?);
        }
        u32::try_from(value - 1).ok()
    }
}

impl VideoPacket {
    /// Any malformed authenticated video packet is a protocol violation.
    pub(crate) fn parse(bytes: &[u8]) -> Result<Self> {
        let codec = match bytes.get(..4) {
            Some(magic) if magic == MAGIC => Codec::H264,
            Some(magic) if magic == HEVC_MAGIC => Codec::Hevc,
            _ => return Err(Error::Protocol),
        };
        let header_bytes = if codec == Codec::Hevc {
            HEVC_HEADER_BYTES
        } else {
            HEADER_BYTES
        };
        if bytes.len() < header_bytes
            || bytes.len() > MAX_PACKET
            || bytes[4] > 1
            || bytes[5] != 4
            || bytes[6..8] != [0, 0]
        {
            return Err(Error::Protocol);
        }
        let word =
            |start: usize| u32::from_be_bytes(bytes[start..start + 4].try_into().unwrap()) as usize;
        let long = |start: usize| u64::from_be_bytes(bytes[start..start + 8].try_into().unwrap());
        let header = VideoHeader {
            codec,
            width: word(8) as u32,
            height: word(12) as u32,
            sequence: long(16),
            timestamp_us: long(24),
            keyframe: bytes[4] == 1,
        };
        let lengths = if codec == Codec::Hevc {
            [word(32), word(36), word(40), word(44)]
        } else {
            [0, word(32), word(36), word(40)]
        };
        let mut start = header_bytes;
        let mut ranges = [0..0, 0..0, 0..0, 0..0];
        for (range, length) in ranges.iter_mut().zip(lengths) {
            let end = start.checked_add(length).ok_or(Error::Protocol)?;
            *range = start..end;
            start = end;
        }
        let [vps, sps, pps, avcc] = ranges;
        if avcc.end != bytes.len() {
            return Err(Error::Protocol);
        }
        VideoFrame {
            header,
            vps: &bytes[vps.clone()],
            sps: &bytes[sps.clone()],
            pps: &bytes[pps.clone()],
            avcc: &bytes[avcc.clone()],
        }
        .validate()
        .map_err(|_| Error::Protocol)?;
        Ok(Self {
            header,
            vps,
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
                codec: Codec::H264,
                width: 1920,
                height: 1080,
                sequence: 7,
                timestamp_us: 123_456,
                keyframe,
            },
            vps: &[],
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

    pub(crate) const VPS: &[u8] = &[0x40, 0x01, 0x0c, 0x01];
    /// An HEVC SPS for 4:4:4 (Rext profile), no sub-layers.
    pub(crate) const HEVC_SPS: &[u8] = &[
        0x42, 0x01, 0x01, 0x04, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x5d, 0x90, 0x80,
    ];
    pub(crate) const HEVC_PPS: &[u8] = &[0x44, 0x01, 0xc1];
    /// AUD + prefix SEI + one IDR_W_RADL slice.
    pub(crate) const HEVC_IDR: &[u8] = &[
        0, 0, 0, 3, 0x46, 0x01, 0x50, 0, 0, 0, 3, 0x4e, 0x01, 0x05, 0, 0, 0, 4, 0x26, 0x01, 0xaf,
        0x10,
    ];
    pub(crate) const HEVC_P: &[u8] = &[0, 0, 0, 4, 0x02, 0x01, 0xd0, 0x08];

    pub(crate) fn hevc_frame(data: &[u8], keyframe: bool) -> VideoFrame<'_> {
        VideoFrame {
            header: VideoHeader {
                codec: Codec::Hevc,
                ..frame(data, keyframe).header
            },
            vps: VPS,
            sps: HEVC_SPS,
            pps: HEVC_PPS,
            avcc: data,
        }
    }

    #[test]
    fn hevc_packets_round_trip_with_their_parameter_sets() {
        for (data, keyframe) in [(HEVC_IDR, true), (HEVC_P, false)] {
            let original = hevc_frame(data, keyframe);
            let bytes = original.encode().unwrap();
            assert_eq!(&bytes[..4], b"MLV2");
            assert_eq!(bytes.len(), original.encoded_len());
            let packet = VideoPacket::parse(&bytes).unwrap();
            assert_eq!(packet.header, original.header);
            assert_eq!(&bytes[packet.vps], VPS);
            assert_eq!(&bytes[packet.sps], HEVC_SPS);
            assert_eq!(&bytes[packet.pps], HEVC_PPS);
            assert_eq!(&bytes[packet.avcc], data);
        }
        // H.264 keeps the MLV1 format earlier previews read.
        let h264 = frame(IDR, true).encode().unwrap();
        assert_eq!(&h264[..4], b"MLV1");
        assert_eq!(
            VideoPacket::parse(&h264).unwrap().vps,
            HEADER_BYTES..HEADER_BYTES
        );
    }

    #[test]
    fn hevc_frames_reject_invalid_configuration_and_bitstreams() {
        let in_band_sps = [
            0, 0, 0, 3, 0x42, 0x01, 0x01, 0, 0, 0, 4, 0x26, 0x01, 0xaf, 0x10,
        ];
        let forbidden = [0, 0, 0, 3, 0xa6, 0x01, 0xaf];
        let layer = [0, 0, 0, 3, 0x26, 0x09, 0xaf];
        let temporal_zero = [0, 0, 0, 3, 0x26, 0x00, 0xaf];
        let reserved_type = [0, 0, 0, 3, 0x30, 0x01, 0xaf]; // type 24
        let sei_only = [0, 0, 0, 3, 0x4e, 0x01, 0x05];
        let one_byte = [0, 0, 0, 1, 0x26];
        let cases = [
            hevc_frame(HEVC_IDR, false),
            hevc_frame(HEVC_P, true),
            hevc_frame(&in_band_sps, true),
            hevc_frame(&forbidden, true),
            hevc_frame(&layer, true),
            hevc_frame(&temporal_zero, true),
            hevc_frame(&reserved_type, false),
            hevc_frame(&sei_only, false),
            hevc_frame(&one_byte, true),
            hevc_frame(&[], false),
            VideoFrame {
                vps: &[],
                ..hevc_frame(HEVC_IDR, true)
            },
            VideoFrame {
                vps: HEVC_SPS,
                ..hevc_frame(HEVC_IDR, true)
            },
            VideoFrame {
                sps: HEVC_PPS,
                ..hevc_frame(HEVC_IDR, true)
            },
            VideoFrame {
                pps: &[0x44, 0x01],
                ..hevc_frame(HEVC_IDR, true)
            },
            VideoFrame {
                vps: VPS,
                ..frame(IDR, true)
            }, // H.264 carries no VPS
        ];
        for invalid in cases {
            assert_eq!(invalid.validate(), Err(Error::Invalid), "{invalid:?}");
        }
        let valid = hevc_frame(HEVC_IDR, true).encode().unwrap();
        let mut bad_length = valid.clone();
        bad_length[44..48].copy_from_slice(&u32::MAX.to_be_bytes());
        let mut bad_magic = valid.clone();
        bad_magic[3] = b'3';
        for bytes in [
            valid[..HEVC_HEADER_BYTES - 1].to_vec(),
            bad_length,
            bad_magic,
        ] {
            assert_eq!(VideoPacket::parse(&bytes), Err(Error::Protocol));
        }
    }

    #[test]
    fn hevc_chroma_format_is_read_from_the_sps() {
        assert_eq!(hevc_chroma_format(HEVC_SPS), Some(3));
        let mut four_two_zero = HEVC_SPS.to_vec();
        four_two_zero[3] = 0x01; // Main profile
        four_two_zero[15] = 0xa0; // ue(0) then ue(1)
        assert_eq!(hevc_chroma_format(&four_two_zero), Some(1));
        // An emulation-prevention byte inside the profile is skipped.
        let mut escaped = HEVC_SPS[..4].to_vec();
        escaped.extend_from_slice(&[0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0x5d, 0x90, 0x80]);
        assert_eq!(hevc_chroma_format(&escaped), Some(3));
        let mut sub_layers = HEVC_SPS.to_vec();
        sub_layers[2] = 0x03; // max_sub_layers_minus1 = 1
        assert_eq!(hevc_chroma_format(&sub_layers), None);
        assert_eq!(hevc_chroma_format(HEVC_PPS), None);
        assert_eq!(hevc_chroma_format(&HEVC_SPS[..10]), None);
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

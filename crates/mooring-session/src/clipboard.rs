//! Shared clipboard: up to three representations of one copied item (plain
//! text, RTF and PNG), sent by either Mac while a session is connected. Rust
//! validates kinds, order, sizes and signatures on send and receive. Swift
//! reads and writes the pasteboard, and never sends items marked concealed or
//! transient.
//!
//! Wire format: `[version=1, count, 0, 0]`, then `count` entries of
//! `[kind, 0, 0, 0, length: u32 BE]`, then each representation's bytes in
//! entry order. Kinds are strictly ascending, so each appears at most once.

use crate::{Error, Result};
use std::ops::Range;

/// Total representation bytes in one clipboard message.
pub(crate) const MAX_CLIPBOARD_BYTES: usize = 4 * 1024 * 1024;
pub(crate) const MAX_ITEMS: usize = 3;
const VERSION: u8 = 1;
const PREFIX: usize = 4;
const ENTRY: usize = 8;
/// Largest encoded clipboard message.
pub(crate) const MAX_CLIPBOARD: usize = PREFIX + MAX_ITEMS * ENTRY + MAX_CLIPBOARD_BYTES;
const PNG_SIGNATURE: &[u8] = b"\x89PNG\r\n\x1a\n";

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
#[repr(u8)]
pub(crate) enum ClipboardKind {
    /// UTF-8 plain text.
    Text = 1,
    /// Rich Text Format.
    Rtf = 2,
    /// A PNG image.
    Png = 3,
}

impl ClipboardKind {
    pub(crate) fn from_raw(value: u8) -> Result<Self> {
        match value {
            1 => Ok(Self::Text),
            2 => Ok(Self::Rtf),
            3 => Ok(Self::Png),
            _ => Err(Error::Invalid),
        }
    }
    fn accepts(self, data: &[u8]) -> bool {
        match self {
            Self::Text => std::str::from_utf8(data).is_ok(),
            Self::Rtf => data.starts_with(b"{\\rtf"),
            Self::Png => data.starts_with(PNG_SIGNATURE),
        }
    }
}

/// One to three non-empty representations in ascending kind order, each with
/// its format's signature, totalling at most `MAX_CLIPBOARD_BYTES`.
pub(crate) fn validate<'a>(
    items: impl ExactSizeIterator<Item = (ClipboardKind, &'a [u8])>,
) -> Result<()> {
    if !(1..=MAX_ITEMS).contains(&items.len()) {
        return Err(Error::Invalid);
    }
    let mut previous: Option<ClipboardKind> = None;
    let mut total = 0_usize;
    for (kind, data) in items {
        total = total.checked_add(data.len()).ok_or(Error::Invalid)?;
        if data.is_empty()
            || total > MAX_CLIPBOARD_BYTES
            || previous.is_some_and(|last| last >= kind)
            || !kind.accepts(data)
        {
            return Err(Error::Invalid);
        }
        previous = Some(kind);
    }
    Ok(())
}

/// Validates and encodes representations for sending.
pub(crate) fn encode(items: &[(ClipboardKind, &[u8])]) -> Result<Vec<u8>> {
    validate(items.iter().map(|(kind, data)| (*kind, *data)))?;
    let body: usize = items.iter().map(|(_, data)| data.len()).sum();
    let mut out = Vec::with_capacity(PREFIX + items.len() * ENTRY + body);
    out.extend_from_slice(&[VERSION, items.len() as u8, 0, 0]);
    for (kind, data) in items {
        out.extend_from_slice(&[*kind as u8, 0, 0, 0]);
        out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    }
    for (_, data) in items {
        out.extend_from_slice(data);
    }
    Ok(out)
}

/// A received clipboard message; ranges index the caller's receive buffer.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ClipboardPacket {
    pub(crate) items: Vec<(ClipboardKind, Range<usize>)>,
}

impl ClipboardPacket {
    pub(crate) fn parse(data: &[u8]) -> Result<Self> {
        let malformed = || Error::Protocol;
        if data.len() < PREFIX || data[0] != VERSION || data[2..4] != [0, 0] {
            return Err(malformed());
        }
        let count = usize::from(data[1]);
        let table_end = PREFIX + count * ENTRY;
        if !(1..=MAX_ITEMS).contains(&count) || data.len() < table_end {
            return Err(malformed());
        }
        let mut items = Vec::with_capacity(count);
        let mut offset = table_end;
        for entry in data[PREFIX..table_end].as_chunks::<ENTRY>().0 {
            let kind = ClipboardKind::from_raw(entry[0]).map_err(|_| malformed())?;
            let length = u32::from_be_bytes([entry[4], entry[5], entry[6], entry[7]]) as usize;
            let end = offset.checked_add(length).ok_or_else(malformed)?;
            if entry[1..4] != [0, 0, 0] || end > data.len() {
                return Err(malformed());
            }
            items.push((kind, offset..end));
            offset = end;
        }
        if offset != data.len() {
            return Err(malformed());
        }
        validate(
            items
                .iter()
                .map(|(kind, range)| (*kind, &data[range.clone()])),
        )
        .map_err(|_| malformed())?;
        Ok(Self { items })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PNG: &[u8] = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR";
    const RTF: &[u8] = b"{\\rtf1\\ansi hello}";

    #[test]
    fn representations_round_trip_in_kind_order() {
        let items = [
            (ClipboardKind::Text, "héllo".as_bytes()),
            (ClipboardKind::Rtf, RTF),
            (ClipboardKind::Png, PNG),
        ];
        let wire = encode(&items).unwrap();
        let packet = ClipboardPacket::parse(&wire).unwrap();
        let decoded: Vec<_> = packet
            .items
            .iter()
            .map(|(kind, range)| (*kind, &wire[range.clone()]))
            .collect();
        assert_eq!(decoded, items);
        let text_only = encode(&[(ClipboardKind::Text, b"x")]).unwrap();
        assert_eq!(text_only, [1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, b'x']);
    }

    #[test]
    fn senders_cannot_encode_unsafe_or_oversized_sets() {
        let text = |data: &'static [u8]| (ClipboardKind::Text, data);
        for items in [
            vec![],
            vec![text(b"")],
            vec![text(b"\xff\xfe")],
            vec![(ClipboardKind::Rtf, b"plain".as_slice())],
            vec![(ClipboardKind::Png, b"GIF89a".as_slice())],
            vec![text(b"a"), text(b"b")],
            vec![(ClipboardKind::Png, PNG), text(b"a")],
            vec![
                text(b"a"),
                (ClipboardKind::Rtf, RTF),
                (ClipboardKind::Png, PNG),
                text(b"b"),
            ],
        ] {
            assert_eq!(encode(&items), Err(Error::Invalid), "{items:?}");
        }
        let largest = vec![b'a'; MAX_CLIPBOARD_BYTES];
        assert_eq!(
            encode(&[(ClipboardKind::Text, &largest)]).unwrap().len(),
            PREFIX + ENTRY + MAX_CLIPBOARD_BYTES
        );
        let over = vec![b'a'; MAX_CLIPBOARD_BYTES - PNG.len() + 1];
        assert_eq!(
            encode(&[(ClipboardKind::Text, &over), (ClipboardKind::Png, PNG)]),
            Err(Error::Invalid)
        );
        assert_eq!(ClipboardKind::from_raw(0), Err(Error::Invalid));
        assert_eq!(ClipboardKind::from_raw(4), Err(Error::Invalid));
    }

    #[test]
    fn malformed_messages_are_protocol_errors() {
        let good = encode(&[(ClipboardKind::Text, b"ab"), (ClipboardKind::Png, PNG)]).unwrap();
        let mutate = |index: usize, value: u8| {
            let mut copy = good.clone();
            copy[index] = value;
            copy
        };
        let mut trailing = good.clone();
        trailing.push(0);
        let mut short = good.clone();
        short.pop();
        for data in [
            vec![],
            good[..3].to_vec(),
            mutate(0, 2),     // version
            mutate(1, 0),     // no items
            mutate(1, 4),     // too many
            mutate(2, 1),     // reserved
            mutate(4, 9),     // unknown kind
            mutate(5, 1),     // entry reserved
            mutate(11, 3),    // length past the end
            mutate(12, 1),    // a second Text entry
            mutate(20, 0xff), // invalid UTF-8
            mutate(22, b'X'), // PNG signature
            trailing,
            short,
        ] {
            assert_eq!(
                ClipboardPacket::parse(&data),
                Err(Error::Protocol),
                "{data:?}"
            );
        }
    }
}

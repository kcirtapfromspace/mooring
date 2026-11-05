//! Mac keyboard events to X11 keysyms, and the held-key state that makes
//! every key-up match its key-down.
//!
//! Special keys come from the Mac virtual key code; other keys from the
//! characters the key produces without modifiers other than Shift. Command
//! is sent as Super (the Hyprland and Omarchy modifier), Option as Alt.

use std::collections::BTreeMap;

pub mod x {
    pub const BACKSPACE: u32 = 0xff08;
    pub const TAB: u32 = 0xff09;
    pub const RETURN: u32 = 0xff0d;
    pub const ESCAPE: u32 = 0xff1b;
    pub const HOME: u32 = 0xff50;
    pub const LEFT: u32 = 0xff51;
    pub const UP: u32 = 0xff52;
    pub const RIGHT: u32 = 0xff53;
    pub const DOWN: u32 = 0xff54;
    pub const PAGE_UP: u32 = 0xff55;
    pub const PAGE_DOWN: u32 = 0xff56;
    pub const END: u32 = 0xff57;
    pub const INSERT: u32 = 0xff63;
    pub const KP_ENTER: u32 = 0xff8d;
    pub const F1: u32 = 0xffbe;
    pub const SHIFT_L: u32 = 0xffe1;
    pub const SHIFT_R: u32 = 0xffe2;
    pub const CONTROL_L: u32 = 0xffe3;
    pub const CONTROL_R: u32 = 0xffe4;
    pub const CAPS_LOCK: u32 = 0xffe5;
    pub const ALT_L: u32 = 0xffe9;
    pub const ALT_R: u32 = 0xffea;
    pub const SUPER_L: u32 = 0xffeb;
    pub const SUPER_R: u32 = 0xffec;
    pub const DELETE: u32 = 0xffff;
    pub const SPACE: u32 = 0x0020;
}

/// The keysym for a Mac virtual key code that has a fixed meaning.
pub fn special_key(code: u16) -> Option<u32> {
    let function = |n: u32| Some(x::F1 + n - 1);
    match code {
        0x24 => Some(x::RETURN),
        0x30 => Some(x::TAB),
        0x31 => Some(x::SPACE),
        0x33 => Some(x::BACKSPACE),
        0x35 => Some(x::ESCAPE),
        0x37 => Some(x::SUPER_L),
        0x36 => Some(x::SUPER_R),
        0x38 => Some(x::SHIFT_L),
        0x3c => Some(x::SHIFT_R),
        0x39 => Some(x::CAPS_LOCK),
        0x3a => Some(x::ALT_L),
        0x3d => Some(x::ALT_R),
        0x3b => Some(x::CONTROL_L),
        0x3e => Some(x::CONTROL_R),
        0x4c => Some(x::KP_ENTER),
        0x72 => Some(x::INSERT),
        0x73 => Some(x::HOME),
        0x74 => Some(x::PAGE_UP),
        0x75 => Some(x::DELETE),
        0x77 => Some(x::END),
        0x79 => Some(x::PAGE_DOWN),
        0x7b => Some(x::LEFT),
        0x7c => Some(x::RIGHT),
        0x7d => Some(x::DOWN),
        0x7e => Some(x::UP),
        0x7a => function(1),
        0x78 => function(2),
        0x63 => function(3),
        0x76 => function(4),
        0x60 => function(5),
        0x61 => function(6),
        0x62 => function(7),
        0x64 => function(8),
        0x65 => function(9),
        0x6d => function(10),
        0x67 => function(11),
        0x6f => function(12),
        0x69 => function(13),
        0x6b => function(14),
        0x71 => function(15),
        0x6a => function(16),
        0x40 => function(17),
        0x4f => function(18),
        0x50 => function(19),
        0x5a => function(20),
        _ => None,
    }
}

/// Whether the key code is a modifier, which the Mac reports as a flag change.
pub fn is_modifier(code: u16) -> bool {
    matches!(code, 0x36..=0x3e)
}

/// The keysym for a character: Latin-1 maps directly, other Unicode to
/// 0x01000000 + code point. Control characters have no keysym here.
pub fn char_keysym(c: char) -> Option<u32> {
    let code = u32::from(c);
    match code {
        0x20..=0x7e | 0xa0..=0xff => Some(code),
        0x100..=0x10_ffff => Some(0x0100_0000 + code),
        _ => None,
    }
}

/// The keysym for a key event, preferring the key code's fixed meaning.
pub fn keysym_for(code: u16, characters: &str) -> Option<u32> {
    if let Some(keysym) = special_key(code) {
        return Some(keysym);
    }
    let mut chars = characters.chars();
    let first = chars.next()?;
    // A key that produces several characters (rare) has no single keysym.
    if chars.next().is_some() {
        return None;
    }
    char_keysym(first)
}

/// Keys held on the remote side, by Mac key code.
#[derive(Debug, Default)]
pub struct HeldKeys {
    held: BTreeMap<u16, u32>,
}

/// At most this many keys are tracked as held; more is not a real keyboard.
pub const MAX_HELD_KEYS: usize = 32;

impl HeldKeys {
    /// The keysym to send for this event, or `None` to send nothing. A key-up
    /// always sends the keysym its key-down sent, even if the characters
    /// changed in between (for example Shift was released first).
    pub fn event(&mut self, code: u16, characters: &str, down: bool) -> Option<(bool, u32)> {
        if down {
            if let Some(keysym) = self.held.get(&code) {
                // Key repeat: send it again, as a real keyboard would.
                return Some((true, *keysym));
            }
            if self.held.len() >= MAX_HELD_KEYS {
                return None;
            }
            let keysym = keysym_for(code, characters)?;
            self.held.insert(code, keysym);
            Some((true, keysym))
        } else {
            self.held.remove(&code).map(|keysym| (false, keysym))
        }
    }

    /// Key-ups for everything still held, for focus loss or disconnect.
    pub fn release_all(&mut self) -> Vec<u32> {
        let keysyms = self.held.values().copied().collect();
        self.held.clear();
        keysyms
    }

    pub fn is_empty(&self) -> bool {
        self.held.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn special_keys_and_modifiers_map_to_x_keysyms() {
        assert_eq!(keysym_for(0x24, "\r"), Some(x::RETURN));
        assert_eq!(keysym_for(0x33, "\u{7f}"), Some(x::BACKSPACE));
        assert_eq!(keysym_for(0x75, "\u{f728}"), Some(x::DELETE));
        assert_eq!(keysym_for(0x7e, "\u{f700}"), Some(x::UP));
        assert_eq!(keysym_for(0x37, ""), Some(x::SUPER_L));
        assert_eq!(keysym_for(0x3a, ""), Some(x::ALT_L));
        assert_eq!(keysym_for(0x7a, "\u{f704}"), Some(x::F1));
        assert_eq!(keysym_for(0x6f, ""), Some(x::F1 + 11));
        assert!(is_modifier(0x38) && is_modifier(0x37) && !is_modifier(0x24));
    }

    #[test]
    fn characters_map_to_latin1_or_unicode_keysyms() {
        assert_eq!(keysym_for(0x00, "a"), Some(0x61));
        assert_eq!(keysym_for(0x00, "A"), Some(0x41));
        assert_eq!(keysym_for(0x00, "é"), Some(0xe9));
        assert_eq!(keysym_for(0x00, "€"), Some(0x0100_20ac));
        assert_eq!(keysym_for(0x00, ""), None);
        assert_eq!(keysym_for(0x00, "\u{1}"), None);
        assert_eq!(keysym_for(0x00, "ab"), None);
    }

    #[test]
    fn key_ups_match_key_downs_and_nothing_stays_held() {
        let mut held = HeldKeys::default();
        assert_eq!(held.event(0x38, "", true), Some((true, x::SHIFT_L)));
        assert_eq!(held.event(0x00, "A", true), Some((true, 0x41)));
        // Shift is released before the letter: the letter's key-up is still A.
        assert_eq!(held.event(0x38, "", false), Some((false, x::SHIFT_L)));
        assert_eq!(held.event(0x00, "a", false), Some((false, 0x41)));
        // A key-up with no key-down sends nothing.
        assert_eq!(held.event(0x00, "a", false), None);
        // Repeat resends the held keysym.
        assert_eq!(held.event(0x01, "s", true), Some((true, 0x73)));
        assert_eq!(held.event(0x01, "S", true), Some((true, 0x73)));
        assert_eq!(held.event(0x37, "", true), Some((true, x::SUPER_L)));
        let mut released = held.release_all();
        released.sort();
        assert_eq!(released, [0x73, x::SUPER_L]);
        assert!(held.is_empty());
        for code in 0..MAX_HELD_KEYS as u16 + 5 {
            held.event(0x100 + code, "x", true);
        }
        assert_eq!(held.release_all().len(), MAX_HELD_KEYS);
    }
}

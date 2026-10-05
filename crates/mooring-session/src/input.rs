//! Remote input events and the host's bounded held-input state.
//!
//! Version 1 wire format, 44 bytes, big-endian: version:u8 (=1), kind:u8,
//! button:u8, click_count:u8, is_repeat:u8 (0/1), reserved:u8 (=0),
//! key_code:u16, modifiers:u32, x:f64, y:f64, delta_x:f64, delta_y:f64.
//! Coordinates are normalized with a top-left origin in the displayed image,
//! independent of Retina scaling. Fields a kind does not use must be zero.
//!
//! Trackpad gestures (protocol 5, to hosts that announce them): magnify and
//! rotate carry their phase in `button` (1 began, 2 changed, 4 ended, 8
//! cancelled) and their value in `delta_x` (magnification, or degrees); smart
//! magnify carries only a position.

use crate::{Error, Result};
use std::collections::{BTreeSet, HashMap};

pub(crate) const INPUT_BYTES: usize = 44;
pub(crate) const MODIFIERS: u32 = 0x3f; // shift, control, option, command, caps lock, function
/// 128 key codes, three buttons and one open gesture: the most one cleanup can release.
pub(crate) const MAX_RELEASES: usize = 132;
const MAGNIFY_LIMIT: f64 = 5.0;
const ROTATE_LIMIT: f64 = 360.0;
pub(crate) const PHASE_BEGAN: u8 = 1;
pub(crate) const PHASE_CHANGED: u8 = 2;
pub(crate) const PHASE_ENDED: u8 = 4;
pub(crate) const PHASE_CANCELLED: u8 = 8;
const MAX_KEY_CODE: u16 = 127;
const SCROLL_LIMIT: f64 = 1200.0;
const REPEAT_INTERVAL: f64 = 1.0 / 120.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub(crate) enum InputKind {
    KeyDown = 1,
    KeyUp = 2,
    PointerMove = 3,
    PointerDown = 4,
    PointerUp = 5,
    Scroll = 6,
    ReleaseAll = 7,
    Magnify = 8,
    Rotate = 9,
    SmartMagnify = 10,
}

impl InputKind {
    fn from_raw(value: u8) -> Result<Self> {
        Ok(match value {
            1 => Self::KeyDown,
            2 => Self::KeyUp,
            3 => Self::PointerMove,
            4 => Self::PointerDown,
            5 => Self::PointerUp,
            6 => Self::Scroll,
            7 => Self::ReleaseAll,
            8 => Self::Magnify,
            9 => Self::Rotate,
            10 => Self::SmartMagnify,
            _ => return Err(Error::Invalid),
        })
    }
    pub(crate) fn is_gesture(self) -> bool {
        matches!(self, Self::Magnify | Self::Rotate | Self::SmartMagnify)
    }
}

pub(crate) fn is_modifier_key(code: u16) -> bool {
    matches!(code, 54..=63)
}

/// While the viewer captures system shortcuts such as ⌘-Tab for the remote
/// Mac, these stay on the viewing Mac as an escape hatch: Force Quit (⌘⌥Esc,
/// with or without ⇧), Lock Screen (⌃⌘Q), full screen (⌃⌘F or Globe-F),
/// diagnostic footer (⌃⌘D), and stats (⌃⌘I).
/// Caps Lock is ignored.
pub(crate) fn keeps_local(key_code: u16, modifiers: u32) -> bool {
    const SHIFT: u32 = 1;
    const CONTROL: u32 = 2;
    const OPTION: u32 = 4;
    const COMMAND: u32 = 8;
    const FUNCTION: u32 = 32;
    let held = modifiers & (SHIFT | CONTROL | OPTION | COMMAND | FUNCTION);
    match key_code {
        53 => held == COMMAND | OPTION || held == COMMAND | OPTION | SHIFT, // Escape
        12 => held == CONTROL | COMMAND,                                    // Q
        3 => held == CONTROL | COMMAND || held == FUNCTION,                 // F
        2 | 34 => held == CONTROL | COMMAND,                                // D, I
        _ => false,
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct InputEvent {
    pub kind: InputKind,
    pub key_code: u16,
    pub button: u8,
    pub click_count: u8,
    pub is_repeat: bool,
    pub modifiers: u32,
    pub x: f64,
    pub y: f64,
    pub delta_x: f64,
    pub delta_y: f64,
}

impl InputEvent {
    fn empty(kind: InputKind) -> Self {
        Self {
            kind,
            key_code: 0,
            button: 0,
            click_count: 0,
            is_repeat: false,
            modifiers: 0,
            x: 0.0,
            y: 0.0,
            delta_x: 0.0,
            delta_y: 0.0,
        }
    }
    pub(crate) fn key(kind: InputKind, key_code: u16) -> Self {
        Self {
            key_code,
            ..Self::empty(kind)
        }
    }

    /// Strict constructor shared by the wire decoder and the C ABI.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn from_parts(
        kind: u8,
        key_code: u16,
        button: u8,
        click_count: u8,
        is_repeat: u8,
        modifiers: u32,
        position: (f64, f64),
        delta: (f64, f64),
    ) -> Result<Self> {
        let is_repeat = match is_repeat {
            0 => false,
            1 => true,
            _ => return Err(Error::Invalid),
        };
        let event = Self {
            kind: InputKind::from_raw(kind)?,
            key_code,
            button,
            click_count,
            is_repeat,
            modifiers,
            x: position.0,
            y: position.1,
            delta_x: delta.0,
            delta_y: delta.1,
        };
        event.validate()?;
        Ok(event)
    }

    fn validate(&self) -> Result<()> {
        let unit = |value: f64| value.is_finite() && (0.0..=1.0).contains(&value);
        let no_position = self.x == 0.0 && self.y == 0.0;
        let no_scroll = self.delta_x == 0.0 && self.delta_y == 0.0;
        let valid = self.modifiers & !MODIFIERS == 0
            && match self.kind {
                InputKind::KeyDown | InputKind::KeyUp => {
                    self.key_code <= MAX_KEY_CODE
                        && self.button == 0
                        && self.click_count == 0
                        && no_position
                        && no_scroll
                        && (!self.is_repeat
                            || (self.kind == InputKind::KeyDown && !is_modifier_key(self.key_code)))
                }
                InputKind::PointerMove
                | InputKind::PointerDown
                | InputKind::PointerUp
                | InputKind::Scroll => {
                    let buttons = match self.kind {
                        InputKind::PointerDown | InputKind::PointerUp => {
                            self.button <= 2 && (1..=3).contains(&self.click_count)
                        }
                        _ => self.button == 0 && self.click_count == 0,
                    };
                    let scroll = if self.kind == InputKind::Scroll {
                        [self.delta_x, self.delta_y]
                            .iter()
                            .all(|value| value.is_finite() && value.abs() <= SCROLL_LIMIT)
                    } else {
                        no_scroll
                    };
                    unit(self.x)
                        && unit(self.y)
                        && self.key_code == 0
                        && !self.is_repeat
                        && buttons
                        && scroll
                }
                InputKind::ReleaseAll => *self == Self::empty(InputKind::ReleaseAll),
                InputKind::Magnify | InputKind::Rotate => {
                    let limit = if self.kind == InputKind::Magnify {
                        MAGNIFY_LIMIT
                    } else {
                        ROTATE_LIMIT
                    };
                    unit(self.x)
                        && unit(self.y)
                        && self.key_code == 0
                        && !self.is_repeat
                        && self.click_count == 0
                        && [PHASE_BEGAN, PHASE_CHANGED, PHASE_ENDED, PHASE_CANCELLED]
                            .contains(&self.button)
                        && self.delta_x.is_finite()
                        && self.delta_x.abs() <= limit
                        && self.delta_y == 0.0
                }
                InputKind::SmartMagnify => {
                    unit(self.x)
                        && unit(self.y)
                        && self.key_code == 0
                        && !self.is_repeat
                        && self.button == 0
                        && self.click_count == 0
                        && no_scroll
                }
            };
        if valid { Ok(()) } else { Err(Error::Invalid) }
    }

    pub(crate) fn encode(&self) -> [u8; INPUT_BYTES] {
        let mut bytes = [0_u8; INPUT_BYTES];
        bytes[..5].copy_from_slice(&[
            1,
            self.kind as u8,
            self.button,
            self.click_count,
            self.is_repeat.into(),
        ]);
        bytes[6..8].copy_from_slice(&self.key_code.to_be_bytes());
        bytes[8..12].copy_from_slice(&self.modifiers.to_be_bytes());
        for (index, value) in [self.x, self.y, self.delta_x, self.delta_y]
            .into_iter()
            .enumerate()
        {
            let start = 12 + index * 8;
            bytes[start..start + 8].copy_from_slice(&value.to_bits().to_be_bytes());
        }
        bytes
    }

    /// Any malformed authenticated input event is a protocol violation.
    pub(crate) fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() != INPUT_BYTES || bytes[0] != 1 || bytes[5] != 0 {
            return Err(Error::Protocol);
        }
        let float = |start: usize| {
            f64::from_bits(u64::from_be_bytes(
                bytes[start..start + 8].try_into().unwrap(),
            ))
        };
        Self::from_parts(
            bytes[1],
            u16::from_be_bytes([bytes[6], bytes[7]]),
            bytes[2],
            bytes[3],
            bytes[4],
            u32::from_be_bytes(bytes[8..12].try_into().unwrap()),
            (float(12), float(20)),
            (float(28), float(36)),
        )
        .map_err(|_| Error::Protocol)
    }
}

/// Pure bounded state: unknown releases and duplicate presses can never
/// release a key or button this connection did not press.
#[derive(Clone, Debug)]
pub(crate) struct InputState {
    stopped: bool,
    held_keys: BTreeSet<u16>,
    held_buttons: BTreeSet<u8>,
    position: (f64, f64),
    last_key_down: HashMap<u16, f64>,
    /// A magnify or rotate that began and has not ended.
    open_gesture: Option<InputKind>,
}

impl Default for InputState {
    fn default() -> Self {
        Self {
            stopped: false,
            held_keys: BTreeSet::new(),
            held_buttons: BTreeSet::new(),
            position: (0.5, 0.5),
            last_key_down: HashMap::new(),
            open_gesture: None,
        }
    }
}

impl InputState {
    /// Returns the event to post, or nothing when it must be ignored.
    fn accept(&mut self, event: &InputEvent, now: f64) -> Result<Option<InputEvent>> {
        if self.stopped {
            return Err(Error::Closed);
        }
        event.validate()?;
        if !now.is_finite() {
            return Err(Error::Invalid);
        }
        let code = event.key_code;
        let changes = match event.kind {
            // A clock regression yields a negative interval and is ignored.
            InputKind::KeyDown if event.is_repeat => {
                self.held_keys.contains(&code)
                    && self
                        .last_key_down
                        .get(&code)
                        .is_some_and(|previous| now - previous >= REPEAT_INTERVAL)
            }
            InputKind::KeyDown => self.held_keys.insert(code),
            InputKind::KeyUp => self.held_keys.remove(&code),
            InputKind::PointerDown => self.held_buttons.insert(event.button),
            InputKind::PointerUp => self.held_buttons.remove(&event.button),
            InputKind::Scroll => event.delta_x != 0.0 || event.delta_y != 0.0,
            InputKind::PointerMove => true,
            InputKind::ReleaseAll => return Err(Error::Invalid),
            // One gesture at a time: a begin while another is open, or a
            // change or end for a gesture that is not open, is ignored.
            InputKind::Magnify | InputKind::Rotate => match (event.button, self.open_gesture) {
                (PHASE_BEGAN, None) => {
                    self.open_gesture = Some(event.kind);
                    true
                }
                (PHASE_CHANGED, Some(open)) => open == event.kind,
                (PHASE_ENDED | PHASE_CANCELLED, Some(open)) if open == event.kind => {
                    self.open_gesture = None;
                    true
                }
                _ => false,
            },
            InputKind::SmartMagnify => self.open_gesture.is_none(),
        };
        if !changes {
            return Ok(None);
        }
        match event.kind {
            InputKind::KeyDown => {
                self.last_key_down.insert(code, now);
            }
            InputKind::KeyUp => {
                self.last_key_down.remove(&code);
            }
            _ => self.position = (event.x, event.y),
        }
        Ok(Some(*event))
    }

    /// Ordinary keys before modifiers, then buttons at the latest position.
    /// Releases carry no modifiers so no stale flag reaches the next event.
    fn release_all(&mut self) -> Vec<InputEvent> {
        let mut keys: Vec<u16> = self.held_keys.iter().copied().collect();
        keys.sort_by_key(|code| (is_modifier_key(*code), *code));
        let mut events: Vec<InputEvent> = keys
            .into_iter()
            .map(|code| InputEvent::key(InputKind::KeyUp, code))
            .collect();
        events.extend(self.held_buttons.iter().map(|button| InputEvent {
            button: *button,
            click_count: 1,
            x: self.position.0,
            y: self.position.1,
            ..InputEvent::empty(InputKind::PointerUp)
        }));
        // An open pinch or rotation ends, so no app is left mid-gesture.
        if let Some(kind) = self.open_gesture.take() {
            events.push(InputEvent {
                button: PHASE_ENDED,
                x: self.position.0,
                y: self.position.1,
                ..InputEvent::empty(kind)
            });
        }
        self.held_keys.clear();
        self.held_buttons.clear();
        self.last_key_down.clear();
        events
    }
}

/// Stages each transition so the caller commits only after it has built every
/// native event; any other call discards an uncommitted transition.
#[derive(Default)]
pub(crate) struct InputReducer {
    current: InputState,
    staged: Option<InputState>,
}

impl InputReducer {
    /// Returns the events to post and the buttons held afterward (bit n is
    /// button n), which decides whether a pointer move is a drag.
    pub(crate) fn accept(&mut self, event: &InputEvent, now: f64) -> Result<(Vec<InputEvent>, u8)> {
        self.staged = None;
        if self.current.stopped {
            return Err(Error::Closed);
        }
        event.validate()?;
        if event.kind == InputKind::ReleaseAll {
            return Ok((self.current.release_all(), 0));
        }
        let mut next = self.current.clone();
        let accepted = next.accept(event, now)?;
        let held = next
            .held_buttons
            .iter()
            .fold(0, |mask, button| mask | (1 << button));
        self.staged = Some(next);
        Ok((accepted.into_iter().collect(), held))
    }
    pub(crate) fn commit(&mut self) {
        if let Some(next) = self.staged.take() {
            self.current = next;
        }
    }
    pub(crate) fn release_all(&mut self) -> Vec<InputEvent> {
        self.staged = None;
        self.current.release_all()
    }
    /// Permanently ends the state: queued input cannot press anything later.
    pub(crate) fn stop(&mut self) -> Vec<InputEvent> {
        self.current.stopped = true;
        self.release_all()
    }
    #[cfg(test)]
    fn is_stopped(&self) -> bool {
        self.current.stopped
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[allow(clippy::too_many_arguments)]
    fn event(
        kind: u8,
        key: u16,
        button: u8,
        clicks: u8,
        repeat: u8,
        modifiers: u32,
        x: f64,
        y: f64,
        dx: f64,
        dy: f64,
    ) -> Result<InputEvent> {
        InputEvent::from_parts(
            kind,
            key,
            button,
            clicks,
            repeat,
            modifiers,
            (x, y),
            (dx, dy),
        )
    }
    fn key(kind: InputKind, code: u16) -> InputEvent {
        InputEvent::key(kind, code)
    }
    fn repeat(code: u16) -> InputEvent {
        InputEvent {
            is_repeat: true,
            ..key(InputKind::KeyDown, code)
        }
    }
    fn pointer(kind: InputKind, button: u8, x: f64, y: f64) -> InputEvent {
        let clicks = if matches!(kind, InputKind::PointerDown | InputKind::PointerUp) {
            1
        } else {
            0
        };
        event(kind as u8, 0, button, clicks, 0, 0, x, y, 0.0, 0.0).unwrap()
    }
    fn accept(reducer: &mut InputReducer, value: &InputEvent, now: f64) -> Vec<InputEvent> {
        let (result, _) = reducer.accept(value, now).unwrap();
        reducer.commit();
        result
    }

    #[test]
    fn valid_events_round_trip_the_wire() {
        let values = [
            event(1, 0, 0, 0, 0, 0b1001, 0.0, 0.0, 0.0, 0.0).unwrap(),
            event(2, 127, 0, 0, 0, 0, 0.0, 0.0, 0.0, 0.0).unwrap(),
            event(3, 0, 0, 0, 0, 0, 0.25, 0.75, 0.0, 0.0).unwrap(),
            event(4, 0, 0, 2, 0, 0, 0.25, 0.75, 0.0, 0.0).unwrap(),
            event(5, 0, 2, 1, 0, 0, 0.0, 1.0, 0.0, 0.0).unwrap(),
            event(6, 0, 0, 0, 0, 0, 1.0, 0.0, -0.75, 12.5).unwrap(),
            event(7, 0, 0, 0, 0, 0, 0.0, 0.0, 0.0, 0.0).unwrap(),
            repeat(0),
        ];
        for value in values {
            assert_eq!(InputEvent::decode(&value.encode()).unwrap(), value);
        }
    }

    #[test]
    fn validation_rejects_fields_outside_each_kind() {
        let nan = f64::NAN;
        for (kind, key, button, clicks, rep, modifiers, x, y, dx, dy) in [
            (1, 128, 0, 0, 0, 0, 0.0, 0.0, 0.0, 0.0), // unsupported key code
            (2, 0, 0, 0, 1, 0, 0.0, 0.0, 0.0, 0.0),   // key release cannot repeat
            (1, 56, 0, 0, 1, 0, 0.0, 0.0, 0.0, 0.0),  // modifiers cannot repeat
            (1, 0, 0, 0, 2, 0, 0.0, 0.0, 0.0, 0.0),   // repeat is a strict boolean
            (1, 0, 0, 0, 0, 0, 0.5, 0.0, 0.0, 0.0),   // keyboard events carry no position
            (1, 0, 1, 0, 0, 0, 0.0, 0.0, 0.0, 0.0),   // or button
            (1, 0, 0, 0, 0, 64, 0.0, 0.0, 0.0, 0.0),  // unknown modifier bits
            (4, 0, 3, 1, 0, 0, 0.0, 0.0, 0.0, 0.0),   // three buttons only
            (4, 0, 0, 4, 0, 0, 0.0, 0.0, 0.0, 0.0),   // bounded click count
            (4, 0, 0, 0, 0, 0, 0.0, 0.0, 0.0, 0.0),   // clicks are required
            (3, 0, 1, 0, 0, 0, 0.0, 0.0, 0.0, 0.0),   // move cannot smuggle a button
            (3, 0, 0, 1, 0, 0, 0.0, 0.0, 0.0, 0.0),
            (3, 1, 0, 0, 0, 0, 0.0, 0.0, 0.0, 0.0), // or a key
            (3, 0, 0, 0, 0, 0, f64::NEG_INFINITY, 0.0, 0.0, 0.0),
            (3, 0, 0, 0, 0, 0, nan, 0.0, 0.0, 0.0),
            (3, 0, 0, 0, 0, 0, 1.01, 0.0, 0.0, 0.0),
            (3, 0, 0, 0, 0, 0, 0.0, -0.01, 0.0, 0.0),
            (3, 0, 0, 0, 0, 0, 0.0, 0.0, 1.0, 0.0), // only scroll carries deltas
            (6, 0, 0, 0, 0, 0, 0.0, 0.0, 0.0, 1201.0),
            (6, 0, 0, 0, 0, 0, 0.0, 0.0, nan, 0.0),
            (7, 55, 0, 0, 0, 0, 0.0, 0.0, 0.0, 0.0), // release-all names no key
            (7, 0, 0, 0, 0, 8, 0.0, 0.0, 0.0, 0.0),  // and leaves no modifier set
            (0, 0, 0, 0, 0, 0, 0.0, 0.0, 0.0, 0.0),
            (8, 0, 0, 0, 0, 0, 0.0, 0.0, 0.0, 0.0),
        ] {
            assert_eq!(
                event(kind, key, button, clicks, rep, modifiers, x, y, dx, dy),
                Err(Error::Invalid),
                "kind {kind}"
            );
        }
    }

    #[test]
    fn malformed_wire_events_are_protocol_violations() {
        let valid = key(InputKind::KeyDown, 0).encode();
        let mut cases = vec![valid[..43].to_vec(), [&valid[..], &[0]].concat()];
        for (index, value) in [(0, 2), (1, 9), (5, 1), (4, 2), (6, 1)] {
            let mut bytes = valid;
            bytes[index] = value;
            cases.push(bytes.to_vec());
        }
        let mut nan = pointer(InputKind::PointerMove, 0, 0.5, 0.5).encode();
        nan[12..20].copy_from_slice(&f64::NAN.to_bits().to_be_bytes());
        cases.push(nan.to_vec());
        for bytes in cases {
            assert_eq!(InputEvent::decode(&bytes), Err(Error::Protocol));
        }
    }

    #[test]
    fn held_keys_are_idempotent_and_repeats_are_bounded() {
        let mut state = InputReducer::default();
        let down = InputEvent {
            modifiers: 0b1001,
            ..key(InputKind::KeyDown, 0)
        };
        assert!(
            accept(&mut state, &key(InputKind::KeyUp, 0), 1.0).is_empty(),
            "untracked release"
        );
        assert!(
            accept(&mut state, &repeat(0), 1.0).is_empty(),
            "autorepeat cannot invent a key"
        );
        assert_eq!(accept(&mut state, &down, 1.0), [down]);
        assert!(
            accept(&mut state, &down, 1.001).is_empty(),
            "duplicate press"
        );
        assert!(
            accept(&mut state, &repeat(0), 1.001).is_empty(),
            "at most 120 Hz"
        );
        assert_eq!(accept(&mut state, &repeat(0), 1.02), [repeat(0)]);
        assert!(
            accept(&mut state, &repeat(0), 0.0).is_empty(),
            "clock regression"
        );
        assert_eq!(
            accept(&mut state, &key(InputKind::KeyUp, 0), 1.03),
            [key(InputKind::KeyUp, 0)]
        );
        assert!(
            accept(&mut state, &repeat(0), 2.0).is_empty(),
            "released keys cannot repeat"
        );
        assert!(state.accept(&down, f64::NAN).is_err(), "nonfinite clock");
    }

    #[test]
    fn buttons_track_position_and_cleanup_orders_releases() {
        let mut state = InputReducer::default();
        let click = pointer(InputKind::PointerDown, 0, 0.25, 0.75);
        assert_eq!(state.accept(&click, 2.0).unwrap(), (vec![click], 0b001));
        state.commit();
        let other = pointer(InputKind::PointerDown, 2, 0.25, 0.75);
        assert_eq!(
            state.accept(&other, 2.0).unwrap().1,
            0b101,
            "held buttons after the staged transition"
        );
        assert!(
            accept(&mut state, &click, 2.0).is_empty(),
            "duplicate pointer down"
        );
        accept(
            &mut state,
            &pointer(InputKind::PointerMove, 0, 0.9, 0.1),
            2.0,
        );
        assert!(
            accept(&mut state, &pointer(InputKind::PointerUp, 1, 0.0, 0.0), 2.0).is_empty(),
            "untracked button"
        );
        accept(&mut state, &key(InputKind::KeyDown, 56), 3.0);
        accept(&mut state, &key(InputKind::KeyDown, 0), 3.0);
        let releases = state.release_all();
        assert_eq!(releases.len(), 3);
        assert_eq!(
            (releases[0].kind, releases[0].key_code),
            (InputKind::KeyUp, 0)
        );
        assert_eq!(
            (releases[1].kind, releases[1].key_code),
            (InputKind::KeyUp, 56)
        );
        assert_eq!(
            (
                releases[2].kind,
                releases[2].button,
                releases[2].x,
                releases[2].y
            ),
            (InputKind::PointerUp, 0, 0.9, 0.1)
        );
        assert!(
            releases
                .iter()
                .all(|value| value.modifiers == 0 && value.validate().is_ok())
        );
        assert!(state.release_all().is_empty(), "cleanup is idempotent");
        let empty_scroll = event(6, 0, 0, 0, 0, 0, 0.5, 0.5, 0.0, 0.0).unwrap();
        assert!(
            accept(&mut state, &empty_scroll, 4.0).is_empty(),
            "zero scrolls are dropped"
        );
    }

    #[test]
    fn held_state_is_bounded_and_wire_release_all_clears_it() {
        let mut state = InputReducer::default();
        for code in 0..=MAX_KEY_CODE {
            accept(&mut state, &key(InputKind::KeyDown, code), 4.0);
        }
        for button in 0..=2 {
            accept(
                &mut state,
                &pointer(InputKind::PointerDown, button, 1.0, 1.0),
                4.0,
            );
        }
        accept(
            &mut state,
            &gesture(InputKind::Magnify, PHASE_BEGAN, 0.0),
            4.0,
        );
        let clear = event(7, 0, 0, 0, 0, 0, 0.0, 0.0, 0.0, 0.0).unwrap();
        assert_eq!(state.accept(&clear, 5.0).unwrap().0.len(), MAX_RELEASES);
        assert!(state.release_all().is_empty());
    }

    #[test]
    fn uncommitted_transitions_are_discarded() {
        let mut state = InputReducer::default();
        let down = key(InputKind::KeyDown, 4);
        assert_eq!(state.accept(&down, 1.0).unwrap().0, [down]);
        assert!(
            state.release_all().is_empty(),
            "a press is not held until committed"
        );
        assert_eq!(state.accept(&down, 1.0).unwrap().0, [down]);
        assert_eq!(
            state.accept(&down, 1.0).unwrap().0,
            [down],
            "restaging replaces the previous stage"
        );
        state.commit();
        assert_eq!(state.release_all(), [key(InputKind::KeyUp, 4)]);
    }

    #[test]
    fn only_the_escape_hatch_shortcuts_stay_local() {
        let (shift, control, option, command, caps, function) = (1, 2, 4, 8, 16, 32);
        for (code, modifiers) in [
            (53, command | option),
            (53, command | option | shift),
            (53, command | option | caps),
            (12, control | command),
            (3, control | command),
            (3, function),
            (2, control | command),
            (34, control | command | caps),
        ] {
            assert!(keeps_local(code, modifiers), "{code} {modifiers}");
        }
        for (code, modifiers) in [
            (48, command), // ⌘-Tab goes to the remote Mac
            (48, command | shift),
            (49, command), // ⌘-Space
            (53, 0),       // Escape alone
            (53, command),
            (12, command), // ⌘-Q quits the remote app
            (3, command),  // ⌘-F finds on the remote Mac
            (3, control | command | shift),
            (2, command), // ⌘-D belongs to the remote app
            (34, command),
            (2, control | command | option),
            (34, control | command | shift),
            (123, control), // ⌃← switches remote Spaces
        ] {
            assert!(!keeps_local(code, modifiers), "{code} {modifiers}");
        }
    }

    #[test]
    fn stop_releases_current_input_and_rejects_queued_events() {
        let mut state = InputReducer::default();
        accept(&mut state, &key(InputKind::KeyDown, 0), 6.0);
        assert_eq!(state.stop().len(), 1);
        assert!(state.is_stopped());
        assert_eq!(
            state.accept(&key(InputKind::KeyDown, 0), 7.0),
            Err(Error::Closed)
        );
        assert_eq!(
            state.accept(&pointer(InputKind::PointerMove, 0, 0.5, 0.5), 7.0),
            Err(Error::Closed)
        );
        assert!(state.stop().is_empty() && state.release_all().is_empty());
    }

    fn gesture(kind: InputKind, phase: u8, value: f64) -> InputEvent {
        InputEvent {
            button: phase,
            x: 0.4,
            y: 0.6,
            delta_x: value,
            ..InputEvent::empty(kind)
        }
    }

    #[test]
    fn gestures_carry_a_phase_value_and_position() {
        for event in [
            gesture(InputKind::Magnify, PHASE_BEGAN, 0.0),
            gesture(InputKind::Magnify, PHASE_CHANGED, -0.12),
            gesture(InputKind::Rotate, PHASE_ENDED, 359.0),
            gesture(InputKind::SmartMagnify, 0, 0.0),
        ] {
            assert_eq!(InputEvent::decode(&event.encode()), Ok(event), "{event:?}");
        }
        for invalid in [
            gesture(InputKind::Magnify, 3, 0.1), // not a single phase
            gesture(InputKind::Magnify, PHASE_CHANGED, 6.0),
            gesture(InputKind::Rotate, PHASE_CHANGED, f64::NAN),
            gesture(InputKind::Rotate, PHASE_CHANGED, 361.0),
            gesture(InputKind::SmartMagnify, PHASE_BEGAN, 0.0),
            gesture(InputKind::SmartMagnify, 0, 0.5),
            InputEvent {
                x: 1.5,
                ..gesture(InputKind::Magnify, PHASE_BEGAN, 0.0)
            },
            InputEvent {
                delta_y: 1.0,
                ..gesture(InputKind::Rotate, PHASE_BEGAN, 0.0)
            },
        ] {
            assert!(invalid.validate().is_err(), "{invalid:?}");
        }
        assert!(InputKind::Magnify.is_gesture() && !InputKind::Scroll.is_gesture());
    }

    #[test]
    fn one_gesture_at_a_time_and_cleanup_ends_it() {
        let mut state = InputState::default();
        let accept = |state: &mut InputState, event| state.accept(&event, 1.0).unwrap().is_some();
        assert!(
            !accept(&mut state, gesture(InputKind::Magnify, PHASE_CHANGED, 0.1)),
            "no change before a begin"
        );
        assert!(accept(
            &mut state,
            gesture(InputKind::Magnify, PHASE_BEGAN, 0.0)
        ));
        assert!(
            !accept(&mut state, gesture(InputKind::Rotate, PHASE_BEGAN, 0.0)),
            "one gesture at a time"
        );
        assert!(!accept(
            &mut state,
            gesture(InputKind::SmartMagnify, 0, 0.0)
        ));
        assert!(accept(
            &mut state,
            gesture(InputKind::Magnify, PHASE_CHANGED, 0.2)
        ));
        assert!(
            !accept(&mut state, gesture(InputKind::Rotate, PHASE_ENDED, 0.0)),
            "ends only its own gesture"
        );
        let released = state.release_all();
        assert_eq!(
            released.last().map(|event| (event.kind, event.button)),
            Some((InputKind::Magnify, PHASE_ENDED))
        );
        assert!(state.release_all().is_empty(), "the gesture ends once");
        assert!(accept(
            &mut state,
            gesture(InputKind::Rotate, PHASE_BEGAN, 0.0)
        ));
        assert!(accept(
            &mut state,
            gesture(InputKind::Rotate, PHASE_CANCELLED, 0.0)
        ));
        assert!(accept(&mut state, gesture(InputKind::SmartMagnify, 0, 0.0)));
    }
}

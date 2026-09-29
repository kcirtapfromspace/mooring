//! Per-role session policy. A listener-accepted session is the sharing host; a
//! connected session is the viewer. Each side may send only its own messages,
//! receives are rate limited, and an idle peer ends the session.

use crate::control::{ControlKind, ControlMessage};
use crate::telemetry::TelemetryMessage;
use crate::transport::Incoming;
use crate::{Error, Result};
use std::time::{Duration, Instant};

pub(crate) const VIDEO: u8 = 1;
pub(crate) const INPUT: u8 = 2;
pub(crate) const CONTROL: u8 = 3;
pub(crate) const TELEMETRY: u8 = 4;
pub(crate) const CLIPBOARD: u8 = 5;

/// Protocol versions this build speaks. 4 is the preview 4-8 protocol; 5 adds
/// a capability exchange, so later features switch on only when both sides
/// support them and mixed versions keep connecting.
pub(crate) const PROTOCOL_MIN: u32 = 4;
pub(crate) const PROTOCOL_MAX: u32 = 5;
/// The viewer decodes HEVC 4:4:4 in hardware, so the host may send it.
pub(crate) const CAPABILITY_HEVC_444: u64 = 1;

/// No complete authenticated message for this long ends the session. Viewers
/// ping every second and hosts answer, so a healthy idle desktop stays open.
pub(crate) const IDLE_LIMIT: Duration = Duration::from_secs(10);
const WINDOW: Duration = Duration::from_secs(1);
const HOST_MESSAGES_PER_WINDOW: u32 = 1000;
/// Control and telemetry together; hosts send a few of each per second.
const VIEWER_CONTROLS_PER_WINDOW: u32 = 32;
/// Clipboard messages from either side. Senders poll their pasteboard at most
/// twice a second, so this only stops a peer flooding large messages.
const CLIPBOARDS_PER_WINDOW: u32 = 4;
const PING_SPACING: Duration = Duration::from_millis(250);
/// Viewers retry keyframe requests at a longer interval, so a request dropped
/// here is always followed by one that is honored.
const KEYFRAME_SPACING: Duration = Duration::from_millis(500);

/// Automatic viewer reconnects after an unexpected end use a short, bounded
/// backoff. A session that stayed connected for `RECONNECT_STABLE` starts a
/// fresh budget, so a rare drop never exhausts it.
pub(crate) const RECONNECT_DELAYS: [Duration; 5] = [
    Duration::from_millis(500),
    Duration::from_secs(1),
    Duration::from_secs(2),
    Duration::from_secs(4),
    Duration::from_secs(8),
];
pub(crate) const RECONNECT_STABLE: Duration = Duration::from_secs(20);

/// The wait before reconnect `attempt` (1-based), or None once the budget is spent.
pub(crate) fn reconnect_delay(attempt: u32) -> Option<Duration> {
    let index = usize::try_from(attempt.checked_sub(1)?).ok()?;
    RECONNECT_DELAYS.get(index).copied()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Role {
    Host,
    Viewer,
}

impl Role {
    pub(crate) fn may_send(self, kind: u8) -> bool {
        matches!(
            (self, kind),
            (Self::Host, VIDEO | CONTROL | TELEMETRY | CLIPBOARD)
                | (Self::Viewer, INPUT | CONTROL | TELEMETRY | CLIPBOARD)
        )
    }
    pub(crate) fn may_receive(self, kind: u8) -> bool {
        self.peer().may_send(kind)
    }
    pub(crate) fn may_send_control(self, kind: ControlKind) -> bool {
        match self {
            Self::Host => matches!(
                kind,
                ControlKind::Geometry
                    | ControlKind::InputState
                    | ControlKind::Pong
                    | ControlKind::Hello
            ),
            Self::Viewer => matches!(
                kind,
                ControlKind::Ping | ControlKind::Keyframe | ControlKind::Hello
            ),
        }
    }
    /// Both sides report stats; only the viewer tunes the sharing host.
    pub(crate) fn may_send_telemetry(self, message: &TelemetryMessage) -> bool {
        !matches!((self, message), (Self::Host, TelemetryMessage::Tuning(_)))
    }
    fn peer(self) -> Self {
        match self {
            Self::Host => Self::Viewer,
            Self::Viewer => Self::Host,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Admission {
    Deliver,
    /// Valid but too soon; consumed without being returned to the caller.
    Skip,
}

pub(crate) struct ReceivePolicy {
    role: Role,
    version: u32,
    /// This side's capabilities, fixed for the session.
    local_capabilities: u64,
    hello: bool,
    window_start: Instant,
    window_count: u32,
    clipboard_count: u32,
    last_ping: Option<Instant>,
    last_keyframe: Option<Instant>,
    has_geometry: bool,
    last_message: Instant,
    pub(crate) idle_limit: Duration,
}

impl ReceivePolicy {
    #[cfg(test)]
    pub(crate) fn new(role: Role, now: Instant) -> Self {
        Self::for_version(role, PROTOCOL_MIN, 0, now)
    }
    pub(crate) fn for_version(
        role: Role,
        version: u32,
        local_capabilities: u64,
        now: Instant,
    ) -> Self {
        Self {
            role,
            version,
            local_capabilities,
            hello: false,
            window_start: now,
            window_count: 0,
            clipboard_count: 0,
            last_ping: None,
            last_keyframe: None,
            has_geometry: false,
            last_message: now,
            idle_limit: IDLE_LIMIT,
        }
    }

    /// Call once for every complete, decoded message.
    pub(crate) fn admit(&mut self, message: &Incoming, now: Instant) -> Result<Admission> {
        self.last_message = now;
        let peer = self.role.peer();
        let (kind, allowed) = match message {
            Incoming::Video(_) => (VIDEO, true),
            Incoming::Input(_) => (INPUT, true),
            Incoming::Control(control) => (CONTROL, peer.may_send_control(control.kind())),
            Incoming::Telemetry(telemetry) => (TELEMETRY, peer.may_send_telemetry(telemetry)),
            Incoming::Clipboard(_) => (CLIPBOARD, true),
        };
        if !allowed || !self.role.may_receive(kind) {
            return Err(Error::Protocol);
        }
        match message {
            // A Hello needs protocol 5 and arrives at most once.
            Incoming::Control(ControlMessage::Hello(_)) if self.version < 5 || self.hello => {
                return Err(Error::Protocol);
            }
            Incoming::Control(ControlMessage::Hello(_)) => self.hello = true,
            // HEVC only reaches a side that declared it decodes HEVC 4:4:4.
            Incoming::Video(packet)
                if packet.header.codec == crate::video::Codec::Hevc
                    && self.local_capabilities & CAPABILITY_HEVC_444 == 0 =>
            {
                return Err(Error::Protocol);
            }
            _ => {}
        }
        if now.saturating_duration_since(self.window_start) >= WINDOW {
            self.window_start = now;
            self.window_count = 0;
            self.clipboard_count = 0;
        }
        if kind == CLIPBOARD {
            self.clipboard_count += 1;
            if self.clipboard_count > CLIPBOARDS_PER_WINDOW {
                return Err(Error::RateLimited);
            }
        }
        let (counted, limit) = match self.role {
            Role::Host => (true, HOST_MESSAGES_PER_WINDOW),
            Role::Viewer => (
                matches!(kind, CONTROL | TELEMETRY),
                VIEWER_CONTROLS_PER_WINDOW,
            ),
        };
        if counted {
            self.window_count += 1;
            if self.window_count > limit {
                return Err(Error::RateLimited);
            }
        }
        let spaced = |last: &mut Option<Instant>, spacing: Duration| {
            if last.is_some_and(|previous| now.saturating_duration_since(previous) < spacing) {
                Admission::Skip
            } else {
                *last = Some(now);
                Admission::Deliver
            }
        };
        Ok(match message {
            Incoming::Control(ControlMessage::Ping(_)) => spaced(&mut self.last_ping, PING_SPACING),
            Incoming::Control(ControlMessage::Keyframe) => {
                spaced(&mut self.last_keyframe, KEYFRAME_SPACING)
            }
            Incoming::Control(ControlMessage::Geometry { .. }) => {
                self.has_geometry = true;
                Admission::Deliver
            }
            // Video is meaningless before geometry.
            Incoming::Video(_) if !self.has_geometry => return Err(Error::Protocol),
            _ => Admission::Deliver,
        })
    }

    pub(crate) fn is_idle(&self, now: Instant) -> bool {
        now.saturating_duration_since(self.last_message) >= self.idle_limit
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::control::DisplayGeometry;
    use crate::input::{InputEvent, InputKind};
    use crate::telemetry::Tuning;
    use crate::video::{VideoHeader, VideoPacket};

    fn geometry() -> Incoming {
        Incoming::Control(ControlMessage::Geometry {
            geometry: DisplayGeometry {
                x: 0.0,
                y: 0.0,
                width: 1920.0,
                height: 1080.0,
                pixel_width: 1920,
                pixel_height: 1080,
            },
            input_enabled: true,
        })
    }
    fn video() -> Incoming {
        Incoming::Video(VideoPacket {
            header: VideoHeader::default(),
            vps: 0..0,
            sps: 0..1,
            pps: 1..2,
            avcc: 2..3,
        })
    }
    fn input() -> Incoming {
        Incoming::Input(InputEvent::key(InputKind::KeyDown, 0))
    }
    fn control(message: ControlMessage) -> Incoming {
        Incoming::Control(message)
    }
    fn stats() -> Incoming {
        Incoming::Telemetry(TelemetryMessage::Stats(vec![]))
    }
    fn clipboard() -> Incoming {
        Incoming::Clipboard(crate::clipboard::ClipboardPacket { items: vec![] })
    }
    fn tuning() -> Incoming {
        Incoming::Telemetry(TelemetryMessage::Tuning(Tuning {
            fps: 30,
            ..Tuning::default()
        }))
    }

    #[test]
    fn each_role_sends_only_its_own_messages() {
        assert!(
            Role::Host.may_send(VIDEO)
                && Role::Host.may_send(CONTROL)
                && !Role::Host.may_send(INPUT)
        );
        assert!(
            Role::Viewer.may_send(INPUT)
                && Role::Viewer.may_send(CONTROL)
                && !Role::Viewer.may_send(VIDEO)
        );
        assert!(Role::Host.may_send(TELEMETRY) && Role::Viewer.may_send(TELEMETRY));
        assert!(Role::Host.may_send(CLIPBOARD) && Role::Viewer.may_send(CLIPBOARD));
        assert!(!Role::Host.may_send(0) && !Role::Viewer.may_send(6));
        for kind in [
            ControlKind::Geometry,
            ControlKind::InputState,
            ControlKind::Pong,
        ] {
            assert!(Role::Host.may_send_control(kind) && !Role::Viewer.may_send_control(kind));
        }
        for kind in [ControlKind::Ping, ControlKind::Keyframe] {
            assert!(Role::Viewer.may_send_control(kind) && !Role::Host.may_send_control(kind));
        }
        let Incoming::Telemetry(tune) = tuning() else {
            unreachable!()
        };
        assert!(Role::Viewer.may_send_telemetry(&tune) && !Role::Host.may_send_telemetry(&tune));
    }

    #[test]
    fn hosts_reject_viewer_bound_messages() {
        let now = Instant::now();
        for message in [video(), geometry(), control(ControlMessage::Pong(1))] {
            let mut policy = ReceivePolicy::new(Role::Host, now);
            assert_eq!(policy.admit(&message, now), Err(Error::Protocol));
        }
        for message in [control(ControlMessage::Keyframe), input(), tuning()] {
            let mut policy = ReceivePolicy::new(Role::Viewer, now);
            assert_eq!(policy.admit(&message, now), Err(Error::Protocol));
        }
        let mut policy = ReceivePolicy::new(Role::Host, now);
        assert_eq!(policy.admit(&tuning(), now), Ok(Admission::Deliver));
        assert_eq!(policy.admit(&stats(), now), Ok(Admission::Deliver));
    }

    #[test]
    fn viewers_require_geometry_before_video() {
        let now = Instant::now();
        let mut policy = ReceivePolicy::new(Role::Viewer, now);
        assert_eq!(policy.admit(&video(), now), Err(Error::Protocol));
        let mut policy = ReceivePolicy::new(Role::Viewer, now);
        assert_eq!(policy.admit(&geometry(), now), Ok(Admission::Deliver));
        assert_eq!(policy.admit(&video(), now), Ok(Admission::Deliver));
    }

    #[test]
    fn host_limits_all_messages_per_second() {
        let now = Instant::now();
        let mut policy = ReceivePolicy::new(Role::Host, now);
        for _ in 0..HOST_MESSAGES_PER_WINDOW {
            assert!(policy.admit(&input(), now).is_ok());
        }
        assert_eq!(policy.admit(&input(), now), Err(Error::RateLimited));
        let mut policy = ReceivePolicy::new(Role::Host, now);
        for _ in 0..HOST_MESSAGES_PER_WINDOW {
            policy.admit(&input(), now).unwrap();
        }
        assert!(
            policy.admit(&input(), now + WINDOW).is_ok(),
            "a new window resets the budget"
        );
    }

    #[test]
    fn viewer_limits_controls_and_telemetry_but_not_video() {
        let now = Instant::now();
        let mut policy = ReceivePolicy::new(Role::Viewer, now);
        policy.admit(&geometry(), now).unwrap();
        for _ in 0..500 {
            assert!(policy.admit(&video(), now).is_ok());
        }
        for index in 1..VIEWER_CONTROLS_PER_WINDOW {
            let message = if index % 2 == 0 {
                stats()
            } else {
                control(ControlMessage::Pong(1))
            };
            assert!(policy.admit(&message, now).is_ok());
        }
        assert_eq!(policy.admit(&stats(), now), Err(Error::RateLimited));
    }

    #[test]
    fn both_sides_limit_clipboard_messages_per_second() {
        let now = Instant::now();
        for role in [Role::Host, Role::Viewer] {
            let mut policy = ReceivePolicy::new(role, now);
            for _ in 0..CLIPBOARDS_PER_WINDOW {
                assert_eq!(policy.admit(&clipboard(), now), Ok(Admission::Deliver));
            }
            assert_eq!(policy.admit(&clipboard(), now), Err(Error::RateLimited));
            let mut policy = ReceivePolicy::new(role, now);
            for _ in 0..CLIPBOARDS_PER_WINDOW {
                policy.admit(&clipboard(), now).unwrap();
            }
            assert!(
                policy.admit(&clipboard(), now + WINDOW).is_ok(),
                "a new window resets the budget"
            );
        }
    }

    #[test]
    fn hello_needs_protocol_5_and_arrives_once() {
        let now = Instant::now();
        let hello = || control(ControlMessage::Hello(CAPABILITY_HEVC_444));
        let mut old = ReceivePolicy::for_version(Role::Host, 4, 0, now);
        assert_eq!(old.admit(&hello(), now), Err(Error::Protocol));
        let mut new = ReceivePolicy::for_version(Role::Host, 5, 0, now);
        assert_eq!(new.admit(&hello(), now), Ok(Admission::Deliver));
        assert_eq!(new.admit(&hello(), now), Err(Error::Protocol));
    }

    #[test]
    fn hevc_reaches_only_a_side_that_declared_it() {
        let now = Instant::now();
        let hevc = || {
            let mut packet = match video() {
                Incoming::Video(packet) => packet,
                _ => unreachable!(),
            };
            packet.header.codec = crate::video::Codec::Hevc;
            Incoming::Video(packet)
        };
        for (capabilities, expected) in [
            (0, Err(Error::Protocol)),
            (CAPABILITY_HEVC_444, Ok(Admission::Deliver)),
        ] {
            let mut policy = ReceivePolicy::for_version(Role::Viewer, 5, capabilities, now);
            policy.admit(&geometry(), now).unwrap();
            assert_eq!(policy.admit(&hevc(), now), expected);
        }
    }

    #[test]
    fn host_spaces_pings_and_keyframe_requests() {
        let now = Instant::now();
        let mut policy = ReceivePolicy::new(Role::Host, now);
        let ping = control(ControlMessage::Ping(1));
        assert_eq!(policy.admit(&ping, now), Ok(Admission::Deliver));
        assert_eq!(
            policy.admit(&ping, now + Duration::from_millis(249)),
            Ok(Admission::Skip)
        );
        assert_eq!(
            policy.admit(&ping, now + PING_SPACING),
            Ok(Admission::Deliver)
        );
        let keyframe = control(ControlMessage::Keyframe);
        assert_eq!(policy.admit(&keyframe, now), Ok(Admission::Deliver));
        assert_eq!(
            policy.admit(&keyframe, now + Duration::from_millis(499)),
            Ok(Admission::Skip)
        );
        assert_eq!(
            policy.admit(&keyframe, now + KEYFRAME_SPACING),
            Ok(Admission::Deliver)
        );
    }

    #[test]
    fn reconnect_backoff_is_bounded_and_increasing() {
        assert_eq!(reconnect_delay(0), None);
        assert_eq!(reconnect_delay(1), Some(Duration::from_millis(500)));
        assert_eq!(reconnect_delay(5), Some(Duration::from_secs(8)));
        assert_eq!(reconnect_delay(6), None);
        assert_eq!(reconnect_delay(u32::MAX), None);
        assert!(RECONNECT_DELAYS.windows(2).all(|pair| pair[0] < pair[1]));
        let total: Duration = RECONNECT_DELAYS.iter().sum();
        assert!(
            total < RECONNECT_STABLE,
            "a full budget ends before a session counts as stable"
        );
    }

    #[test]
    fn idleness_counts_from_the_last_complete_message() {
        let now = Instant::now();
        let mut policy = ReceivePolicy::new(Role::Host, now);
        assert!(!policy.is_idle(now + IDLE_LIMIT - Duration::from_millis(1)));
        assert!(policy.is_idle(now + IDLE_LIMIT));
        policy.admit(&input(), now + IDLE_LIMIT).unwrap();
        assert!(!policy.is_idle(now + IDLE_LIMIT + Duration::from_secs(1)));
    }
}

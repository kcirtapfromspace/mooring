//! Per-role session policy. A listener-accepted session is the sharing host; a
//! connected session is the viewer. Each side may send only its own messages,
//! receives are rate limited, and an idle peer ends the session.

use crate::control::{ControlKind, ControlMessage};
use crate::{Error, Result};
use std::time::{Duration, Instant};

pub(crate) const VIDEO: u8 = 1;
pub(crate) const INPUT: u8 = 2;
pub(crate) const CONTROL: u8 = 3;

/// No complete authenticated message for this long ends the session. Viewers
/// ping every second and hosts answer, so a healthy idle desktop stays open.
pub(crate) const IDLE_LIMIT: Duration = Duration::from_secs(10);
const WINDOW: Duration = Duration::from_secs(1);
const HOST_MESSAGES_PER_WINDOW: u32 = 1000;
const VIEWER_CONTROLS_PER_WINDOW: u32 = 32;
const PING_SPACING: Duration = Duration::from_millis(250);
/// Viewers retry keyframe requests at a longer interval, so a request dropped
/// here is always followed by one that is honored.
const KEYFRAME_SPACING: Duration = Duration::from_millis(500);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Role {
    Host,
    Viewer,
}

impl Role {
    pub(crate) fn may_send(self, kind: u8) -> bool {
        matches!(
            (self, kind),
            (Self::Host, VIDEO | CONTROL) | (Self::Viewer, INPUT | CONTROL)
        )
    }
    pub(crate) fn may_receive(self, kind: u8) -> bool {
        self.peer().may_send(kind)
    }
    pub(crate) fn may_send_control(self, kind: ControlKind) -> bool {
        match self {
            Self::Host => matches!(
                kind,
                ControlKind::Geometry | ControlKind::InputState | ControlKind::Pong
            ),
            Self::Viewer => matches!(kind, ControlKind::Ping | ControlKind::Keyframe),
        }
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
    window_start: Instant,
    window_count: u32,
    last_ping: Option<Instant>,
    last_keyframe: Option<Instant>,
    has_geometry: bool,
    last_message: Instant,
    pub(crate) idle_limit: Duration,
}

impl ReceivePolicy {
    pub(crate) fn new(role: Role, now: Instant) -> Self {
        Self {
            role,
            window_start: now,
            window_count: 0,
            last_ping: None,
            last_keyframe: None,
            has_geometry: false,
            last_message: now,
            idle_limit: IDLE_LIMIT,
        }
    }

    /// Call once for every complete, decoded message.
    pub(crate) fn admit(
        &mut self,
        kind: u8,
        control: Option<&ControlMessage>,
        now: Instant,
    ) -> Result<Admission> {
        self.last_message = now;
        let control_kind = control.map(ControlMessage::kind);
        if !self.role.may_receive(kind)
            || control_kind.is_some_and(|value| !self.role.peer().may_send_control(value))
        {
            return Err(Error::Protocol);
        }
        if now.saturating_duration_since(self.window_start) >= WINDOW {
            self.window_start = now;
            self.window_count = 0;
        }
        let (counted, limit) = match self.role {
            Role::Host => (true, HOST_MESSAGES_PER_WINDOW),
            Role::Viewer => (kind == CONTROL, VIEWER_CONTROLS_PER_WINDOW),
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
        Ok(match control_kind {
            Some(ControlKind::Ping) => spaced(&mut self.last_ping, PING_SPACING),
            Some(ControlKind::Keyframe) => spaced(&mut self.last_keyframe, KEYFRAME_SPACING),
            Some(ControlKind::Geometry) => {
                self.has_geometry = true;
                Admission::Deliver
            }
            // Input coordinates and video are meaningless before geometry.
            _ if kind == VIDEO && !self.has_geometry => return Err(Error::Protocol),
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

    fn geometry() -> ControlMessage {
        ControlMessage::Geometry {
            geometry: DisplayGeometry {
                x: 0.0,
                y: 0.0,
                width: 1920.0,
                height: 1080.0,
                pixel_width: 1920,
                pixel_height: 1080,
            },
            input_enabled: true,
        }
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
        assert!(!Role::Host.may_send(0) && !Role::Viewer.may_send(4));
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
    }

    #[test]
    fn hosts_reject_viewer_bound_messages() {
        let now = Instant::now();
        for (kind, control) in [
            (VIDEO, None),
            (CONTROL, Some(geometry())),
            (CONTROL, Some(ControlMessage::Pong(1))),
        ] {
            let mut policy = ReceivePolicy::new(Role::Host, now);
            assert_eq!(
                policy.admit(kind, control.as_ref(), now),
                Err(Error::Protocol)
            );
        }
        let mut policy = ReceivePolicy::new(Role::Viewer, now);
        assert_eq!(
            policy.admit(CONTROL, Some(&ControlMessage::Keyframe), now),
            Err(Error::Protocol)
        );
        assert_eq!(policy.admit(INPUT, None, now), Err(Error::Protocol));
    }

    #[test]
    fn viewers_require_geometry_before_video() {
        let now = Instant::now();
        let mut policy = ReceivePolicy::new(Role::Viewer, now);
        assert_eq!(policy.admit(VIDEO, None, now), Err(Error::Protocol));
        let mut policy = ReceivePolicy::new(Role::Viewer, now);
        assert_eq!(
            policy.admit(CONTROL, Some(&geometry()), now),
            Ok(Admission::Deliver)
        );
        assert_eq!(policy.admit(VIDEO, None, now), Ok(Admission::Deliver));
    }

    #[test]
    fn host_limits_all_messages_per_second() {
        let now = Instant::now();
        let mut policy = ReceivePolicy::new(Role::Host, now);
        for _ in 0..HOST_MESSAGES_PER_WINDOW {
            assert!(policy.admit(INPUT, None, now).is_ok());
        }
        assert_eq!(policy.admit(INPUT, None, now), Err(Error::RateLimited));
        let mut policy = ReceivePolicy::new(Role::Host, now);
        for _ in 0..HOST_MESSAGES_PER_WINDOW {
            policy.admit(INPUT, None, now).unwrap();
        }
        assert!(
            policy.admit(INPUT, None, now + WINDOW).is_ok(),
            "a new window resets the budget"
        );
    }

    #[test]
    fn viewer_limits_controls_but_not_video() {
        let now = Instant::now();
        let mut policy = ReceivePolicy::new(Role::Viewer, now);
        policy.admit(CONTROL, Some(&geometry()), now).unwrap();
        for _ in 0..500 {
            assert!(policy.admit(VIDEO, None, now).is_ok());
        }
        for _ in 1..VIEWER_CONTROLS_PER_WINDOW {
            assert!(
                policy
                    .admit(CONTROL, Some(&ControlMessage::Pong(1)), now)
                    .is_ok()
            );
        }
        assert_eq!(
            policy.admit(CONTROL, Some(&ControlMessage::Pong(1)), now),
            Err(Error::RateLimited)
        );
    }

    #[test]
    fn host_spaces_pings_and_keyframe_requests() {
        let now = Instant::now();
        let mut policy = ReceivePolicy::new(Role::Host, now);
        let ping = ControlMessage::Ping(1);
        assert_eq!(
            policy.admit(CONTROL, Some(&ping), now),
            Ok(Admission::Deliver)
        );
        assert_eq!(
            policy.admit(CONTROL, Some(&ping), now + Duration::from_millis(249)),
            Ok(Admission::Skip)
        );
        assert_eq!(
            policy.admit(CONTROL, Some(&ping), now + PING_SPACING),
            Ok(Admission::Deliver)
        );
        let keyframe = ControlMessage::Keyframe;
        assert_eq!(
            policy.admit(CONTROL, Some(&keyframe), now),
            Ok(Admission::Deliver)
        );
        assert_eq!(
            policy.admit(CONTROL, Some(&keyframe), now + Duration::from_millis(499)),
            Ok(Admission::Skip)
        );
        assert_eq!(
            policy.admit(CONTROL, Some(&keyframe), now + KEYFRAME_SPACING),
            Ok(Admission::Deliver)
        );
    }

    #[test]
    fn idleness_counts_from_the_last_complete_message() {
        let now = Instant::now();
        let mut policy = ReceivePolicy::new(Role::Host, now);
        assert!(!policy.is_idle(now + IDLE_LIMIT - Duration::from_millis(1)));
        assert!(policy.is_idle(now + IDLE_LIMIT));
        policy.admit(INPUT, None, now + IDLE_LIMIT).unwrap();
        assert!(!policy.is_idle(now + IDLE_LIMIT + Duration::from_secs(1)));
    }
}

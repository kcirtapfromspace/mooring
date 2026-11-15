//! A Linux connection attempt. Time, UI, authentication and I/O are effects;
//! this model only admits transitions. A generation rejects late callbacks
//! after disconnect or a subsequent connection to the same saved desktop.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum Phase {
    Connecting = 0,
    WaitingForDesktop = 1,
    Authenticating = 2,
    Viewing = 3,
    Ended = 4,
    Closed = 5,
}

#[derive(Clone, Copy, Debug)]
pub enum Event {
    TunnelReady(u16),
    DesktopReadyOrTimedOut,
    ViewerStarted,
    RetryRequested,
    Close,
    ViewerEnded,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(i32)]
pub enum Action {
    None = 0,
    WaitForDesktop = 1,
    AskForSignIn = 2,
    StopTunnel = 3,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LinuxSession {
    generation: u64,
    phase: Phase,
    port: u16,
}

impl LinuxSession {
    pub fn new(generation: u64) -> Self {
        Self {
            generation,
            phase: Phase::Connecting,
            port: 0,
        }
    }
    pub fn generation(&self) -> u64 {
        self.generation
    }
    pub fn phase(&self) -> Phase {
        self.phase
    }
    pub fn port(&self) -> u16 {
        self.port
    }

    /// Restore the adapter's fixed-layout snapshot, checking its invariants.
    pub fn restore(generation: u64, phase: u32, port: u16) -> Option<Self> {
        let phase = match phase {
            0 => Phase::Connecting,
            1 => Phase::WaitingForDesktop,
            2 => Phase::Authenticating,
            3 => Phase::Viewing,
            4 => Phase::Ended,
            5 => Phase::Closed,
            _ => return None,
        };
        if generation == 0 || (port == 0 && !matches!(phase, Phase::Connecting | Phase::Closed)) {
            return None;
        }
        Some(Self {
            generation,
            phase,
            port,
        })
    }

    pub fn apply(&mut self, generation: u64, event: Event) -> Action {
        if generation != self.generation || self.phase == Phase::Closed {
            return Action::None;
        }
        match (self.phase, event) {
            (Phase::Connecting, Event::TunnelReady(port)) if port != 0 => {
                self.port = port;
                self.phase = Phase::WaitingForDesktop;
                Action::WaitForDesktop
            }
            (Phase::WaitingForDesktop, Event::DesktopReadyOrTimedOut) => {
                self.phase = Phase::Authenticating;
                Action::AskForSignIn
            }
            (Phase::Authenticating, Event::ViewerStarted) => {
                self.phase = Phase::Viewing;
                Action::None
            }
            (Phase::Viewing | Phase::Authenticating, Event::ViewerEnded) => {
                self.phase = Phase::Ended;
                Action::None
            }
            (Phase::Ended, Event::RetryRequested) => {
                self.phase = Phase::Authenticating;
                Action::AskForSignIn
            }
            (_, Event::Close) => {
                self.phase = Phase::Closed;
                Action::StopTunnel
            }
            _ => Action::None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn desktop_and_timeout_race_opens_only_one_prompt() {
        let mut s = LinuxSession::new(1);
        assert_eq!(s.apply(1, Event::TunnelReady(1234)), Action::WaitForDesktop);
        assert_eq!(
            s.apply(1, Event::DesktopReadyOrTimedOut),
            Action::AskForSignIn
        );
        assert_eq!(s.apply(1, Event::DesktopReadyOrTimedOut), Action::None);
        assert_eq!(s.apply(1, Event::TunnelReady(4321)), Action::None);
        assert_eq!(s.port(), 1234);
    }
    #[test]
    fn cancellation_and_stale_callbacks_cannot_reopen_a_session() {
        let mut s = LinuxSession::new(2);
        assert_eq!(s.apply(1, Event::TunnelReady(1234)), Action::None);
        assert_eq!(s.apply(2, Event::Close), Action::StopTunnel);
        assert_eq!(s.apply(2, Event::Close), Action::None);
        assert_eq!(s.apply(2, Event::TunnelReady(1234)), Action::None);
    }
    #[test]
    fn sign_in_failure_needs_a_fresh_user_submission() {
        let mut s = LinuxSession::new(1);
        s.apply(1, Event::TunnelReady(1234));
        s.apply(1, Event::DesktopReadyOrTimedOut);
        s.apply(1, Event::ViewerStarted);
        s.apply(1, Event::ViewerEnded);
        assert_eq!(s.phase(), Phase::Ended);
        assert_eq!(s.apply(1, Event::DesktopReadyOrTimedOut), Action::None);
        assert_eq!(s.apply(1, Event::RetryRequested), Action::AskForSignIn);
        assert_eq!(s.apply(1, Event::RetryRequested), Action::None);
    }
    #[test]
    fn invalid_snapshots_and_zero_ports_are_refused() {
        assert!(LinuxSession::restore(0, 0, 0).is_none());
        assert!(LinuxSession::restore(1, 99, 1).is_none());
        assert!(LinuxSession::restore(1, 3, 0).is_none());
        let mut s = LinuxSession::new(1);
        assert_eq!(s.apply(1, Event::TunnelReady(0)), Action::None);
        assert_eq!(LinuxSession::restore(1, 0, 0), Some(s));
    }
}

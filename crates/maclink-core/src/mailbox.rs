use serde::Serialize;
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::Duration;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct MailboxStats {
    pub published: u64,
    pub superseded: u64,
    pub delivered: u64,
    pub discarded_on_close: u64,
    pub pending: bool,
    pub closed: bool,
}

struct State<T> {
    latest: Option<T>,
    stats: MailboxStats,
}

#[derive(Debug)]
pub struct MailboxClosed<T>(pub T);

#[derive(Debug, PartialEq, Eq)]
pub enum MailboxRead<T> {
    Frame(T),
    Timeout,
    Closed,
}

/// A one-slot, thread-safe mailbox for raw captured frames or fully decoded frames.
/// Publishing replaces and drops any unconsumed frame, bounding producer backlog.
/// Wrap in `Arc` to share it. Consumers may independently retain frames; this bounds
/// the mailbox, not all application allocations. Do not publish interdependent
/// compressed video packets here: discarding those requires decoder-aware recovery.
pub struct LatestFrameMailbox<T> {
    state: Mutex<State<T>>,
    available: Condvar,
}

impl<T> Default for LatestFrameMailbox<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T> LatestFrameMailbox<T> {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(State {
                latest: None,
                stats: MailboxStats::default(),
            }),
            available: Condvar::new(),
        }
    }

    fn lock(&self) -> MutexGuard<'_, State<T>> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn publish(&self, frame: T) -> Result<(), MailboxClosed<T>> {
        let replaced = {
            let mut state = self.lock();
            if state.stats.closed {
                return Err(MailboxClosed(frame));
            }
            let replaced = state.latest.replace(frame);
            state.stats.published = state.stats.published.saturating_add(1);
            if replaced.is_some() {
                state.stats.superseded = state.stats.superseded.saturating_add(1);
            }
            state.stats.pending = true;
            replaced
        };
        self.available.notify_one();
        // Frame destructors can release GPU resources or execute user code.
        // Never run them while holding the mailbox lock.
        drop(replaced);
        Ok(())
    }

    pub fn take(&self) -> Option<T> {
        Self::take_locked(&mut self.lock())
    }

    fn take_locked(state: &mut State<T>) -> Option<T> {
        let frame = state.latest.take();
        if frame.is_some() {
            state.stats.delivered = state.stats.delivered.saturating_add(1);
            state.stats.pending = false;
        }
        frame
    }

    pub fn wait_take(&self, timeout: Duration) -> MailboxRead<T> {
        let (mut state, _) = self
            .available
            .wait_timeout_while(self.lock(), timeout, |state| {
                state.latest.is_none() && !state.stats.closed
            })
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(frame) = Self::take_locked(&mut state) {
            MailboxRead::Frame(frame)
        } else if state.stats.closed {
            MailboxRead::Closed
        } else {
            MailboxRead::Timeout
        }
    }

    /// Cancel waiters, reject future publications, and release a pending frame.
    pub fn close(&self) {
        let pending = {
            let mut state = self.lock();
            state.stats.closed = true;
            state.stats.pending = false;
            let pending = state.latest.take();
            if pending.is_some() {
                state.stats.discarded_on_close = state.stats.discarded_on_close.saturating_add(1);
            }
            pending
        };
        self.available.notify_all();
        drop(pending);
    }

    pub fn stats(&self) -> MailboxStats {
        self.lock().stats
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };

    #[test]
    fn a_slow_consumer_gets_only_the_latest_frame() {
        let mailbox = LatestFrameMailbox::new();
        for frame in 0..10000 {
            mailbox.publish(frame).unwrap();
        }
        assert_eq!(mailbox.stats().superseded, 9999);
        assert!(mailbox.stats().pending);
        assert_eq!(mailbox.take(), Some(9999));
        assert_eq!(mailbox.take(), None);
        assert_eq!(mailbox.stats().delivered, 1);
        assert!(!mailbox.stats().pending);
    }

    #[test]
    fn replaced_frames_are_released_and_close_cancels_waits() {
        #[derive(Debug)]
        struct Frame(Arc<AtomicUsize>);
        impl Drop for Frame {
            fn drop(&mut self) {
                self.0.fetch_add(1, Ordering::SeqCst);
            }
        }
        let dropped = Arc::new(AtomicUsize::new(0));
        let mailbox = LatestFrameMailbox::new();
        for _ in 0..20 {
            mailbox.publish(Frame(dropped.clone())).unwrap();
        }
        assert_eq!(dropped.load(Ordering::SeqCst), 19);
        mailbox.close();
        assert_eq!(dropped.load(Ordering::SeqCst), 20);
        assert!(matches!(
            mailbox.wait_take(Duration::from_secs(1)),
            MailboxRead::Closed
        ));
        assert!(mailbox.publish(Frame(dropped.clone())).is_err());
        assert_eq!(dropped.load(Ordering::SeqCst), 21);
    }

    #[test]
    fn frame_delivery_and_close_work_across_threads() {
        let mailbox = Arc::new(LatestFrameMailbox::new());
        let worker = mailbox.clone();
        let reader = std::thread::spawn(move || worker.wait_take(Duration::from_secs(2)));
        mailbox.publish(42).unwrap();
        assert_eq!(reader.join().unwrap(), MailboxRead::Frame(42));
        let worker = mailbox.clone();
        let reader = std::thread::spawn(move || worker.wait_take(Duration::from_secs(2)));
        mailbox.close();
        assert_eq!(reader.join().unwrap(), MailboxRead::Closed);
    }

    #[test]
    fn empty_mailbox_times_out_without_inventing_a_frame() {
        let mailbox = LatestFrameMailbox::<u8>::new();
        assert_eq!(mailbox.wait_take(Duration::ZERO), MailboxRead::Timeout);
        assert_eq!(mailbox.stats().delivered, 0);
    }
}

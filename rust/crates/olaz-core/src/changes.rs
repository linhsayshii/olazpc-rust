//! Dirty-key change stream pulled by Swift (`next_changes()`, D2/D3).
//!
//! High-frequency domain keys (conversations, messages, typing added in later units) coalesce in
//! place in `O(dirty keys)` memory. Low-frequency `Session` lifecycle transitions are buffered in
//! a small bounded queue (`MAX_SESSION_QUEUE`) with consecutive-duplicate coalescing so fast local
//! or loopback servers never skip intermediate login/ready transitions before Swift pulls.

use std::collections::{BTreeSet, VecDeque};
use std::sync::{Mutex, PoisonError};

use tokio::sync::Notify;

use crate::state::{CoreState, SessionSnapshot};

/// Upper bound on queued distinct session transitions; keeps hub memory strictly `O(1)`.
const MAX_SESSION_QUEUE: usize = 64;

/// Domain/entity keys dirtied by a `reduce` step.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum DirtyKey {
    Session,
}

/// Set of keys dirtied by one `reduce` step.
pub type DirtySet = BTreeSet<DirtyKey>;

/// One batch returned by [`ChangeHub::next_changes`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoreChanges {
    /// Monotonic revision of the latest change included in this batch.
    pub version: u64,
    pub session: Option<SessionSnapshot>,
}

#[derive(Default)]
struct DirtyBuffer {
    version: u64,
    dirty: DirtySet,
    session_queue: VecDeque<(u64, SessionSnapshot)>,
    closed: bool,
}

/// Change hub between the actor and the Swift `next_changes()` consumer.
pub struct ChangeHub {
    buf: Mutex<DirtyBuffer>,
    notify: Notify,
}

impl Default for ChangeHub {
    fn default() -> Self {
        Self::new()
    }
}

impl ChangeHub {
    #[must_use]
    pub fn new() -> Self {
        Self {
            buf: Mutex::new(DirtyBuffer::default()),
            notify: Notify::new(),
        }
    }

    /// Publishes any dirty keys from `state`, returning the resulting monotonic revision.
    pub fn publish(&self, dirty: &DirtySet, state: &CoreState) -> u64 {
        let mut buf = self.buf.lock().unwrap_or_else(PoisonError::into_inner);
        if dirty.is_empty() {
            return buf.version;
        }
        buf.version = buf.version.saturating_add(1);
        let version = buf.version;
        for &key in dirty {
            match key {
                DirtyKey::Session => {
                    let snap = state.session.snapshot();
                    if let Some((last_ver, last_snap)) = buf.session_queue.back_mut()
                        && *last_snap == snap
                    {
                        *last_ver = version;
                    } else {
                        if buf.session_queue.len() >= MAX_SESSION_QUEUE {
                            buf.session_queue.pop_front();
                        }
                        buf.session_queue.push_back((version, snap));
                    }
                }
            }
            buf.dirty.insert(key);
        }
        drop(buf);
        self.notify.notify_waiters();
        version
    }

    /// Current revision published to the hub.
    #[must_use]
    pub fn current_version(&self) -> u64 {
        self.buf
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .version
    }

    /// Marks the hub closed so `next_changes()` returns `None` once buffered changes are drained.
    pub fn close(&self) {
        let mut buf = self.buf.lock().unwrap_or_else(PoisonError::into_inner);
        buf.closed = true;
        drop(buf);
        self.notify.notify_waiters();
    }

    /// Waits until at least one change is pending, returning the next batch.
    /// Returns `None` after [`Self::close`] once no buffered changes remain.
    pub async fn next_changes(&self) -> Option<CoreChanges> {
        loop {
            // Register interest before checking the buffer to prevent lost wakeups.
            let notified = self.notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();

            {
                let mut buf = self.buf.lock().unwrap_or_else(PoisonError::into_inner);
                if let Some((version, session)) = buf.session_queue.pop_front() {
                    if buf.session_queue.is_empty() {
                        buf.dirty.remove(&DirtyKey::Session);
                    }
                    return Some(CoreChanges {
                        version,
                        session: Some(session),
                    });
                }
                if !buf.dirty.is_empty() {
                    buf.dirty.clear();
                    return Some(CoreChanges {
                        version: buf.version,
                        session: None,
                    });
                }
                if buf.closed {
                    return None;
                }
            }

            notified.await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::{LoginState, Phase};

    #[tokio::test]
    async fn preserves_distinct_session_transitions_and_coalesces_duplicates() {
        let hub = ChangeHub::new();
        let mut state = CoreState::default();
        let dirty = DirtySet::from([DirtyKey::Session]);

        state.session.phase = Phase::Login(LoginState::generating());
        let v1 = hub.publish(&dirty, &state);
        assert_eq!(v1, 1);

        // Identical consecutive snapshot coalesces in place with bumped revision.
        let v2 = hub.publish(&dirty, &state);
        assert_eq!(v2, 2);

        state.session.phase = Phase::Ready;
        let v3 = hub.publish(&dirty, &state);
        assert_eq!(v3, 3);

        let first = hub.next_changes().await;
        assert_eq!(first.as_ref().map(|c| c.version), Some(2));
        assert_eq!(
            first.and_then(|c| c.session).map(|s| s.phase),
            Some(Phase::Login(LoginState::generating()))
        );

        let second = hub.next_changes().await;
        assert_eq!(second.as_ref().map(|c| c.version), Some(3));
        assert_eq!(
            second.and_then(|c| c.session).map(|s| s.phase),
            Some(Phase::Ready)
        );
    }

    #[tokio::test]
    async fn close_drains_pending_then_returns_none() {
        let hub = ChangeHub::new();
        let mut state = CoreState::default();
        state.session.phase = Phase::SigningIn;
        hub.publish(&DirtySet::from([DirtyKey::Session]), &state);
        hub.close();

        let first = hub.next_changes().await;
        assert!(first.is_some());
        let second = hub.next_changes().await;
        assert!(second.is_none());
    }
}

//! Coalesced dirty-key change stream pulled by Swift (`next_changes()`, D2/D3).

use std::collections::BTreeSet;
use std::sync::{Mutex, PoisonError};

use tokio::sync::Notify;

use crate::state::{CoreState, SessionSnapshot};

/// Domain/entity keys dirtied by a `reduce` step.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum DirtyKey {
    Session,
}

/// Set of keys dirtied by one `reduce` step.
pub type DirtySet = BTreeSet<DirtyKey>;

/// One coalesced batch returned by [`ChangeHub::next_changes`].
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
    session: Option<SessionSnapshot>,
    closed: bool,
}

/// Coalescing hub between the actor and the Swift `next_changes()` consumer.
///
/// Memory is O(number of dirty keys): rapid state transitions overwrite the latest snapshot
/// until Swift pulls it.
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
        for &key in dirty {
            buf.dirty.insert(key);
            match key {
                DirtyKey::Session => {
                    buf.session = Some(state.session.snapshot());
                }
            }
        }
        let version = buf.version;
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

    /// Waits until at least one key is dirty, returns the latest values and clears the dirty set.
    /// Returns `None` after [`Self::close`] once no buffered changes remain.
    pub async fn next_changes(&self) -> Option<CoreChanges> {
        loop {
            // Register interest before checking the buffer to prevent lost wakeups.
            let notified = self.notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();

            {
                let mut buf = self.buf.lock().unwrap_or_else(PoisonError::into_inner);
                if !buf.dirty.is_empty() {
                    buf.dirty.clear();
                    let session = buf.session.take();
                    return Some(CoreChanges {
                        version: buf.version,
                        session,
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
    async fn coalesces_multiple_publishes_into_latest_snapshot() {
        let hub = ChangeHub::new();
        let mut state = CoreState::default();
        let dirty = DirtySet::from([DirtyKey::Session]);

        state.session.phase = Phase::Login(LoginState::generating());
        let v1 = hub.publish(&dirty, &state);
        assert_eq!(v1, 1);

        state.session.phase = Phase::Ready;
        let v2 = hub.publish(&dirty, &state);
        assert_eq!(v2, 2);

        let changes = hub.next_changes().await;
        assert_eq!(
            changes.as_ref().map(|c| c.version),
            Some(2),
            "only the latest version should be delivered"
        );
        assert_eq!(
            changes.and_then(|c| c.session).map(|s| s.phase),
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

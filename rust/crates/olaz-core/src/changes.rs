//! Dirty-key change stream pulled by Swift (`next_changes()`, D2/D3).
//!
//! High-frequency domain keys (conversations, flags, extras, UI, prompt) coalesce in place in
//! `O(dirty keys)` memory. Low-frequency `Session` lifecycle transitions are buffered in a small
//! bounded queue (`MAX_SESSION_QUEUE`) with consecutive-duplicate coalescing so fast local or
//! loopback servers never skip intermediate login/ready transitions before Swift pulls.

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::sync::{Mutex, PoisonError};

use tokio::sync::Notify;

use crate::conversations::{
    ConversationActionUI, ConversationActionsState, ConversationExtras, ConversationPrompt,
    ConversationSummary,
};
use crate::state::{CoreState, SessionSnapshot};
use crate::typing::TypingStatus;

/// Upper bound on queued distinct session transitions; keeps hub memory strictly `O(1)`.
const MAX_SESSION_QUEUE: usize = 64;

/// Domain/entity keys dirtied by a `reduce` step.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum DirtyKey {
    Session,
    Conversations,
    ConversationFlags,
    ConversationExtras,
    ConversationUi,
    ConversationPrompt,
    // U5
    Typing,
}

/// Set of keys dirtied by one `reduce` step.
pub type DirtySet = BTreeSet<DirtyKey>;

/// One batch returned by [`ChangeHub::next_changes`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoreChanges {
    /// Monotonic revision of the latest change included in this batch.
    pub version: u64,
    pub session: Option<SessionSnapshot>,
    pub conversations: Option<Vec<ConversationSummary>>,
    pub conversation_flags: Option<ConversationActionsState>,
    pub conversation_extras: Option<ConversationExtras>,
    pub conversation_ui: Option<ConversationActionUI>,
    /// Outer `Some(...)` means the prompt changed; inner `Option` is the new prompt (`None` = cleared).
    pub conversation_prompt: Option<Option<ConversationPrompt>>,
    // U5
    pub typing: Option<BTreeMap<String, TypingStatus>>,
}

#[derive(Default)]
struct DirtyBuffer {
    version: u64,
    dirty: DirtySet,
    session_queue: VecDeque<(u64, SessionSnapshot)>,
    conversations: Option<Vec<ConversationSummary>>,
    conversation_flags: Option<ConversationActionsState>,
    conversation_extras: Option<ConversationExtras>,
    conversation_ui: Option<ConversationActionUI>,
    conversation_prompt: Option<Option<ConversationPrompt>>,
    // U5
    typing: Option<BTreeMap<String, TypingStatus>>,
    closed: bool,
}

impl DirtyBuffer {
    fn has_domain_changes(&self) -> bool {
        self.conversations.is_some()
            || self.conversation_flags.is_some()
            || self.conversation_extras.is_some()
            || self.conversation_ui.is_some()
            || self.conversation_prompt.is_some()
            || self.typing.is_some()
    }
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
                DirtyKey::Conversations => {
                    buf.conversations = Some(state.conversations.conversations.clone());
                }
                DirtyKey::ConversationFlags => {
                    buf.conversation_flags = Some(state.conversations.actions.clone());
                }
                DirtyKey::ConversationExtras => {
                    buf.conversation_extras = Some(state.conversations.extras.clone());
                }
                DirtyKey::ConversationUi => {
                    buf.conversation_ui = Some(state.conversations.ui.clone());
                }
                DirtyKey::ConversationPrompt => {
                    buf.conversation_prompt = Some(state.conversations.prompt.clone());
                }
                // U5
                DirtyKey::Typing => {
                    buf.typing = Some(state.typing.active.clone());
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
                if buf.session_queue.len() > 1 {
                    // Drain earlier session lifecycle transitions one-by-one before attaching
                    // coalesced domain state to the latest transition.
                    if let Some((version, session)) = buf.session_queue.pop_front() {
                        return Some(CoreChanges {
                            version,
                            session: Some(session),
                            conversations: None,
                            conversation_flags: None,
                            conversation_extras: None,
                            conversation_ui: None,
                            conversation_prompt: None,
                            // U5
                            typing: None,
                        });
                    }
                }
                if buf.session_queue.len() == 1 || buf.has_domain_changes() || !buf.dirty.is_empty()
                {
                    let popped_session = buf.session_queue.pop_front();
                    let has_domains = buf.has_domain_changes();
                    let version = match (&popped_session, has_domains) {
                        (Some((sv, _)), false) => *sv,
                        _ => buf.version,
                    };
                    buf.dirty.clear();
                    return Some(CoreChanges {
                        version,
                        session: popped_session.map(|(_, s)| s),
                        conversations: buf.conversations.take(),
                        conversation_flags: buf.conversation_flags.take(),
                        conversation_extras: buf.conversation_extras.take(),
                        conversation_ui: buf.conversation_ui.take(),
                        conversation_prompt: buf.conversation_prompt.take(),
                        // U5
                        typing: buf.typing.take(),
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
    async fn coalesces_conversation_bursts_in_place_and_bundles_with_ready() {
        let hub = ChangeHub::new();
        let mut state = CoreState::default();
        state.session.phase = Phase::Ready;
        state.conversations.actions.loaded = true;
        hub.publish(
            &DirtySet::from([
                DirtyKey::Session,
                DirtyKey::Conversations,
                DirtyKey::ConversationFlags,
            ]),
            &state,
        );
        state.conversations.actions.hidden_enabled = true;
        hub.publish(&DirtySet::from([DirtyKey::ConversationFlags]), &state);

        let batch = hub.next_changes().await;
        let Some(batch) = batch else {
            panic!("expected batch");
        };
        assert_eq!(batch.version, 2);
        assert_eq!(
            batch.session.as_ref().map(|s| &s.phase),
            Some(&Phase::Ready)
        );
        assert!(batch.conversations.is_some());
        assert_eq!(
            batch.conversation_flags.as_ref().map(|f| f.hidden_enabled),
            Some(true)
        );
        assert!(batch.conversation_extras.is_none());
        assert!(batch.conversation_ui.is_none());
        assert!(batch.conversation_prompt.is_none());
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

    #[tokio::test]
    async fn typing_changes_coalesce_in_place() {
        let hub = ChangeHub::new();
        let mut state = CoreState::default();
        state.typing.active.insert(
            "3000515".to_owned(),
            TypingStatus {
                name: "Alice".to_owned(),
                on_pc: true,
            },
        );
        hub.publish(&DirtySet::from([DirtyKey::Typing]), &state);
        state.typing.active.insert(
            "g500515".to_owned(),
            TypingStatus {
                name: "Bob".to_owned(),
                on_pc: false,
            },
        );
        hub.publish(&DirtySet::from([DirtyKey::Typing]), &state);

        let Some(batch) = hub.next_changes().await else {
            panic!("expected typing batch");
        };
        assert_eq!(batch.version, 2);
        assert!(batch.session.is_none());
        let Some(typing) = batch.typing else {
            panic!("expected typing payload");
        };
        assert_eq!(typing.len(), 2);
        assert_eq!(
            typing.get("3000515"),
            Some(&TypingStatus {
                name: "Alice".to_owned(),
                on_pc: true,
            })
        );
        assert_eq!(
            typing.get("g500515"),
            Some(&TypingStatus {
                name: "Bob".to_owned(),
                on_pc: false,
            })
        );
    }
}

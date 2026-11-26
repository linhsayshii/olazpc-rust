//! Dirty-key change stream pulled by Swift (`next_changes()`, D2/D3).
//!
//! High-frequency domain keys (conversations, flags, extras, UI, prompt, contacts, message meta,
//! message windows) coalesce in place in `O(dirty keys / dirty windows)` memory. Low-frequency
//! `Session` lifecycle transitions are buffered in a small bounded queue (`MAX_SESSION_QUEUE`)
//! with consecutive-duplicate coalescing so fast local or loopback servers never skip intermediate
//! login/ready transitions before Swift pulls.

use std::collections::{BTreeMap, BTreeSet, HashSet, VecDeque};
use std::fmt;
use std::sync::{Mutex, PoisonError};

use tokio::sync::Notify;

use crate::actions::{DeleteUndoSnapshot, MessageConfirmState};
use crate::composer::ComposerConfirm;
use crate::conversations::{
    CachedGroup, CachedProfile, ConversationActionUI, ConversationActionsState, ConversationExtras,
    ConversationPrompt, ConversationSummary,
};
use crate::forward::ForwardRequest;
use crate::messages::{
    ContactsState, HistoryFreshness, PendingWindowOp, WindowDelta, coalesce_window_op,
};
use crate::state::{CoreState, SessionSnapshot};
use crate::stickers::StickerSuggestSetting;
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
    Messages,
    MessageMeta,
    MessagesResetAll,
    Contacts,
    // U5
    Typing,
    // U8
    ForwardRequest,
    ForwardClearSelection,
    // U6
    DeleteUndo,
    MessageConfirm,
    AutoDelete,
    StarredIds,
    CachedProfiles,
    CachedGroups,
    // U12
    Polls,
    // U13
    StickerSuggest,
    ComposerConfirm,
}

/// Set of keys dirtied by one `reduce` step.
pub type DirtySet = BTreeSet<DirtyKey>;

/// Snapshot of `MessagesState` paging/freshness metadata shipped via `DirtyKey::MessageMeta`.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct MessageMetaSnapshot {
    pub has_more_history: BTreeMap<String, bool>,
    pub history_ticks: BTreeMap<String, u64>,
    pub history_freshness: BTreeMap<String, HistoryFreshness>,
}

impl fmt::Debug for MessageMetaSnapshot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MessageMetaSnapshot")
            .field("has_more_history", &self.has_more_history.len())
            .field("history_ticks", &self.history_ticks.len())
            .field("history_freshness", &self.history_freshness.len())
            .finish()
    }
}

/// One batch returned by [`ChangeHub::next_changes`].
#[derive(Clone, PartialEq)]
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
    /// Coalesced per-conversation message window deltas (`Reset` / `Append` / `Patch`).
    pub window_deltas: Vec<WindowDelta>,
    /// When true, all message windows, cursors, ticks, and freshness were wiped (logout / session reset).
    pub messages_reset_all: bool,
    /// Updated `has_more_history` / `history_ticks` / `history_freshness` maps.
    pub message_meta: Option<MessageMetaSnapshot>,
    /// Updated partial-U9 contacts state.
    pub contacts: Option<ContactsState>,
    // U5
    pub typing: Option<BTreeMap<String, TypingStatus>>,
    // U8
    /// Outer `Some(...)` means the forward request changed; inner `None` means cleared.
    pub forward_request: Option<Option<ForwardRequest>>,
    /// One-shot signal telling Swift to end multi-message selection after a multi-forward succeeds.
    pub clear_selection: bool,
    // U6
    /// Outer `Some(...)` means the undo bar changed; inner `Option` is the new snapshot.
    pub delete_undo: Option<Option<DeleteUndoSnapshot>>,
    /// Outer `Some(...)` means the message-action confirmation dialog changed.
    pub message_confirm: Option<Option<MessageConfirmState>>,
    /// Outer `Some(...)` means auto-delete settings changed; inner `Option` is the new map.
    pub auto_delete: Option<Option<BTreeMap<String, i64>>>,
    /// Updated sorted starred message ids (`cachedStarredIds`).
    pub starred_ids: Option<BTreeSet<String>>,
    /// Updated cached profile map (`cachedProfiles`).
    pub cached_profiles: Option<BTreeMap<String, CachedProfile>>,
    /// Updated cached group map (`cachedGroups`).
    pub cached_groups: Option<BTreeMap<String, CachedGroup>>,
    // U12
    pub polls: Option<crate::polls::PollsState>,
    // U13
    /// Outer `Some(...)` means the sticker suggest setting changed; inner `Option` is the setting.
    pub sticker_suggest: Option<Option<StickerSuggestSetting>>,
    /// Outer `Some(...)` means the active composer confirm changed.
    pub composer_confirm: Option<Option<ComposerConfirm>>,
    /// Updated queued composer confirms.
    pub queued_composer_confirms: Option<Vec<ComposerConfirm>>,
}

impl fmt::Debug for CoreChanges {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CoreChanges")
            .field("version", &self.version)
            .field("has_session", &self.session.is_some())
            .field("has_conversations", &self.conversations.is_some())
            .field("window_deltas", &self.window_deltas.len())
            .field("messages_reset_all", &self.messages_reset_all)
            .field("has_message_meta", &self.message_meta.is_some())
            .field("has_contacts", &self.contacts.is_some())
            .field("has_typing", &self.typing.is_some())
            .field("has_forward_request", &self.forward_request.is_some())
            .field("clear_selection", &self.clear_selection)
            .field("has_cached_groups", &self.cached_groups.is_some())
            .field("has_polls", &self.polls.is_some())
            .finish()
    }
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
    /// Conversations whose base `Reset` has already been shipped in the current mirror session.
    shipped_windows: HashSet<String>,
    /// Coalesced pending op per conversation since the last `next_changes()` pull.
    pending_windows: BTreeMap<String, PendingWindowOp>,
    /// Latest window contents for conversations present in `pending_windows`.
    latest_windows: BTreeMap<String, Vec<olaz_wire::ChatMessage>>,
    messages_reset_all: bool,
    message_meta: Option<MessageMetaSnapshot>,
    contacts: Option<ContactsState>,
    // U5
    typing: Option<BTreeMap<String, TypingStatus>>,
    // U8
    forward_request: Option<Option<ForwardRequest>>,
    clear_selection: bool,
    // U6
    delete_undo: Option<Option<DeleteUndoSnapshot>>,
    message_confirm: Option<Option<MessageConfirmState>>,
    auto_delete: Option<Option<BTreeMap<String, i64>>>,
    starred_ids: Option<BTreeSet<String>>,
    cached_profiles: Option<BTreeMap<String, CachedProfile>>,
    cached_groups: Option<BTreeMap<String, CachedGroup>>,
    // U12
    polls: Option<crate::polls::PollsState>,
    // U13
    sticker_suggest: Option<Option<StickerSuggestSetting>>,
    composer_confirm: Option<Option<ComposerConfirm>>,
    queued_composer_confirms: Option<Vec<ComposerConfirm>>,
    closed: bool,
}

impl DirtyBuffer {
    fn has_domain_changes(&self) -> bool {
        self.conversations.is_some()
            || self.conversation_flags.is_some()
            || self.conversation_extras.is_some()
            || self.conversation_ui.is_some()
            || self.conversation_prompt.is_some()
            || !self.pending_windows.is_empty()
            || self.messages_reset_all
            || self.message_meta.is_some()
            || self.contacts.is_some()
            || self.typing.is_some()
            || self.forward_request.is_some()
            || self.clear_selection
            || self.delete_undo.is_some()
            || self.message_confirm.is_some()
            || self.auto_delete.is_some()
            || self.starred_ids.is_some()
            || self.cached_profiles.is_some()
            || self.cached_groups.is_some()
            || self.polls.is_some()
            || self.sticker_suggest.is_some()
            || self.composer_confirm.is_some()
            || self.queued_composer_confirms.is_some()
    }
}

/// Captures deterministic sorted `BTreeMap` copies of `MessagesState` metadata.
#[must_use]
pub fn snapshot_message_meta(state: &CoreState) -> MessageMetaSnapshot {
    MessageMetaSnapshot {
        has_more_history: state
            .messages
            .has_more_history
            .iter()
            .map(|(k, v)| (k.clone(), *v))
            .collect(),
        history_ticks: state
            .messages
            .history_ticks
            .iter()
            .map(|(k, v)| (k.clone(), *v))
            .collect(),
        history_freshness: state
            .messages
            .history_freshness
            .iter()
            .map(|(k, v)| (k.clone(), *v))
            .collect(),
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

    /// Publishes any dirty keys (and queued `window_ops`) from `state`, returning the monotonic revision.
    pub fn publish(&self, dirty: &DirtySet, state: &CoreState) -> u64 {
        self.publish_with_window_ops(dirty, &[], state)
    }

    /// Publishes dirty keys plus explicit `(conv_id, PendingWindowOp)` mutations drained from `state.messages`.
    pub fn publish_with_window_ops(
        &self,
        dirty: &DirtySet,
        window_ops: &[(String, PendingWindowOp)],
        state: &CoreState,
    ) -> u64 {
        let mut buf = self.buf.lock().unwrap_or_else(PoisonError::into_inner);
        if dirty.is_empty() && window_ops.is_empty() {
            return buf.version;
        }
        buf.version = buf.version.saturating_add(1);
        let version = buf.version;

        if dirty.contains(&DirtyKey::MessagesResetAll) {
            buf.shipped_windows.clear();
            buf.pending_windows.clear();
            buf.latest_windows.clear();
            buf.messages_reset_all = true;
            buf.message_meta = Some(snapshot_message_meta(state));
            buf.dirty.insert(DirtyKey::MessagesResetAll);
        }

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
                DirtyKey::Messages | DirtyKey::MessagesResetAll => {}
                DirtyKey::MessageMeta => {
                    buf.message_meta = Some(snapshot_message_meta(state));
                }
                DirtyKey::Contacts => {
                    buf.contacts = Some(state.contacts.clone());
                }
                // U5
                DirtyKey::Typing => {
                    buf.typing = Some(state.typing.active.clone());
                }
                // U8
                DirtyKey::ForwardRequest => {
                    buf.forward_request = Some(state.forward.request.clone());
                }
                DirtyKey::ForwardClearSelection => {
                    buf.clear_selection = true;
                }
                // U12
                DirtyKey::Polls => {
                    buf.polls = Some(state.polls.clone());
                }
                // U6
                DirtyKey::DeleteUndo => {
                    buf.delete_undo = Some(state.actions.delete_undo.snapshot());
                }
                DirtyKey::MessageConfirm => {
                    buf.message_confirm = Some(state.actions.message_confirm.clone());
                }
                DirtyKey::AutoDelete => {
                    buf.auto_delete = Some(state.actions.auto_delete.clone());
                }
                DirtyKey::StarredIds => {
                    buf.starred_ids = Some(state.actions.starred_ids.clone());
                }
                DirtyKey::CachedProfiles => {
                    buf.cached_profiles =
                        Some(state.conversations.identities.cached_profiles.clone());
                }
                DirtyKey::CachedGroups => {
                    buf.cached_groups = Some(state.conversations.identities.cached_groups.clone());
                }
                // U13
                DirtyKey::StickerSuggest => {
                    buf.sticker_suggest = Some(state.stickers.suggest_setting);
                }
                DirtyKey::ComposerConfirm => {
                    buf.composer_confirm = Some(state.composer.active_confirm.clone());
                    buf.queued_composer_confirms =
                        Some(state.composer.queued_confirms.iter().cloned().collect());
                }
            }
            buf.dirty.insert(key);
        }

        for (conv_id, op) in window_ops {
            let already_shipped = buf.shipped_windows.contains(conv_id);
            let existing = buf.pending_windows.remove(conv_id);
            let next = coalesce_window_op(already_shipped, existing, op.clone());
            match next {
                PendingWindowOp::Reset => {
                    let full = state
                        .messages
                        .windows
                        .get(conv_id)
                        .cloned()
                        .unwrap_or_default();
                    buf.latest_windows.insert(conv_id.clone(), full);
                }
                PendingWindowOp::Remove => {
                    buf.latest_windows.remove(conv_id);
                    buf.shipped_windows.remove(conv_id);
                }
                _ => {}
            }
            buf.pending_windows.insert(conv_id.clone(), next);
            buf.dirty.insert(DirtyKey::Messages);
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
                            window_deltas: Vec::new(),
                            messages_reset_all: false,
                            message_meta: None,
                            contacts: None,
                            // U5
                            typing: None,
                            // U8
                            forward_request: None,
                            clear_selection: false,
                            // U6
                            delete_undo: None,
                            message_confirm: None,
                            auto_delete: None,
                            starred_ids: None,
                            cached_profiles: None,
                            cached_groups: None,
                            // U12
                            polls: None,
                            // U13
                            sticker_suggest: None,
                            composer_confirm: None,
                            queued_composer_confirms: None,
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

                    let reset_all = std::mem::take(&mut buf.messages_reset_all);
                    let pending_windows = std::mem::take(&mut buf.pending_windows);
                    let mut latest_windows = std::mem::take(&mut buf.latest_windows);
                    let mut window_deltas = Vec::with_capacity(pending_windows.len());
                    for (conv_id, op) in pending_windows {
                        match op {
                            PendingWindowOp::Reset => {
                                let messages = latest_windows.remove(&conv_id).unwrap_or_default();
                                buf.shipped_windows.insert(conv_id.clone());
                                window_deltas.push(WindowDelta::Reset { conv_id, messages });
                            }
                            PendingWindowOp::Append(messages) => {
                                window_deltas.push(WindowDelta::Append { conv_id, messages });
                            }
                            PendingWindowOp::Patch {
                                upserts,
                                removed_ids,
                            } => {
                                window_deltas.push(WindowDelta::Patch {
                                    conv_id,
                                    upserts,
                                    removed_ids,
                                });
                            }
                            PendingWindowOp::Remove => {
                                buf.shipped_windows.remove(&conv_id);
                                window_deltas.push(WindowDelta::Remove { conv_id });
                            }
                        }
                    }

                    return Some(CoreChanges {
                        version,
                        session: popped_session.map(|(_, s)| s),
                        conversations: buf.conversations.take(),
                        conversation_flags: buf.conversation_flags.take(),
                        conversation_extras: buf.conversation_extras.take(),
                        conversation_ui: buf.conversation_ui.take(),
                        conversation_prompt: buf.conversation_prompt.take(),
                        window_deltas,
                        messages_reset_all: reset_all,
                        message_meta: buf.message_meta.take(),
                        contacts: buf.contacts.take(),
                        // U5
                        typing: buf.typing.take(),
                        // U8
                        forward_request: buf.forward_request.take(),
                        clear_selection: std::mem::take(&mut buf.clear_selection),
                        // U6
                        delete_undo: buf.delete_undo.take(),
                        message_confirm: buf.message_confirm.take(),
                        auto_delete: buf.auto_delete.take(),
                        starred_ids: buf.starred_ids.take(),
                        cached_profiles: buf.cached_profiles.take(),
                        cached_groups: buf.cached_groups.take(),
                        // U12
                        polls: buf.polls.take(),
                        // U13
                        sticker_suggest: buf.sticker_suggest.take(),
                        composer_confirm: buf.composer_confirm.take(),
                        queued_composer_confirms: buf.queued_composer_confirms.take(),
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

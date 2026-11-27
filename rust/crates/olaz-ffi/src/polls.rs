//! UniFFI records, conversions, and pure model helpers for the U12 group polls domain.
//!
//! Credentials and user-facing personal data never reach `Debug` output (ADR-008).

use std::collections::BTreeSet;
use std::fmt;

use olaz_core::conversations::ConversationsState;
use olaz_core::messages::{ContactsState, MessagesState};
use olaz_core::polls::{
    AddedPollOption, POLL_DEBOUNCE_DELAY_MS, PollAction, PollActionResult, PollCapabilities,
    PollClock, PollConfig, PollCreateDraft, PollCreateIssue, PollDetail, PollMessageNotice,
    PollOption, PollPinConfirm, PollPinOutcome, PollPinState, PollVoteDraft, PollVoterGroup,
    PollVoterUser, PollVoters, PollsState, is_group_admin_or_creator, map_poll_pin_session_error,
    normalize_poll_detail, resolve_poll_group_id,
};
use olaz_json::to_swift_json_string;
use olaz_wire::ChatMessage;
use serde_json::{Value, json};

use crate::conversations::IdentityTableRecord;
use crate::messages::ContactsStateRecord;

// ---------------------------------------------------------------------------
// Poll detail & store mirror records
// ---------------------------------------------------------------------------

/// One option row inside [`PollDetailRecord`].
#[derive(Clone, PartialEq, uniffi::Record)]
pub struct PollOptionRecord {
    pub id: String,
    pub content: String,
    pub votes: i64,
    pub voted: bool,
    /// Precomputed share of `total_votes` (`0.0..=1.0`), computed once per detail update in core.
    #[uniffi(default = 0.0)]
    pub weight: f64,
}

impl fmt::Debug for PollOptionRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollOptionRecord")
            .field("votes", &self.votes)
            .field("voted", &self.voted)
            .finish()
    }
}

impl From<PollOption> for PollOptionRecord {
    fn from(o: PollOption) -> Self {
        Self {
            id: o.id,
            content: o.content,
            votes: o.votes,
            voted: o.voted,
            weight: 0.0,
        }
    }
}

impl From<PollOptionRecord> for PollOption {
    fn from(r: PollOptionRecord) -> Self {
        Self {
            id: r.id,
            content: r.content,
            votes: r.votes,
            voted: r.voted,
        }
    }
}

/// Normalized group poll detail (`PollDetail`), including derived render fields computed once per
/// detail update in core so SwiftUI views do not cross FFI per getter.
#[derive(Clone, PartialEq, uniffi::Record)]
pub struct PollDetailRecord {
    pub id: String,
    pub group_id: String,
    pub question: String,
    pub creator: String,
    pub creator_name: String,
    pub created_ms: Option<i64>,
    pub expires_ms: Option<i64>,
    pub closed: bool,
    pub joined: bool,
    pub multi: bool,
    pub allow_add: bool,
    pub anonymous: bool,
    pub hide_preview: bool,
    pub voter_count: i64,
    pub can_close: bool,
    #[uniffi(default = 0)]
    pub total_votes: i64,
    #[uniffi(default = false)]
    pub results_hidden: bool,
    #[uniffi(default = false)]
    pub voters_visible: bool,
    #[uniffi(default = false)]
    pub locked_without_expiry: bool,
    #[uniffi(default = false)]
    pub has_duplicate_options: bool,
    pub options: Vec<PollOptionRecord>,
}

impl fmt::Debug for PollDetailRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollDetailRecord")
            .field("closed", &self.closed)
            .field("joined", &self.joined)
            .field("multi", &self.multi)
            .field("options", &self.options.len())
            .field("voter_count", &self.voter_count)
            .finish()
    }
}

impl From<PollDetail> for PollDetailRecord {
    fn from(d: PollDetail) -> Self {
        let total_votes = d.total_votes();
        let results_hidden = d.results_hidden();
        let voters_visible = d.voters_visible();
        let locked_without_expiry = d.closed || (d.hide_preview && d.joined);
        let has_duplicate_options = PollVoteDraft::new(&d).has_duplicates(&d);
        let options = d
            .options
            .iter()
            .map(|o| PollOptionRecord {
                id: o.id.clone(),
                content: o.content.clone(),
                votes: o.votes,
                voted: o.voted,
                weight: d.weight(o),
            })
            .collect();
        Self {
            id: d.id,
            group_id: d.group_id,
            question: d.question,
            creator: d.creator,
            creator_name: d.creator_name,
            created_ms: d.created_ms,
            expires_ms: d.expires_ms,
            closed: d.closed,
            joined: d.joined,
            multi: d.multi,
            allow_add: d.allow_add,
            anonymous: d.anonymous,
            hide_preview: d.hide_preview,
            voter_count: d.voter_count,
            can_close: d.can_close,
            total_votes,
            results_hidden,
            voters_visible,
            locked_without_expiry,
            has_duplicate_options,
            options,
        }
    }
}

impl From<PollDetailRecord> for PollDetail {
    fn from(r: PollDetailRecord) -> Self {
        Self {
            id: r.id,
            group_id: r.group_id,
            question: r.question,
            creator: r.creator,
            creator_name: r.creator_name,
            created_ms: r.created_ms,
            expires_ms: r.expires_ms,
            closed: r.closed,
            joined: r.joined,
            multi: r.multi,
            allow_add: r.allow_add,
            anonymous: r.anonymous,
            hide_preview: r.hide_preview,
            voter_count: r.voter_count,
            can_close: r.can_close,
            options: r.options.into_iter().map(Into::into).collect(),
        }
    }
}

/// Per-poll pin state on the group board (`PollPinState`).
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct PollPinStateRecord {
    pub ready: bool,
    pub can_pin: bool,
    pub pinned: bool,
    pub limit: i64,
}

impl From<PollPinState> for PollPinStateRecord {
    fn from(s: PollPinState) -> Self {
        Self {
            ready: s.ready,
            can_pin: s.can_pin,
            pinned: s.pinned,
            limit: s.limit,
        }
    }
}

impl From<PollPinStateRecord> for PollPinState {
    fn from(r: PollPinStateRecord) -> Self {
        Self {
            ready: r.ready,
            can_pin: r.can_pin,
            pinned: r.pinned,
            limit: r.limit,
        }
    }
}

/// Key/value entry for `PollsMirrorRecord.details`.
#[derive(Clone, PartialEq, uniffi::Record)]
pub struct PollDetailEntryRecord {
    pub id: String,
    pub detail: PollDetailRecord,
}

impl fmt::Debug for PollDetailEntryRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollDetailEntryRecord")
            .field("detail", &self.detail)
            .finish()
    }
}

/// Key/value entry for `PollsMirrorRecord.pins`.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollPinEntryRecord {
    pub id: String,
    pub state: PollPinStateRecord,
}

impl fmt::Debug for PollPinEntryRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollPinEntryRecord")
            .field("state", &self.state)
            .finish()
    }
}

/// Key/value entry for `PollsMirrorRecord.watched` (and group window poll hints).
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollWatchedEntryRecord {
    pub poll_id: String,
    pub conv_id: String,
}

impl fmt::Debug for PollWatchedEntryRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollWatchedEntryRecord")
            .field("has_poll_id", &!self.poll_id.is_empty())
            .field("has_conv_id", &!self.conv_id.is_empty())
            .finish()
    }
}

/// Key/value entry for `PollsMirrorRecord.last_attempt_ms`.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollAttemptEntryRecord {
    pub poll_id: String,
    pub last_attempt_ms: i64,
}

impl fmt::Debug for PollAttemptEntryRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollAttemptEntryRecord")
            .field("last_attempt_ms", &self.last_attempt_ms)
            .finish()
    }
}

/// Key/value entry for `PollsMirrorRecord.pending_refresh`.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollPendingRefreshEntryRecord {
    pub poll_id: String,
    pub seq: u64,
}

impl fmt::Debug for PollPendingRefreshEntryRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollPendingRefreshEntryRecord")
            .field("seq", &self.seq)
            .finish()
    }
}

/// Coalesced mirror snapshot of `CoreState.polls` (`PollStore` + `PollClock`).
#[derive(Clone, Default, PartialEq, uniffi::Record)]
pub struct PollsMirrorRecord {
    pub details: Vec<PollDetailEntryRecord>,
    pub pins: Vec<PollPinEntryRecord>,
    pub failed: Vec<String>,
    pub watched: Vec<PollWatchedEntryRecord>,
    pub last_attempt_ms: Vec<PollAttemptEntryRecord>,
    pub seen_messages: Vec<String>,
    pub did_evict_watched: bool,
    pub pending_refresh: Vec<PollPendingRefreshEntryRecord>,
    pub next_debounce_seq: u64,
    pub sync_epoch: u64,
}

impl fmt::Debug for PollsMirrorRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollsMirrorRecord")
            .field("details", &self.details.len())
            .field("pins", &self.pins.len())
            .field("failed", &self.failed.len())
            .field("watched", &self.watched.len())
            .field("seen_messages", &self.seen_messages.len())
            .field("did_evict_watched", &self.did_evict_watched)
            .field("pending_refresh", &self.pending_refresh.len())
            .field("sync_epoch", &self.sync_epoch)
            .finish()
    }
}

impl From<PollsState> for PollsMirrorRecord {
    fn from(s: PollsState) -> Self {
        let seen_messages = s.clock.seen_message_ids();
        let pending_refresh = s
            .clock
            .pending_refresh
            .into_iter()
            .map(|(poll_id, seq)| PollPendingRefreshEntryRecord { poll_id, seq })
            .collect();
        let next_debounce_seq = s.clock.next_debounce_seq;
        let sync_epoch = s.clock.sync_epoch;
        Self {
            details: s
                .details
                .into_iter()
                .map(|(id, detail)| PollDetailEntryRecord {
                    id,
                    detail: detail.into(),
                })
                .collect(),
            pins: s
                .pins
                .into_iter()
                .map(|(id, state)| PollPinEntryRecord {
                    id,
                    state: state.into(),
                })
                .collect(),
            failed: s.failed.into_iter().collect(),
            watched: s
                .clock
                .watched
                .into_iter()
                .map(|(poll_id, conv_id)| PollWatchedEntryRecord { poll_id, conv_id })
                .collect(),
            last_attempt_ms: s
                .clock
                .last_attempt_ms
                .into_iter()
                .map(|(poll_id, last_attempt_ms)| PollAttemptEntryRecord {
                    poll_id,
                    last_attempt_ms,
                })
                .collect(),
            seen_messages,
            did_evict_watched: s.clock.did_evict_watched,
            pending_refresh,
            next_debounce_seq,
            sync_epoch,
        }
    }
}

impl From<PollsMirrorRecord> for PollsState {
    fn from(r: PollsMirrorRecord) -> Self {
        let mut clock = PollClock::default();
        clock.watched = r
            .watched
            .into_iter()
            .map(|e| (e.poll_id, e.conv_id))
            .collect();
        clock.did_evict_watched = r.did_evict_watched;
        clock.last_attempt_ms = r
            .last_attempt_ms
            .into_iter()
            .map(|e| (e.poll_id, e.last_attempt_ms))
            .collect();
        clock.pending_refresh = r
            .pending_refresh
            .into_iter()
            .map(|e| (e.poll_id, e.seq))
            .collect();
        clock.next_debounce_seq = r.next_debounce_seq;
        clock.sync_epoch = r.sync_epoch;
        clock.seed_seen_messages(r.seen_messages);
        Self {
            details: r
                .details
                .into_iter()
                .map(|e| (e.id, e.detail.into()))
                .collect(),
            pins: r.pins.into_iter().map(|e| (e.id, e.state.into())).collect(),
            failed: r.failed.into_iter().collect(),
            clock,
        }
    }
}

// ---------------------------------------------------------------------------
// Voters, config, capabilities, drafts, and action outcome records
// ---------------------------------------------------------------------------

/// One voter entry in [`PollVoterGroupRecord`].
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollVoterUserRecord {
    pub uid: String,
    pub name: String,
    pub avatar: Option<String>,
    pub is_me: bool,
}

impl fmt::Debug for PollVoterUserRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollVoterUserRecord")
            .field("is_me", &self.is_me)
            .field("has_avatar", &self.avatar.is_some())
            .finish()
    }
}

impl From<PollVoterUser> for PollVoterUserRecord {
    fn from(u: PollVoterUser) -> Self {
        Self {
            uid: u.uid,
            name: u.name,
            avatar: u.avatar,
            is_me: u.is_me,
        }
    }
}

/// Per-option voter breakdown in [`PollVotersRecord`].
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollVoterGroupRecord {
    pub id: String,
    pub content: String,
    pub votes: i64,
    pub users: Vec<PollVoterUserRecord>,
}

impl fmt::Debug for PollVoterGroupRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollVoterGroupRecord")
            .field("votes", &self.votes)
            .field("users", &self.users.len())
            .finish()
    }
}

impl From<PollVoterGroup> for PollVoterGroupRecord {
    fn from(g: PollVoterGroup) -> Self {
        Self {
            id: g.id,
            content: g.content,
            votes: g.votes,
            users: g.users.into_iter().map(Into::into).collect(),
        }
    }
}

/// Full voter list for a poll (`PollVoters`).
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollVotersRecord {
    pub restricted: bool,
    pub groups: Vec<PollVoterGroupRecord>,
}

impl fmt::Debug for PollVotersRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollVotersRecord")
            .field("restricted", &self.restricted)
            .field("groups", &self.groups.len())
            .finish()
    }
}

impl From<PollVoters> for PollVotersRecord {
    fn from(v: PollVoters) -> Self {
        Self {
            restricted: v.restricted,
            groups: v.groups.into_iter().map(Into::into).collect(),
        }
    }
}

/// Official `groupPoll` limits (`PollConfig`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollConfigRecord {
    pub min_options: i64,
    pub max_options: i64,
    pub max_question: i64,
    pub max_option: i64,
    pub enable_anonymous: bool,
    pub enable_hide_preview: bool,
    pub display_options: i64,
}

impl From<PollConfig> for PollConfigRecord {
    fn from(c: PollConfig) -> Self {
        Self {
            min_options: c.min_options,
            max_options: c.max_options,
            max_question: c.max_question,
            max_option: c.max_option,
            enable_anonymous: c.enable_anonymous,
            enable_hide_preview: c.enable_hide_preview,
            display_options: c.display_options,
        }
    }
}

impl From<PollConfigRecord> for PollConfig {
    fn from(r: PollConfigRecord) -> Self {
        Self {
            min_options: r.min_options,
            max_options: r.max_options,
            max_question: r.max_question,
            max_option: r.max_option,
            enable_anonymous: r.enable_anonymous,
            enable_hide_preview: r.enable_hide_preview,
            display_options: r.display_options,
        }
    }
}

/// Conversation poll capabilities (`PollCapabilities`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollCapabilitiesRecord {
    pub ready: bool,
    pub can_create: bool,
    pub can_pin: bool,
    pub config: PollConfigRecord,
}

impl From<PollCapabilities> for PollCapabilitiesRecord {
    fn from(c: PollCapabilities) -> Self {
        Self {
            ready: c.ready,
            can_create: c.can_create,
            can_pin: c.can_pin,
            config: c.config.into(),
        }
    }
}

/// Validation failure reason for [`PollCreateDraftRecord`].
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PollCreateIssueRecord {
    EmptyQuestion,
    TooFewOptions { min: i64 },
    Duplicate,
    PastDeadline,
}

impl From<PollCreateIssue> for PollCreateIssueRecord {
    fn from(i: PollCreateIssue) -> Self {
        match i {
            PollCreateIssue::EmptyQuestion => Self::EmptyQuestion,
            PollCreateIssue::TooFewOptions(min) => Self::TooFewOptions { min },
            PollCreateIssue::Duplicate => Self::Duplicate,
            PollCreateIssue::PastDeadline => Self::PastDeadline,
        }
    }
}

/// Create-poll form model (`PollCreateDraft`).
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollCreateDraftRecord {
    pub question: String,
    pub options: Vec<String>,
    pub has_deadline: bool,
    pub deadline_ms: i64,
    pub pin: bool,
    pub multi: bool,
    pub allow_add: bool,
    pub hide_preview: bool,
    pub anonymous: bool,
}

impl fmt::Debug for PollCreateDraftRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollCreateDraftRecord")
            .field("options", &self.options.len())
            .field("has_deadline", &self.has_deadline)
            .field("pin", &self.pin)
            .field("multi", &self.multi)
            .finish()
    }
}

impl From<PollCreateDraftRecord> for PollCreateDraft {
    fn from(r: PollCreateDraftRecord) -> Self {
        Self {
            question: r.question,
            options: r.options,
            has_deadline: r.has_deadline,
            deadline_ms: r.deadline_ms,
            pin: r.pin,
            multi: r.multi,
            allow_add: r.allow_add,
            hide_preview: r.hide_preview,
            anonymous: r.anonymous,
        }
    }
}

/// One newly added option row inside [`PollVoteDraftRecord`].
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct AddedPollOptionRecord {
    pub id: String,
    pub text: String,
    pub voted: bool,
    #[uniffi(default = false)]
    pub is_duplicate: bool,
}

impl fmt::Debug for AddedPollOptionRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AddedPollOptionRecord")
            .field("voted", &self.voted)
            .field("is_duplicate", &self.is_duplicate)
            .finish()
    }
}

impl From<AddedPollOption> for AddedPollOptionRecord {
    fn from(a: AddedPollOption) -> Self {
        Self {
            id: a.id,
            text: a.text,
            voted: a.voted,
            is_duplicate: false,
        }
    }
}

impl From<AddedPollOptionRecord> for AddedPollOption {
    fn from(r: AddedPollOptionRecord) -> Self {
        Self {
            id: r.id,
            text: r.text,
            voted: r.voted,
        }
    }
}

/// Vote form state (`PollVoteDraft`), with derived render fields (`has_changes`, `votes_nothing`,
/// `has_duplicates`, per-row `is_duplicate`, and `applied`) computed once per draft mutation in core.
#[derive(Clone, PartialEq, uniffi::Record)]
pub struct PollVoteDraftRecord {
    pub selected: Vec<String>,
    pub original: Vec<String>,
    pub multi: bool,
    pub added: Vec<AddedPollOptionRecord>,
    #[uniffi(default = false)]
    pub selection_changed: bool,
    #[uniffi(default = true)]
    pub selection_empty: bool,
    #[uniffi(default = false)]
    pub has_changes: bool,
    #[uniffi(default = true)]
    pub votes_nothing: bool,
    #[uniffi(default = false)]
    pub has_duplicates: bool,
    #[uniffi(default = None)]
    pub applied: Option<PollDetailRecord>,
}

impl fmt::Debug for PollVoteDraftRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollVoteDraftRecord")
            .field("selected", &self.selected.len())
            .field("added", &self.added.len())
            .field("multi", &self.multi)
            .field("has_changes", &self.has_changes)
            .field("votes_nothing", &self.votes_nothing)
            .field("has_duplicates", &self.has_duplicates)
            .finish()
    }
}

impl PollVoteDraftRecord {
    #[must_use]
    pub fn from_draft_and_detail(d: PollVoteDraft, detail: Option<&PollDetail>) -> Self {
        let selection_changed = d.selected() != d.original();
        let selection_empty = d.selected().is_empty();
        let has_changes = d.has_changes();
        let votes_nothing = d.votes_nothing();
        let (has_duplicates, applied, added) = if let Some(det) = detail {
            let has_dups = d.has_duplicates(det);
            let app: PollDetailRecord = d.applied(det).into();
            let rows = d
                .added
                .iter()
                .map(|a| AddedPollOptionRecord {
                    id: a.id.clone(),
                    text: a.text.clone(),
                    voted: a.voted,
                    is_duplicate: d.is_duplicate(&a.id, det),
                })
                .collect();
            (has_dups, Some(app), rows)
        } else {
            let empty_det = PollDetail {
                id: String::new(),
                group_id: String::new(),
                question: String::new(),
                creator: String::new(),
                creator_name: String::new(),
                created_ms: None,
                expires_ms: None,
                closed: false,
                joined: false,
                multi: d.multi(),
                allow_add: true,
                anonymous: false,
                hide_preview: false,
                voter_count: 0,
                can_close: false,
                options: Vec::new(),
            };
            let has_dups = d.has_duplicates(&empty_det);
            let rows = d
                .added
                .iter()
                .map(|a| AddedPollOptionRecord {
                    id: a.id.clone(),
                    text: a.text.clone(),
                    voted: a.voted,
                    is_duplicate: d.is_duplicate(&a.id, &empty_det),
                })
                .collect();
            (has_dups, None, rows)
        };
        let selected = d.selected().iter().cloned().collect();
        let original = d.original().iter().cloned().collect();
        let multi = d.multi();
        Self {
            selected,
            original,
            multi,
            added,
            selection_changed,
            selection_empty,
            has_changes,
            votes_nothing,
            has_duplicates,
            applied,
        }
    }
}

impl From<PollVoteDraft> for PollVoteDraftRecord {
    fn from(d: PollVoteDraft) -> Self {
        Self::from_draft_and_detail(d, None)
    }
}

impl From<PollVoteDraftRecord> for PollVoteDraft {
    fn from(r: PollVoteDraftRecord) -> Self {
        Self::from_parts(
            r.selected.into_iter().collect::<BTreeSet<_>>(),
            r.original.into_iter().collect::<BTreeSet<_>>(),
            r.multi,
            r.added.into_iter().map(Into::into).collect(),
        )
    }
}

/// New option payload entry in [`PollVoteRequestRecord`].
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollNewOptionPayloadRecord {
    pub content: String,
    pub voted: bool,
}

impl fmt::Debug for PollNewOptionPayloadRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollNewOptionPayloadRecord")
            .field("voted", &self.voted)
            .finish()
    }
}

/// Request arguments built by `PollVoteDraft.request(for:)`.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollVoteRequestRecord {
    pub new_options: Vec<PollNewOptionPayloadRecord>,
    pub voted_ids: Vec<String>,
}

impl fmt::Debug for PollVoteRequestRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollVoteRequestRecord")
            .field("new_options", &self.new_options.len())
            .field("voted_ids", &self.voted_ids.len())
            .finish()
    }
}

/// Poll action kind (`PollAction`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PollActionRecord {
    Vote,
    Lock,
    Share,
    Create,
    Pin,
    Unpin,
}

impl From<PollActionRecord> for PollAction {
    fn from(r: PollActionRecord) -> Self {
        match r {
            PollActionRecord::Vote => Self::Vote,
            PollActionRecord::Lock => Self::Lock,
            PollActionRecord::Share => Self::Share,
            PollActionRecord::Create => Self::Create,
            PollActionRecord::Pin => Self::Pin,
            PollActionRecord::Unpin => Self::Unpin,
        }
    }
}

/// Outcome of a poll mutation (`PollActionResult`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollActionResultRecord {
    pub ok: bool,
    pub error: Option<String>,
    pub pin_skipped: bool,
}

impl From<PollActionResult> for PollActionResultRecord {
    fn from(r: PollActionResult) -> Self {
        Self {
            ok: r.ok,
            error: r.error,
            pin_skipped: r.pin_skipped,
        }
    }
}

impl From<PollActionResultRecord> for PollActionResult {
    fn from(r: PollActionResultRecord) -> Self {
        Self {
            ok: r.ok,
            error: r.error,
            pin_skipped: r.pin_skipped,
        }
    }
}

/// Replace-oldest-pin confirmation payload (`PollPinConfirm`).
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollPinConfirmRecord {
    pub ref_id: String,
    pub limit: i64,
    pub kind: String,
    pub title: String,
}

impl fmt::Debug for PollPinConfirmRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollPinConfirmRecord")
            .field("limit", &self.limit)
            .field("kind", &self.kind)
            .finish()
    }
}

impl From<PollPinConfirm> for PollPinConfirmRecord {
    fn from(c: PollPinConfirm) -> Self {
        Self {
            ref_id: c.ref_id,
            limit: c.limit,
            kind: c.kind,
            title: c.title,
        }
    }
}

impl From<PollPinConfirmRecord> for PollPinConfirm {
    fn from(r: PollPinConfirmRecord) -> Self {
        Self {
            ref_id: r.ref_id,
            limit: r.limit,
            kind: r.kind,
            title: r.title,
        }
    }
}

/// Outcome of `pinPoll` (`PollPinOutcome`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PollPinOutcomeRecord {
    Done,
    NeedsConfirmation { confirm: PollPinConfirmRecord },
    Failed { result: PollActionResultRecord },
}

impl From<PollPinOutcome> for PollPinOutcomeRecord {
    fn from(o: PollPinOutcome) -> Self {
        match o {
            PollPinOutcome::Done => Self::Done,
            PollPinOutcome::NeedsConfirmation(confirm) => Self::NeedsConfirmation {
                confirm: confirm.into(),
            },
            PollPinOutcome::Failed(result) => Self::Failed {
                result: result.into(),
            },
        }
    }
}

/// Minimal poll message notice passed into `notePollMessages`.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollMessageNoticeRecord {
    pub msg_id: String,
    pub poll_id: String,
    pub conv_id: String,
    pub date_ms: i64,
}

impl fmt::Debug for PollMessageNoticeRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollMessageNoticeRecord")
            .field("date_ms", &self.date_ms)
            .finish()
    }
}

impl From<PollMessageNoticeRecord> for PollMessageNotice {
    fn from(r: PollMessageNoticeRecord) -> Self {
        Self {
            msg_id: r.msg_id,
            poll_id: r.poll_id,
            conv_id: r.conv_id,
            date_ms: r.date_ms,
        }
    }
}

/// Debounce timer instruction produced synchronously for `@MainActor` `notePollMessages`.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollDebounceArmRecord {
    pub poll_id: String,
    pub seq: u64,
    pub delay_ms: u64,
}

impl fmt::Debug for PollDebounceArmRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollDebounceArmRecord")
            .field("seq", &self.seq)
            .field("delay_ms", &self.delay_ms)
            .finish()
    }
}

/// Output of [`apply_note_poll_messages_ffi`].
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct NotePollMessagesPlanRecord {
    pub mirror: PollsMirrorRecord,
    pub armed: Vec<PollDebounceArmRecord>,
}

/// Versioned return of `CoreEngine::refresh_poll_pin`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollPinStateOutcomeRecord {
    pub state: PollPinStateRecord,
    pub version: u64,
}

/// Versioned return of `CoreEngine::pin_poll`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollPinActionOutcomeRecord {
    pub outcome: PollPinOutcomeRecord,
    pub version: u64,
}

/// Versioned return of `CoreEngine::vote_poll` / `lock_poll` / `share_poll` / `create_poll` / `unpin_poll`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollActionOutcomeRecord {
    pub result: PollActionResultRecord,
    pub version: u64,
}

/// Versioned return of `CoreEngine::poll_voters`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollVotersOutcomeRecord {
    pub voters: Option<PollVotersRecord>,
    pub version: u64,
}

/// Versioned return of `CoreEngine::poll_capabilities`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollCapabilitiesOutcomeRecord {
    pub capabilities: PollCapabilitiesRecord,
    pub version: u64,
}

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Pure FFI exports for Swift poll models, views, and offline unit tests
// ---------------------------------------------------------------------------

#[uniffi::export]
#[must_use]
pub fn poll_detail_from_json(json: String) -> Option<PollDetailRecord> {
    let obj = olaz_json::parse_object_str(&json)?;
    PollDetail::from_json(&obj).map(Into::into)
}

#[uniffi::export]
#[must_use]
pub fn poll_detail_to_json(detail: PollDetailRecord) -> String {
    let options: Vec<Value> = detail
        .options
        .into_iter()
        .map(|o| {
            json!({
                "id": o.id,
                "content": o.content,
                "votes": o.votes,
                "voted": o.voted,
            })
        })
        .collect();
    let val = json!({
        "id": detail.id,
        "groupId": detail.group_id,
        "question": detail.question,
        "creator": detail.creator,
        "creatorName": detail.creator_name,
        "created": detail.created_ms.unwrap_or(0),
        "expired": detail.expires_ms.unwrap_or(0),
        "closed": detail.closed,
        "joined": detail.joined,
        "multi": detail.multi,
        "allowAdd": detail.allow_add,
        "anonymous": detail.anonymous,
        "hidePreview": detail.hide_preview,
        "voters": detail.voter_count,
        "canClose": detail.can_close,
        "options": options,
    });
    to_swift_json_string(&val)
}

#[uniffi::export]
#[must_use]
pub fn poll_detail_total_votes(detail: PollDetailRecord) -> i64 {
    let d: PollDetail = detail.into();
    d.total_votes()
}

#[uniffi::export]
#[must_use]
pub fn poll_detail_is_expired(detail: PollDetailRecord, now_ms: i64) -> bool {
    let d: PollDetail = detail.into();
    d.is_expired_at(now_ms)
}

#[uniffi::export]
#[must_use]
pub fn poll_detail_is_voting_locked(detail: PollDetailRecord, now_ms: i64) -> bool {
    let d: PollDetail = detail.into();
    d.is_voting_locked_at(now_ms)
}

#[uniffi::export]
#[must_use]
pub fn poll_detail_results_hidden(detail: PollDetailRecord) -> bool {
    let d: PollDetail = detail.into();
    d.results_hidden()
}

#[uniffi::export]
#[must_use]
pub fn poll_detail_voters_visible(detail: PollDetailRecord) -> bool {
    let d: PollDetail = detail.into();
    d.voters_visible()
}

#[uniffi::export]
#[must_use]
pub fn poll_detail_option_weight(detail: PollDetailRecord, option: PollOptionRecord) -> f64 {
    let d: PollDetail = detail.into();
    let o: PollOption = option.into();
    d.weight(&o)
}

#[uniffi::export]
#[must_use]
pub fn poll_voters_from_json(json: String) -> Option<PollVotersRecord> {
    let obj = olaz_json::parse_object_str(&json)?;
    Some(PollVoters::from_json(&obj).into())
}

#[uniffi::export]
#[must_use]
pub fn poll_config_default() -> PollConfigRecord {
    PollConfig::default().into()
}

#[uniffi::export]
#[must_use]
pub fn poll_config_from_json(json: Option<String>) -> PollConfigRecord {
    let obj = json.as_deref().and_then(olaz_json::parse_object_str);
    PollConfig::from_json(obj.as_ref()).into()
}

#[uniffi::export]
#[must_use]
pub fn poll_capabilities_from_json(json: Option<String>) -> PollCapabilitiesRecord {
    let obj = json.as_deref().and_then(olaz_json::parse_object_str);
    PollCapabilities::from_json(obj.as_ref()).into()
}

#[uniffi::export]
#[must_use]
pub fn poll_capabilities_for_conversation(conv_id: String) -> PollCapabilitiesRecord {
    PollCapabilities::for_conversation(&conv_id).into()
}

#[uniffi::export]
#[must_use]
pub fn poll_pin_state_from_json(json: Option<String>) -> PollPinStateRecord {
    let obj = json.as_deref().and_then(olaz_json::parse_object_str);
    PollPinState::from_json(obj.as_ref()).into()
}

#[uniffi::export]
#[must_use]
pub fn poll_pin_confirm_from_json(json: Option<String>) -> Option<PollPinConfirmRecord> {
    let obj = json.as_deref().and_then(olaz_json::parse_object_str)?;
    let ref_id = obj.get("ref").and_then(Value::as_str)?;
    if ref_id.is_empty() {
        return None;
    }
    let limit_f64 = match obj.get("limit") {
        Some(Value::Number(n)) => n.as_f64().unwrap_or(0.0),
        _ => 0.0,
    };
    let limit = olaz_core::clamped_int64(limit_f64).max(0);
    let replace = obj.get("replace").and_then(Value::as_object);
    let kind = replace
        .and_then(|r| r.get("kind"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let title = replace
        .and_then(|r| r.get("title"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    Some(PollPinConfirmRecord {
        ref_id: ref_id.to_owned(),
        limit,
        kind,
        title,
    })
}

#[uniffi::export]
#[must_use]
pub fn poll_pin_confirm_message(confirm: PollPinConfirmRecord) -> String {
    let c: PollPinConfirm = confirm.into();
    c.message()
}

#[uniffi::export]
#[must_use]
pub fn poll_action_result_message(
    result: PollActionResultRecord,
    action: PollActionRecord,
) -> String {
    let r: PollActionResult = result.into();
    r.message(action.into()).to_owned()
}

#[uniffi::export]
#[must_use]
pub fn poll_vote_draft_new(detail: PollDetailRecord) -> PollVoteDraftRecord {
    let d: PollDetail = detail.into();
    let draft = PollVoteDraft::new(&d);
    PollVoteDraftRecord::from_draft_and_detail(draft, Some(&d))
}

#[uniffi::export]
#[must_use]
pub fn poll_vote_draft_recompute(
    draft: PollVoteDraftRecord,
    detail: Option<PollDetailRecord>,
) -> PollVoteDraftRecord {
    let d: PollVoteDraft = draft.into();
    let det: Option<PollDetail> = detail.map(Into::into);
    PollVoteDraftRecord::from_draft_and_detail(d, det.as_ref())
}

#[uniffi::export]
#[must_use]
pub fn poll_vote_draft_toggle(
    draft: PollVoteDraftRecord,
    option_id: String,
    detail: Option<PollDetailRecord>,
) -> PollVoteDraftRecord {
    let mut d: PollVoteDraft = draft.into();
    d.toggle(&option_id);
    let det: Option<PollDetail> = detail.map(Into::into);
    PollVoteDraftRecord::from_draft_and_detail(d, det.as_ref())
}

#[uniffi::export]
#[must_use]
pub fn poll_vote_draft_set_added_voted(
    draft: PollVoteDraftRecord,
    id: String,
    voted: bool,
    detail: Option<PollDetailRecord>,
) -> PollVoteDraftRecord {
    let mut d: PollVoteDraft = draft.into();
    d.set_added_voted(&id, voted);
    let det: Option<PollDetail> = detail.map(Into::into);
    PollVoteDraftRecord::from_draft_and_detail(d, det.as_ref())
}

#[uniffi::export]
#[must_use]
pub fn poll_vote_draft_has_changes(draft: PollVoteDraftRecord) -> bool {
    let d: PollVoteDraft = draft.into();
    d.has_changes()
}

#[uniffi::export]
#[must_use]
pub fn poll_vote_draft_votes_nothing(draft: PollVoteDraftRecord) -> bool {
    let d: PollVoteDraft = draft.into();
    d.votes_nothing()
}

#[uniffi::export]
#[must_use]
pub fn poll_vote_draft_has_duplicates(
    draft: PollVoteDraftRecord,
    detail: PollDetailRecord,
) -> bool {
    let dr: PollVoteDraft = draft.into();
    let de: PollDetail = detail.into();
    dr.has_duplicates(&de)
}

#[uniffi::export]
#[must_use]
pub fn poll_vote_draft_is_duplicate(
    draft: PollVoteDraftRecord,
    id: String,
    detail: PollDetailRecord,
) -> bool {
    let dr: PollVoteDraft = draft.into();
    let de: PollDetail = detail.into();
    dr.is_duplicate(&id, &de)
}

#[uniffi::export]
#[must_use]
pub fn poll_vote_draft_request(
    draft: PollVoteDraftRecord,
    detail: PollDetailRecord,
) -> PollVoteRequestRecord {
    let dr: PollVoteDraft = draft.into();
    let de: PollDetail = detail.into();
    let (new_opts, voted_ids) = dr.request(&de);
    PollVoteRequestRecord {
        new_options: new_opts
            .into_iter()
            .map(|o| PollNewOptionPayloadRecord {
                content: o.content,
                voted: o.voted,
            })
            .collect(),
        voted_ids,
    }
}

#[uniffi::export]
#[must_use]
pub fn poll_vote_draft_applied(
    draft: PollVoteDraftRecord,
    detail: PollDetailRecord,
) -> PollDetailRecord {
    let dr: PollVoteDraft = draft.into();
    let de: PollDetail = detail.into();
    dr.applied(&de).into()
}

#[uniffi::export]
#[must_use]
pub fn poll_create_draft_is_duplicate(draft: PollCreateDraftRecord, index: u64) -> bool {
    let d: PollCreateDraft = draft.into();
    usize::try_from(index).is_ok_and(|idx| d.is_duplicate(idx))
}

#[uniffi::export]
#[must_use]
pub fn poll_create_draft_issue(
    draft: PollCreateDraftRecord,
    config: PollConfigRecord,
    now_ms: i64,
) -> Option<PollCreateIssueRecord> {
    let d: PollCreateDraft = draft.into();
    let c: PollConfig = config.into();
    d.issue(&c, now_ms).map(Into::into)
}

#[uniffi::export]
#[must_use]
pub fn poll_create_draft_spec_json(
    draft: PollCreateDraftRecord,
    config: PollConfigRecord,
    can_pin: bool,
) -> String {
    let d: PollCreateDraft = draft.into();
    let c: PollConfig = config.into();
    to_swift_json_string(&d.spec(&c, can_pin))
}

#[uniffi::export]
#[must_use]
pub fn map_poll_pin_session_error_ffi(
    code: i64,
    message: String,
    partial: bool,
) -> PollActionResultRecord {
    map_poll_pin_session_error(code, &message, partial).into()
}

#[uniffi::export]
#[must_use]
pub fn map_poll_pin_transport_error_ffi(
    is_network_or_transport: bool,
    partial: bool,
) -> PollActionResultRecord {
    if partial {
        PollActionResult::err(Some("partial")).into()
    } else if is_network_or_transport {
        PollActionResult::err(Some("network")).into()
    } else {
        PollActionResult::err(None).into()
    }
}

#[uniffi::export]
#[must_use]
pub fn apply_note_poll_messages_ffi(
    mirror: PollsMirrorRecord,
    notices: Vec<PollMessageNoticeRecord>,
    now_ms: i64,
) -> NotePollMessagesPlanRecord {
    let mut polls: PollsState = mirror.into();
    let core_notices: Vec<PollMessageNotice> = notices.into_iter().map(Into::into).collect();
    let armed = polls
        .note_poll_messages(&core_notices, now_ms)
        .into_iter()
        .map(|(poll_id, seq)| PollDebounceArmRecord {
            poll_id,
            seq,
            delay_ms: POLL_DEBOUNCE_DELAY_MS,
        })
        .collect();
    NotePollMessagesPlanRecord {
        mirror: polls.into(),
        armed,
    }
}

#[uniffi::export]
#[must_use]
pub fn apply_poll_state_event_ffi(
    mirror: PollsMirrorRecord,
    state_json: String,
) -> Option<PollsMirrorRecord> {
    let obj = olaz_json::parse_object_str(&state_json)?;
    let mut polls: PollsState = mirror.into();
    polls.apply_poll_state_event(&obj).then(|| polls.into())
}

#[uniffi::export]
#[must_use]
pub fn resolve_poll_group_id_ffi(
    poll_id: String,
    payload_json: String,
    explicit_group_id: Option<String>,
    watched_group_id: Option<String>,
    previous_detail_group_id: Option<String>,
    group_window_poll_hits: Vec<PollWatchedEntryRecord>,
) -> String {
    let payload = olaz_json::parse_object_str(&payload_json).unwrap_or_default();
    let mut polls = PollsState::default();
    if let Some(wg) = watched_group_id {
        polls.clock.watched.insert(poll_id.clone(), wg);
    }
    if let Some(pg) = previous_detail_group_id {
        let seed = json!({
            "id": poll_id,
            "groupId": pg,
            "question": "",
        });
        if let Some(d) = seed.as_object().and_then(PollDetail::from_json) {
            polls.details.insert(poll_id.clone(), d);
        }
    }
    let mut messages = MessagesState::default();
    for hit in group_window_poll_hits {
        let seed_msg = json!({
            "id": format!("hit-{}", hit.poll_id),
            "conversationId": hit.conv_id,
            "kind": {
                "type": "poll",
                "question": "",
                "pollId": hit.poll_id,
                "conversationId": hit.conv_id,
            },
        });
        if let Some(msg) = seed_msg
            .as_object()
            .and_then(|obj| ChatMessage::from_json(obj, &hit.conv_id))
        {
            messages.windows.entry(hit.conv_id).or_default().push(msg);
        }
    }
    resolve_poll_group_id(
        &poll_id,
        &payload,
        explicit_group_id.as_deref(),
        &polls,
        &messages,
    )
}

#[uniffi::export]
#[must_use]
pub fn is_group_admin_or_creator_ffi(
    uid: String,
    group_id: String,
    contacts: ContactsStateRecord,
) -> bool {
    let groups = olaz_core::GroupsState {
        details_json: contacts
            .group_details_json
            .into_iter()
            .map(|p| (p.key, p.value))
            .collect(),
        ..olaz_core::GroupsState::default()
    };
    is_group_admin_or_creator(&uid, &group_id, &groups)
}

#[uniffi::export]
#[must_use]
pub fn normalize_poll_detail_ffi(
    payload_json: String,
    poll_id: String,
    resolved_group_id: String,
    my_uid: String,
    my_avatar: Option<String>,
    contacts: ContactsStateRecord,
    identities: IdentityTableRecord,
) -> Option<PollDetailRecord> {
    let payload = olaz_json::parse_object_str(&payload_json)?;
    let polls = PollsState::default();
    let mut groups = olaz_core::GroupsState {
        details_json: contacts
            .group_details_json
            .iter()
            .map(|p| (p.key.clone(), p.value.clone()))
            .collect(),
        ..olaz_core::GroupsState::default()
    };
    let mut c: ContactsState = contacts.into();
    c.apply_identity_table(identities.into(), &mut groups);
    let convs = ConversationsState::default();
    let messages = MessagesState::default();
    let explicit = (!resolved_group_id.is_empty()).then_some(resolved_group_id.as_str());
    normalize_poll_detail(
        &payload,
        &poll_id,
        explicit,
        &my_uid,
        my_avatar.as_deref(),
        &polls,
        &c,
        &groups,
        &convs,
        &messages,
    )
    .map(Into::into)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn poll_detail_record_precomputes_derived_render_fields() {
        let raw = json!({
            "id": "p1",
            "groupId": "g1",
            "question": "Ăn gì?",
            "creator": "5",
            "creatorName": "Lan",
            "created": 1_700_000_000_000_i64,
            "expired": 1_900_000_000_000_i64,
            "closed": false,
            "joined": true,
            "multi": true,
            "allowAdd": true,
            "anonymous": false,
            "hidePreview": true,
            "voters": 3,
            "canClose": true,
            "options": [
                {"id": "1", "content": "Phở", "votes": 2, "voted": true},
                {"id": "2", "content": "Bún", "votes": 1, "voted": false},
                {"id": "3", "content": "Cơm", "votes": 0, "voted": false}
            ]
        });
        let maybe_detail = raw.as_object().and_then(PollDetail::from_json);
        assert!(maybe_detail.is_some());
        let Some(detail) = maybe_detail else {
            return;
        };
        let rec = PollDetailRecord::from(detail);
        assert_eq!(rec.total_votes, 3);
        assert!(!rec.results_hidden);
        assert!(rec.voters_visible);
        assert!(rec.locked_without_expiry);
        assert!(!rec.has_duplicate_options);
        assert!((rec.options[0].weight - 2.0 / 3.0).abs() < 1e-9);
        assert!((rec.options[1].weight - 1.0 / 3.0).abs() < 1e-9);
        assert!(rec.options[2].weight.abs() < 1e-9);
    }

    #[test]
    fn poll_ffi_records_redact_sensitive_fields_in_debug() {
        let detail = PollDetailRecord {
            id: "SECRET_POLL_ID".to_owned(),
            group_id: "SECRET_GROUP_ID".to_owned(),
            question: "SECRET_QUESTION".to_owned(),
            creator: "SECRET_UID".to_owned(),
            creator_name: "SECRET_NAME".to_owned(),
            created_ms: Some(1_700_000_000_000),
            expires_ms: None,
            closed: false,
            joined: true,
            multi: true,
            allow_add: true,
            anonymous: false,
            hide_preview: false,
            voter_count: 1,
            can_close: true,
            total_votes: 1,
            results_hidden: false,
            voters_visible: true,
            locked_without_expiry: false,
            has_duplicate_options: false,
            options: vec![PollOptionRecord {
                id: "SECRET_OPT_ID".to_owned(),
                content: "SECRET_OPT_TEXT".to_owned(),
                votes: 1,
                voted: true,
                weight: 1.0,
            }],
        };
        let voters = PollVotersRecord {
            restricted: false,
            groups: vec![PollVoterGroupRecord {
                id: "SECRET_OPT_ID".to_owned(),
                content: "SECRET_OPT_TEXT".to_owned(),
                votes: 1,
                users: vec![PollVoterUserRecord {
                    uid: "SECRET_UID".to_owned(),
                    name: "SECRET_NAME".to_owned(),
                    avatar: Some("https://secret.example/a.jpg".to_owned()),
                    is_me: false,
                }],
            }],
        };
        let dbg = format!("{detail:?} {voters:?}");
        for secret in [
            "SECRET_POLL_ID",
            "SECRET_GROUP_ID",
            "SECRET_QUESTION",
            "SECRET_UID",
            "SECRET_NAME",
            "SECRET_OPT_ID",
            "SECRET_OPT_TEXT",
            "https://secret.example/a.jpg",
        ] {
            assert!(!dbg.contains(secret), "leaked {secret} in {dbg}");
        }
    }
}

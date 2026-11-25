//! Group polls domain state, pure models, clock/timers, and shared group-metadata merge (U12).
//!
//! Mirrors `ZaloEngine+Poll.swift` with the four user-approved fixes (`user-decisions` item 8):
//! 1. `friend_board` default service host (`olaz-net::domains`).
//! 2. `refresh_poll_pin_state` uses the cached board's `limit` (`0` when uncached or 1-1).
//! 3. Voter and creator UIDs use [`normalize_poll_uid`] (U9 `sanitize_profile_uid` fallback to
//!    `strip_user_prefix`) and a single unknown-name default ([`UNKNOWN_POLL_USER_NAME`]).
//! 4. `PollClock` deduplicates poll event messages in a 2,000-entry FIFO queue instead of clearing.
//!
//! [`merge_fetched_group_metadata`] is shared between U12 (`refreshPoll` missing-group fetch) and
//! U10 (`refreshGroupMetadata` in group management).

use std::collections::{BTreeMap, BTreeSet, HashSet, VecDeque};
use std::fmt;

use olaz_api::{JsonObject, NewPollOptionPayload, clean_group_member_ids};
use olaz_net::{NetError, ZaloSessionError};
use olaz_store::StoredConversation;
use olaz_wire::{
    Kind, clean_group_id, group_conv_id, is_group_id, lossless, sanitize_profile_uid,
    strip_user_prefix,
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::conversations::{
    CachedGroup, ConversationSummary, ConversationsState, GroupIdentity, sort_conversations,
};
use crate::messages::{
    ContactsState, GroupEntry, IdentitySnapshot, MessagesState, fold_contact_str, is_valid_url_str,
    localized_standard_cmp, serialize_cached_groups_json,
};

/// Unified fallback display name for unknown poll creators and voters (Approved Fix #3).
pub const UNKNOWN_POLL_USER_NAME: &str = "Người dùng Zalo";

/// Maximum watched polls retained in [`PollClock`] before evicting an existing entry.
pub const MAX_WATCHED_POLLS: usize = 500;

/// Maximum seen poll-event message IDs retained in [`PollClock`] (Approved Fix #4: FIFO eviction).
pub const MAX_SEEN_POLL_MESSAGES: usize = 2_000;

/// Minimum interval (ms) between automatic `watchPoll` fetch attempts for the same poll.
pub const WATCH_POLL_THROTTLE_MS: i64 = 5_000;

/// Maximum age (ms) of an incoming poll message eligible to trigger a debounced refresh (120 s).
pub const POLL_MESSAGE_MAX_AGE_MS: i64 = 120_000;

/// Debounce delay (ms) coalescing incoming poll messages before refreshing poll detail (1.5 s).
pub const POLL_DEBOUNCE_DELAY_MS: u64 = 1_500;

/// Upper bound (`2100-01-01T00:00:00Z` in ms) used by `PollDetail.init?(json:)` for valid timestamps.
const MAX_VALID_POLL_DATE_MS: f64 = 4_102_444_800_000.0;

/// Port of Swift `clampedInt(_ value: Double) -> Int64`.
#[must_use]
pub fn clamped_int64(value: f64) -> i64 {
    if !value.is_finite() {
        return 0;
    }
    #[expect(
        clippy::cast_possible_truncation,
        reason = "clamped to [-9e15, 9e15], well within i64 range"
    )]
    let out = value.clamp(-9e15, 9e15) as i64;
    out
}

/// Normalizes a user ID for poll creator/voter matching (Approved Fix #3, U9 normalizer).
#[must_use]
pub fn normalize_poll_uid(raw: &str) -> String {
    sanitize_profile_uid(raw).unwrap_or_else(|| strip_user_prefix(raw))
}

fn nsnumber_f64(val: Option<&Value>) -> Option<f64> {
    match val? {
        Value::Number(n) => n.as_f64(),
        Value::Bool(b) => Some(if *b { 1.0 } else { 0.0 }),
        _ => None,
    }
}

fn nsnumber_bool(val: Option<&Value>) -> Option<bool> {
    match val? {
        Value::Bool(b) => Some(*b),
        Value::Number(n) => n.as_f64().map(|x| x != 0.0),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Poll models
// ---------------------------------------------------------------------------

/// One option inside a [`PollDetail`].
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PollOption {
    pub id: String,
    pub content: String,
    pub votes: i64,
    pub voted: bool,
}

impl fmt::Debug for PollOption {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollOption")
            .field("votes", &self.votes)
            .field("voted", &self.voted)
            .finish()
    }
}

/// Normalized group poll detail (`ZaloEngine+Poll.swift` `PollDetail`).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PollDetail {
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
    pub options: Vec<PollOption>,
}

impl fmt::Debug for PollDetail {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollDetail")
            .field("closed", &self.closed)
            .field("joined", &self.joined)
            .field("multi", &self.multi)
            .field("options", &self.options.len())
            .field("voter_count", &self.voter_count)
            .finish()
    }
}

impl PollDetail {
    /// Port of `PollDetail.init?(json: [String: Any])`.
    #[must_use]
    pub fn from_json(json: &Map<String, Value>) -> Option<Self> {
        let id = json.get("id").and_then(Value::as_str)?;
        if id.is_empty() {
            return None;
        }
        let text = |key: &str| -> String {
            json.get(key)
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned()
        };
        let flag = |key: &str| -> bool { nsnumber_bool(json.get(key)).unwrap_or(false) };
        let date_ms = |key: &str| -> Option<i64> {
            let ms = nsnumber_f64(json.get(key)).unwrap_or(0.0);
            if ms > 0.0 && ms < MAX_VALID_POLL_DATE_MS {
                #[expect(
                    clippy::cast_possible_truncation,
                    reason = "bounded to (0, 4_102_444_800_000)"
                )]
                Some(ms.round() as i64)
            } else {
                None
            }
        };
        let voter_count = clamped_int64(nsnumber_f64(json.get("voters")).unwrap_or(0.0));
        let options = json
            .get("options")
            .and_then(Value::as_array)
            .map(|rows| {
                rows.iter()
                    .filter_map(|v| {
                        let row = v.as_object()?;
                        let opt_id = row.get("id").and_then(Value::as_str)?;
                        if opt_id.is_empty() {
                            return None;
                        }
                        let content = row
                            .get("content")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_owned();
                        let votes =
                            clamped_int64(nsnumber_f64(row.get("votes")).unwrap_or(0.0)).max(0);
                        let voted = nsnumber_bool(row.get("voted")).unwrap_or(false);
                        Some(PollOption {
                            id: opt_id.to_owned(),
                            content,
                            votes,
                            voted,
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();

        Some(Self {
            id: id.to_owned(),
            group_id: text("groupId"),
            question: text("question"),
            creator: text("creator"),
            creator_name: text("creatorName"),
            created_ms: date_ms("created"),
            expires_ms: date_ms("expired"),
            closed: flag("closed"),
            joined: flag("joined"),
            multi: flag("multi"),
            allow_add: flag("allowAdd"),
            anonymous: flag("anonymous"),
            hide_preview: flag("hidePreview"),
            voter_count,
            can_close: flag("canClose"),
            options,
        })
    }

    #[must_use]
    pub fn total_votes(&self) -> i64 {
        self.options.iter().map(|o| o.votes).sum()
    }

    #[must_use]
    pub fn is_expired_at(&self, now_ms: i64) -> bool {
        self.expires_ms.is_some_and(|exp| exp < now_ms)
    }

    #[must_use]
    pub fn is_voting_locked_at(&self, now_ms: i64) -> bool {
        self.closed || self.is_expired_at(now_ms) || (self.hide_preview && self.joined)
    }

    #[must_use]
    pub fn results_hidden(&self) -> bool {
        self.hide_preview && !self.joined
    }

    #[must_use]
    pub fn voters_visible(&self) -> bool {
        !self.anonymous && !self.results_hidden() && self.total_votes() > 0
    }

    #[must_use]
    pub fn weight(&self, option: &PollOption) -> f64 {
        let total = self.total_votes();
        if total > 0 {
            #[expect(
                clippy::cast_precision_loss,
                reason = "matches Swift Double(option.votes) / Double(totalVotes)"
            )]
            let w = (option.votes as f64) / (total as f64);
            w
        } else {
            0.0
        }
    }
}

/// Added option row inside [`PollVoteDraft`].
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AddedPollOption {
    pub id: String,
    pub text: String,
    pub voted: bool,
}

impl fmt::Debug for AddedPollOption {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AddedPollOption")
            .field("has_text", &!self.text.trim().is_empty())
            .field("voted", &self.voted)
            .finish()
    }
}

/// Mutable state for voting / adding options on an existing poll (`PollVoteDraft`).
#[derive(Clone, PartialEq, Eq)]
pub struct PollVoteDraft {
    selected: BTreeSet<String>,
    original: BTreeSet<String>,
    multi: bool,
    pub added: Vec<AddedPollOption>,
    next_added_seq: u64,
}

impl fmt::Debug for PollVoteDraft {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollVoteDraft")
            .field("selected", &self.selected.len())
            .field("added", &self.added.len())
            .field("multi", &self.multi)
            .finish()
    }
}

impl PollVoteDraft {
    #[must_use]
    pub fn new(detail: &PollDetail) -> Self {
        let voted: BTreeSet<String> = detail
            .options
            .iter()
            .filter(|o| o.voted)
            .map(|o| o.id.clone())
            .collect();
        Self {
            selected: voted.clone(),
            original: voted,
            multi: detail.multi,
            added: Vec::new(),
            next_added_seq: 0,
        }
    }

    #[must_use]
    pub fn from_parts(
        selected: BTreeSet<String>,
        original: BTreeSet<String>,
        multi: bool,
        added: Vec<AddedPollOption>,
    ) -> Self {
        let next_added_seq = u64::try_from(added.len()).unwrap_or(0);
        Self {
            selected,
            original,
            multi,
            added,
            next_added_seq,
        }
    }

    #[must_use]
    pub fn selected(&self) -> &BTreeSet<String> {
        &self.selected
    }

    #[must_use]
    pub fn original(&self) -> &BTreeSet<String> {
        &self.original
    }

    #[must_use]
    pub fn multi(&self) -> bool {
        self.multi
    }

    pub fn toggle(&mut self, option_id: &str) {
        if self.selected.remove(option_id) {
            return;
        }
        if !self.multi {
            self.selected.clear();
            for item in &mut self.added {
                item.voted = false;
            }
        }
        self.selected.insert(option_id.to_owned());
    }

    pub fn set_added_voted(&mut self, id: &str, voted: bool) {
        let Some(at) = self.added.iter().position(|row| row.id == id) else {
            return;
        };
        if voted && !self.multi {
            self.selected.clear();
            for item in &mut self.added {
                item.voted = false;
            }
        }
        self.added[at].voted = voted;
    }

    pub fn add_row(&mut self) -> String {
        self.next_added_seq = self.next_added_seq.saturating_add(1);
        let id = format!("added-{}", self.next_added_seq);
        self.added.push(AddedPollOption {
            id: id.clone(),
            text: String::new(),
            voted: false,
        });
        id
    }

    pub fn remove_added(&mut self, id: &str) {
        self.added.retain(|row| row.id != id);
    }

    fn filled(&self) -> Vec<AddedPollOption> {
        self.added
            .iter()
            .filter_map(|row| {
                let trimmed = row.text.trim();
                if trimmed.is_empty() {
                    None
                } else {
                    Some(AddedPollOption {
                        id: row.id.clone(),
                        text: trimmed.to_owned(),
                        voted: row.voted,
                    })
                }
            })
            .collect()
    }

    #[must_use]
    pub fn has_changes(&self) -> bool {
        self.selected != self.original || !self.filled().is_empty()
    }

    #[must_use]
    pub fn votes_nothing(&self) -> bool {
        self.selected.is_empty() && !self.filled().iter().any(|r| r.voted)
    }

    #[must_use]
    pub fn has_duplicates(&self, detail: &PollDetail) -> bool {
        let filled = self.filled();
        let mut seen = HashSet::with_capacity(detail.options.len() + filled.len());
        for opt in &detail.options {
            if !seen.insert(opt.content.trim().to_owned()) {
                return true;
            }
        }
        for row in filled {
            if !seen.insert(row.text) {
                return true;
            }
        }
        false
    }

    #[must_use]
    pub fn is_duplicate(&self, id: &str, detail: &PollDetail) -> bool {
        let filled = self.filled();
        let Some(row) = filled.iter().find(|r| r.id == id) else {
            return false;
        };
        detail.options.iter().any(|o| o.content.trim() == row.text)
            || filled.iter().any(|r| r.id != id && r.text == row.text)
    }

    #[must_use]
    pub fn request(&self, detail: &PollDetail) -> (Vec<NewPollOptionPayload>, Vec<String>) {
        let new_options = self
            .filled()
            .into_iter()
            .map(|r| NewPollOptionPayload {
                content: r.text,
                voted: r.voted,
            })
            .collect();
        let voted_ids = detail
            .options
            .iter()
            .filter(|o| self.selected.contains(&o.id))
            .map(|o| o.id.clone())
            .collect();
        (new_options, voted_ids)
    }

    #[must_use]
    pub fn applied(&self, detail: &PollDetail) -> PollDetail {
        let mut next = detail.clone();
        for (idx, next_opt) in next.options.iter_mut().enumerate() {
            let was = detail.options[idx].voted;
            let now = self.selected.contains(&next_opt.id);
            next_opt.voted = now;
            if was != now {
                next_opt.votes = (next_opt.votes + if now { 1 } else { -1 }).max(0);
            }
        }
        next
    }

    #[must_use]
    pub fn can_submit(&self) -> bool {
        self.has_changes()
    }
}

/// One voter entry in [`PollVoters`].
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PollVoterUser {
    pub uid: String,
    pub name: String,
    pub avatar: Option<String>,
    pub is_me: bool,
}

impl fmt::Debug for PollVoterUser {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollVoterUser")
            .field("is_me", &self.is_me)
            .field("has_avatar", &self.avatar.is_some())
            .finish()
    }
}

/// Per-option voter breakdown in [`PollVoters`].
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PollVoterGroup {
    pub id: String,
    pub content: String,
    pub votes: i64,
    pub users: Vec<PollVoterUser>,
}

impl fmt::Debug for PollVoterGroup {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollVoterGroup")
            .field("votes", &self.votes)
            .field("users", &self.users.len())
            .finish()
    }
}

/// Poll voter sheet model (`PollVoters`).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PollVoters {
    pub restricted: bool,
    pub groups: Vec<PollVoterGroup>,
}

impl fmt::Debug for PollVoters {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollVoters")
            .field("restricted", &self.restricted)
            .field("groups", &self.groups.len())
            .finish()
    }
}

impl PollVoters {
    /// Port of `PollVoters.init?(json:)`.
    #[must_use]
    pub fn from_json(object: &Map<String, Value>) -> Self {
        let restricted = nsnumber_bool(object.get("restricted")).unwrap_or(false);
        let groups = object
            .get("groups")
            .and_then(Value::as_array)
            .map(|rows| {
                rows.iter()
                    .filter_map(|v| {
                        let row = v.as_object()?;
                        let id = row.get("optionId").and_then(Value::as_str)?.to_owned();
                        let content = row
                            .get("content")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_owned();
                        let votes = clamped_int64(nsnumber_f64(row.get("votes")).unwrap_or(0.0));
                        let users = row
                            .get("users")
                            .and_then(Value::as_array)
                            .map(|u_rows| {
                                u_rows
                                    .iter()
                                    .filter_map(|uv| {
                                        let u = uv.as_object()?;
                                        let uid = u.get("uid").and_then(Value::as_str)?;
                                        if uid.is_empty() {
                                            return None;
                                        }
                                        let name = u
                                            .get("name")
                                            .and_then(Value::as_str)
                                            .unwrap_or("")
                                            .to_owned();
                                        let avatar = u
                                            .get("avatar")
                                            .and_then(Value::as_str)
                                            .filter(|s| !s.is_empty())
                                            .map(str::to_owned);
                                        let is_me = nsnumber_bool(u.get("isMe")).unwrap_or(false);
                                        Some(PollVoterUser {
                                            uid: uid.to_owned(),
                                            name,
                                            avatar,
                                            is_me,
                                        })
                                    })
                                    .collect()
                            })
                            .unwrap_or_default();
                        Some(PollVoterGroup {
                            id,
                            content,
                            votes,
                            users,
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        Self { restricted, groups }
    }
}

/// Official `groupPoll` limits (`PollConfig`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PollConfig {
    pub min_options: i64,
    pub max_options: i64,
    pub max_question: i64,
    pub max_option: i64,
    pub enable_anonymous: bool,
    pub enable_hide_preview: bool,
    pub display_options: i64,
}

impl Default for PollConfig {
    fn default() -> Self {
        Self {
            min_options: 2,
            max_options: 30,
            max_question: 200,
            max_option: 120,
            enable_anonymous: true,
            enable_hide_preview: true,
            display_options: 3,
        }
    }
}

impl PollConfig {
    /// Port of `PollConfig(json: [String: Any]?)`.
    #[must_use]
    pub fn from_json(json: Option<&Map<String, Value>>) -> Self {
        let mut cfg = Self::default();
        let Some(json) = json else {
            return cfg;
        };
        let count = |key: &str, fallback: i64| -> i64 {
            let value = clamped_int64(nsnumber_f64(json.get(key)).unwrap_or(0.0));
            if value > 0 { value } else { fallback }
        };
        cfg.min_options = count("minOptions", cfg.min_options);
        cfg.max_options = cfg.min_options.max(count("maxOptions", cfg.max_options));
        cfg.max_question = count("maxQuestion", cfg.max_question);
        cfg.max_option = count("maxOption", cfg.max_option);
        cfg.display_options = count("displayOptions", cfg.display_options);
        cfg.enable_anonymous = nsnumber_bool(json.get("enableAnonymous")).unwrap_or(true);
        cfg.enable_hide_preview = nsnumber_bool(json.get("enableHidePreview")).unwrap_or(true);
        cfg
    }
}

/// Conversation poll capabilities (`PollCapabilities`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PollCapabilities {
    pub ready: bool,
    pub can_create: bool,
    pub can_pin: bool,
    pub config: PollConfig,
}

impl PollCapabilities {
    #[must_use]
    pub fn from_json(json: Option<&Map<String, Value>>) -> Self {
        let Some(o) = json else {
            return Self::default();
        };
        Self {
            ready: nsnumber_bool(o.get("ready")).unwrap_or(false),
            can_create: nsnumber_bool(o.get("canCreate")).unwrap_or(false),
            can_pin: nsnumber_bool(o.get("canPin")).unwrap_or(false),
            config: PollConfig::from_json(o.get("config").and_then(Value::as_object)),
        }
    }

    /// Port of `ZaloEngine.pollCapabilities(in:)`.
    #[must_use]
    pub fn for_conversation(conv_id: &str) -> Self {
        let is_group = is_group_id(conv_id);
        Self {
            ready: is_group,
            can_create: is_group,
            can_pin: is_group,
            config: PollConfig::default(),
        }
    }
}

/// Validation failure reason for [`PollCreateDraft`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PollCreateIssue {
    EmptyQuestion,
    TooFewOptions(i64),
    Duplicate,
    PastDeadline,
}

/// Create-poll form model (`PollCreateDraft`).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PollCreateDraft {
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

impl fmt::Debug for PollCreateDraft {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollCreateDraft")
            .field("options", &self.options.len())
            .field("has_deadline", &self.has_deadline)
            .field("pin", &self.pin)
            .field("multi", &self.multi)
            .finish()
    }
}

impl PollCreateDraft {
    #[must_use]
    pub fn new(config: &PollConfig, now_ms: i64) -> Self {
        let count = usize::try_from(config.min_options.max(0)).unwrap_or(2);
        Self {
            question: String::new(),
            options: vec![String::new(); count],
            has_deadline: false,
            deadline_ms: now_ms.saturating_add(86_400_000),
            pin: false,
            multi: true,
            allow_add: true,
            hide_preview: false,
            anonymous: false,
        }
    }

    #[must_use]
    pub fn trimmed_question(&self) -> &str {
        self.question.trim()
    }

    #[must_use]
    pub fn filled_options(&self) -> Vec<String> {
        self.options
            .iter()
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect()
    }

    #[must_use]
    pub fn is_duplicate(&self, index: usize) -> bool {
        let Some(raw) = self.options.get(index) else {
            return false;
        };
        let text = raw.trim();
        if text.is_empty() {
            return false;
        }
        self.options
            .iter()
            .enumerate()
            .any(|(i, item)| i != index && item.trim() == text)
    }

    #[must_use]
    pub fn issue(&self, config: &PollConfig, now_ms: i64) -> Option<PollCreateIssue> {
        if self.trimmed_question().is_empty() {
            return Some(PollCreateIssue::EmptyQuestion);
        }
        let filled = self.filled_options();
        let unique: HashSet<&str> = filled.iter().map(String::as_str).collect();
        if unique.len() != filled.len() {
            return Some(PollCreateIssue::Duplicate);
        }
        if i64::try_from(filled.len()).unwrap_or(0) < config.min_options {
            return Some(PollCreateIssue::TooFewOptions(config.min_options));
        }
        if self.has_deadline && self.deadline_ms <= now_ms {
            return Some(PollCreateIssue::PastDeadline);
        }
        None
    }

    #[must_use]
    pub fn effective_allow_add(&self) -> bool {
        self.allow_add && !self.hide_preview
    }

    #[must_use]
    pub fn truncated_question(&self, config: &PollConfig) -> String {
        let limit = usize::try_from(config.max_question.max(0)).unwrap_or(0);
        self.trimmed_question().chars().take(limit).collect()
    }

    #[must_use]
    pub fn truncated_options(&self, config: &PollConfig) -> Vec<String> {
        let limit = usize::try_from(config.max_option.max(0)).unwrap_or(0);
        self.filled_options()
            .into_iter()
            .map(|opt| opt.chars().take(limit).collect())
            .collect()
    }

    /// Port of `PollCreateDraft.spec(config:canPin:)`.
    #[must_use]
    pub fn spec(&self, config: &PollConfig, can_pin: bool) -> Value {
        json!({
            "question": self.truncated_question(config),
            "options": self.truncated_options(config),
            "expired": if self.has_deadline { self.deadline_ms } else { 0 },
            "pin": self.pin && can_pin,
            "multi": self.multi,
            "allowAdd": self.effective_allow_add(),
            "hidePreview": self.hide_preview && config.enable_hide_preview,
            "anonymous": self.anonymous && config.enable_anonymous,
        })
    }
}

/// Poll action kind for localized error formatting (`PollAction`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PollAction {
    Vote,
    Lock,
    Share,
    Create,
    Pin,
    Unpin,
}

/// Outcome of a poll mutation (`PollActionResult`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PollActionResult {
    pub ok: bool,
    pub error: Option<String>,
    pub pin_skipped: bool,
}

impl PollActionResult {
    #[must_use]
    pub fn ok() -> Self {
        Self {
            ok: true,
            error: None,
            pin_skipped: false,
        }
    }

    #[must_use]
    pub fn ok_pin_skipped() -> Self {
        Self {
            ok: true,
            error: None,
            pin_skipped: true,
        }
    }

    #[must_use]
    pub fn err(code: Option<&str>) -> Self {
        Self {
            ok: false,
            error: code.map(str::to_owned),
            pin_skipped: false,
        }
    }

    /// Official Vietnamese toast/modal text (`PollActionResult.message(for:)`).
    #[must_use]
    pub fn message(&self, action: PollAction) -> &'static str {
        match self.error.as_deref() {
            Some("closed") => "Có lỗi xảy ra do bình chọn đã bị khoá",
            Some("expired") => "Bình chọn đã hết hạn",
            Some("network") => "Không có mạng, vui lòng kiểm tra lại kết nối và thử lại",
            Some("duplicate") => "Phương án được thêm đã tồn tại",
            Some("forbidden") => match action {
                PollAction::Create => "Bạn không đủ quyền tạo bình chọn",
                PollAction::Pin | PollAction::Unpin => "Bạn không có quyền thực hiện thao tác này.",
                PollAction::Vote | PollAction::Lock | PollAction::Share => {
                    "Bạn không có quyền khóa bình chọn này"
                }
            },
            Some("limit") => "Bảng ghim đã đầy. Hãy bỏ bớt ghim trong Zalo rồi thử lại.",
            Some("partial") => {
                "Đã bỏ ghim cũ nhưng chưa ghim được bình chọn. Vui lòng thử ghim lại."
            }
            Some("unknown") => "Chưa xác nhận được kết quả. Vui lòng kiểm tra lại bình chọn sau.",
            _ => match action {
                PollAction::Vote => "Có lỗi xảy ra trong quá trình bình chọn.",
                PollAction::Lock => {
                    "Có lỗi xảy ra trong quá trình khóa bình chọn. Vui lòng thử lại."
                }
                PollAction::Share => {
                    "Có lỗi xảy ra trong quá trình chia sẻ bình chọn. Vui lòng thử lại."
                }
                PollAction::Create => {
                    "Có lỗi xảy ra trong quá trình tạo bình chọn. Vui lòng kiểm tra lại."
                }
                PollAction::Pin => "Ghim bình chọn không thành công. Vui lòng thử lại.",
                PollAction::Unpin => "Bỏ ghim không thành công. Vui lòng thử lại.",
            },
        }
    }
}

/// Per-poll pin state on the group board (`PollPinState`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PollPinState {
    pub ready: bool,
    pub can_pin: bool,
    pub pinned: bool,
    pub limit: i64,
}

impl PollPinState {
    #[must_use]
    pub fn from_json(json: Option<&Map<String, Value>>) -> Self {
        let Some(o) = json else {
            return Self::default();
        };
        Self {
            ready: nsnumber_bool(o.get("ready")).unwrap_or(false),
            can_pin: nsnumber_bool(o.get("canPin")).unwrap_or(false),
            pinned: nsnumber_bool(o.get("pinned")).unwrap_or(false),
            limit: clamped_int64(nsnumber_f64(o.get("limit")).unwrap_or(0.0)).max(0),
        }
    }

    #[must_use]
    pub fn offers_pin(&self) -> bool {
        self.ready && self.can_pin
    }
}

/// Replace-oldest-pin confirmation payload when a group board is full (`PollPinConfirm`).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PollPinConfirm {
    pub ref_id: String,
    pub limit: i64,
    pub kind: String,
    pub title: String,
}

impl fmt::Debug for PollPinConfirm {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollPinConfirm")
            .field("limit", &self.limit)
            .field("kind", &self.kind)
            .finish()
    }
}

impl PollPinConfirm {
    #[must_use]
    pub fn message(&self) -> String {
        let label = match self.kind.as_str() {
            "poll" => "Bình chọn",
            "reminder" => "Nhắc hẹn",
            "message" => "Tin nhắn",
            _ => "Ghi chú",
        };
        let head = if self.limit > 0 {
            format!("Đã đạt giới hạn {} ghim. ", self.limit)
        } else {
            String::new()
        };
        let tail = if self.title.is_empty() {
            label.to_owned()
        } else {
            format!("{label}: {}", self.title)
        };
        format!("{head}Ghim cũ dưới đây sẽ được bỏ để cập nhật nội dung mới.\n{tail}")
    }
}

/// Outcome of `pinPoll` (`PollPinOutcome`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum PollPinOutcome {
    Done,
    NeedsConfirmation(PollPinConfirm),
    Failed(PollActionResult),
}

// ---------------------------------------------------------------------------
// Temporary U7 read-only board mirror types
// ---------------------------------------------------------------------------

/// One item in a conversation's pinned board list (`PinnedItem` read-only mirror until U7).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BoardPinItem {
    pub ref_id: String,
    pub kind: String,
    pub title: String,
    pub sender: String,
    pub thumbnail: Option<String>,
    pub msg_id: String,
    pub cli_msg_id: String,
}

impl fmt::Debug for BoardPinItem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BoardPinItem")
            .field("kind", &self.kind)
            .finish()
    }
}

/// Conversation board pin list (`PinnedList` read-only mirror until U7).
#[derive(Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct BoardPinList {
    pub ready: bool,
    pub can_pin: bool,
    pub limit: i64,
    pub items: Vec<BoardPinItem>,
}

impl fmt::Debug for BoardPinList {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BoardPinList")
            .field("ready", &self.ready)
            .field("can_pin", &self.can_pin)
            .field("limit", &self.limit)
            .field("items", &self.items.len())
            .finish()
    }
}

/// Raw board topic cache for a conversation (`cachedBoardRawTopics[convId]` until U7).
#[derive(Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct BoardRawTopics {
    pub version: i64,
    /// `topic_id -> raw JSON object` (used to extract `type` for `unpinv2` / `multi_unpin`).
    pub topics: BTreeMap<String, JsonObject>,
}

impl fmt::Debug for BoardRawTopics {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BoardRawTopics")
            .field("version", &self.version)
            .field("topics", &self.topics.len())
            .finish()
    }
}

// ---------------------------------------------------------------------------
// PollsState + PollClock
// ---------------------------------------------------------------------------

/// Incoming poll message summary passed to [`PollClock::note_poll_messages`].
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PollMessageNotice {
    pub msg_id: String,
    pub poll_id: String,
    pub conv_id: String,
    pub date_ms: i64,
}

impl fmt::Debug for PollMessageNotice {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollMessageNotice")
            .field("date_ms", &self.date_ms)
            .finish()
    }
}

/// Per-instance poll clock/debounce/throttle state (`PollClock` in `olaz-core`).
#[derive(Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PollClock {
    pub watched: BTreeMap<String, String>,
    pub did_evict_watched: bool,
    pub last_attempt_ms: BTreeMap<String, i64>,
    seen_messages_order: VecDeque<String>,
    seen_messages_set: HashSet<String>,
    /// `poll_id -> active debounce sequence number`.
    pub pending_refresh: BTreeMap<String, u64>,
    pub next_debounce_seq: u64,
}

impl fmt::Debug for PollClock {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollClock")
            .field("watched", &self.watched.len())
            .field("did_evict_watched", &self.did_evict_watched)
            .field("last_attempt_ms", &self.last_attempt_ms.len())
            .field("seen_messages", &self.seen_messages_order.len())
            .field("pending_refresh", &self.pending_refresh.len())
            .finish()
    }
}

impl PollClock {
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    #[must_use]
    pub fn seen_messages_count(&self) -> usize {
        self.seen_messages_order.len()
    }

    #[must_use]
    pub fn pending_refresh_ids(&self) -> Vec<String> {
        self.pending_refresh.keys().cloned().collect()
    }

    /// Seeds `seen_messages` for test/recorder cases while enforcing the 2,000-entry FIFO cap.
    pub fn seed_seen_messages(&mut self, ids: impl IntoIterator<Item = String>) {
        for id in ids {
            self.insert_seen_message(&id);
        }
    }

    /// Inserts `msg_id` if unseen; returns `true` if newly inserted. Evicts oldest past 2,000
    /// (Approved Fix #4).
    pub fn insert_seen_message(&mut self, msg_id: &str) -> bool {
        if !self.seen_messages_set.insert(msg_id.to_owned()) {
            return false;
        }
        self.seen_messages_order.push_back(msg_id.to_owned());
        while self.seen_messages_order.len() > MAX_SEEN_POLL_MESSAGES {
            if let Some(oldest) = self.seen_messages_order.pop_front() {
                self.seen_messages_set.remove(&oldest);
            }
        }
        true
    }

    /// Registers `(id, conv_id)` in `watched`, evicting one existing entry `!= id` if count
    /// exceeds 500 (`MAX_WATCHED_POLLS`).
    pub fn record_watched(&mut self, id: &str, conv_id: &str) {
        self.watched.insert(id.to_owned(), conv_id.to_owned());
        if self.watched.len() > MAX_WATCHED_POLLS
            && let Some(drop_key) = self.watched.keys().find(|k| k.as_str() != id).cloned()
        {
            self.watched.remove(&drop_key);
            self.last_attempt_ms.remove(&drop_key);
            self.did_evict_watched = true;
        }
    }
}

/// Core-owned poll state (`ZaloEngine.polls` + `PollClock`).
#[derive(Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PollsState {
    pub details: BTreeMap<String, PollDetail>,
    pub pins: BTreeMap<String, PollPinState>,
    pub failed: BTreeSet<String>,
    pub clock: PollClock,
}

impl fmt::Debug for PollsState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollsState")
            .field("details", &self.details.len())
            .field("pins", &self.pins.len())
            .field("failed", &self.failed.len())
            .field("clock", &self.clock)
            .finish()
    }
}

impl PollsState {
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// Pure `watchPoll` transition: returns `true` when a `RefreshPoll` effect should run.
    pub fn watch_poll(&mut self, id: &str, conv_id: &str, now_ms: i64) -> bool {
        if id.is_empty() {
            return false;
        }
        self.clock.record_watched(id, conv_id);
        if self.details.contains_key(id) {
            return false;
        }
        if let Some(&last_ms) = self.clock.last_attempt_ms.get(id)
            && now_ms.saturating_sub(last_ms) < WATCH_POLL_THROTTLE_MS
        {
            return false;
        }
        self.clock.last_attempt_ms.insert(id.to_owned(), now_ms);
        self.failed.remove(id);
        true
    }

    /// Pure `retryPoll` transition: updates `last_attempt_ms`, clears `failed`, and returns `true`
    /// when `id` is non-empty so `RefreshPoll` runs.
    pub fn retry_poll(&mut self, id: &str, now_ms: i64) -> bool {
        self.clock.last_attempt_ms.insert(id.to_owned(), now_ms);
        self.failed.remove(id);
        !id.is_empty()
    }

    /// Pure `rewatchPolls` query: returns all watched poll IDs to refresh immediately.
    #[must_use]
    pub fn rewatch_poll_ids(&self) -> Vec<String> {
        self.clock
            .watched
            .keys()
            .filter(|id| !id.is_empty())
            .cloned()
            .collect()
    }

    /// Pure `notePollMessages` transition: filters loaded polls & fresh unseen messages, updates
    /// `seen_messages` (2,000-entry FIFO), and returns `(poll_id, seq)` debounce timers to arm.
    pub fn note_poll_messages(
        &mut self,
        incoming: &[PollMessageNotice],
        now_ms: i64,
    ) -> Vec<(String, u64)> {
        let cutoff_ms = now_ms.saturating_sub(POLL_MESSAGE_MAX_AGE_MS);
        let mut armed = Vec::new();
        for msg in incoming {
            if msg.poll_id.is_empty()
                || !self.details.contains_key(&msg.poll_id)
                || msg.date_ms <= cutoff_ms
                || !self.clock.insert_seen_message(&msg.msg_id)
            {
                continue;
            }
            self.clock.next_debounce_seq = self.clock.next_debounce_seq.saturating_add(1);
            let seq = self.clock.next_debounce_seq;
            self.clock.pending_refresh.insert(msg.poll_id.clone(), seq);
            armed.push((msg.poll_id.clone(), seq));
        }
        armed
    }

    /// Pure `PollDebounceFired` check: returns `true` when `(poll_id, seq)` matches the active
    /// pending refresh and should trigger `RefreshPoll`.
    pub fn complete_debounce(&mut self, poll_id: &str, seq: u64) -> bool {
        if self.clock.pending_refresh.get(poll_id) == Some(&seq) {
            self.clock.pending_refresh.remove(poll_id);
            true
        } else {
            false
        }
    }

    /// Port of `ZaloEngine.handlePoll(state:)`. Returns `true` if `details` or `failed` mutated.
    pub fn apply_poll_state_event(&mut self, state: &Map<String, Value>) -> bool {
        let Some(poll_obj) = state.get("poll").and_then(Value::as_object) else {
            return false;
        };
        let Some(id) = poll_obj.get("id").and_then(Value::as_str) else {
            return false;
        };
        if let Some(detail) = poll_obj
            .get("detail")
            .and_then(Value::as_object)
            .and_then(PollDetail::from_json)
        {
            let removed_fail = self.failed.remove(id);
            if self.details.get(id) != Some(&detail) {
                self.details.insert(id.to_owned(), detail);
                return true;
            }
            return removed_fail;
        }
        if poll_obj.get("error").is_some() && !self.details.contains_key(id) {
            return self.failed.insert(id.to_owned());
        }
        false
    }
}

// ---------------------------------------------------------------------------
// Pure poll resolution, normalization, pin state, and error mappers
// ---------------------------------------------------------------------------

/// Port of `ZaloEngine.resolvePollGroupId(id:payload:explicit:)`, preserving Quirk #7's
/// non-empty short-circuit across `group_id ?? groupId ?? grid` and skipping `"0"` / `"g0"`.
#[must_use]
pub fn resolve_poll_group_id(
    id: &str,
    payload: &Map<String, Value>,
    explicit: Option<&str>,
    polls: &PollsState,
    messages: &MessagesState,
) -> String {
    let payload_group = lossless::string(
        payload
            .get("group_id")
            .or_else(|| payload.get("groupId"))
            .or_else(|| payload.get("grid")),
    );
    let candidates = [
        explicit.unwrap_or(""),
        payload_group.as_str(),
        polls.clock.watched.get(id).map_or("", String::as_str),
        polls.details.get(id).map_or("", |d| d.group_id.as_str()),
    ];
    for raw in candidates {
        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed == "0" || trimmed == "g0" {
            continue;
        }
        let gid = group_conv_id(trimmed);
        if !gid.is_empty() {
            return gid;
        }
    }
    for (conv_id, win) in &messages.windows {
        if !is_group_id(conv_id) {
            continue;
        }
        let has_poll = win
            .iter()
            .any(|m| matches!(&m.kind, Kind::Poll(info) if info.poll_id == id));
        if has_poll {
            return group_conv_id(conv_id);
        }
    }
    String::new()
}

/// Port of `ZaloEngine.isGroupAdminOrCreator(_:inGroup:)`.
#[must_use]
pub fn is_group_admin_or_creator(uid: &str, group_id: &str, contacts: &ContactsState) -> bool {
    let clean_uid = normalize_poll_uid(uid);
    if clean_uid.is_empty() || clean_uid == "0" {
        return false;
    }
    let clean_grid = clean_group_id(group_id);
    let conv_id = group_conv_id(group_id);
    let raw_json = (!clean_grid.is_empty())
        .then(|| contacts.group_details_json.get(&clean_grid))
        .flatten()
        .or_else(|| {
            (!conv_id.is_empty())
                .then(|| contacts.group_details_json.get(&conv_id))
                .flatten()
        });
    let Some(info) = raw_json.and_then(|s| serde_json::from_str::<Map<String, Value>>(s).ok())
    else {
        return false;
    };

    let mut privileged = HashSet::new();
    let mut add_candidate = |val: Option<&Value>| {
        let s = lossless::string(val);
        let norm = normalize_poll_uid(&s);
        if !norm.is_empty() && norm != "0" {
            privileged.insert(norm);
        }
    };

    for key in ["creatorId", "creator_id", "ownerId", "owner_id", "creator"] {
        add_candidate(info.get(key));
    }
    for key in ["adminIds", "admin_ids", "admins", "deputies", "deputyIds"] {
        if let Some(Value::Array(arr)) = info.get(key) {
            for item in arr {
                add_candidate(Some(item));
            }
        }
    }
    if let Some(Value::Array(cur)) = info.get("currentMems") {
        for item in cur {
            let Some(mem) = item.as_object() else {
                continue;
            };
            let is_admin = lossless::bool(mem.get("isAdmin")) == Some(true)
                || lossless::bool(mem.get("isCreator")) == Some(true);
            if is_admin {
                add_candidate(mem.get("id").or_else(|| mem.get("uid")));
            }
        }
    }
    privileged.contains(&clean_uid)
}

fn lookup_person_name_and_avatar(
    uid: &str,
    my_uid: &str,
    my_avatar: Option<&str>,
    convs: &ConversationsState,
) -> Option<(String, String)> {
    let snap = IdentitySnapshot::from_core(my_uid, my_avatar, convs);
    snap.lookup_person(uid).map(|hit| (hit.name, hit.avatar))
}

/// Port of `ZaloEngine.normalizePollDetail(_:id:groupId:)` with Approved Fix #3 (normalized UIDs
/// and [`UNKNOWN_POLL_USER_NAME`] fallback).
#[must_use]
#[expect(
    clippy::too_many_arguments,
    reason = "pure projection over explicit core state slices"
)]
pub fn normalize_poll_detail(
    d: &Map<String, Value>,
    id: &str,
    explicit_group_id: Option<&str>,
    my_raw_uid: &str,
    my_avatar: Option<&str>,
    polls: &PollsState,
    contacts: &ContactsState,
    convs: &ConversationsState,
    messages: &MessagesState,
) -> Option<PollDetail> {
    let my_uid = normalize_poll_uid(my_raw_uid);
    let creator_id = normalize_poll_uid(&lossless::string(d.get("creator")));
    let resolved_group_id = resolve_poll_group_id(id, d, explicit_group_id, polls, messages);
    let is_poll_creator = !my_uid.is_empty() && creator_id == my_uid;
    let is_group_privileged = !my_uid.is_empty()
        && !resolved_group_id.is_empty()
        && is_group_admin_or_creator(&my_uid, &resolved_group_id, contacts);

    let mut total_voters = HashSet::new();
    let mut options_json = Vec::new();
    if let Some(Value::Array(options_raw)) = d.get("options") {
        for item in options_raw {
            let Some(opt) = item.as_object() else {
                continue;
            };
            let opt_id = lossless::string(opt.get("option_id").or_else(|| opt.get("id")));
            let voters: Vec<String> = opt
                .get("voters")
                .and_then(Value::as_array)
                .map(|arr| {
                    arr.iter()
                        .map(|v| normalize_poll_uid(&lossless::string(Some(v))))
                        .filter(|s| !s.is_empty())
                        .collect()
                })
                .unwrap_or_default();
            for v in &voters {
                total_voters.insert(v.clone());
            }
            let voted = !my_uid.is_empty() && voters.iter().any(|v| v == &my_uid);
            options_json.push(json!({
                "id": opt_id,
                "content": lossless::string(opt.get("content")),
                "votes": voters.len(),
                "voted": voted,
                "voters": voters,
            }));
        }
    }

    let creator_name = lookup_person_name_and_avatar(&creator_id, my_raw_uid, my_avatar, convs)
        .map(|(name, _)| name)
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| UNKNOWN_POLL_USER_NAME.to_owned());

    let expired_ms = lossless::int64(d.get("expired_time"))
        .unwrap_or(0)
        .saturating_mul(1_000);
    let normalized = json!({
        "id": id,
        "groupId": resolved_group_id,
        "question": lossless::string(d.get("question")),
        "creator": creator_id,
        "creatorName": creator_name,
        "multi": d.get("is_multi_choice").and_then(Value::as_bool).unwrap_or(false),
        "allowAdd": d.get("is_add_new_option").and_then(Value::as_bool).unwrap_or(false),
        "anonymous": d.get("is_anonymous").and_then(Value::as_bool).unwrap_or(false),
        "hidePreview": d.get("is_hide_vote_preview").and_then(Value::as_bool).unwrap_or(false),
        "closed": lossless::int64(d.get("status")) == Some(0),
        "expired": expired_ms,
        "voters": total_voters.len(),
        "canClose": is_poll_creator || is_group_privileged,
        "joined": !my_uid.is_empty() && total_voters.contains(&my_uid),
        "options": options_json,
    });
    normalized.as_object().and_then(PollDetail::from_json)
}

/// Port of `ZaloEngine.pollVoters(_:)` over `/api/poll/detail`'s `data` object with Approved Fix #3
/// (normalized voter UIDs and [`UNKNOWN_POLL_USER_NAME`]).
#[must_use]
pub fn build_poll_voters(
    d: &Map<String, Value>,
    my_raw_uid: &str,
    my_avatar: Option<&str>,
    convs: &ConversationsState,
) -> PollVoters {
    let anonymous = d
        .get("is_anonymous")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let my_uid = normalize_poll_uid(my_raw_uid);
    let snap = IdentitySnapshot::from_core(my_raw_uid, my_avatar, convs);

    let mut groups_json = Vec::new();
    if let Some(Value::Array(options_raw)) = d.get("options") {
        for item in options_raw {
            let Some(opt) = item.as_object() else {
                continue;
            };
            let voters: Vec<String> = opt
                .get("voters")
                .and_then(Value::as_array)
                .map(|arr| {
                    arr.iter()
                        .map(|v| normalize_poll_uid(&lossless::string(Some(v))))
                        .collect()
                })
                .unwrap_or_default();
            let users_json: Vec<Value> = if anonymous {
                Vec::new()
            } else {
                voters
                    .iter()
                    .map(|uid| {
                        let hit = snap.lookup_person(uid);
                        let name = hit
                            .as_ref()
                            .map(|h| h.name.as_str())
                            .filter(|n| !n.is_empty())
                            .unwrap_or(UNKNOWN_POLL_USER_NAME);
                        let avatar = hit.as_ref().map_or("", |h| h.avatar.as_str());
                        json!({
                            "uid": uid,
                            "name": name,
                            "avatar": avatar,
                            "isMe": !my_uid.is_empty() && uid == &my_uid,
                        })
                    })
                    .collect()
            };
            groups_json.push(json!({
                "optionId": lossless::string(opt.get("option_id").or_else(|| opt.get("id"))),
                "content": lossless::string(opt.get("content")),
                "votes": voters.len(),
                "users": users_json,
            }));
        }
    }
    let root = json!({
        "restricted": anonymous,
        "groups": groups_json,
    });
    match root.as_object() {
        Some(obj) => PollVoters::from_json(obj),
        None => PollVoters {
            restricted: anonymous,
            groups: Vec::new(),
        },
    }
}

/// Computes and updates `polls.pins[id]` for `refreshPollPin` with Approved Fix #2:
/// uses `board_pins.get(conv_id).map_or(0, |b| b.limit)` when `is_group` (`0` when uncached or 1-1).
/// Returns `(returned_state, mutated)`.
pub fn refresh_poll_pin_state(
    polls: &mut PollsState,
    board_pins: &BTreeMap<String, BoardPinList>,
    id: &str,
    conv_id: &str,
) -> (PollPinState, bool) {
    let is_group = is_group_id(conv_id);
    let board = board_pins.get(conv_id);
    let is_pinned = board.is_some_and(|b| {
        b.items
            .iter()
            .any(|item| item.kind == "poll" && item.ref_id == id)
    });
    let limit = if is_group {
        board.map_or(0, |b| b.limit.max(0))
    } else {
        0
    };
    let state = PollPinState {
        ready: is_group,
        can_pin: is_group,
        pinned: is_pinned,
        limit,
    };
    let mut mutated = false;
    if (state.ready || !polls.pins.contains_key(id)) && polls.pins.get(id) != Some(&state) {
        polls.pins.insert(id.to_owned(), state.clone());
        mutated = true;
    }
    let out = polls.pins.get(id).cloned().unwrap_or(state);
    (out, mutated)
}

/// Computes [`PollPinConfirm`] when a pin attempt hits `"limit"`, using the real board limit
/// (Approved Fix #2: `items.len().max(board.limit)`).
#[must_use]
pub fn build_pin_limit_confirm(
    poll_id: &str,
    board: Option<&BoardPinList>,
) -> Option<PollPinConfirm> {
    let board = board?;
    let oldest = board.items.last()?;
    if oldest.ref_id == poll_id {
        return None;
    }
    let items_count = i64::try_from(board.items.len()).unwrap_or(0);
    let limit = items_count.max(board.limit.max(0));
    Some(PollPinConfirm {
        ref_id: oldest.ref_id.clone(),
        limit,
        kind: oldest.kind.clone(),
        title: oldest.title.clone(),
    })
}

/// Port of `ZaloEngine.mapPollPinError(_:partial:)` over `(code, message)` session errors.
#[must_use]
pub fn map_poll_pin_session_error(code: i64, message: &str, partial: bool) -> PollActionResult {
    if partial {
        return PollActionResult::err(Some("partial"));
    }
    let msg = message.to_lowercase();
    if code == 1005
        || code == 1010
        || code == 201
        || msg.contains("limit")
        || msg.contains("max")
        || msg.contains("full")
        || msg.contains("giới hạn")
        || msg.contains("tối đa")
    {
        return PollActionResult::err(Some("limit"));
    }
    if code == 112
        || code == 114
        || code == 200
        || code == 403
        || msg.contains("permission")
        || msg.contains("forbidden")
        || msg.contains("admin")
        || msg.contains("quyền")
        || msg.contains("not allowed")
    {
        return PollActionResult::err(Some("forbidden"));
    }
    PollActionResult::err(None)
}

/// Port of `ZaloEngine.mapPollPinError(_:partial:)` over [`NetError`].
#[must_use]
pub fn map_poll_pin_net_error(err: &NetError, partial: bool) -> PollActionResult {
    if partial {
        return PollActionResult::err(Some("partial"));
    }
    match err {
        NetError::Session(ZaloSessionError { code, message, .. }) => {
            map_poll_pin_session_error(*code, message, false)
        }
        NetError::Crypto(_) => PollActionResult::err(None),
        NetError::NotAuthenticated
        | NetError::InvalidUrl(_)
        | NetError::Http { .. }
        | NetError::InvalidJson
        | NetError::QrFailed(_)
        | NetError::QrTimeout
        | NetError::Cancelled
        | NetError::Network { .. } => PollActionResult::err(Some("network")),
    }
}

/// Port of `createPoll`'s catch error classifier (`forbidden` vs `network`).
#[must_use]
pub fn map_create_poll_net_error(err: &NetError) -> PollActionResult {
    if let NetError::Session(ZaloSessionError { code, message, .. }) = err {
        let msg = message.to_lowercase();
        if *code == 112
            || *code == 114
            || *code == 403
            || msg.contains("permission")
            || msg.contains("forbidden")
            || msg.contains("quyền")
        {
            return PollActionResult::err(Some("forbidden"));
        }
    }
    PollActionResult::err(Some("network"))
}

// ---------------------------------------------------------------------------
// Shared U12 / U10 group metadata merge (`refreshGroupMetadata`)
// ---------------------------------------------------------------------------

/// Persistence artifacts produced by [`merge_fetched_group_metadata`] for SQLite writeback.
#[derive(Clone, PartialEq, Eq)]
pub struct MergedGroupMetadataPersistence {
    pub gid: String,
    pub cached_groups_json: Option<Vec<u8>>,
    pub stored_conversation: Option<StoredConversation>,
}

impl fmt::Debug for MergedGroupMetadataPersistence {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MergedGroupMetadataPersistence")
            .field("has_cached_groups", &self.cached_groups_json.is_some())
            .field("has_stored_conv", &self.stored_conversation.is_some())
            .finish()
    }
}

/// Shared port of `ZaloEngine.refreshGroupMetadata` + `applyGroupMetadataUpdate` +
/// `persistSingleGroupConversation` for U12 (`refreshPoll`) and U10 (group management).
pub fn merge_fetched_group_metadata(
    group_id: &str,
    info: &JsonObject,
    contacts: &mut ContactsState,
    convs: &mut ConversationsState,
    self_conv_id: Option<&str>,
    now_ms: i64,
) -> Option<MergedGroupMetadataPersistence> {
    let gid = group_conv_id(group_id);
    let clean_grid = clean_group_id(group_id);
    if gid.is_empty() || clean_grid.is_empty() || info.is_empty() {
        return None;
    }

    let server_name = lossless::string(info.get("name"));
    let avt_str = lossless::string(info.get("avt").or_else(|| info.get("fullAvt")));
    let avt_url = is_valid_url_str(&avt_str).then_some(avt_str);

    let mut raw_member_ids: Vec<String> = Vec::new();
    if let Some(Value::Array(ver_list)) = info.get("memVerList")
        && ver_list.iter().all(Value::is_string)
    {
        for v in ver_list {
            if let Some(s) = v.as_str()
                && let Some(first) = s.split('_').next()
            {
                raw_member_ids.push(first.to_owned());
            }
        }
    }
    if raw_member_ids.is_empty()
        && let Some(Value::Array(mems)) = info.get("memIds")
    {
        raw_member_ids.extend(mems.iter().map(|v| lossless::string(Some(v))));
    }
    if raw_member_ids.is_empty()
        && let Some(Value::Array(cur)) = info.get("currentMems")
        && cur.iter().all(Value::is_object)
    {
        for v in cur {
            if let Some(obj) = v.as_object() {
                raw_member_ids.push(lossless::string(obj.get("id").or_else(|| obj.get("uid"))));
            }
        }
    }
    let clean_member_ids = clean_group_member_ids(&raw_member_ids);
    let member_count = lossless::int64(info.get("totalMember").or_else(|| info.get("total")))
        .unwrap_or_else(|| i64::try_from(clean_member_ids.len()).unwrap_or(0));

    let opt_name = (!server_name.is_empty()).then_some(server_name.as_str());
    let opt_members = (member_count > 0).then_some(member_count);

    let mut detail = info.clone();
    if let Some(n) = opt_name {
        detail.insert("name".to_owned(), Value::from(n));
    }
    if let Some(ref avt) = avt_url {
        detail.insert("avt".to_owned(), Value::from(avt.as_str()));
    }
    if let Some(mc) = opt_members {
        detail.insert("totalMember".to_owned(), Value::from(mc));
    }
    if !clean_member_ids.is_empty() {
        detail.insert("memIds".to_owned(), json!(clean_member_ids));
        let ver_list: Vec<String> = clean_member_ids
            .iter()
            .map(|id| format!("{id}_0"))
            .collect();
        detail.insert("memVerList".to_owned(), json!(ver_list));
        if detail.contains_key("currentMems") {
            let cur_mems: Vec<Value> = clean_member_ids
                .iter()
                .map(|id| json!({ "id": id }))
                .collect();
            detail.insert("currentMems".to_owned(), Value::Array(cur_mems));
        }
    }
    if let Ok(serialized) = serde_json::to_string(&Value::Object(detail)) {
        contacts.group_details_json.insert(clean_grid, serialized);
    }

    if let Some(existing) = contacts.groups.iter_mut().find(|g| g.id == gid) {
        let next_name = match opt_name {
            Some(n) => n.to_owned(),
            None => existing.name.clone(),
        };
        let next_avt = avt_url.clone().or_else(|| existing.avatar.clone());
        let next_members = opt_members.unwrap_or(existing.members);
        existing.sort_key = fold_contact_str(&next_name);
        existing.name = next_name;
        existing.avatar = next_avt;
        existing.members = next_members;
    } else {
        let next_name = opt_name.unwrap_or("Nhóm").to_owned();
        let sort_key = fold_contact_str(&next_name);
        contacts.groups.push(GroupEntry {
            id: gid.clone(),
            name: next_name,
            avatar: avt_url.clone(),
            members: opt_members.unwrap_or(1),
            sort_key,
        });
    }
    contacts
        .groups
        .sort_by(|a, b| localized_standard_cmp(&a.sort_key, &b.sort_key));
    convs.identities.groups = contacts
        .groups
        .iter()
        .map(|g| GroupIdentity {
            id: g.id.clone(),
            name: g.name.clone(),
            avatar: g.avatar.clone(),
            members: g.members,
        })
        .collect();

    if let Some(conv) = convs.conversations.iter_mut().find(|c| c.id == gid) {
        if let Some(n) = opt_name {
            conv.name = n.to_owned();
        }
        if let Some(ref avt) = avt_url {
            conv.avatar = Some(avt.clone());
        }
        if let Some(mc) = opt_members {
            conv.members = mc;
        }
    } else {
        convs.conversations.push(ConversationSummary {
            id: gid.clone(),
            is_group: true,
            name: opt_name.unwrap_or("Nhóm").to_owned(),
            avatar: avt_url.clone(),
            pinned: convs.pinned_ids.contains(&gid),
            members: opt_members.unwrap_or(1),
            unread: 0,
            preview: None,
        });
    }
    sort_conversations(&mut convs.conversations, &convs.identities.activity_ranks);

    let existing_cached = convs.identities.cached_groups.get(&gid).cloned();
    convs.identities.cached_groups.insert(
        gid.clone(),
        CachedGroup {
            name: match opt_name {
                Some(n) => n.to_owned(),
                None => existing_cached
                    .as_ref()
                    .map_or_else(String::new, |c| c.name.clone()),
            },
            avatar: avt_url.unwrap_or_else(|| {
                existing_cached
                    .as_ref()
                    .map_or_else(String::new, |c| c.avatar.clone())
            }),
            members: opt_members
                .unwrap_or_else(|| existing_cached.as_ref().map_or(0, |c| c.members)),
        },
    );

    convs.rebuild_conversation_flags(self_conv_id);
    convs.rebuild_conversation_extras(self_conv_id);

    let cached_groups_json = serialize_cached_groups_json(&convs.identities.cached_groups);
    let stored_conversation = convs
        .conversations
        .iter()
        .find(|c| c.id == gid)
        .map(|summary| StoredConversation {
            id: summary.id.clone(),
            is_group: summary.is_group,
            name: summary.name.clone(),
            avatar: summary.avatar.clone().unwrap_or_default(),
            pinned: summary.pinned,
            members: summary.members,
            unread: summary.unread,
            preview_text: summary
                .preview
                .as_ref()
                .map_or_else(String::new, |p| p.text.clone()),
            preview_ts_ms: summary
                .preview
                .as_ref()
                .and_then(|p| p.date_ms)
                .unwrap_or(0),
            preview_from_me: summary.preview.as_ref().is_some_and(|p| p.from_me),
            updated_at_ms: now_ms,
        });

    Some(MergedGroupMetadataPersistence {
        gid,
        cached_groups_json,
        stored_conversation,
    })
}

#[cfg(test)]
#[expect(
    clippy::unwrap_used,
    reason = "unit tests assert invariants on synthetic fixtures"
)]
mod tests {
    use super::*;
    use crate::conversations::FriendIdentity;

    #[test]
    fn vote_draft_single_and_multi_branches_match_swift() {
        let detail = PollDetail::from_json(
            json!({
                "id": "vd1",
                "groupId": "g1",
                "question": "Single",
                "multi": false,
                "options": [
                    {"id": "1", "content": "One", "votes": 0, "voted": false},
                    {"id": "2", "content": "Two", "votes": 1, "voted": true},
                ],
            })
            .as_object()
            .unwrap(),
        )
        .unwrap();

        let mut vd = PollVoteDraft::new(&detail);
        assert!(!vd.has_changes());
        assert!(!vd.votes_nothing());

        let r0 = vd.add_row();
        vd.added[0].text = "  One  ".to_owned();
        vd.set_added_voted(&r0, true);
        let (new_opts, voted_ids) = vd.request(&detail);
        assert!(voted_ids.is_empty());
        assert_eq!(new_opts.len(), 1);
        assert!(new_opts[0].voted);
        assert!(vd.is_duplicate(&r0, &detail));
        assert!(vd.has_duplicates(&detail));

        vd.toggle("1");
        let (new_opts_after, voted_after) = vd.request(&detail);
        assert_eq!(voted_after, vec!["1"]);
        assert!(!new_opts_after[0].voted);

        let preview = vd.applied(&detail);
        assert_eq!(preview.options[0].votes, 1);
        assert!(preview.options[0].voted);
        assert_eq!(preview.options[1].votes, 0);
        assert!(!preview.options[1].voted);

        vd.remove_added(&r0);
        assert!(!vd.votes_nothing());
        vd.toggle("1");
        assert!(vd.votes_nothing());
    }

    #[test]
    fn create_draft_config_and_pin_confirm_match_swift() {
        let cfg = PollConfig::from_json(
            json!({
                "minOptions": 4,
                "maxOptions": 2,
                "maxQuestion": 0,
                "maxOption": -5,
                "displayOptions": 0,
                "enableAnonymous": false,
                "enableHidePreview": false,
            })
            .as_object(),
        );
        assert_eq!(cfg.min_options, 4);
        assert_eq!(cfg.max_options, 4);
        assert_eq!(cfg.max_question, 200);
        assert_eq!(cfg.max_option, 120);
        assert_eq!(cfg.display_options, 3);
        assert!(!cfg.enable_anonymous);
        assert!(!cfg.enable_hide_preview);

        let cfg2 = PollConfig::from_json(json!({"minOptions": 2}).as_object());
        let ref_now = 1_700_010_000_000_i64;
        let mut d = PollCreateDraft::new(&cfg2, ref_now);
        assert_eq!(
            d.issue(&cfg2, ref_now),
            Some(PollCreateIssue::EmptyQuestion)
        );
        d.question = "Q?".to_owned();
        d.options = vec!["A".to_owned(), "A".to_owned()];
        assert!(d.is_duplicate(0));
        assert!(!d.is_duplicate(99));
        assert_eq!(d.issue(&cfg2, ref_now), Some(PollCreateIssue::Duplicate));
        d.options = vec!["A".to_owned(), String::new()];
        assert_eq!(
            d.issue(&cfg2, ref_now),
            Some(PollCreateIssue::TooFewOptions(2))
        );
        d.options = vec!["A".to_owned(), "B".to_owned()];
        d.has_deadline = true;
        d.deadline_ms = ref_now;
        assert_eq!(d.issue(&cfg2, ref_now), Some(PollCreateIssue::PastDeadline));
        d.deadline_ms = ref_now + 60_000;
        assert_eq!(d.issue(&cfg2, ref_now), None);

        let confirm = PollPinConfirm {
            ref_id: "p1".to_owned(),
            limit: 3,
            kind: "poll".to_owned(),
            title: "Họp".to_owned(),
        };
        assert_eq!(
            confirm.message(),
            "Đã đạt giới hạn 3 ghim. Ghim cũ dưới đây sẽ được bỏ để cập nhật nội dung mới.\nBình chọn: Họp"
        );
    }

    #[test]
    fn approved_fixes_2_3_4_and_watch_eviction_work_as_specified() {
        // Fix #2: real board limit when cached, 0 when uncached or 1-1.
        let mut polls = PollsState::default();
        let mut boards = BTreeMap::new();
        let (uncached, _) = refresh_poll_pin_state(&mut polls, &boards, "9701", "g500701");
        assert_eq!(uncached.limit, 0);
        assert!(uncached.ready);

        boards.insert(
            "g500701".to_owned(),
            BoardPinList {
                ready: true,
                can_pin: true,
                limit: 3,
                items: vec![BoardPinItem {
                    ref_id: "9701".to_owned(),
                    kind: "poll".to_owned(),
                    title: "Poll".to_owned(),
                    sender: "A".to_owned(),
                    thumbnail: None,
                    msg_id: String::new(),
                    cli_msg_id: String::new(),
                }],
            },
        );
        let (cached, _) = refresh_poll_pin_state(&mut polls, &boards, "9701", "g500701");
        assert_eq!(cached.limit, 3);
        assert!(cached.pinned);

        let (dm_pin, _) = refresh_poll_pin_state(&mut polls, &boards, "9702", "3001001");
        assert!(!dm_pin.ready);
        assert_eq!(dm_pin.limit, 0);

        // Fix #3: normalized u-prefixed UIDs + unified "Người dùng Zalo" unknown default.
        let contacts = ContactsState::default();
        let mut convs = ConversationsState::default();
        convs.identities.friends.push(FriendIdentity {
            id: "3001001".to_owned(),
            name: "An Nguyễn".to_owned(),
            avatar: Some("https://cdn.example.invalid/an.jpg".to_owned()),
        });
        let messages = MessagesState::default();
        let raw_payload = json!({
            "group_id": "500101",
            "question": "Ăn trưa?",
            "creator": "u9999999",
            "is_multi_choice": true,
            "is_add_new_option": true,
            "status": 1,
            "expired_time": 1_700_086_400,
            "options": [
                {"option_id": 1, "content": "Phở", "voters": ["u2001001", "u3001001"]},
            ],
        });
        let detail = normalize_poll_detail(
            raw_payload.as_object().unwrap(),
            "9101",
            None,
            "2001001",
            None,
            &polls,
            &contacts,
            &convs,
            &messages,
        )
        .unwrap();
        assert_eq!(detail.creator, "9999999");
        assert_eq!(detail.creator_name, "Người dùng Zalo");
        assert!(detail.joined);
        assert!(detail.options[0].voted);
        assert_eq!(detail.voter_count, 2);

        let voters = build_poll_voters(raw_payload.as_object().unwrap(), "2001001", None, &convs);
        assert_eq!(voters.groups[0].users[0].uid, "2001001");
        assert!(voters.groups[0].users[0].is_me);
        assert_eq!(voters.groups[0].users[1].uid, "3001001");
        assert_eq!(voters.groups[0].users[1].name, "An Nguyễn");

        // Fix #4: 2,000-entry FIFO eviction instead of clearing.
        polls.details.insert("9101".to_owned(), detail);
        polls
            .clock
            .seed_seen_messages((1..=2_000).map(|i| format!("m{i}")));
        assert_eq!(polls.clock.seen_messages_count(), 2_000);
        let armed = polls.note_poll_messages(
            &[
                PollMessageNotice {
                    msg_id: "m2001".to_owned(),
                    poll_id: "9101".to_owned(),
                    conv_id: "g500101".to_owned(),
                    date_ms: 1_700_010_000_000,
                },
                // m2 is still retained (only m1 was evicted)!
                PollMessageNotice {
                    msg_id: "m2".to_owned(),
                    poll_id: "9101".to_owned(),
                    conv_id: "g500101".to_owned(),
                    date_ms: 1_700_010_000_000,
                },
            ],
            1_700_010_001_000,
        );
        assert_eq!(polls.clock.seen_messages_count(), 2_000);
        assert_eq!(armed.len(), 1);
        assert!(polls.complete_debounce("9101", armed[0].1));

        // 500 watched cap eviction
        for i in 1..=501 {
            let pid = format!("w{i}");
            let _ = polls.watch_poll(&pid, "g500101", 1_700_010_000_000);
        }
        assert_eq!(polls.clock.watched.len(), 500);
        assert!(polls.clock.did_evict_watched);
        assert!(polls.clock.watched.contains_key("w501"));
    }

    #[test]
    fn shared_merge_fetched_group_metadata_updates_contacts_and_conversations() {
        let mut contacts = ContactsState::default();
        let mut convs = ConversationsState::default();
        let info = json!({
            "groupId": "500202",
            "name": "Nhóm Mới",
            "avt": "https://cdn.example.invalid/g.jpg",
            "creatorId": "2001001",
            "memVerList": ["u2001001_0", "3001001_1"],
        });
        let persisted = merge_fetched_group_metadata(
            "g500202",
            info.as_object().unwrap(),
            &mut contacts,
            &mut convs,
            Some("2001001"),
            1_700_010_000_000,
        )
        .unwrap();
        assert_eq!(persisted.gid, "g500202");
        assert!(contacts.group_details_json.contains_key("500202"));
        assert!(is_group_admin_or_creator("2001001", "g500202", &contacts));
        assert_eq!(contacts.groups.len(), 1);
        assert_eq!(contacts.groups[0].members, 2);
        assert_eq!(convs.conversations.len(), 1);
        assert_eq!(convs.conversations[0].name, "Nhóm Mới");
        assert!(persisted.cached_groups_json.is_some());
        assert!(persisted.stored_conversation.is_some());
    }
}

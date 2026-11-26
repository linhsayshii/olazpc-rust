//! Board pins domain state and pure helpers (U7).
//!
//! Mirrors `Sources/Olaz/ZaloRuntime/ZaloEngine+Pins.swift` and the board pin structs in
//! `Sources/Olaz/ZaloRuntime/ZaloEngine+MessageActions.swift`.
//!
//! No I/O and no wall clock live here (D9).

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use olaz_api::{ApiError, JsonObject, board_topic_params};
use olaz_json::{int64, string as json_string};
use olaz_net::NetError;
use olaz_wire::{ChatMessage, Kind, Status, strip_user_prefix};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::actions::swift_error_type_name;
use crate::messages::is_valid_url_str;

/// Default pin limit when a board response omits `pinLimit` (`ZaloWireParser.defaultPinLimit`).
pub const DEFAULT_PIN_LIMIT: i64 = 3;

/// Card toast shown when pinning a message fails (`ZaloEngine+MessageActions.swift:788`).
pub const PIN_FAILED_CARD_TEXT: &str = "Ghim tin nhắn không thành công.";

/// Card toast shown when unpinning a topic fails (`ZaloEngine+MessageActions.swift:841`).
pub const UNPIN_FAILED_CARD_TEXT: &str = "Yêu cầu thực hiện không thành công";

/// What pinning one more topic needs when the board holds `count` of at most `limit`
/// (`PinLimitDecision` in `ZaloEngine+Pins.swift`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PinLimitDecision {
    Allowed,
    /// One over: confirm replacing the oldest pin (the last item of the newest-first list).
    ReplaceOldest,
    /// Several over (limit was lowered): ask the user to drop at least `need` pins first.
    ChooseMany {
        need: i64,
    },
}

impl PinLimitDecision {
    #[must_use]
    pub fn decide(count: usize, limit: i64) -> Self {
        let count_i64 = i64::try_from(count).unwrap_or(i64::MAX);
        if limit <= 0 || count_i64 < limit {
            return Self::Allowed;
        }
        let need = count_i64.saturating_sub(limit).saturating_add(1);
        if need == 1 {
            Self::ReplaceOldest
        } else {
            Self::ChooseMany { need }
        }
    }
}

/// One pin of a conversation (`PinnedItem`), newest first.
#[derive(Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PinnedItem {
    pub ref_id: String,
    pub kind: String,
    pub title: String,
    pub sender: String,
    pub thumbnail: Option<String>,
    pub msg_id: String,
    pub cli_msg_id: String,
}

/// Alias matching U12's `BoardPinItem` name.
pub type BoardPinItem = PinnedItem;

impl PinnedItem {
    /// Official board label for the pin's kind (`PinnedItem.label`, `STR_MSG_PINNED…`).
    #[must_use]
    pub fn label(&self) -> &'static str {
        match self.kind.as_str() {
            "message" => "Tin nhắn",
            "poll" => "Bình chọn",
            "reminder" => "Nhắc hẹn",
            _ => "Ghi chú",
        }
    }

    /// Whether this pin points at `msg` (`PinnedItem.message(in:)` single-message check).
    #[must_use]
    pub fn matches_message(&self, msg: &ChatMessage) -> bool {
        if self.kind != "message" {
            return false;
        }
        (!self.msg_id.is_empty() && msg.id == self.msg_id)
            || (!self.cli_msg_id.is_empty() && msg.id == self.cli_msg_id)
    }

    /// Finds the loaded chat message this pin points at (`PinnedItem.message(in:)`).
    #[must_use]
    pub fn find_message<'a>(&self, list: &'a [ChatMessage]) -> Option<&'a ChatMessage> {
        if self.kind != "message" {
            return None;
        }
        list.iter().rev().find(|m| self.matches_message(m))
    }

    /// Serializes to the Case format v1 JSON representation.
    #[must_use]
    pub fn to_case_json(&self) -> Value {
        json!({
            "ref": self.ref_id,
            "kind": self.kind,
            "title": self.title,
            "sender": self.sender,
            "thumbnail": self.thumbnail,
            "msg_id": self.msg_id,
            "cli_msg_id": self.cli_msg_id,
        })
    }
}

impl fmt::Debug for PinnedItem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PinnedItem")
            .field("kind", &self.kind)
            .field("has_thumb", &self.thumbnail.is_some())
            .finish()
    }
}

/// A conversation's pinned list (`PinnedList`).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PinnedList {
    pub ready: bool,
    pub can_pin: bool,
    pub limit: i64,
    pub items: Vec<PinnedItem>,
}

/// Alias matching U12's `BoardPinList` name.
pub type BoardPinList = PinnedList;

impl Default for PinnedList {
    fn default() -> Self {
        Self {
            ready: false,
            can_pin: false,
            limit: DEFAULT_PIN_LIMIT,
            items: Vec::new(),
        }
    }
}

impl PinnedList {
    /// Parses Swift's `PinnedList(json:)` shape (also used by `handlePins(state:)` and test seeds).
    #[must_use]
    pub fn from_json(json_obj: &JsonObject) -> Self {
        let ready = json_obj
            .get("ready")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let can_pin = json_obj
            .get("canPin")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let limit = json_obj
            .get("limit")
            .and_then(Value::as_i64)
            .filter(|&l| l > 0)
            .unwrap_or(DEFAULT_PIN_LIMIT);
        let items = json_obj
            .get("items")
            .and_then(Value::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| {
                        let row = v.as_object()?;
                        let ref_id = row.get("ref").and_then(Value::as_str).unwrap_or("");
                        if ref_id.is_empty() {
                            return None;
                        }
                        let kind = match row.get("kind").and_then(Value::as_str).unwrap_or("") {
                            "message" => "message",
                            "note" => "note",
                            "link" => "link",
                            "poll" => "poll",
                            "reminder" => "reminder",
                            _ => "note",
                        };
                        let title = row
                            .get("title")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_owned();
                        let sender = row
                            .get("sender")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_owned();
                        let thumbnail = row
                            .get("thumb")
                            .or_else(|| row.get("thumbnail"))
                            .and_then(Value::as_str)
                            .filter(|s| !s.is_empty() && is_valid_url_str(s))
                            .map(str::to_owned);
                        let msg_id = row
                            .get("msgId")
                            .or_else(|| row.get("msg_id"))
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_owned();
                        let cli_msg_id = row
                            .get("cliMsgId")
                            .or_else(|| row.get("cli_msg_id"))
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_owned();
                        Some(PinnedItem {
                            ref_id: ref_id.to_owned(),
                            kind: kind.to_owned(),
                            title,
                            sender,
                            thumbnail,
                            msg_id,
                            cli_msg_id,
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        Self {
            ready,
            can_pin,
            limit,
            items,
        }
    }

    /// Serializes to the Case format v1 JSON representation.
    #[must_use]
    pub fn to_case_json(&self) -> Value {
        json!({
            "ready": self.ready,
            "can_pin": self.can_pin,
            "limit": self.limit,
            "items": self.items.iter().map(PinnedItem::to_case_json).collect::<Vec<_>>(),
        })
    }
}

impl fmt::Debug for PinnedList {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PinnedList")
            .field("ready", &self.ready)
            .field("can_pin", &self.can_pin)
            .field("limit", &self.limit)
            .field("items", &self.items.len())
            .finish()
    }
}

/// Raw board topic cache for a conversation (`cachedBoardRawTopics[convId]`).
#[derive(Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct BoardRawTopics {
    pub version: i64,
    /// `topic_id -> raw JSON object` (used to extract `type` for `unpinv2` / `multi_unpin`).
    pub topics: BTreeMap<String, JsonObject>,
}

impl BoardRawTopics {
    /// Serializes to the Case format v1 JSON representation (`{version, topic_ids}`).
    #[must_use]
    pub fn to_case_json(&self) -> Value {
        let topic_ids: Vec<String> = self.topics.keys().cloned().collect();
        json!({
            "version": self.version,
            "topic_ids": topic_ids,
        })
    }
}

impl fmt::Debug for BoardRawTopics {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BoardRawTopics")
            .field("version", &self.version)
            .field("topics", &self.topics.len())
            .finish()
    }
}

/// Result of [`parse_board_topics`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParsedBoardTopics {
    pub list: PinnedList,
    pub raw_topics: BoardRawTopics,
    pub raw_rows_count: i64,
}

/// Parses a `fetch_board_pins` boxed `{items, boardVersion, pinLimit}` object into
/// [`PinnedList`] + [`BoardRawTopics`] (`ZaloWireParser.parseBoardTopics`).
#[must_use]
pub fn parse_board_topics(
    box_obj: &JsonObject,
    sender_name: impl Fn(&str) -> Option<String>,
) -> ParsedBoardTopics {
    let raw_rows_count = box_obj
        .get("items")
        .and_then(Value::as_array)
        .map_or(-1, |a| i64::try_from(a.len()).unwrap_or(i64::MAX));
    let rows: Vec<&JsonObject> = box_obj
        .get("items")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(Value::as_object).collect())
        .unwrap_or_default();
    let version = int64(box_obj.get("boardVersion")).unwrap_or(0);
    let limit = int64(box_obj.get("pinLimit")).unwrap_or(0);

    let mut raw: BTreeMap<String, JsonObject> = BTreeMap::new();
    let mut items: Vec<PinnedItem> = Vec::with_capacity(rows.len());

    for row in rows {
        let ref_id = json_string(
            row.get("id")
                .or_else(|| row.get("topicId"))
                .or_else(|| row.get("topic_id")),
        );
        if ref_id.is_empty() || raw.contains_key(&ref_id) {
            continue;
        }
        raw.insert(ref_id.clone(), row.clone());
        let params = board_topic_params(row);
        let kind = match int64(row.get("type")).unwrap_or(2) {
            3 => "poll",
            0 => "note",
            1 => "reminder",
            _ => "message",
        };
        let sender_uid = strip_user_prefix(&json_string(
            params
                .get("senderUid")
                .or_else(|| params.get("senderId"))
                .or_else(|| row.get("creatorId")),
        ));
        let mut sender = json_string(
            params
                .get("senderName")
                .or_else(|| params.get("sender_name"))
                .or_else(|| params.get("dName"))
                .or_else(|| params.get("fromName"))
                .or_else(|| row.get("creatorName")),
        );
        if sender.is_empty() && !sender_uid.is_empty() {
            sender = sender_name(&sender_uid).unwrap_or_default();
        }
        let title = json_string(
            params
                .get("title")
                .or_else(|| params.get("linkCaption"))
                .or_else(|| params.get("content"))
                .or_else(|| params.get("msg"))
                .or_else(|| params.get("message"))
                .or_else(|| params.get("description"))
                .or_else(|| row.get("title"))
                .or_else(|| row.get("content")),
        );
        let thumb_str = json_string(params.get("thumb"));
        let thumbnail =
            (!thumb_str.is_empty() && is_valid_url_str(&thumb_str)).then_some(thumb_str);
        let msg_id = json_string(
            params
                .get("globalMsgId")
                .or_else(|| params.get("global_msg_id"))
                .or_else(|| params.get("msgId"))
                .or_else(|| params.get("msg_id")),
        );
        let cli_msg_id = json_string(
            params
                .get("cliMsgId")
                .or_else(|| params.get("client_msg_id")),
        );
        items.push(PinnedItem {
            ref_id,
            kind: kind.to_owned(),
            title,
            sender,
            thumbnail,
            msg_id,
            cli_msg_id,
        });
    }

    let list = PinnedList {
        ready: true,
        can_pin: true,
        limit: if limit > 0 { limit } else { DEFAULT_PIN_LIMIT },
        items,
    };
    ParsedBoardTopics {
        list,
        raw_topics: BoardRawTopics {
            version,
            topics: raw,
        },
        raw_rows_count,
    }
}

/// Returns whether `msg` is currently pinned on its conversation's board (`ZaloEngine.isPinned`).
#[must_use]
pub fn is_pinned(lists: &BTreeMap<String, PinnedList>, msg: &ChatMessage) -> bool {
    lists
        .get(&msg.conversation_id)
        .is_some_and(|list| list.items.iter().any(|it| it.matches_message(msg)))
}

/// Returns whether `msg` may be pinned (`ZaloEngine.canPinMessage`).
#[must_use]
pub fn can_pin_message(lists: &BTreeMap<String, PinnedList>, msg: &ChatMessage) -> bool {
    let Some(list) = lists.get(&msg.conversation_id) else {
        return false;
    };
    if !list.ready || !list.can_pin || msg.is_e2ee {
        return false;
    }
    if matches!(
        msg.kind,
        Kind::Recalled
            | Kind::Call { .. }
            | Kind::Placeholder { .. }
            | Kind::System
            | Kind::Notice { .. }
    ) {
        return false;
    }
    !matches!(msg.status, Status::Sending | Status::Failed)
}

/// Extracts the API path component from a session error URL string (matching Swift `URL(string:)?.path`).
fn url_path(raw: &str) -> &str {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return "";
    }
    let after_scheme = if let Some(idx) = trimmed.find("://") {
        let rest = &trimmed[idx + 3..];
        match rest.find('/') {
            Some(slash) => &rest[slash..],
            None => return "",
        }
    } else {
        trimmed
    };
    after_scheme
        .split(['?', '#'])
        .next()
        .unwrap_or(after_scheme)
}

/// Formats a board request error for logs (`ZaloEngine.pinErrorShape`).
#[must_use]
pub fn pin_error_shape(err: &ApiError) -> String {
    match err {
        ApiError::Net(NetError::Session(se)) => {
            let path = url_path(&se.url);
            format!("code={} path={path}", se.code)
        }
        other => format!("error={}", swift_error_type_name(other)),
    }
}

/// Observable snapshot of board pins shipped in [`crate::changes::CoreChanges`] and
/// [`crate::state::CoreSnapshot`].
#[derive(Clone, Default, PartialEq, Eq)]
pub struct PinsSnapshot {
    pub lists: BTreeMap<String, PinnedList>,
    pub raw_topics: BTreeMap<String, BoardRawTopics>,
}

impl PinsSnapshot {
    #[must_use]
    pub fn lists_to_case_json(&self) -> Value {
        let mut map = Map::new();
        for (cid, list) in &self.lists {
            map.insert(cid.clone(), list.to_case_json());
        }
        Value::Object(map)
    }

    #[must_use]
    pub fn raw_topics_to_case_json(&self) -> Value {
        let mut map = Map::new();
        for (cid, raw) in &self.raw_topics {
            map.insert(cid.clone(), raw.to_case_json());
        }
        Value::Object(map)
    }
}

impl fmt::Debug for PinsSnapshot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PinsSnapshot")
            .field("lists", &self.lists.len())
            .field("raw_topics", &self.raw_topics.len())
            .finish()
    }
}

/// What happens after `Effect::RefreshBoardPins` completes or is skipped.
#[derive(Clone, PartialEq, Eq)]
pub enum RefreshBoardFollowup {
    /// Standalone refresh (`Command::RefreshBoardPins`, `Command::RewatchPins`, or `PinTopic`).
    Standalone { op_id: Option<u64> },
    /// Part of `Command::OpenConversation`: emits `MarkReadBoundary` and completes `op_id`.
    OpenConversation {
        conv_id: String,
        seen_target: Option<crate::input::SeenTarget>,
        op_id: Option<u64>,
    },
    /// After replace-unpin succeeded inside `pin(msg, replacing:)`: proceed to `ResolveMessageIds`.
    PinReplaceAfterUnpin { pin_op_id: u64 },
    /// After `pinBoardMessage` succeeded: release busy key & complete `op_id`.
    PinSucceeded { pin_op_id: u64 },
    /// After `pin` failed (either replace-unpin or create): show card, release busy key & complete `op_id`.
    PinFailed { pin_op_id: u64 },
    /// After `unpinBoardTopic` succeeded: release busy key & complete `op_id`.
    UnpinSucceeded { unpin_op_id: u64 },
    /// After `unpinBoardTopic` failed: show card, release busy key & complete `op_id`.
    UnpinFailed { unpin_op_id: u64 },
    /// After poll-triggered board refresh: resume the poll pin continuation.
    Poll {
        conv_id: String,
        continuation: crate::effect::PollBoardContinuation,
    },
}

impl fmt::Debug for RefreshBoardFollowup {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Standalone { op_id } => {
                f.debug_struct("Standalone").field("op_id", op_id).finish()
            }
            Self::OpenConversation { op_id, .. } => f
                .debug_struct("OpenConversation")
                .field("op_id", op_id)
                .finish(),
            Self::PinReplaceAfterUnpin { pin_op_id } => f
                .debug_struct("PinReplaceAfterUnpin")
                .field("pin_op_id", pin_op_id)
                .finish(),
            Self::PinSucceeded { pin_op_id } => f
                .debug_struct("PinSucceeded")
                .field("pin_op_id", pin_op_id)
                .finish(),
            Self::PinFailed { pin_op_id } => f
                .debug_struct("PinFailed")
                .field("pin_op_id", pin_op_id)
                .finish(),
            Self::UnpinSucceeded { unpin_op_id } => f
                .debug_struct("UnpinSucceeded")
                .field("unpin_op_id", unpin_op_id)
                .finish(),
            Self::UnpinFailed { unpin_op_id } => f
                .debug_struct("UnpinFailed")
                .field("unpin_op_id", unpin_op_id)
                .finish(),
            Self::Poll { continuation, .. } => f
                .debug_struct("Poll")
                .field("continuation", continuation)
                .finish(),
        }
    }
}

/// Which flow initiated `Effect::UnpinBoardTopicApi`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnpinBoardPurpose {
    PinReplace { pin_op_id: u64 },
    Unpin { unpin_op_id: u64 },
}

#[derive(Clone)]
pub(crate) struct InFlightPin {
    pub(crate) conv_id: String,
    pub(crate) msg: ChatMessage,
    pub(crate) replacing: Option<String>,
    pub(crate) busy_key: String,
    pub(crate) op_id: Option<u64>,
}

#[derive(Clone)]
pub(crate) struct InFlightUnpin {
    pub(crate) conv_id: String,
    pub(crate) busy_key: String,
    pub(crate) op_id: Option<u64>,
}

/// Core-owned board pins state (U7).
#[derive(Clone, Default)]
pub struct PinsState {
    pub lists: BTreeMap<String, PinnedList>,
    pub raw_topics: BTreeMap<String, BoardRawTopics>,
    /// In-flight busy keys (`"{conv}|{msg}|pin"` or `"{conv}|{ref}|unpin"`).
    pub(crate) busy: BTreeSet<String>,
    /// Per-conversation monotonic generation bumped on local mutations to drop stale board refreshes.
    pub(crate) board_gen: BTreeMap<String, u64>,
    pub(crate) next_op_seq: u64,
    pub(crate) in_flight_pins: BTreeMap<u64, InFlightPin>,
    pub(crate) in_flight_unpins: BTreeMap<u64, InFlightUnpin>,
}

impl PinsState {
    #[must_use]
    pub fn snapshot(&self) -> PinsSnapshot {
        PinsSnapshot {
            lists: self.lists.clone(),
            raw_topics: self.raw_topics.clone(),
        }
    }

    pub(crate) fn alloc_op_seq(&mut self) -> u64 {
        self.next_op_seq = self.next_op_seq.saturating_add(1);
        self.next_op_seq
    }

    #[must_use]
    pub(crate) fn current_gen(&self, conv_id: &str) -> u64 {
        self.board_gen.get(conv_id).copied().unwrap_or(0)
    }

    pub(crate) fn bump_gen(&mut self, conv_id: &str) -> u64 {
        let entry = self.board_gen.entry(conv_id.to_owned()).or_insert(0);
        *entry = entry.saturating_add(1);
        *entry
    }

    /// Clears per-session pin lists, raw topics, busy guards, and in-flight maps on logout / reset.
    /// Keeps `board_gen` and `next_op_seq` monotonic across resets to avoid ABA collisions.
    pub(crate) fn reset_session(&mut self) -> bool {
        let had = !self.lists.is_empty() || !self.raw_topics.is_empty();
        self.lists.clear();
        self.raw_topics.clear();
        self.busy.clear();
        self.in_flight_pins.clear();
        self.in_flight_unpins.clear();
        had
    }
}

impl fmt::Debug for PinsState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PinsState")
            .field("lists", &self.lists.len())
            .field("raw_topics", &self.raw_topics.len())
            .field("busy", &self.busy.len())
            .field("in_flight_pins", &self.in_flight_pins.len())
            .field("in_flight_unpins", &self.in_flight_unpins.len())
            .finish()
    }
}

#[cfg(test)]
#[expect(clippy::unwrap_used, reason = "unit test fixtures")]
mod tests {
    use olaz_net::ZaloSessionError;

    use super::*;

    #[test]
    fn pin_limit_decision_matches_swift() {
        assert_eq!(PinLimitDecision::decide(0, 3), PinLimitDecision::Allowed);
        assert_eq!(PinLimitDecision::decide(2, 3), PinLimitDecision::Allowed);
        assert_eq!(
            PinLimitDecision::decide(3, 3),
            PinLimitDecision::ReplaceOldest
        );
        assert_eq!(
            PinLimitDecision::decide(5, 3),
            PinLimitDecision::ChooseMany { need: 3 }
        );
        assert_eq!(PinLimitDecision::decide(9, 0), PinLimitDecision::Allowed);
    }

    #[test]
    fn parse_board_topics_dedupes_and_resolves_kinds_and_fallbacks() {
        let box_obj = json!({
            "boardVersion": 7,
            "pinLimit": 5,
            "items": [
                {"id": "t1", "type": 2, "params": r#"{"title":"Tiêu đề 1","senderName":"Tên 1","thumb":"https://cdn.example.invalid/t1.jpg","globalMsgId":"900101","cliMsgId":"c900101"}"#},
                {"id": "t1", "type": 2, "params": {"title": "Dup"}},
                {"id": "", "type": 2, "params": {"title": "Empty"}},
                {"topicId": "t2", "type": 3, "params": {"linkCaption": "Poll", "senderUid": "u1001"}},
                {"topic_id": "t3", "type": 0, "content": "Row Content"},
                {"id": "t4", "type": 1, "title": "Rem"}
            ]
        })
        .as_object()
        .unwrap()
        .clone();

        let parsed =
            parse_board_topics(&box_obj, |uid| (uid == "u1001").then(|| "Minh".to_owned()));
        assert_eq!(parsed.raw_rows_count, 6);
        assert_eq!(parsed.list.limit, 5);
        assert_eq!(parsed.list.items.len(), 4);
        assert_eq!(parsed.list.items[0].ref_id, "t1");
        assert_eq!(parsed.list.items[0].kind, "message");
        assert_eq!(
            parsed.list.items[0].thumbnail.as_deref(),
            Some("https://cdn.example.invalid/t1.jpg")
        );
        assert_eq!(parsed.list.items[1].kind, "poll");
        assert_eq!(parsed.list.items[1].sender, "Minh");
        assert_eq!(parsed.list.items[2].kind, "note");
        assert_eq!(parsed.list.items[2].title, "Row Content");
        assert_eq!(parsed.list.items[3].kind, "reminder");
        assert_eq!(parsed.raw_topics.version, 7);
        assert_eq!(parsed.raw_topics.topics.len(), 4);
    }

    #[test]
    fn pin_error_shape_matches_swift() {
        let se = ApiError::Net(NetError::Session(ZaloSessionError {
            code: 500,
            message: "fail".to_owned(),
            url: "https://groupboard-wpa.api.zaloapp.com/api/board/pin/list?zpw_ver=694".to_owned(),
        }));
        assert_eq!(pin_error_shape(&se), "code=500 path=/api/board/pin/list");

        let se_path = ApiError::Net(NetError::Session(ZaloSessionError {
            code: 114,
            message: "unpin".to_owned(),
            url: "/api/board/unpinv2".to_owned(),
        }));
        assert_eq!(
            pin_error_shape(&se_path),
            "code=114 path=/api/board/unpinv2"
        );

        let http = ApiError::Net(NetError::Http {
            status: 502,
            body: String::new(),
        });
        assert_eq!(pin_error_shape(&http), "error=ZaloTransportError");
    }
}

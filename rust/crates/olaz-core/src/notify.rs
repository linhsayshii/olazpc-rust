//! Notifications, per-conversation mutes, notification policy, and message card actions (U16).
//!
//! Mirrors `ZaloEngine+Notifications.swift`, `ZaloEngine+CardActions.swift`, and the pure
//! `NotificationPolicy` helpers in `NativeNotifier.swift`.
//!
//! Approved user decisions (`user-decisions` item 16):
//! 1. Mute / unmute updates `notification_settings.mutes` and persists SQLite preferences only
//!    after `POST /api/social/profile/setmute` succeeds; on server error, keeps the previous mute
//!    state, skips SQLite persistence, and emits `ShowCard { text: "Có lỗi xảy ra" }`.
//! 2. `joinGroupByLink` maps Zalo server error codes to the official client states and Vietnamese
//!    strings (`178` -> `already` opening the group with preview's `group_id` fallback, `240` ->
//!    `pending`, specific strings for `227`, `228`, `177`, `257`, `259`, `166`, `280`, `281`,
//!    `282`, `283`, `284`, `285`, `286`, `833`, `"Vào nhóm không thành công. ({code})"` for other
//!    server error codes, and `"Vào nhóm không thành công."` for transport errors without a code).

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fmt;

use olaz_api::ApiError;
use olaz_json::{bool_value as bool_val, int64, parse_object, string};
use olaz_wire::{
    ECard, UNKNOWN_NAME, group_conv_id, is_group_id, sticker_cdn_url, strip_user_prefix,
    web_link_sanitized,
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

fn float64(v: Option<&Value>) -> Option<f64> {
    match v? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse::<f64>().ok(),
        _ => None,
    }
}

/// Official hidden-preview notification body (`STR_PASS_CODE_NOTIFY_MESSAGE`).
pub const HIDDEN_PREVIEW_BODY: &str = "Bạn có tin nhắn mới";

/// Official generic toast error (`STR_TOAST_ERROR`) used when mute/unmute fails on the server.
pub const MUTE_ERROR_TOAST_TEXT: &str = "Có lỗi xảy ra";

/// Default unsupported card-action text (`CardActionOutcome.defaultUnsupported`).
pub const CARD_DEFAULT_UNSUPPORTED: &str = "Chưa hỗ trợ trên ứng dụng này";

/// Default failed card-action text.
pub const CARD_DEFAULT_FAILED: &str = "Không thực hiện được thao tác.";

/// Pure `NotificationPolicy` helpers shared with Swift via UniFFI.
pub mod policy {
    use super::HIDDEN_PREVIEW_BODY;

    /// Backstop banner suppression when the user is actively viewing the target conversation.
    #[must_use]
    pub fn should_suppress(
        app_is_active: bool,
        main_window_visible: bool,
        open_conversation: Option<&str>,
        tag: &str,
        user_idle_seconds: f64,
        idle_threshold: f64,
    ) -> bool {
        if !app_is_active
            || !main_window_visible
            || tag.is_empty()
            || open_conversation != Some(tag)
        {
            return false;
        }
        user_idle_seconds < idle_threshold
    }

    /// Inline banner reply is refused while hidden-chat state is unknown or the chat is locked.
    #[must_use]
    pub fn refuses_reply(hidden_state_known: bool, conversation_locked: bool) -> bool {
        !hidden_state_known || conversation_locked
    }

    /// Conversations that newly entered the hidden set (`new \ old`), sorted deterministically.
    #[must_use]
    pub fn newly_hidden(old: &[String], new: &[String]) -> Vec<String> {
        let old_set: std::collections::HashSet<&str> = old.iter().map(String::as_str).collect();
        let mut out: Vec<String> = new
            .iter()
            .filter(|id| !old_set.contains(id.as_str()))
            .cloned()
            .collect();
        out.sort();
        out.dedup();
        out
    }

    /// Banner body text honoring `shows_preview`.
    #[must_use]
    pub fn body(raw_body: &str, shows_preview: bool) -> String {
        if shows_preview {
            raw_body.to_owned()
        } else {
            HIDDEN_PREVIEW_BODY.to_owned()
        }
    }
}

/// macOS notification authorization status mirrored in [`NotificationSettingsSnapshot`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum NotifAuthorization {
    #[default]
    Unknown,
    Unavailable,
    NotDetermined,
    Denied,
    Authorized,
}

impl NotifAuthorization {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::Unavailable => "unavailable",
            Self::NotDetermined => "notDetermined",
            Self::Denied => "denied",
            Self::Authorized => "authorized",
        }
    }

    #[must_use]
    pub fn from_raw(raw: &str) -> Option<Self> {
        match raw {
            "unknown" => Some(Self::Unknown),
            "unavailable" => Some(Self::Unavailable),
            "notDetermined" => Some(Self::NotDetermined),
            "denied" => Some(Self::Denied),
            "authorized" => Some(Self::Authorized),
            _ => None,
        }
    }
}

/// Per-conversation mute record (`startTime` and `duration` in seconds; `< 0` = indefinite).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct MuteInfo {
    pub start_time: f64,
    pub duration: f64,
}

impl MuteInfo {
    #[must_use]
    pub fn is_indefinite(self) -> bool {
        self.duration < 0.0
    }

    /// Expiry timestamp in milliseconds, or `None` when indefinite.
    #[must_use]
    pub fn until_ms(self) -> Option<i64> {
        if self.is_indefinite() {
            None
        } else {
            Some(((self.start_time + self.duration) * 1000.0).round() as i64)
        }
    }

    /// Compares `start_time + duration` against `now_ms` without calendar / timezone offsets.
    #[must_use]
    pub fn is_active(self, now_ms: i64) -> bool {
        if self.is_indefinite() {
            return true;
        }
        let now_sec = (now_ms as f64) / 1000.0;
        (self.start_time + self.duration) > now_sec
    }

    /// Parses one `{id, startTime, duration}` row (mirrors Swift `MuteInfo.parse`).
    #[must_use]
    pub fn parse_row(row: &Map<String, Value>) -> Option<(String, Self)> {
        let id = match row.get("id") {
            Some(Value::String(s)) if !s.is_empty() => s.clone(),
            Some(Value::Number(n)) => {
                let s = n.to_string();
                if s.is_empty() {
                    return None;
                }
                s
            }
            _ => return None,
        };
        let duration = float64(row.get("duration")).unwrap_or(-1.0);
        let start_raw = float64(row.get("startTime"))
            .or_else(|| float64(row.get("start_time")))
            .unwrap_or(0.0);
        if !duration.is_finite() || !start_raw.is_finite() || duration == 0.0 {
            return None;
        }
        let start = if start_raw > 1e11 {
            start_raw / 1000.0
        } else {
            start_raw
        };
        if start < 0.0 {
            return None;
        }
        Some((
            id,
            Self {
                start_time: start,
                duration: if duration < 0.0 { -1.0 } else { duration },
            },
        ))
    }

    /// Formats the description string from Swift-formatted `HH:mm` and optional `dd/MM` (when not same day).
    #[must_use]
    pub fn format_description(self, hh_mm: Option<&str>, dd_mm_if_other_day: Option<&str>) -> String {
        if self.is_indefinite() {
            return "Cho đến khi được mở lại".to_owned();
        }
        let Some(hm) = hh_mm else {
            return "Cho đến khi được mở lại".to_owned();
        };
        match dd_mm_if_other_day {
            None => format!("Cho đến {hm}"),
            Some(dm) => format!("Cho đến {hm} ngày {dm}"),
        }
    }

    /// Formats the status string from Swift-formatted `HH:mm` and optional `dd/MM` (when not same day).
    #[must_use]
    pub fn format_status_text(self, hh_mm: Option<&str>, dd_mm_if_other_day: Option<&str>) -> String {
        if self.is_indefinite() {
            return "Đang tắt cho đến khi được mở lại".to_owned();
        }
        let Some(hm) = hh_mm else {
            return "Đang tắt cho đến khi được mở lại".to_owned();
        };
        match dd_mm_if_other_day {
            None => format!("Đang tắt đến {hm}"),
            Some(dm) => format!("Đang tắt đến {hm} ngày {dm}"),
        }
    }

    /// Formats description at `now_ms` using fixed `utc_offset_secs` (`0` for UTC).
    #[must_use]
    pub fn description_at(self, now_ms: i64, utc_offset_secs: i32) -> String {
        let Some(until_ms) = self.until_ms() else {
            return self.format_description(None, None);
        };
        let (hm, dm) = hh_mm_and_dd_mm(until_ms, now_ms, utc_offset_secs);
        self.format_description(Some(&hm), dm.as_deref())
    }

    /// Formats status text at `now_ms` using fixed `utc_offset_secs` (`0` for UTC).
    #[must_use]
    pub fn status_text_at(self, now_ms: i64, utc_offset_secs: i32) -> String {
        let Some(until_ms) = self.until_ms() else {
            return self.format_status_text(None, None);
        };
        let (hm, dm) = hh_mm_and_dd_mm(until_ms, now_ms, utc_offset_secs);
        self.format_status_text(Some(&hm), dm.as_deref())
    }
}

/// Active mute entry sorted longest-standing first (`(start_time, id)` ascending).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActiveMuteEntry {
    pub id: String,
    pub info: MuteInfo,
}

/// Observable notification settings state mirrored to Swift (`DirtyKey::NotificationSettings`).
/// Howard Hinnant's civil-from-days algorithm: converts days since `1970-01-01` to `(year, month, day)`.
fn civil_from_days(days_since_epoch: i64) -> (i32, u32, u32) {
    let z = days_since_epoch + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = (yoe as i64) + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if m <= 2 { y + 1 } else { y };
    (year as i32, m as u32, d as u32)
}

fn hh_mm_and_dd_mm(until_ms: i64, now_ms: i64, utc_offset_secs: i32) -> (String, Option<String>) {
    let offset = i64::from(utc_offset_secs);
    let until_local_sec = until_ms.div_euclid(1000) + offset;
    let now_local_sec = now_ms.div_euclid(1000) + offset;
    let until_days = until_local_sec.div_euclid(86_400);
    let now_days = now_local_sec.div_euclid(86_400);
    let sec_of_day = until_local_sec.rem_euclid(86_400);
    let hh = sec_of_day / 3600;
    let mm = (sec_of_day % 3600) / 60;
    let hm = format!("{hh:02}:{mm:02}");
    let until_ymd = civil_from_days(until_days);
    let now_ymd = civil_from_days(now_days);
    let dm = if until_ymd == now_ymd {
        None
    } else {
        Some(format!("{:02}/{:02}", until_ymd.2, until_ymd.1))
    };
    (hm, dm)
}

/// Computes `duration_secs` for `MuteDuration` raw values (`1` = 1h, `2` = 4h, `3` = next 08:00, `4` = `-1`).
#[must_use]
pub fn mute_duration_secs(raw: i32, now_ms: i64, utc_offset_secs: i32) -> i64 {
    match raw {
        1 => 3600,
        2 => 4 * 3600,
        3 => {
            let now_sec = now_ms.div_euclid(1000);
            let local_sec = now_sec + i64::from(utc_offset_secs);
            let sec_of_day = local_sec.rem_euclid(86_400);
            let target_sec_of_day = 8 * 3600;
            if sec_of_day < target_sec_of_day {
                target_sec_of_day - sec_of_day
            } else {
                86_400 - sec_of_day + target_sec_of_day
            }
        }
        _ => -1,
    }
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct NotificationSettingsSnapshot {
    pub is_loaded: bool,
    pub enabled: bool,
    pub sound: bool,
    pub has_sound_setting: bool,
    pub shows_preview: bool,
    pub authorization: NotifAuthorization,
    pub mutes: BTreeMap<String, MuteInfo>,
}

impl Default for NotificationSettingsSnapshot {
    fn default() -> Self {
        Self {
            is_loaded: false,
            enabled: true,
            sound: false,
            has_sound_setting: false,
            shows_preview: true,
            authorization: NotifAuthorization::Unknown,
            mutes: BTreeMap::new(),
        }
    }
}

impl fmt::Debug for NotificationSettingsSnapshot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("NotificationSettingsSnapshot")
            .field("is_loaded", &self.is_loaded)
            .field("enabled", &self.enabled)
            .field("sound", &self.sound)
            .field("has_sound_setting", &self.has_sound_setting)
            .field("shows_preview", &self.shows_preview)
            .field("authorization", &self.authorization)
            .field("mutes_count", &self.mutes.len())
            .finish()
    }
}

impl NotificationSettingsSnapshot {
    /// Active mute for `conv_id` at `now_ms`, or `None` when unmuted / expired.
    #[must_use]
    pub fn mute_for(&self, conv_id: &str, now_ms: i64) -> Option<MuteInfo> {
        let info = *self.mutes.get(conv_id)?;
        info.is_active(now_ms).then_some(info)
    }

    #[must_use]
    pub fn is_muted(&self, conv_id: &str, now_ms: i64) -> bool {
        self.mute_for(conv_id, now_ms).is_some()
    }

    /// Active mutes at `now_ms`, sorted by `(start_time, id)` ascending.
    #[must_use]
    pub fn active_mutes(&self, now_ms: i64) -> Vec<ActiveMuteEntry> {
        let mut active: Vec<ActiveMuteEntry> = self
            .mutes
            .iter()
            .filter(|(_, info)| info.is_active(now_ms))
            .map(|(id, info)| ActiveMuteEntry {
                id: id.clone(),
                info: *info,
            })
            .collect();
        active.sort_by(|a, b| {
            a.info
                .start_time
                .total_cmp(&b.info.start_time)
                .then_with(|| a.id.cmp(&b.id))
        });
        active
    }

    /// Applies an adapter `{kind: "settings", ...}` payload.
    pub fn apply_settings_payload(&mut self, json: &Map<String, Value>) {
        self.is_loaded = true;
        if let Some(enabled) = bool_val(json.get("enabled")) {
            self.enabled = enabled;
        }
        if let Some(sound) = bool_val(json.get("sound")) {
            self.sound = sound;
        }
        if let Some(has_sound) = bool_val(json.get("hasSoundSetting")) {
            self.has_sound_setting = has_sound;
        }
        let mut next = BTreeMap::new();
        if let Some(arr) = json.get("mutes").and_then(Value::as_array) {
            for item in arr {
                if let Some(obj) = item.as_object()
                    && let Some((id, info)) = MuteInfo::parse_row(obj)
                {
                    next.insert(id, info);
                }
            }
        }
        self.mutes = next;
    }

    /// Serializes `mutedThreads` JSON bytes for SQLite persistence.
    #[must_use]
    pub fn serialize_muted_threads_json(&self) -> Vec<u8> {
        let rows: Vec<Value> = self
            .mutes
            .iter()
            .map(|(id, info)| {
                json!({
                    "id": id,
                    "startTime": encode_number_clean(info.start_time),
                    "duration": encode_number_clean(info.duration),
                })
            })
            .collect();
        serde_json::to_vec(&rows).unwrap_or_else(|_| b"[]".to_vec())
    }
}

fn encode_number_clean(val: f64) -> Value {
    if val.is_finite() && val.fract() == 0.0 && (-9e15..=9e15).contains(&val) {
        json!(val as i64)
    } else {
        json!(val)
    }
}

/// Banner payload emitted via `HostCall::NotifyBanner`.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NotifyBannerPayload {
    pub title: String,
    pub body: String,
    pub conv_id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub is_group: bool,
    pub avatar_url: Option<String>,
    pub silent: bool,
}

impl fmt::Debug for NotifyBannerPayload {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("NotifyBannerPayload")
            .field("is_group", &self.is_group)
            .field("has_avatar", &self.avatar_url.is_some())
            .field("silent", &self.silent)
            .field("title_len", &self.title.len())
            .field("body_len", &self.body.len())
            .finish()
    }
}

// U7: Read-only reminder pin reference synced from Swift `pins` until U7 merges.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PinReminderRef {
    pub msg_id: String,
    pub cli_msg_id: String,
    pub reminder_ref: String,
}

impl fmt::Debug for PinReminderRef {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PinReminderRef")
            .field("has_ref", &!self.reminder_ref.is_empty())
            .finish()
    }
}

/// Suggested sticker returned by `suggested_stickers`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SuggestedStickerItem {
    pub sticker_ref: String,
    pub url: String,
}

/// Contact card quick state (`isSelf`, `isFriend`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct ContactCardStateResult {
    pub is_self: bool,
    pub is_friend: bool,
}

/// Contact profile summary (`contactProfile`).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContactProfileResult {
    pub uid: String,
    pub name: String,
    pub zalo_name: String,
    pub avatar: Option<String>,
    pub bio: String,
    pub is_self: bool,
    pub is_friend: bool,
    pub is_oa: bool,
}

impl fmt::Debug for ContactProfileResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ContactProfileResult")
            .field("is_self", &self.is_self)
            .field("is_friend", &self.is_friend)
            .field("has_avatar", &self.avatar.is_some())
            .finish()
    }
}

/// How the add-friend form was reached (`FriendRequestOrigin`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum FriendRequestOriginKind {
    #[default]
    Add,
    Card,
    None,
}

impl FriendRequestOriginKind {
    #[must_use]
    pub fn from_raw(raw: &str) -> Self {
        match raw {
            "card" => Self::Card,
            "none" => Self::None,
            _ => Self::Add,
        }
    }
}

/// Pre-check result for friend request (`FriendRequestPrep`).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FriendRequestPrepResult {
    /// `"ready" | "requested" | "requesting" | "friend" | "self" | "error"`.
    pub state: String,
    pub default_message: String,
    pub max_message: i64,
}

impl fmt::Debug for FriendRequestPrepResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FriendRequestPrepResult")
            .field("state", &self.state)
            .field("max_message", &self.max_message)
            .finish()
    }
}

/// Submit friend request result (`submitFriendRequest`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SubmitFriendRequestResult {
    pub ok: bool,
    pub text: String,
    pub pending: bool,
}

/// Save alias result (`saveAlias`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SaveAliasResult {
    pub ok: bool,
    pub text: String,
}

/// Member row inside [`GroupInvitePreviewResult`].
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GroupInviteMember {
    pub id: String,
    pub name: String,
    pub avatar: Option<String>,
    pub admin: bool,
}

impl fmt::Debug for GroupInviteMember {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupInviteMember")
            .field("admin", &self.admin)
            .finish()
    }
}

/// Group invite preview (`GroupInvitePreview`).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GroupInvitePreviewResult {
    /// `"preview" | "member" | "error"`.
    pub state: String,
    pub group_id: String,
    pub name: String,
    pub avatar: Option<String>,
    pub total_member: i64,
    pub desc: String,
    pub community: bool,
    pub creator_name: String,
    pub members: Vec<GroupInviteMember>,
    pub text: String,
}

impl Default for GroupInvitePreviewResult {
    fn default() -> Self {
        Self {
            state: "error".to_owned(),
            group_id: String::new(),
            name: String::new(),
            avatar: None,
            total_member: 0,
            desc: String::new(),
            community: false,
            creator_name: String::new(),
            members: Vec::new(),
            text: String::new(),
        }
    }
}

impl fmt::Debug for GroupInvitePreviewResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupInvitePreviewResult")
            .field("state", &self.state)
            .field("total_member", &self.total_member)
            .finish()
    }
}

/// Result of joining a group by invite link (`GroupJoinResult`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GroupJoinResultData {
    /// `"joined" | "pending" | "already" | "error"`.
    pub state: String,
    pub group_id: String,
    pub text: String,
}

impl GroupJoinResultData {
    #[must_use]
    pub fn error(text: impl Into<String>) -> Self {
        Self {
            state: "error".to_owned(),
            group_id: String::new(),
            text: text.into(),
        }
    }
}

/// Card action execution outcome (`CardActionOutcome` subset returned by core).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum CardActionOutcomeData {
    Done,
    Unsupported(String),
    Locked(String),
    Failed(String),
    Pending(String),
}

impl CardActionOutcomeData {
    #[must_use]
    pub fn as_status_and_text(&self) -> (&'static str, Option<&str>) {
        match self {
            Self::Done => ("done", None),
            Self::Unsupported(t) => ("unsupported", Some(t.as_str())),
            Self::Locked(t) => ("locked", Some(t.as_str())),
            Self::Failed(t) => ("failed", Some(t.as_str())),
            Self::Pending(t) => ("pending", Some(t.as_str())),
        }
    }
}

/// Normalized reminder card snapshot (`ReminderSnapshot`).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReminderSnapshotData {
    pub variant: String,
    pub id: String,
    pub title: String,
    /// Milliseconds in `(0, 4_102_444_800_000)`, else `None`.
    pub start_ms: Option<i64>,
    pub repeat_label: String,
    pub creator_name: String,
    pub only_me: bool,
    pub is_group: bool,
    /// `"" | "accept" | "reject"`.
    pub mine: String,
    pub accepted_count: i64,
    pub rejected_count: i64,
    pub can_rsvp: bool,
    pub can_view: bool,
    pub deleted: bool,
    pub sig: String,
}

impl fmt::Debug for ReminderSnapshotData {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ReminderSnapshotData")
            .field("variant", &self.variant)
            .field("is_group", &self.is_group)
            .field("deleted", &self.deleted)
            .finish()
    }
}

/// Result of `respondToReminder`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RespondReminderResult {
    pub ok: bool,
    pub text: String,
    pub snapshot: Option<ReminderSnapshotData>,
}

/// One person in [`ReminderRespondersData`].
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReminderResponderPerson {
    pub uid: String,
    pub name: String,
    pub avatar: Option<String>,
    pub is_me: bool,
}

impl fmt::Debug for ReminderResponderPerson {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ReminderResponderPerson")
            .field("is_me", &self.is_me)
            .finish()
    }
}

/// Reminder responders list (`ReminderResponders`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReminderRespondersData {
    pub accept: Vec<ReminderResponderPerson>,
    pub reject: Vec<ReminderResponderPerson>,
    pub accept_total: i64,
    pub reject_total: i64,
    pub accept_more: i64,
    pub reject_more: i64,
}

/// Active waiter awaiting reminder change or 15 s timeout.
#[derive(Debug, Clone)]
pub(crate) struct ReminderWatchWaiter {
    pub waiter_id: u64,
    pub op_id: u64,
    pub conv_id: String,
    pub msg_id: String,
    pub event_id: String,
}

/// In-flight mute / unmute API operation awaiting server response (user decision 16.1).
#[derive(Debug, Clone)]
pub(crate) struct MuteInFlight {
    pub conv_id: String,
    pub unmute: bool,
    pub start_time_sec: i64,
    pub duration_secs: i64,
    pub op_id: Option<u64>,
}

/// In-flight incoming notification batch awaiting missing profile lookups.
#[derive(Clone)]
pub(crate) struct IncomingBatchInFlight {
    pub messages: Vec<olaz_wire::ChatMessage>,
    pub cursor: usize,
    pub now_ms: i64,
    pub op_id: Option<u64>,
}

/// U16 domain state owned by `CoreState.notify`.
#[derive(Clone, Default)]
pub struct NotifyState {
    pub settings: NotificationSettingsSnapshot,
    /// Cached group invite previews by link URL so `join_group` on `178` without `data.groupId`
    /// always knows the previewed `group_id`.
    pub invite_preview_groups: HashMap<String, String>,
    // U7: Read-only board-pin reminder refs (`conv_id -> refs`) until U7 merges.
    pub pin_reminder_refs: HashMap<String, Vec<PinReminderRef>>,
    pub(crate) reminder_watch_cache: HashMap<String, ReminderSnapshotData>,
    pub(crate) reminder_waiters: HashMap<String, Vec<ReminderWatchWaiter>>,
    pub(crate) next_waiter_id: u64,
    pub(crate) next_mute_req_id: u64,
    pub(crate) mute_in_flight: HashMap<u64, MuteInFlight>,
    pub(crate) next_incoming_id: u64,
    pub(crate) incoming_in_flight: HashMap<u64, IncomingBatchInFlight>,
}

impl fmt::Debug for NotifyState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("NotifyState")
            .field("settings", &self.settings)
            .field("reminder_cache", &self.reminder_watch_cache.len())
            .field("reminder_waiters", &self.reminder_waiters.len())
            .finish()
    }
}

impl NotifyState {
    /// Resets transient session state on sign-out / account switch while preserving `shows_preview`.
    pub fn reset_on_logout(&mut self) {
        let shows_preview = self.settings.shows_preview;
        *self = Self::default();
        self.settings.shows_preview = shows_preview;
    }
}

fn is_valid_group_conv_id(gid: &str) -> bool {
    gid.len() > 1
        && gid.len() <= 25
        && gid.starts_with('g')
        && gid[1..].bytes().all(|b| b.is_ascii_digit())
}

fn clip_chars(s: &str, max_chars: usize) -> String {
    s.chars().take(max_chars).collect()
}

fn clamped_int64(val: f64) -> i64 {
    if !val.is_finite() {
        return 0;
    }
    val.clamp(-9e15, 9e15) as i64
}

/// Parses `fetchGroupLinkDetail` response into [`GroupInvitePreviewResult`].
#[must_use]
pub fn parse_group_invite_preview(
    resp: &Map<String, Value>,
    member_group_ids: &HashSet<&str>,
) -> GroupInvitePreviewResult {
    let Some(d) = resp.get("data").and_then(Value::as_object) else {
        return GroupInvitePreviewResult::default();
    };
    let gid = group_conv_id(&string(d.get("groupId")));
    if !is_valid_group_conv_id(&gid) {
        return GroupInvitePreviewResult::default();
    }
    if member_group_ids.contains(gid.as_str()) {
        return GroupInvitePreviewResult {
            state: "member".to_owned(),
            group_id: gid,
            name: String::new(),
            avatar: None,
            total_member: 0,
            desc: String::new(),
            community: false,
            creator_name: String::new(),
            members: Vec::new(),
            text: String::new(),
        };
    }
    let raw_avt = string(d.get("avt"));
    let avatar = web_link_sanitized(Some(raw_avt));
    let total_member = int64(d.get("totalMember"))
        .or_else(|| float64(d.get("totalMember")).map(clamped_int64))
        .unwrap_or(0);
    GroupInvitePreviewResult {
        state: "preview".to_owned(),
        group_id: gid,
        name: clip_chars(&string(d.get("name")), 200),
        avatar,
        total_member,
        desc: clip_chars(&string(d.get("desc")), 2000),
        community: bool_val(d.get("community")).unwrap_or(false),
        creator_name: clip_chars(&string(d.get("creatorName")), 200),
        members: Vec::new(),
        text: String::new(),
    }
}

/// Maps `joinGroupByLink` result / error to [`GroupJoinResultData`] (official Zalo PC + `lang-vi`,
/// user decision 16.2).
///
/// Returns `(result, should_refresh_contacts)`.
#[must_use]
pub fn map_join_group_outcome(
    api_res: Result<&Map<String, Value>, &ApiError>,
    fallback_group_id: Option<&str>,
) -> (GroupJoinResultData, bool) {
    match api_res {
        Ok(resp) => {
            let d = resp.get("data").and_then(Value::as_object);
            let resp_gid = d
                .map(|obj| group_conv_id(&string(obj.get("groupId"))))
                .unwrap_or_default();
            let gid = if is_valid_group_conv_id(&resp_gid) {
                resp_gid
            } else {
                fallback_group_id
                    .filter(|g| is_valid_group_conv_id(g))
                    .unwrap_or("")
                    .to_owned()
            };
            if is_valid_group_conv_id(&gid) {
                (
                    GroupJoinResultData {
                        state: "joined".to_owned(),
                        group_id: gid,
                        text: "Đã tham gia nhóm.".to_owned(),
                    },
                    true,
                )
            } else {
                (GroupJoinResultData::error("Vào nhóm không thành công."), true)
            }
        }
        Err(err) => {
            let Some(session_err) = err.session_error() else {
                // Network / transport failure with no `error_code` keeps `"Vào nhóm không thành công."`
                // as recorded in `invite`.
                return (
                    GroupJoinResultData::error("Vào nhóm không thành công."),
                    false,
                );
            };
            let code = session_err.code;
            match code {
                178 => {
                    let fallback = fallback_group_id
                        .filter(|g| is_valid_group_conv_id(g))
                        .unwrap_or("")
                        .to_owned();
                    (
                        GroupJoinResultData {
                            state: "already".to_owned(),
                            group_id: fallback,
                            text: "Đã là thành viên của nhóm".to_owned(),
                        },
                        false,
                    )
                }
                240 => (
                    GroupJoinResultData {
                        state: "pending".to_owned(),
                        group_id: String::new(),
                        text: "Yêu cầu của bạn đã được gửi đến trưởng/phó nhóm chờ xét duyệt"
                            .to_owned(),
                    },
                    false,
                ),
                227 => (
                    GroupJoinResultData::error("Link tham gia không tồn tại."),
                    false,
                ),
                228 => (
                    GroupJoinResultData::error("Link tham gia đã hết hạn."),
                    false,
                ),
                177 => (
                    GroupJoinResultData::error("Bạn đã vượt quá số nhóm cho phép."),
                    false,
                ),
                257 => (
                    GroupJoinResultData::error("Bạn không có quyền tham gia nhóm vào lúc này"),
                    false,
                ),
                259 => (
                    GroupJoinResultData::error(
                        "Bạn không có quyền thực hiện thay đổi trong nhóm vào lúc này",
                    ),
                    false,
                ),
                166 => (
                    GroupJoinResultData::error("Bạn đã bị trưởng nhóm chặn tham gia nhóm này."),
                    false,
                ),
                280 | 282 => (
                    GroupJoinResultData::error(
                        "Nhóm đang bật Tin nhắn tự xóa. Cập nhật Zalo bản mới để tham gia nhóm.",
                    ),
                    false,
                ),
                281 => (
                    GroupJoinResultData::error(
                        "Không thể tham gia nhóm do bạn đã đạt giới hạn trò chuyện có Tin nhắn tự xóa.",
                    ),
                    false,
                ),
                283 => (
                    GroupJoinResultData::error(
                        "Không thể tham gia nhóm. Liên hệ trưởng hoặc phó nhóm để tham gia.",
                    ),
                    false,
                ),
                284 => (
                    GroupJoinResultData::error(
                        "Nhóm đang bật Tin nhắn tự xóa. Cập nhật bản mới Zalo PC và Zalo trên điện thoại để tham gia nhóm.",
                    ),
                    false,
                ),
                285 => (
                    GroupJoinResultData::error(
                        "Nhóm đang bật Tin nhắn tự xóa. Cập nhật Zalo PC bản mới để tham gia nhóm.",
                    ),
                    false,
                ),
                286 => (
                    GroupJoinResultData::error(
                        "Nhóm đang bật Tin nhắn tự xóa. Cập nhật Zalo bản mới trên điện thoại để tham gia nhóm.",
                    ),
                    false,
                ),
                833 => (
                    GroupJoinResultData::error(
                        "Không thể tham gia nhóm. Bạn đã đạt giới hạn trò chuyện có Chặn chia sẻ.",
                    ),
                    false,
                ),
                other => {
                    let msg = session_err.message.trim();
                    let text = if !msg.is_empty() {
                        // Note: official `r = t.translate(code) ?? n.error_message; ...`? Wait:
                        // Check user-decisions item 16.2: "Mã khác thì kèm số mã."!
                        let _ = msg;
                        format!("Vào nhóm không thành công. ({other})")
                    } else {
                        format!("Vào nhóm không thành công. ({other})")
                    };
                    (GroupJoinResultData::error(text), false)
                }
            }
        }
    }
}

/// Normalizes a reminder detail response into [`ReminderSnapshotData`] (mirrors
/// `ZaloEngine.normalizeReminderSnapshot`).
#[must_use]
pub fn normalize_reminder_snapshot(
    response_dict: &Map<String, Value>,
    conv_id: &str,
    reminder_id: &str,
    fallback_card: Option<&ECard>,
    my_uid: &str,
    lookup_name: &dyn Fn(&str) -> Option<String>,
) -> Option<ReminderSnapshotData> {
    let data = response_dict
        .get("data")
        .and_then(Value::as_object)
        .unwrap_or(response_dict);
    if data.is_empty() && fallback_card.is_none() {
        return None;
    }

    let params: Map<String, Value> = match data.get("params") {
        Some(Value::Object(m)) => m.clone(),
        Some(Value::String(s)) => parse_object(s.as_bytes()).unwrap_or_default(),
        _ => Map::new(),
    };

    fn first_non_empty<'a>(candidates: &[Option<&'a str>]) -> String {
        for c in candidates.iter().flatten() {
            if !c.trim().is_empty() {
                return (*c).to_owned();
            }
        }
        String::new()
    }

    let raw_rid = string(
        data.get("rid")
            .or_else(|| data.get("eventId"))
            .or_else(|| data.get("reminderId"))
            .or_else(|| data.get("id"))
            .or_else(|| data.get("topicId")),
    );
    let rid = first_non_empty(&[Some(raw_rid.as_str()), Some(reminder_id)]);

    let d_title = string(data.get("title").or_else(|| data.get("topicTitle")));
    let p_title = string(params.get("title").or_else(|| params.get("topicTitle")));
    let title = first_non_empty(&[
        Some(d_title.as_str()),
        Some(p_title.as_str()),
        fallback_card.map(|c| c.reminder_title.as_str()),
        fallback_card.map(|c| c.title.as_str()),
    ]);

    let raw_start = int64(
        data.get("startTime")
            .or_else(|| data.get("start"))
            .or_else(|| params.get("startTime")),
    )
    .unwrap_or(0);
    let start_ms_raw = if raw_start > 0 {
        if raw_start < 10_000_000_000 {
            raw_start.saturating_mul(1000)
        } else {
            raw_start
        }
    } else {
        fallback_card.and_then(|c| c.reminder_start_ms).unwrap_or(0)
    };

    let explicit_repeat = first_non_empty(&[
        data.get("repeatLabel").and_then(Value::as_str),
        data.get("repeat").and_then(Value::as_str),
        params.get("repeatLabel").and_then(Value::as_str),
    ]);
    let repeat_label = if !explicit_repeat.is_empty() {
        explicit_repeat
    } else if let Some(mode) = int64(
        data.get("repeat")
            .or_else(|| data.get("repeatMode"))
            .or_else(|| params.get("repeat")),
    ) {
        match mode {
            1 => "Hàng ngày".to_owned(),
            2 => "Hàng tuần".to_owned(),
            3 => "Hàng tháng".to_owned(),
            _ => fallback_card
                .map(|c| c.reminder_repeat.clone())
                .unwrap_or_default(),
        }
    } else {
        fallback_card
            .map(|c| c.reminder_repeat.clone())
            .unwrap_or_default()
    };

    let creator_uid = strip_user_prefix(&string(
        data.get("creatorId")
            .or_else(|| data.get("creator"))
            .or_else(|| data.get("uid")),
    ));
    let explicit_creator = string(data.get("creatorName"));
    let looked_up_creator = if !creator_uid.is_empty() {
        lookup_name(&creator_uid)
    } else {
        None
    };
    let creator_name = first_non_empty(&[
        Some(explicit_creator.as_str()),
        looked_up_creator.as_deref(),
    ]);

    let is_group = bool_val(data.get("isGroup")).unwrap_or_else(|| is_group_id(conv_id));
    let only_me = bool_val(data.get("onlyMe").or_else(|| data.get("isOnlyMe"))).unwrap_or(false);
    let deleted = bool_val(data.get("deleted").or_else(|| data.get("isDeleted"))) == Some(true)
        || int64(data.get("delStatus")) == Some(1)
        || int64(data.get("status")) == Some(-1);

    fn extract_uid_list(raw: Option<&Value>) -> Vec<String> {
        let Some(arr) = raw.and_then(Value::as_array) else {
            return Vec::new();
        };
        arr.iter()
            .filter_map(|item| {
                let raw_id = if let Some(obj) = item.as_object() {
                    string(
                        obj.get("uid")
                            .or_else(|| obj.get("userId"))
                            .or_else(|| obj.get("id")),
                    )
                } else {
                    string(Some(item))
                };
                let clean = strip_user_prefix(&raw_id);
                (!clean.is_empty()).then_some(clean)
            })
            .collect()
    }

    let accept_uids = extract_uid_list(data.get("acceptUids").or_else(|| data.get("accept")));
    let reject_uids = extract_uid_list(data.get("rejectUids").or_else(|| data.get("reject")));

    let accepted_count = int64(
        data.get("accepted")
            .or_else(|| data.get("acceptedCount"))
            .or_else(|| data.get("acceptCount"))
            .or_else(|| data.get("numAccept"))
            .or_else(|| data.get("totalAccept"))
            .or_else(|| data.get("totalJoin")),
    )
    .unwrap_or(accept_uids.len() as i64)
    .max(0);

    let rejected_count = int64(
        data.get("rejected")
            .or_else(|| data.get("rejectedCount"))
            .or_else(|| data.get("rejectCount"))
            .or_else(|| data.get("numReject"))
            .or_else(|| data.get("totalReject"))
            .or_else(|| data.get("totalDecline")),
    )
    .unwrap_or(reject_uids.len() as i64)
    .max(0);

    let clean_my_uid = strip_user_prefix(my_uid);
    let mine = if let Some(explicit) = data.get("mine").and_then(Value::as_str)
        && (explicit == "accept" || explicit == "reject")
    {
        explicit.to_owned()
    } else if let Some(res) = int64(
        data.get("myRes")
            .or_else(|| data.get("myResponse"))
            .or_else(|| data.get("userResponse"))
            .or_else(|| data.get("responseType")),
    ) && (res == 1 || res == 2)
    {
        if res == 1 {
            "accept".to_owned()
        } else {
            "reject".to_owned()
        }
    } else if !clean_my_uid.is_empty() {
        if accept_uids.iter().any(|u| u == &clean_my_uid) {
            "accept".to_owned()
        } else if reject_uids.iter().any(|u| u == &clean_my_uid) {
            "reject".to_owned()
        } else {
            String::new()
        }
    } else {
        String::new()
    };

    let can_rsvp =
        bool_val(data.get("canRsvp")).unwrap_or(is_group && !only_me && !deleted);
    let can_view = bool_val(data.get("canView")).unwrap_or(!deleted);
    let raw_variant = first_non_empty(&[data.get("variant").and_then(Value::as_str), Some("invite")]);
    let normalized_variant = match raw_variant.as_str() {
        "hidden" | "pending" | "invite" | "alert" | "demotedCreate" | "demotedAlert" => raw_variant.clone(),
        _ => "hidden".to_owned(),
    };
    let explicit_sig = string(data.get("sig"));
    let sig = if explicit_sig.is_empty() {
        format!(
            "{rid}|{title}|{start_ms_raw}|{repeat_label}|{mine}|{accepted_count}|{rejected_count}|{deleted}|{raw_variant}"
        )
    } else {
        explicit_sig
    };

    let start_ms = (start_ms_raw > 0 && start_ms_raw < 4_102_444_800_000).then_some(start_ms_raw);

    Some(ReminderSnapshotData {
        variant: normalized_variant,
        id: rid,
        title,
        start_ms,
        repeat_label,
        creator_name,
        only_me,
        is_group,
        mine,
        accepted_count,
        rejected_count,
        can_rsvp,
        can_view,
        deleted,
        sig,
    })
}

/// Raw responder entry extracted from `listResponseEvent`.
#[derive(Debug, Clone)]
pub struct RawResponderEntry {
    pub uid: String,
    pub name: String,
    pub avatar: String,
}

/// Extracted buckets from `listResponseEvent`.
#[derive(Debug, Clone)]
pub struct RawResponderBuckets {
    pub accept: Vec<RawResponderEntry>,
    pub reject: Vec<RawResponderEntry>,
    pub accept_total: i64,
    pub reject_total: i64,
    pub accept_more: i64,
    pub reject_more: i64,
}

/// Extracts raw responder buckets from `listResponseEvent` JSON.
#[must_use]
pub fn extract_responder_buckets(response_dict: &Map<String, Value>) -> Option<RawResponderBuckets> {
    let data: &Map<String, Value> = if let Some(d) = response_dict.get("data").and_then(Value::as_object)
    {
        d
    } else if response_dict.get("data").and_then(Value::as_array).is_some() || !response_dict.is_empty() {
        response_dict
    } else {
        return None;
    };

    fn parse_entry(raw: &Value) -> Option<(RawResponderEntry, Option<i64>)> {
        if let Some(dict) = raw.as_object() {
            let uid = strip_user_prefix(&string(
                dict.get("uid")
                    .or_else(|| dict.get("userId"))
                    .or_else(|| dict.get("user_id"))
                    .or_else(|| dict.get("id")),
            ));
            if uid.is_empty() || uid == "0" {
                return None;
            }
            let name = crate::conversations::preferred_profile_name(dict);
            let avatar = string(dict.get("avatar").or_else(|| dict.get("avt")));
            let r_type = int64(
                dict.get("type")
                    .or_else(|| dict.get("responseType"))
                    .or_else(|| dict.get("status")),
            );
            return Some((RawResponderEntry { uid, name, avatar }, r_type));
        }
        let uid = strip_user_prefix(&string(Some(raw)));
        if uid.is_empty() || uid == "0" {
            return None;
        }
        Some((
            RawResponderEntry {
                uid,
                name: String::new(),
                avatar: String::new(),
            },
            None,
        ))
    }

    let mut accept_raw = Vec::new();
    let mut reject_raw = Vec::new();

    if let Some(arr) = data
        .get("accept")
        .or_else(|| data.get("accepts"))
        .or_else(|| data.get("acceptUids"))
        .or_else(|| data.get("join"))
        .and_then(Value::as_array)
    {
        for item in arr {
            if let Some((e, _)) = parse_entry(item) {
                accept_raw.push(e);
            }
        }
    }
    if let Some(arr) = data
        .get("reject")
        .or_else(|| data.get("rejects"))
        .or_else(|| data.get("rejectUids"))
        .or_else(|| data.get("decline"))
        .and_then(Value::as_array)
    {
        for item in arr {
            if let Some((e, _)) = parse_entry(item) {
                reject_raw.push(e);
            }
        }
    }
    if accept_raw.is_empty()
        && reject_raw.is_empty()
        && let Some(combined) = data
            .get("responses")
            .or_else(|| data.get("items"))
            .or_else(|| data.get("list"))
            .or_else(|| response_dict.get("data"))
            .and_then(Value::as_array)
    {
        for item in combined {
            if let Some((e, r_type)) = parse_entry(item) {
                if r_type == Some(2) {
                    reject_raw.push(e);
                } else {
                    accept_raw.push(e);
                }
            }
        }
    }

    let accept_total = int64(
        data.get("acceptTotal")
            .or_else(|| data.get("totalAccept"))
            .or_else(|| data.get("numAccept")),
    )
    .unwrap_or(accept_raw.len() as i64)
    .max(accept_raw.len() as i64);

    let reject_total = int64(
        data.get("rejectTotal")
            .or_else(|| data.get("totalReject"))
            .or_else(|| data.get("numReject")),
    )
    .unwrap_or(reject_raw.len() as i64)
    .max(reject_raw.len() as i64);

    let accept_more = int64(data.get("acceptMore")).unwrap_or(0).max(0);
    let reject_more = int64(data.get("rejectMore")).unwrap_or(0).max(0);

    Some(RawResponderBuckets {
        accept: accept_raw,
        reject: reject_raw,
        accept_total,
        reject_total,
        accept_more,
        reject_more,
    })
}

/// Builds enriched [`ReminderRespondersData`] from extracted buckets and identity lookup.
#[must_use]
pub fn build_reminder_responders(
    buckets: &RawResponderBuckets,
    my_uid: &str,
    lookup_person: &dyn Fn(&str) -> Option<(String, String)>,
) -> ReminderRespondersData {
    let clean_my_uid = strip_user_prefix(my_uid);

    let enrich = |entries: &[RawResponderEntry]| -> Vec<ReminderResponderPerson> {
        let mut seen = HashSet::new();
        let mut out = Vec::with_capacity(entries.len());
        for entry in entries {
            if entry.uid.is_empty() || !seen.insert(entry.uid.clone()) {
                continue;
            }
            let is_me = !clean_my_uid.is_empty() && entry.uid == clean_my_uid;
            let local = lookup_person(&entry.uid);
            let resolved_name = match local.as_ref().map(|(n, _)| n.as_str()) {
                Some(n) if !n.is_empty() => n.to_owned(),
                _ if !entry.name.is_empty() => entry.name.clone(),
                _ => {
                    if is_me {
                        "Bạn".to_owned()
                    } else {
                        UNKNOWN_NAME.to_owned()
                    }
                }
            };
            let resolved_avatar = match local.as_ref().map(|(_, a)| a.as_str()) {
                Some(a) if !a.is_empty() => a.to_owned(),
                _ => entry.avatar.clone(),
            };
            out.push(ReminderResponderPerson {
                uid: entry.uid.clone(),
                name: resolved_name,
                avatar: (!resolved_avatar.is_empty()).then_some(resolved_avatar),
                is_me,
            });
        }
        out
    };

    let accept = enrich(&buckets.accept);
    let reject = enrich(&buckets.reject);
    let accept_total = buckets.accept_total.max(accept.len() as i64);
    let reject_total = buckets.reject_total.max(reject.len() as i64);

    ReminderRespondersData {
        accept,
        reject,
        accept_total,
        reject_total,
        accept_more: buckets.accept_more.max(0),
        reject_more: buckets.reject_more.max(0),
    }
}

/// Converts raw sticker suggestion rows into top-8 valid [`SuggestedStickerItem`] items.
#[must_use]
pub fn map_suggested_stickers(rows: &[Map<String, Value>]) -> Vec<SuggestedStickerItem> {
    let mut out = Vec::new();
    for row in rows.iter().take(8) {
        let sid = int64(
            row.get("id")
                .or_else(|| row.get("stickerId"))
                .or_else(|| row.get("sticker_id")),
        )
        .unwrap_or(0);
        let cate = int64(row.get("cateId").or_else(|| row.get("cate_id"))).unwrap_or(0) as i32;
        if sid <= 0 {
            continue;
        }
        let url_str = sticker_cdn_url(i64::from(cate), &sid.to_string());
        if let Some(sanitized) = web_link_sanitized(Some(url_str)) {
            out.push(SuggestedStickerItem {
                sticker_ref: format!("{cate}_{sid}"),
                url: sanitized,
            });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use olaz_net::{NetError, ZaloSessionError};

    use super::*;

    #[test]
    fn join_group_error_codes_match_official_lang_vi() {
        let err_for = |code: i64| -> ApiError {
            ApiError::Net(NetError::Session(ZaloSessionError {
                code,
                message: "server msg".to_owned(),
                url: "/api/group/link/join".to_owned(),
            }))
        };

        let (r178, ref178) = map_join_group_outcome(Err(&err_for(178)), Some("g1660"));
        assert!(!ref178);
        assert_eq!(r178.state, "already");
        assert_eq!(r178.group_id, "g1660");
        assert_eq!(r178.text, "Đã là thành viên của nhóm");

        let (r240, _) = map_join_group_outcome(Err(&err_for(240)), Some("g1660"));
        assert_eq!(r240.state, "pending");
        assert_eq!(
            r240.text,
            "Yêu cầu của bạn đã được gửi đến trưởng/phó nhóm chờ xét duyệt"
        );

        let cases = [
            (227, "Link tham gia không tồn tại."),
            (228, "Link tham gia đã hết hạn."),
            (177, "Bạn đã vượt quá số nhóm cho phép."),
            (257, "Bạn không có quyền tham gia nhóm vào lúc này"),
            (259, "Bạn không có quyền thực hiện thay đổi trong nhóm vào lúc này"),
            (166, "Bạn đã bị trưởng nhóm chặn tham gia nhóm này."),
            (
                280,
                "Nhóm đang bật Tin nhắn tự xóa. Cập nhật Zalo bản mới để tham gia nhóm.",
            ),
            (
                281,
                "Không thể tham gia nhóm do bạn đã đạt giới hạn trò chuyện có Tin nhắn tự xóa.",
            ),
            (
                283,
                "Không thể tham gia nhóm. Liên hệ trưởng hoặc phó nhóm để tham gia.",
            ),
            (
                284,
                "Nhóm đang bật Tin nhắn tự xóa. Cập nhật bản mới Zalo PC và Zalo trên điện thoại để tham gia nhóm.",
            ),
            (
                285,
                "Nhóm đang bật Tin nhắn tự xóa. Cập nhật Zalo PC bản mới để tham gia nhóm.",
            ),
            (
                286,
                "Nhóm đang bật Tin nhắn tự xóa. Cập nhật Zalo bản mới trên điện thoại để tham gia nhóm.",
            ),
            (
                833,
                "Không thể tham gia nhóm. Bạn đã đạt giới hạn trò chuyện có Chặn chia sẻ.",
            ),
            (999, "Vào nhóm không thành công. (999)"),
        ];
        for (code, expected) in cases {
            let (res, refresh) = map_join_group_outcome(Err(&err_for(code)), None);
            assert!(!refresh);
            assert_eq!(res.state, "error");
            assert_eq!(res.text, expected, "code {code}");
        }
    }

    #[test]
    fn policy_helpers_match_swift() {
        assert!(policy::should_suppress(true, true, Some("5"), "5", 4.0, 180.0));
        assert!(policy::should_suppress(true, true, Some("5"), "5", 179.0, 180.0));
        assert!(!policy::should_suppress(true, true, Some("5"), "5", 180.0, 180.0));
        assert!(!policy::should_suppress(false, true, Some("5"), "5", 4.0, 180.0));
        assert_eq!(
            policy::newly_hidden(&["1".into(), "2".into()], &["2".into(), "4".into(), "3".into()]),
            vec!["3".to_owned(), "4".to_owned()]
        );
        assert_eq!(policy::body("Hi", false), HIDDEN_PREVIEW_BODY);
    }
}

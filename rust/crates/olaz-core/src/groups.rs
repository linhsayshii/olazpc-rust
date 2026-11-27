//! Groups domain state, pure models, and shared group metadata helpers (U10 + U12).
//!
//! Owns `details_json` (`cachedGroupDetails`), `member_cache` (`groupMemberCache`),
//! `cached_groups` (`cachedGroups`), and `navigation_request` (`navigationRequest`) alongside U9's
//! [`ContactsState`].
//!
//! Incorporates the three approved fixes from `user-decisions` item 7:
//! 1. Created groups persist immediately (SQLite conversation + `cachedGroups` pref) even when
//!    `/api/group/getmg-v2` returns an empty `gridInfoMap`.
//! 2. Invite "Chưa thêm được …" notice preserves deterministic invite/response order (deduplicated)
//!    instead of unordered `Set` iteration.
//! 3. Mention candidates preserve member-list order (deduplicated) and exclude self by normalized
//!    UID (`normalize_contact_uid`).

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use olaz_api::{JsonObject, clean_group_member_ids};
use olaz_store::StoredConversation;
use olaz_wire::{
    clean_group_id, group_conv_id, lossless, normalize_contact_uid, sanitize_profile_uid,
    strip_user_prefix,
};
use serde_json::{Map, Value, json};

use crate::conversations::{
    CachedGroup, ConversationSummary, ConversationsState, sort_conversations,
};
use crate::messages::{
    ContactsState, GroupEntry, fold_contact_str, is_valid_url_str, localized_standard_cmp,
    serialize_cached_groups_json,
};

/// Default failure message when group creation fails (`STR_CREATE_GROUP_FAIL`).
pub const GROUP_CREATE_DEFAULT_FAILURE: &str = "Tạo nhóm không thành công.";

/// Official toast when an admin API fails with error code 166 (not owner/deputy).
pub const GROUP_ADMIN_CODE_166_TEXT: &str = "Chỉ có trưởng/phó nhóm thực hiện được tính năng này.";

/// Fallback display name for unknown group members (`ZaloEngine.contactName` / `loadGroupMembers`).
pub const UNKNOWN_GROUP_MEMBER_NAME: &str = "Người dùng Zalo";

/// Mentionable group member entry (`ChatModels.swift: MentionCandidate`).
#[derive(Clone, PartialEq, Eq)]
pub struct MentionCandidate {
    pub id: String,
    pub name: String,
    pub avatar: Option<String>,
    pub is_all: bool,
}

impl MentionCandidate {
    /// The synthetic `@All` mention candidate prepended to cached group member lists.
    #[must_use]
    pub fn all() -> Self {
        Self {
            id: "-1".to_owned(),
            name: "All".to_owned(),
            avatar: None,
            is_all: true,
        }
    }
}

impl fmt::Debug for MentionCandidate {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MentionCandidate")
            .field("is_all", &self.is_all)
            .field("has_avatar", &self.avatar.is_some())
            .finish()
    }
}

/// Group roles derived from a cached group detail (`ZaloEngine+GroupAdmin.swift: GroupRoles`).
#[derive(Clone, Default, PartialEq, Eq)]
pub struct GroupRoles {
    pub owner: String,
    pub admins: BTreeSet<String>,
    /// Official `setting.joinAppr == 1`: new members wait for approval.
    pub join_approval: bool,
}

impl fmt::Debug for GroupRoles {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupRoles")
            .field("has_owner", &!self.owner.is_empty())
            .field("admins", &self.admins.len())
            .field("join_approval", &self.join_approval)
            .finish()
    }
}

impl GroupRoles {
    #[must_use]
    pub fn is_owner(&self, uid: &str) -> bool {
        !uid.is_empty() && uid == self.owner
    }

    #[must_use]
    pub fn is_admin(&self, uid: &str) -> bool {
        self.admins.contains(uid)
    }

    #[must_use]
    pub fn can_manage(&self, uid: &str) -> bool {
        self.is_owner(uid) || self.is_admin(uid)
    }

    /// Port of `GroupRoles.from(_ info: [String: Any])`.
    #[must_use]
    pub fn from_info(info: &Map<String, Value>) -> Self {
        let mut roles = Self {
            owner: strip_user_prefix(&lossless::string(
                info.get("creatorId")
                    .or_else(|| info.get("creator_id"))
                    .or_else(|| info.get("ownerId")),
            )),
            admins: BTreeSet::new(),
            join_approval: false,
        };
        for key in ["adminIds", "admin_ids", "admins"] {
            if let Some(Value::Array(arr)) = info.get(key) {
                for raw in arr {
                    let uid = strip_user_prefix(&lossless::string(Some(raw)));
                    if !uid.is_empty() && uid != "0" && uid != roles.owner {
                        roles.admins.insert(uid);
                    }
                }
            }
        }
        if let Some(setting) = info.get("setting").and_then(Value::as_object) {
            roles.join_approval = lossless::int64(setting.get("joinAppr")) == Some(1);
        }
        roles
    }
}

/// Prepared JPEG group avatar bytes passed into `Command::CreateGroup`.
#[derive(Clone, PartialEq, Eq)]
pub struct GroupAvatarUpload {
    pub jpeg: Vec<u8>,
    pub side: u32,
}

impl fmt::Debug for GroupAvatarUpload {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupAvatarUpload")
            .field("bytes", &self.jpeg.len())
            .field("side", &self.side)
            .finish()
    }
}

/// Outcome of `Command::CreateGroup` (`ZaloEngine+GroupCreate.swift: GroupCreateOutcome`).
#[derive(Clone, PartialEq, Eq)]
pub enum GroupCreateOutcome {
    Created {
        id: String,
        failed: Vec<String>,
    },
    Exists {
        id: String,
        text: String,
    },
    Invalid {
        text: String,
        dropped: Vec<String>,
    },
    Failed {
        title: Option<String>,
        message: String,
        closes: bool,
    },
    Pending {
        text: String,
    },
}

impl fmt::Debug for GroupCreateOutcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Created { failed, .. } => f
                .debug_struct("Created")
                .field("failed", &failed.len())
                .finish(),
            Self::Exists { .. } => f.write_str("Exists"),
            Self::Invalid { dropped, .. } => f
                .debug_struct("Invalid")
                .field("dropped", &dropped.len())
                .finish(),
            Self::Failed { closes, .. } => {
                f.debug_struct("Failed").field("closes", closes).finish()
            }
            Self::Pending { .. } => f.write_str("Pending"),
        }
    }
}

/// Admin mutation dispatched through `Effect::GroupAdminApi`.
#[derive(Clone, PartialEq, Eq)]
pub enum GroupAdminAction {
    SetAdmin { uid: String, admin: bool },
    ChangeOwner { uid: String },
    BlockMember { uid: String },
    ReviewPending { uids: Vec<String>, approve: bool },
    SetJoinApproval { settings: JsonObject },
}

impl GroupAdminAction {
    #[must_use]
    pub const fn ok_text(&self) -> &'static str {
        match self {
            Self::SetAdmin { admin: true, .. } => "Đã thêm phó nhóm",
            Self::SetAdmin { admin: false, .. } => "Đã xóa quyền phó nhóm",
            Self::ChangeOwner { .. } => "Đã chuyển quyền trưởng nhóm",
            Self::BlockMember { .. } => "Đã chặn khỏi nhóm",
            Self::ReviewPending { .. } | Self::SetJoinApproval { .. } => "",
        }
    }

    #[must_use]
    pub const fn fail_text(&self) -> &'static str {
        match self {
            Self::SetAdmin { admin: true, .. } => "Thêm quyền phó nhóm không thành công",
            Self::SetAdmin { admin: false, .. } => "Xóa quyền phó nhóm không thành công",
            Self::ChangeOwner { .. } => "Có lỗi xảy ra không thể thay đổi trưởng nhóm!",
            Self::BlockMember { .. } => "Chặn thành viên không thành công",
            Self::ReviewPending { .. } => "Không thể thực hiện, vui lòng thử lại",
            Self::SetJoinApproval { .. } => "Không thể thay đổi cài đặt nhóm",
        }
    }
}

impl fmt::Debug for GroupAdminAction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::SetAdmin { admin, .. } => {
                f.debug_struct("SetAdmin").field("admin", admin).finish()
            }
            Self::ChangeOwner { .. } => f.write_str("ChangeOwner"),
            Self::BlockMember { .. } => f.write_str("BlockMember"),
            Self::ReviewPending { uids, approve } => f
                .debug_struct("ReviewPending")
                .field("uids", &uids.len())
                .field("approve", approve)
                .finish(),
            Self::SetJoinApproval { settings } => f
                .debug_struct("SetJoinApproval")
                .field("keys", &settings.len())
                .finish(),
        }
    }
}

/// Continuation carried across `Effect::FetchGroupDetailApi` -> `Input::GroupDetailFetched`.
#[derive(Clone, PartialEq, Eq)]
pub enum GroupDetailPurpose {
    Refresh {
        op_id: Option<u64>,
        now_ms: i64,
    },
    CreateFollowup {
        op_id: Option<u64>,
        failed: Vec<String>,
        avatar_upload_failed: bool,
        now_ms: i64,
    },
    InviteFollowup {
        op_id: Option<u64>,
        rejected_ordered: Vec<String>,
        now_ms: i64,
    },
    KickFollowup {
        op_id: Option<u64>,
        now_ms: i64,
    },
    AdminFollowup {
        op_id: Option<u64>,
        ok_text: String,
        now_ms: i64,
    },
    LoadMembers {
        op_id: Option<u64>,
        now_ms: i64,
    },
}

impl fmt::Debug for GroupDetailPurpose {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Refresh { op_id, .. } => f.debug_struct("Refresh").field("op_id", op_id).finish(),
            Self::CreateFollowup {
                op_id,
                failed,
                avatar_upload_failed,
                ..
            } => f
                .debug_struct("CreateFollowup")
                .field("op_id", op_id)
                .field("failed", &failed.len())
                .field("avatar_upload_failed", avatar_upload_failed)
                .finish(),
            Self::InviteFollowup {
                op_id,
                rejected_ordered,
                ..
            } => f
                .debug_struct("InviteFollowup")
                .field("op_id", op_id)
                .field("rejected", &rejected_ordered.len())
                .finish(),
            Self::KickFollowup { op_id, .. } => f
                .debug_struct("KickFollowup")
                .field("op_id", op_id)
                .finish(),
            Self::AdminFollowup { op_id, .. } => f
                .debug_struct("AdminFollowup")
                .field("op_id", op_id)
                .finish(),
            Self::LoadMembers { op_id, .. } => {
                f.debug_struct("LoadMembers").field("op_id", op_id).finish()
            }
        }
    }
}

/// Continuation carried across `Effect::FetchGroupMemberProfilesApi`.
#[derive(Clone, PartialEq, Eq)]
pub enum MemberProfilesPurpose {
    Mention {
        query: String,
        excluding: Vec<String>,
    },
    LoadMembers,
}

impl fmt::Debug for MemberProfilesPurpose {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Mention { excluding, .. } => f
                .debug_struct("Mention")
                .field("excluding", &excluding.len())
                .finish(),
            Self::LoadMembers => f.write_str("LoadMembers"),
        }
    }
}

/// Groups domain state owned by [`crate::state::CoreState`] next to [`ContactsState`].
#[derive(Clone, Default, PartialEq, Eq)]
pub struct GroupsState {
    /// Clean group id -> serialized JSON object string (`cachedGroupDetails`).
    pub details_json: BTreeMap<String, String>,
    /// Group conversation id (`g<grid>`) -> cached mention candidates (`groupMemberCache`).
    pub member_cache: BTreeMap<String, Vec<MentionCandidate>>,
    /// Group conversation id (`g<grid>`) -> cached name/avatar/members (`cachedGroups`).
    pub cached_groups: BTreeMap<String, CachedGroup>,
    /// Last created group conversation id requested for UI navigation (`navigationRequest`).
    pub navigation_request: Option<String>,
}

impl fmt::Debug for GroupsState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupsState")
            .field("details_json", &self.details_json.len())
            .field("member_cache", &self.member_cache.len())
            .field("cached_groups", &self.cached_groups.len())
            .field("has_nav_request", &self.navigation_request.is_some())
            .finish()
    }
}

impl GroupsState {
    /// Applies a seeded [`GroupsState`] (from `Command::SeedGroups`), preserving existing
    /// `member_cache` and `cached_groups` when the seed leaves them empty.
    pub fn apply_seeded_groups(&mut self, seed: Self) {
        self.details_json = seed.details_json;
        if !seed.member_cache.is_empty() {
            self.member_cache = seed.member_cache;
        }
        if !seed.cached_groups.is_empty() {
            self.cached_groups = seed.cached_groups;
        }
    }

    /// Parses the cached detail JSON object for `group_id` (clean grid or `g`-prefixed).
    #[must_use]
    pub fn detail_object(&self, group_id: &str) -> Option<Map<String, Value>> {
        let clean_grid = clean_group_id(group_id);
        let conv_id = group_conv_id(group_id);
        let raw_json = (!clean_grid.is_empty())
            .then(|| self.details_json.get(&clean_grid))
            .flatten()
            .or_else(|| {
                (!conv_id.is_empty())
                    .then(|| self.details_json.get(&conv_id))
                    .flatten()
            })?;
        serde_json::from_str::<Map<String, Value>>(raw_json).ok()
    }

    /// Computes [`GroupRoles`] for `group_id` from `details_json` (`ZaloEngine.groupRoles`).
    #[must_use]
    pub fn roles(&self, group_id: &str) -> GroupRoles {
        self.detail_object(group_id)
            .map(|info| GroupRoles::from_info(&info))
            .unwrap_or_default()
    }
}

/// Formats the "Chưa thêm được A, B và 3 người khác vào nhóm." notice (`ZaloEngine.notAddedText`).
#[must_use]
pub fn not_added_text(names: &[String]) -> String {
    let shown = names
        .iter()
        .take(3)
        .map(String::as_str)
        .collect::<Vec<_>>()
        .join(", ");
    let rest = names.len().saturating_sub(3);
    if rest > 0 {
        format!("Chưa thêm được {shown} và {rest} người khác vào nhóm.")
    } else {
        format!("Chưa thêm được {shown} vào nhóm.")
    }
}

/// Maps a group admin API error code to the official action-card text.
#[must_use]
pub fn admin_error_text(code: Option<i64>, default_fail: &str) -> String {
    if code == Some(166) {
        GROUP_ADMIN_CODE_166_TEXT.to_owned()
    } else {
        default_fail.to_owned()
    }
}

/// Port of `ZaloWireParser.preferredName(_:)`.
#[must_use]
pub fn preferred_profile_name(row: &Map<String, Value>) -> String {
    for key in [
        "zaloName",
        "zalo_name",
        "displayName",
        "display_name",
        "dName",
        "name",
    ] {
        let value = lossless::string(row.get(key));
        let trimmed = value.trim();
        if !trimmed.is_empty() {
            return trimmed.to_owned();
        }
    }
    String::new()
}

/// Port of `ZaloEngine.contactName(_:)` (friends lookup with `Người dùng Zalo` fallback).
#[must_use]
pub fn contact_name_for_group_notice(uid: &str, contacts: &ContactsState) -> String {
    contacts
        .friends
        .iter()
        .find(|f| f.id == uid)
        .map(|f| f.name.clone())
        .unwrap_or_else(|| UNKNOWN_GROUP_MEMBER_NAME.to_owned())
}

/// Extracts raw member IDs from a group detail dict using the priority order
/// `memVerList` -> `memIds` -> `currentMems` (used by `refreshGroupMetadata` and `mentionCandidates`).
#[must_use]
pub fn extract_raw_member_ids_from_detail(info: &Map<String, Value>) -> Vec<String> {
    let mut raw: Vec<String> = Vec::new();
    if let Some(Value::Array(ver_list)) = info.get("memVerList")
        && ver_list.iter().all(Value::is_string)
    {
        for v in ver_list {
            if let Some(s) = v.as_str()
                && let Some(first) = s.split('_').next()
            {
                raw.push(first.to_owned());
            }
        }
    }
    if raw.is_empty()
        && let Some(Value::Array(mems)) = info.get("memIds")
    {
        raw.extend(mems.iter().map(|v| lossless::string(Some(v))));
    }
    if raw.is_empty()
        && let Some(Value::Array(cur)) = info.get("currentMems")
        && cur.iter().all(Value::is_object)
    {
        for v in cur {
            if let Some(obj) = v.as_object() {
                raw.push(lossless::string(obj.get("id").or_else(|| obj.get("uid"))));
            }
        }
    }
    raw
}

/// Port of `ZaloEngine.groupMemberIds(in:)` — concatenates `memVerList`, `memIds`, `currentMems`
/// from `details_json[cleanGrid]` plus cached non-All entries from `member_cache[gid]`, then cleans.
#[must_use]
pub fn group_member_ids(group_id: &str, groups: &GroupsState) -> Vec<String> {
    let gid = group_conv_id(group_id);
    let mut raw: Vec<String> = Vec::new();
    if let Some(info) = groups.detail_object(group_id) {
        if let Some(Value::Array(ver_list)) = info.get("memVerList")
            && ver_list.iter().all(Value::is_string)
        {
            for v in ver_list {
                if let Some(s) = v.as_str()
                    && let Some(first) = s.split('_').next()
                {
                    raw.push(first.to_owned());
                }
            }
        }
        if let Some(Value::Array(mems)) = info.get("memIds") {
            raw.extend(mems.iter().map(|v| lossless::string(Some(v))));
        }
        if let Some(Value::Array(cur)) = info.get("currentMems")
            && cur.iter().all(Value::is_object)
        {
            for v in cur {
                if let Some(obj) = v.as_object() {
                    raw.push(lossless::string(obj.get("id").or_else(|| obj.get("uid"))));
                }
            }
        }
    }
    if let Some(cached) = groups.member_cache.get(&gid) {
        for c in cached {
            if !c.is_all && c.id != "-1" {
                raw.push(c.id.clone());
            }
        }
    }
    clean_group_member_ids(&raw)
}

/// Ordered, deduplicated member UIDs to fetch for `mentionCandidates` (excluding self).
///
/// Approved Fix (`user-decisions` item 7.3): preserves member-list order (deduplicated) instead of
/// `Set` iteration order, and excludes self by normalized UID (`normalize_contact_uid`).
#[must_use]
pub fn mention_member_fetch_ids(
    group_id: &str,
    my_raw_uid: &str,
    groups: &GroupsState,
) -> Vec<String> {
    let Some(info) = groups.detail_object(group_id) else {
        return Vec::new();
    };
    let my_norm =
        sanitize_profile_uid(my_raw_uid).unwrap_or_else(|| normalize_contact_uid(my_raw_uid));
    let raw = extract_raw_member_ids_from_detail(&info);
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    for item in raw {
        let uid = sanitize_profile_uid(&item).unwrap_or_else(|| normalize_contact_uid(&item));
        if uid.is_empty() {
            continue;
        }
        if !my_norm.is_empty() && uid == my_norm {
            continue;
        }
        if seen.insert(uid.clone()) {
            out.push(uid);
        }
    }
    out
}

/// Filters a cached list of [`MentionCandidate`] by query and excluded IDs.
#[must_use]
pub fn filter_mention_candidates(
    cached: &[MentionCandidate],
    query: &str,
    excluding: &[String],
) -> Vec<MentionCandidate> {
    let excluded: BTreeSet<&str> = excluding.iter().map(String::as_str).collect();
    let needle = fold_contact_str(query);
    let needle = needle.trim();
    cached
        .iter()
        .filter(|c| {
            if excluded.contains(c.id.as_str()) {
                return false;
            }
            if needle.is_empty() {
                return true;
            }
            fold_contact_str(&c.name).contains(needle)
        })
        .cloned()
        .collect()
}

/// Persistence artifacts produced by [`apply_group_metadata_update`] /
/// [`merge_fetched_group_metadata`] for SQLite writeback.
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

/// Inputs for [`apply_group_metadata_update`] (port of `ZaloEngine.applyGroupMetadataUpdate`).
#[derive(Debug, Default)]
pub struct GroupMetadataPatch<'a> {
    pub name: Option<&'a str>,
    pub avatar: Option<&'a str>,
    pub member_count: Option<i64>,
    pub member_ids: Option<&'a [String]>,
    pub base_detail: Option<&'a JsonObject>,
}

/// Applies a group metadata update across `groups`, `contacts.groups`, and `conversations` in one
/// pure reducer step, returning SQLite persistence artifacts (`cachedGroups` pref + single
/// conversation row).
pub fn apply_group_metadata_update(
    group_id: &str,
    patch: GroupMetadataPatch<'_>,
    groups: &mut GroupsState,
    contacts: &mut ContactsState,
    convs: &mut ConversationsState,
    self_conv_id: Option<&str>,
    now_ms: i64,
) -> Option<MergedGroupMetadataPersistence> {
    let gid = group_conv_id(group_id);
    let clean_grid = clean_group_id(group_id);
    if gid.is_empty() || clean_grid.is_empty() {
        return None;
    }

    let avt_url = patch
        .avatar
        .map(str::trim)
        .filter(|s| is_valid_url_str(s))
        .map(str::to_owned);

    let mut detail = if let Some(base) = patch.base_detail {
        base.clone()
    } else {
        groups
            .details_json
            .get(&clean_grid)
            .and_then(|s| serde_json::from_str::<Map<String, Value>>(s).ok())
            .unwrap_or_default()
    };

    if let Some(n) = patch.name
        && !n.is_empty()
    {
        detail.insert("name".to_owned(), Value::from(n));
    }
    if let Some(ref avt) = avt_url {
        detail.insert("avt".to_owned(), Value::from(avt.as_str()));
    }
    if let Some(mc) = patch.member_count
        && mc > 0
    {
        detail.insert("totalMember".to_owned(), Value::from(mc));
    }
    if let Some(raw_ids) = patch.member_ids {
        let clean_ids = clean_group_member_ids(raw_ids);
        detail.insert("memIds".to_owned(), json!(clean_ids));
        let ver_list: Vec<String> = clean_ids.iter().map(|id| format!("{id}_0")).collect();
        detail.insert("memVerList".to_owned(), json!(ver_list));
        if detail.contains_key("currentMems") {
            let cur_mems: Vec<Value> = clean_ids.iter().map(|id| json!({ "id": id })).collect();
            detail.insert("currentMems".to_owned(), Value::Array(cur_mems));
        }
    }
    if let Ok(serialized) = serde_json::to_string(&Value::Object(detail)) {
        groups.details_json.insert(clean_grid, serialized);
    }

    let opt_name = patch.name.filter(|s| !s.is_empty());
    let opt_members = patch.member_count.filter(|&c| c > 0);

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
    sort_conversations(&mut convs.conversations, &contacts.activity_ranks);

    let existing_cached = groups.cached_groups.get(&gid).cloned();
    groups.cached_groups.insert(
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
    convs.rebuild_conversation_extras(contacts, self_conv_id);

    let cached_groups_json = serialize_cached_groups_json(&groups.cached_groups);
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

/// Shared port of `ZaloEngine.refreshGroupMetadata` + `applyGroupMetadataUpdate` +
/// `persistSingleGroupConversation` for U12 (`refreshPoll`) and U10 (group management).
pub fn merge_fetched_group_metadata(
    group_id: &str,
    info: &JsonObject,
    groups: &mut GroupsState,
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
    let clean_member_ids = clean_group_member_ids(&extract_raw_member_ids_from_detail(info));
    let member_count = lossless::int64(info.get("totalMember").or_else(|| info.get("total")))
        .unwrap_or_else(|| i64::try_from(clean_member_ids.len()).unwrap_or(0));

    apply_group_metadata_update(
        &gid,
        GroupMetadataPatch {
            name: (!server_name.is_empty()).then_some(server_name.as_str()),
            avatar: (!avt_str.is_empty()).then_some(avt_str.as_str()),
            member_count: (member_count > 0).then_some(member_count),
            member_ids: (!clean_member_ids.is_empty()).then_some(clean_member_ids.as_slice()),
            base_detail: Some(info),
        },
        groups,
        contacts,
        convs,
        self_conv_id,
        now_ms,
    )
}

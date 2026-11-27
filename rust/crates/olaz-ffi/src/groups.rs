//! UniFFI records and pure helpers for U10 groups (`olaz-core::groups` + `olaz-wire::group_events`).

use std::collections::{BTreeMap, HashMap};
use std::fmt;

use olaz_api::{GroupLink, GroupPendingMember};
use olaz_core::{
    CachedGroup, GroupAvatarUpload, GroupCreateOutcome, GroupRoles, GroupsState, MentionCandidate,
    group_member_ids, not_added_text,
};
use olaz_wire::{clean_group_id, group_conv_id, group_event_notice};

use crate::conversations::{CachedGroupEntry, StringPairEntry};

/// Mentionable group member entry (`ChatModels.swift: MentionCandidate`).
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct MentionCandidateRecord {
    pub id: String,
    pub name: String,
    pub avatar: Option<String>,
    pub is_all: bool,
}

impl fmt::Debug for MentionCandidateRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MentionCandidateRecord")
            .field("is_all", &self.is_all)
            .field("has_avatar", &self.avatar.is_some())
            .finish()
    }
}

impl From<MentionCandidate> for MentionCandidateRecord {
    fn from(m: MentionCandidate) -> Self {
        Self {
            id: m.id,
            name: m.name,
            avatar: m.avatar,
            is_all: m.is_all,
        }
    }
}

impl From<MentionCandidateRecord> for MentionCandidate {
    fn from(m: MentionCandidateRecord) -> Self {
        Self {
            id: m.id,
            name: m.name,
            avatar: m.avatar,
            is_all: m.is_all,
        }
    }
}

/// One group's cached mention candidates (`groupMemberCache[gid]`).
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct GroupMemberCacheEntry {
    pub group_id: String,
    pub members: Vec<MentionCandidateRecord>,
}

impl fmt::Debug for GroupMemberCacheEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupMemberCacheEntry")
            .field("members", &self.members.len())
            .finish()
    }
}

/// Full U10 groups state snapshot delivered via `CoreChangesRecord.groups`.
#[derive(Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct GroupsStateRecord {
    pub details_json: Vec<StringPairEntry>,
    pub member_cache: Vec<GroupMemberCacheEntry>,
    pub cached_groups: Vec<CachedGroupEntry>,
    pub navigation_request: Option<String>,
}

impl fmt::Debug for GroupsStateRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupsStateRecord")
            .field("details_json", &self.details_json.len())
            .field("member_cache", &self.member_cache.len())
            .field("cached_groups", &self.cached_groups.len())
            .field("has_nav_request", &self.navigation_request.is_some())
            .finish()
    }
}

impl From<GroupsState> for GroupsStateRecord {
    fn from(g: GroupsState) -> Self {
        Self {
            details_json: g
                .details_json
                .into_iter()
                .map(|(key, value)| StringPairEntry { key, value })
                .collect(),
            member_cache: g
                .member_cache
                .into_iter()
                .map(|(group_id, members)| GroupMemberCacheEntry {
                    group_id,
                    members: members.into_iter().map(Into::into).collect(),
                })
                .collect(),
            cached_groups: g
                .cached_groups
                .into_iter()
                .map(|(gid, cg)| CachedGroupEntry {
                    gid,
                    name: cg.name,
                    avatar: cg.avatar,
                    members: cg.members,
                })
                .collect(),
            navigation_request: g.navigation_request,
        }
    }
}

impl From<GroupsStateRecord> for GroupsState {
    fn from(r: GroupsStateRecord) -> Self {
        Self {
            details_json: r
                .details_json
                .into_iter()
                .map(|p| (p.key, p.value))
                .collect(),
            member_cache: r
                .member_cache
                .into_iter()
                .map(|e| (e.group_id, e.members.into_iter().map(Into::into).collect()))
                .collect(),
            cached_groups: r
                .cached_groups
                .into_iter()
                .map(|e| {
                    (
                        e.gid,
                        CachedGroup {
                            name: e.name,
                            avatar: e.avatar,
                            members: e.members,
                        },
                    )
                })
                .collect(),
            navigation_request: r.navigation_request,
        }
    }
}

/// Group roles derived from a cached group detail (`GroupRoles`).
#[derive(Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct GroupRolesRecord {
    pub owner: String,
    pub admins: Vec<String>,
    pub join_approval: bool,
}

impl fmt::Debug for GroupRolesRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupRolesRecord")
            .field("has_owner", &!self.owner.is_empty())
            .field("admins", &self.admins.len())
            .field("join_approval", &self.join_approval)
            .finish()
    }
}

impl From<GroupRoles> for GroupRolesRecord {
    fn from(r: GroupRoles) -> Self {
        Self {
            owner: r.owner,
            admins: r.admins.into_iter().collect(),
            join_approval: r.join_approval,
        }
    }
}

/// Prepared JPEG group avatar bytes passed into `CoreEngine::create_group`.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct GroupAvatarUploadRecord {
    pub jpeg: Vec<u8>,
    pub side: u32,
}

impl fmt::Debug for GroupAvatarUploadRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupAvatarUploadRecord")
            .field("bytes", &self.jpeg.len())
            .field("side", &self.side)
            .finish()
    }
}

impl From<GroupAvatarUploadRecord> for GroupAvatarUpload {
    fn from(r: GroupAvatarUploadRecord) -> Self {
        Self {
            jpeg: r.jpeg,
            side: r.side,
        }
    }
}

/// Outcome of `CoreEngine::create_group` (`GroupCreateOutcome`).
#[derive(Clone, PartialEq, Eq, uniffi::Enum)]
pub enum GroupCreateOutcomeRecord {
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

impl fmt::Debug for GroupCreateOutcomeRecord {
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

impl From<GroupCreateOutcome> for GroupCreateOutcomeRecord {
    fn from(o: GroupCreateOutcome) -> Self {
        match o {
            GroupCreateOutcome::Created { id, failed } => Self::Created { id, failed },
            GroupCreateOutcome::Exists { id, text } => Self::Exists { id, text },
            GroupCreateOutcome::Invalid { text, dropped } => Self::Invalid { text, dropped },
            GroupCreateOutcome::Failed {
                title,
                message,
                closes,
            } => Self::Failed {
                title,
                message,
                closes,
            },
            GroupCreateOutcome::Pending { text } => Self::Pending { text },
        }
    }
}

/// Settled result of `CoreEngine::create_group`.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct GroupCreateResultRecord {
    pub outcome: GroupCreateOutcomeRecord,
    pub version: u64,
}

impl fmt::Debug for GroupCreateResultRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupCreateResultRecord")
            .field("outcome", &self.outcome)
            .field("version", &self.version)
            .finish()
    }
}

/// Settled boolean result of a group mutation (`rename`, `invite`, `kick`, `leave`, admin calls).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GroupBoolResultRecord {
    pub ok: bool,
    pub version: u64,
}

/// Settled member list result (`mention_candidates`, `load_group_members`).
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct GroupMembersResultRecord {
    pub members: Vec<MentionCandidateRecord>,
    pub version: u64,
}

impl fmt::Debug for GroupMembersResultRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupMembersResultRecord")
            .field("members", &self.members.len())
            .field("version", &self.version)
            .finish()
    }
}

/// One pending join request (`GroupPendingMember`).
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct GroupPendingMemberRecord {
    pub id: String,
    pub name: String,
    pub avatar: Option<String>,
}

impl fmt::Debug for GroupPendingMemberRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupPendingMemberRecord")
            .field("has_id", &!self.id.is_empty())
            .field("has_avatar", &self.avatar.is_some())
            .finish()
    }
}

impl From<GroupPendingMember> for GroupPendingMemberRecord {
    fn from(m: GroupPendingMember) -> Self {
        Self {
            id: m.id,
            name: m.name,
            avatar: m.avatar,
        }
    }
}

/// Settled result of `CoreEngine::fetch_group_pending`.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct GroupPendingResultRecord {
    pub members: Option<Vec<GroupPendingMemberRecord>>,
    pub version: u64,
}

impl fmt::Debug for GroupPendingResultRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupPendingResultRecord")
            .field("count", &self.members.as_ref().map(Vec::len))
            .field("version", &self.version)
            .finish()
    }
}

/// Group join link (`GroupLink`).
#[derive(Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct GroupLinkRecord {
    pub link: String,
    pub enabled: bool,
}

impl fmt::Debug for GroupLinkRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupLinkRecord")
            .field("has_link", &!self.link.is_empty())
            .field("enabled", &self.enabled)
            .finish()
    }
}

impl From<GroupLink> for GroupLinkRecord {
    fn from(l: GroupLink) -> Self {
        Self {
            link: l.link,
            enabled: l.enabled,
        }
    }
}

/// Settled result of `CoreEngine::fetch_group_link` / `CoreEngine::set_group_link`.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct GroupLinkResultRecord {
    pub link: Option<GroupLinkRecord>,
    pub version: u64,
}

impl fmt::Debug for GroupLinkResultRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupLinkResultRecord")
            .field("link", &self.link)
            .field("version", &self.version)
            .finish()
    }
}

/// Pure helper: parses `GroupRoles` from a serialized group detail JSON object.
#[uniffi::export]
#[must_use]
pub fn group_roles_from_json_ffi(info_json: String) -> GroupRolesRecord {
    olaz_json::parse_object_str(&info_json)
        .map(|info| GroupRoles::from_info(&info).into())
        .unwrap_or_default()
}

/// Pure helper: formats `"Chưa thêm được A, B và N người khác vào nhóm."`.
#[uniffi::export]
#[must_use]
pub fn group_not_added_text_ffi(names: Vec<String>) -> String {
    not_added_text(&names)
}

/// Pure helper: extracts cleaned member IDs from a serialized group detail JSON + cached member IDs.
#[uniffi::export]
#[must_use]
pub fn group_member_ids_from_detail_ffi(
    group_id: String,
    detail_json: Option<String>,
    cached_member_ids: Vec<String>,
) -> Vec<String> {
    let mut details_json = BTreeMap::new();
    let clean_grid = clean_group_id(&group_id);
    if let Some(json) = detail_json
        && !clean_grid.is_empty()
    {
        details_json.insert(clean_grid, json);
    }
    let mut member_cache = BTreeMap::new();
    let gid = group_conv_id(&group_id);
    if !gid.is_empty() && !cached_member_ids.is_empty() {
        member_cache.insert(
            gid,
            cached_member_ids
                .into_iter()
                .map(|id| MentionCandidate {
                    id,
                    name: String::new(),
                    avatar: None,
                    is_all: false,
                })
                .collect(),
        );
    }
    let groups = GroupsState {
        details_json,
        member_cache,
        ..GroupsState::default()
    };
    group_member_ids(&group_id, &groups)
}

/// Pure helper: formats a group control event into its official Vietnamese system line.
#[uniffi::export]
#[must_use]
pub fn group_event_notice_ffi(
    act: String,
    data_json: String,
    my_uid: String,
    resolved_names: Vec<StringPairEntry>,
) -> Option<String> {
    let data = olaz_json::parse_object_str(&data_json)?;
    let names: HashMap<String, String> = resolved_names
        .into_iter()
        .map(|p| (p.key, p.value))
        .collect();
    group_event_notice(&act, &data, &my_uid, |uid| names.get(uid).cloned())
}

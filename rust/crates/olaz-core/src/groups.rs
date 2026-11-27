//! Groups domain state and shared group metadata helpers (U10 + U12).
//!
//! Owns `details_json` (`cachedGroupDetails`), `member_cache` (`groupMemberCache`), and
//! `cached_groups` (`cachedGroups`) alongside U9's [`ContactsState`].

use std::collections::BTreeMap;
use std::fmt;

use olaz_api::{JsonObject, clean_group_member_ids};
use olaz_store::StoredConversation;
use olaz_wire::{clean_group_id, group_conv_id, lossless};
use serde_json::{Map, Value, json};

use crate::conversations::{
    CachedGroup, ConversationSummary, ConversationsState, sort_conversations,
};
use crate::messages::{
    ContactsState, GroupEntry, fold_contact_str, is_valid_url_str, localized_standard_cmp,
    serialize_cached_groups_json,
};

/// Mentionable group member entry (`ChatModels.swift: MentionCandidate`).
#[derive(Clone, PartialEq, Eq)]
pub struct MentionCandidate {
    pub id: String,
    pub name: String,
    pub avatar: Option<String>,
    pub is_all: bool,
}

impl fmt::Debug for MentionCandidate {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MentionCandidate")
            .field("is_all", &self.is_all)
            .field("has_avatar", &self.avatar.is_some())
            .finish()
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
}

impl fmt::Debug for GroupsState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupsState")
            .field("details_json", &self.details_json.len())
            .field("member_cache", &self.member_cache.len())
            .field("cached_groups", &self.cached_groups.len())
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
        if !clean_ids.is_empty() {
            detail.insert("memIds".to_owned(), json!(clean_ids));
            let ver_list: Vec<String> = clean_ids.iter().map(|id| format!("{id}_0")).collect();
            detail.insert("memVerList".to_owned(), json!(ver_list));
            if detail.contains_key("currentMems") {
                let cur_mems: Vec<Value> = clean_ids.iter().map(|id| json!({ "id": id })).collect();
                detail.insert("currentMems".to_owned(), Value::Array(cur_mems));
            }
        }
    }
    if !detail.is_empty()
        && let Ok(serialized) = serde_json::to_string(&Value::Object(detail))
    {
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

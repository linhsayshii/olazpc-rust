//! Conversation lists, contacts and polling (Swift "Contacts & Profiles" and "Conversations, Pins,
//! Archive, Mute, Polling" sections).

use std::collections::{BTreeMap, HashSet};
use std::fmt;
use std::time::Duration;

use olaz_crypto::md5_hex;
use olaz_json::{bool_value, int64, string};
use olaz_net::{ApiRequest, NetError, Transport, common_params, domains::normalize_host};
use olaz_wire::util::{as_dict_array, pick};
use olaz_wire::{
    clean_group_id, group_conv_id, is_group_id, normalize_thread_id_from_list, strip_user_prefix,
};
use serde_json::{Map, Value, json};

use crate::api::{JsonObject, ZaloApi};
use crate::error::ApiError;
use crate::poll::PollState;
use crate::util::{as_string_array, data_object, non_empty_strings, swift_json};

/// Result of [`ZaloApi::fetch_chat_from_polling`] (Swift `(box, nextState, more)`).
#[derive(Debug, Clone, PartialEq)]
pub struct PollOutcome {
    pub response: JsonObject,
    pub next_state: PollState,
    pub more: bool,
}

/// Server snapshot returned by [`ZaloApi::fetch_hidden_conversations`] (Swift
/// `HiddenConversationsSnapshot`).
#[derive(Clone, PartialEq, Eq, Default)]
pub struct HiddenConversationsSnapshot {
    /// Lowercase MD5 hex of the hidden-chat PIN, or empty when no PIN is configured.
    pub pin: String,
    /// Normalized conversation IDs (deduplicated, preserving server order).
    pub thread_ids: Vec<String>,
}

impl fmt::Debug for HiddenConversationsSnapshot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("HiddenConversationsSnapshot")
            .field("has_pin", &!self.pin.is_empty())
            .field("thread_count", &self.thread_ids.len())
            .finish()
    }
}

/// Flattens `recommendsv2/list` items with `recommType == 2` into the row shape the contacts sync
/// reads (`userId`, `displayName`, `zaloName`, `avatar`, `message`, `time`), newest first
/// (Swift `ZaloSessionClient.receivedFriendRequestRows`).
#[must_use]
pub fn received_friend_request_rows(data: Option<&Value>) -> Vec<JsonObject> {
    let items = data
        .and_then(Value::as_object)
        .and_then(|d| as_dict_array(d.get("recommItems")))
        .unwrap_or_default();
    let mut rows: Vec<JsonObject> = Vec::new();
    for item in items {
        let Some(Value::Object(info)) = item.get("dataInfo") else {
            continue;
        };
        if int64(info.get("recommType")) != Some(2) {
            continue;
        }
        let mut row = info.clone();
        let recomm = info.get("recommInfo").and_then(Value::as_object);
        let msg = string(
            recomm
                .and_then(|r| r.get("message"))
                .or_else(|| info.get("message")),
        );
        let time = int64(
            info.get("recommTime")
                .or_else(|| info.get("friendRequestFetchTime")),
        )
        .unwrap_or(0);
        row.insert("message".to_owned(), Value::String(msg));
        row.insert("time".to_owned(), Value::from(time));
        rows.push(row);
    }
    rows.sort_by(|a, b| {
        int64(b.get("time"))
            .unwrap_or(0)
            .cmp(&int64(a.get("time")).unwrap_or(0))
    });
    rows
}

/// Parses a `/api/hiddenconvers/get-all` response (Swift `parseHiddenConversationsResponse`).
#[must_use]
pub fn parse_hidden_conversations_response(resp: &JsonObject) -> HiddenConversationsSnapshot {
    let data_node = match resp.get("data") {
        Some(Value::Object(d)) => d,
        _ => resp,
    };
    let pin = string(data_node.get("pin")).trim().to_ascii_lowercase();
    let raw_threads = as_dict_array(data_node.get("threads")).unwrap_or_default();

    let mut seen = HashSet::with_capacity(raw_threads.len());
    let mut normalized_ids = Vec::with_capacity(raw_threads.len());

    for row in raw_threads {
        let raw_id = string(pick(row, &["thread_id", "threadId"]));
        if raw_id.is_empty() {
            continue;
        }
        let is_group_val = pick(row, &["is_group", "isGroup"]);
        let is_group = bool_value(is_group_val).unwrap_or_else(|| int64(is_group_val) == Some(1));
        let normalized = if is_group {
            group_conv_id(&raw_id)
        } else {
            strip_user_prefix(&raw_id)
        };
        if normalized.is_empty() || normalized == "0" || normalized == "g0" {
            continue;
        }
        if seen.insert(normalized.clone()) {
            normalized_ids.push(normalized);
        }
    }

    HiddenConversationsSnapshot {
        pin,
        thread_ids: normalized_ids,
    }
}

impl<T: Transport> ZaloApi<T> {
    /// Swift `fetchFriends`. Also fills the global-id caches.
    pub async fn fetch_friends(&self, page: i64, count: i64) -> Result<Vec<JsonObject>, ApiError> {
        let resp = self
            .get(
                ApiRequest::new("profile", "/api/social/friend/getfriends").payload(json!({
                    "incInvalid": 1,
                    "page": page,
                    "count": count,
                    "avatar_size": 160,
                    "actiontime": 0,
                    "imei": self.imei(),
                })),
            )
            .await?;
        let rows = rows_of_data(&resp, &["list", "friends"]);
        let mut state = self.state();
        for row in &rows {
            let uid = strip_user_prefix(&string(pick(row, &["userId", "uid", "id"])));
            let gid = string(row.get("globalId"));
            if !uid.is_empty() && !gid.is_empty() {
                state.global_id_to_uid.insert(gid.clone(), uid.clone());
                state.uid_to_global_id.insert(uid, gid);
            }
        }
        drop(state);
        Ok(rows)
    }

    /// Swift `fetchSentFriendRequests` (`/api/friend/requested/list`).
    pub async fn fetch_sent_friend_requests(&self) -> Result<Vec<JsonObject>, ApiError> {
        let resp = self
            .get(
                ApiRequest::new("friend", "/api/friend/requested/list").payload(json!({
                    "page": 1,
                    "count": 100,
                    "avatar_size": 120,
                })),
            )
            .await?;
        Ok(rows_of_data(&resp, &["list"]))
    }

    /// Swift `fetchReceivedFriendRequests` (`/api/friend/recommendsv2/list`, keeping
    /// `recommItems` whose `dataInfo.recommType == 2`).
    pub async fn fetch_received_friend_requests(&self) -> Result<Vec<JsonObject>, ApiError> {
        let resp = self
            .get(
                ApiRequest::new("friend", "/api/friend/recommendsv2/list")
                    .payload(json!({"imei": self.imei()})),
            )
            .await?;
        Ok(received_friend_request_rows(resp.get("data")))
    }

    /// Swift `fetchGroupsList`: `{gridVerMap, gridInfoMap}` with the group details fetched in
    /// batches of 50 (a failed batch is skipped, like Swift's `try?`).
    pub async fn fetch_groups_list(&self) -> Result<JsonObject, ApiError> {
        let list_resp = self
            .get(ApiRequest::new("group", "/api/group/getlg/v4"))
            .await?;
        let outer = data_object(&list_resp);
        let data_dict = match outer.get("data") {
            Some(Value::Object(inner)) => inner.clone(),
            _ => outer,
        };
        let grid_ver_map = match data_dict.get("gridVerMap") {
            Some(Value::Object(m)) => m.clone(),
            _ => Map::new(),
        };
        let removed: HashSet<String> = match data_dict.get("removedsGroup") {
            Some(Value::Array(a)) => a.iter().map(|v| string(Some(v))).collect(),
            _ => HashSet::new(),
        };
        let all_ids: Vec<&String> = grid_ver_map
            .keys()
            .filter(|k| !k.is_empty() && !removed.contains(*k))
            .collect();

        let mut combined = Map::new();
        for chunk in all_ids.chunks(50) {
            let mut chunk_ver = Map::new();
            for id in chunk {
                chunk_ver.insert((*id).clone(), Value::from(0));
            }
            let ver_json = swift_json(&Value::Object(chunk_ver));
            let batch = self
                .post(
                    ApiRequest::new("group", "/api/group/getmg-v2")
                        .payload(json!({"gridVerMap": ver_json, "imei": self.imei()})),
                )
                .await;
            let Ok(batch_resp) = batch else { continue };
            let Some(Value::Object(outer_batch)) = batch_resp.get("data") else {
                continue;
            };
            let batch_data = match outer_batch.get("data") {
                Some(Value::Object(inner)) => inner,
                _ => outer_batch,
            };
            if let Some(Value::Object(info)) = batch_data.get("gridInfoMap") {
                for (k, v) in info {
                    combined.insert(k.clone(), v.clone());
                }
            }
        }
        let mut out = Map::new();
        out.insert("gridVerMap".to_owned(), Value::Object(grid_ver_map));
        out.insert("gridInfoMap".to_owned(), Value::Object(combined));
        Ok(out)
    }

    /// Swift `fetchAliases`: `uid -> alias`, up to 20 pages of 100.
    pub async fn fetch_aliases(&self) -> Result<BTreeMap<String, String>, ApiError> {
        let mut result = BTreeMap::new();
        let page_size: usize = 100;
        for page in 1..=20_i64 {
            let resp = self
                .get(ApiRequest::new("alias", "/api/alias/list").payload(json!({
                    "page": page,
                    "count": page_size,
                    "imei": self.imei(),
                })))
                .await?;
            let rows = rows_of_data(&resp, &["items", "aliases", "list"]);
            for row in &rows {
                let uid =
                    strip_user_prefix(&string(pick(row, &["userId", "uid", "friendId", "id"])));
                let alias = string(pick(row, &["alias", "aliasName", "name"]))
                    .trim()
                    .to_owned();
                if !uid.is_empty() && !alias.is_empty() {
                    result.insert(uid, alias);
                }
            }
            if rows.len() < page_size {
                break;
            }
        }
        Ok(result)
    }

    /// Swift `fetchChatFromPolling`: one HTTP long-poll of the chat queue.
    pub async fn fetch_chat_from_polling(
        &self,
        state: &PollState,
    ) -> Result<PollOutcome, ApiError> {
        let ts = self.now_ms() / 1000;
        let lp_chat = self.client().domains().lp_chat;
        let base = normalize_host(&lp_chat);
        if base.is_empty() {
            return Err(NetError::InvalidUrl(lp_chat).into());
        }
        let url = format!(
            "{base}/?{}&params={}&ts={ts}",
            common_params(),
            state.encoded_params()
        );
        let resp = self
            .client()
            .raw_get_json(&url, Duration::from_secs(12), true)
            .await?;
        let data_node = match resp.get("data") {
            Some(Value::Object(d)) => d.clone(),
            _ => resp.clone(),
        };
        let mut next_state = state.clone();
        let (more, _reset) = next_state.apply_response(&data_node);
        Ok(PollOutcome {
            response: resp,
            next_state,
            more,
        })
    }

    /// Swift `fetchPinnedConversations`.
    pub async fn fetch_pinned_conversations(&self) -> Result<Vec<String>, ApiError> {
        let resp = self
            .get(ApiRequest::new("conversation", "/api/pinconvers/list"))
            .await?;
        let raw_ids = match resp.get("data") {
            Some(Value::Array(list)) => non_empty_strings(list),
            Some(Value::Object(dict)) => {
                let arr = match dict.get("conversations") {
                    Some(Value::Array(a)) => Some(a),
                    _ => match dict.get("items") {
                        Some(Value::Array(a)) => Some(a),
                        _ => None,
                    },
                };
                arr.map(|a| non_empty_strings(a)).unwrap_or_default()
            }
            _ => Vec::new(),
        };
        Ok(raw_ids
            .iter()
            .map(|id| normalize_thread_id_from_list(id))
            .collect())
    }

    /// Swift `updatePinnedConversation`.
    pub async fn update_pinned_conversation(
        &self,
        conv_id: &str,
        pinned: bool,
    ) -> Result<(), ApiError> {
        let wire_id = if is_group_id(conv_id) {
            group_conv_id(conv_id)
        } else {
            format!("u{}", strip_user_prefix(conv_id))
        };
        self.post(
            ApiRequest::new("conversation", "/api/pinconvers/updatev2").payload(json!({
                "actionType": if pinned { 1 } else { 2 },
                "conversations": [wire_id],
                "tab": 0,
            })),
        )
        .await?;
        Ok(())
    }

    /// Swift `fetchArchivedChats`. Remembers `data.version` (see [`Self::archived_version`]).
    pub async fn fetch_archived_chats(&self) -> Result<Vec<String>, ApiError> {
        let resp = self
            .get(
                ApiRequest::new("label", "/api/archivedchat/list")
                    .payload(json!({"version": 0, "imei": self.imei()})),
            )
            .await?;
        let d = data_object(&resp);
        if let Some(ver) = int64(d.get("version")) {
            self.state().archived_version = ver;
        }
        let mut result = Vec::new();
        if let Some(items) = as_dict_array(d.get("items")) {
            for item in items {
                let raw_id = string(item.get("id"));
                if raw_id.is_empty() {
                    continue;
                }
                let type_val = int64(item.get("type")).unwrap_or(0);
                if type_val == 1 || is_group_id(&raw_id) {
                    result.push(group_conv_id(&raw_id));
                } else {
                    result.push(normalize_thread_id_from_list(&raw_id));
                }
            }
        } else if let Some(raw_ids) =
            as_string_array(d.get("conversations")).or_else(|| as_string_array(resp.get("data")))
        {
            result = raw_ids
                .iter()
                .map(|id| normalize_thread_id_from_list(id))
                .collect();
        }
        Ok(result)
    }

    /// Swift `updateArchivedChat`.
    pub async fn update_archived_chat(
        &self,
        conv_id: &str,
        archived: bool,
    ) -> Result<(), ApiError> {
        let (is_group, clean_id) = crate::util::conv_target(conv_id);
        let version = self.state().archived_version;
        self.post(
            ApiRequest::new("label", "/api/archivedchat/update").payload(json!({
                "ids": [{"id": clean_id, "type": if is_group { 1 } else { 0 }}],
                "version": version,
                "actionType": if archived { 0 } else { 1 },
                "imei": self.imei(),
            })),
        )
        .await?;
        Ok(())
    }

    /// Swift `fetchConversationLabels`. Remembers `data.version` ([`Self::label_version`]).
    pub async fn fetch_conversation_labels(&self) -> Result<JsonObject, ApiError> {
        let resp = self
            .get(
                ApiRequest::new("label", "/api/convlabel/get")
                    .payload(json!({"imei": self.imei()})),
            )
            .await?;
        let d = data_object(&resp);
        if let Some(ver) = int64(d.get("version")) {
            self.state().label_version = ver;
        }
        Ok(d)
    }

    /// Swift `updateConversationLabels`. Remembers `data.version` when present.
    pub async fn update_conversation_labels(&self, label_data_json: &str) -> Result<(), ApiError> {
        let version = self.state().label_version;
        let resp = self
            .post(
                ApiRequest::new("label", "/api/convlabel/update").payload(json!({
                    "labelData": label_data_json,
                    "version": version,
                    "imei": self.imei(),
                })),
            )
            .await?;
        let d = data_object(&resp);
        if let Some(ver) = int64(d.get("version")) {
            self.state().label_version = ver;
        }
        Ok(())
    }

    /// Swift `deleteConversationAPI`.
    pub async fn delete_conversation(
        &self,
        conv_id: &str,
        last_cli_msg_id: &str,
    ) -> Result<(), ApiError> {
        let (is_group, clean_id) = crate::util::conv_target(conv_id);
        let cli_id = if last_cli_msg_id.is_empty() {
            self.client().next_client_id().to_string()
        } else {
            last_cli_msg_id.to_owned()
        };
        if is_group {
            self.post(
                ApiRequest::new("group", "/api/group/deleteconver").payload(json!({
                    "grid": clean_id,
                    "cliMsgId": cli_id,
                    "conver": {},
                    "onlyMe": 1,
                    "imei": self.imei(),
                })),
            )
            .await?;
        } else {
            self.post(
                ApiRequest::new("chat", "/api/message/deleteconver").payload(json!({
                    "toid": clean_id,
                    "cliMsgId": cli_id,
                    "conver": {},
                    "onlyMe": 1,
                    "imei": self.imei(),
                })),
            )
            .await?;
        }
        Ok(())
    }

    /// Swift `fetchHiddenConversationsAPI`.
    pub async fn fetch_hidden_conversations(
        &self,
    ) -> Result<HiddenConversationsSnapshot, ApiError> {
        let resp = self
            .get(
                ApiRequest::new("conversation", "/api/hiddenconvers/get-all")
                    .payload(json!({"imei": self.imei()})),
            )
            .await?;
        Ok(parse_hidden_conversations_response(&resp))
    }

    /// Swift `setHiddenConversationAPI`.
    pub async fn set_hidden_conversation(
        &self,
        conv_id: &str,
        hidden: bool,
    ) -> Result<(), ApiError> {
        let (is_group, clean_id) = crate::util::conv_target(conv_id);
        let entry = json!([{"is_group": if is_group { 1 } else { 0 }, "thread_id": clean_id}]);
        let entry_str = swift_json(&entry);
        let (add_str, del_str) = if hidden {
            (entry_str, "[]".to_owned())
        } else {
            ("[]".to_owned(), entry_str)
        };
        self.post(
            ApiRequest::new("conversation", "/api/hiddenconvers/add-remove").payload(json!({
                "del_threads": del_str,
                "add_threads": add_str,
                "imei": self.imei(),
            })),
        )
        .await?;
        Ok(())
    }

    /// Swift `updateHiddenPinAPI`.
    pub async fn update_hidden_pin(&self, pin: &str) -> Result<JsonObject, ApiError> {
        if pin.is_empty() {
            return Err(NetError::InvalidUrl("hiddenconvers:update-pin".to_owned()).into());
        }
        self.get(
            ApiRequest::new("conversation", "/api/hiddenconvers/update-pin").payload(json!({
                "new_pin": md5_hex(pin.as_bytes()),
                "imei": self.imei(),
            })),
        )
        .await
    }

    /// Swift `resetHiddenPinAPI`.
    pub async fn reset_hidden_pin(&self) -> Result<JsonObject, ApiError> {
        self.get(ApiRequest::new("conversation", "/api/hiddenconvers/reset"))
            .await
    }

    /// Swift `fetchMuteList`: rows tagged `type` 1 (peer) / 2 (group), or the legacy fallbacks.
    pub async fn fetch_mute_list(&self) -> Result<Vec<JsonObject>, ApiError> {
        let resp = self
            .get(
                ApiRequest::new("profile", "/api/social/profile/getmute")
                    .payload(json!({"imei": self.imei()})),
            )
            .await?;
        let d = data_object(&resp);
        let mut normalized: Vec<JsonObject> = Vec::new();
        for (key, tag) in [("chatEntries", 1), ("groupChatEntries", 2)] {
            if let Some(rows) = as_dict_array(d.get(key)) {
                for row in rows {
                    let mut row = row.clone();
                    row.insert("type".to_owned(), Value::from(tag));
                    normalized.push(row);
                }
            }
        }
        if normalized.is_empty() {
            let fallback = as_dict_array(d.get("chats"))
                .or_else(|| as_dict_array(resp.get("data")))
                .unwrap_or_default();
            normalized.extend(fallback.into_iter().cloned());
        }
        Ok(normalized)
    }

    /// Swift `fetchPreloadConversations`: recent threads with their last messages. An empty
    /// `thread_ids` (`threadIdLocalMsgId: "{}"`) returns the active-thread overview; otherwise at
    /// most 25 ids are asked for.
    pub async fn fetch_preload_conversations(
        &self,
        thread_ids: &[String],
    ) -> Result<JsonObject, ApiError> {
        let mut map = Map::new();
        for raw_id in thread_ids.iter().take(25) {
            if is_group_id(raw_id) {
                let clean = clean_group_id(raw_id);
                if !clean.is_empty() {
                    map.insert(format!("{clean}_1"), Value::from("1"));
                }
            } else {
                let clean = strip_user_prefix(raw_id);
                if !clean.is_empty() {
                    map.insert(format!("{clean}_0"), Value::from("1"));
                }
            }
        }
        let map_json = if map.is_empty() {
            "{}".to_owned()
        } else {
            swift_json(&Value::Object(map))
        };
        self.get(
            ApiRequest::new("conversation", "/api/preloadconvers/get-last-msgs").payload(json!({
                "threadIdLocalMsgId": map_json,
                "imei": self.imei(),
            })),
        )
        .await
    }

    /// Swift `setUnreadMarkAPI`.
    pub async fn set_unread_mark(&self, conv_id: &str, unread: bool) -> Result<(), ApiError> {
        let (is_group, clean) = crate::util::conv_target(conv_id);
        let (convs_group, convs_user) = if is_group {
            (vec![clean], Vec::new())
        } else {
            (Vec::new(), vec![clean])
        };
        let (path, inner) = if unread {
            (
                "/api/conv/addUnreadMark",
                json!({"convsGroup": convs_group, "convsUser": convs_user, "imei": self.imei()}),
            )
        } else {
            (
                "/api/conv/removeUnreadMark",
                json!({
                    "convsGroup": convs_group,
                    "convsUser": convs_user,
                    "convsGroupData": [],
                    "convsUserData": [],
                }),
            )
        };
        self.post(
            ApiRequest::new("conversation", path).payload(json!({"param": swift_json(&inner)})),
        )
        .await?;
        Ok(())
    }
}

/// `data as [[String: Any]]`, else `data[k1] ?? data[k2] ...` as `[[String: Any]]`, else `[]`.
fn rows_of_data(resp: &JsonObject, keys: &[&str]) -> Vec<JsonObject> {
    if let Some(direct) = as_dict_array(resp.get("data")) {
        return direct.into_iter().cloned().collect();
    }
    if let Some(Value::Object(d)) = resp.get("data") {
        for key in keys {
            if let Some(rows) = as_dict_array(d.get(*key)) {
                return rows.into_iter().cloned().collect();
            }
        }
    }
    Vec::new()
}

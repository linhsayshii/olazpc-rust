//! Message history (Swift `fetchHistory`).

use olaz_json::{int64, string};
use olaz_net::{ApiRequest, Transport};
use olaz_wire::util::as_dict_array;
use serde_json::{Map, Value, json};

use crate::api::{JsonObject, ZaloApi};
use crate::error::ApiError;
use crate::util::conv_target;

const NEWEST_CURSOR: &str = "9223372036854775807";

fn empty_msgs() -> JsonObject {
    let mut data = Map::new();
    data.insert("msgs".to_owned(), Value::Array(Vec::new()));
    let mut out = Map::new();
    out.insert("error_code".to_owned(), Value::from(0));
    out.insert("data".to_owned(), Value::Object(data));
    out
}

fn flag(value: Option<&Value>) -> bool {
    int64(value) == Some(1) || matches!(value, Some(Value::Bool(true)))
}

impl<T: Transport> ZaloApi<T> {
    /// Swift `fetchHistory`.
    ///
    /// 1-1 peer chats have no `/api/cm/*` history: the newest messages come from
    /// `get-last-msgs` and any paging request answers an empty `msgs` list. Groups and the self
    /// cloud page through `/api/cm/getrecentv2` / `getoldv2` (up to 8 pages, until about 20
    /// messages are collected) and answer with `data.groupMsgs`, `isOld`, `hasMore`, `lastMsgId`.
    pub async fn fetch_history(
        &self,
        conv_id: &str,
        last_msg_id: Option<&str>,
        count: i64,
        is_old: Option<bool>,
    ) -> Result<JsonObject, ApiError> {
        let (is_group, clean_id) = conv_target(conv_id);
        let account = self.client().account();
        let send2me = account.as_ref().map(|a| a.send2me_id.clone());
        let user_id = account.as_ref().map(|a| a.user_id.clone());
        let is_self_cloud = !is_group
            && (send2me.as_deref() == Some(clean_id.as_str())
                || (user_id.as_deref() == Some(clean_id.as_str())
                    && send2me.as_deref().is_some_and(|s| !s.is_empty())));
        let cursor_in = last_msg_id.filter(|c| !c.is_empty() && *c != "0");
        let has_valid_cursor = cursor_in.is_some();

        if !is_group && !is_self_cloud {
            if is_old == Some(true) || has_valid_cursor {
                return Ok(empty_msgs());
            }
            return self
                .fetch_preload_conversations(&[conv_id.to_owned()])
                .await;
        }

        let cloud_id = match (&send2me, is_self_cloud) {
            (Some(s), true) if !s.is_empty() => s.clone(),
            _ => clean_id.clone(),
        };
        if is_old == Some(true) && !has_valid_cursor {
            return Ok(empty_msgs());
        }
        if !has_valid_cursor && is_old.is_none() {
            self.state()
                .cloud_is_old_by_conv
                .insert(cloud_id.clone(), false);
        }

        let mut current_is_old = is_old.unwrap_or_else(|| {
            if has_valid_cursor {
                self.state()
                    .cloud_is_old_by_conv
                    .get(&cloud_id)
                    .copied()
                    .unwrap_or(false)
            } else {
                false
            }
        });
        let mut current_cursor = cursor_in.unwrap_or(NEWEST_CURSOR).to_owned();
        let mut accumulated: Vec<Value> = Vec::new();
        let mut last_response: JsonObject = {
            let mut data = Map::new();
            data.insert("groupMsgs".to_owned(), Value::Array(Vec::new()));
            let mut m = Map::new();
            m.insert("error_code".to_owned(), Value::from(0));
            m.insert("data".to_owned(), Value::Object(data));
            m
        };
        let mut final_has_more = false;
        let mut final_last_msg_id = "0".to_owned();
        let min_target_count = usize::try_from(count.clamp(1, 20)).unwrap_or(1);
        let imei = self.imei();

        for attempt in 0..8_i64 {
            let path = if current_is_old {
                "/api/cm/getoldv2"
            } else {
                "/api/cm/getrecentv2"
            };
            let src_val = if attempt == 0 {
                if has_valid_cursor { 3 } else { 1 }
            } else {
                2
            };
            let mut payload = json!({
                "groupId": cloud_id,
                "globalMsgId": current_cursor,
                "count": count,
                "msgIds": [],
                "imei": imei,
                "src": src_val,
            });
            if is_self_cloud && let Some(obj) = payload.as_object_mut() {
                obj.insert("isOA".to_owned(), Value::from(1));
            }
            let request = ApiRequest::new("group_cloud_message", path)
                .header("nretry", &attempt.to_string())
                .payload(payload);
            let resp = match self.get(request).await {
                Ok(r) => r,
                Err(e) if attempt == 0 => return Err(e),
                Err(_) => break,
            };

            last_response = resp;
            let Some(Value::Object(d)) = last_response.get("data") else {
                break;
            };
            if let Some(page) = as_dict_array(d.get("groupMsgs")) {
                accumulated.extend(page.into_iter().map(|m| Value::Object(m.clone())));
            }
            let server_is_old = flag(d.get("isOld"));
            let server_has_more = flag(d.get("hasMore"));
            let raw_last = string(d.get("lastMsgId"));

            self.state()
                .cloud_is_old_by_conv
                .insert(cloud_id.clone(), server_is_old);
            current_is_old = server_is_old;
            final_has_more = server_has_more;
            final_last_msg_id = raw_last.clone();

            if !server_has_more
                || accumulated.len() >= min_target_count
                || raw_last.is_empty()
                || raw_last == "0"
                || raw_last == current_cursor
            {
                break;
            }
            current_cursor = raw_last;
        }

        let mut out_data = match last_response.get("data") {
            Some(Value::Object(d)) => d.clone(),
            _ => Map::new(),
        };
        out_data.insert("groupMsgs".to_owned(), Value::Array(accumulated));
        out_data.insert("isOld".to_owned(), Value::from(i64::from(current_is_old)));
        out_data.insert("hasMore".to_owned(), Value::from(i64::from(final_has_more)));
        out_data.insert("lastMsgId".to_owned(), Value::from(final_last_msg_id));
        last_response.insert("data".to_owned(), Value::Object(out_data));
        Ok(last_response)
    }
}

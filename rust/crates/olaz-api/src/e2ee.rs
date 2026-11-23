//! E2EE message envelope (Swift `buildE2EE*`, `extractE2EESendResponse`, `sendE2EEMessageAPI`).
//! The Signal ciphertext itself is produced elsewhere; this only builds and sends the request.

use olaz_json::{int64, string};
use olaz_net::{ApiRequest, Transport};
use olaz_wire::strip_user_prefix;
use olaz_wire::util::as_dict_array;
use serde_json::{Map, Value, json};

use crate::api::{JsonObject, SendMessageResult, ZaloApi};
use crate::error::ApiError;
use crate::messaging::CallSpec;
use crate::util::swift_json;

/// Swift `buildE2EEExtJSON` (sorted keys).
pub fn build_e2ee_ext_json(
    registration_id: i64,
    sender_registration_id: i64,
    version: i64,
    compat_version: i64,
) -> String {
    swift_json(&json!({
        "version": version,
        "compat_version": compat_version,
        "iid": registration_id,
        "sender_iid": sender_registration_id,
    }))
}

/// Inputs of [`build_e2ee_list_param_entry`] (Swift `buildE2EEListParamEntry`).
#[derive(Debug, Clone)]
pub struct E2eeListParams<'a> {
    pub to_id: &'a str,
    pub platform: i64,
    pub client_id: i64,
    pub imei: &'a str,
    pub registration_id: i64,
    pub sender_iid: i64,
    /// Swift default 0.
    pub ttl: i64,
    /// `true` writes the ext JSON under `e2ee` instead of `e2eeExt`.
    pub use_legacy_e2ee_key: bool,
    /// Swift default 1.
    pub version: i64,
    /// Swift default 1.
    pub compat_version: i64,
    /// Merged last, overriding the standard keys.
    pub extra_fields: Map<String, Value>,
}

impl<'a> E2eeListParams<'a> {
    pub fn new(
        to_id: &'a str,
        platform: i64,
        client_id: i64,
        imei: &'a str,
        registration_id: i64,
        sender_iid: i64,
    ) -> Self {
        Self {
            to_id,
            platform,
            client_id,
            imei,
            registration_id,
            sender_iid,
            ttl: 0,
            use_legacy_e2ee_key: false,
            version: 1,
            compat_version: 1,
            extra_fields: Map::new(),
        }
    }
}

/// Swift `buildE2EEListParamEntry`.
pub fn build_e2ee_list_param_entry(p: &E2eeListParams<'_>) -> JsonObject {
    let ext = build_e2ee_ext_json(p.registration_id, p.sender_iid, p.version, p.compat_version);
    let mut entry = Map::new();
    entry.insert("toId".to_owned(), Value::from(strip_user_prefix(p.to_id)));
    entry.insert("platform".to_owned(), Value::from(p.platform));
    entry.insert("clientId".to_owned(), Value::from(p.client_id));
    entry.insert("imei".to_owned(), Value::from(p.imei));
    entry.insert("ttl".to_owned(), Value::from(p.ttl));
    entry.insert(
        if p.use_legacy_e2ee_key {
            "e2ee"
        } else {
            "e2eeExt"
        }
        .to_owned(),
        Value::from(ext),
    );
    for (k, v) in &p.extra_fields {
        entry.insert(k.clone(), v.clone());
    }
    entry
}

/// Swift `buildE2EEMessageRequestPayload`. Groups send the first list entry with `clientId` set;
/// 1-1 sends `listParams` as a JSON string plus `destType`, `threadId`, `clientId`.
pub fn build_e2ee_message_request_payload(
    endpoint: &str,
    thread_id: &str,
    is_group: bool,
    client_id: i64,
    list_params: &[JsonObject],
    dest_type: i64,
) -> CallSpec {
    if is_group {
        let mut payload = list_params.first().cloned().unwrap_or_default();
        payload.insert("clientId".to_owned(), Value::from(client_id));
        return CallSpec {
            service: "group_e2e".to_owned(),
            path: format!("/api/e2ee/pc/group/{endpoint}"),
            payload: Value::Object(payload),
        };
    }
    let clean_id = strip_user_prefix(thread_id);
    let list: Vec<Value> = list_params.iter().cloned().map(Value::Object).collect();
    CallSpec {
        service: "chat_e2e".to_owned(),
        path: format!("/api/e2ee/pc/message/{endpoint}"),
        payload: json!({
            "listParams": swift_json(&Value::Array(list)),
            "destType": dest_type,
            "threadId": clean_id,
            "clientId": client_id,
        }),
    }
}

/// Swift `extractE2EESendResponse`: `(msgId, tsMs)` from `data`, `data.data`, `data.data[]` or the
/// root. `msgId` is `minGlobalMsgId` / `msgId` / `globalMsgId` (non-empty, not `"0"`); a `ts`
/// below 1e10 is seconds and is scaled to ms.
pub fn extract_e2ee_send_response(resp: &JsonObject) -> (String, Option<i64>) {
    let d = resp.get("data").and_then(Value::as_object);
    let nested = d.and_then(|d| d.get("data")).and_then(Value::as_object);
    let mut dicts: Vec<&JsonObject> = Vec::new();
    if let Some(d) = d {
        dicts.push(d);
    }
    if let Some(n) = nested {
        dicts.push(n);
    }
    if let Some(arr) = as_dict_array(d.and_then(|d| d.get("data"))) {
        dicts.extend(arr);
    }
    dicts.push(resp);

    let mut msg_id = String::new();
    for dict in &dicts {
        if !msg_id.is_empty() {
            break;
        }
        for key in ["minGlobalMsgId", "msgId", "globalMsgId"] {
            let candidate = string(dict.get(key)).trim().to_owned();
            if !candidate.is_empty() && candidate != "0" {
                msg_id = candidate;
                break;
            }
        }
    }

    let mut ts_ms = None;
    for dict in &dicts {
        if let Some(raw) = int64(dict.get("ts").or_else(|| dict.get("sendDttm")))
            && raw > 0
        {
            ts_ms = Some(if raw < 10_000_000_000 {
                raw * 1000
            } else {
                raw
            });
            break;
        }
    }
    (msg_id, ts_ms)
}

impl<T: Transport> ZaloApi<T> {
    /// Swift `sendE2EEMessageAPI`. The result's `msg_id` falls back to the client id until the
    /// WebSocket echo supplies the server id.
    pub async fn send_e2ee_message(
        &self,
        endpoint: &str,
        thread_id: &str,
        is_group: bool,
        client_id: i64,
        list_params: &[JsonObject],
        dest_type: i64,
    ) -> Result<SendMessageResult, ApiError> {
        let spec = build_e2ee_message_request_payload(
            endpoint,
            thread_id,
            is_group,
            client_id,
            list_params,
            dest_type,
        );
        let resp = self
            .post(ApiRequest::new(spec.service.clone(), spec.path.clone()).payload(spec.payload))
            .await?;
        let (msg_id, ts_ms) = extract_e2ee_send_response(&resp);
        if msg_id.is_empty() {
            // Shapes only (key names), never values.
            let keys = resp
                .get("data")
                .and_then(Value::as_object)
                .map(|d| d.keys().cloned().collect::<Vec<_>>().join(","));
            tracing::debug!(path = %spec.path, data_keys = ?keys, "e2ee send: no server msgId");
        }
        let cli_str = client_id.to_string();
        Ok(SendMessageResult {
            msg_id: if msg_id.is_empty() {
                cli_str.clone()
            } else {
                msg_id
            },
            cli_msg_id: cli_str,
            ts_ms: ts_ms.unwrap_or_else(|| self.now_ms()),
        })
    }
}

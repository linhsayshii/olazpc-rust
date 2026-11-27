//! Reminder creation endpoints (U13, Swift `createReminderAPI`).

use std::fmt;

use olaz_json::string as json_string;
use olaz_net::{ApiRequest, Transport};
use olaz_wire::{clean_group_id, is_group_id, strip_user_prefix};
use serde_json::{Value, json};

use crate::api::{JsonObject, ZaloApi};
use crate::error::ApiError;
use crate::messaging::CallSpec;
use crate::util::swift_json;

/// Parameters for [`ZaloApi::create_reminder`].
///
/// `Debug` is shape-only (ADR-008): conversation id and title text are redacted.
#[derive(Clone, PartialEq, Eq)]
pub struct CreateReminderParams {
    pub conv_id: String,
    pub title: String,
    pub start_time_ms: i64,
    pub repeat_mode: i64,
    pub pin: bool,
}

impl fmt::Debug for CreateReminderParams {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CreateReminderParams")
            .field("is_group", &is_group_id(&self.conv_id))
            .field("title_len", &self.title.len())
            .field("start_time_ms", &self.start_time_ms)
            .field("repeat_mode", &self.repeat_mode)
            .field("pin", &self.pin)
            .finish()
    }
}

/// Pure request builder for [`ZaloApi::create_reminder`].
///
/// Approved fix (user-decisions item 13.1): 1-1 reminders send `needPin: params.pin` instead of
/// hardcoding `false`.
#[must_use]
pub fn build_create_reminder_request(params: &CreateReminderParams, imei: &str) -> CallSpec {
    let is_group = is_group_id(&params.conv_id);
    if !is_group {
        let clean_id = strip_user_prefix(&params.conv_id);
        let obj = json!({
            "toUid": clean_id,
            "type": 0,
            "color": -16_777_216_i64,
            "emoji": "⏰",
            "startTime": params.start_time_ms,
            "duration": -1,
            "params": {
                "title": params.title,
                "setTitle": true,
            },
            "needPin": params.pin,
            "repeat": params.repeat_mode,
        });
        return CallSpec {
            service: "group_board".to_owned(),
            path: "/api/board/oneone/create".to_owned(),
            payload: json!({
                "objectData": swift_json(&obj),
                "imei": imei,
            }),
        };
    }
    let clean_id = clean_group_id(&params.conv_id);
    let params_str = swift_json(&json!({
        "title": params.title,
        "setTitle": true,
    }));
    CallSpec {
        service: "group_board".to_owned(),
        path: "/api/board/topic/createv2".to_owned(),
        payload: json!({
            "grid": clean_id,
            "type": 0,
            "color": -16_777_216_i64,
            "emoji": "⏰",
            "startTime": params.start_time_ms,
            "duration": -1,
            "params": params_str,
            "pinAct": 0,
            "repeat": params.repeat_mode,
            "src": 1,
            "imei": imei,
        }),
    }
}

impl<T: Transport> ZaloApi<T> {
    /// Creates a reminder in a 1-1 or group conversation (`createReminderAPI`).
    pub async fn create_reminder(
        &self,
        params: &CreateReminderParams,
    ) -> Result<JsonObject, ApiError> {
        let imei = self.imei();
        let spec = build_create_reminder_request(params, &imei);
        self.post(ApiRequest::new(spec.service, spec.path).payload(spec.payload))
            .await
    }
}

/// Extracts the created topic/reminder id from a `createv2` response.
#[must_use]
pub fn extract_created_reminder_id(resp: &JsonObject) -> String {
    let data_node = resp.get("data").and_then(Value::as_object).unwrap_or(resp);
    let raw = data_node
        .get("id")
        .or_else(|| data_node.get("topicId"))
        .or_else(|| data_node.get("topic_id"));
    json_string(raw).trim().to_owned()
}

#[cfg(test)]
#[expect(clippy::unwrap_used, reason = "unit test fixtures")]
mod tests {
    use super::*;

    #[test]
    fn group_create_reminder_sends_pin_act_zero_and_1_1_preserves_need_pin() {
        for pin in [true, false] {
            let spec = build_create_reminder_request(
                &CreateReminderParams {
                    conv_id: "g501308".to_owned(),
                    title: "Standup".to_owned(),
                    start_time_ms: 1_700_003_000_000,
                    repeat_mode: 2,
                    pin,
                },
                "imei-1",
            );
            assert_eq!(spec.service, "group_board");
            assert_eq!(spec.path, "/api/board/topic/createv2");
            assert_eq!(spec.payload.get("grid"), Some(&json!("501308")));
            assert_eq!(spec.payload.get("type"), Some(&json!(0)));
            assert_eq!(spec.payload.get("pinAct"), Some(&json!(0)));
        }

        let oneone = build_create_reminder_request(
            &CreateReminderParams {
                conv_id: "3001308".to_owned(),
                title: "Call".to_owned(),
                start_time_ms: 1_700_001_000_000,
                repeat_mode: 0,
                pin: true,
            },
            "imei-1",
        );
        assert_eq!(oneone.path, "/api/board/oneone/create");
        let obj_str = oneone
            .payload
            .get("objectData")
            .and_then(Value::as_str)
            .unwrap();
        let obj: Value = serde_json::from_str(obj_str).unwrap();
        assert_eq!(obj.get("needPin"), Some(&json!(true)));
    }

    #[test]
    fn extract_created_reminder_id_reads_data_and_root_variants() {
        assert_eq!(
            extract_created_reminder_id(json!({"data": {"id": " rem_1 "}}).as_object().unwrap()),
            "rem_1"
        );
        assert_eq!(
            extract_created_reminder_id(json!({"data": {"id": 987654}}).as_object().unwrap()),
            "987654"
        );
        assert_eq!(
            extract_created_reminder_id(json!({"data": {"topicId": "t_2"}}).as_object().unwrap()),
            "t_2"
        );
        assert_eq!(
            extract_created_reminder_id(json!({"topic_id": "t_3"}).as_object().unwrap()),
            "t_3"
        );
        assert_eq!(
            extract_created_reminder_id(json!({"data": {}}).as_object().unwrap()),
            ""
        );
    }
}

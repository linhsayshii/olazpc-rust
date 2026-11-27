//! Notification mute API + card-action / invite / reminder / sticker-suggest APIs (U16).
//!
//! Mirrors the U16 subset of `ZaloAPIService.swift`:
//! - `setMuteAPI` (`POST /api/social/profile/setmute`)
//! - `suggestStickersAPI` (`GET /api/message/sticker/suggest/stickers`)
//! - `fetchGroupLinkDetail` (`GET /api/group/link/detail`)
//! - `joinGroupByLink` (`GET /api/group/link/join`)
//! - `fetchReminderDetail` (`GET /api/board/topic/getReminder`)
//! - `respondReminderAPI` (`POST /api/board/topic/updateEventResponse`)
//! - `fetchReminderRespondersAPI` (`GET /api/board/topic/listResponseEvent`)

use olaz_net::{ApiRequest, Transport};
use olaz_wire::{clean_group_id, strip_user_prefix};
use serde_json::{Value, json};

use crate::api::{JsonObject, ZaloApi};
use crate::error::ApiError;

/// Pure request payload builder for `setMuteAPI` (`POST /api/social/profile/setmute`).
#[must_use]
pub fn build_set_mute_payload(
    conv_id: &str,
    is_group: bool,
    duration_secs: i64,
    unmute: bool,
    start_time_sec: i64,
    imei: &str,
) -> Value {
    let clean_id = if is_group {
        clean_group_id(conv_id)
    } else {
        strip_user_prefix(conv_id)
    };
    json!({
        "toid": clean_id,
        "duration": if unmute { 0 } else { duration_secs },
        "action": if unmute { 3 } else { 1 },
        "startTime": start_time_sec,
        "muteType": if is_group { 2 } else { 1 },
        "imei": imei,
    })
}

/// Pure response extractor for `suggestStickersAPI`.
#[must_use]
pub fn extract_suggested_sticker_rows(resp: &JsonObject) -> Vec<JsonObject> {
    if let Some(d) = resp.get("data").and_then(Value::as_object) {
        if let Some(sugg) = d.get("sugg_sticker").and_then(Value::as_array) {
            let objs: Vec<JsonObject> = sugg.iter().filter_map(Value::as_object).cloned().collect();
            if !objs.is_empty() {
                return objs;
            }
        }
        if let Some(stickers) = d.get("stickers").and_then(Value::as_array) {
            return stickers
                .iter()
                .filter_map(Value::as_object)
                .cloned()
                .collect();
        }
    }
    resp.get("data")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(Value::as_object).cloned().collect())
        .unwrap_or_default()
}

impl<T: Transport> ZaloApi<T> {
    /// Swift `setMuteAPI`: `POST /api/social/profile/setmute`.
    pub async fn set_mute(
        &self,
        conv_id: &str,
        is_group: bool,
        duration_secs: i64,
        unmute: bool,
        start_time_sec: Option<i64>,
    ) -> Result<(), ApiError> {
        let start = start_time_sec.unwrap_or_else(|| self.now_ms() / 1000);
        let payload = build_set_mute_payload(
            conv_id,
            is_group,
            duration_secs,
            unmute,
            start,
            &self.imei(),
        );
        self.post(ApiRequest::new("profile", "/api/social/profile/setmute").payload(payload))
            .await?;
        Ok(())
    }

    /// Swift `fetchGroupLinkDetail`: `GET /api/group/link/detail`.
    pub async fn fetch_group_link_detail(&self, link: &str) -> Result<JsonObject, ApiError> {
        self.get(
            ApiRequest::new("group", "/api/group/link/detail").payload(json!({
                "link": link,
                "avatar_size": 120,
                "member_avatar_size": 120,
                "mpage": 1,
            })),
        )
        .await
    }

    /// Swift `joinGroupByLink`: `GET /api/group/link/join`.
    /// Preserves non-zero `error_code` + `data` so `178` can read `data.groupId` when present.
    pub async fn join_group_by_link(&self, link: &str) -> Result<JsonObject, ApiError> {
        let client_id = self.client().next_client_id();
        let req = ApiRequest::new("group", "/api/group/link/join").payload(json!({
            "link": link,
            "clientId": client_id,
        }));
        Ok(self.client().get_unchecked(&req).await?)
    }

    /// Swift `fetchReminderDetail`: `GET /api/board/topic/getReminder`.
    pub async fn fetch_reminder_detail(&self, reminder_id: &str) -> Result<JsonObject, ApiError> {
        self.get(
            ApiRequest::new("group_board", "/api/board/topic/getReminder").payload(json!({
                "eventId": reminder_id,
                "imei": self.imei(),
            })),
        )
        .await
    }

    /// Swift `respondReminderAPI`: `POST /api/board/topic/updateEventResponse`.
    pub async fn respond_reminder(
        &self,
        conv_id: &str,
        reminder_id: &str,
        accept: bool,
    ) -> Result<JsonObject, ApiError> {
        let grid = clean_group_id(conv_id);
        self.post(
            ApiRequest::new("group_board", "/api/board/topic/updateEventResponse").payload(json!({
                "grid": grid,
                "type": if accept { 1 } else { 2 },
                "eventId": reminder_id,
                "imei": self.imei(),
            })),
        )
        .await
    }

    /// Swift `fetchReminderRespondersAPI`: `GET /api/board/topic/listResponseEvent`.
    pub async fn fetch_reminder_responders(
        &self,
        reminder_id: &str,
    ) -> Result<JsonObject, ApiError> {
        self.get(
            ApiRequest::new("group_board", "/api/board/topic/listResponseEvent")
                .payload(json!({ "eventId": reminder_id })),
        )
        .await
    }
}

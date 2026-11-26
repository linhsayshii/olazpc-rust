//! "Tin nhắn tự xóa" (official `getAutoDeleteConvers` / `updateAutoDeleteConvers`, Swift
//! `ZaloAPIService+AutoDelete.swift`).

use std::collections::BTreeMap;
use std::fmt;

use olaz_json::{int64, string};
use olaz_net::{ApiRequest, Transport};
use olaz_wire::util::{as_dict_array, pick};
use olaz_wire::{group_conv_id, strip_user_prefix};
use serde_json::{Value, json};

use crate::api::{JsonObject, ZaloApi};
use crate::error::ApiError;
use crate::util::{conv_target, data_object};

/// Official auto-delete choices (ms): 1 giờ, 1 ngày, 7 ngày, 14 ngày, 30 ngày; 0 = off.
pub const AUTO_DELETE_OPTIONS: &[(i64, &str)] = &[
    (0, "Không bao giờ"),
    (3_600_000, "1 giờ"),
    (86_400_000, "1 ngày"),
    (604_800_000, "7 ngày"),
    (1_209_600_000, "14 ngày"),
    (2_592_000_000, "30 ngày"),
];

/// Swift `AutoDelete.label(_:)`: official preset name, or [`auto_delete_remaining`] for custom TTLs.
#[must_use]
pub fn auto_delete_label(ttl_ms: i64) -> String {
    if let Some((_, label)) = AUTO_DELETE_OPTIONS.iter().find(|(ttl, _)| *ttl == ttl_ms) {
        return (*label).to_owned();
    }
    auto_delete_remaining(ttl_ms / 1000)
}

/// Swift `AutoDelete.remaining(_:)`: time left in the largest whole unit.
#[must_use]
pub fn auto_delete_remaining(seconds: i64) -> String {
    let s = seconds.max(0);
    if s >= 86_400 {
        return format!("{} ngày", s / 86_400);
    }
    if s >= 3_600 {
        return format!("{} giờ", s / 3_600);
    }
    if s >= 60 {
        return format!("{} phút", s / 60);
    }
    format!("{} giây", s.max(1))
}

/// Swift `AutoDelete.settings(from:)`: `data.convers = [{destId, isGroup, ttl}]` -> map of
/// normalized conversation id to ttl (ms), with off (`ttl <= 0`) and empty entries dropped.
#[must_use]
pub fn parse_auto_delete_settings(data: &JsonObject) -> BTreeMap<String, i64> {
    let mut out = BTreeMap::new();
    let Some(rows) = as_dict_array(data.get("convers")) else {
        return out;
    };
    for row in rows {
        let dest = string(pick(row, &["destId", "threadId"]));
        let is_group = int64(row.get("isGroup")) == Some(1)
            || row.get("isGroup").and_then(Value::as_bool) == Some(true);
        let ttl = int64(row.get("ttl")).unwrap_or(0);
        if dest.is_empty() || ttl <= 0 {
            continue;
        }
        let id = if is_group {
            group_conv_id(&dest)
        } else {
            strip_user_prefix(&dest)
        };
        if !id.is_empty() {
            out.insert(id, ttl);
        }
    }
    out
}

/// Swift `AutoDelete.updatePayload(convId:ttl:)`: official `updateAutoDeleteConvers` params.
#[must_use]
pub fn build_update_auto_delete_payload(conv_id: &str, ttl: i64) -> Value {
    let (is_group, thread) = conv_target(conv_id);
    json!({
        "threadId": thread,
        "isGroup": if is_group { 1 } else { 0 },
        "ttl": ttl,
        "clientLang": "vi",
    })
}

/// Result of [`ZaloApi::fetch_auto_delete`], carrying metadata for Swift's list diagnostic log.
#[derive(Clone, PartialEq, Eq, Default)]
pub struct AutoDeleteFetchOutcome {
    pub settings: BTreeMap<String, i64>,
    pub data_keys: Vec<String>,
    pub convers_count: i64,
}

impl AutoDeleteFetchOutcome {
    /// Swift `EngineLog`: `autodelete: list keys=[...] convers=<N>`.
    #[must_use]
    pub fn log_line(&self) -> String {
        let keys = self
            .data_keys
            .iter()
            .map(|k| format!("{k:?}"))
            .collect::<Vec<_>>()
            .join(", ");
        format!(
            "autodelete: list keys=[{keys}] convers={}",
            self.convers_count
        )
    }
}

impl fmt::Debug for AutoDeleteFetchOutcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AutoDeleteFetchOutcome")
            .field("settings_count", &self.settings.len())
            .field("data_keys", &self.data_keys)
            .field("convers_count", &self.convers_count)
            .finish()
    }
}

impl<T: Transport> ZaloApi<T> {
    /// Swift `fetchAutoDeleteAPI`: `GET conversation /api/conv/autodelete/getConvers` `{}`.
    pub async fn fetch_auto_delete(&self) -> Result<AutoDeleteFetchOutcome, ApiError> {
        let resp = self
            .get(
                ApiRequest::new("conversation", "/api/conv/autodelete/getConvers")
                    .payload(json!({})),
            )
            .await?;
        let data = data_object(&resp);
        let mut data_keys: Vec<String> = data.keys().cloned().collect();
        data_keys.sort();
        let convers_count = data
            .get("convers")
            .and_then(Value::as_array)
            .map_or(-1, |a| i64::try_from(a.len()).unwrap_or(i64::MAX));
        let settings = parse_auto_delete_settings(&data);
        Ok(AutoDeleteFetchOutcome {
            settings,
            data_keys,
            convers_count,
        })
    }

    /// Swift `updateAutoDeleteAPI`: `POST conversation /api/conv/autodelete/updateConvers`.
    pub async fn update_auto_delete(&self, conv_id: &str, ttl: i64) -> Result<(), ApiError> {
        self.post(
            ApiRequest::new("conversation", "/api/conv/autodelete/updateConvers")
                .payload(build_update_auto_delete_payload(conv_id, ttl)),
        )
        .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use olaz_crypto::{decode_aes, percent_decode};
    use olaz_json::parse_any;
    use olaz_net::http::{RawResponse, RequestSpec};
    use olaz_net::mock::MockTransport;
    use olaz_net::{LoginAccount, NetError, SessionClient, ZaloDomains};

    use super::*;

    const KEY: &[u8; 16] = b"0123456789abcdef";

    fn api_with(
        handler: impl FnMut(&RequestSpec) -> Result<RawResponse, NetError> + Send + 'static,
    ) -> ZaloApi<MockTransport> {
        let client = SessionClient::new(
            MockTransport::from_fn(handler),
            "imei-1".to_owned(),
            "Mac".to_owned(),
        );
        client.update_credentials(
            LoginAccount {
                user_id: "100".to_owned(),
                send2me_id: "999".to_owned(),
                ..LoginAccount::default()
            },
            KEY.to_vec(),
            "sek.1.2".to_owned(),
            Some(ZaloDomains::default()),
        );
        ZaloApi::new(client)
    }

    fn params_of(req: &RequestSpec) -> Value {
        let enc = match req.query_value("params") {
            Some(p) => p.to_owned(),
            None => {
                let body = String::from_utf8(req.body.clone().unwrap_or_default()).unwrap();
                percent_decode(body.strip_prefix("params=").unwrap())
            }
        };
        let plain = decode_aes(KEY, &enc).unwrap();
        parse_any(plain.as_bytes()).unwrap()
    }

    #[test]
    fn auto_delete_label_and_remaining_match_swift() {
        assert_eq!(auto_delete_label(0), "Không bao giờ");
        assert_eq!(auto_delete_label(3_600_000), "1 giờ");
        assert_eq!(auto_delete_label(86_400_000), "1 ngày");
        assert_eq!(auto_delete_label(604_800_000), "7 ngày");
        assert_eq!(auto_delete_label(1_209_600_000), "14 ngày");
        assert_eq!(auto_delete_label(2_592_000_000), "30 ngày");

        // Non-preset durations fall back to remaining().
        assert_eq!(auto_delete_label(7_200_000), "2 giờ");
        assert_eq!(auto_delete_label(172_800_000), "2 ngày");
        assert_eq!(auto_delete_label(300_000), "5 phút");
        assert_eq!(auto_delete_label(45_000), "45 giây");
        assert_eq!(auto_delete_label(500), "1 giây");
        assert_eq!(auto_delete_remaining(-10), "1 giây");
    }

    #[test]
    fn parse_auto_delete_settings_matches_auto_delete_load_fixture() {
        let data = json!({
            "convers": [
                {"destId": "u3000627", "isGroup": 0, "ttl": 3_600_000},
                {"destId": "3000629", "isGroup": 0, "ttl": 7_200_000},
                {"destId": "627", "isGroup": 1, "ttl": 86_400_000},
                {"destId": "3000628", "isGroup": 0, "ttl": 0},
                {"threadId": "g999", "isGroup": true, "ttl": "604800000"},
                {"destId": "", "isGroup": 0, "ttl": 3_600_000},
            ]
        });
        let map = parse_auto_delete_settings(data.as_object().unwrap());
        // Matches Swift `stripUserPrefix` (trim only, preserving leading `u`).
        assert_eq!(map.get("u3000627"), Some(&3_600_000));
        assert_eq!(map.get("3000629"), Some(&7_200_000));
        assert_eq!(map.get("g627"), Some(&86_400_000));
        assert_eq!(map.get("g999"), Some(&604_800_000));
        assert!(!map.contains_key("3000628"));
        assert_eq!(map.len(), 4);
    }

    #[test]
    fn build_update_auto_delete_payload_matches_one_to_one_and_group() {
        assert_eq!(
            build_update_auto_delete_payload("3000628", 3_600_000),
            json!({
                "threadId": "3000628",
                "isGroup": 0,
                "ttl": 3_600_000,
                "clientLang": "vi",
            })
        );
        assert_eq!(
            build_update_auto_delete_payload("g627", 0),
            json!({
                "threadId": "627",
                "isGroup": 1,
                "ttl": 0,
                "clientLang": "vi",
            })
        );
    }

    #[tokio::test]
    async fn fetch_and_update_auto_delete_endpoints_and_logs() {
        let api = api_with(|req| match req.path().as_str() {
            "/api/conv/autodelete/getConvers" => Ok(RawResponse::new(
                200,
                json!({
                    "error_code": 0,
                    "data": {
                        "convers": [
                            {"destId": "u3000627", "isGroup": 0, "ttl": 3_600_000},
                            {"destId": "3000629", "isGroup": 0, "ttl": 7_200_000},
                            {"destId": "627", "isGroup": 1, "ttl": 86_400_000},
                            {"destId": "3000628", "isGroup": 0, "ttl": 0},
                        ]
                    }
                })
                .to_string()
                .into_bytes(),
            )),
            "/api/conv/autodelete/updateConvers" => Ok(RawResponse::new(
                200,
                json!({"error_code": 0, "data": {}})
                    .to_string()
                    .into_bytes(),
            )),
            _ => Ok(RawResponse::new(404, b"{}".to_vec())),
        });

        let out = api.fetch_auto_delete().await.unwrap();
        assert_eq!(out.convers_count, 4);
        assert_eq!(
            out.log_line(),
            r#"autodelete: list keys=["convers"] convers=4"#
        );
        assert_eq!(
            out.settings,
            BTreeMap::from([
                ("3000629".to_owned(), 7_200_000),
                ("g627".to_owned(), 86_400_000),
                ("u3000627".to_owned(), 3_600_000),
            ])
        );
        let reqs = api.client().transport().requests();
        assert_eq!(reqs.len(), 1);
        assert_eq!(reqs[0].method, olaz_net::Method::Get);
        assert_eq!(reqs[0].path(), "/api/conv/autodelete/getConvers");
        assert_eq!(params_of(&reqs[0]), json!({}));

        api.update_auto_delete("3000628", 3_600_000).await.unwrap();
        let reqs = api.client().transport().requests();
        assert_eq!(reqs.len(), 2);
        assert_eq!(reqs[1].method, olaz_net::Method::Post);
        assert_eq!(reqs[1].path(), "/api/conv/autodelete/updateConvers");
        assert_eq!(
            params_of(&reqs[1]),
            json!({
                "threadId": "3000628",
                "isGroup": 0,
                "ttl": 3_600_000,
                "clientLang": "vi",
            })
        );
    }
}

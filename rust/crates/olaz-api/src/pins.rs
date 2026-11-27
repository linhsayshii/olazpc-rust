//! Board pin endpoints and wire helpers (U7: `fetchBoardPins`, `pinBoardMessage`,
//! `unpinBoardTopic`).
//!
//! Mirrors `Sources/Olaz/ZaloRuntime/Protocol/ZaloAPIService.swift` (`// MARK: - Board Pins,
//! Polls, Reminders`) and the wire helpers in `Sources/Olaz/ZaloRuntime/ZaloEngine+Pins.swift`.

use olaz_json::{int64, parse_any, parse_object_str};
use olaz_net::{ApiRequest, Transport};
use olaz_wire::util::as_dict_array;
use olaz_wire::{Kind, clean_group_id, is_group_id, reaction_client_msg_type, strip_user_prefix};
use serde_json::{Map, Value, json};

use crate::api::{JsonObject, ZaloApi};
use crate::error::ApiError;
use crate::util::data_object;

/// Decoded topic `params` object (`ZaloWireParser.boardTopicParams`).
///
/// Accepts either a JSON object or a JSON string encoding an object; anything else yields empty.
#[must_use]
pub fn board_topic_params(row: &JsonObject) -> JsonObject {
    match row.get("params") {
        Some(Value::Object(map)) => map.clone(),
        Some(Value::String(s)) => parse_object_str(s).unwrap_or_default(),
        _ => JsonObject::new(),
    }
}

/// Boxes a `friend_board /api/friendboard/list` response into the uniform `{items, boardVersion,
/// pinLimit}` shape used by group boards (`ZaloWireParser.friendBoardListBox`).
///
/// Handles all four wire shapes seen from Zalo:
/// 1. `data` as JSON string of `{data|topics: [...], version, pinLimit|pin_limit}`
/// 2. `data` as JSON array of topic rows (`boardVersion = 0`, `pinLimit = 0`)
/// 3. `data` as JSON object `{data|topics: [...], version, pinLimit|pin_limit}`
/// 4. `data` as `"[]"` or absent -> empty items, `boardVersion = 0`, `pinLimit = 0`
#[must_use]
pub fn friend_board_list_box(resp: &JsonObject) -> JsonObject {
    let payload = match resp.get("data") {
        Some(Value::String(s)) => parse_any(s.as_bytes()),
        other => other.cloned(),
    };
    if let Some(Value::Array(arr)) = &payload
        && arr.iter().all(Value::is_object)
    {
        let version = int64(resp.get("version")).unwrap_or(0);
        let limit = int64(resp.get("pinLimit").or_else(|| resp.get("pin_limit"))).unwrap_or(0);
        return obj_from_json(json!({
            "items": arr,
            "boardVersion": version,
            "pinLimit": limit,
        }));
    }
    let d = payload
        .as_ref()
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let items: Vec<Value> = as_dict_array(d.get("data"))
        .or_else(|| as_dict_array(d.get("topics")))
        .map(|rows| rows.into_iter().cloned().map(Value::Object).collect())
        .unwrap_or_default();
    let version = int64(d.get("version")).unwrap_or(0);
    let limit = int64(d.get("pinLimit").or_else(|| d.get("pin_limit"))).unwrap_or(0);
    obj_from_json(json!({
        "items": items,
        "boardVersion": version,
        "pinLimit": limit,
    }))
}

/// Official `getTopicDataFromMessage` params for pinning a message (`ZaloWireParser.pinTopicParams`).
#[must_use]
pub fn pin_topic_params(
    msg_id: &str,
    cli_msg_id: &str,
    sender_uid: &str,
    sender_name: &str,
    kind: &Kind,
    title: &str,
) -> JsonObject {
    obj_from_json(json!({
        "client_msg_id": cli_msg_id,
        "global_msg_id": msg_id,
        "senderUid": strip_user_prefix(sender_uid),
        "senderName": sender_name,
        "msg_type": reaction_client_msg_type(kind),
        "title": title,
    }))
}

/// `/api/friendboard/multi_unpin` and `/api/board/unpinv2` topic descriptor
/// (`ZaloWireParser.friendBoardUnpinTopics`).
#[must_use]
pub fn friend_board_unpin_topics(
    topic_ref: &str,
    raw_topic: Option<&JsonObject>,
) -> Vec<JsonObject> {
    let topic_type = raw_topic
        .and_then(|row| int64(row.get("type")))
        .unwrap_or(2);
    vec![obj_from_json(json!({
        "topicId": topic_ref,
        "topicType": topic_type,
    }))]
}

/// Canonical sorted-key JSON string serialization for `params` inside pin topic payloads
/// (matches Swift `JSONSerialization.data(withJSONObject:options:[.sortedKeys])`).
fn canonicalize_sorted(val: &Value) -> Value {
    match val {
        Value::Object(map) => {
            let mut entries: Vec<(&String, &Value)> = map.iter().collect();
            entries.sort_by_key(|(a, _)| *a);
            let mut sorted = Map::with_capacity(entries.len());
            for (k, v) in entries {
                sorted.insert(k.clone(), canonicalize_sorted(v));
            }
            Value::Object(sorted)
        }
        Value::Array(arr) => Value::Array(arr.iter().map(canonicalize_sorted).collect()),
        other => other.clone(),
    }
}

fn serialize_params_sorted(params: &JsonObject) -> String {
    let sorted = canonicalize_sorted(&Value::Object(params.clone()));
    serde_json::to_string(&sorted).unwrap_or_else(|_| "{}".to_owned())
}

fn obj_from_json(val: Value) -> JsonObject {
    match val {
        Value::Object(map) => map,
        _ => Map::new(),
    }
}

impl<T: Transport> ZaloApi<T> {
    /// Fetches the conversation's pinned board in the boxed `{items, boardVersion, pinLimit}`
    /// shape (`ZaloSessionClient.fetchBoardPins`).
    ///
    /// - 1-1: `GET friend_board /api/friendboard/list` `{conversationId, version: 0}`
    /// - Group: `GET group_board /api/board/pin/list` `{groupId, boardVersion: 0, imei}`
    pub async fn fetch_board_pins(&self, conv_id: &str) -> Result<JsonObject, ApiError> {
        if !is_group_id(conv_id) {
            let resp = self
                .get(
                    ApiRequest::new("friend_board", "/api/friendboard/list").payload(json!({
                        "conversationId": strip_user_prefix(conv_id),
                        "version": 0_i64,
                    })),
                )
                .await?;
            return Ok(friend_board_list_box(&resp));
        }

        let grid = clean_group_id(conv_id);
        let resp = self
            .get(
                ApiRequest::new("group_board", "/api/board/pin/list").payload(json!({
                    "groupId": grid,
                    "boardVersion": 0_i64,
                    "imei": self.imei(),
                })),
            )
            .await?;
        let d = data_object(&resp);
        let items: Vec<Value> = as_dict_array(d.get("topics"))
            .or_else(|| as_dict_array(d.get("items")))
            .map(|rows| rows.into_iter().cloned().map(Value::Object).collect())
            .unwrap_or_default();
        let ver = int64(d.get("boardVersion").or_else(|| d.get("version"))).unwrap_or(0);
        let limit = int64(d.get("pinLimit").or_else(|| d.get("pin_limit"))).unwrap_or(0);
        Ok(obj_from_json(json!({
            "items": items,
            "boardVersion": ver,
            "pinLimit": limit,
        })))
    }

    /// Pins a message topic (`ZaloSessionClient.pinBoardMessage`).
    ///
    /// - 1-1: `GET friend_board /api/friendboard/create`
    /// - Group: `POST group_board /api/board/topic/createv2`
    pub async fn pin_board_message(
        &self,
        conv_id: &str,
        params: &JsonObject,
        board_version: i64,
    ) -> Result<JsonObject, ApiError> {
        let params_str = serialize_params_sorted(params);
        if !is_group_id(conv_id) {
            let topic = json!({
                "type": 2_i64,
                "color": -16_777_216_i64,
                "emoji": "",
                "startTime": -1_i64,
                "duration": -1_i64,
                "params": params_str,
                "pinAct": 1_i64,
                "isCreated": true,
                "src": -1_i64,
            });
            return self
                .get(
                    ApiRequest::new("friend_board", "/api/friendboard/create").payload(json!({
                        "conversationId": strip_user_prefix(conv_id),
                        "topic": topic,
                        "version": board_version,
                        "lang": "vi",
                    })),
                )
                .await;
        }

        let grid = clean_group_id(conv_id);
        self.post(
            ApiRequest::new("group_board", "/api/board/topic/createv2").payload(json!({
                "grid": grid,
                "type": 2_i64,
                "color": -16_777_216_i64,
                "emoji": "",
                "startTime": -1_i64,
                "duration": -1_i64,
                "params": params_str,
                "pinAct": 1_i64,
                "repeat": 0_i64,
                "src": -1_i64,
                "imei": self.imei(),
            })),
        )
        .await
    }

    /// Unpins a topic (`ZaloSessionClient.unpinBoardTopic`).
    ///
    /// - 1-1: `GET friend_board /api/friendboard/multi_unpin`
    /// - Group: `GET group_board /api/board/unpinv2`
    pub async fn unpin_board_topic(
        &self,
        conv_id: &str,
        topic_id: &str,
        raw_topic: Option<&JsonObject>,
        board_version: i64,
    ) -> Result<(), ApiError> {
        let topics = friend_board_unpin_topics(topic_id, raw_topic);
        if !is_group_id(conv_id) {
            let topics_val: Vec<Value> = topics.into_iter().map(Value::Object).collect();
            let _ = self
                .get(
                    ApiRequest::new("friend_board", "/api/friendboard/multi_unpin").payload(
                        json!({
                            "conversationId": strip_user_prefix(conv_id),
                            "topics": topics_val,
                            "version": board_version,
                            "lang": "vi",
                        }),
                    ),
                )
                .await?;
            return Ok(());
        }

        let grid = clean_group_id(conv_id);
        let topic_payload = Value::Object(topics.into_iter().next().unwrap_or_default());
        let _ = self
            .get(
                ApiRequest::new("group_board", "/api/board/unpinv2").payload(json!({
                    "grid": grid,
                    "topic": topic_payload,
                    "boardVersion": board_version,
                    "imei": self.imei(),
                })),
            )
            .await?;
        Ok(())
    }

    /// Pins an existing group board topic (`GET group_board /api/board/pinv2`, encrypted
    /// `{grid, topicId, type}` with `g` stripped from `conv_id`).
    pub async fn pin_board_item(
        &self,
        conv_id: &str,
        topic_id: &str,
        topic_type: i64,
    ) -> Result<JsonObject, ApiError> {
        self.pin_board_item_api(conv_id, topic_id, topic_type).await
    }
}

#[cfg(test)]
mod tests {
    use olaz_crypto::{decode_aes, percent_decode};
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
            "imei-pin".to_owned(),
            "Mac".to_owned(),
        );
        client.update_credentials(
            LoginAccount {
                user_id: "100".to_owned(),
                send2me_id: "999".to_owned(),
                ..LoginAccount::default()
            },
            KEY.to_vec(),
            "sek.pin.1".to_owned(),
            Some({
                let mut d = ZaloDomains::default();
                d.service_candidates.insert(
                    "friend_board".to_owned(),
                    vec!["https://friendboard-wpa.chat.zalo.me".to_owned()],
                );
                d
            }),
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
    fn friend_board_list_box_covers_all_shapes() {
        let s = friend_board_list_box(
            json!({"data": r#"{"data":[{"id":1,"type":2}],"version":4,"pinLimit":4}"#})
                .as_object()
                .unwrap(),
        );
        assert_eq!(s.get("boardVersion"), Some(&json!(4)));
        assert_eq!(s.get("pinLimit"), Some(&json!(4)));
        assert_eq!(s.get("items").and_then(Value::as_array).unwrap().len(), 1);

        let a = friend_board_list_box(
            json!({"data": [{"id": "2", "type": 2}]})
                .as_object()
                .unwrap(),
        );
        assert_eq!(a.get("boardVersion"), Some(&json!(0)));
        assert_eq!(a.get("pinLimit"), Some(&json!(0)));
        assert_eq!(a.get("items").and_then(Value::as_array).unwrap().len(), 1);

        let t = friend_board_list_box(
            json!({"data": {"version": 9, "pin_limit": 6, "topics": [{"id": "3", "type": 0}]}})
                .as_object()
                .unwrap(),
        );
        assert_eq!(t.get("boardVersion"), Some(&json!(9)));
        assert_eq!(t.get("pinLimit"), Some(&json!(6)));
        assert_eq!(t.get("items").and_then(Value::as_array).unwrap().len(), 1);

        let empty = friend_board_list_box(json!({"data": "[]"}).as_object().unwrap());
        assert_eq!(empty.get("boardVersion"), Some(&json!(0)));
        assert_eq!(empty.get("pinLimit"), Some(&json!(0)));
        assert!(
            empty
                .get("items")
                .and_then(Value::as_array)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn pin_topic_params_and_unpin_topics_match_swift() {
        let p = pin_topic_params("90401", "c90401", "u2000704", "User", &Kind::Text, "Hi");
        assert_eq!(
            Value::Object(p),
            json!({
                "client_msg_id": "c90401",
                "global_msg_id": "90401",
                "senderUid": "u2000704",
                "senderName": "User",
                "msg_type": 1,
                "title": "Hi",
            })
        );

        let raw = json!({"id": "t1", "type": 0}).as_object().unwrap().clone();
        assert_eq!(
            friend_board_unpin_topics("t1", Some(&raw)),
            vec![obj_from_json(json!({"topicId": "t1", "topicType": 0}))]
        );
        assert_eq!(
            friend_board_unpin_topics("t2", None),
            vec![obj_from_json(json!({"topicId": "t2", "topicType": 2}))]
        );
    }

    #[tokio::test]
    async fn fetch_pin_and_unpin_endpoints_match_wire_shapes() {
        let api =
            api_with(|req| {
                match req.path().as_str() {
            "/api/board/pin/list" => Ok(RawResponse::new(
                200,
                json!({
                    "error_code": 0,
                    "data": {"boardVersion": 7, "pinLimit": 5, "topics": [{"id": "t1", "type": 2}]}
                })
                .to_string()
                .into_bytes(),
            )),
            "/api/friendboard/list" => Ok(RawResponse::new(
                200,
                json!({"error_code": 0, "data": "[]"}).to_string().into_bytes(),
            )),
            "/api/board/topic/createv2" | "/api/friendboard/create" => Ok(RawResponse::new(
                200,
                json!({"error_code": 0, "data": {"id": "t_new"}})
                    .to_string()
                    .into_bytes(),
            )),
            "/api/board/unpinv2" | "/api/friendboard/multi_unpin" => Ok(RawResponse::new(
                200,
                json!({"error_code": 0, "data": {}}).to_string().into_bytes(),
            )),
            _ => Ok(RawResponse::new(404, b"{}".to_vec())),
        }
            });

        let gbox = api.fetch_board_pins("g500701").await.unwrap();
        assert_eq!(gbox.get("boardVersion"), Some(&json!(7)));
        assert_eq!(gbox.get("pinLimit"), Some(&json!(5)));

        let fbox = api.fetch_board_pins("3000701").await.unwrap();
        assert_eq!(fbox.get("boardVersion"), Some(&json!(0)));

        let params = pin_topic_params("901", "c901", "200", "Me", &Kind::Text, "Hello");
        let _ = api.pin_board_message("g500701", &params, 7).await.unwrap();
        let _ = api.pin_board_message("3000701", &params, 2).await.unwrap();

        let raw_note = json!({"id": "t_n", "type": 0}).as_object().unwrap().clone();
        api.unpin_board_topic("g500701", "t_n", Some(&raw_note), 7)
            .await
            .unwrap();
        api.unpin_board_topic("3000701", "t_f", None, 2)
            .await
            .unwrap();

        let reqs = api.client().transport().requests();
        assert_eq!(reqs.len(), 6);
        assert_eq!(reqs[0].method, olaz_net::Method::Get);
        assert_eq!(reqs[0].path(), "/api/board/pin/list");
        assert_eq!(
            params_of(&reqs[0]),
            json!({"groupId": "500701", "boardVersion": 0, "imei": "imei-pin"})
        );
        assert_eq!(reqs[1].method, olaz_net::Method::Get);
        assert_eq!(reqs[1].path(), "/api/friendboard/list");
        assert_eq!(
            params_of(&reqs[1]),
            json!({"conversationId": "3000701", "version": 0})
        );
        assert_eq!(reqs[2].method, olaz_net::Method::Post);
        assert_eq!(reqs[2].path(), "/api/board/topic/createv2");
        assert_eq!(
            params_of(&reqs[2]).get("params"),
            Some(&json!(
                r#"{"client_msg_id":"c901","global_msg_id":"901","msg_type":1,"senderName":"Me","senderUid":"200","title":"Hello"}"#
            ))
        );
        assert_eq!(reqs[3].method, olaz_net::Method::Get);
        assert_eq!(reqs[3].path(), "/api/friendboard/create");
        assert_eq!(params_of(&reqs[3]).get("version"), Some(&json!(2)));
        assert_eq!(reqs[4].method, olaz_net::Method::Get);
        assert_eq!(reqs[4].path(), "/api/board/unpinv2");
        assert_eq!(
            params_of(&reqs[4]).get("topic"),
            Some(&json!({"topicId": "t_n", "topicType": 0}))
        );
        assert_eq!(reqs[5].method, olaz_net::Method::Get);
        assert_eq!(reqs[5].path(), "/api/friendboard/multi_unpin");
        assert_eq!(
            params_of(&reqs[5]).get("topics"),
            Some(&json!([{"topicId": "t_f", "topicType": 2}]))
        );
    }

    #[tokio::test]
    async fn pin_board_item_sends_encrypted_get_pinv2_without_g_prefix() {
        let api = api_with(|_| {
            Ok(RawResponse::new(
                200,
                json!({"error_code": 0, "data": {}})
                    .to_string()
                    .into_bytes(),
            ))
        });
        let _ = api.pin_board_item("g500701", "rem_42", 0).await.unwrap();
        let reqs = api.client().transport().requests();
        assert_eq!(reqs.len(), 1);
        assert_eq!(reqs[0].method, olaz_net::Method::Get);
        assert_eq!(reqs[0].path(), "/api/board/pinv2");
        assert_eq!(
            params_of(&reqs[0]),
            json!({"grid": "500701", "topicId": "rem_42", "type": 0})
        );
    }
}

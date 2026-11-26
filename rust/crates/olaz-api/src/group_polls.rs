//! Group poll and board-pin/unpin API request builders and [`ZaloApi`] methods (U12).
//!
//! Mirrors `ZaloSessionClient`'s poll endpoints (`fetchPollDetail`, `createPollAPI`,
//! `votePollAPI`, `addPollOptionAPI`, `lockPollAPI`, `sharePollAPI`) and the board pin/unpin
//! calls used by polls (`pinBoardItemAPI`, `unpinBoardTopic`, `friendBoardUnpinTopics`).

use olaz_json::string as json_string;
use olaz_net::{ApiRequest, NetError, Transport};
use olaz_wire::{clean_group_id, is_group_id, lossless, strip_user_prefix};
use serde_json::{Value, json};

use crate::api::{JsonObject, ZaloApi};
use crate::error::ApiError;
use crate::messaging::CallSpec;
use crate::util::parse_i64;

/// A new option entry passed to `/api/poll/option/add` (`{"voted": bool, "content": String}`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewPollOptionPayload {
    pub content: String,
    pub voted: bool,
}

/// Parameters for [`build_create_poll_request`] / [`ZaloApi::create_poll_api`].
#[derive(Debug, Clone)]
pub struct CreatePollArgs<'a> {
    pub conv_id: &'a str,
    pub question: &'a str,
    pub options: &'a [String],
    pub expired_time_ms: i64,
    pub allow_multi: bool,
    pub allow_add: bool,
    pub hide_vote_preview: bool,
    pub is_anonymous: bool,
    pub imei: &'a str,
}

/// Swift `let pidVal: Any = Int64(pollId) ?? pollId`.
fn poll_id_value(poll_id: &str) -> Value {
    match parse_i64(poll_id) {
        Some(n) => Value::from(n),
        None => Value::from(poll_id),
    }
}

/// Swift `optionIds.compactMap { Int64($0) }`.
fn compact_i64_ids(ids: &[String]) -> Vec<i64> {
    ids.iter().filter_map(|s| parse_i64(s)).collect()
}

/// `GET /api/poll/detail` on `"group_poll"` (`fetchPollDetail`).
#[must_use]
pub fn build_fetch_poll_detail_request(poll_id: &str, imei: &str) -> CallSpec {
    CallSpec {
        service: "group_poll".to_owned(),
        path: "/api/poll/detail".to_owned(),
        payload: json!({
            "poll_id": poll_id_value(poll_id),
            "imei": imei,
        }),
    }
}

/// `POST /api/poll/create` on `"group_poll"` (`createPollAPI`).
#[must_use]
pub fn build_create_poll_request(args: &CreatePollArgs<'_>) -> CallSpec {
    let grid = clean_group_id(args.conv_id);
    CallSpec {
        service: "group_poll".to_owned(),
        path: "/api/poll/create".to_owned(),
        payload: json!({
            "group_id": grid,
            "question": args.question,
            "options": args.options,
            "expired_time": args.expired_time_ms,
            "allow_multi_choices": args.allow_multi,
            "allow_add_new_option": args.allow_add,
            "is_multi_choice": args.allow_multi,
            "is_add_new_option": args.allow_add,
            "is_hide_vote_preview": args.hide_vote_preview,
            "is_anonymous": args.is_anonymous,
            "poll_type": 0,
            "src": 1,
            "imei": args.imei,
        }),
    }
}

/// Extracts the created poll id from `/api/poll/create` response (`poll_id` / `pollId` / `id`).
#[must_use]
pub fn extract_created_poll_id(resp: &JsonObject) -> String {
    let data_node = resp.get("data").and_then(Value::as_object).unwrap_or(resp);
    let raw = data_node
        .get("poll_id")
        .or_else(|| data_node.get("pollId"))
        .or_else(|| data_node.get("id"));
    json_string(raw).trim().to_owned()
}

/// `GET /api/poll/vote` on `"group_poll"` (`votePollAPI`).
#[must_use]
pub fn build_vote_poll_request(poll_id: &str, option_ids: &[String], imei: &str) -> CallSpec {
    CallSpec {
        service: "group_poll".to_owned(),
        path: "/api/poll/vote".to_owned(),
        payload: json!({
            "poll_id": poll_id_value(poll_id),
            "option_ids": compact_i64_ids(option_ids),
            "imei": imei,
        }),
    }
}

/// `GET /api/poll/option/add` on `"group_poll"` (`addPollOptionAPI` — note no `imei` in Swift).
#[must_use]
pub fn build_add_poll_option_request(
    poll_id: &str,
    new_options: &[NewPollOptionPayload],
    voted_ids: &[String],
) -> CallSpec {
    let options_val: Vec<Value> = new_options
        .iter()
        .map(|opt| {
            json!({
                "voted": opt.voted,
                "content": opt.content,
            })
        })
        .collect();
    CallSpec {
        service: "group_poll".to_owned(),
        path: "/api/poll/option/add".to_owned(),
        payload: json!({
            "poll_id": poll_id_value(poll_id),
            "new_options": options_val,
            "voted_option_ids": compact_i64_ids(voted_ids),
        }),
    }
}

/// `POST /api/poll/end` on `"group_poll"` (`lockPollAPI`).
#[must_use]
pub fn build_lock_poll_request(poll_id: &str, imei: &str) -> CallSpec {
    CallSpec {
        service: "group_poll".to_owned(),
        path: "/api/poll/end".to_owned(),
        payload: json!({
            "poll_id": poll_id_value(poll_id),
            "imei": imei,
        }),
    }
}

/// `POST /api/poll/share` on `"group_poll"` (`sharePollAPI`).
#[must_use]
pub fn build_share_poll_request(poll_id: &str, imei: &str) -> CallSpec {
    CallSpec {
        service: "group_poll".to_owned(),
        path: "/api/poll/share".to_owned(),
        payload: json!({
            "poll_id": poll_id_value(poll_id),
            "imei": imei,
        }),
    }
}

/// `GET /api/board/pinv2` on `"group_board"` (`ZaloSessionClient.buildPinBoardItemRequest`).
#[must_use]
pub fn build_pin_board_item_request(
    group_id: &str,
    topic_id: &str,
    topic_type: i64,
) -> Option<CallSpec> {
    let clean_grid = clean_group_id(group_id);
    let clean_topic = topic_id.trim();
    if clean_grid.is_empty() || clean_grid == "0" || clean_topic.is_empty() {
        return None;
    }
    Some(CallSpec {
        service: "group_board".to_owned(),
        path: "/api/board/pinv2".to_owned(),
        payload: json!({
            "grid": clean_grid,
            "topicId": clean_topic,
            "type": topic_type,
        }),
    })
}

/// Port of `ZaloWireParser.friendBoardUnpinTopics(ref:rawTopic:)`:
/// returns `[{"topicId": ref, "topicType": type}]` defaulting `topicType` to `2`.
#[must_use]
pub fn friend_board_unpin_topics(ref_id: &str, raw_topic: Option<&JsonObject>) -> Vec<Value> {
    let topic_type = raw_topic
        .and_then(|t| lossless::int64(t.get("type")))
        .unwrap_or(2);
    vec![json!({
        "topicId": ref_id,
        "topicType": topic_type,
    })]
}

/// Pure request builder for `ZaloSessionClient.unpinBoardTopic`:
/// - Group: `GET /api/board/unpinv2` on `"group_board"`
/// - 1-1: `GET /api/friendboard/multi_unpin` on `"friend_board"`
#[must_use]
pub fn build_unpin_board_topic_request(
    conv_id: &str,
    topic_id: &str,
    raw_topic: Option<&JsonObject>,
    board_version: i64,
    imei: &str,
) -> CallSpec {
    let topics = friend_board_unpin_topics(topic_id, raw_topic);
    if !is_group_id(conv_id) {
        return CallSpec {
            service: "friend_board".to_owned(),
            path: "/api/friendboard/multi_unpin".to_owned(),
            payload: json!({
                "conversationId": strip_user_prefix(conv_id),
                "topics": topics,
                "version": board_version,
                "lang": "vi",
            }),
        };
    }
    let grid = clean_group_id(conv_id);
    let topic_payload = topics.into_iter().next().unwrap_or_else(|| {
        json!({
            "topicId": topic_id,
            "topicType": 2,
        })
    });
    CallSpec {
        service: "group_board".to_owned(),
        path: "/api/board/unpinv2".to_owned(),
        payload: json!({
            "grid": grid,
            "topic": topic_payload,
            "boardVersion": board_version,
            "imei": imei,
        }),
    }
}

impl<T: Transport> ZaloApi<T> {
    pub async fn fetch_poll_detail(&self, poll_id: &str) -> Result<JsonObject, ApiError> {
        let spec = build_fetch_poll_detail_request(poll_id, &self.imei());
        self.get(ApiRequest::new(spec.service, spec.path).payload(spec.payload))
            .await
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "mirrors ZaloSessionClient.createPollAPI parameter list 1:1"
    )]
    pub async fn create_poll_api(
        &self,
        conv_id: &str,
        question: &str,
        options: &[String],
        expired_time_ms: i64,
        allow_multi: bool,
        allow_add: bool,
        hide_vote_preview: bool,
        is_anonymous: bool,
    ) -> Result<JsonObject, ApiError> {
        let imei = self.imei();
        let spec = build_create_poll_request(&CreatePollArgs {
            conv_id,
            question,
            options,
            expired_time_ms,
            allow_multi,
            allow_add,
            hide_vote_preview,
            is_anonymous,
            imei: &imei,
        });
        self.post(ApiRequest::new(spec.service, spec.path).payload(spec.payload))
            .await
    }

    pub async fn vote_poll_api(
        &self,
        poll_id: &str,
        option_ids: &[String],
    ) -> Result<JsonObject, ApiError> {
        let spec = build_vote_poll_request(poll_id, option_ids, &self.imei());
        self.get(ApiRequest::new(spec.service, spec.path).payload(spec.payload))
            .await
    }

    pub async fn add_poll_option_api(
        &self,
        poll_id: &str,
        new_options: &[NewPollOptionPayload],
        voted_ids: &[String],
    ) -> Result<JsonObject, ApiError> {
        let spec = build_add_poll_option_request(poll_id, new_options, voted_ids);
        self.get(ApiRequest::new(spec.service, spec.path).payload(spec.payload))
            .await
    }

    pub async fn lock_poll_api(&self, poll_id: &str) -> Result<JsonObject, ApiError> {
        let spec = build_lock_poll_request(poll_id, &self.imei());
        self.post(ApiRequest::new(spec.service, spec.path).payload(spec.payload))
            .await
    }

    pub async fn share_poll_api(&self, poll_id: &str) -> Result<JsonObject, ApiError> {
        let spec = build_share_poll_request(poll_id, &self.imei());
        self.post(ApiRequest::new(spec.service, spec.path).payload(spec.payload))
            .await
    }

    pub async fn pin_board_item_api(
        &self,
        group_id: &str,
        topic_id: &str,
        topic_type: i64,
    ) -> Result<JsonObject, ApiError> {
        let Some(spec) = build_pin_board_item_request(group_id, topic_id, topic_type) else {
            return Err(ApiError::Net(NetError::InvalidUrl("pinv2".to_owned())));
        };
        self.get(ApiRequest::new(spec.service, spec.path).payload(spec.payload))
            .await
    }

    pub async fn unpin_board_topic_api(
        &self,
        conv_id: &str,
        topic_id: &str,
        raw_topic: Option<&JsonObject>,
        board_version: i64,
    ) -> Result<JsonObject, ApiError> {
        let spec = build_unpin_board_topic_request(
            conv_id,
            topic_id,
            raw_topic,
            board_version,
            &self.imei(),
        );
        self.get(ApiRequest::new(spec.service, spec.path).payload(spec.payload))
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn poll_detail_vote_add_lock_share_builders_match_swift_keys() {
        let detail_num = build_fetch_poll_detail_request("9101", "imei-1");
        assert_eq!(detail_num.service, "group_poll");
        assert_eq!(detail_num.path, "/api/poll/detail");
        assert_eq!(
            detail_num.payload,
            json!({"poll_id": 9101, "imei": "imei-1"})
        );

        let detail_str = build_fetch_poll_detail_request("poll_custom", "imei-1");
        assert_eq!(
            detail_str.payload,
            json!({"poll_id": "poll_custom", "imei": "imei-1"})
        );

        let vote = build_vote_poll_request(
            "9101",
            &["1".to_owned(), "bad".to_owned(), "2".to_owned()],
            "imei-1",
        );
        assert_eq!(vote.path, "/api/poll/vote");
        assert_eq!(
            vote.payload,
            json!({"poll_id": 9101, "option_ids": [1, 2], "imei": "imei-1"})
        );

        let add = build_add_poll_option_request(
            "9101",
            &[NewPollOptionPayload {
                content: "Bún chả".to_owned(),
                voted: true,
            }],
            &["1".to_owned()],
        );
        assert_eq!(add.path, "/api/poll/option/add");
        assert_eq!(
            add.payload,
            json!({
                "poll_id": 9101,
                "new_options": [{"voted": true, "content": "Bún chả"}],
                "voted_option_ids": [1],
            })
        );

        let lock = build_lock_poll_request("9101", "imei-1");
        assert_eq!(lock.path, "/api/poll/end");
        assert_eq!(lock.payload, json!({"poll_id": 9101, "imei": "imei-1"}));

        let share = build_share_poll_request("9101", "imei-1");
        assert_eq!(share.path, "/api/poll/share");
        assert_eq!(share.payload, json!({"poll_id": 9101, "imei": "imei-1"}));
    }

    #[test]
    fn create_poll_and_extract_id_match_swift() {
        let opts = vec!["Phở".to_owned(), "Bún".to_owned()];
        let spec = build_create_poll_request(&CreatePollArgs {
            conv_id: "g501201",
            question: "Ăn gì?",
            options: &opts,
            expired_time_ms: 1_700_086_400_000,
            allow_multi: true,
            allow_add: false,
            hide_vote_preview: true,
            is_anonymous: false,
            imei: "imei-1",
        });
        assert_eq!(spec.service, "group_poll");
        assert_eq!(spec.path, "/api/poll/create");
        assert_eq!(
            spec.payload,
            json!({
                "group_id": "501201",
                "question": "Ăn gì?",
                "options": ["Phở", "Bún"],
                "expired_time": 1_700_086_400_000_i64,
                "allow_multi_choices": true,
                "allow_add_new_option": false,
                "is_multi_choice": true,
                "is_add_new_option": false,
                "is_hide_vote_preview": true,
                "is_anonymous": false,
                "poll_type": 0,
                "src": 1,
                "imei": "imei-1",
            })
        );

        assert_eq!(
            extract_created_poll_id(json!({"data": {"poll_id": 9991}}).as_object().unwrap()),
            "9991"
        );
        assert_eq!(
            extract_created_poll_id(json!({"data": {"pollId": " 9992 "}}).as_object().unwrap()),
            "9992"
        );
        assert_eq!(
            extract_created_poll_id(json!({"id": "9993"}).as_object().unwrap()),
            "9993"
        );
        assert_eq!(
            extract_created_poll_id(json!({"data": {}}).as_object().unwrap()),
            ""
        );
    }

    #[test]
    fn pin_and_unpin_board_builders_match_group_and_1_1() {
        assert!(build_pin_board_item_request("", "9801", 3).is_none());
        assert!(build_pin_board_item_request("g0", "9801", 3).is_none());
        assert!(build_pin_board_item_request("g500801", "   ", 3).is_none());

        let pin = build_pin_board_item_request("g500801", " 9801 ", 3).unwrap();
        assert_eq!(pin.service, "group_board");
        assert_eq!(pin.path, "/api/board/pinv2");
        assert_eq!(
            pin.payload,
            json!({"grid": "500801", "topicId": "9801", "type": 3})
        );

        let raw_poll = json!({"id": "9901", "type": 3});
        let grp_unpin =
            build_unpin_board_topic_request("g500901", "9901", raw_poll.as_object(), 3, "imei-1");
        assert_eq!(grp_unpin.service, "group_board");
        assert_eq!(grp_unpin.path, "/api/board/unpinv2");
        assert_eq!(
            grp_unpin.payload,
            json!({
                "grid": "500901",
                "topic": {"topicId": "9901", "topicType": 3},
                "boardVersion": 3,
                "imei": "imei-1",
            })
        );

        let dm_unpin = build_unpin_board_topic_request(" 3001001 ", "9902", None, 0, "imei-1");
        assert_eq!(dm_unpin.service, "friend_board");
        assert_eq!(dm_unpin.path, "/api/friendboard/multi_unpin");
        assert_eq!(
            dm_unpin.payload,
            json!({
                "conversationId": "3001001",
                "topics": [{"topicId": "9902", "topicType": 2}],
                "version": 0,
                "lang": "vi",
            })
        );
    }
}

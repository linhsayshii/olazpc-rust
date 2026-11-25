//! Ports of the Swift tests that touch `ZaloAPIService` plus mock-transport payload/parse tests
//! for every ported method. Payloads are read back by decrypting the `params` the client sent.

use olaz_crypto::{decode_aes, percent_decode};
use olaz_json::{parse_any, parse_object_str};
use olaz_net::http::{RawResponse, RequestSpec};
use olaz_net::mock::MockTransport;
use olaz_net::{LoginAccount, NetError, SessionClient, ZaloDomains, url_encode};
use serde_json::{Map, Value, json};

use crate::*;

const KEY: &[u8; 16] = b"0123456789abcdef";
const NOW_MS: i64 = 1_700_000_000_123;
const INITIAL_QUEUES_B64: &str = "eyIxIjp7ImlkcyI6W10sImxhc3RJZCI6IjEifSwiMiI6eyJpZHMiOltdLCJsYXN0SWQiOiIxIn0sIjMiOnsiaWRzIjpbXSwibGFzdElkIjoiMSJ9fQ==";

type Reply = Result<RawResponse, NetError>;

fn reply(value: &Value) -> Reply {
    Ok(RawResponse::new(200, value.to_string().into_bytes()))
}

fn ok(data: Value) -> Reply {
    reply(&json!({"error_code": 0, "data": data}))
}

fn err(code: i64) -> Reply {
    reply(&json!({"error_code": code, "error_message": "x"}))
}

fn account() -> LoginAccount {
    LoginAccount {
        user_id: "100".to_owned(),
        send2me_id: "999".to_owned(),
        ..LoginAccount::default()
    }
}

fn api_with(handler: impl FnMut(&RequestSpec) -> Reply + Send + 'static) -> ZaloApi<MockTransport> {
    let client = SessionClient::new(
        MockTransport::from_fn(handler),
        "imei-1".to_owned(),
        "Mac".to_owned(),
    )
    .with_clock(|| NOW_MS);
    client.update_credentials(
        account(),
        KEY.to_vec(),
        "sek.1.2".to_owned(),
        Some(ZaloDomains::default()),
    );
    ZaloApi::new(client)
}

fn api_ok() -> ZaloApi<MockTransport> {
    api_with(|_| ok(json!({})))
}

/// Decrypts the `params` of a GET (query) or POST (form body) request.
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

fn sent(api: &ZaloApi<MockTransport>) -> Vec<RequestSpec> {
    api.client().transport().requests()
}

fn last(api: &ZaloApi<MockTransport>) -> RequestSpec {
    sent(api).pop().unwrap()
}

/// The request URL starts with one of the service's candidate hosts.
fn assert_service(api: &ZaloApi<MockTransport>, req: &RequestSpec, service: &str) {
    let hosts = api.client().domains().candidates(service);
    assert!(
        hosts.iter().any(|h| req.url.starts_with(h.as_str())),
        "{} not on a {service} host",
        req.path()
    );
}

fn parsed_json_string(v: &Value) -> Value {
    parse_any(v.as_str().unwrap().as_bytes()).unwrap()
}

fn last_params_string(api: &ZaloApi<MockTransport>, key: &str) -> String {
    params_of(&last(api))[key].as_str().unwrap().to_owned()
}

fn strs(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| (*s).to_owned()).collect()
}

// ---------------------------------------------------------------- PollState

#[test]
fn poll_state_encodes_and_ignores_socket_queue_15() {
    // Swift NativeProtocolTests.pollStateEncodesAndIgnoresSocketQueue15
    let mut state = PollState::default();
    let initial = state.encoded_params();
    assert!(initial.starts_with("1,1,"));
    let node = parse_object_str(
        r#"{"lastActionId":"42","lastActionIdOther":"43","more":1,
            "queueStatus":{"1":{"lastId":"100","ids":["a"]},"15":{"lastId":"999","ids":["skip"]}}}"#,
    )
    .unwrap();
    let (more, reset) = state.apply_response(&node);
    assert!(more);
    assert!(!reset);
    assert_eq!(state.last_action_id, "42");
    assert_eq!(state.last_action_id_other, "43");
    assert_eq!(state.queues["1"].last_id, "100");
    assert_eq!(state.queues["1"].ids, vec!["a".to_owned()]);
    assert!(!state.queues.contains_key("15"));
}

#[test]
fn poll_state_encoded_params_match_swift_golden() {
    // Produced by running Swift JSONSerialization(.sortedKeys) + base64EncodedString.
    let mut state = PollState::default();
    assert_eq!(
        state.encoded_params(),
        format!("1,1,{}", url_encode(&format!("{INITIAL_QUEUES_B64},1")))
    );
    let node = parse_object_str(r#"{"queueStatus":{"1":{"lastId":"100","ids":["a"]}}}"#).unwrap();
    state.apply_response(&node);
    let b64b = "eyIxIjp7ImlkcyI6WyJhIl0sImxhc3RJZCI6IjEwMCJ9LCIyIjp7ImlkcyI6W10sImxhc3RJZCI6IjEifSwiMyI6eyJpZHMiOltdLCJsYXN0SWQiOiIxIn19";
    assert_eq!(
        state.encoded_params(),
        format!("1,1,{}", url_encode(&format!("{b64b},1")))
    );
}

#[test]
fn poll_state_reset_and_empty_last_id_fallback() {
    let mut state = PollState {
        last_action_id: "9".to_owned(),
        ..PollState::default()
    };
    state.queues.get_mut("2").unwrap().last_id = "55".to_owned();
    // Empty lastId keeps the stored one; empty ids are dropped.
    let node = parse_object_str(r#"{"queueStatus":{"2":{"lastId":"","ids":["x",""]}}}"#).unwrap();
    assert_eq!(state.apply_response(&node), (false, false));
    assert_eq!(state.queues["2"].last_id, "55");
    assert_eq!(state.queues["2"].ids, vec!["x".to_owned()]);
    // resetLastActionId as number 1 resets everything.
    let reset = parse_object_str(r#"{"resetLastActionId":1,"more":1}"#).unwrap();
    assert_eq!(state.apply_response(&reset), (true, true));
    assert_eq!(state, PollState::default());
}

#[test]
fn poll_state_serde_uses_swift_codable_keys() {
    let v = serde_json::to_value(PollState::default()).unwrap();
    assert_eq!(v["lastActionId"], "1");
    assert_eq!(v["lastActionIdOther"], "1");
    assert_eq!(v["queues"]["3"], json!({"lastId": "1", "ids": []}));
}

#[tokio::test]
async fn fetch_chat_from_polling_builds_url_and_advances_state() {
    let api = api_with(|_| {
        ok(json!({"lastActionId": "42", "more": 1,
            "queueStatus": {"1": {"lastId": "100", "ids": ["a"]}, "15": {"lastId": "9"}}}))
    });
    let out = api
        .fetch_chat_from_polling(&PollState::default())
        .await
        .unwrap();
    assert!(out.more);
    assert_eq!(out.next_state.last_action_id, "42");
    assert_eq!(out.next_state.queues["1"].last_id, "100");
    assert!(!out.next_state.queues.contains_key("15"));
    assert!(out.response.contains_key("data"));
    let req = last(&api);
    assert!(
        req.url
            .starts_with("https://p4-msg-chat.zaloapp.com/?zpw_ver=694&zpw_type=23&params=")
    );
    assert_eq!(req.query_value("ts"), Some("1700000000"));
    assert_eq!(
        req.query_value("params"),
        Some(format!("1,1,{INITIAL_QUEUES_B64},1").as_str())
    );
    assert_eq!(req.timeout, Some(std::time::Duration::from_secs(12)));
}

// ---------------------------------------------------------------- builders (Swift ports)

#[test]
fn build_recall_message_request_covers_all_four_routes() {
    // Swift FeatureFixesTests.buildRecallMessageRequestCoversAllFourRoutes
    let normal11 = build_recall_message_request(&RecallParams::new(
        "200", "9001", "7001", 888, false, "imei-1",
    ));
    assert_eq!(normal11.service, "chat");
    assert_eq!(normal11.path, "/api/message/undo");
    assert_eq!(normal11.payload["toid"], "200");
    assert_eq!(normal11.payload["msgId"], "9001");
    assert_eq!(normal11.payload["cliMsgIdUndo"], "7001");
    assert_eq!(normal11.payload["clientId"], 888);

    let mut p = RecallParams::new("g555", "9002", "7002", 889, false, "imei-1");
    p.visibility = 1;
    let normal_group = build_recall_message_request(&p);
    assert_eq!(normal_group.service, "group");
    assert_eq!(normal_group.path, "/api/group/undomsg");
    assert_eq!(normal_group.payload["grid"], "555");
    assert_eq!(normal_group.payload["visibility"], 1);
    assert_eq!(normal_group.payload["imei"], "imei-1");

    let e2ee11 = build_recall_message_request(&RecallParams::new(
        "200", "9003", "7003", 890, true, "imei-1",
    ));
    assert_eq!(e2ee11.service, "chat_e2e");
    assert_eq!(e2ee11.path, "/api/e2ee/pc/message/undo");
    assert_eq!(e2ee11.payload["destType"], 3);
    assert_eq!(e2ee11.payload["toid"], "200");

    let e2ee_group = build_recall_message_request(&RecallParams::new(
        "g555", "9004", "7004", 891, true, "imei-1",
    ));
    assert_eq!(e2ee_group.service, "group_e2e");
    assert_eq!(e2ee_group.path, "/api/e2ee/pc/group/undoMsg");
    assert_eq!(e2ee_group.payload["grid"], "555");

    // Empty cliMsgId falls back to msgId; the exact key set matches Swift.
    let fallback =
        build_recall_message_request(&RecallParams::new("200", "9001", "", 1, false, "imei-1"));
    assert_eq!(
        fallback.payload,
        json!({"msgId": "9001", "clientId": 1, "cliMsgIdUndo": "9001", "toid": "200"})
    );
}

#[test]
fn extract_e2ee_send_response_reads_min_global_msg_id_and_timestamp() {
    // Swift FeatureFixesTests.extractE2EESendResponseReadsMinGlobalMsgIdAndTimestamp
    let direct = parse_object_str(
        r#"{"error_code":0,"data":{"clientId":"1795343225629","minGlobalMsgId":"8517564749999","ts":1795343225631}}"#,
    )
    .unwrap();
    assert_eq!(
        extract_e2ee_send_response(&direct),
        ("8517564749999".to_owned(), Some(1_795_343_225_631))
    );
    let nested =
        parse_object_str(r#"{"data":{"data":{"minGlobalMsgId":"8517564750001","ts":1795343300}}}"#)
            .unwrap();
    assert_eq!(
        extract_e2ee_send_response(&nested),
        ("8517564750001".to_owned(), Some(1_795_343_300_000))
    );
}

#[test]
fn extract_e2ee_send_response_edge_shapes() {
    let skip_zero =
        parse_object_str(r#"{"data":{"minGlobalMsgId":"0","msgId":" 77 ","sendDttm":5}}"#).unwrap();
    assert_eq!(
        extract_e2ee_send_response(&skip_zero),
        ("77".to_owned(), Some(5000))
    );
    let array = parse_object_str(r#"{"data":{"data":[{"globalMsgId":"42"}]}}"#).unwrap();
    assert_eq!(extract_e2ee_send_response(&array), ("42".to_owned(), None));
    let root = parse_object_str(r#"{"msgId":"9","ts":0}"#).unwrap();
    assert_eq!(extract_e2ee_send_response(&root), ("9".to_owned(), None));
    assert_eq!(
        extract_e2ee_send_response(&Map::new()),
        (String::new(), None)
    );
}

#[test]
fn build_reaction_request_formatting_and_routes() {
    // Swift FeatureFixesTests.buildReactionRequestFormattingAndRoutes
    let photo = build_reaction_request(&ReactionParams {
        conv_id: "200",
        msg_id: "88001",
        cli_msg_id: "17001",
        r_icon: "/-heart",
        r_type: 5,
        msg_type: 32,
        client_id: 9991,
        imei: "imei-1",
    });
    assert_eq!(photo.call.service, "reaction");
    assert_eq!(photo.call.path, "/api/message/reaction");
    assert_eq!(photo.client_id, 9991);
    assert_eq!(photo.call.payload["toid"], "200");
    let msg_str = photo.call.payload["react_list"][0]["message"]
        .as_str()
        .unwrap();
    assert!(msg_str.contains("/-heart"));
    assert!(!msg_str.contains("\\/-heart"));
    // Golden from Swift JSONSerialization([.withoutEscapingSlashes, .sortedKeys]).
    assert_eq!(
        msg_str,
        r#"{"rIcon":"/-heart","rMsg":[{"cMsgID":17001,"gMsgID":88001,"msgType":32}],"rType":5,"source":6}"#
    );
    assert_eq!(photo.call.payload["react_list"][0]["clientId"], 9991);
    let inner = parsed_json_string(&photo.call.payload["react_list"][0]["message"]);
    assert_eq!(inner["rMsg"][0]["gMsgID"], 88001);
    assert_eq!(inner["rMsg"][0]["cMsgID"], 17001);
    assert_eq!(inner["rMsg"][0]["msgType"], 32);

    let group = build_reaction_request(&ReactionParams {
        conv_id: "g555",
        msg_id: "99001",
        cli_msg_id: "27001",
        r_icon: "/-strong",
        r_type: 3,
        msg_type: 46,
        client_id: 9992,
        imei: "imei-g",
    });
    assert_eq!(group.call.path, "/api/group/reaction");
    assert_eq!(group.call.payload["grid"], "555");
    assert_eq!(group.call.payload["imei"], "imei-g");
    assert!(group.call.payload.get("toid").is_none());
    let g_inner = parsed_json_string(&group.call.payload["react_list"][0]["message"]);
    assert_eq!(g_inner["rMsg"][0]["msgType"], 46);

    // Non-numeric msg id stays a string; unparsable cli id falls back to the msg id, then clientId.
    let odd = build_reaction_request(&ReactionParams {
        conv_id: "200",
        msg_id: "abc",
        cli_msg_id: "zzz",
        r_icon: "/-ok",
        r_type: 1,
        msg_type: 1,
        client_id: 5,
        imei: "i",
    });
    let odd_inner = parsed_json_string(&odd.call.payload["react_list"][0]["message"]);
    assert_eq!(odd_inner["rMsg"][0]["gMsgID"], "abc");
    assert_eq!(odd_inner["rMsg"][0]["cMsgID"], 5);
}

#[test]
fn remove_reaction_wire_format() {
    // Swift FeatureFixesTests.removeReactionWireFormat
    let spec = build_reaction_request(&ReactionParams {
        conv_id: "200",
        msg_id: "88001",
        cli_msg_id: "17001",
        r_icon: "",
        r_type: -1,
        msg_type: 1,
        client_id: 1,
        imei: "i",
    });
    let inner = parsed_json_string(&spec.call.payload["react_list"][0]["message"]);
    assert_eq!(inner["rType"], -1);
    assert_eq!(inner["rIcon"], "");
}

#[test]
fn build_e2ee_ext_json_matches_swift_sorted_golden() {
    assert_eq!(
        build_e2ee_ext_json(3001, 9002, 1, 1),
        r#"{"compat_version":1,"iid":3001,"sender_iid":9002,"version":1}"#
    );
}

#[test]
fn e2ee_list_param_entry_and_request_payload() {
    // Swift NativeProtocolTests.e2eeDomainsListParamEntryAndAPIServiceMockSend (builder part)
    let mut p = E2eeListParams::new("222", 0, 1_795_000_000_123, "IMEI_TEST", 3001, 9002);
    p.extra_fields
        .insert("message".to_owned(), Value::from("AzM_CIPHER"));
    let entry = build_e2ee_list_param_entry(&p);
    assert_eq!(entry["toId"], "222");
    assert_eq!(entry["platform"], 0);
    assert_eq!(entry["clientId"], 1_795_000_000_123_i64);
    assert_eq!(entry["imei"], "IMEI_TEST");
    assert_eq!(entry["ttl"], 0);
    assert_eq!(entry["message"], "AzM_CIPHER");
    let ext = parsed_json_string(&entry["e2eeExt"]);
    assert_eq!(
        ext,
        json!({"version": 1, "compat_version": 1, "iid": 3001, "sender_iid": 9002})
    );

    let one = build_e2ee_message_request_payload(
        "sms",
        "222",
        false,
        1_795_000_000_123,
        std::slice::from_ref(&entry),
        3,
    );
    assert_eq!(one.service, "chat_e2e");
    assert_eq!(one.path, "/api/e2ee/pc/message/sms");
    assert_eq!(one.payload["destType"], 3);
    assert_eq!(one.payload["threadId"], "222");
    assert_eq!(one.payload["clientId"], 1_795_000_000_123_i64);
    let list = parsed_json_string(&one.payload["listParams"]);
    assert_eq!(list.as_array().unwrap().len(), 1);
    assert_eq!(list[0]["message"], "AzM_CIPHER");

    let grp = build_e2ee_message_request_payload(
        "sms",
        "g777",
        true,
        1_795_000_000_123,
        std::slice::from_ref(&entry),
        3,
    );
    assert_eq!(grp.service, "group_e2e");
    assert_eq!(grp.path, "/api/e2ee/pc/group/sms");
    assert_eq!(grp.payload["clientId"], 1_795_000_000_123_i64);
    assert_eq!(grp.payload["message"], "AzM_CIPHER");
    assert_eq!(grp.payload["toId"], "222");

    // Legacy key + extra override + empty group list.
    let mut legacy = E2eeListParams::new("u9", 1, 1, "i", 1, 2);
    legacy.use_legacy_e2ee_key = true;
    legacy.ttl = 5;
    legacy.extra_fields.insert("ttl".to_owned(), Value::from(7));
    let e = build_e2ee_list_param_entry(&legacy);
    assert!(e.contains_key("e2ee") && !e.contains_key("e2eeExt"));
    assert_eq!(e["ttl"], 7);
    let empty = build_e2ee_message_request_payload("sms", "g1", true, 4, &[], 3);
    assert_eq!(empty.payload, json!({"clientId": 4}));
}

#[tokio::test]
async fn send_e2ee_message_posts_payload_and_reads_server_id() {
    // Swift NativeProtocolTests.e2eeDomainsListParamEntryAndAPIServiceMockSend (HTTP part)
    let api = api_with(|_| ok(json!({"msgId": "8800112233"})));
    let mut p = E2eeListParams::new("222", 0, 1_795_000_000_123, "IMEI_TEST", 3001, 9002);
    p.extra_fields
        .insert("message".to_owned(), Value::from("AzM_CIPHER"));
    let entry = build_e2ee_list_param_entry(&p);
    let res = api
        .send_e2ee_message(
            "sms",
            "222",
            false,
            1_795_000_000_123,
            std::slice::from_ref(&entry),
            3,
        )
        .await
        .unwrap();
    assert_eq!(res.msg_id, "8800112233");
    assert_eq!(res.cli_msg_id, "1795000000123");
    let req = last(&api);
    assert_eq!(req.path(), "/api/e2ee/pc/message/sms");
    assert_service(&api, &req, "chat_e2e");
    let payload = params_of(&req);
    assert_eq!(payload["destType"], 3);
    assert_eq!(payload["threadId"], "222");
    assert_eq!(payload["clientId"], 1_795_000_000_123_i64);
    let sent_list = parsed_json_string(&payload["listParams"]);
    assert_eq!(sent_list[0]["e2eeExt"], entry["e2eeExt"]);
}

#[tokio::test]
async fn send_e2ee_message_without_server_id_falls_back_to_client_id() {
    let api = api_ok();
    let res = api
        .send_e2ee_message("sms", "g777", true, 55, &[Map::new()], 3)
        .await
        .unwrap();
    assert_eq!(res.msg_id, "55");
    assert_eq!(res.ts_ms, NOW_MS);
    let req = last(&api);
    assert_eq!(req.path(), "/api/e2ee/pc/group/sms");
    assert_service(&api, &req, "group_e2e");
}

// ---------------------------------------------------------------- profiles

#[tokio::test]
async fn fetch_profiles_sanitizes_falls_back_to_get_profiles_v2_and_splits_on_114() {
    // Swift NativeProtocolTests.fetchProfilesSanitizesFallsBackToGetProfilesV2AndSplitsOn114
    let api = api_with(|req| {
        let uids: Vec<String> = params_of(req)["friend_pversion_map"]
            .as_array()
            .map(|a| a.iter().map(|v| v.as_str().unwrap().to_owned()).collect())
            .unwrap_or_default();
        if uids.iter().any(|u| u == "999_0") {
            return err(114);
        }
        match req.path().as_str() {
            "/api/social/group/members" => err(114),
            "/api/social/friend/getprofiles/v2" => {
                let mut changed = Map::new();
                for pver in &uids {
                    let uid = pver.split('_').next().unwrap();
                    changed.insert(
                        uid.to_owned(),
                        json!({"userId": uid, "displayName": format!("User {uid}"),
                               "avatar": format!("https://ava.example/{uid}.jpg")}),
                    );
                }
                ok(json!({"changed_profiles": changed, "unchanged_profiles": {}}))
            }
            _ => Ok(RawResponse::new(404, b"{}".to_vec())),
        }
    });

    // 1. All-invalid uids short-circuit without network calls.
    let empty = api
        .fetch_profiles(&strs(&["0", "-1", "g123", "stranger_box", "2000.noise=="]))
        .await
        .unwrap();
    assert!(empty.is_empty());
    assert!(sent(&api).is_empty());

    // 2. Fallback + binary split drops only the poison uid 999.
    let res = api
        .fetch_profiles(&strs(&["u111", "222_0", "999", "333", "0", "g888", "222"]))
        .await
        .unwrap();
    let profiles = olaz_wire::extract_profiles_map(&res);
    let mut keys: Vec<&str> = profiles.keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(keys, ["111", "222", "333"]);
    assert_eq!(profiles["111"]["displayName"], "User 111");
    assert_eq!(profiles["222"]["displayName"], "User 222");
    assert_eq!(profiles["333"]["displayName"], "User 333");
    assert!(
        sent(&api)
            .iter()
            .any(|r| r.path() == "/api/social/friend/getprofiles/v2")
    );
    assert!(
        sent(&api)
            .iter()
            .all(|r| r.method == olaz_net::Method::Post)
    );

    // 3. More than 50 uids are chunked as 50 + 10.
    let before = sent(&api).len();
    let sixty: Vec<String> = (1..=60).map(|i| (10_000 + i).to_string()).collect();
    let chunked = api.fetch_profiles(&sixty).await.unwrap();
    assert_eq!(olaz_wire::extract_profiles_map(&chunked).len(), 60);
    let counts: Vec<usize> = sent(&api)[before..]
        .iter()
        .filter(|r| r.path() == "/api/social/friend/getprofiles/v2")
        .map(|r| {
            params_of(r)["friend_pversion_map"]
                .as_array()
                .unwrap()
                .len()
        })
        .collect();
    assert_eq!(counts, [50, 10]);
}

#[tokio::test]
async fn fetch_profiles_payloads_for_primary_and_fallback() {
    let api = api_with(|req| match req.path().as_str() {
        "/api/social/group/members" => err(5),
        _ => ok(json!({"profiles": {"7": {"userId": "7", "displayName": "Seven"}}})),
    });
    let res = api.fetch_profiles(&strs(&["u7", "7"])).await.unwrap();
    assert_eq!(res["data"]["profiles"]["7"]["displayName"], "Seven");
    let reqs = sent(&api);
    assert_eq!(reqs.len(), 2);
    assert_service(&api, &reqs[0], "profile");
    assert_eq!(params_of(&reqs[0]), json!({"friend_pversion_map": ["7_0"]}));
    assert_eq!(
        params_of(&reqs[1]),
        json!({"phonebook_version": 0, "friend_pversion_map": ["7_0"], "avatar_size": 160,
               "language": "vi", "show_online_status": 0, "imei": "imei-1"})
    );
}

#[tokio::test]
async fn fetch_profiles_auth_and_transport_errors_do_not_fall_back() {
    let api = api_with(|_| err(-102));
    let e = api.fetch_profiles(&strs(&["7"])).await.unwrap_err();
    assert!(e.is_auth_error());
    assert_eq!(sent(&api).len(), 1);

    let api = api_with(|_| Ok(RawResponse::new(400, b"bad".to_vec())));
    let e = api.fetch_profiles(&strs(&["7"])).await.unwrap_err();
    assert!(e.session_error().is_none());
    assert_eq!(sent(&api).len(), 1);

    // Non-114 error on both endpoints is rethrown from the fallback.
    let api = api_with(|_| err(77));
    let e = api.fetch_profiles(&strs(&["7"])).await.unwrap_err();
    assert_eq!(e.session_error().unwrap().code, 77);
    assert_eq!(
        e.session_error().unwrap().url,
        "/api/social/friend/getprofiles/v2"
    );
}

// ---------------------------------------------------------------- lists

#[tokio::test]
async fn fetch_friends_payload_and_parse() {
    let api = api_with(|_| {
        ok(json!({"list": [
            {"userId": "111", "displayName": "A", "globalId": "g-enc-1"},
            {"uid": "222"}]}))
    });
    let rows = api.fetch_friends(1, 20000).await.unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0]["displayName"], "A");
    let req = last(&api);
    assert_eq!(req.method, olaz_net::Method::Get);
    assert_eq!(req.path(), "/api/social/friend/getfriends");
    assert_service(&api, &req, "profile");
    assert_eq!(
        params_of(&req),
        json!({"incInvalid": 1, "page": 1, "count": 20000, "avatar_size": 160,
               "actiontime": 0, "imei": "imei-1"})
    );
    assert_eq!(api.state().uid_to_global_id["111"], "g-enc-1");
    assert_eq!(api.state().global_id_to_uid["g-enc-1"], "111");

    // Direct array and `friends` key shapes.
    let api = api_with(|_| ok(json!([{"id": "5"}])));
    assert_eq!(api.fetch_friends(1, 10).await.unwrap().len(), 1);
    let api = api_with(|_| ok(json!({"friends": [{"id": "5"}, {"id": "6"}]})));
    assert_eq!(api.fetch_friends(1, 10).await.unwrap().len(), 2);
    let api = api_with(|_| ok(json!({"list": "nope"})));
    assert!(api.fetch_friends(1, 10).await.unwrap().is_empty());
}

#[tokio::test]
async fn fetch_aliases_pages_and_trims() {
    let api = api_with(|req| {
        let page = params_of(req)["page"].as_i64().unwrap();
        if page == 1 {
            let rows: Vec<Value> = (0..100)
                .map(|i| json!({"userId": format!("{}", 1000 + i), "alias": format!(" Al{i} ")}))
                .collect();
            ok(json!({"items": rows}))
        } else {
            ok(
                json!({"aliases": [{"uid": "5", "aliasName": "Five"}, {"friendId": "6", "name": "  "}]}),
            )
        }
    });
    let map = api.fetch_aliases().await.unwrap();
    assert_eq!(map.len(), 101);
    assert_eq!(map["1000"], "Al0");
    assert_eq!(map["5"], "Five");
    assert!(!map.contains_key("6"));
    let reqs = sent(&api);
    assert_eq!(reqs.len(), 2);
    assert_eq!(reqs[0].path(), "/api/alias/list");
    assert_service(&api, &reqs[0], "alias");
    assert_eq!(
        params_of(&reqs[1]),
        json!({"page": 2, "count": 100, "imei": "imei-1"})
    );
}

#[tokio::test]
async fn fetch_groups_list_batches_and_skips_failed_batch() {
    let ids: Vec<String> = (1..=60).map(|i| format!("{}", 5000 + i)).collect();
    let ver: Map<String, Value> = ids.iter().map(|i| (i.clone(), Value::from(1))).collect();
    let list_body = json!({"data": {"gridVerMap": ver, "removedsGroup": ["5001"]}});
    let mut calls = 0;
    let api = api_with(move |req| match req.path().as_str() {
        "/api/group/getlg/v4" => ok(list_body.clone()),
        _ => {
            calls += 1;
            if calls == 2 {
                return err(5);
            }
            let sent_ver = parsed_json_string(&params_of(req)["gridVerMap"]);
            let info: Map<String, Value> = sent_ver
                .as_object()
                .unwrap()
                .keys()
                .map(|k| (k.clone(), json!({"name": "G"})))
                .collect();
            ok(json!({"data": {"gridInfoMap": info}}))
        }
    });
    let out = api.fetch_groups_list().await.unwrap();
    assert_eq!(out["gridVerMap"].as_object().unwrap().len(), 60);
    // 59 live ids -> batches of 50 and 9; the second batch failed and is skipped.
    assert_eq!(out["gridInfoMap"].as_object().unwrap().len(), 50);
    assert!(out["gridInfoMap"].get("5001").is_none());
    let reqs = sent(&api);
    assert_eq!(reqs.len(), 3);
    assert_eq!(reqs[0].method, olaz_net::Method::Get);
    assert_service(&api, &reqs[0], "group");
    assert!(reqs[0].query_value("params").is_none());
    assert_eq!(reqs[1].path(), "/api/group/getmg-v2");
    assert_eq!(reqs[1].method, olaz_net::Method::Post);
    let p = params_of(&reqs[1]);
    assert_eq!(p["imei"], "imei-1");
    let v = parsed_json_string(&p["gridVerMap"]);
    assert_eq!(v.as_object().unwrap().len(), 50);
    assert!(v.as_object().unwrap().values().all(|x| *x == json!(0)));
}

#[tokio::test]
async fn fetch_pinned_and_archived_parse_shapes() {
    let api = api_with(|_| ok(json!(["u100", "g555", "", 7])));
    assert_eq!(
        api.fetch_pinned_conversations().await.unwrap(),
        ["100", "g555", "7"]
    );
    assert_eq!(last(&api).path(), "/api/pinconvers/list");
    assert!(last(&api).query_value("params").is_none());
    assert_service(&api, &last(&api), "conversation");
    let api = api_with(|_| ok(json!({"items": ["u1"]})));
    assert_eq!(api.fetch_pinned_conversations().await.unwrap(), ["1"]);
    let api = api_with(|_| ok(json!({"conversations": ["group_9"], "items": ["u1"]})));
    assert_eq!(api.fetch_pinned_conversations().await.unwrap(), ["g9"]);
    let api = api_with(|_| ok(json!("weird")));
    assert!(api.fetch_pinned_conversations().await.unwrap().is_empty());

    let api = api_with(|_| {
        ok(json!({"version": 77, "items": [
            {"id": "u200", "type": 0}, {"id": "555", "type": 1}, {"id": "g777"}, {"id": ""}]}))
    });
    assert_eq!(
        api.fetch_archived_chats().await.unwrap(),
        ["200", "g555", "g777"]
    );
    assert_eq!(api.archived_version(), 77);
    let req = last(&api);
    assert_eq!(req.path(), "/api/archivedchat/list");
    assert_service(&api, &req, "label");
    assert_eq!(params_of(&req), json!({"version": 0, "imei": "imei-1"}));
    let api = api_with(|_| ok(json!({"conversations": ["u5", "g6"]})));
    assert_eq!(api.fetch_archived_chats().await.unwrap(), ["5", "g6"]);
    let api = api_with(|_| ok(json!(["u8"])));
    assert_eq!(api.fetch_archived_chats().await.unwrap(), ["8"]);
}

#[tokio::test]
async fn fetch_labels_and_mute_list() {
    let api = api_with(|_| ok(json!({"version": 12, "labelData": []})));
    let d = api.fetch_conversation_labels().await.unwrap();
    assert_eq!(d["version"], 12);
    assert_eq!(api.label_version(), 12);
    let req = last(&api);
    assert_eq!(req.path(), "/api/convlabel/get");
    assert_eq!(params_of(&req), json!({"imei": "imei-1"}));

    let api = api_with(|_| {
        ok(json!({"chatEntries": [{"id": "1", "type": 9}], "groupChatEntries": [{"id": "2"}]}))
    });
    let rows = api.fetch_mute_list().await.unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0]["type"], 1);
    assert_eq!(rows[1]["type"], 2);
    let req = last(&api);
    assert_eq!(req.path(), "/api/social/profile/getmute");
    assert_service(&api, &req, "profile");
    assert_eq!(params_of(&req), json!({"imei": "imei-1"}));
    let api = api_with(|_| ok(json!({"chats": [{"id": "3"}]})));
    assert_eq!(api.fetch_mute_list().await.unwrap().len(), 1);
    let api = api_with(|_| ok(json!([{"id": "4"}])));
    assert_eq!(api.fetch_mute_list().await.unwrap()[0]["id"], "4");
}

#[tokio::test]
async fn fetch_preload_conversations_builds_thread_map() {
    let api = api_with(|_| ok(json!({"clearUnreads": []})));
    let res = api.fetch_preload_conversations(&[]).await.unwrap();
    assert_eq!(res["error_code"], 0);
    let req = last(&api);
    assert_eq!(req.path(), "/api/preloadconvers/get-last-msgs");
    assert_service(&api, &req, "conversation");
    let p = params_of(&req);
    assert_eq!(p["threadIdLocalMsgId"], "{}");
    assert_eq!(p["imei"], "imei-1");

    // Group ids become `<clean>_1`, others `<id>_0` (stripUserPrefix only trims); sorted keys
    // like Swift's `.sortedKeys`.
    api.fetch_preload_conversations(&strs(&["333", "g555", "group_9", "", " 44 "]))
        .await
        .unwrap();
    assert_eq!(
        last_params_string(&api, "threadIdLocalMsgId"),
        r#"{"333_0":"1","44_0":"1","555_1":"1","9_1":"1"}"#
    );

    // Only the first 25 ids are used.
    let many: Vec<String> = (1..=40).map(|i| format!("{}", 100 + i)).collect();
    api.fetch_preload_conversations(&many).await.unwrap();
    let parsed = parse_object_str(&last_params_string(&api, "threadIdLocalMsgId")).unwrap();
    assert_eq!(parsed.len(), 25);
}

// ---------------------------------------------------------------- history

#[tokio::test]
async fn fetch_history_one_to_one_uses_preload_and_paging_is_empty() {
    let api = api_ok();
    api.fetch_history("200", None, 50, Some(false))
        .await
        .unwrap();
    let req = last(&api);
    assert_eq!(req.path(), "/api/preloadconvers/get-last-msgs");
    assert_eq!(
        last_params_string(&api, "threadIdLocalMsgId"),
        r#"{"200_0":"1"}"#
    );

    let before = sent(&api).len();
    let a = api
        .fetch_history("200", Some("123"), 50, None)
        .await
        .unwrap();
    let b = api
        .fetch_history("200", None, 50, Some(true))
        .await
        .unwrap();
    assert_eq!(a, b);
    assert_eq!(a["data"]["msgs"], json!([]));
    assert_eq!(a["error_code"], 0);
    assert_eq!(sent(&api).len(), before);
    // A "0" cursor is not a cursor.
    api.fetch_history("200", Some("0"), 50, None).await.unwrap();
    assert_eq!(sent(&api).len(), before + 1);
}

#[tokio::test]
async fn fetch_history_group_first_page_payload_and_output_shape() {
    let api = api_with(|_| {
        ok(
            json!({"groupMsgs": [{"msgId": "9007199254740993"}, {"msgId": "2"}],
                  "isOld": 0, "hasMore": 0, "lastMsgId": 5, "extra": "keep"}),
        )
    });
    let out = api.fetch_history("g555", None, 30, None).await.unwrap();
    let reqs = sent(&api);
    assert_eq!(reqs.len(), 1);
    let req = &reqs[0];
    assert_eq!(req.path(), "/api/cm/getrecentv2");
    assert_service(&api, req, "group_cloud_message");
    assert_eq!(req.header("nretry"), Some("0"));
    assert_eq!(req.method, olaz_net::Method::Get);
    assert_eq!(
        params_of(req),
        json!({"groupId": "555", "globalMsgId": "9223372036854775807", "count": 30,
               "msgIds": [], "imei": "imei-1", "src": 1})
    );
    assert_eq!(out["data"]["groupMsgs"].as_array().unwrap().len(), 2);
    assert_eq!(out["data"]["groupMsgs"][0]["msgId"], "9007199254740993");
    assert_eq!(out["data"]["isOld"], 0);
    assert_eq!(out["data"]["hasMore"], 0);
    assert_eq!(out["data"]["lastMsgId"], "5");
    assert_eq!(out["data"]["extra"], "keep");
    assert_eq!(out["error_code"], 0);
}

#[tokio::test]
async fn fetch_history_group_pages_until_enough_and_tracks_direction() {
    let mut page = 0;
    let api = api_with(move |_| {
        page += 1;
        match page {
            1 => ok(
                json!({"groupMsgs": [{"msgId": "1"}], "isOld": 1, "hasMore": 1, "lastMsgId": "800"}),
            ),
            2 => ok(json!({
                "groupMsgs": (0..25).map(|i| json!({"msgId": i})).collect::<Vec<_>>(),
                "isOld": 1, "hasMore": 1, "lastMsgId": "700"})),
            _ => ok(json!({"groupMsgs": [], "hasMore": 0})),
        }
    });
    let out = api
        .fetch_history("g555", Some("900"), 50, Some(true))
        .await
        .unwrap();
    let reqs = sent(&api);
    assert_eq!(reqs.len(), 2);
    assert_eq!(reqs[0].path(), "/api/cm/getoldv2");
    assert_eq!(reqs[1].path(), "/api/cm/getoldv2");
    assert_eq!(reqs[1].header("nretry"), Some("1"));
    let p0 = params_of(&reqs[0]);
    assert_eq!(
        (p0["globalMsgId"].as_str(), p0["src"].as_i64()),
        (Some("900"), Some(3))
    );
    let p1 = params_of(&reqs[1]);
    assert_eq!(
        (p1["globalMsgId"].as_str(), p1["src"].as_i64()),
        (Some("800"), Some(2))
    );
    assert_eq!(out["data"]["groupMsgs"].as_array().unwrap().len(), 26);
    assert_eq!(out["data"]["isOld"], 1);
    assert_eq!(out["data"]["hasMore"], 1);
    assert_eq!(out["data"]["lastMsgId"], "700");

    // The remembered direction is reused for a cursor request without an explicit flag.
    let api2 = api_with(|_| ok(json!({"groupMsgs": [], "isOld": 1, "hasMore": 0})));
    api2.fetch_history("g555", None, 50, None).await.unwrap();
    api2.fetch_history("g555", Some("5"), 50, None)
        .await
        .unwrap();
    assert_eq!(sent(&api2)[0].path(), "/api/cm/getrecentv2");
    assert_eq!(sent(&api2)[1].path(), "/api/cm/getoldv2");
}

#[tokio::test]
async fn fetch_history_group_old_without_cursor_and_error_handling() {
    let api = api_ok();
    let out = api
        .fetch_history("g555", None, 50, Some(true))
        .await
        .unwrap();
    assert_eq!(out["data"]["msgs"], json!([]));
    assert!(sent(&api).is_empty());

    // First request error is returned; a later one just stops paging.
    let api = api_with(|_| err(5));
    assert!(api.fetch_history("g555", None, 50, None).await.is_err());
    let mut n = 0;
    let api = api_with(move |_| {
        n += 1;
        if n == 1 {
            ok(json!({"groupMsgs": [{"msgId": "1"}], "hasMore": 1, "lastMsgId": "9"}))
        } else {
            err(5)
        }
    });
    let out = api.fetch_history("g555", None, 50, None).await.unwrap();
    assert_eq!(out["data"]["groupMsgs"].as_array().unwrap().len(), 1);
    assert_eq!(out["data"]["hasMore"], 1);
    assert_eq!(out["data"]["lastMsgId"], "9");
}

#[tokio::test]
async fn fetch_history_self_cloud_uses_send2me_id_and_is_oa() {
    let api = api_with(|_| ok(json!({"groupMsgs": [], "hasMore": 0})));
    // Both the send2Me id and (because send2Me is set) the own uid are the self cloud.
    api.fetch_history("999", None, 50, None).await.unwrap();
    api.fetch_history("100", None, 50, None).await.unwrap();
    let reqs = sent(&api);
    assert_eq!(reqs.len(), 2);
    for req in &reqs {
        assert_eq!(req.path(), "/api/cm/getrecentv2");
        assert_eq!(
            params_of(req),
            json!({"groupId": "999", "globalMsgId": "9223372036854775807", "count": 50,
                   "msgIds": [], "imei": "imei-1", "src": 1, "isOA": 1})
        );
    }
    // A stranger 1-1 id is not self cloud.
    api.fetch_history("555", None, 50, None).await.unwrap();
    assert_eq!(last(&api).path(), "/api/preloadconvers/get-last-msgs");
}

// ---------------------------------------------------------------- send text

fn mention(uid: &str, pos: i64, len: i64, is_all: bool) -> olaz_wire::Mention {
    olaz_wire::Mention {
        uid: uid.to_owned(),
        pos,
        len,
        is_all,
    }
}

#[tokio::test]
async fn send_text_one_to_one_plain_payload_and_result() {
    let api = api_with(|_| ok(json!({"msgId": "8800112233"})));
    let res = api
        .send_text(&SendTextArgs {
            conv_id: "200",
            text: "xin chào",
            cli_msg_id: "1795000000123",
            ..SendTextArgs::default()
        })
        .await
        .unwrap();
    assert_eq!(res.msg_id, "8800112233");
    assert_eq!(res.cli_msg_id, "1795000000123");
    assert_eq!(res.ts_ms, NOW_MS);
    let req = last(&api);
    assert_eq!(req.path(), "/api/message/sms");
    assert_eq!(req.method, olaz_net::Method::Post);
    assert_service(&api, &req, "chat");
    assert_eq!(
        params_of(&req),
        json!({"message": "xin chào", "clientId": 1_795_000_000_123_i64, "imei": "imei-1",
               "ttl": 0, "toid": "200"})
    );
    assert_eq!(
        req.header("content-type"),
        Some("application/x-www-form-urlencoded")
    );
}

#[tokio::test]
async fn send_text_falls_back_to_client_id_and_generates_missing_one() {
    let api = api_ok();
    let res = api
        .send_text(&SendTextArgs {
            conv_id: "200",
            text: "hi",
            cli_msg_id: "not-a-number",
            ..SendTextArgs::default()
        })
        .await
        .unwrap();
    assert_eq!(res.msg_id, NOW_MS.to_string());
    assert_eq!(res.cli_msg_id, NOW_MS.to_string());
    assert_eq!(params_of(&last(&api))["clientId"], NOW_MS);
}

#[tokio::test]
async fn send_text_group_with_mentions() {
    let api = api_ok();
    let mentions = [mention("-1", 0, 4, true), mention("222", 5, 6, false)];
    api.send_text(&SendTextArgs {
        conv_id: "g555",
        text: "@all @Bob hi",
        cli_msg_id: "77",
        mentions: &mentions,
        ..SendTextArgs::default()
    })
    .await
    .unwrap();
    let req = last(&api);
    assert_eq!(req.path(), "/api/group/sendmsg");
    assert_service(&api, &req, "group");
    let p = params_of(&req);
    assert_eq!(p["grid"], "555");
    assert_eq!(p["visibility"], 0);
    assert_eq!(p["ttl"], 0);
    assert!(p.get("toid").is_none());
    assert_eq!(
        parsed_json_string(&p["mentionInfo"]),
        json!([{"uid": "-1", "pos": 0, "len": 4, "type": 1},
               {"uid": "222", "pos": 5, "len": 6, "type": 0}])
    );
    // The same mention list is ignored for a 1-1 chat.
    api.send_text(&SendTextArgs {
        conv_id: "200",
        text: "x",
        cli_msg_id: "78",
        mentions: &mentions,
        ..SendTextArgs::default()
    })
    .await
    .unwrap();
    assert!(params_of(&last(&api)).get("mentionInfo").is_none());
}

#[tokio::test]
async fn send_text_all_mention_ignores_uid_text() {
    let api = api_ok();
    let mentions = [mention("whatever", 0, 4, true)];
    api.send_text(&SendTextArgs {
        conv_id: "g555",
        text: "@all",
        cli_msg_id: "1",
        mentions: &mentions,
        ..SendTextArgs::default()
    })
    .await
    .unwrap();
    // Golden shape from Swift JSONSerialization for the mention array (keys sorted here).
    assert_eq!(
        params_of(&last(&api))["mentionInfo"].as_str().unwrap(),
        r#"[{"len":4,"pos":0,"type":1,"uid":"-1"}]"#
    );
}

#[tokio::test]
async fn send_text_quote_one_to_one_and_group_payloads() {
    let api = api_ok();
    api.send_text(&SendTextArgs {
        conv_id: "200",
        text: "reply",
        cli_msg_id: "10",
        quote_msg_id: Some(" 9001 "),
        quote_cli_msg_id: Some("7001"),
        quote_owner_id: Some("300"),
        quote_text: Some("orig"),
        quote_ts_ms: Some(1_700_000_000_000),
        ..SendTextArgs::default()
    })
    .await
    .unwrap();
    let req = last(&api);
    assert_eq!(req.path(), "/api/message/quote");
    assert_eq!(
        params_of(&req),
        json!({"message": "reply", "clientId": 10, "qmsgOwner": "300", "qmsgId": 9001,
               "qmsgCliId": 7001, "qmsgType": 1, "qmsg": "orig", "qmsgTs": 1_700_000_000_000_i64,
               "ttl": 0, "zsource": 101, "imei": "imei-1", "toid": "200"})
    );

    let mentions = [mention("222", 0, 4, false)];
    api.send_text(&SendTextArgs {
        conv_id: "g555",
        text: "reply",
        cli_msg_id: "11",
        quote_msg_id: Some("9002"),
        mentions: &mentions,
        ..SendTextArgs::default()
    })
    .await
    .unwrap();
    let req = last(&api);
    assert_eq!(req.path(), "/api/group/quote");
    let p = params_of(&req);
    // Defaults: owner = own uid, cli id = quote msg id, empty text, ts = now.
    assert_eq!(p["qmsgOwner"], "100");
    assert_eq!(p["qmsgCliId"], 9002);
    assert_eq!(p["qmsg"], "");
    assert_eq!(p["qmsgTs"], NOW_MS);
    assert_eq!(p["grid"], "555");
    assert_eq!(p["visibility"], 0);
    assert_eq!(p["language"], "vi");
    assert_eq!(p["qmsgAttach"], "{}");
    assert!(p.get("toid").is_none());
    assert_eq!(parsed_json_string(&p["mentionInfo"])[0]["uid"], "222");
}

#[tokio::test]
async fn send_text_quote_failure_falls_back_to_plain_and_zero_quote_is_plain() {
    let api = api_with(|req| {
        if req.path() == "/api/message/quote" {
            err(5)
        } else {
            ok(json!({"msgId": 12345}))
        }
    });
    let res = api
        .send_text(&SendTextArgs {
            conv_id: "200",
            text: "t",
            cli_msg_id: "10",
            quote_msg_id: Some("9001"),
            ..SendTextArgs::default()
        })
        .await
        .unwrap();
    assert_eq!(res.msg_id, "12345");
    let paths: Vec<String> = sent(&api).iter().map(RequestSpec::path).collect();
    assert_eq!(paths, ["/api/message/quote", "/api/message/sms"]);

    let api = api_ok();
    for q in ["0", "abc", ""] {
        api.send_text(&SendTextArgs {
            conv_id: "200",
            text: "t",
            cli_msg_id: "10",
            quote_msg_id: Some(q),
            ..SendTextArgs::default()
        })
        .await
        .unwrap();
        assert_eq!(last(&api).path(), "/api/message/sms");
    }

    // The plain send's own error is returned.
    let api = api_with(|_| err(-102));
    let e = api
        .send_text(&SendTextArgs {
            conv_id: "200",
            text: "t",
            cli_msg_id: "10",
            ..SendTextArgs::default()
        })
        .await
        .unwrap_err();
    assert!(e.is_auth_error());
}

// ---------------------------------------------------------------- typing / seen / unread

#[tokio::test]
async fn typing_payloads() {
    let api = api_ok();
    api.send_typing("200").await;
    let req = last(&api);
    assert_eq!(req.path(), "/api/message/typing");
    assert_service(&api, &req, "chat");
    assert_eq!(
        params_of(&req),
        json!({"toid": "200", "destType": 3, "imei": "imei-1"})
    );
    api.send_typing("g555").await;
    let req = last(&api);
    assert_eq!(req.path(), "/api/group/typing");
    assert_service(&api, &req, "group");
    assert_eq!(params_of(&req), json!({"grid": "555", "imei": "imei-1"}));
    // Errors are swallowed.
    let failing = api_with(|_| err(5));
    failing.send_typing("200").await;
    assert_eq!(sent(&failing).len(), 1);
}

#[tokio::test]
async fn seen_payloads_and_guards() {
    let api = api_ok();
    api.send_seen("200", " 9 ", "", "300").await;
    let req = last(&api);
    assert_eq!(req.path(), "/api/message/seenv2");
    let p = params_of(&req);
    assert_eq!(p.as_object().unwrap().len(), 1);
    assert_eq!(
        parsed_json_string(&p["msgInfos"]),
        json!({"data": [{"gmi": "9", "cmi": "9"}], "senderId": "200"})
    );
    api.send_seen("g555", "9", "8", "300").await;
    let req = last(&api);
    assert_eq!(req.path(), "/api/group/seenv2");
    assert_service(&api, &req, "group");
    let p = params_of(&req);
    assert_eq!(p["imei"], "imei-1");
    assert_eq!(
        parsed_json_string(&p["msgInfos"]),
        json!({"data": [{"gmi": "9", "cmi": "8"}], "grid": "555"})
    );
    // Swift order is unspecified; ours is sorted.
    assert_eq!(
        p["msgInfos"].as_str().unwrap(),
        r#"{"data":[{"cmi":"8","gmi":"9"}],"grid":"555"}"#
    );
    let before = sent(&api).len();
    api.send_seen("200", "  ", "1", "").await;
    api.send_seen("", "9", "1", "").await;
    assert_eq!(sent(&api).len(), before);
}

#[tokio::test]
async fn unread_mark_payloads() {
    let api = api_ok();
    api.set_unread_mark("200", true).await.unwrap();
    let req = last(&api);
    assert_eq!(req.path(), "/api/conv/addUnreadMark");
    assert_service(&api, &req, "conversation");
    let p = params_of(&req);
    assert_eq!(p.as_object().unwrap().len(), 1);
    assert_eq!(
        parsed_json_string(&p["param"]),
        json!({"convsGroup": [], "convsUser": ["200"], "imei": "imei-1"})
    );
    api.set_unread_mark("g555", false).await.unwrap();
    let req = last(&api);
    assert_eq!(req.path(), "/api/conv/removeUnreadMark");
    assert_eq!(
        parsed_json_string(&params_of(&req)["param"]),
        json!({"convsGroup": ["555"], "convsUser": [], "convsGroupData": [], "convsUserData": []})
    );
    // Golden from Swift JSONSerialization(.sortedKeys) for the 1-1 remove variant.
    api.set_unread_mark("200", false).await.unwrap();
    assert_eq!(
        params_of(&last(&api))["param"].as_str().unwrap(),
        r#"{"convsGroup":[],"convsGroupData":[],"convsUser":["200"],"convsUserData":[]}"#
    );
    let failing = api_with(|_| err(5));
    assert!(failing.set_unread_mark("200", true).await.is_err());
}

// ---------------------------------------------------------------- recall / delete / reaction

#[tokio::test]
async fn recall_message_posts_built_request() {
    let api = api_ok();
    api.recall_message("200", "9001", "7001", false)
        .await
        .unwrap();
    let req = last(&api);
    assert_eq!(req.path(), "/api/message/undo");
    assert_service(&api, &req, "chat");
    assert_eq!(
        params_of(&req),
        json!({"msgId": "9001", "clientId": NOW_MS, "cliMsgIdUndo": "7001", "toid": "200"})
    );
    api.recall_message("g555", "9002", "", true).await.unwrap();
    let req = last(&api);
    assert_eq!(req.path(), "/api/e2ee/pc/group/undoMsg");
    assert_service(&api, &req, "group_e2e");
    assert_eq!(
        params_of(&req),
        json!({"msgId": "9002", "clientId": NOW_MS + 1, "cliMsgIdUndo": "9002",
               "grid": "555", "visibility": 0, "imei": "imei-1"})
    );
}

#[tokio::test]
async fn delete_message_for_me_payloads() {
    let api = api_ok();
    api.delete_message_for_me("200", "9001", "7001", "300")
        .await
        .unwrap();
    let req = last(&api);
    assert_eq!(req.path(), "/api/message/delete");
    assert_service(&api, &req, "chat");
    assert_eq!(
        params_of(&req),
        json!({"cliMsgId": NOW_MS, "onlyMe": 1, "imei": "imei-1", "toid": "200",
               "msgs": [{"cliMsgId": "7001", "globalMsgId": "9001", "ownerId": "300", "destId": "200"}]})
    );
    // Empty cli id -> msg id; empty sender -> own uid.
    api.delete_message_for_me("g555", "9002", "", "")
        .await
        .unwrap();
    let req = last(&api);
    assert_eq!(req.path(), "/api/group/deletemsg");
    assert_service(&api, &req, "group");
    assert_eq!(
        params_of(&req),
        json!({"cliMsgId": NOW_MS + 1, "onlyMe": 1, "imei": "imei-1", "grid": "555",
               "msgs": [{"cliMsgId": "9002", "globalMsgId": "9002", "ownerId": "100", "destId": "555"}]})
    );
}

#[tokio::test]
async fn send_reaction_posts_to_reaction_service() {
    let api = api_ok();
    let id = api
        .send_reaction("g555", "99001", "27001", "/-strong", 3, 46, None)
        .await
        .unwrap();
    assert_eq!(id, NOW_MS);
    let req = last(&api);
    assert_eq!(req.path(), "/api/group/reaction");
    assert_service(&api, &req, "reaction");
    let p = params_of(&req);
    assert_eq!(p["grid"], "555");
    assert_eq!(p["imei"], "imei-1");
    assert_eq!(p["react_list"][0]["clientId"], NOW_MS);
    let id2 = api
        .send_reaction("200", "88001", "17001", "/-heart", 5, 1, Some(42))
        .await
        .unwrap();
    assert_eq!(id2, 42);
    assert_eq!(params_of(&last(&api))["toid"], "200");
}

// ---------------------------------------------------------------- errors

#[tokio::test]
async fn api_error_exposes_session_error_and_auth_flag() {
    let api = api_with(|_| err(600));
    let e = api.fetch_pinned_conversations().await.unwrap_err();
    assert!(e.is_auth_error());
    assert_eq!(e.session_error().unwrap().code, 600);
    assert_eq!(e.session_error().unwrap().url, "/api/pinconvers/list");

    let unauth = ZaloApi::new(SessionClient::new(
        MockTransport::scripted(vec![]),
        "i".to_owned(),
        "n".to_owned(),
    ));
    // A call that carries encrypted params needs the session key.
    let e = unauth.fetch_archived_chats().await.unwrap_err();
    assert_eq!(e, ApiError::Net(NetError::NotAuthenticated));
}

/// Rich text: `textProperties` rides along unchanged on the plain and the quote payload (official `buildMsgParams`).
#[tokio::test]
async fn send_text_carries_text_properties() {
    let api = api_with(|_| ok(json!({"msgId": "8800112299"})));
    let tp = r#"{"styles":[{"len":3,"st":"b","start":0}],"ver":0}"#;
    api.send_text(&SendTextArgs {
        conv_id: "200",
        text: "Đậm",
        cli_msg_id: "1795000000999",
        text_properties: Some(tp),
        ..SendTextArgs::default()
    })
    .await
    .unwrap();
    assert_eq!(
        params_of(&last(&api))["textProperties"].as_str().unwrap(),
        tp
    );
    api.send_text(&SendTextArgs {
        conv_id: "200",
        text: "x",
        cli_msg_id: "1",
        ..SendTextArgs::default()
    })
    .await
    .unwrap();
    assert!(params_of(&last(&api)).get("textProperties").is_none());
}

// ---------------------------------------------------------------- U3 conversation action endpoints

#[tokio::test]
async fn update_pinned_conversation_formats_user_and_group_wire_ids() {
    let api = api_ok();
    api.update_pinned_conversation("3000202", true)
        .await
        .unwrap();
    let req = last(&api);
    assert_service(&api, &req, "conversation");
    assert_eq!(req.path(), "/api/pinconvers/updatev2");
    assert_eq!(
        params_of(&req),
        json!({"actionType": 1, "conversations": ["u3000202"], "tab": 0})
    );

    api.update_pinned_conversation("g900001", false)
        .await
        .unwrap();
    let req = last(&api);
    assert_eq!(
        params_of(&req),
        json!({"actionType": 2, "conversations": ["g900001"], "tab": 0})
    );
}

#[tokio::test]
async fn update_archived_chat_uses_tracked_version_and_action_type() {
    let api = api_with(|req| {
        if req.path() == "/api/archivedchat/list" {
            ok(json!({"version": 7, "items": []}))
        } else {
            ok(json!({}))
        }
    });
    api.fetch_archived_chats().await.unwrap();
    assert_eq!(api.archived_version(), 7);

    api.update_archived_chat("3000271", true).await.unwrap();
    let req = last(&api);
    assert_service(&api, &req, "label");
    assert_eq!(req.path(), "/api/archivedchat/update");
    assert_eq!(
        params_of(&req),
        json!({
            "ids": [{"id": "3000271", "type": 0}],
            "version": 7,
            "actionType": 0,
            "imei": "imei-1",
        })
    );

    api.update_archived_chat("g555", false).await.unwrap();
    let req = last(&api);
    assert_eq!(
        params_of(&req),
        json!({
            "ids": [{"id": "555", "type": 1}],
            "version": 7,
            "actionType": 1,
            "imei": "imei-1",
        })
    );
}

#[tokio::test]
async fn update_conversation_labels_tracks_version_across_calls() {
    let api = api_with(|_| ok(json!({"version": 42})));
    api.update_conversation_labels(r#"[{"id":1}]"#)
        .await
        .unwrap();
    let req = last(&api);
    assert_service(&api, &req, "label");
    assert_eq!(req.path(), "/api/convlabel/update");
    assert_eq!(
        params_of(&req),
        json!({"labelData": r#"[{"id":1}]"#, "version": 0, "imei": "imei-1"})
    );
    assert_eq!(api.label_version(), 42);

    api.update_conversation_labels(r#"[]"#).await.unwrap();
    assert_eq!(params_of(&last(&api))["version"], json!(42));
}

#[tokio::test]
async fn delete_conversation_routes_dm_and_group_and_generates_fallback_cli_id() {
    let api = api_ok();
    api.delete_conversation("3000281", "m281_last")
        .await
        .unwrap();
    let req = last(&api);
    assert_service(&api, &req, "chat");
    assert_eq!(req.path(), "/api/message/deleteconver");
    assert_eq!(
        params_of(&req),
        json!({
            "toid": "3000281",
            "cliMsgId": "m281_last",
            "conver": {},
            "onlyMe": 1,
            "imei": "imei-1",
        })
    );

    api.delete_conversation("g888", "").await.unwrap();
    let req = last(&api);
    assert_service(&api, &req, "group");
    assert_eq!(req.path(), "/api/group/deleteconver");
    let p = params_of(&req);
    assert_eq!(p["grid"], json!("888"));
    assert_eq!(p["conver"], json!({}));
    assert_eq!(p["onlyMe"], json!(1));
    assert!(!p["cliMsgId"].as_str().unwrap().is_empty());
}

#[tokio::test]
async fn hidden_conversation_endpoints_match_wire_contract() {
    let api = api_with(|req| match req.path().as_str() {
        "/api/hiddenconvers/get-all" => ok(json!({
            "pin": " 81DC9BDB52D04DC20036DBD8313ED055 ",
            "threads": [
                {"thread_id": " 3000301 ", "is_group": 0},
                {"threadId": "90001", "isGroup": true},
                {"thread_id": "3000301", "is_group": 0},
                {"thread_id": "0", "is_group": 0},
                {"thread_id": "g0", "is_group": 1}
            ]
        })),
        _ => ok(json!({})),
    });

    let snap = api.fetch_hidden_conversations().await.unwrap();
    assert_eq!(snap.pin, "81dc9bdb52d04dc20036dbd8313ed055");
    assert_eq!(snap.thread_ids, vec!["3000301", "g90001"]);
    let req = last(&api);
    assert_service(&api, &req, "conversation");
    assert_eq!(req.path(), "/api/hiddenconvers/get-all");
    assert_eq!(params_of(&req), json!({"imei": "imei-1"}));

    api.set_hidden_conversation("3000301", true).await.unwrap();
    let req = last(&api);
    assert_eq!(req.path(), "/api/hiddenconvers/add-remove");
    assert_eq!(
        params_of(&req),
        json!({
            "add_threads": r#"[{"is_group":0,"thread_id":"3000301"}]"#,
            "del_threads": "[]",
            "imei": "imei-1",
        })
    );

    api.set_hidden_conversation("g90001", false).await.unwrap();
    assert_eq!(
        params_of(&last(&api)),
        json!({
            "add_threads": "[]",
            "del_threads": r#"[{"is_group":1,"thread_id":"90001"}]"#,
            "imei": "imei-1",
        })
    );

    api.update_hidden_pin("1234").await.unwrap();
    let req = last(&api);
    assert_eq!(req.path(), "/api/hiddenconvers/update-pin");
    assert_eq!(
        params_of(&req),
        json!({
            "new_pin": "81dc9bdb52d04dc20036dbd8313ed055",
            "imei": "imei-1",
        })
    );

    let err = api.update_hidden_pin("").await.unwrap_err();
    assert_eq!(
        err,
        ApiError::Net(NetError::InvalidUrl("hiddenconvers:update-pin".to_owned()))
    );

    api.reset_hidden_pin().await.unwrap();
    let req = last(&api);
    assert_eq!(req.path(), "/api/hiddenconvers/reset");
    assert!(req.query_value("params").is_none());
}

//! Scenario integration tests covering all 26 U2 transport behaviors (WS lifecycle, routing,
//! typed chat hot path, auth watch, cursor persistence + ordering, long-poll loop, and
//! serialized `drain_chat_polling`) under `tokio::time::pause()`.

#![expect(clippy::expect_used, reason = "integration tests")]

mod common;

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use common::{AwaitPredicate, Case, Expect, HttpResponseSpec, Seed, ServerEntry, Step, run_case};
use olaz_api::PollState;
use olaz_core::actor::CoreHandle;
use olaz_core::input::{Command, Input};
use olaz_core::reduce::{reduce, transport::LP_TICK_INTERVAL};
use olaz_core::runner::{Host, SessionEffectRunner, WsDriver};
use olaz_core::state::{CoreState, PersistedTransportState, Phase, WsPhase};
use olaz_core::typed_chat::try_parse_plain_chat_pure;
use olaz_net::{LoginAccount, SessionClient, ZaloDomains};
use olaz_wire::NameLookup;
use olaz_ws::WsQueueCursorSnapshot;
use serde_json::{Map, Value, json};
use tokio::runtime::Handle;

fn ready_seed(suppress: &[&str]) -> Seed {
    Seed {
        saved_session: Some(json!({
            "version": 1,
            "imei": "00000000-0000-4000-8000-000000000000-00000000000000000000000000000000",
            "computerName": "TestMac",
            "zpwSek": "sek.test.1",
            "plainAccount": {
                "userId": "100",
                "displayName": "An",
                "avatar": "",
                "phone": "",
                "send2meId": "self-100",
                "dkey": "dk",
                "zpwEnk": "MDEyMzQ1Njc4OWFiY2RlZg==",
                "zpwSek": "sek.test.1"
            },
            "domains": {
                "isolated": true,
                "chat": "http://fake",
                "profile": "http://fake",
                "lpChat": "http://fake",
                "ws": ["ws://fake/ws1", "ws://fake/ws2"]
            }
        })),
        domains: None,
        legacy_cookie: None,
        prefs: BTreeMap::new(),
        poll_state: None,
        ws_cursors: None,
        suppress: suppress.iter().map(|s| (*s).to_owned()).collect(),
        ..Seed::default()
    }
}

fn http_ok(path: &str, body: Value) -> ServerEntry {
    ServerEntry {
        kind: "http".to_owned(),
        path: path.to_owned(),
        response: Some(HttpResponseSpec {
            status: 200,
            json: Some(body),
            raw: None,
            error: None,
            headers: BTreeMap::new(),
        }),
        ..ServerEntry::default()
    }
}

fn http_err(path: &str, err: &str) -> ServerEntry {
    ServerEntry {
        kind: "http".to_owned(),
        path: path.to_owned(),
        response: Some(HttpResponseSpec {
            status: 200,
            json: None,
            raw: None,
            error: Some(err.to_owned()),
            headers: BTreeMap::new(),
        }),
        ..ServerEntry::default()
    }
}

fn boot_http_entries() -> Vec<ServerEntry> {
    vec![
        http_ok(
            "/api/login/getLoginInfo",
            json!({ "error_code": 0, "data": { "uid": "100" } }),
        ),
        http_ok(
            "/api/social/profile/me-v2",
            json!({ "error_code": 0, "data": { "userId": "100", "displayName": "An" } }),
        ),
    ]
}

fn ws_auth_frame(queues: Value) -> ServerEntry {
    ServerEntry {
        kind: "ws_frame".to_owned(),
        cmd: Some(1),
        sub_cmd: Some(1),
        payload: Some(json!({ "error_code": 0, "data": { "qCmds": queues } })),
        ..ServerEntry::default()
    }
}

fn ws_frame(cmd: u16, sub_cmd: u8, payload: Value) -> ServerEntry {
    ServerEntry {
        kind: "ws_frame".to_owned(),
        cmd: Some(cmd),
        sub_cmd: Some(sub_cmd),
        payload: Some(payload),
        ..ServerEntry::default()
    }
}

fn ws_close() -> ServerEntry {
    ServerEntry {
        kind: "ws_close".to_owned(),
        code: Some(1006),
        ..ServerEntry::default()
    }
}

fn make_case(name: &str, seed: Seed, server: Vec<ServerEntry>, steps: Vec<Step>) -> Case {
    Case {
        format: 1,
        domain: "transport".to_owned(),
        name: name.to_owned(),
        slow: false,
        seed,
        server,
        steps,
        expect: Expect {
            snapshots: BTreeMap::new(),
            final_state: json!({}),
            requests: Vec::new(),
            host: Vec::new(),
        },
    }
}

fn step_start() -> Step {
    Step::Cmd {
        cmd: "start".to_owned(),
        args: json!({}),
        now_ms: None,
        rand4: None,
    }
}

fn step_await_ready() -> Step {
    Step::Await {
        predicate: AwaitPredicate {
            phase: "ready".to_owned(),
            step: None,
        },
        timeout_ms: Some(5000),
    }
}

fn step_await_host(name: &str) -> Step {
    Step::AwaitHost {
        await_host: name.to_owned(),
        timeout_ms: Some(15_000),
    }
}

fn step_ws_push(n: usize) -> Step {
    Step::WsPush { ws_push: n }
}

fn host_names(host: &[Value]) -> Vec<&str> {
    host.iter()
        .filter_map(|v| v.get("call").and_then(Value::as_str))
        .collect()
}

fn find_host<'a>(host: &'a [Value], call: &str) -> Vec<&'a Value> {
    host.iter()
        .filter(|v| v.get("call").and_then(Value::as_str) == Some(call))
        .collect()
}

// -----------------------------------------------------------------------------
// 1. ws_starts_after_ready
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t01_ws_starts_after_ready() {
    let mut server = boot_http_entries();
    server.push(ws_auth_frame(json!([])));
    let case = make_case(
        "ws_starts_after_ready",
        ready_seed(&["long_poll"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("e2ee_connected"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    assert!(
        res.requests
            .iter()
            .any(|r| r.get("kind").and_then(Value::as_str) == Some("ws_connect"))
    );
    let names = host_names(&res.host);
    let idx_ws = names
        .iter()
        .position(|&n| n == "start_ws")
        .expect("start_ws");
    let idx_lp = names
        .iter()
        .position(|&n| n == "start_long_poll")
        .expect("start_long_poll");
    let idx_boot = names
        .iter()
        .position(|&n| n == "start_bootstrap")
        .expect("start_bootstrap");
    let idx_e2ee = names
        .iter()
        .position(|&n| n == "e2ee_connected")
        .expect("e2ee_connected");
    assert!(idx_ws < idx_lp && idx_lp < idx_boot && idx_boot < idx_e2ee);
    assert_eq!(res.host[idx_e2ee]["args"]["uid"], json!("100"));
}

// -----------------------------------------------------------------------------
// 2 & 3. ws_kicked_600 & ws_kicked_minus_102
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t02_and_t03_ws_kicked_600_and_minus_102() {
    for code in [600, -102] {
        let mut server = boot_http_entries();
        server.push(ws_auth_frame(json!([])));
        server.push(ws_frame(501, 1, json!({ "error_code": code })));
        let case = make_case(
            "ws_kicked",
            ready_seed(&["long_poll"]),
            server,
            vec![
                step_start(),
                step_await_ready(),
                step_await_host("e2ee_connected"),
                step_ws_push(1),
                step_await_host("mark_expired"),
            ],
        );
        let res = run_case(&case).await.expect("case run");
        assert_eq!(
            res.final_state["sign_out_notice"],
            json!("Tài khoản đã đăng xuất hoặc đăng nhập trên thiết bị khác.")
        );
        assert_eq!(res.final_state["phase"]["kind"], json!("login"));
        assert!(find_host(&res.host, "apply_batch").is_empty());
    }
}

// -----------------------------------------------------------------------------
// 4. ws_authen_ignored
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t04_ws_authen_ignored() {
    let mut server = boot_http_entries();
    server.push(ws_auth_frame(json!([])));
    server.push(ws_frame(1, 1, json!({ "error_code": 0, "data": {} })));
    let case = make_case(
        "ws_authen_ignored",
        ready_seed(&["long_poll"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("e2ee_connected"),
            step_ws_push(1),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    assert!(find_host(&res.host, "apply_batch").is_empty());
}

// -----------------------------------------------------------------------------
// 5. ws_e2ee_signal
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t05_ws_e2ee_signal() {
    let mut server = boot_http_entries();
    server.push(ws_auth_frame(json!([])));
    server.push(ws_frame(543, 1, json!({ "data": { "k": "init" } })));
    server.push(ws_frame(516, 1, json!({ "data": { "k": "offline" } })));
    server.push(ws_frame(549, 1, json!({ "data": { "k": "prekeys" } })));
    let case = make_case(
        "ws_e2ee_signal",
        ready_seed(&["long_poll"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("e2ee_connected"),
            step_ws_push(3),
            step_await_host("e2ee_signal"),
            step_await_host("e2ee_signal"),
            step_await_host("e2ee_signal"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    let sigs = find_host(&res.host, "e2ee_signal");
    let cmds: Vec<i64> = sigs
        .iter()
        .filter_map(|v| v["args"]["cmd"].as_i64())
        .collect();
    assert_eq!(cmds, vec![543, 516, 549]);
    assert!(find_host(&res.host, "apply_batch").is_empty());
}

// -----------------------------------------------------------------------------
// 6. ws_deliver_reports
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t06_ws_deliver_reports() {
    let mut server = boot_http_entries();
    server.push(ws_auth_frame(json!([])));
    server.push(ws_frame(553, 1, json!({ "data": { "deliver": [] } })));
    let case = make_case(
        "ws_deliver_reports",
        ready_seed(&["long_poll"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("e2ee_connected"),
            step_ws_push(1),
            step_await_host("e2ee_deliver_reports"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    let reports = find_host(&res.host, "e2ee_deliver_reports");
    assert_eq!(reports.len(), 1);
    assert_eq!(reports[0]["args"]["cmd"], json!(553));
    assert!(find_host(&res.host, "apply_batch").is_empty());
}

// -----------------------------------------------------------------------------
// 7. ws_sync_ack
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t07_ws_sync_ack() {
    let mut server = boot_http_entries();
    server.push(ws_auth_frame(json!([])));
    server.push(ws_frame(590, 1, json!({ "error_code": 0, "data": {} })));
    server.push(ws_frame(592, 1, json!({ "error_code": 0, "data": {} })));
    let case = make_case(
        "ws_sync_ack",
        ready_seed(&["long_poll"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("e2ee_connected"),
            step_ws_push(2),
            step_await_host("apply_batch"),
            step_await_host("apply_batch"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    let batches = find_host(&res.host, "apply_batch");
    let cmds: Vec<i64> = batches
        .iter()
        .filter_map(|v| v["args"]["cmd"].as_i64())
        .collect();
    assert_eq!(cmds, vec![590, 592]);
}

// -----------------------------------------------------------------------------
// 8. ws_mobile_sync
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t08_ws_mobile_sync() {
    let mut server = boot_http_entries();
    server.push(ws_auth_frame(json!([])));
    server.push(ws_frame(
        601,
        1,
        json!({
            "data": {
                "controls": [
                    {
                        "act_type": "transfer_msg",
                        "content": { "act": "user_confirm", "data": { "user_action": 1 } }
                    }
                ]
            }
        }),
    ));
    let case = make_case(
        "ws_mobile_sync",
        ready_seed(&["long_poll"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("e2ee_connected"),
            step_ws_push(1),
            step_await_host("apply_batch"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    let names = host_names(&res.host);
    let i_sync = names
        .iter()
        .position(|&n| n == "mobile_sync")
        .expect("mobile_sync");
    let i_batch = names
        .iter()
        .position(|&n| n == "apply_batch")
        .expect("apply_batch");
    assert!(i_sync < i_batch);
}

// -----------------------------------------------------------------------------
// 9. ws_typing
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t09_ws_typing() {
    let mut server = boot_http_entries();
    server.push(ws_auth_frame(json!([])));
    server.push(ws_frame(
        602,
        1,
        json!({
            "data": {
                "controls": [
                    { "act_type": "typing", "content": { "act": "typing", "data": { "uid": "200", "isPC": 1 } } },
                    { "act_type": "typing", "content": { "act": "gtyping", "data": { "uid": "201", "gid": "900" } } },
                    { "act_type": "typing", "content": { "act": "gtyping", "data": { "uid": "901" } } },
                    { "act_type": "typing", "content": { "act": "typing", "data": { "uid": "100" } } }
                ]
            }
        }),
    ));
    let case = make_case(
        "ws_typing",
        ready_seed(&["long_poll"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("e2ee_connected"),
            step_ws_push(1),
            step_await_host("apply_batch"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    let typings = find_host(&res.host, "show_typing");
    assert_eq!(typings.len(), 3);
    assert_eq!(
        typings[0]["args"],
        json!({ "conv_id": "200", "uid": "200", "on_pc": true })
    );
    assert_eq!(
        typings[1]["args"],
        json!({ "conv_id": "g900", "uid": "201", "on_pc": false })
    );
    assert_eq!(
        typings[2]["args"],
        json!({ "conv_id": "g901", "uid": "901", "on_pc": false })
    );
}

// -----------------------------------------------------------------------------
// 10. ws_voip
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t10_ws_voip() {
    let mut server = boot_http_entries();
    server.push(ws_auth_frame(json!([])));
    server.push(ws_frame(
        601,
        1,
        json!({
            "data": {
                "controls": [
                    { "act_type": "voip", "content": { "act": "request", "data": { "callId": "c1" } } }
                ]
            }
        }),
    ));
    server.push(ws_frame(
        604,
        1,
        json!({ "data": { "act": "group_request", "data": "{\"callId\":\"c2\"}" } }),
    ));
    let case = make_case(
        "ws_voip",
        ready_seed(&["long_poll"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("e2ee_connected"),
            step_ws_push(2),
            step_await_host("voip_control"),
            step_await_host("voip_control"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    let voips = find_host(&res.host, "voip_control");
    assert_eq!(voips.len(), 2);
    assert_eq!(voips[0]["args"]["act"], json!("request"));
    assert_eq!(voips[1]["args"]["act"], json!("group_request"));
    assert_eq!(voips[1]["args"]["data"]["callId"], json!("c2"));
}

// -----------------------------------------------------------------------------
// 11. ws_pin_topic
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t11_ws_pin_topic() {
    let mut server = boot_http_entries();
    server.push(ws_auth_frame(json!([])));
    server.push(ws_frame(
        601,
        1,
        json!({
            "data": {
                "controls": [
                    { "act_type": "fr", "content": { "act": "pin_create", "data": { "conversationIds": ["200", "300"] } } },
                    { "act_type": "group", "content": { "act": "new_pin_topic", "data": { "groupId": "777" } } }
                ]
            }
        }),
    ));
    let case = make_case(
        "ws_pin_topic",
        ready_seed(&["long_poll"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("e2ee_connected"),
            step_ws_push(1),
            step_await_host("apply_batch"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    let pins: Vec<&str> = find_host(&res.host, "pin_topic")
        .iter()
        .filter_map(|v| v["args"]["conv_id"].as_str())
        .collect();
    assert_eq!(pins, vec!["200", "300", "g777"]);
}

// -----------------------------------------------------------------------------
// 12. ws_group_notice
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t12_ws_group_notice() {
    let mut server = boot_http_entries();
    server.push(ws_auth_frame(json!([])));
    server.push(ws_frame(
        601,
        1,
        json!({
            "data": {
                "controls": [
                    { "act_type": "group", "ts": 1111, "content": { "act": "join", "data": { "groupId": "77", "updateTime": 9999 } } },
                    { "act_type": "group", "content": { "act": "leave", "data": { "groupId": "77", "ts": 2222 } } },
                    { "act_type": "group", "content": { "act": "not_in_notice_set", "data": { "groupId": "77" } } }
                ]
            }
        }),
    ));
    let case = make_case(
        "ws_group_notice",
        ready_seed(&["long_poll"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("e2ee_connected"),
            step_ws_push(1),
            step_await_host("apply_batch"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    let notices = find_host(&res.host, "group_notice");
    assert_eq!(notices.len(), 2);
    assert_eq!(notices[0]["args"]["act"], json!("join"));
    assert_eq!(notices[0]["args"]["ts"], json!(1111));
    assert_eq!(notices[1]["args"]["act"], json!("leave"));
    assert_eq!(notices[1]["args"]["ts"], json!(2222));
}

// -----------------------------------------------------------------------------
// 13. ws_mute
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t13_ws_mute() {
    let mut server = boot_http_entries();
    server.push(ws_auth_frame(json!([])));
    server.push(ws_frame(
        601,
        1,
        json!({
            "data": {
                "controls": [
                    { "act_type": "mute", "content": { "act": "set", "data": { "id": "200", "muteMode": 1, "duration": 3600, "startTime": 1000 } } },
                    { "act_type": "mute", "content": { "act": "unset", "data": { "id": "200", "muteMode": 1, "duration": 3600, "startTime": 1001 } } },
                    { "act_type": "mute", "content": { "act": "set", "data": { "id": "200", "muteMode": 2, "duration": 3600, "startTime": 1002 } } },
                    { "act_type": "mute", "content": { "act": "set", "data": { "id": "200", "muteMode": 1, "duration": 0, "startTime": 1003 } } },
                    { "act_type": "mute", "content": { "act": "set", "data": { "id": "555", "muteType": 2, "muteMode": 1, "duration": 60, "systemTime": 2000 } } },
                    { "act_type": "mute", "content": { "act": "set", "data": { "id": "555", "muteMode": 1, "duration": 60 } } }
                ]
            }
        }),
    ));
    let case = make_case(
        "ws_mute",
        ready_seed(&["long_poll"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("e2ee_connected"),
            step_ws_push(1),
            step_await_host("apply_batch"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    let mutes = find_host(&res.host, "mute");
    assert_eq!(mutes.len(), 6);
    assert_eq!(
        mutes[0]["args"],
        json!({ "conv_id": "200", "set": true, "start": 1000, "duration": 3600 })
    );
    assert_eq!(mutes[1]["args"]["set"], json!(false));
    assert_eq!(mutes[2]["args"]["set"], json!(false));
    assert_eq!(mutes[3]["args"]["set"], json!(false));
    assert_eq!(
        mutes[4]["args"],
        json!({ "conv_id": "g555", "set": true, "start": 2000, "duration": 60 })
    );
    // Missing startTime & systemTime marks start as fallback (`"<volatile>"` in Case format v1).
    assert_eq!(mutes[5]["args"]["start"], json!("<volatile>"));
}

// -----------------------------------------------------------------------------
// 14. ws_controls_shapes
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t14_ws_controls_shapes() {
    let mut server = boot_http_entries();
    server.push(ws_auth_frame(json!([])));
    // actions, nested controls under data array, JSON string content, braceless `"k":v` data
    server.push(ws_frame(
        601,
        1,
        json!({
            "data": [
                {
                    "controls": [
                        { "act_type": "typing", "content": "{\"act\":\"typing\",\"data\":\"\\\"uid\\\":\\\"205\\\",\\\"isPC\\\":1\"}" }
                    ]
                }
            ]
        }),
    ));
    server.push(ws_frame(
        601,
        1,
        json!({
            "data": {
                "actions": [
                    { "act_type": "fr", "content": { "act": "pin_create", "data": { "conversationId": "206" } } }
                ]
            }
        }),
    ));
    let case = make_case(
        "ws_controls_shapes",
        ready_seed(&["long_poll"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("e2ee_connected"),
            step_ws_push(2),
            step_await_host("show_typing"),
            step_await_host("pin_topic"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    assert_eq!(
        find_host(&res.host, "show_typing")[0]["args"],
        json!({ "conv_id": "205", "uid": "205", "on_pc": true })
    );
    assert_eq!(
        find_host(&res.host, "pin_topic")[0]["args"],
        json!({ "conv_id": "206" })
    );
}

// -----------------------------------------------------------------------------
// 15. ws_live_vs_pull
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t15_ws_live_vs_pull() {
    let mut server = boot_http_entries();
    server.push(ws_auth_frame(json!([])));
    // Include an empty controls array or non-plain shape so these exercise the `apply_batch` path.
    for cmd in [501, 521, 510, 511, 532] {
        server.push(ws_frame(
            cmd,
            1,
            json!({ "data": { "controls": [], "msgs": [] } }),
        ));
    }
    let case = make_case(
        "ws_live_vs_pull",
        ready_seed(&["long_poll"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("e2ee_connected"),
            step_ws_push(5),
            step_await_host("apply_batch"),
            step_await_host("apply_batch"),
            step_await_host("apply_batch"),
            step_await_host("apply_batch"),
            step_await_host("apply_batch"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    let flags: Vec<(i64, bool, bool)> = find_host(&res.host, "apply_batch")
        .iter()
        .map(|v| {
            (
                v["args"]["cmd"].as_i64().unwrap_or(-1),
                v["args"]["increment_unread"].as_bool().unwrap_or(false),
                v["args"]["notify_incoming"].as_bool().unwrap_or(false),
            )
        })
        .collect();
    assert_eq!(
        flags,
        vec![
            (501, true, true),
            (521, true, true),
            (510, false, false),
            (511, false, false),
            (532, false, false),
        ]
    );
}

// -----------------------------------------------------------------------------
// 16. ws_typed_chat (+ WirePayloadHandle::resolve)
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t16_ws_typed_chat_and_name_resolve() {
    let plain_msg = json!({
        "data": {
            "msgs": [
                {
                    "msgId": "90001",
                    "cliMsgId": "c1",
                    "uidFrom": "200",
                    "idTo": "100",
                    "msgType": "webchat",
                    "content": "hello",
                    "ts": "1700000000000",
                    "dName": ""
                }
            ]
        }
    });
    let mut server = boot_http_entries();
    server.push(ws_auth_frame(json!([])));
    server.push(ws_frame(501, 1, plain_msg.clone()));
    let case = make_case(
        "ws_typed_chat",
        ready_seed(&["long_poll"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("e2ee_connected"),
            step_ws_push(1),
            step_await_host("apply_parsed_events"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    let parsed = find_host(&res.host, "apply_parsed_events");
    assert_eq!(parsed.len(), 1);
    assert_eq!(parsed[0]["args"]["cmd"], json!(501));
    assert_eq!(parsed[0]["args"]["increment_unread"], json!(true));
    assert_eq!(parsed[0]["args"]["notify_incoming"], json!(true));
    assert!(find_host(&res.host, "apply_batch").is_empty());

    // Verify WirePayloadHandle::resolve re-parses when a name lookup changes and returns None when unchanged.
    let map = plain_msg.as_object().cloned().unwrap_or_default();
    let olaz_core::typed_chat::PlainChatParse::Typed(env) =
        try_parse_plain_chat_pure(501, &map, "100", Some("self-100"))
    else {
        panic!("expected PlainChatParse::Typed");
    };
    assert!(env.payload.resolve("100", Some("self-100"), &[]).is_none());
    let updated = env.payload.resolve(
        "100",
        Some("self-100"),
        &[(
            "200".to_owned(),
            NameLookup {
                name: "Binh".to_owned(),
                avatar: "https://cdn/b.jpg".to_owned(),
            },
        )],
    );
    assert!(updated.is_some());
}

// -----------------------------------------------------------------------------
// 17. ws_auth_watch
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t17_ws_auth_watch() {
    let mut server = boot_http_entries();
    server.push(ws_auth_frame(json!([])));
    server.push(ws_close());
    server.push(ws_auth_frame(json!([])));
    let case = make_case(
        "ws_auth_watch",
        ready_seed(&["long_poll"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("e2ee_connected"),
            step_ws_push(1),
            step_await_host("e2ee_disconnected"),
            step_await_host("e2ee_connected"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    let auth_calls: Vec<&str> = host_names(&res.host)
        .into_iter()
        .filter(|&n| n == "e2ee_connected" || n == "e2ee_disconnected")
        .collect();
    assert_eq!(
        auth_calls,
        vec!["e2ee_connected", "e2ee_disconnected", "e2ee_connected"]
    );
}

// -----------------------------------------------------------------------------
// 18. ws_cursors (+ Claude's ordering rule: apply_batch strictly before persist_ws_cursors)
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t18_ws_cursors_seeded_pull_and_event_before_persist_order() {
    let mut seed = ready_seed(&["long_poll"]);
    seed.ws_cursors = Some(json!({
        "510_1": { "lastId": "42", "preIds": ["41"] }
    }));
    let mut server = boot_http_entries();
    // Auth lists queue 510/1 so WsCore sends initial pull with seeded lastId "42".
    server.push(ws_auth_frame(json!([
        { "cmd": 510, "subCmd": 1 }
    ])));
    // Frame 510/1 advances cursor to "99" (non-plain envelope with controls so it goes to apply_batch).
    server.push(ws_frame(
        510,
        1,
        json!({
            "data": {
                "controls": [],
                "lastActionId": "99",
                "msgs": []
            }
        }),
    ));
    let case = make_case(
        "ws_cursors",
        seed,
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("e2ee_connected"),
            step_ws_push(1),
            step_await_host("persist_ws_cursors"),
        ],
    );
    let res = run_case(&case).await.expect("case run");

    // Verify seeded cursor was sent in initial ws_send pull (cmd 510).
    let pull = res
        .requests
        .iter()
        .find(|r| r["kind"] == "ws_send" && r["cmd"] == 510)
        .expect("initial pull ws_send");
    assert_eq!(pull["payload"]["lastId"], json!(42));

    // Claude's ordering rule: `apply_batch` MUST precede `persist_ws_cursors`.
    let names = host_names(&res.host);
    let i_batch = names
        .iter()
        .position(|&n| n == "apply_batch")
        .expect("apply_batch");
    let i_cursors = names
        .iter()
        .position(|&n| n == "persist_ws_cursors")
        .expect("persist_ws_cursors");
    assert!(
        i_batch < i_cursors,
        "expected apply_batch before persist_ws_cursors, got {names:?}"
    );
    assert_eq!(
        res.host[i_cursors]["args"]["cursors"]["510_1"]["lastId"],
        json!("99")
    );
}

// -----------------------------------------------------------------------------
// 19. ws_stopped_on_logout
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t19_ws_stopped_on_logout_ignores_stale_ws_gen() {
    let mut state = CoreState::default();
    state.session.profile = Some(olaz_core::state::Profile {
        user_id: "100".to_owned(),
        display_name: "An".to_owned(),
        avatar: None,
        phone: None,
    });
    state.transport.ws_gen = 1;
    state.transport.ws_phase = WsPhase::Running;

    let out = reduce(&mut state, Input::Command(Command::LogOut));
    assert_eq!(state.transport.ws_phase, WsPhase::Stopped);
    assert!(state.transport.ws_gen > 1);
    assert!(out.effects.iter().any(|e| matches!(
        e,
        olaz_core::Effect::StopWs {
            reset_cursors: true
        }
    )));

    // Stale frame from old ws_gen=1 must produce no effects.
    let mut payload = Map::new();
    payload.insert("data".to_owned(), json!({ "controls": [] }));
    let stale = reduce(
        &mut state,
        Input::WsEvent {
            ws_gen: 1,
            cmd: 501,
            payload,
            now_unix_secs: 0,
        },
    );
    assert!(stale.effects.is_empty());
}

// -----------------------------------------------------------------------------
// 20. lp_tick (4 s delay, more=true twice -> exactly 2 polls per tick)
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t20_lp_tick_two_batches_and_persist_before_apply() {
    let mut seed = ready_seed(&["ws"]);
    seed.poll_state = Some(json!({
        "lastActionId": "10",
        "lastActionIdOther": "1",
        "queues": { "1": { "lastId": "10", "ids": [] } }
    }));
    let mut server = boot_http_entries();
    server.push(http_ok(
        "/",
        json!({ "error_code": 0, "data": { "lastActionId": "11", "more": 1 } }),
    ));
    server.push(http_ok(
        "/",
        json!({ "error_code": 0, "data": { "lastActionId": "12", "more": 1 } }),
    ));
    // A 3rd poll must NOT run in the same periodic tick (maxBatches=2).
    let case = make_case(
        "lp_tick",
        seed,
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("apply_batch"),
            step_await_host("apply_batch"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    let lp_reqs: Vec<&Value> = res
        .requests
        .iter()
        .filter(|r| r["kind"] == "http" && r["path"] == "/")
        .collect();
    assert_eq!(lp_reqs.len(), 2, "expected exactly 2 poll requests in tick");

    let lp_calls: Vec<&str> = host_names(&res.host)
        .into_iter()
        .filter(|&n| n == "persist_poll_state" || n == "apply_batch")
        .collect();
    assert_eq!(
        lp_calls,
        vec![
            "persist_poll_state",
            "apply_batch",
            "persist_poll_state",
            "apply_batch"
        ]
    );
    for b in find_host(&res.host, "apply_batch") {
        assert_eq!(b["args"]["cmd"], Value::Null);
        assert_eq!(b["args"]["increment_unread"], json!(true));
        assert_eq!(b["args"]["notify_incoming"], json!(true));
    }
}

// -----------------------------------------------------------------------------
// 21. lp_state_persist (only when state changed)
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t21_lp_state_persist_only_when_changed() {
    let mut server = boot_http_entries();
    server.push(http_ok(
        "/",
        json!({ "error_code": 0, "data": { "lastActionId": "1", "more": 0 } }),
    ));
    let case = make_case(
        "lp_state_persist",
        ready_seed(&["ws"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("apply_batch"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    assert!(find_host(&res.host, "persist_poll_state").is_empty());
    assert_eq!(find_host(&res.host, "apply_batch").len(), 1);
}

// -----------------------------------------------------------------------------
// 22. lp_auth_error
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t22_lp_auth_error_expires_and_stops_polling() {
    let mut server = boot_http_entries();
    server.push(http_ok(
        "/",
        json!({ "error_code": 600, "error_message": "session expired" }),
    ));
    let case = make_case(
        "lp_auth_error",
        ready_seed(&["ws"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("mark_expired"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    assert_eq!(
        res.final_state["sign_out_notice"],
        json!("Phiên đăng nhập đã hết hạn hoặc bị đăng xuất.")
    );
    assert_eq!(res.final_state["phase"]["kind"], json!("login"));
    assert!(find_host(&res.host, "apply_batch").is_empty());
}

// -----------------------------------------------------------------------------
// 23. lp_other_error (ends tick, next 4 s tick retries)
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t23_lp_other_error_retries_next_tick() {
    let mut server = boot_http_entries();
    server.push(http_err("/", "reset"));
    server.push(http_ok(
        "/",
        json!({ "error_code": 0, "data": { "lastActionId": "55", "more": 0 } }),
    ));
    let case = make_case(
        "lp_other_error",
        ready_seed(&["ws"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("apply_batch"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    let lp_reqs: Vec<&Value> = res
        .requests
        .iter()
        .filter(|r| r["kind"] == "http" && r["path"] == "/")
        .collect();
    assert_eq!(lp_reqs.len(), 2);
    assert_eq!(find_host(&res.host, "persist_poll_state").len(), 1);
    assert_eq!(find_host(&res.host, "apply_batch").len(), 1);
}

// -----------------------------------------------------------------------------
// 24. lp_mobile_sync_and_controls
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t24_lp_mobile_sync_and_controls_before_apply_batch() {
    let mut server = boot_http_entries();
    server.push(http_ok(
        "/",
        json!({
            "error_code": 0,
            "data": {
                "lastActionId": "77",
                "more": 0,
                "controls": [
                    { "act_type": "transfer_msg", "content": { "act": "user_confirm", "data": { "user_action": 1 } } },
                    { "act_type": "fr", "content": { "act": "pin_create", "data": { "conversationId": "300" } } }
                ]
            }
        }),
    ));
    let case = make_case(
        "lp_mobile_sync_and_controls",
        ready_seed(&["ws"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("apply_batch"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    let names: Vec<&str> = host_names(&res.host)
        .into_iter()
        .filter(|&n| {
            matches!(
                n,
                "persist_poll_state" | "mobile_sync" | "pin_topic" | "apply_batch"
            )
        })
        .collect();
    assert_eq!(
        names,
        vec![
            "persist_poll_state",
            "mobile_sync",
            "pin_topic",
            "apply_batch"
        ]
    );
    let b = find_host(&res.host, "apply_batch")[0];
    assert_eq!(b["args"]["cmd"], Value::Null);
    assert_eq!(b["args"]["increment_unread"], json!(true));
    assert_eq!(b["args"]["notify_incoming"], json!(true));
}

// -----------------------------------------------------------------------------
// 25. lp_stopped_on_logout
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t25_lp_stopped_on_logout() {
    let server = boot_http_entries();
    let case = make_case(
        "lp_stopped_on_logout",
        ready_seed(&["ws"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("start_long_poll"),
            Step::Cmd {
                cmd: "log_out".to_owned(),
                args: json!({}),
                now_ms: None,
                rand4: None,
            },
            step_await_host("reset_domains"),
        ],
    );
    let res = run_case(&case).await.expect("case run");
    let lp_reqs: Vec<&Value> = res
        .requests
        .iter()
        .filter(|r| r["kind"] == "http" && r["path"] == "/")
        .collect();
    assert!(
        lp_reqs.is_empty(),
        "expected no poll requests after log_out"
    );
}

// -----------------------------------------------------------------------------
// 26. drain_command (+ serialization ADR-018)
// -----------------------------------------------------------------------------
#[tokio::test(start_paused = true)]
async fn t26_drain_command_four_batches_flags_false_and_serialized() {
    let mut server = boot_http_entries();
    for i in 1..=4 {
        server.push(http_ok(
            "/",
            json!({
                "error_code": 0,
                "data": {
                    "lastActionId": format!("{}", i + 1),
                    "more": 1
                }
            }),
        ));
    }
    let case = make_case(
        "drain_command",
        ready_seed(&["ws", "long_poll"]),
        server,
        vec![
            step_start(),
            step_await_ready(),
            step_await_host("start_long_poll"),
            Step::Cmd {
                cmd: "drain_chat_polling".to_owned(),
                args: json!({ "max_batches": 4, "notify_incoming": false }),
                now_ms: None,
                rand4: None,
            },
        ],
    );
    let res = run_case(&case).await.expect("case run");
    let lp_reqs: Vec<&Value> = res
        .requests
        .iter()
        .filter(|r| r["kind"] == "http" && r["path"] == "/")
        .collect();
    assert_eq!(lp_reqs.len(), 4);
    let batches = find_host(&res.host, "apply_batch");
    assert_eq!(batches.len(), 4);
    for b in batches {
        assert_eq!(b["args"]["cmd"], Value::Null);
        assert_eq!(b["args"]["increment_unread"], json!(false));
        assert_eq!(b["args"]["notify_incoming"], json!(false));
    }
}

/// Verifies ADR-018 serialization: concurrent `drain_chat_polling` callers run strictly one after
/// another with no overlapping `FetchPollBatch` and exact `applied_count` returned to each caller.
#[tokio::test(start_paused = true)]
async fn adr018_concurrent_drains_are_serialized() {
    let mut state = CoreState::default();
    state.session.phase = Phase::Ready;
    state.session.profile = Some(olaz_core::state::Profile {
        user_id: "100".to_owned(),
        display_name: "An".to_owned(),
        avatar: None,
        phone: None,
    });
    state.transport.lp_gen = 1;
    state.transport.lp_running = true;

    let d1 = 100;
    let d2 = 101;

    let out1 = reduce(
        &mut state,
        Input::DrainRequested {
            drain_id: d1,
            max_batches: 2,
            notify_incoming: false,
        },
    );
    assert!(matches!(
        out1.effects.as_slice(),
        [olaz_core::Effect::FetchPollBatch {
            lp_gen: 1,
            drain_id,
            ..
        }] if *drain_id == d1
    ));

    // Second drain arrives while d1 is active: must queue without emitting FetchPollBatch yet.
    let out2 = reduce(
        &mut state,
        Input::DrainRequested {
            drain_id: d2,
            max_batches: 1,
            notify_incoming: true,
        },
    );
    assert!(out2.effects.is_empty());

    // Periodic tick while d1 is active: also queues behind d2 without overlapping.
    let out_tick = reduce(&mut state, Input::LpTick { lp_gen: 1 });
    assert!(out_tick.effects.is_empty());

    // d1 finishes batch 1 (more = false).
    let next_ps = PollState {
        last_action_id: "2".to_owned(),
        ..PollState::default()
    };
    let _ = reduce(
        &mut state,
        Input::PollBatchFetched {
            lp_gen: 1,
            drain_id: d1,
            result: Ok(olaz_core::PollBatchOutcome {
                payload: Map::new(),
                next_state: next_ps.clone(),
                more: false,
            }),
            now_unix_secs: 0,
        },
    );
    let out_done1 = reduce(
        &mut state,
        Input::PollBatchApplied {
            lp_gen: 1,
            drain_id: d1,
            delta: olaz_core::BatchApplyDelta {
                applied_count: 3,
                updates: Vec::new(),
                persist_conversations: false,
            },
        },
    );
    assert!(matches!(
        out_done1.effects.as_slice(),
        [
            olaz_core::Effect::CompleteDrain { drain_id: id1, total_events: 3 },
            olaz_core::Effect::FetchPollBatch { lp_gen: 1, drain_id: id2, poll_state },
        ] if *id1 == d1 && *id2 == d2 && poll_state.last_action_id == "2"
    ));

    // Finish d2 -> periodic tick begins next, and finishing periodic tick re-arms 4 s timer.
    let _ = reduce(
        &mut state,
        Input::PollBatchFetched {
            lp_gen: 1,
            drain_id: d2,
            result: Ok(olaz_core::PollBatchOutcome {
                payload: Map::new(),
                next_state: next_ps.clone(),
                more: false,
            }),
            now_unix_secs: 0,
        },
    );
    let out_done2 = reduce(
        &mut state,
        Input::PollBatchApplied {
            lp_gen: 1,
            drain_id: d2,
            delta: olaz_core::BatchApplyDelta {
                applied_count: 5,
                updates: Vec::new(),
                persist_conversations: false,
            },
        },
    );
    let periodic_id = match out_done2.effects.as_slice() {
        [
            olaz_core::Effect::CompleteDrain {
                drain_id: id2,
                total_events: 5,
            },
            olaz_core::Effect::FetchPollBatch {
                lp_gen: 1,
                drain_id: pid,
                ..
            },
        ] if *id2 == d2 => *pid,
        other => panic!("unexpected effects: {other:?}"),
    };

    let _ = reduce(
        &mut state,
        Input::PollBatchFetched {
            lp_gen: 1,
            drain_id: periodic_id,
            result: Ok(olaz_core::PollBatchOutcome {
                payload: Map::new(),
                next_state: next_ps,
                more: false,
            }),
            now_unix_secs: 0,
        },
    );
    let out_tick_done = reduce(
        &mut state,
        Input::PollBatchApplied {
            lp_gen: 1,
            drain_id: periodic_id,
            delta: olaz_core::BatchApplyDelta {
                applied_count: 1,
                updates: Vec::new(),
                persist_conversations: false,
            },
        },
    );
    assert!(matches!(
        out_tick_done.effects.as_slice(),
        [
            olaz_core::Effect::CompleteDrain {
                drain_id: pid,
                total_events: 1
            },
            olaz_core::Effect::StartLpTimer {
                lp_gen: 1,
                initial: false,
                delay,
            },
        ] if *pid == periodic_id && *delay == LP_TICK_INTERVAL
    ));
}

/// Verifies `CoreHandle::drain_chat_polling` returns the exact applied event count end-to-end.
#[tokio::test(start_paused = true)]
async fn core_handle_drain_chat_polling_returns_total_event_count() {
    use olaz_net::http::RawResponse;
    use olaz_net::mock::MockTransport;

    struct CountHost;

    #[async_trait::async_trait]
    impl Host for CountHost {
        async fn load_saved_session(&self) -> Option<String> {
            None
        }
        async fn load_legacy_cookie(&self) -> Option<olaz_core::LegacyCookie> {
            None
        }
        async fn load_transport_state(&self) -> PersistedTransportState {
            PersistedTransportState::default()
        }
        async fn set_pref(&self, _key: String, _value: String) {}
        async fn prepare_store(&self, _user_id: String, _account: LoginAccount) {}
        async fn start_bootstrap(&self) {}
        async fn offer_first_login_transfer(&self, _force: bool) {}
        async fn reset_domains(&self) {}
        async fn persist_session(&self, _snapshot_json: String) {}
        async fn clear_session(&self) {}
        async fn mark_expired(&self, _snapshot_json: String) {}
        async fn persist_poll_state(&self, _state: PollState) {}
        async fn persist_ws_cursors(&self, _cursors: olaz_ws::CursorMap) {}
        async fn apply_batch(
            &self,
            _cmd: Option<u16>,
            _increment_unread: bool,
            _notify_incoming: bool,
            _payload: Map<String, Value>,
        ) -> olaz_core::BatchApplyDelta {
            olaz_core::BatchApplyDelta {
                applied_count: 4,
                updates: Vec::new(),
                persist_conversations: false,
            }
        }
        async fn apply_parsed_events(
            &self,
            _cmd: u16,
            _increment_unread: bool,
            _notify_incoming: bool,
            _envelope: olaz_core::TypedChatEnvelope,
        ) -> olaz_core::BatchApplyDelta {
            olaz_core::BatchApplyDelta::default()
        }
        async fn mobile_sync(&self, _events: Vec<olaz_core::MobileSyncEvent>) {}
        async fn e2ee_signal(&self, _cmd: u16, _payload: Map<String, Value>) {}
        async fn e2ee_deliver_reports(&self, _cmd: u16, _payload: Map<String, Value>) {}
        async fn e2ee_connected(&self, _uid: String) {}
        async fn e2ee_disconnected(&self) {}
        async fn voip_control(&self, _act: String, _raw_data: Value, _data: Map<String, Value>) {}
        async fn show_typing(&self, _conv_id: String, _uid: String, _on_pc: bool) {}
        async fn pin_topic(&self, _conv_id: String) {}
        async fn group_notice(&self, _act: String, _data: Map<String, Value>, _ts: i64) {}
        async fn mute(
            &self,
            _conv_id: String,
            _set: bool,
            _start: i64,
            _start_explicit: bool,
            _duration: i64,
        ) {
        }
    }

    let transport = MockTransport::scripted(vec![
        Ok(RawResponse::new(
            200,
            br#"{"error_code":0,"data":{"lastActionId":"2","more":1}}"#.to_vec(),
        )),
        Ok(RawResponse::new(
            200,
            br#"{"error_code":0,"data":{"lastActionId":"3","more":0}}"#.to_vec(),
        )),
    ]);
    let client = Arc::new(SessionClient::new(
        transport,
        "imei-1".to_owned(),
        "Mac".to_owned(),
    ));
    let domains = ZaloDomains {
        isolated: true,
        lp_chat: "http://fake".to_owned(),
        ..ZaloDomains::default()
    };
    client.with_session(|s| s.domains = domains);

    let ws_driver: Arc<dyn WsDriver> = Arc::new(common::ScriptedWsDriver::new(
        &[],
        Arc::new(std::sync::Mutex::new(Vec::new())),
        true,
    ));
    let runner = Arc::new(SessionEffectRunner::with_options(
        client,
        Arc::new(CountHost),
        ws_driver,
        Handle::current(),
        None,
        true,
    ));
    let mut initial = CoreState::default();
    initial.session.phase = Phase::Ready;
    initial.transport.lp_gen = 1;
    initial.transport.lp_running = true;

    let core = CoreHandle::start_with_state(initial, runner, Handle::current());
    let total = tokio::time::timeout(Duration::from_secs(5), core.drain_chat_polling(4, false))
        .await
        .expect("drain finished");
    assert_eq!(total, 8);
    core.stop();
}

#[test]
fn persisted_ws_cursors_roundtrip_key_and_values() {
    let mut map = olaz_ws::CursorMap::new();
    map.insert(
        "510_1".to_owned(),
        WsQueueCursorSnapshot {
            last_id: "123".to_owned(),
            pre_ids: vec!["122".to_owned()],
        },
    );
    let json = serde_json::to_string(&map).expect("serialize");
    let decoded: olaz_ws::CursorMap = serde_json::from_str(&json).expect("deserialize");
    assert_eq!(decoded, map);
}

#[test]
fn drain_requested_while_ready_before_transport_start_queues_until_lp_running() {
    let mut state = CoreState::default();
    state.session.phase = Phase::Ready;
    state.transport.lp_running = false;

    let out = olaz_core::reduce::reduce(
        &mut state,
        Input::DrainRequested {
            drain_id: 77,
            max_batches: 4,
            notify_incoming: false,
        },
    );
    assert!(
        out.effects.is_empty(),
        "drain should queue until start_transport rather than completing immediately: {:?}",
        out.effects
    );

    // Once boot validation completes and starts transport, the queued drain starts immediately.
    let start_out = olaz_core::reduce::reduce(
        &mut state,
        Input::SyncProfileMeDone {
            boot_gen: 0,
            profile_synced: false,
            account: None,
            ws_endpoints: vec!["ws://fake".to_owned()],
        },
    );
    assert!(
        start_out.effects.iter().any(|e| matches!(
            e,
            olaz_core::effect::Effect::FetchPollBatch { drain_id: 77, .. }
        )),
        "expected queued drain_id=77 to start on start_transport: {:?}",
        start_out.effects
    );

    // If session expires while another drain is queued before transport start, it completes with 0.
    let mut exp_state = CoreState::default();
    exp_state.session.phase = Phase::Ready;
    exp_state.transport.lp_running = false;
    let out2 = olaz_core::reduce::reduce(
        &mut exp_state,
        Input::DrainRequested {
            drain_id: 88,
            max_batches: 2,
            notify_incoming: false,
        },
    );
    assert!(out2.effects.is_empty());
    let exp_out = olaz_core::reduce::reduce(
        &mut exp_state,
        Input::Command(olaz_core::input::Command::SessionExpired {
            reason: "expired".to_owned(),
        }),
    );
    assert!(exp_out.effects.iter().any(|e| matches!(
        e,
        olaz_core::effect::Effect::CompleteDrain {
            drain_id: 88,
            total_events: 0
        }
    )));
}

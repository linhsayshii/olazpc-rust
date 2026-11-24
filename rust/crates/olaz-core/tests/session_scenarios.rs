//! End-to-end integration tests covering all 20 session scenarios from U1a through the real
//! `olaz-core` actor, `SessionEffectRunner<ScriptedTransport>`, `olaz-net::SessionClient`, and
//! `RecordingHost` under `tokio::time::pause()`.

mod common;

use std::collections::BTreeMap;

use common::{
    AwaitPredicate, Case, Expect, HttpResponseSpec, Seed, ServerEntry, Step, compare_case, run_case,
};
use serde_json::{Value, json};

const TEST_ENK: &str = "MDEyMzQ1Njc4OWFiY2RlZg=="; // 16-byte AES-128 test key
const TEST_SEK: &str = "sek.11111.22222";
const TEST_IMEI: &str = "11111111-2222-4333-8444-555555555555-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn fake_domains() -> Value {
    json!({
        "auth": "http://fake",
        "wpaChat": "http://fake",
        "ws": ["ws://fake/ws"],
        "serviceCandidates": {
            "profile": ["http://fake"]
        },
        "isolated": true
    })
}

fn saved_session_json(user_id: &str, display_name: &str, send2me: &str) -> Value {
    json!({
        "zpwType": "23",
        "imei": TEST_IMEI,
        "computerName": "TestMac",
        "domains": fake_domains(),
        "plainAccount": {
            "userId": user_id,
            "displayName": display_name,
            "avatar": "https://cdn.example/saved.jpg",
            "phone": "+84901234567",
            "send2MeId": send2me,
            "dkey": "dk-1",
            "zpwEnk": TEST_ENK,
            "zpwSek": TEST_SEK
        }
    })
}

fn http_ok(path: &str, json_body: Value) -> ServerEntry {
    ServerEntry {
        kind: "http".to_owned(),
        path: path.to_owned(),
        method: Some("GET".to_owned()),
        repeat: false,
        response: Some(HttpResponseSpec {
            status: 200,
            json: Some(json_body),
            raw: None,
            error: None,
            headers: BTreeMap::new(),
        }),
        ..ServerEntry::default()
    }
}

fn http_repeat_ok(path: &str, json_body: Value) -> ServerEntry {
    let mut e = http_ok(path, json_body);
    e.repeat = true;
    e
}

fn http_error(path: &str, err: &str) -> ServerEntry {
    ServerEntry {
        kind: "http".to_owned(),
        path: path.to_owned(),
        method: Some("GET".to_owned()),
        repeat: false,
        response: Some(HttpResponseSpec {
            status: 0,
            json: None,
            raw: None,
            error: Some(err.to_owned()),
            headers: BTreeMap::new(),
        }),
        ..ServerEntry::default()
    }
}

fn reqqr_ok(payload: &str) -> ServerEntry {
    http_ok(
        "/api/login/reqqr",
        json!({
            "error_code": 0,
            "data": {
                "token_id": "tok-1",
                "qr_cnt": payload,
                "chk_wait_scan": "http://fake/api/login/waitScan",
                "chk_wait_cfirm": "http://fake/api/login/waitConfirm",
                "qr_timeout": 10,
                "qr_retry": 1
            }
        }),
    )
}

fn server_info_ok() -> ServerEntry {
    http_ok("/api/login/getServerInfo", json!({ "error_code": 0 }))
}

fn login_info_ok(uid: &str, need_sync_msg: bool) -> ServerEntry {
    http_ok(
        "/api/login/getLoginInfo",
        json!({
            "error_code": 0,
            "data": {
                "uid": uid,
                "display_name": "Nguyen An",
                "dkey": "dk-new",
                "zpw_enk": TEST_ENK,
                "zpw_sek": TEST_SEK,
                "send2me_id": format!("s2m-{uid}"),
                "need_sync_msg": need_sync_msg,
                "zpw_ws": ["ws://fake/ws"]
            }
        }),
    )
}

fn profile_me_ok(uid: &str, display_name: &str) -> ServerEntry {
    http_ok(
        "/api/social/profile/me-v2",
        json!({
            "error_code": 0,
            "data": {
                "profile": {
                    "userId": uid,
                    "displayName": display_name,
                    "avatar": "https://cdn.example/fresh.jpg",
                    "phoneNumber": "+84909999999"
                }
            }
        }),
    )
}

fn base_case(name: &str, seed: Seed, server: Vec<ServerEntry>, steps: Vec<Step>) -> Case {
    Case {
        format: 1,
        domain: "session".to_owned(),
        name: name.to_owned(),
        slow: false,
        seed,
        server,
        steps,
        expect: Expect {
            snapshots: BTreeMap::new(),
            final_state: Value::Null,
            requests: Vec::new(),
            host: Vec::new(),
        },
    }
}

fn cmd(name: &str) -> Step {
    Step::Cmd {
        cmd: name.to_owned(),
        args: json!({}),
    }
}

fn await_phase(phase: &str, step: Option<&str>) -> Step {
    Step::Await {
        predicate: AwaitPredicate {
            phase: phase.to_owned(),
            step: step.map(str::to_owned),
        },
        timeout_ms: Some(5000),
    }
}

fn snapshot(label: &str) -> Step {
    Step::Snapshot {
        snapshot: label.to_owned(),
    }
}

#[tokio::test(start_paused = true)]
async fn s01_qr_first_screen() -> Result<(), String> {
    let case = base_case(
        "qr_first_screen",
        Seed {
            domains: Some(fake_domains()),
            ..Seed::default()
        },
        vec![
            server_info_ok(),
            reqqr_ok("zalo://qr/first"),
            http_repeat_ok("/api/login/waitScan", json!({ "error_code": 8 })),
        ],
        vec![
            cmd("start"),
            await_phase("login", Some("generating")),
            snapshot("generating"),
            await_phase("login", Some("waiting_scan")),
        ],
    );
    let res = run_case(&case).await?;
    assert_eq!(res.snapshots["generating"]["phase"]["step"], "generating");
    assert_eq!(res.final_state["phase"]["step"], "waiting_scan");
    assert_eq!(res.final_state["phase"]["qr"], "zalo://qr/first");
    assert!(res.host.is_empty());
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn s02_qr_full_login() -> Result<(), String> {
    let case = base_case(
        "qr_full_login",
        Seed {
            domains: Some(fake_domains()),
            ..Seed::default()
        },
        vec![
            server_info_ok(),
            reqqr_ok("zalo://qr/full"),
            http_ok(
                "/api/login/waitScan",
                json!({
                    "error_code": 0,
                    "data": { "display_name": "An", "avatar": "https://cdn.example/scan.jpg" }
                }),
            ),
            http_ok(
                "/api/login/waitConfirm",
                json!({
                    "error_code": 0,
                    "data": { "zpw_sek": TEST_SEK }
                }),
            ),
            login_info_ok("1001", false),
            profile_me_ok("1001", "Nguyen An"),
        ],
        vec![
            cmd("start"),
            await_phase("login", Some("waiting_confirm")),
            snapshot("confirm"),
            await_phase("signing_in", None),
            snapshot("signing_in"),
            await_phase("ready", None),
        ],
    );
    let res = run_case(&case).await?;
    assert_eq!(res.snapshots["confirm"]["phase"]["name"], "An");
    assert_eq!(
        res.snapshots["confirm"]["phase"]["avatar"],
        "https://cdn.example/scan.jpg"
    );
    assert_eq!(res.snapshots["signing_in"]["phase"]["kind"], "signing_in");
    assert_eq!(res.final_state["phase"]["kind"], "ready");
    assert_eq!(res.final_state["profile"]["user_id"], "1001");
    assert_eq!(res.final_state["profile"]["display_name"], "Nguyen An");
    assert_eq!(res.final_state["sign_out_notice"], Value::Null);
    assert_eq!(res.final_state["prefs"]["didOfferInitialSync"], "0");
    assert_eq!(
        res.host,
        vec![
            json!({ "call": "persist_session", "args": {} }),
            json!({ "call": "persist_session", "args": {} }),
            json!({ "call": "prepare_store", "args": { "user_id": "1001" } }),
            json!({ "call": "start_ws", "args": { "endpoints": ["ws://fake/ws"] } }),
            json!({ "call": "start_long_poll", "args": {} }),
            json!({ "call": "start_bootstrap", "args": {} }),
            json!({ "call": "offer_first_login_transfer", "args": { "force": false } }),
        ]
    );
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn s03_qr_full_login_need_sync() -> Result<(), String> {
    let case = base_case(
        "qr_full_login_need_sync",
        Seed {
            domains: Some(fake_domains()),
            ..Seed::default()
        },
        vec![
            server_info_ok(),
            reqqr_ok("zalo://qr/sync"),
            http_ok(
                "/api/login/waitScan",
                json!({ "error_code": 0, "data": { "display_name": "An" } }),
            ),
            http_ok(
                "/api/login/waitConfirm",
                json!({ "error_code": 0, "data": { "zpw_sek": TEST_SEK } }),
            ),
            login_info_ok("1002", true),
            profile_me_ok("1002", "Nguyen An"),
        ],
        vec![cmd("start"), await_phase("ready", None)],
    );
    let res = run_case(&case).await?;
    assert_eq!(
        res.host.last(),
        Some(&json!({ "call": "offer_first_login_transfer", "args": { "force": true } }))
    );
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn s04_qr_rotated_while_waiting() -> Result<(), String> {
    let case = base_case(
        "qr_rotated_while_waiting",
        Seed {
            domains: Some(fake_domains()),
            ..Seed::default()
        },
        vec![
            server_info_ok(),
            reqqr_ok("zalo://qr/one"),
            http_ok(
                "/api/login/waitScan",
                json!({
                    "error_code": -20,
                    "data": {
                        "token_id": "tok-2",
                        "qr_cnt": "zalo://qr/two",
                        "chk_wait_scan": "http://fake/api/login/waitScan2",
                        "chk_wait_cfirm": "http://fake/api/login/waitConfirm",
                        "qr_timeout": 10,
                        "qr_retry": 1
                    }
                }),
            ),
            http_repeat_ok("/api/login/waitScan2", json!({ "error_code": 8 })),
        ],
        vec![cmd("start"), await_phase("login", Some("waiting_scan"))],
    );
    let res = run_case(&case).await?;
    assert_eq!(res.final_state["phase"]["step"], "waiting_scan");
    assert_eq!(res.final_state["phase"]["qr"], "zalo://qr/two");
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn s05_qr_timeout() -> Result<(), String> {
    // Single hanging waitScan hitting the real 60s deadline / 70s request-timeout floor.
    let case = base_case(
        "qr_timeout",
        Seed {
            domains: Some(fake_domains()),
            ..Seed::default()
        },
        vec![
            server_info_ok(),
            reqqr_ok("zalo://qr/timeout"),
            http_error("/api/login/waitScan", "timeout"),
        ],
        vec![cmd("start"), await_phase("login", Some("expired"))],
    );
    let res = run_case(&case).await?;
    assert_eq!(res.final_state["phase"]["step"], "expired");
    assert_eq!(res.final_state["phase"]["qr"], Value::Null);
    let scan_reqs = res
        .requests
        .iter()
        .filter(|r| r["path"] == "/api/login/waitScan")
        .count();
    assert_eq!(
        scan_reqs, 1,
        "single hanging waitScan must hit 70s timeout > 60s deadline"
    );
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn s06_qr_server_error_empty_and_non_empty() -> Result<(), String> {
    let empty_case = base_case(
        "qr_server_error_empty",
        Seed {
            domains: Some(fake_domains()),
            ..Seed::default()
        },
        vec![
            server_info_ok(),
            http_ok(
                "/api/login/reqqr",
                json!({ "error_code": -1, "error_message": "" }),
            ),
        ],
        vec![cmd("start"), await_phase("login", Some("failed"))],
    );
    let r1 = run_case(&empty_case).await?;
    assert_eq!(
        r1.final_state["phase"]["message"],
        "Zalo error -1: Không tạo được mã QR (/api/login/reqqr)"
    );

    let msg_case = base_case(
        "qr_server_error_msg",
        Seed {
            domains: Some(fake_domains()),
            ..Seed::default()
        },
        vec![
            server_info_ok(),
            http_ok(
                "/api/login/reqqr",
                json!({ "error_code": 42, "error_message": "Máy chủ bận" }),
            ),
        ],
        vec![cmd("start"), await_phase("login", Some("failed"))],
    );
    let r2 = run_case(&msg_case).await?;
    assert_eq!(
        r2.final_state["phase"]["message"],
        "Zalo error 42: Máy chủ bận (/api/login/reqqr)"
    );
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn s07_qr_missing_data() -> Result<(), String> {
    let case = base_case(
        "qr_missing_data",
        Seed {
            domains: Some(fake_domains()),
            ..Seed::default()
        },
        vec![
            server_info_ok(),
            http_ok("/api/login/reqqr", json!({ "error_code": 0 })),
        ],
        vec![cmd("start"), await_phase("login", Some("failed"))],
    );
    let res = run_case(&case).await?;
    assert_eq!(
        res.final_state["phase"]["message"],
        "Máy chủ không trả về dữ liệu QR."
    );
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn s08_qr_network_error() -> Result<(), String> {
    // A single non-repeat `refused` entry stops the listener immediately, so both
    // getServerInfo and reqqr get ECONNREFUSED and neither is recorded in `requests`.
    let case = base_case(
        "qr_network_error",
        Seed {
            domains: Some(fake_domains()),
            ..Seed::default()
        },
        vec![http_error("/api/login/reqqr", "refused")],
        vec![cmd("start"), await_phase("login", Some("failed"))],
    );
    let res = run_case(&case).await?;
    assert_eq!(
        res.final_state["phase"]["message"],
        "The operation couldn\u{2019}t be completed. (NSURLErrorDomain error -1004.)"
    );
    assert!(res.requests.is_empty());
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn s09_qr_confirm_rejected() -> Result<(), String> {
    let server_msg_case = base_case(
        "qr_confirm_rejected",
        Seed {
            domains: Some(fake_domains()),
            ..Seed::default()
        },
        vec![
            server_info_ok(),
            reqqr_ok("zalo://qr/rej"),
            http_ok(
                "/api/login/waitScan",
                json!({ "error_code": 0, "data": { "display_name": "An" } }),
            ),
            http_ok(
                "/api/login/waitConfirm",
                json!({
                    "error_code": -5,
                    "error_message": "Đăng nhập đã bị từ chối trên điện thoại."
                }),
            ),
        ],
        vec![cmd("start"), await_phase("login", Some("failed"))],
    );
    let res = run_case(&server_msg_case).await?;
    assert_eq!(
        res.final_state["phase"]["message"],
        "Đăng nhập đã bị từ chối trên điện thoại."
    );

    let fallback_case = base_case(
        "qr_confirm_rejected_empty_msg",
        Seed {
            domains: Some(fake_domains()),
            ..Seed::default()
        },
        vec![
            server_info_ok(),
            reqqr_ok("zalo://qr/rej2"),
            http_ok(
                "/api/login/waitScan",
                json!({ "error_code": 0, "data": { "display_name": "An" } }),
            ),
            http_ok(
                "/api/login/waitConfirm",
                json!({ "error_code": -5, "error_message": "" }),
            ),
        ],
        vec![cmd("start"), await_phase("login", Some("failed"))],
    );
    let res2 = run_case(&fallback_case).await?;
    assert_eq!(
        res2.final_state["phase"]["message"],
        "Đăng nhập bị từ chối (mã -5)."
    );
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn s10_boot_saved_session_valid() -> Result<(), String> {
    let case = base_case(
        "boot_saved_session_valid",
        Seed {
            saved_session: Some(saved_session_json("500", "Saved Name", "s2m-500")),
            ..Seed::default()
        },
        vec![
            login_info_ok("500", false),
            profile_me_ok("500", "Fresh Name"),
        ],
        vec![
            cmd("start"),
            await_phase("ready", None),
            snapshot("ready_before_sync"),
        ],
    );
    let res = run_case(&case).await?;
    assert_eq!(res.snapshots["ready_before_sync"]["phase"]["kind"], "ready");
    assert_eq!(
        res.snapshots["ready_before_sync"]["profile"]["display_name"],
        "Saved Name"
    );
    assert_eq!(res.final_state["phase"]["kind"], "ready");
    assert_eq!(res.final_state["profile"]["display_name"], "Fresh Name");
    assert_eq!(
        res.host,
        vec![
            json!({ "call": "prepare_store", "args": { "user_id": "500" } }),
            json!({ "call": "persist_session", "args": {} }),
            json!({ "call": "persist_session", "args": {} }),
            json!({ "call": "start_ws", "args": { "endpoints": ["ws://fake/ws"] } }),
            json!({ "call": "start_long_poll", "args": {} }),
            json!({ "call": "start_bootstrap", "args": {} }),
        ]
    );
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn s11_boot_saved_session_profile_fails() -> Result<(), String> {
    let case = base_case(
        "boot_saved_session_profile_fails",
        Seed {
            saved_session: Some(saved_session_json("501", "Saved Name", "s2m-501")),
            ..Seed::default()
        },
        vec![
            login_info_ok("501", false),
            http_error("/api/social/profile/me-v2", "refused"),
        ],
        vec![cmd("start"), await_phase("ready", None)],
    );
    let res = run_case(&case).await?;
    assert_eq!(res.final_state["phase"]["kind"], "ready");
    // Profile stays the saved/login-info one when syncProfileMe fails, no extra persist_session.
    assert_eq!(res.final_state["profile"]["user_id"], "501");
    let persist_count = res
        .host
        .iter()
        .filter(|h| h["call"] == "persist_session")
        .count();
    assert_eq!(persist_count, 1);
    assert!(
        res.requests
            .iter()
            .all(|r| r["path"] != "/api/social/profile/me-v2"),
        "refused me-v2 request must not be recorded"
    );
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn s12_boot_saved_session_expired() -> Result<(), String> {
    let case = base_case(
        "boot_saved_session_expired",
        Seed {
            saved_session: Some(saved_session_json("502", "Saved Name", "s2m-502")),
            domains: Some(fake_domains()),
            ..Seed::default()
        },
        vec![
            // getLoginInfo tries auth then wpaChat (both auth error 600).
            http_ok(
                "/api/login/getLoginInfo",
                json!({ "error_code": 600, "error_message": "expired" }),
            ),
            http_ok(
                "/api/login/getLoginInfo",
                json!({ "error_code": 600, "error_message": "expired" }),
            ),
            server_info_ok(),
            reqqr_ok("zalo://qr/relogin"),
            http_repeat_ok("/api/login/waitScan", json!({ "error_code": 8 })),
        ],
        vec![cmd("start"), await_phase("login", Some("waiting_scan"))],
    );
    let res = run_case(&case).await?;
    assert_eq!(res.final_state["phase"]["step"], "waiting_scan");
    assert_eq!(
        res.final_state["sign_out_notice"],
        "Phiên đăng nhập đã hết hạn. Vui lòng quét mã QR để đăng nhập lại."
    );
    assert_eq!(res.final_state["profile"], Value::Null);
    assert_eq!(
        res.host,
        vec![
            json!({ "call": "prepare_store", "args": { "user_id": "502" } }),
            json!({ "call": "mark_expired", "args": {} }),
        ]
    );
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn s13_boot_saved_session_unreachable() -> Result<(), String> {
    let case = base_case(
        "boot_saved_session_unreachable",
        Seed {
            saved_session: Some(saved_session_json("503", "Cached User", "s2m-503")),
            ..Seed::default()
        },
        vec![
            http_error("/api/login/getLoginInfo", "refused"),
            http_error("/api/login/getLoginInfo", "refused"),
            http_error("/api/social/profile/me-v2", "refused"),
            http_error("/api/social/profile/me-v2", "refused"),
            http_error("/api/social/profile/me-v2", "refused"),
            http_error("/api/social/profile/me-v2", "refused"),
        ],
        vec![cmd("start"), await_phase("ready", None)],
    );
    let res = run_case(&case).await?;
    assert_eq!(res.final_state["phase"]["kind"], "ready");
    assert_eq!(res.final_state["profile"]["display_name"], "Cached User");
    assert_eq!(
        res.host,
        vec![
            json!({ "call": "prepare_store", "args": { "user_id": "503" } }),
            json!({ "call": "start_ws", "args": { "endpoints": ["ws://fake/ws"] } }),
            json!({ "call": "start_long_poll", "args": {} }),
            json!({ "call": "start_bootstrap", "args": {} }),
        ]
    );
    assert!(res.requests.is_empty());
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn s14_boot_saved_session_empty_user() -> Result<(), String> {
    let case = base_case(
        "boot_saved_session_empty_user",
        Seed {
            saved_session: Some(saved_session_json("", "", "")),
            domains: Some(fake_domains()),
            ..Seed::default()
        },
        vec![
            server_info_ok(),
            reqqr_ok("zalo://qr/empty-uid"),
            http_repeat_ok("/api/login/waitScan", json!({ "error_code": 8 })),
        ],
        vec![cmd("start"), await_phase("login", Some("waiting_scan"))],
    );
    let res = run_case(&case).await?;
    assert_eq!(res.final_state["phase"]["step"], "waiting_scan");
    assert_eq!(res.final_state["phase"]["qr"], "zalo://qr/empty-uid");
    assert!(res.host.is_empty());
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn s15_boot_legacy_cookie() -> Result<(), String> {
    let case = base_case(
        "boot_legacy_cookie",
        Seed {
            domains: Some(fake_domains()),
            legacy_cookie: Some(json!({ "zpw_sek": TEST_SEK, "imei": TEST_IMEI })),
            ..Seed::default()
        },
        vec![
            // completeLogin (legacy cookie): getLoginInfo + syncProfileMe
            login_info_ok("600", false),
            profile_me_ok("600", "Legacy User"),
            // sessionStatus + syncProfileMe after boot ready
            login_info_ok("600", false),
            profile_me_ok("600", "Legacy User Updated"),
        ],
        vec![cmd("start"), await_phase("ready", None)],
    );
    let res = run_case(&case).await?;
    assert_eq!(res.final_state["phase"]["kind"], "ready");
    assert_eq!(
        res.final_state["profile"]["display_name"],
        "Legacy User Updated"
    );
    assert_eq!(
        res.host,
        vec![
            json!({ "call": "persist_session", "args": {} }),
            json!({ "call": "persist_session", "args": {} }),
            json!({ "call": "prepare_store", "args": { "user_id": "600" } }),
            json!({ "call": "persist_session", "args": {} }),
            json!({ "call": "persist_session", "args": {} }),
            json!({ "call": "start_ws", "args": { "endpoints": ["ws://fake/ws"] } }),
            json!({ "call": "start_long_poll", "args": {} }),
            json!({ "call": "start_bootstrap", "args": {} }),
        ]
    );
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn s16_log_out_from_ready() -> Result<(), String> {
    let case = base_case(
        "log_out_from_ready",
        Seed {
            saved_session: Some(saved_session_json("700", "Active User", "s2m-700")),
            domains: Some(fake_domains()),
            ..Seed::default()
        },
        vec![
            login_info_ok("700", false),
            profile_me_ok("700", "Active User"),
            server_info_ok(),
            reqqr_ok("zalo://qr/after-logout"),
            http_repeat_ok("/api/login/waitScan", json!({ "error_code": 8 })),
        ],
        vec![
            cmd("start"),
            await_phase("ready", None),
            cmd("log_out"),
            await_phase("login", Some("waiting_scan")),
        ],
    );
    let res = run_case(&case).await?;
    assert_eq!(res.final_state["phase"]["step"], "waiting_scan");
    assert_eq!(res.final_state["phase"]["qr"], "zalo://qr/after-logout");
    assert_eq!(res.final_state["profile"], Value::Null);
    assert_eq!(res.final_state["sign_out_notice"], Value::Null);
    let tail: Vec<&Value> = res.host.iter().rev().take(2).collect();
    assert_eq!(
        tail,
        vec![
            &json!({ "call": "reset_domains", "args": {} }),
            &json!({ "call": "clear_session", "args": {} }),
        ]
    );
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn s17_and_s18_session_expired_mid_session_then_refresh_qr() -> Result<(), String> {
    let case = base_case(
        "session_expired_then_refresh",
        Seed {
            saved_session: Some(saved_session_json("800", "Active User", "s2m-800")),
            domains: Some(fake_domains()),
            ..Seed::default()
        },
        vec![
            login_info_ok("800", false),
            profile_me_ok("800", "Active User"),
            server_info_ok(),
            reqqr_ok("zalo://qr/expired-1"),
            http_repeat_ok("/api/login/waitScan", json!({ "error_code": 8 })),
            server_info_ok(),
            reqqr_ok("zalo://qr/refreshed-2"),
        ],
        vec![
            cmd("start"),
            await_phase("ready", None),
            Step::Cmd {
                cmd: "session_expired".to_owned(),
                args: json!({ "reason": "Phiên hết hạn giữa chừng." }),
            },
            await_phase("login", Some("waiting_scan")),
            snapshot("after_expired"),
            cmd("refresh_qr"),
            await_phase("login", Some("generating")),
            await_phase("login", Some("waiting_scan")),
        ],
    );
    let res = run_case(&case).await?;
    assert_eq!(
        res.snapshots["after_expired"]["sign_out_notice"],
        "Phiên hết hạn giữa chừng."
    );
    assert_eq!(
        res.snapshots["after_expired"]["phase"]["qr"],
        "zalo://qr/expired-1"
    );
    assert_eq!(res.final_state["sign_out_notice"], Value::Null);
    assert_eq!(res.final_state["phase"]["qr"], "zalo://qr/refreshed-2");
    assert!(res.host.iter().any(|h| h["call"] == "mark_expired"));
    assert!(!res.host.iter().any(|h| h["call"] == "reset_domains"));
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn s19_profile_defaults() -> Result<(), String> {
    let case = base_case(
        "profile_defaults",
        Seed::default(),
        vec![],
        vec![Step::Cmd {
            cmd: "apply_account_profile".to_owned(),
            args: json!({
                "userId": "900",
                "displayName": "",
                "avatar": "",
                "phone": "",
                "send2MeId": ""
            }),
        }],
    );
    let res = run_case(&case).await?;
    assert_eq!(res.final_state["profile"]["user_id"], "900");
    assert_eq!(
        res.final_state["profile"]["display_name"],
        "Người dùng Zalo"
    );
    assert_eq!(res.final_state["profile"]["avatar"], Value::Null);
    assert_eq!(res.final_state["profile"]["phone"], Value::Null);
    assert_eq!(res.final_state["self_conversation_id"], "900");
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn s20_start_twice() -> Result<(), String> {
    let case = base_case(
        "start_twice",
        Seed {
            domains: Some(fake_domains()),
            ..Seed::default()
        },
        vec![
            server_info_ok(),
            reqqr_ok("zalo://qr/once"),
            http_repeat_ok("/api/login/waitScan", json!({ "error_code": 8 })),
        ],
        vec![
            cmd("start"),
            await_phase("login", Some("waiting_scan")),
            cmd("start"),
        ],
    );
    let res = run_case(&case).await?;
    let reqqr_count = res
        .requests
        .iter()
        .filter(|r| r["path"] == "/api/login/reqqr")
        .count();
    assert_eq!(reqqr_count, 1);
    assert!(res.host.is_empty());
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn compare_case_detects_mismatches_and_applies_known_diffs() -> Result<(), String> {
    let mut case = base_case(
        "diff_check",
        Seed::default(),
        vec![],
        vec![Step::Cmd {
            cmd: "apply_account_profile".to_owned(),
            args: json!({ "userId": "1", "displayName": "Minh" }),
        }],
    );
    let res = run_case(&case).await?;
    case.expect.final_state = res.final_state.clone();
    let mut used = vec![];
    assert!(compare_case(&case, &res, &[], &mut used).is_empty());

    case.expect.final_state["profile"]["display_name"] = json!("Wrong");
    let diffs = compare_case(&case, &res, &[], &mut used);
    assert_eq!(diffs.len(), 1);
    assert_eq!(diffs[0].path, "final.profile.display_name");
    Ok(())
}

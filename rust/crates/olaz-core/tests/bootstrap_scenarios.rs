//! Paused-time integration tests for U4 launch bootstrap (steps 1–8) covering:
//! - full end-to-end bootstrap + second-run SQLite probe-before-save skipping up-to-date history,
//! - aliases auth error abort & session expiry teardown,
//! - group history waves of 6 concurrent requests applied in exact `gids` order,
//! - dual-gated finalize waiting on slow concurrent long-poll drain,
//! - `Host::on_bootstrap_started` auto-trigger (`true`) vs suppression (`false`),
//! - mid-flight `LogOut` cancellation with no stale writes.

#![expect(clippy::expect_used, reason = "integration tests")]

mod common;

use std::collections::BTreeMap;
use std::future::Future;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use common::{
    AwaitPredicate, Case, Expect, HttpResponseSpec, ScriptedWsDriver, Seed, ServerEntry, Step,
    run_case,
};
use olaz_api::PollState;
use olaz_core::actor::CoreHandle;
use olaz_core::conversations::BatchApplyDelta;
use olaz_core::input::{Command, LegacyCookie};
use olaz_core::reduce::classify::MobileSyncEvent;
use olaz_core::runner::{Host, SessionEffectRunner, SharedStoreSlot, WsDriver};
use olaz_core::state::{CoreState, LoginStep, Phase};
use olaz_core::typed_chat::TypedChatEnvelope;
use olaz_crypto::{encode_aes, md5_hex, parse_secret_key};
use olaz_net::http::{RawResponse, RequestSpec, Transport};
use olaz_net::{LoginAccount, NetError, SessionClient, ZaloDomains};
use olaz_store::Store;
use olaz_ws::CursorMap;
use serde_json::{Map, Value, json};
use tokio::runtime::Handle;
use tokio::sync::Notify;

const TEST_IMEI: &str = "00000000-0000-4000-8000-000000000001-f39f277f3586bbc6c6ab67a11a27cc0a";
const TEST_ENK: &str = "0123456789abcdef";

fn service_map_json() -> Value {
    json!({
        "alias": ["http://fake"],
        "chat": ["http://fake"],
        "conversation": ["http://fake"],
        "file": ["http://fake"],
        "friend": ["http://fake"],
        "group": ["http://fake"],
        "group_cloud_message": ["http://fake"],
        "label": ["http://fake"],
        "profile": ["http://fake"],
        "reaction": ["http://fake"],
        "zcloud": ["http://fake"]
    })
}

fn test_domains_json() -> Value {
    json!({
        "isolated": true,
        "auth": "http://fake",
        "lpChat": "http://fake",
        "lpControl": "http://fake",
        "wpaChat": "http://fake",
        "preferredHosts": {},
        "serviceCandidates": service_map_json(),
        "ws": ["ws://fake"]
    })
}

fn test_domains() -> ZaloDomains {
    serde_json::from_value(test_domains_json()).expect("valid domains json")
}

fn bootstrap_seed(uid: &str, self_id: &str) -> Seed {
    Seed {
        saved_session: Some(json!({
            "version": 1,
            "imei": TEST_IMEI,
            "computerName": "TestMac",
            "zpwType": "23",
            "zpwSek": "sek.boot.1",
            "plainAccount": {
                "userId": uid,
                "displayName": "Me",
                "avatar": "https://cdn.example.invalid/me.jpg",
                "phone": "+84900000100",
                "send2MeId": self_id,
                "dkey": "dk",
                "needSyncMsg": false,
                "zpwEnk": TEST_ENK,
                "zpwSek": "sek.boot.1"
            },
            "domains": test_domains_json()
        })),
        domains: Some(test_domains_json()),
        suppress: vec!["ws".to_owned(), "long_poll".to_owned()],
        ws_auth: Some("manual".to_owned()),
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

fn http_ok_repeat(path: &str, body: Value) -> ServerEntry {
    ServerEntry {
        repeat: true,
        ..http_ok(path, body)
    }
}

fn login_and_profile_entries(uid: &str, self_id: &str) -> Vec<ServerEntry> {
    vec![
        http_ok(
            "/api/login/getLoginInfo",
            json!({
                "error_code": 0,
                "data": {
                    "uid": uid,
                    "dkey": "dk",
                    "zpw_enk": TEST_ENK,
                    "zpw_sek": "sek.boot.1",
                    "send2me_id": self_id,
                    "display_name": "Me",
                    "need_sync_msg": false,
                    "zpw_service_map_v3": service_map_json(),
                    "zpw_ws": ["ws://fake"]
                }
            }),
        ),
        http_ok(
            "/api/social/profile/me-v2",
            json!({
                "error_code": 0,
                "data": {
                    "profile": {
                        "userId": uid,
                        "displayName": "Me",
                        "avatar": "https://cdn.example.invalid/me.jpg",
                        "phoneNumber": "+84900000100"
                    }
                }
            }),
        ),
    ]
}

#[tokio::test(start_paused = true)]
async fn b01_full_bootstrap_and_second_run_probe_before_save_skips_up_to_date() {
    let uid = "2000901";
    let self_id = "9200901";
    let mut server = login_and_profile_entries(uid, self_id);
    server.extend([
        http_ok_repeat(
            "/api/alias/list",
            json!({
                "error_code": 0,
                "data": { "items": [{ "userId": "3000901", "alias": "Bestie" }] }
            }),
        ),
        http_ok_repeat("/", json!({ "error_code": 0, "data": { "more": 0 } })),
        http_ok_repeat(
            "/api/pinconvers/list",
            json!({ "error_code": 0, "data": { "conversations": ["3000901"] } }),
        ),
        http_ok_repeat(
            "/api/archivedchat/list",
            json!({ "error_code": 0, "data": { "items": [] } }),
        ),
        http_ok_repeat(
            "/api/social/profile/getmute",
            json!({
                "error_code": 0,
                "data": {
                    "chatEntries": [{ "id": "3000901", "duration": 3600, "startTime": 1_700_000_000 }]
                }
            }),
        ),
        http_ok_repeat("/api/convlabel/get", json!({ "error_code": 0, "data": {} })),
        http_ok_repeat(
            "/api/hiddenconvers/get-all",
            json!({ "error_code": 0, "data": { "pin": "", "threads": [] } }),
        ),
        http_ok_repeat(
            "/api/social/friend/getfriends",
            json!({
                "error_code": 0,
                "data": [{
                    "userId": "3000901",
                    "displayName": "Alice",
                    "avatar": "https://cdn.example.invalid/a.jpg"
                }]
            }),
        ),
        http_ok_repeat(
            "/api/group/getlg/v4",
            json!({
                "error_code": 0,
                "data": { "gridVerMap": { "500901": 1 }, "removedsGroup": [] }
            }),
        ),
        http_ok_repeat(
            "/api/group/getmg-v2",
            json!({
                "error_code": 0,
                "data": {
                    "gridInfoMap": {
                        "500901": {
                            "grid": "500901",
                            "name": "Dev Squad",
                            "avt": "https://cdn.example.invalid/g.jpg",
                            "totalMember": 4
                        }
                    }
                }
            }),
        ),
        http_ok_repeat(
            "/api/friend/requested/list",
            json!({ "error_code": 0, "data": [] }),
        ),
        http_ok_repeat(
            "/api/friend/recommendsv2/list",
            json!({ "error_code": 0, "data": { "recommItems": [] } }),
        ),
        // Preload overview returns clearUnreads + self + group messages
        http_ok_repeat(
            "/api/preloadconvers/get-last-msgs",
            json!({
                "error_code": 0,
                "data": {
                    "clearUnreads": [{ "id": "3000901", "type": 0 }],
                    "msgs": {
                        "9200901": [{
                            "msgId": "8001",
                            "cliMsgId": "cli_8001",
                            "uidFrom": uid,
                            "idTo": self_id,
                            "dName": "Me",
                            "content": "Note to self",
                            "msgType": "webchat",
                            "ts": 1_700_000_010_000_i64
                        }],
                        "g500901": [{
                            "msgId": "8002",
                            "cliMsgId": "cli_8002",
                            "uidFrom": "3000901",
                            "idTo": "500901",
                            "dName": "Alice",
                            "content": "Hi squad",
                            "msgType": "webchat",
                            "ts": 1_700_000_020_000_i64
                        }]
                    }
                }
            }),
        ),
        // Only called on first run (full refresh due); second run skips both because probed up_to_date!
        http_ok(
            "/api/cm/getrecentv2",
            json!({
                "error_code": 0,
                "data": {
                    "msgs": [{
                        "msgId": "8001",
                        "cliMsgId": "cli_8001",
                        "uidFrom": uid,
                        "idTo": self_id,
                        "dName": "Me",
                        "content": "Note to self",
                        "msgType": "webchat",
                        "ts": 1_700_000_010_000_i64
                    }]
                }
            }),
        ),
        http_ok(
            "/api/cm/getrecentv2",
            json!({
                "error_code": 0,
                "data": {
                    "msgs": [{
                        "msgId": "8002",
                        "cliMsgId": "cli_8002",
                        "uidFrom": "3000901",
                        "idTo": "500901",
                        "dName": "Alice",
                        "content": "Hi squad",
                        "msgType": "webchat",
                        "ts": 1_700_000_020_000_i64
                    }]
                }
            }),
        ),
    ]);

    let case = Case {
        format: 1,
        domain: "bootstrap".to_owned(),
        name: "b01_full_and_second_run".to_owned(),
        slow: false,
        seed: bootstrap_seed(uid, self_id),
        server,
        steps: vec![
            Step::Cmd {
                cmd: "start".to_owned(),
                args: Value::Null,
                now_ms: None,
                rand4: None,
            },
            Step::Await {
                predicate: AwaitPredicate {
                    phase: "ready".to_owned(),
                    step: None,
                },
                timeout_ms: Some(5000),
            },
            Step::Cmd {
                cmd: "bootstrap".to_owned(),
                args: Value::Null,
                now_ms: Some(1_700_100_000_000),
                rand4: None,
            },
            Step::Snapshot {
                snapshot: "after_first".to_owned(),
            },
            // Second bootstrap 100s later (< 24h): probe finds 8001 & 8002 in SQLite -> up_to_date!
            Step::Cmd {
                cmd: "bootstrap".to_owned(),
                args: Value::Null,
                now_ms: Some(1_700_100_100_000),
                rand4: None,
            },
        ],
        expect: Expect {
            snapshots: BTreeMap::new(),
            final_state: Value::Null,
            requests: Vec::new(),
            host: Vec::new(),
        },
    };

    let res = run_case(&case).await.expect("case runs");
    let first = res.snapshots.get("after_first").expect("after_first snap");

    // 1. First run persisted integral Swift Double format `1700100000.0` in SQLite.
    assert_eq!(
        first["store"]["prefs"]["history_full_refresh_at"],
        json!("1700100000.0")
    );
    assert_eq!(
        first["bootstrap_logs"],
        json!([
            "bootstrap: history full=true groups_fetch=1 up_to_date=0",
            "bootstrap: convs=3 friends=1 groups=1"
        ])
    );
    // Aliases merged and persisted.
    assert_eq!(
        first["store"]["prefs"]["aliases"]["3000901"],
        json!("Bestie")
    );

    // 2. Second run probed BEFORE saving, marked both self & group up_to_date, skipped `/api/cm/getrecentv2`.
    assert_eq!(
        res.final_state["history_freshness"][self_id],
        json!("up_to_date")
    );
    assert_eq!(
        res.final_state["history_freshness"]["g500901"],
        json!("up_to_date")
    );
    assert_eq!(
        res.final_state["store"]["prefs"]["history_full_refresh_at"],
        json!("1700100000.0")
    );
    assert_eq!(
        res.final_state["bootstrap_logs"],
        json!([
            "bootstrap: history full=true groups_fetch=1 up_to_date=0",
            "bootstrap: convs=3 friends=1 groups=1",
            "bootstrap: history full=false groups_fetch=0 up_to_date=2",
            "bootstrap: convs=3 friends=1 groups=1"
        ])
    );

    // Exactly 2 `/api/cm/getrecentv2` calls total (both from the first run, zero from the second).
    let history_calls = res
        .requests
        .iter()
        .filter(|r| r["path"] == "/api/cm/getrecentv2")
        .count();
    assert_eq!(history_calls, 2);

    // Host trace includes apply_mutes and two refresh_cloud calls.
    let mutes_calls: Vec<&Value> = res
        .host
        .iter()
        .filter(|h| h["call"] == "apply_mutes")
        .collect();
    assert_eq!(mutes_calls.len(), 2);
    assert_eq!(
        mutes_calls[0]["args"]["mutes"],
        json!([{ "conv_id": "3000901", "duration": 3600, "start": 1_700_000_000 }])
    );
    let cloud_calls = res
        .host
        .iter()
        .filter(|h| h["call"] == "refresh_cloud")
        .count();
    assert_eq!(cloud_calls, 2);
}

#[tokio::test(start_paused = true)]
async fn b02_aliases_auth_error_aborts_and_expires_session() {
    let uid = "2000902";
    let self_id = "9200902";
    let mut server = login_and_profile_entries(uid, self_id);
    server.extend([
        http_ok(
            "/api/alias/list",
            json!({ "error_code": 600, "error_message": "Session expired" }),
        ),
        http_ok(
            "/api/login/getServerInfo",
            json!({ "error_code": 0, "data": {} }),
        ),
        http_ok(
            "/api/login/reqqr",
            json!({
                "error_code": 0,
                "data": {
                    "token_id": "tok902",
                    "qr_cnt": "https://zalo.me/qr/b02",
                    "chk_wait_scan": "http://fake/api/login/waitScan",
                    "chk_wait_cfirm": "http://fake/api/login/waitCfirm",
                    "qr_retry": 1,
                    "qr_timeout": 60
                }
            }),
        ),
        ServerEntry {
            kind: "http".to_owned(),
            path: "/api/login/waitScan".to_owned(),
            response: Some(HttpResponseSpec {
                status: 200,
                json: None,
                raw: None,
                error: Some("timeout".to_owned()),
                headers: BTreeMap::new(),
            }),
            ..ServerEntry::default()
        },
    ]);

    let case = Case {
        format: 1,
        domain: "bootstrap".to_owned(),
        name: "b02_aliases_auth_error".to_owned(),
        slow: false,
        seed: bootstrap_seed(uid, self_id),
        server,
        steps: vec![
            Step::Cmd {
                cmd: "start".to_owned(),
                args: Value::Null,
                now_ms: None,
                rand4: None,
            },
            Step::Await {
                predicate: AwaitPredicate {
                    phase: "ready".to_owned(),
                    step: None,
                },
                timeout_ms: Some(5000),
            },
            Step::Cmd {
                cmd: "bootstrap".to_owned(),
                args: Value::Null,
                now_ms: Some(1_700_100_000_000),
                rand4: None,
            },
            Step::Await {
                predicate: AwaitPredicate {
                    phase: "login".to_owned(),
                    step: Some("waiting_scan".to_owned()),
                },
                timeout_ms: Some(5000),
            },
        ],
        expect: Expect {
            snapshots: BTreeMap::new(),
            final_state: Value::Null,
            requests: Vec::new(),
            host: Vec::new(),
        },
    };

    let res = run_case(&case).await.expect("case runs");
    assert_eq!(res.final_state["phase"]["kind"], json!("login"));
    assert_eq!(res.final_state["phase"]["step"], json!("waiting_scan"));
    assert!(res.final_state["sign_out_notice"].is_string());
    assert_eq!(res.final_state["store"], Value::Null);
    assert_eq!(res.final_state["flags"]["loaded"], json!(false));
    assert_eq!(res.final_state["bootstrap_logs"], json!([]));
    // No PAM, contacts, preload, or refresh_cloud after auth failure.
    assert!(
        !res.requests
            .iter()
            .any(|r| r["path"] == "/api/pinconvers/list"
                || r["path"] == "/api/preloadconvers/get-last-msgs")
    );
    assert!(!res.host.iter().any(|h| h["call"] == "refresh_cloud"));
    assert!(res.host.iter().any(|h| h["call"] == "mark_expired"));
}

fn derive_param_cipher_key(zcid: &str, zcid_ext: &str) -> Vec<u8> {
    let md5_upper = md5_hex(zcid_ext).to_uppercase();
    let n_even: Vec<char> = md5_upper.chars().step_by(2).collect();
    let a_even: Vec<char> = zcid.chars().step_by(2).collect();
    let a_odd: Vec<char> = zcid.chars().skip(1).step_by(2).collect();
    let key: String = n_even
        .iter()
        .take(8)
        .chain(a_even.iter().take(12))
        .chain(a_odd.iter().rev().take(12))
        .collect();
    key.into_bytes()
}

/// Custom scripted transport supporting per-path delays and an optional blocking gate.
struct DelayedBootstrapTransport {
    key: Vec<u8>,
    lp_delay: Duration,
    group_delays_ms: BTreeMap<String, u64>,
    group_count: usize,
    stall_pam: Arc<AtomicBool>,
    pam_hit: Arc<Notify>,
    pam_release: Arc<Notify>,
    active_history: Arc<AtomicUsize>,
    max_concurrent_history: Arc<AtomicUsize>,
    seen_paths: Arc<Mutex<Vec<String>>>,
}

fn encrypt_with_key(val: &Value, key: &[u8]) -> Vec<u8> {
    let Some(obj) = val.as_object() else {
        return serde_json::to_vec(val).unwrap_or_default();
    };
    if let Some(data) = obj.get("data")
        && (data.is_object() || data.is_array())
        && let Ok(raw) = serde_json::to_string(data)
        && let Ok(enc) = encode_aes(key, &raw)
    {
        let mut wrapped = obj.clone();
        wrapped.insert("data".to_owned(), Value::String(enc));
        return serde_json::to_vec(&Value::Object(wrapped)).unwrap_or_default();
    }
    serde_json::to_vec(val).unwrap_or_default()
}

impl Transport for DelayedBootstrapTransport {
    fn send(
        &self,
        request: RequestSpec,
    ) -> impl Future<Output = Result<RawResponse, NetError>> + Send {
        let path = request.path();
        self.seen_paths
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(path.clone());

        let lp_delay = self.lp_delay;
        let group_delays_ms = self.group_delays_ms.clone();
        let group_count = self.group_count;
        let stall_pam = Arc::clone(&self.stall_pam);
        let pam_hit = Arc::clone(&self.pam_hit);
        let pam_release = Arc::clone(&self.pam_release);
        let active_history = Arc::clone(&self.active_history);
        let max_concurrent_history = Arc::clone(&self.max_concurrent_history);
        let key = self.key.clone();

        // Decode `groupId` from encrypted params for `/api/cm/getrecentv2` so we know which group.
        let history_grid = if path == "/api/cm/getrecentv2" {
            let raw_params = request
                .query_value("params")
                .map(str::to_owned)
                .or_else(|| {
                    let body = request.body.as_deref()?;
                    let body_str = std::str::from_utf8(body).ok()?;
                    url::form_urlencoded::parse(body_str.as_bytes())
                        .find(|(k, _)| k == "params")
                        .map(|(_, v)| v.into_owned())
                });
            raw_params
                .and_then(|enc| olaz_crypto::decode_aes(&key, &enc).ok())
                .and_then(|plain| serde_json::from_str::<Value>(&plain).ok())
                .and_then(|v| {
                    v.get("groupId")
                        .and_then(Value::as_str)
                        .map(str::to_owned)
                        .or_else(|| {
                            v.get("groupId")
                                .and_then(Value::as_i64)
                                .map(|n| n.to_string())
                        })
                })
        } else {
            None
        };

        let resp_json = match path.as_str() {
            "/api/login/getLoginInfo" => json!({
                "error_code": 0,
                "data": {
                    "uid": "2000903",
                    "dkey": "dk",
                    "zpw_enk": TEST_ENK,
                    "zpw_sek": "sek.boot.1",
                    "send2me_id": "9200903",
                    "display_name": "Me",
                    "need_sync_msg": false,
                    "zpw_service_map_v3": service_map_json(),
                    "zpw_ws": ["ws://fake"]
                }
            }),
            "/api/social/profile/me-v2" => json!({
                "error_code": 0,
                "data": {
                    "profile": {
                        "userId": "2000903",
                        "displayName": "Me",
                        "avatar": ""
                    }
                }
            }),
            "/api/alias/list" => json!({ "error_code": 0, "data": { "items": [] } }),
            "/" => json!({ "error_code": 0, "data": { "more": 0 } }),
            "/api/pinconvers/list" => json!({ "error_code": 0, "data": { "conversations": [] } }),
            "/api/archivedchat/list" => json!({ "error_code": 0, "data": { "items": [] } }),
            "/api/social/profile/getmute" => {
                json!({ "error_code": 0, "data": { "chatEntries": [] } })
            }
            "/api/convlabel/get" => json!({ "error_code": 0, "data": {} }),
            "/api/hiddenconvers/get-all" => {
                json!({ "error_code": 0, "data": { "pin": "", "threads": [] } })
            }
            "/api/social/friend/getfriends" => json!({ "error_code": 0, "data": [] }),
            "/api/group/getlg/v4" => {
                let mut ver = Map::new();
                for i in 1..=group_count {
                    ver.insert(format!("{}", 500_000 + i), json!(1));
                }
                json!({ "error_code": 0, "data": { "gridVerMap": ver, "removedsGroup": [] } })
            }
            "/api/group/getmg-v2" => {
                let mut info = Map::new();
                for i in 1..=group_count {
                    let gid = format!("{}", 500_000 + i);
                    info.insert(
                        gid.clone(),
                        json!({
                            "grid": gid,
                            "name": format!("Group {i}"),
                            "avt": "",
                            "totalMember": 3
                        }),
                    );
                }
                json!({ "error_code": 0, "data": { "gridInfoMap": info } })
            }
            "/api/friend/requested/list" => json!({ "error_code": 0, "data": [] }),
            "/api/friend/recommendsv2/list" => {
                json!({ "error_code": 0, "data": { "recommItems": [] } })
            }
            "/api/preloadconvers/get-last-msgs" => {
                json!({ "error_code": 0, "data": { "clearUnreads": [], "msgs": {} } })
            }
            "/api/cm/getrecentv2" => {
                if let Some(grid) = &history_grid {
                    json!({
                        "error_code": 0,
                        "data": {
                            "msgs": [{
                                "msgId": format!("m_{grid}"),
                                "cliMsgId": format!("cli_{grid}"),
                                "uidFrom": "3000001",
                                "idTo": grid,
                                "dName": "Peer",
                                "content": format!("Hello {grid}"),
                                "msgType": "webchat",
                                "ts": 1_700_000_000_000_i64
                            }]
                        }
                    })
                } else {
                    json!({ "error_code": 0, "data": { "msgs": [] } })
                }
            }
            "/api/login/reqqr" => json!({
                "error_code": 0,
                "data": {
                    "token_id": "tok_logout",
                    "qr_cnt": "https://zalo.me/qr/after-logout",
                    "chk_wait_scan": "http://fake/api/login/waitScan",
                    "chk_wait_cfirm": "http://fake/api/login/waitCfirm",
                    "qr_retry": 1,
                    "qr_timeout": 60
                }
            }),
            _ => json!({ "error_code": 0, "data": {} }),
        };

        let param_cipher_key = match (request.query_value("zcid"), request.query_value("zcid_ext"))
        {
            (Some(zcid), Some(zcid_ext)) => Some(derive_param_cipher_key(zcid, zcid_ext)),
            _ => None,
        };
        let has_params = request.query_value("params").is_some()
            || request
                .body
                .as_deref()
                .and_then(|b| std::str::from_utf8(b).ok())
                .is_some_and(|s| s.contains("params="));
        let body = if let Some(pc_key) = param_cipher_key.as_deref() {
            encrypt_with_key(&resp_json, pc_key)
        } else if has_params && path != "/" {
            encrypt_with_key(&resp_json, &key)
        } else {
            serde_json::to_vec(&resp_json).unwrap_or_default()
        };

        async move {
            if path == "/api/pinconvers/list" && stall_pam.load(Ordering::Acquire) {
                pam_hit.notify_waiters();
                pam_release.notified().await;
            }
            if path == "/api/login/waitScan" {
                tokio::time::sleep(Duration::from_secs(60)).await;
            } else if path == "/" {
                tokio::time::sleep(lp_delay).await;
            } else if path == "/api/cm/getrecentv2"
                && let Some(grid) = history_grid
            {
                let prev = active_history.fetch_add(1, Ordering::AcqRel) + 1;
                max_concurrent_history.fetch_max(prev, Ordering::AcqRel);
                let ms = group_delays_ms.get(&grid).copied().unwrap_or(10);
                tokio::time::sleep(Duration::from_millis(ms)).await;
                active_history.fetch_sub(1, Ordering::AcqRel);
            } else {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            Ok(RawResponse::new(200, body))
        }
    }
}

struct ArcTransport<T>(Arc<T>);

impl<T: Transport> Transport for ArcTransport<T> {
    fn send(
        &self,
        request: RequestSpec,
    ) -> impl Future<Output = Result<RawResponse, NetError>> + Send {
        self.0.send(request)
    }
}

struct AutoBootstrapHost {
    saved_session: String,
    auto_trigger: bool,
    shared_store_slot: Mutex<Option<SharedStoreSlot>>,
    store: Mutex<Option<Arc<Mutex<Store>>>>,
    temp_dir: tempfile::TempDir,
    start_bootstrap_calls: AtomicUsize,
    refresh_cloud_calls: AtomicUsize,
    refresh_notify: Notify,
}

impl AutoBootstrapHost {
    fn new(uid: &str, self_id: &str, auto_trigger: bool) -> Self {
        let saved = json!({
            "version": 1,
            "imei": TEST_IMEI,
            "computerName": "TestMac",
            "zpwType": "23",
            "zpwSek": "sek.boot.1",
            "plainAccount": {
                "userId": uid,
                "displayName": "Me",
                "avatar": "",
                "phone": "",
                "send2MeId": self_id,
                "dkey": "dk",
                "needSyncMsg": false,
                "zpwEnk": TEST_ENK,
                "zpwSek": "sek.boot.1"
            },
            "domains": test_domains_json()
        });
        Self {
            saved_session: saved.to_string(),
            auto_trigger,
            shared_store_slot: Mutex::new(None),
            store: Mutex::new(None),
            temp_dir: tempfile::tempdir().expect("tempdir"),
            start_bootstrap_calls: AtomicUsize::new(0),
            refresh_cloud_calls: AtomicUsize::new(0),
            refresh_notify: Notify::new(),
        }
    }

    fn bind_store_slot(&self, slot: SharedStoreSlot) {
        *self
            .shared_store_slot
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(slot);
    }

    fn store_arc(&self) -> Option<Arc<Mutex<Store>>> {
        self.store
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }
}

#[async_trait]
impl Host for AutoBootstrapHost {
    async fn load_saved_session(&self) -> Option<String> {
        Some(self.saved_session.clone())
    }
    async fn load_legacy_cookie(&self) -> Option<LegacyCookie> {
        None
    }
    async fn set_pref(&self, _key: String, _value: String) {}
    async fn prepare_store(&self, user_id: String, _account: LoginAccount) {
        let db = self.temp_dir.path().join(format!("{user_id}.sqlite"));
        let store = Arc::new(Mutex::new(Store::open(&db).expect("open sqlite")));
        *self.store.lock().unwrap_or_else(PoisonError::into_inner) = Some(Arc::clone(&store));
        if let Some(slot) = self
            .shared_store_slot
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
        {
            *slot.lock().unwrap_or_else(PoisonError::into_inner) = Some(store);
        }
    }
    async fn start_bootstrap(&self) {
        self.start_bootstrap_calls.fetch_add(1, Ordering::AcqRel);
    }
    async fn on_bootstrap_started(&self) -> bool {
        self.start_bootstrap().await;
        self.auto_trigger
    }
    async fn refresh_cloud(&self) {
        self.refresh_cloud_calls.fetch_add(1, Ordering::AcqRel);
        self.refresh_notify.notify_waiters();
    }
    async fn offer_first_login_transfer(&self, _force: bool) {}
    async fn reset_domains(&self) {
        *self.store.lock().unwrap_or_else(PoisonError::into_inner) = None;
    }
    async fn persist_session(&self, _snapshot_json: String) {}
    async fn clear_session(&self) {}
    async fn mark_expired(&self, _snapshot_json: String) {
        *self.store.lock().unwrap_or_else(PoisonError::into_inner) = None;
    }
    async fn on_ws_started(&self, _endpoints: Vec<String>) -> bool {
        false
    }
    async fn on_long_poll_started(&self) -> bool {
        false
    }
    async fn persist_poll_state(&self, _state: PollState) {}
    async fn persist_ws_cursors(&self, _cursors: CursorMap) {}
    async fn apply_batch(
        &self,
        _cmd: Option<u16>,
        _increment_unread: bool,
        _notify_incoming: bool,
        _payload: Map<String, Value>,
    ) -> BatchApplyDelta {
        BatchApplyDelta::default()
    }
    async fn apply_parsed_events(
        &self,
        _cmd: u16,
        _increment_unread: bool,
        _notify_incoming: bool,
        _envelope: TypedChatEnvelope,
    ) -> BatchApplyDelta {
        BatchApplyDelta::default()
    }
    async fn mobile_sync(&self, _events: Vec<MobileSyncEvent>) {}
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

fn build_harness(
    transport: Arc<DelayedBootstrapTransport>,
    host: Arc<AutoBootstrapHost>,
) -> CoreHandle {
    let client = Arc::new(SessionClient::new(
        ArcTransport(transport),
        TEST_IMEI.to_owned(),
        "TestMac".to_owned(),
    ));
    client.with_session(|s| s.domains = test_domains());
    let ws_driver = Arc::new(ScriptedWsDriver::with_auth_mode(
        &[],
        Arc::new(Mutex::new(Vec::new())),
        true,
        true,
    ));
    let runner = Arc::new(SessionEffectRunner::with_options(
        client,
        Arc::clone(&host) as Arc<dyn Host>,
        ws_driver as Arc<dyn WsDriver>,
        Handle::current(),
        Some(test_domains()),
        true,
    ));
    host.bind_store_slot(runner.shared_store_slot());
    CoreHandle::start_with_state(CoreState::default(), runner, Handle::current())
}

#[tokio::test(start_paused = true)]
async fn b03_group_waves_cap_at_6_concurrent_and_preserve_gids_order() {
    let mut delays = BTreeMap::new();
    // Reverse completion times within wave 1 (6 groups) so 500006 finishes first and 500001 last.
    delays.insert("500001".to_owned(), 600);
    delays.insert("500002".to_owned(), 500);
    delays.insert("500003".to_owned(), 400);
    delays.insert("500004".to_owned(), 300);
    delays.insert("500005".to_owned(), 200);
    delays.insert("500006".to_owned(), 100);
    // Wave 2 (2 groups)
    delays.insert("500007".to_owned(), 200);
    delays.insert("500008".to_owned(), 50);

    let max_concurrent = Arc::new(AtomicUsize::new(0));
    let transport = Arc::new(DelayedBootstrapTransport {
        key: parse_secret_key(TEST_ENK),
        lp_delay: Duration::from_millis(10),
        group_delays_ms: delays,
        group_count: 8,
        stall_pam: Arc::new(AtomicBool::new(false)),
        pam_hit: Arc::new(Notify::new()),
        pam_release: Arc::new(Notify::new()),
        active_history: Arc::new(AtomicUsize::new(0)),
        max_concurrent_history: Arc::clone(&max_concurrent),
        seen_paths: Arc::new(Mutex::new(Vec::new())),
    });
    let host = Arc::new(AutoBootstrapHost::new("2000903", "9200903", false));
    let core = build_harness(transport, Arc::clone(&host));

    core.send(Command::Start);
    tokio::time::timeout(Duration::from_secs(5), core.wait_idle())
        .await
        .expect("ready idle");
    assert_eq!(core.snapshot().await.expect("snap").phase, Phase::Ready);

    core.request_unit(Command::Bootstrap {
        now_ms: 1_700_200_000_000,
    })
    .await;

    // Peak concurrency during group waves must be exactly 6 (never 8).
    assert_eq!(max_concurrent.load(Ordering::Acquire), 6);

    let full = core.full_snapshot().await.expect("full snap");
    assert_eq!(
        full.messages.bootstrap_logs,
        vec![
            "bootstrap: history full=true groups_fetch=8 up_to_date=0",
            "bootstrap: convs=9 friends=0 groups=8"
        ]
    );
    // Full refresh leaves history_freshness empty and persists all 8 group messages to SQLite.
    assert!(full.messages.history_freshness.is_empty());
    let store = host.store_arc().expect("store open");
    let guard = store.lock().unwrap_or_else(PoisonError::into_inner);
    for i in 1..=8 {
        let grid = format!("{}", 500_000 + i);
        let cid = format!("g{grid}");
        let msgs = guard.messages(&cid, None, 10).expect("read group messages");
        assert_eq!(msgs.len(), 1, "expected 1 stored message for {cid}");
        assert_eq!(msgs[0].id, format!("m_{grid}"));
        assert_eq!(msgs[0].text, format!("Hello {grid}"));
    }
    drop(guard);
    assert_eq!(host.refresh_cloud_calls.load(Ordering::Acquire), 1);
}

#[tokio::test(start_paused = true)]
async fn b04_finalize_dual_gate_waits_for_slow_lp_drain_after_waves() {
    let transport = Arc::new(DelayedBootstrapTransport {
        key: parse_secret_key(TEST_ENK),
        lp_delay: Duration::from_secs(5),
        group_delays_ms: BTreeMap::new(),
        group_count: 1,
        stall_pam: Arc::new(AtomicBool::new(false)),
        pam_hit: Arc::new(Notify::new()),
        pam_release: Arc::new(Notify::new()),
        active_history: Arc::new(AtomicUsize::new(0)),
        max_concurrent_history: Arc::new(AtomicUsize::new(0)),
        seen_paths: Arc::new(Mutex::new(Vec::new())),
    });
    let host = Arc::new(AutoBootstrapHost::new("2000903", "9200903", false));
    let core = build_harness(transport, Arc::clone(&host));

    core.send(Command::Start);
    tokio::time::timeout(Duration::from_secs(2), core.wait_idle())
        .await
        .expect("ready idle");

    // Fire bootstrap asynchronously so we can inspect state while LP drain is still sleeping (5s).
    core.send(Command::Bootstrap {
        now_ms: 1_700_300_000_000,
    });

    // Let bootstrap steps (10ms each) & group wave finish (~200ms), while LP drain still sleeps (5s).
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert_eq!(
        host.refresh_cloud_calls.load(Ordering::Acquire),
        0,
        "finalize must wait for LpDrainDone"
    );

    // Wait for the 5s LP drain + finalize to settle cleanly.
    tokio::time::timeout(Duration::from_secs(10), core.wait_idle())
        .await
        .expect("bootstrap idle");

    assert_eq!(host.refresh_cloud_calls.load(Ordering::Acquire), 1);
    let store = host.store_arc().expect("store open");
    let pref = store
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .get_preference_string("historyFullRefreshAt")
        .expect("read pref");
    assert_eq!(pref.as_deref(), Some("1700300000.0"));
}

#[tokio::test(start_paused = true)]
async fn b05_on_bootstrap_started_true_auto_triggers_and_false_suppresses() {
    // Case A: auto_trigger = true (production Host default)
    let transport_auto = Arc::new(DelayedBootstrapTransport {
        key: parse_secret_key(TEST_ENK),
        lp_delay: Duration::from_millis(10),
        group_delays_ms: BTreeMap::new(),
        group_count: 1,
        stall_pam: Arc::new(AtomicBool::new(false)),
        pam_hit: Arc::new(Notify::new()),
        pam_release: Arc::new(Notify::new()),
        active_history: Arc::new(AtomicUsize::new(0)),
        max_concurrent_history: Arc::new(AtomicUsize::new(0)),
        seen_paths: Arc::new(Mutex::new(Vec::new())),
    });
    let host_auto = Arc::new(AutoBootstrapHost::new("2000903", "9200903", true));
    let core_auto = build_harness(Arc::clone(&transport_auto), Arc::clone(&host_auto));

    core_auto.send(Command::Start);
    tokio::time::timeout(Duration::from_secs(5), core_auto.wait_idle())
        .await
        .expect("auto bootstrap idle");

    assert_eq!(host_auto.start_bootstrap_calls.load(Ordering::Acquire), 1);
    assert_eq!(host_auto.refresh_cloud_calls.load(Ordering::Acquire), 1);
    assert!(
        transport_auto
            .seen_paths
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .any(|p| p == "/api/alias/list")
    );

    // Case B: auto_trigger = false (RecordingHost behavior)
    let transport_sup = Arc::new(DelayedBootstrapTransport {
        key: parse_secret_key(TEST_ENK),
        lp_delay: Duration::from_millis(10),
        group_delays_ms: BTreeMap::new(),
        group_count: 1,
        stall_pam: Arc::new(AtomicBool::new(false)),
        pam_hit: Arc::new(Notify::new()),
        pam_release: Arc::new(Notify::new()),
        active_history: Arc::new(AtomicUsize::new(0)),
        max_concurrent_history: Arc::new(AtomicUsize::new(0)),
        seen_paths: Arc::new(Mutex::new(Vec::new())),
    });
    let host_sup = Arc::new(AutoBootstrapHost::new("2000903", "9200903", false));
    let core_sup = build_harness(Arc::clone(&transport_sup), Arc::clone(&host_sup));

    core_sup.send(Command::Start);
    tokio::time::timeout(Duration::from_secs(5), core_sup.wait_idle())
        .await
        .expect("suppressed idle");

    assert_eq!(host_sup.start_bootstrap_calls.load(Ordering::Acquire), 1);
    assert_eq!(host_sup.refresh_cloud_calls.load(Ordering::Acquire), 0);
    assert!(
        !transport_sup
            .seen_paths
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .any(|p| p == "/api/alias/list")
    );
}

#[tokio::test(start_paused = true)]
async fn b06_logout_mid_bootstrap_cancels_inflight_tasks_and_drops_stale_writes() {
    let pam_hit = Arc::new(Notify::new());
    let pam_release = Arc::new(Notify::new());
    let transport = Arc::new(DelayedBootstrapTransport {
        key: parse_secret_key(TEST_ENK),
        lp_delay: Duration::from_secs(10),
        group_delays_ms: BTreeMap::new(),
        group_count: 2,
        stall_pam: Arc::new(AtomicBool::new(true)),
        pam_hit: Arc::clone(&pam_hit),
        pam_release: Arc::clone(&pam_release),
        active_history: Arc::new(AtomicUsize::new(0)),
        max_concurrent_history: Arc::new(AtomicUsize::new(0)),
        seen_paths: Arc::new(Mutex::new(Vec::new())),
    });
    let host = Arc::new(AutoBootstrapHost::new("2000903", "9200903", false));
    let core = build_harness(Arc::clone(&transport), Arc::clone(&host));

    core.send(Command::Start);
    tokio::time::timeout(Duration::from_secs(5), core.wait_idle())
        .await
        .expect("ready idle");

    // Start bootstrap and wait until PAM is in flight.
    core.send(Command::Bootstrap {
        now_ms: 1_700_400_000_000,
    });
    tokio::time::timeout(Duration::from_secs(5), pam_hit.notified())
        .await
        .expect("PAM request reached transport");

    // Log out mid-flight: cancels bootstrap tasks, resets domains, starts QR login.
    core.send(Command::LogOut);
    pam_release.notify_waiters();

    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Some(snap) = core.snapshot().await
                && matches!(
                    snap.phase,
                    Phase::Login(ref l) if l.step == LoginStep::WaitingScan
                )
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("logout reached waiting_scan");

    let snap = core.full_snapshot().await.expect("snap");
    assert!(
        matches!(
            snap.session.phase,
            Phase::Login(ref l) if l.step == LoginStep::WaitingScan
        ),
        "expected login waiting_scan, got {:?}",
        snap.session.phase
    );
    assert!(snap.messages.bootstrap_logs.is_empty());
    assert!(snap.conversations.conversations.is_empty());
    assert_eq!(host.refresh_cloud_calls.load(Ordering::Acquire), 0);
    assert!(host.store_arc().is_none());
    // Ensure later steps (labels, preload, history) never ran after cancellation.
    assert!(
        !transport
            .seen_paths
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .any(|p| p == "/api/convlabel/get" || p == "/api/preloadconvers/get-last-msgs")
    );
}

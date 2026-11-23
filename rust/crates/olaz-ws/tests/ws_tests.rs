#![allow(clippy::unwrap_used, clippy::expect_used)]
//! Ports of the Swift tests touching `ZaloWebSocket` (NativeProtocolTests,
//! FeatureFixesTests) plus golden frames produced by the Swift code
//! (`/private/tmp/claude-501/olaz-port/ws/probe.swift`, verbatim copies of
//! `encodeFrame` / `encodeRequestFrame` compiled with swiftc).

use std::collections::BTreeMap;
use std::time::Duration;

use olaz_ws::consts::*;
use olaz_ws::frame::{decode_frame, encode_frame, encode_frame_json, encode_request_frame};
use olaz_ws::queue::{highest_action_id, queues_from_auth};
use olaz_ws::*;
use serde_json::{Map, Value, json};

fn obj(v: Value) -> Map<String, Value> {
    match v {
        Value::Object(m) => m,
        _ => panic!("not an object"),
    }
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn no_decrypt() -> impl Fn(Option<&[u8]>, u8, &str) -> Result<Vec<u8>, DecryptError> {
    |_, enc, data| {
        if enc == 0 {
            Ok(data.as_bytes().to_vec())
        } else {
            Err(DecryptError("no decryptor".into()))
        }
    }
}

// ---- Swift: wsFrameCodecURLSlashAndAuthQueues -------------------------------------------

#[test]
fn ws_frame_codec_roundtrip() {
    let encoded = encode_frame_json(510, 1, 1, Some(&obj(json!({"first": true}))));
    let decoded = decode_frame(&encoded).unwrap();
    assert_eq!(decoded.version, 1);
    assert_eq!(decoded.cmd, 510);
    assert_eq!(decoded.sub_cmd, 1);
    assert_eq!(decoded.envelope.get("first"), Some(&Value::Bool(true)));
}

#[test]
fn ws_url_has_slash_before_query() {
    let url = build_socket_url("wss://ws1-msg.chat.zalo.me", 123456);
    assert!(url.starts_with("wss://ws1-msg.chat.zalo.me/?"));
    assert_eq!(
        url,
        "wss://ws1-msg.chat.zalo.me/?zpw_ver=694&zpw_type=23&t=123456"
    );
}

#[test]
fn ws_url_variants() {
    // path already present: no extra slash
    assert_eq!(
        build_socket_url("wss://h.example/ws", 1),
        "wss://h.example/ws?zpw_ver=694&zpw_type=23&t=1"
    );
    // existing query preserved
    assert_eq!(
        build_socket_url("wss://h.example?a=b", 1),
        "wss://h.example/?a=b&zpw_ver=694&zpw_type=23&t=1"
    );
    // empty query dropped
    assert_eq!(
        build_socket_url("wss://h.example?", 1),
        "wss://h.example/?zpw_ver=694&zpw_type=23&t=1"
    );
    // no scheme: hostPart itself is inspected
    assert_eq!(
        build_socket_url("h.example", 1),
        "h.example/?zpw_ver=694&zpw_type=23&t=1"
    );
}

#[test]
fn queues_from_auth_dedups_and_orders() {
    let auth = obj(json!({
        "data": {
            "ctrl_qCmds": [{"cmd": 603, "subCmd": 1}, {"cmd": 604, "subCmd": 0}],
            "qCmds": [{"cmd": 510, "subCmd": 1}, {"cmd": 510, "subCmd": 1}, {"cmd": 511, "subCmd": 0}]
        }
    }));
    let queues = queues_from_auth(&auth);
    assert_eq!(queues.len(), 4);
    assert!(queues.contains(&WsQueue {
        cmd: 603,
        sub_cmd: 1
    }));
    assert!(queues.contains(&WsQueue {
        cmd: 510,
        sub_cmd: 1
    }));
    assert_eq!(
        queues[0],
        WsQueue {
            cmd: 603,
            sub_cmd: 1
        }
    );
    assert_eq!(
        queues[3],
        WsQueue {
            cmd: 511,
            sub_cmd: 0
        }
    );
}

#[test]
fn queues_from_auth_edge_cases() {
    let auth = obj(json!({"data": {"qCmds": [
        {"cmd": 70000, "subCmd": 1}, {"cmd": -1}, {"cmd": "510"}, {"cmd": 511, "subCmd": 999},
        {"cmd": 512, "subCmd": -4}, {"subCmd": 1}
    ]}}));
    let q = queues_from_auth(&auth);
    assert_eq!(
        q,
        vec![
            WsQueue {
                cmd: 510,
                sub_cmd: 0
            },
            WsQueue {
                cmd: 511,
                sub_cmd: 255
            },
            WsQueue {
                cmd: 512,
                sub_cmd: 0
            },
        ]
    );
    // a non-object element invalidates the whole list (`as? [[String: Any]]`)
    let bad = obj(json!({"data": {"qCmds": [{"cmd": 510}, 5]}}));
    assert!(queues_from_auth(&bad).is_empty());
    assert!(queues_from_auth(&obj(json!({}))).is_empty());
}

// ---- Swift: e2eeSubmitBundle request frame ------------------------------------------------

#[test]
fn encode_request_frame_wraps_inner_data_once() {
    let inner = obj(json!({"delSS": 0}));
    let frame = encode_request_frame(CMD_E2EE_SUBMIT_BUNDLE, 0, 1, "req_540", &inner);
    let decoded = decode_frame(&frame).unwrap();
    assert_eq!(decoded.cmd, CMD_E2EE_SUBMIT_BUNDLE);
    assert_eq!(
        decoded.envelope.get("reqId").and_then(Value::as_str),
        Some("req_540")
    );
    let outer = decoded
        .envelope
        .get("data")
        .and_then(Value::as_object)
        .unwrap();
    assert_eq!(outer.get("delSS").and_then(Value::as_i64), Some(0));
    assert!(outer.get("data").is_none());
}

// ---- Swift: wsExtractFileDoneControls, extractFileDoneEvents --------------------------------

#[test]
fn ws_extract_file_done_controls() {
    let events = files::extract_file_done_events(&obj(json!({
        "data": {"controls": [
            {"content": {"act_type": "file_done", "data": {"fileId": "987654", "url": "https://cdn.example/f.pdf"}}}
        ]}
    })));
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].file_id, "987654");
    assert_eq!(events[0].url, "https://cdn.example/f.pdf");
}

#[test]
fn extract_file_done_nested_url_and_video_done_json_string() {
    let payload = obj(json!({
        "data": {"controls": [
            {"content": {"act_type": "file_done", "data": {"fileId": "f1", "data": {"url": "https://cdn.example.test/f1.pdf"}}}},
            {"content": r#"{"act_type":"video_done","data":{"fileId":"v2","url":"https://cdn.example.test/v2.mp4"}}"#}
        ]}
    }));
    let events = files::extract_file_done_events(&payload);
    assert_eq!(events.len(), 2);
    assert_eq!(
        (events[0].file_id.as_str(), events[0].url.as_str()),
        ("f1", "https://cdn.example.test/f1.pdf")
    );
    assert_eq!(
        (events[1].file_id.as_str(), events[1].url.as_str()),
        ("v2", "https://cdn.example.test/v2.mp4")
    );
}

#[test]
fn extract_file_done_array_data_actions_and_fallbacks() {
    // payload.data as array of items, some carrying `controls`
    let p = obj(json!({"data": [
        {"controls": [{"content": {"actType": "file_done", "data": {"fileId": "a", "fileUrl": "u1"}}}]},
        {"content": {"act_type": "video_done", "fileId": "b", "url": "u2"}},
        {"content": {"act_type": "other", "fileId": "c", "url": "u3"}},
    ]}));
    let e = files::extract_file_done_events(&p);
    assert_eq!(e.len(), 2);
    assert_eq!((e[0].file_id.as_str(), e[0].url.as_str()), ("a", "u1"));
    assert_eq!((e[1].file_id.as_str(), e[1].url.as_str()), ("b", "u2"));
    // actions list, and empty candidates fall back to the data node itself
    let p = obj(
        json!({"data": {"actions": [{"content": {"act_type": "file_done", "data": {"fileId": "x", "url": "y"}}}]}}),
    );
    assert_eq!(files::extract_file_done_events(&p).len(), 1);
    let p = obj(json!({"act_type": "file_done", "fileId": "x", "url": "y"}));
    assert_eq!(files::extract_file_done_events(&p).len(), 1);
    // missing url or fileId dropped
    let p = obj(
        json!({"data": {"controls": [{"content": {"act_type": "file_done", "data": {"fileId": "x"}}}]}}),
    );
    assert!(files::extract_file_done_events(&p).is_empty());
}

// ---- Swift: webSocketHighestActionIdAdvancesAcrossReactQueues -------------------------------

#[test]
fn highest_action_id_advances_across_react_queues() {
    let d = obj(json!({"reacts": [{"actionId": "505"}], "reactGroups": [{"actId": "606"}]}));
    assert_eq!(highest_action_id(&d).as_deref(), Some("606"));
    let d = obj(json!({"msgs": [{"id": 9007199254740993_i64}, {"id": "12"}]}));
    assert_eq!(highest_action_id(&d).as_deref(), Some("9007199254740993"));
    assert_eq!(highest_action_id(&obj(json!({"msgs": [{"id": 0}]}))), None);
}

// ---- Swift: cursor persistence (FeatureFixesTests ~1380) -------------------------------------

#[test]
fn queue_cursor_seed_and_current_roundtrip() {
    let mut c = QueueCursors::default();
    let mut snaps = BTreeMap::new();
    snaps.insert(
        "510_0".to_string(),
        WsQueueCursorSnapshot {
            last_id: "998877".into(),
            pre_ids: vec!["12".into()],
        },
    );
    snaps.insert(
        "511_0".to_string(),
        WsQueueCursorSnapshot {
            last_id: "1".into(),
            pre_ids: vec![],
        },
    );
    snaps.insert(
        "512_0".to_string(),
        WsQueueCursorSnapshot {
            last_id: " 0 ".into(),
            pre_ids: vec![],
        },
    );
    snaps.insert(
        "513_0".to_string(),
        WsQueueCursorSnapshot {
            last_id: "".into(),
            pre_ids: vec![],
        },
    );
    c.seed(&snaps);
    let cur = c.current();
    assert_eq!(cur.len(), 1);
    assert_eq!(
        cur["510_0"],
        WsQueueCursorSnapshot {
            last_id: "998877".into(),
            pre_ids: vec!["12".into()]
        }
    );
    // numeric text is stored as an Int64 JSON number, otherwise string
    assert_eq!(c.get("510_0").unwrap().last_id, json!(998877));
    c.seed(&BTreeMap::from([(
        "9_0".to_string(),
        WsQueueCursorSnapshot {
            last_id: "abc".into(),
            pre_ids: vec![],
        },
    )]));
    assert_eq!(c.get("9_0").unwrap().last_id, json!("abc"));
}

#[test]
fn snapshot_json_shape_matches_swift_codable() {
    let snap = WsQueueCursorSnapshot {
        last_id: "998877".into(),
        pre_ids: vec!["12".into()],
    };
    let m: BTreeMap<String, WsQueueCursorSnapshot> =
        BTreeMap::from([("510_0".into(), snap.clone())]);
    let text = serde_json::to_string(&m).unwrap();
    assert_eq!(text, r#"{"510_0":{"lastId":"998877","preIds":["12"]}}"#);
    let back: BTreeMap<String, WsQueueCursorSnapshot> = serde_json::from_str(&text).unwrap();
    assert_eq!(back["510_0"], snap);
}

// ---- Golden frames from the Swift implementation ----------------------------------------------

#[test]
fn golden_frames_from_swift() {
    // A: encodeFrame(510,1,1,data:["first":true])
    let a = encode_frame_json(510, 1, 1, Some(&obj(json!({"first": true}))));
    assert_eq!(hex(&a), "01fe01017b226669727374223a747275657d");
    // B: header only, cmd 0x1234 LE, sub 7, version 3
    assert_eq!(hex(&encode_frame(0x1234, 7, 3, None)), "03341207");
    // empty payload adds nothing
    assert_eq!(hex(&encode_frame(0x1234, 7, 3, Some(b""))), "03341207");
    // C: ping body
    assert_eq!(
        hex(&ping_frame_bytes(1_700_000_000_123)),
        "010200017b226576656e744964223a313730303030303030303132337d"
    );
    // D: encodeRequestFrame(540, reqId req_540, {"delSS":0})
    let d = encode_request_frame(540, 0, 1, "req_540", &obj(json!({"delSS": 0})));
    assert_eq!(
        hex(&d),
        "011c02007b2264617461223a7b2264656c5353223a307d2c227265714964223a227265715f353430227d"
    );
    // E: empty inner data
    let e = encode_request_frame(570, 0, 1, "req_1", &Map::new());
    assert_eq!(
        hex(&e),
        "013a02007b2264617461223a7b7d2c227265714964223a227265715f31227d"
    );
    // F: JSONSerialization escapes "/" and quotes/newlines; UTF-8 passes through
    let f = encode_frame_json(570, 0, 1, Some(&obj(json!({"u": "https://a/b\u{e9}\"\n"}))));
    assert_eq!(
        hex(&f),
        "013a02007b2275223a2268747470733a5c2f5c2f615c2f62c3a95c225c6e227d"
    );
    // H: empty array
    assert_eq!(
        hex(&encode_frame_json(510, 0, 1, Some(&obj(json!({"x": []}))))),
        "01fe01007b2278223a5b5d7d"
    );
    // I: control chars use lowercase \u001f, DEL stays raw
    assert_eq!(
        hex(&encode_frame_json(
            510,
            0,
            1,
            Some(&obj(json!({"x": "\u{1f}\u{7f}"})))
        )),
        "01fe01007b2278223a225c75303031667f227d"
    );
    // J: empty dict is "{}" (data: nil would be header only)
    assert_eq!(
        hex(&encode_frame_json(510, 0, 1, Some(&Map::new()))),
        "01fe01007b7d"
    );
    assert_eq!(hex(&encode_frame_json(510, 0, 1, None)), "01fe0100");
}

fn ping_frame_bytes(ms: i64) -> Vec<u8> {
    frame::ping_frame(ms)
}

#[test]
fn pull_frames() {
    // first: only when int64(lastId) == 1 (also the string "1")
    let f = frame::pull_frame(510, 0, "req_1", &json!(1), &json!([]));
    assert_eq!(
        String::from_utf8(f[4..].to_vec()).unwrap(),
        r#"{"first":true,"lastId":1,"preIds":[],"reqId":"req_1"}"#
    );
    let f = frame::pull_frame(510, 0, "r", &json!("1"), &json!([]));
    assert!(
        decode_frame(&f).unwrap().envelope["first"]
            .as_bool()
            .unwrap()
    );
    let f = frame::pull_frame(510, 0, "r", &json!(5), &json!(["7"]));
    assert!(
        !decode_frame(&f).unwrap().envelope["first"]
            .as_bool()
            .unwrap()
    );
    let f = frame::pull_next_frame(510, 0, "r", &json!(1), &json!([]));
    assert!(
        !decode_frame(&f).unwrap().envelope["first"]
            .as_bool()
            .unwrap()
    );
    assert_eq!(&f[..4], &[1, 0xfe, 0x01, 0]);
}

#[test]
fn decode_frame_errors_and_header_only() {
    assert_eq!(decode_frame(&[1, 2, 3]), Err(FrameError::TooShort));
    assert_eq!(
        decode_frame(&[1, 2, 0, 0, b'[', b']']),
        Err(FrameError::BadBody)
    );
    assert_eq!(decode_frame(&[1, 2, 0, 0, b'x']), Err(FrameError::BadBody));
    let f = decode_frame(&[9, 0x01, 0x02, 7]).unwrap();
    assert_eq!((f.version, f.cmd, f.sub_cmd), (9, 0x0201, 7));
    assert!(f.envelope.is_empty());
}

#[test]
fn encrypt_field_clamps() {
    let mk = |v: Value| Frame {
        version: 1,
        cmd: 2,
        sub_cmd: 0,
        envelope: obj(json!({"encrypt": v})),
    };
    assert_eq!(mk(json!(3)).encrypt(), 3);
    assert_eq!(mk(json!("2")).encrypt(), 2);
    assert_eq!(mk(json!(-5)).encrypt(), 0);
    assert_eq!(mk(json!(999)).encrypt(), 255);
    assert_eq!(mk(json!(null)).encrypt(), 0);
}

// ---- WsEvent -----------------------------------------------------------------------------------

#[test]
fn event_classification() {
    let ev = |cmd| WsEvent {
        cmd,
        sub_cmd: 0,
        version: 1,
        payload: Map::new(),
    };
    for c in [
        501, 521, 510, 511, 513, 514, 515, 517, 518, 534, 570, 551, 552, 535,
    ] {
        assert!(ev(c).is_chat_push_or_pull(), "{c}");
        assert!(!ev(c).is_control_event(), "{c}");
    }
    for c in [601, 602, 603, 604] {
        assert!(ev(c).is_control_event(), "{c}");
        assert!(!ev(c).is_chat_push_or_pull(), "{c}");
    }
    for c in [1, 2, 4, 512, 532, 533, 590] {
        assert!(
            !ev(c).is_chat_push_or_pull() && !ev(c).is_control_event(),
            "{c}"
        );
    }
}

// ---- Reconnect policy ---------------------------------------------------------------------------

#[test]
fn reconnect_policy_backoff_and_rotation() {
    let mut p = ReconnectPolicy::new(4);
    assert_eq!(p.current_endpoint(), Some(0));
    let short = Duration::from_secs(1);
    let delays: Vec<u64> = (0..6)
        .map(|_| p.on_session_ended(short).as_secs())
        .collect();
    assert_eq!(delays, vec![4, 8, 16, 30, 30, 30]);
    assert_eq!(p.current_endpoint(), Some(2)); // 6 % 4
    // stable session resets to 2s
    assert_eq!(p.on_session_ended(Duration::from_secs(31)).as_secs(), 2);
    assert_eq!(p.on_session_ended(Duration::from_secs(30)).as_secs(), 4); // exactly 30 is not "> 30"
    assert_eq!(ReconnectPolicy::new(0).current_endpoint(), None);
}

#[test]
fn handshake_headers() {
    let h = connect_headers("SEK");
    assert_eq!(h[0], ("Cookie", "zpw_sek=SEK; _zlang=vi".to_string()));
    assert_eq!(h[1], ("zpw_sek", "SEK".to_string()));
    assert_eq!(h[2], ("Origin", "file://".to_string()));
    assert_eq!(h[3], ("User-Agent", "ZaloPC-darwin-23v694".to_string()));
}

// ---- Waiters --------------------------------------------------------------------------------------

#[test]
fn file_waiters_bookkeeping() {
    let mut w = FileWaiters::default();
    assert_eq!(w.wait("", 1), FileWait::Invalid);
    assert_eq!(w.wait("f", 1), FileWait::Pending(1));
    assert_eq!(w.wait("f", 2), FileWait::Pending(2));
    assert_eq!(w.wait("g", 3), FileWait::Pending(3));
    assert_eq!(w.record("f", "u"), vec![1, 2]);
    assert_eq!(w.wait("f", 4), FileWait::Ready("u".into()));
    assert!(w.record("", "u").is_empty());
    assert!(w.record("h", "").is_empty());
    assert_eq!(w.timeout("g"), vec![3]);
    assert!(w.timeout("g").is_empty());
    assert_eq!(w.wait("z", 9), FileWait::Pending(9));
    assert_eq!(w.clear(), vec![9]);
    assert_eq!(w.completed_len(), 0);
    assert_eq!(w.wait("f", 5), FileWait::Pending(5));
}

#[test]
fn completed_file_cache_capped_at_200() {
    let mut w = FileWaiters::default();
    for i in 0..250 {
        w.record(&format!("f{i}"), "u");
    }
    assert_eq!(w.completed_len(), 200);
    assert_eq!(w.wait("f0", 1), FileWait::Pending(1)); // oldest evicted
    assert_eq!(w.wait("f249", 2), FileWait::Ready("u".into()));
}

#[test]
fn request_waiters_bookkeeping() {
    let mut r = RequestWaiters::default();
    assert_eq!(r.register("req_1", 10), None);
    assert_eq!(r.register("req_2", 11), None);
    assert_eq!(r.register("req_1", 12), Some(10));
    assert!(r.is_pending("req_1"));
    assert_eq!(r.finish("req_2"), Some(11));
    assert_eq!(r.finish("req_2"), None);
    assert_eq!(r.fail_all(), vec![("req_1".to_string(), 12)]);
    assert!(r.is_empty());
}

// ---- Core state machine --------------------------------------------------------------------------

fn frame_of(cmd: u16, sub: u8, env: Value) -> Vec<u8> {
    encode_frame_json(cmd, sub, 1, Some(&obj(env)))
}

fn authed_core(auth_payload: Value) -> (WsCore, FrameOutcome) {
    let mut core = WsCore::new();
    core.on_connect();
    // envelope: encrypt 0, data = JSON text (the stub decryptor returns it verbatim)
    let env = json!({"encrypt": 0, "key": "AAEC", "data": auth_payload.to_string()});
    let out = core.handle_binary_frame(&frame_of(CMD_AUTHEN, 0, env), &no_decrypt());
    (core, out)
}

#[test]
fn auth_success_pulls_every_queue_from_seed_or_one() {
    let mut core = WsCore::new();
    core.cursors.seed(&BTreeMap::from([(
        "510_1".to_string(),
        WsQueueCursorSnapshot {
            last_id: "998877".into(),
            pre_ids: vec!["12".into()],
        },
    )]));
    let auth = json!({"error_code": 0, "data": {"ctrl_qCmds": [{"cmd": 603, "subCmd": 1}], "qCmds": [{"cmd": 510, "subCmd": 1}]}});
    let env = json!({"encrypt": 0, "key": "AAEC", "data": auth.to_string()});
    let out = core.handle_binary_frame(&frame_of(CMD_AUTHEN, 0, env), &no_decrypt());
    assert!(core.is_authed());
    assert_eq!(core.cipher_key(), Some(&[0u8, 1, 2][..]));
    assert_eq!(out.close, None);
    assert_eq!(out.log, vec!["ws: authed queues=2".to_string()]);
    let ev = out.event.unwrap();
    assert_eq!((ev.cmd, ev.version), (CMD_AUTHEN, 1));
    assert_eq!(out.sends.len(), 2);
    let p0 = decode_frame(&out.sends[0]).unwrap();
    assert_eq!((p0.cmd, p0.sub_cmd), (603, 1));
    assert_eq!(p0.envelope["lastId"], json!(1));
    assert_eq!(p0.envelope["first"], json!(true));
    assert_eq!(p0.envelope["reqId"], json!("req_1"));
    let p1 = decode_frame(&out.sends[1]).unwrap();
    assert_eq!(p1.envelope["lastId"], json!(998877));
    assert_eq!(p1.envelope["preIds"], json!(["12"]));
    assert_eq!(p1.envelope["first"], json!(false));
    assert_eq!(p1.envelope["reqId"], json!("req_2"));
}

#[test]
fn auth_failures_close_with_policy_violation() {
    let mut core = WsCore::new();
    let fail = |_: Option<&[u8]>, _: u8, _: &str| Err(DecryptError("x".into()));
    let out = core.handle_binary_frame(
        &frame_of(CMD_AUTHEN, 0, json!({"encrypt": 1, "data": "zz"})),
        &fail,
    );
    assert_eq!(out.close, Some(CloseRequest::PolicyViolation));
    assert!(out.event.is_none() && !core.is_authed());
    assert_eq!(out.log, vec!["ws: auth decrypt failed".to_string()]);

    let (core, out) = authed_core(json!({"error_code": 5}));
    assert!(!core.is_authed());
    assert_eq!(out.close, Some(CloseRequest::PolicyViolation));
    assert_eq!(out.event.unwrap().payload["error_code"], json!(5));
    assert_eq!(out.log, vec!["ws: auth rejected error_code=5".to_string()]);

    // missing error_code is -1 (rejected)
    let (_, out) = authed_core(json!({}));
    assert_eq!(out.log, vec!["ws: auth rejected error_code=-1".to_string()]);
}

#[test]
fn bad_key_base64_clears_cipher_key() {
    let mut core = WsCore::new();
    let env = json!({"encrypt": 0, "key": "AAEC", "data": "{\"error_code\":0}"});
    core.handle_binary_frame(&frame_of(CMD_AUTHEN, 0, env), &no_decrypt());
    assert!(core.cipher_key().is_some());
    let env = json!({"encrypt": 0, "key": "!!!!", "data": "{\"error_code\":0}"});
    core.handle_binary_frame(&frame_of(CMD_AUTHEN, 0, env), &no_decrypt());
    assert_eq!(core.cipher_key(), None);
}

#[test]
fn base64_matches_foundation() {
    use olaz_ws::json::base64_decode;
    assert_eq!(base64_decode("YWJj"), Some(b"abc".to_vec()));
    assert_eq!(base64_decode("YWI="), Some(b"ab".to_vec()));
    assert_eq!(base64_decode(""), Some(vec![]));
    for bad in ["YWI", "YW Jj", "YWJj\n", "Y", "!!!!"] {
        assert_eq!(base64_decode(bad), None, "{bad}");
    }
}

#[test]
fn push_frame_updates_cursor_and_paginates() {
    let (mut core, _) = authed_core(json!({"error_code": 0}));
    let env = json!({"encrypt": 0, "data": {"lastActionId": "555", "more": 1, "queueStatus": {"510_0": {"ids": ["7", ""]}}, "msgs": []}});
    let out = core.handle_binary_frame(&frame_of(510, 0, env), &no_decrypt());
    assert_eq!(
        out.cursors_changed.unwrap()["510_0"],
        WsQueueCursorSnapshot {
            last_id: "555".into(),
            pre_ids: vec!["7".into()]
        }
    );
    assert_eq!(out.sends.len(), 1);
    let next = decode_frame(&out.sends[0]).unwrap();
    assert_eq!((next.cmd, next.sub_cmd), (510, 0));
    assert_eq!(next.envelope["first"], json!(false));
    assert_eq!(next.envelope["lastId"], json!("555"));
    assert_eq!(next.envelope["preIds"], json!(["7", ""]));
    assert!(out.event.is_some());

    // same payload again: snapshot unchanged -> no callback, still paginates
    let env = json!({"encrypt": 0, "data": {"lastActionId": "555", "more": 1, "queueStatus": {"510_0": {"ids": ["7", ""]}}}});
    let out = core.handle_binary_frame(&frame_of(510, 0, env), &no_decrypt());
    assert!(out.cursors_changed.is_none());
    assert_eq!(out.sends.len(), 1);

    // fallback chain: queueStatus.lastId, then highest action id; "0" never stored
    let env = json!({"encrypt": 0, "data": {"queueStatus": {"511_0": {"lastId": 77}}}});
    let out = core.handle_binary_frame(&frame_of(511, 0, env), &no_decrypt());
    assert_eq!(out.cursors_changed.unwrap()["511_0"].last_id, "77");
    let env = json!({"encrypt": 0, "data": {"msgs": [{"msgId": 1, "id": "31"}, {"id": 40}]}});
    let out = core.handle_binary_frame(&frame_of(513, 0, env), &no_decrypt());
    assert_eq!(out.cursors_changed.unwrap()["513_0"].last_id, "40");
    let env = json!({"encrypt": 0, "data": {"lastActionId": 0}});
    let out = core.handle_binary_frame(&frame_of(514, 0, env), &no_decrypt());
    assert!(out.cursors_changed.is_none());
    assert!(!core.cursors.current().contains_key("514_0"));
}

#[test]
fn reset_last_action_id_drops_cursor() {
    let (mut core, _) = authed_core(json!({"error_code": 0}));
    let env = json!({"encrypt": 0, "data": {"lastActionId": "9"}});
    core.handle_binary_frame(&frame_of(510, 0, env), &no_decrypt());
    assert!(core.cursors.current().contains_key("510_0"));
    for reset in [json!(true), json!(1), json!("true")] {
        let env = json!({"encrypt": 0, "data": {"lastActionId": "9", "more": 1, "resetLastActionId": reset}});
        let out = core.handle_binary_frame(&frame_of(510, 0, env), &no_decrypt());
        assert!(out.sends.is_empty());
        // first iteration removes it and reports; later ones have nothing to remove
        if let Some(changed) = out.cursors_changed {
            assert!(changed.is_empty());
        }
        let env = json!({"encrypt": 0, "data": {"lastActionId": "9"}});
        core.handle_binary_frame(&frame_of(510, 0, env), &no_decrypt());
    }
}

#[test]
fn has_msg_triggers_get_msg_and_reply_resolves_waiter() {
    let (mut core, _) = authed_core(json!({"error_code": 0}));
    let out = core.handle_binary_frame(
        &frame_of(
            CMD_HAS_MSG,
            0,
            json!({"encrypt": 0, "data": {"queueId": "q1", "ids": ["a", "b"]}}),
        ),
        &no_decrypt(),
    );
    let get = decode_frame(&out.sends[0]).unwrap();
    assert_eq!(get.cmd, CMD_GET_MSG);
    assert_eq!(get.envelope["queueId"], json!("q1"));
    assert_eq!(get.envelope["ids"], json!(["a", "b"]));
    assert_eq!(get.envelope["lastId"], json!("1"));
    assert_eq!(get.envelope["reqId"], json!("req_1"));

    let prep = core
        .prepare_request(
            CMD_E2EE_SUBMIT_BUNDLE,
            0,
            1,
            None,
            &obj(json!({"delSS": 0})),
        )
        .unwrap();
    assert_eq!(prep.req_id, "req_2");
    assert_eq!(
        decode_frame(&prep.frame).unwrap().envelope["reqId"],
        json!("req_2")
    );
    // reply carries the reqId inside data
    let out = core.handle_binary_frame(
        &frame_of(
            CMD_E2EE_SUBMIT_BUNDLE,
            0,
            json!({"encrypt": 0, "data": {"reqId": "req_2", "error_code": 0}}),
        ),
        &no_decrypt(),
    );
    let r = out.resolved_request.unwrap();
    assert_eq!((r.req_id.as_str(), r.token), ("req_2", prep.token));
    assert!(!core.requests.is_pending("req_2"));
    // reply with top-level reqId on an unrelated waiter
    let p2 = core
        .prepare_request(1000, 0, 1, Some("custom"), &Map::new())
        .unwrap();
    let out = core.handle_binary_frame(
        &frame_of(1000, 0, json!({"encrypt": 0, "reqId": "custom"})),
        &no_decrypt(),
    );
    assert_eq!(out.resolved_request.unwrap().token, p2.token);
    // unknown reqId: nothing resolved
    let out = core.handle_binary_frame(
        &frame_of(1000, 0, json!({"encrypt": 0, "reqId": "nope"})),
        &no_decrypt(),
    );
    assert!(out.resolved_request.is_none() && out.event.is_some());
}

#[test]
fn request_requires_auth_and_disconnect_fails_waiters() {
    let mut core = WsCore::new();
    assert!(core.prepare_request(540, 0, 1, None, &Map::new()).is_none());
    assert!(core.frame_if_authed(1000, 0, 1, None).is_none());
    assert!(core.ping_frame_if_authed(1).is_none());
    let (mut core, _) = authed_core(json!({"error_code": 0}));
    let a = core.prepare_request(540, 0, 1, None, &Map::new()).unwrap();
    let b = core.prepare_request(540, 0, 1, None, &Map::new()).unwrap();
    assert!(core.ping_frame_if_authed(5).is_some());
    let failed = core.on_disconnect();
    assert_eq!(
        failed.iter().map(|(_, t)| *t).collect::<Vec<_>>(),
        vec![a.token, b.token]
    );
    assert!(!core.is_authed());
    // req counter survives reconnects
    assert_eq!(core.next_req_id(), "req_3");
}

#[test]
fn encrypted_frames_use_decryptor_and_fall_back_to_envelope() {
    let (mut core, _) = authed_core(json!({"error_code": 0}));
    let ok = |key: Option<&[u8]>, enc: u8, data: &str| {
        assert_eq!(key, Some(&[0u8, 1, 2][..]));
        assert_eq!((enc, data), (3, "CIPHER"));
        Ok(br#"{"data":{"lastActionId":"42"}}"#.to_vec())
    };
    let out = core.handle_binary_frame(
        &frame_of(510, 0, json!({"encrypt": 3, "data": "CIPHER"})),
        &ok,
    );
    assert_eq!(
        out.event.unwrap().payload["data"]["lastActionId"],
        json!("42")
    );
    assert_eq!(out.cursors_changed.unwrap()["510_0"].last_id, "42");
    // decrypt failure: payload is the raw envelope
    let bad = |_: Option<&[u8]>, _: u8, _: &str| Err(DecryptError("bad".into()));
    let out = core.handle_binary_frame(
        &frame_of(510, 0, json!({"encrypt": 1, "data": "CIPHER"})),
        &bad,
    );
    assert_eq!(out.event.unwrap().payload["data"], json!("CIPHER"));
    // garbage frames are dropped
    assert_eq!(
        core.handle_binary_frame(&[1, 2], &bad),
        FrameOutcome::default()
    );
    assert_eq!(
        core.handle_binary_frame(&[1, 2, 0, 0, b'['], &bad),
        FrameOutcome::default()
    );
}

#[test]
fn file_done_in_frame_wakes_waiters() {
    let (mut core, _) = authed_core(json!({"error_code": 0}));
    let FileWait::Pending(tok) = core.wait_for_file_done("fid") else {
        panic!("pending")
    };
    let env = json!({"encrypt": 0, "data": {"controls": [{"content": {"act_type": "file_done", "data": {"fileId": "fid", "url": "https://x/y"}}}]}});
    let out = core.handle_binary_frame(&frame_of(601, 0, env), &no_decrypt());
    assert_eq!(
        out.file_wakes,
        vec![FileWake {
            file_id: "fid".into(),
            url: "https://x/y".into(),
            waiters: vec![tok]
        }]
    );
    assert!(matches!(core.wait_for_file_done("fid"), FileWait::Ready(u) if u == "https://x/y"));
}

#[test]
fn stop_resets_state() {
    let (mut core, _) = authed_core(json!({"error_code": 0}));
    core.handle_binary_frame(
        &frame_of(510, 0, json!({"encrypt": 0, "data": {"lastActionId": "9"}})),
        &no_decrypt(),
    );
    let p = core.prepare_request(1, 0, 1, None, &Map::new()).unwrap();
    let FileWait::Pending(ft) = core.wait_for_file_done("f") else {
        panic!()
    };
    let (reqs, files) = core.stop(false);
    assert_eq!((reqs, files), (vec![p.token], vec![ft]));
    assert!(core.cursors.current().contains_key("510_0"));
    assert!(core.cipher_key().is_none() && !core.is_authed());
    core.stop(true);
    assert!(core.cursors.current().is_empty());
}

#[test]
fn json_helpers_match_swift_lossless() {
    use olaz_ws::json::*;
    assert_eq!(
        string_of(Some(&json!(9007199254740993_i64))),
        "9007199254740993"
    );
    assert_eq!(string_of(Some(&json!(true))), "true");
    assert_eq!(string_of(Some(&json!(null))), "");
    assert_eq!(int64_of(Some(&json!(" 12 "))), Some(12));
    assert_eq!(int64_of(Some(&json!(1.9))), Some(1));
    assert_eq!(int64_of(Some(&json!("x"))), None);
    assert_eq!(bool_of(Some(&json!("TRUE"))), Some(true));
    assert_eq!(bool_of(Some(&json!(0))), Some(false));
    assert_eq!(bool_of(Some(&json!("maybe"))), None);
    // 64-bit ids survive a decode/encode cycle untouched
    let mut bytes = vec![1, 0, 1, 0];
    bytes.extend_from_slice(br#"{"i":12345678901234567890}"#);
    let f = decode_frame(&bytes).unwrap();
    assert_eq!(string_of(f.envelope.get("i")), "12345678901234567890");
}

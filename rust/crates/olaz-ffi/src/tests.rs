#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::sync::Mutex;
use std::sync::mpsc;
use std::time::Duration;

use super::*;

fn row(id: &str, ts: i64) -> MessageRow {
    MessageRow {
        id: id.into(),
        conv_id: "c1".into(),
        client_id: "cli".into(),
        sender_id: "u1".into(),
        sender_name: "An".into(),
        sender_avatar: String::new(),
        is_mine: false,
        text: "xin chào".into(),
        kind_tag: "text".into(),
        ts_ms: ts,
        status: "sent".into(),
        raw_json: br#"{"id":"1"}"#.to_vec(),
    }
}

#[test]
fn version_is_crate_version() {
    assert_eq!(core_version(), env!("CARGO_PKG_VERSION"));
}

#[tokio::test]
async fn store_roundtrip_keeps_64_bit_ids() {
    let dir = tempfile::tempdir().unwrap();
    let store = CoreStore::open(dir.path().join("t.db").to_string_lossy().into_owned()).unwrap();
    store
        .save_messages(vec![row("7412345678901234567", 1_795_000_000_000)])
        .await
        .unwrap();
    let got = store.messages("c1".into(), None, 50).await.unwrap();
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].id, "7412345678901234567");
    assert_eq!(got[0].text, "xin chào");
    assert!(
        store
            .messages("c1".into(), Some(1), 50)
            .await
            .unwrap()
            .is_empty()
    );

    store
        .set_preference_string("k".into(), "v".into())
        .await
        .unwrap();
    assert_eq!(
        store
            .preference_string("k".into())
            .await
            .unwrap()
            .as_deref(),
        Some("v")
    );
    assert!(store.load_conversations().await.unwrap().is_empty());
}

#[test]
fn parses_wire_event_with_big_ids() {
    let json = r#"{"msgId":7412345678901234567,"cliMsgId":7412345678901234568,"uidFrom":"peer","idTo":"me","msgType":"webchat","content":"hi","ts":1795000000000}"#;
    let ev = parse_wire_event(json.into(), "me".into(), WireOptions::default()).unwrap();
    let WireEvent::Message { message, stored } = ev else {
        panic!("expected a message event");
    };
    assert_eq!(message.id, "7412345678901234567");
    assert_eq!(message.client_id, "7412345678901234568");
    assert_eq!(stored.kind_tag, "text");
    assert_eq!(message.text, "hi");
    assert!(!stored.locked);
    assert!(
        String::from_utf8_lossy(&stored.raw_json).contains("7412345678901234567"),
        "canonical raw json keeps the id"
    );

    assert!(parse_wire_event("[1]".into(), "me".into(), WireOptions::default()).is_err());
    let batch = parse_wire_batch(
        r#"{"data":{"msgs":[{"msgId":7412345678901234567,"uidFrom":"peer","idTo":"me","msgType":"webchat","content":"x","ts":1}]}}"#.into(),
        "me".into(),
        WireOptions::default(),
    )
    .unwrap();
    assert_eq!(batch.len(), 1);
}

#[test]
fn crypto_helpers() {
    assert_eq!(
        decrypt_ws_frame(None, 0, "abc".into()).unwrap(),
        b"abc".to_vec()
    );
    assert!(decrypt_ws_frame(None, 2, "abc".into()).is_err());
    assert!(inflate(vec![1, 2, 3]).is_err());
}

struct Probe(Mutex<mpsc::Sender<&'static str>>);

impl WsListener for Probe {
    fn on_event(&self, _event: WsEventRecord) {}
    fn on_wire_events(
        &self,
        _cmd: u16,
        _sub_cmd: u8,
        _version: u8,
        _events: Vec<WireEvent>,
        _uids: Vec<String>,
        _payload: std::sync::Arc<WirePayload>,
    ) {
    }
    fn on_cursors_changed(&self, _cursors: Vec<CursorEntry>) {}
    fn on_stopped(&self) {
        let _ = self.0.lock().unwrap().send("stopped");
    }
}

#[tokio::test]
async fn ws_session_stop_notifies_listener() {
    let (tx, rx) = mpsc::channel();
    let session = ws_start(
        WsConfigRecord {
            preferred_languages: vec!["vi".to_owned()],
            endpoints: vec!["ws://127.0.0.1:1".into()],
            zpw_sek: "sek".into(),
            seed_cursors: vec![CursorEntry {
                queue_key: "501_0".into(),
                last_id: "42".into(),
                pre_ids: vec![],
            }],
            event_capacity: None,
            my_uid: None,
            self_conv_id: None,
        },
        std::sync::Arc::new(Probe(Mutex::new(tx))),
    )
    .unwrap();
    assert!(!session.is_authed().await.unwrap());
    assert!(!session.send_frame(1, 1, 1, None).await.unwrap());
    let left = session.stop(false).await.unwrap();
    assert_eq!(left.len(), 1);
    assert_eq!(rx.recv_timeout(Duration::from_secs(5)), Ok("stopped"));
}

// ---------------------------------------------------------------- session / api

mod session_api {
    use std::sync::Arc;

    use olaz_net::http::RawResponse;
    use olaz_net::mock::MockTransport;
    use olaz_net::{
        LoginAccount, NetError, NetworkErrorKind, SessionClient, ZaloDomains, ZaloSessionError,
    };
    use serde_json::json;

    use crate::*;

    const FAKE_SNAPSHOT: &str = r#"{
        "zpwType": "23",
        "imei": "imei-test",
        "computerName": "Mac test",
        "domains": {},
        "plainAccount": {"userId":"100","displayName":"An","avatar":"","phone":"",
            "send2MeId":"999","dkey":"","zpwEnk":"0123456789abcdef","zpwSek":"sek.1.2"},
        "expiredAt": null,
        "sealedSecretsBase64": null
    }"#;

    fn domains_json() -> String {
        serde_json::to_string(&ZaloDomains::default()).unwrap()
    }

    fn fake_snapshot() -> String {
        FAKE_SNAPSHOT.replace("{}", &domains_json())
    }

    #[test]
    fn restore_and_snapshot_round_trip() {
        let s = CoreSession::new("Mac".into()).unwrap();
        assert!(!s.is_authenticated());
        assert!(s.restore(fake_snapshot()).unwrap());
        assert!(s.is_authenticated());
        let snap = s.snapshot_json().unwrap();
        let v: serde_json::Value = serde_json::from_str(&snap).unwrap();
        assert_eq!(v["plainAccount"]["userId"], "100");
        assert_eq!(v["plainAccount"]["send2MeId"], "999");
        assert_eq!(v["computerName"], "Mac test");
        // The snapshot restores into another session unchanged.
        let s2 = CoreSession::new("Other".into()).unwrap();
        assert!(s2.restore(snap.clone()).unwrap());
        assert_eq!(s2.snapshot_json().unwrap(), snap);

        s.mark_expired();
        let v: serde_json::Value = serde_json::from_str(&s.snapshot_json().unwrap()).unwrap();
        assert!(v["expiredAt"].as_f64().unwrap() > 0.0);
        s.clear_session();
        assert!(!s.is_authenticated());
    }

    #[test]
    fn restore_rejects_garbage_and_accounts_without_cookie() {
        let s = CoreSession::new("Mac".into()).unwrap();
        assert!(matches!(
            s.restore("not json".into()),
            Err(CoreError::Parse { .. })
        ));
        let no_sek = fake_snapshot().replace("sek.1.2", "");
        assert!(!s.restore(no_sek).unwrap());
        assert!(!s.is_authenticated());
    }

    #[test]
    fn next_client_id_is_strictly_increasing() {
        let s = CoreSession::new("Mac".into()).unwrap();
        let a = s.next_client_id();
        let b = s.next_client_id();
        assert!(b > a);
    }

    #[test]
    fn qr_ticket_record_round_trips() {
        let rec = QrTicketRecord {
            token_id: "t".into(),
            qr_payload: "https://zalo.me/g/abc".into(),
            base64_png: Some("AAAA".into()),
            png_data: None,
            chk_wait_scan: "https://a/scan".into(),
            chk_wait_cfirm: "https://a/cfirm".into(),
            qr_timeout_seconds: 100,
            qr_retry: 2,
        };
        let back: QrTicketRecord = olaz_net::QrTicket::from(rec.clone()).into();
        assert_eq!(back, rec);
    }

    #[test]
    fn net_errors_map_for_swift() {
        let auth: CoreError = NetError::from(ZaloSessionError {
            code: -102,
            message: "expired".into(),
            url: "/api/x".into(),
        })
        .into();
        assert!(auth.is_auth_error());
        assert!(matches!(
            auth,
            CoreError::Session {
                code: -102,
                is_auth: true,
                ..
            }
        ));
        let other: CoreError = NetError::from(ZaloSessionError {
            code: 7,
            message: "x".into(),
            url: String::new(),
        })
        .into();
        assert!(matches!(
            other,
            CoreError::Session {
                code: 7,
                is_auth: false,
                ..
            }
        ));
        assert!(!other.is_auth_error());
        let timeout: CoreError = NetError::network(NetworkErrorKind::Timeout, "timed out").into();
        assert!(matches!(
            timeout,
            CoreError::Network {
                kind: NetworkKind::Timeout,
                ..
            }
        ));
        assert!(matches!(
            CoreError::from(NetError::Http {
                status: 502,
                body: "secret".into()
            }),
            CoreError::Http { status: 502 }
        ));
        assert!(matches!(
            CoreError::from(NetError::NotAuthenticated),
            CoreError::NotAuthenticated
        ));
        assert!(matches!(
            CoreError::from(NetError::QrTimeout),
            CoreError::QrTimeout
        ));
    }

    #[test]
    fn poll_state_record_round_trips() {
        let init = poll_state_initial();
        assert_eq!(init.last_action_id, "1");
        assert_eq!(init.queues.len(), 3);
        let state: olaz_api::PollState = init.clone().into();
        assert_eq!(PollStateRecord::from(&state), init);
    }

    #[tokio::test]
    async fn core_api_without_login_throws_auth_error() {
        let session = CoreSession::new("Mac".into()).unwrap();
        let api = CoreApi::new(session);
        let e = api.fetch_pinned_conversations().await.unwrap_err();
        // No cookie: the client answers like the server would (code 600, a dead session).
        assert!(e.is_auth_error(), "{e:?}");
    }

    fn mock_api(
        reply: impl FnMut(&olaz_net::http::RequestSpec) -> Result<RawResponse, NetError>
        + Send
        + 'static,
    ) -> olaz_api::ZaloApi<MockTransport> {
        let client = SessionClient::new(
            MockTransport::from_fn(reply),
            "imei-1".to_owned(),
            "Mac".to_owned(),
        )
        .with_clock(|| 1_700_000_000_123);
        client.update_credentials(
            LoginAccount {
                user_id: "100".to_owned(),
                send2me_id: "999".to_owned(),
                ..LoginAccount::default()
            },
            b"0123456789abcdef".to_vec(),
            "sek.1.2".to_owned(),
            Some(ZaloDomains::default()),
        );
        olaz_api::ZaloApi::new(client)
    }

    fn json_reply(v: &serde_json::Value) -> Result<RawResponse, NetError> {
        Ok(RawResponse::new(200, v.to_string().into_bytes()))
    }

    #[tokio::test]
    async fn api_session_error_600_maps_to_auth_error() {
        let api = mock_api(|_| json_reply(&json!({"error_code": 600, "error_message": "dead"})));
        let e: CoreError = api.fetch_pinned_conversations().await.unwrap_err().into();
        assert!(e.is_auth_error(), "{e:?}");
    }

    #[tokio::test]
    async fn api_results_serialize_lossless_json() {
        let api = mock_api(|_| {
            json_reply(&json!({"error_code": 0, "data": {"list": [
                {"userId": "1", "globalId": "7412345678901234567"}
            ]}}))
        });
        let rows = api.fetch_friends(1, 50).await.unwrap();
        let blobs = rows
            .iter()
            .map(|o| olaz_json::to_swift_json_string(&serde_json::Value::Object(o.clone())))
            .collect::<Vec<_>>();
        assert_eq!(blobs.len(), 1);
        assert!(blobs[0].contains("7412345678901234567"), "{}", blobs[0]);
    }

    #[tokio::test]
    async fn shared_session_client_is_visible_to_api() {
        let session = CoreSession::new("Mac".into()).unwrap();
        let _api = CoreApi::new(Arc::clone(&session));
        assert!(session.restore(fake_snapshot()).unwrap());
        assert!(session.is_authenticated());
    }
}

#[tokio::test]
async fn store_chat_path_methods() {
    let dir = tempfile::tempdir().unwrap();
    let store = CoreStore::open(dir.path().join("t.db").to_string_lossy().into_owned()).unwrap();
    let mut m = row("100", 1_795_000_000_000);
    m.raw_json = br#"{"id":"100","text":"Xin Chao","reactions":[]}"#.to_vec();
    store
        .save_messages(vec![m, row("101", 1_795_000_001_000)])
        .await
        .unwrap();

    assert!(
        store
            .message("c1".into(), "100".into())
            .await
            .unwrap()
            .is_some()
    );
    assert!(
        store
            .message("c1".into(), "nope".into())
            .await
            .unwrap()
            .is_none()
    );
    let mut existing = store
        .existing_message_ids("c1".into(), vec!["100".into(), "999".into()])
        .await
        .unwrap();
    existing.sort();
    assert!(existing.contains(&"100".to_owned()));
    assert!(!existing.contains(&"999".to_owned()));
    let hits = store
        .search_messages("c1".into(), "xin".into(), 10)
        .await
        .unwrap();
    assert!(!hits.is_empty());
    let around = store
        .messages_around("c1".into(), 1_795_000_000_000, None, 25, 3000)
        .await
        .unwrap();
    assert_eq!(around.messages.len(), 2);

    assert!(
        store
            .upgrade_message_id("c1".into(), "101".into(), "5000".into(), "cli".into())
            .await
            .unwrap()
    );
    store
        .delete_message("c1".into(), "5000".into())
        .await
        .unwrap();
    assert!(
        store
            .message("c1".into(), "5000".into())
            .await
            .unwrap()
            .is_none()
    );
    store
        .mark_recalled("c1".into(), "100".into(), String::new())
        .await
        .unwrap();
    store
        .update_message_reactions_json("c1".into(), "100".into(), b"[]".to_vec())
        .await
        .unwrap();

    let conv = ConversationRow {
        id: "c1".into(),
        is_group: false,
        name: "An".into(),
        avatar: String::new(),
        pinned: false,
        members: 0,
        unread: 0,
        preview_text: String::new(),
        preview_ts_ms: 0,
        preview_from_me: false,
        updated_at_ms: 1,
    };
    store.upsert_conversation(conv).await.unwrap();
    store.set_conversation_unread("c1".into(), 3).await.unwrap();
    store
        .set_conversation_pinned("c1".into(), true)
        .await
        .unwrap();
    let c = store.load_conversations().await.unwrap();
    assert_eq!((c[0].unread, c[0].pinned), (3, true));

    store.set_preference_bool("b".into(), true).await.unwrap();
    assert!(store.preference_bool("b".into(), false).await.unwrap());
    assert!(
        !store
            .preference_bool("missing".into(), false)
            .await
            .unwrap()
    );
    store
        .set_preference_strings("s".into(), vec!["a".into(), "b".into()])
        .await
        .unwrap();
    assert_eq!(
        store.preference_strings("s".into()).await.unwrap(),
        vec!["a", "b"]
    );
    store
        .set_preference_data("d".into(), br#"{"x":1}"#.to_vec())
        .await
        .unwrap();
    assert_eq!(
        store.preference_data("d".into()).await.unwrap().unwrap(),
        br#"{"x":1}"#
    );
    store.delete_preference("d".into()).await.unwrap();
    assert!(store.preference_data("d".into()).await.unwrap().is_none());
}

// ---- typed hot path ----

fn push_payload(msg_id: &str, from: &str) -> serde_json::Map<String, serde_json::Value> {
    serde_json::json!({"data": {"msgs": [{
        "msgId": msg_id, "cliMsgId": "c1", "uidFrom": from, "idTo": "me", "msgType": "webchat",
        "content": "xin chào", "ts": 1_795_000_000_000_i64
    }]}})
    .as_object()
    .unwrap()
    .clone()
}

#[test]
fn plain_envelope_is_typed_and_resolve_tracks_names() {
    let probe = WireParseProbe::new("me".into(), None);
    let bytes = serde_json::to_vec(&push_payload("7412345678901234567", "u1")).unwrap();
    let env = probe.parse(bytes.clone(), 501).expect("plain envelope");
    assert_eq!(env.uids, vec!["u1".to_owned()]);
    let WireEvent::Message { message, .. } = &env.events[0] else {
        panic!("message expected");
    };
    assert_eq!(message.id, "7412345678901234567");
    assert_eq!(message.sender_name, "Người dùng Zalo");
    // Swift knows no name either and the same uid: the delivered events stand.
    assert!(env.payload.resolve("me".into(), None, vec![]).is_none());
    // Swift resolves a name: the payload re-parses with it and the session remembers it.
    let names = vec![NameEntry {
        uid: "u1".into(),
        name: "An".into(),
        avatar: "https://ava.example/an.jpg".into(),
    }];
    let fresh = env
        .payload
        .resolve("me".into(), None, names.clone())
        .expect("name changed");
    let WireEvent::Message { message, .. } = &fresh[0] else {
        panic!("message expected");
    };
    assert_eq!(message.sender_name, "An");
    // The next envelope is parsed with the remembered name and confirmed without a re-parse.
    let env2 = probe.parse(bytes, 501).expect("plain envelope");
    let WireEvent::Message { message, .. } = &env2.events[0] else {
        panic!("message expected");
    };
    assert_eq!(message.sender_name, "An");
    assert!(env2.payload.resolve("me".into(), None, names).is_none());
    // A different signed-in uid forces a re-parse (the sender is now "me").
    let mine = env2
        .payload
        .resolve("u1".into(), None, vec![])
        .expect("uid changed");
    let WireEvent::Message { message, .. } = &mine[0] else {
        panic!("message expected");
    };
    assert!(message.is_mine);
}

#[test]
fn non_plain_envelopes_take_the_raw_path() {
    let probe = WireParseProbe::new("me".into(), None);
    let mut with_cipher = push_payload("1", "u1");
    with_cipher["data"]["msgs"][0]["content"] = serde_json::json!(
        "AzMIARIgmPWlMdiC4wZ0hVUkXfJNMGeaKzuZQHfDCq7xsZVv2DMYASAAKhBRjyzr+XbYlKSf6RJpDsNYYEQQBKQD3BpgD3Z3lXe7e0yLmZm/Bpf2gTLm1y6lcAsaZnlYFuE="
    );
    let cases: Vec<(u16, serde_json::Map<String, serde_json::Value>)> = vec![
        (551, push_payload("1", "u1")), // E2EE command
        (501, with_cipher),             // undecrypted Signal ciphertext
        (
            501,
            serde_json::json!({"error_code": 600, "data": {"msgs": []}})
                .as_object()
                .unwrap()
                .clone(),
        ),
        (
            501,
            serde_json::json!({"data": {"controls": [{"content": {"act_type": "typing"}}]}})
                .as_object()
                .unwrap()
                .clone(),
        ),
        (
            521,
            serde_json::json!({"data": [{"act": "gtyping", "uidFrom": "u1"}]})
                .as_object()
                .unwrap()
                .clone(),
        ),
    ];
    for (cmd, payload) in cases {
        assert!(
            probe
                .parse(serde_json::to_vec(&payload).unwrap(), cmd)
                .is_none(),
            "cmd {cmd} must stay on the raw-JSON path"
        );
    }
}

#[tokio::test]
async fn typed_store_reads_match_the_raw_rows() {
    let dir = tempfile::tempdir().unwrap();
    let store = CoreStore::open(dir.path().join("t.db").to_string_lossy().into_owned()).unwrap();
    let batch = parse_wire_batch(
        r#"{"data":{"msgs":[
            {"msgId":"1","cliMsgId":"c1","uidFrom":"u1","idTo":"me","msgType":"webchat","content":"Chào An","ts":1000},
            {"msgId":"2","cliMsgId":"c2","uidFrom":"u1","idTo":"me","msgType":"chat.photo","content":{"hd":"https://cdn.example/p.jpg","title":"Anh"},"ts":2000}
        ]}}"#
            .into(),
        "me".into(),
        WireOptions::default(),
    )
    .unwrap();
    let rows: Vec<MessageRow> = batch
        .iter()
        .filter_map(|e| match e {
            WireEvent::Message { message, stored } => Some(MessageRow {
                id: message.id.clone(),
                conv_id: message.conversation_id.clone(),
                client_id: message.client_id.clone(),
                sender_id: message.sender_id.clone(),
                sender_name: message.sender_name.clone(),
                sender_avatar: stored.sender_avatar.clone(),
                is_mine: message.is_mine,
                text: message.text.clone(),
                kind_tag: stored.kind_tag.clone(),
                ts_ms: message.date_ms,
                status: "sent".into(),
                raw_json: stored.raw_json.clone(),
            }),
            _ => None,
        })
        .collect();
    store.save_messages(rows).await.unwrap();
    let typed = store.messages_chat("u1".into(), None, 50).await.unwrap();
    assert_eq!(typed.len(), 2);
    for (t, e) in typed.iter().zip(&batch) {
        let WireEvent::Message { message, .. } = e else {
            panic!("message expected");
        };
        assert_eq!(&t.message, message, "typed read equals the typed parse");
    }
    let sync = store
        .read_chat_messages_now("u1".into(), None, 50)
        .expect("reader");
    assert_eq!(sync, typed);
    assert_eq!(
        store
            .search_messages_chat("u1".into(), "chào".into(), 10)
            .await
            .unwrap()
            .len(),
        1
    );
    // Typed save re-encodes the canonical row: a second store receives the same typed messages.
    let dir2 = tempfile::tempdir().unwrap();
    let store2 = CoreStore::open(dir2.path().join("t.db").to_string_lossy().into_owned()).unwrap();
    store2
        .save_chat_messages(
            typed.iter().map(|r| r.message.clone()).collect(),
            false,
            false,
        )
        .await
        .unwrap();
    assert_eq!(
        store2.messages_chat("u1".into(), None, 50).await.unwrap(),
        typed
    );
    // Typed single lookup: by server id and by client id, equal to the batch read; a miss is None.
    for key in ["2", "c2"] {
        let one = store
            .message_chat("u1".into(), key.into())
            .await
            .unwrap()
            .expect("row");
        assert_eq!(one.message, typed[1].message, "lookup by {key}");
        assert_eq!(
            (one.row_id.as_str(), one.row_client_id.as_str()),
            ("2", "c2")
        );
    }
    assert!(
        store
            .message_chat("u1".into(), "nope".into())
            .await
            .unwrap()
            .is_none()
    );
    // A row whose JSON cannot be decoded is None, like Swift's `decodeStoredMessage`.
    let mut bad = row("9", 3000);
    bad.conv_id = "u1".into();
    bad.raw_json = b"not json".to_vec();
    store.save_messages(vec![bad]).await.unwrap();
    assert!(
        store
            .message_chat("u1".into(), "9".into())
            .await
            .unwrap()
            .is_none()
    );
    assert!(
        store
            .message("u1".into(), "9".into())
            .await
            .unwrap()
            .is_some()
    );
}

const HISTORY_BODY: &str = r#"{"error_code":0,"data":{"hasMore":1,"isOld":0,"lastMsgId":7412345678901234500,"groupMsgs":[
    {"msgId":7412345678901234567,"cliMsgId":"c1","uidFrom":"u1","idTo":"g1","msgType":"webchat","content":"Chào nhóm","ts":1795000000000},
    {"msgId":"7412345678901234568","cliMsgId":"c2","uidFrom":"me","idTo":"g1","msgType":"webchat","content":"Tôi đây","ts":1795000001000}
]}}"#;

#[test]
fn history_batch_types_head_uids_and_events_like_parse_wire_batch() {
    let obj = olaz_json::parse_object_str(HISTORY_BODY).unwrap();
    let h = HistoryBatch::from_object(obj).record();
    assert!(h.has_more);
    assert!(!h.is_old);
    assert_eq!(
        h.last_msg_id, "7412345678901234500",
        "64-bit id stays exact"
    );
    assert_eq!(h.uids, vec!["me".to_owned(), "u1".to_owned()]);
    let opts = || WireOptions {
        fallback_conv_id: Some("g1".into()),
        is_group_hint: Some(true),
        names: vec![NameEntry {
            uid: "u1".into(),
            name: "An".into(),
            avatar: String::new(),
        }],
        ..WireOptions::default()
    };
    let typed = h.batch.events("me".into(), opts());
    // Same events as the JSON route Swift used before (history raw JSON -> parse_wire_batch).
    let via_json = parse_wire_batch(h.batch.raw_json(), "me".into(), opts()).unwrap();
    assert_eq!(typed, via_json);
    let msgs: Vec<_> = typed
        .iter()
        .filter_map(|e| match e {
            WireEvent::Message { message, .. } => Some(message),
            _ => None,
        })
        .collect();
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0].id, "7412345678901234567");
    assert_eq!(msgs[0].sender_name, "An");
    assert!(msgs[1].is_mine);
}

#[test]
fn history_batch_head_defaults_when_data_is_missing() {
    let h = HistoryBatch::from_object(olaz_json::parse_object_str(r#"{"error_code":0}"#).unwrap())
        .record();
    assert!(!h.has_more && !h.is_old);
    assert_eq!(h.last_msg_id, "");
    assert!(h.uids.is_empty());
    assert!(
        h.batch
            .events("me".into(), WireOptions::default())
            .is_empty()
    );
}

// ---- Golden fixtures ported from Swift RustCoreCutoverTests ----

#[test]
fn typed_wire_kinds_golden_fixtures() {
    use std::collections::HashSet;

    let cipher = "AzMIARIgmPWlMdiC4wZ0hVUkXfJNMGeaKzuZQHfDCq7xsZVv2DMYASAAKhBRjyzr+XbYlKSf6RJpDsNYYEQQBKQD3BpgD3Z3lXe7e0yLmZm/Bpf2gTLm1y6lcAsaZnlYFuE=";
    let root = serde_json::json!({
        "data": {
            "msgs": [
                {"msgId": "1001", "cliMsgId": "c1001", "uidFrom": "u1", "idTo": "me", "msgType": "webchat", "content": "Chào @An và mọi người", "ts": 1_000,
                 "mentions": [{"uid": "u1", "pos": 5, "len": 3, "type": 0}, {"uid": "-1", "pos": 12, "len": 9, "type": 1}],
                 "quote": {"ownerId": "u1", "msg": "Tin cũ", "fromD": "An cũ"}},
                {"msgId": "1002", "cliMsgId": "c1002", "uidFrom": "me", "idTo": "u1", "msgType": "chat.photo",
                 "content": {"hd": "https://cdn.example/p.jpg", "normalUrl": "https://cdn.example/n.jpg", "title": "Ảnh đẹp", "params": {"width": 640, "height": 480}}, "ts": 2_000},
                {"msgId": "1003", "cliMsgId": "c1003", "uidFrom": "u1", "idTo": "me", "msgType": "chat.sticker", "content": {"id": 3, "catId": 0, "type": 7}, "ts": 3_000},
                {"msgId": "1004", "cliMsgId": "c1004", "uidFrom": "u1", "idTo": "me", "msgType": "chat.gif", "content": {"href": "https://cdn.example/a.gif"}, "ts": 4_000},
                {"msgId": "1005", "cliMsgId": "c1005", "uidFrom": "u1", "idTo": "me", "msgType": "chat.video.msg",
                 "content": {"href": "https://cdn.example/v.mp4", "thumb": "https://cdn.example/v.jpg", "title": "Clip", "params": {"duration": 12_000}}, "ts": 5_000},
                {"msgId": "1006", "cliMsgId": "c1006", "uidFrom": "u1", "idTo": "me", "msgType": "chat.voice",
                 "content": {"href": "https://cdn.example/v.m4a", "params": {"duration": 3_000}}, "ts": 6_000},
                {"msgId": "1007", "cliMsgId": "c1007", "uidFrom": "u1", "idTo": "me", "msgType": "share.file",
                 "content": {"title": "báo cáo", "href": "https://cdn.example/f.pdf", "params": {"fileExt": "pdf", "fileSize": "123456"}}, "ts": 7_000},
                {"msgId": "1008", "cliMsgId": "c1008", "uidFrom": "u1", "idTo": "me", "msgType": "chat.recommended",
                 "content": {"action": "recommened.link", "href": "https://example.com/x", "title": "Ví dụ", "description": "Mô tả", "thumb": "https://cdn.example/t.jpg"}, "ts": 8_000},
                {"msgId": "1009", "cliMsgId": "c1009", "uidFrom": "u1", "idTo": "me", "msgType": "chat.recommended",
                 "content": {"action": "recommened.link", "href": "file:///etc/passwd", "title": "bad"}, "ts": 9_000},
                {"msgId": "1010", "cliMsgId": "c1010", "uidFrom": "u1", "idTo": "me", "msgType": "chat.recommended",
                 "content": {"action": "recommened.user", "title": "Nguyễn Văn B", "params": "777888", "thumb": "https://cdn.example/a.jpg"}, "ts": 10_000},
                {"msgId": "1011", "cliMsgId": "c1011", "uidFrom": "u1", "idTo": "me", "msgType": "chat.location.new",
                 "content": {"title": "Quán", "description": "Hà Nội", "params": {"lat": 21.0285, "lon": 105.8542, "locationName": "Quán cà phê"}}, "ts": 11_000},
                {"msgId": "1012", "cliMsgId": "c1012", "uidFrom": "u1", "idTo": "me", "msgType": "chat.recommended",
                 "content": {"action": "recommened.misscall", "params": {"duration": 0}}, "ts": 12_000},
                {"msgId": "1013", "cliMsgId": "c1013", "uidFrom": "u1", "idTo": "me", "msgType": "chat.ecard",
                 "content": {"action": "ecard.reminder", "title": "Họp", "description": "10h", "href": "https://cdn.example/e.png", "params": {"startTime": 1_795_000_000_000_i64, "topicTitle": "Họp nhóm", "repeatLabel": "Hằng ngày"}}, "ts": 13_000},
                {"msgId": "1014", "cliMsgId": "c1014", "uidFrom": "u1", "idTo": "me", "msgType": "chat.poll",
                 "content": {"question": "Ăn gì?", "description": "An đã bình chọn", "params": {"poll_id": "77", "is_anonymous": false}}, "ts": 14_000},
                {"msgId": "1015", "cliMsgId": "c1015", "uidFrom": "u1", "idTo": "me", "msgType": "chat.sys", "content": {"title": "Nhóm đổi tên"}, "ts": 15_000},
                {"msgId": "1016", "cliMsgId": "c1016", "uidFrom": "u1", "idTo": "me", "msgType": "chat.webcontent", "content": {"title": "Zinstant", "description": "d", "thumb": "https://cdn.example/z.png"}, "ts": 16_000},
                {"msgId": "1017", "cliMsgId": "c1017", "uidFrom": "u1", "idTo": "me", "msgType": "webchat", "content": cipher, "ts": 17_000},
                {"msgId": "1018", "cliMsgId": "c1018", "uidFrom": "u1", "idTo": "me", "msgType": "chat.mystery", "content": {"title": "lạ"}, "ts": 18_000},
                {"msgId": "1019", "cliMsgId": "c1019", "uidFrom": "u1", "idTo": "me", "msgType": "chat.sticker", "content": {"id": cipher, "catId": cipher, "type": cipher}, "ts": 19_000},
                {"msgType": "chat.undo", "uidFrom": "u1", "idTo": "me", "content": {"globalMsgId": "1001", "cliMsgId": "c1001"}}
            ]
        }
    });
    let options = WireOptions {
        self_conv_id: Some("cloud999".into()),
        names: vec![NameEntry {
            uid: "u1".into(),
            name: "An".into(),
            avatar: "https://ava.example/an.jpg".into(),
        }],
        ..WireOptions::default()
    };
    let events = parse_wire_batch(root.to_string(), "me".into(), options).unwrap();
    assert!(events.len() >= 19);

    let mut tags = HashSet::new();
    for ev in &events {
        if let WireEvent::Message { message, stored } = ev {
            tags.insert(stored.kind_tag.as_str());
            if message.id == "1001" {
                assert_eq!(message.sender_name, "An");
                assert_eq!(message.mentions.len(), 2);
                assert_eq!(message.quote.as_ref().unwrap().sender_name, "An");
            }
            if message.id == "1009" {
                assert!(matches!(message.kind, KindRecord::Link { url: None, .. }));
            }
            if message.id == "1017" || message.id == "1019" {
                assert!(stored.locked);
                assert!(matches!(message.kind, KindRecord::Placeholder { .. }));
            }
        }
    }
    for tag in [
        "text",
        "photo",
        "sticker",
        "gif",
        "video",
        "voice",
        "file",
        "link",
        "contactCard",
        "location",
        "call",
        "ecard",
        "poll",
        "system",
        "placeholder",
        "unsupported",
    ] {
        assert!(tags.contains(tag), "kind {tag} missing (got {tags:?})");
    }
    assert!(matches!(
        events.last().unwrap(),
        WireEvent::Undo {
            msg_id,
            cli_msg_id,
            ..
        } if msg_id == "1001" && cli_msg_id == "c1001"
    ));
}

#[tokio::test]
async fn typed_store_reads_and_single_lookup_golden_fixtures() {
    fn stored_row(
        id: &str,
        ts: i64,
        kind: &str,
        mut dict: serde_json::Map<String, serde_json::Value>,
    ) -> MessageRow {
        dict.insert("id".into(), serde_json::json!(id));
        if !dict.contains_key("clientId") {
            dict.insert("clientId".into(), serde_json::json!(format!("cli{id}")));
        }
        dict.insert("conversationId".into(), serde_json::json!("u1"));
        dict.insert("date".into(), serde_json::json!(ts));
        if !dict.contains_key("kind") {
            dict.insert("kind".into(), serde_json::json!({"type": kind}));
        }
        let client_id = dict
            .get("clientId")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_owned();
        let text = dict
            .get("text")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_owned();
        let kind_tag = dict
            .get("kind")
            .and_then(|v| v.as_object())
            .and_then(|k| k.get("type"))
            .and_then(|v| v.as_str())
            .unwrap_or("text")
            .to_owned();
        let raw_json = serde_json::to_vec(&serde_json::Value::Object(dict)).unwrap();
        MessageRow {
            id: id.into(),
            conv_id: "u1".into(),
            client_id,
            sender_id: "u1".into(),
            sender_name: "An".into(),
            sender_avatar: String::new(),
            is_mine: false,
            text,
            kind_tag,
            ts_ms: ts,
            status: "sent".into(),
            raw_json,
        }
    }

    let obj_from = |v: serde_json::Value| v.as_object().unwrap().clone();
    let heart = serde_json::json!({"type": "5", "key": "/-heart", "emoji": "❤️", "image": "", "count": 3, "includesMe": true, "names": ["Bạn", "An"], "people": 2, "userCounts": {"me": 1, "u1": 2}});
    let ghost = serde_json::json!({"type": "3", "key": "/-strong", "emoji": "👍", "image": "", "count": 1, "includesMe": false, "names": ["Người dùng Zalo"], "people": 1});
    let sentinel = serde_json::json!({"type": "0", "key": ":>", "emoji": "😆", "count": 2, "includesMe": false, "names": ["Lan"], "people": 1, "userCounts": {"__legacy__": 2}});
    let menu = serde_json::json!({"forward": "ok", "recall": true, "delete": "forMe", "pin": true, "star": "unstar", "starred": true, "pinned": true, "protected": true});

    let rows = vec![
        stored_row("2001", 1_000, "text", obj_from(serde_json::json!({"text": "xin chào", "senderAvatar": "https://ava.example/a.jpg", "isMine": true, "status": "delivered", "reactions": [heart, ghost, sentinel], "mentions": [{"uid": "u2", "pos": 1, "len": 3, "isAll": false}, {"uid": "", "pos": 0, "len": 1}], "menu": menu, "quote": {"senderName": "An", "text": "tin cũ"}, "isE2EE": true, "buttons": [{"ref": "b1", "label": "  Mở  ", "enabled": true, "help": "h"}, {"ref": "", "label": "x"}], "stickers": true}))),
        stored_row("2002", 2_000, "photo", obj_from(serde_json::json!({"kind": {"type": "photo", "url": "https://cdn.example/p.jpg", "width": 640.0, "height": 480, "fallbacks": ["https://cdn.example/n.jpg", "", "ht tp://bad url"]}, "text": "Ảnh"}))),
        stored_row("2003", 3_000, "sticker", obj_from(serde_json::json!({"kind": {"type": "sticker", "url": "  https://cdn.example/s.png "}, "text": "[Sticker]"}))),
        stored_row("2004", 4_000, "link", obj_from(serde_json::json!({"kind": {"type": "link", "title": "T", "url": "javascript:alert(1)", "thumbnail": "https://cdn.example/t.jpg", "description": "d", "source": "s"}}))),
        stored_row("2005", 5_000, "link", obj_from(serde_json::json!({"kind": {"type": "link", "title": "T", "url": "https://example.com/ok", "thumbnail": "", "description": "d", "source": "example.com"}}))),
        stored_row("2006", 6_000, "file", obj_from(serde_json::json!({"kind": {"type": "file", "name": "a.pdf", "size": 1.5e9, "url": "https://cdn.example/a.pdf"}, "text": "a.pdf"}))),
        stored_row("2007", 7_000, "location", obj_from(serde_json::json!({"kind": {"type": "location", "title": "Quán", "address": "Hà Nội", "hasCoordinates": true, "latitude": 21.03, "longitude": 105.85, "thumbnail": "https://cdn.example/m.png"}}))),
        stored_row("2008", 8_000, "location", obj_from(serde_json::json!({"kind": {"type": "location", "title": "Sai", "address": "", "hasCoordinates": true, "latitude": 999.0, "longitude": 105.85, "thumbnail": ""}}))),
        stored_row("2009", 9_000, "ecard", obj_from(serde_json::json!({"kind": {"type": "ecard", "style": "birthday", "image": "https://cdn.example/e.png", "thumb": "", "title": "SN", "description": "d", "actions": ["a", "", "b"], "avatars": ["https://cdn.example/1.png", "bad url"], "reminderTitle": "r", "reminderStart": 5.0e12, "reminderRepeat": ""}}))),
        stored_row("2010", 10_000, "ecard", obj_from(serde_json::json!({"kind": {"type": "ecard", "style": "weird", "title": "x", "reminderStart": 1_795_000_000_000.0}}))),
        stored_row("2011", 11_000, "oaMessage", obj_from(serde_json::json!({"kind": {"type": "oaMessage", "parts": [{"header": true, "title": "Tiêu đề", "description": "d", "thumb": "https://cdn.example/h.png", "url": "https://oa.example/1", "help": ""}, {"title": "", "thumb": ""}, {"header": false, "title": "Dòng", "url": "file:///x"}]}}))),
        stored_row("2012", 12_000, "poll", obj_from(serde_json::json!({"kind": {"type": "poll", "question": "Q", "header": "H", "anonymous": true, "pollId": "9", "conversationId": "u1"}}))),
        stored_row("2013", 13_000, "call", obj_from(serde_json::json!({"kind": {"type": "call", "video": true, "missed": true, "duration": 65, "title": "Bạn bị nhỡ", "detail": "1 phút"}}))),
        stored_row("2014", 14_000, "contactCard", obj_from(serde_json::json!({"kind": {"type": "contactCard", "name": "B", "uid": "77", "avatar": "https://cdn.example/b.png", "phone": "0900", "qr": "", "oaLink": "", "isOA": true}}))),
        stored_row("2015", 15_000, "placeholder", obj_from(serde_json::json!({"kind": {"type": "placeholder", "symbol": "", "text": "🔒 Tin nhắn mã hóa"}, "isE2EE": true}))),
        stored_row("2016", 16_000, "notice", obj_from(serde_json::json!({"kind": {"type": "notice", "symbol": "", "text": "Thông báo"}}))),
        stored_row("2017", 17_000, "recalled", obj_from(serde_json::json!({"text": "", "reactions": []}))),
        stored_row("2018", 18_000, "unsupported", obj_from(serde_json::json!({"kind": {"type": "unsupported", "rawType": "chat.x"}}))),
        stored_row("2019", 19_000, "video", obj_from(serde_json::json!({"kind": {"type": "video", "thumbnail": "https://cdn.example/v.jpg", "duration": 12, "url": "https://cdn.example/v.mp4"}}))),
        stored_row("2020", 20_000, "voice", obj_from(serde_json::json!({"kind": {"type": "voice", "url": "https://cdn.example/v.m4a", "duration": 3}}))),
        stored_row("2021", 21_000, "zinstant", obj_from(serde_json::json!({"kind": {"type": "zinstant", "title": "Z", "text": "t", "thumb": "https://cdn.example/z.png"}}))),
        stored_row("2022", 22_000, "stickerSet", obj_from(serde_json::json!({"kind": {"type": "stickerSet", "title": "Bộ", "thumb": ""}}))),
        stored_row("2023", 23_000, "gif", obj_from(serde_json::json!({"kind": {"type": "gif", "url": "https://cdn.example/a.gif"}}))),
        stored_row("2024", 24_000, "system", obj_from(serde_json::json!({"text": "Nhóm đổi tên"}))),
        MessageRow {
            id: "2025".into(),
            conv_id: "u1".into(),
            client_id: "cli2025".into(),
            sender_id: "u1".into(),
            sender_name: "An".into(),
            sender_avatar: String::new(),
            is_mine: false,
            text: "hỏng".into(),
            kind_tag: "text".into(),
            ts_ms: 25_000,
            status: "sent".into(),
            raw_json: b"not json".to_vec(),
        },
        MessageRow {
            id: "2026".into(),
            conv_id: "u1".into(),
            client_id: "colcli".into(),
            sender_id: "u1".into(),
            sender_name: "An".into(),
            sender_avatar: String::new(),
            is_mine: false,
            text: "t".into(),
            kind_tag: "text".into(),
            ts_ms: 26_000,
            status: "sent".into(),
            raw_json: br#"{"id":"2026","conversationId":"u1","kind":{"type":"text"},"text":"t","date":26000}"#.to_vec(),
        },
    ];

    let total_rows = rows.len();
    let dir = tempfile::tempdir().unwrap();
    let store = CoreStore::open(dir.path().join("t.db").to_string_lossy().into_owned()).unwrap();
    store.save_messages(rows.clone()).await.unwrap();

    let all = store.messages_chat("u1".into(), None, 100).await.unwrap();
    assert_eq!(all.len(), total_rows - 1); // 2025 corrupt row drops

    // Sync reader agrees with async reader
    assert_eq!(
        store
            .read_chat_messages_now("u1".into(), Some(20_500), 100)
            .unwrap(),
        store
            .messages_chat("u1".into(), Some(20_500), 100)
            .await
            .unwrap()
    );
    assert_eq!(
        store.read_chat_messages_now("u1".into(), None, 5).unwrap(),
        store.messages_chat("u1".into(), None, 5).await.unwrap()
    );
    assert_eq!(
        store
            .search_messages_chat("u1".into(), "xin".into(), 10)
            .await
            .unwrap()
            .len(),
        1
    );
    let around = store
        .messages_around_chat("u1".into(), 5_000, None, 2, 6)
        .await
        .unwrap();
    assert!(!around.messages.is_empty());

    // Canonical re-encode round-trip produces identical decoded messages
    let dir2 = tempfile::tempdir().unwrap();
    let store2 = CoreStore::open(dir2.path().join("t2.db").to_string_lossy().into_owned()).unwrap();
    store2
        .save_chat_messages(
            all.iter().map(|r| r.message.clone()).collect(),
            false,
            false,
        )
        .await
        .unwrap();
    assert_eq!(
        store2.messages_chat("u1".into(), None, 100).await.unwrap(),
        all
    );

    // Every non-corrupt row resolves by server id and client id; 2025 corrupt and misses return None
    let mut found = 0usize;
    for r in &rows {
        for key in [r.id.as_str(), r.client_id.as_str()] {
            let got = store.message_chat("u1".into(), key.into()).await.unwrap();
            if r.id == "2025" {
                assert!(got.is_none());
            } else {
                let got = got.expect("valid row");
                found += 1;
                assert_eq!(got.row_id, r.id);
                assert_eq!(got.row_client_id, r.client_id);
            }
        }
    }
    assert!(found > 40);
    assert!(
        store
            .message_chat("u1".into(), "missing".into())
            .await
            .unwrap()
            .is_none()
    );
    assert!(
        store
            .message_chat("other".into(), "2001".into())
            .await
            .unwrap()
            .is_none()
    );
    let fallback = store
        .message_chat("u1".into(), "colcli".into())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        (fallback.row_id.as_str(), fallback.row_client_id.as_str()),
        ("2026", "colcli")
    );
}

#[test]
fn history_batch_with_quote_photo_and_undo_matches_parse_wire_batch() {
    let body = serde_json::json!({
        "error_code": 0,
        "data": {
            "hasMore": 1,
            "isOld": 0,
            "lastMsgId": "7412345678901234500",
            "groupMsgs": [
                {"msgId": "7412345678901234567", "cliMsgId": "c1", "uidFrom": "u1", "idTo": "g1", "msgType": "webchat", "content": "Chào nhóm", "ts": 1_795_000_000_000_i64,
                 "quote": {"ownerId": "u1", "msg": "Tin cũ", "fromD": "x"}},
                {"msgId": "7412345678901234568", "cliMsgId": "c2", "uidFrom": "me", "idTo": "g1", "msgType": "chat.photo", "content": {"hd": "https://cdn.example/p.jpg", "title": "Anh"}, "ts": 1_795_000_001_000_i64},
                {"msgType": "chat.undo", "uidFrom": "u1", "idTo": "g1", "content": {"globalMsgId": "7412345678901234567", "cliMsgId": "c1"}}
            ]
        }
    });
    let h = history_record_from_json(body.to_string()).unwrap();
    assert!(h.has_more && !h.is_old);
    assert_eq!(h.last_msg_id, "7412345678901234500");
    assert_eq!(h.uids, vec!["me".to_owned(), "u1".to_owned()]);
    for fallback in ["g1", "g:g1"] {
        let o = WireOptions {
            fallback_conv_id: Some(fallback.into()),
            is_group_hint: Some(true),
            self_conv_id: Some("cloud999".into()),
            names: vec![NameEntry {
                uid: "u1".into(),
                name: "An".into(),
                avatar: "https://ava.example/an.jpg".into(),
            }],
            ..WireOptions::default()
        };
        let typed = h.batch.events("me".into(), o.clone());
        let via_json = parse_wire_batch(h.batch.raw_json(), "me".into(), o).unwrap();
        assert!(typed.len() >= 3);
        assert_eq!(typed, via_json);
    }
}

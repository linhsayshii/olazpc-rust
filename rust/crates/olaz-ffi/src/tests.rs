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
}

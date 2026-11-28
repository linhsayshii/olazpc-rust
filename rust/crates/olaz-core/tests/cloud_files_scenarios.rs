#![allow(clippy::expect_used, clippy::unwrap_used)]
//! Regression tests for "Cloud của tôi" / zCloud saved files missing when older than the
//! bootstrap recent window (~20 messages).
//!
//! Uses synthetic IDs, filenames, and `example.invalid` URLs only (zero live network traffic).

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use olaz_api::PollState;
use olaz_core::actor::{ActorSink, CoreHandle};
use olaz_core::cloud::{CloudFetch, CloudItemKind};
use olaz_core::conversations::BatchApplyDelta;
use olaz_core::forward::{FileResolutionOutcome, MediaResolutionOutcome};
use olaz_core::input::{Command, LegacyCookie};
use olaz_core::reduce::classify::MobileSyncEvent;
use olaz_core::runner::{EffectRunner, Host, SessionEffectRunner, WsDriver, WsStartParams};
use olaz_core::state::{CoreState, Phase, Profile};
use olaz_core::typed_chat::TypedChatEnvelope;
use olaz_crypto::{decode_aes, encode_aes};
use olaz_net::SessionClient;
use olaz_net::domains::ZaloDomains;
use olaz_net::http::RawResponse;
use olaz_net::mock::MockTransport;
use olaz_net::session::{LoginAccount, SessionState};
use olaz_store::{Store, StoredConversation};
use olaz_wire::{ChatMessage, Kind, MessageMenu, Status, encode_chat_message};
use olaz_ws::CursorMap;
use serde_json::{Map, Value, json};
use tokio::runtime::Handle;

const TEST_UID: &str = "2009001";
const TEST_SELF_CONV: &str = "92009001";
const TEST_KEY: &[u8] = b"0123456789abcdef";

struct NoopWsDriver;

#[async_trait]
impl WsDriver for NoopWsDriver {
    fn start(&self, _params: WsStartParams, _sink: ActorSink, _runtime: &Handle) {}
    fn stop(&self, _reset_cursors: bool) {}
    fn record_file_done(&self, _file_id: String, _url: String) {}
    async fn send_frame(&self, _cmd: u16, _sub_cmd: u8, _payload_json: Option<Vec<u8>>) -> bool {
        false
    }
    async fn send_frame_versioned(
        &self,
        _cmd: u16,
        _sub_cmd: u8,
        _version: u8,
        _payload_json: Option<Vec<u8>>,
    ) -> bool {
        false
    }
    async fn send_request(
        &self,
        _cmd: u16,
        _sub_cmd: u8,
        _version: u8,
        _req_id: Option<String>,
        _inner_data: Map<String, Value>,
        _timeout: Duration,
    ) -> Option<Map<String, Value>> {
        None
    }
    async fn wait_for_file_done(&self, _file_id: String, _timeout: Duration) -> Option<String> {
        None
    }
    async fn is_authed(&self) -> bool {
        false
    }
    async fn current_cursors(&self) -> CursorMap {
        CursorMap::new()
    }
    async fn seed_cursors(&self, _cursors: CursorMap) {}
}

struct TestCloudHost {
    resolved_files: Mutex<Vec<(String, String, String, Option<String>)>>,
}

impl TestCloudHost {
    fn new() -> Self {
        Self {
            resolved_files: Mutex::new(Vec::new()),
        }
    }
}

#[async_trait]
impl Host for TestCloudHost {
    async fn load_saved_session(&self) -> Option<String> {
        None
    }
    async fn load_legacy_cookie(&self) -> Option<LegacyCookie> {
        None
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
    async fn pin_topic(&self, _conv_id: String) -> bool {
        false
    }
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
    async fn resolve_media(
        &self,
        _conv_id: String,
        _msg_id: String,
        _kind: String,
    ) -> MediaResolutionOutcome {
        MediaResolutionOutcome::File("/tmp/fake_photo.jpg".to_owned())
    }
    async fn resolve_file(
        &self,
        conv_id: String,
        msg_id: String,
        name: String,
        url: Option<String>,
    ) -> FileResolutionOutcome {
        self.resolved_files
            .lock()
            .unwrap()
            .push((conv_id, msg_id, name.clone(), url));
        FileResolutionOutcome::Ready(format!("/tmp/staged/{name}"))
    }
}

fn encrypted_ok(inner: &Value) -> RawResponse {
    let cipher = encode_aes(TEST_KEY, &serde_json::to_string(inner).unwrap()).unwrap();
    let body = serde_json::to_vec(&json!({
        "error_code": 0,
        "data": cipher,
    }))
    .unwrap();
    RawResponse::new(200, body)
}

fn decode_query_params(url: &str) -> Value {
    let query = url.split_once('?').map_or("", |(_, q)| q);
    let encoded = query
        .split('&')
        .find_map(|pair| pair.strip_prefix("params="))
        .expect("missing params query param");
    let decoded = percent_decode(encoded);
    let plain = decode_aes(TEST_KEY, &decoded).expect("failed to decrypt params");
    serde_json::from_str(&plain).expect("invalid params json")
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let Ok(val) =
                u8::from_str_radix(std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or(""), 16)
        {
            out.push(val);
            i += 3;
            continue;
        }
        if bytes[i] == b'+' {
            out.push(b' ');
        } else {
            out.push(bytes[i]);
        }
        i += 1;
    }
    String::from_utf8(out).unwrap()
}

fn seed_store_with_recent_photo_only(store: &mut Store) {
    store
        .save_conversations(&[StoredConversation {
            id: TEST_SELF_CONV.to_owned(),
            name: "Cloud của tôi".to_owned(),
            avatar: String::new(),
            is_group: false,
            pinned: false,
            members: 0,
            unread: 0,
            preview_text: "[Hình ảnh]".to_owned(),
            preview_from_me: true,
            preview_ts_ms: 1_700_000_900_000,
            updated_at_ms: 1_700_000_900_000,
        }])
        .unwrap();

    let recent_photo = ChatMessage {
        id: "m_recent_photo".to_owned(),
        conversation_id: TEST_SELF_CONV.to_owned(),
        sender_id: TEST_UID.to_owned(),
        sender_name: "Bạn".to_owned(),
        sender_avatar: None,
        is_mine: true,
        kind: Kind::Photo {
            url: Some("https://cdn.example.invalid/recent.jpg".to_owned()),
            width: 800,
            height: 600,
        },
        text: String::new(),
        date_ms: 1_700_000_900_000,
        status: Status::Sent,
        quote: None,
        reactions: Vec::new(),
        is_e2ee: false,
        mentions: Vec::new(),
        card_buttons: Vec::new(),
        suggests_stickers: false,
        menu: MessageMenu::default(),
        fallback_urls: Vec::new(),
        client_id: "cli_recent_photo".to_owned(),
        text_styles: Vec::new(),
        ttl_ms: 0,
        urgency: 0,
    };
    let wire_stored = encode_chat_message(&recent_photo, "").unwrap();
    let db_stored = olaz_store::StoredMessage {
        id: wire_stored.id,
        conv_id: wire_stored.conv_id,
        client_id: wire_stored.client_id,
        sender_id: wire_stored.sender_id,
        sender_name: wire_stored.sender_name,
        sender_avatar: wire_stored.sender_avatar,
        is_mine: wire_stored.is_mine,
        text: wire_stored.text,
        kind_tag: wire_stored.kind_tag,
        ts_ms: wire_stored.ts_ms,
        status: wire_stored.status,
        raw_json_data: wire_stored.raw_json_data,
    };
    store.save_messages(&[db_stored]).unwrap();
}

async fn setup_engine(
    transport: MockTransport,
) -> (
    CoreHandle,
    Arc<SessionEffectRunner<MockTransport>>,
    Arc<TestCloudHost>,
    Arc<Mutex<Store>>,
) {
    let mut net_state = SessionState::new("test_imei".to_owned(), "TestMac".to_owned());
    net_state.domains = ZaloDomains::default();
    net_state.update_credentials(
        LoginAccount {
            user_id: TEST_UID.to_owned(),
            display_name: "Test User".to_owned(),
            send2me_id: TEST_SELF_CONV.to_owned(),
            zpw_enk: "0123456789abcdef".to_owned(),
            zpw_sek: "sek.test".to_owned(),
            ..LoginAccount::default()
        },
        TEST_KEY.to_vec(),
        "sek.test".to_owned(),
        Some(ZaloDomains::default()),
    );
    let client = Arc::new(SessionClient::with_state(transport, net_state));
    let host = Arc::new(TestCloudHost::new());
    let runner = Arc::new(SessionEffectRunner::with_options(
        Arc::clone(&client),
        host.clone(),
        Arc::new(NoopWsDriver),
        Handle::current(),
        Some(ZaloDomains::default()),
        true,
    ));

    let store = Arc::new(Mutex::new(Store::open_in_memory().unwrap()));
    seed_store_with_recent_photo_only(&mut store.lock().unwrap());
    runner.attach_store(Arc::clone(&store));

    let mut initial = CoreState::default();
    initial.session.phase = Phase::Ready;
    initial.session.self_conversation_id = Some(TEST_SELF_CONV.to_owned());
    initial.session.profile = Some(Profile {
        user_id: TEST_UID.to_owned(),
        display_name: "Test User".to_owned(),
        avatar: None,
        phone: None,
    });

    let core = CoreHandle::start_with_state(initial, runner.clone() as Arc<dyn EffectRunner>, Handle::current());
    (core, runner, host, store)
}

#[tokio::test]
async fn my_cloud_file_tab_loads_saved_files_from_media_store_when_absent_from_local_sqlite() {
    let transport = MockTransport::from_fn(|req| {
        if req.url.contains("/api/media/oneone/list") {
            let params = decode_query_params(&req.url);
            let media_type = params
                .get("media_type")
                .and_then(Value::as_str)
                .unwrap_or("");
            if media_type == "file" {
                return Ok(encrypted_ok(&json!({
                    "error_code": 0,
                    "data": {
                        "has_more": false,
                        "last_id": "ms_file_2",
                        "items": [
                            {
                                "id": "ms_file_1",
                                "global_msg_id": "700001",
                                "client_msg_id": "cli_700001",
                                "owner_id": TEST_UID,
                                "created_time": 1_700_000_500_000_i64,
                                "type": "file",
                                "file_name": "HopDong_2026.pdf",
                                "title": "HopDong_2026.pdf",
                                "file_size": 245_760,
                                "fileExt": "pdf",
                                "fType": 1,
                                "src_url": "https://cdn.example.invalid/files/HopDong_2026.pdf"
                            },
                            {
                                "id": "ms_file_2",
                                "global_msg_id": "700002",
                                "client_msg_id": "cli_700002",
                                "owner_id": TEST_UID,
                                "created_time": 1_700_000_200_000_i64,
                                "type": "file",
                                "file_name": "TaiLieuDuAn",
                                "title": "TaiLieuDuAn.zip",
                                "file_size": 1_048_576,
                                "fileExt": "zip",
                                "fType": 2,
                                "src_url": "https://cdn.example.invalid/files/TaiLieuDuAn.zip"
                            }
                        ]
                    }
                })));
            }
            return Ok(encrypted_ok(&json!({
                "error_code": 0,
                "data": { "has_more": false, "last_id": "", "items": [] }
            })));
        }
        Ok(RawResponse::new(404, Vec::new()))
    });

    let (core, _runner, host, store) = setup_engine(transport).await;

    let page = core
        .request_cloud_page(Command::CloudList {
            conv_id: Some(TEST_SELF_CONV.to_owned()),
            kind: Some(CloudItemKind::File),
            sort_by_size: false,
            ascending: false,
            offset: 0,
            limit: 60,
        })
        .await;

    assert_eq!(page.error, None);
    assert_eq!(
        page.items.len(),
        2,
        "expected 2 saved files from media_store_send2me"
    );
    assert_eq!(page.items[0].title, "HopDong_2026.pdf");
    assert_eq!(page.items[0].ext, "pdf");
    assert_eq!(page.items[0].size, 245_760);
    assert_eq!(page.items[1].title, "TaiLieuDuAn.zip");
    assert_eq!(page.items[1].ext, "zip");
    assert_eq!(page.items[1].size, 1_048_576);

    // Server-only My Cloud files MUST NOT pollute SQLite `messages` table (would create chat history gaps).
    let stored_msgs = store
        .lock()
        .unwrap()
        .messages(TEST_SELF_CONV, None, 50)
        .unwrap();
    assert_eq!(stored_msgs.len(), 1);
    assert_eq!(stored_msgs[0].id, "m_recent_photo");

    // Downloading/opening the server-only file via CloudFetch must resolve its URL from cache.
    let fetch = core
        .request_cloud_fetch(Command::CloudFetch {
            key: page.items[0].id.clone(),
        })
        .await;
    match fetch {
        CloudFetch::Ready(file) => {
            assert_eq!(file.title, "HopDong_2026.pdf");
            assert_eq!(file.ext, "pdf");
        }
        other => panic!("expected CloudFetch::Ready, got {other:?}"),
    }
    let resolved = host.resolved_files.lock().unwrap();
    assert_eq!(resolved.len(), 1);
    assert_eq!(
        resolved[0].3.as_deref(),
        Some("https://cdn.example.invalid/files/HopDong_2026.pdf")
    );
}

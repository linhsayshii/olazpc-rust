//! U14 Search domain types and pure message-matching helpers.
//!
//! Uses `olaz_store::search_text` as the single shared fold/trim/contains implementation so
//! in-memory matching and SQLite search cannot drift apart.

use std::collections::{HashMap, HashSet, VecDeque};

use olaz_store::{fold_search_text, search_text_contains_folded, trim_search_query};
use olaz_wire::{ChatMessage, Kind};

use crate::effect::{Effect, OpResult};
use crate::reduce::ReduceOutput;

/// Returns `true` when `message` matches `query` under the exact Swift `ZaloEngine+Search.swift`
/// rule (`trimmingCharacters(in: .whitespacesAndNewlines)` + `lowercased().contains`).
#[must_use]
pub fn message_matches_search_query(message: &ChatMessage, query: &str) -> bool {
    let trimmed = trim_search_query(query);
    if trimmed.is_empty() {
        return false;
    }
    let folded_needle = fold_search_text(trimmed);
    message_matches_folded_needle(message, &folded_needle)
}

/// Returns `true` when `message` matches pre-folded `folded_needle` (produced by
/// [`olaz_store::fold_search_text`]).
#[must_use]
pub fn message_matches_folded_needle(message: &ChatMessage, folded_needle: &str) -> bool {
    if folded_needle.is_empty() {
        return false;
    }
    if matches!(message.kind, Kind::Recalled) {
        return false;
    }
    if matches!(message.kind, Kind::Placeholder { .. }) && message.is_e2ee {
        return false;
    }

    if search_text_contains_folded(&message.text, folded_needle) {
        return true;
    }

    match &message.kind {
        Kind::File { name, .. } => search_text_contains_folded(name, folded_needle),
        Kind::Link {
            title, description, ..
        } => {
            search_text_contains_folded(title, folded_needle)
                || search_text_contains_folded(description, folded_needle)
        }
        Kind::ContactCard(card) => search_text_contains_folded(&card.name, folded_needle),
        Kind::Location(info) => {
            search_text_contains_folded(&info.title, folded_needle)
                || search_text_contains_folded(&info.address, folded_needle)
        }
        Kind::Call { title, detail, .. } => {
            search_text_contains_folded(title, folded_needle)
                || search_text_contains_folded(detail, folded_needle)
        }
        Kind::Ecard(card) => {
            search_text_contains_folded(&card.title, folded_needle)
                || search_text_contains_folded(&card.description, folded_needle)
                || search_text_contains_folded(&card.reminder_title, folded_needle)
        }
        Kind::OaMessage(parts) => parts.iter().any(|part| {
            search_text_contains_folded(&part.title, folded_needle)
                || search_text_contains_folded(&part.description, folded_needle)
        }),
        Kind::Poll(poll) => {
            search_text_contains_folded(&poll.question, folded_needle)
                || search_text_contains_folded(&poll.header, folded_needle)
        }
        Kind::StickerSet { title, .. } => search_text_contains_folded(title, folded_needle),
        Kind::Zinstant { title, text, .. } => {
            search_text_contains_folded(title, folded_needle)
                || search_text_contains_folded(text, folded_needle)
        }
        Kind::Notice { text, .. } => search_text_contains_folded(text, folded_needle),
        Kind::Text
        | Kind::Photo { .. }
        | Kind::Sticker { .. }
        | Kind::Gif { .. }
        | Kind::Video { .. }
        | Kind::Voice { .. }
        | Kind::Placeholder { .. }
        | Kind::System
        | Kind::Recalled
        | Kind::Unsupported { .. } => false,
    }
}

/// Active state for an in-flight cursor-paged `SearchMessages` request.
#[derive(Clone, Debug)]
pub(crate) struct PendingSearch {
    pub conv_id: String,
    pub trimmed_query: String,
    pub folded_needle: String,
    pub limit: usize,
    pub page_size: usize,
    pub pending_deleted_keys: HashSet<String>,
    pub memory_keys: HashSet<String>,
    pub seen_keys: HashSet<String>,
    pub memory_results: Vec<ChatMessage>,
    pub store_results: Vec<ChatMessage>,
}

/// Active state for an in-flight `EnsureMessageLoaded` request (standalone or chained from
/// `LoadQuotedMessage`).
#[derive(Clone, Debug)]
pub(crate) struct PendingEnsureLoaded {
    pub conv_id: String,
    pub message: ChatMessage,
    pub pending_deleted_keys: HashSet<String>,
    /// When `true`, completes with `OpResult::OptionalString` instead of `OpResult::Bool`.
    pub for_quote: bool,
}

/// Active state for an in-flight `LoadQuotedMessage` store lookup.
#[derive(Clone, Debug)]
pub(crate) struct PendingLoadQuoted {
    pub conv_id: String,
    pub remaining_keys: VecDeque<String>,
    pub legacy_text: Option<String>,
    pub mine_only: bool,
    pub pending_deleted_keys: HashSet<String>,
    pub memory_shadow_keys: HashSet<String>,
}

/// Pending request tables for U14 search / ensure-loaded / load-quoted flows.
#[derive(Clone, Debug, Default)]
pub struct SearchState {
    pub(crate) pending_searches: HashMap<u64, PendingSearch>,
    pub(crate) pending_ensures: HashMap<u64, PendingEnsureLoaded>,
    pub(crate) pending_quotes: HashMap<u64, PendingLoadQuoted>,
}

impl SearchState {
    /// Cancels and completes all in-flight U14 ops on logout or session expiry so callers never hang.
    pub fn reset(&mut self, out: &mut ReduceOutput) {
        for (op_id, _) in self.pending_searches.drain() {
            out.effects.push(Effect::CompleteOp {
                op_id,
                result: OpResult::SearchMessages(Vec::new()),
                after_store: false,
            });
        }
        for (op_id, pending) in self.pending_ensures.drain() {
            let result = if pending.for_quote {
                OpResult::OptionalString(None)
            } else {
                OpResult::Bool(false)
            };
            out.effects.push(Effect::CompleteOp {
                op_id,
                result,
                after_store: false,
            });
        }
        for (op_id, _) in self.pending_quotes.drain() {
            out.effects.push(Effect::CompleteOp {
                op_id,
                result: OpResult::OptionalString(None),
                after_store: false,
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use olaz_net::{SessionClient, mock::MockTransport};
    use olaz_store::{Store, StoredMessage};
    use olaz_wire::{
        ChatMessage, ContactCard, ECard, Kind, LocationInfo, OaPart, PollInfo, Quote, Status,
    };

    use super::*;
    use crate::actor::CoreHandle;
    use crate::input::Command;
    use crate::runner::{Host, SessionEffectRunner};
    use crate::state::CoreState;

    struct NoopHost;

    #[async_trait::async_trait]
    impl Host for NoopHost {
        async fn load_saved_session(&self) -> Option<String> {
            None
        }
        async fn load_legacy_cookie(&self) -> Option<crate::input::LegacyCookie> {
            None
        }
        async fn set_pref(&self, _key: String, _value: String) {}
        async fn prepare_store(&self, _user_id: String, _account: olaz_net::LoginAccount) {}
        async fn start_bootstrap(&self) {}
        async fn offer_first_login_transfer(&self, _force: bool) {}
        async fn reset_domains(&self) {}
        async fn persist_session(&self, _snapshot_json: String) {}
        async fn clear_session(&self) {}
        async fn mark_expired(&self, _snapshot_json: String) {}
        async fn persist_poll_state(&self, _state: olaz_api::PollState) {}
        async fn persist_ws_cursors(&self, _cursors: olaz_ws::CursorMap) {}
        async fn apply_batch(
            &self,
            _cmd: Option<u16>,
            _increment_unread: bool,
            _notify_incoming: bool,
            _payload: serde_json::Map<String, serde_json::Value>,
        ) -> crate::conversations::BatchApplyDelta {
            crate::conversations::BatchApplyDelta::default()
        }
        async fn apply_parsed_events(
            &self,
            _cmd: u16,
            _increment_unread: bool,
            _notify_incoming: bool,
            _envelope: crate::typed_chat::TypedChatEnvelope,
        ) -> crate::conversations::BatchApplyDelta {
            crate::conversations::BatchApplyDelta::default()
        }
        async fn mobile_sync(&self, _events: Vec<crate::reduce::classify::MobileSyncEvent>) {}
        async fn e2ee_signal(
            &self,
            _cmd: u16,
            _payload: serde_json::Map<String, serde_json::Value>,
        ) {
        }
        async fn e2ee_deliver_reports(
            &self,
            _cmd: u16,
            _payload: serde_json::Map<String, serde_json::Value>,
        ) {
        }
        async fn e2ee_connected(&self, _uid: String) {}
        async fn e2ee_disconnected(&self) {}
        async fn voip_control(
            &self,
            _act: String,
            _raw_data: serde_json::Value,
            _data: serde_json::Map<String, serde_json::Value>,
        ) {
        }
        async fn show_typing(&self, _conv_id: String, _uid: String, _on_pc: bool) {}
        async fn pin_topic(&self, _conv_id: String) {}
        async fn group_notice(
            &self,
            _act: String,
            _data: serde_json::Map<String, serde_json::Value>,
            _ts: i64,
        ) {
        }
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

    fn base_msg(id: &str, conv_id: &str, date_ms: i64, text: &str, kind: Kind) -> ChatMessage {
        ChatMessage {
            id: id.to_owned(),
            conversation_id: conv_id.to_owned(),
            sender_id: "u1".to_owned(),
            sender_name: "Alice".to_owned(),
            sender_avatar: None,
            is_mine: false,
            kind,
            text: text.to_owned(),
            date_ms,
            status: Status::Sent,
            quote: None,
            reactions: Vec::new(),
            is_e2ee: false,
            mentions: Vec::new(),
            card_buttons: Vec::new(),
            suggests_stickers: false,
            menu: Default::default(),
            fallback_urls: Vec::new(),
            client_id: format!("cli_{id}"),
            text_styles: Vec::new(),
            ttl_ms: 0,
            urgency: 0,
        }
    }

    #[expect(clippy::too_many_arguments, reason = "compact test fixture builder")]
    fn stored_row(
        id: &str,
        conv_id: &str,
        client_id: &str,
        text: &str,
        ts_ms: i64,
        kind_tag: &str,
        is_mine: bool,
        raw_json: &str,
    ) -> StoredMessage {
        StoredMessage {
            id: id.to_owned(),
            conv_id: conv_id.to_owned(),
            client_id: client_id.to_owned(),
            sender_id: if is_mine {
                "me".to_owned()
            } else {
                "u1".to_owned()
            },
            sender_name: "Alice".to_owned(),
            sender_avatar: String::new(),
            is_mine,
            text: text.to_owned(),
            kind_tag: kind_tag.to_owned(),
            ts_ms,
            status: "sent".to_owned(),
            raw_json_data: raw_json.as_bytes().to_vec(),
        }
    }

    fn start_test_core(store: Store) -> (CoreHandle, Arc<SessionEffectRunner<MockTransport>>) {
        let client = Arc::new(SessionClient::new(
            MockTransport::scripted(Vec::new()),
            "test-imei".to_owned(),
            "Mac".to_owned(),
        ));
        let host: Arc<dyn Host> = Arc::new(NoopHost);
        let rt = tokio::runtime::Handle::current();
        let runner = Arc::new(SessionEffectRunner::new(client, host, rt.clone()));
        runner.attach_store(Arc::new(Mutex::new(store)));
        let handle = CoreHandle::start_with_state(CoreState::default(), runner.clone(), rt);
        (handle, runner)
    }

    #[test]
    fn message_matches_all_kinds_and_exclusions() {
        assert!(message_matches_search_query(
            &base_msg("1", "c", 1, "hello Kestrel", Kind::Text),
            "kestrel"
        ));
        assert!(message_matches_search_query(
            &base_msg(
                "2",
                "c",
                2,
                "[Tệp]",
                Kind::File {
                    name: "Kestrel.pdf".into(),
                    size: 10,
                    url: None,
                }
            ),
            "kestrel"
        ));
        assert!(message_matches_search_query(
            &base_msg(
                "3",
                "c",
                3,
                "[Link]",
                Kind::Link {
                    title: "T".into(),
                    url: None,
                    thumbnail: None,
                    description: "Kestrel desc".into(),
                    source: String::new(),
                }
            ),
            "kestrel"
        ));
        assert!(message_matches_search_query(
            &base_msg(
                "4",
                "c",
                4,
                "[Danh thiếp]",
                Kind::ContactCard(ContactCard {
                    name: "Kestrel Card".into(),
                    ..Default::default()
                })
            ),
            "kestrel"
        ));
        assert!(message_matches_search_query(
            &base_msg(
                "5",
                "c",
                5,
                "[Vị trí]",
                Kind::Location(LocationInfo {
                    title: "Spot".into(),
                    address: "Kestrel St".into(),
                    ..Default::default()
                })
            ),
            "kestrel"
        ));
        assert!(message_matches_search_query(
            &base_msg(
                "6",
                "c",
                6,
                "[Cuộc gọi]",
                Kind::Call {
                    video: false,
                    missed: false,
                    duration: 12,
                    title: "Call".into(),
                    detail: "Kestrel detail".into(),
                }
            ),
            "kestrel"
        ));
        assert!(message_matches_search_query(
            &base_msg(
                "7",
                "c",
                7,
                "[Thiệp]",
                Kind::Ecard(ECard {
                    reminder_title: "Kestrel reminder".into(),
                    ..Default::default()
                })
            ),
            "kestrel"
        ));
        assert!(message_matches_search_query(
            &base_msg(
                "8",
                "c",
                8,
                "[OA]",
                Kind::OaMessage(vec![OaPart {
                    is_header: false,
                    title: "Kestrel OA".into(),
                    description: String::new(),
                    thumb: None,
                    url: None,
                    help: String::new(),
                }])
            ),
            "kestrel"
        ));
        assert!(message_matches_search_query(
            &base_msg(
                "9",
                "c",
                9,
                "[Poll]",
                Kind::Poll(PollInfo {
                    question: "Kestrel?".into(),
                    ..Default::default()
                })
            ),
            "kestrel"
        ));
        assert!(message_matches_search_query(
            &base_msg(
                "10",
                "c",
                10,
                "[StickerSet]",
                Kind::StickerSet {
                    title: "Kestrel Pack".into(),
                    thumbnail: None,
                }
            ),
            "kestrel"
        ));
        assert!(message_matches_search_query(
            &base_msg(
                "11",
                "c",
                11,
                "[Z]",
                Kind::Zinstant {
                    title: "T".into(),
                    text: "Kestrel body".into(),
                    thumbnail: None,
                }
            ),
            "kestrel"
        ));
        assert!(message_matches_search_query(
            &base_msg(
                "12",
                "c",
                12,
                "[N]",
                Kind::Notice {
                    symbol: "info".into(),
                    text: "Kestrel notice".into(),
                }
            ),
            "kestrel"
        ));
        // Recalled excluded even if text contains query.
        assert!(!message_matches_search_query(
            &base_msg("13", "c", 13, "kestrel recalled", Kind::Recalled),
            "kestrel"
        ));
        // E2EE locked placeholder excluded.
        let mut locked = base_msg(
            "14",
            "c",
            14,
            "kestrel locked",
            Kind::Placeholder {
                symbol: "lock".into(),
                text: "kestrel".into(),
            },
        );
        locked.is_e2ee = true;
        assert!(!message_matches_search_query(&locked, "kestrel"));
        // Non-E2EE placeholder does NOT match kind.text.
        assert!(!message_matches_search_query(
            &base_msg(
                "15",
                "c",
                15,
                "",
                Kind::Placeholder {
                    symbol: "info".into(),
                    text: "kestrel".into(),
                }
            ),
            "kestrel"
        ));
        // Whitespace-only query returns false.
        assert!(!message_matches_search_query(
            &base_msg("16", "c", 16, "hello", Kind::Text),
            " \t\n\u{200B} "
        ));
    }

    #[test]
    fn message_matches_unicode_edge_cases() {
        // NFC vs NFD
        assert!(message_matches_search_query(
            &base_msg("1", "c", 1, "\u{1EA5}", Kind::Text),
            "a\u{0302}\u{0301}"
        ));
        assert!(message_matches_search_query(
            &base_msg("2", "c", 2, "a\u{0302}\u{0301}", Kind::Text),
            "\u{1EA5}"
        ));
        assert!(!message_matches_search_query(
            &base_msg("3", "c", 3, "a\u{0302}\u{0301}", Kind::Text),
            "a"
        ));
        // Đ / đ
        assert!(message_matches_search_query(
            &base_msg("4", "c", 4, "Đà Nẵng", Kind::Text),
            "đà"
        ));
        // Turkish İ
        assert!(!message_matches_search_query(
            &base_msg("5", "c", 5, "\u{0130}stanbul", Kind::Text),
            "i"
        ));
        assert!(message_matches_search_query(
            &base_msg("6", "c", 6, "\u{0130}stanbul", Kind::Text),
            "i\u{0307}"
        ));
        assert!(message_matches_search_query(
            &base_msg("7", "c", 7, "\u{0130}stanbul", Kind::Text),
            "\u{0130}"
        ));
        // Kelvin sign K (U+212A)
        assert!(message_matches_search_query(
            &base_msg("8", "c", 8, "300\u{212A}", Kind::Text),
            "k"
        ));
        assert!(message_matches_search_query(
            &base_msg("9", "c", 9, "300k", Kind::Text),
            "\u{212A}"
        ));
        // ß and ẞ
        assert!(!message_matches_search_query(
            &base_msg("10", "c", 10, "Straße", Kind::Text),
            "ss"
        ));
        assert!(message_matches_search_query(
            &base_msg("11", "c", 11, "STRA\u{1E9E}E", Kind::Text),
            "ß"
        ));
        // Whitespace trim (incl. U+200B)
        assert!(message_matches_search_query(
            &base_msg("12", "c", 12, "hello", Kind::Text),
            "\u{200B}  HELLO \n\t\u{00A0}"
        ));
    }

    #[tokio::test]
    async fn search_pages_past_300_filtered_rows_to_fill_limit()
    -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let mut store = Store::open(dir.path().join("store.sqlite"))?;
        let conv = "c_page";

        let mut rows = Vec::with_capacity(305);
        // 5 older real hits (ts 1..=5).
        for i in 1..=5_i64 {
            let id = format!("hit_{i:03}");
            let raw = format!(
                r#"{{"id":"{id}","conversationId":"{conv}","clientId":"cli_{id}","senderId":"u1","senderName":"A","isMine":false,"date":{i},"status":"sent","text":"needle hit {i}","kind":{{"type":"text"}}}}"#
            );
            rows.push(stored_row(
                &id,
                conv,
                &format!("cli_{id}"),
                &format!("needle hit {i}"),
                i,
                "text",
                false,
                &raw,
            ));
        }
        // 300 newer rows matching "needle" in SQLite that will be recalled in memory!
        let mut recalled_in_mem = Vec::with_capacity(300);
        for i in 100..400_i64 {
            let id = format!("rec_{i:03}");
            let raw = format!(
                r#"{{"id":"{id}","conversationId":"{conv}","clientId":"cli_{id}","senderId":"u1","senderName":"A","isMine":false,"date":{i},"status":"sent","text":"needle stale {i}","kind":{{"type":"text"}}}}"#
            );
            rows.push(stored_row(
                &id,
                conv,
                &format!("cli_{id}"),
                &format!("needle stale {i}"),
                i,
                "text",
                false,
                &raw,
            ));
            recalled_in_mem.push(base_msg(&id, conv, i, "", Kind::Recalled));
        }
        store.save_messages(&rows)?;

        let (handle, _runner) = start_test_core(store);
        handle
            .send_and_ack(Command::WriteThroughReplaceWindow {
                conv_id: conv.to_owned(),
                messages: recalled_in_mem,
            })
            .await;

        let (hits, _ver) = handle
            .search_messages(conv.to_owned(), "needle".to_owned(), 3)
            .await;
        let ids: Vec<_> = hits.into_iter().map(|m| m.id).collect();
        assert_eq!(ids, vec!["hit_005", "hit_004", "hit_003"]);
        handle.stop();
        Ok(())
    }

    #[tokio::test]
    async fn fixes_2_3_4_end_to_end_via_actor_and_store() -> Result<(), Box<dyn std::error::Error>>
    {
        let dir = tempfile::tempdir()?;
        let mut store = Store::open(dir.path().join("store.sqlite"))?;
        let conv = "c_fixes";

        let call_raw = r#"{"id":"m_call","conversationId":"c_fixes","clientId":"cli_call","senderId":"u1","senderName":"A","isMine":false,"date":1000,"status":"sent","text":"[Cuộc gọi]","kind":{"type":"call","video":false,"missed":false,"duration":125,"title":"Cuộc gọi","detail":"2 phút 5 giây"}}"#;
        let ecard_raw = r#"{"id":"m_ecard","conversationId":"c_fixes","clientId":"cli_ecard","senderId":"u1","senderName":"A","isMine":false,"date":1001,"status":"sent","text":"[Thiệp]","kind":{"type":"ecard","style":"reminder","title":"Nhắc","description":"","reminderTitle":"Họp giao ban"}}"#;
        let pd_raw = r#"{"id":"srv_pd","conversationId":"c_fixes","clientId":"cli_pd_shared","senderId":"u1","senderName":"A","isMine":true,"date":1002,"status":"sent","text":"comet hidden","kind":{"type":"text"}}"#;
        let q_recalled_raw = r#"{"id":"q_rec","conversationId":"c_fixes","clientId":"cli_q_rec","senderId":"u1","senderName":"A","isMine":false,"date":1003,"status":"sent","text":"was recalled","kind":{"type":"recalled"}}"#;
        let q_legacy_raw = r#"{"id":"q_leg_store","conversationId":"c_fixes","clientId":"cli_q_leg","senderId":"me","senderName":"Me","isMine":true,"date":1004,"status":"sent","text":"  Old legacy quote  ","kind":{"type":"text"}}"#;

        store.save_messages(&[
            stored_row(
                "m_call",
                conv,
                "cli_call",
                "[Cuộc gọi]",
                1000,
                "call",
                false,
                call_raw,
            ),
            stored_row(
                "m_ecard",
                conv,
                "cli_ecard",
                "[Thiệp]",
                1001,
                "ecard",
                false,
                ecard_raw,
            ),
            stored_row(
                "srv_pd",
                conv,
                "cli_pd_shared",
                "comet hidden",
                1002,
                "text",
                true,
                pd_raw,
            ),
            stored_row(
                "q_rec",
                conv,
                "cli_q_rec",
                "was recalled",
                1003,
                "recalled",
                false,
                q_recalled_raw,
            ),
            stored_row(
                "q_leg_store",
                conv,
                "cli_q_leg",
                "  Old legacy quote  ",
                1004,
                "text",
                true,
                q_legacy_raw,
            ),
        ])?;

        let (handle, _runner) = start_test_core(store);

        // Fix 2: call detail + ecard reminderTitle found in store.
        let (call_hits, _) = handle
            .search_messages(conv.to_owned(), "2 phút".to_owned(), 10)
            .await;
        assert_eq!(
            call_hits.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
            vec!["m_call"]
        );

        let (ecard_hits, _) = handle
            .search_messages(conv.to_owned(), "giao ban".to_owned(), 10)
            .await;
        assert_eq!(
            ecard_hits.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
            vec!["m_ecard"]
        );

        // Fix 3: U6 core delete_undo pending_deleted by client_id filters search AND
        // ensure_message_loaded fallback merge (no Swift bridge needed).
        let mut pd_mem = base_msg("srv_pd_mem", conv, 1002, "comet hidden", Kind::Text);
        pd_mem.client_id = "cli_pd_shared".to_owned();
        let _ = handle
            .send_and_ack(crate::Command::WriteThroughUpsertMessage {
                msg: Box::new(pd_mem),
                replacing_client_id: None,
            })
            .await;
        handle
            .request_unit(crate::Command::DeleteForMe {
                conv_id: conv.to_owned(),
                msg_id: "srv_pd_mem".to_owned(),
                confirmed: true,
                now_ms: 1_700_000_000_000,
            })
            .await;

        let (pd_hits, _) = handle
            .search_messages(conv.to_owned(), "comet".to_owned(), 10)
            .await;
        assert!(pd_hits.is_empty());

        let mut pd_direct = base_msg("srv_pd", conv, 1002, "comet hidden", Kind::Text);
        pd_direct.client_id = "cli_pd_shared".to_owned();
        let (loaded_pd, _) = handle
            .ensure_message_loaded(conv.to_owned(), pd_direct)
            .await;
        assert!(!loaded_pd);

        // Undoing the delete restores visibility immediately in search.
        handle.request_unit(crate::Command::UndoDelete).await;
        let (restored_hits, _) = handle
            .search_messages(conv.to_owned(), "comet".to_owned(), 10)
            .await;
        assert!(!restored_hits.is_empty());

        // Fix 4a: load_quoted_message skips recalled target by id.
        let mut quoting_recalled = base_msg("q_src1", conv, 2000, "reply", Kind::Text);
        quoting_recalled.quote = Some(Quote {
            msg_id: "q_rec".to_owned(),
            cli_msg_id: String::new(),
            sender_name: "A".to_owned(),
            text: "was recalled".to_owned(),
        });
        let (q1, _) = handle
            .load_quoted_message(conv.to_owned(), quoting_recalled)
            .await;
        assert_eq!(q1, None);

        // Fix 4b: legacy quote without ids finds older store-only message and loads window.
        let mut quoting_legacy = base_msg("q_src2", conv, 2001, "reply legacy", Kind::Text);
        quoting_legacy.quote = Some(Quote {
            msg_id: String::new(),
            cli_msg_id: "0".to_owned(),
            sender_name: "Bạn".to_owned(),
            text: "Old legacy quote".to_owned(),
        });
        let (q2, ver) = handle
            .load_quoted_message(conv.to_owned(), quoting_legacy)
            .await;
        assert_eq!(q2.as_deref(), Some("q_leg_store"));
        assert!(ver > 0);
        let Some(snap) = handle.full_snapshot().await else {
            return Err("missing snapshot".into());
        };
        assert!(
            snap.messages
                .windows
                .get(conv)
                .is_some_and(|list| list.iter().any(|m| m.id == "q_leg_store"))
        );

        handle.stop();
        Ok(())
    }
}

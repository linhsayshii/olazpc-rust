//! Ports of the Swift tests that exercise `ZaloSQLiteStore` (names noted per test) plus
//! compatibility checks. Fixtures use inline JSON shaped like the Swift `ChatMessage` dictionary.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::collections::HashSet;

use rusqlite::Connection;
use serde_json::{Value, json};

use crate::helpers::{is_signal_ciphertext, url_has_undecrypted_signal_cipher};
use crate::schema::{PRAGMAS_SQL, SCHEMA_SQL};
use crate::{CloudMediaQuery, SaveOptions, Store, StoredConversation, StoredMessage};

fn conv(id: &str, group: bool, name: &str, pinned: bool, prev_ts: i64) -> StoredConversation {
    StoredConversation {
        id: id.into(),
        is_group: group,
        name: name.into(),
        pinned,
        preview_ts_ms: prev_ts,
        updated_at_ms: prev_ts,
        ..Default::default()
    }
}

fn msg(
    id: &str,
    conv_id: &str,
    client_id: &str,
    text: &str,
    ts: i64,
    kind: &str,
    status: &str,
) -> StoredMessage {
    let raw = json!({
        "id": id, "clientId": client_id, "conversationId": conv_id, "senderId": "111",
        "senderName": "Alice", "isMine": false, "kind": {"type": kind}, "text": text,
        "date": ts, "status": status
    });
    StoredMessage {
        id: id.into(),
        conv_id: conv_id.into(),
        client_id: client_id.into(),
        sender_id: "111".into(),
        sender_name: "Alice".into(),
        is_mine: false,
        text: text.into(),
        kind_tag: kind.into(),
        ts_ms: ts,
        status: status.into(),
        raw_json_data: raw.to_string().into_bytes(),
        ..Default::default()
    }
}

fn with_raw(mut m: StoredMessage, raw: Value) -> StoredMessage {
    m.raw_json_data = raw.to_string().into_bytes();
    m
}

fn ids(v: &[StoredMessage]) -> Vec<&str> {
    v.iter().map(|m| m.id.as_str()).collect()
}

fn raw_value(m: &StoredMessage) -> Value {
    serde_json::from_slice(&m.raw_json_data).unwrap()
}

// NativeSQLiteAndWireTests.sqliteStoreConversationsMessagesMediaAndPrefs
#[test]
fn sqlite_store_conversations_messages_media_and_prefs() {
    let mut store = Store::open_in_memory().unwrap();
    let mut c1 = conv("u1", false, "An", false, 1000);
    c1.unread = 2;
    c1.preview_text = "Hi".into();
    let mut c2 = conv("g2", true, "Team", true, 500);
    c2.members = 5;
    c2.preview_text = "Yo".into();
    c2.preview_from_me = true;
    store.save_conversations(&[c1, c2]).unwrap();
    let convs = store.load_conversations().unwrap();
    assert_eq!(
        convs.iter().map(|c| c.id.as_str()).collect::<Vec<_>>(),
        ["g2", "u1"]
    );

    let s1 = msg("101", "u1", "c1", "Tin 1", 1000, "text", "sent");
    let s2 = with_raw(
        msg("102", "u1", "c2", "Anh", 2000, "photo", "sent"),
        json!({"id": "102", "kind": {"type": "photo", "url": "https://cdn.example/p.jpg"}, "text": "Anh"}),
    );
    let s3 = msg("103", "u1", "c3", "Example", 3000, "link", "sent");
    store.save_messages(&[s1, s2, s3]).unwrap();

    let latest_two = store.messages("u1", None, 2).unwrap();
    assert_eq!(ids(&latest_two), ["102", "103"]);
}

// Rest of the same Swift test; the wire parser turns `ts: 1000` (seconds) into 1_000_000 ms, so fixtures use that scale.
#[test]
fn sqlite_store_before_cursor_media_recall_delete_and_prefs() {
    let mut store = Store::open_in_memory().unwrap();
    store
        .save_messages(&[
            msg("101", "u1", "c1", "Tin 1", 1000, "text", "sent"),
            with_raw(
                msg("102", "u1", "c2", "Anh", 2_000_000, "photo", "sent"),
                json!({"id": "102", "kind": {"type": "photo"}, "text": "Anh"}),
            ),
            msg("103", "u1", "c3", "Example", 3_000_000, "link", "sent"),
        ])
        .unwrap();
    let older = store.messages("u1", Some(2_000_000), 5).unwrap();
    assert_eq!(ids(&older), ["101"]);

    let tags = vec!["photo".to_owned(), "video".to_owned()];
    let media = store.shared_media_raw("u1", &tags, None, 10).unwrap();
    assert_eq!(media.rows.len(), 1);

    store.mark_recalled("u1", "101", "").unwrap();
    let recalled = store.message("u1", "101").unwrap().unwrap();
    assert_eq!(recalled.kind_tag, "recalled");
    assert_eq!(recalled.text, "");
    let raw = raw_value(&recalled);
    assert_eq!(raw["kind"], json!({"type": "recalled"}));
    assert_eq!(raw["reactions"], json!([]));

    store.delete_message("u1", "103").unwrap();
    let remaining = store.messages("u1", None, 10).unwrap();
    assert_eq!(ids(&remaining), ["101", "102"]);

    store
        .set_preference_strings("pinnedIds", &["g2".to_owned()])
        .unwrap();
    assert_eq!(store.get_preference_strings("pinnedIds").unwrap(), ["g2"]);
}

// GroupMgmtAndSearchTests.sqliteSearchEscapesWildcardsIsCaseInsensitiveScopedAndOrdered
#[test]
fn sqlite_search_escapes_wildcards_is_case_insensitive_scoped_and_ordered() {
    let mut store = Store::open_in_memory().unwrap();
    let t = |id: &str, text: &str, ts: i64| msg(id, "c1", "", text, ts, "text", "sent");
    store
        .save_messages(&[
            t("m1", "Hello World", 1000),
            t("m2", "Đà Nẵng cuối tuần", 2000),
            t("m3", "Discount 50% today", 3000),
            t("m4", "Discount 500 today", 3100),
            t("m5", "file_name_v1 and path\\to\\doc", 4000),
            t("m6", "fileXnameXv1", 4100),
            with_raw(
                msg("m7", "c1", "", "", 5000, "link", "sent"),
                json!({"id": "m7", "conversationId": "c1", "senderId": "u1", "senderName": "An",
                    "isMine": false, "text": "Example", "date": 5000, "status": "sent",
                    "kind": {"type": "link", "title": "Example", "url": "https://example.com",
                             "description": "Special Caption Body"}}),
            ),
            t("m8", "HELLO again", 6000),
            msg("m9", "c1", "", "hello recalled", 7000, "recalled", "sent"),
            msg(
                "m10",
                "c1",
                "",
                "hello locked",
                8000,
                "placeholder",
                "e2ee_locked",
            ),
            msg(
                "other",
                "c2",
                "",
                "hello from other conv",
                9000,
                "text",
                "sent",
            ),
        ])
        .unwrap();

    let hello = store.search_messages("c1", "hello", 50).unwrap();
    assert_eq!(ids(&hello), ["m8", "m1"]);
    let limited = store.search_messages("c1", "hello", 1).unwrap();
    assert_eq!(ids(&limited), ["m8"]);
    let vn = store.search_messages("c1", "đà nẵng", 50).unwrap();
    assert_eq!(ids(&vn), ["m2"]);
    let pct = store.search_messages("c1", "50%", 50).unwrap();
    assert_eq!(ids(&pct), ["m3"]);
    let underscore = store.search_messages("c1", "file_name", 50).unwrap();
    assert_eq!(ids(&underscore), ["m5"]);
    let slash = store.search_messages("c1", r"path\to", 50).unwrap();
    assert_eq!(ids(&slash), ["m5"]);
    let caption = store.search_messages("c1", "caption body", 50).unwrap();
    assert_eq!(ids(&caption), ["m7"]);

    store
        .save_messages(&[
            with_raw(
                msg("m11", "c1", "", "", 6500, "oaMessage", "sent"),
                json!({"id": "m11", "conversationId": "c1", "senderId": "u1", "senderName": "OA",
                    "isMine": false, "text": "", "date": 6500, "status": "sent",
                    "kind": {"type": "oaMessage", "parts": [
                        {"header": true, "title": "Weekly Digest", "description": "Summary inside OA"}]}}),
            ),
            StoredMessage {
                raw_json_data: b"not-valid-json".to_vec(),
                ..msg("m12", "c1", "", "Fallback plain body", 6600, "text", "sent")
            },
        ])
        .unwrap();
    assert_eq!(
        ids(&store
            .search_messages("c1", "summary inside oa", 50)
            .unwrap()),
        ["m11"]
    );
    assert_eq!(
        ids(&store.search_messages("c1", "fallback plain", 50).unwrap()),
        ["m12"]
    );
    assert!(store.search_messages("c1", "   ", 50).unwrap().is_empty());
    assert!(store.search_messages("c1", "hello", 0).unwrap().is_empty());
}

// NativeSQLiteAndWireTests.sqliteClientIdIndexExistsBulkSaveIsFastAndE2EETwinProtectionIntact
#[test]
fn client_id_index_exists_bulk_save_is_fast_and_e2ee_twin_protection_intact() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(dir.path().join("history.sqlite3")).unwrap();
    assert!(
        store
            .message_index_names()
            .unwrap()
            .contains(&"idx_messages_conv_client".to_owned())
    );

    let mk = |id: &str, cli: &str, ts: i64, text: &str, status: &str| StoredMessage {
        raw_json_data: format!("{{\"id\":\"{id}\",\"text\":\"{text}\"}}").into_bytes(),
        ..msg(id, "conv_bulk", cli, text, ts, "text", status)
    };
    let base = 1_700_000_000_000_i64;
    let seed: Vec<_> = (1..=2000)
        .map(|i| {
            mk(
                &format!("seed_{i}"),
                &format!("cli_seed_{i}"),
                base + i,
                "Hello",
                "sent",
            )
        })
        .collect();
    store.save_messages(&seed).unwrap();

    let next: Vec<_> = (2001..=4500)
        .map(|i| {
            mk(
                &format!("msg_{i}"),
                &format!("cli_{i}"),
                base + i,
                "Hello",
                "sent",
            )
        })
        .collect();
    let t0 = std::time::Instant::now();
    store.save_messages(&next).unwrap();
    assert!(
        t0.elapsed().as_secs_f64() < 0.5,
        "indexed bulk save too slow: {:?}",
        t0.elapsed()
    );

    let fast: Vec<_> = (4501..=7000)
        .map(|i| {
            mk(
                &format!("msg_{i}"),
                &format!("cli_{i}"),
                base + i,
                "Hello",
                "sent",
            )
        })
        .collect();
    let t1 = std::time::Instant::now();
    store
        .save_messages_with(
            &fast,
            SaveOptions {
                skip_twin_checks: true,
                ..Default::default()
            },
        )
        .unwrap();
    assert!(
        t1.elapsed().as_secs_f64() < 0.5,
        "fast bulk save too slow: {:?}",
        t1.elapsed()
    );

    // 1) locked twin arriving after plaintext twin with matching clientId is ignored
    store
        .save_messages(&[mk(
            "e2ee_dup_1",
            "cli_2001",
            base + 2001,
            "Locked",
            "e2ee_locked",
        )])
        .unwrap();
    assert!(store.message("conv_bulk", "e2ee_dup_1").unwrap().is_none());

    // 2) locked placeholder stored first is deleted when plaintext twin arrives
    store
        .save_messages(&[mk(
            "locked_temp_99",
            "cli_twin_99",
            base + 999_000,
            "Locked",
            "e2ee_locked",
        )])
        .unwrap();
    assert!(
        store
            .message("conv_bulk", "locked_temp_99")
            .unwrap()
            .is_some()
    );
    store
        .save_messages(&[mk(
            "plain_real_99",
            "cli_twin_99",
            base + 999_000,
            "Decrypted!",
            "sent",
        )])
        .unwrap();
    assert!(
        store
            .message("conv_bulk", "locked_temp_99")
            .unwrap()
            .is_none()
    );
    let real = store
        .message("conv_bulk", "plain_real_99")
        .unwrap()
        .unwrap();
    assert_eq!(real.text, "Decrypted!");
}

// MessageRecallTests: locked server echo upgrades the local plain row (id == clientId)
#[test]
fn locked_echo_with_server_id_upgrades_local_plain_row() {
    let mut store = Store::open_in_memory().unwrap();
    let cli = "1795343225001";
    let srv = "8502116332999";
    store
        .save_messages(&[msg(
            cli,
            "3161",
            cli,
            "Tin nhắn E2EE vừa gửi",
            1_795_343_225_000,
            "text",
            "sent",
        )])
        .unwrap();
    store
        .save_messages(&[msg(
            srv,
            "3161",
            cli,
            "Tin nhắn mã hóa đầu cuối",
            1_795_343_225_000,
            "placeholder",
            "e2ee_locked",
        )])
        .unwrap();
    let rows = store.messages("3161", None, 10).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].id, srv);
    assert_eq!(rows[0].client_id, cli);
    assert_eq!(rows[0].text, "Tin nhắn E2EE vừa gửi");
    assert_eq!(rows[0].status, "sent");
    let raw = raw_value(&rows[0]);
    assert_eq!(raw["id"], json!(srv));
    assert_eq!(raw["clientId"], json!(cli));
}

// NativeProtocolTests.e2eeSignalDecryptionPlaceholderProtectionAndSQLiteSelfHealing (store part)
const PREKEY_CIPHER: &str = "AzMovwMIpFUwoVUSIQVNUKcMqQKEDdK1jcEt8He7V15D1iWl9ngJgOPtsXiUIRohBZSX4D1qiBhXbdSPciObevx/DTnpfki5s5eI0wzTTQp/InIzCiEFCFnb614YZfaOg7R9/7/DIagW4nsLw5V5jK1ELLEbY1IQCBgAIkDL6XqJXgMKkj5gMtM5+CCkjt5p+Xm4q0wQjhLXMOgyl8M137oQAjyDi9fCjALZOCaCQpyjgm5/eW2crnxEu3JybU+y/enV2FQ=";
const WHISPER_CIPHER: &str =
    "AjMKIQXfGtZEt75pr2/KWoTA8W8Bu0oNpGDv9ITalIBSb69UaxAOGAAiENtYix7GNUB1eR/LgY4IuK2Blmqxld2njA==";

#[test]
fn signal_ciphertext_detection() {
    assert!(is_signal_ciphertext(PREKEY_CIPHER));
    assert!(is_signal_ciphertext(WHISPER_CIPHER));
    assert!(!is_signal_ciphertext("miế ngan trộn"));
    assert!(!is_signal_ciphertext(
        "https://api.zaloapp.com/api/emoticon/sticker/webpc?eid=34840&size=130"
    ));
    let broken =
        format!("https://api.zaloapp.com/api/emoticon/sticker/webpc?eid={PREKEY_CIPHER}&size=130");
    assert!(url_has_undecrypted_signal_cipher(&broken));
    assert!(!url_has_undecrypted_signal_cipher(
        "https://x.example/a?eid=34840"
    ));
}

#[test]
fn e2ee_locked_never_overwrites_plain_and_legacy_poison_is_repaired() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(dir.path().join("history.sqlite3")).unwrap();
    let conv_id = "31612076530602762";
    let locked = msg(
        "8502116332010",
        conv_id,
        "1794982452921",
        "Tin nhắn mã hóa đầu cuối",
        1_794_982_453_589,
        "placeholder",
        "e2ee_locked",
    );
    store.save_messages(std::slice::from_ref(&locked)).unwrap();

    let plain = msg(
        "8502116332010",
        conv_id,
        "1794982452921",
        "Con về ăn cơm nhé",
        1_794_982_453_589,
        "text",
        "sent",
    );
    store.save_messages(&[plain]).unwrap();
    store.save_messages(&[locked]).unwrap();
    let loaded = store.messages(conv_id, None, 10).unwrap();
    assert_eq!(loaded.len(), 1);
    assert_eq!(loaded[0].text, "Con về ăn cơm nhé");
    assert_eq!(loaded[0].status, "sent");

    let broken_url =
        format!("https://api.zaloapp.com/api/emoticon/sticker/webpc?eid={PREKEY_CIPHER}&size=130");
    let poisoned = with_raw(
        msg(
            "legacy_poison_1",
            conv_id,
            "999111",
            "[Sticker]",
            1_794_982_472_463,
            "sticker",
            "sent",
        ),
        json!({"id": "legacy_poison_1", "clientId": "999111", "conversationId": conv_id,
            "senderId": conv_id, "senderName": "Mẹ", "senderAvatar": "", "isMine": false,
            "kind": {"type": "sticker", "url": broken_url}, "text": "[Sticker]",
            "date": 1_794_982_472_463_i64, "status": "sent", "isE2EE": false}),
    );
    store.save_messages(&[poisoned]).unwrap();
    // Poisoned conversation preview is sanitized too.
    let mut c = conv(conv_id, false, "Mẹ", false, 5);
    c.preview_text = PREKEY_CIPHER.into();
    store.save_conversations(&[c]).unwrap();

    let repaired = store.repair_undecrypted_e2ee_messages().unwrap();
    assert!(repaired >= 1);
    let after = store.messages(conv_id, None, 10).unwrap();
    let row = after.iter().find(|m| m.id == "legacy_poison_1").unwrap();
    assert_eq!(row.kind_tag, "placeholder");
    assert_eq!(row.status, "e2ee_locked");
    assert_eq!(row.text, "[Sticker]");
    let raw = raw_value(row);
    assert_eq!(raw["kind"]["symbol"], json!("lock.fill"));
    assert_eq!(raw["undecryptedE2EE"], json!(true));
    let convs = store.load_conversations().unwrap();
    assert_eq!(convs[0].preview_text, "🔒 Tin nhắn mã hóa đầu cuối");
}

// FeatureFixesTests: preserveExistingReactions store-level behavior
#[test]
fn preserve_existing_reactions_flag() {
    let mut store = Store::open_in_memory().unwrap();
    let reaction = json!([{"type": "5", "key": "/-heart", "emoji": "❤️", "count": 1, "userCounts": {"100": 1}}]);
    let with = with_raw(
        msg(
            "7001",
            "200",
            "c7001",
            "Ping",
            1_760_000_000_000,
            "text",
            "sent",
        ),
        json!({"id": "7001", "kind": {"type": "text"}, "reactions": reaction}),
    );
    let without = with_raw(
        msg(
            "7001",
            "200",
            "c7001",
            "Ping",
            1_760_000_000_000,
            "text",
            "sent",
        ),
        json!({"id": "7001", "kind": {"type": "text"}, "reactions": []}),
    );
    store.save_messages(&[with]).unwrap();
    store
        .save_messages_with(
            std::slice::from_ref(&without),
            SaveOptions {
                preserve_existing_reactions: true,
                ..Default::default()
            },
        )
        .unwrap();
    let kept = store.message("200", "7001").unwrap().unwrap();
    assert_eq!(raw_value(&kept)["reactions"], reaction);

    store
        .save_messages_with(&[without], SaveOptions::default())
        .unwrap();
    let cleared = store.message("200", "7001").unwrap().unwrap();
    assert_eq!(raw_value(&cleared)["reactions"], json!([]));
}

// FeatureFixesTests.repairLegacyReactions...
#[test]
fn repair_legacy_reactions_strips_ghosts_and_normalizes() {
    let mut store = Store::open_in_memory().unwrap();
    let mk = |id: &str, reactions: Value| {
        with_raw(
            msg(
                id,
                "200",
                &format!("c_{id}"),
                &format!("Msg {id}"),
                1_760_000_000_000,
                "text",
                "sent",
            ),
            json!({"id": id, "clientId": format!("c_{id}"), "conversationId": "200", "senderId": "200",
                "senderName": "Lan", "senderAvatar": "", "isMine": false, "kind": {"type": "text"},
                "text": format!("Msg {id}"), "date": 1_760_000_000_000_i64, "status": "sent",
                "reactions": reactions, "isE2EE": false}),
        )
    };
    let ghost = mk(
        "m1",
        json!([{"type": "5", "key": "/-heart", "emoji": "❤️", "image": "",
        "count": 1, "includesMe": false, "names": ["Người dùng Zalo"], "people": 1}]),
    );
    let mixed = mk(
        "m2",
        json!([{"type": "5", "key": "/-heart", "emoji": "❤️", "image": "",
        "count": 4, "includesMe": false, "names": ["Người dùng Zalo", "Lan"], "people": 3,
        "userCounts": {"__legacy__": 2, "u200": 1, "0": 1}}]),
    );
    store.save_messages(&[ghost, mixed]).unwrap();

    assert_eq!(store.repair_legacy_reactions("100").unwrap(), 2);
    assert_eq!(store.repair_legacy_reactions("100").unwrap(), 0);
    assert_eq!(
        store
            .get_preference_string("reactionRepairVersion")
            .unwrap()
            .as_deref(),
        Some("2")
    );

    let r1 = raw_value(&store.message("200", "m1").unwrap().unwrap());
    assert_eq!(r1["reactions"], json!([]));
    let r2 = raw_value(&store.message("200", "m2").unwrap().unwrap());
    let react = &r2["reactions"][0];
    assert_eq!(react["count"], json!(2));
    assert_eq!(react["people"], json!(2));
    assert_eq!(react["includesMe"], json!(true));
    assert_eq!(react["userCounts"], json!({"200": 1, "100": 1}));
    assert_eq!(react["names"], json!(["Lan"]));
}

// FeatureFixesTests.persistedReactionDedup...SurviveRestart (store part: close + reopen)
#[test]
fn data_and_prefs_survive_close_and_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("history.sqlite3");
    {
        let mut s1 = Store::open(&path).unwrap();
        s1.save_messages(&[msg(
            "77001",
            "200",
            "c77001",
            "Ping",
            1_760_000_000_000,
            "text",
            "sent",
        )])
        .unwrap();
        s1.set_preference_string("pollState", "456789").unwrap();
        s1.close();
        assert!(matches!(
            s1.messages("200", None, 5),
            Err(crate::StoreError::Closed)
        ));
    }
    let s2 = Store::open(&path).unwrap();
    assert_eq!(s2.message("200", "77001").unwrap().unwrap().text, "Ping");
    assert_eq!(
        s2.get_preference_string("pollState").unwrap().as_deref(),
        Some("456789")
    );
}

// Stage4FeaturesTests: absent / wrongly typed preferences read as nil
#[test]
fn preferences_absent_and_typed_defaults() {
    let mut store = Store::open_in_memory().unwrap();
    assert_eq!(store.get_preference_string("hiddenPinMD5").unwrap(), None);
    assert!(store.get_preference_bool("flag", true).unwrap());
    assert!(store.get_preference_strings("none").unwrap().is_empty());

    store.set_preference_bool("flag", false).unwrap();
    assert!(!store.get_preference_bool("flag", true).unwrap());
    // wrong type -> fallback / None
    assert_eq!(store.get_preference_string("flag").unwrap(), None);
    store
        .set_preference_string("hiddenPinHash", "abc/def")
        .unwrap();
    assert_eq!(
        store
            .get_preference_string("hiddenPinHash")
            .unwrap()
            .as_deref(),
        Some("abc/def")
    );
    // Swift JSONEncoder escapes `/`; so do we (readable by both).
    assert_eq!(
        store.get_preference_data("hiddenPinHash").unwrap().unwrap(),
        br#""abc\/def""#
    );
    store.delete_preference("hiddenPinHash").unwrap();
    assert_eq!(store.get_preference_string("hiddenPinHash").unwrap(), None);
    store.set_preference_data("raw", b"{\"a\":1}").unwrap();
    assert_eq!(
        store.get_preference_data("raw").unwrap().unwrap(),
        b"{\"a\":1}"
    );
}

// ---- Additional semantics (no direct Swift test; derived from the Swift source) ----

#[test]
fn conversation_upsert_rules_unread_pin_delete() {
    let mut store = Store::open_in_memory().unwrap();
    let mut a = conv("u1", false, "An", false, 1000);
    a.avatar = "av".into();
    a.members = 3;
    a.preview_text = "new".into();
    store.upsert_conversation(&a).unwrap();
    // Older preview, empty name/avatar, zero members must not overwrite.
    let mut b = conv("u1", false, "", false, 900);
    b.preview_text = "old".into();
    b.updated_at_ms = 2000;
    store.upsert_conversation(&b).unwrap();
    let got = &store.load_conversations().unwrap()[0];
    assert_eq!(
        (got.name.as_str(), got.avatar.as_str(), got.members),
        ("An", "av", 3)
    );
    assert_eq!(
        (
            got.preview_text.as_str(),
            got.preview_ts_ms,
            got.updated_at_ms
        ),
        ("new", 1000, 2000)
    );

    store.set_conversation_unread("u1", -5).unwrap();
    assert_eq!(store.load_conversations().unwrap()[0].unread, 0);
    store.set_conversation_pinned("u1", true).unwrap();
    assert!(store.load_conversations().unwrap()[0].pinned);

    store
        .save_messages(&[msg("1", "u1", "", "x", 1, "text", "sent")])
        .unwrap();
    assert!(store.has_any_messages().unwrap());
    store.delete_conversation("u1").unwrap();
    assert!(store.load_conversations().unwrap().is_empty());
    assert!(!store.has_any_messages().unwrap());
}

#[test]
fn messages_paging_clamp_and_around() {
    let mut store = Store::open_in_memory().unwrap();
    let batch: Vec<_> = (1..=60)
        .map(|i| {
            msg(
                &format!("srv_{i}"),
                "u9",
                &format!("cli_{i}"),
                "x",
                i * 1000,
                "text",
                "sent",
            )
        })
        .collect();
    store.save_messages(&batch).unwrap();
    assert_eq!(store.messages("u9", None, 0).unwrap().len(), 1); // limit clamps to >= 1
    let around = store
        .messages_around("u9", 5000, Some(8000), 2, 3000)
        .unwrap();
    assert_eq!(
        ids(&around.messages),
        ["srv_3", "srv_4", "srv_5", "srv_6", "srv_7", "srv_8"]
    );
    assert!(around.has_more_older);
    let at_start = store.messages_around("u9", 2000, None, 25, 3).unwrap();
    assert_eq!(
        ids(&at_start.messages),
        ["srv_1", "srv_2", "srv_3", "srv_4"]
    );
    assert!(!at_start.has_more_older);
}

#[test]
fn message_lookup_by_client_id_and_existing_ids() {
    let mut store = Store::open_in_memory().unwrap();
    store
        .save_messages(&[
            msg("srv_1", "c", "cli_1", "a", 1, "text", "sent"),
            msg("srv_2", "c", "", "b", 2, "text", "sent"),
        ])
        .unwrap();
    assert_eq!(store.message("c", "cli_1").unwrap().unwrap().id, "srv_1");
    assert!(store.message("other", "cli_1").unwrap().is_none());
    let found = store
        .existing_message_ids(
            "c",
            &["cli_1".into(), "srv_2".into(), "nope".into(), String::new()],
        )
        .unwrap();
    assert_eq!(
        found,
        ["cli_1", "srv_1", "srv_2"]
            .iter()
            .map(|s| (*s).to_owned())
            .collect::<HashSet<_>>()
    );
    assert!(
        store
            .existing_message_ids("", &["a".into()])
            .unwrap()
            .is_empty()
    );
}

#[test]
fn upgrade_message_id_rules() {
    let mut store = Store::open_in_memory().unwrap();
    store
        .save_messages(&[
            msg("tmp", "c", "", "a", 1, "text", "sent"),
            msg("taken", "c", "", "b", 2, "text", "sent"),
        ])
        .unwrap();
    assert!(!store.upgrade_message_id("c", "tmp", "tmp", "x").unwrap());
    assert!(!store.upgrade_message_id("c", "tmp", "taken", "x").unwrap());
    assert!(!store.upgrade_message_id("c", "missing", "n", "x").unwrap());
    assert!(store.upgrade_message_id("c", "tmp", "srv", "cli").unwrap());
    let row = store.message("c", "srv").unwrap().unwrap();
    assert_eq!(row.client_id, "cli");
    assert_eq!(raw_value(&row)["id"], json!("srv"));
    assert!(store.message("c", "tmp").unwrap().is_none());
}

#[test]
fn shared_media_cursor_paging() {
    let mut store = Store::open_in_memory().unwrap();
    let batch: Vec<_> = (1..=5)
        .map(|i| msg(&format!("p{i}"), "c", "", "", i * 10, "photo", "sent"))
        .collect();
    store.save_messages(&batch).unwrap();
    let tags = vec!["photo".to_owned()];
    let p1 = store.shared_media_raw("c", &tags, None, 2).unwrap();
    assert_eq!(
        (p1.rows.len(), p1.more, p1.cursor.as_deref()),
        (2, true, Some("40|p4"))
    );
    let p2 = store
        .shared_media_raw("c", &tags, p1.cursor.as_deref(), 2)
        .unwrap();
    assert_eq!(
        (p2.rows.len(), p2.more, p2.cursor.as_deref()),
        (2, true, Some("20|p2"))
    );
    let p3 = store
        .shared_media_raw("c", &tags, p2.cursor.as_deref(), 2)
        .unwrap();
    assert_eq!((p3.rows.len(), p3.more, p3.cursor), (1, false, None));
    assert!(
        store
            .shared_media_raw("c", &[], None, 2)
            .unwrap()
            .rows
            .is_empty()
    );
}

#[test]
fn cloud_media_aggregation_and_items() {
    let mut store = Store::open_in_memory().unwrap();
    let mut c = conv("g5", true, "Team", false, 1);
    c.avatar = "a".into();
    store.save_conversations(&[c]).unwrap();
    let media = |id: &str, kind: &str, ts: i64, size: Option<i64>, status: &str| {
        let mut k = json!({"type": kind, "url": format!("https://cdn/{id}"), "name": format!("{id}.bin"), "duration": 7, "width": 4, "height": 3});
        if let Some(s) = size {
            k["size"] = json!(s);
        }
        with_raw(
            msg(id, "g5", "", "", ts, kind, status),
            json!({"id": id, "kind": k}),
        )
    };
    store
        .save_messages(&[
            media("ph1", "photo", 10, Some(1000), "sent"),
            media("ph2", "photo", 20, None, "sent"),
            media("vd1", "video", 30, Some(5000), "sent"),
            media("fl1", "file", 40, None, "sent"),
            media("lk", "photo", 50, Some(999_999), "e2ee_locked"),
            msg("t1", "g5", "", "text", 60, "text", "sent"),
        ])
        .unwrap();
    let agg = store.cloud_media_aggregation().unwrap();
    assert_eq!(agg.len(), 1);
    let s = &agg[0];
    assert_eq!(
        (
            s.conv_name.as_str(),
            s.is_group,
            s.item_count,
            s.last_activity_ms
        ),
        ("Team", true, 4, 40)
    );
    assert_eq!(
        (s.photo_bytes, s.video_bytes, s.file_bytes, s.voice_bytes),
        (1000 + 150_000, 5000, 0, 0)
    );
    assert_eq!(s.total_bytes(), 156_000);

    let (items, more) = store
        .cloud_media_items(&CloudMediaQuery {
            limit: 3,
            ..Default::default()
        })
        .unwrap();
    assert_eq!(
        items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
        ["fl1", "vd1", "ph2"]
    );
    assert!(more);
    assert_eq!(
        (
            items[1].file_name.as_str(),
            items[1].duration_sec,
            items[1].width,
            items[1].height,
            items[1].url.as_str()
        ),
        ("vd1.bin", 7, 4, 3, "https://cdn/vd1")
    );
    let by_size = store
        .cloud_media_items(&CloudMediaQuery {
            sort_by_size: true,
            kind_tags: vec!["photo".into(), "bogus".into()],
            ..Default::default()
        })
        .unwrap();
    assert_eq!(
        by_size.0.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
        ["ph2", "ph1"]
    );
    let excl = store
        .cloud_media_items(&CloudMediaQuery {
            excluding_conv_id: Some("g5".into()),
            ..Default::default()
        })
        .unwrap();
    assert!(excl.0.is_empty());
    let only_bogus = store
        .cloud_media_items(&CloudMediaQuery {
            kind_tags: vec!["bogus".into()],
            ..Default::default()
        })
        .unwrap();
    assert_eq!(only_bogus, (vec![], false));
}

#[test]
fn mark_recalled_menu_quote_and_reaction_update() {
    let mut store = Store::open_in_memory().unwrap();
    store
        .save_messages(&[with_raw(
            msg("srv", "c", "cli", "hello", 1, "text", "sent"),
            json!({"id": "srv", "text": "hello", "quote": {"a": 1}, "buttons": [1],
                   "menu": {"recall": true, "forward": "x", "pin": true, "star": "s", "starred": true, "keep": 1}}),
        )])
        .unwrap();
    store
        .update_message_reactions_json("c", "cli", br#"[{"type":"5"}]"#)
        .unwrap();
    assert_eq!(
        raw_value(&store.message("c", "srv").unwrap().unwrap())["reactions"],
        json!([{"type": "5"}])
    );
    // fragments are rejected (no-op)
    store
        .update_message_reactions_json("c", "cli", b"5")
        .unwrap();
    assert_eq!(
        raw_value(&store.message("c", "srv").unwrap().unwrap())["reactions"],
        json!([{"type": "5"}])
    );

    store.mark_recalled("c", "missing", "cli").unwrap(); // falls back to cliMsgId
    let r = raw_value(&store.message("c", "srv").unwrap().unwrap());
    assert_eq!(r["type"], json!("recalled"));
    assert!(r.get("quote").is_none());
    assert_eq!(r["buttons"], json!([]));
    assert_eq!(
        r["menu"],
        json!({"recall": false, "forward": "", "pin": false, "star": "", "starred": false, "keep": 1})
    );
}

#[test]
fn large_64bit_ids_round_trip_as_text() {
    let mut store = Store::open_in_memory().unwrap();
    let id = "9223372036854775807";
    let raw = format!("{{\"id\":\"{id}\",\"big\":{id}}}");
    let m = StoredMessage {
        raw_json_data: raw.clone().into_bytes(),
        ..msg(id, "31612076530602762", "", "x", 1, "text", "sent")
    };
    store.save_messages(&[m]).unwrap();
    let got = store.message("31612076530602762", id).unwrap().unwrap();
    assert_eq!(got.id, id);
    assert_eq!(String::from_utf8(got.raw_json_data).unwrap(), raw);
}

#[test]
fn read_messages_now_uses_read_only_connection() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(dir.path().join("h.sqlite3")).unwrap();
    store
        .save_messages(&[
            msg("1", "c", "", "a", 1, "text", "sent"),
            msg("2", "c", "", "b", 2, "text", "sent"),
        ])
        .unwrap();
    let rows = store.read_messages_now("c", None, 10).unwrap();
    assert_eq!(ids(&rows), ["1", "2"]);
    assert!(
        Store::open_in_memory()
            .unwrap()
            .read_messages_now("c", None, 10)
            .is_none()
    );
}

// ---- Schema compatibility ----

fn master_rows(conn: &Connection) -> Vec<(String, String, String)> {
    let mut stmt = conn
        .prepare("SELECT type, name, COALESCE(sql, '') FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name")
        .unwrap();
    stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .map(Result::unwrap)
        .collect()
}

/// Pulls the SQL out of `ZaloSQLiteStore.init` in the Swift source and dedents the 8-space
/// literal indentation exactly as Swift's multi-line string literal does.
fn swift_schema_from_source() -> Option<(String, String)> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../Sources/Olaz/ZaloRuntime/Protocol/ZaloSQLiteStore.swift");
    let src = std::fs::read_to_string(path).ok()?;
    let start = src.find("try Self.exec(handle, \"\"\"")?;
    let body = &src[start..];
    let body = &body[body.find('\n')? + 1..];
    let end = body.find("\n        \"\"\")")?;
    let lines: Vec<&str> = body[..end]
        .lines()
        .map(|l| l.strip_prefix("        ").unwrap_or(l))
        .collect();
    let pragma_lines = lines.iter().take_while(|l| l.starts_with("PRAGMA")).count();
    let pragmas = lines[..pragma_lines].join("\n") + "\n";
    let schema = lines[pragma_lines..].join("\n") + "\n";
    Some((pragmas, schema))
}

#[test]
fn schema_constants_match_swift_source_verbatim() {
    let Some((pragmas, schema)) = swift_schema_from_source() else {
        eprintln!("Swift source not found; skipping");
        return;
    };
    assert_eq!(pragmas, PRAGMAS_SQL);
    assert_eq!(schema, SCHEMA_SQL);
}

#[test]
fn created_schema_matches_swift_schema_in_sqlite_master() {
    // "Swift side": execute the SQL extracted from the Swift source (fallback: the const).
    let (_, swift_schema) = swift_schema_from_source().unwrap_or_default();
    let swift_schema = if swift_schema.is_empty() {
        SCHEMA_SQL.to_owned()
    } else {
        swift_schema
    };
    let reference = Connection::open_in_memory().unwrap();
    reference.execute_batch(&swift_schema).unwrap();

    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("history.sqlite3");
    drop(Store::open(&path).unwrap());
    let ours = Connection::open(&path).unwrap();
    assert_eq!(master_rows(&ours), master_rows(&reference));
    assert_eq!(master_rows(&ours).len(), 7); // 3 tables + 4 explicit indexes
    // Swift never sets user_version and runs WAL + synchronous=NORMAL.
    let uv: i64 = ours
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(uv, 0);
    let mode: String = ours
        .query_row("PRAGMA journal_mode", [], |r| r.get(0))
        .unwrap();
    assert_eq!(mode, "wal");
    let store = Store::open(&path).unwrap();
    let sync: i64 = store
        .db()
        .unwrap()
        .query_row("PRAGMA synchronous", [], |r| r.get(0))
        .unwrap();
    assert_eq!(sync, 1); // NORMAL
    // Reopening an existing DB is idempotent (IF NOT EXISTS).
    assert_eq!(master_rows(&Connection::open(&path).unwrap()).len(), 7);
}

/// Compares `sqlite_master` of a COPY of a real Swift-created DB (path in `OLAZ_STORE_COMPAT_DB`,
/// opened read-only; a second copy is then opened through `Store`) with what `Store` creates.
/// Prints no row contents. Older Swift builds lacked some indexes; `CREATE INDEX IF NOT EXISTS`
/// (identical in both implementations) adds them on open, so: every statement already present
/// must match exactly, and after `Store::open` the whole schema must match.
#[test]
fn real_swift_database_copy_has_identical_schema() {
    let Ok(path) = std::env::var("OLAZ_STORE_COMPAT_DB") else {
        eprintln!("OLAZ_STORE_COMPAT_DB not set; skipping");
        return;
    };
    let real =
        Connection::open_with_flags(&path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("h.sqlite3");
    drop(Store::open(&p).unwrap());
    let ours = master_rows(&Connection::open(&p).unwrap());
    let theirs = master_rows(&real);
    for row in &theirs {
        assert!(ours.contains(row), "statement differs: {} {}", row.0, row.1);
    }
    let missing: Vec<_> = ours
        .iter()
        .filter(|r| !theirs.contains(r))
        .map(|r| r.1.clone())
        .collect();
    eprintln!(
        "compat: tables/statements present in real DB all identical; indexes missing in real DB (added on open): {missing:?}"
    );
    let uv: i64 = real
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(uv, 0);

    // Open a copy of the real DB through Store: migration is just the idempotent IF NOT EXISTS.
    let copy = dir.path().join("copy.sqlite3");
    std::fs::copy(&path, &copy).unwrap();
    let wal = format!("{path}-wal");
    if std::path::Path::new(&wal).exists() {
        std::fs::copy(&wal, dir.path().join("copy.sqlite3-wal")).unwrap();
    }
    let store = Store::open(&copy).unwrap();
    assert!(store.load_conversations().is_ok());
    assert!(store.has_any_messages().is_ok());
    drop(store);
    assert_eq!(master_rows(&Connection::open(&copy).unwrap()), ours);
}

/// ADR-010: the store runs on the system SQLite (macOS ships 3.4x+). `rusqlite::version()` is
/// `sqlite3_libversion()`.
#[test]
fn links_system_sqlite_new_enough() {
    let v = rusqlite::version();
    let number = rusqlite::version_number();
    eprintln!("sqlite3_libversion = {v} ({number})");
    assert!(
        number >= 3_035_000,
        "SQLite {v} too old for RETURNING/UPSERT paths"
    );
}

#[test]
fn provisional_own_row_after_server_copy_is_dropped() {
    // 1-1 E2EE: the websocket echo (server id) lands before the send reply, which has no msgId.
    let mine = |m: StoredMessage| StoredMessage { is_mine: true, ..m };
    let mut store = Store::open_in_memory().unwrap();
    store
        .save_messages(&[mine(msg("srv1", "c", "cli1", "hi", 10, "text", "sent"))])
        .unwrap();
    store
        .save_messages(&[mine(msg("cli1", "c", "cli1", "hi", 9, "text", "sent"))])
        .unwrap();
    assert!(store.message("c", "srv1").unwrap().is_some());
    let row = store.message("c", "cli1").unwrap().unwrap();
    assert_eq!(row.id, "srv1");
    // Someone else's message whose id equals its client id is untouched.
    store
        .save_messages(&[msg("x", "c", "x", "yo", 11, "text", "sent")])
        .unwrap();
    assert!(store.message("c", "x").unwrap().is_some());
}

#[test]
fn open_drops_stored_provisional_twins() {
    let dir = std::env::temp_dir().join(format!("olaz-twins-{}", std::process::id()));
    let path = dir.join("h.sqlite3");
    {
        let mut store = Store::open(&path).unwrap();
        let mine = |m: StoredMessage| StoredMessage { is_mine: true, ..m };
        // The skip-twin fast path writes both, like older builds did.
        store
            .save_messages_with(
                &[
                    mine(msg("cli1", "c", "cli1", "hi", 9, "text", "sent")),
                    mine(msg("srv1", "c", "cli1", "hi", 10, "text", "sent")),
                    mine(msg("cli2", "c", "cli2", "alone", 12, "text", "sent")),
                ],
                crate::model::SaveOptions {
                    skip_twin_checks: true,
                    ..Default::default()
                },
            )
            .unwrap();
    }
    let store = Store::open(&path).unwrap();
    assert_eq!(store.message("c", "cli1").unwrap().unwrap().id, "srv1");
    assert!(store.message("c", "cli2").unwrap().is_some());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn set_conversation_preview_allows_rollback_and_empty_clear() {
    let dir = std::env::temp_dir().join(format!("olaz-set-conv-preview-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let path = dir.join("store.sqlite");
    let mut store = Store::open(&path).unwrap();
    store
        .save_conversations(&[StoredConversation {
            id: "c1".into(),
            is_group: false,
            name: "Peer".into(),
            avatar: String::new(),
            pinned: false,
            members: 0,
            unread: 1,
            preview_text: "Latest".into(),
            preview_ts_ms: 2_000,
            preview_from_me: false,
            updated_at_ms: 2_000,
        }])
        .unwrap();

    // Roll back to an older message timestamp (save_conversations would refuse because 1_000 < 2_000).
    store
        .set_conversation_preview("c1", "Earlier", 1_000, true, 3_000)
        .unwrap();
    let row = store.load_conversations().unwrap().remove(0);
    assert_eq!(row.preview_text, "Earlier");
    assert_eq!(row.preview_ts_ms, 1_000);
    assert!(row.preview_from_me);

    // Clear when no message remains.
    store
        .set_conversation_preview("c1", "", 0, false, 4_000)
        .unwrap();
    let row = store.load_conversations().unwrap().remove(0);
    assert_eq!(row.preview_text, "");
    assert_eq!(row.preview_ts_ms, 0);
    assert!(!row.preview_from_me);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn cloud_media_aggregation_null_is_group_falls_back_to_is_group_id() {
    let mut store = Store::open_in_memory().unwrap();
    // Explicit 1-1 conversation row (is_group = 0) and explicit group row (is_group = 1).
    let dm = conv("3001001", false, "Alice", false, 100);
    let grp = conv("g5001002", true, "Team", false, 100);
    store.save_conversations(&[dm, grp]).unwrap();

    // Media rows:
    // - 3001001 (explicit is_group = 0)
    // - g5001002 (explicit is_group = 1)
    // - 3001003 (NO conversations row -> c.is_group IS NULL -> 1-1 via is_group_id)
    // - g5001004 (NO conversations row -> c.is_group IS NULL -> group via is_group_id)
    let mut m_dm = msg("m1", "3001001", "c1", "", 10, "photo", "sent");
    m_dm.raw_json_data = br#"{"kind":{"type":"photo","size":1000}}"#.to_vec();
    let mut m_grp = msg("m2", "g5001002", "c2", "", 20, "photo", "sent");
    m_grp.raw_json_data = br#"{"kind":{"type":"photo","size":2000}}"#.to_vec();
    let mut m_dm_null = msg("m3", "3001003", "c3", "", 30, "file", "sent");
    m_dm_null.raw_json_data = br#"{"kind":{"type":"file","name":"a.pdf","size":3000}}"#.to_vec();
    let mut m_grp_null = msg("m4", "g5001004", "c4", "", 40, "file", "sent");
    m_grp_null.raw_json_data = br#"{"kind":{"type":"file","name":"b.pdf","size":4000}}"#.to_vec();
    store
        .save_messages(&[m_dm, m_grp, m_dm_null, m_grp_null])
        .unwrap();

    let agg = store.cloud_media_aggregation().unwrap();
    let by_id: std::collections::HashMap<_, _> = agg.iter().map(|s| (s.conv_id.as_str(), s)).collect();
    assert!(!by_id["3001001"].is_group, "explicit 1-1 conv must stay is_group=false");
    assert!(by_id["g5001002"].is_group, "explicit group conv must stay is_group=true");
    assert!(!by_id["3001003"].is_group, "1-1 conv with NULL c.is_group must resolve is_group=false via is_group_id");
    assert!(by_id["g5001004"].is_group, "group conv with NULL c.is_group must resolve is_group=true via is_group_id");
}

//! Ports of the Swift tests that exercise `ZaloWireParser`, plus extra edge cases (ADR-005).

use serde_json::{Map, Value};

use crate::lossless;
use crate::*;

fn obj(s: &str) -> Map<String, Value> {
    lossless::parse_object(s.as_bytes()).expect("valid JSON object")
}

fn val(s: &str) -> Value {
    lossless::parse_any(s.as_bytes()).expect("valid JSON")
}

fn opts() -> WireParseOptions<'static> {
    WireParseOptions::default()
}

fn parse(s: &str, my_uid: &str) -> ParsedWireEvent {
    parse_wire_message(&obj(s), my_uid, &opts())
}

fn msg_of(ev: ParsedWireEvent) -> (ChatMessage, StoredMessage) {
    match ev {
        ParsedWireEvent::Message(m, s) => (*m, *s),
        other => panic!("expected message, got {other:?}"),
    }
}

// MARK: - NativeProtocolTests

#[test]
fn wire_parser_control_types_and_round_trip() {
    // undo
    let undo = parse(
        r#"{"msgType":"chat.undo","uidFrom":"u9","idTo":"me","content":{"globalMsgId":"555","cliMsgId":"c555"}}"#,
        "me",
    );
    assert_eq!(
        undo,
        ParsedWireEvent::Undo {
            conv_id: "u9".into(),
            msg_id: "555".into(),
            cli_msg_id: "c555".into()
        }
    );

    // reaction (group push)
    let o = WireParseOptions {
        cmd: CMD_PUSH_MSG_GROUP,
        ..opts()
    };
    let reaction = parse_wire_message(
        &obj(r#"{"msgType":"chat.reaction","uidFrom":"u9","idTo":"g123",
            "content":{"rType":5,"rIcon":"/-heart","rMsg":[{"gMsgID":"777","cMsgID":"c777"}]}}"#),
        "me",
        &o,
    );
    match reaction {
        ParsedWireEvent::Reaction {
            conv_id,
            msg_id,
            r_type,
            ..
        } => {
            assert_eq!(
                (conv_id.as_str(), msg_id.as_str(), r_type.as_str()),
                ("g123", "777", "5")
            );
        }
        other => panic!("expected reaction, got {other:?}"),
    }

    // Self-cloud push arriving over cmdPushMsgGroup must route to selfConvId, never "g217477...".
    let o = WireParseOptions {
        cmd: CMD_PUSH_MSG_GROUP,
        self_conv_id: Some("2174771368031376212"),
        ..opts()
    };
    let ev = parse_wire_message(
        &obj(
            r#"{"msgId":"888","cliMsgId":"c888","uidFrom":"me","idTo":"2174771368031376212",
            "msgType":"share.file","content":{"title":"probe.txt","href":"https://cdn.example/probe.txt"},"ts":4000}"#,
        ),
        "me",
        &o,
    );
    let (msg, _) = msg_of(ev);
    assert_eq!(msg.conversation_id, "2174771368031376212");
    assert!(msg.is_mine);
}

#[test]
fn parses_text_photo_link_like_sqlite_store_test() {
    let (m1, s1) = msg_of(parse(
        r#"{"msgId":"101","cliMsgId":"c1","uidFrom":"u1","idTo":"me","msgType":"webchat","content":"Tin 1","ts":1000}"#,
        "me",
    ));
    let (m2, s2) = msg_of(parse(
        r#"{"msgId":"102","cliMsgId":"c2","uidFrom":"me","idTo":"u1","msgType":"chat.photo",
        "content":{"hd":"https://cdn.example/p.jpg","title":"Anh"},"ts":2000}"#,
        "me",
    ));
    let (m3, s3) = msg_of(parse(
        r#"{"msgId":"103","cliMsgId":"c3","uidFrom":"u1","idTo":"me","msgType":"chat.recommended",
        "content":{"action":"recommened.link","href":"https://example.com","title":"Example"},"ts":3000}"#,
        "me",
    ));
    assert_eq!(
        (s1.id.as_str(), s1.conv_id.as_str(), s1.kind_tag.as_str()),
        ("101", "u1", "text")
    );
    assert_eq!(
        (s2.id.as_str(), s2.conv_id.as_str(), s2.kind_tag.as_str()),
        ("102", "u1", "photo")
    );
    assert_eq!(
        (s3.id.as_str(), s3.conv_id.as_str(), s3.kind_tag.as_str()),
        ("103", "u1", "link")
    );
    // Seconds are normalized to milliseconds.
    assert_eq!(s1.ts_ms, 1_000_000);
    assert_eq!(m1.date_ms, 1_000_000);
    assert!(m2.is_mine);
    assert_eq!(m2.text, "Anh");
    match m2.kind {
        Kind::Photo { url, .. } => assert_eq!(url.as_deref(), Some("https://cdn.example/p.jpg")),
        other => panic!("{other:?}"),
    }
    match m3.kind {
        Kind::Link { title, url, .. } => {
            assert_eq!(title, "Example");
            assert_eq!(url.as_deref(), Some("https://example.com"));
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(m3.text, "Example");
}

#[test]
fn extract_batch_events_cloud_routing_int_types_contact_cards_and_reactions() {
    let root = val(
        r#"{"error_code":0,"data":[{"threadId":"thread_ignored","type":0,"msgs":[
        {"msgId":"201","uidFrom":"0","idTo":"0","msgType":1,"content":"Cloud note","ts":1000},
        {"msgId":"202","uidFrom":"peer1","idTo":"0","msgType":5,"content":"{\"catId\":0,\"id\":3,\"type\":7}","ts":2000},
        {"msgId":"203","uidFrom":"peer1","idTo":"0","msgType":"chat.recommended",
         "content":{"action":"recommened.user","title":"Nguyen Van B","params":"777888","thumb":"https://cdn.example/a.jpg"},"ts":3000},
        {"msgId":"204","uidFrom":"peer1","idTo":"0","msgType":31,"content":{"globalMsgId":"202"},"ts":4000}
        ]}]}"#,
    );
    let o = WireParseOptions {
        self_conv_id: Some("cloud999"),
        ..opts()
    };
    let events = extract_batch_events(&root, "me123", &o);
    assert_eq!(events.len(), 4);
    let (mut cloud, mut sticker, mut card, mut undo) = (false, false, false, false);
    for ev in &events {
        match ev {
            ParsedWireEvent::Message(msg, _) => match (msg.id.as_str(), &msg.kind) {
                ("201", _) => {
                    cloud = msg.conversation_id == "cloud999"
                        && msg.is_mine
                        && msg.text == "Cloud note";
                }
                ("202", Kind::Sticker { url }) => {
                    sticker = url.as_deref()
                        == Some("https://stc-chat.zdn.vn/images/stickers/default/thumb/3.png");
                }
                ("203", Kind::ContactCard(c)) => {
                    card = c.uid == "777888" && c.name == "Nguyen Van B";
                }
                _ => {}
            },
            ParsedWireEvent::Undo { msg_id, .. } if msg_id == "202" => undo = true,
            _ => {}
        }
    }
    assert!(cloud && sticker && card && undo);

    // Live reactGroups dict extraction
    let root = val(r#"{"data":{"reactGroups":[{"uidFrom":"peer2","idTo":"999",
        "content":{"rIcon":"/-heart","rType":5,"rMsg":[{"gMsgID":"300","cMsgID":"300"}]}}]}}"#);
    let react = extract_batch_events(&root, "me123", &o);
    assert_eq!(react.len(), 1);
    match &react[0] {
        ParsedWireEvent::Reaction {
            conv_id,
            msg_id,
            sender_id,
            r_type,
            ..
        } => {
            assert_eq!(conv_id, "g999");
            assert_eq!(msg_id, "300");
            assert_eq!(sender_id, "peer2");
            assert_eq!(r_type, "5");
        }
        other => panic!("{other:?}"),
    }

    // Profiles dict extraction
    let profiles = extract_profiles_map(&obj(
        r#"{"data":{"profiles":{"111":{"userId":"111","displayName":"Alice"},"222":{"uid":"222","zaloName":"Bob"}}}}"#,
    ));
    assert_eq!(profiles["111"]["displayName"], "Alice");
    assert_eq!(profiles["222"]["zaloName"], "Bob");
}

#[test]
fn batch_envelope_never_routes_1on1_to_ghost_g0_and_prefers_alias() {
    let root = val(
        r#"{"data":{"msgs":[{"msgId":"8500861956467","cliMsgId":"1795000000001",
        "uidFrom":"31612076530602762","idTo":"0","dName":"Ha","msgType":"chat.recommended",
        "ts":1795000000000,"content":{"action":"recommened.calltime","params":"{\"duration\":42,\"callType\":1}"}}],
        "groupMsgs":[]}}"#,
    );
    let lookup = |uid: &str| {
        (uid == "31612076530602762").then(|| NameLookup {
            name: "Mẹ".into(),
            avatar: "https://ava.example/me.jpg".into(),
        })
    };
    let o = WireParseOptions {
        self_conv_id: Some("2174771368031376212"),
        name_lookup: Some(&lookup),
        ..opts()
    };
    let events = extract_batch_events(&root, "2072032406797762235", &o);
    assert_eq!(events.len(), 1);
    let (msg, stored) = msg_of(events[0].clone());
    assert_eq!(msg.conversation_id, "31612076530602762");
    assert_eq!(stored.conv_id, "31612076530602762");
    assert_eq!(msg.sender_name, "Mẹ");
    assert_eq!(
        msg.sender_avatar.as_deref(),
        Some("https://ava.example/me.jpg")
    );
    assert_eq!(msg.text, "Cuộc gọi thoại");
    assert_eq!(
        msg.card_buttons,
        vec![CardButton {
            r#ref: "call:back".into(),
            label: "Gọi lại".into(),
            enabled: true,
            help: String::new()
        }]
    );
    assert_eq!(group_conv_id("0"), "");
    assert_eq!(group_conv_id("g0"), "");
    assert!(!is_group_id("g0"));

    // Explicit 1-1 uidFrom must never be overridden by an unrelated fallbackConvId
    let o = WireParseOptions {
        fallback_conv_id: Some("8964177950559533085"),
        is_group_hint: Some(false),
        ..opts()
    };
    let ev = parse_wire_message(
        &obj(
            r#"{"msgId":"8500861956467","uidFrom":"31612076530602762","idTo":"0","msgType":"webchat",
            "ts":1795000000000,"content":"Alo con"}"#,
        ),
        "2072032406797762235",
        &o,
    );
    let (m, _) = msg_of(ev);
    assert_eq!(m.conversation_id, "31612076530602762");
}

#[test]
fn wire_file_extension_normalization_and_photo_group_array_parsing() {
    let (msg, _) = msg_of(parse(
        r#"{"msgId":"701","uidFrom":"peer1","idTo":"me1","msgType":"share.file","ts":1760000001000,
        "content":{"title":"Báo cáo quý 4","fileUrl":"https://file-stal-f5.dlfl.vn/hash_without_ext",
        "params":"{\"fileSize\":20480,\"fileExt\":\".xlsx\"}"}}"#,
        "me1",
    ));
    match msg.kind {
        Kind::File { name, size, url } => {
            assert_eq!(name, "Báo cáo quý 4.xlsx");
            assert_eq!(size, 20480);
            assert_eq!(
                url.as_deref(),
                Some("https://file-stal-f5.dlfl.vn/hash_without_ext")
            );
        }
        other => panic!("{other:?}"),
    }

    assert_eq!(zdb_msg_type(11), "chat.photo");
    assert_eq!(zdb_msg_type(12), "chat.photo");
    let (album, _) = msg_of(parse(
        r#"{"msgId":"702","uidFrom":"peer1","idTo":"me1","msgType":"chat.photo","ts":1760000002000,
        "content":"[{\"hdUrl\":\"https://photo-stal.zdn.vn/album1.jpg\",\"thumbUrl\":\"https://photo-stal.zdn.vn/album1_t.jpg\",\"width\":800,\"height\":600}]"}"#,
        "me1",
    ));
    match &album.kind {
        Kind::Photo { url, width, height } => {
            assert_eq!(url.as_deref(), Some("https://photo-stal.zdn.vn/album1.jpg"));
            assert_eq!((*width, *height), (800, 600));
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(
        album.fallback_urls,
        vec!["https://photo-stal.zdn.vn/album1_t.jpg".to_string()]
    );
}

const PREKEY_CIPHER: &str = "AzMovwMIpFUwoVUSIQVNUKcMqQKEDdK1jcEt8He7V15D1iWl9ngJgOPtsXiUIRohBZSX4D1qiBhXbdSPciObevx/DTnpfki5s5eI0wzTTQp/InIzCiEFCFnb614YZfaOg7R9/7/DIagW4nsLw5V5jK1ELLEbY1IQCBgAIkDL6XqJXgMKkj5gMtM5+CCkjt5p+Xm4q0wQjhLXMOgyl8M137oQAjyDi9fCjALZOCaCQpyjgm5/eW2crnxEu3JybU+y/enV2FQ=";
const WHISPER_CIPHER: &str =
    "AjMKIQXfGtZEt75pr2/KWoTA8W8Bu0oNpGDv9ITalIBSb69UaxAOGAAiENtYix7GNUB1eR/LgY4IuK2Blmqxld2njA==";

#[test]
fn e2ee_signal_detection_and_placeholders() {
    let broken_url =
        format!("https://api.zaloapp.com/api/emoticon/sticker/webpc?eid={PREKEY_CIPHER}&size=130");
    assert!(is_signal_ciphertext(PREKEY_CIPHER));
    assert!(is_signal_ciphertext(WHISPER_CIPHER));
    assert!(!is_signal_ciphertext("miế ngan trộn"));
    assert!(!is_signal_ciphertext(
        "https://api.zaloapp.com/api/emoticon/sticker/webpc?eid=34840&size=130"
    ));
    assert!(url_has_undecrypted_signal_cipher(&broken_url));

    let locked_text = serde_json::json!({
        "msgId": "8502116332010", "cliMsgId": "1794982452921", "uidFrom": "31612076530602762",
        "idTo": "2072032406797762235", "msgType": "webchat", "ts": 1_794_982_453_589_i64,
        "content": PREKEY_CIPHER
    });
    let (locked, stored) = msg_of(parse(&locked_text.to_string(), "2072032406797762235"));
    assert!(locked.is_e2ee);
    assert_eq!(stored.status, "e2ee_locked");
    match &locked.kind {
        Kind::Placeholder { symbol, text } => {
            assert_eq!(symbol, "lock.fill");
            assert!(text.contains("mã hóa đầu cuối"));
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(locked.text, "🔒 Tin nhắn mã hóa đầu cuối");

    let locked_sticker = serde_json::json!({
        "msgId": "8502117270115", "cliMsgId": "1794982471828", "uidFrom": "31612076530602762",
        "idTo": "2072032406797762235", "msgType": "chat.sticker", "ts": 1_794_982_472_463_i64,
        "content": {"id": PREKEY_CIPHER, "catId": PREKEY_CIPHER, "type": PREKEY_CIPHER}
    });
    let (s_msg, s_stored) = msg_of(parse(&locked_sticker.to_string(), "2072032406797762235"));
    assert_eq!(s_stored.status, "e2ee_locked");
    match &s_msg.kind {
        Kind::Placeholder { text, .. } => assert!(text.contains("Sticker mã hóa đầu cuối")),
        other => panic!("{other:?}"),
    }

    // Sync2 arrives with real plaintext for the exact same message.
    let plain = serde_json::json!({
        "msgId": "8502116332010", "cliMsgId": "1794982452921", "uidFrom": "31612076530602762",
        "idTo": "2072032406797762235", "msgType": "webchat", "ts": 1_794_982_453_589_i64,
        "content": "Con về ăn cơm nhé"
    });
    let (plain_msg, plain_stored) = msg_of(parse(&plain.to_string(), "2072032406797762235"));
    assert_eq!(plain_stored.status, "sent");
    assert_eq!(plain_stored.text, "Con về ăn cơm nhé");
    assert_eq!(plain_stored.id, locked.id);
    assert!(matches!(plain_msg.kind, Kind::Text));
}

#[test]
fn decrypted_e2ee_envelope_parses_text_and_sticker() {
    // Shape of the envelope after `decryptEnvelopeIfNeeded` (plaintext content, id 34840 / cat 420).
    let root = val(r#"{"data":{"msgs":[
        {"msgId":"9001","cliMsgId":"9001","uidFrom":"mom_uid","idTo":"me_uid","msgType":"webchat","ts":1795000001000,
         "paramsExt":{"platformType":0},"content":"Mẹ nấu canh chua rồi!","isE2EE":true},
        {"msgId":"9002","cliMsgId":"9002","uidFrom":"mom_uid","idTo":"me_uid","msgType":"chat.sticker","ts":1795000002000,
         "paramsExt":{"platformType":0},"content":{"id":34840,"catId":420,"type":7},"e2eeStatus":1}]}}"#);
    let events = extract_batch_events(&root, "me_uid", &opts());
    assert_eq!(events.len(), 2);
    let (m1, _) = msg_of(events[0].clone());
    assert_eq!(m1.text, "Mẹ nấu canh chua rồi!");
    assert!(m1.is_e2ee);
    let (m2, _) = msg_of(events[1].clone());
    match m2.kind {
        Kind::Sticker { url } => assert!(url.unwrap().contains("eid=34840")),
        other => panic!("{other:?}"),
    }
    assert!(m2.is_e2ee);
}

#[test]
fn sanitize_profile_uid_and_extract_profiles_map_variants() {
    for bad in [
        "",
        "   ",
        "0",
        "000",
        "-1",
        "g123",
        "G123456",
        "stranger_box",
        "u",
        "u0",
        "123_abc",
        "123_",
        "2000.globalEncryptedId==",
    ] {
        assert_eq!(sanitize_profile_uid(bad), None, "{bad:?}");
    }
    assert_eq!(sanitize_profile_uid(&"9".repeat(25)), None);
    assert_eq!(sanitize_profile_uid("123456").as_deref(), Some("123456"));
    assert_eq!(
        sanitize_profile_uid("  123456  ").as_deref(),
        Some("123456")
    );
    assert_eq!(sanitize_profile_uid("u123456").as_deref(), Some("123456"));
    assert_eq!(sanitize_profile_uid("123456_0").as_deref(), Some("123456"));
    assert_eq!(
        sanitize_profile_uid("u123456_12").as_deref(),
        Some("123456")
    );
    assert_eq!(sanitize_profile_uid(&"7".repeat(24)), Some("7".repeat(24)));

    let v2 = extract_profiles_map(&obj(
        r#"{"data":{"changed_profiles":{"111_0":{"userId":"111","displayName":"Changed Alice","avatar":"https://a.vn/1.jpg"}},
        "unchanged_profiles":{"222_0":{"uid":"222","zaloName":"Unchanged Bob","avt":"https://a.vn/2.jpg"}}}}"#,
    ));
    assert_eq!(v2["111"]["displayName"], "Changed Alice");
    assert_eq!(v2["222"]["zaloName"], "Unchanged Bob");

    let from_list = extract_profiles_map(&obj(
        r#"{"data":{"list":[{"id":"333","dName":"Charlie"}]}}"#,
    ));
    assert_eq!(from_list["333"]["dName"], "Charlie");

    // getprofiles/v2 answer shape used by `fetchProfiles` (changed_profiles keyed by uid, empty unchanged).
    let merged = extract_profiles_map(&obj(
        r#"{"error_code":0,"data":{"changed_profiles":{"111":{"userId":"111","displayName":"User 111"},
        "333":{"userId":"333","displayName":"User 333"}},"unchanged_profiles":{}}}"#,
    ));
    let mut keys: Vec<&str> = merged.keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(keys, vec!["111", "333"]);
    assert_eq!(merged["111"]["displayName"], "User 111");
}

// MARK: - FeatureFixesTests / Stage4 / GroupMgmt

#[test]
fn reaction_spec_and_icon_and_client_msg_type() {
    assert_eq!(reaction_spec("😡"), (":-h", 20));
    assert_eq!(reaction_spec("😠"), (":-h", 20));
    assert_eq!(reaction_spec("❤️"), ("/-heart", 5));
    assert_eq!(reaction_spec("❤"), ("/-heart", 5));
    assert_eq!(reaction_spec("👍"), ("/-strong", 3));
    assert_eq!(reaction_spec("😆"), (":>", 0));
    assert_eq!(reaction_spec("😮"), (":o", 32));
    assert_eq!(reaction_spec("😢"), (":-((", 2));

    assert_eq!(reaction_icon("20", "").unwrap().emoji, "😡");
    assert_eq!(reaction_icon("-1", ""), None);
    assert_eq!(reaction_icon("", ""), None);
    assert_eq!(reaction_icon("999", ""), None);
    assert_eq!(reaction_icon("34", "/-weak").unwrap().emoji, "/-weak");

    assert_eq!(reaction_client_msg_type(&Kind::Text), 1);
    assert_eq!(
        reaction_client_msg_type(&Kind::Voice {
            url: None,
            duration: 5
        }),
        31
    );
    assert_eq!(
        reaction_client_msg_type(&Kind::Photo {
            url: None,
            width: 100,
            height: 100
        }),
        32
    );
    assert_eq!(reaction_client_msg_type(&Kind::Sticker { url: None }), 36);
    assert_eq!(
        reaction_client_msg_type(&Kind::Link {
            title: "t".into(),
            url: None,
            thumbnail: None,
            description: String::new(),
            source: String::new()
        }),
        38
    );
    assert_eq!(
        reaction_client_msg_type(&Kind::ContactCard(ContactCard {
            name: "A".into(),
            ..Default::default()
        })),
        38
    );
    assert_eq!(
        reaction_client_msg_type(&Kind::Location(LocationInfo::default())),
        43
    );
    assert_eq!(
        reaction_client_msg_type(&Kind::Video {
            thumbnail: None,
            duration: 3,
            url: None
        }),
        44
    );
    assert_eq!(
        reaction_client_msg_type(&Kind::File {
            name: "a.pdf".into(),
            size: 10,
            url: None
        }),
        46
    );
    assert_eq!(reaction_client_msg_type(&Kind::Gif { url: None }), 49);
}

#[test]
fn chat_message_preserves_client_id_through_json_round_trip() {
    let dict = obj(
        r#"{"id":"srv_9001","clientId":"cli_1700001","kind":{"type":"text"},
        "text":"Tin nhắn cần lưu cliId","isMine":true}"#,
    );
    let msg = ChatMessage::from_json(&dict, "300").unwrap();
    assert_eq!(msg.id, "srv_9001");
    assert_eq!(msg.client_id, "cli_1700001");
    assert_eq!(msg.conversation_id, "300");

    let stored = encode_chat_message(&msg, "").unwrap();
    assert_eq!(stored.client_id, "cli_1700001");
    let decoded = decode_stored_message(&stored).unwrap();
    assert_eq!(decoded.id, "srv_9001");
    assert_eq!(decoded.client_id, "cli_1700001");
    assert_eq!(decoded.text, "Tin nhắn cần lưu cliId");
}

#[test]
fn my_cloud_wire_message_excludes_recall_menu() {
    let o = WireParseOptions {
        fallback_conv_id: Some("999"),
        is_group_hint: Some(false),
        self_conv_id: Some("999"),
        ..opts()
    };
    let ev = parse_wire_message(
        &obj(
            r#"{"msgId":"8001","cliMsgId":"4001","uidFrom":"100","idTo":"999","msgType":"webchat",
            "content":"Ghi chú cá nhân","ts":1700000000000}"#,
        ),
        "100",
        &o,
    );
    let (parsed, stored) = msg_of(ev);
    assert_eq!(parsed.conversation_id, "999");
    let decoded = decode_stored_message(&stored).unwrap();
    assert!(!decoded.menu.recall);
    assert_eq!(decoded.menu.delete, Some(DeleteMode::Plain));
}

#[test]
fn fallback_urls_survive_stored_message_round_trip() {
    let (built, stored) = msg_of(parse(
        r#"{"msgId":"5001","uidFrom":"111","idTo":"999","msgType":"chat.photo","ts":1760000000000,
        "content":{"hdUrl":"https://photo-stal-f10.zdn.vn/jpg/hd_full.jpg",
        "normalUrl":"https://photo-stal-f10.zdn.vn/jpg/normal_mid.jpg",
        "thumbUrl":"https://f16-zpcloud.zdn.vn/jpg/thumb_small.jpg","width":1200,"height":900}}"#,
        "999",
    ));
    match &built.kind {
        Kind::Photo { url, width, height } => {
            assert_eq!(
                url.as_deref(),
                Some("https://photo-stal-f10.zdn.vn/jpg/hd_full.jpg")
            );
            assert_eq!((*width, *height), (1200, 900));
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(
        built.fallback_urls,
        vec![
            "https://photo-stal-f10.zdn.vn/jpg/normal_mid.jpg".to_string(),
            "https://f16-zpcloud.zdn.vn/jpg/thumb_small.jpg".to_string(),
        ]
    );
    let decoded = decode_stored_message(&stored).unwrap();
    assert_eq!(decoded.fallback_urls, built.fallback_urls);
    assert_eq!(decoded, built);
}

fn heart_reaction() -> Reaction {
    Reaction {
        icon: ReactionIcon::new("5", "/-heart", "❤️"),
        count: 1,
        includes_me: true,
        names: vec!["Bạn".into()],
        people: 1,
        user_counts: [("100".to_string(), 1)].into_iter().collect(),
    }
}

fn base_message(kind: Kind, text: &str) -> ChatMessage {
    ChatMessage {
        id: "7001".into(),
        conversation_id: "200".into(),
        sender_id: "200".into(),
        sender_name: "Lan".into(),
        sender_avatar: None,
        is_mine: false,
        kind,
        text: text.into(),
        date_ms: 1_760_000_000_000,
        status: Status::Sent,
        quote: None,
        reactions: vec![],
        is_e2ee: false,
        mentions: vec![],
        card_buttons: vec![],
        suggests_stickers: false,
        menu: MessageMenu::default(),
        fallback_urls: vec![],
        client_id: "c7001".into(),
        text_styles: vec![],
        ttl_ms: 0,
        urgency: 0,
    }
}

#[test]
fn reactions_encode_decode_and_empty_clears() {
    let mut with = base_message(Kind::Text, "Test");
    with.reactions = vec![heart_reaction()];
    let stored_with = encode_chat_message(&with, "").unwrap();
    let after = decode_stored_message(&stored_with).unwrap();
    assert_eq!(after.reactions.len(), 1);
    assert_eq!(after.reactions[0], heart_reaction());

    let mut without = with.clone();
    without.reactions = vec![];
    let after_clear = decode_stored_message(&encode_chat_message(&without, "").unwrap()).unwrap();
    assert!(after_clear.reactions.is_empty());
}

#[test]
fn ghost_reactions_are_dropped_on_decode() {
    let d = obj(r#"{"id":"1","kind":{"type":"text"},"reactions":[
        {"type":"5","key":"/-heart","emoji":"❤️","count":3,"includesMe":false,"names":[],"people":0},
        {"type":"-1","key":"x","emoji":"x","count":1,"includesMe":true},
        {"type":"3","key":"/-strong","emoji":"👍","count":2,"includesMe":false,"userCounts":{"unknown":2}},
        {"type":"0","key":":>","emoji":"😆","count":9,"includesMe":false,"userCounts":{"a":2,"b":1},"names":["Người dùng Zalo","An"]}
        ]}"#);
    let m = ChatMessage::from_json(&d, "c").unwrap();
    assert_eq!(m.reactions.len(), 1);
    assert_eq!(m.reactions[0].count, 3); // sum of userCounts, not "count"
    assert_eq!(m.reactions[0].people, 2);
    assert_eq!(m.reactions[0].names, vec!["An".to_string()]);
}

#[test]
fn media_kinds_round_trip_with_e2ee_locked_status() {
    let kinds = [
        Kind::Photo {
            url: Some("https://cdn.example/p.jpg".into()),
            width: 800,
            height: 600,
        },
        Kind::File {
            name: "Spec.pdf".into(),
            size: 500_000,
            url: Some("https://cdn.example/spec.pdf".into()),
        },
        Kind::Video {
            thumbnail: None,
            duration: 12,
            url: Some("https://cdn.example/v.mp4".into()),
        },
        Kind::Voice {
            url: Some("https://cdn.example/a.m4a".into()),
            duration: 5,
        },
        Kind::Photo {
            url: None,
            width: 0,
            height: 0,
        },
    ];
    for k in kinds {
        let msg = base_message(k.clone(), "x");
        let mut stored = encode_chat_message(&msg, "").unwrap();
        stored.status = "e2ee_locked".into();
        let decoded = decode_stored_message(&stored).unwrap();
        assert_eq!(decoded.kind, k);
        assert_eq!(decoded.date_ms, 1_760_000_000_000);
    }
    let (_, tag) = serialize_kind(&Kind::Voice {
        url: None,
        duration: 0,
    });
    assert_eq!(tag, "voice");
}

// MARK: - Extra edge cases

#[test]
fn huge_unquoted_ids_stay_exact() {
    let root = val(
        r#"{"data":{"msgs":[{"msgId":7412345678901234567,"cliMsgId":7412345678901234568,"uidFrom":7412345678901234569,
        "idTo":2072032406797762235,"msgType":"webchat","content":"hi","ts":1795000000000}]}}"#,
    );
    let events = extract_batch_events(&root, "2072032406797762235", &opts());
    assert_eq!(events.len(), 1);
    let (m, s) = msg_of(events[0].clone());
    assert_eq!(m.id, "7412345678901234567");
    assert_eq!(s.client_id, "7412345678901234568");
    assert_eq!(m.sender_id, "7412345678901234569");
    assert_eq!(m.conversation_id, "7412345678901234569");
}

#[test]
fn huge_ids_also_exact_without_lossless_pre_quoting() {
    // `serde_json` with arbitrary_precision keeps the literal even when the caller did not use `parse_object`.
    let raw: Map<String, Value> = serde_json::from_str(
        r#"{"msgId":7412345678901234567,"uidFrom":"peer","idTo":"me","msgType":"webchat","content":"x","ts":1}"#,
    )
    .unwrap();
    let (m, _) = msg_of(parse_wire_message(&raw, "me", &opts()));
    assert_eq!(m.id, "7412345678901234567");
}

#[test]
fn lossless_quoting_rules() {
    let q =
        |s: &str| String::from_utf8(lossless::quote_large_integer_literals(s.as_bytes())).unwrap();
    assert_eq!(q(r#"{"a":123456789012345}"#), r#"{"a":"123456789012345"}"#);
    assert_eq!(q(r#"{"a":12345678901234}"#), r#"{"a":12345678901234}"#); // 14 digits
    assert_eq!(
        q(r#"{"a":-123456789012345678}"#),
        r#"{"a":-123456789012345678}"#
    ); // negative untouched
    assert_eq!(
        q(r#"{"a":123456789012345.5}"#),
        r#"{"a":123456789012345.5}"#
    );
    assert_eq!(
        q(r#"{"a":"123456789012345678"}"#),
        r#"{"a":"123456789012345678"}"#
    );
    assert_eq!(q(r#"[1234567890123456,2]"#), r#"["1234567890123456",2]"#);
    let v = val(r#"{"x":7412345678901234567}"#);
    assert_eq!(v["x"], "7412345678901234567");
}

#[test]
fn lossless_coercions() {
    let v = val(
        r#"{"s":"  42 ","n":5,"f":5.0,"b":true,"z":0,"t":"TRUE","nul":null,"big":12345678901234567890}"#,
    );
    assert_eq!(lossless::string(v.get("n")), "5");
    assert_eq!(lossless::string(v.get("f")), "5");
    assert_eq!(lossless::string(v.get("b")), "true");
    assert_eq!(lossless::string(v.get("nul")), "");
    assert_eq!(lossless::string(None), "");
    assert_eq!(lossless::int64(v.get("s")), Some(42));
    assert_eq!(lossless::int64(v.get("b")), Some(1));
    assert_eq!(lossless::int64(v.get("nul")), None);
    assert_eq!(lossless::bool(v.get("t")), Some(true));
    assert_eq!(lossless::bool(v.get("z")), Some(false));
    assert_eq!(lossless::bool(v.get("s")), None);
    assert_eq!(lossless::string(v.get("big")), "12345678901234567890");
}

#[test]
fn missing_optional_fields_default_sensibly() {
    // No msgId / cliMsgId at all: a synthetic id is generated; no ts: "now" is used.
    let (m, s) = msg_of(parse(
        r#"{"uidFrom":"peer","idTo":"me","msgType":"webchat","content":"hi"}"#,
        "me",
    ));
    assert!(m.id.contains('_'));
    assert_eq!(s.id, m.id);
    assert!(m.date_ms > 1_600_000_000_000);
    assert_eq!(m.sender_name, "Người dùng Zalo");
    assert_eq!(m.client_id, "");
    assert!(m.mentions.is_empty() && m.quote.is_none());

    // Missing everything routable: ignored.
    assert_eq!(
        parse(r#"{"msgType":"webchat","content":"x"}"#, "").clone(),
        ParsedWireEvent::Ignore
    );
    // Reaction without a target is ignored.
    assert_eq!(
        parse(
            r#"{"msgType":"chat.reaction","uidFrom":"u9","idTo":"me","content":{"rType":5}}"#,
            "me"
        ),
        ParsedWireEvent::Ignore
    );
    // msgId "0" falls back to the client id.
    let (m, _) = msg_of(parse(
        r#"{"msgId":"0","cliMsgId":"c9","uidFrom":"peer","idTo":"me","content":"x"}"#,
        "me",
    ));
    assert_eq!(m.id, "c9");
}

#[test]
fn emoji_and_diacritics_are_preserved() {
    let (m, s) = msg_of(parse(
        r#"{"msgId":"1","uidFrom":"peer","idTo":"me","msgType":"webchat","dName":"Nguyễn Thị Ánh","content":"Chào bạn 👋🏽 👨‍👩‍👧 Việt Nam ❤️","ts":1760000000}"#,
        "me",
    ));
    assert_eq!(m.text, "Chào bạn 👋🏽 👨‍👩‍👧 Việt Nam ❤️");
    assert_eq!(m.sender_name, "Nguyễn Thị Ánh");
    assert_eq!(s.ts_ms, 1_760_000_000_000);
    let decoded = decode_stored_message(&s).unwrap();
    assert_eq!(decoded.text, m.text);
    assert_eq!(normalized_file_name("Báo cáo", ".docx"), "Báo cáo.docx");
    assert_eq!(normalized_file_name("báo CÁO.DOCX", "docx"), "báo CÁO.DOCX");
    assert_eq!(normalized_file_name("  ", ""), "Tệp đính kèm");
    assert_eq!(preview_label("photo", "  "), "[Hình ảnh]");
    assert_eq!(preview_label("photo", " Ảnh đẹp "), "Ảnh đẹp");
}

#[test]
fn mention_offsets_are_raw_utf16_integers() {
    // "@Ánh 👋" : the server counts UTF-16 units; the parser must keep pos/len untouched.
    let (m, s) = msg_of(parse(
        r#"{"msgId":"1","uidFrom":"peer","idTo":"g55","msgType":"webchat","content":"@Ánh 👋 xin chào","ts":1760000000000,
        "mentions":[{"uid":"42","pos":0,"len":4,"type":0},{"uid":"-1","pos":5,"len":3},{"uid":"","pos":1,"len":1},
        {"uid":"7","pos":"6","len":"2","isAll":true}]}"#,
        "me",
    ));
    assert_eq!(m.conversation_id, "g55");
    assert_eq!(
        m.mentions,
        vec![
            Mention {
                uid: "42".into(),
                pos: 0,
                len: 4,
                is_all: false
            },
            Mention {
                uid: "-1".into(),
                pos: 5,
                len: 3,
                is_all: true
            },
            Mention {
                uid: "7".into(),
                pos: 6,
                len: 2,
                is_all: true
            },
        ]
    );
    assert!(m.menu.pin); // group, not cloud
    let d = decode_stored_message(&s).unwrap();
    assert_eq!(d.mentions, m.mentions);
}

#[test]
fn quote_and_signal_quote_are_sanitized() {
    let me = "100";
    let (m, _) = msg_of(parse(
        r#"{"msgId":"1","uidFrom":"peer","idTo":"100","msgType":"webchat","content":"ok","ts":1760000000000,
        "quote":{"ownerId":"100","msg":"hello","fromD":"x"}}"#,
        me,
    ));
    assert_eq!(
        m.quote,
        Some(Quote {
            sender_name: "Bạn".into(),
            text: "hello".into(),
            msg_id: String::new(),
            cli_msg_id: String::new(),
        })
    );
    let q = serde_json::json!({"msgId":"2","uidFrom":"peer","idTo":"100","msgType":"webchat","content":"ok",
        "ts":1760000000000_i64,"quote":{"ownerId":"peer","msg":PREKEY_CIPHER,"fromD":PREKEY_CIPHER}});
    let (m, _) = msg_of(parse(&q.to_string(), me));
    assert_eq!(
        m.quote,
        Some(Quote {
            sender_name: "Người dùng Zalo".into(),
            text: "[Tin nhắn mã hóa đầu cuối]".into(),
            msg_id: String::new(),
            cli_msg_id: String::new(),
        })
    );
}

#[test]
fn control_events_and_reaction_string_rmsg() {
    let ev = parse(
        r#"{"msgType":"chat.delete","uidFrom":"u9","idTo":"me","msgId":"1","content":{"globalDelMsgId":"90","clientDelMsgId":"91"}}"#,
        "me",
    );
    assert_eq!(
        ev,
        ParsedWireEvent::Delete {
            conv_id: "u9".into(),
            msg_id: "90".into(),
            cli_msg_id: "91".into()
        }
    );
    // rMsg arrives as a JSON string holding an array.
    let ev = parse(
        r#"{"msgType":"chat.reaction","uidFrom":"u9","idTo":"me","msgId":"5","actionId":"77","cliMsgId":"8","ts":1760000000,
        "dName":"An","content":{"rType":"3","rIcon":"/-strong","rMsg":"[{\"gMsgID\":\"7412345678901234567\",\"cMsgID\":\"c1\"}]"}}"#,
        "me",
    );
    match ev {
        ParsedWireEvent::Reaction {
            conv_id,
            msg_id,
            cli_msg_id,
            sender_id,
            event_id,
            react_client_id,
            ts_ms,
            seq_id,
            sender_name,
            ..
        } => {
            assert_eq!(conv_id, "u9");
            assert_eq!(msg_id, "7412345678901234567");
            assert_eq!(cli_msg_id, "c1");
            assert_eq!(sender_id, "u9");
            assert_eq!(event_id, "77");
            assert_eq!(react_client_id, "8");
            assert_eq!(ts_ms, 1_760_000_000_000);
            assert_eq!(seq_id, 77);
            assert_eq!(sender_name, "An");
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn sort_reactions_chronologically_per_target() {
    let r = |msg: &str, ts: i64, seq: i64, sender: &str| ParsedWireEvent::Reaction {
        conv_id: "c".into(),
        msg_id: msg.into(),
        cli_msg_id: String::new(),
        sender_id: sender.into(),
        r_type: "5".into(),
        r_icon: String::new(),
        event_id: String::new(),
        react_client_id: String::new(),
        ts_ms: ts,
        seq_id: seq,
        sender_name: String::new(),
    };
    let events = vec![
        r("A", 300, 3, "a3"),
        ParsedWireEvent::Ignore,
        r("B", 50, 1, "b1"),
        r("A", 100, 1, "a1"),
        r("A", 200, 2, "a2"),
        r("B", 0, 9, "b0"),
    ];
    let sorted = sort_reaction_events_chronologically(&events);
    let senders: Vec<String> = sorted
        .iter()
        .map(|e| match e {
            ParsedWireEvent::Reaction { sender_id, .. } => sender_id.clone(),
            _ => String::new(),
        })
        .collect();
    // Group A first (first seen), sorted by ts; group B has a zero ts so falls back to seq ids (1 < 9).
    assert_eq!(senders, vec!["a1", "a2", "a3", "b1", "b0"]);
}

#[test]
fn id_helpers() {
    assert_eq!(clean_group_id(" group_55 "), "55");
    assert_eq!(clean_group_id("G77"), "77");
    assert_eq!(clean_group_id("gabc"), "gabc");
    assert_eq!(group_conv_id("group_9"), "g9");
    assert!(
        is_group_id("group_9")
            && !is_group_id("group_0")
            && !is_group_id("g")
            && !is_group_id("gx1")
    );
    assert_eq!(normalize_thread_id_from_list("u12345"), "12345");
    assert_eq!(normalize_thread_id_from_list("g678"), "g678");
    assert_eq!(normalize_thread_id_from_list("group_0"), "");
    assert_eq!(normalize_thread_id_from_list("abc"), "abc");
}

#[test]
fn timestamp_and_misc_helpers() {
    assert_eq!(
        normalize_timestamp_ms_at(Some(&val("1760000000")), 5),
        1_760_000_000_000
    );
    assert_eq!(
        normalize_timestamp_ms_at(Some(&val("\"1760000000123\"")), 5),
        1_760_000_000_123
    );
    assert_eq!(normalize_timestamp_ms_at(Some(&val("0")), 5), 5);
    assert_eq!(normalize_timestamp_ms_at(None, 5), 5);
    assert_eq!(optional_timestamp_ms(Some(&val("-3"))), 0);
    assert_eq!(
        sticker_cdn_url(0, "30"),
        "https://stc-chat.zdn.vn/images/stickers/default/thumb/30.png"
    );
    assert_eq!(
        sticker_cdn_url(0, "31"),
        "https://api.zaloapp.com/api/emoticon/sticker/webpc?eid=31&size=130"
    );
    assert_eq!(sticker_cdn_url(-1, " "), "");
    assert_eq!(normalized_msg_type(" 24 "), "chat.location.new");
    assert_eq!(normalized_msg_type("chat.gif"), "chat.gif");
    assert_eq!(zdb_msg_type(-4), "group.event");
    assert_eq!(zdb_msg_type(999), "webchat");
    assert_eq!(
        unique_non_empty_strings(&[" a ".into(), "a".into(), "".into(), "b".into()]),
        vec!["a".to_string(), "b".to_string()]
    );
}

#[test]
fn location_poll_ecard_voice_video_kinds() {
    let (loc, _) = msg_of(parse(
        r#"{"msgId":"1","uidFrom":"p","idTo":"me","msgType":"chat.location.new","ts":1760000000000,
        "content":{"title":"Quán","description":"Hà Nội","params":"{\"latitude\":\"21.03\",\"longitude\":105.85}"}}"#,
        "me",
    ));
    match &loc.kind {
        Kind::Location(l) => assert_eq!(l.coordinate, Some((21.03, 105.85))),
        other => panic!("{other:?}"),
    }
    let (voice, _) = msg_of(parse(
        r#"{"msgId":"2","uidFrom":"p","idTo":"me","msgType":"chat.voice","ts":1760000000000,
        "content":{"href":"https://v/a.m4a","params":"{\"duration\":12500}"}}"#,
        "me",
    ));
    assert_eq!(
        voice.kind,
        Kind::Voice {
            url: Some("https://v/a.m4a".into()),
            duration: 12
        }
    );
    let (poll, _) = msg_of(parse(
        r#"{"msgId":"3","uidFrom":"p","idTo":"g9","msgType":"group.poll","ts":1760000000000,
        "content":{"description":"An đã bình chọn","params":"{\"poll_id\":7412345678901234567,\"question\":\"Ăn gì?\",\"is_anonymous\":1}"}}"#,
        "me",
    ));
    assert_eq!(
        poll.kind,
        Kind::Poll(PollInfo {
            question: "Ăn gì?".into(),
            header: "An đã bình chọn".into(),
            anonymous: true,
            poll_id: "7412345678901234567".into(),
            conversation_id: "g9".into()
        })
    );
    let (card, _) = msg_of(parse(
        r#"{"msgId":"4","uidFrom":"p","idTo":"me","msgType":"chat.ecard","ts":1760000000000,
        "content":{"action":"ecard.birthday","title":"Sinh nhật","params":"{\"startTime\":1760000000000}"}}"#,
        "me",
    ));
    assert!(card.suggests_stickers);
    match card.kind {
        Kind::Ecard(c) => {
            assert_eq!(c.style, ECardStyle::Birthday);
            assert_eq!(c.reminder_start_ms, Some(1_760_000_000_000));
            assert_eq!(c.reminder_title, "Sinh nhật");
        }
        other => panic!("{other:?}"),
    }
    let (unk, _) = msg_of(parse(
        r#"{"msgId":"5","uidFrom":"p","idTo":"me","msgType":"chat.weird","ts":1760000000000,"content":{}}"#,
        "me",
    ));
    assert_eq!(
        unk.kind,
        Kind::Unsupported {
            raw_type: "chat.weird".into()
        }
    );
    assert_eq!(unk.text, "[chat.weird]");
}

#[test]
fn web_link_sanitizing_in_link_cards() {
    let (m, _) = msg_of(parse(
        r#"{"msgId":"1","uidFrom":"p","idTo":"me","msgType":"chat.recommended","ts":1760000000000,
        "content":{"action":"recommened.link","href":"javascript:alert(1)","title":"x"}}"#,
        "me",
    ));
    // The canonical JSON keeps the URL, but decoding a Link kind only accepts http(s) with a host.
    match m.kind {
        Kind::Link { url, .. } => assert_eq!(url, None),
        other => panic!("{other:?}"),
    }
}

/// Info notices synced from the phone (pin / unpin / …) arrive as `webchat` with an object content whose
/// `action` is `msginfo.actionlist`: a centered system line, not a text bubble (same as under `chat.recommended`).
#[test]
fn webchat_msginfo_actionlist_is_system() {
    let (m, s) = msg_of(parse(
        r#"{"msgId":"8522","cliMsgId":"1795","msgType":"webchat","uidFrom":"0","idTo":"peer","ts":"1795463690898",
            "content":{"action":"msginfo.actionlist","title":"Hoàng Việt Linh đã ghim tin nhắn a đi dạy về ah.","description":"","href":"","params":"{}","thumb":"","type":"","childnumber":0}}"#,
        "me",
    ));
    assert_eq!(s.kind_tag, "system");
    assert_eq!(m.text, "Hoàng Việt Linh đã ghim tin nhắn a đi dạy về ah.");
    // A plain webchat with an object content stays text.
    let (_, plain) = msg_of(parse(
        r#"{"msgId":"8523","msgType":"webchat","uidFrom":"peer","idTo":"me","ts":"1","content":{"title":"hi"}}"#,
        "me",
    ));
    assert_eq!(plain.kind_tag, "text");
}

/// `group.poll` events (official `_onMessageInfoEvent`): the info line is the actor + the verb of `content.action` + the
/// question from `content.params`; the actor is "Bạn" for my own events.
#[test]
fn group_poll_event_info_line() {
    let ev = |action: &str, from: &str| {
        let raw = format!(
            r#"{{"msgId":"9{action}","msgType":"group.poll","uidFrom":"{from}","idTo":"3993665107146848278","ts":"1",
                "content":{{"action":"{action}","title":"","description":"","params":"{{\"pollId\":1192926841,\"question\":\"Khỏe không\",\"uid\":\"{from}\",\"dName\":\"Việt Linh\",\"pollVer\":2}}"}}}}"#
        );
        let o = WireParseOptions {
            is_group_hint: Some(true),
            ..Default::default()
        };
        let (_, s) = msg_of(parse_wire_message(&obj(&raw), "me", &o));
        let kind: serde_json::Value = serde_json::from_slice(&s.raw_json_data).unwrap();
        kind["kind"]["header"].as_str().unwrap().to_string()
    };
    assert_eq!(
        ev("create", "peer"),
        "Việt Linh tạo cuộc bình chọn mới: Khỏe không"
    );
    assert_eq!(
        ev("vote", "peer"),
        "Việt Linh tham gia cuộc bình chọn: Khỏe không"
    );
    assert_eq!(
        ev("update", "peer"),
        "Việt Linh đổi lựa chọn trong cuộc bình chọn: Khỏe không"
    );
    assert_eq!(
        ev("share", "peer"),
        "Việt Linh chia sẻ cuộc bình chọn: Khỏe không"
    );
    assert_eq!(ev("close", "peer"), "Việt Linh khóa bình chọn: Khỏe không");
    assert_eq!(ev("vote", "0"), "Bạn tham gia cuộc bình chọn: Khỏe không");
}

/// Rich text (official `action: rtf`, sent with `textProperties`): the text is `title`, the styles come from
/// `params.styles` and survive the store round trip.
#[test]
fn rtf_styles_parse_and_round_trip() {
    let (m, s) = msg_of(parse(
        r#"{"msgId":"8601","cliMsgId":"1801","msgType":"webchat","uidFrom":"peer","idTo":"me","ts":"1",
            "content":{"action":"rtf","title":"Đậm nghiêng","description":"","href":"","thumb":"","type":"","childnumber":0,
            "params":"{\"styles\":[{\"start\":0,\"len\":3,\"st\":\"b\"},{\"start\":4,\"len\":7,\"st\":\"i,c_db342e\"},{\"start\":0,\"len\":0,\"st\":\"u\"}],\"ver\":0}"}}"#,
        "me",
    ));
    assert_eq!(s.kind_tag, "text");
    assert_eq!(m.text, "Đậm nghiêng");
    assert_eq!(
        m.text_styles,
        vec![
            TextStyle {
                start: 0,
                len: 3,
                st: "b".into()
            },
            TextStyle {
                start: 4,
                len: 7,
                st: "i,c_db342e".into()
            },
        ]
    );
    let stored = encode_chat_message(&m, "").unwrap();
    let decoded = decode_stored_message(&stored).unwrap();
    assert_eq!(decoded.text_styles, m.text_styles);
}

/// "Tin nhắn tự xóa": the wire `ttl` (ms) is kept on the message and through the store.
#[test]
fn ttl_parse_and_round_trip() {
    let (m, _) = msg_of(parse(
        r#"{"msgId":"8701","msgType":"webchat","uidFrom":"peer","idTo":"me","ts":"1000","ttl":86400000,"content":"hẹn"}"#,
        "me",
    ));
    assert_eq!(m.ttl_ms, 86_400_000);
    let decoded = decode_stored_message(&encode_chat_message(&m, "").unwrap()).unwrap();
    assert_eq!(decoded.ttl_ms, 86_400_000);
    let (plain, _) = msg_of(parse(
        r#"{"msgId":"8702","msgType":"webchat","uidFrom":"peer","idTo":"me","ts":"1","ttl":0,"content":"x"}"#,
        "me",
    ));
    assert_eq!(plain.ttl_ms, 0);
}

/// "Quan trọng" / "Khẩn cấp": `metaData.urgency` (object or JSON string) or a top-level `urgency`, kept through the store.
#[test]
fn urgency_parse_and_round_trip() {
    let (m, _) = msg_of(parse(
        r#"{"msgId":"8801","msgType":"webchat","uidFrom":"peer","idTo":"me","ts":"1","metaData":"{\"urgency\":2}","content":"gấp"}"#,
        "me",
    ));
    assert_eq!(m.urgency, 2);
    assert_eq!(
        decode_stored_message(&encode_chat_message(&m, "").unwrap())
            .unwrap()
            .urgency,
        2
    );
    let (n, _) = msg_of(parse(
        r#"{"msgId":"8802","msgType":"webchat","uidFrom":"peer","idTo":"me","ts":"1","urgency":1,"content":"x"}"#,
        "me",
    ));
    assert_eq!(n.urgency, 1);
    let (obj_meta, _) = msg_of(parse(
        r#"{"msgId":"8803","msgType":"webchat","uidFrom":"peer","idTo":"me","ts":"1","metaData":{"urgency":1},"content":"x"}"#,
        "me",
    ));
    assert_eq!(obj_meta.urgency, 1);
}

#[test]
fn quote_keeps_the_quoted_message_ids() {
    let (m, stored) = msg_of(parse(
        r#"{"msgId":"9","uidFrom":"peer","idTo":"100","msgType":"webchat","content":"ok","ts":1760000000000,
        "quote":{"ownerId":"peer","msg":"hello","fromD":"P","globalMsgId":8521991431452,"cliMsgId":"1795441030216"}}"#,
        "100",
    ));
    let q = m.quote.unwrap();
    assert_eq!(
        (q.msg_id.as_str(), q.cli_msg_id.as_str()),
        ("8521991431452", "1795441030216")
    );
    let back = crate::model::ChatMessage::from_json(
        serde_json::from_slice::<serde_json::Value>(&stored.raw_json_data)
            .unwrap()
            .as_object()
            .unwrap(),
        "",
    )
    .unwrap();
    assert_eq!(back.quote.unwrap().msg_id, "8521991431452");
}

#[test]
fn text_properties_json_matches_swift_send_jsonl_shapes() {
    // Empty styles produce None (plain messages omit textProperties).
    assert_eq!(TextStyle::text_properties_json(&[]), None);
    assert_eq!(crate::text_properties_json(&[]), None);

    // Exact shapes recorded in send.jsonl (`send_mentions_styles_urgency`):
    // keys sorted alphabetically at both top level (`styles`, `ver`) and entry level (`len`, `st`, `start`).
    let bold_at_12 = vec![TextStyle {
        start: 12,
        len: 5,
        st: "b".to_owned(),
    }];
    assert_eq!(
        crate::text_properties_json(&bold_at_12).as_deref(),
        Some(r#"{"styles":[{"len":5,"st":"b","start":12}],"ver":0}"#)
    );

    let italic_at_0 = vec![TextStyle {
        start: 0,
        len: 6,
        st: "i".to_owned(),
    }];
    assert_eq!(
        TextStyle::text_properties_json(&italic_at_0).as_deref(),
        Some(r#"{"styles":[{"len":6,"st":"i","start":0}],"ver":0}"#)
    );

    // Multiple styled runs preserve array order and composite tokens.
    let multi = vec![
        TextStyle {
            start: 0,
            len: 4,
            st: "b,i,c_db342e".to_owned(),
        },
        TextStyle {
            start: 5,
            len: 10,
            st: "lst_1,f_18,ind_1".to_owned(),
        },
    ];
    let serialized = crate::text_properties_json(&multi).unwrap();
    assert_eq!(
        serialized,
        r#"{"styles":[{"len":4,"st":"b,i,c_db342e","start":0},{"len":10,"st":"lst_1,f_18,ind_1","start":5}],"ver":0}"#
    );

    // Round-trips back through TextStyle::list on the parsed `styles` array.
    let parsed: Value = serde_json::from_str(&serialized).unwrap();
    assert_eq!(parsed["ver"], 0);
    assert_eq!(TextStyle::list(parsed.get("styles")), multi);
}

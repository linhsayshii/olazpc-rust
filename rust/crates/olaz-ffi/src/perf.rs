//! Wall-clock timings of the Rust hot paths (run: `cargo test --release -p olaz-ffi perf -- --ignored --nocapture`).
//! No assertions on speed; the tables in the Wave 4 notes quote these next to the Swift-side `RustCorePerf` suite.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::print_stdout)]

use std::sync::{Arc, Mutex};
use std::time::Instant;

use olaz_store::{Store, StoredConversation, StoredMessage};
use olaz_ws::WsEvent;
use serde_json::{Value, json};

use crate::chat::ChatMessageRecord;
use crate::wire::{WireEvent, WireOptions, parse_wire_batch};
use crate::ws::{WirePayload, WsEventRecord, WsListener};

fn wire_msg(i: usize) -> Value {
    json!({
        "msgId": format!("{}", 9_000_000_000_000_000_i64 + i as i64),
        "cliMsgId": format!("{}", 1_000_000 + i),
        "uidFrom": if i.is_multiple_of(2) { "u1" } else { "me" },
        "idTo": if i.is_multiple_of(2) { "me" } else { "u1" },
        "msgType": "webchat",
        "content": format!("Tin nhắn số {i} xin chào"),
        "ts": 1_795_000_000_000_i64 + (i as i64) * 1000
    })
}

#[derive(Default)]
struct Sink(Mutex<usize>);

impl WsListener for Sink {
    fn on_event(&self, _e: WsEventRecord) {}
    fn on_wire_events(
        &self,
        _cmd: u16,
        _sub: u8,
        _ver: u8,
        events: Vec<WireEvent>,
        _uids: Vec<String>,
        _payload: Arc<WirePayload>,
    ) {
        *self.0.lock().unwrap() += events.len();
    }
    fn on_cursors_changed(&self, _c: Vec<crate::ws::CursorEntry>) {}
    fn on_stopped(&self) {}
}

fn ms(t: Instant) -> f64 {
    t.elapsed().as_secs_f64() * 1000.0
}

#[test]
#[ignore = "timing"]
fn perf_rust_hot_paths() {
    let state = Arc::new(Mutex::new(crate::ws::test_parse_state("me")));
    let sink: Arc<dyn WsListener> = Arc::new(Sink::default());

    // (a) 2,000 realtime pushes, one message each: payload map -> typed events delivered to the listener.
    let events: Vec<WsEvent> = (0..2000)
        .map(|i| WsEvent {
            cmd: 501,
            sub_cmd: 0,
            version: 1,
            payload: json!({"data": {"msgs": [wire_msg(i)]}})
                .as_object()
                .unwrap()
                .clone(),
        })
        .collect();
    let t = Instant::now();
    for ev in events {
        crate::ws::deliver(ev, &sink, &state);
    }
    println!(
        "RUSTPERF (a) 2000 realtime events, typed deliver     : {:.1} ms",
        ms(t)
    );

    // (b) one history batch of 2,000 messages: JSON text in, typed events out.
    let msgs: Vec<Value> = (0..2000).map(wire_msg).collect();
    let json = serde_json::to_string(&json!({"data": {"msgs": msgs}})).unwrap();
    let t = Instant::now();
    let root = olaz_json::parse_any(json.as_bytes()).unwrap();
    println!(
        "RUSTPERF (b) .. json text -> Value                    : {:.1} ms",
        ms(t)
    );
    let t = Instant::now();
    let evs = olaz_wire::extract_batch_events(&root, "me", &olaz_wire::WireParseOptions::default());
    println!(
        "RUSTPERF (b) .. extract_batch_events ({})           : {:.1} ms",
        evs.len(),
        ms(t)
    );
    let t = Instant::now();
    let parsed = parse_wire_batch(json, "me".into(), WireOptions::default()).unwrap();
    println!(
        "RUSTPERF (b) 2000 history batch parse -> {} typed events: {:.1} ms",
        parsed.len(),
        ms(t)
    );

    // (c) save 2,000 rows (+ typed save), then load 50 per conversation.
    let rows: Vec<StoredMessage> = parsed
        .iter()
        .filter_map(|e| match e {
            WireEvent::Message { message, stored } => Some(StoredMessage {
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
                raw_json_data: stored.raw_json.clone(),
            }),
            _ => None,
        })
        .collect();
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(dir.path().join("p.db")).unwrap();
    let t = Instant::now();
    store.save_messages(&rows).unwrap();
    println!(
        "RUSTPERF (c) save 2000 rows (store only)             : {:.1} ms",
        ms(t)
    );
    let t = Instant::now();
    let loaded = store.messages("u1", None, 50).unwrap();
    println!(
        "RUSTPERF (c) load 50 rows (store only, {})           : {:.2} ms",
        loaded.len(),
        ms(t)
    );
    let records: Vec<ChatMessageRecord> = parsed
        .into_iter()
        .filter_map(|e| match e {
            WireEvent::Message { message, .. } => Some(message),
            _ => None,
        })
        .collect();
    let t_enc = Instant::now();
    let rows2: Vec<StoredMessage> = records
        .iter()
        .filter_map(|r| {
            olaz_wire::encode_chat_message(&olaz_wire::ChatMessage::from(r), "").map(|w| {
                StoredMessage {
                    id: w.id,
                    conv_id: w.conv_id,
                    client_id: w.client_id,
                    sender_id: w.sender_id,
                    sender_name: w.sender_name,
                    sender_avatar: w.sender_avatar,
                    is_mine: w.is_mine,
                    text: w.text,
                    kind_tag: w.kind_tag,
                    ts_ms: w.ts_ms,
                    status: w.status,
                    raw_json_data: w.raw_json_data,
                }
            })
        })
        .collect();
    println!(
        "RUSTPERF (c) typed re-encode of {} records (save-typed cost): {:.1} ms",
        rows2.len(),
        ms(t_enc)
    );

    // (d) 700 conversations.
    let convs: Vec<StoredConversation> = (0..700)
        .map(|i| StoredConversation {
            id: format!("conv{i}"),
            is_group: i % 3 == 0,
            name: format!("Hội thoại {i}"),
            avatar: format!("https://cdn.example/{i}.jpg"),
            pinned: i % 50 == 0,
            members: i,
            unread: i % 5,
            preview_text: format!("Tin cuối cùng của {i}"),
            preview_ts_ms: 1_795_000_000_000 + i,
            preview_from_me: i % 2 == 0,
            updated_at_ms: 1_795_000_000_000 + i,
        })
        .collect();
    store.save_conversations(&convs).unwrap();
    let t = Instant::now();
    let list = store.load_conversations().unwrap();
    println!(
        "RUSTPERF (d) load {} conversations (store only)    : {:.2} ms",
        list.len(),
        ms(t)
    );
}

/// Long loop for `sample`/Instruments: `OLAZ_PERF_LOOPS=300 cargo test --release -p olaz-ffi perf_loop -- --ignored`.
#[test]
#[ignore = "profiling"]
fn perf_loop() {
    let loops: usize = std::env::var("OLAZ_PERF_LOOPS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let msgs: Vec<Value> = (0..2000).map(wire_msg).collect();
    let json = serde_json::to_string(&json!({"data": {"msgs": msgs}})).unwrap();
    for _ in 0..loops {
        let r = parse_wire_batch(json.clone(), "me".into(), WireOptions::default()).unwrap();
        std::hint::black_box(r);
    }
}

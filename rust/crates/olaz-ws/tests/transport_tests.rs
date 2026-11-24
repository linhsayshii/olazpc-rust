#![cfg(feature = "transport")]
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::result_large_err)]
//! Integration tests for the live transport against a local tokio-tungstenite server
//! on 127.0.0.1 (no internet). Real `CryptoDecryptor`, `encrypt = 0` frames.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use olaz_ws::consts::*;
use olaz_ws::frame::{decode_frame, encode_frame_json};
use olaz_ws::*;
use serde_json::{Map, Value, json};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio::time::{Instant, timeout};
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;

const T: Duration = Duration::from_secs(5);

fn obj(v: Value) -> Map<String, Value> {
    match v {
        Value::Object(m) => m,
        _ => panic!("not an object"),
    }
}

struct Conn {
    ws: WebSocketStream<tokio::net::TcpStream>,
    uri: String,
    headers: Vec<(String, String)>,
    patience: Duration,
}

impl Conn {
    /// Next binary frame from the client (skips control frames).
    async fn recv_frame(&mut self) -> Frame {
        loop {
            match timeout(self.patience, self.ws.next())
                .await
                .expect("recv timeout")
            {
                Some(Ok(Message::Binary(b))) => return decode_frame(&b).unwrap(),
                Some(Ok(Message::Close(_))) | None => panic!("closed while expecting a frame"),
                Some(Ok(_)) => {}
                Some(Err(e)) => panic!("ws error {e}"),
            }
        }
    }

    /// Waits for the client's Close frame and returns its code.
    async fn recv_close_code(&mut self) -> Option<u16> {
        loop {
            match timeout(T, self.ws.next()).await.expect("close timeout") {
                Some(Ok(Message::Close(f))) => return f.map(|f| u16::from(f.code)),
                Some(Ok(_)) => {}
                Some(Err(_)) | None => return None,
            }
        }
    }

    async fn send(&mut self, cmd: u16, sub: u8, env: Value) {
        let bytes = encode_frame_json(cmd, sub, 1, Some(&obj(env)));
        self.ws.send(Message::Binary(bytes.into())).await.unwrap();
    }

    async fn send_auth(&mut self, error_code: i64, qcmds: Value) {
        let auth = json!({"error_code": error_code, "data": {"qCmds": qcmds}});
        self.send(
            CMD_AUTHEN,
            0,
            json!({"encrypt": 0, "key": "AAEC", "data": auth.to_string()}),
        )
        .await;
    }

    /// Auth ok with queue 510/1, then consume the initial pull frame.
    async fn auth_ok(&mut self) {
        self.send_auth(0, json!([{"cmd": 510, "subCmd": 1}])).await;
        let pull = self.recv_frame().await;
        assert_eq!((pull.cmd, pull.sub_cmd), (510, 1));
    }
}

struct Server {
    addr: String,
    conns: mpsc::Receiver<Conn>,
}

impl Server {
    async fn start() -> Server {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = format!("ws://{}", listener.local_addr().unwrap());
        let (tx, rx) = mpsc::channel(8);
        tokio::spawn(async move {
            while let Ok((sock, _)) = listener.accept().await {
                let seen = Arc::new(Mutex::new((String::new(), Vec::new())));
                let seen2 = seen.clone();
                let cb = move |req: &Request, resp: Response| {
                    let headers = req
                        .headers()
                        .iter()
                        .map(|(k, v)| (k.to_string(), v.to_str().unwrap_or("").to_owned()))
                        .collect();
                    *seen2.lock().unwrap() = (req.uri().to_string(), headers);
                    Ok(resp)
                };
                if let Ok(ws) = tokio_tungstenite::accept_hdr_async(sock, cb).await {
                    let (uri, headers) = seen.lock().unwrap().clone();
                    let _ = tx
                        .send(Conn {
                            ws,
                            uri,
                            headers,
                            patience: T,
                        })
                        .await;
                }
            }
        });
        Server { addr, conns: rx }
    }

    async fn accept(&mut self) -> Conn {
        timeout(T, self.conns.recv())
            .await
            .expect("accept timeout")
            .expect("server gone")
    }
}

fn fast() -> WsTimings {
    WsTimings {
        ping_interval: Duration::from_millis(100),
        request_timeout: Duration::from_millis(150),
        file_timeout: Duration::from_millis(150),
        connect_timeout: Duration::from_secs(5),
        backoff_initial: Duration::from_millis(50),
        backoff_max: Duration::from_millis(400),
        stable_session: Duration::from_secs(30),
    }
}

fn start(endpoints: Vec<String>, timings: WsTimings) -> (WsHandle, mpsc::Receiver<WsEvent>) {
    let mut cfg = WsConfig::new(endpoints, "SEKVALUE");
    cfg.timings = timings;
    WsClient::start(cfg, Arc::new(CryptoDecryptor))
}

async fn next_event(rx: &mut mpsc::Receiver<WsEvent>) -> WsEvent {
    timeout(T, rx.recv())
        .await
        .expect("event timeout")
        .expect("event stream ended")
}

#[tokio::test]
async fn connect_sends_handshake_and_surfaces_auth_event() {
    let mut srv = Server::start().await;
    let (h, mut ev) = start(vec![srv.addr.clone()], fast());
    let mut c = srv.accept().await;

    assert!(c.uri.contains("zpw_ver=694&zpw_type=23&t="), "{}", c.uri);
    let hdr = |n: &str| {
        c.headers
            .iter()
            .find(|(k, _)| k == n)
            .map(|(_, v)| v.clone())
            .unwrap_or_default()
    };
    assert_eq!(hdr("cookie"), "zpw_sek=SEKVALUE; _zlang=vi");
    assert_eq!(hdr("zpw_sek"), "SEKVALUE");
    assert_eq!(hdr("origin"), "file://");
    assert_eq!(hdr("user-agent"), "ZaloPC-darwin-23v694");

    assert!(!h.is_authed().await);
    assert!(!h.send_frame(CMD_PING, 1, None).await, "not authed yet");
    c.auth_ok().await;
    let e = next_event(&mut ev).await;
    assert_eq!(e.cmd, CMD_AUTHEN);
    assert_eq!(e.payload["error_code"], json!(0));
    assert!(h.is_authed().await);

    assert!(h.send_frame(777, 3, Some(b"{\"a\":1}".to_vec())).await);
    let f = c.recv_frame().await;
    assert_eq!(
        (f.cmd, f.sub_cmd, f.envelope["a"].clone()),
        (777, 3, json!(1))
    );
}

#[tokio::test]
async fn ping_cadence_uses_interval_after_auth() {
    let mut srv = Server::start().await;
    let (_h, mut ev) = start(vec![srv.addr.clone()], fast());
    let mut c = srv.accept().await;
    c.auth_ok().await;
    next_event(&mut ev).await;
    let t0 = Instant::now();
    let mut stamps = Vec::new();
    for _ in 0..3 {
        let f = c.recv_frame().await;
        assert_eq!((f.cmd, f.sub_cmd), (CMD_PING, SUB_KEEP_CONNECTION));
        assert!(f.envelope["eventId"].as_i64().unwrap() > 1_000_000_000_000);
        stamps.push(t0.elapsed());
    }
    // ~100 ms apart; the first one not before one interval (Swift sleeps first).
    assert!(stamps[0] >= Duration::from_millis(60), "{stamps:?}");
    assert!(
        stamps[2] - stamps[0] >= Duration::from_millis(150),
        "{stamps:?}"
    );
}

/// The default cadence is the Swift constant (15 s). A paused-clock socket test is not
/// possible: tokio auto-advances time while real loopback I/O is pending, which makes
/// handshakes and timers race, so cadence is tested with shrunk `WsTimings` instead.
#[test]
fn default_timings_match_swift() {
    let t = WsTimings::default();
    assert_eq!(t.ping_interval, Duration::from_secs(15));
    assert_eq!(t.request_timeout, Duration::from_secs(10));
    assert_eq!(t.file_timeout, Duration::from_secs(12));
    assert_eq!(t.backoff_initial, Duration::from_secs(2));
    assert_eq!(t.backoff_max, Duration::from_secs(30));
    assert_eq!(t.stable_session, Duration::from_secs(30));
}

#[tokio::test]
async fn request_response_by_req_id() {
    let mut srv = Server::start().await;
    let (h, _ev) = start(vec![srv.addr.clone()], fast());
    let mut c = srv.accept().await;
    c.auth_ok().await;
    // wait for authed state
    while !h.is_authed().await {
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    let h2 = h.clone();
    let req = tokio::spawn(async move {
        h2.send_request(612, 0, Some("rid_a".into()), obj(json!({"q": 1})))
            .await
    });
    let f = c.recv_frame().await;
    assert_eq!(f.cmd, 612);
    assert_eq!(f.envelope["reqId"], json!("rid_a"));
    assert_eq!(f.envelope["data"], json!({"q": 1}));
    // unrelated frame first, then the reply
    c.send(601, 0, json!({"encrypt": 0, "reqId": "other"}))
        .await;
    c.send(
        612,
        0,
        json!({"encrypt": 0, "reqId": "rid_a", "result": 42}),
    )
    .await;
    let resp = timeout(T, req).await.unwrap().unwrap().unwrap();
    assert_eq!(resp["result"], json!(42));

    // auto-generated ids follow the shared counter (req_1 was the initial pull)
    let h3 = h.clone();
    let auto = tokio::spawn(async move { h3.send_request(612, 0, None, Map::new()).await });
    let f = c.recv_frame().await;
    assert_eq!(f.envelope["reqId"], json!("req_2"));
    c.send(612, 0, json!({"encrypt": 0, "data": {"reqId": "req_2"}}))
        .await;
    assert!(timeout(T, auto).await.unwrap().unwrap().is_some());
}

#[tokio::test]
async fn request_times_out_and_late_reply_is_ignored() {
    let mut srv = Server::start().await;
    let (h, mut ev) = start(vec![srv.addr.clone()], fast());
    let mut c = srv.accept().await;
    // not authed: immediate None
    assert!(h.send_request(612, 0, None, Map::new()).await.is_none());
    c.auth_ok().await;
    next_event(&mut ev).await;

    let t0 = Instant::now();
    let r = h
        .send_request_with_timeout(
            612,
            0,
            Some("slow".into()),
            Map::new(),
            Duration::from_millis(120),
        )
        .await;
    assert!(r.is_none());
    assert!(t0.elapsed() >= Duration::from_millis(100));
    let _ = c.recv_frame().await;
    // late reply: surfaces as an ordinary event, resolves nothing
    c.send(612, 0, json!({"encrypt": 0, "reqId": "slow"})).await;
    let late = next_event(&mut ev).await;
    assert_eq!(late.cmd, 612);
}

#[tokio::test]
async fn file_done_wakes_waiters_and_caches() {
    let mut srv = Server::start().await;
    let (h, mut ev) = start(vec![srv.addr.clone()], fast());
    let mut c = srv.accept().await;
    c.auth_ok().await;
    next_event(&mut ev).await;

    let (a, b) = (h.clone(), h.clone());
    let w1 = tokio::spawn(async move {
        a.wait_for_file_done_with_timeout("F1", Duration::from_secs(5))
            .await
    });
    let w2 = tokio::spawn(async move {
        b.wait_for_file_done_with_timeout("F1", Duration::from_secs(5))
            .await
    });
    // make sure both waiters registered before the push
    tokio::time::sleep(Duration::from_millis(50)).await;
    c.send(
        CMD_CTRL_ACTION,
        0,
        json!({"encrypt": 0, "data": {"controls": [{"content": {
            "act_type": "file_done",
            "data": {"fileId": "F1", "url": "https://files.example/x"}}}]}}),
    )
    .await;
    for w in [w1, w2] {
        assert_eq!(
            timeout(T, w).await.unwrap().unwrap().as_deref(),
            Some("https://files.example/x")
        );
    }
    // already completed: returns at once
    assert_eq!(
        h.wait_for_file_done("F1").await.as_deref(),
        Some("https://files.example/x")
    );
    // empty id
    assert_eq!(h.wait_for_file_done("").await, None);
}

#[tokio::test]
async fn file_wait_times_out() {
    let mut srv = Server::start().await;
    let (h, _ev) = start(vec![srv.addr.clone()], fast());
    let _c = srv.accept().await;
    let t0 = Instant::now();
    assert_eq!(h.wait_for_file_done("nope").await, None);
    assert!(
        t0.elapsed() >= Duration::from_millis(120),
        "{:?}",
        t0.elapsed()
    );
}

#[tokio::test]
async fn server_close_reconnects_to_next_endpoint_with_backoff() {
    let mut a = Server::start().await;
    let mut b = Server::start().await;
    let (h, mut ev) = start(vec![a.addr.clone(), b.addr.clone()], fast());
    let mut ca = a.accept().await;
    ca.auth_ok().await;
    next_event(&mut ev).await;

    // pending request fails with None when the session drops
    let h2 = h.clone();
    let pending = tokio::spawn(async move {
        h2.send_request_with_timeout(612, 0, None, Map::new(), Duration::from_secs(5))
            .await
    });
    let _ = ca.recv_frame().await;
    let dropped = Instant::now();
    drop(ca);
    assert!(timeout(T, pending).await.unwrap().unwrap().is_none());

    // session was short: backoff = 2 * 50ms before endpoint B
    let mut cb = b.accept().await;
    assert!(
        dropped.elapsed() >= Duration::from_millis(90),
        "{:?}",
        dropped.elapsed()
    );
    cb.auth_ok().await;
    assert_eq!(next_event(&mut ev).await.cmd, CMD_AUTHEN);
    assert!(h.is_authed().await);

    // drop B too: backoff doubles (200ms) and rotation wraps back to A
    let dropped = Instant::now();
    drop(cb);
    let _ca2 = a.accept().await;
    assert!(
        dropped.elapsed() >= Duration::from_millis(180),
        "{:?}",
        dropped.elapsed()
    );
}

#[tokio::test]
async fn failed_connect_rotates_endpoint() {
    // first endpoint refuses connections (port closed), second works
    let dead = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let dead_addr = format!("ws://{}", dead.local_addr().unwrap());
    drop(dead);
    let mut live = Server::start().await;
    let (_h, mut ev) = start(vec![dead_addr, live.addr.clone()], fast());
    let mut c = live.accept().await;
    c.auth_ok().await;
    assert_eq!(next_event(&mut ev).await.cmd, CMD_AUTHEN);
}

#[tokio::test]
async fn auth_failure_closes_with_1008_then_reconnects() {
    let mut srv = Server::start().await;
    let (h, mut ev) = start(vec![srv.addr.clone()], fast());
    let mut c = srv.accept().await;
    c.send_auth(5, json!([])).await;
    let e = next_event(&mut ev).await;
    assert_eq!(e.cmd, CMD_AUTHEN);
    assert_eq!(e.payload["error_code"], json!(5));
    assert_eq!(
        c.recv_close_code().await,
        Some(u16::from(CloseCode::Policy))
    );
    assert!(!h.is_authed().await);
    // the loop keeps going: a fresh session arrives after the backoff
    let _c2 = srv.accept().await;
}

#[tokio::test]
async fn undecryptable_auth_closes_with_1008() {
    let mut srv = Server::start().await;
    let (_h, _ev) = start(vec![srv.addr.clone()], fast());
    let mut c = srv.accept().await;
    // encrypt=2 without a usable key -> decrypt error -> policy violation
    c.send(CMD_AUTHEN, 0, json!({"encrypt": 2, "data": "AAAA"}))
        .await;
    assert_eq!(c.recv_close_code().await, Some(1008));
}

#[tokio::test]
async fn stop_semantics_keep_or_reset_cursors() {
    for reset in [false, true] {
        let mut srv = Server::start().await;
        let mut cfg = WsConfig::new(vec![srv.addr.clone()], "SEK");
        cfg.timings = fast();
        cfg.seed_cursors = BTreeMap::from([
            (
                "510_1".to_string(),
                WsQueueCursorSnapshot {
                    last_id: "998877".into(),
                    pre_ids: vec!["12".into()],
                },
            ),
            // unusable seeds are ignored
            (
                "511_1".to_string(),
                WsQueueCursorSnapshot {
                    last_id: "1".into(),
                    pre_ids: vec![],
                },
            ),
        ]);
        let (h, mut ev) = WsClient::start(cfg, Arc::new(CryptoDecryptor));
        assert_eq!(h.current_cursors().await.len(), 1);
        let mut c = srv.accept().await;
        // initial pull resumes from the seed
        c.send_auth(0, json!([{"cmd": 510, "subCmd": 1}])).await;
        let pull = c.recv_frame().await;
        assert_eq!(pull.envelope["lastId"], json!(998877));
        next_event(&mut ev).await;

        let (hf, hr) = (h.clone(), h.clone());
        let file = tokio::spawn(async move {
            hf.wait_for_file_done_with_timeout("F", Duration::from_secs(30))
                .await
        });
        let req = tokio::spawn(async move {
            hr.send_request_with_timeout(612, 0, None, Map::new(), Duration::from_secs(30))
                .await
        });
        let _ = c.recv_frame().await;

        let left = h.stop(reset).await;
        assert_eq!(left.len(), usize::from(!reset), "reset={reset}");
        assert!(timeout(T, file).await.unwrap().unwrap().is_none());
        assert!(timeout(T, req).await.unwrap().unwrap().is_none());
        assert_eq!(c.recv_close_code().await, Some(1000));
        // event stream ends, handle degrades gracefully
        assert!(timeout(T, ev.recv()).await.unwrap().is_none());
        assert!(!h.send_frame(CMD_PING, 1, None).await);
        assert!(h.send_request(612, 0, None, Map::new()).await.is_none());
        assert_eq!(h.current_cursors().await.len(), usize::from(!reset));
        assert_eq!(h.watch_cursors().borrow().len(), usize::from(!reset));
    }
}

#[tokio::test]
async fn cursors_persist_through_observer_and_watch() {
    let mut srv = Server::start().await;
    let seen: Arc<Mutex<Vec<CursorMap>>> = Arc::default();
    let sink = seen.clone();
    let mut cfg = WsConfig::new(vec![srv.addr.clone()], "SEK");
    cfg.timings = fast();
    cfg.on_cursors_changed = Some(Arc::new(move |m: &CursorMap| {
        sink.lock().unwrap().push(m.clone());
    }));
    let (h, mut ev) = WsClient::start(cfg, Arc::new(CryptoDecryptor));
    let mut c = srv.accept().await;
    c.auth_ok().await;
    next_event(&mut ev).await;

    c.send(
        CMD_PULL_MSG_11,
        1,
        json!({"encrypt": 0, "data": {"lastActionId": 555, "queueStatus": {"510_1": {"ids": ["7"]}}}}),
    )
    .await;
    let e = next_event(&mut ev).await;
    assert_eq!(e.cmd, CMD_PULL_MSG_11);

    let want = BTreeMap::from([(
        "510_1".to_string(),
        WsQueueCursorSnapshot {
            last_id: "555".into(),
            pre_ids: vec!["7".into()],
        },
    )]);
    assert_eq!(seen.lock().unwrap().last(), Some(&want));
    assert_eq!(h.current_cursors().await, want);
    assert_eq!(*h.watch_cursors().borrow(), want);
}

#[tokio::test]
async fn has_msg_triggers_get_msg_and_more_pages_next_pull() {
    let mut srv = Server::start().await;
    let (_h, mut ev) = start(vec![srv.addr.clone()], fast());
    let mut c = srv.accept().await;
    c.auth_ok().await;
    next_event(&mut ev).await;
    c.send(
        CMD_HAS_MSG,
        0,
        json!({"encrypt": 0, "data": {"queueId": 9, "ids": [1, 2]}}),
    )
    .await;
    let f = c.recv_frame().await;
    assert_eq!(f.cmd, CMD_GET_MSG);
    assert_eq!(f.envelope["queueId"], json!(9));
}

#[tokio::test]
async fn dropping_every_handle_stops_the_task() {
    let mut srv = Server::start().await;
    let (h, mut ev) = start(vec![srv.addr.clone()], fast());
    let mut c = srv.accept().await;
    c.auth_ok().await;
    next_event(&mut ev).await;
    drop(h);
    assert_eq!(c.recv_close_code().await, Some(1000));
    assert!(timeout(T, ev.recv()).await.unwrap().is_none());
}

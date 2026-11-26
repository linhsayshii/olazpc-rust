#![allow(clippy::expect_used, clippy::unwrap_used)]
//! `ReqwestTransport` against a throwaway localhost socket (no external network).

use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::mpsc;
use std::time::Duration;

use olaz_net::{Method, NetError, NetworkErrorKind, RequestSpec, ReqwestTransport, Transport};

fn serve_once(response: &'static str) -> (String, mpsc::Receiver<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            let mut buf = [0u8; 8192];
            let n = stream.read(&mut buf).unwrap_or(0);
            let _ = tx.send(String::from_utf8_lossy(&buf[..n]).into_owned());
            let _ = stream.write_all(response.as_bytes());
        }
    });
    (format!("http://{addr}"), rx)
}

fn spec(url: String, method: Method, body: Option<Vec<u8>>) -> RequestSpec {
    RequestSpec {
        method,
        url,
        query: Vec::new(),
        headers: vec![
            ("User-Agent".to_owned(), "ZaloPC-darwin-23v694".to_owned()),
            ("Cookie".to_owned(), "zpw_sek=a.b".to_owned()),
            (
                "Content-Type".to_owned(),
                "application/x-www-form-urlencoded".to_owned(),
            ),
        ],
        body,
        timeout: Some(Duration::from_secs(5)),
    }
}

#[tokio::test]
async fn sends_headers_and_body_and_keeps_duplicate_set_cookie() {
    let (base, rx) = serve_once(
        "HTTP/1.1 503 Service Unavailable\r\nSet-Cookie: zpw_sek=one.1.2; Path=/\r\nSet-Cookie: x=y\r\nContent-Length: 4\r\nConnection: close\r\n\r\nbusy",
    );
    let t = ReqwestTransport::new().unwrap();
    let resp = t
        .send(spec(
            format!("{base}/api/x?zpw_ver=694"),
            Method::Post,
            Some(b"params=abc".to_vec()),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status, 503);
    assert_eq!(resp.body, b"busy");
    let cookies: Vec<&str> = resp
        .headers
        .iter()
        .filter(|(k, _)| k.eq_ignore_ascii_case("set-cookie"))
        .map(|(_, v)| v.as_str())
        .collect();
    assert_eq!(cookies, ["zpw_sek=one.1.2; Path=/", "x=y"]);

    let raw = rx
        .recv_timeout(Duration::from_secs(5))
        .unwrap()
        .to_lowercase();
    assert!(raw.starts_with("post /api/x?zpw_ver=694 http/1.1"), "{raw}");
    assert!(raw.contains("user-agent: zalopc-darwin-23v694"));
    assert!(raw.contains("cookie: zpw_sek=a.b"));
    assert!(raw.contains("content-type: application/x-www-form-urlencoded"));
    assert!(raw.ends_with("params=abc"));
}

#[tokio::test]
async fn slow_server_maps_to_timeout_and_closed_port_to_network_error() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let t = ReqwestTransport::new().unwrap();
    let mut slow = spec(format!("http://{addr}/slow"), Method::Get, None);
    slow.timeout = Some(Duration::from_millis(200));
    let err = t.send(slow).await.unwrap_err();
    assert!(
        matches!(
            err,
            NetError::Network {
                kind: NetworkErrorKind::Timeout,
                ..
            }
        ),
        "{err:?}"
    );
    assert!(err.should_failover());
    drop(listener);

    let err = t
        .send(spec(format!("http://{addr}/closed"), Method::Get, None))
        .await
        .unwrap_err();
    assert!(matches!(err, NetError::Network { .. }), "{err:?}");
    // The error text must not leak the URL (it can carry signed params).
    assert!(!err.to_string().contains("/closed"), "{err}");
}

/// Serves one 200 answer whose body arrives in `pieces`, `gap` apart. `announced` is the
/// `Content-Length`; when it exceeds what is sent the socket then stays silent for 3 s.
fn serve_trickle(pieces: Vec<&'static str>, gap: Duration, announced: usize) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    std::thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            let mut buf = [0u8; 4096];
            let _ = stream.read(&mut buf);
            let head = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {announced}\r\nConnection: close\r\n\r\n"
            );
            let _ = stream.write_all(head.as_bytes());
            let mut sent = 0;
            for p in pieces {
                std::thread::sleep(gap);
                let _ = stream.write_all(p.as_bytes());
                let _ = stream.flush();
                sent += p.len();
            }
            if sent < announced {
                std::thread::sleep(Duration::from_secs(3));
            }
        }
    });
    format!("http://{addr}")
}

/// The timeout is an inactivity timer (Swift `timeoutIntervalForRequest`), not a total deadline:
/// a body that keeps trickling in must outlive it.
#[tokio::test]
async fn timeout_is_inactivity_not_total() {
    let base = serve_trickle(
        vec!["aaaa", "bbbb", "cccc", "dddd"],
        Duration::from_millis(150),
        16,
    );
    let t = ReqwestTransport::new().unwrap();
    let mut s = spec(format!("{base}/trickle"), Method::Get, None);
    // 4 x 150 ms = 600 ms in total, but never silent for more than ~150 ms.
    s.timeout = Some(Duration::from_millis(400));
    let resp = t.send(s).await.unwrap();
    assert_eq!(resp.status, 200);
    assert_eq!(resp.body, b"aaaabbbbccccdddd");
}

/// A server that goes silent mid-body times out (`URLError.timedOut`).
#[tokio::test]
async fn silence_mid_body_times_out() {
    let base = serve_trickle(vec!["abcd"], Duration::from_millis(10), 100);
    let t = ReqwestTransport::new().unwrap();
    let mut s = spec(format!("{base}/stall"), Method::Get, None);
    s.timeout = Some(Duration::from_millis(300));
    let started = std::time::Instant::now();
    let err = t.send(s).await.unwrap_err();
    assert!(
        matches!(
            err,
            NetError::Network {
                kind: NetworkErrorKind::Timeout,
                ..
            }
        ),
        "{err:?}"
    );
    assert!(started.elapsed() < Duration::from_secs(2));
}

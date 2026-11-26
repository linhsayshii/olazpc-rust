#![allow(clippy::unwrap_used, clippy::expect_used)]
//! FFI-level media tests against a local socket server (no real network).

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use crate::media::*;

struct TestServer {
    port: u16,
    hits: Arc<AtomicUsize>,
    client_closed: Arc<AtomicBool>,
}

/// `hang`: never answer, record when the client closes the connection.
async fn server(body: &'static [u8], hang: bool) -> TestServer {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let hits = Arc::new(AtomicUsize::new(0));
    let client_closed = Arc::new(AtomicBool::new(false));
    let (h, c) = (Arc::clone(&hits), Arc::clone(&client_closed));
    tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                return;
            };
            let (h, c) = (Arc::clone(&h), Arc::clone(&c));
            tokio::spawn(async move {
                let mut buf = [0_u8; 2048];
                if stream.read(&mut buf).await.unwrap_or(0) == 0 {
                    return;
                }
                h.fetch_add(1, Ordering::SeqCst);
                if hang {
                    // Wait for the client to go away.
                    while stream.read(&mut buf).await.unwrap_or(0) > 0 {}
                    c.store(true, Ordering::SeqCst);
                    return;
                }
                let head = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", body.len());
                let _ = stream.write_all(head.as_bytes()).await;
                let _ = stream.write_all(body).await;
            });
        }
    });
    TestServer {
        port,
        hits,
        client_closed,
    }
}

fn media(dir: &std::path::Path) -> Arc<CoreMedia> {
    CoreMedia::new(
        MediaCoreOptions {
            preferred_languages: vec!["vi".to_owned()],
            files_dir: dir.join("files").to_string_lossy().into_owned(),
            files_cache_limit: 1 << 30,
            max_concurrent: 6,
            allow_plain_http: true,
            doh_endpoints: None,
            file_idle_secs: 30.0,
            image_idle_secs: 10.0,
        },
        None,
    )
}

fn data_req(port: u16, path: &str) -> MediaDataRequest {
    let url = format!("http://127.0.0.1:{port}{path}");
    MediaDataRequest {
        url: url.clone(),
        fallback_url: None,
        secure: None,
        key_seed: url,
        deadline_secs: 20.0,
    }
}

#[tokio::test]
async fn data_roundtrip_and_error_mapping() {
    let s = server(b"ffi-bytes", false).await;
    let dir = tempfile::tempdir().unwrap();
    let m = media(dir.path());
    let bytes = m
        .data(data_req(s.port, "/a"), MediaCancel::new())
        .await
        .unwrap();
    assert_eq!(bytes, b"ffi-bytes");
    let bad = MediaDataRequest {
        url: "nope".to_owned(),
        ..data_req(s.port, "/a")
    };
    assert_eq!(
        m.data(bad, MediaCancel::new()).await.unwrap_err(),
        MediaCoreError::BadUrl
    );
}

#[tokio::test]
async fn cancel_returns_promptly_and_closes_the_connection() {
    let s = server(b"", true).await;
    let dir = tempfile::tempdir().unwrap();
    let m = media(dir.path());
    let cancel = MediaCancel::new();
    let canceller = Arc::clone(&cancel);
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(250)).await;
        canceller.cancel();
    });
    let started = Instant::now();
    let err = m.data(data_req(s.port, "/hang"), cancel).await.unwrap_err();
    assert_eq!(err, MediaCoreError::Cancelled);
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "{:?}",
        started.elapsed()
    );
    assert_eq!(s.hits.load(Ordering::SeqCst), 1);
    // The transfer was really aborted: the server sees the connection close.
    for _ in 0..100 {
        if s.client_closed.load(Ordering::SeqCst) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(
        s.client_closed.load(Ordering::SeqCst),
        "client connection must be closed after cancel"
    );
}

#[tokio::test]
async fn cancel_before_the_call_cancels_immediately() {
    let s = server(b"x", false).await;
    let dir = tempfile::tempdir().unwrap();
    let m = media(dir.path());
    let cancel = MediaCancel::new();
    cancel.cancel();
    // The flag is sticky: a call started after cancel() is cancelled too.
    let r = m.data(data_req(s.port, "/late"), cancel).await;
    assert_eq!(r.unwrap_err(), MediaCoreError::Cancelled);
}

#[tokio::test]
async fn local_file_and_download_to_report_failures_with_official_codes() {
    let s = server(b"file-body", false).await;
    let dir = tempfile::tempdir().unwrap();
    let m = media(dir.path());
    let name = media_cached_file_name("seed".to_owned(), "txt".to_owned());
    let req = MediaFileRequest {
        url: format!("http://127.0.0.1:{}/f.txt", s.port),
        fallback_url: None,
        file_name: name.clone(),
        secure: None,
        origin_url: "origin".to_owned(),
    };
    let path = m
        .local_file(req.clone(), None, MediaCancel::new())
        .await
        .unwrap();
    assert!(path.ends_with(&name));
    assert_eq!(std::fs::read(&path).unwrap(), b"file-body");
    m.evict(name);
    assert!(!std::path::Path::new(&path).exists());
    let outcome = m
        .download_to(
            MediaDownloadRequest {
                source: MediaDownloadSource::Cached { request: req },
                secure: MediaSecureChoice::Invalid,
                temp_dir: dir.path().join("t").to_string_lossy().into_owned(),
            },
            None,
            MediaCancel::new(),
        )
        .await;
    assert_eq!(outcome.failure.unwrap().code, 14_998);
    assert!(outcome.staged_path.is_none());
}

#[test]
fn pure_helpers_match_the_swift_definitions() {
    assert_eq!(media_stable_hash("a".to_owned()), "af63dc4c8601ec8c");
    assert_eq!(
        media_cached_file_name("a".to_owned(), "png".to_owned()),
        "af63dc4c8601ec8c.png"
    );
    assert!(media_is_zalo_cdn("res-zalo.zadn.vn".to_owned()));
    assert!(!media_is_zalo_cdn("zadn.vn.evil.com".to_owned()));
    let enc = media_encrypt_e2ee_file(b"abc".to_vec(), vec![1; 32], vec![2; 12]).unwrap();
    assert_eq!(enc.token.len(), 60);
    assert!(media_encrypt_e2ee_file(vec![], vec![1; 31], vec![2; 12]).is_err());
}

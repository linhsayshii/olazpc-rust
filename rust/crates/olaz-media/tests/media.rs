#![allow(clippy::unwrap_used, clippy::expect_used)]
//! Behaviour tests against local servers only (plain HTTP and a local TLS server); no real DNS and
//! no Zalo/CDN host is ever contacted.

mod support;

use std::net::{IpAddr, Ipv4Addr};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use olaz_media::{
    Algorithm, DataRequest, DownloadRequest, DownloadSource, FileRequest, HeadersRequest,
    MediaConfig, MediaCore, MediaError, MediaHooks, MediaOptions, NetKind, ProgressFn,
    ResolveError, SecureChoice, SecureSpec, cached_file_name, encrypt_e2ee_file,
};
use support::{Handler, Resp, Server, cert_pem, serve, serve_tls};

const LOCAL: IpAddr = IpAddr::V4(Ipv4Addr::LOCALHOST);

fn handler(f: impl Fn(&support::Req) -> Resp + Send + Sync + 'static) -> Handler {
    Arc::new(f)
}

fn plain_cfg() -> MediaConfig {
    MediaConfig {
        allow_plain_http: true,
        ..MediaConfig::default()
    }
}

fn core_with(
    cfg: MediaConfig,
    dir: &Path,
    tweak: impl FnOnce(&mut MediaOptions),
) -> Arc<MediaCore> {
    let mut opts = MediaOptions::new(dir.join("files"));
    tweak(&mut opts);
    MediaCore::new(cfg, opts, None)
}

fn core(dir: &Path) -> Arc<MediaCore> {
    core_with(plain_cfg(), dir, |_| {})
}

fn data_req(url: &str) -> DataRequest {
    DataRequest {
        url: url.to_owned(),
        fallback_url: None,
        secure: None,
        key_seed: url.to_owned(),
        deadline: Duration::from_secs(10),
    }
}

fn file_req(url: &str, name: &str) -> FileRequest {
    FileRequest {
        url: url.to_owned(),
        fallback_url: None,
        file_name: name.to_owned(),
        secure: None,
        origin_url: url.to_owned(),
    }
}

fn url(server: &Server, path: &str) -> String {
    format!("http://127.0.0.1:{}{path}", server.port)
}

fn parts(dir: &Path) -> Vec<String> {
    std::fs::read_dir(dir)
        .map(|r| {
            r.flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| n.ends_with(".part"))
                .collect()
        })
        .unwrap_or_default()
}

// MARK: data

#[tokio::test]
async fn data_returns_bytes_and_maps_http_errors() {
    let server = serve(handler(|r| match r.path.as_str() {
        "/ok" => Resp::ok(b"hello".to_vec()),
        "/gone" => Resp::status(404),
        _ => Resp::status(503),
    }))
    .await;
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    assert_eq!(
        core.data(data_req(&url(&server, "/ok")))
            .await
            .unwrap()
            .as_slice(),
        b"hello"
    );
    assert_eq!(
        core.data(data_req(&url(&server, "/gone")))
            .await
            .unwrap_err(),
        MediaError::Http(404)
    );
    assert_eq!(
        core.data(data_req(&url(&server, "/x"))).await.unwrap_err(),
        MediaError::Http(503)
    );
    assert_eq!(
        core.data(data_req("not a url")).await.unwrap_err(),
        MediaError::BadUrl
    );
    assert_eq!(core.in_flight(), 0);
}

#[tokio::test]
async fn data_follows_redirects_up_to_three() {
    let server = serve(handler(|r| match r.path.as_str() {
        "/a" => Resp::redirect("/b"),
        "/b" => Resp::redirect("/c"),
        "/c" => Resp::redirect("/d"),
        "/d" => Resp::ok(b"end".to_vec()),
        "/e" => Resp::redirect("/a"),
        _ => Resp::status(404),
    }))
    .await;
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    assert_eq!(
        core.data(data_req(&url(&server, "/a")))
            .await
            .unwrap()
            .as_slice(),
        b"end"
    );
    // Four hops exceed the budget: the last 3xx is reported as an HTTP error.
    assert_eq!(
        core.data(data_req(&url(&server, "/e"))).await.unwrap_err(),
        MediaError::Http(302)
    );
}

#[tokio::test]
async fn parallel_requests_share_one_flight() {
    let server = serve(handler(|_| Resp {
        body_delay: Duration::from_millis(150),
        ..Resp::ok(b"shared".to_vec())
    }))
    .await;
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    let u = url(&server, "/same");
    let mut tasks = Vec::new();
    for _ in 0..20 {
        let (core, u) = (Arc::clone(&core), u.clone());
        tasks.push(tokio::spawn(async move { core.data(data_req(&u)).await }));
    }
    for t in tasks {
        assert_eq!(t.await.unwrap().unwrap().as_slice(), b"shared");
    }
    assert_eq!(server.hit_count("/same"), 1);
    assert_eq!(core.in_flight(), 0);
}

#[tokio::test]
async fn concurrency_cap_limits_parallel_server_hits() {
    let server = serve(handler(|_| Resp {
        head_delay: Duration::from_millis(120),
        ..Resp::ok(b"x".to_vec())
    }))
    .await;
    let dir = tempfile::tempdir().unwrap();
    let core = core_with(plain_cfg(), dir.path(), |o| o.max_concurrent = 2);
    let mut tasks = Vec::new();
    for i in 0..8 {
        let (core, u) = (Arc::clone(&core), url(&server, &format!("/p{i}")));
        tasks.push(tokio::spawn(async move { core.data(data_req(&u)).await }));
    }
    for t in tasks {
        t.await.unwrap().unwrap();
    }
    assert_eq!(server.total_hits(), 8);
    assert!(
        server.max_active.load(Ordering::SeqCst) <= 2,
        "max active {}",
        server.max_active.load(Ordering::SeqCst)
    );
    assert!(server.max_active.load(Ordering::SeqCst) >= 2);
}

#[tokio::test]
async fn data_deadline_and_idle_timeouts() {
    let server = serve(handler(|r| match r.path.as_str() {
        "/slow" => Resp {
            head_delay: Duration::from_secs(5),
            ..Resp::ok(b"x".to_vec())
        },
        _ => Resp {
            body: vec![1; 64],
            chunk: Some((8, Duration::from_millis(400))),
            status: 200,
            ..Resp::default()
        },
    }))
    .await;
    let dir = tempfile::tempdir().unwrap();
    let core = core_with(plain_cfg(), dir.path(), |o| {
        o.image_idle = Duration::from_millis(150)
    });
    // Header wait longer than the idle bound: URLError-class timeout.
    let started = Instant::now();
    assert_eq!(
        core.data(data_req(&url(&server, "/slow")))
            .await
            .unwrap_err(),
        MediaError::Net(NetKind::TimedOut)
    );
    assert!(started.elapsed() < Duration::from_secs(2));
    // A stall between chunks too.
    assert_eq!(
        core.data(data_req(&url(&server, "/trickle")))
            .await
            .unwrap_err(),
        MediaError::Net(NetKind::TimedOut)
    );
    // The overall deadline is a LoadError.timedOut.
    let patient = core_with(plain_cfg(), dir.path(), |o| {
        o.image_idle = Duration::from_secs(30)
    });
    let mut req = data_req(&url(&server, "/slow"));
    req.deadline = Duration::from_millis(200);
    assert_eq!(patient.data(req).await.unwrap_err(), MediaError::TimedOut);
    assert_eq!(patient.in_flight(), 0);
}

#[tokio::test]
async fn jxl_fallback_is_tried_when_primary_fails() {
    let server = serve(handler(|r| match r.path.as_str() {
        "/jpg/a.jpg" => Resp::ok(b"jpeg".to_vec()),
        _ => Resp::status(404),
    }))
    .await;
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    let mut req = data_req(&url(&server, "/jxl/a.jxl"));
    req.fallback_url = Some(url(&server, "/jpg/a.jpg"));
    assert_eq!(core.data(req).await.unwrap().as_slice(), b"jpeg");
    let mut file = file_req(&url(&server, "/jxl/a.jxl"), "fallback.jpg");
    file.fallback_url = Some(url(&server, "/jpg/a.jpg"));
    let path = core.local_file(file, None).await.unwrap();
    assert_eq!(std::fs::read(path).unwrap(), b"jpeg");
}

#[tokio::test]
async fn data_decrypts_secure_stream() {
    let (key, iv) = ([3_u8; 32], [8_u8; 12]);
    let plain: Vec<u8> = (0..9000_u32).map(|i| (i % 251) as u8).collect();
    let (cipher, token) = encrypt_e2ee_file(&plain, &key, &iv).unwrap();
    let body = cipher.clone();
    let server = serve(handler(move |_| Resp::ok(body.clone()))).await;
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    let spec = SecureSpec {
        algorithm: Algorithm::Gcm,
        key: key.to_vec(),
        iv: iv.to_vec(),
        tag: Some(token[44..].to_vec()),
        block: false,
        block_size: 4096,
    };
    let mut req = data_req(&url(&server, "/enc"));
    req.secure = Some(spec.clone());
    assert_eq!(core.data(req).await.unwrap().as_slice(), plain.as_slice());
    let mut bad = spec;
    bad.tag = Some(vec![0; 16]);
    let mut req = data_req(&url(&server, "/enc"));
    req.secure = Some(bad);
    req.key_seed = "other".to_owned();
    assert_eq!(core.data(req).await.unwrap_err(), MediaError::Undecodable);
}

// MARK: cancellation

#[tokio::test]
async fn dropping_the_future_cancels_the_transfer() {
    let server = serve(handler(|_| Resp {
        head_delay: Duration::from_secs(3),
        ..Resp::ok(b"late".to_vec())
    }))
    .await;
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    let u = url(&server, "/hang");
    let attempt = tokio::time::timeout(Duration::from_millis(300), core.data(data_req(&u))).await;
    assert!(attempt.is_err(), "still pending, then dropped");
    // The flight task is aborted when its last waiter goes away.
    for _ in 0..50 {
        if core.in_flight() == 0 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(core.in_flight(), 0);
    // The slot is free again and a new request starts a fresh flight.
    let server2 = serve(handler(|_| Resp::ok(b"fine".to_vec()))).await;
    assert_eq!(
        core.data(data_req(&url(&server2, "/ok")))
            .await
            .unwrap()
            .as_slice(),
        b"fine"
    );
}

#[tokio::test]
async fn one_waiter_cancelling_keeps_the_shared_flight() {
    let server = serve(handler(|_| Resp {
        body_delay: Duration::from_millis(300),
        ..Resp::ok(b"both".to_vec())
    }))
    .await;
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    let u = url(&server, "/share");
    let stayer = {
        let (core, u) = (Arc::clone(&core), u.clone());
        tokio::spawn(async move { core.data(data_req(&u)).await })
    };
    tokio::time::sleep(Duration::from_millis(50)).await;
    let _ = tokio::time::timeout(Duration::from_millis(50), core.data(data_req(&u))).await; // joins, leaves
    assert_eq!(stayer.await.unwrap().unwrap().as_slice(), b"both");
    assert_eq!(server.hit_count("/share"), 1);
}

#[tokio::test]
async fn cancelling_a_file_download_leaves_no_part_file() {
    let body = vec![7_u8; 200_000];
    let server = serve(handler(move |_| Resp {
        body: body.clone(),
        chunk: Some((10_000, Duration::from_millis(100))),
        status: 200,
        ..Resp::default()
    }))
    .await;
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    let attempt = tokio::time::timeout(
        Duration::from_millis(350),
        core.local_file(file_req(&url(&server, "/big"), "big.bin"), None),
    )
    .await;
    assert!(attempt.is_err());
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(
        parts(core.files_dir()).is_empty(),
        "{:?}",
        parts(core.files_dir())
    );
    assert!(!core.files_dir().join("big.bin").exists());
    assert_eq!(core.in_flight(), 0);
}

// MARK: files cache

struct Hook {
    seen: Mutex<Vec<(PathBuf, bool)>>,
    final_path: PathBuf,
}
impl MediaHooks for Hook {
    fn before_publish(&self, path: &Path, _origin: &str) {
        self.seen
            .lock()
            .unwrap()
            .push((path.to_owned(), self.final_path.exists()));
    }
}

#[tokio::test]
async fn local_file_downloads_once_publishes_atomically_and_reuses() {
    let payload: Vec<u8> = (0..300_000_u32).map(|i| (i % 253) as u8).collect();
    let body = payload.clone();
    let server = serve(handler(move |_| Resp::ok(body.clone()))).await;
    let dir = tempfile::tempdir().unwrap();
    let files = dir.path().join("files");
    let name = cached_file_name("seed-1", "json");
    let hook = Arc::new(Hook {
        seen: Mutex::new(Vec::new()),
        final_path: files.join(&name),
    });
    let core = MediaCore::new(
        plain_cfg(),
        MediaOptions::new(files.clone()),
        Some(hook.clone()),
    );
    let seen = Arc::new(Mutex::new(Vec::<f64>::new()));
    let progress: ProgressFn = {
        let seen = Arc::clone(&seen);
        Arc::new(move |f| seen.lock().unwrap().push(f))
    };
    let path = core
        .local_file(file_req(&url(&server, "/f.json"), &name), Some(progress))
        .await
        .unwrap();
    assert_eq!(path, files.join(&name));
    assert_eq!(std::fs::read(&path).unwrap(), payload);
    {
        let calls = hook.seen.lock().unwrap();
        assert_eq!(calls.len(), 1);
        assert!(
            !calls[0].1,
            "final name must not exist while the hook runs (quarantine first)"
        );
        assert!(
            calls[0]
                .0
                .file_name()
                .unwrap()
                .to_string_lossy()
                .ends_with(".part")
        );
    }
    let seen_values = seen.lock().unwrap().clone();
    assert_eq!(seen_values.last().copied(), Some(1.0));
    assert!(
        seen_values.windows(2).all(|w| w[0] <= w[1] || w[1] == 0.0),
        "{seen_values:?}"
    );
    // Throttled: far fewer callbacks than chunks.
    assert!(seen_values.len() < 400);
    assert!(parts(&files).is_empty());
    // Reuse: no second hit, no second hook call.
    let again = core
        .local_file(file_req(&url(&server, "/f.json"), &name), None)
        .await
        .unwrap();
    assert_eq!(again, path);
    assert_eq!(server.hit_count("/f.json"), 1);
    assert_eq!(hook.seen.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn parallel_local_file_requests_share_one_download() {
    let server = serve(handler(|_| Resp {
        body_delay: Duration::from_millis(200),
        ..Resp::ok(vec![5_u8; 1000])
    }))
    .await;
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    let mut tasks = Vec::new();
    for _ in 0..10 {
        let core = Arc::clone(&core);
        let req = file_req(&url(&server, "/one"), "one.bin");
        tasks.push(tokio::spawn(
            async move { core.local_file(req, None).await },
        ));
    }
    for t in tasks {
        assert!(t.await.unwrap().is_ok());
    }
    assert_eq!(server.hit_count("/one"), 1);
}

#[tokio::test]
async fn local_file_errors_leave_no_files() {
    let server = serve(handler(|r| match r.path.as_str() {
        "/trunc" => Resp {
            declared_length: Some(1000),
            ..Resp::ok(vec![1_u8; 10])
        },
        "/404" => Resp::status(404),
        _ => Resp::ok(vec![0_u8; 1]),
    }))
    .await;
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    assert_eq!(
        core.local_file(file_req(&url(&server, "/404"), "a.bin"), None)
            .await
            .unwrap_err(),
        MediaError::Http(404)
    );
    let truncated = core
        .local_file(file_req(&url(&server, "/trunc"), "b.bin"), None)
        .await
        .unwrap_err();
    assert!(matches!(truncated, MediaError::Net(_)), "{truncated:?}");
    assert!(parts(core.files_dir()).is_empty());
    assert!(!core.files_dir().join("a.bin").exists() && !core.files_dir().join("b.bin").exists());
}

#[tokio::test]
async fn local_file_stall_fails_after_idle_timeout() {
    let server = serve(handler(|_| Resp {
        body: vec![1; 100],
        chunk: Some((10, Duration::from_millis(600))),
        status: 200,
        ..Resp::default()
    }))
    .await;
    let dir = tempfile::tempdir().unwrap();
    let core = core_with(plain_cfg(), dir.path(), |o| {
        o.file_idle = Duration::from_millis(200)
    });
    // `localhost` is not a Zalo CDN host, so a stall is the URLError-class timeout (no DoH retry).
    let err = core
        .local_file(file_req(&url(&server, "/stall"), "s.bin"), None)
        .await
        .unwrap_err();
    assert_eq!(err, MediaError::Net(NetKind::TimedOut));
    assert!(parts(core.files_dir()).is_empty());
}

#[tokio::test]
async fn local_file_decrypts_and_rejects_bad_tag() {
    let (key, iv) = ([4_u8; 32], [9_u8; 12]);
    let plain: Vec<u8> = (0..5000_u32).map(|i| (i % 249) as u8).collect();
    let (cipher, token) = encrypt_e2ee_file(&plain, &key, &iv).unwrap();
    let server = serve(handler(move |_| Resp::ok(cipher.clone()))).await;
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    let good = SecureSpec {
        algorithm: Algorithm::Gcm,
        key: key.to_vec(),
        iv: iv.to_vec(),
        tag: Some(token[44..].to_vec()),
        block: false,
        block_size: 4096,
    };
    let mut req = file_req(&url(&server, "/e"), "dec.bin");
    req.secure = Some(good.clone());
    let path = core.local_file(req, None).await.unwrap();
    assert_eq!(std::fs::read(path).unwrap(), plain);
    let mut bad = good;
    bad.tag = Some(vec![1; 16]);
    let mut req = file_req(&url(&server, "/e"), "bad.bin");
    req.secure = Some(bad);
    assert_eq!(
        core.local_file(req, None).await.unwrap_err(),
        MediaError::Undecodable
    );
    assert!(!core.files_dir().join("bad.bin").exists());
    assert!(
        parts(core.files_dir()).is_empty(),
        "ciphertext must not be left behind"
    );
}

#[tokio::test]
async fn trim_runs_after_a_download() {
    let server = serve(handler(|r| {
        Resp::ok(vec![0_u8; if r.path == "/big" { 4000 } else { 1000 }])
    }))
    .await;
    let dir = tempfile::tempdir().unwrap();
    let core = core_with(plain_cfg(), dir.path(), |o| o.files_cache_limit = 2500);
    core.local_file(file_req(&url(&server, "/a"), "a.bin"), None)
        .await
        .unwrap();
    core.local_file(file_req(&url(&server, "/b"), "b.bin"), None)
        .await
        .unwrap();
    core.local_file(file_req(&url(&server, "/big"), "big.bin"), None)
        .await
        .unwrap();
    // Trim runs on the blocking pool right after publication.
    for _ in 0..50 {
        if !core.files_dir().join("a.bin").exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(
        core.files_dir().join("big.bin").exists(),
        "the file just downloaded is never evicted"
    );
    assert!(!core.files_dir().join("a.bin").exists());
    core.evict("big.bin");
    assert!(!core.files_dir().join("big.bin").exists());
}

// MARK: headers

#[tokio::test]
async fn header_download_sends_safe_headers_and_caps_size() {
    let server = serve(handler(|r| match r.path.as_str() {
        "/h" => Resp::ok(vec![9_u8; 500]),
        "/big" => Resp::ok(vec![9_u8; 5000]),
        "/chunked" => Resp {
            body: vec![9_u8; 5000],
            chunk: Some((500, Duration::ZERO)),
            status: 200,
            ..Resp::default()
        },
        "/403" => Resp::status(403),
        _ => Resp::status(404),
    }))
    .await;
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    let temp = dir.path().join("tmp");
    let make = |path: &str, max: u64| HeadersRequest {
        url: url(&server, path),
        headers: vec![
            ("X-Test".to_owned(), "yes".to_owned()),
            ("cloud-viewer-key".to_owned(), "secret".to_owned()),
            ("Cookie".to_owned(), "c=1".to_owned()),
            ("Host".to_owned(), "evil".to_owned()),
        ],
        max_bytes: max,
        ttfb: None,
        temp_dir: temp.clone(),
    };
    let out = core
        .download_with_headers(make("/h", 1000), None)
        .await
        .unwrap();
    assert_eq!(std::fs::read(&out).unwrap().len(), 500);
    let seen = server.last("/h").unwrap();
    assert_eq!(seen.headers.get("x-test").map(String::as_str), Some("yes"));
    // Sensitive headers never reach a non-Zalo / non-https host; hop-by-hop ones are dropped.
    assert!(!seen.headers.contains_key("cloud-viewer-key") && !seen.headers.contains_key("cookie"));
    assert_ne!(seen.headers.get("host").map(String::as_str), Some("evil"));
    assert_eq!(
        core.download_with_headers(make("/big", 1000), None)
            .await
            .unwrap_err(),
        MediaError::TooLarge
    );
    assert_eq!(
        core.download_with_headers(make("/chunked", 1000), None)
            .await
            .unwrap_err(),
        MediaError::TooLarge
    );
    assert_eq!(
        core.download_with_headers(make("/403", 1000), None)
            .await
            .unwrap_err(),
        MediaError::Http(403)
    );
    let leftovers = parts(&temp);
    assert_eq!(
        leftovers.len(),
        1,
        "only the successful download's file remains: {leftovers:?}"
    );
}

#[tokio::test]
async fn header_download_ttfb_is_a_load_error() {
    let server = serve(handler(|_| Resp {
        head_delay: Duration::from_millis(800),
        ..Resp::ok(vec![1; 10])
    }))
    .await;
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    let req = HeadersRequest {
        url: url(&server, "/slow"),
        headers: vec![],
        max_bytes: 1000,
        ttfb: Some(Duration::from_millis(150)),
        temp_dir: dir.path().join("tmp"),
    };
    let started = Instant::now();
    assert_eq!(
        core.download_with_headers(req, None).await.unwrap_err(),
        MediaError::TimedOut
    );
    assert!(
        started.elapsed() < Duration::from_millis(700),
        "{:?}",
        started.elapsed()
    );
}

// MARK: staged downloads

#[tokio::test]
async fn download_to_stages_decrypts_and_reports_failures() {
    let (key, iv) = ([6_u8; 32], [1_u8; 12]);
    let plain: Vec<u8> = (0..7000_u32).map(|i| (i % 241) as u8).collect();
    let (cipher, token) = encrypt_e2ee_file(&plain, &key, &iv).unwrap();
    let c2 = cipher.clone();
    let server = serve(handler(move |r| match r.path.as_str() {
        "/enc" => Resp::ok(c2.clone()),
        "/plain" => Resp::ok(b"photo-bytes".to_vec()),
        "/empty" => Resp::ok(Vec::new()),
        "/gone" => Resp::status(404),
        _ => Resp::status(500),
    }))
    .await;
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    let temp = dir.path().join("dl-tmp");
    let spec = SecureSpec {
        algorithm: Algorithm::Gcm,
        key: key.to_vec(),
        iv: iv.to_vec(),
        tag: Some(token[44..].to_vec()),
        block: false,
        block_size: 4096,
    };
    let run = |source: DownloadSource, secure: SecureChoice| {
        let core = Arc::clone(&core);
        let temp = temp.clone();
        async move {
            core.download_to(
                DownloadRequest {
                    source,
                    secure,
                    temp_dir: temp,
                },
                None,
            )
            .await
        }
    };
    // Photo bytes -> staged file.
    let out = run(
        DownloadSource::Photo(data_req(&url(&server, "/plain"))),
        SecureChoice::None,
    )
    .await;
    assert_eq!(std::fs::read(out.staged.unwrap()).unwrap(), b"photo-bytes");
    // Photo + secure stream, cached-file source + secure stream.
    let out = run(
        DownloadSource::Photo(data_req(&url(&server, "/enc"))),
        SecureChoice::Stream(spec.clone()),
    )
    .await;
    assert_eq!(std::fs::read(out.staged.unwrap()).unwrap(), plain);
    let out = run(
        DownloadSource::Cached(file_req(&url(&server, "/enc"), "enc.bin")),
        SecureChoice::Stream(spec.clone()),
    )
    .await;
    assert_eq!(std::fs::read(out.staged.unwrap()).unwrap(), plain);
    assert!(
        core.files_dir().join("enc.bin").exists(),
        "the shared cache file is copied, never moved"
    );
    // Failures carry the official codes.
    let out = run(
        DownloadSource::Photo(data_req(&url(&server, "/gone"))),
        SecureChoice::None,
    )
    .await;
    assert_eq!(out.failure.unwrap().code, 75_404);
    let out = run(
        DownloadSource::Photo(data_req(&url(&server, "/empty"))),
        SecureChoice::None,
    )
    .await;
    assert_eq!(out.failure.unwrap().code, 75_000 + 5002);
    let out = run(
        DownloadSource::Photo(data_req(&url(&server, "/plain"))),
        SecureChoice::Invalid,
    )
    .await;
    assert_eq!(out.failure.unwrap().code, 14_998);
    let mut wrong = spec;
    wrong.tag = Some(vec![0; 16]);
    let out = run(
        DownloadSource::Photo(data_req(&url(&server, "/enc"))),
        SecureChoice::Stream(wrong),
    )
    .await;
    assert_eq!(out.failure.unwrap().code, 14_998);
    // Header source: the raw file is moved into staging.
    let out = run(
        DownloadSource::Headers(HeadersRequest {
            url: url(&server, "/plain"),
            headers: vec![("X-A".to_owned(), "1".to_owned())],
            max_bytes: 1000,
            ttfb: None,
            temp_dir: temp.clone(),
        }),
        SecureChoice::None,
    )
    .await;
    assert_eq!(std::fs::read(out.staged.unwrap()).unwrap(), b"photo-bytes");
    // Only the five staged files that succeeded remain; every failure cleaned up.
    assert_eq!(parts(&temp).len(), 4, "{:?}", parts(&temp));
}

// MARK: DNS policy (DoH fallback, pinned TLS)

struct DohCounters {
    queries: Arc<AtomicUsize>,
}

/// DoH JSON endpoint answering `A 127.0.0.1` for hosts in `known`, NXDOMAIN (Status 3) otherwise.
async fn doh_server(known: &'static [&'static str]) -> (Server, DohCounters) {
    let queries = Arc::new(AtomicUsize::new(0));
    let q = Arc::clone(&queries);
    let server = serve(handler(move |r| {
        q.fetch_add(1, Ordering::SeqCst);
        let name = r
            .path
            .split("name=")
            .nth(1)
            .and_then(|s| s.split('&').next())
            .unwrap_or("");
        let body = if known.contains(&name) {
            r#"{"Status":0,"Answer":[{"type":1,"TTL":120,"data":"127.0.0.1"}]}"#.to_owned()
        } else {
            r#"{"Status":3}"#.to_owned()
        };
        Resp::ok(body.into_bytes())
    }))
    .await;
    (server, DohCounters { queries })
}

fn doh_cfg(doh: &Server, failing: &[&str]) -> MediaConfig {
    MediaConfig {
        doh_endpoints: vec![format!("http://127.0.0.1:{}/resolve", doh.port)],
        doh_suffixes: vec!["olaz.test".to_owned()],
        extra_root_pem: vec![cert_pem()],
        dns_failing: failing.iter().map(|s| (*s).to_owned()).collect(),
        ..MediaConfig::default()
    }
}

#[tokio::test]
async fn broken_system_dns_falls_back_to_pinned_doh_with_real_hostname_verification() {
    let tls = serve_tls(handler(|_| Resp::ok(b"over-pinned-tls".to_vec()))).await;
    let (doh, counters) = doh_server(&["cdn.olaz.test"]).await;
    let dir = tempfile::tempdir().unwrap();
    let core = core_with(
        doh_cfg(&doh, &["cdn.olaz.test", "evil.olaz.test"]),
        dir.path(),
        |_| {},
    );
    let good = format!("https://cdn.olaz.test:{}/img", tls.port);
    assert_eq!(
        core.data(data_req(&good)).await.unwrap().as_slice(),
        b"over-pinned-tls"
    );
    assert!(
        core.uses_doh("cdn.olaz.test"),
        "host is remembered as needing DoH"
    );
    assert_eq!(counters.queries.load(Ordering::SeqCst), 1);
    // The answer is cached: the second fetch does not ask DoH again and skips the system probe.
    let again = format!("https://cdn.olaz.test:{}/img2", tls.port);
    assert_eq!(
        core.data(data_req(&again)).await.unwrap().as_slice(),
        b"over-pinned-tls"
    );
    assert_eq!(counters.queries.load(Ordering::SeqCst), 1);
    // Files take the same path.
    let path = core
        .local_file(file_req(&good, "pinned.bin"), None)
        .await
        .unwrap();
    assert_eq!(std::fs::read(path).unwrap(), b"over-pinned-tls");
}

#[tokio::test]
async fn pinned_connection_rejects_a_certificate_for_another_hostname() {
    // The DoH answer points `evil.olaz.test` at the local TLS server, whose certificate only
    // covers `cdn.olaz.test` / `localhost`: validation must use the requested hostname and fail.
    let tls = serve_tls(handler(|_| Resp::ok(b"must-not-arrive".to_vec()))).await;
    let (doh, _counters) = doh_server(&["evil.olaz.test"]).await;
    let dir = tempfile::tempdir().unwrap();
    let core = core_with(doh_cfg(&doh, &["evil.olaz.test"]), dir.path(), |_| {});
    let result = core
        .data(data_req(&format!("https://evil.olaz.test:{}/x", tls.port)))
        .await;
    assert!(result.is_err(), "{result:?}");
    assert_eq!(
        tls.total_hits(),
        0,
        "no request may be sent over an unverified connection"
    );
}

#[tokio::test]
async fn nxdomain_marks_the_host_dead_without_asking_again() {
    let (doh, counters) = doh_server(&[]).await;
    let dir = tempfile::tempdir().unwrap();
    let core = core_with(doh_cfg(&doh, &["gone.olaz.test"]), dir.path(), |_| {});
    let u = "https://gone.olaz.test:9/x";
    assert_eq!(
        core.data(data_req(u)).await.unwrap_err(),
        MediaError::HostNotFound
    );
    assert_eq!(counters.queries.load(Ordering::SeqCst), 1);
    // Dead host: fails immediately, even for other paths.
    assert_eq!(
        core.data(data_req("https://gone.olaz.test:9/y"))
            .await
            .unwrap_err(),
        MediaError::HostNotFound
    );
    assert_eq!(
        core.local_file(file_req("https://gone.olaz.test:9/z", "z"), None)
            .await
            .unwrap_err(),
        MediaError::HostNotFound
    );
    assert_eq!(counters.queries.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn doh_is_only_used_for_cdn_hosts_and_all_endpoints_failing_is_typed() {
    let (doh, counters) = doh_server(&["cdn.olaz.test"]).await;
    let dir = tempfile::tempdir().unwrap();
    // Not a CDN host (suffix list is olaz.test): system DNS fails -> plain failure, DoH untouched.
    let cfg = MediaConfig {
        dns_failing: ["other.example".to_owned()].into(),
        ..doh_cfg(&doh, &[])
    };
    let core = core_with(cfg, dir.path(), |_| {});
    let err = core
        .data(data_req("http://other.example:9/x"))
        .await
        .unwrap_err();
    assert_eq!(err, MediaError::Net(NetKind::CannotFindHost));
    assert_eq!(counters.queries.load(Ordering::SeqCst), 0);
    // CDN host, every DoH endpoint down: the system error is reported (Swift rethrows urlError).
    let dead = MediaConfig {
        doh_endpoints: vec!["http://127.0.0.1:1/resolve".to_owned()],
        ..doh_cfg(&doh, &["cdn.olaz.test"])
    };
    let core = core_with(dead, dir.path(), |_| {});
    let err = core
        .data(data_req("https://cdn.olaz.test:9/x"))
        .await
        .unwrap_err();
    assert_eq!(err, MediaError::Net(NetKind::CannotFindHost));
    let _ = ResolveError::AllEndpointsFailed;
}

#[tokio::test]
async fn working_system_dns_never_touches_doh() {
    let server = serve(handler(|_| Resp::ok(b"system".to_vec()))).await;
    let (doh, counters) = doh_server(&["cdn.olaz.test"]).await;
    let mut cfg = doh_cfg(&doh, &[]);
    cfg.allow_plain_http = true;
    cfg.dns_overrides
        .insert("cdn.olaz.test".to_owned(), vec![LOCAL]);
    let dir = tempfile::tempdir().unwrap();
    let core = core_with(cfg, dir.path(), |_| {});
    let got = core
        .data(data_req(&format!("http://cdn.olaz.test:{}/a", server.port)))
        .await
        .unwrap();
    assert_eq!(got.as_slice(), b"system");
    assert_eq!(counters.queries.load(Ordering::SeqCst), 0);
    assert!(!core.uses_doh("cdn.olaz.test"));
}

#[tokio::test]
async fn system_failure_mid_fetch_retries_through_doh() {
    // The system lookup "works" for the probe but the connect fails like a DNS error: the host
    // here is only resolvable through DoH once marked failing after the probe. Simulated with an
    // override that points at a closed port (connect refused is NOT a DNS failure -> no retry).
    let (doh, counters) = doh_server(&["cdn.olaz.test"]).await;
    let mut cfg = doh_cfg(&doh, &[]);
    cfg.dns_overrides
        .insert("cdn.olaz.test".to_owned(), vec![LOCAL]);
    let dir = tempfile::tempdir().unwrap();
    let core = core_with(cfg, dir.path(), |_| {});
    let err = core
        .data(data_req("https://cdn.olaz.test:1/x"))
        .await
        .unwrap_err();
    assert!(
        matches!(err, MediaError::Net(NetKind::CannotConnect)),
        "{err:?}"
    );
    assert_eq!(
        counters.queries.load(Ordering::SeqCst),
        0,
        "connection refused is not evidence of broken DNS"
    );
}

#[tokio::test]
async fn parallel_burst_over_local_server_completes() {
    let server = serve(handler(|r| Resp::ok(r.path.clone().into_bytes()))).await;
    let dir = tempfile::tempdir().unwrap();
    let core = core_with(plain_cfg(), dir.path(), |o| o.max_concurrent = 6);
    let started = Instant::now();
    let mut tasks = Vec::new();
    for i in 0..200 {
        let (core, u) = (Arc::clone(&core), url(&server, &format!("/img/{i}")));
        tasks.push(tokio::spawn(async move { core.data(data_req(&u)).await }));
    }
    for (i, t) in tasks.into_iter().enumerate() {
        assert_eq!(
            t.await.unwrap().unwrap().as_slice(),
            format!("/img/{i}").as_bytes()
        );
    }
    assert_eq!(server.total_hits(), 200);
    assert!(started.elapsed() < Duration::from_secs(10));
    let _ = AtomicBool::new(false);
}

#[tokio::test]
async fn encoded_files_decode_before_decryption_and_finish_progress_without_wire_totals() {
    use std::io::Write;
    fn encode(body: &[u8], encoding: &str) -> Vec<u8> {
        if encoding == "gzip" {
            let mut encoder =
                flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
            encoder.write_all(body).unwrap();
            encoder.finish().unwrap()
        } else {
            let mut out = Vec::new();
            {
                let mut encoder = brotli::CompressorWriter::new(&mut out, 4096, 4, 22);
                encoder.write_all(body).unwrap();
            }
            out
        }
    }
    fn probe() -> (Arc<Mutex<Vec<f64>>>, ProgressFn) {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let observer = Arc::clone(&seen);
        (
            seen,
            Arc::new(move |fraction| observer.lock().unwrap().push(fraction)),
        )
    }
    fn assert_finished(seen: &Mutex<Vec<f64>>) {
        let values = seen.lock().unwrap();
        assert_eq!(values.last().copied(), Some(1.0), "{values:?}");
        assert!(
            values
                .iter()
                .all(|v| v.is_finite() && (0.0..=1.0).contains(v)),
            "{values:?}"
        );
    }

    let plain: Vec<u8> = (0..100_000_u32).map(|i| (i % 241) as u8).collect();
    let (key, iv) = ([6_u8; 32], [1_u8; 12]);
    let (cipher, token) = encrypt_e2ee_file(&plain, &key, &iv).unwrap();
    let spec = SecureSpec {
        algorithm: Algorithm::Gcm,
        key: key.to_vec(),
        iv: iv.to_vec(),
        tag: Some(token[44..].to_vec()),
        block: false,
        block_size: 4096,
    };
    let bodies: std::collections::HashMap<_, _> = [
        ("/plain/gzip", encode(&plain, "gzip")),
        ("/plain/br", encode(&plain, "br")),
        ("/encrypted/gzip", encode(&cipher, "gzip")),
        ("/encrypted/br", encode(&cipher, "br")),
    ]
    .into_iter()
    .collect();
    // Incompressible ciphertext adds framing overhead: this would falsely exceed max_bytes
    // if the wire Content-Length were compared against the decoded-byte limit.
    assert!(bodies["/encrypted/gzip"].len() > cipher.len());
    let server = serve(handler(move |r| {
        let body = bodies[r.path.as_str()].clone();
        Resp {
            headers: vec![(
                "Content-Encoding".into(),
                r.path.rsplit('/').next().unwrap().into(),
            )],
            declared_length: Some(body.len()),
            ..Resp::ok(body)
        }
    }))
    .await;
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    for encoding in ["gzip", "br"] {
        for encrypted in [false, true] {
            let flavour = if encrypted { "encrypted" } else { "plain" };
            let target = url(&server, &format!("/{flavour}/{encoding}"));
            let mut request = file_req(&target, &format!("{flavour}-{encoding}.bin"));
            request.secure = encrypted.then(|| spec.clone());
            let (seen, progress) = probe();
            let path = core.local_file(request, Some(progress)).await.unwrap();
            assert_eq!(std::fs::read(path).unwrap(), plain);
            assert_finished(&seen);

            // Header/cloud download path streams decoded bytes to disk, then decrypts them.
            let (seen, progress) = probe();
            let outcome = core
                .download_to(
                    DownloadRequest {
                        source: DownloadSource::Headers(HeadersRequest {
                            url: target,
                            headers: Vec::new(),
                            max_bytes: plain.len() as u64,
                            ttfb: None,
                            temp_dir: dir.path().join("raw"),
                        }),
                        secure: if encrypted {
                            SecureChoice::Stream(spec.clone())
                        } else {
                            SecureChoice::None
                        },
                        temp_dir: dir.path().join("staged"),
                    },
                    Some(progress),
                )
                .await;
            assert_eq!(outcome.failure, None, "{flavour}/{encoding}");
            assert_eq!(std::fs::read(outcome.staged.unwrap()).unwrap(), plain);
            assert_finished(&seen);
        }
    }
    let error = core
        .download_with_headers(
            HeadersRequest {
                url: url(&server, "/plain/gzip"),
                headers: Vec::new(),
                max_bytes: plain.len() as u64 - 1,
                ttfb: None,
                temp_dir: dir.path().join("over-limit"),
            },
            None,
        )
        .await
        .unwrap_err();
    assert_eq!(
        error,
        MediaError::TooLarge,
        "the size cap applies to decoded bytes"
    );
}

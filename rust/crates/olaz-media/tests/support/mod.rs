#![allow(dead_code, clippy::unwrap_used, clippy::expect_used)]
//! Tiny HTTP/1.1 test server on local sockets (plain or TLS). Never touches the network.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

#[derive(Clone, Debug)]
pub struct Req {
    pub path: String,
    pub headers: HashMap<String, String>,
}

#[derive(Clone, Default)]
pub struct Resp {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    /// Sleep before sending the head.
    pub head_delay: Duration,
    /// Sleep between head and body.
    pub body_delay: Duration,
    /// Declare this Content-Length instead of `body.len()` (truncation tests); `Some(0)` = none.
    pub declared_length: Option<usize>,
    /// Chunked transfer: send the body in pieces of this size with `chunk_delay` between them.
    pub chunk: Option<(usize, Duration)>,
}

impl Resp {
    pub fn ok(body: impl Into<Vec<u8>>) -> Self {
        Self {
            status: 200,
            body: body.into(),
            ..Self::default()
        }
    }
    pub fn status(status: u16) -> Self {
        Self {
            status,
            ..Self::default()
        }
    }
    pub fn redirect(location: &str) -> Self {
        Self {
            status: 302,
            headers: vec![("Location".to_owned(), location.to_owned())],
            ..Self::default()
        }
    }
}

pub type Handler = Arc<dyn Fn(&Req) -> Resp + Send + Sync>;

pub struct Server {
    pub port: u16,
    pub hits: Arc<Mutex<Vec<Req>>>,
    pub active: Arc<AtomicUsize>,
    pub max_active: Arc<AtomicUsize>,
    pub closed_early: Arc<AtomicUsize>,
}

impl Server {
    pub fn hit_count(&self, path: &str) -> usize {
        self.hits
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r.path == path)
            .count()
    }
    pub fn total_hits(&self) -> usize {
        self.hits.lock().unwrap().len()
    }
    pub fn last(&self, path: &str) -> Option<Req> {
        self.hits
            .lock()
            .unwrap()
            .iter()
            .rev()
            .find(|r| r.path == path)
            .cloned()
    }
}

/// Plain HTTP server on 127.0.0.1.
pub async fn serve(handler: Handler) -> Server {
    serve_with(handler, None).await
}

/// TLS server (certificate for `cdn.olaz.test` / `localhost`).
pub async fn serve_tls(handler: Handler) -> Server {
    let pem = std::fs::read(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/cert.pem"
    ))
    .unwrap();
    let key = std::fs::read(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/key.pem"
    ))
    .unwrap();
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
    let certs: Vec<CertificateDer<'static>> = CertificateDer::pem_slice_iter(&pem)
        .collect::<Result<_, _>>()
        .unwrap();
    let key = PrivateKeyDer::from_pem_slice(&key).unwrap();
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(certs, key)
    .unwrap();
    serve_with(
        handler,
        Some(tokio_rustls::TlsAcceptor::from(Arc::new(config))),
    )
    .await
}

pub fn cert_pem() -> Vec<u8> {
    std::fs::read(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/root.pem"
    ))
    .unwrap()
}

async fn serve_with(handler: Handler, tls: Option<tokio_rustls::TlsAcceptor>) -> Server {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = Server {
        port,
        hits: Arc::default(),
        active: Arc::default(),
        max_active: Arc::default(),
        closed_early: Arc::default(),
    };
    let (hits, active, max_active, closed) = (
        Arc::clone(&server.hits),
        Arc::clone(&server.active),
        Arc::clone(&server.max_active),
        Arc::clone(&server.closed_early),
    );
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                return;
            };
            let (handler, hits, active, max_active, closed, tls) = (
                Arc::clone(&handler),
                Arc::clone(&hits),
                Arc::clone(&active),
                Arc::clone(&max_active),
                Arc::clone(&closed),
                tls.clone(),
            );
            tokio::spawn(async move {
                match tls {
                    Some(acceptor) => {
                        let Ok(stream) = acceptor.accept(stream).await else {
                            return;
                        };
                        conn(stream, handler, hits, active, max_active, closed).await;
                    }
                    None => conn(stream, handler, hits, active, max_active, closed).await,
                }
            });
        }
    });
    server
}

async fn conn<S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin>(
    mut stream: S,
    handler: Handler,
    hits: Arc<Mutex<Vec<Req>>>,
    active: Arc<AtomicUsize>,
    max_active: Arc<AtomicUsize>,
    closed: Arc<AtomicUsize>,
) {
    let mut buf = Vec::new();
    loop {
        // Read one request head.
        let mut chunk = [0_u8; 4096];
        let end = loop {
            if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                break pos + 4;
            }
            match stream.read(&mut chunk).await {
                Ok(0) | Err(_) => return,
                Ok(n) => buf.extend_from_slice(&chunk[..n]),
            }
        };
        let head = String::from_utf8_lossy(&buf[..end]).into_owned();
        buf.drain(..end);
        let mut lines = head.split("\r\n");
        let first = lines.next().unwrap_or("");
        let path = first.split(' ').nth(1).unwrap_or("/").to_owned();
        let mut headers = HashMap::new();
        for line in lines {
            if let Some((k, v)) = line.split_once(':') {
                headers.insert(k.trim().to_lowercase(), v.trim().to_owned());
            }
        }
        let req = Req { path, headers };
        hits.lock().unwrap().push(req.clone());
        let now = active.fetch_add(1, Ordering::SeqCst) + 1;
        max_active.fetch_max(now, Ordering::SeqCst);
        let resp = handler(&req);
        let sent = respond(&mut stream, &resp).await;
        active.fetch_sub(1, Ordering::SeqCst);
        if !sent {
            closed.fetch_add(1, Ordering::SeqCst);
            return;
        }
        if resp.declared_length.is_some_and(|d| d > resp.body.len()) {
            return; // truncated on purpose: close
        }
    }
}

async fn respond<S: tokio::io::AsyncWrite + Unpin>(stream: &mut S, resp: &Resp) -> bool {
    tokio::time::sleep(resp.head_delay).await;
    let mut head = format!("HTTP/1.1 {} X\r\n", resp.status);
    for (k, v) in &resp.headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    match (resp.chunk, resp.declared_length) {
        (Some(_), _) => head.push_str("Transfer-Encoding: chunked\r\n"),
        (None, Some(d)) => head.push_str(&format!("Content-Length: {d}\r\n")),
        (None, None) => head.push_str(&format!("Content-Length: {}\r\n", resp.body.len())),
    }
    head.push_str("\r\n");
    if stream.write_all(head.as_bytes()).await.is_err() {
        return false;
    }
    tokio::time::sleep(resp.body_delay).await;
    if let Some((size, delay)) = resp.chunk {
        for piece in resp.body.chunks(size.max(1)) {
            let frame = [format!("{:x}\r\n", piece.len()).as_bytes(), piece, b"\r\n"].concat();
            if stream.write_all(&frame).await.is_err() {
                return false;
            }
            tokio::time::sleep(delay).await;
        }
        return stream.write_all(b"0\r\n\r\n").await.is_ok();
    }
    stream.write_all(&resp.body).await.is_ok() && stream.flush().await.is_ok()
}

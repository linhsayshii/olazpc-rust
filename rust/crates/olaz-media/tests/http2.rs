#![allow(clippy::unwrap_used, clippy::expect_used)]
//! Actual TLS ALPN negotiation, HTTP/2 requests and decompression on both production clients.
//! Uses the existing local certificate fixtures; no external network or forced h2 mode.
use std::collections::BTreeMap;
use std::io::Write;
use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use olaz_media::{DataRequest, FileRequest, HeadersRequest, MediaConfig, MediaCore, MediaOptions};
use olaz_net::{RequestOptions, ReqwestTransport, send_raw};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
use tokio::net::TcpListener;
use tokio::sync::mpsc;

const BODY: &[u8] = br#"{"error_code":0,"data":{"decoded":true}}"#;
const ROOT: &[u8] = include_bytes!("fixtures/root.pem");
type Headers = BTreeMap<String, String>;

fn compressed(encoding: &str) -> Vec<u8> {
    match encoding {
        "gzip" => {
            let mut encoder =
                flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
            encoder.write_all(BODY).unwrap();
            encoder.finish().unwrap()
        }
        "deflate" => {
            let mut encoder =
                flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
            encoder.write_all(BODY).unwrap();
            encoder.finish().unwrap()
        }
        "br" => {
            let mut out = Vec::new();
            {
                let mut encoder = brotli::CompressorWriter::new(&mut out, 4096, 4, 22);
                encoder.write_all(BODY).unwrap();
            }
            out
        }
        _ => BODY.to_vec(),
    }
}

async fn server() -> (
    String,
    mpsc::UnboundedReceiver<(String, Headers)>,
    tokio::task::JoinHandle<()>,
) {
    let certs = CertificateDer::pem_slice_iter(include_bytes!("fixtures/cert.pem"))
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    let key = PrivateKeyDer::from_pem_slice(include_bytes!("fixtures/key.pem")).unwrap();
    let mut config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(certs, key)
    .unwrap();
    config.alpn_protocols = vec![b"h2".to_vec()];
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!(
        "https://localhost:{}",
        listener.local_addr().unwrap().port()
    );
    let (tx, rx) = mpsc::unbounded_channel();
    let task = tokio::spawn(async move {
        while let Ok((socket, _)) = listener.accept().await {
            let acceptor = acceptor.clone();
            let tx = tx.clone();
            tokio::spawn(async move {
                let socket = acceptor.accept(socket).await.unwrap();
                assert_eq!(socket.get_ref().1.alpn_protocol(), Some(b"h2".as_slice()));
                let mut conn = h2::server::handshake(socket).await.unwrap();
                while let Some(request) = conn.accept().await {
                    let (request, mut respond) = request.unwrap();
                    assert_eq!(request.version(), http::Version::HTTP_2);
                    let path = request.uri().path().to_owned();
                    let encoding = path.rsplit('/').next().unwrap();
                    let body = compressed(encoding);
                    tx.send((
                        path.clone(),
                        request
                            .headers()
                            .iter()
                            .map(|(k, v)| (k.as_str().to_owned(), v.to_str().unwrap().to_owned()))
                            .collect(),
                    ))
                    .unwrap();
                    let response = http::Response::builder()
                        .status(200)
                        .header("content-encoding", encoding)
                        .header("content-length", body.len())
                        .body(())
                        .unwrap();
                    respond
                        .send_response(response, false)
                        .unwrap()
                        .send_data(Bytes::from(body), true)
                        .unwrap();
                }
            });
        }
    });
    (base, rx, task)
}

fn assert_headers(headers: &Headers, accept: &str, dest: &str, mode: &str, api: bool) {
    let get = |name: &str| headers.get(name).map(String::as_str);
    assert_eq!(get("accept"), Some(accept));
    assert_eq!(get("accept-encoding"), Some("gzip, deflate, br"));
    assert_eq!(get("accept-language"), Some("vi-VN,en-US;q=0.9"));
    assert_eq!(get("user-agent"), Some("ZaloPC-darwin-23v694"));
    assert_eq!(
        get("sec-ch-ua"),
        Some("\"Not?A_Brand\";v=\"8\", \"Chromium\";v=\"108\"")
    );
    assert_eq!(get("sec-ch-ua-mobile"), Some("?0"));
    assert_eq!(get("sec-ch-ua-platform"), Some("\"macOS\""));
    assert_eq!(get("sec-fetch-dest"), Some(dest));
    assert_eq!(get("sec-fetch-mode"), Some(mode));
    assert_eq!(get("sec-fetch-site"), Some("cross-site"));
    assert_eq!(
        get("content-type"),
        if api {
            Some("application/x-www-form-urlencoded")
        } else {
            None
        }
    );
    assert_eq!(get("origin"), None);
    assert_eq!(get("referer"), None);
    assert_eq!(get("zpw_sek"), None);
    assert_eq!(get("cookie"), None);
    assert!(headers.values().all(|v| !v.contains("_zlang")));
    // HTTP/2 pseudo-headers are not included in HeaderMap.
    assert_eq!(headers.len(), if api { 11 } else { 10 });
}

#[tokio::test]
async fn api_and_media_negotiate_h2_and_decode_all_advertised_encodings() {
    tokio::time::timeout(Duration::from_secs(20), async {
        let (base, mut rx, server) = server().await;
        let languages = vec!["vi_VN".to_owned(), "en-US".to_owned()];
        let transport = ReqwestTransport::with_roots(languages.clone(), &[ROOT.to_vec()]).unwrap();
        let dir = tempfile::tempdir().unwrap();
        let media = MediaCore::new(
            MediaConfig {
                extra_root_pem: vec![ROOT.to_vec()],
                preferred_languages: languages,
                ..MediaConfig::default()
            },
            MediaOptions::new(dir.path().join("files")),
            None,
        );
        for encoding in ["gzip", "deflate", "br"] {
            let url = format!("{base}/api/{encoding}");
            let response = send_raw(&transport, &RequestOptions::get(url), None, 0)
                .await
                .unwrap()
                .response;
            assert_eq!(response.body, BODY);
            assert!(
                response
                    .headers
                    .iter()
                    .all(|(k, _)| k != "content-encoding" && k != "content-length")
            );
            let (_, headers) = rx.recv().await.unwrap();
            assert_headers(
                &headers,
                "application/json, text/plain, */*",
                "empty",
                "cors",
                true,
            );

            let url = format!("{base}/image/{encoding}");
            let body = media
                .data(DataRequest {
                    url: url.clone(),
                    fallback_url: None,
                    secure: None,
                    key_seed: url,
                    deadline: Duration::from_secs(5),
                })
                .await
                .unwrap();
            assert_eq!(body.as_slice(), BODY);
            let (_, headers) = rx.recv().await.unwrap();
            assert_headers(
                &headers,
                "image/webp,image/apng,image/*,*/*;q=0.8",
                "image",
                "no-cors",
                false,
            );

            let url = format!("{base}/file/{encoding}");
            let path = media
                .local_file(
                    FileRequest {
                        url: url.clone(),
                        fallback_url: None,
                        file_name: encoding.to_owned(),
                        secure: None,
                        origin_url: url,
                    },
                    None,
                )
                .await
                .unwrap();
            assert_eq!(std::fs::read(path).unwrap(), BODY);
            let (_, headers) = rx.recv().await.unwrap();
            assert_headers(&headers, "*/*", "empty", "cors", false);
        }
        // Defaults also reach header-authenticated downloads; caller values win case-insensitively.
        let path = media
            .download_with_headers(
                HeadersRequest {
                    url: format!("{base}/headers/gzip"),
                    headers: vec![
                        ("ACCEPT".into(), "custom".into()),
                        ("Accept-Encoding".into(), "gzip".into()),
                        ("Content-Type".into(), "custom/type".into()),
                        ("Cookie".into(), "zpw_sek=secret; _zlang=vi".into()),
                    ],
                    max_bytes: 1024,
                    ttfb: None,
                    temp_dir: dir.path().to_owned(),
                },
                None,
            )
            .await
            .unwrap();
        assert_eq!(std::fs::read(path).unwrap(), BODY);
        let (_, headers) = rx.recv().await.unwrap();
        assert_eq!(headers.get("accept").map(String::as_str), Some("custom"));
        assert_eq!(
            headers.get("content-type").map(String::as_str),
            Some("custom/type")
        );
        assert_eq!(
            headers.get("accept-encoding").map(String::as_str),
            Some("gzip, deflate, br")
        );
        assert!(!headers.contains_key("cookie"));
        server.abort();
    })
    .await
    .unwrap();
}

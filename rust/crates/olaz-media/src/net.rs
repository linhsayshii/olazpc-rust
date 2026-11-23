//! HTTP routes (system DNS / DoH-pinned), the DNS fallback policy and body readers.
//!
//! The pinned connection is a reqwest client whose resolver is the DoH resolver: the connection
//! goes to the DoH IP while SNI and certificate validation still use the real hostname (the URL
//! keeps the original host). Only Zalo CDN hosts ever get that client.

use std::collections::{HashMap, HashSet};
use std::error::Error as StdError;
use std::future::Future;
use std::net::{IpAddr, SocketAddr};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

use futures_util::FutureExt;
use futures_util::future::{BoxFuture, Shared};
use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use tokio::io::AsyncWriteExt;
use url::Url;

use crate::doh::{DEFAULT_ENDPOINTS, DohResolver};
use crate::error::{MediaError, NetKind, ResolveError};
use crate::naming::{DOH_HOST_SUFFIXES, is_suffix_match};

pub const USER_AGENT: &str = "ZaloPC-darwin-23v694";

const DOH_STICKINESS: Duration = Duration::from_secs(600);
const SYSTEM_OK_TTL: Duration = Duration::from_secs(300);
const DEAD_HOST_TTL: Duration = Duration::from_secs(300);
const PROBE_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_REDIRECTS: usize = 3;

/// Behaviour switches. Production uses [`MediaConfig::default`]; tests point the DoH endpoints and
/// DNS at local servers.
#[derive(Clone)]
pub struct MediaConfig {
    pub doh_endpoints: Vec<String>,
    pub doh_suffixes: Vec<String>,
    /// PEM certificates trusted in addition to the system roots (local TLS test servers).
    pub extra_root_pem: Vec<Vec<u8>>,
    /// Keep `http` URLs `http` (local test servers); production upgrades to https (ATS).
    pub allow_plain_http: bool,
    /// Host -> addresses answered without touching real DNS (tests).
    pub dns_overrides: HashMap<String, Vec<IpAddr>>,
    /// Hosts whose system lookup fails (tests simulate a broken system resolver).
    pub dns_failing: HashSet<String>,
    pub user_agent: String,
}

impl Default for MediaConfig {
    fn default() -> Self {
        Self {
            doh_endpoints: DEFAULT_ENDPOINTS.iter().map(|s| (*s).to_owned()).collect(),
            doh_suffixes: DOH_HOST_SUFFIXES.iter().map(|s| (*s).to_owned()).collect(),
            extra_root_pem: Vec::new(),
            allow_plain_http: false,
            dns_overrides: HashMap::new(),
            dns_failing: HashSet::new(),
            user_agent: USER_AGENT.to_owned(),
        }
    }
}

impl MediaConfig {
    pub(crate) fn is_cdn(&self, host: &str) -> bool {
        is_suffix_match(host, self.doh_suffixes.iter().map(String::as_str))
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Route {
    System,
    Doh,
}

/// Marker error: the system resolver could not resolve the host.
#[derive(Debug)]
struct DnsFailure;
impl std::fmt::Display for DnsFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("system dns failure")
    }
}
impl StdError for DnsFailure {}

type BoxErr = Box<dyn StdError + Send + Sync>;

struct SystemResolver {
    cfg: Arc<MediaConfig>,
}

async fn system_lookup(cfg: &MediaConfig, host: &str) -> Result<Vec<SocketAddr>, DnsFailure> {
    if cfg.dns_failing.contains(host) {
        return Err(DnsFailure);
    }
    if let Some(ips) = cfg.dns_overrides.get(host) {
        return Ok(ips.iter().map(|ip| SocketAddr::new(*ip, 0)).collect());
    }
    match tokio::net::lookup_host((host, 0)).await {
        Ok(it) => Ok(it.collect()),
        Err(_) => Err(DnsFailure),
    }
}

impl Resolve for SystemResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let cfg = Arc::clone(&self.cfg);
        Box::pin(async move {
            let addrs = system_lookup(&cfg, name.as_str())
                .await
                .map_err(|e| Box::new(e) as BoxErr)?;
            Ok(Box::new(addrs.into_iter()) as Addrs)
        })
    }
}

struct PinResolver {
    cfg: Arc<MediaConfig>,
    doh: Arc<DohResolver>,
    rotate: AtomicUsize,
}

#[derive(Debug)]
struct NotAllowed;
impl std::fmt::Display for NotAllowed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("host not allowed for doh")
    }
}
impl StdError for NotAllowed {}

impl Resolve for PinResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let host = name.as_str().to_lowercase();
        let allowed = self.cfg.is_cdn(&host);
        let doh = Arc::clone(&self.doh);
        let start = self.rotate.fetch_add(1, Ordering::Relaxed);
        Box::pin(async move {
            if !allowed {
                return Err(Box::new(NotAllowed) as BoxErr);
            }
            let mut ips = doh
                .resolve(&host)
                .await
                .map_err(|e| Box::new(e) as BoxErr)?;
            if !ips.is_empty() {
                let shift = start % ips.len();
                ips.rotate_left(shift); // spread load over the answer set (Swift shuffled)
            }
            let addrs: Vec<SocketAddr> = ips
                .into_iter()
                .take(4)
                .map(|ip| SocketAddr::new(IpAddr::V4(ip), 0))
                .collect();
            Ok(Box::new(addrs.into_iter()) as Addrs)
        })
    }
}

struct Inner {
    system: reqwest::Client,
    pinned: reqwest::Client,
    doh: Arc<DohResolver>,
}

#[derive(Default)]
struct Routing {
    /// host -> when to retry system DNS
    doh_hosts: HashMap<String, Instant>,
    /// host -> system DNS treated as good until
    system_ok: HashMap<String, Instant>,
    probes: HashMap<String, Shared<BoxFuture<'static, bool>>>,
    /// Zalo CDN hosts DoH reported NXDOMAIN for (migrated messages point at retired hosts).
    dead_hosts: HashMap<String, Instant>,
}

/// Shared network state of one `MediaCore`.
pub(crate) struct Net {
    pub(crate) cfg: Arc<MediaConfig>,
    routing: Mutex<Routing>,
    inner: OnceLock<Result<Inner, MediaError>>,
}

fn builder(cfg: &MediaConfig) -> Result<reqwest::ClientBuilder, MediaError> {
    let mut b = reqwest::Client::builder()
        .user_agent(cfg.user_agent.clone())
        .redirect(reqwest::redirect::Policy::none())
        .no_gzip()
        .connect_timeout(Duration::from_secs(10));
    for pem in &cfg.extra_root_pem {
        let cert =
            reqwest::Certificate::from_pem(pem).map_err(|_| MediaError::Net(NetKind::Other))?;
        b = b.add_root_certificate(cert);
    }
    Ok(b)
}

fn build_inner(cfg: &Arc<MediaConfig>) -> Result<Inner, MediaError> {
    let other = |_| MediaError::Net(NetKind::Other);
    let system = builder(cfg)?
        .dns_resolver(Arc::new(SystemResolver {
            cfg: Arc::clone(cfg),
        }))
        .build()
        .map_err(other)?;
    let query = builder(cfg)?.build().map_err(other)?;
    let doh = DohResolver::new(query, cfg.doh_endpoints.clone());
    let pinned = builder(cfg)?
        .connect_timeout(Duration::from_secs(6))
        .dns_resolver(Arc::new(PinResolver {
            cfg: Arc::clone(cfg),
            doh: Arc::clone(&doh),
            rotate: AtomicUsize::new(0),
        }))
        .build()
        .map_err(other)?;
    Ok(Inner {
        system,
        pinned,
        doh,
    })
}

/// Maps a reqwest failure to the `URLError`-class the Swift code branched on.
pub(crate) fn classify(error: &reqwest::Error) -> MediaError {
    if error.is_timeout() {
        return MediaError::Net(NetKind::TimedOut);
    }
    let mut kind = if error.is_connect() {
        NetKind::CannotConnect
    } else {
        NetKind::Other
    };
    let mut source: Option<&(dyn StdError + 'static)> = Some(error);
    while let Some(err) = source {
        if err.downcast_ref::<DnsFailure>().is_some() {
            return MediaError::Net(NetKind::CannotFindHost);
        }
        if let Some(resolve) = err.downcast_ref::<ResolveError>() {
            return MediaError::Resolve(resolve.clone());
        }
        if let Some(io) = err.downcast_ref::<std::io::Error>() {
            use std::io::ErrorKind as K;
            match io.kind() {
                K::ConnectionRefused => kind = NetKind::CannotConnect,
                K::NotConnected | K::NetworkUnreachable | K::HostUnreachable | K::NetworkDown => {
                    kind = NetKind::NotConnected;
                }
                K::ConnectionReset | K::ConnectionAborted | K::BrokenPipe | K::UnexpectedEof => {
                    kind = NetKind::ConnectionLost;
                }
                K::TimedOut => kind = NetKind::TimedOut,
                _ => {}
            }
        }
        let text = err.to_string().to_lowercase();
        if text.contains("certificate") || text.contains("handshake") || text.contains("tls") {
            return MediaError::Net(NetKind::SecureFailed);
        }
        source = err.source();
    }
    MediaError::Net(kind)
}

/// A finished response head: status, `Location` and the body stream.
pub(crate) struct Head {
    pub(crate) status: u16,
    pub(crate) location: Option<String>,
    pub(crate) content_length: Option<u64>,
    pub(crate) response: reqwest::Response,
}

impl Net {
    pub(crate) fn new(cfg: MediaConfig) -> Self {
        Self {
            cfg: Arc::new(cfg),
            routing: Mutex::new(Routing::default()),
            inner: OnceLock::new(),
        }
    }

    fn routing(&self) -> std::sync::MutexGuard<'_, Routing> {
        self.routing.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn inner(&self) -> Result<&Inner, MediaError> {
        self.inner
            .get_or_init(|| build_inner(&self.cfg))
            .as_ref()
            .map_err(Clone::clone)
    }

    /// Test hook: has this host been switched to the DoH path?
    pub(crate) fn uses_doh(&self, host: &str) -> bool {
        self.routing()
            .doh_hosts
            .get(&host.to_lowercase())
            .is_some_and(|t| *t > Instant::now())
    }

    pub(crate) fn fail_if_dead(&self, host: &str) -> Result<(), MediaError> {
        let mut routing = self.routing();
        match routing.dead_hosts.get(host) {
            Some(until) if *until > Instant::now() => Err(MediaError::HostNotFound),
            Some(_) => {
                routing.dead_hosts.remove(host);
                Ok(())
            }
            None => Ok(()),
        }
    }

    fn mark_dead(&self, host: &str) {
        let mut routing = self.routing();
        if routing.dead_hosts.len() > 1000 {
            routing.dead_hosts.clear();
        }
        routing
            .dead_hosts
            .insert(host.to_owned(), Instant::now() + DEAD_HOST_TTL);
    }

    fn set_doh_host(&self, host: &str) {
        self.routing()
            .doh_hosts
            .insert(host.to_owned(), Instant::now() + DOH_STICKINESS);
    }

    /// Cheap pre-flight: does the system resolver answer for `host` within a few seconds? One
    /// shared probe per host, so a stalled resolver cannot pile up blocked lookups.
    async fn system_resolves(&self, host: &str) -> bool {
        let probe = {
            let mut routing = self.routing();
            if routing
                .doh_hosts
                .get(host)
                .is_some_and(|t| *t > Instant::now())
            {
                return false;
            }
            if routing
                .system_ok
                .get(host)
                .is_some_and(|t| *t > Instant::now())
            {
                return true;
            }
            routing
                .probes
                .entry(host.to_owned())
                .or_insert_with(|| {
                    let cfg = Arc::clone(&self.cfg);
                    let host = host.to_owned();
                    async move { probe_system_dns(&cfg, &host, PROBE_TIMEOUT).await }
                        .boxed()
                        .shared()
                })
                .clone()
        };
        let ok = probe.await;
        let mut routing = self.routing();
        if routing.probes.remove(host).is_some() {
            if ok {
                routing
                    .system_ok
                    .insert(host.to_owned(), Instant::now() + SYSTEM_OK_TTL);
            } else {
                routing
                    .doh_hosts
                    .insert(host.to_owned(), Instant::now() + Duration::from_secs(20));
            }
        }
        ok
    }

    /// Runs `op` with the DNS fallback policy (Swift `withDNSFallback`): DoH first for hosts whose
    /// system lookup is known / probed bad, DoH as a retry when the system fetch fails like a DNS
    /// problem. DoH is only ever used for Zalo CDN hosts.
    pub(crate) async fn with_dns_fallback<T, F, Fut>(
        &self,
        host: &str,
        confirm_timeouts: bool,
        op: F,
    ) -> Result<T, MediaError>
    where
        F: Fn(Route) -> Fut,
        Fut: Future<Output = Result<T, MediaError>>,
    {
        let allow_doh = self.cfg.is_cdn(host);
        if allow_doh && !self.system_resolves(host).await {
            match op(Route::Doh).await {
                Ok(v) => {
                    self.set_doh_host(host);
                    return Ok(v);
                }
                Err(e) if e.is_load_error() || e == MediaError::Cancelled => return Err(e),
                Err(MediaError::Resolve(ResolveError::NotFound)) => {
                    self.mark_dead(host);
                    return Err(MediaError::HostNotFound);
                }
                Err(_) => {
                    // DoH path broke; give the system resolver a go.
                    let mut routing = self.routing();
                    routing.doh_hosts.remove(host);
                    routing
                        .system_ok
                        .insert(host.to_owned(), Instant::now() + Duration::from_secs(30));
                }
            }
        }
        match op(Route::System).await {
            Err(e) if allow_doh && e.is_dns_failure() => {
                // A mid-transfer stall is not evidence of broken DNS: only fall back to DoH (and
                // remember the host) when a fresh lookup really fails.
                if confirm_timeouts
                    && e == MediaError::Net(NetKind::TimedOut)
                    && probe_system_dns(&self.cfg, host, PROBE_TIMEOUT).await
                {
                    return Err(MediaError::TimedOut);
                }
                match op(Route::Doh).await {
                    Ok(v) => {
                        self.set_doh_host(host);
                        Ok(v)
                    }
                    Err(load) if load.is_load_error() || load == MediaError::Cancelled => Err(load),
                    Err(MediaError::Resolve(ResolveError::NotFound)) => {
                        self.mark_dead(host);
                        Err(MediaError::HostNotFound)
                    }
                    Err(_) => Err(e), // DoH failed too (offline?): report the system error
                }
            }
            other => other,
        }
    }

    /// One GET on `route`; returns once the response head arrived (`idle` bounds that wait).
    pub(crate) async fn send(
        &self,
        route: Route,
        url: &Url,
        headers: &[(String, String)],
        idle: Duration,
    ) -> Result<Head, MediaError> {
        let inner = self.inner()?;
        let host = url.host_str().unwrap_or("").to_lowercase();
        let client = match route {
            Route::System => &inner.system,
            Route::Doh => {
                if url.scheme() != "https" || !self.cfg.is_cdn(&host) {
                    return Err(MediaError::BadUrl);
                }
                inner.doh.resolve(&host).await?; // typed NXDOMAIN / all-failed before connecting
                &inner.pinned
            }
        };
        let mut request = client.get(url.clone());
        for (name, value) in headers {
            request = request.header(name.as_str(), value.as_str());
        }
        let sent = tokio::time::timeout(idle, request.send()).await;
        let response = match sent {
            Err(_) => {
                if route == Route::Doh {
                    inner.doh.invalidate(&host);
                }
                return Err(MediaError::Net(NetKind::TimedOut));
            }
            Ok(Err(e)) => {
                if route == Route::Doh {
                    inner.doh.invalidate(&host);
                }
                return Err(classify(&e));
            }
            Ok(Ok(r)) => r,
        };
        let location = response
            .headers()
            .get(reqwest::header::LOCATION)
            .and_then(|v| v.to_str().ok())
            .map(str::to_owned);
        Ok(Head {
            status: response.status().as_u16(),
            location,
            content_length: response.content_length(),
            response,
        })
    }

    /// Redirect target when `head` is a followable redirect (Swift: 301/302/303/307/308 with a
    /// `Location` that normalises to https/http and hops left).
    pub(crate) fn redirect_target(
        &self,
        head: &Head,
        current: &Url,
        hops_left: usize,
    ) -> Option<Url> {
        if !matches!(head.status, 301 | 302 | 303 | 307 | 308) || hops_left == 0 {
            return None;
        }
        let next = current.join(head.location.as_deref()?).ok()?;
        crate::naming::normalize_url(&next, self.cfg.allow_plain_http)
    }

    pub(crate) const fn max_redirects() -> usize {
        MAX_REDIRECTS
    }
}

async fn probe_system_dns(cfg: &MediaConfig, host: &str, timeout: Duration) -> bool {
    matches!(
        tokio::time::timeout(timeout, system_lookup(cfg, host)).await,
        Ok(Ok(_))
    )
}

/// Body of `head` into memory. `idle` is the allowed gap between chunks; `route` decides how a
/// stall is reported (DoH stalls are `TimedOut`, like the Swift pinned client's watchdog only for
/// files; for in-memory bodies both routes report the URLError-class timeout).
pub(crate) async fn read_body(
    mut response: reqwest::Response,
    idle: Duration,
    limit: u64,
    content_length: Option<u64>,
) -> Result<Vec<u8>, MediaError> {
    if content_length.is_some_and(|n| n > limit) {
        return Err(MediaError::TooLarge);
    }
    let mut out = Vec::with_capacity(content_length.map_or(0, |n| n.min(8 << 20)) as usize);
    loop {
        match tokio::time::timeout(idle, response.chunk()).await {
            Err(_) => return Err(MediaError::Net(NetKind::TimedOut)),
            Ok(Err(e)) => return Err(classify(&e)),
            Ok(Ok(None)) => return Ok(out),
            Ok(Ok(Some(chunk))) => {
                if (out.len() + chunk.len()) as u64 > limit {
                    return Err(MediaError::TooLarge);
                }
                out.extend_from_slice(&chunk);
            }
        }
    }
}

/// Streams the body into `path` (created/truncated). Fails on stalls longer than `idle`
/// (`stall_error`), bodies over `limit`, truncated bodies and cancellation; the caller deletes
/// `path` on error. `progress(received, total)` runs per chunk (the caller throttles).
pub(crate) async fn stream_to_file(
    mut response: reqwest::Response,
    path: &Path,
    idle: Duration,
    first: Option<Duration>,
    limit: u64,
    stall_error: MediaError,
    mut progress: impl FnMut(u64, Option<u64>),
) -> Result<u64, MediaError> {
    let total = response.content_length();
    if total.is_some_and(|n| n > limit) {
        return Err(MediaError::TooLarge);
    }
    let file = tokio::fs::File::create(path).await?;
    let mut writer = tokio::io::BufWriter::with_capacity(256 * 1024, file);
    let mut received: u64 = 0;
    loop {
        // `first` bounds the wait for the very first byte (time to first byte) only.
        let ttfb = if received == 0 {
            first.filter(|f| *f <= idle)
        } else {
            None
        };
        match tokio::time::timeout(ttfb.unwrap_or(idle), response.chunk()).await {
            Err(_) if ttfb.is_some() => return Err(MediaError::TimedOut),
            Err(_) => return Err(stall_error),
            Ok(Err(e)) => return Err(classify(&e)),
            Ok(Ok(None)) => break,
            Ok(Ok(Some(chunk))) => {
                received += chunk.len() as u64;
                if received > limit {
                    return Err(MediaError::TooLarge);
                }
                writer.write_all(&chunk).await?;
                progress(received, total);
            }
        }
    }
    writer.flush().await?;
    Ok(received)
}

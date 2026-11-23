//! DNS-over-HTTPS resolver for Zalo CDN hosts the system resolver cannot resolve (Swift
//! `DoHResolver`): same endpoints (the two hostname endpoints first, IP-literal ones as the last
//! resort), TTL clamped to 60...600 s, authoritative NXDOMAIN remembered for 300 s, one in-flight
//! query per host.

use std::collections::HashMap;
use std::net::Ipv4Addr;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use futures_util::FutureExt;
use futures_util::future::{BoxFuture, Shared};
use serde::Deserialize;

use crate::error::ResolveError;

pub const DEFAULT_ENDPOINTS: [&str; 4] = [
    "https://dns.google/resolve",
    "https://cloudflare-dns.com/dns-query",
    "https://8.8.8.8/resolve",
    "https://1.1.1.1/dns-query",
];

const NEGATIVE_TTL: Duration = Duration::from_secs(300);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);
const TTL_MIN: i64 = 60;
const TTL_MAX: i64 = 600;

#[derive(Deserialize)]
struct Answer {
    #[serde(rename = "type")]
    kind: i64,
    #[serde(rename = "TTL")]
    ttl: Option<i64>,
    data: String,
}

#[derive(Deserialize)]
struct Reply {
    #[serde(rename = "Status")]
    status: i64,
    #[serde(rename = "Answer")]
    answer: Option<Vec<Answer>>,
}

type Addresses = Vec<Ipv4Addr>;
type Flight = Shared<BoxFuture<'static, Result<Addresses, ResolveError>>>;

#[derive(Default)]
struct State {
    cache: HashMap<String, (Addresses, Instant)>,
    negative: HashMap<String, Instant>,
    in_flight: HashMap<String, Flight>,
}

/// Cached, single-flight DoH resolver (IPv4 `A` records only, like Swift).
pub struct DohResolver {
    client: reqwest::Client,
    endpoints: Vec<String>,
    state: Mutex<State>,
}

impl DohResolver {
    pub fn new(client: reqwest::Client, endpoints: Vec<String>) -> Arc<Self> {
        Arc::new(Self {
            client,
            endpoints,
            state: Mutex::new(State::default()),
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Resolved IPv4 addresses for `host` (cached for the record TTL, clamped to 60...600 s).
    pub async fn resolve(self: &Arc<Self>, host: &str) -> Result<Addresses, ResolveError> {
        let key = host.to_lowercase();
        let flight = {
            let mut state = self.lock();
            if let Some((addresses, expires)) = state.cache.get(&key)
                && *expires > Instant::now()
            {
                return Ok(addresses.clone());
            }
            if let Some(until) = state.negative.get(&key).copied() {
                if until > Instant::now() {
                    return Err(ResolveError::NotFound);
                }
                state.negative.remove(&key);
            }
            if let Some(flight) = state.in_flight.get(&key) {
                flight.clone()
            } else {
                let this = Arc::clone(self);
                let query_key = key.clone();
                // Detached from the caller: one waiter leaving must not cancel the shared query.
                let task = tokio::spawn(async move { this.query(&query_key).await });
                let flight: Flight =
                    async move { task.await.unwrap_or(Err(ResolveError::AllEndpointsFailed)) }
                        .boxed()
                        .shared();
                state.in_flight.insert(key.clone(), flight.clone());
                flight
            }
        };
        let result = flight.await;
        let mut state = self.lock();
        state.in_flight.remove(&key);
        if matches!(result, Err(ResolveError::NotFound)) {
            if state.negative.len() > 2000 {
                state.negative.clear();
            }
            state.negative.insert(key, Instant::now() + NEGATIVE_TTL);
        }
        result
    }

    /// Drops a cached answer (e.g. after every address failed to connect).
    pub fn invalidate(&self, host: &str) {
        self.lock().cache.remove(&host.to_lowercase());
    }

    async fn query(&self, host: &str) -> Result<Addresses, ResolveError> {
        for endpoint in &self.endpoints {
            let Ok(url) = url::Url::parse_with_params(endpoint, &[("name", host), ("type", "A")])
            else {
                continue;
            };
            let sent = self
                .client
                .get(url)
                .header("Accept", "application/dns-json")
                .timeout(REQUEST_TIMEOUT)
                .send()
                .await;
            let Ok(response) = sent else { continue };
            if response.status().as_u16() != 200 {
                continue;
            }
            let Ok(bytes) = response.bytes().await else {
                continue;
            };
            let Ok(reply) = serde_json::from_slice::<Reply>(&bytes) else {
                continue;
            };
            if reply.status == 3 {
                return Err(ResolveError::NotFound); // NXDOMAIN is authoritative
            }
            if reply.status != 0 {
                continue;
            }
            let records: Vec<&Answer> = reply
                .answer
                .iter()
                .flatten()
                .filter(|a| a.kind == 1)
                .collect();
            let addresses: Addresses = records
                .iter()
                .filter_map(|a| a.data.parse::<Ipv4Addr>().ok())
                .collect();
            if addresses.is_empty() {
                continue;
            }
            let ttl = records.iter().filter_map(|a| a.ttl).min().unwrap_or(60);
            let ttl = ttl.clamp(TTL_MIN, TTL_MAX).unsigned_abs();
            self.lock().cache.insert(
                host.to_owned(),
                (addresses.clone(), Instant::now() + Duration::from_secs(ttl)),
            );
            return Ok(addresses);
        }
        tracing::debug!("doh: all endpoints failed");
        Err(ResolveError::AllEndpointsFailed)
    }
}

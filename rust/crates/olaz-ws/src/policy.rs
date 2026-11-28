//! Reconnect/backoff policy, endpoint rotation, socket URL and handshake headers.

use std::time::Duration;

use crate::consts::*;

/// `runLoop` backoff: starts at 2s; after each session, reset to 2s when the
/// session lasted more than 30s, otherwise `min(30, backoff * 2)`; the endpoint
/// index always advances. The caller sleeps the returned delay.
#[derive(Debug, Clone, PartialEq)]
pub struct ReconnectPolicy {
    endpoint_count: usize,
    endpoint_idx: usize,
    initial_backoff_secs: f64,
    max_backoff_secs: f64,
    stable_session_secs: f64,
    backoff_secs: f64,
}

impl ReconnectPolicy {
    pub const INITIAL_BACKOFF_SECS: f64 = 2.0;
    pub const MAX_BACKOFF_SECS: f64 = 30.0;
    pub const STABLE_SESSION_SECS: f64 = 30.0;

    pub fn new(endpoint_count: usize) -> Self {
        Self::with_timings(
            endpoint_count,
            Self::INITIAL_BACKOFF_SECS,
            Self::MAX_BACKOFF_SECS,
            Self::STABLE_SESSION_SECS,
        )
    }

    /// Same policy with custom timings (tests / tuning); `new` uses the Swift constants.
    pub fn with_timings(
        endpoint_count: usize,
        initial_backoff_secs: f64,
        max_backoff_secs: f64,
        stable_session_secs: f64,
    ) -> Self {
        Self {
            endpoint_count,
            endpoint_idx: 0,
            initial_backoff_secs,
            max_backoff_secs,
            stable_session_secs,
            backoff_secs: initial_backoff_secs,
        }
    }

    /// Index into the endpoint list for the next session (`idx % count`); None if empty.
    pub fn current_endpoint(&self) -> Option<usize> {
        (self.endpoint_count > 0).then(|| self.endpoint_idx % self.endpoint_count)
    }

    /// Call when a session ended (not by `stop`); returns how long to wait before reconnecting.
    pub fn on_session_ended(&mut self, connected_for: Duration) -> Duration {
        if connected_for.as_secs_f64() > self.stable_session_secs {
            self.backoff_secs = self.initial_backoff_secs;
        } else {
            self.backoff_secs = (self.backoff_secs * 2.0).min(self.max_backoff_secs);
        }
        self.endpoint_idx += 1;
        Duration::from_secs_f64(self.backoff_secs)
    }
}

/// `buildSocketURL`: guarantees a `/` before the query, keeps any existing query
/// and appends `zpw_ver`, `zpw_type`, `t=<ms>`.
pub fn build_socket_url(base: &str, now_ms: i64) -> String {
    let (host_part, existing_query) = match base.split_once('?') {
        Some((h, q)) => (h, Some(q)),
        None => (base, None),
    };
    // Swift: `components(separatedBy: "://").dropFirst().first ?? hostPart`
    let after_scheme = host_part.split("://").nth(1).unwrap_or(host_part);
    let mut full = if after_scheme.contains('/') {
        host_part.to_owned()
    } else {
        format!("{host_part}/")
    };
    full.push('?');
    if let Some(q) = existing_query.filter(|q| !q.is_empty()) {
        full.push_str(q);
        full.push('&');
    }
    full.push_str(&format!("zpw_ver={ZPW_VER}&zpw_type={ZPW_TYPE}&t={now_ms}"));
    full
}

/// Handshake headers set by `runSingleSession`.
pub fn connect_headers(
    host: &str,
    zpw_sek: &str,
    preferred_languages: &[String],
) -> Vec<(&'static str, String)> {
    olaz_client::headers::websocket_headers(host, zpw_sek, preferred_languages)
}

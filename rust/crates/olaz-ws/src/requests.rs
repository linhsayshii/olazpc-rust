//! `requestAsyncV2` waiter bookkeeping (`requestWaiters`), as pure state.

use std::collections::HashMap;

use crate::files::WaiterToken;

/// Pending `reqId -> waiter` map. The transport owns the actual channel and
/// keys it by [`WaiterToken`].
#[derive(Debug, Default)]
pub struct RequestWaiters {
    waiters: HashMap<String, WaiterToken>,
}

impl RequestWaiters {
    /// Registers a waiter. Returns a previously registered token for the same
    /// `reqId` (Swift silently dropped it; the transport should resolve it with `None`).
    pub fn register(&mut self, req_id: &str, token: WaiterToken) -> Option<WaiterToken> {
        self.waiters.insert(req_id.to_owned(), token)
    }

    pub fn is_pending(&self, req_id: &str) -> bool {
        self.waiters.contains_key(req_id)
    }

    /// `finishRequestWaiter`: removes and returns the waiter (reply, timeout or send failure).
    pub fn finish(&mut self, req_id: &str) -> Option<WaiterToken> {
        self.waiters.remove(req_id)
    }

    /// Fails every pending waiter (disconnect / stop). Sorted by token for determinism.
    pub fn fail_all(&mut self) -> Vec<(String, WaiterToken)> {
        let mut all: Vec<_> = self.waiters.drain().collect();
        all.sort_by_key(|(_, t)| *t);
        all
    }

    pub fn len(&self) -> usize {
        self.waiters.len()
    }

    pub fn is_empty(&self) -> bool {
        self.waiters.is_empty()
    }
}

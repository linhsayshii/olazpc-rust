//! Single-flight table (Swift `MediaLoader.join`) and the progress fan-out hub (`FileProgress`).
//!
//! Concurrent requests for one key share one task. The task is aborted when the last waiter goes
//! away (every caller cancelled / dropped its future), so cancelling a Swift `Task` really stops
//! the transfer.

use std::collections::HashMap;
use std::future::Future;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use tokio::sync::watch;
use tokio::task::AbortHandle;

use crate::error::MediaError;

pub type ProgressFn = Arc<dyn Fn(f64) + Send + Sync>;

/// What a flight produces.
#[derive(Clone, Debug)]
pub enum Output {
    Bytes(Arc<Vec<u8>>),
    Path(PathBuf),
}

/// Fan-out of download progress to every caller sharing one in-flight download.
#[derive(Default)]
pub struct ProgressHub {
    inner: Mutex<HubState>,
    next_id: AtomicU64,
}

#[derive(Default)]
struct HubState {
    observers: HashMap<u64, ProgressFn>,
    last: f64,
}

impl ProgressHub {
    fn lock(&self) -> std::sync::MutexGuard<'_, HubState> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn add(&self, observer: ProgressFn) -> u64 {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.lock().observers.insert(id, observer);
        id
    }

    pub fn remove(&self, id: u64) {
        self.lock().observers.remove(&id);
    }

    /// A new attempt (redirect, DoH fallback) restarts the transfer from zero.
    pub fn reset(&self) {
        let callbacks: Vec<ProgressFn> = {
            let mut state = self.lock();
            state.last = 0.0;
            state.observers.values().cloned().collect()
        };
        for callback in callbacks {
            callback(0.0);
        }
    }

    /// Throttled to ~0.5% steps; unknown totals report nothing.
    pub fn report(&self, received: u64, total: Option<u64>) {
        let Some(total) = total.filter(|t| *t > 0) else {
            return;
        };
        let fraction = (received as f64 / total as f64).min(1.0);
        let callbacks: Vec<ProgressFn> = {
            let mut state = self.lock();
            if fraction - state.last < 0.005 {
                return;
            }
            state.last = fraction;
            state.observers.values().cloned().collect()
        };
        for callback in callbacks {
            callback(fraction);
        }
    }
}

type Slot = Option<Result<Output, MediaError>>;

struct Entry {
    waiters: usize,
    abort: Option<AbortHandle>,
    done: bool,
    tx: watch::Sender<Slot>,
    hub: Arc<ProgressHub>,
}

#[derive(Default)]
pub(crate) struct Flights {
    map: Arc<Mutex<HashMap<String, Entry>>>,
}

struct Waiter {
    map: Arc<Mutex<HashMap<String, Entry>>>,
    key: String,
    hub: Arc<ProgressHub>,
    observer: Option<u64>,
}

impl Drop for Waiter {
    fn drop(&mut self) {
        if let Some(id) = self.observer {
            self.hub.remove(id);
        }
        let mut map = self.map.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(entry) = map.get_mut(&self.key) else {
            return;
        };
        entry.waiters = entry.waiters.saturating_sub(1);
        if entry.waiters == 0
            && !entry.done
            && let Some(abort) = map.remove(&self.key).and_then(|e| e.abort)
        {
            abort.abort();
        }
    }
}

impl Flights {
    /// Joins the flight for `key`, starting it with `start` when none is running. `observer`
    /// (progress 0...1) is removed when the caller leaves.
    pub(crate) async fn join<F, Fut>(
        &self,
        key: &str,
        observer: Option<ProgressFn>,
        start: F,
    ) -> Result<Output, MediaError>
    where
        F: FnOnce(Arc<ProgressHub>) -> Fut,
        Fut: Future<Output = Result<Output, MediaError>> + Send + 'static,
    {
        let (mut rx, hub) = {
            let mut map = self.map.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(entry) = map.get_mut(key) {
                entry.waiters += 1;
                (entry.tx.subscribe(), Arc::clone(&entry.hub))
            } else {
                let hub = Arc::new(ProgressHub::default());
                let (tx, rx) = watch::channel(None);
                let fut = start(Arc::clone(&hub));
                let shared_map = Arc::clone(&self.map);
                let task_key = key.to_owned();
                let sender = tx.clone();
                let handle = tokio::spawn(async move {
                    let result = fut.await;
                    {
                        let mut map = shared_map.lock().unwrap_or_else(PoisonError::into_inner);
                        if let Some(entry) = map.get_mut(&task_key) {
                            entry.done = true;
                        }
                        map.remove(&task_key);
                    }
                    let _ = sender.send(Some(result));
                });
                map.insert(
                    key.to_owned(),
                    Entry {
                        waiters: 1,
                        abort: Some(handle.abort_handle()),
                        done: false,
                        tx,
                        hub: Arc::clone(&hub),
                    },
                );
                (rx, hub)
            }
        };
        let observer_id = observer.map(|o| hub.add(o));
        let _waiter = Waiter {
            map: Arc::clone(&self.map),
            key: key.to_owned(),
            hub,
            observer: observer_id,
        };
        match rx.wait_for(Option::is_some).await {
            Ok(slot) => slot.clone().unwrap_or(Err(MediaError::Cancelled)),
            Err(_) => Err(MediaError::Cancelled), // task aborted before finishing
        }
    }

    pub(crate) fn len(&self) -> usize {
        self.map
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .len()
    }
}

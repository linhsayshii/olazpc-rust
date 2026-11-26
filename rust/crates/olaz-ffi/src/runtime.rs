//! The one tokio runtime behind every async export.

use std::future::Future;
use std::sync::LazyLock;

use tokio::runtime::{Builder, Runtime};

use crate::error::CoreError;

const MIN_WORKER_THREADS: usize = 4;
const MAX_WORKER_THREADS: usize = 8;

fn worker_thread_count() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get().clamp(MIN_WORKER_THREADS, MAX_WORKER_THREADS))
        .unwrap_or(MIN_WORKER_THREADS)
}

static RUNTIME: LazyLock<Result<Runtime, String>> = LazyLock::new(|| {
    Builder::new_multi_thread()
        .worker_threads(worker_thread_count())
        .thread_name("olaz-core")
        .enable_all()
        .build()
        .map_err(|e| e.to_string())
});

/// The shared runtime (created on first use).
pub(crate) fn runtime() -> Result<&'static Runtime, CoreError> {
    RUNTIME.as_ref().map_err(|message| CoreError::Internal {
        message: format!("tokio runtime: {message}"),
    })
}

/// Runs `fut` on the shared runtime and awaits its result from any executor.
pub(crate) async fn run<T, F>(fut: F) -> Result<T, CoreError>
where
    T: Send + 'static,
    F: Future<Output = T> + Send + 'static,
{
    Ok(runtime()?.spawn(fut).await?)
}

/// Runs blocking `f` on the runtime's blocking pool and awaits it from any executor.
pub(crate) async fn blocking<T, F>(f: F) -> Result<T, CoreError>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    Ok(runtime()?.spawn_blocking(f).await?)
}

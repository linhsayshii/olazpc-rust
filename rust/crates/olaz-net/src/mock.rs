//! Scriptable [`Transport`] for tests (no network).

use std::collections::VecDeque;
use std::future::Future;
use std::sync::{Mutex, PoisonError};

use crate::error::{NetError, NetworkErrorKind};
use crate::http::{RawResponse, RequestSpec, Transport};

type Handler = Box<dyn FnMut(&RequestSpec) -> Result<RawResponse, NetError> + Send>;

/// Records every request and answers from a closure or a FIFO script.
pub struct MockTransport {
    handler: Mutex<Handler>,
    log: Mutex<Vec<RequestSpec>>,
}

impl MockTransport {
    /// Answers each request with `f`.
    pub fn from_fn(
        f: impl FnMut(&RequestSpec) -> Result<RawResponse, NetError> + Send + 'static,
    ) -> Self {
        Self {
            handler: Mutex::new(Box::new(f)),
            log: Mutex::new(Vec::new()),
        }
    }

    /// Answers requests in order from `script`; an exhausted script is a network error.
    pub fn scripted(script: Vec<Result<RawResponse, NetError>>) -> Self {
        let mut queue: VecDeque<_> = script.into();
        Self::from_fn(move |_| {
            queue.pop_front().unwrap_or_else(|| {
                Err(NetError::network(
                    NetworkErrorKind::Other,
                    "mock script exhausted",
                ))
            })
        })
    }

    /// Every request seen so far, oldest first.
    pub fn requests(&self) -> Vec<RequestSpec> {
        self.log
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    fn respond(&self, request: &RequestSpec) -> Result<RawResponse, NetError> {
        self.log
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(request.clone());
        let mut handler = self.handler.lock().unwrap_or_else(PoisonError::into_inner);
        (*handler)(request)
    }
}

impl Transport for MockTransport {
    fn send(
        &self,
        request: RequestSpec,
    ) -> impl Future<Output = Result<RawResponse, NetError>> + Send {
        let result = self.respond(&request);
        async move { result }
    }
}

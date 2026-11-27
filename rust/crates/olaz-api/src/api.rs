use std::collections::HashMap;
use std::sync::Arc;
use std::sync::{Mutex, MutexGuard, PoisonError};

use olaz_net::{ApiRequest, MultipartPart, SessionClient, Transport};
use serde_json::{Map, Value};

use crate::error::ApiError;

/// Swift `ZaloJSONBox.dict`: a decoded server answer.
pub type JsonObject = Map<String, Value>;

/// Swift `SendMessageResult`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SendMessageResult {
    pub msg_id: String,
    pub cli_msg_id: String,
    pub ts_ms: i64,
}

/// Per-session values Swift kept as stored properties on `ZaloSessionClient`.
#[derive(Debug, Default)]
pub(crate) struct ApiState {
    pub archived_version: i64,
    pub label_version: i64,
    pub cloud_is_old_by_conv: HashMap<String, bool>,
    pub global_id_to_uid: HashMap<String, String>,
    pub uid_to_global_id: HashMap<String, String>,
}

/// Chat-path API calls over a [`SessionClient`].
pub struct ZaloApi<T: Transport> {
    client: Arc<SessionClient<T>>,
    state: Mutex<ApiState>,
}

impl<T: Transport> ZaloApi<T> {
    pub fn new(client: SessionClient<T>) -> Self {
        Self::from_shared(Arc::new(client))
    }

    /// Wraps a session client that other owners (e.g. the FFI session object) share.
    pub fn from_shared(client: Arc<SessionClient<T>>) -> Self {
        Self {
            client,
            state: Mutex::new(ApiState::default()),
        }
    }

    /// The wrapped session client (login, QR, session status, snapshot).
    pub fn client(&self) -> &SessionClient<T> {
        &self.client
    }

    /// The client when this is its only owner, else the shared handle back.
    pub fn into_client(self) -> Result<SessionClient<T>, Arc<SessionClient<T>>> {
        Arc::try_unwrap(self.client)
    }

    /// Resets per-session API state (`cloud_is_old_by_conv`, `archived_version`, `label_version`,
    /// and global-id caches) on log out / session reset.
    pub fn reset_state(&self) {
        *self.state() = ApiState::default();
    }

    pub(crate) fn state(&self) -> MutexGuard<'_, ApiState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(crate) fn imei(&self) -> String {
        self.client.imei()
    }

    pub(crate) fn now_ms(&self) -> i64 {
        self.client.now_ms()
    }

    /// Version counter returned by `archivedchat/list` (Swift `archivedVersion`).
    pub fn archived_version(&self) -> i64 {
        self.state().archived_version
    }

    /// Version counter returned by `convlabel/get` (Swift `labelVersion`).
    pub fn label_version(&self) -> i64 {
        self.state().label_version
    }

    pub(crate) async fn get(&self, req: ApiRequest) -> Result<JsonObject, ApiError> {
        Ok(self.client.get(&req).await?)
    }

    pub(crate) async fn post(&self, req: ApiRequest) -> Result<JsonObject, ApiError> {
        Ok(self.client.post(&req).await?)
    }

    pub(crate) async fn post_multipart(
        &self,
        req: ApiRequest,
        part: MultipartPart,
    ) -> Result<JsonObject, ApiError> {
        Ok(self.client.post_multipart(&req, &part).await?)
    }
}

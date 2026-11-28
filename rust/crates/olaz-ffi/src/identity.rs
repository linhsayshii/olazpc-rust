//! Pinned native protocol identity exposed to Swift (never inferred from runtime assets).
use olaz_client::identity::{CLIENT_TYPE, CLIENT_VERSION, USER_AGENT, WEB_CLIENT_TYPE, WS_ORIGIN};

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ClientIdentityRecord {
    pub client_version: String,
    pub client_type: String,
    pub web_client_type: String,
    pub user_agent: String,
    pub ws_origin: String,
}

#[uniffi::export]
pub fn client_identity() -> ClientIdentityRecord {
    ClientIdentityRecord {
        client_version: CLIENT_VERSION.to_owned(),
        client_type: CLIENT_TYPE.to_owned(),
        web_client_type: WEB_CLIENT_TYPE.to_owned(),
        user_agent: USER_AGENT.to_owned(),
        ws_origin: WS_ORIGIN.to_owned(),
    }
}

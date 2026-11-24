//! Mirror of libsignal's `storage.proto` session messages (v0.73.0).
//!
//! libsignal keeps its generated types private; `SessionRecord::deserialize` / `serialize` speak
//! this wire format, so mirroring it lets the converter build and read records without any
//! change to the library API. Only the fields a Zalo (X3DH, v3) session uses are modelled; unknown
//! fields survive a decode/encode round trip only if modelled here, which is fine because the
//! converter always rebuilds records from scratch.

#[derive(Clone, PartialEq, prost::Message)]
pub struct RecordStructure {
    #[prost(message, optional, tag = "1")]
    pub current_session: Option<SessionStructure>,
    /// Serialized `SessionStructure`s, most recent first.
    #[prost(bytes = "vec", repeated, tag = "2")]
    pub previous_sessions: Vec<Vec<u8>>,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct SessionStructure {
    #[prost(uint32, tag = "1")]
    pub session_version: u32,
    #[prost(bytes = "vec", tag = "2")]
    pub local_identity_public: Vec<u8>,
    #[prost(bytes = "vec", tag = "3")]
    pub remote_identity_public: Vec<u8>,
    #[prost(bytes = "vec", tag = "4")]
    pub root_key: Vec<u8>,
    #[prost(uint32, tag = "5")]
    pub previous_counter: u32,
    #[prost(message, optional, tag = "6")]
    pub sender_chain: Option<Chain>,
    #[prost(message, repeated, tag = "7")]
    pub receiver_chains: Vec<Chain>,
    #[prost(message, optional, tag = "9")]
    pub pending_pre_key: Option<PendingPreKey>,
    #[prost(uint32, tag = "10")]
    pub remote_registration_id: u32,
    #[prost(uint32, tag = "11")]
    pub local_registration_id: u32,
    #[prost(bytes = "vec", tag = "13")]
    pub alice_base_key: Vec<u8>,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct Chain {
    #[prost(bytes = "vec", tag = "1")]
    pub sender_ratchet_key: Vec<u8>,
    #[prost(bytes = "vec", tag = "2")]
    pub sender_ratchet_key_private: Vec<u8>,
    #[prost(message, optional, tag = "3")]
    pub chain_key: Option<ChainKey>,
    #[prost(message, repeated, tag = "4")]
    pub message_keys: Vec<MessageKey>,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct ChainKey {
    #[prost(uint32, tag = "1")]
    pub index: u32,
    #[prost(bytes = "vec", tag = "2")]
    pub key: Vec<u8>,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct MessageKey {
    #[prost(uint32, tag = "1")]
    pub index: u32,
    #[prost(bytes = "vec", tag = "2")]
    pub cipher_key: Vec<u8>,
    #[prost(bytes = "vec", tag = "3")]
    pub mac_key: Vec<u8>,
    #[prost(bytes = "vec", tag = "4")]
    pub iv: Vec<u8>,
    /// When set, the three expanded keys are empty and derive from this seed.
    #[prost(bytes = "vec", tag = "5")]
    pub seed: Vec<u8>,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct PendingPreKey {
    #[prost(uint32, optional, tag = "1")]
    pub pre_key_id: Option<u32>,
    #[prost(int32, tag = "3")]
    pub signed_pre_key_id: i32,
    #[prost(bytes = "vec", tag = "2")]
    pub base_key: Vec<u8>,
    /// Unix seconds.
    #[prost(uint64, tag = "4")]
    pub timestamp: u64,
}

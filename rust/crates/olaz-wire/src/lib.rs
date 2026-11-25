//! Wire parser: port of `Protocol/ZaloWireParser.swift`.
//!
//! Turns raw Zalo wire JSON (HTTP history/poll envelopes and `zpw_ws` push bodies) into
//! [`ChatMessage`] / [`ParsedWireEvent`] values, and converts messages to and from the canonical JSON
//! kept in the SQLite store (`StoredMessage.raw_json_data`).
//!
//! Input JSON must be parsed with [`lossless::parse_object`] / [`lossless::parse_any`] (the port of
//! `JSONLossless`) so 64-bit ids survive. Nothing here slices strings by server offsets; mention `pos` /
//! `len` are raw UTF-16 offsets kept as integers.

#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used))]

pub mod batch;
pub mod codec;
pub mod envelope;
pub mod ids;
pub mod lossless;
pub mod message;
pub mod model;
pub mod signal;
pub mod util;

pub use batch::{extract_batch_events, extract_profiles_map, sort_reaction_events_chronologically};
pub use codec::{decode_stored_message, encode_chat_message, serialize_kind};
pub use envelope::{
    TYPED_CHAT_CMDS, collect_name_uids, envelope_contains_signal_cipher, is_plain_chat_envelope,
    is_typed_chat_cmd,
};
pub use ids::{
    clean_group_id, group_conv_id, is_group_id, normalize_thread_id_from_list,
    sanitize_profile_uid, strip_user_prefix,
};
pub use message::{
    CMD_PULL_MSG_GROUP, CMD_PUSH_MSG_GROUP, NameLookup, NameLookupFn, WireParseOptions,
    normalize_timestamp_ms, normalize_timestamp_ms_at, normalized_file_name, normalized_msg_type,
    optional_timestamp_ms, parse_wire_message, preview_label, reaction_client_msg_type,
    reaction_icon, reaction_spec, sticker_cdn_url, unique_non_empty_strings, zdb_msg_type,
};
pub use model::{
    Availability, CardButton, ChatMessage, ContactCard, DeleteMode, ECard, ECardStyle, Kind,
    LocationInfo, Mention, MessageMenu, OaPart, ParsedWireEvent, PollInfo, Quote, Reaction,
    ReactionIcon, StarMode, Status, StoredMessage, TextStyle, UNKNOWN_NAME, text_properties_json,
    web_link_sanitized,
};
pub use signal::{
    is_signal_ciphertext, removing_percent_encoding, url_has_undecrypted_signal_cipher,
};

#[cfg(test)]
mod tests;

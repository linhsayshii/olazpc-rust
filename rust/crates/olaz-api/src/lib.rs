//! Rust port of the core-chat subset of Olaz `ZaloAPIService.swift`.
//!
//! [`ZaloApi`] wraps an [`olaz_net::SessionClient`] and exposes the API calls the chat path needs:
//! conversation lists (preload, pins, archive, mute, labels, groups, friends, friend-request lists,
//! aliases, profiles, hidden chats, delete), message history (1-1 preload, group and self cloud
//! paging), the HTTP long-poll queue, sending text (plain, quoted, E2EE envelope), typing, seen,
//! unread marks, recall, delete-for-me, reactions, and auto-delete settings.
//!
//! Every method is a request builder (service, path, params payload with the exact Swift keys and
//! JSON types) plus a response parser. The pure builders ([`build_recall_message_request`],
//! [`build_reaction_request`], [`build_e2ee_message_request_payload`], ...) are free functions so tests
//! can compare payloads without a transport. Login, QR and session state live in `olaz-net`
//! (reach them with [`ZaloApi::client`]).
//!
//! Not ported here (later waves): media upload and file send, polls and reminders, cloud, stickers,
//! group management, board pins, contact cards, friend-request mutations, call signalling, global-id
//! encrypt/decrypt, mute set.

#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used))]

mod api;
mod autodelete;
mod cloud;
mod conversations;
mod e2ee;
mod error;
mod history;
mod messaging;
mod poll;
mod profiles;
mod util;

#[cfg(test)]
mod tests;

pub use api::{JsonObject, SendMessageResult, ZaloApi};
pub use autodelete::{
    AUTO_DELETE_OPTIONS, AutoDeleteFetchOutcome, auto_delete_label, auto_delete_remaining,
    build_update_auto_delete_payload, parse_auto_delete_settings,
};
pub use cloud::{CloudPlanKind, CloudServerSnapshot, parse_cloud_usage_snapshot};
pub use conversations::{
    HiddenConversationsSnapshot, PollOutcome, parse_hidden_conversations_response,
    received_friend_request_rows,
};
pub use e2ee::{
    E2eeListParams, build_e2ee_ext_json, build_e2ee_list_param_entry,
    build_e2ee_message_request_payload, extract_e2ee_send_response,
};
pub use error::ApiError;
pub use messaging::{
    CallSpec, ReactionParams, ReactionRequestSpec, RecallParams, SendTextArgs, SendTextParams,
    build_reaction_request, build_recall_message_request,
};
pub use poll::{PollQueueCursor, PollState};

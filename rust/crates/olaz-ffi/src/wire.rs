//! Wire parsing (`olaz-wire`): typed core fields plus the canonical store row.

use olaz_wire::{NameLookup, ParsedWireEvent, WireParseOptions};
use serde_json::Value;

use crate::chat::ChatMessageRecord;
use crate::error::CoreError;

/// Arguments of `parseWireMessage` / `extractBatchEvents` (without the name-lookup closure).
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct WireOptions {
    /// `zpw_ws` command number the payload arrived on (0 when unknown).
    #[uniffi(default = 0)]
    pub cmd: u16,
    #[uniffi(default = None)]
    pub fallback_conv_id: Option<String>,
    #[uniffi(default = None)]
    pub is_group_hint: Option<bool>,
    #[uniffi(default = None)]
    pub self_conv_id: Option<String>,
    /// Pre-resolved contact names (the Swift `nameLookup` closure, evaluated up front by uid).
    #[uniffi(default = [])]
    pub names: Vec<NameEntry>,
}

/// One cached contact (`nameLookup` result for `uid`).
#[derive(Debug, Clone, uniffi::Record)]
pub struct NameEntry {
    pub uid: String,
    pub name: String,
    pub avatar: String,
}

/// Store-row facts of a parsed message that the typed [`ChatMessageRecord`] does not carry. Swift rebuilds its
/// `StoredMessage` from the record plus these; `raw_json` is the canonical JSON saved as-is (never parsed in Swift).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WireStored {
    pub kind_tag: String,
    /// Stored `sender_avatar` column (the raw string; the record holds the parsed URL).
    pub sender_avatar: String,
    /// Status column was `e2ee_locked` (undecryptable E2EE echo).
    pub locked: bool,
    pub raw_json: Vec<u8>,
}

/// One parsed realtime / history event (`ParsedWireEvent`).
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
// Short-lived FFI value; boxing would not cross uniffi anyway.
#[allow(clippy::large_enum_variant)]
pub enum WireEvent {
    Message {
        /// Fully typed message (kind, quote, reactions, mentions, menu...).
        message: ChatMessageRecord,
        stored: WireStored,
    },
    Reaction {
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        sender_id: String,
        r_type: String,
        r_icon: String,
        event_id: String,
        react_client_id: String,
        ts_ms: i64,
        seq_id: i64,
        sender_name: String,
    },
    Undo {
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
    },
    Delete {
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
    },
    Typing {
        conv_id: String,
        sender_id: String,
        is_group: bool,
    },
    Ignore,
}

pub(crate) fn convert(event: ParsedWireEvent) -> WireEvent {
    match event {
        ParsedWireEvent::Message(chat, stored) => {
            let stored = *stored;
            WireEvent::Message {
                message: (*chat).into(),
                stored: WireStored {
                    kind_tag: stored.kind_tag,
                    sender_avatar: stored.sender_avatar,
                    locked: stored.status == "e2ee_locked",
                    raw_json: stored.raw_json_data,
                },
            }
        }
        ParsedWireEvent::Reaction {
            conv_id,
            msg_id,
            cli_msg_id,
            sender_id,
            r_type,
            r_icon,
            event_id,
            react_client_id,
            ts_ms,
            seq_id,
            sender_name,
        } => WireEvent::Reaction {
            conv_id,
            msg_id,
            cli_msg_id,
            sender_id,
            r_type,
            r_icon,
            event_id,
            react_client_id,
            ts_ms,
            seq_id,
            sender_name,
        },
        ParsedWireEvent::Undo {
            conv_id,
            msg_id,
            cli_msg_id,
        } => WireEvent::Undo {
            conv_id,
            msg_id,
            cli_msg_id,
        },
        ParsedWireEvent::Delete {
            conv_id,
            msg_id,
            cli_msg_id,
        } => WireEvent::Delete {
            conv_id,
            msg_id,
            cli_msg_id,
        },
        ParsedWireEvent::Typing {
            conv_id,
            sender_id,
            is_group,
        } => WireEvent::Typing {
            conv_id,
            sender_id,
            is_group,
        },
        ParsedWireEvent::Ignore => WireEvent::Ignore,
    }
}

pub(crate) fn with_options<R>(o: &WireOptions, f: impl FnOnce(&WireParseOptions<'_>) -> R) -> R {
    let table: std::collections::HashMap<&str, NameLookup> = o
        .names
        .iter()
        .map(|n| {
            (
                n.uid.as_str(),
                NameLookup {
                    name: n.name.clone(),
                    avatar: n.avatar.clone(),
                },
            )
        })
        .collect();
    let lookup = |uid: &str| table.get(uid).cloned();
    let opts = WireParseOptions {
        cmd: o.cmd,
        fallback_conv_id: o.fallback_conv_id.as_deref(),
        is_group_hint: o.is_group_hint,
        self_conv_id: o.self_conv_id.as_deref(),
        name_lookup: if table.is_empty() {
            None
        } else {
            Some(&lookup)
        },
    };
    f(&opts)
}

/// Parses one wire message object (a `zpw_ws` push body entry) given as JSON text. Big integer ids
/// are read losslessly.
#[uniffi::export]
pub fn parse_wire_event(
    json: String,
    my_uid: String,
    options: WireOptions,
) -> Result<WireEvent, CoreError> {
    let raw = olaz_json::parse_object_str(&json).ok_or_else(|| CoreError::Parse {
        message: "wire event is not a JSON object".to_owned(),
    })?;
    Ok(with_options(&options, |o| {
        convert(olaz_wire::parse_wire_message(&raw, &my_uid, o))
    }))
}

/// Walks a whole envelope (history response, push body, polling result) and parses every message
/// and live reaction in it (`extractBatchEvents`).
#[uniffi::export]
pub fn parse_wire_batch(
    json: String,
    my_uid: String,
    options: WireOptions,
) -> Result<Vec<WireEvent>, CoreError> {
    let root: Value = olaz_json::parse_any(json.as_bytes()).ok_or_else(|| CoreError::Parse {
        message: "envelope is not valid JSON".to_owned(),
    })?;
    Ok(with_options(&options, |o| {
        olaz_wire::extract_batch_events(&root, &my_uid, o)
            .into_iter()
            .map(convert)
            .collect()
    }))
}

/// [`parse_wire_batch`] over the raw JSON bytes (no UTF-8 round trip for callers that already hold `Data`).
#[uniffi::export]
pub fn parse_wire_batch_bytes(
    json: Vec<u8>,
    my_uid: String,
    options: WireOptions,
) -> Result<Vec<WireEvent>, CoreError> {
    let root: Value = olaz_json::parse_any(&json).ok_or_else(|| CoreError::Parse {
        message: "envelope is not valid JSON".to_owned(),
    })?;
    Ok(with_options(&options, |o| {
        olaz_wire::extract_batch_events(&root, &my_uid, o)
            .into_iter()
            .map(convert)
            .collect()
    }))
}

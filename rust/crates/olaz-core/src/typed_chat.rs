//! Typed hot-path envelope parsing for plain chat WS frames (U2).
//!
//! Mirrors `olaz-ffi/src/ws.rs` `typed_envelope` + `WirePayload::resolve`:
//! plain chat envelopes (`is_plain_chat_envelope`) are parsed off the MainActor using the
//! per-session name cache (`SharedParse`). Swift checks/updates names via
//! [`WirePayloadHandle::resolve`], which returns `None` when the cached parse is already exact.

use std::collections::HashMap;
use std::fmt;
use std::sync::{Arc, Mutex, PoisonError};

use olaz_json::to_swift_json_string;
use olaz_wire::{
    NameLookup, ParsedWireEvent, WireParseOptions, collect_name_uids, extract_batch_events,
    is_plain_chat_envelope,
};
use serde_json::{Map, Value};

/// Per-session parse context: signed-in uid, "My Cloud" id, and cached contact names.
#[derive(Default)]
pub struct ParseState {
    pub my_uid: String,
    pub self_conv_id: Option<String>,
    pub names: HashMap<String, NameLookup>,
}

/// Thread-safe handle to a session's [`ParseState`].
pub type SharedParse = Arc<Mutex<ParseState>>;

/// Creates a new [`SharedParse`] initialized with `my_uid` and `self_conv_id`.
#[must_use]
pub fn new_shared_parse(my_uid: String, self_conv_id: Option<String>) -> SharedParse {
    Arc::new(Mutex::new(ParseState {
        my_uid,
        self_conv_id,
        names: HashMap::new(),
    }))
}

fn parse_with(
    cmd: u16,
    root: &Value,
    my_uid: &str,
    self_conv_id: Option<&str>,
    names: &HashMap<String, NameLookup>,
) -> Vec<ParsedWireEvent> {
    let lookup = |uid: &str| names.get(uid).cloned();
    let opts = WireParseOptions {
        cmd,
        fallback_conv_id: None,
        is_group_hint: None,
        self_conv_id,
        name_lookup: if names.is_empty() {
            None
        } else {
            Some(&lookup)
        },
    };
    extract_batch_events(root, my_uid, &opts)
}

/// A plain chat envelope retained alongside its pre-parsed [`ParsedWireEvent`]s so the host can
/// verify or update contact names via [`Self::resolve`].
pub struct WirePayloadHandle {
    cmd: u16,
    root: Value,
    uids: Vec<String>,
    used_my_uid: String,
    used_self_conv_id: Option<String>,
    used_names: Vec<Option<NameLookup>>,
    state: SharedParse,
}

impl WirePayloadHandle {
    /// Sender / quote-owner uids referenced by this envelope.
    #[must_use]
    pub fn uids(&self) -> &[String] {
        &self.uids
    }

    /// Returns `None` when the delivered events were parsed with the exact same `my_uid`,
    /// `self_conv_id`, and `names`; otherwise re-parses and updates the shared name cache.
    #[must_use]
    pub fn resolve(
        &self,
        my_uid: &str,
        self_conv_id: Option<&str>,
        names: &[(String, NameLookup)],
    ) -> Option<Vec<ParsedWireEvent>> {
        let wanted: HashMap<&str, &NameLookup> =
            names.iter().map(|(uid, n)| (uid.as_str(), n)).collect();
        let same_names = self.uids.iter().zip(&self.used_names).all(|(uid, used)| {
            match (wanted.get(uid.as_str()), used) {
                (None, None) => true,
                (Some(w), Some(u)) => w.name == u.name && w.avatar == u.avatar,
                _ => false,
            }
        });
        if same_names
            && my_uid == self.used_my_uid
            && self_conv_id == self.used_self_conv_id.as_deref()
        {
            return None;
        }
        let mut table: HashMap<String, NameLookup> = HashMap::with_capacity(names.len());
        for (uid, lookup) in names {
            table.insert(uid.clone(), lookup.clone());
        }
        let events = parse_with(self.cmd, &self.root, my_uid, self_conv_id, &table);
        let mut st = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        st.my_uid = my_uid.to_owned();
        st.self_conv_id = self_conv_id.map(str::to_owned);
        for uid in &self.uids {
            match table.get(uid) {
                Some(n) => {
                    st.names.insert(uid.clone(), n.clone());
                }
                None => {
                    st.names.remove(uid);
                }
            }
        }
        Some(events)
    }

    /// Lossless JSON string of the decrypted payload (diagnostic / fallback).
    #[must_use]
    pub fn json_string(&self) -> String {
        to_swift_json_string(&self.root)
    }
}

impl fmt::Debug for WirePayloadHandle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("WirePayloadHandle")
            .field("cmd", &self.cmd)
            .field("uids_count", &self.uids.len())
            .finish()
    }
}

/// Pre-parsed plain chat envelope ready for host delivery (`apply_parsed_events`).
#[derive(Clone)]
pub struct TypedChatEnvelope {
    pub events: Vec<ParsedWireEvent>,
    pub uids: Vec<String>,
    pub payload: Arc<WirePayloadHandle>,
}

impl fmt::Debug for TypedChatEnvelope {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TypedChatEnvelope")
            .field("events_count", &self.events.len())
            .field("uids_count", &self.uids.len())
            .finish()
    }
}

/// Result of attempting to parse a WS frame on the typed plain-chat hot path.
pub enum PlainChatParse {
    /// Not a plain chat envelope: route through `classify` / `apply_batch`.
    NotPlain,
    /// Plain chat envelope that yielded only `ParsedWireEvent::Ignore` (drop without host call).
    Empty,
    /// Plain chat envelope with concrete parsed events.
    Typed(TypedChatEnvelope),
}

/// Checks `is_plain_chat_envelope` and parses the frame using `state`.
#[must_use]
pub fn try_parse_plain_chat(
    cmd: u16,
    payload: &Map<String, Value>,
    state: &SharedParse,
) -> PlainChatParse {
    if !is_plain_chat_envelope(cmd, payload) {
        return PlainChatParse::NotPlain;
    }
    let root = Value::Object(payload.clone());
    let (my_uid, self_conv_id, names) = {
        let st = state.lock().unwrap_or_else(PoisonError::into_inner);
        (st.my_uid.clone(), st.self_conv_id.clone(), st.names.clone())
    };
    let events = parse_with(cmd, &root, &my_uid, self_conv_id.as_deref(), &names);
    if events.iter().all(|e| matches!(e, ParsedWireEvent::Ignore)) {
        return PlainChatParse::Empty;
    }
    let uids = collect_name_uids(&root);
    let used_names = uids.iter().map(|u| names.get(u).cloned()).collect();
    let handle = Arc::new(WirePayloadHandle {
        cmd,
        root,
        uids: uids.clone(),
        used_my_uid: my_uid,
        used_self_conv_id: self_conv_id,
        used_names,
        state: Arc::clone(state),
    });
    PlainChatParse::Typed(TypedChatEnvelope {
        events,
        uids,
        payload: handle,
    })
}

/// Pure variant for reducer unit tests without a pre-existing [`SharedParse`].
#[must_use]
pub fn try_parse_plain_chat_pure(
    cmd: u16,
    payload: &Map<String, Value>,
    my_uid: &str,
    self_conv_id: Option<&str>,
) -> PlainChatParse {
    let state = new_shared_parse(my_uid.to_owned(), self_conv_id.map(str::to_owned));
    try_parse_plain_chat(cmd, payload, &state)
}

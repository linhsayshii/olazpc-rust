//! Envelope classification for the realtime hot path: which `zpw_ws` payloads are plain chat-message envelopes (so the
//! parser can run in the socket task and Swift needs no JSON dictionary), and which contact uids a parse looks up.
//!
//! "Plain" is deliberately conservative: anything that could reach Swift's other payload consumers (E2EE decryption,
//! control actions, file-done / mobile-sync events, duplicate-login errors) is not plain and takes the raw-JSON path.

use std::collections::BTreeSet;

use serde_json::{Map, Value};

use crate::ids::strip_user_prefix;
use crate::lossless::{int64, string};

/// Chat-message commands the typed path handles (push 501/521, pulls 510/511/513-515/517/518). The E2EE commands
/// (535, 551, 552), 534 / 570 and everything else stay on the raw-JSON path.
pub const TYPED_CHAT_CMDS: [u16; 9] = [501, 510, 511, 513, 514, 515, 517, 518, 521];

/// Keys that make a control / sync item (`act_type`, `act`, `action`, `controls`, `actions`).
const CONTROL_KEYS: [&str; 6] = [
    "act_type", "actType", "act", "action", "controls", "actions",
];

/// Prefixes of Signal v3 ciphertext (`ZaloE2EEManager.signalCipherPrefixes`).
const SIGNAL_PREFIXES: [&str; 10] = [
    "AzM", "AjM", "ATMI", "ATMK", "ATMQ", "ATMS", "ATMY", "ATMi", "ATMo", "ATMw",
];

#[must_use]
pub fn is_typed_chat_cmd(cmd: u16) -> bool {
    TYPED_CHAT_CMDS.contains(&cmd)
}

fn has_control_key(m: &Map<String, Value>) -> bool {
    CONTROL_KEYS.iter().any(|k| m.contains_key(*k))
}

/// True when a candidate item (a `data` entry, or the data node itself) looks like a control / sync action.
fn looks_like_control(item: &Map<String, Value>) -> bool {
    if has_control_key(item) {
        return true;
    }
    match item.get("content") {
        Some(Value::Object(c)) => has_control_key(c),
        Some(Value::String(s)) => {
            let t = s.trim_start();
            (t.starts_with('{') || t.starts_with('[')) && s.contains("\"act")
        }
        _ => false,
    }
}

/// True when `v` contains a Signal ciphertext prefix anywhere inside strings, arrays, or objects.
#[must_use]
pub fn envelope_contains_signal_cipher(v: &Value) -> bool {
    contains_signal_cipher(v, 0)
}

fn contains_signal_cipher(v: &Value, depth: usize) -> bool {
    if depth > 64 {
        return true;
    }
    match v {
        Value::String(s) => SIGNAL_PREFIXES.iter().any(|p| s.contains(p)),
        Value::Array(a) => a.iter().any(|x| contains_signal_cipher(x, depth + 1)),
        Value::Object(m) => m.values().any(|x| contains_signal_cipher(x, depth + 1)),
        _ => false,
    }
}

/// True when `payload` (the decrypted body of a chat push / pull `cmd`) is a plain message envelope.
#[must_use]
pub fn is_plain_chat_envelope(cmd: u16, payload: &Map<String, Value>) -> bool {
    if !is_typed_chat_cmd(cmd) {
        return false;
    }
    if let Some(code) = payload.get("error_code")
        && int64(Some(code)).unwrap_or(-1) != 0
    {
        return false;
    }
    let data_node = payload
        .get("data")
        .and_then(Value::as_object)
        .unwrap_or(payload);
    if has_control_key(data_node) {
        return false;
    }
    match payload.get("data") {
        Some(Value::Array(items)) => {
            for item in items {
                if let Value::Object(m) = item
                    && looks_like_control(m)
                {
                    return false;
                }
            }
        }
        Some(Value::Object(m)) => {
            if looks_like_control(m) {
                return false;
            }
        }
        _ => {
            if looks_like_control(payload) {
                return false;
            }
        }
    }
    !payload.values().any(|v| contains_signal_cipher(v, 0))
}

fn collect(node: &Value, out: &mut BTreeSet<String>, depth: usize) {
    if depth >= 12 {
        return;
    }
    match node {
        Value::Object(m) => {
            for (k, v) in m {
                if matches!(k.as_str(), "uidFrom" | "senderId" | "ownerId") {
                    let uid = strip_user_prefix(&string(Some(v)));
                    if !uid.is_empty() && uid != "0" {
                        out.insert(uid);
                    }
                } else if v.is_object() || v.is_array() {
                    collect(v, out, depth + 1);
                }
            }
        }
        Value::Array(a) => {
            for el in a {
                collect(el, out, depth + 1);
            }
        }
        _ => {}
    }
}

/// Sender / quote-owner uids a parse of `root` may look names up for (sorted), as Swift's `collectUids`.
#[must_use]
pub fn collect_name_uids(root: &Value) -> Vec<String> {
    let mut set = BTreeSet::new();
    collect(root, &mut set, 0);
    set.into_iter().collect()
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use serde_json::json;

    use super::*;

    fn obj(v: Value) -> Map<String, Value> {
        v.as_object().unwrap().clone()
    }

    #[test]
    fn plain_message_envelopes() {
        let msgs = json!({"data": {"msgs": [{"msgId": "1", "uidFrom": "u1", "content": "xin chào", "msgType": "webchat"}]}});
        assert!(is_plain_chat_envelope(501, &obj(msgs.clone())));
        assert!(is_plain_chat_envelope(521, &obj(msgs.clone())));
        assert!(!is_plain_chat_envelope(551, &obj(msgs.clone())), "E2EE cmd");
        assert!(!is_plain_chat_envelope(601, &obj(msgs)), "control cmd");
        // Card messages carry `action` inside content, not on the data item.
        let card = json!({"data": {"groupMsgs": [{"msgId": "2", "msgType": "chat.recommended", "content": {"action": "recommened.link", "href": "https://x.example"}}]}});
        assert!(is_plain_chat_envelope(521, &obj(card)));
        let paged = json!({"data": [{"threadId": "t", "msgs": [{"msgId": "3", "content": "a"}]}]});
        assert!(is_plain_chat_envelope(510, &obj(paged)));
    }

    #[test]
    fn control_error_and_cipher_envelopes_are_not_plain() {
        for payload in [
            json!({"error_code": 600}),
            json!({"error_code": "-102", "data": {}}),
            json!({"data": {"controls": []}}),
            json!({"data": {"actions": []}}),
            json!({"data": {"act_type": "file_done"}}),
            json!({"data": [{"content": {"act": "typing"}}]}),
            json!({"data": [{"content": "{\"act_type\":\"voip\"}"}]}),
            json!({"data": {"msgs": [{"content": "AzMIARIgmPWlMdiC"}]}}),
            json!({"data": {"msgs": [{"content": {"id": "xATMIy"}}]}}),
        ] {
            assert!(
                !is_plain_chat_envelope(501, &obj(payload.clone())),
                "{payload}"
            );
        }
        assert!(is_plain_chat_envelope(
            501,
            &obj(json!({"error_code": 0, "data": {"msgs": []}}))
        ));
    }

    #[test]
    fn name_uids_match_the_swift_walker() {
        let root = json!({"data": {"msgs": [
            {"uidFrom": "u1", "quote": {"ownerId": "u2"}, "content": {"senderId": "u3"}},
            {"uidFrom": "0"}, {"uidFrom": "u1"}
        ]}});
        assert_eq!(collect_name_uids(&root), vec!["u1", "u2", "u3"]);
    }
}

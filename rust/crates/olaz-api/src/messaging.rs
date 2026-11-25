//! Sending and acting on messages (Swift "Messaging, Quote, Typing, Seen, Reaction, Delete,
//! Recall" section).

use olaz_json::string;
use olaz_net::{ApiRequest, Transport};
use olaz_wire::{Mention, strip_user_prefix};
use serde_json::{Map, Value, json};

use crate::api::{SendMessageResult, ZaloApi};
use crate::error::ApiError;
use crate::util::{conv_target, parse_i64, swift_json};

/// Official `DEST_TYPING.USER` (`PAGE` = 5 is for official accounts).
const TYPING_DEST_USER: i64 = 3;

/// A built request: service, path and the (unencrypted) params object.
#[derive(Debug, Clone, PartialEq)]
pub struct CallSpec {
    pub service: String,
    pub path: String,
    pub payload: Value,
}

/// Arguments of [`ZaloApi::send_text`] (Swift `sendTextAPI` parameters).
#[derive(Debug, Clone, Default)]
pub struct SendTextArgs<'a> {
    pub conv_id: &'a str,
    pub text: &'a str,
    /// Client id; an unparsable value falls back to a fresh `nextClientId`.
    pub cli_msg_id: &'a str,
    pub quote_msg_id: Option<&'a str>,
    pub quote_cli_msg_id: Option<&'a str>,
    pub quote_owner_id: Option<&'a str>,
    pub quote_text: Option<&'a str>,
    pub quote_ts_ms: Option<i64>,
    pub mentions: &'a [Mention],
    /// Rich text: the official `textProperties` JSON (`{"styles":[…],"ver":0}`), sent with the message as is.
    pub text_properties: Option<&'a str>,
    /// "Tin nhắn tự xóa": lifetime in ms (0 = kept), the conversation's setting.
    pub ttl: i64,
    /// "Quan trọng" (1) / "Khẩn cấp" (2): sent as `metaData: {urgency}`.
    pub urgency: i64,
}

/// Owned counterpart of [`SendTextArgs`] for async callers (e.g. `olaz-core` effects).
///
/// `Debug` is shape-only (ADR-008): message body, quote text, and style payloads are redacted.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct SendTextParams {
    pub conv_id: String,
    pub text: String,
    pub cli_msg_id: String,
    pub quote_msg_id: Option<String>,
    pub quote_cli_msg_id: Option<String>,
    pub quote_owner_id: Option<String>,
    pub quote_text: Option<String>,
    pub quote_ts_ms: Option<i64>,
    pub mentions: Vec<Mention>,
    pub text_properties: Option<String>,
    pub ttl: i64,
    pub urgency: i64,
}

impl SendTextParams {
    /// Borrows this request as [`SendTextArgs`] for [`ZaloApi::send_text`].
    #[must_use]
    pub fn as_args(&self) -> SendTextArgs<'_> {
        SendTextArgs {
            conv_id: &self.conv_id,
            text: &self.text,
            cli_msg_id: &self.cli_msg_id,
            quote_msg_id: self.quote_msg_id.as_deref(),
            quote_cli_msg_id: self.quote_cli_msg_id.as_deref(),
            quote_owner_id: self.quote_owner_id.as_deref(),
            quote_text: self.quote_text.as_deref(),
            quote_ts_ms: self.quote_ts_ms,
            mentions: &self.mentions,
            text_properties: self.text_properties.as_deref(),
            ttl: self.ttl,
            urgency: self.urgency,
        }
    }
}

impl std::fmt::Debug for SendTextParams {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SendTextParams")
            .field("has_quote", &self.quote_msg_id.is_some())
            .field("mentions_count", &self.mentions.len())
            .field("has_text_properties", &self.text_properties.is_some())
            .field("ttl", &self.ttl)
            .field("urgency", &self.urgency)
            .finish()
    }
}

fn mention_info(mentions: &[Mention]) -> Value {
    let objs: Vec<Value> = mentions
        .iter()
        .map(|m| {
            json!({
                "uid": if m.is_all { "-1".to_owned() } else { strip_user_prefix(&m.uid) },
                "pos": m.pos,
                "len": m.len,
                "type": if m.is_all { 1 } else { 0 },
            })
        })
        .collect();
    Value::String(swift_json(&Value::Array(objs)))
}

fn insert(payload: &mut Value, key: &str, value: Value) {
    if let Some(obj) = payload.as_object_mut() {
        obj.insert(key.to_owned(), value);
    }
}

/// Owned parameters for [`ZaloApi::send_contact_card`] (Swift `sendContactCardAPI`).
///
/// `Debug` is shape-only (ADR-008): conversation id, contact uid, and phone number are redacted.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct SendContactCardParams {
    pub conv_id: String,
    pub card_uid: String,
    pub phone: Option<String>,
    /// Client id; when `None`, [`ZaloApi::send_contact_card`] allocates a fresh `next_client_id`.
    pub client_id: Option<i64>,
}

impl std::fmt::Debug for SendContactCardParams {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SendContactCardParams")
            .field(
                "has_phone",
                &self.phone.as_deref().is_some_and(|p| !p.is_empty()),
            )
            .field("has_client_id", &self.client_id.is_some())
            .finish()
    }
}

/// Pure request builder for Swift `sendContactCardAPI`.
#[must_use]
pub fn build_send_contact_card_request(
    conv_id: &str,
    card_uid: &str,
    phone: Option<&str>,
    client_id: i64,
    imei: &str,
) -> CallSpec {
    let (is_group, clean_id) = conv_target(conv_id);
    let mut payload = json!({
        "contactId": strip_user_prefix(card_uid),
        "clientId": client_id,
        "ttl": 0,
        "imei": imei,
    });
    if let Some(p) = phone.filter(|p| !p.is_empty()) {
        insert(&mut payload, "phone", Value::from(p));
    }
    let (service, path) = if is_group {
        insert(&mut payload, "grid", Value::from(clean_id));
        insert(&mut payload, "visibility", Value::from(0));
        ("group", "/api/group/contact")
    } else {
        insert(&mut payload, "toId", Value::from(clean_id));
        ("chat", "/api/message/contact")
    };
    CallSpec {
        service: service.to_owned(),
        path: path.to_owned(),
        payload,
    }
}

/// Inputs of [`build_recall_message_request`].
#[derive(Debug, Clone)]
pub struct RecallParams<'a> {
    pub conv_id: &'a str,
    pub msg_id: &'a str,
    pub cli_msg_id: &'a str,
    pub client_id: i64,
    pub is_e2ee: bool,
    pub imei: &'a str,
    /// Swift default 0.
    pub visibility: i64,
    /// Swift default 3.
    pub dest_type: i64,
}

impl<'a> RecallParams<'a> {
    pub fn new(
        conv_id: &'a str,
        msg_id: &'a str,
        cli_msg_id: &'a str,
        client_id: i64,
        is_e2ee: bool,
        imei: &'a str,
    ) -> Self {
        Self {
            conv_id,
            msg_id,
            cli_msg_id,
            client_id,
            is_e2ee,
            imei,
            visibility: 0,
            dest_type: 3,
        }
    }
}

/// Swift `buildRecallMessageRequest`: the four recall routes (1-1/group x plain/E2EE).
pub fn build_recall_message_request(p: &RecallParams<'_>) -> CallSpec {
    let (is_group, clean_id) = conv_target(p.conv_id);
    let undo = if p.cli_msg_id.is_empty() {
        p.msg_id
    } else {
        p.cli_msg_id
    };
    let mut payload = json!({
        "msgId": p.msg_id,
        "clientId": p.client_id,
        "cliMsgIdUndo": undo,
    });
    if is_group {
        insert(&mut payload, "grid", Value::from(clean_id));
        insert(&mut payload, "visibility", Value::from(p.visibility));
        insert(&mut payload, "imei", Value::from(p.imei));
        let (service, path) = if p.is_e2ee {
            ("group_e2e", "/api/e2ee/pc/group/undoMsg")
        } else {
            ("group", "/api/group/undomsg")
        };
        return CallSpec {
            service: service.to_owned(),
            path: path.to_owned(),
            payload,
        };
    }
    insert(&mut payload, "toid", Value::from(clean_id));
    if p.is_e2ee {
        insert(&mut payload, "destType", Value::from(p.dest_type));
        return CallSpec {
            service: "chat_e2e".to_owned(),
            path: "/api/e2ee/pc/message/undo".to_owned(),
            payload,
        };
    }
    CallSpec {
        service: "chat".to_owned(),
        path: "/api/message/undo".to_owned(),
        payload,
    }
}

/// Inputs of [`build_reaction_request`].
#[derive(Debug, Clone)]
pub struct ReactionParams<'a> {
    pub conv_id: &'a str,
    pub msg_id: &'a str,
    pub cli_msg_id: &'a str,
    pub r_icon: &'a str,
    pub r_type: i64,
    pub msg_type: i64,
    pub client_id: i64,
    pub imei: &'a str,
}

/// Swift `ReactionRequestSpec`.
#[derive(Debug, Clone, PartialEq)]
pub struct ReactionRequestSpec {
    pub call: CallSpec,
    pub client_id: i64,
}

/// Swift `buildReactionRequest`. The inner `message` JSON string keeps `/` unescaped (Swift
/// `.withoutEscapingSlashes`), which the server needs for icons like `/-heart`.
pub fn build_reaction_request(p: &ReactionParams<'_>) -> ReactionRequestSpec {
    let (is_group, clean_id) = conv_target(p.conv_id);
    let g_msg: Value = match parse_i64(p.msg_id) {
        Some(n) => Value::from(n),
        None => Value::from(p.msg_id),
    };
    let c_msg = parse_i64(p.cli_msg_id)
        .or_else(|| parse_i64(p.msg_id))
        .unwrap_or(p.client_id);
    let inner = json!({
        "rMsg": [{"gMsgID": g_msg, "cMsgID": c_msg, "msgType": p.msg_type}],
        "rIcon": p.r_icon,
        "rType": p.r_type,
        "source": 6,
    });
    let inner_str = serde_json::to_string(&olaz_net::canonical_json(&inner))
        .unwrap_or_else(|_| "{}".to_owned());
    let path = if is_group {
        "/api/group/reaction"
    } else {
        "/api/message/reaction"
    };
    let mut payload = json!({
        "react_list": [{"message": inner_str, "clientId": p.client_id}],
    });
    if is_group {
        insert(&mut payload, "grid", Value::from(clean_id));
        insert(&mut payload, "imei", Value::from(p.imei));
    } else {
        insert(&mut payload, "toid", Value::from(clean_id));
    }
    ReactionRequestSpec {
        call: CallSpec {
            service: "reaction".to_owned(),
            path: path.to_owned(),
            payload,
        },
        client_id: p.client_id,
    }
}

impl<T: Transport> ZaloApi<T> {
    /// Swift `sendTextAPI`: plain text, optionally a quote/reply and @mentions (groups only).
    ///
    /// A quote is tried on `/api/message/quote` / `/api/group/quote`; if that call fails for any
    /// reason the message is sent as plain text instead (Swift `try?`). `msg_id` of the result is
    /// the server id, or the client id when the answer has none.
    pub async fn send_text(&self, a: &SendTextArgs<'_>) -> Result<SendMessageResult, ApiError> {
        let (is_group, clean_id) = conv_target(a.conv_id);
        let cli_int = parse_i64(a.cli_msg_id).unwrap_or_else(|| self.client().next_client_id());
        let cli_str = cli_int.to_string();
        let q_msg_int = a
            .quote_msg_id
            .and_then(|q| parse_i64(q.trim()))
            .filter(|n| *n != 0);
        let mention_str = (is_group && !a.mentions.is_empty()).then(|| mention_info(a.mentions));
        let imei = self.imei();
        let service = if is_group { "group" } else { "chat" };

        let mut resp: Option<Map<String, Value>> = None;
        if let Some(q_msg) = q_msg_int {
            let owner = match a.quote_owner_id {
                Some(o) => strip_user_prefix(o),
                None => strip_user_prefix(
                    &self
                        .client()
                        .account()
                        .map(|acc| acc.user_id)
                        .unwrap_or_default(),
                ),
            };
            let q_cli = a.quote_cli_msg_id.and_then(parse_i64).unwrap_or(q_msg);
            let q_ts = a.quote_ts_ms.unwrap_or_else(|| self.now_ms());
            let mut payload = json!({
                "message": a.text,
                "clientId": cli_int,
                "qmsgOwner": owner,
                "qmsgId": q_msg,
                "qmsgCliId": q_cli,
                "qmsgType": 1,
                "qmsg": a.quote_text.unwrap_or(""),
                "qmsgTs": q_ts,
                "ttl": a.ttl,
                "zsource": 101,
                "imei": imei,
            });
            if let Some(tp) = a.text_properties.filter(|t| !t.is_empty()) {
                insert(&mut payload, "textProperties", Value::from(tp));
            }
            if a.urgency > 0 {
                insert(&mut payload, "metaData", json!({"urgency": a.urgency}));
            }
            if is_group {
                insert(&mut payload, "grid", Value::from(clean_id.clone()));
                insert(&mut payload, "visibility", Value::from(0));
                insert(&mut payload, "language", Value::from("vi"));
                insert(&mut payload, "qmsgAttach", Value::from("{}"));
                if let Some(m) = &mention_str {
                    insert(&mut payload, "mentionInfo", m.clone());
                }
            } else {
                insert(&mut payload, "toid", Value::from(clean_id.clone()));
            }
            let path = if is_group {
                "/api/group/quote"
            } else {
                "/api/message/quote"
            };
            resp = self
                .post(ApiRequest::new(service, path).payload(payload))
                .await
                .ok();
        }

        let resp = match resp {
            Some(r) => r,
            None => {
                let mut payload = json!({
                    "message": a.text,
                    "clientId": cli_int,
                    "imei": imei,
                    "ttl": a.ttl,
                });
                if let Some(tp) = a.text_properties.filter(|t| !t.is_empty()) {
                    insert(&mut payload, "textProperties", Value::from(tp));
                }
                if a.urgency > 0 {
                    insert(&mut payload, "metaData", json!({"urgency": a.urgency}));
                }
                if is_group {
                    insert(&mut payload, "grid", Value::from(clean_id));
                    insert(&mut payload, "visibility", Value::from(0));
                    if let Some(m) = mention_str {
                        insert(&mut payload, "mentionInfo", m);
                    }
                } else {
                    insert(&mut payload, "toid", Value::from(clean_id));
                }
                let path = if is_group {
                    "/api/group/sendmsg"
                } else {
                    "/api/message/sms"
                };
                self.post(ApiRequest::new(service, path).payload(payload))
                    .await?
            }
        };

        let server_msg_id = resp
            .get("data")
            .and_then(Value::as_object)
            .map(|d| string(d.get("msgId")))
            .unwrap_or_default();
        Ok(SendMessageResult {
            msg_id: if server_msg_id.is_empty() {
                cli_str.clone()
            } else {
                server_msg_id
            },
            cli_msg_id: cli_str,
            ts_ms: self.now_ms(),
        })
    }

    /// Swift `sendTypingAPI` (errors are ignored, like Swift's `try?`). `destType` is the official
    /// `DEST_TYPING.USER`: with 0 the peer shows no typing indicator.
    pub async fn send_typing(&self, conv_id: &str) {
        let (is_group, clean_id) = conv_target(conv_id);
        let imei = self.imei();
        let (service, path, payload) = if is_group {
            (
                "group",
                "/api/group/typing",
                json!({"grid": clean_id, "imei": imei}),
            )
        } else {
            (
                "chat",
                "/api/message/typing",
                json!({"toid": clean_id, "destType": TYPING_DEST_USER, "imei": imei}),
            )
        };
        let _ = self
            .post(ApiRequest::new(service, path).payload(payload))
            .await;
    }

    /// Swift `sendSeenAPI` (errors are ignored; empty ids are a no-op).
    pub async fn send_seen(&self, conv_id: &str, msg_id: &str, cli_msg_id: &str, _sender_id: &str) {
        let (is_group, clean_id) = conv_target(conv_id);
        let trimmed = msg_id.trim();
        if clean_id.is_empty() || trimmed.is_empty() {
            return;
        }
        let cmi = if cli_msg_id.is_empty() {
            trimmed
        } else {
            cli_msg_id
        };
        let data = json!([{"gmi": trimmed, "cmi": cmi}]);
        let infos = if is_group {
            json!({"data": data, "grid": clean_id})
        } else {
            json!({"data": data, "senderId": clean_id})
        };
        let mut payload = json!({"msgInfos": swift_json(&infos)});
        let (service, path) = if is_group {
            insert(&mut payload, "imei", Value::from(self.imei()));
            ("group", "/api/group/seenv2")
        } else {
            ("chat", "/api/message/seenv2")
        };
        let _ = self
            .post(ApiRequest::new(service, path).payload(payload))
            .await;
    }

    /// Swift `sendReactionAPI`; returns the client id used.
    #[allow(clippy::too_many_arguments)]
    pub async fn send_reaction(
        &self,
        conv_id: &str,
        msg_id: &str,
        cli_msg_id: &str,
        r_icon: &str,
        r_type: i64,
        msg_type: i64,
        client_id: Option<i64>,
    ) -> Result<i64, ApiError> {
        let client_id = client_id.unwrap_or_else(|| self.client().next_client_id());
        let imei = self.imei();
        let spec = build_reaction_request(&ReactionParams {
            conv_id,
            msg_id,
            cli_msg_id,
            r_icon,
            r_type,
            msg_type,
            client_id,
            imei: &imei,
        });
        self.post(ApiRequest::new(spec.call.service, spec.call.path).payload(spec.call.payload))
            .await?;
        Ok(spec.client_id)
    }

    /// Swift `recallMessageAPI`.
    pub async fn recall_message(
        &self,
        conv_id: &str,
        msg_id: &str,
        cli_msg_id: &str,
        is_e2ee: bool,
    ) -> Result<(), ApiError> {
        let imei = self.imei();
        let spec = build_recall_message_request(&RecallParams::new(
            conv_id,
            msg_id,
            cli_msg_id,
            self.client().next_client_id(),
            is_e2ee,
            &imei,
        ));
        self.post(ApiRequest::new(spec.service, spec.path).payload(spec.payload))
            .await?;
        Ok(())
    }

    /// Swift `deleteMessageForMeAPI`.
    pub async fn delete_message_for_me(
        &self,
        conv_id: &str,
        msg_id: &str,
        cli_msg_id: &str,
        sender_id: &str,
    ) -> Result<(), ApiError> {
        let (is_group, clean_id) = conv_target(conv_id);
        let owner = if sender_id.is_empty() {
            self.client()
                .account()
                .map(|a| a.user_id)
                .unwrap_or_default()
        } else {
            sender_id.to_owned()
        };
        let msg_del = json!({
            "cliMsgId": if cli_msg_id.is_empty() { msg_id } else { cli_msg_id },
            "globalMsgId": msg_id,
            "ownerId": strip_user_prefix(&owner),
            "destId": clean_id,
        });
        let mut payload = json!({
            "cliMsgId": self.client().next_client_id(),
            "msgs": [msg_del],
            "onlyMe": 1,
            "imei": self.imei(),
        });
        let (service, path) = if is_group {
            insert(&mut payload, "grid", Value::from(clean_id));
            ("group", "/api/group/deletemsg")
        } else {
            insert(&mut payload, "toid", Value::from(clean_id));
            ("chat", "/api/message/delete")
        };
        self.post(ApiRequest::new(service, path).payload(payload))
            .await?;
        Ok(())
    }

    /// Swift `sendContactCardAPI`.
    pub async fn send_contact_card(
        &self,
        params: &SendContactCardParams,
    ) -> Result<SendMessageResult, ApiError> {
        let cli_id = params
            .client_id
            .unwrap_or_else(|| self.client().next_client_id());
        let cli_str = cli_id.to_string();
        let imei = self.imei();
        let spec = build_send_contact_card_request(
            &params.conv_id,
            &params.card_uid,
            params.phone.as_deref(),
            cli_id,
            &imei,
        );
        let resp = self
            .post(ApiRequest::new(spec.service, spec.path).payload(spec.payload))
            .await?;
        let d = resp.get("data");
        let msg_id = string(d.and_then(|v| v.get("msgId")));
        Ok(SendMessageResult {
            msg_id: if msg_id.is_empty() {
                cli_str.clone()
            } else {
                msg_id
            },
            cli_msg_id: cli_str,
            ts_ms: self.now_ms(),
        })
    }
}

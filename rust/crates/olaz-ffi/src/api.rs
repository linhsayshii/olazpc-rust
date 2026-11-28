//! `CoreApi`: the chat-path API calls (`olaz-api`) as a Swift object.
//!
//! Heterogeneous server answers come back as lossless JSON text (64-bit ids exact, see
//! `olaz_json::to_swift_json_string`) so Swift can keep its existing parsing during cutover; small well-known
//! shapes are typed records, and chat history is a [`HistoryBatch`] parsed to typed events (no JSON in Swift).

use std::collections::HashMap;
use std::sync::Arc;

use olaz_api::{
    JsonObject, PollQueueCursor, PollState, SendContactCardParams, SendTextArgs, ZaloApi,
};
use olaz_json::{parse_object_str, to_swift_json_string};
use olaz_net::ReqwestTransport;
use olaz_wire::{Mention, collect_name_uids, extract_batch_events};
use serde_json::Value;

use crate::error::CoreError;
use crate::runtime::run;
use crate::session::CoreSession;
use crate::wire::{WireEvent, WireOptions, convert, with_options};

type Api = ZaloApi<ReqwestTransport>;

fn blob(o: &JsonObject) -> String {
    to_swift_json_string(&Value::Object(o.clone()))
}

fn blobs(rows: &[JsonObject]) -> Vec<String> {
    rows.iter().map(blob).collect()
}

/// Result of a send call (Swift `SendMessageResult`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SendResultRecord {
    pub msg_id: String,
    pub cli_msg_id: String,
    pub ts_ms: i64,
}

/// An @mention; `pos` / `len` are UTF-16 offsets into the text.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MentionRecord {
    pub uid: String,
    pub pos: i64,
    pub len: i64,
    pub is_all: bool,
}

/// Arguments of `send_text` (Swift `sendTextAPI`). `cli_msg_id` may be empty (a fresh client id
/// is used).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SendTextRecord {
    pub conv_id: String,
    pub text: String,
    #[uniffi(default = "")]
    pub cli_msg_id: String,
    #[uniffi(default = None)]
    pub quote_msg_id: Option<String>,
    #[uniffi(default = None)]
    pub quote_cli_msg_id: Option<String>,
    #[uniffi(default = None)]
    pub quote_owner_id: Option<String>,
    #[uniffi(default = None)]
    pub quote_text: Option<String>,
    #[uniffi(default = None)]
    pub quote_ts_ms: Option<i64>,
    #[uniffi(default = [])]
    pub mentions: Vec<MentionRecord>,
    #[uniffi(default = None)]
    pub text_properties: Option<String>,
    #[uniffi(default = 0)]
    pub ttl: i64,
    #[uniffi(default = 0)]
    pub urgency: i64,
}

/// One long-poll queue cursor.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollQueueRecord {
    pub key: String,
    pub last_id: String,
    pub ids: Vec<String>,
}

/// Long-poll cursor state (Swift `ZaloPollState`). Start from [`poll_state_initial`] and feed back
/// `PollOutcomeRecord.next_state`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollStateRecord {
    pub last_action_id: String,
    pub last_action_id_other: String,
    pub queues: Vec<PollQueueRecord>,
}

impl From<&PollState> for PollStateRecord {
    fn from(s: &PollState) -> Self {
        Self {
            last_action_id: s.last_action_id.clone(),
            last_action_id_other: s.last_action_id_other.clone(),
            queues: s
                .queues
                .iter()
                .map(|(k, q)| PollQueueRecord {
                    key: k.clone(),
                    last_id: q.last_id.clone(),
                    ids: q.ids.clone(),
                })
                .collect(),
        }
    }
}

impl From<PollStateRecord> for PollState {
    fn from(s: PollStateRecord) -> Self {
        Self {
            last_action_id: s.last_action_id,
            last_action_id_other: s.last_action_id_other,
            queues: s
                .queues
                .into_iter()
                .map(|q| {
                    (
                        q.key,
                        PollQueueCursor {
                            last_id: q.last_id,
                            ids: q.ids,
                        },
                    )
                })
                .collect(),
        }
    }
}

/// The initial poll state (queues "1", "2", "3" at id "1").
#[uniffi::export]
#[must_use]
pub fn poll_state_initial() -> PollStateRecord {
    (&PollState::default()).into()
}

/// One long-poll answer.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollOutcomeRecord {
    /// The server answer as lossless JSON (feed to `parse_wire_batch`).
    pub raw_json: String,
    pub next_state: PollStateRecord,
    /// More data is waiting: poll again immediately.
    pub more: bool,
}

/// `fetch_history` answer: paging head plus the parsed body kept Rust-side. For 1-1 chats this is the
/// `get-last-msgs` answer (head fields stay at their defaults). No JSON crosses the FFI: Swift resolves `uids` to
/// contact names, then asks `batch.events(...)` for the typed events (same flow as [`crate::WirePayload`]).
#[derive(Clone, uniffi::Record)]
pub struct HistoryRecord {
    pub has_more: bool,
    pub is_old: bool,
    pub last_msg_id: String,
    /// Sender / quote-owner uids a parse looks names up for (`NameEntry.uid`).
    pub uids: Vec<String>,
    pub batch: Arc<HistoryBatch>,
}

/// The server answer of a history call, parsed on demand. Ids stay exact (lossless JSON never leaves Rust).
#[derive(uniffi::Object)]
pub struct HistoryBatch {
    root: Value,
}

impl HistoryBatch {
    pub(crate) fn from_object(o: JsonObject) -> Self {
        Self {
            root: Value::Object(o),
        }
    }

    pub(crate) fn record(self) -> HistoryRecord {
        let data = self.root.get("data").and_then(Value::as_object);
        HistoryRecord {
            has_more: data.is_some_and(|d| flag(d.get("hasMore"))),
            is_old: data.is_some_and(|d| flag(d.get("isOld"))),
            last_msg_id: data.map_or_else(String::new, |d| olaz_json::string(d.get("lastMsgId"))),
            uids: collect_name_uids(&self.root),
            batch: Arc::new(self),
        }
    }
}

#[uniffi::export]
impl HistoryBatch {
    /// Every message and live reaction / recall / delete in the answer, parsed with `options` (`extractBatchEvents`).
    /// Synchronous and CPU-bound: call it off the main actor for big pages.
    pub fn events(&self, my_uid: String, options: WireOptions) -> Vec<WireEvent> {
        with_options(&options, |o| {
            extract_batch_events(&self.root, &my_uid, o)
                .into_iter()
                .map(convert)
                .collect()
        })
    }

    /// The answer as lossless JSON text, for the few callers that read raw fields (cloud-message lookups, audits).
    pub fn raw_json(&self) -> String {
        to_swift_json_string(&self.root)
    }
}

/// Wraps a history answer given as JSON text the way [`CoreApi::fetch_history`] would return it (tests and benchmarks:
/// the same typed path without a network call).
#[uniffi::export]
pub fn history_record_from_json(json: String) -> Result<HistoryRecord, CoreError> {
    let o = olaz_json::parse_object_str(&json).ok_or_else(|| CoreError::Parse {
        message: "history answer is not a JSON object".to_owned(),
    })?;
    Ok(HistoryBatch::from_object(o).record())
}

fn flag(v: Option<&Value>) -> bool {
    olaz_json::int64(v) == Some(1) || matches!(v, Some(Value::Bool(true)))
}

/// Chat-path API over a shared [`CoreSession`]. Every method is async and runs on the shared
/// runtime; failures throw `CoreError` (`.session(isAuth: true)` means re-login).
#[derive(uniffi::Object)]
pub struct CoreApi {
    api: Arc<Api>,
}

impl CoreApi {
    pub(crate) fn from_shared_api(api: Arc<Api>) -> Arc<Self> {
        Arc::new(Self { api })
    }
}

#[uniffi::export]
impl CoreApi {
    #[uniffi::constructor]
    pub fn new(session: Arc<CoreSession>) -> Arc<Self> {
        Arc::new(Self {
            api: Arc::new(ZaloApi::from_shared(Arc::clone(&session.client))),
        })
    }

    /// Version counter from `archivedchat/list`.
    pub fn archived_version(&self) -> i64 {
        self.api.archived_version()
    }

    /// Version counter from `convlabel/get`.
    pub fn label_version(&self) -> i64 {
        self.api.label_version()
    }

    /// Friends page: one lossless JSON object per friend.
    pub async fn fetch_friends(&self, page: i64, count: i64) -> Result<Vec<String>, CoreError> {
        let api = Arc::clone(&self.api);
        let rows = run(async move { api.fetch_friends(page, count).await }).await??;
        Ok(blobs(&rows))
    }

    /// `{gridVerMap, gridInfoMap}` as lossless JSON.
    pub async fn fetch_groups_list(&self) -> Result<String, CoreError> {
        let api = Arc::clone(&self.api);
        let o = run(async move { api.fetch_groups_list().await }).await??;
        Ok(blob(&o))
    }

    /// `uid -> alias`.
    pub async fn fetch_aliases(&self) -> Result<HashMap<String, String>, CoreError> {
        let api = Arc::clone(&self.api);
        let m = run(async move { api.fetch_aliases().await }).await??;
        Ok(m.into_iter().collect())
    }

    /// Global noised ID -> PC uid, with bounded GET batches and retry/split recovery.
    pub async fn decrypt_global_ids(
        &self,
        ids: Vec<String>,
    ) -> Result<HashMap<String, String>, CoreError> {
        let api = Arc::clone(&self.api);
        Ok(run(async move { api.decrypt_global_ids(&ids).await }).await??)
    }

    /// PC uid -> global noised ID.
    pub async fn encrypt_global_ids(
        &self,
        ids: Vec<String>,
    ) -> Result<HashMap<String, String>, CoreError> {
        let api = Arc::clone(&self.api);
        Ok(run(async move { api.encrypt_global_ids(&ids).await }).await??)
    }

    /// `{"data": {"profiles": {uid: row}}}` as lossless JSON.
    pub async fn fetch_profiles(&self, uids: Vec<String>) -> Result<String, CoreError> {
        let api = Arc::clone(&self.api);
        let o = run(async move { api.fetch_profiles(&uids).await }).await??;
        Ok(blob(&o))
    }

    /// One HTTP long-poll of the chat queue.
    pub async fn fetch_chat_from_polling(
        &self,
        state: PollStateRecord,
    ) -> Result<PollOutcomeRecord, CoreError> {
        let api = Arc::clone(&self.api);
        let state: PollState = state.into();
        let out = run(async move { api.fetch_chat_from_polling(&state).await }).await??;
        Ok(PollOutcomeRecord {
            raw_json: blob(&out.response),
            next_state: (&out.next_state).into(),
            more: out.more,
        })
    }

    pub async fn fetch_pinned_conversations(&self) -> Result<Vec<String>, CoreError> {
        let api = Arc::clone(&self.api);
        Ok(run(async move { api.fetch_pinned_conversations().await }).await??)
    }

    pub async fn fetch_archived_chats(&self) -> Result<Vec<String>, CoreError> {
        let api = Arc::clone(&self.api);
        Ok(run(async move { api.fetch_archived_chats().await }).await??)
    }

    /// Label data (`data` object of `convlabel/get`) as lossless JSON.
    pub async fn fetch_conversation_labels(&self) -> Result<String, CoreError> {
        let api = Arc::clone(&self.api);
        let o = run(async move { api.fetch_conversation_labels().await }).await??;
        Ok(blob(&o))
    }

    /// Mute rows (`type` 1 = peer, 2 = group): one lossless JSON object each.
    pub async fn fetch_mute_list(&self) -> Result<Vec<String>, CoreError> {
        let api = Arc::clone(&self.api);
        let rows = run(async move { api.fetch_mute_list().await }).await??;
        Ok(blobs(&rows))
    }

    /// Recent threads with last messages (empty `thread_ids` = active-thread overview).
    pub async fn fetch_preload_conversations(
        &self,
        thread_ids: Vec<String>,
    ) -> Result<String, CoreError> {
        let api = Arc::clone(&self.api);
        let o = run(async move { api.fetch_preload_conversations(&thread_ids).await }).await??;
        Ok(blob(&o))
    }

    pub async fn fetch_history(
        &self,
        conv_id: String,
        last_msg_id: Option<String>,
        count: i64,
        is_old: Option<bool>,
    ) -> Result<HistoryRecord, CoreError> {
        let api = Arc::clone(&self.api);
        let o = run(async move {
            api.fetch_history(&conv_id, last_msg_id.as_deref(), count, is_old)
                .await
        })
        .await??;
        Ok(HistoryBatch::from_object(o).record())
    }

    pub async fn send_text(&self, args: SendTextRecord) -> Result<SendResultRecord, CoreError> {
        let api = Arc::clone(&self.api);
        let r = run(async move {
            let mentions: Vec<Mention> = args
                .mentions
                .into_iter()
                .map(|m| Mention {
                    uid: m.uid,
                    pos: m.pos,
                    len: m.len,
                    is_all: m.is_all,
                })
                .collect();
            api.send_text(&SendTextArgs {
                conv_id: &args.conv_id,
                text: &args.text,
                cli_msg_id: &args.cli_msg_id,
                quote_msg_id: args.quote_msg_id.as_deref(),
                quote_cli_msg_id: args.quote_cli_msg_id.as_deref(),
                quote_owner_id: args.quote_owner_id.as_deref(),
                quote_text: args.quote_text.as_deref(),
                quote_ts_ms: args.quote_ts_ms,
                mentions: &mentions,
                text_properties: args.text_properties.as_deref(),
                ttl: args.ttl,
                urgency: args.urgency,
            })
            .await
        })
        .await??;
        Ok(SendResultRecord {
            msg_id: r.msg_id,
            cli_msg_id: r.cli_msg_id,
            ts_ms: r.ts_ms,
        })
    }

    /// Sends a contact card (Swift `sendContactCardAPI`).
    pub async fn send_contact_card(
        &self,
        conv_id: String,
        card_uid: String,
        phone: Option<String>,
    ) -> Result<SendResultRecord, CoreError> {
        let api = Arc::clone(&self.api);
        let r = run(async move {
            api.send_contact_card(&SendContactCardParams {
                conv_id,
                card_uid,
                phone,
                client_id: None,
            })
            .await
        })
        .await??;
        Ok(SendResultRecord {
            msg_id: r.msg_id,
            cli_msg_id: r.cli_msg_id,
            ts_ms: r.ts_ms,
        })
    }

    /// Fire-and-forget typing indicator (errors are ignored, like Swift).
    pub async fn send_typing(&self, conv_id: String) -> Result<(), CoreError> {
        let api = Arc::clone(&self.api);
        run(async move { api.send_typing(&conv_id).await }).await
    }

    /// Marks a message seen (errors are ignored, like Swift).
    pub async fn send_seen(
        &self,
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        sender_id: String,
    ) -> Result<(), CoreError> {
        let api = Arc::clone(&self.api);
        run(async move {
            api.send_seen(&conv_id, &msg_id, &cli_msg_id, &sender_id)
                .await;
        })
        .await
    }

    pub async fn set_unread_mark(&self, conv_id: String, unread: bool) -> Result<(), CoreError> {
        let api = Arc::clone(&self.api);
        run(async move { api.set_unread_mark(&conv_id, unread).await }).await??;
        Ok(())
    }

    pub async fn recall_message(
        &self,
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        is_e2ee: bool,
    ) -> Result<(), CoreError> {
        let api = Arc::clone(&self.api);
        run(async move {
            api.recall_message(&conv_id, &msg_id, &cli_msg_id, is_e2ee)
                .await
        })
        .await??;
        Ok(())
    }

    pub async fn delete_message_for_me(
        &self,
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        sender_id: String,
    ) -> Result<(), CoreError> {
        let api = Arc::clone(&self.api);
        run(async move {
            api.delete_message_for_me(&conv_id, &msg_id, &cli_msg_id, &sender_id)
                .await
        })
        .await??;
        Ok(())
    }

    /// Returns the client id used for the reaction.
    #[allow(clippy::too_many_arguments)]
    pub async fn send_reaction(
        &self,
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        r_icon: String,
        r_type: i64,
        msg_type: i64,
        client_id: Option<i64>,
    ) -> Result<i64, CoreError> {
        let api = Arc::clone(&self.api);
        Ok(run(async move {
            api.send_reaction(
                &conv_id,
                &msg_id,
                &cli_msg_id,
                &r_icon,
                r_type,
                msg_type,
                client_id,
            )
            .await
        })
        .await??)
    }

    /// Sends a pre-built E2EE envelope. `list_params_json` holds one JSON object per entry
    /// (`olaz_api::build_e2ee_list_param_entry` shape, built by the Signal layer in Swift).
    pub async fn send_e2ee_message(
        &self,
        endpoint: String,
        thread_id: String,
        is_group: bool,
        client_id: i64,
        list_params_json: Vec<String>,
        dest_type: i64,
    ) -> Result<SendResultRecord, CoreError> {
        let mut params: Vec<JsonObject> = Vec::with_capacity(list_params_json.len());
        for p in &list_params_json {
            params.push(parse_object_str(p).ok_or_else(|| CoreError::Parse {
                message: "e2ee list param is not a JSON object".to_owned(),
            })?);
        }
        let api = Arc::clone(&self.api);
        let r = run(async move {
            api.send_e2ee_message(
                &endpoint, &thread_id, is_group, client_id, &params, dest_type,
            )
            .await
        })
        .await??;
        Ok(SendResultRecord {
            msg_id: r.msg_id,
            cli_msg_id: r.cli_msg_id,
            ts_ms: r.ts_ms,
        })
    }
}

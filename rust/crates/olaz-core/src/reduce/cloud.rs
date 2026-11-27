//! Pure reducer for the zCloud domain (U11).

use std::collections::{BTreeMap, BTreeSet};

use olaz_store::{StoredCloudConversationSummary, StoredCloudMediaItem};
use olaz_wire::{ChatMessage, Kind};

use crate::changes::DirtyKey;
use crate::cloud::{
    CLOUD_FETCH_FAILED_ERROR, CLOUD_LOCAL_READ_ERROR, CLOUD_NOT_FOUND_ERROR,
    CLOUD_OFFLOAD_UNSUPPORTED_ERROR, CloudActionResult, CloudFetch, CloudFile, CloudItem,
    CloudItemKind, CloudPage, CloudServerSnapshot, ESTIMATED_PHOTO_BYTES, ESTIMATED_VIDEO_BYTES,
    ESTIMATED_VOICE_BYTES, FileResolutionOutcome, MediaResolutionOutcome, PendingCloudDelete,
    PendingCloudFetchStage, PendingCloudList, apply_cloud_snapshot, cloud_item_from_message,
    cloud_item_from_stored, collect_list_memory_media_ids, collect_memory_media_ids,
    message_cloud_kind, path_extension, resolve_cloud_conversation_meta, sort_cloud_items,
    split_cloud_key,
};
use crate::effect::{Effect, HostCall, OpResult};
use crate::input::{Command, Input};
use crate::reduce::ReduceOutput;
use crate::state::CoreState;

/// Pure entry point for all zCloud commands and async completion inputs.
pub fn reduce_cloud(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::Command(cmd) => reduce_command(state, cmd, None, out),
        Input::OpRequest { op_id, cmd } => reduce_command(state, cmd, Some(op_id), out),
        Input::CloudRefreshLoaded {
            op_id,
            server_snapshot,
            sql_summaries,
            existing_ids_by_conv,
        } => {
            handle_cloud_refresh_loaded(
                state,
                op_id,
                server_snapshot.as_ref(),
                &sql_summaries,
                &existing_ids_by_conv,
                out,
            );
        }
        Input::CloudListStoreDone {
            op_id,
            store_present,
            existing_ids_by_conv,
            sql_items,
            sql_has_more,
            sql_error,
        } => {
            handle_cloud_list_store_done(
                state,
                CloudListStoreInput {
                    op_id,
                    store_present,
                    existing_ids_by_conv: &existing_ids_by_conv,
                    sql_items: &sql_items,
                    sql_has_more,
                    sql_error,
                },
                out,
            );
        }
        Input::CloudLookupMessageDone { op_id, message } => {
            handle_cloud_lookup_message_done(state, op_id, message.map(|m| *m), out);
        }
        Input::CloudResolveMediaDone {
            op_id,
            outcome,
            file_size,
        } => {
            handle_cloud_resolve_media_done(state, op_id, outcome, file_size, out);
        }
        Input::CloudResolveFileDone {
            op_id,
            outcome,
            file_size,
        } => {
            handle_cloud_resolve_file_done(state, op_id, outcome, file_size, out);
        }
        Input::CloudDeleteMessageApiDone { op_id, error } => {
            handle_cloud_delete_api_done(state, op_id, error, out);
        }
        Input::CloudRemoteDeleteDone { op_id } => {
            on_cloud_remote_delete_done(state, op_id, out);
        }
        _ => {}
    }
}

fn reduce_command(state: &mut CoreState, cmd: Command, op_id: Option<u64>, out: &mut ReduceOutput) {
    match cmd {
        Command::RefreshCloud => {
            let media_ids_by_conv = collect_memory_media_ids(state);
            out.effects.push(Effect::RefreshCloudData {
                op_id,
                media_ids_by_conv,
                skip_api_if_no_store: true,
            });
        }
        Command::CloudList {
            conv_id,
            kind,
            sort_by_size,
            ascending,
            offset,
            limit,
        } => {
            let Some(op_id) = op_id else {
                return;
            };
            let safe_offset = offset.max(0);
            let safe_limit = limit.max(1);
            let kind_tags: Vec<String> = match kind {
                Some(k) => vec![k.as_str().to_owned()],
                None => ["photo", "video", "file", "voice"]
                    .iter()
                    .map(|s| (*s).to_owned())
                    .collect(),
            };
            let excluding_self = if conv_id.is_none() {
                state.session.self_conversation_id.clone()
            } else {
                None
            };
            let memory_media = collect_list_memory_media_ids(
                state,
                conv_id.as_deref(),
                excluding_self.as_deref(),
                kind,
            );
            state.cloud.pending_lists.insert(
                op_id,
                PendingCloudList {
                    conv_id: conv_id.clone(),
                    excluding_self: excluding_self.clone(),
                    kind,
                    sort_by_size,
                    ascending,
                    safe_offset,
                    safe_limit,
                },
            );
            out.effects.push(Effect::CloudListStore {
                op_id,
                conv_id,
                excluding_self,
                kind_tags,
                sort_by_size,
                ascending,
                offset: safe_offset,
                limit: safe_limit,
                memory_media,
            });
        }
        Command::CloudThumbnail { key } => {
            let Some(op_id) = op_id else {
                return;
            };
            let parts = split_cloud_key(&key);
            let (Some(cid), Some(mid)) = (parts.first(), parts.get(1)) else {
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::MediaResolution(MediaResolutionOutcome::Unavailable),
                    after_store: false,
                });
                return;
            };
            let kind = if parts.get(2).copied() == Some("video") {
                "videoThumb"
            } else {
                "photo"
            };
            state.cloud.pending_thumbnails.insert(op_id);
            out.effects.push(Effect::Host(HostCall::CloudResolveMedia {
                op_id,
                conv_id: (*cid).to_owned(),
                msg_id: (*mid).to_owned(),
                kind: kind.to_owned(),
            }));
        }
        Command::CloudFetch { key } => {
            let Some(op_id) = op_id else {
                return;
            };
            let parts = split_cloud_key(&key);
            let (Some(cid), Some(mid)) = (parts.first(), parts.get(1)) else {
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::CloudFetch(CloudFetch::Failed(
                        CLOUD_NOT_FOUND_ERROR.to_owned(),
                    )),
                    after_store: false,
                });
                return;
            };
            let cid = (*cid).to_owned();
            let mid = (*mid).to_owned();
            if let Some(msg) = find_message_in_conv(state, &cid, &mid).cloned() {
                start_fetch_with_message(state, op_id, &cid, &mid, &msg, out);
                return;
            }
            if !cid.is_empty() {
                state.cloud.pending_fetches.insert(
                    op_id,
                    PendingCloudFetchStage::LookingUp {
                        conv_id: cid.clone(),
                        msg_id: mid.clone(),
                    },
                );
                out.effects.push(Effect::CloudLookupMessage {
                    op_id,
                    conv_id: cid,
                    msg_id: mid,
                });
                return;
            }
            if let Some(msg) = find_message_across_windows(state, &mid).cloned() {
                start_fetch_with_message(state, op_id, &cid, &mid, &msg, out);
            } else {
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::CloudFetch(CloudFetch::Failed(
                        CLOUD_NOT_FOUND_ERROR.to_owned(),
                    )),
                    after_store: false,
                });
            }
        }
        Command::CloudDelete { keys } => {
            let Some(op_id) = op_id else {
                return;
            };
            state.cloud.pending_deletes.insert(
                op_id,
                PendingCloudDelete {
                    original_keys: keys,
                    index: 0,
                    current_conv_id: String::new(),
                    current_msg_id: String::new(),
                    current_cli_msg_id: String::new(),
                    deleted: Vec::new(),
                    first_error: None,
                },
            );
            advance_cloud_delete(state, op_id, out);
        }
        Command::CloudSetOffload { enabled: _ } => {
            let mut next = state.cloud.snapshot.clone();
            next.settings.offload_enabled = false;
            next.settings.offload_available = false;
            if next != state.cloud.snapshot {
                state.cloud.snapshot = next;
                out.dirty.insert(DirtyKey::Cloud);
            }
            if let Some(op_id) = op_id {
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::CloudAction(CloudActionResult {
                        ok: false,
                        deleted: Vec::new(),
                        failed: Vec::new(),
                        error: Some(CLOUD_OFFLOAD_UNSUPPORTED_ERROR.to_owned()),
                    }),
                    after_store: false,
                });
            }
        }
        Command::ResetCloud => {
            if state.cloud.reset_snapshot() {
                out.dirty.insert(DirtyKey::Cloud);
            }
            out.effects.push(Effect::ClearCloudViewerKey);
            if let Some(op_id) = op_id {
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::Unit,
                    after_store: false,
                });
            }
        }
        _ => {}
    }
}

fn find_message_in_conv<'a>(
    state: &'a CoreState,
    conv_id: &str,
    msg_id: &str,
) -> Option<&'a ChatMessage> {
    state
        .messages
        .windows
        .get(conv_id)
        .and_then(|list| list.iter().find(|m| m.id == msg_id))
}

fn find_message_across_windows<'a>(state: &'a CoreState, msg_id: &str) -> Option<&'a ChatMessage> {
    state
        .messages
        .windows
        .values()
        .find_map(|list| list.iter().find(|m| m.id == msg_id))
}

fn handle_cloud_refresh_loaded(
    state: &mut CoreState,
    op_id: Option<u64>,
    server_snapshot: Option<&CloudServerSnapshot>,
    sql_summaries: &[StoredCloudConversationSummary],
    existing_ids_by_conv: &BTreeMap<String, BTreeSet<String>>,
    out: &mut ReduceOutput,
) {
    if apply_cloud_snapshot(state, sql_summaries, existing_ids_by_conv, server_snapshot) {
        out.dirty.insert(DirtyKey::Cloud);
    }
    if let Some(op_id) = op_id {
        if let Some(del) = state.cloud.pending_deletes.remove(&op_id) {
            let deleted_set: BTreeSet<&str> = del.deleted.iter().map(String::as_str).collect();
            let failed: Vec<String> = del
                .original_keys
                .into_iter()
                .filter(|k| !deleted_set.contains(k.as_str()))
                .collect();
            out.effects.push(Effect::CompleteOp {
                op_id,
                result: OpResult::CloudAction(CloudActionResult {
                    ok: !del.deleted.is_empty(),
                    deleted: del.deleted,
                    failed,
                    error: del.first_error,
                }),
                after_store: false,
            });
        } else {
            out.effects.push(Effect::CompleteOp {
                op_id,
                result: OpResult::Unit,
                after_store: false,
            });
        }
    }
}

struct CloudListStoreInput<'a> {
    op_id: u64,
    store_present: bool,
    existing_ids_by_conv: &'a BTreeMap<String, BTreeSet<String>>,
    sql_items: &'a [StoredCloudMediaItem],
    sql_has_more: bool,
    sql_error: bool,
}

fn handle_cloud_list_store_done(
    state: &mut CoreState,
    input: CloudListStoreInput<'_>,
    out: &mut ReduceOutput,
) {
    let op_id = input.op_id;
    let store_present = input.store_present;
    let existing_ids_by_conv = input.existing_ids_by_conv;
    let sql_items = input.sql_items;
    let sql_has_more = input.sql_has_more;
    let sql_error = input.sql_error;
    let Some(req) = state.cloud.pending_lists.remove(&op_id) else {
        return;
    };

    let mut unsynced_items: Vec<CloudItem> = Vec::new();
    let convs: Vec<String> = match &req.conv_id {
        Some(cid) => vec![cid.clone()],
        None => state
            .messages
            .windows
            .keys()
            .filter(|cid| req.excluding_self.as_deref() != Some(cid.as_str()))
            .cloned()
            .collect(),
    };
    for cid in convs {
        let Some(list) = state.messages.windows.get(&cid) else {
            continue;
        };
        if list.is_empty() {
            continue;
        }
        let has_media = list.iter().any(|m| message_cloud_kind(m).is_some());
        if !has_media {
            continue;
        }
        let persisted = existing_ids_by_conv.get(&cid);
        let (conv_name, _, _) = resolve_cloud_conversation_meta(state, &cid, "", "", None);
        for msg in list {
            if persisted.is_some_and(|set| set.contains(&msg.id)) {
                continue;
            }
            let Some(item) = cloud_item_from_message(msg, &cid, &conv_name) else {
                continue;
            };
            if req.kind.is_some_and(|k| k != item.kind) {
                continue;
            }
            unsynced_items.push(item);
        }
    }

    let safe_offset = usize::try_from(req.safe_offset).unwrap_or(0);
    let safe_limit = usize::try_from(req.safe_limit).unwrap_or(1);

    let page = if store_present {
        if unsynced_items.is_empty() {
            if sql_error {
                CloudPage {
                    items: Vec::new(),
                    has_more: false,
                    error: Some(CLOUD_LOCAL_READ_ERROR.to_owned()),
                }
            } else {
                let mapped: Vec<CloudItem> = sql_items
                    .iter()
                    .filter_map(|row| cloud_item_from_stored(state, row))
                    .collect();
                CloudPage {
                    items: mapped,
                    has_more: sql_has_more,
                    error: None,
                }
            }
        } else {
            let mut merged: Vec<CloudItem> = sql_items
                .iter()
                .filter_map(|row| cloud_item_from_stored(state, row))
                .collect();
            let mut seen_ids: BTreeSet<String> = merged.iter().map(|i| i.id.clone()).collect();
            for item in unsynced_items {
                if seen_ids.insert(item.id.clone()) {
                    merged.push(item);
                }
            }
            sort_cloud_items(&mut merged, req.sort_by_size, req.ascending);
            let total = merged.len();
            let sliced: Vec<CloudItem> = merged
                .into_iter()
                .skip(safe_offset)
                .take(safe_limit)
                .collect();
            let has_more = sql_has_more || safe_offset.saturating_add(sliced.len()) < total;
            CloudPage {
                items: sliced,
                has_more,
                error: None,
            }
        }
    } else {
        sort_cloud_items(&mut unsynced_items, req.sort_by_size, req.ascending);
        let total = unsynced_items.len();
        let sliced: Vec<CloudItem> = unsynced_items
            .into_iter()
            .skip(safe_offset)
            .take(safe_limit)
            .collect();
        let has_more = safe_offset.saturating_add(sliced.len()) < total;
        CloudPage {
            items: sliced,
            has_more,
            error: None,
        }
    };

    out.effects.push(Effect::CompleteOp {
        op_id,
        result: OpResult::CloudPage(page),
        after_store: false,
    });
}

fn start_fetch_with_message(
    state: &mut CoreState,
    op_id: u64,
    cid: &str,
    mid: &str,
    msg: &ChatMessage,
    out: &mut ReduceOutput,
) {
    match &msg.kind {
        Kind::Photo { .. } => {
            state.cloud.pending_fetches.insert(
                op_id,
                PendingCloudFetchStage::Resolving {
                    kind: CloudItemKind::Photo,
                    title: msg.text.clone(),
                    date_ms: Some(msg.date_ms),
                    fallback_size: ESTIMATED_PHOTO_BYTES,
                },
            );
            out.effects.push(Effect::Host(HostCall::CloudResolveMedia {
                op_id,
                conv_id: cid.to_owned(),
                msg_id: mid.to_owned(),
                kind: "photo".to_owned(),
            }));
        }
        Kind::Video { .. } => {
            state.cloud.pending_fetches.insert(
                op_id,
                PendingCloudFetchStage::Resolving {
                    kind: CloudItemKind::Video,
                    title: msg.text.clone(),
                    date_ms: Some(msg.date_ms),
                    fallback_size: ESTIMATED_VIDEO_BYTES,
                },
            );
            out.effects.push(Effect::Host(HostCall::CloudResolveMedia {
                op_id,
                conv_id: cid.to_owned(),
                msg_id: mid.to_owned(),
                kind: "video".to_owned(),
            }));
        }
        Kind::Voice { url, .. } => {
            state.cloud.pending_fetches.insert(
                op_id,
                PendingCloudFetchStage::Resolving {
                    kind: CloudItemKind::Voice,
                    title: msg.text.clone(),
                    date_ms: Some(msg.date_ms),
                    fallback_size: ESTIMATED_VOICE_BYTES,
                },
            );
            out.effects.push(Effect::Host(HostCall::CloudResolveFile {
                op_id,
                conv_id: cid.to_owned(),
                msg_id: mid.to_owned(),
                name: "Tin nhắn thoại.m4a".to_owned(),
                url: url.clone(),
            }));
        }
        Kind::File { name, size, url } => {
            state.cloud.pending_fetches.insert(
                op_id,
                PendingCloudFetchStage::Resolving {
                    kind: CloudItemKind::File,
                    title: name.clone(),
                    date_ms: Some(msg.date_ms),
                    fallback_size: (*size).max(0),
                },
            );
            out.effects.push(Effect::Host(HostCall::CloudResolveFile {
                op_id,
                conv_id: cid.to_owned(),
                msg_id: mid.to_owned(),
                name: name.clone(),
                url: url.clone(),
            }));
        }
        _ => {
            out.effects.push(Effect::CompleteOp {
                op_id,
                result: OpResult::CloudFetch(CloudFetch::Failed(
                    CLOUD_FETCH_FAILED_ERROR.to_owned(),
                )),
                after_store: false,
            });
        }
    }
}

fn handle_cloud_lookup_message_done(
    state: &mut CoreState,
    op_id: u64,
    message: Option<ChatMessage>,
    out: &mut ReduceOutput,
) {
    if let Some(PendingCloudFetchStage::LookingUp { conv_id, msg_id }) =
        state.cloud.pending_fetches.remove(&op_id)
    {
        let resolved = message.or_else(|| find_message_across_windows(state, &msg_id).cloned());
        if let Some(msg) = resolved {
            start_fetch_with_message(state, op_id, &conv_id, &msg_id, &msg, out);
        } else {
            out.effects.push(Effect::CompleteOp {
                op_id,
                result: OpResult::CloudFetch(CloudFetch::Failed(CLOUD_NOT_FOUND_ERROR.to_owned())),
                after_store: false,
            });
        }
        return;
    }

    if let Some(del) = state.cloud.pending_deletes.get(&op_id).cloned() {
        let resolved =
            message.or_else(|| find_message_across_windows(state, &del.current_msg_id).cloned());
        if let Some(msg) = resolved {
            let cli_msg_id = if msg.client_id.is_empty() {
                del.current_msg_id.clone()
            } else {
                msg.client_id.clone()
            };
            if let Some(entry) = state.cloud.pending_deletes.get_mut(&op_id) {
                entry.current_cli_msg_id = cli_msg_id.clone();
            }
            out.effects.push(Effect::CloudDeleteMessageApi {
                op_id,
                conv_id: del.current_conv_id,
                msg_id: del.current_msg_id,
                cli_msg_id,
                sender_id: msg.sender_id,
            });
        } else {
            if let Some(entry) = state.cloud.pending_deletes.get_mut(&op_id) {
                entry.index += 1;
            }
            advance_cloud_delete(state, op_id, out);
        }
    }
}

fn handle_cloud_resolve_media_done(
    state: &mut CoreState,
    op_id: u64,
    outcome: MediaResolutionOutcome,
    file_size: Option<i64>,
    out: &mut ReduceOutput,
) {
    if state.cloud.pending_thumbnails.remove(&op_id) {
        out.effects.push(Effect::CompleteOp {
            op_id,
            result: OpResult::MediaResolution(outcome),
            after_store: false,
        });
        return;
    }
    let Some(PendingCloudFetchStage::Resolving {
        kind,
        title,
        date_ms,
        fallback_size,
    }) = state.cloud.pending_fetches.remove(&op_id)
    else {
        return;
    };
    let fetch = match outcome {
        MediaResolutionOutcome::File(path) => CloudFetch::Ready(CloudFile {
            ext: path_extension(&path),
            path,
            kind,
            title,
            size: file_size.unwrap_or(fallback_size),
            date_ms,
        }),
        MediaResolutionOutcome::Expired => CloudFetch::Expired,
        MediaResolutionOutcome::Unsupported | MediaResolutionOutcome::Unavailable => {
            CloudFetch::Failed(CLOUD_FETCH_FAILED_ERROR.to_owned())
        }
    };
    out.effects.push(Effect::CompleteOp {
        op_id,
        result: OpResult::CloudFetch(fetch),
        after_store: false,
    });
}

fn handle_cloud_resolve_file_done(
    state: &mut CoreState,
    op_id: u64,
    outcome: FileResolutionOutcome,
    file_size: Option<i64>,
    out: &mut ReduceOutput,
) {
    let Some(PendingCloudFetchStage::Resolving {
        kind,
        title,
        date_ms,
        fallback_size,
    }) = state.cloud.pending_fetches.remove(&op_id)
    else {
        return;
    };
    let fetch = match outcome {
        FileResolutionOutcome::Ready(path) => CloudFetch::Ready(CloudFile {
            ext: path_extension(&path),
            path,
            kind,
            title,
            size: file_size.unwrap_or(fallback_size),
            date_ms,
        }),
        FileResolutionOutcome::Expired => CloudFetch::Expired,
        FileResolutionOutcome::Failed(err) => CloudFetch::Failed(err),
    };
    out.effects.push(Effect::CompleteOp {
        op_id,
        result: OpResult::CloudFetch(fetch),
        after_store: false,
    });
}

fn advance_cloud_delete(state: &mut CoreState, op_id: u64, out: &mut ReduceOutput) {
    loop {
        let next_key = {
            let Some(del) = state.cloud.pending_deletes.get(&op_id) else {
                return;
            };
            del.original_keys.get(del.index).cloned()
        };
        let Some(key) = next_key else {
            let media_ids_by_conv = collect_memory_media_ids(state);
            out.effects.push(Effect::RefreshCloudData {
                op_id: Some(op_id),
                media_ids_by_conv,
                skip_api_if_no_store: false,
            });
            return;
        };

        let parts = split_cloud_key(&key);
        let (Some(cid), Some(mid)) = (parts.first(), parts.get(1)) else {
            if let Some(del) = state.cloud.pending_deletes.get_mut(&op_id) {
                del.index += 1;
            }
            continue;
        };
        let cid = (*cid).to_owned();
        let mid = (*mid).to_owned();
        if let Some(del) = state.cloud.pending_deletes.get_mut(&op_id) {
            del.current_conv_id = cid.clone();
            del.current_msg_id = mid.clone();
        }

        if let Some(msg) = find_message_in_conv(state, &cid, &mid).cloned() {
            let cli_msg_id = if msg.client_id.is_empty() {
                mid.clone()
            } else {
                msg.client_id.clone()
            };
            if let Some(del) = state.cloud.pending_deletes.get_mut(&op_id) {
                del.current_cli_msg_id = cli_msg_id.clone();
            }
            out.effects.push(Effect::CloudDeleteMessageApi {
                op_id,
                conv_id: cid,
                msg_id: mid,
                cli_msg_id,
                sender_id: msg.sender_id,
            });
            return;
        }
        if !cid.is_empty() {
            out.effects.push(Effect::CloudLookupMessage {
                op_id,
                conv_id: cid,
                msg_id: mid,
            });
            return;
        }
        if let Some(msg) = find_message_across_windows(state, &mid).cloned() {
            let cli_msg_id = if msg.client_id.is_empty() {
                mid.clone()
            } else {
                msg.client_id.clone()
            };
            if let Some(del) = state.cloud.pending_deletes.get_mut(&op_id) {
                del.current_cli_msg_id = cli_msg_id.clone();
            }
            out.effects.push(Effect::CloudDeleteMessageApi {
                op_id,
                conv_id: cid,
                msg_id: mid,
                cli_msg_id,
                sender_id: msg.sender_id,
            });
            return;
        }
        if let Some(del) = state.cloud.pending_deletes.get_mut(&op_id) {
            del.index += 1;
        }
    }
}

fn handle_cloud_delete_api_done(
    state: &mut CoreState,
    op_id: u64,
    error: Option<String>,
    out: &mut ReduceOutput,
) {
    if let Some(err) = error {
        // Approved fix (user-decisions item 12.3): on an API error, keep the item locally
        // and record the failure rather than deleting it from SQLite/memory.
        if let Some(del) = state.cloud.pending_deletes.get_mut(&op_id) {
            if del.first_error.is_none() {
                del.first_error = Some(err);
            }
            del.index += 1;
        }
        advance_cloud_delete(state, op_id, out);
        return;
    }
    let Some(del) = state.cloud.pending_deletes.get(&op_id) else {
        return;
    };
    out.effects.push(Effect::Host(HostCall::ApplyRemoteDelete {
        conv_id: del.current_conv_id.clone(),
        msg_id: del.current_msg_id.clone(),
        cli_msg_id: del.current_cli_msg_id.clone(),
        update_conversation_preview: true,
        persist_conversations: true,
        cloud_delete_op_id: Some(op_id),
    }));
}

/// Resumes an in-flight `CloudDelete` batch after U6 remote-delete finishes for the current key.
pub fn on_cloud_remote_delete_done(state: &mut CoreState, op_id: u64, out: &mut ReduceOutput) {
    let Some(del) = state.cloud.pending_deletes.get_mut(&op_id) else {
        return;
    };
    if let Some(key) = del.original_keys.get(del.index).cloned() {
        del.deleted.push(key);
    }
    del.index += 1;
    advance_cloud_delete(state, op_id, out);
}

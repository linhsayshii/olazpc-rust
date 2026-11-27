//! Media upload/download orchestration, single-flight resolver, file-download tracking, and
//! shared-media reducer (U15, ADR-031).

use std::collections::BTreeSet;

use olaz_wire::{
    Availability, ChatMessage, DeleteMode, Kind, MessageMenu, StarMode, Status,
    encode_chat_message, is_group_id,
};

use crate::changes::DirtyKey;
use crate::composer::{COMPOSER_GENERIC_FAILURE, ComposerOutcome};
use crate::conversations::MessagePreviewInput;
use crate::effect::{Effect, HostCall, OpResult, StoreOp};
use crate::input::{Command, Input, SharedMediaLoadOutcome};
use crate::media::{
    ActiveMediaFlight, CandidateScheme, FileExistsPurpose, FileFetchOutcome, FileLoadError,
    FileResolution, MEDIA_SETTLED_PRUNE_THRESHOLD, MEDIA_UNAVAILABLE_TTL_MS, MediaFetchOutcome,
    MediaFlightPhase, MediaKind, MediaResolution, OutgoingFileMode, OutgoingFileProbe,
    PendingResolveFile, PendingSendFiles, PendingSendMedia, SettledMedia, SharedMediaKind,
    classify_candidate_scheme, extract_media_candidates, format_upload_file_error,
    is_image_extension, is_video_extension, last_path_component, sanitized_file_name,
    shared_media_memory, split_sanitized_stem_ext, stable_hash, validate_outgoing_file_probe,
};
use crate::messages::{is_valid_url_str, to_db_stored};
use crate::reduce::{ReduceOutput, conversations};
use crate::state::CoreState;

/// Returns true if `cmd` belongs to the U15 media domain.
#[must_use]
pub const fn is_media_command(cmd: &Command) -> bool {
    matches!(
        cmd,
        Command::SendMedia { .. }
            | Command::SendFiles { .. }
            | Command::ResolveMedia { .. }
            | Command::CancelMediaResolve { .. }
            | Command::ResolveFile { .. }
            | Command::SharedMedia { .. }
            | Command::RememberDownloadedFile { .. }
            | Command::ForgetDownloadedFile { .. }
            | Command::CheckRememberedDownloadedFile { .. }
            | Command::SeedDownloadedFilePaths(_)
            | Command::SeedMediaCloudFileLimit(_)
            | Command::ResetMedia
    )
}

/// Resets media state on logout, session expiry, or explicit `Command::ResetMedia`.
pub(crate) fn reset_media(state: &mut CoreState, out: &mut ReduceOutput) {
    let pending_media: Vec<PendingSendMedia> = state
        .media
        .pending_send_media
        .drain()
        .map(|(_, v)| v)
        .collect();
    for p in pending_media {
        out.effects
            .push(Effect::MediaReleaseOutgoingFile { op_id: p.op_id });
        complete_op(
            Some(p.op_id),
            OpResult::ComposerOutcome(ComposerOutcome::Cancelled),
            false,
            out,
        );
    }

    let pending_files: Vec<PendingSendFiles> = state
        .media
        .pending_send_files
        .drain()
        .map(|(_, v)| v)
        .collect();
    for p in pending_files {
        out.effects
            .push(Effect::MediaReleaseOutgoingFile { op_id: p.op_id });
        complete_op(
            Some(p.op_id),
            OpResult::ComposerOutcome(ComposerOutcome::Cancelled),
            false,
            out,
        );
    }

    let pending_resolve: Vec<PendingResolveFile> = state
        .media
        .pending_resolve_files
        .drain()
        .map(|(_, v)| v)
        .collect();
    for p in pending_resolve {
        complete_op(
            Some(p.op_id),
            OpResult::FileResolution(FileResolution::Failed(
                FileLoadError::Cancelled.user_message(),
            )),
            false,
            out,
        );
    }

    let flights: Vec<ActiveMediaFlight> = state.media.flights.drain().map(|(_, v)| v).collect();
    for f in flights {
        for waiter in f.waiters {
            complete_op(
                Some(waiter),
                OpResult::MediaResolution(MediaResolution::Unavailable),
                false,
                out,
            );
        }
    }

    state.media.flight_id_to_key.clear();
    state.media.queue.clear();
    state.media.running = 0;
    state.media.settled.clear();
    if !state.media.downloaded_file_paths.is_empty() {
        state.media.downloaded_file_paths.clear();
        out.dirty.insert(DirtyKey::DownloadedFilePaths);
    }
}

/// Pure reducer entry point for the U15 media domain.
pub fn reduce_media(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::Command(cmd) => handle_command(state, None, cmd, out),
        Input::OpRequest { op_id, cmd } => handle_command(state, Some(op_id), cmd, out),

        Input::MediaOutgoingFileRead { op_id, probe } => {
            on_outgoing_file_read(state, op_id, probe, out);
        }
        Input::MediaImageDimensionsDone {
            op_id,
            width,
            height,
        } => {
            on_image_dimensions_done(state, op_id, width, height, out);
        }
        Input::MediaVideoMetadataDone { op_id, meta } => {
            on_video_metadata_done(state, op_id, meta, out);
        }
        Input::MediaUploadPhotoDone { op_id, result } => {
            on_upload_photo_done(state, op_id, result, out);
        }
        Input::MediaUploadVideoDone { op_id, result } => {
            on_upload_video_done(state, op_id, result, out);
        }
        Input::MediaClientIdAllocated { op_id, client_id } => {
            on_client_id_allocated(state, op_id, client_id, out);
        }
        Input::MediaUploadFileDone { op_id, result } => {
            on_upload_file_done(state, op_id, result, out);
        }

        Input::MediaFileExistsChecked { purpose, exists } => {
            on_file_exists_checked(state, purpose, exists, out);
        }
        Input::MediaStoreMessageLoaded { flight_id, message } => {
            on_store_message_loaded(state, flight_id, message, out);
        }
        Input::MediaCacheLookupDone { flight_id, hit } => {
            on_cache_lookup_done(state, flight_id, hit, out);
        }
        Input::MediaLocalFileChecked {
            flight_id,
            allowed,
            path,
            is_video,
        } => {
            on_local_file_checked(state, flight_id, allowed, path, is_video, out);
        }
        Input::MediaLoaderFetchMediaDone { flight_id, outcome } => {
            on_loader_fetch_media_done(state, flight_id, outcome, out);
        }
        Input::MediaVideoPosterDone {
            flight_id,
            poster_path,
            from_cache,
        } => {
            on_video_poster_done(state, flight_id, poster_path, from_cache, out);
        }

        Input::MediaFileMessageLoaded { op_id, message } => {
            on_file_message_loaded(state, op_id, message, out);
        }
        Input::MediaLoaderFetchFileDone { op_id, outcome } => {
            on_loader_fetch_file_done(state, op_id, outcome, out);
        }
        Input::MediaFileStaged { op_id, staged_path } => {
            on_file_staged(state, op_id, staged_path, out);
        }

        Input::MediaSharedMediaLoaded {
            op_id,
            conv_id,
            kind,
            limit,
            outcome,
        } => {
            on_shared_media_loaded(state, op_id, &conv_id, kind, limit, outcome, out);
        }
        _ => {}
    }
}

fn handle_command(state: &mut CoreState, op_id: Option<u64>, cmd: Command, out: &mut ReduceOutput) {
    match cmd {
        Command::SendMedia {
            conv_id,
            paths,
            now_ms,
        } => {
            if paths.is_empty() || conv_id.is_empty() {
                complete_op(
                    op_id,
                    OpResult::ComposerOutcome(ComposerOutcome::Cancelled),
                    false,
                    out,
                );
                return;
            }
            let Some(op_id) = op_id else {
                return;
            };
            state.media.pending_send_media.insert(
                op_id,
                PendingSendMedia {
                    op_id,
                    conv_id,
                    paths,
                    idx: 0,
                    sent_any: false,
                    now_ms,
                    current_file_name: String::new(),
                    current_size: 0,
                },
            );
            advance_send_media(state, op_id, out);
        }

        Command::SendFiles {
            conv_id,
            paths,
            now_ms,
        } => {
            if paths.is_empty() || conv_id.is_empty() {
                complete_op(
                    op_id,
                    OpResult::ComposerOutcome(ComposerOutcome::Cancelled),
                    false,
                    out,
                );
                return;
            }
            let Some(op_id) = op_id else {
                return;
            };
            let max_bytes = state
                .media
                .effective_file_limit(state.cloud.snapshot.plan.as_ref().map(|p| p.file_limit));
            let is_group = is_group_id(&conv_id);
            let is_e2ee = if is_group {
                false
            } else {
                state.send.e2ee_threads.contains(&conv_id)
            };
            state.media.pending_send_files.insert(
                op_id,
                PendingSendFiles {
                    op_id,
                    conv_id,
                    paths,
                    idx: 0,
                    max_bytes,
                    is_group,
                    is_e2ee,
                    sent_any: false,
                    last_failure: None,
                    now_ms,
                    current_file_name: String::new(),
                    current_size: 0,
                    current_client_id: None,
                },
            );
            advance_send_files(state, op_id, out);
        }

        Command::ResolveMedia {
            conv_id,
            msg_id,
            kind,
            force,
            now_ms,
        } => {
            let Some(op_id) = op_id else {
                return;
            };
            handle_resolve_media(state, op_id, conv_id, msg_id, kind, force, now_ms, out);
        }

        Command::CancelMediaResolve { op_id: target_op } => {
            cancel_media_resolve_waiter(state, target_op, out);
        }

        Command::ResolveFile {
            conv_id,
            msg_id,
            name,
            url,
            force,
            request_token,
        } => {
            let Some(op_id) = op_id else {
                return;
            };
            handle_resolve_file(
                state,
                op_id,
                conv_id,
                msg_id,
                name,
                url,
                force,
                request_token,
                out,
            );
        }

        Command::SharedMedia {
            conv_id,
            kind,
            after_cursor,
            limit,
            simulate_store_error,
        } => {
            if simulate_store_error {
                complete_op(op_id, OpResult::SharedMedia(None), false, out);
                return;
            }
            let Some(op_id) = op_id else {
                return;
            };
            out.effects.push(Effect::MediaQuerySharedMedia {
                op_id,
                conv_id,
                kind,
                after_cursor,
                limit,
            });
        }

        Command::RememberDownloadedFile { key, path } => {
            if state.media.downloaded_file_paths.get(&key) != Some(&path) {
                state.media.downloaded_file_paths.insert(key, path);
                out.dirty.insert(DirtyKey::DownloadedFilePaths);
            }
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::ForgetDownloadedFile { key } => {
            if state.media.downloaded_file_paths.remove(&key).is_some() {
                out.dirty.insert(DirtyKey::DownloadedFilePaths);
            }
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::CheckRememberedDownloadedFile { key } => {
            let Some(op_id) = op_id else {
                return;
            };
            let Some(path) = state.media.downloaded_file_paths.get(&key).cloned() else {
                complete_op(op_id.into(), OpResult::OptionalString(None), false, out);
                return;
            };
            out.effects.push(Effect::MediaCheckFileExists {
                path: path.clone(),
                purpose: FileExistsPurpose::DownloadedFile { op_id, key, path },
            });
        }

        Command::SeedDownloadedFilePaths(paths) => {
            state.media.downloaded_file_paths = paths;
            out.dirty.insert(DirtyKey::DownloadedFilePaths);
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::SeedMediaCloudFileLimit(limit) => {
            state.media.seeded_cloud_file_limit = limit;
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::ResetMedia => {
            reset_media(state, out);
            complete_op(op_id, OpResult::Unit, false, out);
        }

        _ => {}
    }
}

// MARK: - Outgoing send_media / send_files

fn advance_send_media(state: &mut CoreState, op_id: u64, out: &mut ReduceOutput) {
    let Some(pending) = state.media.pending_send_media.get_mut(&op_id) else {
        return;
    };
    if pending.idx >= pending.paths.len() {
        let finished = state.media.pending_send_media.remove(&op_id);
        let sent_any = finished.as_ref().is_some_and(|p| p.sent_any);
        let outcome = if sent_any {
            ComposerOutcome::Done
        } else {
            ComposerOutcome::Failed(COMPOSER_GENERIC_FAILURE.to_owned())
        };
        complete_op(
            Some(op_id),
            OpResult::ComposerOutcome(outcome),
            sent_any,
            out,
        );
        return;
    }

    let path = pending.paths[pending.idx].clone();
    let name = last_path_component(&path);
    pending.current_file_name = name.clone();
    pending.current_size = 0;
    pending.idx += 1;

    out.effects.push(Effect::MediaReadOutgoingFile {
        op_id,
        path,
        name,
        mode: OutgoingFileMode::Media,
    });
}

fn advance_send_files(state: &mut CoreState, op_id: u64, out: &mut ReduceOutput) {
    let Some(pending) = state.media.pending_send_files.get_mut(&op_id) else {
        return;
    };
    if pending.idx >= pending.paths.len() {
        let Some(finished) = state.media.pending_send_files.remove(&op_id) else {
            return;
        };
        if finished.sent_any {
            if let Some(failure) = finished.last_failure {
                out.effects.push(Effect::Host(HostCall::ShowCard {
                    conv_id: Some(finished.conv_id),
                    text: failure,
                }));
            }
            complete_op(
                Some(op_id),
                OpResult::ComposerOutcome(ComposerOutcome::Done),
                true,
                out,
            );
        } else {
            complete_op(
                Some(op_id),
                OpResult::ComposerOutcome(ComposerOutcome::Failed(
                    finished
                        .last_failure
                        .unwrap_or_else(|| COMPOSER_GENERIC_FAILURE.to_owned()),
                )),
                false,
                out,
            );
        }
        return;
    }

    let path = pending.paths[pending.idx].clone();
    let name = last_path_component(&path);
    pending.current_file_name = name.clone();
    pending.current_size = 0;
    pending.current_client_id = None;
    pending.idx += 1;

    out.effects.push(Effect::MediaReadOutgoingFile {
        op_id,
        path,
        name,
        mode: OutgoingFileMode::File,
    });
}

fn on_outgoing_file_read(
    state: &mut CoreState,
    op_id: u64,
    probe: OutgoingFileProbe,
    out: &mut ReduceOutput,
) {
    if let Some(pending) = state.media.pending_send_media.get_mut(&op_id) {
        if !probe.exists || probe.is_dir || !probe.readable {
            out.effects.push(Effect::MediaReleaseOutgoingFile { op_id });
            advance_send_media(state, op_id, out);
            return;
        }
        let path = pending.paths[pending.idx.saturating_sub(1)].clone();
        let name = pending.current_file_name.clone();
        let conv_id = pending.conv_id.clone();
        let size = probe.size;
        pending.current_size = size;

        let (is_image, is_video) = if let Some(hint) = probe.media_type.as_deref() {
            (hint == "image", hint == "video")
        } else {
            let img = is_image_extension(&name);
            let vid = !img && is_video_extension(&name);
            (img, vid)
        };

        if is_image {
            out.effects.push(Effect::MediaImageDimensions {
                op_id,
                path,
                name,
                size,
            });
        } else if is_video {
            out.effects.push(Effect::MediaVideoMetadata {
                op_id,
                path,
                name,
                size,
            });
        } else {
            out.effects.push(Effect::MediaUploadFile {
                op_id,
                conv_id,
                file_name: name,
                size,
                client_id: None,
                is_e2ee: false,
            });
        }
        return;
    }

    if let Some(pending) = state.media.pending_send_files.get_mut(&op_id) {
        let name = pending.current_file_name.clone();
        let max_bytes = pending.max_bytes;
        if let Some(reason) = validate_outgoing_file_probe(&name, &probe, max_bytes) {
            pending.last_failure = Some(reason);
            out.effects.push(Effect::MediaReleaseOutgoingFile { op_id });
            advance_send_files(state, op_id, out);
            return;
        }
        pending.current_size = probe.size;
        out.effects.push(Effect::MediaAllocClientId { op_id });
    }
}

fn on_image_dimensions_done(
    state: &mut CoreState,
    op_id: u64,
    width: i64,
    height: i64,
    out: &mut ReduceOutput,
) {
    let Some(pending) = state.media.pending_send_media.get(&op_id) else {
        return;
    };
    out.effects.push(Effect::MediaUploadPhoto {
        op_id,
        conv_id: pending.conv_id.clone(),
        file_name: pending.current_file_name.clone(),
        size: pending.current_size,
        width,
        height,
    });
}

fn on_video_metadata_done(
    state: &mut CoreState,
    op_id: u64,
    meta: crate::media::VideoMetadata,
    out: &mut ReduceOutput,
) {
    let Some(pending) = state.media.pending_send_media.get(&op_id) else {
        return;
    };
    out.effects.push(Effect::MediaUploadVideo {
        op_id,
        conv_id: pending.conv_id.clone(),
        file_name: pending.current_file_name.clone(),
        size: pending.current_size,
        duration_ms: meta.duration_ms,
        width: meta.width,
        height: meta.height,
        has_thumb: meta.has_thumb,
    });
}

fn on_upload_photo_done(
    state: &mut CoreState,
    op_id: u64,
    result: Result<crate::media::UploadedPhotoResult, String>,
    out: &mut ReduceOutput,
) {
    out.effects.push(Effect::MediaReleaseOutgoingFile { op_id });
    let Some((conv_id, now_ms)) = state
        .media
        .pending_send_media
        .get(&op_id)
        .map(|p| (p.conv_id.clone(), p.now_ms))
    else {
        return;
    };

    match result {
        Ok(res) => {
            record_uploaded_message(
                state,
                &conv_id,
                res.msg_id,
                res.cli_msg_id,
                Kind::Photo {
                    url: non_empty_url(res.url),
                    width: res.width,
                    height: res.height,
                },
                String::new(),
                false,
                now_ms,
                out,
            );
            if let Some(pending) = state.media.pending_send_media.get_mut(&op_id) {
                pending.sent_any = true;
            }
        }
        Err(err) => {
            out.effects
                .push(Effect::EngineLog(format!("sendMedia failed: {err}")));
        }
    }
    advance_send_media(state, op_id, out);
}

fn on_upload_video_done(
    state: &mut CoreState,
    op_id: u64,
    result: Result<crate::media::UploadedVideoResult, String>,
    out: &mut ReduceOutput,
) {
    out.effects.push(Effect::MediaReleaseOutgoingFile { op_id });
    let Some((conv_id, now_ms)) = state
        .media
        .pending_send_media
        .get(&op_id)
        .map(|p| (p.conv_id.clone(), p.now_ms))
    else {
        return;
    };

    match result {
        Ok(res) => {
            #[expect(
                clippy::cast_possible_truncation,
                clippy::cast_precision_loss,
                reason = "Matches Swift Int((Double(res.durationMs) / 1000.0).rounded())"
            )]
            let dur_sec = if res.duration_ms > 0 {
                ((res.duration_ms as f64) / 1000.0).round() as i64
            } else {
                0
            }
            .max(i64::from(res.duration_ms > 0));
            record_uploaded_message(
                state,
                &conv_id,
                res.msg_id,
                res.cli_msg_id,
                Kind::Video {
                    thumbnail: non_empty_url(res.thumb_url),
                    duration: dur_sec,
                    url: non_empty_url(res.url),
                },
                String::new(),
                false,
                now_ms,
                out,
            );
            if let Some(pending) = state.media.pending_send_media.get_mut(&op_id) {
                pending.sent_any = true;
            }
        }
        Err(err) => {
            out.effects
                .push(Effect::EngineLog(format!("sendMedia failed: {err}")));
        }
    }
    advance_send_media(state, op_id, out);
}

fn on_client_id_allocated(
    state: &mut CoreState,
    op_id: u64,
    client_id: i64,
    out: &mut ReduceOutput,
) {
    let Some((conv_id, file_name, file_size, is_group, is_e2ee, now_ms)) =
        state.media.pending_send_files.get(&op_id).map(|p| {
            (
                p.conv_id.clone(),
                p.current_file_name.clone(),
                p.current_size,
                p.is_group,
                p.is_e2ee,
                p.now_ms,
            )
        })
    else {
        return;
    };

    let cli_id = client_id.to_string();
    if let Some(pending) = state.media.pending_send_files.get_mut(&op_id) {
        pending.current_client_id = Some(cli_id.clone());
    }

    let is_self = state.session.self_conversation_id.as_deref() == Some(conv_id.as_str());
    let (sender_id, sender_name, sender_avatar) = my_sender_fields(state);
    let optimistic = ChatMessage {
        id: cli_id.clone(),
        conversation_id: conv_id.clone(),
        sender_id,
        sender_name,
        sender_avatar,
        is_mine: true,
        kind: Kind::File {
            name: file_name.clone(),
            size: file_size,
            url: None,
        },
        text: file_name.clone(),
        date_ms: now_ms,
        status: Status::Sending,
        quote: None,
        reactions: Vec::new(),
        is_e2ee,
        mentions: Vec::new(),
        card_buttons: Vec::new(),
        suggests_stickers: false,
        menu: outgoing_media_menu(is_group, is_self),
        fallback_urls: Vec::new(),
        client_id: cli_id.clone(),
        text_styles: Vec::new(),
        ttl_ms: 0,
        urgency: 0,
    };

    let snap = state.identity_snapshot();
    state.messages.merge_message(optimistic, None, &snap);
    out.dirty.insert(DirtyKey::Messages);

    out.effects.push(Effect::MediaUploadFile {
        op_id,
        conv_id,
        file_name,
        size: file_size,
        client_id: Some(cli_id),
        is_e2ee,
    });
}

fn on_upload_file_done(
    state: &mut CoreState,
    op_id: u64,
    result: Result<crate::media::UploadedFileResult, crate::media::UploadFileError>,
    out: &mut ReduceOutput,
) {
    out.effects.push(Effect::MediaReleaseOutgoingFile { op_id });

    // Branch 1: non-image/non-video fallback inside `send_media`.
    if let Some((conv_id, file_name, file_size, now_ms)) =
        state.media.pending_send_media.get(&op_id).map(|p| {
            (
                p.conv_id.clone(),
                p.current_file_name.clone(),
                p.current_size,
                p.now_ms,
            )
        })
    {
        match result {
            Ok(res) => {
                record_uploaded_message(
                    state,
                    &conv_id,
                    res.msg_id,
                    res.cli_msg_id,
                    Kind::File {
                        name: file_name.clone(),
                        size: file_size,
                        url: non_empty_url(res.url),
                    },
                    file_name,
                    false,
                    now_ms,
                    out,
                );
                if let Some(pending) = state.media.pending_send_media.get_mut(&op_id) {
                    pending.sent_any = true;
                }
            }
            Err(err) => {
                out.effects
                    .push(Effect::EngineLog(format!("sendMedia failed: {err:?}")));
            }
        }
        advance_send_media(state, op_id, out);
        return;
    }

    // Branch 2: `send_files`.
    let Some((conv_id, file_name, file_size, is_e2ee, now_ms, cli_id)) =
        state.media.pending_send_files.get(&op_id).map(|p| {
            (
                p.conv_id.clone(),
                p.current_file_name.clone(),
                p.current_size,
                p.is_e2ee,
                p.now_ms,
                p.current_client_id.clone().unwrap_or_default(),
            )
        })
    else {
        return;
    };

    match result {
        Ok(res) => {
            let effective_cli = if res.cli_msg_id.is_empty() {
                cli_id
            } else {
                res.cli_msg_id
            };
            record_uploaded_message(
                state,
                &conv_id,
                res.msg_id,
                effective_cli,
                Kind::File {
                    name: file_name.clone(),
                    size: file_size,
                    url: non_empty_url(res.url),
                },
                file_name,
                is_e2ee,
                now_ms,
                out,
            );
            if let Some(pending) = state.media.pending_send_files.get_mut(&op_id) {
                pending.sent_any = true;
            }
        }
        Err(err) => {
            remove_optimistic_file(state, &conv_id, &cli_id, out);
            let msg = format_upload_file_error(&file_name, &err);
            out.effects
                .push(Effect::EngineLog(format!("sendFiles failed: {err:?}")));
            if let Some(pending) = state.media.pending_send_files.get_mut(&op_id) {
                pending.last_failure = Some(msg);
            }
        }
    }
    advance_send_files(state, op_id, out);
}

fn remove_optimistic_file(
    state: &mut CoreState,
    conv_id: &str,
    cli_id: &str,
    out: &mut ReduceOutput,
) {
    if cli_id.is_empty() {
        return;
    }
    let mut ids = BTreeSet::new();
    ids.insert(cli_id.to_owned());
    if let Some(list) = state.messages.windows.get(conv_id) {
        for m in list {
            if m.id == cli_id || m.client_id == cli_id {
                ids.insert(m.id.clone());
            }
        }
    }
    let ids_vec: Vec<String> = ids.into_iter().collect();
    state.messages.write_through_remove(conv_id, &ids_vec);
    out.dirty.insert(DirtyKey::Messages);
}

#[expect(
    clippy::too_many_arguments,
    reason = "Matches ZaloEngine.recordUploadedMessage parameters"
)]
pub(crate) fn record_uploaded_message(
    state: &mut CoreState,
    conv_id: &str,
    msg_id: String,
    cli_id: String,
    kind: Kind,
    text: String,
    is_e2ee: bool,
    now_ms: i64,
    out: &mut ReduceOutput,
) {
    let is_self = state.session.self_conversation_id.as_deref() == Some(conv_id);
    let is_group = is_group_id(conv_id);
    let (sender_id, sender_name, sender_avatar) = my_sender_fields(state);
    let msg = ChatMessage {
        id: msg_id,
        conversation_id: conv_id.to_owned(),
        sender_id,
        sender_name,
        sender_avatar,
        is_mine: true,
        kind,
        text,
        date_ms: now_ms,
        status: Status::Sent,
        quote: None,
        reactions: Vec::new(),
        is_e2ee,
        mentions: Vec::new(),
        card_buttons: Vec::new(),
        suggests_stickers: false,
        menu: outgoing_media_menu(is_group, is_self),
        fallback_urls: Vec::new(),
        client_id: cli_id.clone(),
        text_styles: Vec::new(),
        ttl_ms: 0,
        urgency: 0,
    };

    let snap = state.identity_snapshot();
    let replacing = (!cli_id.is_empty()).then_some(cli_id.as_str());
    state.messages.merge_message(msg.clone(), replacing, &snap);
    out.dirty.insert(DirtyKey::Messages);

    if let Some(wire_stored) = encode_chat_message(&msg, &cli_id) {
        out.effects.push(Effect::Store(StoreOp::SaveMessages {
            rows: vec![to_db_stored(&wire_stored)],
            preserve_existing_reactions: false,
        }));
    }

    let my_uid = state
        .session
        .profile
        .as_ref()
        .map_or("", |p| p.user_id.as_str())
        .to_owned();
    let my_avatar = state
        .session
        .profile
        .as_ref()
        .and_then(|p| p.avatar.as_deref())
        .map(str::to_owned);
    let self_conv_id = state.session.self_conversation_id.clone();
    let preview_input = MessagePreviewInput::from_chat_message(&msg);
    if state.conversations.update_conversation_on_message(
        &preview_input,
        false,
        &my_uid,
        my_avatar.as_deref(),
        self_conv_id.as_deref(),
    ) {
        out.dirty.insert(DirtyKey::Conversations);
        out.dirty.insert(DirtyKey::ConversationFlags);
        out.dirty.insert(DirtyKey::ConversationExtras);
        conversations::emit_save_conversations(state, out);
    }
}

fn my_sender_fields(state: &CoreState) -> (String, String, Option<String>) {
    let my_uid = state
        .session
        .profile
        .as_ref()
        .map_or_else(String::new, |p| p.user_id.clone());
    let my_name = state
        .session
        .profile
        .as_ref()
        .map_or_else(|| "Bạn".to_owned(), |p| p.display_name.clone());
    let my_avatar = state
        .session
        .profile
        .as_ref()
        .and_then(|p| p.avatar.clone())
        .filter(|s| is_valid_url_str(s));
    (my_uid, my_name, my_avatar)
}

fn outgoing_media_menu(is_group: bool, is_self: bool) -> MessageMenu {
    MessageMenu {
        forward: Availability::Available,
        recall: !is_self,
        delete: Some(if is_self {
            DeleteMode::Plain
        } else {
            DeleteMode::ForMe
        }),
        pin: is_group && !is_self,
        star: Some(StarMode::Star),
        starred: false,
        pinned: false,
        is_protected: false,
    }
}

fn non_empty_url(url: String) -> Option<String> {
    if url.is_empty() || !is_valid_url_str(&url) {
        None
    } else {
        Some(url)
    }
}

// MARK: - resolve_media (single-flight + 3-slot LIFO + settled TTL cache)

#[expect(
    clippy::too_many_arguments,
    reason = "Matches Command::ResolveMedia parameters"
)]
fn handle_resolve_media(
    state: &mut CoreState,
    op_id: u64,
    conv_id: String,
    msg_id: String,
    kind: MediaKind,
    force: bool,
    now_ms: i64,
    out: &mut ReduceOutput,
) {
    let key = format!("{conv_id}|{msg_id}|{}", kind.as_str());

    // If `force`, delete any previously known own local file before retrying.
    if force
        && let Some(SettledMedia {
            resolution: MediaResolution::File(bad_path),
            ..
        }) = state.media.settled.get(&key)
    {
        out.effects.push(Effect::MediaRemoveOwnLocalFile {
            path: bad_path.clone(),
        });
    }

    if let Some(known) = state.media.settled.get(&key)
        && known.until_ms > now_ms
    {
        match &known.resolution {
            MediaResolution::Unavailable | MediaResolution::File(_) if force => {}
            MediaResolution::File(path) => {
                let path_clone = path.clone();
                out.effects.push(Effect::MediaCheckFileExists {
                    path: path_clone.clone(),
                    purpose: FileExistsPurpose::SettledMedia {
                        op_id,
                        conv_id,
                        msg_id,
                        kind,
                        force,
                        now_ms,
                        path: path_clone,
                    },
                });
                return;
            }
            res => {
                complete_op(
                    Some(op_id),
                    OpResult::MediaResolution(res.clone()),
                    false,
                    out,
                );
                return;
            }
        }
    }

    enqueue_media_flight(state, op_id, key, conv_id, msg_id, kind, force, now_ms, out);
}

fn on_file_exists_checked(
    state: &mut CoreState,
    purpose: FileExistsPurpose,
    exists: bool,
    out: &mut ReduceOutput,
) {
    match purpose {
        FileExistsPurpose::SettledMedia {
            op_id,
            conv_id,
            msg_id,
            kind,
            force,
            now_ms,
            path,
        } => {
            if exists {
                complete_op(
                    Some(op_id),
                    OpResult::MediaResolution(MediaResolution::File(path)),
                    false,
                    out,
                );
            } else {
                let key = format!("{conv_id}|{msg_id}|{}", kind.as_str());
                enqueue_media_flight(state, op_id, key, conv_id, msg_id, kind, force, now_ms, out);
            }
        }
        FileExistsPurpose::DownloadedFile { op_id, key, path } => {
            if exists {
                complete_op(
                    Some(op_id),
                    OpResult::OptionalString(Some(path)),
                    false,
                    out,
                );
            } else {
                if state.media.downloaded_file_paths.remove(&key).is_some() {
                    out.dirty.insert(DirtyKey::DownloadedFilePaths);
                }
                complete_op(Some(op_id), OpResult::OptionalString(None), false, out);
            }
        }
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "Single-flight enqueue parameters"
)]
fn enqueue_media_flight(
    state: &mut CoreState,
    op_id: u64,
    key: String,
    conv_id: String,
    msg_id: String,
    kind: MediaKind,
    force: bool,
    now_ms: i64,
    out: &mut ReduceOutput,
) {
    if let Some(existing) = state.media.flights.get_mut(&key) {
        existing.waiters.push(op_id);
        return;
    }

    let flight_id = state.media.alloc_flight_id();
    let flight = ActiveMediaFlight {
        flight_id,
        conv_id,
        msg_id,
        kind,
        force,
        now_ms,
        waiters: vec![op_id],
        phase: MediaFlightPhase::Queued,
    };
    state.media.flights.insert(key.clone(), flight);
    state.media.flight_id_to_key.insert(flight_id, key.clone());

    if state.media.running < state.media.max_concurrent {
        state.media.running += 1;
        start_media_flight(state, &key, out);
    } else {
        state.media.queue.push(key);
    }
}

fn cancel_media_resolve_waiter(state: &mut CoreState, op_id: u64, out: &mut ReduceOutput) {
    let mut found_key: Option<String> = None;
    for (k, flight) in &mut state.media.flights {
        if let Some(pos) = flight.waiters.iter().position(|&w| w == op_id) {
            flight.waiters.remove(pos);
            found_key = Some(k.clone());
            break;
        }
    }
    let Some(key) = found_key else {
        return;
    };
    complete_op(
        Some(op_id),
        OpResult::MediaResolution(MediaResolution::Unavailable),
        false,
        out,
    );

    let should_drop_queued = state
        .media
        .flights
        .get(&key)
        .is_some_and(|f| f.waiters.is_empty() && matches!(f.phase, MediaFlightPhase::Queued));
    if should_drop_queued {
        if let Some(flight) = state.media.flights.remove(&key) {
            state.media.flight_id_to_key.remove(&flight.flight_id);
        }
        if let Some(pos) = state.media.queue.iter().position(|k| k == &key) {
            state.media.queue.remove(pos);
        }
    }
}

fn start_media_flight(state: &mut CoreState, key: &str, out: &mut ReduceOutput) {
    let Some((flight_id, conv_id, msg_id)) = state
        .media
        .flights
        .get(key)
        .map(|f| (f.flight_id, f.conv_id.clone(), f.msg_id.clone()))
    else {
        return;
    };

    // 1. Check in-memory window for `conv_id`.
    if !conv_id.is_empty()
        && let Some(hit) = state
            .messages
            .windows
            .get(&conv_id)
            .and_then(|list| list.iter().find(|m| m.id == msg_id))
            .cloned()
    {
        continue_media_flight_with_message(state, flight_id, Some(hit), out);
        return;
    }

    // 2. Check SQLite store for `(conv_id, msg_id)` if `conv_id` is non-empty.
    if !conv_id.is_empty() {
        if let Some(f) = state.media.flights.get_mut(key) {
            f.phase = MediaFlightPhase::LookupStore;
        }
        out.effects.push(Effect::MediaLookupMessageInStore {
            flight_id,
            conv_id,
            msg_id,
        });
        return;
    }

    // 3. Scan other in-memory windows.
    let fallback = find_message_across_all_windows(state, &msg_id);
    continue_media_flight_with_message(state, flight_id, fallback, out);
}

fn on_store_message_loaded(
    state: &mut CoreState,
    flight_id: u64,
    message: Option<ChatMessage>,
    out: &mut ReduceOutput,
) {
    let Some(key) = state.media.flight_id_to_key.get(&flight_id).cloned() else {
        return;
    };
    let Some(msg_id) = state.media.flights.get(&key).map(|f| f.msg_id.clone()) else {
        return;
    };
    let resolved = message.or_else(|| find_message_across_all_windows(state, &msg_id));
    continue_media_flight_with_message(state, flight_id, resolved, out);
}

fn find_message_across_all_windows(state: &CoreState, msg_id: &str) -> Option<ChatMessage> {
    for list in state.messages.windows.values() {
        if let Some(hit) = list.iter().find(|m| m.id == msg_id) {
            return Some(hit.clone());
        }
    }
    None
}

fn continue_media_flight_with_message(
    state: &mut CoreState,
    flight_id: u64,
    message: Option<ChatMessage>,
    out: &mut ReduceOutput,
) {
    let Some(key) = state.media.flight_id_to_key.get(&flight_id).cloned() else {
        return;
    };
    let Some((conv_id, msg_id, kind, force)) = state
        .media
        .flights
        .get(&key)
        .map(|f| (f.conv_id.clone(), f.msg_id.clone(), f.kind, f.force))
    else {
        return;
    };

    let Some(msg) = message else {
        finish_media_flight(state, flight_id, MediaResolution::Unavailable, out);
        return;
    };

    let candidates = match extract_media_candidates(kind, &msg) {
        Ok(c) if !c.is_empty() => c,
        Ok(_) => {
            finish_media_flight(state, flight_id, MediaResolution::Unavailable, out);
            return;
        }
        Err(()) => {
            finish_media_flight(state, flight_id, MediaResolution::Unsupported, out);
            return;
        }
    };

    let hash_prefix = stable_hash(&key);
    if !force {
        if let Some(f) = state.media.flights.get_mut(&key) {
            f.phase = MediaFlightPhase::CacheLookup {
                candidates,
                hash_prefix: hash_prefix.clone(),
            };
        }
        out.effects.push(Effect::MediaCacheLookup {
            flight_id,
            key,
            hash_prefix,
            conv_id,
            msg_id,
            kind,
        });
    } else {
        if let Some(f) = state.media.flights.get_mut(&key) {
            f.phase = MediaFlightPhase::CandidateLoop {
                candidates,
                hash_prefix,
                idx: 0,
                saw_permanent_gone: false,
                saw_transient_error: false,
            };
        }
        step_media_candidate_loop(state, flight_id, out);
    }
}

fn on_cache_lookup_done(
    state: &mut CoreState,
    flight_id: u64,
    hit: Option<crate::media::MediaCacheHit>,
    out: &mut ReduceOutput,
) {
    let Some(key) = state.media.flight_id_to_key.get(&flight_id).cloned() else {
        return;
    };
    let Some(kind) = state.media.flights.get(&key).map(|f| f.kind) else {
        return;
    };

    if let Some(hit) = hit {
        if kind == MediaKind::VideoThumb && hit.is_video {
            out.effects.push(Effect::MediaVideoPoster {
                flight_id,
                path: hit.path,
                from_cache: true,
            });
        } else {
            finish_media_flight(state, flight_id, MediaResolution::File(hit.path), out);
        }
        return;
    }

    if let Some(f) = state.media.flights.get_mut(&key) {
        let prev = std::mem::replace(&mut f.phase, MediaFlightPhase::Queued);
        if let MediaFlightPhase::CacheLookup {
            candidates,
            hash_prefix,
        } = prev
        {
            f.phase = MediaFlightPhase::CandidateLoop {
                candidates,
                hash_prefix,
                idx: 0,
                saw_permanent_gone: false,
                saw_transient_error: false,
            };
        }
    }
    step_media_candidate_loop(state, flight_id, out);
}

fn step_media_candidate_loop(state: &mut CoreState, flight_id: u64, out: &mut ReduceOutput) {
    let Some(key) = state.media.flight_id_to_key.get(&flight_id).cloned() else {
        return;
    };
    let Some(flight) = state.media.flights.get_mut(&key) else {
        return;
    };
    let kind = flight.kind;
    let force = flight.force;

    let MediaFlightPhase::CandidateLoop {
        candidates,
        hash_prefix,
        idx,
        saw_permanent_gone,
        saw_transient_error,
    } = &mut flight.phase
    else {
        return;
    };

    while *idx < candidates.len() {
        let url = candidates[*idx].clone();
        *idx += 1;
        match classify_candidate_scheme(&url) {
            CandidateScheme::File => {
                out.effects
                    .push(Effect::MediaCheckLocalFile { flight_id, url });
                return;
            }
            CandidateScheme::Http => {
                out.effects.push(Effect::MediaLoaderFetchMedia {
                    flight_id,
                    url,
                    kind,
                    hash_prefix: hash_prefix.clone(),
                    force,
                });
                return;
            }
            CandidateScheme::Other => {}
        }
    }

    let final_res = if *saw_permanent_gone && !*saw_transient_error {
        MediaResolution::Expired
    } else {
        MediaResolution::Unavailable
    };
    finish_media_flight(state, flight_id, final_res, out);
}

fn on_local_file_checked(
    state: &mut CoreState,
    flight_id: u64,
    allowed: bool,
    path: String,
    is_video: bool,
    out: &mut ReduceOutput,
) {
    let Some(key) = state.media.flight_id_to_key.get(&flight_id).cloned() else {
        return;
    };
    let Some(kind) = state.media.flights.get(&key).map(|f| f.kind) else {
        return;
    };

    if allowed {
        if kind == MediaKind::VideoThumb && is_video {
            out.effects.push(Effect::MediaVideoPoster {
                flight_id,
                path,
                from_cache: false,
            });
            return;
        }
        finish_media_flight(state, flight_id, MediaResolution::File(path), out);
        return;
    }

    step_media_candidate_loop(state, flight_id, out);
}

fn on_loader_fetch_media_done(
    state: &mut CoreState,
    flight_id: u64,
    outcome: MediaFetchOutcome,
    out: &mut ReduceOutput,
) {
    let Some(key) = state.media.flight_id_to_key.get(&flight_id).cloned() else {
        return;
    };
    let Some(kind) = state.media.flights.get(&key).map(|f| f.kind) else {
        return;
    };

    match outcome {
        MediaFetchOutcome::Cached { path, is_video } => {
            if kind == MediaKind::VideoThumb && is_video {
                out.effects.push(Effect::MediaVideoPoster {
                    flight_id,
                    path,
                    from_cache: false,
                });
            } else {
                finish_media_flight(state, flight_id, MediaResolution::File(path), out);
            }
        }
        MediaFetchOutcome::PermanentGone => {
            if let Some(f) = state.media.flights.get_mut(&key)
                && let MediaFlightPhase::CandidateLoop {
                    saw_permanent_gone, ..
                } = &mut f.phase
            {
                *saw_permanent_gone = true;
            }
            step_media_candidate_loop(state, flight_id, out);
        }
        MediaFetchOutcome::Transient => {
            if let Some(f) = state.media.flights.get_mut(&key)
                && let MediaFlightPhase::CandidateLoop {
                    saw_transient_error,
                    ..
                } = &mut f.phase
            {
                *saw_transient_error = true;
            }
            step_media_candidate_loop(state, flight_id, out);
        }
    }
}

fn on_video_poster_done(
    state: &mut CoreState,
    flight_id: u64,
    poster_path: Option<String>,
    from_cache: bool,
    out: &mut ReduceOutput,
) {
    if let Some(path) = poster_path {
        finish_media_flight(state, flight_id, MediaResolution::File(path), out);
    } else if from_cache {
        finish_media_flight(state, flight_id, MediaResolution::Unavailable, out);
    } else {
        // Matches Swift ZaloEngine+Media.swift lines 430 & 516: continues without setting sawTransientError.
        step_media_candidate_loop(state, flight_id, out);
    }
}

fn finish_media_flight(
    state: &mut CoreState,
    flight_id: u64,
    resolution: MediaResolution,
    out: &mut ReduceOutput,
) {
    let Some(key) = state.media.flight_id_to_key.remove(&flight_id) else {
        return;
    };
    let Some(flight) = state.media.flights.remove(&key) else {
        return;
    };

    let until_ms = match resolution {
        MediaResolution::Unavailable => flight.now_ms.saturating_add(MEDIA_UNAVAILABLE_TTL_MS),
        MediaResolution::File(_) | MediaResolution::Expired | MediaResolution::Unsupported => {
            i64::MAX
        }
    };
    state.media.settled.insert(
        key,
        SettledMedia {
            resolution: resolution.clone(),
            until_ms,
        },
    );
    if state.media.settled.len() > MEDIA_SETTLED_PRUNE_THRESHOLD {
        let now_ms = flight.now_ms;
        state.media.settled.retain(|_, v| v.until_ms > now_ms);
    }

    for waiter in flight.waiters {
        complete_op(
            Some(waiter),
            OpResult::MediaResolution(resolution.clone()),
            false,
            out,
        );
    }

    // Release concurrency slot — LIFO (newest waiter served first).
    while let Some(next_key) = state.media.queue.pop() {
        if state.media.flights.contains_key(&next_key) {
            start_media_flight(state, &next_key, out);
            return;
        }
    }
    state.media.running = state.media.running.saturating_sub(1);
}

// MARK: - resolve_file

#[expect(
    clippy::too_many_arguments,
    reason = "Matches Command::ResolveFile parameters"
)]
fn handle_resolve_file(
    state: &mut CoreState,
    op_id: u64,
    conv_id: String,
    msg_id: String,
    name: String,
    url: Option<String>,
    force: bool,
    request_token: u64,
    out: &mut ReduceOutput,
) {
    let has_url = url.as_deref().is_some_and(|u| !u.is_empty());
    if !has_url && (!conv_id.is_empty() || !msg_id.is_empty()) {
        if !conv_id.is_empty()
            && let Some(hit) = state
                .messages
                .windows
                .get(&conv_id)
                .and_then(|list| list.iter().find(|m| m.id == msg_id))
                .cloned()
        {
            resolve_file_with_message(
                state,
                op_id,
                conv_id,
                msg_id,
                name,
                force,
                request_token,
                Some(hit),
                out,
            );
            return;
        }
        if !conv_id.is_empty() {
            state.media.pending_resolve_files.insert(
                op_id,
                PendingResolveFile {
                    op_id,
                    conv_id: conv_id.clone(),
                    msg_id: msg_id.clone(),
                    name,
                    force,
                    request_token,
                    cached_path: None,
                },
            );
            out.effects.push(Effect::MediaLookupFileMessageInStore {
                op_id,
                conv_id,
                msg_id,
            });
            return;
        }
        let fallback = find_message_across_all_windows(state, &msg_id);
        resolve_file_with_message(
            state,
            op_id,
            conv_id,
            msg_id,
            name,
            force,
            request_token,
            fallback,
            out,
        );
        return;
    }

    start_resolve_file_fetch(
        state,
        op_id,
        conv_id,
        msg_id,
        name,
        url,
        force,
        request_token,
        out,
    );
}

fn on_file_message_loaded(
    state: &mut CoreState,
    op_id: u64,
    message: Option<ChatMessage>,
    out: &mut ReduceOutput,
) {
    let Some(pending) = state.media.pending_resolve_files.remove(&op_id) else {
        return;
    };
    let resolved = message.or_else(|| find_message_across_all_windows(state, &pending.msg_id));
    resolve_file_with_message(
        state,
        op_id,
        pending.conv_id,
        pending.msg_id,
        pending.name,
        pending.force,
        pending.request_token,
        resolved,
        out,
    );
}

#[expect(
    clippy::too_many_arguments,
    reason = "Carries resolve_file fields across lookup"
)]
fn resolve_file_with_message(
    state: &mut CoreState,
    op_id: u64,
    conv_id: String,
    msg_id: String,
    mut name: String,
    force: bool,
    request_token: u64,
    message: Option<ChatMessage>,
    out: &mut ReduceOutput,
) {
    let mut resolved_url: Option<String> = None;
    if let Some(msg) = message
        && let Kind::File {
            name: db_name,
            url: db_url,
            ..
        } = msg.kind
    {
        resolved_url = db_url;
        if name.is_empty() {
            name = db_name;
        }
    }
    start_resolve_file_fetch(
        state,
        op_id,
        conv_id,
        msg_id,
        name,
        resolved_url,
        force,
        request_token,
        out,
    );
}

#[expect(clippy::too_many_arguments, reason = "Starts loader_fetch_file effect")]
fn start_resolve_file_fetch(
    state: &mut CoreState,
    op_id: u64,
    conv_id: String,
    msg_id: String,
    name: String,
    url: Option<String>,
    force: bool,
    request_token: u64,
    out: &mut ReduceOutput,
) {
    let Some(remote_url) = url.filter(|u| !u.is_empty()) else {
        complete_op(
            Some(op_id),
            OpResult::FileResolution(FileResolution::Failed(
                "Tin nhắn không có đường dẫn tải tệp.".to_owned(),
            )),
            false,
            out,
        );
        return;
    };

    state.media.pending_resolve_files.insert(
        op_id,
        PendingResolveFile {
            op_id,
            conv_id,
            msg_id,
            name,
            force,
            request_token,
            cached_path: None,
        },
    );
    out.effects.push(Effect::MediaLoaderFetchFile {
        op_id,
        url: remote_url,
        force,
        request_token,
    });
}

fn on_loader_fetch_file_done(
    state: &mut CoreState,
    op_id: u64,
    outcome: FileFetchOutcome,
    out: &mut ReduceOutput,
) {
    let Some(pending) = state.media.pending_resolve_files.get_mut(&op_id) else {
        return;
    };

    match outcome {
        FileFetchOutcome::Error(err) => {
            state.media.pending_resolve_files.remove(&op_id);
            let res = if err.is_permanent_gone() {
                FileResolution::Expired
            } else {
                FileResolution::Failed(err.user_message())
            };
            complete_op(Some(op_id), OpResult::FileResolution(res), false, out);
        }
        FileFetchOutcome::Fetched {
            cached_path,
            container_ext,
        } => {
            let safe_full = sanitized_file_name(&pending.name, container_ext.as_deref());
            let (clean_stem, clean_ext) = split_sanitized_stem_ext(&safe_full);
            pending.cached_path = Some(cached_path.clone());
            out.effects.push(Effect::MediaStageFile {
                op_id,
                source_path: cached_path,
                stem: clean_stem,
                ext: clean_ext,
            });
        }
    }
}

fn on_file_staged(
    state: &mut CoreState,
    op_id: u64,
    staged_path: Option<String>,
    out: &mut ReduceOutput,
) {
    let Some(pending) = state.media.pending_resolve_files.remove(&op_id) else {
        return;
    };
    let final_path = staged_path.or(pending.cached_path).unwrap_or_default();
    complete_op(
        Some(op_id),
        OpResult::FileResolution(FileResolution::Ready(final_path)),
        false,
        out,
    );
}

// MARK: - shared_media

fn on_shared_media_loaded(
    state: &CoreState,
    op_id: u64,
    conv_id: &str,
    kind: SharedMediaKind,
    limit: usize,
    outcome: SharedMediaLoadOutcome,
    out: &mut ReduceOutput,
) {
    let result = match outcome {
        SharedMediaLoadOutcome::StoreOk(page) => Some(page),
        SharedMediaLoadOutcome::StoreError => None,
        SharedMediaLoadOutcome::NoStore => {
            let mem = state
                .messages
                .windows
                .get(conv_id)
                .map_or(&[][..], Vec::as_slice);
            Some(shared_media_memory(mem, kind, limit))
        }
    };
    complete_op(Some(op_id), OpResult::SharedMedia(result), false, out);
}

fn complete_op(op_id: Option<u64>, result: OpResult, after_store: bool, out: &mut ReduceOutput) {
    if let Some(op_id) = op_id {
        out.effects.push(Effect::CompleteOp {
            op_id,
            result,
            after_store,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::reduce::reduce;

    fn seed_photo(state: &mut CoreState, conv_id: &str, msg_id: &str, url: &str) {
        state
            .messages
            .windows
            .entry(conv_id.to_owned())
            .or_default()
            .push(ChatMessage {
                id: msg_id.to_owned(),
                conversation_id: conv_id.to_owned(),
                sender_id: String::new(),
                sender_name: String::new(),
                sender_avatar: None,
                is_mine: false,
                kind: Kind::Photo {
                    url: Some(url.to_owned()),
                    width: 10,
                    height: 10,
                },
                text: String::new(),
                date_ms: 0,
                status: Status::Sent,
                quote: None,
                reactions: Vec::new(),
                is_e2ee: false,
                mentions: Vec::new(),
                card_buttons: Vec::new(),
                suggests_stickers: false,
                menu: MessageMenu::default(),
                fallback_urls: Vec::new(),
                client_id: String::new(),
                text_styles: Vec::new(),
                ttl_ms: 0,
                urgency: 0,
            });
    }

    #[test]
    fn media_resolver_throttles_lifo_dedupes_and_caches_unavailable_ttl() {
        let mut state = CoreState::default();
        state.media.max_concurrent = 2;
        for i in 1..=4 {
            seed_photo(
                &mut state,
                "c1",
                &format!("m{i}"),
                &format!("https://cdn.example/{i}.png"),
            );
        }

        // Launch m1, m2 (both start), then m3, m4 (queued LIFO).
        let out1 = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 1,
                cmd: Command::ResolveMedia {
                    conv_id: "c1".into(),
                    msg_id: "m1".into(),
                    kind: MediaKind::Photo,
                    force: false,
                    now_ms: 1000,
                },
            },
        );
        assert!(matches!(
            out1.effects.as_slice(),
            [Effect::MediaCacheLookup { flight_id: 1, .. }]
        ));

        // Duplicate waiter on m1 attaches to existing flight without emitting a second effect.
        let out1_dup = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 10,
                cmd: Command::ResolveMedia {
                    conv_id: "c1".into(),
                    msg_id: "m1".into(),
                    kind: MediaKind::Photo,
                    force: false,
                    now_ms: 1000,
                },
            },
        );
        assert!(out1_dup.effects.is_empty());

        let out2 = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 2,
                cmd: Command::ResolveMedia {
                    conv_id: "c1".into(),
                    msg_id: "m2".into(),
                    kind: MediaKind::Photo,
                    force: false,
                    now_ms: 1000,
                },
            },
        );
        assert!(matches!(
            out2.effects.as_slice(),
            [Effect::MediaCacheLookup { flight_id: 2, .. }]
        ));

        let out3 = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 3,
                cmd: Command::ResolveMedia {
                    conv_id: "c1".into(),
                    msg_id: "m3".into(),
                    kind: MediaKind::Photo,
                    force: false,
                    now_ms: 1000,
                },
            },
        );
        assert!(out3.effects.is_empty());

        let out4 = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 4,
                cmd: Command::ResolveMedia {
                    conv_id: "c1".into(),
                    msg_id: "m4".into(),
                    kind: MediaKind::Photo,
                    force: false,
                    now_ms: 1000,
                },
            },
        );
        assert!(out4.effects.is_empty());
        assert_eq!(state.media.queued_count(), 2);

        // Cancel m3 while queued -> drops without starting.
        let out_cancel = reduce(
            &mut state,
            Input::Command(Command::CancelMediaResolve { op_id: 3 }),
        );
        assert!(matches!(
            out_cancel.effects.as_slice(),
            [Effect::CompleteOp {
                op_id: 3,
                result: OpResult::MediaResolution(MediaResolution::Unavailable),
                ..
            }]
        ));
        assert_eq!(state.media.queued_count(), 1);

        // Complete flight 1 with cache hit -> completes BOTH op 1 and op 10, AND starts m4 (LIFO).
        let out_done = reduce(
            &mut state,
            Input::MediaCacheLookupDone {
                flight_id: 1,
                hit: Some(crate::media::MediaCacheHit {
                    path: "/cache/1.png".into(),
                    is_video: false,
                }),
            },
        );
        assert_eq!(out_done.effects.len(), 3);
        assert!(matches!(
            out_done.effects[0],
            Effect::CompleteOp {
                op_id: 1,
                result: OpResult::MediaResolution(MediaResolution::File(_)),
                ..
            }
        ));
        assert!(matches!(
            out_done.effects[1],
            Effect::CompleteOp {
                op_id: 10,
                result: OpResult::MediaResolution(MediaResolution::File(_)),
                ..
            }
        ));
        assert!(matches!(
            out_done.effects[2],
            Effect::MediaCacheLookup {
                flight_id: 4,
                ref msg_id,
                ..
            } if msg_id == "m4"
        ));

        // Flight 2 fails transiently -> settles Unavailable for 30s.
        let _ = reduce(
            &mut state,
            Input::MediaCacheLookupDone {
                flight_id: 2,
                hit: None,
            },
        );
        let _ = reduce(
            &mut state,
            Input::MediaLoaderFetchMediaDone {
                flight_id: 2,
                outcome: MediaFetchOutcome::Transient,
            },
        );
        assert_eq!(
            state.media.known("c1|m2|photo"),
            Some(&MediaResolution::Unavailable)
        );

        // Re-request within 30s without force -> returns cached Unavailable immediately.
        let out_ttl = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 20,
                cmd: Command::ResolveMedia {
                    conv_id: "c1".into(),
                    msg_id: "m2".into(),
                    kind: MediaKind::Photo,
                    force: false,
                    now_ms: 20_000,
                },
            },
        );
        assert!(matches!(
            out_ttl.effects.as_slice(),
            [Effect::CompleteOp {
                op_id: 20,
                result: OpResult::MediaResolution(MediaResolution::Unavailable),
                ..
            }]
        ));

        // Re-request after 30s -> starts fresh flight.
        let out_expired_ttl = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 21,
                cmd: Command::ResolveMedia {
                    conv_id: "c1".into(),
                    msg_id: "m2".into(),
                    kind: MediaKind::Photo,
                    force: false,
                    now_ms: 35_000,
                },
            },
        );
        assert!(matches!(
            out_expired_ttl.effects.as_slice(),
            [Effect::MediaCacheLookup { .. }]
        ));
    }
}

//! Pure launch-bootstrap domain reducer (U4): steps 1–8 of `ZaloEngine.performBootstrapSync`.
//!
//! No I/O, no clock, and no randomness live here (D9). Wall-clock milliseconds enter solely via
//! [`Command::Bootstrap { now_ms }`].

use std::collections::{BTreeMap, HashMap, HashSet};

use olaz_wire::{group_conv_id, is_group_id, strip_user_prefix};
use serde_json::{Map, Value};

use crate::changes::DirtyKey;
use crate::conversations::{parse_server_labels_response, serialize_labels_local_json};
use crate::effect::{Effect, HostCall, OpResult, StoreOp};
use crate::input::{BootstrapAliasesError, Command, Input};
use crate::messages::{
    BootstrapFlowState, FULL_HISTORY_REFRESH_PREF_KEY, MuteEntry, apply_batch_pass1,
    apply_fetched_contacts, newest_message_ids, parse_batch_events,
};
use crate::reduce::{ReduceOutput, conversations, session, transport};
use crate::state::CoreState;

/// Expiry notice emitted when `/api/alias/list` fails with an auth error during launch bootstrap.
pub const ALIASES_AUTH_EXPIRED_REASON: &str =
    "Phiên đăng nhập không hợp lệ hoặc đã hết hạn. Vui lòng quét mã QR để đăng nhập lại.";

const PRELOAD_PEERS_LIMIT: usize = 50;
const PRELOAD_GROUPS_LIMIT: usize = 50;
const PRELOAD_CHUNK_SIZE: usize = 25;
const SELF_CLOUD_HISTORY_COUNT: i64 = 50;
const GROUP_HISTORY_LIMIT: usize = 24;
const GROUP_HISTORY_WAVE_SIZE: usize = 6;
const GROUP_HISTORY_COUNT: i64 = 30;
const BOOTSTRAP_LP_MAX_BATCHES: u32 = 4;
const RESOLVE_NAMES_CHUNK_SIZE: usize = 50;

/// Internal step machine stage for an active launch bootstrap run.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum BootstrapStage {
    #[default]
    Idle,
    Aliases,
    FreshnessPref,
    PinsArchivedMutes,
    Labels,
    Hidden,
    Contacts,
    PreloadOverview,
    PreloadOverviewProbe,
    PreloadChunk,
    PreloadChunkProbe,
    SelfCloud,
    GroupWaves,
    ResolveNames,
    AwaitingDrain,
}

/// Internal reducer bookkeeping for the active bootstrap run (kept outside `CoreSnapshot`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct BootstrapRuntimeState {
    pub stage: BootstrapStage,
    pub lp_drain_id: Option<u64>,
}

/// Cancels any active bootstrap flow in state (used on logout, session expiry, or restart).
///
/// Bumps `state.messages.boot_gen` so in-flight responses are ignored, and resolves any awaiting
/// `op_id` immediately so callers never hang.
pub(crate) fn cancel_bootstrap_state(state: &mut CoreState, out: &mut ReduceOutput) {
    state.messages.boot_gen = state.messages.boot_gen.saturating_add(1);
    state.bootstrap.stage = BootstrapStage::Idle;
    state.bootstrap.lp_drain_id = None;
    if let Some(prev) = state.messages.active_bootstrap.take()
        && let Some(op_id) = prev.op_id
    {
        out.effects.push(Effect::CompleteOp {
            op_id,
            result: OpResult::Unit,
            after_store: false,
        });
    }
}

/// Called by the transport reducer when a long-poll drain finishes (either normally or on stop).
pub(crate) fn on_lp_drain_done(state: &mut CoreState, drain_id: u64, out: &mut ReduceOutput) {
    if state.bootstrap.lp_drain_id != Some(drain_id) {
        return;
    }
    state.bootstrap.lp_drain_id = None;
    if let Some(flow) = state.messages.active_bootstrap.as_mut() {
        flow.lp_drain_done = true;
        try_complete_finalize(state, out);
    }
}

/// Reduces a U4 bootstrap [`Input`].
pub(crate) fn reduce_bootstrap(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::Command(Command::Bootstrap { now_ms }) => {
            start_bootstrap(state, now_ms, None, out);
        }
        Input::OpRequest {
            op_id,
            cmd: Command::Bootstrap { now_ms },
        } => {
            start_bootstrap(state, now_ms, Some(op_id), out);
        }

        Input::BootstrapAliasesDone { boot_gen, result } => {
            if !matches_stage(state, boot_gen, BootstrapStage::Aliases) {
                return;
            }
            match result {
                Err(BootstrapAliasesError::Auth) => {
                    cancel_bootstrap_state(state, out);
                    session::enter_session_expired(
                        state,
                        ALIASES_AUTH_EXPIRED_REASON.to_owned(),
                        out,
                    );
                    return;
                }
                Ok(aliases) => {
                    if !aliases.is_empty() {
                        for (k, v) in aliases {
                            state.conversations.identities.aliases.insert(k, v);
                        }
                        if let Ok(bytes) =
                            serde_json::to_vec(&state.conversations.identities.aliases)
                        {
                            out.effects.push(Effect::Store(StoreOp::SetPreferenceData {
                                key: "aliases".to_owned(),
                                data: bytes,
                            }));
                        }
                    }
                }
                Err(BootstrapAliasesError::Other) => {}
            }
            state.bootstrap.stage = BootstrapStage::FreshnessPref;
            out.effects
                .push(Effect::Store(StoreOp::LoadPreferenceString {
                    key: FULL_HISTORY_REFRESH_PREF_KEY.to_owned(),
                    boot_gen,
                }));
        }

        Input::BootstrapFreshnessLoaded {
            boot_gen,
            last_refresh_pref,
        } => {
            if !matches_stage(state, boot_gen, BootstrapStage::FreshnessPref) {
                return;
            }
            let Some(now_ms) = state.messages.active_bootstrap.as_ref().map(|f| f.now_ms) else {
                return;
            };
            let full_refresh = state
                .messages
                .begin_freshness_pass(last_refresh_pref.as_deref(), now_ms);
            if let Some(flow) = state.messages.active_bootstrap.as_mut() {
                flow.full_refresh = full_refresh;
            }

            // Launch concurrent long-poll drain (max 4 batches, notify_incoming = false).
            let drain_id = state.transport.alloc_drain_id();
            state.bootstrap.lp_drain_id = Some(drain_id);
            transport::start_bootstrap_drain(state, drain_id, BOOTSTRAP_LP_MAX_BATCHES, false, out);

            state.bootstrap.stage = BootstrapStage::PinsArchivedMutes;
            out.effects.push(Effect::BootstrapFetchPamApi { boot_gen });
        }

        Input::BootstrapPamDone {
            boot_gen,
            pinned_ids,
            archived_ids,
            mute_rows,
        } => {
            if !matches_stage(state, boot_gen, BootstrapStage::PinsArchivedMutes) {
                return;
            }
            let now_ms = match state.messages.active_bootstrap.as_mut() {
                Some(flow) => {
                    flow.pam_done = true;
                    flow.now_ms
                }
                None => return,
            };

            if pinned_ids.is_some() || archived_ids.is_some() {
                if let Some(pins) = pinned_ids {
                    state.conversations.pinned_ids = pins.into_iter().collect();
                    out.effects
                        .push(Effect::Store(StoreOp::SetPreferenceStrings {
                            key: "pinnedIds".to_owned(),
                            values: conversations::sorted_set_vec(&state.conversations.pinned_ids),
                        }));
                }
                if let Some(archived) = archived_ids {
                    state.conversations.archived_ids = archived.into_iter().collect();
                    out.effects
                        .push(Effect::Store(StoreOp::SetPreferenceStrings {
                            key: "archivedIds".to_owned(),
                            values: conversations::sorted_set_vec(
                                &state.conversations.archived_ids,
                            ),
                        }));
                }
                conversations::rebuild_flags_and_extras(state, out);
            }

            if let Some(rows) = mute_rows {
                let mutes = parse_mute_entries(&rows, now_ms);
                out.effects
                    .push(Effect::Host(HostCall::ApplyMutes { mutes }));
            }

            state.bootstrap.stage = BootstrapStage::Labels;
            out.effects
                .push(Effect::BootstrapFetchLabelsApi { boot_gen });
        }

        Input::BootstrapLabelsDone { boot_gen, payload } => {
            if !matches_stage(state, boot_gen, BootstrapStage::Labels) {
                return;
            }
            if let Some(flow) = state.messages.active_bootstrap.as_mut() {
                flow.labels_done = true;
            }
            if let Some(data) = payload {
                let parsed = parse_server_labels_response(&data);
                if !parsed.is_empty() {
                    let local_bytes = serialize_labels_local_json(&parsed);
                    state.conversations.set_labels_in_memory(parsed);
                    let self_conv_id = state.session.self_conversation_id.clone();
                    state
                        .conversations
                        .rebuild_conversation_extras(self_conv_id.as_deref());
                    out.dirty.insert(DirtyKey::ConversationExtras);
                    out.effects.push(Effect::Store(StoreOp::SetPreferenceData {
                        key: "labels".to_owned(),
                        data: local_bytes,
                    }));
                }
            }
            state.bootstrap.stage = BootstrapStage::Hidden;
            out.effects
                .push(Effect::BootstrapFetchHiddenApi { boot_gen });
        }

        Input::BootstrapHiddenDone { boot_gen, snapshot } => {
            if !matches_stage(state, boot_gen, BootstrapStage::Hidden) {
                return;
            }
            if let Some(flow) = state.messages.active_bootstrap.as_mut() {
                flow.hidden_done = true;
            }
            if let Some(snap) = snapshot {
                conversations::apply_server_hidden(state, &snap.pin, &snap.thread_ids, None, out);
            }
            state.bootstrap.stage = BootstrapStage::Contacts;
            out.effects
                .push(Effect::BootstrapFetchContactsApi { boot_gen });
        }

        Input::BootstrapContactsDone {
            boot_gen,
            friends_rows,
            groups_dict,
            sent_rows,
            received_rows,
        } => {
            if !matches_stage(state, boot_gen, BootstrapStage::Contacts) {
                return;
            }
            if let Some(flow) = state.messages.active_bootstrap.as_mut() {
                flow.contacts_done = true;
            }
            apply_fetched_contacts(
                &mut state.contacts,
                &mut state.conversations.identities,
                friends_rows,
                groups_dict,
                sent_rows,
                received_rows,
            );
            // U4-merge: Carbon inserts `out.dirty.insert(DirtyKey::Contacts)` once `changes.rs` lands.
            ensure_known_contacts_and_rebuild(state, out);

            state.bootstrap.stage = BootstrapStage::PreloadOverview;
            out.effects.push(Effect::BootstrapFetchPreloadApi {
                boot_gen,
                thread_ids: Vec::new(),
                is_overview: true,
            });
        }

        Input::BootstrapPreloadDone {
            boot_gen,
            is_overview: true,
            payload,
        } => {
            if !matches_stage(state, boot_gen, BootstrapStage::PreloadOverview) {
                return;
            }
            let Some(full_refresh) = state
                .messages
                .active_bootstrap
                .as_ref()
                .map(|f| f.full_refresh)
            else {
                return;
            };
            let mut awaiting_probe = false;
            if let Some(root_map) = payload {
                let mut group_rank_updates = HashMap::new();
                apply_preload_clear_unreads(&root_map, state, &mut group_rank_updates, out);
                if let Some(flow) = state.messages.active_bootstrap.as_mut() {
                    for (k, v) in group_rank_updates {
                        let entry = flow.group_activity_rank.entry(k).or_insert(0);
                        if v > *entry {
                            *entry = v;
                        }
                    }
                }
                let root_val = Value::Object(root_map);
                awaiting_probe = ingest_bootstrap_batch(
                    state,
                    &root_val,
                    None,
                    None,
                    !full_refresh,
                    boot_gen,
                    out,
                );
            }
            if awaiting_probe {
                state.bootstrap.stage = BootstrapStage::PreloadOverviewProbe;
            } else {
                finish_preload_overview(state, out);
            }
        }

        Input::BootstrapPreloadDone {
            boot_gen,
            is_overview: false,
            payload,
        } => {
            if !matches_stage(state, boot_gen, BootstrapStage::PreloadChunk) {
                return;
            }
            let full_refresh = match state.messages.active_bootstrap.as_mut() {
                Some(flow) => {
                    flow.preload_chunk_idx = flow.preload_chunk_idx.saturating_add(1);
                    flow.full_refresh
                }
                None => return,
            };
            let mut awaiting_probe = false;
            if let Some(root_map) = payload {
                let root_val = Value::Object(root_map);
                awaiting_probe = ingest_bootstrap_batch(
                    state,
                    &root_val,
                    None,
                    None,
                    !full_refresh,
                    boot_gen,
                    out,
                );
            }
            if awaiting_probe {
                state.bootstrap.stage = BootstrapStage::PreloadChunkProbe;
            } else {
                advance_preload_chunks(state, out);
            }
        }

        Input::FreshnessProbed { boot_gen, probes } => {
            // If `boot_gen` is tagged, ignore stale bootstrap probes from superseded runs.
            if let Some(bg) = boot_gen
                && state
                    .messages
                    .active_bootstrap
                    .as_ref()
                    .is_none_or(|f| f.boot_gen != bg)
            {
                return;
            }
            let _ = state.messages.record_freshness_probes(&probes);
            if let Some(bg) = boot_gen {
                if matches_stage(state, bg, BootstrapStage::PreloadOverviewProbe) {
                    finish_preload_overview(state, out);
                } else if matches_stage(state, bg, BootstrapStage::PreloadChunkProbe) {
                    advance_preload_chunks(state, out);
                }
            }
        }

        Input::BootstrapSelfCloudDone {
            boot_gen,
            conv_id,
            payload,
        } => {
            if !matches_stage(state, boot_gen, BootstrapStage::SelfCloud) {
                return;
            }
            if let Some(root_map) = payload {
                let root_val = Value::Object(root_map);
                let _ = ingest_bootstrap_batch(
                    state,
                    &root_val,
                    Some(&conv_id),
                    Some(false),
                    false,
                    boot_gen,
                    out,
                );
            }
            start_group_waves(state, out);
        }

        Input::BootstrapGroupWaveDone { boot_gen, results } => {
            if !matches_stage(state, boot_gen, BootstrapStage::GroupWaves) {
                return;
            }
            if let Some(flow) = state.messages.active_bootstrap.as_mut() {
                flow.group_wave_idx = flow.group_wave_idx.saturating_add(1);
            } else {
                return;
            }
            // Results arrive in exact `gids` slice order from the runner.
            for (gid, payload) in results {
                if let Some(root_map) = payload {
                    let root_val = Value::Object(root_map);
                    let _ = ingest_bootstrap_batch(
                        state,
                        &root_val,
                        Some(&gid),
                        Some(true),
                        false,
                        boot_gen,
                        out,
                    );
                }
            }
            advance_group_waves(state, out);
        }

        Input::BootstrapResolveNamesChunkDone {
            boot_gen,
            mut remaining_chunks,
            profiles_map,
            mut profiles_cache_changed,
        } => {
            if !matches_stage(state, boot_gen, BootstrapStage::ResolveNames) {
                return;
            }
            let (cache_changed, convs_changed) =
                state.conversations.apply_resolved_profiles(&profiles_map);
            profiles_cache_changed |= cache_changed;
            if convs_changed {
                out.dirty.insert(DirtyKey::Conversations);
            }
            if !remaining_chunks.is_empty() {
                let next_chunk = remaining_chunks.remove(0);
                out.effects.push(Effect::BootstrapFetchProfilesChunkApi {
                    boot_gen,
                    chunk: next_chunk,
                    remaining_chunks,
                    profiles_cache_changed,
                });
            } else {
                if profiles_cache_changed
                    && let Ok(bytes) =
                        serde_json::to_vec(&state.conversations.identities.cached_profiles)
                {
                    out.effects.push(Effect::Store(StoreOp::SetPreferenceData {
                        key: "cachedProfiles".to_owned(),
                        data: bytes,
                    }));
                }
                after_resolve_names(state, out);
            }
        }

        _ => {}
    }
}

fn start_bootstrap(state: &mut CoreState, now_ms: i64, op_id: Option<u64>, out: &mut ReduceOutput) {
    cancel_bootstrap_state(state, out);
    let boot_gen = state.messages.boot_gen;
    out.effects.push(Effect::CancelBootstrapTasks);

    state.messages.active_bootstrap = Some(BootstrapFlowState {
        boot_gen,
        now_ms,
        op_id,
        full_refresh: false,
        lp_drain_done: false,
        group_waves_done: false,
        group_activity_rank: HashMap::new(),
        ordered_groups: Vec::new(),
        preload_chunks: Vec::new(),
        preload_chunk_idx: 0,
        group_wave_slices: Vec::new(),
        group_wave_idx: 0,
        pam_done: false,
        labels_done: false,
        hidden_done: false,
        contacts_done: false,
    });
    state.bootstrap = BootstrapRuntimeState {
        stage: BootstrapStage::Aliases,
        lp_drain_id: None,
    };

    out.effects
        .push(Effect::BootstrapFetchAliasesApi { boot_gen });
}

fn matches_stage(state: &CoreState, boot_gen: u64, expected: BootstrapStage) -> bool {
    state.bootstrap.stage == expected
        && state
            .messages
            .active_bootstrap
            .as_ref()
            .is_some_and(|f| f.boot_gen == boot_gen)
}

/// Parses mute rows returned by `/api/social/profile/getmute` into [`MuteEntry`] records.
#[must_use]
pub fn parse_mute_entries(rows: &[Map<String, Value>], now_ms: i64) -> Vec<MuteEntry> {
    let default_start = now_ms / 1000;
    let mut out = Vec::with_capacity(rows.len());
    for entry in rows {
        let id_raw = olaz_wire::lossless::string(entry.get("id"));
        if id_raw.is_empty() {
            continue;
        }
        let type_val = olaz_wire::lossless::int64(entry.get("type")).unwrap_or(1);
        let conv_id = if type_val == 2 {
            group_conv_id(&id_raw)
        } else {
            strip_user_prefix(&id_raw)
        };
        if conv_id.is_empty() {
            continue;
        }
        let duration = olaz_wire::lossless::int64(entry.get("duration")).unwrap_or(-1);
        let start = olaz_wire::lossless::int64(entry.get("startTime")).unwrap_or(default_start);
        out.push(MuteEntry {
            conv_id,
            start,
            duration,
        });
    }
    out
}

/// Extracts `data.clearUnreads` activity ranks from the initial preload overview response,
/// merges them into `state.conversations.identities.activity_ranks` (keeping `max`), records
/// group ranks in `group_activity_rank`, and persists `"activityRanks"` if non-empty.
fn apply_preload_clear_unreads(
    root: &Map<String, Value>,
    state: &mut CoreState,
    group_activity_rank: &mut HashMap<String, i64>,
    out: &mut ReduceOutput,
) {
    let Some(clear_unreads) = root
        .get("data")
        .and_then(Value::as_object)
        .and_then(|d| d.get("clearUnreads"))
        .and_then(Value::as_array)
    else {
        return;
    };

    let known_group_ids: HashSet<&str> = state
        .contacts
        .groups
        .iter()
        .map(|g| g.id.as_str())
        .collect();
    let my_uid = state
        .session
        .profile
        .as_ref()
        .map_or("", |p| p.user_id.as_str());
    let self_g = format!(
        "g{}",
        state.session.self_conversation_id.as_deref().unwrap_or("")
    );

    for row_val in clear_unreads {
        let Some(row) = row_val.as_object() else {
            continue;
        };
        let raw_id = olaz_wire::lossless::string(
            row.get("idTo")
                .or_else(|| row.get("threadId"))
                .or_else(|| row.get("uid")),
        );
        let last_mid = olaz_wire::lossless::int64(row.get("lastMsgId")).unwrap_or(0);
        if raw_id.is_empty() || raw_id == "0" || last_mid <= 0 {
            continue;
        }
        let is_grp_flag = olaz_wire::lossless::int64(row.get("isGroup")) == Some(1)
            || row.get("isGroup").and_then(Value::as_bool) == Some(true);
        let g_candidate = group_conv_id(&raw_id);
        if is_grp_flag || known_group_ids.contains(g_candidate.as_str()) {
            if g_candidate.is_empty() || g_candidate == "g0" || g_candidate == self_g {
                continue;
            }
            let rank_entry = state
                .conversations
                .identities
                .activity_ranks
                .entry(g_candidate.clone())
                .or_insert(0);
            if last_mid > *rank_entry {
                *rank_entry = last_mid;
            }
            let grp_entry = group_activity_rank.entry(g_candidate).or_insert(0);
            if last_mid > *grp_entry {
                *grp_entry = last_mid;
            }
        } else {
            let peer_id = strip_user_prefix(&raw_id);
            if peer_id.is_empty() || peer_id == "0" || peer_id == my_uid {
                continue;
            }
            let rank_entry = state
                .conversations
                .identities
                .activity_ranks
                .entry(peer_id)
                .or_insert(0);
            if last_mid > *rank_entry {
                *rank_entry = last_mid;
            }
        }
    }

    if !state.conversations.identities.activity_ranks.is_empty()
        && let Ok(bytes) = serde_json::to_vec(&state.conversations.identities.activity_ranks)
    {
        out.effects.push(Effect::Store(StoreOp::SetPreferenceData {
            key: "activityRanks".to_owned(),
            data: bytes,
        }));
    }
}

/// Computes `ordered_groups` (pinned first, then `group_activity_rank` desc, then id asc) and
/// 25-ID preload chunks (`ordered_peers[..50] + ordered_groups[..50]`).
#[must_use]
pub fn compute_preload_order_and_chunks(
    state: &CoreState,
    group_activity_rank: &HashMap<String, i64>,
) -> (Vec<String>, Vec<Vec<String>>) {
    let mut ordered_groups: Vec<String> =
        state.contacts.groups.iter().map(|g| g.id.clone()).collect();
    ordered_groups.sort_by(|a, b| {
        let pin_a = state.conversations.pinned_ids.contains(a);
        let pin_b = state.conversations.pinned_ids.contains(b);
        pin_b
            .cmp(&pin_a)
            .then_with(|| {
                let rank_a = group_activity_rank.get(a).copied().unwrap_or(0);
                let rank_b = group_activity_rank.get(b).copied().unwrap_or(0);
                rank_b.cmp(&rank_a)
            })
            .then_with(|| a.cmp(b))
    });

    let mut peers: Vec<(&String, i64)> = state
        .conversations
        .identities
        .activity_ranks
        .iter()
        .filter(|(k, _)| !is_group_id(k))
        .map(|(k, &v)| (k, v))
        .collect();
    peers.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));

    let mut target_ids: Vec<String> =
        Vec::with_capacity(PRELOAD_PEERS_LIMIT + PRELOAD_GROUPS_LIMIT);
    target_ids.extend(
        peers
            .into_iter()
            .take(PRELOAD_PEERS_LIMIT)
            .map(|(k, _)| k.clone()),
    );
    target_ids.extend(ordered_groups.iter().take(PRELOAD_GROUPS_LIMIT).cloned());

    let chunks: Vec<Vec<String>> = target_ids
        .chunks(PRELOAD_CHUNK_SIZE)
        .map(<[String]>::to_vec)
        .collect();
    (ordered_groups, chunks)
}

/// Ingests a bootstrap preload or history batch directly through core `parse_batch_events` +
/// `apply_batch_pass1` + `StoreOp::ProbeAndSaveMessages` (no `HostCall::ApplyBatch`).
///
/// Returns `true` when `probe_freshness` produced non-empty `probe_targets` and the caller must
/// wait for [`Input::FreshnessProbed`] before advancing.
fn ingest_bootstrap_batch(
    state: &mut CoreState,
    root: &Value,
    fallback_conv_id: Option<&str>,
    is_group_hint: Option<bool>,
    probe_freshness: bool,
    boot_gen: u64,
    out: &mut ReduceOutput,
) -> bool {
    let snap = state.identity_snapshot();
    let my_uid = state
        .session
        .profile
        .as_ref()
        .map_or("", |p| p.user_id.as_str());
    let self_conv_id = state.session.self_conversation_id.clone();

    let events = parse_batch_events(
        root,
        my_uid,
        self_conv_id.as_deref(),
        0,
        fallback_conv_id,
        is_group_hint,
        &snap,
    );
    if events.is_empty() {
        return false;
    }

    let probe_targets: BTreeMap<String, String> = if probe_freshness {
        newest_message_ids(&events)
    } else {
        BTreeMap::new()
    };

    let outcome = apply_batch_pass1(
        &mut state.messages,
        &mut state.conversations,
        &events,
        false,
        self_conv_id.as_deref(),
        &snap,
    );
    if outcome.conversations_changed {
        out.dirty.insert(DirtyKey::Conversations);
    }
    if outcome.flags_changed {
        out.dirty.insert(DirtyKey::ConversationFlags);
    }
    if outcome.extras_changed {
        out.dirty.insert(DirtyKey::ConversationExtras);
    }
    // U4-merge: Carbon inserts `DirtyKey::Messages` when `outcome.windows_changed`.

    let awaiting_probe = !probe_targets.is_empty();
    if awaiting_probe || !outcome.stored_rows.is_empty() {
        out.effects
            .push(Effect::Store(StoreOp::ProbeAndSaveMessages {
                probe_targets,
                rows: outcome.stored_rows,
                preserve_existing_reactions: true,
                reply_boot_gen: awaiting_probe.then_some(boot_gen),
            }));
    }
    awaiting_probe
}

fn finish_preload_overview(state: &mut CoreState, out: &mut ReduceOutput) {
    let self_conv_id = state.session.self_conversation_id.clone();
    if state
        .conversations
        .ensure_known_contacts(self_conv_id.as_deref())
    {
        out.dirty.insert(DirtyKey::Conversations);
    }

    let group_rank_clone = match state.messages.active_bootstrap.as_ref() {
        Some(flow) => flow.group_activity_rank.clone(),
        None => return,
    };
    let (ordered_groups, chunks) = compute_preload_order_and_chunks(state, &group_rank_clone);
    if let Some(flow) = state.messages.active_bootstrap.as_mut() {
        flow.ordered_groups = ordered_groups;
        flow.preload_chunks = chunks;
        flow.preload_chunk_idx = 0;
    }
    advance_preload_chunks(state, out);
}

fn advance_preload_chunks(state: &mut CoreState, out: &mut ReduceOutput) {
    let next = state.messages.active_bootstrap.as_ref().and_then(|flow| {
        flow.preload_chunks
            .get(flow.preload_chunk_idx)
            .map(|chunk| (flow.boot_gen, chunk.clone()))
    });
    if let Some((boot_gen, thread_ids)) = next {
        state.bootstrap.stage = BootstrapStage::PreloadChunk;
        out.effects.push(Effect::BootstrapFetchPreloadApi {
            boot_gen,
            thread_ids,
            is_overview: false,
        });
    } else {
        start_self_cloud(state, out);
    }
}

fn start_self_cloud(state: &mut CoreState, out: &mut ReduceOutput) {
    let Some(boot_gen) = state.messages.active_bootstrap.as_ref().map(|f| f.boot_gen) else {
        return;
    };
    let self_id = state
        .session
        .self_conversation_id
        .as_deref()
        .filter(|s| !s.is_empty())
        .map(str::to_owned);
    if let Some(conv_id) = self_id
        && !state.messages.is_recent_history_up_to_date(&conv_id)
    {
        state.bootstrap.stage = BootstrapStage::SelfCloud;
        out.effects.push(Effect::BootstrapFetchHistoryApi {
            boot_gen,
            conv_id,
            count: SELF_CLOUD_HISTORY_COUNT,
        });
    } else {
        start_group_waves(state, out);
    }
}

fn start_group_waves(state: &mut CoreState, out: &mut ReduceOutput) {
    let (full_refresh, initial_group_ids) = match state.messages.active_bootstrap.as_ref() {
        Some(flow) => {
            // Take top 24 groups FIRST, then skip those already probed as UpToDate.
            let ids: Vec<String> = flow
                .ordered_groups
                .iter()
                .take(GROUP_HISTORY_LIMIT)
                .filter(|gid| !state.messages.is_recent_history_up_to_date(gid))
                .cloned()
                .collect();
            (flow.full_refresh, ids)
        }
        None => return,
    };

    let up_to_date = state.messages.up_to_date_count();
    let log = format!(
        "bootstrap: history full={full_refresh} groups_fetch={} up_to_date={up_to_date}",
        initial_group_ids.len()
    );
    state.messages.bootstrap_logs.push(log.clone());
    out.effects.push(Effect::EngineLog(log));

    let slices: Vec<Vec<String>> = initial_group_ids
        .chunks(GROUP_HISTORY_WAVE_SIZE)
        .map(<[String]>::to_vec)
        .collect();
    if let Some(flow) = state.messages.active_bootstrap.as_mut() {
        flow.group_wave_slices = slices;
        flow.group_wave_idx = 0;
    }
    advance_group_waves(state, out);
}

fn advance_group_waves(state: &mut CoreState, out: &mut ReduceOutput) {
    let next = state.messages.active_bootstrap.as_ref().and_then(|flow| {
        flow.group_wave_slices
            .get(flow.group_wave_idx)
            .map(|slice| (flow.boot_gen, slice.clone()))
    });
    if let Some((boot_gen, gids)) = next {
        state.bootstrap.stage = BootstrapStage::GroupWaves;
        out.effects.push(Effect::BootstrapFetchGroupWaveApi {
            boot_gen,
            gids,
            count: GROUP_HISTORY_COUNT,
        });
    } else {
        start_finalize_resolve_names(state, out);
    }
}

fn start_finalize_resolve_names(state: &mut CoreState, out: &mut ReduceOutput) {
    let Some(boot_gen) = state.messages.active_bootstrap.as_ref().map(|f| f.boot_gen) else {
        return;
    };
    let self_conv_id = state.session.self_conversation_id.clone();
    let missing = state
        .conversations
        .missing_name_uids(self_conv_id.as_deref());
    if missing.is_empty() {
        after_resolve_names(state, out);
        return;
    }
    let mut chunks: Vec<Vec<String>> = missing
        .chunks(RESOLVE_NAMES_CHUNK_SIZE)
        .map(<[String]>::to_vec)
        .collect();
    let first = chunks.remove(0);
    state.bootstrap.stage = BootstrapStage::ResolveNames;
    out.effects.push(Effect::BootstrapFetchProfilesChunkApi {
        boot_gen,
        chunk: first,
        remaining_chunks: chunks,
        profiles_cache_changed: false,
    });
}

fn after_resolve_names(state: &mut CoreState, out: &mut ReduceOutput) {
    ensure_known_contacts_and_rebuild(state, out);
    conversations::emit_save_conversations(state, out);

    if let Some(flow) = state.messages.active_bootstrap.as_mut() {
        flow.group_waves_done = true;
    }
    state.bootstrap.stage = BootstrapStage::AwaitingDrain;
    try_complete_finalize(state, out);
}

fn try_complete_finalize(state: &mut CoreState, out: &mut ReduceOutput) {
    let ready = state
        .messages
        .active_bootstrap
        .as_ref()
        .is_some_and(|f| f.group_waves_done && f.lp_drain_done);
    if !ready {
        return;
    }
    let Some(flow) = state.messages.active_bootstrap.take() else {
        return;
    };
    state.bootstrap.stage = BootstrapStage::Idle;
    state.bootstrap.lp_drain_id = None;

    if let Some((key, value)) = state.messages.finish_full_history_refresh(flow.now_ms) {
        out.effects
            .push(Effect::Store(StoreOp::SetPreferenceString { key, value }));
    }
    out.effects.push(Effect::Host(HostCall::RefreshCloud));

    let log = format!(
        "bootstrap: convs={} friends={} groups={}",
        state.conversations.conversations.len(),
        state.contacts.friends.len(),
        state.contacts.groups.len()
    );
    state.messages.bootstrap_logs.push(log.clone());
    out.effects.push(Effect::EngineLog(log));

    if let Some(op_id) = flow.op_id {
        out.effects.push(Effect::CompleteOp {
            op_id,
            result: OpResult::Unit,
            after_store: true,
        });
    }
}

fn ensure_known_contacts_and_rebuild(state: &mut CoreState, out: &mut ReduceOutput) {
    let self_conv_id = state.session.self_conversation_id.clone();
    if state
        .conversations
        .ensure_known_contacts(self_conv_id.as_deref())
    {
        out.dirty.insert(DirtyKey::Conversations);
    }
    conversations::rebuild_flags_and_extras(state, out);
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::conversations::ConversationSummary;
    use crate::messages::{GroupEntry, HistoryFreshness};
    use crate::reduce::reduce;
    use crate::state::{Phase, Profile};

    fn ready_state(uid: &str, self_conv: &str) -> CoreState {
        let mut s = CoreState::default();
        s.session.phase = Phase::Ready;
        s.session.profile = Some(Profile {
            user_id: uid.to_owned(),
            display_name: "Me".to_owned(),
            avatar: Some("https://cdn.example/me.jpg".to_owned()),
            phone: None,
        });
        s.session.self_conversation_id = Some(self_conv.to_owned());
        s.transport.lp_running = true;
        s.transport.lp_gen = 1;
        s
    }

    fn json_obj(v: Value) -> Map<String, Value> {
        match v {
            Value::Object(m) => m,
            _ => Map::new(),
        }
    }

    #[test]
    fn aliases_auth_error_expires_session_and_aborts_bootstrap() {
        let mut state = ready_state("2000519", "9200519");
        let out = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 7,
                cmd: Command::Bootstrap {
                    now_ms: 1_700_100_000_000,
                },
            },
        );
        assert!(matches!(
            out.effects.as_slice(),
            [
                Effect::CancelBootstrapTasks,
                Effect::BootstrapFetchAliasesApi { boot_gen: 1 }
            ]
        ));

        let out = reduce(
            &mut state,
            Input::BootstrapAliasesDone {
                boot_gen: 1,
                result: Err(BootstrapAliasesError::Auth),
            },
        );
        assert!(state.messages.active_bootstrap.is_none());
        assert_eq!(state.bootstrap.stage, BootstrapStage::Idle);
        assert_eq!(
            state.session.sign_out_notice.as_deref(),
            Some(ALIASES_AUTH_EXPIRED_REASON)
        );
        assert!(matches!(state.session.phase, Phase::Login(_)));
        assert!(out.effects.iter().any(|e| matches!(
            e,
            Effect::CompleteOp {
                op_id: 7,
                result: OpResult::Unit,
                after_store: false
            }
        )));
        assert!(
            out.effects
                .iter()
                .any(|e| matches!(e, Effect::Host(HostCall::MarkExpired)))
        );
        assert!(
            !out.effects
                .iter()
                .any(|e| matches!(e, Effect::Store(StoreOp::LoadPreferenceString { .. })))
        );
    }

    #[test]
    fn aliases_success_merges_persists_and_loads_freshness_pref() {
        let mut state = ready_state("2000501", "9200501");
        state
            .conversations
            .identities
            .aliases
            .insert("3000001".to_owned(), "Old".to_owned());

        reduce(
            &mut state,
            Input::Command(Command::Bootstrap {
                now_ms: 1_700_100_000_000,
            }),
        );
        let mut aliases = BTreeMap::new();
        aliases.insert("3000001".to_owned(), "New".to_owned());
        aliases.insert("3000002".to_owned(), "Two".to_owned());

        let out = reduce(
            &mut state,
            Input::BootstrapAliasesDone {
                boot_gen: 1,
                result: Ok(aliases),
            },
        );
        assert_eq!(
            state
                .conversations
                .identities
                .aliases
                .get("3000001")
                .map(String::as_str),
            Some("New")
        );
        assert_eq!(
            state
                .conversations
                .identities
                .aliases
                .get("3000002")
                .map(String::as_str),
            Some("Two")
        );
        assert!(out.effects.iter().any(|e| matches!(
            e,
            Effect::Store(StoreOp::SetPreferenceData { key, .. }) if key == "aliases"
        )));
        assert!(out.effects.iter().any(|e| matches!(
            e,
            Effect::Store(StoreOp::LoadPreferenceString { key, boot_gen: 1 })
                if key == FULL_HISTORY_REFRESH_PREF_KEY
        )));
    }

    #[test]
    fn freshness_pass_starts_concurrent_lp_drain_and_pam() {
        let mut state = ready_state("2000520", "9200520");
        reduce(
            &mut state,
            Input::Command(Command::Bootstrap {
                now_ms: 1_700_000_200_000,
            }),
        );
        reduce(
            &mut state,
            Input::BootstrapAliasesDone {
                boot_gen: 1,
                result: Ok(BTreeMap::new()),
            },
        );

        let out = reduce(
            &mut state,
            Input::BootstrapFreshnessLoaded {
                boot_gen: 1,
                last_refresh_pref: None,
            },
        );
        assert!(
            state
                .messages
                .active_bootstrap
                .as_ref()
                .is_some_and(|f| f.full_refresh)
        );
        assert!(state.bootstrap.lp_drain_id.is_some());
        assert!(
            out.effects
                .iter()
                .any(|e| matches!(e, Effect::FetchPollBatch { lp_gen: 1, .. }))
        );
        assert!(
            out.effects
                .iter()
                .any(|e| matches!(e, Effect::BootstrapFetchPamApi { boot_gen: 1 }))
        );
    }

    #[test]
    fn pam_updates_pins_archived_and_emits_apply_mutes_only_when_ok() {
        let mut state = ready_state("2000520", "9200520");
        reduce(
            &mut state,
            Input::Command(Command::Bootstrap {
                now_ms: 1_700_000_200_000,
            }),
        );
        reduce(
            &mut state,
            Input::BootstrapAliasesDone {
                boot_gen: 1,
                result: Ok(BTreeMap::new()),
            },
        );
        reduce(
            &mut state,
            Input::BootstrapFreshnessLoaded {
                boot_gen: 1,
                last_refresh_pref: None,
            },
        );

        let mute_rows = vec![
            json_obj(
                json!({"id": "3000020", "type": 1, "startTime": 1700000000, "duration": 3600}),
            ),
            json_obj(json!({"id": "3000022", "type": 1, "duration": -1})),
            json_obj(json!({"id": "500020", "type": 2, "duration": 7200})),
        ];
        let out = reduce(
            &mut state,
            Input::BootstrapPamDone {
                boot_gen: 1,
                pinned_ids: Some(vec!["3000020".to_owned(), "g500020".to_owned()]),
                archived_ids: Some(vec!["3000021".to_owned(), "g500021".to_owned()]),
                mute_rows: Some(mute_rows),
            },
        );

        assert!(state.conversations.pinned_ids.contains("3000020"));
        assert!(state.conversations.pinned_ids.contains("g500020"));
        assert!(state.conversations.archived_ids.contains("3000021"));
        assert!(state.conversations.archived_ids.contains("g500021"));

        let applied = out.effects.iter().find_map(|e| match e {
            Effect::Host(HostCall::ApplyMutes { mutes }) => Some(mutes.clone()),
            _ => None,
        });
        assert_eq!(
            applied,
            Some(vec![
                MuteEntry {
                    conv_id: "3000020".to_owned(),
                    start: 1_700_000_000,
                    duration: 3600,
                },
                MuteEntry {
                    conv_id: "3000022".to_owned(),
                    start: 1_700_000_200,
                    duration: -1,
                },
                MuteEntry {
                    conv_id: "g500020".to_owned(),
                    start: 1_700_000_200,
                    duration: 7200,
                },
            ])
        );
        assert!(
            out.effects
                .iter()
                .any(|e| matches!(e, Effect::BootstrapFetchLabelsApi { boot_gen: 1 }))
        );
    }

    #[test]
    fn pam_skips_apply_mutes_when_mute_fetch_failed() {
        let mut state = ready_state("2000520", "9200520");
        reduce(
            &mut state,
            Input::Command(Command::Bootstrap {
                now_ms: 1_700_000_200_000,
            }),
        );
        reduce(
            &mut state,
            Input::BootstrapAliasesDone {
                boot_gen: 1,
                result: Ok(BTreeMap::new()),
            },
        );
        reduce(
            &mut state,
            Input::BootstrapFreshnessLoaded {
                boot_gen: 1,
                last_refresh_pref: None,
            },
        );

        let out = reduce(
            &mut state,
            Input::BootstrapPamDone {
                boot_gen: 1,
                pinned_ids: None,
                archived_ids: None,
                mute_rows: None,
            },
        );
        assert!(
            !out.effects
                .iter()
                .any(|e| matches!(e, Effect::Host(HostCall::ApplyMutes { .. })))
        );
    }

    #[test]
    fn clear_unreads_filters_invalid_ids_and_computes_preload_chunks() {
        let mut state = ready_state("2000501", "92000501");
        state
            .conversations
            .identities
            .activity_ranks
            .insert("3000001".to_owned(), 50);
        state.contacts.groups.push(GroupEntry {
            id: "g500001".to_owned(),
            name: "Known Group".to_owned(),
            avatar: None,
            members: 5,
            sort_key: "known group".to_owned(),
        });
        state.contacts.groups.push(GroupEntry {
            id: "g500099".to_owned(),
            name: "Pinned Group".to_owned(),
            avatar: None,
            members: 3,
            sort_key: "pinned group".to_owned(),
        });
        state.conversations.pinned_ids.insert("g500099".to_owned());

        let payload = json_obj(json!({
            "data": {
                "clearUnreads": [
                    {"idTo": "3000001", "lastMsgId": 30},
                    {"idTo": " 3000002 ", "lastMsgId": 70},
                    {"threadId": "3000002", "lastMsgId": 90},
                    {"idTo": "2000501", "lastMsgId": 99},
                    {"idTo": "0", "lastMsgId": 88},
                    {"idTo": "g0", "isGroup": 1, "lastMsgId": 77},
                    {"idTo": "92000501", "isGroup": 1, "lastMsgId": 66},
                    {"idTo": "3000003", "lastMsgId": 0},
                    {"idTo": "500002", "isGroup": 1, "lastMsgId": 120},
                    {"uid": "500001", "lastMsgId": 110}
                ]
            }
        }));
        let mut group_rank = HashMap::new();
        let mut out = ReduceOutput::default();
        apply_preload_clear_unreads(&payload, &mut state, &mut group_rank, &mut out);

        assert_eq!(
            state.conversations.identities.activity_ranks,
            BTreeMap::from([
                ("3000001".to_owned(), 50),
                ("3000002".to_owned(), 90),
                ("g500001".to_owned(), 110),
                ("g500002".to_owned(), 120),
            ])
        );
        assert_eq!(group_rank.get("g500001"), Some(&110));
        assert_eq!(group_rank.get("g500002"), Some(&120));
        assert!(out.effects.iter().any(|e| matches!(
            e,
            Effect::Store(StoreOp::SetPreferenceData { key, .. }) if key == "activityRanks"
        )));

        let (ordered_groups, chunks) = compute_preload_order_and_chunks(&state, &group_rank);
        assert_eq!(
            ordered_groups,
            vec!["g500099".to_owned(), "g500001".to_owned()]
        );
        assert_eq!(
            chunks,
            vec![vec![
                "3000002".to_owned(),
                "3000001".to_owned(),
                "g500099".to_owned(),
                "g500001".to_owned(),
            ]]
        );
    }

    #[test]
    fn group_waves_cap_at_24_before_filtering_up_to_date_and_chunk_by_6() {
        let mut state = ready_state("2000524", "9200524");
        reduce(
            &mut state,
            Input::Command(Command::Bootstrap {
                now_ms: 1_700_100_000_000,
            }),
        );
        if let Some(flow) = state.messages.active_bootstrap.as_mut() {
            flow.full_refresh = false;
            flow.ordered_groups = (1..=26).map(|i| format!("g5002{i:02}")).collect();
        }
        state
            .messages
            .history_freshness
            .insert("g500201".to_owned(), HistoryFreshness::UpToDate);
        state.bootstrap.stage = BootstrapStage::SelfCloud;

        let out = reduce(
            &mut state,
            Input::BootstrapSelfCloudDone {
                boot_gen: 1,
                conv_id: "9200524".to_owned(),
                payload: None,
            },
        );
        assert_eq!(
            state.messages.bootstrap_logs,
            vec!["bootstrap: history full=false groups_fetch=23 up_to_date=1".to_owned()]
        );
        let first_wave = out.effects.iter().find_map(|e| match e {
            Effect::BootstrapFetchGroupWaveApi { gids, count, .. } => Some((gids.clone(), *count)),
            _ => None,
        });
        assert_eq!(
            first_wave,
            Some((
                vec![
                    "g500202".to_owned(),
                    "g500203".to_owned(),
                    "g500204".to_owned(),
                    "g500205".to_owned(),
                    "g500206".to_owned(),
                    "g500207".to_owned(),
                ],
                30
            ))
        );
        let slices = &state
            .messages
            .active_bootstrap
            .as_ref()
            .map(|f| f.group_wave_slices.clone())
            .unwrap_or_default();
        assert_eq!(slices.len(), 4);
        assert_eq!(slices[3].len(), 5);
        assert_eq!(slices[3].last().map(String::as_str), Some("g500224"));
    }

    #[test]
    fn finalize_waits_for_both_waves_and_lp_drain_in_either_order() {
        // Order A: waves finish first, then LP drain completes.
        let mut state = ready_state("2000525", "9200525");
        reduce(
            &mut state,
            Input::OpRequest {
                op_id: 9,
                cmd: Command::Bootstrap {
                    now_ms: 1_700_300_000_000,
                },
            },
        );
        reduce(
            &mut state,
            Input::BootstrapAliasesDone {
                boot_gen: 1,
                result: Ok(BTreeMap::new()),
            },
        );
        reduce(
            &mut state,
            Input::BootstrapFreshnessLoaded {
                boot_gen: 1,
                last_refresh_pref: None,
            },
        );
        let drain_id = state.bootstrap.lp_drain_id.unwrap_or(0);
        assert!(drain_id > 0);
        state.conversations.conversations.push(ConversationSummary {
            id: "9200525".to_owned(),
            is_group: false,
            name: "Cloud của tôi".to_owned(),
            avatar: None,
            pinned: false,
            members: 0,
            unread: 0,
            preview: None,
        });

        let mut out_a = ReduceOutput::default();
        after_resolve_names(&mut state, &mut out_a);
        // Must NOT finalize yet because LP drain is still running.
        assert!(state.messages.active_bootstrap.is_some());
        assert!(
            !out_a
                .effects
                .iter()
                .any(|e| matches!(e, Effect::Host(HostCall::RefreshCloud)))
        );

        let mut out_b = ReduceOutput::default();
        on_lp_drain_done(&mut state, drain_id, &mut out_b);
        assert!(state.messages.active_bootstrap.is_none());
        assert!(out_b.effects.iter().any(|e| matches!(
            e,
            Effect::Store(StoreOp::SetPreferenceString { key, value })
                if key == FULL_HISTORY_REFRESH_PREF_KEY && value == "1700300000.0"
        )));
        assert!(
            out_b
                .effects
                .iter()
                .any(|e| matches!(e, Effect::Host(HostCall::RefreshCloud)))
        );
        assert!(out_b.effects.iter().any(|e| matches!(
            e,
            Effect::CompleteOp {
                op_id: 9,
                result: OpResult::Unit,
                after_store: true
            }
        )));
        assert_eq!(
            state.messages.bootstrap_logs.last().map(String::as_str),
            Some("bootstrap: convs=1 friends=0 groups=0")
        );

        // Order B: LP drain finishes first, then waves finish.
        let mut state2 = ready_state("2000525", "9200525");
        reduce(
            &mut state2,
            Input::Command(Command::Bootstrap {
                now_ms: 1_700_300_000_000,
            }),
        );
        reduce(
            &mut state2,
            Input::BootstrapAliasesDone {
                boot_gen: 1,
                result: Ok(BTreeMap::new()),
            },
        );
        reduce(
            &mut state2,
            Input::BootstrapFreshnessLoaded {
                boot_gen: 1,
                last_refresh_pref: Some("1700299000.0".to_owned()),
            },
        );
        let drain_id2 = state2.bootstrap.lp_drain_id.unwrap_or(0);
        let mut out_drain = ReduceOutput::default();
        on_lp_drain_done(&mut state2, drain_id2, &mut out_drain);
        assert!(state2.messages.active_bootstrap.is_some());
        assert!(
            !out_drain
                .effects
                .iter()
                .any(|e| matches!(e, Effect::Host(HostCall::RefreshCloud)))
        );

        let mut out_waves = ReduceOutput::default();
        after_resolve_names(&mut state2, &mut out_waves);
        assert!(state2.messages.active_bootstrap.is_none());
        // Full refresh was NOT due, so historyFullRefreshAt must NOT be written.
        assert!(!out_waves.effects.iter().any(|e| matches!(
            e,
            Effect::Store(StoreOp::SetPreferenceString { key, .. })
                if key == FULL_HISTORY_REFRESH_PREF_KEY
        )));
        assert!(
            out_waves
                .effects
                .iter()
                .any(|e| matches!(e, Effect::Host(HostCall::RefreshCloud)))
        );
    }

    #[test]
    fn stale_boot_gen_completions_are_ignored_after_restart() {
        let mut state = ready_state("2000501", "9200501");
        reduce(
            &mut state,
            Input::OpRequest {
                op_id: 1,
                cmd: Command::Bootstrap {
                    now_ms: 1_700_100_000_000,
                },
            },
        );
        let out_restart = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 2,
                cmd: Command::Bootstrap {
                    now_ms: 1_700_200_000_000,
                },
            },
        );
        assert!(out_restart.effects.iter().any(|e| matches!(
            e,
            Effect::CompleteOp {
                op_id: 1,
                result: OpResult::Unit,
                after_store: false
            }
        )));
        assert_eq!(state.messages.boot_gen, 2);

        // Stale auth error from boot_gen=1 must be ignored.
        let out_stale = reduce(
            &mut state,
            Input::BootstrapAliasesDone {
                boot_gen: 1,
                result: Err(BootstrapAliasesError::Auth),
            },
        );
        assert!(out_stale.effects.is_empty());
        assert_eq!(state.session.phase, Phase::Ready);
        assert!(state.messages.active_bootstrap.is_some());
    }
}

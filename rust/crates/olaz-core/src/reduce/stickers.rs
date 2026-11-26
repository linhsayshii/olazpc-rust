//! Pure reducer for U13 stickers (tabs, category details, search, typing suggestions, setting).
//!
//! Sticker sending (`Command::SendSticker`) is intentionally routed through [`crate::reduce::send`]
//! so it reuses the U5 send pipeline (optimistic row, client id, conversation update, failure
//! cleanup) verbatim.

use olaz_wire::is_group_id;

use crate::changes::DirtyKey;
use crate::effect::{Effect, OpResult, StoreOp};
use crate::input::{Command, Input};
use crate::reduce::ReduceOutput;
use crate::state::CoreState;
use crate::stickers::{
    STICKER_CATEGORIES_CACHE_MIN, STICKER_SEARCH_LIMIT, STICKER_SUGGEST_DEBOUNCE_MS,
    STICKER_SUGGEST_LIMIT, STICKER_TAB_ENTRY_LIMIT, STICKER_TAB_RECENT_ID, StickerSuggestSetting,
    sticker_entries_from_recent_json, sticker_entries_from_rows, sticker_tabs_from_categories,
};

fn complete_op(op_id: Option<u64>, result: OpResult, after_store: bool, out: &mut ReduceOutput) {
    if let Some(op_id) = op_id {
        out.effects.push(Effect::CompleteOp {
            op_id,
            result,
            after_store,
        });
    }
}

/// Reduces a U13 sticker [`Input`].
pub(crate) fn reduce_stickers(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::Command(cmd) => reduce_command(state, cmd, None, out),
        Input::OpRequest { op_id, cmd } => reduce_command(state, cmd, Some(op_id), out),
        Input::StickerCategoriesFetched { op_id, result } => match result {
            Ok((fetched, recent_count)) => {
                if fetched.downloaded_count >= STICKER_CATEGORIES_CACHE_MIN {
                    state.stickers.cached_categories = Some(fetched.packs.clone());
                }
                let tabs = sticker_tabs_from_categories(&fetched.packs, recent_count);
                complete_op(op_id, OpResult::StickerTabs(Some(tabs)), false, out);
            }
            Err(_) => {
                complete_op(op_id, OpResult::StickerTabs(None), false, out);
            }
        },
        Input::StickerTabsRecentsLoaded {
            op_id,
            recent_count,
        } => {
            if let Some(cats) = state.stickers.cached_categories.as_deref() {
                let tabs = sticker_tabs_from_categories(cats, recent_count);
                complete_op(op_id, OpResult::StickerTabs(Some(tabs)), false, out);
            } else {
                complete_op(op_id, OpResult::StickerTabs(None), false, out);
            }
        }
        Input::RecentStickersLoaded { op_id, rows } => {
            let entries = sticker_entries_from_recent_json(&rows, STICKER_TAB_ENTRY_LIMIT);
            complete_op(op_id, OpResult::StickerEntries(Some(entries)), false, out);
        }
        Input::StickerCategoryDetailFetched {
            op_id,
            cate_id,
            result,
        } => match result {
            Ok(rows) => {
                let entries = sticker_entries_from_rows(&rows, cate_id, STICKER_TAB_ENTRY_LIMIT);
                complete_op(op_id, OpResult::StickerEntries(Some(entries)), false, out);
            }
            Err(_) => {
                complete_op(op_id, OpResult::StickerEntries(None), false, out);
            }
        },
        Input::StickerSearchFetched { op_id, result } => match result {
            Ok(rows) => {
                let entries = sticker_entries_from_rows(&rows, 0, STICKER_SEARCH_LIMIT);
                complete_op(op_id, OpResult::StickerEntries(Some(entries)), false, out);
            }
            Err(_) => {
                complete_op(op_id, OpResult::StickerEntries(None), false, out);
            }
        },
        Input::StickerSuggestFetched { op_id, result } => {
            let entries = match result {
                Ok(rows) => sticker_entries_from_rows(&rows, 0, STICKER_SUGGEST_LIMIT),
                Err(_) => Vec::new(),
            };
            complete_op(op_id, OpResult::StickerEntries(Some(entries)), false, out);
        }
        Input::StickerSuggestPrefLoaded { op_id, enabled } => {
            // Reading the persisted setting intentionally does NOT mutate
            // `state.stickers.suggest_setting` (matches Swift `stickerSuggestSetting()`).
            complete_op(
                op_id,
                OpResult::StickerSuggestSetting(Some(StickerSuggestSetting {
                    enabled,
                    debounce: STICKER_SUGGEST_DEBOUNCE_MS,
                })),
                false,
                out,
            );
        }
        _ => {}
    }
}

fn reduce_command(state: &mut CoreState, cmd: Command, op_id: Option<u64>, out: &mut ReduceOutput) {
    match cmd {
        Command::StickerTabs => {
            if state.stickers.cached_categories.is_some() {
                out.effects
                    .push(Effect::LoadRecentStickersForTabs { op_id });
            } else {
                out.effects.push(Effect::FetchStickerCategories { op_id });
            }
        }
        Command::StickersInTab { id } => {
            if id == STICKER_TAB_RECENT_ID {
                out.effects.push(Effect::LoadRecentStickers { op_id });
            } else {
                out.effects
                    .push(Effect::FetchStickerCategoryDetail { op_id, cate_id: id });
            }
        }
        Command::SearchStickers { text } => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                complete_op(
                    op_id,
                    OpResult::StickerEntries(Some(Vec::new())),
                    false,
                    out,
                );
                return;
            }
            out.effects.push(Effect::SearchStickersApi {
                op_id,
                keyword: trimmed.to_owned(),
                limit: i64::try_from(STICKER_SEARCH_LIMIT).unwrap_or(40),
            });
        }
        Command::TypingStickerSuggestions {
            conv_id,
            text,
            is_e2ee,
        } => {
            if state
                .stickers
                .suggest_setting
                .as_ref()
                .is_some_and(|s| !s.enabled)
            {
                complete_op(
                    op_id,
                    OpResult::StickerEntries(Some(Vec::new())),
                    false,
                    out,
                );
                return;
            }
            let effective_e2ee = !is_group_id(&conv_id)
                && is_e2ee.unwrap_or_else(|| state.send.e2ee_threads.contains(&conv_id));
            if effective_e2ee {
                complete_op(
                    op_id,
                    OpResult::StickerEntries(Some(Vec::new())),
                    false,
                    out,
                );
                return;
            }
            let trimmed = text.trim();
            if trimmed.is_empty() {
                complete_op(
                    op_id,
                    OpResult::StickerEntries(Some(Vec::new())),
                    false,
                    out,
                );
                return;
            }
            out.effects.push(Effect::SuggestStickersApi {
                op_id,
                keyword: trimmed.to_owned(),
            });
        }
        Command::StickerSetting => {
            out.effects.push(Effect::LoadStickerSuggestPref { op_id });
        }
        Command::SetStickerSuggest { enabled } => {
            let setting = StickerSuggestSetting {
                enabled,
                debounce: STICKER_SUGGEST_DEBOUNCE_MS,
            };
            state.stickers.suggest_setting = Some(setting);
            out.dirty.insert(DirtyKey::StickerSuggest);
            out.effects.push(Effect::Store(StoreOp::SetPreferenceBool {
                key: "stickerSuggest".to_owned(),
                value: enabled,
            }));
            complete_op(
                op_id,
                OpResult::StickerSuggestSetting(Some(setting)),
                true,
                out,
            );
        }
        Command::SeedStickerSuggestSetting(setting) => {
            state.stickers.suggest_setting = setting;
            out.dirty.insert(DirtyKey::StickerSuggest);
            complete_op(op_id, OpResult::Unit, false, out);
        }
        Command::ResetStickers => {
            state.stickers.reset();
            out.dirty.insert(DirtyKey::StickerSuggest);
            complete_op(op_id, OpResult::Unit, false, out);
        }
        _ => {}
    }
}

//! Sticker picker, typing suggestions, and recent-sticker domain types & normalization (U13).
//!
//! `Debug` implementations emit shape-only summaries without URLs or content (ADR-008).

use std::collections::HashSet;
use std::fmt;

use olaz_api::StickerCategoryRow;
use olaz_json::{int64 as json_int64, string as json_string};
use olaz_wire::{sticker_cdn_url, web_link_sanitized};
use serde_json::{Map, Value, json};

/// Tab id for the virtual "Gần đây" (recent stickers) tab.
pub const STICKER_TAB_RECENT_ID: i64 = -2;
/// Default typing-suggestion debounce (ms) reported by the suggest setting.
pub const STICKER_SUGGEST_DEBOUNCE_MS: i64 = 180;
/// Maximum number of recent stickers retained in SQLite (`recentStickers`).
pub const MAX_RECENT_STICKERS: usize = 30;
/// Minimum number of downloaded categories required before caching categories in memory.
pub const STICKER_CATEGORIES_CACHE_MIN: usize = 5;
/// Maximum sticker entries returned for a tab.
pub const STICKER_TAB_ENTRY_LIMIT: usize = 500;
/// Maximum sticker entries returned for search.
pub const STICKER_SEARCH_LIMIT: usize = 40;
/// Maximum sticker entries returned for typing suggestions.
pub const STICKER_SUGGEST_LIMIT: usize = 30;
/// Maximum tabs returned by `sticker_tabs`.
pub const STICKER_TAB_LIMIT: usize = 200;

/// Animation source for a sticker entry.
#[derive(Clone, PartialEq, Eq)]
pub enum StickerAnimation {
    Sprite {
        url: String,
        frames: i64,
        frame_ms: i64,
    },
    Animated {
        url: String,
    },
}

impl fmt::Debug for StickerAnimation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Sprite {
                frames, frame_ms, ..
            } => f
                .debug_struct("Sprite")
                .field("frames", frames)
                .field("frame_ms", frame_ms)
                .finish(),
            Self::Animated { .. } => f.write_str("Animated"),
        }
    }
}

/// A sticker entry shown in the picker or typing suggestion strip.
#[derive(Clone, PartialEq, Eq)]
pub struct StickerEntry {
    pub cate_id: i64,
    pub sticker_id: i64,
    pub url: String,
    pub animation: Option<StickerAnimation>,
}

impl fmt::Debug for StickerEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StickerEntry")
            .field("cate_id", &self.cate_id)
            .field("sticker_id", &self.sticker_id)
            .field("has_anim", &self.animation.is_some())
            .finish()
    }
}

/// A sticker picker tab (a downloaded pack or the virtual recent tab `-2`).
#[derive(Clone, PartialEq, Eq)]
pub struct StickerTab {
    pub id: i64,
    pub name: String,
    pub icon: Option<String>,
    pub count: i64,
}

impl fmt::Debug for StickerTab {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StickerTab")
            .field("id", &self.id)
            .field("has_icon", &self.icon.is_some())
            .field("count", &self.count)
            .finish()
    }
}

/// The "Gợi ý Sticker" setting plus typing debounce in milliseconds.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct StickerSuggestSetting {
    pub enabled: bool,
    pub debounce: i64,
}

/// Where a sticker send originated.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum StickerSource {
    Category,
    Recent,
    Search,
    Suggestion,
}

/// Outcome of a card / sticker action (matches Swift `CardActionOutcome`).
#[derive(Clone, PartialEq, Eq)]
pub enum CardActionOutcome {
    Done,
    OpenChat(String),
    OpenProfile(String),
    OpenUrl(String),
    Copy(String),
    Present,
    Unsupported(String),
    Locked(String),
    Failed(String),
    Pending(String),
}

impl fmt::Debug for CardActionOutcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Done => f.write_str("Done"),
            Self::OpenChat(_) => f.write_str("OpenChat"),
            Self::OpenProfile(_) => f.write_str("OpenProfile"),
            Self::OpenUrl(_) => f.write_str("OpenUrl"),
            Self::Copy(_) => f.write_str("Copy"),
            Self::Present => f.write_str("Present"),
            Self::Unsupported(_) => f.write_str("Unsupported"),
            Self::Locked(_) => f.write_str("Locked"),
            Self::Failed(_) => f.write_str("Failed"),
            Self::Pending(_) => f.write_str("Pending"),
        }
    }
}

/// In-memory sticker state owned by the core actor.
#[derive(Clone, Default)]
pub struct StickerState {
    /// Cached category list when the catalog fetch yielded `>= 5` downloaded packs.
    pub cached_categories: Option<Vec<StickerCategoryRow>>,
    /// Mirrors `StickerSuggestState.shared.setting` (`None` until explicitly applied via
    /// `set_sticker_suggest` or seeded).
    pub suggest_setting: Option<StickerSuggestSetting>,
}

impl StickerState {
    pub(crate) fn reset(&mut self) {
        self.cached_categories = None;
        self.suggest_setting = None;
    }
}

impl fmt::Debug for StickerState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StickerState")
            .field(
                "cached_categories_count",
                &self.cached_categories.as_ref().map(Vec::len),
            )
            .field("suggest_setting", &self.suggest_setting)
            .finish()
    }
}

/// Sanitizes an optional URL string (http/https with non-empty host), matching `WebLink.sanitized`.
#[must_use]
pub fn sanitize_web_url(raw: &str) -> Option<String> {
    if raw.is_empty() {
        return None;
    }
    web_link_sanitized(Some(raw.to_owned()))
}

/// Parses a `StickerAnimation` from a normalized `"anim"` JSON object (`StickerAnimation(json:)`).
fn parse_anim_value(val: Option<&Value>) -> Option<StickerAnimation> {
    let row = val?.as_object()?;
    let raw_url = row.get("url").and_then(Value::as_str)?;
    let url = sanitize_web_url(raw_url)?;
    match row.get("kind").and_then(Value::as_str)? {
        "sprite" => {
            let frames = json_int64(row.get("frames")).unwrap_or(0);
            let ms = json_int64(row.get("ms")).unwrap_or(0);
            if !(2..=200).contains(&frames) {
                return None;
            }
            Some(StickerAnimation::Sprite {
                url,
                frames,
                frame_ms: ms.clamp(30, 1000),
            })
        }
        "gif" | "webp" => Some(StickerAnimation::Animated { url }),
        _ => None,
    }
}

/// Normalizes a raw sticker API row into a [`StickerEntry`] (matching `normalizeStickerRow` +
/// `StickerEntry.list`).
#[must_use]
pub fn normalize_sticker_row(
    row: &Map<String, Value>,
    fallback_cate_id: i64,
) -> Option<StickerEntry> {
    let id = json_int64(
        row.get("id")
            .or_else(|| row.get("stickerId"))
            .or_else(|| row.get("sticker_id")),
    )
    .unwrap_or(0);
    let cate =
        json_int64(row.get("cateId").or_else(|| row.get("cate_id"))).unwrap_or(fallback_cate_id);
    if cate < 0 || id <= 0 {
        return None;
    }
    let explicit_url = json_string(row.get("stickerUrl").or_else(|| row.get("url")));
    let url_str = if explicit_url.is_empty() {
        sticker_cdn_url(cate, &id.to_string())
    } else {
        explicit_url
    };
    let url = sanitize_web_url(&url_str)?;

    let sprite = json_string(row.get("stickerSpriteUrl")).replace("http://", "https://");
    let frames = json_int64(row.get("totalFrames")).unwrap_or(0);
    let animation = if sprite.starts_with("https://") && (2..=200).contains(&frames) {
        sanitize_web_url(&sprite).map(|sprite_url| {
            let raw_dur = json_int64(row.get("duration")).unwrap_or(120);
            let dur = if raw_dur > 0 { raw_dur } else { 120 };
            StickerAnimation::Sprite {
                url: sprite_url,
                frames,
                frame_ms: dur.clamp(30, 1000),
            }
        })
    } else {
        None
    };

    Some(StickerEntry {
        cate_id: cate,
        sticker_id: id,
        url,
        animation,
    })
}

/// Normalizes, filters, deduplicates (`"{cate_id}_{sticker_id}"`), and caps raw sticker API rows.
#[must_use]
pub fn sticker_entries_from_rows(
    rows: &[Map<String, Value>],
    fallback_cate_id: i64,
    limit: usize,
) -> Vec<StickerEntry> {
    let mut seen: HashSet<(i64, i64)> = HashSet::new();
    let mut out = Vec::new();
    for row in rows {
        let Some(entry) = normalize_sticker_row(row, fallback_cate_id) else {
            continue;
        };
        if !seen.insert((entry.cate_id, entry.sticker_id)) {
            continue;
        }
        out.push(entry);
        if out.len() >= limit {
            break;
        }
    }
    out
}

/// Parses persisted `recentStickers` JSON rows directly via `StickerEntry.list` rules.
#[must_use]
pub fn sticker_entries_from_recent_json(rows: &[Value], limit: usize) -> Vec<StickerEntry> {
    let mut seen: HashSet<(i64, i64)> = HashSet::new();
    let mut out = Vec::new();
    for val in rows {
        let Some(row) = val.as_object() else {
            continue;
        };
        let Some(cate) = json_int64(row.get("cateId")) else {
            continue;
        };
        let Some(sticker_id) = json_int64(row.get("id")) else {
            continue;
        };
        if cate < 0 || sticker_id <= 0 {
            continue;
        }
        let Some(url) = row
            .get("url")
            .and_then(Value::as_str)
            .and_then(sanitize_web_url)
        else {
            continue;
        };
        if !seen.insert((cate, sticker_id)) {
            continue;
        }
        out.push(StickerEntry {
            cate_id: cate,
            sticker_id,
            url,
            animation: parse_anim_value(row.get("anim")),
        });
        if out.len() >= limit {
            break;
        }
    }
    out
}

/// Builds the ordered list of [`StickerTab`]s from fetched categories and the raw recent count.
#[must_use]
pub fn sticker_tabs_from_categories(
    categories: &[StickerCategoryRow],
    recent_count: usize,
) -> Vec<StickerTab> {
    let mut seen: HashSet<i64> = HashSet::new();
    let mut out = Vec::new();

    if recent_count > 0 {
        let count = i64::try_from(recent_count)
            .unwrap_or(10_000)
            .clamp(0, 10_000);
        seen.insert(STICKER_TAB_RECENT_ID);
        out.push(StickerTab {
            id: STICKER_TAB_RECENT_ID,
            name: "Gần đây".to_owned(),
            icon: None,
            count,
        });
    }

    for cat in categories {
        if cat.id < 0 || !seen.insert(cat.id) {
            continue;
        }
        let name: String = cat.name.chars().take(200).collect();
        let icon = sanitize_web_url(&cat.icon_url);
        let count = cat.total.clamp(0, 10_000);
        out.push(StickerTab {
            id: cat.id,
            name,
            icon,
            count,
        });
        if out.len() >= STICKER_TAB_LIMIT {
            break;
        }
    }

    out
}

/// Prepends `sticker` to the persisted `recentStickers` JSON array, deduplicating by `id` and
/// capping at [`MAX_RECENT_STICKERS`].
#[must_use]
pub fn update_recent_stickers_json(existing: &[Value], sticker: &StickerEntry) -> Vec<Value> {
    let mut rows: Vec<Value> = existing
        .iter()
        .filter(|v| json_int64(v.as_object().and_then(|o| o.get("id"))) != Some(sticker.sticker_id))
        .cloned()
        .collect();

    let mut fresh = Map::new();
    fresh.insert("id".to_owned(), json!(sticker.sticker_id));
    fresh.insert("cateId".to_owned(), json!(sticker.cate_id));
    fresh.insert("type".to_owned(), json!(7));
    fresh.insert("url".to_owned(), Value::String(sticker.url.clone()));
    rows.insert(0, Value::Object(fresh));

    if rows.len() > MAX_RECENT_STICKERS {
        rows.truncate(MAX_RECENT_STICKERS);
    }
    rows
}

/// Decodes raw `recentStickers` preference bytes into a JSON array (empty on missing/invalid JSON).
#[must_use]
pub fn parse_recent_stickers_bytes(bytes: Option<&[u8]>) -> Vec<Value> {
    let Some(data) = bytes else {
        return Vec::new();
    };
    let Ok(Value::Array(items)) = serde_json::from_slice::<Value>(data) else {
        return Vec::new();
    };
    items.into_iter().filter(Value::is_object).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_row_clamps_sprite_and_falls_back_to_cdn() {
        let mut row = Map::new();
        row.insert("id".to_owned(), json!(1));
        row.insert("cateId".to_owned(), json!(77));
        row.insert("duration".to_owned(), json!(0));
        row.insert("totalFrames".to_owned(), json!(8));
        row.insert(
            "stickerSpriteUrl".to_owned(),
            json!("http://cdn.example.invalid/sprite1.png"),
        );
        assert_eq!(
            normalize_sticker_row(&row, 77),
            Some(StickerEntry {
                cate_id: 77,
                sticker_id: 1,
                url: "https://api.zaloapp.com/api/emoticon/sticker/webpc?eid=1&size=130".to_owned(),
                animation: Some(StickerAnimation::Sprite {
                    url: "https://cdn.example.invalid/sprite1.png".to_owned(),
                    frames: 8,
                    frame_ms: 120,
                }),
            })
        );
    }

    #[test]
    fn update_recent_stickers_moves_existing_to_front_and_caps_at_30() {
        let existing: Vec<Value> = (1..=30)
            .map(|i| {
                json!({
                    "id": i,
                    "cateId": 1,
                    "type": 7,
                    "url": format!("https://cdn.example.invalid/{i}.png")
                })
            })
            .collect();
        let entry = StickerEntry {
            cate_id: 2,
            sticker_id: 15,
            url: "https://cdn.example.invalid/15_new.png".to_owned(),
            animation: None,
        };
        let updated = update_recent_stickers_json(&existing, &entry);
        assert_eq!(updated.len(), 30);
        assert_eq!(updated[0]["id"], json!(15));
        assert_eq!(updated[0]["cateId"], json!(2));
        assert_eq!(updated[0]["type"], json!(7));

        let fresh = StickerEntry {
            cate_id: 3,
            sticker_id: 999,
            url: "https://cdn.example.invalid/999.png".to_owned(),
            animation: None,
        };
        let capped = update_recent_stickers_json(&updated, &fresh);
        assert_eq!(capped.len(), 30);
        assert_eq!(capped[0]["id"], json!(999));
        assert_eq!(capped[29]["id"], json!(29));
    }
}

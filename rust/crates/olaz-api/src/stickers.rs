//! Sticker catalog, detail, search, suggestion, and send endpoints (U13).

use std::collections::BTreeSet;
use std::fmt;
use std::time::Duration;

use olaz_crypto::inflate_zlib_or_gzip;
use olaz_json::{int64, string};
use olaz_net::{ApiRequest, Transport};
use olaz_wire::util::as_dict_array;
use olaz_wire::{clean_group_id, is_group_id, strip_user_prefix};
use serde_json::{Map, Value, json};

use crate::api::{JsonObject, SendMessageResult, ZaloApi};
use crate::error::ApiError;
use crate::messaging::CallSpec;

const DEFAULT_CATALOG_URL: &str = "https://zalo-api.zadn.vn/api/emoticon/pcweb/getAllCate";
const BUILTIN_PACK_NAME: &str = "Củ hành";
const BUILTIN_PACK_ICON: &str = "https://stc-chat.zdn.vn/images/stickers/default/thumb/1.png";
const BUILTIN_PACK_TOTAL: i64 = 30;
const CATALOG_TIMEOUT: Duration = Duration::from_secs(20);

/// One sticker category pack entry returned by [`ZaloApi::fetch_sticker_categories`].
#[derive(Clone, PartialEq, Eq)]
pub struct StickerCategoryRow {
    pub id: i64,
    pub name: String,
    pub icon_url: String,
    pub total: i64,
}

impl fmt::Debug for StickerCategoryRow {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StickerCategoryRow")
            .field("id", &self.id)
            .field("has_name", &!self.name.is_empty())
            .field("has_icon", &!self.icon_url.is_empty())
            .field("total", &self.total)
            .finish()
    }
}

/// Result of [`ZaloApi::fetch_sticker_categories`]: the built-in pack followed by any valid
/// downloaded packs, plus `downloaded_count` so callers can apply the `>= 5` cache threshold.
#[derive(Clone, PartialEq, Eq)]
pub struct FetchedStickerCategories {
    pub packs: Vec<StickerCategoryRow>,
    pub downloaded_count: usize,
}

impl fmt::Debug for FetchedStickerCategories {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FetchedStickerCategories")
            .field("packs_count", &self.packs.len())
            .field("downloaded_count", &self.downloaded_count)
            .finish()
    }
}

/// Parameters for [`ZaloApi::send_sticker`] (Swift `sendStickerAPI`).
///
/// `Debug` is shape-only (ADR-008).
#[derive(Clone, PartialEq, Eq)]
pub struct SendStickerParams {
    pub conv_id: String,
    pub cate_id: i64,
    pub sticker_id: i64,
    pub sticker_type: i64,
    /// Client id; when `None`, [`ZaloApi::send_sticker`] allocates a fresh `next_client_id`.
    pub client_id: Option<i64>,
}

impl fmt::Debug for SendStickerParams {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SendStickerParams")
            .field("is_group", &is_group_id(&self.conv_id))
            .field("cate_id", &self.cate_id)
            .field("sticker_id", &self.sticker_id)
            .field("sticker_type", &self.sticker_type)
            .field("has_client_id", &self.client_id.is_some())
            .finish()
    }
}

/// The built-in "Củ hành" sticker pack (`id == 0`, 30 stickers).
#[must_use]
pub fn builtin_sticker_pack() -> StickerCategoryRow {
    StickerCategoryRow {
        id: 0,
        name: BUILTIN_PACK_NAME.to_owned(),
        icon_url: BUILTIN_PACK_ICON.to_owned(),
        total: BUILTIN_PACK_TOTAL,
    }
}

/// Upgrades `http://` catalog URLs to `https://` except for loopback test servers.
fn normalize_catalog_url(raw: &str) -> String {
    if raw.is_empty() {
        return DEFAULT_CATALOG_URL.to_owned();
    }
    if raw.starts_with("http://127.0.0.1:")
        || raw.starts_with("http://localhost:")
        || raw.starts_with("http://[::1]:")
    {
        return raw.to_owned();
    }
    raw.replace("http://", "https://")
}

/// Pure request builder for Swift `sendStickerAPI`.
#[must_use]
pub fn build_send_sticker_request(
    conv_id: &str,
    cate_id: i64,
    sticker_id: i64,
    sticker_type: i64,
    client_id: i64,
    imei: &str,
) -> CallSpec {
    let is_group = is_group_id(conv_id);
    let clean_id = if is_group {
        clean_group_id(conv_id)
    } else {
        strip_user_prefix(conv_id)
    };
    let mut payload = Map::new();
    payload.insert("stickerId".to_owned(), Value::from(sticker_id));
    payload.insert("cateId".to_owned(), Value::from(cate_id));
    payload.insert("type".to_owned(), Value::from(sticker_type));
    payload.insert("clientId".to_owned(), Value::from(client_id));
    payload.insert("zsource".to_owned(), Value::from(101_i64));
    payload.insert("imei".to_owned(), Value::from(imei));
    payload.insert("ttl".to_owned(), Value::from(0_i64));
    let (service, path) = if is_group {
        payload.insert("grid".to_owned(), Value::from(clean_id));
        ("group", "/api/group/sticker")
    } else {
        payload.insert("toid".to_owned(), Value::from(clean_id));
        ("chat", "/api/message/sticker")
    };
    CallSpec {
        service: service.to_owned(),
        path: path.to_owned(),
        payload: Value::Object(payload),
    }
}

/// Parses and filters the raw catalog JSON bytes (inflating gzip if `0x1F 0x8B`).
#[must_use]
pub fn parse_sticker_catalog_bytes(
    raw_bytes: &[u8],
    excluded_ids: &BTreeSet<i64>,
) -> Vec<StickerCategoryRow> {
    let inflated;
    let plain_bytes: &[u8] = if raw_bytes.len() >= 2 && raw_bytes[0] == 0x1F && raw_bytes[1] == 0x8B
    {
        if let Ok(buf) = inflate_zlib_or_gzip(raw_bytes) {
            inflated = buf;
            &inflated
        } else {
            raw_bytes
        }
    } else {
        raw_bytes
    };

    let Ok(Value::Array(arr)) = serde_json::from_slice::<Value>(plain_bytes) else {
        return Vec::new();
    };
    let mut downloaded = Vec::new();
    for item in arr {
        let Some(obj) = item.as_object() else {
            continue;
        };
        let Some(id) = int64(obj.get("id")) else {
            continue;
        };
        if id <= 0 || excluded_ids.contains(&id) {
            continue;
        }
        let name = string(obj.get("name")).trim().to_owned();
        if name.is_empty() || name.to_lowercase().contains("test") {
            continue;
        }
        let icon_url = string(
            obj.get("iconUrl")
                .or_else(|| obj.get("thumbImg"))
                .or_else(|| obj.get("icon")),
        )
        .replace("http://", "https://");
        let total = int64(obj.get("totalImage").or_else(|| obj.get("total"))).unwrap_or(16);
        downloaded.push(StickerCategoryRow {
            id,
            name,
            icon_url,
            total,
        });
    }
    downloaded.sort_by_key(|a| std::cmp::Reverse(a.id));
    downloaded
}

fn clone_dict_array(value: Option<&Value>) -> Option<Vec<JsonObject>> {
    as_dict_array(value).map(|v| v.into_iter().cloned().collect())
}

impl<T: Transport> ZaloApi<T> {
    /// Swift `fetchStickerCategories` (minus the session cache, which lives in `olaz-core`).
    pub async fn fetch_sticker_categories(&self) -> Result<FetchedStickerCategories, ApiError> {
        let resp = self
            .get(
                ApiRequest::new("sticker", "/api/message/sticker/category/list/v2")
                    .raw_encrypted(""),
            )
            .await?;
        let d = resp.get("data").and_then(Value::as_object);
        let ex_ids: BTreeSet<i64> = d
            .and_then(|d| d.get("exCateIds"))
            .and_then(Value::as_array)
            .map(|arr| arr.iter().filter_map(|v| int64(Some(v))).collect())
            .unwrap_or_default();
        let data_url = d.map_or_else(String::new, |d| string(d.get("dataUrl")));
        let catalog_url = normalize_catalog_url(&data_url);

        let mut packs = vec![builtin_sticker_pack()];
        let mut downloaded_count = 0usize;
        if let Ok(raw_bytes) = self
            .client()
            .raw_download_data(&catalog_url, CATALOG_TIMEOUT)
            .await
        {
            let downloaded = parse_sticker_catalog_bytes(&raw_bytes, &ex_ids);
            downloaded_count = downloaded.len();
            packs.extend(downloaded);
        }
        Ok(FetchedStickerCategories {
            packs,
            downloaded_count,
        })
    }

    /// Swift `fetchStickerCategoryDetail`: returns the raw sticker row objects (synthesizing the
    /// 30 built-in "Củ hành" rows when `cate_id == 0`).
    pub async fn fetch_sticker_category_detail(
        &self,
        cate_id: i64,
    ) -> Result<Vec<JsonObject>, ApiError> {
        if cate_id == 0 {
            let rows = (1..=30_i64)
                .map(|sid| {
                    let mut m = Map::new();
                    m.insert("id".to_owned(), Value::from(sid));
                    m.insert("cateId".to_owned(), Value::from(0_i64));
                    m.insert("type".to_owned(), Value::from(7_i64));
                    m.insert(
                        "stickerUrl".to_owned(),
                        Value::from(format!(
                            "https://stc-chat.zdn.vn/images/stickers/default/thumb/{sid}.png"
                        )),
                    );
                    m
                })
                .collect();
            return Ok(rows);
        }
        let resp = self
            .get(
                ApiRequest::new("sticker", "/api/message/sticker/category/sticker_detail")
                    .payload(json!({ "cid": cate_id.to_string() })),
            )
            .await?;
        let data = resp.get("data");
        if let Some(direct) = clone_dict_array(data) {
            return Ok(direct);
        }
        if let Some(node) = data.and_then(Value::as_object) {
            if let Some(stickers) = clone_dict_array(node.get("stickers")) {
                return Ok(stickers);
            }
            let key = cate_id.to_string();
            if let Some(nested) = node
                .get(&key)
                .and_then(Value::as_object)
                .and_then(|sub| clone_dict_array(sub.get("stickers")))
            {
                return Ok(nested);
            }
        }
        Ok(Vec::new())
    }

    /// Swift `searchStickersAPI`.
    pub async fn search_stickers(
        &self,
        keyword: &str,
        limit: i64,
    ) -> Result<Vec<JsonObject>, ApiError> {
        let resp = self
            .get(
                ApiRequest::new("sticker", "/api/message/sticker/search").payload(json!({
                    "keyword": keyword,
                    "limit": limit,
                    "srcType": 0,
                    "imei": self.imei(),
                })),
            )
            .await?;
        let data = resp.get("data");
        if let Some(direct) = clone_dict_array(data) {
            return Ok(direct);
        }
        Ok(data
            .and_then(Value::as_object)
            .and_then(|d| clone_dict_array(d.get("stickers")))
            .unwrap_or_default())
    }

    /// Swift `suggestStickersAPI`.
    pub async fn suggest_stickers(&self, keyword: &str) -> Result<Vec<JsonObject>, ApiError> {
        let resp = self
            .get(
                ApiRequest::new("sticker", "/api/message/sticker/suggest/stickers").payload(
                    json!({
                        "keyword": keyword,
                        "gif": 1,
                        "guggy": 0,
                        "imei": self.imei(),
                    }),
                ),
            )
            .await?;
        let data = resp.get("data");
        if let Some(d) = data.and_then(Value::as_object) {
            if let Some(sugg) = clone_dict_array(d.get("sugg_sticker"))
                && !sugg.is_empty()
            {
                return Ok(sugg);
            }
            if let Some(stickers) = clone_dict_array(d.get("stickers")) {
                return Ok(stickers);
            }
            return Ok(Vec::new());
        }
        Ok(clone_dict_array(data).unwrap_or_default())
    }

    /// Swift `sendStickerAPI`.
    pub async fn send_sticker(
        &self,
        params: &SendStickerParams,
    ) -> Result<SendMessageResult, ApiError> {
        let cli_id = params
            .client_id
            .unwrap_or_else(|| self.client().next_client_id());
        let cli_str = cli_id.to_string();
        let imei = self.imei();
        let spec = build_send_sticker_request(
            &params.conv_id,
            params.cate_id,
            params.sticker_id,
            params.sticker_type,
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

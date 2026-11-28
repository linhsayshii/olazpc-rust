//! Server Media Store list API for "Cloud của tôi" (`send2me_id`) and groups.
//!
//! Official Zalo PC 26.11.10 (`app.asar` ->
//! `pc-dist/lazy/default-login-main-startup-shared-worker-znotification.4bb5e1e2c2e9bab4f7b3.js`):
//! - `@2686084`: cmd `12220` -> `MEDIA_STORE_SEND2ME` `GET /api/media/oneone/list`;
//!   cmd `11841` -> `MEDIA_STORE` `GET /api/mediastore/list`.
//! - `@12413654`: `getMediaFromConversation(convId, mediaType, limit, lastId, lastFetchId)`:
//!   builds AES-CBC encrypted `params` JSON with `media_type` (`"media"` | `"file"` | `"link"`),
//!   optional `limit`, optional `last_id` (plus `group_id` + `imei` for group conversations).
//! - `@12054329`: `_handleGetGroupMediaResponse`: decrypts `data`, extracts
//!   `{ items, has_more, last_id }`.
//! - `@12055423`: `_mapMediaItemProperties`: maps `id`, `global_msg_id`, `client_msg_id`,
//!   `owner_id`, `created_time`, `type`, `sub_type`, `file_name`, `title`, `fileExt`,
//!   `file_size`, `src_url`, `thumb_url`, `width`, `height`, `duration`, `fType`.

use olaz_json::{bool_value, int64, string};
use olaz_net::{ApiRequest, Transport};
use olaz_wire::{
    ChatMessage, Kind, MessageMenu, Status, clean_group_id, normalized_file_name,
    optional_timestamp_ms, strip_user_prefix,
};
use serde_json::{Map, Value, json};

use crate::api::ZaloApi;
use crate::error::ApiError;

/// Server Media Store category (`media_type` query payload field).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum MediaStoreCategory {
    /// Photos, videos, and doodles (`sub_type`: 1=photo, 2=video, 3=doodle).
    Media,
    /// Uploaded files and folders (`fType`: 1=file, 2=folder).
    File,
    /// Shared URLs.
    Link,
}

impl MediaStoreCategory {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Media => "media",
            Self::File => "file",
            Self::Link => "link",
        }
    }
}

/// One decoded page from `/api/media/oneone/list` or `/api/mediastore/list`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MediaStorePage {
    pub items: Vec<ChatMessage>,
    pub has_more: bool,
    pub last_id: Option<String>,
}

/// Builds the authenticated GET request for `media_store_send2me` or `media_store`.
#[must_use]
pub fn build_media_store_list_request(
    conv_id: &str,
    is_self_cloud: bool,
    category: MediaStoreCategory,
    last_id: Option<&str>,
    limit: i64,
    imei: &str,
) -> ApiRequest {
    let mut payload = Map::new();
    payload.insert("media_type".to_owned(), json!(category.as_str()));
    let safe_limit = limit.max(1);
    payload.insert("limit".to_owned(), json!(safe_limit));
    if let Some(cursor) = last_id.map(str::trim).filter(|s| !s.is_empty()) {
        payload.insert("last_id".to_owned(), json!(cursor));
    }

    if is_self_cloud {
        ApiRequest::new("media_store_send2me", "/api/media/oneone/list")
            .payload(Value::Object(payload))
    } else {
        payload.insert("group_id".to_owned(), json!(clean_group_id(conv_id)));
        payload.insert("imei".to_owned(), json!(imei));
        ApiRequest::new("media_store", "/api/mediastore/list").payload(Value::Object(payload))
    }
}

fn non_empty(s: String) -> Option<String> {
    let trimmed = s.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

fn first_non_empty(candidates: &[&str]) -> String {
    for raw in candidates {
        let t = raw.trim();
        if !t.is_empty() {
            return t.to_owned();
        }
    }
    String::new()
}

fn extension_from_name(name: &str) -> String {
    let trimmed = name.trim().trim_end_matches('/');
    let file_name = trimmed.rsplit('/').next().unwrap_or(trimmed);
    match file_name.rfind('.') {
        Some(idx) if idx > 0 && idx + 1 < file_name.len() => file_name[idx + 1..].to_owned(),
        _ => String::new(),
    }
}

fn extract_domain(url: &str) -> String {
    let trimmed = url.trim();
    let rest = trimmed
        .split_once("://")
        .map_or(trimmed, |(_, after)| after);
    let host_port = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = host_port.split('@').next_back().unwrap_or(host_port);
    host.split(':').next().unwrap_or("").to_owned()
}

fn duration_seconds(raw: i64) -> i64 {
    if raw > 10_000 {
        raw / 1000
    } else {
        raw.max(0)
    }
}

/// Converts one raw Media Store item dict (`_mapMediaItemProperties` @12055423) into a
/// [`ChatMessage`] suitable for both zCloud (`CloudList` / `CloudFetch`) and Shared Media.
#[must_use]
pub fn media_store_item_to_chat_message(
    item: &Map<String, Value>,
    conv_id: &str,
    my_uid: &str,
    is_self_cloud: bool,
) -> Option<ChatMessage> {
    let global_id = string(item.get("global_msg_id"));
    let client_id = string(item.get("client_msg_id"));
    let record_id = string(item.get("id"));
    let msg_id = if !global_id.is_empty() && global_id != "0" {
        global_id
    } else if !client_id.is_empty() && client_id != "0" {
        client_id.clone()
    } else if !record_id.is_empty() && record_id != "0" {
        record_id
    } else {
        return None;
    };

    let clean_me = strip_user_prefix(my_uid);
    let raw_owner = strip_user_prefix(&string(item.get("owner_id")));
    let is_mine = is_self_cloud
        || raw_owner.is_empty()
        || raw_owner == "0"
        || (!clean_me.is_empty() && raw_owner == clean_me);
    let sender_id = if is_mine && (raw_owner.is_empty() || raw_owner == "0") {
        clean_me
    } else {
        raw_owner
    };
    let sender_name = if is_mine {
        "Bạn".to_owned()
    } else {
        String::new()
    };

    let date_ms = optional_timestamp_ms(item.get("created_time"));
    let src_url = first_non_empty(&[
        &string(item.get("src_url")),
        &string(item.get("href")),
        &string(item.get("oriUrl")),
    ]);
    let thumb_url = first_non_empty(&[
        &string(item.get("thumb_url")),
        &string(item.get("thumb")),
        &string(item.get("previewThumb")),
    ]);

    let item_type = string(item.get("type")).trim().to_ascii_lowercase();
    let mut fallback_urls = Vec::new();
    let (kind, text) = match item_type.as_str() {
        "file" => {
            let raw_file_name = string(item.get("file_name"));
            let raw_title = string(item.get("title"));
            let base_name = first_non_empty(&[&raw_file_name, &raw_title, "Tệp đính kèm"]);
            let explicit_ext = string(item.get("fileExt"));
            let raw_ext = if !explicit_ext.trim().is_empty() {
                explicit_ext
            } else {
                extension_from_name(&raw_title)
            };
            let file_name = normalized_file_name(&base_name, &raw_ext);
            let size = int64(item.get("file_size")).unwrap_or(0).max(0);
            let kind = Kind::File {
                name: file_name.clone(),
                size,
                url: non_empty(src_url),
            };
            (kind, file_name)
        }
        "media" => {
            let sub_type = int64(item.get("sub_type")).unwrap_or(1);
            if sub_type == 2 {
                let dur = duration_seconds(int64(item.get("duration")).unwrap_or(0));
                let kind = Kind::Video {
                    thumbnail: non_empty(thumb_url),
                    duration: dur,
                    url: non_empty(src_url),
                };
                let text = string(item.get("title"));
                (kind, text)
            } else {
                let width = int64(item.get("width")).unwrap_or(0).max(0);
                let height = int64(item.get("height")).unwrap_or(0).max(0);
                let primary = if !src_url.is_empty() {
                    if !thumb_url.is_empty() && thumb_url != src_url {
                        fallback_urls.push(thumb_url);
                    }
                    Some(src_url)
                } else {
                    non_empty(thumb_url)
                };
                let mut text = string(item.get("title"));
                if text == "[Hình ảnh]" {
                    text.clear();
                }
                let kind = Kind::Photo {
                    url: primary,
                    width,
                    height,
                };
                (kind, text)
            }
        }
        "link" => {
            if src_url.is_empty() {
                return None;
            }
            let title = first_non_empty(&[&string(item.get("title")), &src_url]);
            let source = extract_domain(&src_url);
            let kind = Kind::Link {
                title: title.clone(),
                url: Some(src_url),
                thumbnail: non_empty(thumb_url),
                description: String::new(),
                source,
            };
            (kind, title)
        }
        _ => return None,
    };

    Some(ChatMessage {
        id: msg_id,
        conversation_id: conv_id.to_owned(),
        sender_id,
        sender_name,
        sender_avatar: None,
        is_mine,
        kind,
        text,
        date_ms,
        status: Status::Sent,
        quote: None,
        reactions: Vec::new(),
        is_e2ee: false,
        mentions: Vec::new(),
        card_buttons: Vec::new(),
        suggests_stickers: false,
        menu: MessageMenu::default(),
        fallback_urls,
        client_id,
        text_styles: Vec::new(),
        ttl_ms: 0,
        urgency: 0,
    })
}

/// Pure parser matching official `_handleGetGroupMediaResponse` (`@12054329`).
#[must_use]
pub fn parse_media_store_list_response(
    resp: &Map<String, Value>,
    conv_id: &str,
    my_uid: &str,
    is_self_cloud: bool,
) -> MediaStorePage {
    let data = resp
        .get("data")
        .and_then(Value::as_object)
        .unwrap_or(resp);
    let has_more = bool_value(data.get("has_more")).unwrap_or(false);
    let last_id = non_empty(string(data.get("last_id")));
    let items = data
        .get("items")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_object)
                .filter_map(|obj| {
                    media_store_item_to_chat_message(obj, conv_id, my_uid, is_self_cloud)
                })
                .collect()
        })
        .unwrap_or_default();
    MediaStorePage {
        items,
        has_more,
        last_id,
    }
}

impl<T: Transport> ZaloApi<T> {
    /// Fetches one page of media/files/links from Zalo's server Media Store:
    /// - For "Cloud của tôi" (`is_self_cloud == true`): `media_store_send2me`
    ///   `GET /api/media/oneone/list` (cmd `12220`).
    /// - For group conversations (`is_self_cloud == false`): `media_store`
    ///   `GET /api/mediastore/list` (cmd `11841`).
    pub async fn fetch_media_store_list(
        &self,
        conv_id: &str,
        is_self_cloud: bool,
        category: MediaStoreCategory,
        last_id: Option<&str>,
        limit: i64,
    ) -> Result<MediaStorePage, ApiError> {
        let imei = self.imei();
        let my_uid = self
            .client()
            .account()
            .map(|a| a.user_id)
            .unwrap_or_default();
        let req = build_media_store_list_request(
            conv_id,
            is_self_cloud,
            category,
            last_id,
            limit,
            &imei,
        );
        let resp = self.get(req).await?;
        Ok(parse_media_store_list_response(
            &resp,
            conv_id,
            &my_uid,
            is_self_cloud,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use olaz_crypto::{decode_aes, encode_aes};
    use olaz_net::domains::ZaloDomains;
    use olaz_net::http::RawResponse;
    use olaz_net::mock::MockTransport;
    use olaz_net::session::{LoginAccount, SessionState};
    use olaz_net::SessionClient;

    const KEY: &[u8] = b"0123456789abcdef";

    fn make_api(transport: MockTransport) -> ZaloApi<MockTransport> {
        let mut state = SessionState::new("imei_test".to_owned(), "TestMac".to_owned());
        state.domains = ZaloDomains::default();
        state.update_credentials(
            LoginAccount {
                user_id: "2008001".to_owned(),
                display_name: "Tester".to_owned(),
                send2me_id: "92008001".to_owned(),
                zpw_enk: "0123456789abcdef".to_owned(),
                zpw_sek: "sek.1".to_owned(),
                ..LoginAccount::default()
            },
            KEY.to_vec(),
            "sek.1".to_owned(),
            Some(ZaloDomains::default()),
        );
        ZaloApi::new(SessionClient::with_state(transport, state))
    }

    fn encrypted_resp(val: &Value) -> RawResponse {
        let cipher = encode_aes(KEY, &serde_json::to_string(val).unwrap()).unwrap();
        RawResponse::new(
            200,
            serde_json::to_vec(&json!({ "error_code": 0, "data": cipher })).unwrap(),
        )
    }

    #[test]
    fn build_request_targets_send2me_and_group_services() {
        let self_req = build_media_store_list_request(
            "92008001",
            true,
            MediaStoreCategory::File,
            Some("ms_42"),
            50,
            "imei_x",
        );
        assert_eq!(self_req.service, "media_store_send2me");
        assert_eq!(self_req.path, "/api/media/oneone/list");
        assert_eq!(
            self_req.payload,
            Some(json!({
                "media_type": "file",
                "limit": 50,
                "last_id": "ms_42",
            }))
        );

        let group_req = build_media_store_list_request(
            "g500123",
            false,
            MediaStoreCategory::Media,
            None,
            30,
            "imei_x",
        );
        assert_eq!(group_req.service, "media_store");
        assert_eq!(group_req.path, "/api/mediastore/list");
        assert_eq!(
            group_req.payload,
            Some(json!({
                "media_type": "media",
                "limit": 30,
                "group_id": "500123",
                "imei": "imei_x",
            }))
        );
    }

    #[test]
    fn parse_media_store_items_covers_files_folders_photos_videos_and_links() {
        let resp = json!({
            "error_code": 0,
            "data": {
                "has_more": true,
                "last_id": "rec_5",
                "items": [
                    {
                        "id": "rec_1",
                        "global_msg_id": "1001",
                        "client_msg_id": "cli_1001",
                        "owner_id": "2008001",
                        "created_time": "1700000100",
                        "type": "file",
                        "file_name": "BaoCao",
                        "title": "BaoCao.pdf",
                        "file_size": "512000",
                        "fileExt": "pdf",
                        "fType": 1,
                        "src_url": "https://cdn.example.invalid/f/BaoCao.pdf"
                    },
                    {
                        "id": "rec_2",
                        "global_msg_id": "1002",
                        "client_msg_id": "cli_1002",
                        "owner_id": "0",
                        "created_time": 1_700_000_200_000_i64,
                        "type": "file",
                        "file_name": "ProjectFolder.zip",
                        "title": "ProjectFolder.zip",
                        "file_size": 2048,
                        "fType": 2,
                        "src_url": "https://cdn.example.invalid/f/ProjectFolder.zip"
                    },
                    {
                        "id": "rec_3",
                        "global_msg_id": "1003",
                        "client_msg_id": "cli_1003",
                        "owner_id": "2008001",
                        "created_time": 1_700_000_300_000_i64,
                        "type": "media",
                        "sub_type": 1,
                        "width": 1200,
                        "height": 900,
                        "src_url": "https://cdn.example.invalid/p/1003.jpg",
                        "thumb_url": "https://cdn.example.invalid/p/1003_thumb.jpg"
                    },
                    {
                        "id": "rec_4",
                        "global_msg_id": "1004",
                        "client_msg_id": "cli_1004",
                        "owner_id": "2008001",
                        "created_time": 1_700_000_400_000_i64,
                        "type": "media",
                        "sub_type": 2,
                        "duration": 15000,
                        "src_url": "https://cdn.example.invalid/v/1004.mp4",
                        "thumb_url": "https://cdn.example.invalid/v/1004_thumb.jpg"
                    },
                    {
                        "id": "rec_5",
                        "global_msg_id": "1005",
                        "client_msg_id": "cli_1005",
                        "owner_id": "2008001",
                        "created_time": 1_700_000_500_000_i64,
                        "type": "link",
                        "title": "Docs",
                        "src_url": "https://docs.example.invalid/guide",
                        "thumb_url": "https://docs.example.invalid/og.png"
                    },
                    {
                        "id": "rec_bad_link",
                        "global_msg_id": "1006",
                        "type": "link",
                        "title": "No URL"
                    }
                ]
            }
        });

        let page = parse_media_store_list_response(
            resp.as_object().unwrap(),
            "92008001",
            "2008001",
            true,
        );
        assert!(page.has_more);
        assert_eq!(page.last_id.as_deref(), Some("rec_5"));
        assert_eq!(page.items.len(), 5);

        // File 1: string created_time in seconds -> ms, string file_size, normalized name
        assert_eq!(page.items[0].id, "1001");
        assert_eq!(page.items[0].date_ms, 1_700_000_100_000);
        assert_eq!(
            page.items[0].kind,
            Kind::File {
                name: "BaoCao.pdf".to_owned(),
                size: 512_000,
                url: Some("https://cdn.example.invalid/f/BaoCao.pdf".to_owned()),
            }
        );

        // File 2: folder (fType 2), already has .zip extension
        assert_eq!(page.items[1].id, "1002");
        assert_eq!(
            page.items[1].kind,
            Kind::File {
                name: "ProjectFolder.zip".to_owned(),
                size: 2048,
                url: Some("https://cdn.example.invalid/f/ProjectFolder.zip".to_owned()),
            }
        );

        // Photo: thumb becomes fallback URL
        assert_eq!(
            page.items[2].kind,
            Kind::Photo {
                url: Some("https://cdn.example.invalid/p/1003.jpg".to_owned()),
                width: 1200,
                height: 900,
            }
        );
        assert_eq!(
            page.items[2].fallback_urls,
            vec!["https://cdn.example.invalid/p/1003_thumb.jpg".to_owned()]
        );

        // Video: duration 15000ms -> 15s
        assert_eq!(
            page.items[3].kind,
            Kind::Video {
                thumbnail: Some("https://cdn.example.invalid/v/1004_thumb.jpg".to_owned()),
                duration: 15,
                url: Some("https://cdn.example.invalid/v/1004.mp4".to_owned()),
            }
        );

        // Link: extracts domain into source
        assert_eq!(
            page.items[4].kind,
            Kind::Link {
                title: "Docs".to_owned(),
                url: Some("https://docs.example.invalid/guide".to_owned()),
                thumbnail: Some("https://docs.example.invalid/og.png".to_owned()),
                description: String::new(),
                source: "docs.example.invalid".to_owned(),
            }
        );
    }

    #[tokio::test]
    async fn fetch_media_store_list_encrypts_params_and_decrypts_response() {
        let transport = MockTransport::from_fn(|req| {
            assert!(req.url.contains("mediasend2me-wpa.zaloapp.com/api/media/oneone/list"));
            let q = req.url.split_once('?').unwrap().1;
            let raw_p = q
                .split('&')
                .find_map(|kv| kv.strip_prefix("params="))
                .unwrap();
            let unescaped = raw_p
                .replace("%2B", "+")
                .replace("%2F", "/")
                .replace("%3D", "=");
            let plain = decode_aes(KEY, &unescaped).unwrap();
            let v: Value = serde_json::from_str(&plain).unwrap();
            assert_eq!(v["media_type"], "file");
            assert_eq!(v["limit"], 40);
            assert_eq!(v["last_id"], "cur_1");

            Ok(encrypted_resp(&json!({
                "error_code": 0,
                "data": {
                    "has_more": false,
                    "last_id": "cur_2",
                    "items": [{
                        "id": "cur_2",
                        "global_msg_id": "88001",
                        "client_msg_id": "cli_88001",
                        "owner_id": "2008001",
                        "created_time": 1_700_000_600_000_i64,
                        "type": "file",
                        "file_name": "Invoice.docx",
                        "file_size": 12_345,
                        "src_url": "https://cdn.example.invalid/Invoice.docx"
                    }]
                }
            })))
        });

        let api = make_api(transport);
        let page = api
            .fetch_media_store_list("92008001", true, MediaStoreCategory::File, Some("cur_1"), 40)
            .await
            .unwrap();
        assert!(!page.has_more);
        assert_eq!(page.last_id.as_deref(), Some("cur_2"));
        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].id, "88001");
    }
}

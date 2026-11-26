//! Contacts, friend requests, phone search, blocked users, and friend aliases
//! (`ZaloAPIService.swift` + `ZaloAPIService+Block.swift`, U9).

use std::fmt;

use olaz_json::{bool_value, int64, string};
use olaz_net::{ApiRequest, Transport};
use olaz_wire::strip_user_prefix;
use olaz_wire::util::as_dict_array;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::api::{JsonObject, ZaloApi};
use crate::error::ApiError;
use crate::util::data_object;

/// One blocked account row returned by `/api/friend/blocklistv2` (`BlockedUser`).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BlockedUserEntry {
    pub id: String,
    pub name: String,
    pub avatar: Option<String>,
}

impl fmt::Debug for BlockedUserEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BlockedUserEntry")
            .field("has_avatar", &self.avatar.is_some())
            .finish()
    }
}

/// Normalizes a phone string for `/api/friend/profile/get` (`ZaloSessionClient.normalizePhoneForLookup`):
/// keeps ASCII digits, replacing a leading `0` with `84`.
#[must_use]
pub fn normalize_phone_for_lookup(raw: &str) -> String {
    let digits: String = raw.chars().filter(char::is_ascii_digit).collect();
    if let Some(rest) = digits.strip_prefix('0') {
        format!("84{rest}")
    } else {
        digits
    }
}

/// Builds the `/api/friend/profile/get` payload (`ZaloSessionClient.searchFriendByPhone`).
#[must_use]
pub fn build_search_friend_by_phone_payload(phone: &str, imei: &str) -> Value {
    let normalized = normalize_phone_for_lookup(phone);
    json!({
        "phone": if normalized.is_empty() { phone } else { normalized.as_str() },
        "avatar_size": 240,
        "language": "vi",
        "imei": imei,
        "reqSrc": 40,
    })
}

/// Builds the `/api/friend/sendreq` payload (`ZaloSessionClient.sendFriendRequestAPI`).
#[must_use]
pub fn build_send_friend_request_payload(to_uid: &str, message: &str, imei: &str) -> Value {
    json!({
        "toid": strip_user_prefix(to_uid),
        "msg": message,
        "reqsrc": 30,
        "imei": imei,
        "language": "vi",
    })
}

/// Builds the `/api/friend/accept` payload (`ZaloSessionClient.acceptFriendRequestAPI`).
#[must_use]
pub fn build_accept_friend_request_payload(uid: &str, imei: &str) -> Value {
    json!({
        "fid": strip_user_prefix(uid),
        "language": "vi",
        "imei": imei,
    })
}

/// Builds the `/api/friend/reject` or `/api/friend/undo` or `/api/friend/block` or `/api/friend/unblock`
/// `{fid, imei}` payload.
#[must_use]
pub fn build_fid_imei_payload(uid: &str, imei: &str) -> Value {
    json!({
        "fid": strip_user_prefix(uid),
        "imei": imei,
    })
}

/// Builds the `(path, payload)` pair for `ZaloSessionClient.setAliasAPI`.
#[must_use]
pub fn build_set_alias_request(uid: &str, alias: &str, imei: &str) -> (&'static str, Value) {
    let clean_uid = strip_user_prefix(uid);
    let trimmed = alias.trim();
    if trimmed.is_empty() {
        ("/api/alias/remove", json!({ "friendId": clean_uid }))
    } else {
        (
            "/api/alias/update",
            json!({
                "friendId": clean_uid,
                "alias": trimmed,
                "imei": imei,
            }),
        )
    }
}

/// Parses one `/api/friend/blocklistv2` page (`BlockedUser.page(from:)`).
#[must_use]
pub fn parse_blocked_users_page(data: &JsonObject) -> (Vec<BlockedUserEntry>, bool) {
    let rows = as_dict_array(data.get("profiles")).unwrap_or_default();
    let mut users = Vec::with_capacity(rows.len());
    for row in rows {
        let id = strip_user_prefix(&string(row.get("userId").or_else(|| row.get("uid"))));
        if id.is_empty() || id == "0" {
            continue;
        }
        let disp = string(row.get("displayName"));
        let zalo = string(row.get("zaloName"));
        let name = if !disp.is_empty() { disp } else { zalo };
        let avt = string(row.get("avatar"));
        let avatar = if !avt.is_empty()
            && (avt.starts_with("http://") || avt.starts_with("https://"))
            && !avt.chars().any(char::is_whitespace)
        {
            Some(avt)
        } else {
            None
        };
        users.push(BlockedUserEntry { id, name, avatar });
    }
    let has_more =
        int64(data.get("has_more")) == Some(1) || bool_value(data.get("has_more")) == Some(true);
    (users, has_more)
}

impl<T: Transport> ZaloApi<T> {
    /// Swift `searchFriendByPhone`: `GET friend /api/friend/profile/get`.
    pub async fn search_friend_by_phone(&self, phone: &str) -> Result<JsonObject, ApiError> {
        let imei = self.client().imei().to_owned();
        self.get(
            ApiRequest::new("friend", "/api/friend/profile/get")
                .payload(build_search_friend_by_phone_payload(phone, &imei)),
        )
        .await
    }

    /// Swift `sendFriendRequestAPI`: `POST friend /api/friend/sendreq`.
    pub async fn send_friend_request(
        &self,
        to_uid: &str,
        message: &str,
    ) -> Result<JsonObject, ApiError> {
        let imei = self.client().imei().to_owned();
        self.post(
            ApiRequest::new("friend", "/api/friend/sendreq")
                .payload(build_send_friend_request_payload(to_uid, message, &imei)),
        )
        .await
    }

    /// Swift `acceptFriendRequestAPI`: `POST friend /api/friend/accept`.
    pub async fn accept_friend_request(&self, uid: &str) -> Result<JsonObject, ApiError> {
        let imei = self.client().imei().to_owned();
        self.post(
            ApiRequest::new("friend", "/api/friend/accept")
                .payload(build_accept_friend_request_payload(uid, &imei)),
        )
        .await
    }

    /// Swift `rejectFriendRequestAPI`: `POST friend /api/friend/reject`.
    pub async fn reject_friend_request(&self, uid: &str) -> Result<JsonObject, ApiError> {
        let imei = self.client().imei().to_owned();
        self.post(
            ApiRequest::new("friend", "/api/friend/reject")
                .payload(build_fid_imei_payload(uid, &imei)),
        )
        .await
    }

    /// Swift `cancelFriendRequestAPI`: `POST friend /api/friend/undo`.
    pub async fn cancel_friend_request(&self, uid: &str) -> Result<JsonObject, ApiError> {
        let imei = self.client().imei().to_owned();
        self.post(
            ApiRequest::new("friend", "/api/friend/undo")
                .payload(build_fid_imei_payload(uid, &imei)),
        )
        .await
    }

    /// Swift `setAliasAPI`: `GET alias /api/alias/update` or `/api/alias/remove`.
    pub async fn set_alias(&self, uid: &str, alias: &str) -> Result<JsonObject, ApiError> {
        let imei = self.client().imei().to_owned();
        let (path, payload) = build_set_alias_request(uid, alias, &imei);
        self.get(ApiRequest::new("alias", path).payload(payload))
            .await
    }

    /// Swift `fetchBlockedUsersAPI`: up to 20 pages of `GET friend /api/friend/blocklistv2`.
    pub async fn fetch_blocked_users(&self) -> Result<Vec<BlockedUserEntry>, ApiError> {
        let mut all = Vec::new();
        for page in 1..=20 {
            let resp = self
                .get(
                    ApiRequest::new("friend", "/api/friend/blocklistv2").payload(json!({
                        "page": page,
                        "count": 50,
                        "avatar": 75,
                    })),
                )
                .await?;
            let data = data_object(&resp);
            let (users, has_more) = parse_blocked_users_page(&data);
            let page_non_empty = !users.is_empty();
            all.extend(users);
            if !has_more || !page_non_empty {
                break;
            }
        }
        Ok(all)
    }

    /// Swift `setBlockedAPI`: `POST friend /api/friend/block` or `/api/friend/unblock`.
    pub async fn set_blocked(&self, uid: &str, blocked: bool) -> Result<(), ApiError> {
        let imei = self.client().imei().to_owned();
        let path = if blocked {
            "/api/friend/block"
        } else {
            "/api/friend/unblock"
        };
        self.post(ApiRequest::new("friend", path).payload(build_fid_imei_payload(uid, &imei)))
            .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use olaz_crypto::{decode_aes, percent_decode};
    use olaz_json::parse_any;
    use olaz_net::http::{RawResponse, RequestSpec};
    use olaz_net::mock::MockTransport;
    use olaz_net::{LoginAccount, NetError, SessionClient, ZaloDomains};

    use super::*;

    const KEY: &[u8; 16] = b"0123456789abcdef";

    fn api_with(
        handler: impl FnMut(&RequestSpec) -> Result<RawResponse, NetError> + Send + 'static,
    ) -> ZaloApi<MockTransport> {
        let client = SessionClient::new(
            MockTransport::from_fn(handler),
            "imei-u9".to_owned(),
            "Mac".to_owned(),
        );
        client.update_credentials(
            LoginAccount {
                user_id: "200".to_owned(),
                send2me_id: "9200".to_owned(),
                ..LoginAccount::default()
            },
            KEY.to_vec(),
            "sek.1.2".to_owned(),
            Some(ZaloDomains::default()),
        );
        ZaloApi::new(client)
    }

    fn params_of(req: &RequestSpec) -> Value {
        let enc = match req.query_value("params") {
            Some(p) => p.to_owned(),
            None => {
                let body = String::from_utf8(req.body.clone().unwrap_or_default()).unwrap();
                percent_decode(body.strip_prefix("params=").unwrap())
            }
        };
        let plain = decode_aes(KEY, &enc).unwrap();
        parse_any(plain.as_bytes()).unwrap()
    }

    #[test]
    fn phone_normalization_and_alias_builders_match_swift() {
        assert_eq!(normalize_phone_for_lookup(" 090 123-4567 "), "84901234567");
        assert_eq!(normalize_phone_for_lookup("+84 901 234 567"), "84901234567");
        assert_eq!(normalize_phone_for_lookup("abc"), "");

        assert_eq!(
            build_search_friend_by_phone_payload("0901234567", "imei-1"),
            json!({
                "phone": "84901234567",
                "avatar_size": 240,
                "language": "vi",
                "imei": "imei-1",
                "reqSrc": 40,
            })
        );
        assert_eq!(
            build_set_alias_request(" 3001 ", "  Bí danh  ", "imei-1"),
            (
                "/api/alias/update",
                json!({"friendId": "3001", "alias": "Bí danh", "imei": "imei-1"}),
            )
        );
        assert_eq!(
            build_set_alias_request("3001", "   ", "imei-1"),
            ("/api/alias/remove", json!({"friendId": "3001"}))
        );
    }

    #[tokio::test]
    async fn blocklist_pagination_and_friend_requests_endpoints() {
        let api = api_with(|req| match req.path().as_str() {
            "/api/friend/blocklistv2" => {
                let p = params_of(req)["page"].as_i64().unwrap_or(1);
                let body = if p == 1 {
                    json!({
                        "error_code": 0,
                        "data": {
                            "profiles": [
                                {"userId": "u3001", "displayName": "One", "avatar": "https://cdn.example.invalid/1.jpg"},
                                {"userId": "0", "displayName": "Skip"},
                            ],
                            "has_more": 1
                        }
                    })
                } else {
                    json!({
                        "error_code": 0,
                        "data": {
                            "profiles": [
                                {"uid": "3002", "zaloName": "Two", "avatar": ""}
                            ],
                            "has_more": false
                        }
                    })
                };
                Ok(RawResponse::new(200, body.to_string().into_bytes()))
            }
            "/api/friend/block"
            | "/api/friend/unblock"
            | "/api/friend/sendreq"
            | "/api/friend/accept"
            | "/api/friend/reject"
            | "/api/friend/undo"
            | "/api/alias/update"
            | "/api/alias/remove"
            | "/api/friend/profile/get" => Ok(RawResponse::new(
                200,
                json!({"error_code": 0, "data": {}})
                    .to_string()
                    .into_bytes(),
            )),
            _ => Ok(RawResponse::new(404, b"{}".to_vec())),
        });

        let blocked = api.fetch_blocked_users().await.unwrap();
        assert_eq!(blocked.len(), 2);
        assert_eq!(blocked[0].id, "u3001");
        assert_eq!(blocked[0].name, "One");
        assert_eq!(blocked[1].id, "3002");
        assert_eq!(blocked[1].name, "Two");
        assert_eq!(blocked[1].avatar, None);

        api.set_blocked("3001", true).await.unwrap();
        api.set_blocked("3001", false).await.unwrap();
        let _ = api.send_friend_request("3003", "Xin chào").await.unwrap();
        let _ = api.accept_friend_request("3004").await.unwrap();
        let _ = api.reject_friend_request("3005").await.unwrap();
        let _ = api.cancel_friend_request("3006").await.unwrap();
        let _ = api.set_alias("3001", "Alias").await.unwrap();
        let _ = api.set_alias("3001", "").await.unwrap();
        let _ = api.search_friend_by_phone("0901234567").await.unwrap();
    }
}

//! Group management & administration API helpers (ports `ZaloAPIService.createGroupAPI`,
//! `ZaloAPIService+GroupMgmt.swift`, and `ZaloAPIService+GroupAdmin.swift`), shared between U12
//! (polls) and U10 (groups).

use std::collections::HashSet;
use std::fmt;

use olaz_net::{ApiRequest, MultipartPart, NetError, Transport};
use olaz_wire::{clean_group_id, lossless, strip_user_prefix};
use serde_json::{Map, Value, json};

use crate::api::{JsonObject, ZaloApi};
use crate::error::ApiError;
use crate::messaging::CallSpec;
use crate::util::swift_json;

/// Multipart upload specification for `POST /api/group/upavatar` (`GroupAvatarUploadSpec`).
#[derive(Debug, Clone, PartialEq)]
pub struct GroupAvatarUploadSpec {
    pub service: String,
    pub path: String,
    pub encrypted_payload: Value,
    pub field_name: String,
    pub file_name: String,
    pub mime_type: String,
}

/// One pending join request returned by `/api/group/pending-mems/list` (`GroupPendingMember`).
#[derive(Clone, PartialEq, Eq)]
pub struct GroupPendingMember {
    pub id: String,
    pub name: String,
    pub avatar: Option<String>,
}

impl fmt::Debug for GroupPendingMember {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupPendingMember")
            .field("has_id", &!self.id.is_empty())
            .field("has_name", &!self.name.is_empty())
            .field("has_avatar", &self.avatar.is_some())
            .finish()
    }
}

/// Group join link returned by `/api/group/link/detail` and `/api/group/link/new` (`GroupLink`).
#[derive(Clone, Default, PartialEq, Eq)]
pub struct GroupLink {
    pub link: String,
    pub enabled: bool,
}

impl fmt::Debug for GroupLink {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupLink")
            .field("has_link", &!self.link.is_empty())
            .field("enabled", &self.enabled)
            .finish()
    }
}

/// Port of `ZaloSessionClient.cleanGroupMemberIds(_:)`: trims whitespace, strips a leading `'u'`
/// before ASCII digits, drops empty/`"0"`, and deduplicates while preserving first-seen order.
#[must_use]
pub fn clean_group_member_ids(member_ids: &[String]) -> Vec<String> {
    let mut seen = HashSet::with_capacity(member_ids.len());
    let mut out = Vec::with_capacity(member_ids.len());
    for raw in member_ids {
        let trimmed = strip_user_prefix(raw);
        let clean = match trimmed.strip_prefix('u') {
            Some(rest) if !rest.is_empty() && rest.bytes().all(|b| b.is_ascii_digit()) => {
                rest.to_owned()
            }
            _ => trimmed,
        };
        if clean.is_empty() || clean == "0" || !seen.insert(clean.clone()) {
            continue;
        }
        out.push(clean);
    }
    out
}

/// Pure request builder for `ZaloSessionClient.createGroupAPI(name:members:)`:
/// `GET /api/group/create/v2` on `"group"`.
#[must_use]
pub fn build_create_group_request(
    name: &str,
    members: &[String],
    client_id: i64,
    imei: &str,
) -> CallSpec {
    let clean_members: Vec<String> = members
        .iter()
        .map(|m| strip_user_prefix(m))
        .filter(|m| !m.is_empty())
        .collect();
    CallSpec {
        service: "group".to_owned(),
        path: "/api/group/create/v2".to_owned(),
        payload: json!({
            "clientId": client_id,
            "gname": name,
            "gdesc": Value::Null,
            "members": clean_members,
            "nameChanged": 1,
            "createLink": 1,
            "clientLang": "vi",
            "imei": imei,
            "groupType": Value::Null,
        }),
    }
}

/// Pure request builder for `ZaloSessionClient.buildUploadGroupAvatarRequest`.
#[must_use]
pub fn build_upload_group_avatar_request(
    group_id: &str,
    side: i64,
    client_id: i64,
    imei: &str,
) -> Option<GroupAvatarUploadSpec> {
    let clean_grid = clean_group_id(group_id);
    if clean_grid.is_empty() || clean_grid == "0" || side <= 0 {
        return None;
    }
    Some(GroupAvatarUploadSpec {
        service: "file".to_owned(),
        path: "/api/group/upavatar".to_owned(),
        encrypted_payload: json!({
            "grid": clean_grid,
            "avatarSize": side,
            "clientId": client_id,
            "originWidth": side,
            "originHeight": side,
            "imei": imei,
        }),
        field_name: "fileContent".to_owned(),
        file_name: "avatar.jpg".to_owned(),
        mime_type: "image/jpeg".to_owned(),
    })
}

/// Pure request builder for `ZaloSessionClient.buildRenameGroupRequest`.
#[must_use]
pub fn build_rename_group_request(group_id: &str, name: &str, imei: &str) -> Option<CallSpec> {
    let clean_grid = clean_group_id(group_id);
    if clean_grid.is_empty() || clean_grid == "0" {
        return None;
    }
    Some(CallSpec {
        service: "group".to_owned(),
        path: "/api/group/updateinfo".to_owned(),
        payload: json!({
            "grid": clean_grid,
            "gname": name,
            "imei": imei,
        }),
    })
}

/// Pure request builder for `ZaloSessionClient.buildInviteGroupMembersRequest`.
#[must_use]
pub fn build_invite_group_members_request(
    group_id: &str,
    member_ids: &[String],
    imei: &str,
) -> Option<CallSpec> {
    let clean_grid = clean_group_id(group_id);
    let clean_ids = clean_group_member_ids(member_ids);
    if clean_grid.is_empty() || clean_grid == "0" || clean_ids.is_empty() {
        return None;
    }
    let member_types = vec![-1_i64; clean_ids.len()];
    Some(CallSpec {
        service: "group".to_owned(),
        path: "/api/group/invite/v2".to_owned(),
        payload: json!({
            "grid": clean_grid,
            "members": clean_ids,
            "memberTypes": member_types,
            "imei": imei,
            "clientLang": "vi",
        }),
    })
}

/// Pure request builder for `ZaloSessionClient.buildKickGroupMembersRequest`.
#[must_use]
pub fn build_kick_group_members_request(
    group_id: &str,
    member_ids: &[String],
    imei: &str,
) -> Option<CallSpec> {
    let clean_grid = clean_group_id(group_id);
    let clean_ids = clean_group_member_ids(member_ids);
    if clean_grid.is_empty() || clean_grid == "0" || clean_ids.is_empty() {
        return None;
    }
    Some(CallSpec {
        service: "group".to_owned(),
        path: "/api/group/kickout".to_owned(),
        payload: json!({
            "grid": clean_grid,
            "members": clean_ids,
            "imei": imei,
        }),
    })
}

/// Pure request builder for `ZaloSessionClient.buildLeaveGroupRequest`.
#[must_use]
pub fn build_leave_group_request(group_id: &str, silent: bool, imei: &str) -> Option<CallSpec> {
    let clean_grid = clean_group_id(group_id);
    if clean_grid.is_empty() || clean_grid == "0" {
        return None;
    }
    Some(CallSpec {
        service: "group".to_owned(),
        path: "/api/group/leave".to_owned(),
        payload: json!({
            "grids": [clean_grid],
            "imei": imei,
            "silent": if silent { 1 } else { 0 },
            "language": "vi",
        }),
    })
}

/// Pure request builder for `ZaloSessionClient.fetchGroupDetailAPI(groupId:)`:
/// `POST /api/group/getmg-v2` on `"group"` with `{"gridVerMap": "{\"<grid>\":0}", "imei": imei}`.
#[must_use]
pub fn build_fetch_group_detail_request(group_id: &str, imei: &str) -> Option<CallSpec> {
    let clean_grid = clean_group_id(group_id);
    if clean_grid.is_empty() || clean_grid == "0" {
        return None;
    }
    let mut ver_map = Map::new();
    ver_map.insert(clean_grid, Value::from(0));
    let ver_json = swift_json(&Value::Object(ver_map));
    Some(CallSpec {
        service: "group".to_owned(),
        path: "/api/group/getmg-v2".to_owned(),
        payload: json!({
            "gridVerMap": ver_json,
            "imei": imei,
        }),
    })
}

/// Extracts the single group's `gridInfoMap` object from `/api/group/getmg-v2`, matching
/// `ZaloSessionClient.fetchGroupDetailAPI(groupId:)`.
#[must_use]
pub fn parse_fetch_group_detail_response(resp: &JsonObject, group_id: &str) -> JsonObject {
    let clean_grid = clean_group_id(group_id);
    if clean_grid.is_empty() || clean_grid == "0" {
        return Map::new();
    }
    let outer = resp.get("data").and_then(Value::as_object);
    let batch_data = outer
        .and_then(|o| o.get("data").and_then(Value::as_object))
        .or(outer);
    if let Some(grid_info_map) = batch_data
        .and_then(|b| b.get("gridInfoMap"))
        .and_then(Value::as_object)
        && let Some(Value::Object(info)) = grid_info_map
            .get(&clean_grid)
            .or_else(|| grid_info_map.get(&format!("g{clean_grid}")))
    {
        return info.clone();
    }
    Map::new()
}

/// Port of `ZaloSessionClient.membersPayload(groupId:members:imei:)`.
#[must_use]
pub fn build_group_members_payload(
    group_id: &str,
    members: &[String],
    imei: Option<&str>,
) -> Value {
    let clean_members: Vec<String> = members.iter().map(|m| strip_user_prefix(m)).collect();
    let mut obj = Map::new();
    obj.insert("grid".to_owned(), Value::String(clean_group_id(group_id)));
    obj.insert("members".to_owned(), json!(clean_members));
    if let Some(imei) = imei {
        obj.insert("imei".to_owned(), Value::String(imei.to_owned()));
    }
    Value::Object(obj)
}

/// Port of `GroupPendingMember.list(from:)`: `pending-mems/list` -> `{users:[{uid, dpn, avatar}]}`.
#[must_use]
pub fn parse_group_pending_members(data: &JsonObject) -> Vec<GroupPendingMember> {
    let Some(users) = data.get("users").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut out = Vec::with_capacity(users.len());
    for row_val in users {
        let Some(row) = row_val.as_object() else {
            continue;
        };
        let id = strip_user_prefix(&lossless::string(row.get("uid").or_else(|| row.get("id"))));
        if id.is_empty() || id == "0" {
            continue;
        }
        let name = ["dpn", "displayName", "zaloName"]
            .into_iter()
            .map(|k| lossless::string(row.get(k)))
            .find(|s| !s.is_empty())
            .unwrap_or_default();
        let avatar_raw = lossless::string(row.get("avatar"));
        let avatar = if avatar_raw.is_empty() {
            None
        } else {
            Some(avatar_raw)
        };
        out.push(GroupPendingMember { id, name, avatar });
    }
    out
}

/// Port of `GroupLink.from(_:)`: `{link, expiration_date, enabled}`.
#[must_use]
pub fn parse_group_link(data: &JsonObject) -> GroupLink {
    let link = lossless::string(data.get("link").or_else(|| data.get("url")));
    let enabled = lossless::int64(data.get("enabled"))
        .map(|n| n == 1)
        .or_else(|| data.get("enabled").and_then(Value::as_bool))
        .unwrap_or(!link.is_empty());
    GroupLink {
        enabled: enabled && !link.is_empty(),
        link,
    }
}

impl<T: Transport> ZaloApi<T> {
    async fn group_admin_call(
        &self,
        path: &str,
        payload: Value,
        use_post: bool,
    ) -> Result<JsonObject, ApiError> {
        let req = ApiRequest::new("group", path).payload(payload);
        let resp = if use_post {
            self.post(req).await?
        } else {
            self.get(req).await?
        };
        Ok(resp
            .get("data")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default())
    }

    /// Creates a new group (`createGroupAPI`: `GET /api/group/create/v2`).
    pub async fn create_group(
        &self,
        name: &str,
        members: &[String],
    ) -> Result<JsonObject, ApiError> {
        let client_id = self.client().next_client_id();
        let spec = build_create_group_request(name, members, client_id, &self.imei());
        self.get(ApiRequest::new(spec.service, spec.path).payload(spec.payload))
            .await
    }

    /// Uploads a group avatar (`uploadGroupAvatarAPI`: multipart `POST /api/group/upavatar`).
    pub async fn upload_group_avatar(
        &self,
        group_id: &str,
        jpeg_data: &[u8],
        side: i64,
    ) -> Result<JsonObject, ApiError> {
        if jpeg_data.is_empty() {
            return Err(ApiError::Net(NetError::InvalidUrl(
                "upavatar:empty".to_owned(),
            )));
        }
        let client_id = self.client().next_client_id();
        let Some(spec) = build_upload_group_avatar_request(group_id, side, client_id, &self.imei())
        else {
            return Err(ApiError::Net(NetError::InvalidUrl(
                "upavatar:groupId".to_owned(),
            )));
        };
        let req = ApiRequest::new(spec.service, spec.path).payload(spec.encrypted_payload);
        let part = MultipartPart {
            field_name: spec.field_name,
            file_name: spec.file_name,
            mime_type: spec.mime_type,
            data: jpeg_data.to_vec(),
        };
        self.post_multipart(req, part).await
    }

    /// Renames a group (`renameGroupAPI`: `POST /api/group/updateinfo`).
    pub async fn rename_group(&self, group_id: &str, name: &str) -> Result<JsonObject, ApiError> {
        let trimmed = name.trim();
        if trimmed.is_empty() {
            return Err(ApiError::Net(NetError::InvalidUrl("updateinfo".to_owned())));
        }
        let Some(spec) = build_rename_group_request(group_id, trimmed, &self.imei()) else {
            return Err(ApiError::Net(NetError::InvalidUrl("updateinfo".to_owned())));
        };
        self.post(ApiRequest::new(spec.service, spec.path).payload(spec.payload))
            .await
    }

    /// Invites members to a group (`inviteGroupMembersAPI`: `POST /api/group/invite/v2`).
    pub async fn invite_group_members(
        &self,
        group_id: &str,
        member_ids: &[String],
    ) -> Result<JsonObject, ApiError> {
        let Some(spec) = build_invite_group_members_request(group_id, member_ids, &self.imei())
        else {
            return Err(ApiError::Net(NetError::InvalidUrl("invite".to_owned())));
        };
        self.post(ApiRequest::new(spec.service, spec.path).payload(spec.payload))
            .await
    }

    /// Removes members from a group (`kickGroupMembersAPI`: `POST /api/group/kickout`).
    pub async fn kick_group_members(
        &self,
        group_id: &str,
        member_ids: &[String],
    ) -> Result<JsonObject, ApiError> {
        let Some(spec) = build_kick_group_members_request(group_id, member_ids, &self.imei())
        else {
            return Err(ApiError::Net(NetError::InvalidUrl("kickout".to_owned())));
        };
        self.post(ApiRequest::new(spec.service, spec.path).payload(spec.payload))
            .await
    }

    /// Leaves a group (`leaveGroupAPI`: `POST /api/group/leave`).
    pub async fn leave_group(&self, group_id: &str, silent: bool) -> Result<JsonObject, ApiError> {
        let Some(spec) = build_leave_group_request(group_id, silent, &self.imei()) else {
            return Err(ApiError::Net(NetError::InvalidUrl("leave".to_owned())));
        };
        self.post(ApiRequest::new(spec.service, spec.path).payload(spec.payload))
            .await
    }

    /// Fetches `/api/group/getmg-v2` metadata for a single group (`fetchGroupDetailAPI`).
    pub async fn fetch_group_detail(&self, group_id: &str) -> Result<JsonObject, ApiError> {
        let Some(spec) = build_fetch_group_detail_request(group_id, &self.imei()) else {
            return Err(ApiError::Net(NetError::InvalidUrl("getmg-v2".to_owned())));
        };
        let resp = self
            .post(ApiRequest::new(spec.service, spec.path).payload(spec.payload))
            .await?;
        Ok(parse_fetch_group_detail_response(&resp, group_id))
    }

    /// Promotes or demotes a deputy (`setGroupAdminAPI`: `GET /api/group/admins/{add,remove}`).
    pub async fn set_group_admin(
        &self,
        group_id: &str,
        uid: &str,
        admin: bool,
    ) -> Result<JsonObject, ApiError> {
        let path = if admin {
            "/api/group/admins/add"
        } else {
            "/api/group/admins/remove"
        };
        let imei = self.imei();
        let payload = build_group_members_payload(group_id, &[uid.to_owned()], Some(&imei));
        self.group_admin_call(path, payload, false).await
    }

    /// Transfers group ownership (`changeGroupOwnerAPI`: `POST /api/group/change-owner`).
    pub async fn change_group_owner(
        &self,
        group_id: &str,
        uid: &str,
    ) -> Result<JsonObject, ApiError> {
        let payload = json!({
            "grid": clean_group_id(group_id),
            "newAdminId": strip_user_prefix(uid),
            "imei": self.imei(),
            "language": "vi",
        });
        self.group_admin_call("/api/group/change-owner", payload, true)
            .await
    }

    /// Blocks or unblocks a group member (`setGroupMemberBlockedAPI`: `GET /api/group/blockedmems/{add,remove}`).
    pub async fn set_group_member_blocked(
        &self,
        group_id: &str,
        uid: &str,
        blocked: bool,
    ) -> Result<JsonObject, ApiError> {
        let path = if blocked {
            "/api/group/blockedmems/add"
        } else {
            "/api/group/blockedmems/remove"
        };
        let payload = build_group_members_payload(group_id, &[uid.to_owned()], None);
        self.group_admin_call(path, payload, false).await
    }

    /// Lists pending membership requests (`fetchGroupPendingAPI`: `GET /api/group/pending-mems/list`).
    pub async fn fetch_group_pending(
        &self,
        group_id: &str,
    ) -> Result<Vec<GroupPendingMember>, ApiError> {
        let payload = json!({
            "grid": clean_group_id(group_id),
            "imei": self.imei(),
        });
        let data = self
            .group_admin_call("/api/group/pending-mems/list", payload, false)
            .await?;
        Ok(parse_group_pending_members(&data))
    }

    /// Approves or rejects pending membership requests (`reviewGroupPendingAPI`: `GET /api/group/pending-mems/review`).
    pub async fn review_group_pending(
        &self,
        group_id: &str,
        uids: &[String],
        approve: bool,
    ) -> Result<JsonObject, ApiError> {
        let members: Vec<String> = uids.iter().map(|u| strip_user_prefix(u)).collect();
        let payload = json!({
            "grid": clean_group_id(group_id),
            "members": members,
            "isApprove": approve,
        });
        self.group_admin_call("/api/group/pending-mems/review", payload, false)
            .await
    }

    /// Reads the group's invite link (`fetchGroupLinkAPI`: `GET /api/group/link/detail`).
    pub async fn fetch_group_link(&self, group_id: &str) -> Result<GroupLink, ApiError> {
        let payload = json!({
            "grid": clean_group_id(group_id),
            "imei": self.imei(),
        });
        let data = self
            .group_admin_call("/api/group/link/detail", payload, false)
            .await?;
        Ok(parse_group_link(&data))
    }

    /// Renews or disables the group's invite link (`setGroupLinkAPI`).
    pub async fn set_group_link(&self, group_id: &str, renew: bool) -> Result<GroupLink, ApiError> {
        let grid = clean_group_id(group_id);
        if renew {
            let payload = json!({
                "grid": grid,
                "imei": self.imei(),
            });
            let data = self
                .group_admin_call("/api/group/link/new", payload, false)
                .await?;
            return Ok(parse_group_link(&data));
        }
        let _ = self
            .group_admin_call("/api/group/link/disable", json!({ "grid": grid }), false)
            .await?;
        Ok(GroupLink {
            link: String::new(),
            enabled: false,
        })
    }

    /// Updates group settings (`updateGroupSettingsAPI`: `GET /api/group/setting/update`).
    pub async fn update_group_settings(
        &self,
        group_id: &str,
        settings: &JsonObject,
    ) -> Result<JsonObject, ApiError> {
        let mut payload = settings.clone();
        payload.insert("grid".to_owned(), Value::String(clean_group_id(group_id)));
        payload.insert("imei".to_owned(), Value::String(self.imei()));
        self.group_admin_call("/api/group/setting/update", Value::Object(payload), false)
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_group_member_ids_strips_u_prefix_and_preserves_order() {
        let raw = vec![
            " u2001 ".to_owned(),
            "3002".to_owned(),
            "2001".to_owned(),
            "0".to_owned(),
            "u0".to_owned(),
            "".to_owned(),
            "uabc".to_owned(),
            "u4003".to_owned(),
        ];
        assert_eq!(
            clean_group_member_ids(&raw),
            vec!["2001", "3002", "uabc", "4003"]
        );
    }

    #[test]
    fn build_and_parse_fetch_group_detail_matches_swift() {
        assert!(build_fetch_group_detail_request("", "imei-1").is_none());
        assert!(build_fetch_group_detail_request("0", "imei-1").is_none());
        assert!(build_fetch_group_detail_request("g0", "imei-1").is_none());

        let spec = build_fetch_group_detail_request("g500201", "imei-1").unwrap();
        assert_eq!(spec.service, "group");
        assert_eq!(spec.path, "/api/group/getmg-v2");
        assert_eq!(
            spec.payload,
            json!({
                "gridVerMap": "{\"500201\":0}",
                "imei": "imei-1",
            })
        );

        let direct = json!({
            "data": {
                "gridInfoMap": {
                    "500201": { "groupId": "500201", "name": "Nhóm A", "creatorId": "2001" }
                }
            }
        });
        let parsed = parse_fetch_group_detail_response(direct.as_object().unwrap(), "g500201");
        assert_eq!(parsed.get("name"), Some(&json!("Nhóm A")));

        let nested_prefixed = json!({
            "data": {
                "data": {
                    "gridInfoMap": {
                        "g500202": { "groupId": "500202", "name": "Nhóm B" }
                    }
                }
            }
        });
        let parsed2 =
            parse_fetch_group_detail_response(nested_prefixed.as_object().unwrap(), "500202");
        assert_eq!(parsed2.get("name"), Some(&json!("Nhóm B")));

        let missing = json!({ "data": { "gridInfoMap": {} } });
        assert!(
            parse_fetch_group_detail_response(missing.as_object().unwrap(), "g500201").is_empty()
        );
    }

    #[test]
    fn group_mgmt_builders_match_swift_shapes() {
        let create = build_create_group_request(
            "Team",
            &[" 100 ".to_owned(), "".to_owned(), "200".to_owned()],
            42,
            "imei-1",
        );
        assert_eq!(create.service, "group");
        assert_eq!(create.path, "/api/group/create/v2");
        assert_eq!(
            create.payload,
            json!({
                "clientId": 42,
                "gname": "Team",
                "gdesc": null,
                "members": ["100", "200"],
                "nameChanged": 1,
                "createLink": 1,
                "clientLang": "vi",
                "imei": "imei-1",
                "groupType": null,
            })
        );

        assert!(build_upload_group_avatar_request("g0", 240, 1, "imei").is_none());
        assert!(build_upload_group_avatar_request("g500", 0, 1, "imei").is_none());
        let av = build_upload_group_avatar_request("g500", 240, 77, "imei-1").unwrap();
        assert_eq!(av.service, "file");
        assert_eq!(av.path, "/api/group/upavatar");
        assert_eq!(av.field_name, "fileContent");
        assert_eq!(av.file_name, "avatar.jpg");
        assert_eq!(av.mime_type, "image/jpeg");
        assert_eq!(
            av.encrypted_payload,
            json!({
                "grid": "500",
                "avatarSize": 240,
                "clientId": 77,
                "originWidth": 240,
                "originHeight": 240,
                "imei": "imei-1",
            })
        );

        let rename = build_rename_group_request("g500", "New", "imei-1").unwrap();
        assert_eq!(rename.path, "/api/group/updateinfo");
        assert_eq!(
            rename.payload,
            json!({ "grid": "500", "gname": "New", "imei": "imei-1" })
        );

        let invite = build_invite_group_members_request(
            "g500",
            &["u100".to_owned(), "200".to_owned()],
            "imei-1",
        )
        .unwrap();
        assert_eq!(invite.path, "/api/group/invite/v2");
        assert_eq!(
            invite.payload,
            json!({
                "grid": "500",
                "members": ["100", "200"],
                "memberTypes": [-1, -1],
                "imei": "imei-1",
                "clientLang": "vi",
            })
        );

        let kick =
            build_kick_group_members_request("g500", &["u100".to_owned()], "imei-1").unwrap();
        assert_eq!(kick.path, "/api/group/kickout");
        assert_eq!(
            kick.payload,
            json!({ "grid": "500", "members": ["100"], "imei": "imei-1" })
        );

        let leave = build_leave_group_request("g500", true, "imei-1").unwrap();
        assert_eq!(leave.path, "/api/group/leave");
        assert_eq!(
            leave.payload,
            json!({
                "grids": ["500"],
                "imei": "imei-1",
                "silent": 1,
                "language": "vi",
            })
        );
    }

    #[test]
    fn group_admin_parsers_and_payloads_match_swift() {
        let pending_data = json!({
            "users": [
                { "uid": "u3001", "dpn": "An", "avatar": "https://a.test/1.jpg" },
                { "id": "3002", "displayName": "Binh", "avatar": "" },
                { "uid": "0", "dpn": "Skip" }
            ]
        });
        let pending = parse_group_pending_members(pending_data.as_object().unwrap());
        assert_eq!(
            pending,
            vec![
                GroupPendingMember {
                    id: "u3001".to_owned(),
                    name: "An".to_owned(),
                    avatar: Some("https://a.test/1.jpg".to_owned()),
                },
                GroupPendingMember {
                    id: "3002".to_owned(),
                    name: "Binh".to_owned(),
                    avatar: None,
                },
            ]
        );

        let link1 = parse_group_link(
            json!({ "link": "https://zalo.me/g/abc", "enabled": 1 })
                .as_object()
                .unwrap(),
        );
        assert_eq!(
            link1,
            GroupLink {
                link: "https://zalo.me/g/abc".to_owned(),
                enabled: true,
            }
        );

        let link2 = parse_group_link(
            json!({ "url": "https://zalo.me/g/abc", "enabled": 0 })
                .as_object()
                .unwrap(),
        );
        assert_eq!(
            link2,
            GroupLink {
                link: "https://zalo.me/g/abc".to_owned(),
                enabled: false,
            }
        );

        assert_eq!(
            build_group_members_payload("g500", &[" u3001 ".to_owned()], None),
            json!({ "grid": "500", "members": ["u3001"] })
        );
        assert_eq!(
            build_group_members_payload("g500", &["u3001".to_owned()], Some("imei-1")),
            json!({ "grid": "500", "members": ["u3001"], "imei": "imei-1" })
        );
    }
}

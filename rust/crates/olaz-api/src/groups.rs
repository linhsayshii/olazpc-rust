//! Shared group metadata API helpers (`/api/group/getmg-v2` single-group fetch and member-id
//! normalization), shared between U12 (polls) and U10 (groups).

use std::collections::HashSet;

use olaz_net::{ApiRequest, NetError, Transport};
use olaz_wire::{clean_group_id, strip_user_prefix};
use serde_json::{Map, Value, json};

use crate::api::{JsonObject, ZaloApi};
use crate::error::ApiError;
use crate::messaging::CallSpec;
use crate::util::swift_json;

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

impl<T: Transport> ZaloApi<T> {
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
}

//! Profile lookup (Swift `fetchProfiles` / `fetchProfileChunk`).

use std::future::Future;
use std::pin::Pin;

use olaz_net::{ApiRequest, Transport};
use olaz_wire::{extract_profiles_map, sanitize_profile_uid};
use serde_json::{Map, Value, json};

use crate::api::{JsonObject, ZaloApi};
use crate::error::ApiError;

const CHUNK: usize = 50;

type ChunkFuture<'a> =
    Pin<Box<dyn Future<Output = Result<Map<String, Value>, ApiError>> + Send + 'a>>;

impl<T: Transport> ZaloApi<T> {
    /// Swift `fetchProfiles`: sanitizes and de-duplicates `uids`, asks 50 at a time and returns
    /// `{"data": {"profiles": {uid: row}}}` (an empty object when no uid is valid).
    pub async fn fetch_profiles(&self, uids: &[String]) -> Result<JsonObject, ApiError> {
        let mut clean: Vec<String> = Vec::with_capacity(uids.len());
        for raw in uids {
            if let Some(uid) = sanitize_profile_uid(raw)
                && !clean.contains(&uid)
            {
                clean.push(uid);
            }
        }
        if clean.is_empty() {
            return Ok(Map::new());
        }
        let mut merged = Map::new();
        for chunk in clean.chunks(CHUNK) {
            for (uid, row) in self.fetch_profile_chunk(chunk).await? {
                merged.insert(uid, row);
            }
        }
        let mut data = Map::new();
        data.insert("profiles".to_owned(), Value::Object(merged));
        let mut out = Map::new();
        out.insert("data".to_owned(), Value::Object(data));
        Ok(out)
    }

    /// `/api/social/group/members`; on a server error (not an auth error) falls back to
    /// `/api/social/friend/getprofiles/v2`; error 114 on either splits the chunk in half and a
    /// single invalid uid yields nothing instead of failing the batch.
    fn fetch_profile_chunk<'a>(&'a self, chunk: &'a [String]) -> ChunkFuture<'a> {
        Box::pin(async move {
            if chunk.is_empty() {
                return Ok(Map::new());
            }
            let pver: Vec<String> = chunk.iter().map(|u| format!("{u}_0")).collect();
            let primary = self
                .post(
                    ApiRequest::new("profile", "/api/social/group/members")
                        .payload(json!({"friend_pversion_map": pver})),
                )
                .await;
            let primary_err = match primary {
                Ok(resp) => return Ok(extract_profiles_map(&resp)),
                Err(e) => e,
            };
            let Some(primary_session) = primary_err.session_error() else {
                return Err(primary_err);
            };
            if primary_err.is_auth_error() {
                return Err(primary_err);
            }
            let primary_code = primary_session.code;
            let fallback = self
                .post(
                    ApiRequest::new("profile", "/api/social/friend/getprofiles/v2").payload(
                        json!({
                            "phonebook_version": 0,
                            "friend_pversion_map": pver,
                            "avatar_size": 160,
                            "language": "vi",
                            "show_online_status": 0,
                            "imei": self.imei(),
                        }),
                    ),
                )
                .await;
            let fallback_err = match fallback {
                Ok(resp) => return Ok(extract_profiles_map(&resp)),
                Err(e) => e,
            };
            let Some(fallback_session) = fallback_err.session_error() else {
                return Err(fallback_err);
            };
            if fallback_err.is_auth_error() {
                return Err(fallback_err);
            }
            if fallback_session.code == 114 || primary_code == 114 {
                if chunk.len() > 1 {
                    let mid = chunk.len() / 2;
                    let mut merged = self.fetch_profile_chunk(&chunk[..mid]).await?;
                    for (uid, row) in self.fetch_profile_chunk(&chunk[mid..]).await? {
                        merged.insert(uid, row);
                    }
                    return Ok(merged);
                }
                return Ok(Map::new());
            }
            Err(fallback_err)
        })
    }
}

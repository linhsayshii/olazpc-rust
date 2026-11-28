//! The renderer uses GET for both gid endpoints (26.11.10 compact-app-pc member,
//! /api/gid/encrypt at byte 15069908, /api/gid/decrypt at 15070156).
//! Its wcaV manager retries once; 50 and the byte budget below are client safety
//! limits, not an official batch-size contract.

use std::collections::{HashMap, HashSet, VecDeque};

use olaz_net::{ApiRequest, NetError, Transport};
use olaz_wire::sanitize_profile_uid;
use serde_json::{Value, json};

use crate::{ApiError, ZaloApi};

const CHUNK: usize = 50;
// AES/base64/percent encoding grows this to roughly 3 KiB of query parameters.
const PAYLOAD_BUDGET: usize = 2048;
// Split transient failures too, but never fan an outage out to every singleton.
const TRANSIENT_SPLIT_DEPTH: usize = 3;

#[derive(Clone, Copy)]
enum Direction {
    Decrypt,
    Encrypt,
}

impl Direction {
    fn request(self, ids: &[String]) -> ApiRequest {
        match self {
            Self::Decrypt => ApiRequest::new("profile", "/api/gid/decrypt")
                .payload(json!({"globalUids": json!(ids).to_string()})),
            Self::Encrypt => {
                ApiRequest::new("profile", "/api/gid/encrypt").payload(json!({"noiseUids": ids}))
            }
        }
    }

    fn payload_size(self, ids: &[String]) -> usize {
        match self {
            Self::Decrypt => json!({"globalUids": json!(ids).to_string()})
                .to_string()
                .len(),
            Self::Encrypt => json!({"noiseUids": ids}).to_string().len(),
        }
    }
}

impl<T: Transport> ZaloApi<T> {
    /// Global noised ID -> PC uid. Failed leaves are not cached; a later open/sync retries them.
    pub async fn decrypt_global_ids(
        &self,
        ids: &[String],
    ) -> Result<HashMap<String, String>, ApiError> {
        self.resolve_global_ids(ids, Direction::Decrypt).await
    }

    /// PC uid -> global noised ID; same bounded GET policy as decrypt.
    pub async fn encrypt_global_ids(
        &self,
        ids: &[String],
    ) -> Result<HashMap<String, String>, ApiError> {
        self.resolve_global_ids(ids, Direction::Encrypt).await
    }

    async fn resolve_global_ids(
        &self,
        ids: &[String],
        direction: Direction,
    ) -> Result<HashMap<String, String>, ApiError> {
        let mut seen = HashSet::new();
        let clean: Vec<String> = ids
            .iter()
            .filter_map(|raw| {
                let id = match direction {
                    Direction::Decrypt => raw.trim().to_owned(),
                    Direction::Encrypt => sanitize_profile_uid(raw)?,
                };
                (!id.is_empty() && seen.insert(id.clone())).then_some(id)
            })
            .collect();
        let mut resolved = HashMap::new();
        let mut missing = Vec::new();
        {
            let state = self.state();
            let cache = match direction {
                Direction::Decrypt => &state.global_id_to_uid,
                Direction::Encrypt => &state.uid_to_global_id,
            };
            for id in clean {
                if let Some(hit) = cache.get(&id) {
                    resolved.insert(id, hit.clone());
                } else {
                    missing.push(id);
                }
            }
        }
        let mut pending: VecDeque<_> = missing
            .chunks(CHUNK)
            .map(|c| (c.to_vec(), 0usize))
            .collect();
        while let Some((chunk, depth)) = pending.pop_front() {
            if chunk.len() > 1 && direction.payload_size(&chunk) > PAYLOAD_BUDGET {
                split(&mut pending, &chunk, depth);
                continue;
            }
            let mut answer = self.get(direction.request(&chunk)).await;
            // Official manager retries once on errors. Size failures can only benefit from splitting.
            if let Err(ref error) = answer
                && !size_error(error)
                && retryable(error)
            {
                answer = self.get(direction.request(&chunk)).await;
            }
            let response = match answer {
                Ok(response) => response,
                Err(error) => {
                    if matches!(
                        error,
                        ApiError::Net(NetError::NotAuthenticated | NetError::Cancelled)
                    ) || error.is_auth_error()
                    {
                        return Err(error);
                    }
                    if chunk.len() > 1
                        && (size_error(&error)
                            || (retryable(&error) && depth < TRANSIENT_SPLIT_DEPTH))
                    {
                        split(&mut pending, &chunk, depth);
                    }
                    continue;
                }
            };
            let Some(map) = response.get("data").and_then(Value::as_object) else {
                continue;
            };
            let mut state = self.state();
            for (key, value) in map {
                let value = olaz_wire::lossless::string(Some(value));
                let (gid, uid) = match direction {
                    Direction::Decrypt => (key.clone(), sanitize_profile_uid(&value)),
                    Direction::Encrypt => (value, sanitize_profile_uid(key)),
                };
                let Some(uid) = uid else { continue };
                let requested = match direction {
                    Direction::Decrypt => key.clone(),
                    Direction::Encrypt => uid.clone(),
                };
                if gid.is_empty() || !chunk.contains(&requested) {
                    continue;
                }
                state.global_id_to_uid.insert(gid.clone(), uid.clone());
                state.uid_to_global_id.insert(uid.clone(), gid.clone());
                match direction {
                    Direction::Decrypt => {
                        resolved.insert(gid, uid);
                    }
                    Direction::Encrypt => {
                        resolved.insert(uid, gid);
                    }
                }
            }
        }
        Ok(resolved)
    }
}

fn split(pending: &mut VecDeque<(Vec<String>, usize)>, chunk: &[String], depth: usize) {
    let mid = chunk.len() / 2;
    pending.push_front((chunk[mid..].to_vec(), depth + 1));
    pending.push_front((chunk[..mid].to_vec(), depth + 1));
}

fn size_error(error: &ApiError) -> bool {
    matches!(
        error,
        ApiError::Net(NetError::Http {
            status: 414 | 431,
            ..
        })
    )
}

fn retryable(error: &ApiError) -> bool {
    match error {
        ApiError::Net(NetError::Network { .. }) => true,
        ApiError::Net(NetError::Http { status, .. }) => {
            *status == 408 || *status == 429 || *status >= 500
        }
        ApiError::Net(NetError::Session(error)) => !error.is_auth_error(),
        _ => false,
    }
}

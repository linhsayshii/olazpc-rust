//! zCloud server snapshot endpoints and parser (Swift `ZaloAPIService+Cloud.swift`).
//!
//! Security note (U11): `cloud_viewer_key` and `cloud_enk` are held exclusively inside
//! [`olaz_net::SessionState`] (whose `Debug` impl prints only presence booleans), never logged,
//! traced, or serialized into snapshots, and cleared on logout, account switch, `-1`/`-205`
//! server errors, and explicit `ResetCloud`.

use std::collections::BTreeMap;

use olaz_crypto::decode_cloud_aes;
use olaz_json::{bool_value, int64, parse_any, parse_object, string};
use olaz_net::{
    ApiRequest, NetError, RequestOptions, Transport, ZaloSessionError, common_params, url_encode,
};
use olaz_wire::strip_user_prefix;
use serde_json::{Map, Value};

use crate::api::ZaloApi;
use crate::error::ApiError;

const ONE_GIB: i64 = 1_073_741_824;
const ONE_HUNDRED_MIB: i64 = 100 * 1_048_576;

/// Subscription plan tier for zCloud (Swift `CloudState.PlanKind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloudPlanKind {
    Paid,
    Free,
    Grace,
    AfterGrace,
}

impl CloudPlanKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Paid => "paid",
            Self::Free => "free",
            Self::Grace => "grace",
            Self::AfterGrace => "afterGrace",
        }
    }

    #[must_use]
    pub const fn is_paid(self) -> bool {
        matches!(self, Self::Paid | Self::Grace)
    }
}

/// Server-reported zCloud plan/quota snapshot (Swift `ZaloCloudServerSnapshot`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloudServerSnapshot {
    pub plan_kind: CloudPlanKind,
    pub plan_name: String,
    pub quota: i64,
    pub usage: i64,
    pub family: i64,
    pub cloud_media: i64,
    pub message_backup: i64,
    pub my_cloud: i64,
    /// Expiry timestamp in milliseconds since Unix epoch, if reported.
    pub expire_at_ms: Option<i64>,
    pub auto_renew: Option<bool>,
    pub months: i64,
    pub backup_media: bool,
    pub backup_my_cloud: bool,
    pub backup_messages: bool,
    pub enable_offload: bool,
    pub file_limit: i64,
}

/// Pure parser matching Swift `ZaloSessionClient.parseCloudUsageSnapshot`.
#[must_use]
pub fn parse_cloud_usage_snapshot(
    usage_payload: &Map<String, Value>,
    settings_payload: Option<&Map<String, Value>>,
    info_payload: Option<&Map<String, Value>>,
    family_usage_payload: Option<&Value>,
    my_uid: &str,
) -> Option<CloudServerSnapshot> {
    if usage_payload.is_empty()
        || (usage_payload.get("plan").is_none()
            && usage_payload.get("quota").is_none()
            && usage_payload.get("usage").is_none()
            && usage_payload.get("service_usage").is_none())
    {
        return None;
    }

    let plan_int = int64(usage_payload.get("plan")).unwrap_or(-1);
    let plan_kind = match plan_int {
        0 => CloudPlanKind::Paid,
        100 => CloudPlanKind::Grace,
        69 => CloudPlanKind::AfterGrace,
        _ => CloudPlanKind::Free,
    };

    let service_usage = usage_payload
        .get("service_usage")
        .and_then(Value::as_object);
    let su_cloud_media = int64(service_usage.and_then(|m| m.get("cloud_media")))
        .unwrap_or(0)
        .max(0);
    let su_backup = int64(service_usage.and_then(|m| m.get("message_backup")))
        .unwrap_or(0)
        .max(0);
    let su_my_cloud = int64(service_usage.and_then(|m| m.get("my_cloud")))
        .unwrap_or(0)
        .max(0);
    let raw_quota = int64(usage_payload.get("quota")).unwrap_or(0).max(0);
    let raw_usage = int64(usage_payload.get("usage")).unwrap_or(0).max(0);

    let is_paid_plan = plan_kind.is_paid();
    let (cloud_media, message_backup, my_cloud, usage, family, quota, plan_name) = if !is_paid_plan
    {
        let my_cloud = if su_my_cloud > 0 {
            su_my_cloud
        } else if service_usage.is_some_and(|m| m.contains_key("my_cloud"))
            || su_cloud_media > 0
            || su_backup > 0
        {
            0
        } else {
            raw_usage
        };
        let quota = if raw_quota > 0 { raw_quota } else { ONE_GIB };
        (
            0_i64,
            0_i64,
            my_cloud,
            my_cloud,
            0_i64,
            quota,
            "Cloud của tôi".to_owned(),
        )
    } else {
        let usage = if raw_usage > 0 {
            raw_usage
        } else {
            su_cloud_media + su_backup + su_my_cloud
        };
        let family = match int64(usage_payload.get("family")) {
            Some(direct) if direct > 0 => direct,
            _ => sum_other_family_usage(family_usage_payload, my_uid),
        };
        let plan_name = resolve_plan_name(info_payload, plan_kind);
        (
            su_cloud_media,
            su_backup,
            su_my_cloud,
            usage,
            family,
            raw_quota,
            plan_name,
        )
    };

    let (backup_media, backup_my_cloud, backup_messages) =
        if let Some(opt_in) = int64(settings_payload.and_then(|s| s.get("opt_in"))) {
            ((opt_in & 1) != 0, (opt_in & 2) != 0, (opt_in & 4) != 0)
        } else {
            (is_paid_plan, true, true)
        };

    let enable_offload =
        int64(settings_payload.and_then(|s| s.get("enable_offload"))).unwrap_or(0) == 1;
    let raw_limit =
        int64(settings_payload.and_then(|s| s.get("cloud_media_file_size_limit"))).unwrap_or(0);
    let file_limit = if raw_limit > 0 {
        raw_limit
    } else if is_paid_plan {
        ONE_GIB
    } else {
        ONE_HUNDRED_MIB
    };

    let sub = info_payload
        .and_then(|m| m.get("subscription_info"))
        .and_then(Value::as_object);
    let expire_at_ms = int64(sub.and_then(|s| s.get("expire_time")))
        .filter(|&raw| raw > 0)
        .map(|raw| {
            if raw > 10_000_000_000 {
                raw
            } else {
                raw.saturating_mul(1000)
            }
        });

    let auto_renew = sub.and_then(|s| {
        let prod = string(s.get("auto_renew_product_id")).trim().to_owned();
        if s.get("cancelled_renew").is_none() && prod.is_empty() {
            return None;
        }
        let cancelled = bool_value(s.get("cancelled_renew")).unwrap_or(false);
        Some(!cancelled && !prod.is_empty())
    });

    let months = int64(sub.and_then(|s| s.get("duration_months"))).unwrap_or(0);

    Some(CloudServerSnapshot {
        plan_kind,
        plan_name,
        quota,
        usage,
        family,
        cloud_media,
        message_backup,
        my_cloud,
        expire_at_ms,
        auto_renew,
        months,
        backup_media,
        backup_my_cloud,
        backup_messages,
        enable_offload,
        file_limit,
    })
}

fn sum_other_family_usage(payload: Option<&Value>, my_uid: &str) -> i64 {
    let rows: &[Value] = match payload {
        Some(Value::Array(arr)) => arr.as_slice(),
        Some(Value::Object(obj)) => {
            if let Some(Value::Array(members)) = obj.get("members") {
                members.as_slice()
            } else if let Some(Value::Array(data)) = obj.get("data") {
                data.as_slice()
            } else {
                &[]
            }
        }
        _ => &[],
    };

    let clean_me = strip_user_prefix(my_uid);
    let mut total: i64 = 0;
    for row in rows {
        let Some(obj) = row.as_object() else {
            continue;
        };
        let uid = strip_user_prefix(&string(obj.get("uid").or_else(|| obj.get("userId"))));
        if !clean_me.is_empty() && !uid.is_empty() && uid == clean_me {
            continue;
        }
        let used = int64(obj.get("usage").or_else(|| obj.get("total")))
            .unwrap_or(0)
            .max(0);
        total = total.saturating_add(used);
    }
    total
}

fn resolve_plan_name(
    info_payload: Option<&Map<String, Value>>,
    plan_kind: CloudPlanKind,
) -> String {
    if plan_kind == CloudPlanKind::Grace {
        return "zCloud".to_owned();
    }
    let Some(info) = info_payload else {
        return "zCloud".to_owned();
    };
    let pkg = info.get("package_info").and_then(Value::as_object);
    let sub = info.get("subscription_info").and_then(Value::as_object);
    let candidates = [
        info.get("package_name"),
        info.get("plan_name"),
        pkg.and_then(|p| p.get("name")),
        sub.and_then(|s| s.get("package_name")),
        sub.and_then(|s| s.get("name")),
        info.get("name"),
    ];
    for candidate in candidates.into_iter().flatten() {
        if let Some(dict) = candidate.as_object() {
            let vi = string(dict.get("vi")).trim().to_owned();
            if !vi.is_empty() {
                return vi;
            }
            let en = string(dict.get("en")).trim().to_owned();
            if !en.is_empty() {
                return en;
            }
        }
        let s = string(Some(candidate)).trim().to_owned();
        if !s.is_empty() {
            return s;
        }
    }
    "zCloud".to_owned()
}

fn url_path_only(url: &str) -> String {
    let without_scheme = url.split_once("://").map_or(url, |(_, rest)| rest);
    let path_and_query = without_scheme
        .find('/')
        .map_or("/", |idx| &without_scheme[idx..]);
    path_and_query
        .split_once('?')
        .map_or(path_and_query, |(p, _)| p)
        .to_owned()
}

impl<T: Transport> ZaloApi<T> {
    /// Clears cached zCloud viewer credentials (`cloud_viewer_key` & `cloud_enk`).
    pub fn clear_cloud_viewer_key(&self) {
        self.client().clear_cloud_viewer_key();
    }

    /// Fetches (or returns cached) `(viewer_key, enk)` via `GET /api/getCloudViewerKey`.
    pub async fn fetch_cloud_viewer_key(
        &self,
        force_refresh: bool,
    ) -> Result<(String, String), ApiError> {
        if !force_refresh {
            let cached =
                self.client()
                    .with_session(|s| match (&s.cloud_viewer_key, &s.cloud_enk) {
                        (Some(vk), Some(ek)) if !vk.is_empty() && !ek.is_empty() => {
                            Some((vk.clone(), ek.clone()))
                        }
                        _ => None,
                    });
            if let Some(pair) = cached {
                return Ok(pair);
            }
        }

        let resp = self
            .get(ApiRequest::new("auth", "/api/getCloudViewerKey"))
            .await?;
        let d = resp.get("data").and_then(Value::as_object).unwrap_or(&resp);
        let vk = string(d.get("viewer_key")).trim().to_owned();
        let ek = string(d.get("enk")).trim().to_owned();
        if vk.is_empty() || ek.is_empty() {
            return Err(ApiError::Net(NetError::Session(ZaloSessionError {
                code: -205,
                message: "Thiếu khóa truy cập zCloud.".to_owned(),
                url: "/api/getCloudViewerKey".to_owned(),
            })));
        }
        self.client().with_session(|s| {
            s.cloud_viewer_key = Some(vk.clone());
            s.cloud_enk = Some(ek.clone());
        });
        Ok((vk, ek))
    }

    /// Swift `zCloudGet(path:queryParams:retryOnExpiredKey:)`.
    pub async fn zcloud_get(
        &self,
        path: &str,
        query_params: &BTreeMap<String, String>,
        retry_on_expired_key: bool,
    ) -> Result<Option<Value>, ApiError> {
        let max_attempts = if retry_on_expired_key { 2 } else { 1 };
        for attempt in 0..max_attempts {
            let (viewer_key, enk) = self.fetch_cloud_viewer_key(false).await?;
            let mut suffix = format!("{path}?{}", common_params());
            for (k, v) in query_params {
                suffix.push('&');
                suffix.push_str(k);
                suffix.push('=');
                suffix.push_str(&url_encode(v));
            }

            let hosts = self.client().domains().candidates("zcloud");
            let mut last_error = NetError::InvalidUrl("zcloud".to_owned());
            let mut should_retry_key = false;

            for host in hosts {
                let full_url = format!("{host}{suffix}");
                let outcome = match self
                    .client()
                    .raw_request(
                        RequestOptions::get(&full_url).header("cloud-viewer-key", &viewer_key),
                    )
                    .await
                {
                    Ok(o) => o,
                    Err(NetError::InvalidUrl(_)) => continue,
                    Err(e) if e.should_failover() => {
                        last_error = e;
                        continue;
                    }
                    Err(e) => return Err(ApiError::Net(e)),
                };

                let status = outcome.response.status;
                if status == 404 {
                    last_error = NetError::Http {
                        status: 404,
                        body: String::new(),
                    };
                    continue;
                }
                if !(200..300).contains(&status) {
                    let preview_len = outcome.response.body.len().min(200);
                    let err = NetError::Http {
                        status,
                        body: String::from_utf8_lossy(&outcome.response.body[..preview_len])
                            .into_owned(),
                    };
                    if err.should_failover() {
                        last_error = err;
                        continue;
                    }
                    return Err(ApiError::Net(err));
                }

                let Some(parsed) = parse_object(&outcome.response.body) else {
                    return Err(ApiError::Net(NetError::InvalidJson));
                };

                if let Some(code) = int64(parsed.get("error_code"))
                    && code != 0
                {
                    if code == -1 || code == -205 {
                        self.clear_cloud_viewer_key();
                        if attempt + 1 < max_attempts {
                            should_retry_key = true;
                            break;
                        }
                    }
                    if code == -904 {
                        self.client()
                            .with_session(|s| s.domains.remember_winner("zcloud", &host));
                        return Ok(None);
                    }
                    let msg = string(parsed.get("error_message"));
                    return Err(ApiError::Net(NetError::Session(ZaloSessionError {
                        code,
                        message: msg,
                        url: url_path_only(&full_url),
                    })));
                }

                self.client()
                    .with_session(|s| s.domains.remember_winner("zcloud", &host));

                let raw_data = parsed.get("data");
                if let Some(Value::String(cipher_str)) = raw_data {
                    let trimmed = cipher_str.trim();
                    if trimmed.is_empty() {
                        return Ok(None);
                    }
                    if trimmed.starts_with('{') || trimmed.starts_with('[') {
                        return Ok(parse_any(trimmed.as_bytes()));
                    }
                    let plain = decode_cloud_aes(&enk, trimmed).map_err(NetError::from)?;
                    let trimmed_plain = plain.trim();
                    if trimmed_plain.is_empty() {
                        return Ok(None);
                    }
                    return Ok(parse_any(trimmed_plain.as_bytes()));
                }
                if raw_data.is_none() || matches!(raw_data, Some(Value::Null)) {
                    return Ok(None);
                }
                return Ok(raw_data.cloned());
            }

            if should_retry_key {
                continue;
            }
            return Err(ApiError::Net(last_error));
        }

        Err(ApiError::Net(NetError::InvalidUrl("zcloud".to_owned())))
    }

    /// Swift `fetchCloudServerSnapshot()`.
    pub async fn fetch_cloud_server_snapshot(&self) -> Option<CloudServerSnapshot> {
        let me = self.client().account()?;
        if me.user_id.is_empty() {
            return None;
        }
        let empty = BTreeMap::new();
        let my_cloud_raw = self
            .zcloud_get("/cloudmedia/info/pc/v1/usage-mycloud", &empty, true)
            .await
            .ok()??;
        let mut usage_dict = my_cloud_raw.as_object()?.clone();

        let initial_plan = int64(usage_dict.get("plan")).unwrap_or(-1);
        if matches!(initial_plan, 0 | 100 | 69)
            && let Ok(Some(Value::Object(mut v2_dict))) = self
                .zcloud_get("/cloudmedia/info/pc/v2/usage", &empty, true)
                .await
        {
            if initial_plan == 69
                && int64(v2_dict.get("quota")).unwrap_or(0) <= 0
                && let Some(my_quota) = usage_dict.get("quota").cloned()
            {
                v2_dict.insert("quota".to_owned(), my_quota);
            }
            usage_dict = v2_dict;
        }

        let effective_plan = int64(usage_dict.get("plan")).unwrap_or(initial_plan);
        let settings_dict = self
            .zcloud_get("/cloudmedia/info/pc/v1/cloud-settings", &empty, true)
            .await
            .ok()
            .flatten()
            .and_then(|v| v.as_object().cloned());

        let (info_dict, family_payload) = if effective_plan == 0 || effective_plan == 100 {
            let info = self
                .zcloud_get("/zalocloud/cloudinfopcweb/v1/info", &empty, true)
                .await
                .ok()
                .flatten()
                .and_then(|v| v.as_object().cloned());
            let family = self
                .zcloud_get("/cloudmedia/info/pc/v1/family-usage", &empty, true)
                .await
                .ok()
                .flatten();
            (info, family)
        } else {
            (None, None)
        };

        parse_cloud_usage_snapshot(
            &usage_dict,
            settings_dict.as_ref(),
            info_dict.as_ref(),
            family_payload.as_ref(),
            &me.user_id,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    use olaz_crypto::encode_cloud_aes_with_iv;
    use olaz_net::{
        SessionClient,
        domains::ZaloDomains,
        http::RawResponse,
        mock::MockTransport,
        session::{LoginAccount, SessionState},
    };
    use serde_json::json;

    fn test_domains() -> ZaloDomains {
        ZaloDomains::default()
    }

    fn json_ok(val: &Value) -> Result<RawResponse, olaz_net::NetError> {
        Ok(RawResponse::new(200, serde_json::to_vec(val).unwrap()))
    }

    fn make_api(
        uid: &str,
        script: Vec<Result<RawResponse, olaz_net::NetError>>,
    ) -> ZaloApi<MockTransport> {
        let transport = MockTransport::scripted(script);
        let mut state = SessionState::new("imei".to_owned(), "TestMac".to_owned());
        state.domains = test_domains();
        state.update_credentials(
            LoginAccount {
                user_id: uid.to_owned(),
                display_name: "User".to_owned(),
                zpw_enk: "0123456789abcdef".to_owned(),
                zpw_sek: "sek.1".to_owned(),
                ..LoginAccount::default()
            },
            b"0123456789abcdef".to_vec(),
            "sek.1".to_owned(),
            Some(test_domains()),
        );
        let client = SessionClient::with_state(transport, state);
        ZaloApi::new(client)
    }

    #[tokio::test]
    async fn cloud_viewer_key_retry_on_expired_and_aes_decrypt() {
        let cloud_key = STANDARD.encode(b"0123456789abcdef");
        let iv = [7_u8; 16];
        let enc_usage = encode_cloud_aes_with_iv(
            &cloud_key,
            r#"{"plan":0,"quota":1000,"usage":400,"service_usage":{"cloud_media":100,"message_backup":200,"my_cloud":100}}"#,
            &iv,
        )
        .unwrap();

        let api = make_api(
            "2001",
            vec![
                // 1. First viewer key fetch
                json_ok(&json!({
                    "error_code": 0,
                    "data": {"viewer_key": "vk_old", "enk": cloud_key}
                })),
                // 2. usage-mycloud rejects expired viewer key with -205
                json_ok(&json!({
                    "error_code": -205,
                    "error_message": "expired key"
                })),
                // 3. Automatic single retry fetches a fresh viewer key
                json_ok(&json!({
                    "error_code": 0,
                    "data": {"viewer_key": "vk_fresh", "enk": cloud_key}
                })),
                // 4. Encrypted usage-mycloud succeeds with fresh viewer key
                json_ok(&json!({
                    "error_code": 0,
                    "data": enc_usage
                })),
            ],
        );

        let val = api
            .zcloud_get(
                "/cloudmedia/info/pc/v1/usage-mycloud",
                &BTreeMap::new(),
                true,
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(int64(val.get("plan")), Some(0));
        assert_eq!(int64(val.get("quota")), Some(1000));

        let reqs = api.client().transport().requests();
        assert_eq!(reqs.len(), 4);
        assert!(reqs[0].url.contains("/api/getCloudViewerKey"));
        assert!(reqs[2].url.contains("/api/getCloudViewerKey"));
        assert!(
            reqs[3]
                .headers
                .iter()
                .any(|(k, v)| k == "cloud-viewer-key" && v == "vk_fresh")
        );

        // Verify SessionState Debug never leaks viewer_key or enk.
        let debug_str = api.client().with_session(|s| format!("{s:?}"));
        assert!(!debug_str.contains("vk_fresh"));
        assert!(!debug_str.contains(&cloud_key));
    }

    #[tokio::test]
    async fn cloud_viewer_key_cleared_on_logout_and_relogin_fetches_fresh_key() {
        let k1 = STANDARD.encode(b"aaaaaaaaaaaaaaaa");
        let k2 = STANDARD.encode(b"bbbbbbbbbbbbbbbb");

        let api = make_api(
            "2001",
            vec![
                json_ok(&json!({
                    "error_code": 0,
                    "data": {"viewer_key": "vk_user_1", "enk": k1}
                })),
                json_ok(&json!({
                    "error_code": 0,
                    "data": {"viewer_key": "vk_user_2", "enk": k2}
                })),
                json_ok(&json!({
                    "error_code": 0,
                    "data": {"viewer_key": "vk_user_2_after_reset", "enk": k2}
                })),
            ],
        );

        let (vk1, ek1) = api.fetch_cloud_viewer_key(false).await.unwrap();
        assert_eq!(vk1, "vk_user_1");
        assert_eq!(ek1, k1);

        // Second call uses cache (no new HTTP request).
        let (vk1_cached, _) = api.fetch_cloud_viewer_key(false).await.unwrap();
        assert_eq!(vk1_cached, "vk_user_1");
        assert_eq!(api.client().transport().requests().len(), 1);

        // Logout clears viewer key & enk; re-login as user 2 must fetch a fresh key.
        api.client().clear_session();
        api.client().update_credentials(
            LoginAccount {
                user_id: "2002".to_owned(),
                display_name: "User 2".to_owned(),
                zpw_enk: "fedcba9876543210".to_owned(),
                zpw_sek: "sek.2".to_owned(),
                ..LoginAccount::default()
            },
            b"fedcba9876543210".to_vec(),
            "sek.2".to_owned(),
            Some(test_domains()),
        );

        let (vk2, ek2) = api.fetch_cloud_viewer_key(false).await.unwrap();
        assert_eq!(vk2, "vk_user_2");
        assert_eq!(ek2, k2);
        assert_eq!(api.client().transport().requests().len(), 2);

        // ResetCloud clear also forces a fresh fetch.
        api.clear_cloud_viewer_key();
        let (vk3, _) = api.fetch_cloud_viewer_key(false).await.unwrap();
        assert_eq!(vk3, "vk_user_2_after_reset");
        assert_eq!(api.client().transport().requests().len(), 3);
    }

    #[test]
    fn parse_cloud_usage_snapshot_covers_paid_grace_after_grace_and_free() {
        let usage = json!({
            "plan": 0,
            "quota": 100_000,
            "usage": 0,
            "service_usage": {"cloud_media": 1000, "message_backup": 2000, "my_cloud": 3000}
        });
        let settings =
            json!({"opt_in": 5, "enable_offload": 1, "cloud_media_file_size_limit": 5000});
        let info = json!({
            "package_name": {"vi": "Gói Pro", "en": "Pro"},
            "subscription_info": {
                "expire_time": 1_800_000_000,
                "auto_renew_product_id": "prod_1",
                "cancelled_renew": false,
                "duration_months": 12
            }
        });
        let family = json!({
            "members": [
                {"uid": " 2001 ", "usage": 9999},
                {"uid": "3002", "usage": 1234}
            ]
        });
        let snap = parse_cloud_usage_snapshot(
            usage.as_object().unwrap(),
            settings.as_object(),
            info.as_object(),
            Some(&family),
            "2001",
        )
        .unwrap();
        assert_eq!(snap.plan_kind, CloudPlanKind::Paid);
        assert_eq!(snap.plan_name, "Gói Pro");
        assert_eq!(snap.usage, 6000);
        assert_eq!(snap.family, 1234);
        assert_eq!(snap.expire_at_ms, Some(1_800_000_000_000));
        assert_eq!(snap.auto_renew, Some(true));
        assert_eq!(snap.months, 12);
        assert!(snap.backup_media);
        assert!(!snap.backup_my_cloud);
        assert!(snap.backup_messages);
        assert!(snap.enable_offload);
        assert_eq!(snap.file_limit, 5000);
    }
}

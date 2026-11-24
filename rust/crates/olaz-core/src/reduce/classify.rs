//! Pure WS frame and long-poll response classification (U2).
//!
//! Mirrors `ZaloEngine.handleWSEvent`, `ZaloEngine.processControlEnvelope`,
//! `ZaloEngine.drainChatPolling`, `ZaloPhoneSync.extractMobileSyncEvents`, and
//! `ZaloWireParser.pinTopicEventConversations` with zero I/O or clock access (D9).

use std::fmt;

use olaz_json::{int64, parse_object_str, string};
use olaz_wire::{group_conv_id, is_group_id, strip_user_prefix};
use olaz_ws::files::extract_file_done_events;
use serde_json::{Map, Value};

// WebSocket command constants taken verbatim from Swift source on `main`.
/// `Sources/Olaz/ZaloRuntime/Protocol/ZaloWebSocket.swift:176` (`static let cmdAuthen: UInt16 = 1`)
pub const CMD_AUTHEN: u16 = 1;
/// `Sources/Olaz/ZaloRuntime/Protocol/ZaloWebSocket.swift:185` (`static let cmdCtrlPullVoip: UInt16 = 604`)
pub const CMD_CTRL_PULL_VOIP: u16 = 604;
/// `Sources/Olaz/ZaloRuntime/Protocol/ZaloWebSocket.swift:187` (`static let cmdPushMsg11: UInt16 = 501`)
pub const CMD_PUSH_MSG_11: u16 = 501;
/// `Sources/Olaz/ZaloRuntime/Protocol/ZaloWebSocket.swift:195` (`static let cmdPushMsgGroup: UInt16 = 521`)
pub const CMD_PUSH_MSG_GROUP: u16 = 521;
/// `Sources/Olaz/ZaloRuntime/Protocol/ZaloWebSocket.swift:200` (`static let cmdSyncRequest: UInt16 = 590`)
pub const CMD_SYNC_REQUEST: u16 = 590;
/// `Sources/Olaz/ZaloRuntime/Protocol/ZaloWebSocket.swift:202` (`static let cmdSyncMobileWakeUp: UInt16 = 592`)
pub const CMD_SYNC_MOBILE_WAKE_UP: u16 = 592;

// E2EE command constants taken verbatim from Swift source on `main`.
/// `Sources/Olaz/ZaloRuntime/Protocol/ZaloE2EEManager.swift:15` (`static let cmdSessionOffline: UInt16 = 516`)
pub const CMD_SESSION_OFFLINE: u16 = 516;
/// `Sources/Olaz/ZaloRuntime/Protocol/ZaloE2EEManager.swift:20` (`static let cmdInitSession: UInt16 = 543`)
pub const CMD_INIT_SESSION: u16 = 543;
/// `Sources/Olaz/ZaloRuntime/Protocol/ZaloE2EEManager.swift:23` (`static let cmdRequestPreKeys: UInt16 = 549`)
pub const CMD_REQUEST_PRE_KEYS: u16 = 549;
/// `Sources/Olaz/ZaloRuntime/Protocol/ZaloE2EEManager.swift:24` (`static let cmdReceiveOneOne: UInt16 = 551`)
pub const CMD_RECEIVE_ONE_ONE: u16 = 551;
/// `Sources/Olaz/ZaloRuntime/Protocol/ZaloE2EEManager.swift:25` (`static let cmdReceiveGroup: UInt16 = 552`)
pub const CMD_RECEIVE_GROUP: u16 = 552;
/// `Sources/Olaz/ZaloRuntime/Protocol/ZaloE2EEManager.swift:26` (`static let cmdDeliverSeenOneOne: UInt16 = 553`)
pub const CMD_DELIVER_SEEN_ONE_ONE: u16 = 553;

/// Notice passed to `SessionExpired` when a WS frame carries `error_code` 600 or -102.
/// `Sources/Olaz/ZaloRuntime/ZaloEngine.swift:1267`
pub const WS_KICKED_REASON: &str = "Tài khoản đã đăng xuất hoặc đăng nhập trên thiết bị khác.";

/// Notice passed to `SessionExpired` when long-poll returns an auth error.
/// `Sources/Olaz/ZaloRuntime/ZaloEngine.swift:833`
pub const LP_EXPIRED_REASON: &str = "Phiên đăng nhập đã hết hạn hoặc bị đăng xuất.";

/// `Sources/Olaz/ZaloRuntime/ZaloEngine+Pins.swift:39`
const PIN_TOPIC_ACTS: &[&str] = &[
    "new_pin_topic",
    "update_pin_topic",
    "unpin_topic",
    "reorder_pin_topic",
];

/// `Sources/Olaz/ZaloRuntime/ZaloEngine+Pins.swift:42`
const FRIEND_PIN_TOPIC_ACTS: &[&str] =
    &["pin_create", "pin_unpin", "pin_reorder", "pin_force_sync"];

/// `Sources/Olaz/ZaloRuntime/Protocol/ZaloWireParser+GroupEvents.swift:66`
const GROUP_EVENT_NOTICE_ACTS: &[&str] = &[
    "join",
    "leave",
    "remove_member",
    "block_member",
    "update",
    "update_avatar",
    "add_admin",
    "remove_admin",
    "change_owner",
];

/// Parsed mobile-sync control item (mirrors Swift `ZaloMobileSyncEvent`).
#[derive(Clone, PartialEq, Eq)]
pub enum MobileSyncEvent {
    TransferAfterLogin {
        temp_key: String,
    },
    WaitingConfirmOnPhone {
        sync_id: String,
    },
    UserConfirmed,
    UserRejected,
    MobileBusy,
    UploadBatch {
        sync_id: String,
        url: String,
        batch_type: i64,
        idx: i64,
        is_last: bool,
    },
}

impl fmt::Debug for MobileSyncEvent {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TransferAfterLogin { temp_key } => f
                .debug_struct("TransferAfterLogin")
                .field("temp_key_len", &temp_key.len())
                .finish(),
            Self::WaitingConfirmOnPhone { sync_id } => f
                .debug_struct("WaitingConfirmOnPhone")
                .field("has_sync_id", &!sync_id.is_empty())
                .finish(),
            Self::UserConfirmed => f.write_str("UserConfirmed"),
            Self::UserRejected => f.write_str("UserRejected"),
            Self::MobileBusy => f.write_str("MobileBusy"),
            Self::UploadBatch {
                batch_type,
                idx,
                is_last,
                ..
            } => f
                .debug_struct("UploadBatch")
                .field("batch_type", batch_type)
                .field("idx", idx)
                .field("is_last", is_last)
                .finish(),
        }
    }
}

/// Ordered routing decisions produced by [`classify`] / [`classify_poll`].
#[derive(Clone, PartialEq)]
pub enum Route {
    SessionExpired {
        reason: String,
    },
    E2eeSignal {
        cmd: u16,
        payload: Map<String, Value>,
    },
    E2eeDeliverReports {
        cmd: u16,
        payload: Map<String, Value>,
    },
    LogSyncAck {
        cmd: u16,
        code: i64,
    },
    MobileSync(Vec<MobileSyncEvent>),
    RecordFileDone {
        file_id: String,
        url: String,
    },
    LogUndecodedControl {
        cmd: u16,
        encrypt: i64,
        data_is_string: bool,
    },
    VoipControl {
        act: String,
        raw_data: Value,
        data: Map<String, Value>,
    },
    LogTypingShape {
        shape: String,
    },
    ShowTyping {
        conv_id: String,
        uid: String,
        on_pc: bool,
    },
    PinTopic {
        conv_id: String,
    },
    GroupNotice {
        act: String,
        data: Map<String, Value>,
        ts: i64,
    },
    Mute {
        conv_id: String,
        set: bool,
        start: i64,
        duration: i64,
    },
    ApplyBatch {
        /// `Some(cmd)` on WS frames; `None` on long-poll responses (`ZaloEngine.swift:829`).
        cmd: Option<u16>,
        increment_unread: bool,
        notify_incoming: bool,
        payload: Map<String, Value>,
    },
}

impl fmt::Debug for Route {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::SessionExpired { reason } => f
                .debug_struct("SessionExpired")
                .field("reason_len", &reason.len())
                .finish(),
            Self::E2eeSignal { cmd, payload } => f
                .debug_struct("E2eeSignal")
                .field("cmd", cmd)
                .field("keys", &payload.len())
                .finish(),
            Self::E2eeDeliverReports { cmd, payload } => f
                .debug_struct("E2eeDeliverReports")
                .field("cmd", cmd)
                .field("keys", &payload.len())
                .finish(),
            Self::LogSyncAck { cmd, code } => f
                .debug_struct("LogSyncAck")
                .field("cmd", cmd)
                .field("code", code)
                .finish(),
            Self::MobileSync(events) => f.debug_tuple("MobileSync").field(events).finish(),
            Self::RecordFileDone { file_id, url } => f
                .debug_struct("RecordFileDone")
                .field("has_file_id", &!file_id.is_empty())
                .field("has_url", &!url.is_empty())
                .finish(),
            Self::LogUndecodedControl {
                cmd,
                encrypt,
                data_is_string,
            } => f
                .debug_struct("LogUndecodedControl")
                .field("cmd", cmd)
                .field("encrypt", encrypt)
                .field("data_is_string", data_is_string)
                .finish(),
            Self::VoipControl { act, .. } => {
                f.debug_struct("VoipControl").field("act", act).finish()
            }
            Self::LogTypingShape { shape } => f
                .debug_struct("LogTypingShape")
                .field("shape", shape)
                .finish(),
            Self::ShowTyping { on_pc, .. } => {
                f.debug_struct("ShowTyping").field("on_pc", on_pc).finish()
            }
            Self::PinTopic { conv_id } => f
                .debug_struct("PinTopic")
                .field("is_group", &is_group_id(conv_id))
                .finish(),
            Self::GroupNotice { act, ts, .. } => f
                .debug_struct("GroupNotice")
                .field("act", act)
                .field("ts", ts)
                .finish(),
            Self::Mute {
                set,
                start,
                duration,
                ..
            } => f
                .debug_struct("Mute")
                .field("set", set)
                .field("start", start)
                .field("duration", duration)
                .finish(),
            Self::ApplyBatch {
                cmd,
                increment_unread,
                notify_incoming,
                payload,
            } => f
                .debug_struct("ApplyBatch")
                .field("cmd", cmd)
                .field("increment_unread", increment_unread)
                .field("notify_incoming", notify_incoming)
                .field("keys", &payload.len())
                .finish(),
        }
    }
}

/// Returns whether a WS `cmd` counts as a live push (`incrementUnread` + `notifyIncoming`).
/// `Sources/Olaz/ZaloRuntime/ZaloEngine.swift:1310-1315`
#[must_use]
pub const fn is_ws_live_push(cmd: u16) -> bool {
    matches!(
        cmd,
        CMD_PUSH_MSG_11 | CMD_PUSH_MSG_GROUP | CMD_RECEIVE_ONE_ONE | CMD_RECEIVE_GROUP
    )
}

/// Returns whether a typed plain-chat WS `cmd` counts as a live push (`ZaloEngine.swift:1336-1339`).
#[must_use]
pub const fn is_typed_chat_live_push(cmd: u16) -> bool {
    matches!(cmd, CMD_PUSH_MSG_11 | CMD_PUSH_MSG_GROUP)
}

/// Pure classifier for one non-typed WebSocket frame (`ZaloEngine.handleWSEvent`).
///
/// Order matches Swift verbatim:
/// 1. Kicked check (`error_code` 600 / -102) -> early return
/// 2. `CMD_AUTHEN` (1) -> ignored, early return
/// 3. E2EE signal (`543 | 516 | 549`) -> early return (no-op if `my_uid` is empty)
/// 4. E2EE deliver reports (`553`) -> early return
/// 5. Sync ack log (`590 | 592`) -> falls through
/// 6. `mobile_sync` events (if non-empty)
/// 7. `processControlEnvelope`: `record_file_done` per item, undecoded `encrypt` log, then control
///    items in input order (voip, typing, pin_topic, group_notice, mute)
/// 8. `apply_batch` with `cmd: Some(cmd)` and `live = is_ws_live_push(cmd)`
#[must_use]
pub fn classify(
    cmd: u16,
    payload: Map<String, Value>,
    my_uid: &str,
    now_unix_secs: i64,
) -> Vec<Route> {
    if let Some(code) = int64(payload.get("error_code"))
        && (code == 600 || code == -102)
    {
        return vec![Route::SessionExpired {
            reason: WS_KICKED_REASON.to_owned(),
        }];
    }

    if cmd == CMD_AUTHEN {
        return Vec::new();
    }

    if matches!(
        cmd,
        CMD_INIT_SESSION | CMD_SESSION_OFFLINE | CMD_REQUEST_PRE_KEYS
    ) {
        if !my_uid.is_empty() {
            return vec![Route::E2eeSignal { cmd, payload }];
        }
        return Vec::new();
    }

    if cmd == CMD_DELIVER_SEEN_ONE_ONE {
        return vec![Route::E2eeDeliverReports { cmd, payload }];
    }

    let mut routes = Vec::new();

    if matches!(cmd, CMD_SYNC_REQUEST | CMD_SYNC_MOBILE_WAKE_UP) {
        let code = int64(payload.get("error_code")).unwrap_or(0);
        routes.push(Route::LogSyncAck { cmd, code });
    }

    let mobile_sync = extract_mobile_sync_events(&payload);
    if !mobile_sync.is_empty() {
        routes.push(Route::MobileSync(mobile_sync));
    }

    classify_controls(cmd, &payload, my_uid, now_unix_secs, &mut routes);

    let live = is_ws_live_push(cmd);
    routes.push(Route::ApplyBatch {
        cmd: Some(cmd),
        increment_unread: live,
        notify_incoming: live,
        payload,
    });

    routes
}

/// Pure classifier for one HTTP long-poll batch response (`ZaloEngine.drainChatPolling:824-829`).
///
/// Order matches Swift verbatim: `mobile_sync` -> `processControlEnvelope(cmd = 0)` ->
/// `apply_batch(cmd: None, increment_unread: notify_incoming, notify_incoming)`.
#[must_use]
pub fn classify_poll(
    payload: Map<String, Value>,
    my_uid: &str,
    now_unix_secs: i64,
    notify_incoming: bool,
) -> Vec<Route> {
    let mut routes = Vec::new();

    let mobile_sync = extract_mobile_sync_events(&payload);
    if !mobile_sync.is_empty() {
        routes.push(Route::MobileSync(mobile_sync));
    }

    classify_controls(0, &payload, my_uid, now_unix_secs, &mut routes);

    routes.push(Route::ApplyBatch {
        cmd: None,
        increment_unread: notify_incoming,
        notify_incoming,
        payload,
    });

    routes
}

/// Mirrors Swift `value as? [[String: Any]]`: yields the objects only if `value` is a JSON array
/// whose every element is a JSON object.
fn as_object_array(value: Option<&Value>) -> Option<Vec<&Map<String, Value>>> {
    let arr = value?.as_array()?;
    let mut out = Vec::with_capacity(arr.len());
    for item in arr {
        out.push(item.as_object()?);
    }
    Some(out)
}

/// Extracts `ZaloMobileSyncEvent` items (`ZaloPhoneSync.swift:1024-1115`).
#[must_use]
pub fn extract_mobile_sync_events(root: &Map<String, Value>) -> Vec<MobileSyncEvent> {
    let data_node = root.get("data").and_then(Value::as_object).unwrap_or(root);
    let mut candidates: Vec<&Map<String, Value>> = Vec::new();

    if let Some(controls) = as_object_array(data_node.get("controls")) {
        candidates.extend(controls);
    }
    if let Some(actions) = as_object_array(data_node.get("actions")) {
        candidates.extend(actions);
    }
    if let Some(data_arr) = as_object_array(root.get("data")) {
        for item in data_arr {
            if let Some(sub) = as_object_array(item.get("controls")) {
                candidates.extend(sub);
            } else {
                candidates.push(item);
            }
        }
    }
    if candidates.is_empty() {
        candidates.push(data_node);
    }

    let mut events = Vec::new();
    for item in candidates {
        let parsed_content: Option<Map<String, Value>>;
        let content_obj: &Map<String, Value> = match item.get("content") {
            Some(Value::Object(c)) => c,
            Some(Value::String(s)) => {
                parsed_content = parse_object_str(s);
                parsed_content.as_ref().unwrap_or(item)
            }
            _ => item,
        };

        let act_type = string(content_obj.get("act_type").or_else(|| item.get("act_type")));
        if !matches!(
            act_type.as_str(),
            "transfer_msg" | "syncmsgmb" | "transfer_sync2"
        ) {
            continue;
        }

        let act = string(
            content_obj
                .get("act")
                .or_else(|| item.get("act"))
                .or_else(|| item.get("action")),
        );

        let parsed_data_owned: Option<Map<String, Value>>;
        let empty_map = Map::new();
        let parsed_data: &Map<String, Value> = match content_obj.get("data") {
            Some(Value::Object(d)) => d,
            Some(Value::String(s)) => {
                let trimmed = s.trim();
                let wrapped = if trimmed.starts_with('{') {
                    trimmed.to_owned()
                } else {
                    format!("{{{trimmed}}}")
                };
                parsed_data_owned = parse_object_str(&wrapped);
                parsed_data_owned.as_ref().unwrap_or(&empty_map)
            }
            _ => &empty_map,
        };

        match act.as_str() {
            "transfer_after_login" => {
                let tk = string(parsed_data.get("temp_key")).trim().to_owned();
                if !tk.is_empty() {
                    events.push(MobileSyncEvent::TransferAfterLogin { temp_key: tk });
                }
            }
            "user_confirm" => {
                let ua = int64(parsed_data.get("user_action")).unwrap_or(-1);
                if ua == 1 || ua == 3 {
                    events.push(MobileSyncEvent::UserConfirmed);
                } else if ua == 2 {
                    events.push(MobileSyncEvent::MobileBusy);
                } else if ua == 0 {
                    events.push(MobileSyncEvent::UserRejected);
                }
            }
            "transfer_status" => {
                let st = int64(parsed_data.get("status")).unwrap_or(-1);
                let sid = string(parsed_data.get("syncId"));
                match st {
                    3 => events.push(MobileSyncEvent::WaitingConfirmOnPhone { sync_id: sid }),
                    4 | 5 => events.push(MobileSyncEvent::UserConfirmed),
                    6 | 7 => events.push(MobileSyncEvent::UserRejected),
                    8 => events.push(MobileSyncEvent::MobileBusy),
                    _ => {}
                }
            }
            "upload_batch" => {
                let url = string(parsed_data.get("msgUrl").or_else(|| parsed_data.get("url")))
                    .trim()
                    .to_owned();
                let sid = string(parsed_data.get("syncId")).trim().to_owned();
                if url.is_empty() || sid.is_empty() {
                    continue;
                }
                let batch_type = int64(parsed_data.get("batchType")).unwrap_or(0);
                let idx = int64(parsed_data.get("idx")).unwrap_or(-1);
                let is_last = int64(parsed_data.get("isLast")) == Some(1)
                    || parsed_data.get("isLast") == Some(&Value::Bool(true));
                events.push(MobileSyncEvent::UploadBatch {
                    sync_id: sid,
                    url,
                    batch_type,
                    idx,
                    is_last,
                });
            }
            _ => {}
        }
    }

    events
}

/// Mirrors `ZaloWireParser.pinTopicEventConversations` (`ZaloEngine+Pins.swift:46-61`).
#[must_use]
pub fn pin_topic_event_conversations(
    act_type: &str,
    act: &str,
    data: &Map<String, Value>,
) -> Vec<String> {
    if act_type == "fr" {
        if !FRIEND_PIN_TOPIC_ACTS.contains(&act) {
            return Vec::new();
        }
        let ids: Vec<String> = match data.get("conversationIds").and_then(Value::as_array) {
            Some(arr) => arr.iter().map(|v| string(Some(v))).collect(),
            None => vec![string(data.get("conversationId"))],
        };
        return ids
            .into_iter()
            .map(|id| strip_user_prefix(&id))
            .filter(|id| !id.is_empty() && id != "0")
            .collect();
    }

    if !(act_type.is_empty() || act_type == "group") || !PIN_TOPIC_ACTS.contains(&act) {
        return Vec::new();
    }
    let gid = string(
        data.get("groupId")
            .or_else(|| data.get("grid"))
            .or_else(|| data.get("gid")),
    );
    if gid.is_empty() || gid == "0" {
        return Vec::new();
    }
    let conv_id = group_conv_id(&gid);
    if conv_id.is_empty() {
        Vec::new()
    } else {
        vec![conv_id]
    }
}

/// Mirrors `ZaloEngine.processControlEnvelope` (`ZaloEngine.swift:1343-1430`).
fn classify_controls(
    cmd: u16,
    payload: &Map<String, Value>,
    my_uid: &str,
    now_unix_secs: i64,
    routes: &mut Vec<Route>,
) {
    for done in extract_file_done_events(payload) {
        routes.push(Route::RecordFileDone {
            file_id: done.file_id,
            url: done.url,
        });
    }

    let data_node = payload
        .get("data")
        .and_then(Value::as_object)
        .unwrap_or(payload);

    let mut control_items: Vec<&Map<String, Value>> = Vec::new();
    if let Some(controls) = as_object_array(data_node.get("controls")) {
        control_items.extend(controls);
    }
    if let Some(actions) = as_object_array(data_node.get("actions")) {
        control_items.extend(actions);
    }
    if let Some(data_arr) = as_object_array(payload.get("data")) {
        for item in data_arr {
            if let Some(sub) = as_object_array(item.get("controls")) {
                control_items.extend(sub);
            } else {
                control_items.push(item);
            }
        }
    }
    if control_items.is_empty()
        && (cmd == CMD_CTRL_PULL_VOIP || string(data_node.get("act_type")) == "voip")
    {
        control_items.push(data_node);
    }

    if payload.contains_key("encrypt") {
        routes.push(Route::LogUndecodedControl {
            cmd,
            encrypt: int64(payload.get("encrypt")).unwrap_or(-1),
            data_is_string: matches!(payload.get("data"), Some(Value::String(_))),
        });
    }

    for ctrl in control_items {
        let parsed_content: Option<Map<String, Value>>;
        let content_obj: &Map<String, Value> = match ctrl.get("content") {
            Some(Value::Object(c)) => c,
            Some(Value::String(s)) => {
                parsed_content = parse_object_str(s);
                parsed_content.as_ref().unwrap_or(ctrl)
            }
            _ => ctrl,
        };

        let act_type = string(content_obj.get("act_type").or_else(|| ctrl.get("act_type")));
        let act = string(
            content_obj
                .get("act")
                .or_else(|| ctrl.get("act"))
                .or_else(|| ctrl.get("action")),
        );

        let parsed_act_data: Option<Map<String, Value>>;
        let act_data: &Map<String, Value> = match content_obj.get("data") {
            Some(Value::Object(d)) => d,
            Some(Value::String(s)) => {
                let trimmed = s.trim();
                let wrapped = if trimmed.starts_with('{') || trimmed.starts_with('[') {
                    trimmed.to_owned()
                } else {
                    format!("{{{trimmed}}}")
                };
                parsed_act_data = parse_object_str(&wrapped);
                parsed_act_data.as_ref().unwrap_or(content_obj)
            }
            _ => content_obj,
        };

        if act_type == "voip" || cmd == CMD_CTRL_PULL_VOIP {
            let raw_data = content_obj
                .get("data")
                .cloned()
                .unwrap_or_else(|| Value::Object(act_data.clone()));
            routes.push(Route::VoipControl {
                act,
                raw_data,
                data: act_data.clone(),
            });
        } else if act_type == "typing" || act == "typing" || act == "gtyping" {
            let uid = strip_user_prefix(&string(
                act_data.get("uid").or_else(|| act_data.get("uidFrom")),
            ));
            let gid = string(act_data.get("gid").or_else(|| act_data.get("grid")));
            let conv_id = if !gid.is_empty() || act == "gtyping" {
                let raw_gid = if gid.is_empty() { &uid } else { &gid };
                group_conv_id(raw_gid)
            } else {
                uid.clone()
            };

            let shape = format_typing_shape(&act, act_data);
            routes.push(Route::LogTypingShape { shape });

            if !conv_id.is_empty() && uid != my_uid {
                let on_pc = int64(act_data.get("isPC")) == Some(1);
                routes.push(Route::ShowTyping {
                    conv_id,
                    uid,
                    on_pc,
                });
            }
        } else {
            let pin_convs = pin_topic_event_conversations(&act_type, &act, act_data);
            if !pin_convs.is_empty() {
                for conv_id in pin_convs {
                    routes.push(Route::PinTopic { conv_id });
                }
            } else if act_type == "group" && GROUP_EVENT_NOTICE_ACTS.contains(&act.as_str()) {
                let ts = int64(
                    ctrl.get("ts")
                        .or_else(|| content_obj.get("ts"))
                        .or_else(|| act_data.get("ts")),
                )
                .unwrap_or(0);
                routes.push(Route::GroupNotice {
                    act,
                    data: act_data.clone(),
                    ts,
                });
            } else if act_type == "mute" {
                let raw_id = string(
                    act_data
                        .get("toId")
                        .or_else(|| act_data.get("toid"))
                        .or_else(|| act_data.get("id")),
                );
                let mute_type = int64(act_data.get("muteType")).unwrap_or(1);
                let is_grp = mute_type == 2 || is_group_id(&raw_id);
                let conv_id = if is_grp {
                    group_conv_id(&raw_id)
                } else {
                    strip_user_prefix(&raw_id)
                };
                let duration = int64(act_data.get("duration")).unwrap_or(-1);
                let mute_mode = int64(act_data.get("muteMode")).unwrap_or(1);
                let start = int64(
                    act_data
                        .get("startTime")
                        .or_else(|| act_data.get("systemTime")),
                )
                .unwrap_or(now_unix_secs);
                let is_set = (act == "set"
                    || (act != "unset" && int64(act_data.get("action")) == Some(1)))
                    && mute_mode == 1
                    && duration != 0;
                if !conv_id.is_empty() {
                    routes.push(Route::Mute {
                        conv_id,
                        set: is_set,
                        start,
                        duration,
                    });
                }
            }
        }
    }
}

/// Formats the shape-only typing diagnostic (`ZaloEngine.swift:1399`):
/// `"\(act) keys=\(actData.keys.sorted().joined(separator: ",")) isPC=\(actData["isPC"] ?? "nil")"`.
fn format_typing_shape(act: &str, act_data: &Map<String, Value>) -> String {
    let mut keys: Vec<&str> = act_data.keys().map(String::as_str).collect();
    keys.sort_unstable();
    let is_pc = match act_data.get("isPC") {
        None => "nil".to_owned(),
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        Some(Value::Null) => "<null>".to_owned(),
        Some(other) => other.to_string(),
    };
    format!("{act} keys={} isPC={is_pc}", keys.join(","))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn obj(value: Value) -> Map<String, Value> {
        value.as_object().cloned().unwrap_or_default()
    }

    #[test]
    fn kicked_error_codes_600_and_minus_102_short_circuit_everything() {
        for code in [600_i64, -102_i64] {
            let routes = classify(
                CMD_PUSH_MSG_11,
                obj(json!({ "error_code": code, "data": { "msgs": [] } })),
                "100",
                1_700_000_000,
            );
            assert_eq!(
                routes,
                vec![Route::SessionExpired {
                    reason: WS_KICKED_REASON.to_owned(),
                }]
            );
        }
        // String error_code also parsed via JSONLossless.int64.
        let routes = classify(
            CMD_AUTHEN,
            obj(json!({ "error_code": "-102" })),
            "100",
            1_700_000_000,
        );
        assert_eq!(
            routes,
            vec![Route::SessionExpired {
                reason: WS_KICKED_REASON.to_owned(),
            }]
        );
    }

    #[test]
    fn cmd_authen_is_ignored() {
        let routes = classify(
            CMD_AUTHEN,
            obj(json!({ "error_code": 0, "data": { "key": "secret" } })),
            "100",
            1_700_000_000,
        );
        assert!(routes.is_empty());
    }

    #[test]
    fn e2ee_signal_cmds_route_only_when_my_uid_present_and_skip_batch() {
        for cmd in [CMD_INIT_SESSION, CMD_SESSION_OFFLINE, CMD_REQUEST_PRE_KEYS] {
            let payload = obj(json!({ "data": { "uid": "200" } }));
            let routes = classify(cmd, payload.clone(), "100", 1_700_000_000);
            assert_eq!(routes, vec![Route::E2eeSignal { cmd, payload }]);

            // Empty my_uid returns empty (no batch).
            let empty_uid = classify(cmd, obj(json!({ "data": {} })), "", 1_700_000_000);
            assert!(empty_uid.is_empty());
        }
    }

    #[test]
    fn e2ee_deliver_reports_short_circuits_without_batch() {
        let payload = obj(json!({ "data": { "deliver": [] } }));
        let routes = classify(CMD_DELIVER_SEEN_ONE_ONE, payload.clone(), "", 1_700_000_000);
        assert_eq!(
            routes,
            vec![Route::E2eeDeliverReports {
                cmd: CMD_DELIVER_SEEN_ONE_ONE,
                payload,
            }]
        );
    }

    #[test]
    fn sync_ack_590_and_592_log_and_fall_through() {
        for (cmd, code) in [(CMD_SYNC_REQUEST, 0_i64), (CMD_SYNC_MOBILE_WAKE_UP, 17_i64)] {
            let payload = obj(json!({ "error_code": code }));
            let routes = classify(cmd, payload.clone(), "100", 1_700_000_000);
            assert_eq!(
                routes,
                vec![
                    Route::LogSyncAck { cmd, code },
                    Route::ApplyBatch {
                        cmd: Some(cmd),
                        increment_unread: false,
                        notify_incoming: false,
                        payload,
                    }
                ]
            );
        }
    }

    #[test]
    fn frame_order_is_mobile_sync_then_file_done_then_controls_then_batch() {
        let payload = obj(json!({
            "data": {
                "controls": [
                    {
                        "act_type": "transfer_msg",
                        "act": "transfer_after_login",
                        "data": { "temp_key": " tk_abc " }
                    },
                    {
                        "act_type": "file_done",
                        "data": { "fileId": "f1", "url": "https://cdn.example/f1.jpg" }
                    },
                    {
                        "act_type": "typing",
                        "act": "typing",
                        "data": { "uid": "202", "isPC": 1 }
                    },
                    {
                        "act_type": "fr",
                        "act": "pin_create",
                        "data": { "conversationId": "202" }
                    }
                ]
            }
        }));
        let routes = classify(601, payload.clone(), "100", 1_700_000_000);
        assert_eq!(
            routes,
            vec![
                Route::MobileSync(vec![MobileSyncEvent::TransferAfterLogin {
                    temp_key: "tk_abc".to_owned(),
                }]),
                Route::RecordFileDone {
                    file_id: "f1".to_owned(),
                    url: "https://cdn.example/f1.jpg".to_owned(),
                },
                Route::LogTypingShape {
                    shape: "typing keys=isPC,uid isPC=1".to_owned(),
                },
                Route::ShowTyping {
                    conv_id: "202".to_owned(),
                    uid: "202".to_owned(),
                    on_pc: true,
                },
                Route::PinTopic {
                    conv_id: "202".to_owned(),
                },
                Route::ApplyBatch {
                    cmd: Some(601),
                    increment_unread: false,
                    notify_incoming: false,
                    payload,
                },
            ]
        );
    }

    #[test]
    fn mobile_sync_extracts_all_act_types_and_variants() {
        let payload = obj(json!({
            "data": {
                "actions": [
                    {
                        "act_type": "syncmsgmb",
                        "act": "user_confirm",
                        "data": "\"user_action\":3"
                    },
                    {
                        "act_type": "transfer_sync2",
                        "act": "user_confirm",
                        "data": { "user_action": 2 }
                    },
                    {
                        "act_type": "transfer_msg",
                        "act": "user_confirm",
                        "data": { "user_action": 0 }
                    },
                    {
                        "act_type": "transfer_msg",
                        "act": "transfer_status",
                        "data": { "status": 3, "syncId": "s3" }
                    },
                    {
                        "act_type": "transfer_msg",
                        "act": "transfer_status",
                        "data": { "status": 5 }
                    },
                    {
                        "act_type": "transfer_msg",
                        "act": "transfer_status",
                        "data": { "status": 7 }
                    },
                    {
                        "act_type": "transfer_msg",
                        "act": "transfer_status",
                        "data": { "status": 8 }
                    },
                    {
                        "act_type": "transfer_msg",
                        "act": "upload_batch",
                        "data": {
                            "syncId": "s9",
                            "msgUrl": "https://cdn.example/b.bin",
                            "batchType": 2,
                            "idx": 4,
                            "isLast": 1
                        }
                    },
                    {
                        "act_type": "transfer_msg",
                        "act": "upload_batch",
                        "data": {
                            "syncId": "s10",
                            "url": "https://cdn.example/c.bin",
                            "isLast": true
                        }
                    },
                    {
                        "act_type": "transfer_msg",
                        "act": "upload_batch",
                        "data": { "syncId": "missing_url" }
                    }
                ]
            }
        }));
        let events = extract_mobile_sync_events(&payload);
        assert_eq!(
            events,
            vec![
                MobileSyncEvent::UserConfirmed,
                MobileSyncEvent::MobileBusy,
                MobileSyncEvent::UserRejected,
                MobileSyncEvent::WaitingConfirmOnPhone {
                    sync_id: "s3".to_owned(),
                },
                MobileSyncEvent::UserConfirmed,
                MobileSyncEvent::UserRejected,
                MobileSyncEvent::MobileBusy,
                MobileSyncEvent::UploadBatch {
                    sync_id: "s9".to_owned(),
                    url: "https://cdn.example/b.bin".to_owned(),
                    batch_type: 2,
                    idx: 4,
                    is_last: true,
                },
                MobileSyncEvent::UploadBatch {
                    sync_id: "s10".to_owned(),
                    url: "https://cdn.example/c.bin".to_owned(),
                    batch_type: 0,
                    idx: -1,
                    is_last: true,
                },
            ]
        );
    }

    #[test]
    fn typing_1on1_group_with_and_without_gid_own_uid_and_is_pc() {
        let payload = obj(json!({
            "data": {
                "controls": [
                    { "act_type": "typing", "act": "typing", "data": { "uid": "201", "isPC": 1 } },
                    { "act_type": "typing", "act": "gtyping", "data": { "uid": "202", "gid": "9001" } },
                    { "act_type": "typing", "act": "gtyping", "data": { "uid": "9002" } },
                    { "act_type": "typing", "act": "typing", "data": { "uid": "100", "isPC": 0 } }
                ]
            }
        }));
        let routes = classify(601, payload, "100", 1_700_000_000);
        let typing_routes: Vec<_> = routes
            .iter()
            .filter(|r| matches!(r, Route::ShowTyping { .. }))
            .cloned()
            .collect();
        assert_eq!(
            typing_routes,
            vec![
                Route::ShowTyping {
                    conv_id: "201".to_owned(),
                    uid: "201".to_owned(),
                    on_pc: true,
                },
                Route::ShowTyping {
                    conv_id: "g9001".to_owned(),
                    uid: "202".to_owned(),
                    on_pc: false,
                },
                Route::ShowTyping {
                    conv_id: "g9002".to_owned(),
                    uid: "9002".to_owned(),
                    on_pc: false,
                },
            ]
        );
        // Own uid still emits LogTypingShape (matches Swift logging before uid != myUid).
        let shapes: Vec<_> = routes
            .iter()
            .filter_map(|r| match r {
                Route::LogTypingShape { shape } => Some(shape.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(
            shapes,
            vec![
                "typing keys=isPC,uid isPC=1",
                "gtyping keys=gid,uid isPC=nil",
                "gtyping keys=uid isPC=nil",
                "typing keys=isPC,uid isPC=0",
            ]
        );
    }

    #[test]
    fn voip_control_and_cmd_604_empty_controls_fallback() {
        // Explicit act_type == "voip" inside controls.
        let p1 = obj(json!({
            "data": {
                "controls": [
                    { "act_type": "voip", "act": "request", "data": { "callId": "c1" } }
                ]
            }
        }));
        let r1 = classify(601, p1, "100", 0);
        assert!(matches!(
            r1.first(),
            Some(Route::VoipControl { act, raw_data, data })
                if act == "request"
                    && raw_data == &json!({ "callId": "c1" })
                    && data.get("callId") == Some(&json!("c1"))
        ));

        // cmd == 604 with no controls/actions uses dataNode itself as the item.
        let p2 = obj(json!({
            "data": { "act": "group_request", "data": "{\"callId\":\"c2\"}" }
        }));
        let r2 = classify(CMD_CTRL_PULL_VOIP, p2, "100", 0);
        assert!(matches!(
            r2.first(),
            Some(Route::VoipControl { act, raw_data, data })
                if act == "group_request"
                    && raw_data == &json!("{\"callId\":\"c2\"}")
                    && data.get("callId") == Some(&json!("c2"))
        ));
    }

    #[test]
    fn pin_topic_handles_friend_multi_and_group_and_ignores_invalid() {
        let payload = obj(json!({
            "data": {
                "controls": [
                    {
                        "act_type": "fr",
                        "act": "pin_force_sync",
                        "data": { "conversationIds": ["301", "0", "", " 302 "] }
                    },
                    {
                        "act_type": "group",
                        "act": "new_pin_topic",
                        "data": { "groupId": "777" }
                    },
                    {
                        "act_type": "",
                        "act": "unpin_topic",
                        "data": { "grid": "g888" }
                    },
                    {
                        "act_type": "fr",
                        "act": "unknown_pin",
                        "data": { "conversationId": "303" }
                    }
                ]
            }
        }));
        let routes = classify(601, payload, "100", 0);
        let pins: Vec<_> = routes
            .into_iter()
            .filter_map(|r| match r {
                Route::PinTopic { conv_id } => Some(conv_id),
                _ => None,
            })
            .collect();
        assert_eq!(pins, vec!["301", "302", "g777", "g888"]);
    }

    #[test]
    fn group_notice_checks_act_set_and_ts_precedence() {
        let payload = obj(json!({
            "data": {
                "controls": [
                    {
                        "act_type": "group",
                        "act": "join",
                        "ts": 111,
                        "data": { "groupId": "50", "ts": 222 }
                    },
                    {
                        "act_type": "group",
                        "act": "change_owner",
                        "data": { "groupId": "50", "ts": 333 }
                    },
                    {
                        "act_type": "group",
                        "act": "not_a_notice",
                        "ts": 444,
                        "data": { "groupId": "50" }
                    }
                ]
            }
        }));
        let routes = classify(601, payload, "100", 0);
        let notices: Vec<_> = routes
            .into_iter()
            .filter_map(|r| match r {
                Route::GroupNotice { act, ts, .. } => Some((act, ts)),
                _ => None,
            })
            .collect();
        assert_eq!(
            notices,
            vec![("join".to_owned(), 111), ("change_owner".to_owned(), 333),]
        );
    }

    #[test]
    fn mute_covers_set_unset_mode2_duration0_group_detection_and_start_fallbacks() {
        let now = 1_700_000_555_i64;
        let payload = obj(json!({
            "data": {
                "controls": [
                    // set with duration + explicit startTime
                    {
                        "act_type": "mute",
                        "act": "set",
                        "data": { "toId": "401", "duration": 3600, "startTime": 1000 }
                    },
                    // unset
                    {
                        "act_type": "mute",
                        "act": "unset",
                        "data": { "toId": "402", "action": 1, "systemTime": 2000 }
                    },
                    // muteMode 2 -> not set
                    {
                        "act_type": "mute",
                        "act": "set",
                        "data": { "toId": "403", "muteMode": 2, "duration": 600 }
                    },
                    // duration 0 -> not set
                    {
                        "act_type": "mute",
                        "act": "set",
                        "data": { "toId": "404", "duration": 0 }
                    },
                    // group by muteType 2 (action == 1 without act=="set"), fallback start -> systemTime
                    {
                        "act_type": "mute",
                        "act": "update",
                        "data": { "toid": "555", "muteType": 2, "action": 1, "systemTime": 3000 }
                    },
                    // group by id shape (group_666), fallback start -> now
                    {
                        "act_type": "mute",
                        "act": "set",
                        "data": { "id": "group_666", "duration": -1 }
                    }
                ]
            }
        }));
        let routes = classify(601, payload, "100", now);
        let mutes: Vec<_> = routes
            .into_iter()
            .filter(|r| matches!(r, Route::Mute { .. }))
            .collect();
        assert_eq!(
            mutes,
            vec![
                Route::Mute {
                    conv_id: "401".to_owned(),
                    set: true,
                    start: 1000,
                    duration: 3600,
                },
                Route::Mute {
                    conv_id: "402".to_owned(),
                    set: false,
                    start: 2000,
                    duration: -1,
                },
                Route::Mute {
                    conv_id: "403".to_owned(),
                    set: false,
                    start: now,
                    duration: 600,
                },
                Route::Mute {
                    conv_id: "404".to_owned(),
                    set: false,
                    start: now,
                    duration: 0,
                },
                Route::Mute {
                    conv_id: "g555".to_owned(),
                    set: true,
                    start: 3000,
                    duration: -1,
                },
                Route::Mute {
                    conv_id: "g666".to_owned(),
                    set: true,
                    start: now,
                    duration: -1,
                },
            ]
        );
    }

    #[test]
    fn control_shapes_cover_data_array_nested_controls_string_content_braceless_data_and_encrypt() {
        let payload = obj(json!({
            "encrypt": 2,
            "data": [
                {
                    "controls": [
                        {
                            "content": "{\"act_type\":\"typing\",\"act\":\"typing\",\"data\":\"\\\"uid\\\":\\\"801\\\",\\\"isPC\\\":1\"}"
                        }
                    ]
                },
                {
                    "act_type": "fr",
                    "act": "pin_unpin",
                    "data": "\"conversationId\":\"802\""
                }
            ]
        }));
        let routes = classify(601, payload, "100", 0);
        assert!(routes.contains(&Route::LogUndecodedControl {
            cmd: 601,
            encrypt: 2,
            data_is_string: false,
        }));
        assert!(routes.contains(&Route::ShowTyping {
            conv_id: "801".to_owned(),
            uid: "801".to_owned(),
            on_pc: true,
        }));
        assert!(routes.contains(&Route::PinTopic {
            conv_id: "802".to_owned(),
        }));
    }

    #[test]
    fn live_vs_pull_flags_and_classify_poll_cmd_is_none() {
        for cmd in [
            CMD_PUSH_MSG_11,
            CMD_PUSH_MSG_GROUP,
            CMD_RECEIVE_ONE_ONE,
            CMD_RECEIVE_GROUP,
        ] {
            let routes = classify(cmd, obj(json!({})), "100", 0);
            assert!(matches!(
                routes.last(),
                Some(Route::ApplyBatch {
                    cmd: Some(c),
                    increment_unread: true,
                    notify_incoming: true,
                    ..
                }) if *c == cmd
            ));
        }

        for cmd in [510_u16, 511_u16, 532_u16] {
            let routes = classify(cmd, obj(json!({})), "100", 0);
            assert!(matches!(
                routes.last(),
                Some(Route::ApplyBatch {
                    cmd: Some(c),
                    increment_unread: false,
                    notify_incoming: false,
                    ..
                }) if *c == cmd
            ));
        }

        let poll_payload = obj(json!({
            "data": {
                "controls": [
                    { "act_type": "transfer_msg", "act": "user_confirm", "data": { "user_action": 1 } },
                    { "act_type": "fr", "act": "pin_reorder", "data": { "conversationId": "901" } }
                ]
            }
        }));
        let poll_live = classify_poll(poll_payload.clone(), "100", 0, true);
        assert_eq!(
            poll_live,
            vec![
                Route::MobileSync(vec![MobileSyncEvent::UserConfirmed]),
                Route::PinTopic {
                    conv_id: "901".to_owned(),
                },
                Route::ApplyBatch {
                    cmd: None,
                    increment_unread: true,
                    notify_incoming: true,
                    payload: poll_payload.clone(),
                },
            ]
        );

        let poll_quiet = classify_poll(poll_payload, "100", 0, false);
        assert!(matches!(
            poll_quiet.last(),
            Some(Route::ApplyBatch {
                cmd: None,
                increment_unread: false,
                notify_incoming: false,
                ..
            })
        ));
    }
}

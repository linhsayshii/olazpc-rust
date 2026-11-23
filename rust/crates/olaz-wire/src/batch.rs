//! `extractBatchEvents`, `extractProfilesMap` and `sortReactionEventsChronologically`.

use std::borrow::Cow;
use std::collections::HashMap;

use serde_json::{Map, Value};

use crate::ids::{
    clean_group_id, group_conv_id, is_group_id, sanitize_profile_uid, strip_user_prefix,
};
use crate::lossless::{self, int64, string};
use crate::message::{WireParseOptions, optional_timestamp_ms, parse_nested, parse_wire_message};
use crate::model::ParsedWireEvent;
use crate::util::{as_dict, as_dict_array, first_non_empty, pick, pick_opt};

/// `unwrapValue`: a string holding a JSON object / array is parsed (losslessly); everything else is unchanged.
fn unwrap_value(v: &Value) -> Cow<'_, Value> {
    if let Value::String(s) = v
        && let Some(parsed) = parse_nested(s)
    {
        return Cow::Owned(parsed);
    }
    Cow::Borrowed(v)
}

struct Walker<'a> {
    my_uid: &'a str,
    opts: WireParseOptions<'a>,
    events: Vec<ParsedWireEvent>,
}

impl Walker<'_> {
    fn self_conv(&self) -> Option<&str> {
        self.opts.self_conv_id
    }

    fn ingest_reactions(
        &mut self,
        list: &[&Map<String, Value>],
        is_group: bool,
        fallback_hint: Option<&str>,
    ) {
        for r in list {
            let c_raw = r.get("content").map(unwrap_value);
            let c_dict: Option<&Map<String, Value>> = c_raw.as_deref().and_then(Value::as_object);
            let sender = strip_user_prefix(&string(
                pick(r, &["uidFrom", "fromUid", "senderId"])
                    .or_else(|| pick_opt(c_dict, &["uidFrom", "fromUid"])),
            ));
            let to_raw = match pick(r, &["idTo", "toId", "grid", "groupId"]) {
                Some(v) => string(Some(v)),
                None => fallback_hint.unwrap_or("").to_string(),
            };
            let clean_to = strip_user_prefix(&to_raw);
            let self_conv = self.self_conv();
            let conv_id: String = 'conv: {
                if is_group {
                    let g = group_conv_id(&to_raw);
                    break 'conv if g.is_empty() {
                        fallback_hint.unwrap_or("").to_string()
                    } else {
                        g
                    };
                }
                if sender == self.my_uid || sender == "0" || sender.is_empty() {
                    let to_blank = to_raw == "0" || to_raw.is_empty();
                    let to_self =
                        self_conv.is_some_and(|s| clean_to == s || clean_to == self.my_uid);
                    if to_blank || to_self {
                        break 'conv first_non_empty(&[
                            self_conv.unwrap_or(""),
                            fallback_hint.unwrap_or(""),
                            if to_blank { "" } else { &clean_to },
                        ]);
                    }
                    break 'conv clean_to.clone();
                }
                sender.clone()
            };
            if conv_id.is_empty() {
                continue;
            }
            let msg_id = string(pick_opt(c_dict, &["gMsgID", "msgId", "globalMsgId"]));
            let cli_msg_id = string(pick_opt(c_dict, &["cMsgID", "cliMsgId", "clientId"]));
            let r_icon = string(c_dict.and_then(|c| c.get("rIcon")).or(r.get("rIcon")));
            let r_type = string(c_dict.and_then(|c| c.get("rType")).or(r.get("rType")));
            if r_type.is_empty() && r_icon.is_empty() {
                continue;
            }
            let base_event_id = first_non_empty(&[
                &string(r.get("actionId")),
                &string(r.get("msgId")),
                &string(r.get("cliMsgId")),
            ]);
            let react_client_id = string(pick(r, &["cliMsgId", "clientId"]));
            let ts_ms = optional_timestamp_ms(
                pick(r, &["ts", "time", "sendTime"]).or_else(|| pick_opt(c_dict, &["ts"])),
            );
            let seq_id = int64(pick(r, &["actionId", "msgId", "cliMsgId"])).unwrap_or(0);
            let sender_name =
                string(pick(r, &["dName", "senderName"]).or_else(|| pick_opt(c_dict, &["dName"])));

            let r_msg_raw: Option<Cow<'_, Value>> =
                c_dict.and_then(|c| c.get("rMsg")).map(unwrap_value);
            let r_msgs: Vec<&Map<String, Value>> = match r_msg_raw.as_deref() {
                Some(Value::Array(a)) => a.iter().filter_map(Value::as_object).collect(),
                Some(Value::Object(m)) => vec![m],
                _ => Vec::new(),
            };

            let mut push = |gid: String, cid: String| {
                self.events.push(ParsedWireEvent::Reaction {
                    conv_id: conv_id.clone(),
                    msg_id: gid,
                    cli_msg_id: cid,
                    sender_id: sender.clone(),
                    r_type: r_type.clone(),
                    r_icon: r_icon.clone(),
                    event_id: base_event_id.clone(),
                    react_client_id: react_client_id.clone(),
                    ts_ms,
                    seq_id,
                    sender_name: sender_name.clone(),
                });
            };
            if !r_msgs.is_empty() {
                for rm in r_msgs {
                    let gid = match pick(rm, &["gMsgID", "msgId", "globalMsgId"]) {
                        Some(v) => string(Some(v)),
                        None => msg_id.clone(),
                    };
                    let cid = match pick(rm, &["cMsgID", "cliMsgId", "clientId"]) {
                        Some(v) => string(Some(v)),
                        None => cli_msg_id.clone(),
                    };
                    if gid.is_empty() && cid.is_empty() {
                        continue;
                    }
                    push(gid, cid);
                }
            } else if !msg_id.is_empty() || !cli_msg_id.is_empty() {
                push(msg_id, cli_msg_id);
            }
        }
    }

    fn walk(
        &mut self,
        node: &Value,
        hint_conv: Option<&str>,
        hint_group: Option<bool>,
        depth: usize,
    ) {
        if depth >= 8 {
            return;
        }
        let val = unwrap_value(node);

        if let Value::Array(arr) = val.as_ref() {
            for el in arr {
                self.walk(el, hint_conv, hint_group, depth + 1);
            }
            return;
        }
        let Value::Object(dict) = val.as_ref() else {
            return;
        };

        if let Some(data_val) = dict.get("data") {
            let unwrapped = unwrap_value(data_val);
            if matches!(unwrapped.as_ref(), Value::Object(_) | Value::Array(_)) {
                self.walk(unwrapped.as_ref(), hint_conv, hint_group, depth + 1);
            }
        }

        // Live reactions arrays (`reacts`, `reactGroups`)
        if let Some(reacts) = as_dict_array(dict.get("reacts")) {
            self.ingest_reactions(&reacts, false, hint_conv);
        }
        if let Some(groups) = as_dict_array(dict.get("reactGroups")) {
            self.ingest_reactions(&groups, true, hint_conv);
        }

        // Derive thread hint if this dict is a thread wrapper
        let raw_thread_id = string(pick(
            dict,
            &["threadId", "groupId", "grid", "peerId", "userId", "uid"],
        ));
        let valid_thread_id = if !raw_thread_id.is_empty()
            && raw_thread_id != "0"
            && clean_group_id(&raw_thread_id) != "0"
        {
            raw_thread_id.clone()
        } else {
            String::new()
        };
        let raw_group_field = string(pick(dict, &["groupId", "grid"]));
        let has_valid_group_field =
            !raw_group_field.is_empty() && clean_group_id(&raw_group_field) != "0";
        let wrapper_is_group: Option<bool> = 'wg: {
            if let Some(t) = int64(pick(dict, &["type", "convType"])) {
                if t == 1 {
                    break 'wg Some(true);
                }
                if t == 0 {
                    break 'wg Some(false);
                }
            }
            if let Some(b) = lossless::bool(dict.get("isGroup")) {
                break 'wg Some(b);
            }
            if has_valid_group_field || is_group_id(&valid_thread_id) {
                break 'wg Some(true);
            }
            hint_group
        };
        let next_conv_hint: Option<String> = 'hint: {
            if !valid_thread_id.is_empty() {
                if wrapper_is_group == Some(true)
                    || valid_thread_id.starts_with('g')
                    || valid_thread_id.starts_with("group_")
                {
                    let g = group_conv_id(&valid_thread_id);
                    if !g.is_empty() {
                        break 'hint Some(g);
                    }
                } else {
                    let u = strip_user_prefix(&valid_thread_id);
                    if !u.is_empty() && u != "0" {
                        break 'hint Some(u);
                    }
                }
            }
            hint_conv.map(str::to_string)
        };

        // Check if this dict itself looks like a single wire message
        let has_message_fields = dict.contains_key("msgId")
            || dict.contains_key("globalMsgId")
            || dict.contains_key("cliMsgId")
            || dict.contains_key("msgType")
            || (dict.contains_key("content")
                && (dict.contains_key("uidFrom")
                    || dict.contains_key("idTo")
                    || dict.contains_key("senderId")));
        if has_message_fields {
            let fallback = next_conv_hint.as_deref().or(self.opts.fallback_conv_id);
            let opts = WireParseOptions {
                cmd: self.opts.cmd,
                fallback_conv_id: fallback,
                is_group_hint: wrapper_is_group.or(hint_group),
                self_conv_id: self.opts.self_conv_id,
                name_lookup: self.opts.name_lookup,
            };
            let ev = parse_wire_message(dict, self.my_uid, &opts);
            if !matches!(ev, ParsedWireEvent::Ignore) {
                self.events.push(ev);
            }
        }

        // Check array containers
        for key in [
            "groupMsgs",
            "pageMsgs",
            "conversations",
            "threads",
            "allmsgs",
            "messages",
            "items",
            "list",
        ] {
            if let Some(sub) = dict.get(key) {
                let key_is_group: Option<bool> = if key == "groupMsgs" {
                    Some(
                        !(next_conv_hint.is_some()
                            && next_conv_hint.as_deref() == self.opts.self_conv_id),
                    )
                } else {
                    hint_group.or(wrapper_is_group)
                };
                self.walk(sub, next_conv_hint.as_deref(), key_is_group, depth + 1);
            }
        }
        if let Some(msgs_val) = dict.get("msgs") {
            let unwrapped = unwrap_value(msgs_val);
            match unwrapped.as_ref() {
                Value::Array(_) => {
                    let msgs_is_group = wrapper_is_group.or(if dict.contains_key("groupMsgs") {
                        Some(false)
                    } else {
                        None
                    });
                    self.walk(
                        unwrapped.as_ref(),
                        next_conv_hint.as_deref(),
                        msgs_is_group,
                        depth + 1,
                    );
                }
                Value::Object(map) => {
                    for (k, list_val) in map {
                        let k_is_grp =
                            k.starts_with('g') || k.starts_with("group_") || is_group_id(k);
                        let k_conv = if k_is_grp {
                            group_conv_id(k)
                        } else {
                            strip_user_prefix(k)
                        };
                        self.walk(list_val, Some(&k_conv), Some(k_is_grp), depth + 1);
                    }
                }
                _ => {}
            }
        }

        // Direct nested lastMsg / message
        for key in ["lastMsg", "message"] {
            if let Some(sub @ Value::Object(_)) = dict.get(key) {
                self.walk(sub, next_conv_hint.as_deref(), wrapper_is_group, depth + 1);
            }
        }
    }
}

/// Walks a decoded envelope (history response, push body, polling result) and parses every wire message and
/// live reaction it contains. `opts.cmd` is `defaultCmd`; `opts.fallback_conv_id` / `is_group_hint` seed the walk.
pub fn extract_batch_events(
    root: &Value,
    my_uid: &str,
    opts: &WireParseOptions<'_>,
) -> Vec<ParsedWireEvent> {
    let mut w = Walker {
        my_uid,
        opts: *opts,
        events: Vec::new(),
    };
    w.walk(root, opts.fallback_conv_id, opts.is_group_hint, 0);
    w.events
}

/// `sortReactionEventsChronologically`: returns only the `Reaction` events, grouped by `(conv, target msg)` in
/// first-seen order and sorted ascending by time (or action id) within each group.
pub fn sort_reaction_events_chronologically(events: &[ParsedWireEvent]) -> Vec<ParsedWireEvent> {
    struct Indexed<'a> {
        index: usize,
        ts_ms: i64,
        seq_id: i64,
        event: &'a ParsedWireEvent,
    }
    let mut grouped: HashMap<String, Vec<Indexed<'_>>> = HashMap::new();
    let mut order: Vec<String> = Vec::new();
    for (idx, ev) in events.iter().enumerate() {
        let ParsedWireEvent::Reaction {
            conv_id,
            msg_id,
            cli_msg_id,
            ts_ms,
            seq_id,
            ..
        } = ev
        else {
            continue;
        };
        let target = if msg_id.is_empty() {
            cli_msg_id
        } else {
            msg_id
        };
        let key = format!("{conv_id}|{target}");
        if !grouped.contains_key(&key) {
            order.push(key.clone());
        }
        grouped.entry(key).or_default().push(Indexed {
            index: idx,
            ts_ms: *ts_ms,
            seq_id: *seq_id,
            event: ev,
        });
    }
    let mut out = Vec::new();
    for key in order {
        let Some(mut items) = grouped.remove(&key) else {
            continue;
        };
        if items.iter().all(|i| i.ts_ms > 0) {
            items.sort_by_key(|i| (i.ts_ms, i.seq_id, i.index));
        } else if items.iter().all(|i| i.seq_id > 0) {
            items.sort_by_key(|i| (i.seq_id, i.index));
        }
        out.extend(items.into_iter().map(|i| i.event.clone()));
    }
    out
}

/// `extractProfilesMap`: `uid -> profile row` from the many shapes profile endpoints answer with.
pub fn extract_profiles_map(resp: &Map<String, Value>) -> Map<String, Value> {
    let mut result: Map<String, Value> = Map::new();

    fn normalize_uid(candidate: &str) -> String {
        let trimmed = strip_user_prefix(candidate);
        sanitize_profile_uid(&trimmed).unwrap_or(trimmed)
    }
    fn ingest_dict_map(map: &Map<String, Value>, result: &mut Map<String, Value>) {
        for (k, v) in map {
            if let Value::Object(row) = v {
                let uid = normalize_uid(&first_non_empty(&[
                    &string(pick(row, &["userId", "uid", "id"])),
                    k,
                ]));
                if !uid.is_empty() {
                    result.insert(uid, v.clone());
                }
            }
        }
    }
    fn ingest_array(rows: &[&Map<String, Value>], result: &mut Map<String, Value>) {
        for row in rows {
            let uid = normalize_uid(&string(pick(row, &["userId", "uid", "id"])));
            if !uid.is_empty() {
                result.insert(uid, Value::Object((*row).clone()));
            }
        }
    }

    match resp.get("data") {
        Some(Value::Object(data)) => {
            let mut matched = false;
            for key in ["profiles", "unchanged_profiles", "changed_profiles", "list"] {
                if let Some(d) = as_dict(data.get(key)) {
                    ingest_dict_map(d, &mut result);
                    matched = true;
                } else if let Some(rows) = as_dict_array(data.get(key)) {
                    ingest_array(&rows, &mut result);
                    matched = true;
                }
            }
            if !matched {
                ingest_dict_map(data, &mut result);
            }
        }
        Some(arr @ Value::Array(_)) => {
            if let Some(rows) = as_dict_array(Some(arr)) {
                ingest_array(&rows, &mut result);
            }
        }
        _ => {}
    }
    result
}

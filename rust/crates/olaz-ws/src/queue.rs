//! Queue pairs, cursor bookkeeping and persistence snapshot.

use std::collections::{BTreeMap, HashMap, HashSet};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::json::{bool_of, int64_of, object_array, string_of};

/// `ZaloWSQueue`: a `(cmd, subCmd)` pair declared by the server on AUTHEN.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct WsQueue {
    pub cmd: u16,
    pub sub_cmd: u8,
}

impl WsQueue {
    /// Cursor dictionary key: `"<cmd>_<subCmd>"`.
    pub fn key(&self) -> String {
        queue_key(self.cmd, self.sub_cmd)
    }
}

pub fn queue_key(cmd: u16, sub_cmd: u8) -> String {
    format!("{cmd}_{sub_cmd}")
}

/// `ZaloWSQueueCursorSnapshot`. JSON keys `lastId` / `preIds` (persisted in the
/// `wsQueueCursors` preference as `{ "<cmd>_<sub>": { ... } }`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WsQueueCursorSnapshot {
    #[serde(rename = "lastId")]
    pub last_id: String,
    #[serde(rename = "preIds")]
    pub pre_ids: Vec<String>,
}

/// In-memory cursor: `lastId` is an Int64 or String JSON value, `preIds` any JSON.
#[derive(Debug, Clone, PartialEq)]
pub struct QueueCursor {
    pub last_id: Value,
    pub pre_ids: Value,
}

/// Result of applying one inbound payload to the cursors.
#[derive(Debug, Default, PartialEq)]
pub struct CursorUpdate {
    /// New persisted snapshot when it changed (observer callback in Swift).
    pub changed: Option<BTreeMap<String, WsQueueCursorSnapshot>>,
    /// `(lastId, preIds)` for a follow-up `pullNextFrame` when `more == 1`.
    pub next_pull: Option<(Value, Value)>,
}

#[derive(Debug, Default)]
pub struct QueueCursors {
    cursors: HashMap<String, QueueCursor>,
}

fn is_unusable(last: &str) -> bool {
    last.is_empty() || last == "0" || last == "1"
}

impl QueueCursors {
    pub fn get(&self, qkey: &str) -> Option<&QueueCursor> {
        self.cursors.get(qkey)
    }

    pub fn clear(&mut self) {
        self.cursors.clear();
    }

    /// `seedQueueCursors`: skips empty / "0" / "1"; numeric text becomes an Int64.
    pub fn seed(&mut self, snapshots: &BTreeMap<String, WsQueueCursorSnapshot>) {
        for (qkey, snap) in snapshots {
            let trimmed = snap.last_id.trim();
            if is_unusable(trimmed) {
                continue;
            }
            let last_id = match trimmed.parse::<i64>() {
                Ok(n) => Value::from(n),
                Err(_) => Value::String(trimmed.to_owned()),
            };
            let pre_ids = Value::Array(snap.pre_ids.iter().cloned().map(Value::String).collect());
            self.cursors
                .insert(qkey.clone(), QueueCursor { last_id, pre_ids });
        }
    }

    /// `currentQueueCursors`: drops unusable ids; `preIds` non-empty strings only.
    pub fn current(&self) -> BTreeMap<String, WsQueueCursorSnapshot> {
        let mut out = BTreeMap::new();
        for (qkey, c) in &self.cursors {
            let last = string_of(Some(&c.last_id)).trim().to_owned();
            if is_unusable(&last) {
                continue;
            }
            let pre = match &c.pre_ids {
                Value::Array(a) => a
                    .iter()
                    .map(|v| string_of(Some(v)))
                    .filter(|s| !s.is_empty())
                    .collect(),
                _ => Vec::new(),
            };
            out.insert(
                qkey.clone(),
                WsQueueCursorSnapshot {
                    last_id: last,
                    pre_ids: pre,
                },
            );
        }
        out
    }

    /// Cursor to use for the initial pull of `queue` after AUTHEN: `(lastId, preIds)`,
    /// defaulting to `(1, [])`.
    pub fn initial_pull_args(&self, queue: WsQueue) -> (Value, Value) {
        match self.cursors.get(&queue.key()) {
            Some(c) => (c.last_id.clone(), c.pre_ids.clone()),
            None => (Value::from(1), Value::Array(Vec::new())),
        }
    }

    /// Cursor update rules from `handleBinaryFrame`, applied to `payload["data"]`:
    /// - `resetLastActionId` (bool true or int 1): drop the cursor, no pull.
    /// - candidate lastId = `lastActionId` ?? `queueStatus[qkey].lastId` ?? highest action id
    ///   (a JSON `null` counts as present, like Swift's `NSNull`);
    ///   stored only when its string form is non-empty and not "0".
    /// - `preIds` = `queueStatus[qkey].ids` ?? `[]`.
    /// - `more == 1`: request the next page from the candidate (or stored, or 1).
    pub fn apply_payload(
        &mut self,
        cmd: u16,
        sub_cmd: u8,
        data: &Map<String, Value>,
    ) -> CursorUpdate {
        let qkey = queue_key(cmd, sub_cmd);
        let q_status = data
            .get("queueStatus")
            .and_then(Value::as_object)
            .and_then(|m| m.get(&qkey))
            .and_then(Value::as_object);
        let mut update = CursorUpdate::default();

        let reset = bool_of(data.get("resetLastActionId")) == Some(true)
            || int64_of(data.get("resetLastActionId")) == Some(1);
        if reset {
            if self.cursors.remove(&qkey).is_some() {
                update.changed = Some(self.current());
            }
            return update;
        }

        let candidate: Option<Value> = data
            .get("lastActionId")
            .cloned()
            .or_else(|| q_status.and_then(|q| q.get("lastId")).cloned())
            .or_else(|| highest_action_id(data).map(Value::String));
        let pre_ids = q_status
            .and_then(|q| q.get("ids"))
            .cloned()
            .unwrap_or_else(|| Value::Array(Vec::new()));

        if let Some(cand) = &candidate {
            let s = string_of(Some(cand));
            if !s.is_empty() && s != "0" {
                let prev = self.current();
                self.cursors.insert(
                    qkey.clone(),
                    QueueCursor {
                        last_id: cand.clone(),
                        pre_ids: pre_ids.clone(),
                    },
                );
                let updated = self.current();
                if updated != prev {
                    update.changed = Some(updated);
                }
            }
        }

        if int64_of(data.get("more")) == Some(1) {
            let last = candidate
                .or_else(|| self.cursors.get(&qkey).map(|c| c.last_id.clone()))
                .unwrap_or_else(|| Value::from(1));
            update.next_pull = Some((last, pre_ids));
        }
        update
    }
}

/// `queuesFromAuth`: pairs from `data.ctrl_qCmds` then `data.qCmds`, deduplicated,
/// `cmd` must fit u16, `subCmd` defaults to 0 and is clamped into u8. A list with
/// any non-object element is ignored whole (Swift `as? [[String: Any]]`).
pub fn queues_from_auth(auth: &Map<String, Value>) -> Vec<WsQueue> {
    let Some(data) = auth.get("data").and_then(Value::as_object) else {
        return Vec::new();
    };
    let mut seen = HashSet::new();
    let mut result = Vec::new();
    for key in ["ctrl_qCmds", "qCmds"] {
        let Some(items) = object_array(data.get(key)) else {
            continue;
        };
        for item in items {
            let Some(cmd) =
                int64_of(item.get("cmd")).filter(|c| (0..=i64::from(u16::MAX)).contains(c))
            else {
                continue;
            };
            let sub = int64_of(item.get("subCmd")).unwrap_or(0).clamp(0, 255);
            let pair = WsQueue {
                cmd: cmd as u16,
                sub_cmd: sub as u8,
            };
            if seen.insert(pair) {
                result.push(pair);
            }
        }
    }
    result
}

/// `highestActionId`: largest numeric `actionId ?? actId ?? id` (returned in its
/// original string form) across the known row arrays; rows need integer values > 0.
pub fn highest_action_id(data: &Map<String, Value>) -> Option<String> {
    let mut max_val: i64 = 0;
    let mut max_str: Option<String> = None;
    for key in [
        "actions",
        "controls",
        "msgs",
        "groupMsgs",
        "reacts",
        "reactGroups",
    ] {
        let Some(rows) = object_array(data.get(key)) else {
            continue;
        };
        for row in rows {
            let raw = row
                .get("actionId")
                .or_else(|| row.get("actId"))
                .or_else(|| row.get("id"));
            if let Some(n) = int64_of(raw)
                && n > max_val
            {
                max_val = n;
                max_str = Some(string_of(raw));
            }
        }
    }
    max_str
}

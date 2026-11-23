//! Swift `ZaloPollState` / `ZaloPollQueueCursor`: cursor of the HTTP long-poll queue.

use std::collections::BTreeMap;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use olaz_json::{bool_value, int64, string};
use olaz_net::url_encode;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PollQueueCursor {
    pub last_id: String,
    pub ids: Vec<String>,
}

impl Default for PollQueueCursor {
    fn default() -> Self {
        Self {
            last_id: "1".to_owned(),
            ids: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PollState {
    pub last_action_id: String,
    pub last_action_id_other: String,
    pub queues: BTreeMap<String, PollQueueCursor>,
}

fn initial_queues() -> BTreeMap<String, PollQueueCursor> {
    ["1", "2", "3"]
        .into_iter()
        .map(|k| (k.to_owned(), PollQueueCursor::default()))
        .collect()
}

impl Default for PollState {
    fn default() -> Self {
        Self {
            last_action_id: "1".to_owned(),
            last_action_id_other: "1".to_owned(),
            queues: initial_queues(),
        }
    }
}

impl PollState {
    /// Swift `encodedParams`: `<lastActionId>,<lastActionIdOther>,<urlEncode(base64(queuesJSON),1)>`.
    pub fn encoded_params(&self) -> String {
        let mut queues = Map::new();
        for (k, q) in &self.queues {
            queues.insert(k.clone(), json!({"lastId": q.last_id, "ids": q.ids}));
        }
        // sortedKeys, like Swift.
        let json = olaz_json::to_swift_json_string(&Value::Object(queues));
        let b64 = STANDARD.encode(json.as_bytes());
        let suffix = url_encode(&format!("{b64},1"));
        format!(
            "{},{},{suffix}",
            self.last_action_id, self.last_action_id_other
        )
    }

    /// Swift `applyResponse`: returns `(more, reset)`.
    pub fn apply_response(&mut self, data_node: &Map<String, Value>) -> (bool, bool) {
        let more = int64(data_node.get("more")) == Some(1);
        let reset_flag = data_node.get("resetLastActionId");
        if bool_value(reset_flag) == Some(true) || int64(reset_flag) == Some(1) {
            self.last_action_id = "1".to_owned();
            self.last_action_id_other = "1".to_owned();
            self.queues = initial_queues();
            return (more, true);
        }

        let next_last = string(data_node.get("lastActionId"));
        if !next_last.is_empty() {
            self.last_action_id = next_last;
        }
        let next_other = string(data_node.get("lastActionIdOther"));
        if !next_other.is_empty() {
            self.last_action_id_other = next_other;
        }

        if let Some(Value::Object(q_status)) = data_node.get("queueStatus") {
            for (raw_key, raw_val) in q_status {
                // Socket-only queue "15" causes repeated loops if persisted in HTTP poll state.
                if raw_key == "15" {
                    continue;
                }
                let Value::Object(q) = raw_val else { continue };
                let last_id = string(q.get("lastId"));
                let ids: Vec<String> = match q.get("ids") {
                    Some(Value::Array(raw)) => raw
                        .iter()
                        .map(|v| string(Some(v)))
                        .filter(|s| !s.is_empty())
                        .collect(),
                    _ => Vec::new(),
                };
                let fallback = self
                    .queues
                    .get(raw_key)
                    .map_or_else(|| "1".to_owned(), |c| c.last_id.clone());
                self.queues.insert(
                    raw_key.clone(),
                    PollQueueCursor {
                        last_id: if last_id.is_empty() {
                            fallback
                        } else {
                            last_id
                        },
                        ids,
                    },
                );
            }
        }
        (more, false)
    }
}

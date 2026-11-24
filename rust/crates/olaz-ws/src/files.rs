//! `file_done` / `video_done` extraction and waiter bookkeeping.

use std::collections::{HashMap, VecDeque};

use serde_json::{Map, Value};

use crate::consts::COMPLETED_FILE_CAP;
use crate::json::{object_array, parse_object, string_of};

/// Opaque id the transport uses to find the channel behind a waiter.
pub type WaiterToken = u64;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileDone {
    pub file_id: String,
    pub url: String,
}

/// Outcome of [`FileWaiters::wait`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileWait {
    /// Empty file id: resolve `None` immediately.
    Invalid,
    /// Already completed: resolve with this url.
    Ready(String),
    /// Registered; resolve later via `record` / `timeout`.
    Pending(WaiterToken),
}

/// Waiters to resolve after recording a completion.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileWake {
    pub file_id: String,
    pub url: String,
    pub waiters: Vec<WaiterToken>,
}

#[derive(Debug, Default)]
pub struct FileWaiters {
    completed: HashMap<String, String>,
    order: VecDeque<String>,
    waiters: HashMap<String, Vec<WaiterToken>>,
}

impl FileWaiters {
    /// `waitForFileDone` (without the timer; the transport schedules `timeout`).
    pub fn wait(&mut self, file_id: &str, token: WaiterToken) -> FileWait {
        if file_id.is_empty() {
            return FileWait::Invalid;
        }
        if let Some(url) = self.completed.get(file_id).filter(|u| !u.is_empty()) {
            return FileWait::Ready(url.clone());
        }
        self.waiters
            .entry(file_id.to_owned())
            .or_default()
            .push(token);
        FileWait::Pending(token)
    }

    /// `timeoutFileWaiters`: removes every waiter of `file_id`; resolve them with `None`.
    pub fn timeout(&mut self, file_id: &str) -> Vec<WaiterToken> {
        self.waiters.remove(file_id).unwrap_or_default()
    }

    /// `recordFileDone`: ignored for empty id/url. Caches the url (cap 200, oldest evicted;
    /// Swift evicted an arbitrary key) and returns the waiters to resolve with it.
    pub fn record(&mut self, file_id: &str, url: &str) -> Vec<WaiterToken> {
        if file_id.is_empty() || url.is_empty() {
            return Vec::new();
        }
        if self
            .completed
            .insert(file_id.to_owned(), url.to_owned())
            .is_none()
        {
            self.order.push_back(file_id.to_owned());
        }
        if self.completed.len() > COMPLETED_FILE_CAP
            && let Some(oldest) = self.order.pop_front()
        {
            self.completed.remove(&oldest);
        }
        self.waiters.remove(file_id).unwrap_or_default()
    }

    /// `stop`: drops cache and waiters; resolve returned tokens with `None`.
    pub fn clear(&mut self) -> Vec<WaiterToken> {
        self.completed.clear();
        self.order.clear();
        let mut all: Vec<WaiterToken> = self.waiters.drain().flat_map(|(_, v)| v).collect();
        all.sort_unstable();
        all
    }

    pub fn completed_len(&self) -> usize {
        self.completed.len()
    }
}

/// Parses a string field as a JSON object (`content` / `data` may be JSON text).
fn object_from(v: Option<&Value>) -> Option<Map<String, Value>> {
    match v {
        Some(Value::Object(m)) => Some(m.clone()),
        Some(Value::String(s)) => parse_object(s.as_bytes()),
        _ => None,
    }
}

/// `extractFileDoneEvents`: finds `file_done` / `video_done` controls/actions in a payload.
pub fn extract_file_done_events(payload: &Map<String, Value>) -> Vec<FileDone> {
    let data_node: Map<String, Value> = match payload.get("data") {
        Some(Value::Object(m)) => m.clone(),
        _ => payload.clone(),
    };
    let mut candidates: Vec<Map<String, Value>> = Vec::new();
    if let Some(c) = object_array(data_node.get("controls")) {
        candidates.extend(c.into_iter().cloned());
    }
    if let Some(a) = object_array(data_node.get("actions")) {
        candidates.extend(a.into_iter().cloned());
    }
    if let Some(items) = object_array(payload.get("data")) {
        for item in items {
            match object_array(item.get("controls")) {
                Some(sub) => candidates.extend(sub.into_iter().cloned()),
                None => candidates.push(item.clone()),
            }
        }
    }
    if candidates.is_empty() {
        candidates.push(data_node);
    }

    let mut results = Vec::new();
    for item in candidates {
        let content = object_from(item.get("content")).unwrap_or_else(|| item.clone());
        let act_type = string_of(content.get("act_type").or_else(|| content.get("actType")));
        if act_type != "file_done" && act_type != "video_done" {
            continue;
        }
        let d_obj = object_from(content.get("data")).unwrap_or_else(|| content.clone());
        let file_id = string_of(d_obj.get("fileId").or_else(|| content.get("fileId")));
        let nested = d_obj.get("data").and_then(Value::as_object);
        let url = string_of(
            nested
                .and_then(|n| n.get("url"))
                .or_else(|| d_obj.get("url"))
                .or_else(|| d_obj.get("fileUrl")),
        );
        if !file_id.is_empty() && !url.is_empty() {
            results.push(FileDone { file_id, url });
        }
    }
    results
}

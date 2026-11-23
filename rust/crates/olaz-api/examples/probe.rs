//! Shape-only live probe (ADR-008): never prints names, ids, tokens or message text.
//!
//! Usage: `cargo run -p olaz-api --example probe -- <session-snapshot.json>`
//!
//! Restores a `SessionSnapshot` (the JSON `olaz-net` writes), validates the session with
//! `getLoginInfo` / `me-v2`, then fetches the recent-thread overview and prints counts, key names
//! and error codes only.

use std::process::ExitCode;

use olaz_api::{ApiError, JsonObject, ZaloApi};
use olaz_net::{ReqwestTransport, SessionClient, SessionSnapshot, SessionStatus};
use serde_json::Value;

fn key_names(map: &JsonObject) -> String {
    let mut keys: Vec<&str> = map.keys().map(String::as_str).collect();
    keys.sort_unstable();
    keys.join(",")
}

fn describe_error(e: &ApiError) -> String {
    match e.session_error() {
        Some(s) => format!("error_code={}", s.code),
        None => "transport error".to_owned(),
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    let Some(path) = std::env::args().nth(1) else {
        eprintln!("usage: probe <session-snapshot.json>");
        return ExitCode::from(2);
    };
    let snapshot: SessionSnapshot = match std::fs::read_to_string(&path)
        .map_err(|e| e.kind().to_string())
        .and_then(|t| serde_json::from_str(&t).map_err(|_| "invalid snapshot JSON".to_owned()))
    {
        Ok(s) => s,
        Err(why) => {
            eprintln!("cannot load snapshot: {why}");
            return ExitCode::from(2);
        }
    };
    let transport = match ReqwestTransport::new() {
        Ok(t) => t,
        Err(_) => {
            eprintln!("cannot build HTTP transport");
            return ExitCode::from(2);
        }
    };
    let client = SessionClient::new(
        transport,
        snapshot.imei.clone(),
        snapshot.computer_name.clone(),
    );
    let restored = client.restore(snapshot);
    println!("restore: {restored}");
    if !restored {
        return ExitCode::from(1);
    }
    let api = ZaloApi::new(client);

    let status = api.client().session_status().await;
    println!(
        "session status: {}",
        match status {
            SessionStatus::Valid => "valid",
            SessionStatus::Expired => "expired",
            SessionStatus::Unreachable => "unreachable",
        }
    );
    if status != SessionStatus::Valid {
        return ExitCode::from(1);
    }

    match api.fetch_preload_conversations(&[]).await {
        Ok(resp) => {
            println!("preload: top keys [{}]", key_names(&resp));
            if let Some(Value::Object(data)) = resp.get("data") {
                println!("preload: data keys [{}]", key_names(data));
                for (name, value) in data {
                    if let Value::Array(rows) = value {
                        let sample: Vec<String> = rows
                            .iter()
                            .take(5)
                            .filter_map(Value::as_object)
                            .map(key_names)
                            .collect();
                        println!(
                            "preload: {name} count={} first5 row-shapes={sample:?}",
                            rows.len()
                        );
                    }
                }
            }
        }
        Err(e) => println!("preload: {}", describe_error(&e)),
    }
    match api.fetch_pinned_conversations().await {
        Ok(ids) => println!("pinned: count={}", ids.len()),
        Err(e) => println!("pinned: {}", describe_error(&e)),
    }
    ExitCode::SUCCESS
}

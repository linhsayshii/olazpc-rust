//! Case format v1 replay runner (`cargo test -p olaz-core --test cases -- <domain>`).
//!
//! Reads `cases/<domain>.jsonl` and `cases/known-diffs.jsonl`, replays each case through the real
//! `olaz-core` actor + `SessionEffectRunner<ScriptedTransport>` + `RecordingHost`, prints
//! `N/M cases match` per domain, and lists any mismatch as `name: path: expected X, got Y`.

mod common;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use common::{Case, KnownDiff, canonical_json_string, compare_case, run_case};

/// Domains whose `.jsonl` recordings are merged ahead of their `olaz-core` port.
///
/// Unfiltered runs (`cargo test -p olaz-core --test cases`) print each pending domain with its
/// case count and skip execution; explicit `-- <domain>` runs (and `scripts/gate-core.sh`) refuse
/// pending domains. Each port removes its domain from this list in the same PR.
const PENDING_DOMAINS: &[&str] = &["cloud", "contacts", "forward", "groups", "media", "message_actions", "pins", "polls", "search", "stickers"];

fn cases_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("cases")
}

fn load_jsonl<T: serde::de::DeserializeOwned>(path: &Path) -> Result<Vec<T>, String> {
    let text = fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut items = Vec::new();
    for (line_no, raw_line) in text.lines().enumerate() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        let parsed: T = serde_json::from_str(line)
            .map_err(|e| format!("{}:{}: {e}", path.display(), line_no + 1))?;
        items.push(parsed);
    }
    Ok(items)
}

fn load_known_diffs(dir: &Path) -> Result<Vec<KnownDiff>, String> {
    let path = dir.join("known-diffs.jsonl");
    if !path.exists() {
        return Ok(Vec::new());
    }
    load_jsonl(&path)
}

fn discover_domains(dir: &Path, filter: Option<&str>) -> Result<Vec<(String, PathBuf)>, String> {
    if let Some(domain) = filter {
        let path = dir.join(format!("{domain}.jsonl"));
        if !path.exists() {
            return Err(format!("case file missing: {}", path.display()));
        }
        return Ok(vec![(domain.to_owned(), path)]);
    }
    if !dir.exists() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    let entries = fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    for entry in entries {
        let entry = entry.map_err(|e| format!("{}: {e}", dir.display()))?;
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("jsonl") {
            continue;
        }
        let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        if stem == "known-diffs" {
            continue;
        }
        out.push((stem.to_owned(), path));
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(out)
}

fn parse_domain_filter() -> Option<String> {
    // `cargo test -p olaz-core --test cases -- session` passes `session` as a positional arg.
    // Ignore flags like `--nocapture`, `--exact`, `--test-threads=1`, etc.
    for arg in std::env::args().skip(1) {
        if arg.starts_with('-') {
            continue;
        }
        return Some(arg);
    }
    None
}

fn main() -> ExitCode {
    let dir = cases_dir();
    let filter = parse_domain_filter();

    if filter.is_none() {
        for &pending in PENDING_DOMAINS {
            let pending_path = dir.join(format!("{pending}.jsonl"));
            if !pending_path.exists() {
                eprintln!(
                    "error: pending domain '{pending}' in PENDING_DOMAINS has no case file at {}",
                    pending_path.display()
                );
                return ExitCode::FAILURE;
            }
        }
    }

    let domains = match discover_domains(&dir, filter.as_deref()) {
        Ok(d) => d,
        Err(msg) => {
            eprintln!("error: {msg}");
            return ExitCode::FAILURE;
        }
    };

    if domains.is_empty() {
        println!("0/0 cases match (no case files under {})", dir.display());
        return ExitCode::SUCCESS;
    }

    let known_diffs = match load_known_diffs(&dir) {
        Ok(k) => k,
        Err(msg) => {
            eprintln!("error: {msg}");
            return ExitCode::FAILURE;
        }
    };
    let mut used_known_diffs = vec![false; known_diffs.len()];

    let mut any_failure = false;

    for (domain, path) in &domains {
        if PENDING_DOMAINS.contains(&domain.as_str()) {
            let raw_cases: Vec<serde_json::Value> = match load_jsonl(path) {
                Ok(c) => c,
                Err(msg) => {
                    eprintln!("error: {msg}");
                    return ExitCode::FAILURE;
                }
            };
            let total = raw_cases.len();
            if filter.is_some() {
                eprintln!(
                    "error: domain '{domain}' is pending ({total} cases in PENDING_DOMAINS); remove it from PENDING_DOMAINS before gating"
                );
                return ExitCode::FAILURE;
            }
            println!("skipped pending domain: {domain} ({total} cases)");
            continue;
        }

        let cases: Vec<Case> = match load_jsonl(path) {
            Ok(c) => c,
            Err(msg) => {
                eprintln!("error: {msg}");
                return ExitCode::FAILURE;
            }
        };

        let total = cases.len();
        let mut matched = 0usize;
        let mut mismatch_lines = Vec::new();

        for case in &cases {
            if case.format != 1 {
                mismatch_lines.push(format!(
                    "{}: format: expected 1, got {}",
                    case.name, case.format
                ));
                continue;
            }
            let rt = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .start_paused(true)
                .build()
            {
                Ok(rt) => rt,
                Err(e) => {
                    eprintln!("error: tokio runtime: {e}");
                    return ExitCode::FAILURE;
                }
            };
            match rt.block_on(run_case(case)) {
                Ok(actual) => {
                    let mismatches =
                        compare_case(case, &actual, &known_diffs, &mut used_known_diffs);
                    if mismatches.is_empty() {
                        matched += 1;
                    } else {
                        for m in mismatches {
                            mismatch_lines.push(format!(
                                "{}: {}: expected {}, got {}",
                                case.name,
                                m.path,
                                canonical_json_string(&m.expected),
                                canonical_json_string(&m.actual),
                            ));
                        }
                    }
                }
                Err(err) => {
                    mismatch_lines.push(format!("{}: runner: {err}", case.name));
                }
            }
        }

        // Check for stale known-diffs in this domain.
        for (idx, kd) in known_diffs.iter().enumerate() {
            if kd.domain == *domain && !used_known_diffs[idx] {
                mismatch_lines.push(format!(
                    "{}: {}: stale known-diff (case no longer differs)",
                    kd.name, kd.path
                ));
                any_failure = true;
            }
        }

        println!("{matched}/{total} cases match");
        for line in &mismatch_lines {
            println!("{line}");
        }
        if matched != total || !mismatch_lines.is_empty() {
            any_failure = true;
        }
    }

    if any_failure {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}

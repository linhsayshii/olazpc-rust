#![allow(dead_code, clippy::unwrap_used, clippy::expect_used)]

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use serde_json::Value;

pub fn crate_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

pub fn scenario() -> Value {
    let text =
        std::fs::read_to_string(crate_dir().join("tests/fixtures/js_scenario.json")).unwrap();
    serde_json::from_str(&text).unwrap()
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

/// A node process running the bundled JS library (`tests/js/interop_server.js`).
pub struct Node {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl Node {
    /// `None` when `node` is not installed (the interop tests then report a skip).
    pub fn start() -> Option<Self> {
        let mut child = Command::new("node")
            .arg(crate_dir().join("tests/js/interop_server.js"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .ok()?;
        let stdin = child.stdin.take()?;
        let stdout = BufReader::new(child.stdout.take()?);
        Some(Self {
            child,
            stdin,
            stdout,
        })
    }

    pub fn call(&mut self, req: Value) -> Value {
        writeln!(self.stdin, "{req}").unwrap();
        self.stdin.flush().unwrap();
        let mut line = String::new();
        self.stdout.read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap_or_else(|e| panic!("bad node reply {line:?}: {e}"))
    }
}

impl Drop for Node {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#!/bin/zsh
# Pre-commit / phase gate for the Rust core extraction.
# Usage: scripts/gate-core.sh <domain> [<domain>...]   (e.g. `scripts/gate-core.sh session`)
#        scripts/gate-core.sh all                      (every domain with a cases file)
# Checks 1, 3, 4 and 5 do not depend on the domain and run once; checks 2 and 6 run per domain.
# Wall-clock budget tests (TIMING_*) are left out of checks 1 and 5 and run in check 7 once the
# host load is below its core count, so a busy machine cannot fail them.
set -euo pipefail

if [[ $# -lt 1 || -z "${1:-}" ]]; then
    echo "Usage: $0 <domain> [<domain>...] | all" >&2
    exit 2
fi

cd "$(dirname "$0")/.."
ROOT="$PWD"

is_pending_domain() {
    local domain="$1"
    [[ -f "$ROOT/rust/crates/olaz-core/tests/cases.rs" ]] || return 1
    python3 - "$ROOT/rust/crates/olaz-core/tests/cases.rs" "$domain" <<'PY'
import re, sys

cases_rs, domain = sys.argv[1], sys.argv[2]
src = open(cases_rs, encoding="utf-8").read()
m = re.search(r'\bPENDING_DOMAINS\s*:\s*&\[\s*&str\s*\]\s*=\s*&\[(.*?)\];', src, re.S)
if not m:
    sys.exit(1)
body = "\n".join(line.split("//", 1)[0] for line in m.group(1).splitlines())
pending = set(re.findall(r'"([^"]+)"', body))
sys.exit(0 if domain in pending else 1)
PY
}

if [[ "$1" == "all" ]]; then
    DOMAINS=()
    for f in "$ROOT"/rust/crates/olaz-core/cases/*.jsonl(N); do
        d="${f:t:r}"
        [[ "$d" == "known-diffs" ]] && continue
        # Domains recorded but not ported yet (`PENDING_DOMAINS` in tests/cases.rs) are not gated.
        is_pending_domain "$d" && continue
        DOMAINS+=("$d")
    done
else
    DOMAINS=("$@")
    for DOMAIN in "${DOMAINS[@]}"; do
        if is_pending_domain "$DOMAIN"; then
            echo "gate FAIL: domain '$DOMAIN' is listed in PENDING_DOMAINS (rust/crates/olaz-core/tests/cases.rs); remove it before gating" >&2
            exit 1
        fi
    done
fi

# Tests that assert a wall-clock budget or poll real time.
TIMING_SWIFT='sqliteClientIdIndexExistsBulkSaveIsFastAndE2EETwinProtectionIntact|fastPhoneSyncPlanFiltersAndSortsNewestFirstAndBulkIngestsFast|startsHelperQueuesUntilReadyThenSendsInitFirst|queueIsLIFOAndDropsCancelledWork|scrubEndsAtOnceAndPlaybackResumesEvenIfALaterSeekSupersedesTheExactOne|phaseGateTasksCompleteAcrossStartLogOutRefreshExpiryAndTeardown|uncachedDecodesStayOutOfTheSharedMemoryCache'
TIMING_RUST=(ping_cadence_uses_interval_after_auth)
# The crate holding TIMING_RUST; the olaz-core `cases` harness reads any free argument as a domain, so test
# filters go to this crate only.
TIMING_RUST_CRATE=olaz-ws

export PATH="$HOME/.cargo/bin:$PATH"
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" ]]; then
    for candidate in /Applications/Xcode.app/Contents/Developer /Applications/Xcode-beta.app/Contents/Developer; do
        if [[ -f "$candidate/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
            export DEVELOPER_DIR="$candidate"
            break
        fi
    done
fi
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"

TMPDIR_GATE="$(mktemp -d "${TMPDIR:-/tmp}/olaz-gate.XXXXXX")"
trap 'rm -rf "$TMPDIR_GATE"' EXIT

run_quiet() {
    local check_num="$1"
    local label="$2"
    shift 2
    local log="$TMPDIR_GATE/check_${check_num}.log"
    if "$@" >"$log" 2>&1; then
        return 0
    else
        local rc=$?
        echo "check ${check_num} FAIL: ${label}"
        cat "$log" >&2
        return "$rc"
    fi
}

# 1. Rust workspace fmt, clippy, tests
run_quiet 1 "rust fmt / clippy / test" zsh -c '
    set -euo pipefail
    cd "$1/rust"
    cargo fmt --all --check
    cargo clippy --workspace --all-targets -- -D warnings
    cargo test --workspace --locked --exclude "$2"
    cargo test -p "$2" --locked -- ${=3}
' _ "$ROOT" "$TIMING_RUST_CRATE" "${(j: :)${TIMING_RUST/#/--skip }}"
echo "check 1 PASS: rust fmt, clippy, workspace tests"

# 2. olaz-core cases replay test, per domain
if [[ ! -f "$ROOT/rust/crates/olaz-core/Cargo.toml" ]]; then
    echo "check 2 FAIL: olaz-core missing (U1b)"
    exit 1
fi
for DOMAIN in "${DOMAINS[@]}"; do
    LOG2="$TMPDIR_GATE/check_2_${DOMAIN}.log"
    if ! (cd "$ROOT/rust" && cargo test -p olaz-core --test cases -- "$DOMAIN" >"$LOG2" 2>&1); then
        echo "check 2 FAIL: olaz-core cases test failed (${DOMAIN})"
        cat "$LOG2" >&2
        exit 1
    fi
    CASES_SUMMARY="$(grep -Eo '[0-9]+/[0-9]+' "$LOG2" | tail -n 1 || true)"
    if [[ -z "$CASES_SUMMARY" ]]; then
        echo "check 2 FAIL: olaz-core cases did not print N/N (${DOMAIN})"
        cat "$LOG2" >&2
        exit 1
    fi
    MATCHED_N="${CASES_SUMMARY%/*}"
    TOTAL_N="${CASES_SUMMARY#*/}"
    if [[ "$MATCHED_N" != "$TOTAL_N" || "$TOTAL_N" == "0" ]]; then
        echo "check 2 FAIL: olaz-core cases reported ${CASES_SUMMARY} (${DOMAIN})"
        cat "$LOG2" >&2
        exit 1
    fi
    echo "check 2 PASS: olaz-core cases ${DOMAIN} (${CASES_SUMMARY})"
done

# 3. olaz-core hygiene audit outside #[cfg(test)] and tests/
run_quiet 3 "olaz-core production code hygiene" python3 - "$ROOT/rust/crates/olaz-core/src" <<'PY'
import os, re, sys

src_dir = sys.argv[1]
if not os.path.isdir(src_dir):
    sys.exit(0)

violations = []

def strip_line_comment(line: str) -> str:
    # Simple string/comment stripper sufficient for attribute and keyword checks.
    i = 0
    in_str = False
    escape = False
    while i < len(line):
        ch = line[i]
        if in_str:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_str = False
        else:
            if ch == '"':
                in_str = True
            elif line[i:i+2] == "//":
                return line[:i]
        i += 1
    return line

for dirpath, dirnames, filenames in os.walk(src_dir):
    dirnames[:] = [d for d in dirnames if d != "tests"]
    for fn in sorted(filenames):
        if not fn.endswith(".rs"):
            continue
        path = os.path.join(dirpath, fn)
        lines = open(path, encoding="utf-8").read().splitlines()
        in_cfg_test = False
        pending_cfg_test = False
        brace_depth = 0
        cfg_test_depth = 0

        for idx, line in enumerate(lines):
            lineno = idx + 1
            prev_line = lines[idx - 1] if idx > 0 else ""
            code = strip_line_comment(line)

            if re.search(r'#\[\s*cfg\s*\(\s*test\s*\)\s*\]', code):
                pending_cfg_test = True

            if pending_cfg_test and not in_cfg_test:
                opens = code.count("{")
                closes = code.count("}")
                if opens > 0:
                    in_cfg_test = True
                    cfg_test_depth = brace_depth
                    brace_depth += opens - closes
                    if brace_depth <= cfg_test_depth:
                        in_cfg_test = False
                        pending_cfg_test = False
                    continue
                if ";" in code:
                    pending_cfg_test = False
                brace_depth += opens - closes
                continue

            if in_cfg_test:
                brace_depth += code.count("{") - code.count("}")
                if brace_depth <= cfg_test_depth:
                    in_cfg_test = False
                    pending_cfg_test = False
                continue

            brace_depth += code.count("{") - code.count("}")

            has_infallible = ("// INFALLIBLE:" in line) or ("// INFALLIBLE:" in prev_line)
            if (".unwrap(" in code or ".expect(" in code or re.search(r'\bpanic!\s*\(', code)) and not has_infallible:
                violations.append(f"{path}:{lineno}: unwrap/expect/panic! without // INFALLIBLE:")

            if re.search(r'\b(todo|unimplemented)!\s*\(', code):
                violations.append(f"{path}:{lineno}: todo!/unimplemented! is forbidden")

            if re.search(r'\bunsafe\b', code) and ("// SAFETY:" not in prev_line):
                violations.append(f"{path}:{lineno}: unsafe without // SAFETY: on previous line")

            if re.search(r'#\[\s*allow\s*\(', code):
                violations.append(f"{path}:{lineno}: #[allow(...)] forbidden; use #[expect(..., reason = \"...\")]")

if violations:
    sys.stderr.write("\n".join(violations) + "\n")
    sys.exit(1)
PY
echo "check 3 PASS: olaz-core hygiene"

# 4. Build Rust core and verify UniFFI bindings are committed (matching .github/workflows/ci.yml)
run_quiet 4 "build-rust.sh + OlazCore.swift bindings drift check" zsh -c '
    set -euo pipefail
    cd "$1"
    ./scripts/build-rust.sh
    git diff --exit-code -- Sources/OlazCore/OlazCore.swift
' _ "$ROOT"
echo "check 4 PASS: build-rust and OlazCore.swift bindings"

# 5. Swift build + Swift test suite
run_quiet 5 "swift build && swift test" zsh -c '
    set -euo pipefail
    cd "$1"
    swift build
    swift test --skip "$2"
' _ "$ROOT" "$TIMING_SWIFT"
echo "check 5 PASS: swift build and swift test (timing tests run in check 7)"

# 6. Recorder freshness (including slow cases), per domain
for DOMAIN in "${DOMAINS[@]}"; do
    DOMAIN_CAP="${(C)DOMAIN}"
    case "$DOMAIN" in
        conversations)
            RECORDER_FILTER="ConversationRecorderTests/testConversationsCases"
            ;;
        conversation_actions)
            RECORDER_FILTER="ConversationRecorderTests/testConversationActionsCases"
            ;;
        messages)
            RECORDER_FILTER="MessageRecorderTests"
            ;;
        message_actions)
            RECORDER_FILTER="MessageActionRecorderTests"
            ;;
        contacts)
            RECORDER_FILTER="ContactRecorderTests"
            ;;
        groups)
            RECORDER_FILTER="GroupRecorderTests"
            ;;
        polls)
            RECORDER_FILTER="PollRecorderTests"
            ;;
        *)
            RECORDER_FILTER="${DOMAIN_CAP}RecorderTests"
            ;;
    esac
    run_quiet "6_${DOMAIN}" "${RECORDER_FILTER} freshness" zsh -c '
        set -euo pipefail
        cd "$1"
        OLAZ_SLOW_CASES=1 swift test --filter "$2"
    ' _ "$ROOT" "$RECORDER_FILTER"
    echo "check 6 PASS: ${RECORDER_FILTER} (with OLAZ_SLOW_CASES=1)"
done

# 7. Wall-clock budget tests, on a quiet host: wait (up to 30 min) until the 1-minute load average
# is below the core count, run them; one more quiet wait and run if they fail; a second failure fails.
CORES="$(sysctl -n hw.ncpu)"
wait_quiet() {
    local waited=0
    while (( waited < 1800 )); do
        local load="$(sysctl -n vm.loadavg | awk '{print int($2)}')"
        (( load < CORES )) && return 0
        sleep 30
        (( waited += 30 ))
    done
    echo "check 7 note: host load stayed at or above ${CORES} for 30 min; running anyway"
}
run_timing() {
    (cd "$ROOT/rust" && cargo test -p "$TIMING_RUST_CRATE" --locked -- ${=1} --exact) && \
        (cd "$ROOT" && swift test --skip-build --filter "$2")
}
RUST_FILTER="${(j: :)TIMING_RUST}"
LOG7="$TMPDIR_GATE/check_7.log"
for attempt in 1 2; do
    wait_quiet
    if run_timing "$RUST_FILTER" "$TIMING_SWIFT" >"$LOG7" 2>&1; then
        echo "check 7 PASS: wall-clock budget tests on a quiet host (attempt ${attempt})"
        exit 0
    fi
    echo "check 7 attempt ${attempt} failed (load $(sysctl -n vm.loadavg))"
done
echo "check 7 FAIL: wall-clock budget tests"
cat "$LOG7" >&2
exit 1

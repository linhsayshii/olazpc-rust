#!/usr/bin/env python3
"""Local gate: compare installed Zalo runtime with the protocol identity Rust implements."""
import argparse
import mmap
from pathlib import Path
import re
import sys


def check(asar: Path, identity: Path) -> int:
    source = identity.read_text(encoding="utf-8")
    pinned = re.search(r'client_identity!\(\s*"([0-9]+)"\s*,', source)
    if pinned is None:
        print("runtime drift FAIL: Rust client identity is missing", file=sys.stderr)
        return 1
    expected = pinned.group(1).encode("ascii")
    if not asar.exists():
        print("runtime drift SKIP: official runtime is not installed")
        return 0
    if asar.stat().st_size == 0:
        found = set()
    else:
        with asar.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
            found = set(re.findall(rb"getClientVersion\s*:\s*function\s*\(\s*\)\s*\{\s*return\s+([0-9]+)\s*[;}]", data))
    if not found:
        print("runtime drift FAIL: installed app.asar has no getClientVersion function", file=sys.stderr)
        return 1
    if found != {expected}:
        print("runtime drift FAIL: installed client version " + ", ".join(sorted(v.decode("ascii") for v in found))
              + " differs from native protocol " + expected.decode("ascii"), file=sys.stderr)
        return 1
    print("runtime drift PASS: installed runtime and Rust protocol are " + expected.decode("ascii"))
    return 0


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--asar", type=Path, default=Path.home() / "Library/Application Support/Olaz/ZaloRuntime/current/Contents/Resources/app.asar")
    parser.add_argument("--identity", type=Path, default=root / "rust/crates/olaz-client/src/identity.rs")
    args = parser.parse_args()
    try:
        return check(args.asar, args.identity)
    except (OSError, ValueError) as error:
        print("runtime drift FAIL: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

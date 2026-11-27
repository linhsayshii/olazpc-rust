#!/usr/bin/env python3
"""Check that every DEACTIVATE_E2EE_GROUP constant in an app.asar bundle is !0."""
import argparse
import mmap
from pathlib import Path
import re
import sys

DEFAULT_ASAR = Path.home() / "Library/Application Support/Olaz/ZaloRuntime/current/Contents/Resources/app.asar"
PATTERN = re.compile(rb"DEACTIVATE_E2EE_GROUP\s*:\s*([^,}\];\)\s]*)")


def check(asar: Path, explicit: bool) -> int:
    if not asar.exists():
        if explicit:
            print(f"e2ee-group-flag FAIL: {asar} does not exist", file=sys.stderr)
            return 1
        print("e2ee-group-flag SKIP: app.asar is missing")
        return 0
    if asar.stat().st_size == 0:
        matches: list[bytes] = []
    else:
        with asar.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
            matches = PATTERN.findall(data)
    if not matches:
        print(
            "group E2EE enabled in this Zalo build: reopen U17 (no DEACTIVATE_E2EE_GROUP constant found)",
            file=sys.stderr,
        )
        return 1
    non_disabled = sorted({m.decode("ascii", errors="replace")[:32] for m in matches if m != b"!0"})
    if non_disabled:
        print(
            "group E2EE enabled in this Zalo build: reopen U17 (DEACTIVATE_E2EE_GROUP: "
            + ", ".join(non_disabled)
            + ")",
            file=sys.stderr,
        )
        return 1
    print(f"e2ee-group-flag OK: all {len(matches)} DEACTIVATE_E2EE_GROUP constants are !0")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("asar_pos", nargs="?", type=Path, help="Path to app.asar")
    parser.add_argument("--asar", type=Path, dest="asar_opt", help="Path to app.asar")
    args = parser.parse_args()
    given = args.asar_opt or args.asar_pos
    try:
        return check(given or DEFAULT_ASAR, explicit=given is not None)
    except (OSError, ValueError) as error:
        print("e2ee-group-flag FAIL: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

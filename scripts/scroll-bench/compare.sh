#!/bin/zsh
# A/B of the offline chat scroll benchmark (`Olaz --scroll-bench`, see Sources/Olaz/ZaloRuntime/ScrollBench.swift).
# usage: scripts/scroll-bench/compare.sh <outdir> <rounds> <dirA> <dirB> ...
#   each <dir> holds a release `Olaz` binary and its `Olaz_Olaz.bundle` (copy both out of .build/release).
# Binaries run one after another, interleaved per round; the medians per pass are printed by summarize.py.
# Env passed through: OLAZ_BENCH_MSGS, OLAZ_BENCH_SPEED, OLAZ_BENCH_POINTER, OLAZ_BENCH_SHOT.
# Runs never touch ~/Library/Application Support/Olaz and can run beside the real app.
set -u
OUT=$1; N=$2; shift 2
mkdir -p "$OUT"
LOG="$OUT/compare.log"; : > "$LOG"
for r in $(seq 1 "$N"); do
  for d in "$@"; do
    timeout 300 "$d/Olaz" --scroll-bench "$OUT/run" "${d:t}" 2>&1 \
      | grep -E "bench: (TOTAL|DRAG|FLING|PREP|memory|list|pointer)" | sed "s/^bench: /${d:t} r$r /" >> "$LOG"
  done
done
python3 "${0:h}/summarize.py" "$LOG"

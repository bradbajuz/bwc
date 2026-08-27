#!/usr/bin/env bash
# bench.sh — bwc vs GNU wc: wall-clock comparison, min of N runs, warm cache
#
# Methodology: warm the page cache once per fixture, then time N runs of
# each tool and report the MINIMUM (least-noise estimate of true cost).
# bwc is built with ReleaseFast — never benchmark a Debug build.

BWC=./zig-out/bin/bwc
N=${N:-5}
BENCH=/tmp/bwc-bench

zig build -Doptimize=ReleaseFast || exit 1

mkdir -p "$BENCH"

# --- fixtures (generated once, reused across runs) ---
if [ ! -f "$BENCH/ascii.txt" ]; then
  echo "generating fixtures in $BENCH ..."
  yes 'the quick brown fox jumps over the lazy dog' | head -c 300M >"$BENCH/ascii.txt"
  yes 'héllo wörld 你好 café' | head -c 300M >"$BENCH/utf8.txt"
  head -c 300M /dev/urandom >"$BENCH/binary.bin"
fi

# min-of-N wall time in milliseconds
time_min() {
  local best=999999999 start end elapsed i
  i=0
  while [ $i -lt $N ]; do
    start=$(date +%s%N)
    "$@" >/dev/null 2>&1
    end=$(date +%s%N)
    elapsed=$(((end - start) / 1000000))
    if [ $elapsed -ge 0 ] && [ $elapsed -lt $best ]; then best=$elapsed; fi
    i=$((i + 1))
  done
  echo $best
}

bench() {
  local label=$1 file=$2
  shift 2 # rest are flags for both tools

  cat "$file" >/dev/null # warm the page cache

  local wc_ms bwc_ms verdict
  wc_ms=$(time_min wc "$@" "$file")
  bwc_ms=$(time_min "$BWC" "$@" "$file")

  if [ "$wc_ms" -lt 5 ] && [ "$bwc_ms" -lt 5 ]; then
    verdict="tie (timer floor)"
  elif [ "$bwc_ms" -le "$wc_ms" ]; then
    verdict=$(awk "BEGIN { printf \"bwc %.2fx faster\", $wc_ms / ($bwc_ms == 0 ? 1 : $bwc_ms) }")
  else
    verdict=$(awk "BEGIN { printf \"wc %.2fx faster\", $bwc_ms / ($wc_ms == 0 ? 1 : $wc_ms) }")
  fi
  printf '%-28s wc=%6dms  bwc=%6dms  %s\n' "$label" "$wc_ms" "$bwc_ms" "$verdict"
}

for f in ascii.txt utf8.txt binary.bin; do
  bench "$f -l" "$BENCH/$f" -l
  bench "$f -w" "$BENCH/$f" -w
  bench "$f -c" "$BENCH/$f" -c
  bench "$f -m" "$BENCH/$f" -m
  bench "$f -L" "$BENCH/$f" -L
  bench "$f (all)" "$BENCH/$f" -l -w -c -m -L
done

if [ -f /tmp/big.bin ]; then
  bench "big.bin -l (2GB)" /tmp/big.bin -l
  bench "big.bin -c (2GB)" /tmp/big.bin -c
fi

# bwc learning checklist

Working through these in order. For each: I attempt the fix, then get it reviewed.

- [x] 1. Dead `@max` in the max-line loop (`src/main.zig:38-46`) — boundary-update pattern
- [x] 2. `defer` in the file loop "fd leak" (`src/main.zig:143`) — INVESTIGATED: not a bug. Zig `defer` is block-scoped and a loop body is a block, so the close fires per iteration. Proven experimentally: 100 files under `ulimit -n 64`, no errors. (Claim originated from Go's function-scoped defer; doesn't apply to Zig.)
- [x] 3. Invalid UTF-8 crashed `-m` — fixed: count decodable codepoints, skip undecodable bytes (matches GNU `wc -m`, verified against oracle). Bonus: `analyze` no longer fallible, error union removed.
- [x] 4. Golden-test harness — `golden.sh`: differential vs GNU wc (oracle). 59 cases: fixtures×flagsets matrix, multi-file, error paths, stdin. PASS/DIFF/XFAIL/XPASS verdicts; `expected_diffs` (21 entries) records catalogued divergences (items 8–11). XPASS is a failure (stale entry signal). Exit 0 only when fail=0 and xpass=0. Found items 10 & 11 during construction.
- [x] 5. Fused the three byte-wise counting passes (lines/words/max-line) into one loop in `analyze`; char loop stays separate (variable-width, skip-on-error). Verified as pure refactor: 11/11 unit tests + golden.sh 38/21 unchanged.
- [x] 6. De-duplicated the print blocks — extracted `printRow(*std.Io.Writer, FileResult, width, Flags)`; totals row is just a `FileResult` with `.path = "total"`. Five loose `show_*` bools became a `Flags` struct. Print section: 73 lines → 15. (Process lesson: harness tests the *binary* — `zig build || exit 1` added to golden.sh after a stale-build false alarm; also found `$(...)` strips trailing newlines, masking missing-\n bugs on single-row output.)
- [ ] 7. Streaming architecture — constant memory, chunk-boundary state
- [ ] 8. `-L` should count characters, not bytes (found via `wc -L utf8test.txt`: 11 vs 13)
- [ ] 9. Column-padding rule differs from GNU wc. Empirical GNU rule (coreutils 9.4): exactly ONE counter selected → no padding, ever; multiple counters → pad to digits of largest total, min 7 for stdin. bwc (`src/main.zig:176-187`) always uses max(lines,words,bytes) and forces 7 for stdin. Found via: `printf 'ab\n' | wc -L` (stdin case) and golden.sh `bwc -l foobar.txt` → ` 9` vs `9` (file case — same bug, caught by the harness)
- [ ] 10. `-w` treats undecodable bytes as word characters; GNU doesn't. `\xff\xfe hello`: bwc counts 2 words, wc counts 1 (found via golden.sh sweep on `testdir/bad.bin`)
- [ ] 11. Directory as argument: both print zero counts + rc 1, but GNU pads to width 7 (non-regular file → size unknown → width fallback); bwc prints width 1 (found via golden.sh sweep: `bwc testdir` vs `wc testdir`)

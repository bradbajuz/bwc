# bwc learning checklist

Working through these in order. For each: I attempt the fix, then get it reviewed.

- [x] 1. Dead `@max` in the max-line loop (`src/main.zig:38-46`) — boundary-update pattern
- [ ] 2. `defer` in the file loop leaks fds (`src/main.zig:143`) — defer is block-scoped
- [ ] 3. Invalid UTF-8 crashes `-m` (`src/main.zig:49`) — decide, don't propagate
- [ ] 4. Golden-test harness — diff `bwc` vs real `wc` before refactoring
- [ ] 5. Fuse the three counting passes into one loop (`analyze`)
- [ ] 6. De-duplicate the print blocks (`src/main.zig:173-245`)
- [ ] 7. Streaming architecture — constant memory, chunk-boundary state
- [ ] 8. `-L` should count characters, not bytes (found via `wc -L utf8test.txt`: 11 vs 13)
- [ ] 9. Stdin output is padded to width 7; GNU coreutils 9.4 doesn't pad (found via `printf 'ab\n' | wc -L`)

# bwc

A `wc` clone written in Zig, built as a learning exercise.

Counts lines, words, bytes, characters, and maximum line length for files or
standard input, aiming for GNU `wc`-compatible output.

## Usage

```
bwc [OPTION]... [FILE]...
```

With no FILE, or when FILE is not given, reads standard input.

| Option | Description              |
| ------ | ------------------------ |
| `-l`   | print the line count     |
| `-w`   | print the word count     |
| `-c`   | print the byte count     |
| `-m`   | print the character count|
| `-L`   | print the max line length|

With no options, defaults to `-l -w -c`.

## Compatibility notes

- `-m` counts decodable UTF-8 characters and silently skips undecodable
  bytes, matching GNU `wc` behavior under a UTF-8 locale.
- `-L` reports terminal display width, not codepoints, via libc's
  `wcwidth()` (the same function GNU `wc` uses): wide chars (CJK, most
  emoji) count 2, combining marks and control chars count 0, and tab
  advances to the next multiple of 8. The locale is taken from the
  environment (`setlocale(LC_ALL, "")`), as GNU `wc` does.

## Building

Requires Zig 0.16.0 or newer. Links against the system C library
(for `wcwidth`/`setlocale`), producing a dynamically linked binary.

```
zig build
```

The binary lands in `zig-out/bin/bwc`:

```
./zig-out/bin/bwc -l testdir/foobar.txt
```

## Testing

Unit tests (libc must be linked explicitly):

```
zig test src/main.zig -lc
```

Differential tests against the system `wc` (builds first, then compares
output and exit codes across a fixture × flag matrix):

```
./golden.sh
```

## Status

Work in progress — known issues and planned improvements are tracked in
[CHECKLIST.md](CHECKLIST.md).

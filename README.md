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

## Building

Requires Zig 0.16.0 or newer.

```
zig build
```

The binary lands in `zig-out/bin/bwc`:

```
./zig-out/bin/bwc -l foobar.txt
```

## Status

Work in progress — known issues and planned improvements are tracked in
[CHECKLIST.md](CHECKLIST.md).

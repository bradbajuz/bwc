const std = @import("std");

// ------------------------------ types ------------------------------

extern fn wcwidth(wc: c_int) c_int;
extern fn setlocale(category: c_int, locale: [*:0]const u8) ?[*:0]u8;
const LC_ALL: c_int = 6; // glibc

const FileResult = struct {
    lines: usize,
    words: usize,
    bytes: usize,
    chars: usize,
    max_line_len: usize,
    path: []const u8, // filename; empty when reading from stdin
};

const Flags = struct {
    lines: bool = false,
    words: bool = false,
    chars: bool = false,
    bytes: bool = false,
    len: bool = false,
};

const Analyzer = struct {
    lines: usize = 0,
    words: usize = 0,
    bytes: usize = 0,
    chars: usize = 0,
    current_len: usize = 0,
    max_len: usize = 0,
    in_word: bool = false,

    /// Process chunk, updating all counters. Returns bytes consumed.
    /// When is_eof is false, an incomplete UTF-8 sequence at the END of
    /// chunk is left uncomsumed (caller carries it into the next read).
    /// When true, it's truncated garbage: skipped byte-at-a-time (item 3).
    fn process(self: *Analyzer, chunk: []const u8, is_eof: bool) usize {
        var i: usize = 0;
        while (i < chunk.len) {
            const n = std.unicode.utf8ByteSequenceLength(chunk[i]) catch {
                i += 1;
                continue; // invalid lead byte: skip, don't count
            };
            if (i + n > chunk.len) {
                if (!is_eof) break; // carry: decide when the next chunk arrives
                i += 1;
                continue; // EOF: truncated, skip
            }
            const cp = std.unicode.utf8Decode(chunk[i..][0..n]) catch {
                i += 1;
                continue; // valid lead, bad continuation ("\xc3\x28")
            };

            if (isWordSeparator(cp)) {
                self.in_word = false;
            } else if (!self.in_word) {
                self.words += 1;
                self.in_word = true;
            }

            if (cp == '\n') {
                self.lines += 1;
                self.max_len = @max(self.max_len, self.current_len);
                self.current_len = 0;
            } else if (cp == '\t') {
                self.current_len += 8 - (self.current_len % 8);
            } else {
                const w = wcwidth(cp);
                if (w > 0) self.current_len += @intCast(w);
            }

            self.chars += 1;
            i += n;
        }
        self.bytes += i; // carried bytes get counted when finally consumed
        return i;
    }

    /// Fast path for lines/bytes-only selections: '\n' is a single byte
    /// and invalid UTF-8 can't affect the count, so no decoding, no carry.
    fn processLinesOnly(self: *Analyzer, chunk: []const u8) void {
        self.lines += std.mem.count(u8, chunk, "\n");
        self.bytes += chunk.len;
    }

    /// Final fold; call once after the last chunk.
    fn result(self: *Analyzer, path: []const u8) FileResult {
        self.max_len = @max(self.max_len, self.current_len);
        return .{
            .path = path,
            .lines = self.lines,
            .words = self.words,
            .bytes = self.bytes,
            .chars = self.chars,
            .max_line_len = self.max_len,
        };
    }
};

// ------------------------------ logic ------------------------------

/// Totals
fn addToTotal(total: *FileResult, r: FileResult) void {
    total.lines += r.lines;
    total.words += r.words;
    total.bytes += r.bytes;
    total.chars += r.chars;
    total.max_line_len = @max(total.max_line_len, r.max_line_len);
}

/// Stream one input through the analyzer in buf-sized chunks,
/// carrying any incomplete UTF-8 tail across chunk boundaries.
fn countInput(file: std.Io.File, io: std.Io, buf: []u8, path: []const u8, flags: Flags) !FileResult {
    var a: Analyzer = .{};

    if (!flags.words and !flags.chars and !flags.len) {
        // selection ⊆ {lines, bytes}: byte scan suffices
        while (true) {
            const n = file.readStreaming(io, &.{buf}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            a.processLinesOnly(buf[0..n]);
        }
        return a.result(path);
    }

    // full decode path (words/chars/len selected)
    var carry: usize = 0;
    while (true) {
        const n = file.readStreaming(io, &.{buf[carry..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const total = carry + n;
        const used = a.process(buf[0..total], false);
        carry = total - used;
        @memmove(buf[0..carry], buf[used..total]);
    }
    _ = a.process(buf[0..carry], true); // EOF sementics for any leftover tail
    return a.result(path);
}

/// Word separators per glibc C.UTF-8 iswspace: ASCII whitespace plus
/// Unicode category Zs. Notably NOT U+0085 or U+2028/2029 (verified
/// against GNU wc).
fn isWordSeparator(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isWhitespace(@intCast(cp));
    return switch (cp) {
        0xA0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// Count all five wc metrics of `contents`. Infallible: undecodable
/// bytes are skipped, not errors (see checklist items 3, 10).
fn analyze(contents: []const u8, path: []const u8) FileResult {
    var a: Analyzer = .{};
    _ = a.process(contents, true);
    return a.result(path);
}

/// Print one row of counters, right-aligned to `width`, with the
/// path label when present ("total" is just another path).
fn printRow(w: *std.Io.Writer, result: FileResult, width: usize, flags: Flags) !void {
    // track column printing
    var printed_column = false;

    if (flags.lines) {
        if (printed_column) try w.print(" ", .{});
        try w.print("{d:[1]}", .{ result.lines, width });
        printed_column = true;
    }

    if (flags.words) {
        if (printed_column) try w.print(" ", .{});
        try w.print("{d:[1]}", .{ result.words, width });
        printed_column = true;
    }

    if (flags.chars) {
        if (printed_column) try w.print(" ", .{});
        try w.print("{d:[1]}", .{ result.chars, width });
        printed_column = true;
    }

    if (flags.bytes) {
        if (printed_column) try w.print(" ", .{});
        try w.print("{d:[1]}", .{ result.bytes, width });
        printed_column = true;
    }

    if (flags.len) {
        if (printed_column) try w.print(" ", .{});
        try w.print("{d:[1]}", .{ result.max_line_len, width });
        printed_column = true;
    }

    if (result.path.len > 0) try w.print(" {s}", .{result.path});
    try w.print("\n", .{});
}

/// wc clone: count lines, words, bytes, chars, and max line length for
/// each file (or stdin when no files are given), print one row per input
/// plus a total row for multiple files. Exits 1 if any file errored.
pub fn main(init: std.process.Init) !void {
    _ = setlocale(LC_ALL, "");
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var buf: [128 * 1024]u8 = undefined;

    var out_buf: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var writer = std.Io.File.writer(stdout_file, init.io, &out_buf);

    var had_error = false;
    var flags: Flags = .{};
    var any_flag: bool = false;

    var filenames: std.ArrayList([]const u8) = .empty;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-l")) {
            any_flag = true;
            flags.lines = true;
        } else if (std.mem.eql(u8, arg, "-w")) {
            any_flag = true;
            flags.words = true;
        } else if (std.mem.eql(u8, arg, "-c")) {
            any_flag = true;
            flags.bytes = true;
        } else if (std.mem.eql(u8, arg, "-m")) {
            any_flag = true;
            flags.chars = true;
        } else if (std.mem.eql(u8, arg, "-L")) {
            any_flag = true;
            flags.len = true;
        } else {
            try filenames.append(arena, arg);
        }
    }

    if (!any_flag) {
        flags.lines = true;
        flags.words = true;
        flags.bytes = true;
    }

    const selected = @as(usize, @intFromBool(flags.lines)) + @intFromBool(flags.words) + @intFromBool(flags.chars) + @intFromBool(flags.bytes) + @intFromBool(flags.len);
    var results: std.ArrayList(FileResult) = .empty;
    var saw_directory = false;
    var totals: FileResult = .{ .lines = 0, .words = 0, .bytes = 0, .chars = 0, .max_line_len = 0, .path = "total" };

    if (filenames.items.len == 0) {
        const result = try countInput(std.Io.File.stdin(), init.io, &buf, "", flags);

        addToTotal(&totals, result);

        try results.append(arena, result);
    } else {
        for (filenames.items) |filename| {
            const file = std.Io.Dir.openFile(std.Io.Dir.cwd(), init.io, filename, .{ .allow_directory = false }) catch |err| {
                switch (err) {
                    error.FileNotFound => std.debug.print("bwc: {s}: No such file or directory\n", .{filename}),
                    error.PermissionDenied, error.AccessDenied => std.debug.print("bwc: {s}: Permission denied\n", .{filename}),
                    error.IsDir => {
                        std.debug.print("bwc: {s}: Is a directory\n", .{filename});
                        try results.append(arena, FileResult{ .lines = 0, .words = 0, .bytes = 0, .chars = 0, .max_line_len = 0, .path = filename });
                        saw_directory = true;
                    },
                    else => std.debug.print("bwc: {s}: {s}\n", .{ filename, @errorName(err) }),
                }
                had_error = true;
                continue;
            };
            defer file.close(init.io);

            if (selected == 1 and flags.bytes) { // lone -c
                const stat = try file.stat(init.io);
                if (stat.kind == .file) {
                    const result = FileResult{ .lines = 0, .words = 0, .bytes = @intCast(stat.size), .chars = 0, .max_line_len = 0, .path = filename };
                    addToTotal(&totals, result);
                    try results.append(arena, result);
                    continue;
                }
                // non-regular (pipe, device...): fall through and actually read
            }

            const result = try countInput(file, init.io, &buf, filename, flags);

            addToTotal(&totals, result);

            try results.append(arena, result);
        }
    }

    var width: usize = 1;
    if (selected > 1 or filenames.items.len > 1) {
        // determine width for formatting; total_chars can never be larger than total_bytes
        var max_val = @max(totals.lines, totals.words, totals.bytes);
        while (max_val >= 10) {
            max_val /= 10;
            width += 1;
        }
        if (filenames.items.len == 0) {
            width = @max(width, 7);
        }
        if (saw_directory) width = @max(width, 7);
    }

    for (results.items) |item| {
        try printRow(&writer.interface, item, width, flags);
    }

    if (filenames.items.len > 1) {
        try printRow(&writer.interface, totals, width, flags);
    }
    try writer.interface.flush();
    if (had_error) std.process.exit(1);
}

// ------------------------------ tests ------------------------------

test "max line length" {
    const result = analyze("ab\n", "");
    try std.testing.expectEqual(2, result.max_line_len);
}

test "max line length: trailing newline" {
    const result = analyze("a\nbb\n", "");
    try std.testing.expectEqual(2, result.max_line_len);
}

test "max line length: no trailing newline" {
    const result = analyze("a\nbb", "");
    try std.testing.expectEqual(2, result.max_line_len);
}

test "max line length: empty input" {
    const result = analyze("", "");
    try std.testing.expectEqual(0, result.max_line_len);
}

test "max line length: just a newline" {
    const result = analyze("\n", "");
    try std.testing.expectEqual(0, result.max_line_len);
}

test "max line length: multibyte characters" {
    _ = setlocale(LC_ALL, "C.UTF-8");
    const result = analyze("héllo\nbb\n", "");
    try std.testing.expectEqual(5, result.max_line_len);
}

test "max line length: invalid bytes don't count" {
    const result = analyze("\xff\xfe hello", "");
    try std.testing.expectEqual(6, result.max_line_len);
}

test "max line length: wide chars count double" {
    // 你 and 又 are East Asian Wide: wcwidth = 2 each
    // -> 4 columns, not 2 codepoints
    _ = setlocale(LC_ALL, "C.UTF-8");
    const result = analyze("你好\n", "");
    try std.testing.expectEqual(4, result.max_line_len);
}

test "max line length: tab advances to next stop" {
    // a,b -> column 2; tab -> 8; c,d -> 10 (oracle: printf 'ab\tcd\n' | wc -L)
    _ = setlocale(LC_ALL, "C.UTF-8");
    const result = analyze("ab\tcd\n", "");
    try std.testing.expectEqual(10, result.max_line_len);
}

test "max line length: combining marks are zero width" {
    // e + U+0301 combining acute -> 1 column
    _ = setlocale(LC_ALL, "C.UTF-8");
    const result = analyze("e\xcc\x81\n", "");
    try std.testing.expectEqual(1, result.max_line_len);
}

test "max line length: control chars are zero width" {
    // BEL is non-printable: wcwidth = -1 -> adds nothing
    _ = setlocale(LC_ALL, "C.UTF-8");
    const result = analyze("a\x07b\n", "");
    try std.testing.expectEqual(2, result.max_line_len);
}

test "char count: invalid bytes are skipped" {
    const result = analyze("\xff\xfe hello", "");
    try std.testing.expectEqual(6, result.chars);
}

test "char count: multibyte characters" {
    const result = analyze("héllo", "");
    try std.testing.expectEqual(5, result.chars);
}

test "char count: valid lead byte with invalid continuation" {
    const result = analyze("\xc3\x28", "");
    try std.testing.expectEqual(1, result.chars);
}

test "char count: truncated sequence at end of input" {
    const result = analyze("\xc3", "");
    try std.testing.expectEqual(0, result.chars);
}

test "char count: empty input" {
    const result = analyze("", "");
    try std.testing.expectEqual(0, result.chars);
}

test "words: invalid bytes are invisible" {
    const result = analyze("\xff\xfe hello", "");
    try std.testing.expectEqual(1, result.words);
}

test "words: invalid bytes don't split a word" {
    const result = analyze("ab\xffcd", "");
    try std.testing.expectEqual(1, result.words);
}

test "words: non-breaking space separates" {
    const result = analyze("a\xc2\xa0b", "");
    try std.testing.expectEqual(2, result.words);
}

test "words: NEL is not a separator" {
    const result = analyze("a\xc2\x85b", "");
    try std.testing.expectEqual(1, result.words);
}

test "all counters: multibyte input" {
    _ = setlocale(LC_ALL, "C.UTF-8");
    const result = analyze("héllo wörld\n", "");
    try std.testing.expectEqual(1, result.lines);
    try std.testing.expectEqual(2, result.words);
    try std.testing.expectEqual(14, result.bytes);
    try std.testing.expectEqual(12, result.chars);
    try std.testing.expectEqual(11, result.max_line_len);
}

test "lines only: counts across chunk boundaries" {
    var a: Analyzer = .{};
    a.processLinesOnly("ab\ncd");
    a.processLinesOnly("\nef\n");
    try std.testing.expectEqual(3, a.lines);
    try std.testing.expectEqual(9, a.bytes);
}

test "streaming: chunk boundaries are invisible" {
    _ = setlocale(LC_ALL, "C.UTF-8");
    const input = "ab\théllo 😀\n\xffdone";
    const baseline = analyze(input, "");

    var k: usize = 0;
    while (k <= input.len) : (k += 1) {
        var a: Analyzer = .{};
        const used = a.process(input[0..k], false);

        // carry: unconsumed tail of chunk 1 is prepending to chunk 2 --
        // the same dance main's read loop will do in step 4
        var tmp: [64]u8 = undefined;
        const tail = input[used..k];
        @memcpy(tmp[0..tail.len], tail);
        @memcpy(tmp[tail.len..][0 .. input.len - k], input[k..]);
        _ = a.process(tmp[0 .. tail.len + input.len - k], true);

        const got = a.result("");
        if (!std.meta.eql(baseline, got)) {
            std.debug.print("failed at split {d}\n", .{k});
        }
        try std.testing.expectEqual(baseline, a.result(""));
    }
}

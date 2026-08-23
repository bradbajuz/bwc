const std = @import("std");

// ------------------------------ types ------------------------------

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

// ------------------------------ logic ------------------------------

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

    // single pass, one codepoint at a time: wc -l, -w, -m, -L
    // undecodable bytes are skipped, never counted
    var i: usize = 0;
    var line_count: usize = 0;
    var word_count: usize = 0;
    var in_word: bool = false;
    var char_count: usize = 0;
    var current_len: usize = 0;
    var max_len: usize = 0;

    while (i < contents.len) {
        const n = std.unicode.utf8ByteSequenceLength(contents[i]) catch {
            i += 1;
            continue; // invalid lead byte: skip, don't count
        };
        if (i + n > contents.len) {
            i += 1;
            continue; // truncated final sequence: skip, don't count
        }
        const cp = std.unicode.utf8Decode(contents[i..][0..n]) catch {
            i += 1;
            continue; // valid lead, bad continuation ("\xc3\x28")
        };

        if (isWordSeparator(cp)) {
            in_word = false;
        } else if (!in_word) {
            word_count += 1;
            in_word = true;
        }

        if (cp == '\n') {
            line_count += 1;
            max_len = @max(max_len, current_len);
            current_len = 0;
        } else {
            current_len += 1;
        }

        char_count += 1;
        i += n;
    }

    max_len = @max(max_len, current_len);

    return FileResult{
        .path = path,
        .lines = line_count,
        .words = word_count,
        .bytes = contents.len,
        .chars = char_count,
        .max_line_len = max_len,
    };
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
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var buf: [4096]u8 = undefined;

    var out_buf: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var writer = std.Io.File.writer(stdout_file, init.io, &out_buf);

    var had_error = false;
    var total_lines: usize = 0;
    var total_words: usize = 0;
    var total_bytes: usize = 0;
    var total_chars: usize = 0;
    var total_max_line_len: usize = 0;
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

    var results: std.ArrayList(FileResult) = .empty;
    var saw_directory = false;

    if (filenames.items.len == 0) {
        const file = std.Io.File.stdin();
        var file_reader = std.Io.File.reader(file, init.io, &buf);
        const contents = try std.Io.Reader.allocRemaining(&file_reader.interface, arena, .unlimited);

        const result = analyze(contents, "");

        total_lines += result.lines;
        total_words += result.words;
        total_bytes += result.bytes;
        total_chars += result.chars;
        total_max_line_len = @max(result.max_line_len, total_max_line_len);

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

            var file_reader = std.Io.File.reader(file, init.io, &buf);
            const contents = try std.Io.Reader.allocRemaining(&file_reader.interface, arena, .unlimited);

            const result = analyze(contents, filename);

            total_lines += result.lines;
            total_words += result.words;
            total_bytes += result.bytes;
            total_chars += result.chars;
            total_max_line_len = @max(result.max_line_len, total_max_line_len);

            try results.append(arena, result);
        }
    }

    const selected = @as(usize, @intFromBool(flags.lines)) + @intFromBool(flags.words) +
        @intFromBool(flags.chars) + @intFromBool(flags.bytes) + @intFromBool(flags.len);

    var width: usize = 1;
    if (selected > 1 or filenames.items.len > 1) {
        // determine width for formatting; total_chars can never be larger than total_bytes
        var max_val = @max(total_lines, total_words, total_bytes);
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
        const totals = FileResult{
            .lines = total_lines,
            .words = total_words,
            .bytes = total_bytes,
            .chars = total_chars,
            .max_line_len = total_max_line_len,
            .path = "total",
        };
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
    const result = analyze("héllo\nbb\n", "");
    try std.testing.expectEqual(5, result.max_line_len);
}

test "max line length: invalid bytes don't count" {
    const result = analyze("\xff\xfe hello", "");
    try std.testing.expectEqual(6, result.max_line_len);
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
    const result = analyze("héllo wörld\n", "");
    try std.testing.expectEqual(1, result.lines);
    try std.testing.expectEqual(2, result.words);
    try std.testing.expectEqual(14, result.bytes);
    try std.testing.expectEqual(12, result.chars);
    try std.testing.expectEqual(11, result.max_line_len);
}

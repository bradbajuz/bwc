const std = @import("std");

const FileResult = struct {
    lines: usize,
    words: usize,
    bytes: usize,
    chars: usize,
    max_line_len: usize,
    path: []const u8, // filename; empty when reading from stdin
};

fn analyze(contents: []const u8, path: []const u8) !FileResult {
    // wc -l
    var line_count: usize = 0;
    for (contents) |byte| {
        if (byte == '\n') {
            line_count += 1;
        }
    }

    // wc -w
    var word_count: usize = 0;
    var in_word: bool = false;

    for (contents) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            in_word = false;
        } else if (!in_word) {
            word_count += 1;
            in_word = true;
        }
    }

    // wc -L
    var current_len: usize = 0;
    var max_len: usize = 0;

    for (contents) |byte| {
        if (byte == '\n') {
            current_len = 0;
        } else {
            current_len += 1;
        }
        max_len = @max(max_len, current_len);
    }

    // wc -m
    const char_count = try std.unicode.utf8CountCodepoints(contents);

    return FileResult{
        .path = path,
        .lines = line_count,
        .words = word_count,
        .bytes = contents.len,
        .chars = char_count,
        .max_line_len = max_len,
    };
}

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
    var show_lines: bool = false;
    var show_words: bool = false;
    var show_bytes: bool = false;
    var show_chars: bool = false;
    var show_len: bool = false;
    var any_flag: bool = false;

    var filenames: std.ArrayList([]const u8) = .empty;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-l")) {
            any_flag = true;
            show_lines = true;
        } else if (std.mem.eql(u8, arg, "-w")) {
            any_flag = true;
            show_words = true;
        } else if (std.mem.eql(u8, arg, "-c")) {
            any_flag = true;
            show_bytes = true;
        } else if (std.mem.eql(u8, arg, "-m")) {
            any_flag = true;
            show_chars = true;
        } else if (std.mem.eql(u8, arg, "-L")) {
            any_flag = true;
            show_len = true;
        } else {
            try filenames.append(arena, arg);
        }
    }

    if (!any_flag) {
        show_lines = true;
        show_words = true;
        show_bytes = true;
    }

    var results: std.ArrayList(FileResult) = .empty;

    if (filenames.items.len == 0) {
        const file = std.Io.File.stdin();
        var file_reader = std.Io.File.reader(file, init.io, &buf);
        const contents = try std.Io.Reader.allocRemaining(&file_reader.interface, arena, .unlimited);

        const result = try analyze(contents, "");

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
                    },
                    else => std.debug.print("bwc: {s}: {s}\n", .{ filename, @errorName(err) }),
                }
                had_error = true;
                continue;
            };
            defer file.close(init.io);

            var file_reader = std.Io.File.reader(file, init.io, &buf);
            const contents = try std.Io.Reader.allocRemaining(&file_reader.interface, arena, .unlimited);

            const result = try analyze(contents, filename);

            total_lines += result.lines;
            total_words += result.words;
            total_bytes += result.bytes;
            total_chars += result.chars;
            total_max_line_len = @max(result.max_line_len, total_max_line_len);

            try results.append(arena, result);
        }
    }

    // determine width for formatting; total_chars can never be larger than total_bytes
    var max_val = @max(total_lines, total_words, total_bytes);
    var width: usize = 1;

    while (max_val >= 10) {
        max_val /= 10;
        width += 1;
    }

    if (filenames.items.len == 0) {
        width = @max(width, 7);
    }

    for (results.items) |item| {
        var printed_column = false;

        if (show_lines) {
            if (printed_column) try writer.interface.print(" ", .{});
            try writer.interface.print("{d:[1]}", .{ item.lines, width });
            printed_column = true;
        }

        if (show_words) {
            if (printed_column) try writer.interface.print(" ", .{});
            try writer.interface.print("{d:[1]}", .{ item.words, width });
            printed_column = true;
        }

        if (show_chars) {
            if (printed_column) try writer.interface.print(" ", .{});
            try writer.interface.print("{d:[1]}", .{ item.chars, width });
            printed_column = true;
        }

        if (show_bytes) {
            if (printed_column) try writer.interface.print(" ", .{});
            try writer.interface.print("{d:[1]}", .{ item.bytes, width });
            printed_column = true;
        }

        if (show_len) {
            if (printed_column) try writer.interface.print(" ", .{});
            try writer.interface.print("{d:[1]}", .{ item.max_line_len, width });
            printed_column = true;
        }

        if (item.path.len > 0) try writer.interface.print(" {s}", .{item.path});
        try writer.interface.print("\n", .{});
    }

    if (filenames.items.len > 1) {
        // track column printing
        var printed_column = false;

        if (show_lines) {
            if (printed_column) try writer.interface.print(" ", .{});
            try writer.interface.print("{d:[1]}", .{ total_lines, width });
            printed_column = true;
        }

        if (show_words) {
            if (printed_column) try writer.interface.print(" ", .{});
            try writer.interface.print("{d:[1]}", .{ total_words, width });
            printed_column = true;
        }

        if (show_chars) {
            if (printed_column) try writer.interface.print(" ", .{});
            try writer.interface.print("{d:[1]}", .{ total_chars, width });
            printed_column = true;
        }

        if (show_bytes) {
            if (printed_column) try writer.interface.print(" ", .{});
            try writer.interface.print("{d:[1]}", .{ total_bytes, width });
            printed_column = true;
        }

        if (show_len) {
            if (printed_column) try writer.interface.print(" ", .{});
            try writer.interface.print("{d:[1]}", .{ total_max_line_len, width });
            printed_column = true;
        }

        try writer.interface.print(" total\n", .{});
    }
    try writer.interface.flush();
    if (had_error) std.process.exit(1);
}

test "max line length" {
    const result = try analyze("ab\n", "");
    try std.testing.expectEqual(2, result.max_line_len);
}

test "max line length: trailing newline" {
    const result = try analyze("a\nbb\n", "");
    try std.testing.expectEqual(2, result.max_line_len);
}

test "max line length: no trailing newline" {
    const result = try analyze("a\nbb", "");
    try std.testing.expectEqual(2, result.max_line_len);
}

test "max line length: empty input" {
    const result = try analyze("", "");
    try std.testing.expectEqual(0, result.max_line_len);
}

test "max line length: just a newline" {
    const result = try analyze("\n", "");
    try std.testing.expectEqual(0, result.max_line_len);
}

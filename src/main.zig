pub const std_options = std.Options{
    .log_level = .info,
};

const std = @import("std");

const Io = std.Io;
const File = std.Io.File;
const Dir = std.Io.Dir;

pub const SourceFile = struct {
    name: []const u8,
    io: Io,
    total_lines: u32 = 0,
    current_line: u32 = 1,
    handle: File,
    reader_buffer: [4096]u8 = undefined,
    file_reader: ?File.Reader = null,

    fn init(io: Io, path: []const u8) !SourceFile {
        std.log.debug("Attempting to open file {s}", .{path});

        var handle = try Dir.cwd().openFile(io, path, .{});
        errdefer handle.close(io);

        var self = SourceFile{
            .name = path,
            .io = io,
            .handle = handle,
        };

        // Count lines with a scratch reader. File readers are positional
        // (they track their own offset), so the merge-pass reader created
        // later in readNextLine starts fresh at the beginning of the file.
        var count_reader = self.handle.reader(io, &self.reader_buffer);
        while (true) {
            const n = try count_reader.interface.discardDelimiterExclusive('\n');
            // The delimiter (or the end of the stream) is now the next byte.
            const at_end = blk: {
                _ = count_reader.interface.peek(1) catch |err| switch (err) {
                    error.EndOfStream => break :blk true,
                    else => |e| return e,
                };
                break :blk false;
            };
            if (n == 0 and at_end) break; // empty file, or nothing after the last newline
            self.total_lines += 1;
            if (!at_end) count_reader.interface.toss(1); // consume '\n'
        }

        return self;
    }

    /// Reads the next merge-pass line (without the trailing newline) into
    /// `buffer`. Returns null at end of file.
    ///
    /// The file reader is created lazily on first use, where `self` is a
    /// pointer, so the reader's reference to `&self.reader_buffer` stays
    /// valid for the file's lifetime. (Creating it in init would store a
    /// pointer into a local struct in the returned value — dangling.)
    fn readNextLine(self: *SourceFile, allocator: std.mem.Allocator, line_buf: *[]u8, initial: []const u8) !?[]const u8 {
        if (self.file_reader == null) {
            self.file_reader = self.handle.reader(self.io, &self.reader_buffer);
        }
        return readLine(allocator, &self.file_reader.?, line_buf, initial);
    }
};

const LineResult = struct {
    /// The line (or trailing partial line) that was read; null at a clean
    /// end of file.
    line: ?[]const u8,
};

/// Attempts to read one line from `reader` into `line_buf`.
///
/// Returns `error.WriteFailed` when the line outgrows the buffer; the
/// reader is then left mid-line and the caller must rewind it (seekTo)
/// before retrying with a larger buffer.
fn attemptLine(reader: *File.Reader, line_buf: []u8) Io.Reader.StreamError!LineResult {
    var line_writer = Io.Writer.fixed(line_buf);
    const n = reader.interface.streamDelimiter(&line_writer, '\n') catch |err| switch (err) {
        error.WriteFailed => return err,
        error.EndOfStream => {
            // Stream ended without a newline: return the partial line, or
            // null if there was nothing after the last newline.
            const line = line_writer.buffered();
            return .{ .line = if (line.len == 0) null else std.mem.trimEnd(u8, line, "\r") };
        },
        else => |e| return e,
    };
    _ = n;
    // On success the delimiter is the first buffered byte; consume it.
    reader.interface.toss(1);
    return .{ .line = std.mem.trimEnd(u8, line_writer.buffered(), "\r") };
}

/// Reads one line from `reader` into the growable buffer `*line_buf`.
///
/// Returns null at a clean end of file. A final line without a trailing
/// newline is still returned. Trailing '\r' (CRLF input) is stripped.
///
/// If a line does not fit in the current buffer, the buffer is grown with
/// `allocator` (doubled, minimum 4096 bytes) and the reader is rewound to
/// the start of the line and retried. The grown buffer is stored back into
/// `*line_buf` so later lines reuse it. `initial` is the buffer's original
/// (unallocated, e.g. stack) slice, used to tell heap from stack. The
/// caller owns the allocation and must free `*line_buf` if it no longer
/// points at `initial`.
///
/// The returned slice points into `*line_buf` and is valid until the next
/// call to this function with the same `line_buf`.
fn readLine(allocator: std.mem.Allocator, reader: *File.Reader, line_buf: *[]u8, initial: []const u8) !?[]const u8 {
    while (true) {
        const line_start = File.Reader.logicalPos(reader);
        const result = attemptLine(reader, line_buf.*) catch |err| {
            if (err != error.WriteFailed) return err;
            // The line outgrew the buffer: grow it and retry from the
            // start of the line.
            const new_len = @max(line_buf.*.len * 2, 4096);
            const grown = if (line_buf.*.ptr == initial.ptr)
                try allocator.alloc(u8, new_len)
            else
                try allocator.realloc(line_buf.*, new_len);
            line_buf.* = grown;
            try reader.seekTo(line_start);
            continue;
        };
        return result.line;
    }
}

pub fn mergeFiles(allocator: std.mem.Allocator, source_files: []SourceFile, writer: *Io.Writer) !void {
    var total_lines: u32 = 0;
    for (source_files) |file| {
        total_lines += file.total_lines;
        std.log.debug("file {s} has a total_lines of {d}", .{ file.name, file.total_lines });
    }

    // Reusable buffer for reading lines. Grown (and heap-allocated) on
    // demand if a line exceeds the initial size.
    var line_buffer: [4096]u8 = undefined;
    var line_buf: []u8 = line_buffer[0..];

    var i: u32 = 0;
    while (i < total_lines) : (i += 1) {
        var weight: f64 = 1.1;
        var candidate: ?*SourceFile = null;

        for (source_files) |*file| {
            std.log.debug("Checking {s} current_line = {d}, total_lines = {d}", .{ file.name, file.current_line, file.total_lines });
            if (file.current_line <= file.total_lines) {
                const w: f64 = @as(f64, @floatFromInt(file.current_line)) / @as(f64, @floatFromInt(file.total_lines));
                std.log.debug("For line {d} we have a candidate {s} with a weight of {d}", .{ i, file.name, w });
                if (w < weight) {
                    candidate = file;
                    weight = w;
                }
            }
        }

        if (candidate) |f| {
            const line = (try f.readNextLine(allocator, &line_buf, &line_buffer)) orelse return error.UnexpectedEndOfStream;
            try writer.print("{s}\n", .{line});
            f.current_line += 1;
        } else {
            std.log.err("Failed to find candidate for line {d} out of total lines {d}", .{ i + 1, total_lines });
            return error.NoCandidateFound;
        }
    }
    if (line_buf.ptr != line_buffer[0..].ptr) {
        allocator.free(line_buf);
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // Collect the input file paths from the command line.
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    defer args_iter.deinit();
    const argv0 = args_iter.next() orelse unreachable;
    var paths = std.ArrayList([]const u8).empty;
    defer paths.deinit(gpa);
    while (args_iter.next()) |arg| {
        try paths.append(gpa, arg);
    }
    std.log.debug("argv.len = {d}", .{paths.items.len + 1});
    if (paths.items.len == 0) {
        try printUsage(io, argv0);
        return error.Usage;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.stdout().writer(io, &stdout_buffer);
    defer {
        stdout_writer.interface.flush() catch {};
    }
    const stdout = &stdout_writer.interface;

    var source_files = std.ArrayList(SourceFile).empty;
    defer {
        for (source_files.items) |*file| {
            file.handle.close(io);
        }
        source_files.deinit(gpa);
    }

    for (paths.items) |file_path| {
        const file = try SourceFile.init(io, file_path);
        try source_files.append(gpa, file);
        std.log.info("Found {d} lines in {s}", .{ file.total_lines, file_path });
    }

    try mergeFiles(gpa, source_files.items, stdout);
}

fn printUsage(io: Io, program: []const u8) !void {
    var buf: [128]u8 = undefined;
    var w = File.stderr().writer(io, &buf);
    try w.interface.print("Usage: {s} <file1> [file2] ...\n", .{program});
    try w.interface.flush();
}

const expect = std.testing.expect;
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Zig 0.16 has no `Dir.makeTempFile`, so tests create their own temp files
/// with unique, clearly namespaced names.
var temp_file_counter: u32 = 0;

/// Creates a uniquely named temp file in the CWD containing `contents`.
/// The "merger_test_" prefix means we can never clobber a user file; at worst
/// we collide with our own stale test artifacts, which writeFile truncates.
/// Returns the allocated path; the caller must call `cleanupTempFile`.
fn makeTempFile(allocator: Allocator, stem: []const u8, contents: []const u8) ![]u8 {
    temp_file_counter += 1;
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "merger_test_{d}_{s}.txt", .{ temp_file_counter, stem }) catch unreachable;

    const path = try allocator.dupe(u8, name);
    errdefer allocator.free(path);

    try Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = contents,
    });
    return path;
}

fn cleanupTempFile(allocator: Allocator, path: []u8) void {
    Dir.cwd().deleteFile(std.testing.io, path) catch {};
    allocator.free(path);
}

/// Reads every line of `sf` and asserts it matches `expected` exactly, in order.
fn expectLines(sf: *SourceFile, expected: []const []const u8) !void {
    var buf: [4096]u8 = undefined;
    var line_buf: []u8 = buf[0..];
    var i: usize = 0;
    while (try sf.readNextLine(std.testing.allocator, &line_buf, &buf)) |line| {
        if (i >= expected.len) return error.TooManyLines;
        try expect(std.mem.eql(u8, line, expected[i]));
        i += 1;
    }
    if (line_buf.ptr != buf[0..].ptr) {
        std.testing.allocator.free(line_buf);
    }
    try expect(i == expected.len);
}

/// Runs mergeFiles into a fixed buffer and returns the produced bytes.
fn mergeToBuffer(allocator: std.mem.Allocator, files: *std.ArrayList(SourceFile), buf: []u8) ![]const u8 {
    var w = Io.Writer.fixed(buf);
    try mergeFiles(allocator, files.items, &w);
    return w.buffered();
}

/// mergeFiles terminates every line with '\n', so line count == newline count.
fn countLines(output: []const u8) usize {
    var count: usize = 0;
    for (output) |b| {
        if (b == '\n') count += 1;
    }
    return count;
}

/// Asserts each element of `expected` occurs in `output` in order (not
/// necessarily contiguously), i.e. per-file ordering is preserved.
fn expectSubsequence(output: []const u8, expected: []const []const u8) !void {
    var j: usize = 0;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        // Skip the trailing artifact after the final '\n'.
        if (output.len > 0 and line.len == 0 and line.ptr == output.ptr + output.len) continue;
        if (j < expected.len and std.mem.eql(u8, line, expected[j])) j += 1;
    }
    try expect(j == expected.len);
}

/// Asserts lines of the form "<prefix><n>" occur exactly `expected_count`
/// times and in strictly increasing numeric order, i.e. the source file's own
/// line order is preserved in the merge output.
fn expectOrderedNumericLines(output: []const u8, prefix: u8, expected_count: u32) !void {
    var last: u32 = 0;
    var seen: u32 = 0;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if (output.len > 0 and line.len == 0 and line.ptr == output.ptr + output.len) continue;
        if (line.len >= 2 and line[0] == prefix) {
            const v = std.fmt.parseInt(u32, line[1..], 10) catch return error.BadLineFormat;
            if (seen > 0) try expect(v > last);
            last = v;
            seen += 1;
        }
    }
    try expect(seen == expected_count);
}

/// Asserts the output is proportionally distributed: the output is split into
/// `nbuckets` consecutive windows and each file's share in every window must be
/// within `tolerance` lines of its target share (bucket_len * size / total).
/// This is what "contents are distributed evenly throughout the output" means.
fn expectBucketsProportional(
    output: []const u8,
    prefixes: []const []const u8,
    files: *std.ArrayList(SourceFile),
    nbuckets: usize,
    tolerance: f64,
) !void {
    try expect(nbuckets >= 1);
    try expect(nbuckets <= 10);
    try expect(prefixes.len == files.items.len);
    try expect(files.items.len <= 4);
    const total = countLines(output);
    if (total == 0) return;

    var lo: [10]usize = undefined;
    var hi: [10]usize = undefined;
    for (0..nbuckets) |b| {
        lo[b] = (b * total + nbuckets / 2) / nbuckets;
        hi[b] = ((b + 1) * total + nbuckets / 2) / nbuckets;
    }

    var counts: [10][4]usize = undefined;
    for (0..nbuckets) |b| {
        for (0..4) |k| {
            counts[b][k] = 0;
        }
    }

    var i: usize = 0;
    var b: usize = 0;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if (output.len > 0 and line.len == 0 and line.ptr == output.ptr + output.len) break;
        while (b + 1 < nbuckets and i >= hi[b]) b += 1;
        for (prefixes, 0..) |p, k| {
            if (std.mem.startsWith(u8, line, p)) counts[b][k] += 1;
        }
        i += 1;
    }
    try expect(i == total); // every line attributed to a bucket

    for (0..nbuckets) |bucket| {
        const bucket_len: f64 = @as(f64, @floatFromInt(hi[bucket] - lo[bucket]));
        for (prefixes, 0..) |_, k| {
            const expected: f64 = bucket_len * @as(f64, @floatFromInt(files.items[k].total_lines)) / @as(f64, @floatFromInt(total));
            const actual: f64 = @as(f64, @floatFromInt(counts[bucket][k]));
            try expect(@abs(actual - expected) <= tolerance);
        }
    }
}

// ---------------------------------------------------------------------------
// SourceFile: line reading / counting
// ---------------------------------------------------------------------------

test "line reading: plain lines with trailing newline" {
    const allocator = std.testing.allocator;
    const path = try makeTempFile(allocator, "plain", "a\nb\n");
    defer cleanupTempFile(allocator, path);
    var sf = try SourceFile.init(std.testing.io, path);
    defer sf.handle.close(std.testing.io);

    try expect(sf.total_lines == 2);
    try expectLines(&sf, &[_][]const u8{ "a", "b" });
}

test "line reading: empty line in the middle is preserved" {
    // Regression: readNextLine used to `continue` (i.e. drop) the line whenever
    // streamDelimiter returned 0, which is exactly the empty-line case.
    const allocator = std.testing.allocator;
    const path = try makeTempFile(allocator, "empty_mid", "a\n\nb\n");
    defer cleanupTempFile(allocator, path);
    var sf = try SourceFile.init(std.testing.io, path);
    defer sf.handle.close(std.testing.io);

    try expect(sf.total_lines == 3);
    try expectLines(&sf, &[_][]const u8{ "a", "", "b" });
}

test "line reading: file consisting only of empty lines" {
    const allocator = std.testing.allocator;
    const path = try makeTempFile(allocator, "all_empty", "\n\n\n");
    defer cleanupTempFile(allocator, path);
    var sf = try SourceFile.init(std.testing.io, path);
    defer sf.handle.close(std.testing.io);

    try expect(sf.total_lines == 3);
    try expectLines(&sf, &[_][]const u8{ "", "", "" });
}

test "line reading: trailing empty line is preserved" {
    const allocator = std.testing.allocator;
    const path = try makeTempFile(allocator, "trailing_empty", "a\n\n");
    defer cleanupTempFile(allocator, path);
    var sf = try SourceFile.init(std.testing.io, path);
    defer sf.handle.close(std.testing.io);

    try expect(sf.total_lines == 2);
    try expectLines(&sf, &[_][]const u8{ "a", "" });
}

test "line reading: final line without trailing newline" {
    const allocator = std.testing.allocator;
    const path = try makeTempFile(allocator, "no_final_nl", "a\nb");
    defer cleanupTempFile(allocator, path);
    var sf = try SourceFile.init(std.testing.io, path);
    defer sf.handle.close(std.testing.io);

    try expect(sf.total_lines == 2);
    try expectLines(&sf, &[_][]const u8{ "a", "b" });
}

test "line reading: single line without newline" {
    const allocator = std.testing.allocator;
    const path = try makeTempFile(allocator, "single", "a");
    defer cleanupTempFile(allocator, path);
    var sf = try SourceFile.init(std.testing.io, path);
    defer sf.handle.close(std.testing.io);

    try expect(sf.total_lines == 1);
    try expectLines(&sf, &[_][]const u8{ "a" });
}

test "line reading: CRLF line endings are stripped" {
    const allocator = std.testing.allocator;
    const path = try makeTempFile(allocator, "crlf", "x\r\ny\r\n");
    defer cleanupTempFile(allocator, path);
    var sf = try SourceFile.init(std.testing.io, path);
    defer sf.handle.close(std.testing.io);

    try expect(sf.total_lines == 2);
    try expectLines(&sf, &[_][]const u8{ "x", "y" });
}

test "line reading: empty file has no lines" {
    const allocator = std.testing.allocator;
    const path = try makeTempFile(allocator, "empty", "");
    defer cleanupTempFile(allocator, path);
    var sf = try SourceFile.init(std.testing.io, path);
    defer sf.handle.close(std.testing.io);

    try expect(sf.total_lines == 0);
    try expectLines(&sf, &[_][]const u8{});
}

test "SourceFile.init: missing file returns FileNotFound" {
    try std.testing.expectError(error.FileNotFound, SourceFile.init(std.testing.io, "merger_no_such_file_zz.txt"));
}

// ---------------------------------------------------------------------------
// mergeFiles: content preservation
// ---------------------------------------------------------------------------

test "merge: single file is identity" {
    const allocator = std.testing.allocator;
    const path = try makeTempFile(allocator, "ident", "x\ny\nz\n");
    defer cleanupTempFile(allocator, path);
    var files = std.ArrayList(SourceFile).empty;
    defer {
        for (files.items) |f| {
            f.handle.close(std.testing.io);
        }
        files.deinit(allocator);
    }
    try files.append(allocator, try SourceFile.init(std.testing.io, path));

    var buf: [16384]u8 = undefined;
    const output = try mergeToBuffer(allocator, &files, &buf);
    try expect(std.mem.eql(u8, output, "x\ny\nz\n"));
}

test "merge: single file with empty lines is identity" {
    // Regression: empty lines were silently dropped from merge output.
    const allocator = std.testing.allocator;
    const path = try makeTempFile(allocator, "ident_empty", "x\n\ny\n");
    defer cleanupTempFile(allocator, path);
    var files = std.ArrayList(SourceFile).empty;
    defer {
        for (files.items) |f| {
            f.handle.close(std.testing.io);
        }
        files.deinit(allocator);
    }
    try files.append(allocator, try SourceFile.init(std.testing.io, path));

    var buf: [16384]u8 = undefined;
    const output = try mergeToBuffer(allocator, &files, &buf);
    try expect(std.mem.eql(u8, output, "x\n\ny\n"));
}

test "merge: two files keep all lines and per-file order" {
    const allocator = std.testing.allocator;
    const path_a = try makeTempFile(allocator, "two_a", "A1\n\nA2\n");
    defer cleanupTempFile(allocator, path_a);
    const path_b = try makeTempFile(allocator, "two_b", "B1\nB2\n");
    defer cleanupTempFile(allocator, path_b);
    var files = std.ArrayList(SourceFile).empty;
    defer {
        for (files.items) |f| {
            f.handle.close(std.testing.io);
        }
        files.deinit(allocator);
    }
    try files.append(allocator, try SourceFile.init(std.testing.io, path_a));
    try files.append(allocator, try SourceFile.init(std.testing.io, path_b));

    var buf: [16384]u8 = undefined;
    const output = try mergeToBuffer(allocator, &files, &buf);

    try expect(countLines(output) == 5);
    try expectSubsequence(output, &[_][]const u8{ "A1", "", "A2" });
    try expectSubsequence(output, &[_][]const u8{ "B1", "B2" });
}

test "merge: empty file contributes nothing" {
    const allocator = std.testing.allocator;
    const path_a = try makeTempFile(allocator, "emptyfile_a", "");
    defer cleanupTempFile(allocator, path_a);
    const path_b = try makeTempFile(allocator, "normal_b", "b1\nb2\n");
    defer cleanupTempFile(allocator, path_b);
    var files = std.ArrayList(SourceFile).empty;
    defer {
        for (files.items) |f| {
            f.handle.close(std.testing.io);
        }
        files.deinit(allocator);
    }
    try files.append(allocator, try SourceFile.init(std.testing.io, path_a));
    try files.append(allocator, try SourceFile.init(std.testing.io, path_b));

    var buf: [16384]u8 = undefined;
    const output = try mergeToBuffer(allocator, &files, &buf);
    try expect(std.mem.eql(u8, output, "b1\nb2\n"));
}

test "merge: file without trailing newline" {
    const allocator = std.testing.allocator;
    const path_a = try makeTempFile(allocator, "no_nl_a", "a");
    defer cleanupTempFile(allocator, path_a);
    const path_b = try makeTempFile(allocator, "nl_b", "b\n");
    defer cleanupTempFile(allocator, path_b);
    var files = std.ArrayList(SourceFile).empty;
    defer {
        for (files.items) |f| {
            f.handle.close(std.testing.io);
        }
        files.deinit(allocator);
    }
    try files.append(allocator, try SourceFile.init(std.testing.io, path_a));
    try files.append(allocator, try SourceFile.init(std.testing.io, path_b));

    var buf: [16384]u8 = undefined;
    const output = try mergeToBuffer(allocator, &files, &buf);
    try expect(std.mem.eql(u8, output, "a\nb\n"));
}

test "merge: all files empty produces empty output" {
    const allocator = std.testing.allocator;
    const path_a = try makeTempFile(allocator, "all_empty_a", "");
    defer cleanupTempFile(allocator, path_a);
    const path_b = try makeTempFile(allocator, "all_empty_b", "");
    defer cleanupTempFile(allocator, path_b);
    var files = std.ArrayList(SourceFile).empty;
    defer {
        for (files.items) |f| {
            f.handle.close(std.testing.io);
        }
        files.deinit(allocator);
    }
    try files.append(allocator, try SourceFile.init(std.testing.io, path_a));
    try files.append(allocator, try SourceFile.init(std.testing.io, path_b));

    var buf: [16384]u8 = undefined;
    const output = try mergeToBuffer(allocator, &files, &buf);
    try expect(output.len == 0);
}

test "merge: CRLF inputs produce LF-only output" {
    const allocator = std.testing.allocator;
    const path_a = try makeTempFile(allocator, "crlf_a", "a\r\nb\r\n");
    defer cleanupTempFile(allocator, path_a);
    const path_b = try makeTempFile(allocator, "crlf_b", "c\r\n");
    defer cleanupTempFile(allocator, path_b);
    var files = std.ArrayList(SourceFile).empty;
    defer {
        for (files.items) |f| {
            f.handle.close(std.testing.io);
        }
        files.deinit(allocator);
    }
    try files.append(allocator, try SourceFile.init(std.testing.io, path_a));
    try files.append(allocator, try SourceFile.init(std.testing.io, path_b));

    var buf: [16384]u8 = undefined;
    const output = try mergeToBuffer(allocator, &files, &buf);

    try expect(countLines(output) == 3);
    try expectSubsequence(output, &[_][]const u8{ "a", "b" });
    try expectSubsequence(output, &[_][]const u8{ "c" });
    try expect(std.mem.indexOfScalar(u8, output, '\r') == null);
}

test "merge: line longer than the initial 4096-byte line buffer is preserved" {
    // The line buffer grows past its initial 4096-byte size as needed.
    const allocator = std.testing.allocator;
    var a_content: [5001]u8 = undefined;
    for (a_content[0..5000]) |*c| {
        c.* = 'x';
    }
    a_content[5000] = '\n';
    const path_a = try makeTempFile(allocator, "long_a", &a_content);
    defer cleanupTempFile(allocator, path_a);
    const path_b = try makeTempFile(allocator, "long_b", "y\n");
    defer cleanupTempFile(allocator, path_b);
    var files = std.ArrayList(SourceFile).empty;
    defer {
        for (files.items) |f| {
            f.handle.close(std.testing.io);
        }
        files.deinit(allocator);
    }
    try files.append(allocator, try SourceFile.init(std.testing.io, path_a));
    try files.append(allocator, try SourceFile.init(std.testing.io, path_b));

    var buf: [16384]u8 = undefined;
    const output = try mergeToBuffer(allocator, &files, &buf);

    try expect(countLines(output) == 2);
    var x_count: u32 = 0;
    for (output) |c| {
        if (c == 'x') x_count += 1;
    }
    try expect(x_count == 5000);
    try expect(std.mem.indexOf(u8, output, "y") != null);
}

// ---------------------------------------------------------------------------
// mergeFiles: proportional distribution
// ---------------------------------------------------------------------------

test "merge: README example — 90-line and 10-line files interleave proportionally" {
    const allocator = std.testing.allocator;

    var a_content: [32]u8 = undefined;
    var pos: usize = 0;
    for (0..10) |i| {
        const line = std.fmt.bufPrint(a_content[pos..], "A{d}\n", .{ i }) catch unreachable;
        pos += line.len;
    }
    const path_a = try makeTempFile(allocator, "ratio_a", a_content[0..pos]);
    defer cleanupTempFile(allocator, path_a);

    var b_content: [368]u8 = undefined;
    pos = 0;
    for (0..90) |i| {
        const line = std.fmt.bufPrint(b_content[pos..], "B{d}\n", .{ i }) catch unreachable;
        pos += line.len;
    }
    const path_b = try makeTempFile(allocator, "ratio_b", b_content[0..pos]);
    defer cleanupTempFile(allocator, path_b);

    var files = std.ArrayList(SourceFile).empty;
    defer {
        for (files.items) |f| {
            f.handle.close(std.testing.io);
        }
        files.deinit(allocator);
    }
    try files.append(allocator, try SourceFile.init(std.testing.io, path_a));
    try files.append(allocator, try SourceFile.init(std.testing.io, path_b));

    var buf: [16384]u8 = undefined;
    const output = try mergeToBuffer(allocator, &files, &buf);

    try expect(countLines(output) == 100);
    try expectOrderedNumericLines(output, 'A', 10);
    try expectOrderedNumericLines(output, 'B', 90);
    try expectBucketsProportional(output, &[_][]const u8{ "A", "B" }, &files, 10, 2.0);
}

test "merge: proportional distribution across three files (3/5/10)" {
    const allocator = std.testing.allocator;
    const path_a = try makeTempFile(allocator, "prop_a", "A0\nA1\nA2\n");
    defer cleanupTempFile(allocator, path_a);
    const path_b = try makeTempFile(allocator, "prop_b", "B0\nB1\nB2\nB3\nB4\n");
    defer cleanupTempFile(allocator, path_b);
    const path_c = try makeTempFile(allocator, "prop_c", "C0\nC1\nC2\nC3\nC4\nC5\nC6\nC7\nC8\nC9\n");
    defer cleanupTempFile(allocator, path_c);
    var files = std.ArrayList(SourceFile).empty;
    defer {
        for (files.items) |f| {
            f.handle.close(std.testing.io);
        }
        files.deinit(allocator);
    }
    try files.append(allocator, try SourceFile.init(std.testing.io, path_a));
    try files.append(allocator, try SourceFile.init(std.testing.io, path_b));
    try files.append(allocator, try SourceFile.init(std.testing.io, path_c));

    var buf: [16384]u8 = undefined;
    const output = try mergeToBuffer(allocator, &files, &buf);

    try expect(countLines(output) == 18);
    try expectOrderedNumericLines(output, 'A', 3);
    try expectOrderedNumericLines(output, 'B', 5);
    try expectOrderedNumericLines(output, 'C', 10);
    try expectBucketsProportional(output, &[_][]const u8{ "A", "B", "C" }, &files, 10, 2.0);
}

test "merge: extreme size ratio (1 line vs 1000 lines)" {
    const allocator = std.testing.allocator;
    const path_a = try makeTempFile(allocator, "extreme_a", "A0\n");
    defer cleanupTempFile(allocator, path_a);

    var b_content: [5000]u8 = undefined;
    var pos: usize = 0;
    for (0..1000) |i| {
        const line = std.fmt.bufPrint(b_content[pos..], "B{d}\n", .{ i }) catch unreachable;
        pos += line.len;
    }
    try expect(pos <= b_content.len);
    const path_b = try makeTempFile(allocator, "extreme_b", b_content[0..pos]);
    defer cleanupTempFile(allocator, path_b);

    var files = std.ArrayList(SourceFile).empty;
    defer {
        for (files.items) |f| {
            f.handle.close(std.testing.io);
        }
        files.deinit(allocator);
    }
    try files.append(allocator, try SourceFile.init(std.testing.io, path_a));
    try files.append(allocator, try SourceFile.init(std.testing.io, path_b));

    var buf: [16384]u8 = undefined;
    const output = try mergeToBuffer(allocator, &files, &buf);

    try expect(countLines(output) == 1001);
    try expectOrderedNumericLines(output, 'A', 1);
    try expectOrderedNumericLines(output, 'B', 1000);
    try expectBucketsProportional(output, &[_][]const u8{ "A", "B" }, &files, 10, 2.0);
}

pub const std_options = std.Options{
    // .log_level = .debug,
    .log_level = .info,
};

const std = @import("std");

pub const SourceFile = struct {
    name: []const u8,
    total_lines: u32 = 0,
    current_line: u32 = 1,
    handle: std.fs.File,

    fn init(path: []const u8) !SourceFile {
        std.log.debug("Attempting to open file {s}", .{path});

        var handle = try std.fs.cwd().openFile(path, .{});
        errdefer {
            handle.close();
        }

        // find the file's total_lines
        var buffer: [4096]u8 = undefined;
        var line_count: u32 = 0;
        while (try getNextLineReader(handle.reader(), &buffer)) |line| {
            _ = line; // ignore the line, we don't need it this time
            line_count += 1;
        }
        try handle.seekTo(0); // rewind the file so we are ready to actually process it.

        return .{ .name = path, .handle = handle, .current_line = 1, .total_lines = line_count };
    }

    fn getNextLineReader(reader: anytype, buffer: []u8) !?[]const u8 {
        const line = (try reader.readUntilDelimiterOrEof(
            buffer,
            '\n',
        )) orelse return null;
        return std.mem.trimRight(u8, line, "\r"); // strip trailing carriage returns in case it was a windows generated file
    }

    fn getNextLine(self: SourceFile, buffer: []u8) !?[]const u8 {
        return getNextLineReader(self.handle.reader(), buffer);
    }
};

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const allocator = std.heap.page_allocator;

    // Parse args into string array (error union needs 'try')
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    std.log.debug("argv.len = {d}", .{args.len});
    if (args.len < 3) {
        std.debug.print("Usage: {s} <file1> <file2> ...\n", .{args[0]});
        return;
    }

    var source_files = std.ArrayList(SourceFile).init(allocator);

    defer {
        for (source_files.items) |file| {
            file.handle.close();
        }
        source_files.deinit();
    }

    const files = args[1..args.len];

    for (files) |file_path| {
        if (SourceFile.init(file_path)) |file| {
            try source_files.append(file);
        } else |err| {
            std.debug.print("Failed to prep file {s} - {s}\n", .{ file_path, @errorName(err) });
            std.debug.print("Usage:\n\t{s} <file1> <file2> ...\n", .{args[0]});
            return err;
        }
    }
    var total_lines: u32 = 0;
    for (source_files.items) |file| {
        total_lines += file.total_lines;
        std.log.debug("file {s} has a total_lines of {d}", .{ file.name, file.total_lines });
    }
    // for each line 0 to total_line_count
    // we need to pick a file to read from. Each file should contribute weighted based on total_lines
    // so, in total, file a should contribute a line every total_line_count / line_count lines.

    var i: u32 = 0;
    while (i < total_lines) : (i += 1) {
        var weight: f64 = 1.1;

        var candidate: ?*SourceFile = null;

        for (source_files.items) |*file| {
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
            var buffer: [4096]u8 = undefined;
            if (try f.getNextLine(&buffer)) |line| {
                try stdout.print("{s}\n", .{line});
                f.current_line += 1;
            }
        } else {
            std.log.err("Failed to find candidate for line {d} out of total lines {d}", .{ i + 1, total_lines });
        }
    }
}

const expect = std.testing.expect;
test "Successful file opening and line counting" {
    // Test case 1: Successful file opening and line counting

    // const temp_file_path = try std.fs.cwd().openFile("temp_file.txt", .{});
    const temp_file_path = "temp_file.txt";
    var handle = try std.fs.cwd().createFile(temp_file_path, .{});
    defer std.fs.cwd().deleteFile(temp_file_path) catch {};
    defer handle.close();
    try handle.writeAll("Line 1\nLine 2\nLine 3");

    // Initialize SourceFile with the temporary file path

    const source_file = try SourceFile.init(temp_file_path);

    // Assertions
    try expect(std.mem.eql(u8, source_file.name, temp_file_path)); // Verify filename
    try expect(source_file.total_lines == 3); // Verify line count
}

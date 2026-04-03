pub const std_options = std.Options{
    .log_level = .info,
};

const std = @import("std");

pub const SourceFile = struct {
    name: []const u8,
    total_lines: u32 = 0,
    current_line: u32 = 1,
    handle: std.fs.File,
    reader_buffer: [4096]u8 = undefined,
    file_reader: ?std.fs.File.Reader = null,

    fn init(path: []const u8) !SourceFile {
        std.log.debug("Attempting to open file {s}", .{path});

        var handle = try std.fs.cwd().openFile(path, .{});
        errdefer {
            handle.close();
        }

        // find the file's total_lines
        var line_count: u32 = 0;
        var self = SourceFile{
            .name = path,
            .handle = handle,
            .current_line = 1,
            .total_lines = 0,
            .reader_buffer = undefined,
            .file_reader = null,
        };
        
        // Initialize the reader for counting
        self.file_reader = self.handle.reader(&self.reader_buffer);
        
        // Count lines using modern API
        while (try self.readNextLine()) |line| {
            _ = line;
            line_count += 1;
        }
        
        try handle.seekTo(0); // rewind the file so we are ready to actually process it.
        self.total_lines = line_count;
        // Reset reader after seek
        self.file_reader = self.handle.reader(&self.reader_buffer);

        return self;
    }

    fn readNextLine(self: *SourceFile) !?[]const u8 {
        while (true) {
            var file_reader = self.file_reader orelse return error.ReaderNotInitialized;
            
            // Create a fixed buffer to collect the line
            var line_buffer: [4096]u8 = undefined;
            var line_writer = std.Io.Writer.fixed(&line_buffer);
            
            // Stream until newline delimiter
            const bytes_read = file_reader.interface.streamDelimiter(&line_writer, '\n') catch |err| {
                // Update the stored reader since we modified it
                self.file_reader = file_reader;
                if (err == error.EndOfStream) {
                    // Check if we got any data before EOF
                    const written = line_writer.buffered().len;
                    if (written == 0) {
                        return null;
                    }
                    // Return what we have (last line without trailing newline)
                    const line = line_writer.buffered();
                    return std.mem.trimRight(u8, line, "\r");
                }
                return err;
            };
            
            // Update the stored reader since we modified it
            self.file_reader = file_reader;
            
            // streamDelimiter returns 0 when the delimiter is at position 0.
            // We need to consume the delimiter manually in that case.
            if (bytes_read == 0) {
                // Check if the next byte in the buffer is the delimiter
                if (file_reader.interface.bufferedLen() > 0 and 
                    file_reader.interface.buffered()[0] == '\n') {
                    // Consume the delimiter
                    file_reader.interface.toss(1);
                    self.file_reader = file_reader;
                    
                    // If we have an empty line (consecutive newlines), continue to read next line
                    if (line_writer.buffered().len == 0) {
                        continue;
                    }
                } else {
                    // No delimiter found and no data - we're at EOF
                    if (line_writer.buffered().len == 0) {
                        return null;
                    }
                }
            }
            
            // Get the line and trim trailing carriage returns
            const line = line_writer.buffered();
            return std.mem.trimRight(u8, line, "\r");
        }
    }
};

pub fn mergeFiles(source_files: *std.array_list.Managed(SourceFile), writer: anytype) !void {
    var total_lines: u32 = 0;
    for (source_files.items) |file| {
        total_lines += file.total_lines;
        std.log.debug("file {s} has a total_lines of {d}", .{ file.name, file.total_lines });
    }
    
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
            if (try f.readNextLine()) |line| {
                try writer.print("{s}\n", .{line});
                f.current_line += 1;
            }
        } else {
            std.log.err("Failed to find candidate for line {d} out of total lines {d}", .{ i + 1, total_lines });
            return error.NoCandidateFound;
        }
    }
}

pub fn main() !void {
    const stdout_file = std.fs.File.stdout();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    const allocator = std.heap.page_allocator;

    // Parse args into string array (error union needs 'try')
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    std.log.debug("argv.len = {d}", .{args.len});
    if (args.len < 3) {
        std.debug.print("Usage: {s} <file1> <file2> ...\n", .{args[0]});
        return;
    }

    var source_files = std.array_list.Managed(SourceFile).init(allocator);

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
    
    try mergeFiles(&source_files, stdout);
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
    defer source_file.handle.close();

    // Assertions
    try expect(std.mem.eql(u8, source_file.name, temp_file_path)); // Verify filename
    try expect(source_file.total_lines == 3); // Verify line count
}

test "proportional merge with actual mergeFiles function" {
    // This test uses the actual mergeFiles function to demonstrate the algorithm
    // With file A (10 lines) and file B (90 lines), we expect:
    // - 10% of output should come from file A (10 lines)  
    // - 90% of output should come from file B (90 lines)

    const allocator = std.testing.allocator;

    // Create temp file A with 10 lines (smaller file)
    const file_a_path = "test_file_a.txt";
    var handle_a = try std.fs.cwd().createFile(file_a_path, .{});
    defer std.fs.cwd().deleteFile(file_a_path) catch {};
    defer handle_a.close();
    
    // Use modern writer API
    var writer_buffer_a: [4096]u8 = undefined;
    var file_writer_a = handle_a.writer(&writer_buffer_a);
    for (0..10) |i| {
        try file_writer_a.interface.print("A{d}\n", .{i});
    }
    // Flush the writer to ensure data is written to the file
    try file_writer_a.interface.flush();

    // Create temp file B with 90 lines (larger file)
    const file_b_path = "test_file_b.txt";
    var handle_b = try std.fs.cwd().createFile(file_b_path, .{});
    defer std.fs.cwd().deleteFile(file_b_path) catch {};
    defer handle_b.close();
    
    // Use modern writer API
    var writer_buffer_b: [4096]u8 = undefined;
    var file_writer_b = handle_b.writer(&writer_buffer_b);
    for (0..90) |i| {
        try file_writer_b.interface.print("B{d}\n", .{i});
    }
    // Flush the writer to ensure data is written to the file
    try file_writer_b.interface.flush();

    // Initialize source files
    var source_files = std.array_list.Managed(SourceFile).init(allocator);
    defer {
        for (source_files.items) |file| {
            file.handle.close();
        }
        source_files.deinit();
    }

    try source_files.append(try SourceFile.init(file_a_path));
    try source_files.append(try SourceFile.init(file_b_path));

    // Create a buffer to capture output using modern API
    var output_buffer: [8192]u8 = undefined;
    var output_writer = std.Io.Writer.fixed(&output_buffer);
    
    // Call the actual mergeFiles function
    try mergeFiles(&source_files, &output_writer);

    // Count lines from each file in the output
    const output = output_writer.buffered();
    var output_from_a: u32 = 0;
    var output_from_b: u32 = 0;
    var total_output_lines: u32 = 0;

    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue; // Skip empty lines
        total_output_lines += 1;
        if (line[0] == 'A') {
            output_from_a += 1;
        } else if (line[0] == 'B') {
            output_from_b += 1;
        }
    }

    // Calculate expected vs actual ratios
    const expected_ratio_a = 0.1; // 10/100
    const actual_ratio_a = @as(f64, @floatFromInt(output_from_a)) / @as(f64, @floatFromInt(total_output_lines));
    const tolerance = 0.05; // 5% tolerance

    std.debug.print("\n=== mergeFiles Function Test ===\n", .{});
    std.debug.print("File sizes: A=10 lines, B=90 lines (Total=100)\n", .{});
    std.debug.print("Expected: A should be ~10% ({d} lines), B should be ~90% ({d} lines)\n", .{ @as(u32, @intFromFloat(expected_ratio_a * @as(f64, @floatFromInt(total_output_lines)))), @as(u32, @intFromFloat((1.0 - expected_ratio_a) * @as(f64, @floatFromInt(total_output_lines)))) });
    std.debug.print("Actual:   A contributed {d} lines ({d:.2}%), B contributed {d} lines ({d:.2}%)\n", .{ output_from_a, actual_ratio_a * 100, output_from_b, (1.0 - actual_ratio_a) * 100 });
    
    // Verify we got all lines
    try expect(total_output_lines == 100);
    try expect(output_from_a + output_from_b == total_output_lines);
    
    // Verify proportional distribution
    try expect(@abs(actual_ratio_a - expected_ratio_a) < tolerance);
}

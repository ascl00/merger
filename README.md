# Merger

Simple tool to merge multiple (2+) files in a proportional weighted way. Files of vastly different lengths will be merged so that the contents are distributed evenly throughout the output while retaining the original order within each file.

For example, merging a 90-line file with a 10-line file will result in approximately 90% of the output coming from the larger file and 10% from the smaller file.

## How It Works

The tool uses a weighted round-robin algorithm that selects lines from files based on their progress ratio (`current_line / total_lines`). Files with lower progress ratios are prioritized, ensuring proportional representation based on file sizes.

## Requirements

- Zig 0.15 or later

## Building

```bash
zig build
```

## Usage

```bash
./zig-out/bin/merger file1.txt file2.txt [file3.txt ...] > output.txt
```

### Examples

Merge two files:
```bash
./zig-out/bin/merger small.txt large.txt > merged.txt
```

Merge multiple files:
```bash
./zig-out/bin/merger file1.txt file2.txt file3.txt file4.txt > combined.txt
```

## Testing

Run the test suite:

```bash
zig build test
```

The test suite includes:
- Unit tests for file operations and line counting
- Integration tests verifying proportional merge algorithm correctness

## Algorithm Details

The merging algorithm works as follows:
1. For each file, calculate the progress ratio: `current_line / total_lines`
2. Select the file with the lowest progress ratio
3. Read and output the next line from that file
4. Increment the file's current line counter
5. Repeat until all files are exhausted

This ensures that each file contributes lines proportional to its size in the final output.

## Project Structure

- `src/main.zig` - Main application code with `mergeFiles()` function
- `build.zig` - Zig build configuration
- `build.zig.zon` - Package manifest

## License

See repository for license information.

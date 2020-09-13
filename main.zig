const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;

const snappy = @import("snappy.zig");

fn readFile(allocator: *Allocator, path: []const u8) ![]u8 {
    var f = try fs.cwd().openFile(path, fs.File.OpenFlags{ .read = true });
    const fMetadata = try f.stat();

    var output = try allocator.alloc(u8, fMetadata.size);
    errdefer allocator.free(output);

    _ = try f.readAll(output);

    return output;
}

// A small sample application demonstrating how to decode a snappy block-formatted input.
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().outStream();

    const input = try readFile(allocator, "input");
    defer allocator.free(input);

    const decoded = try snappy.decode(allocator, input);
    defer allocator.free(decoded);

    try stdout.print("{}", .{decoded});
}

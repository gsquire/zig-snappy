const std = @import("std");

const snappy = @import("snappy.zig");

// A small sample application demonstrating how to decode a snappy block-formatted input.
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const decoded = try snappy.decode(allocator, "\x19\x1coh snap,\x05\x06,py is cool!\x0a");
    defer allocator.free(decoded);

    std.debug.warn("{}", .{decoded});
}

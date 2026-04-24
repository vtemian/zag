const std = @import("std");

comptime {
    _ = @import("Pty.zig");
    _ = @import("Spawn.zig");
    _ = @import("Grid.zig");
    _ = @import("Dsl.zig");
    _ = @import("Args.zig");
    _ = @import("phase1_e2e_test.zig");
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try stdout.writeAll("zag-sim\n");
    _ = alloc;
    return 0;
}

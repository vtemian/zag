const std = @import("std");

pub const Aborter = struct {
    ctx: *anyopaque,
    abort_fn: *const fn (ctx: *anyopaque) void,

    pub fn call(self: Aborter) void {
        self.abort_fn(self.ctx);
    }
};

pub const Job = struct {
    // Filled in per subsystem (sleep, http, cmd, fs).
    // For now, only the fields Scope interacts with.
    aborter: ?Aborter = null,

    pub fn abort(self: *Job) void {
        if (self.aborter) |a| a.call();
    }
};

test "Job.abort calls aborter" {
    var called: bool = false;
    const Ctx = struct {
        flag: *bool,
        fn fire(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.flag.* = true;
        }
    };
    var ctx = Ctx{ .flag = &called };
    var job = Job{ .aborter = .{ .ctx = @ptrCast(&ctx), .abort_fn = Ctx.fire } };
    job.abort();
    try std.testing.expect(called);
}

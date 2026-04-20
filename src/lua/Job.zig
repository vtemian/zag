const std = @import("std");

pub const Aborter = struct {
    ctx: *anyopaque,
    abort_fn: *const fn (ctx: *anyopaque) void,

    pub fn call(self: Aborter) void {
        self.abort_fn(self.ctx);
    }
};

/// What the worker should do with this job. The scheduler fills this in
/// before submit. Only `.sleep` exists today; cmd/http/fs land in later
/// phases.
pub const JobKind = union(enum) {
    sleep: struct { ms: u64 },
    // other variants added in Phase 6+
};

/// Success payload handed back to the coroutine on resume. `.empty` means
/// "no meaningful value" (sleep returns nothing).
pub const JobResult = union(enum) {
    empty,
    // others added in Phase 6+
};

/// Stable string tag surfaced to Lua on failure. The strings are part of
/// the public plugin API contract, so `toString` is the single source of
/// truth for both Zig callers and the Lua bridge.
pub const ErrTag = enum {
    cancelled,
    timeout,
    connect_failed,
    tls_error,
    http_error,
    invalid_uri,
    spawn_failed,
    killed,
    io_error,
    not_found,
    permission_denied,
    budget_exceeded,

    pub fn toString(self: ErrTag) []const u8 {
        return switch (self) {
            .cancelled => "cancelled",
            .timeout => "timeout",
            .connect_failed => "connect_failed",
            .tls_error => "tls_error",
            .http_error => "http_error",
            .invalid_uri => "invalid_uri",
            .spawn_failed => "spawn_failed",
            .killed => "killed",
            .io_error => "io_error",
            .not_found => "not_found",
            .permission_denied => "permission_denied",
            .budget_exceeded => "budget_exceeded",
        };
    }
};

pub const Job = struct {
    /// What to run. Scheduler fills before submit.
    kind: JobKind,
    /// Lua registry ref for the coroutine awaiting this job. Scheduler
    /// fills before submit; resumeFromJob uses it to locate the thread.
    thread_ref: i32,
    /// Cancellation scope the job lives under. Worker checks this before
    /// executing; cancel fires aborter to interrupt in-flight work.
    scope: *@import("Scope.zig").Scope,
    /// Worker fills on success. Mutually exclusive with err_tag.
    result: ?JobResult = null,
    /// Worker fills on failure. Mutually exclusive with result.
    err_tag: ?ErrTag = null,
    /// Optional human-readable detail string owned by the job allocator.
    /// resumeFromJob frees it after pushing onto the coroutine stack.
    err_detail: ?[]const u8 = null,
    /// Optional cancel hook. Scope.cancel invokes this to interrupt a
    /// blocking syscall (e.g. close an fd, send SIGKILL).
    aborter: ?Aborter = null,

    pub fn abort(self: *Job) void {
        if (self.aborter) |a| a.call();
    }
};

test "Job.abort calls aborter" {
    const Scope = @import("Scope.zig").Scope;
    const root = try Scope.init(std.testing.allocator, null);
    defer root.deinit();

    var called: bool = false;
    const Ctx = struct {
        flag: *bool,
        fn fire(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.flag.* = true;
        }
    };
    var ctx = Ctx{ .flag = &called };
    var job = Job{
        .kind = .{ .sleep = .{ .ms = 0 } },
        .thread_ref = 0,
        .scope = root,
        .aborter = .{ .ctx = @ptrCast(&ctx), .abort_fn = Ctx.fire },
    };
    job.abort();
    try std.testing.expect(called);
}

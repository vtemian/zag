const std = @import("std");

pub const Aborter = struct {
    ctx: *anyopaque,
    abort_fn: *const fn (ctx: *anyopaque) void,

    pub fn call(self: Aborter) void {
        self.abort_fn(self.ctx);
    }
};

/// Policy for building the child process environment.
/// - `inherit`: the child sees the parent's env untouched.
/// - `replace`: use `env_map` verbatim; nothing is inherited.
/// - `extend`: start from the parent env and overlay `env_map` on top.
pub const CmdExecEnvMode = enum { inherit, replace, extend };

/// Argv/env/timeout/output-cap payload for a cmd_exec job. Kept outside
/// the union because it's bigger than the other variants and is easier to
/// read as its own type.
pub const CmdExecSpec = struct {
    /// Argv slice; item 0 is the program. Owned by the caller (Lua binding
    /// sets up an arena that lives until resumeFromJob). Worker does not
    /// free.
    argv: []const []const u8,
    /// Working directory for the child. Borrowed from the caller.
    cwd: ?[]const u8 = null,
    /// How to construct the child's environment.
    env_mode: CmdExecEnvMode = .inherit,
    /// Optional env overrides. Semantics depend on env_mode.
    env_map: ?std.process.EnvMap = null,
    /// Bytes to write to the child's stdin before draining output. Borrowed
    /// from the caller. null means no stdin pipe is opened.
    stdin_bytes: ?[]const u8 = null,
    /// Wall-clock deadline in milliseconds. 0 disables the timeout.
    timeout_ms: u64 = 30_000,
    /// Per-stream cap. 0 = unbounded. Applied to stdout and stderr
    /// independently; hitting either sets CmdExecResult.truncated.
    max_output_bytes: usize = 10 * 1024 * 1024,
};

/// Success payload for a cmd_exec job. stdout/stderr are heap-allocated on
/// the worker's allocator and must be freed by resumeFromJob after being
/// pushed onto the coroutine stack.
pub const CmdExecResult = struct {
    /// Process exit status. Negative values encode termination by signal
    /// (-N == SIGN). -1 means unknown / unexpected term variant.
    code: i32,
    stdout: []const u8,
    stderr: []const u8,
    /// True when either stream hit max_output_bytes before the child was
    /// done writing.
    truncated: bool,
};

/// What the worker should do with this job. The scheduler fills this in
/// before submit.
pub const JobKind = union(enum) {
    sleep: struct { ms: u64 },
    cmd_exec: CmdExecSpec,
    // http/fs land in later phases
};

/// Success payload handed back to the coroutine on resume. `.empty` means
/// "no meaningful value" (sleep returns nothing).
pub const JobResult = union(enum) {
    empty,
    cmd_exec: CmdExecResult,
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

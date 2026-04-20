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

/// Completion payload for a long-lived `CmdHandle:wait()`. The helper
/// thread that owns the Child has already reaped it and captured the
/// exit status; the main thread only needs the code to push onto the
/// waiting coroutine.
pub const CmdWaitDoneSpec = struct {
    /// Exit status: 0+ for normal exit, negative (-N) for termination by
    /// signal N. -1 when the Term was unknown/stopped.
    code: i32,
};

/// Completion payload for a `CmdHandle:write()` call. The helper
/// thread has attempted the write and (on success) drained the
/// buffer. Short writes from `File.writeAll` aren't possible — the
/// function loops internally — so `bytes_written` equals the
/// requested length on success. On failure the Job carries an
/// `err_tag` of `.io_error` instead of a result.
pub const CmdWriteDoneSpec = struct {
    /// Number of bytes successfully written. Equal to the requested
    /// slice length on success; 0 on failure (check `err_tag`).
    bytes_written: usize,
};

/// Completion payload for a `CmdHandle:close_stdin()` call. No data
/// flows back to the coroutine — the completion just signals the
/// helper is done closing the pipe so Lua can resume.
pub const CmdCloseStdinDoneSpec = struct {};

/// A single HTTP request/response header. Ownership depends on the
/// direction: request headers (in `HttpGetSpec.headers`) are borrowed
/// from the Lua binding's arena; response headers (in `HttpResult`) are
/// heap-allocated on the engine allocator and freed by
/// `pushJobResultOntoStack` after being copied into Lua.
pub const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
};

/// Argv/headers/timeout payload for an `http_get` job. The worker never
/// mutates these fields; they're pinned by the caller's arena until
/// `resumeFromJob` fires.
pub const HttpGetSpec = struct {
    /// Fully-qualified URL (http:// or https://). Borrowed from the
    /// caller's arena.
    url: []const u8,
    /// Extra request headers. Slice + each header's name/value are
    /// borrowed from the caller's arena.
    headers: []const HttpHeader = &.{},
    /// Reserved for Task 7.5; NOT enforced in v1. The worker has only a
    /// pre-request cancel checkpoint today — once std.http.Client.fetch
    /// is called, the request runs to whatever transport-level timeout
    /// std.http uses internally. Plumbed through so the Lua binding can
    /// accept the opt without errors.
    timeout_ms: u64 = 30_000,
    /// Follow 3xx redirects. When true, std.http.Client handles up to
    /// three hops transparently.
    follow_redirects: bool = true,
};

/// Argv/headers/body/timeout payload for an `http_post` job. Same
/// shape as `HttpGetSpec` plus a request body and its content-type.
/// The worker never mutates these fields; they're pinned by the
/// caller's arena until `resumeFromJob` fires.
pub const HttpPostSpec = struct {
    /// Fully-qualified URL (http:// or https://). Borrowed from the
    /// caller's arena.
    url: []const u8,
    /// Extra request headers. Slice + each header's name/value are
    /// borrowed from the caller's arena. The worker appends a
    /// `Content-Type` header derived from `content_type` only if the
    /// caller did not already set one here.
    headers: []const HttpHeader = &.{},
    /// Raw request body bytes. Borrowed from the caller's arena.
    /// Empty slice is valid and means "POST with no body".
    body: []const u8 = &.{},
    /// MIME type for `body`. Empty string means "don't inject a
    /// Content-Type header — let caller-provided headers speak for
    /// themselves (or let the server infer nothing)". Borrowed.
    content_type: []const u8 = "",
    /// Reserved for Task 7.5; see HttpGetSpec.timeout_ms.
    timeout_ms: u64 = 30_000,
    /// Follow 3xx redirects. When true, std.http.Client handles up to
    /// three hops transparently.
    follow_redirects: bool = true,
};

/// Success payload for an `http_get` job. `body` and the backing slice
/// of `headers` (plus each header's name/value) are heap-allocated on
/// the engine allocator and must be freed by `pushJobResultOntoStack`
/// after being copied into Lua.
pub const HttpResult = struct {
    /// HTTP status code (e.g. 200, 404).
    status: u16,
    /// Response headers, lowercase-keyed. In v1 this is always empty —
    /// Zig 0.15 `std.http.Client.fetch` does not expose response
    /// headers in a convenient form. Task 7.2's Lua binding pushes an
    /// empty table for now.
    headers: []const HttpHeader,
    /// Response body bytes.
    body: []const u8,
};

/// Completion payload for one `CmdHandle:lines()` iteration. The
/// CmdHandle helper thread either pulled a newline-terminated segment
/// out of the child's stdout or observed EOF. `pushJobResultOntoStack`
/// is responsible for freeing `line` (if non-null) after `pushString`
/// has copied the bytes into Lua.
pub const CmdReadLineDoneSpec = struct {
    /// Next line from stdout (without the trailing '\n'). Heap-
    /// allocated on the engine allocator; ownership transfers to
    /// `pushJobResultOntoStack`. `null` means EOF — the iterator
    /// Lua-side returns nil and the `for` loop ends.
    line: ?[]const u8,
};

/// Completion payload for one `HttpStreamHandle:lines()` iteration.
/// The helper thread either pulled a newline-terminated segment out
/// of the response body or observed EOF. Same ownership rules as
/// `CmdReadLineDoneSpec`: `pushJobResultOntoStack` frees `line` after
/// copying into Lua.
pub const HttpStreamLineDoneSpec = struct {
    /// Next line from the response body (without the trailing '\n';
    /// a trailing '\r' is also stripped so SSE "\r\n" framing arrives
    /// clean). Heap-allocated on the engine allocator. `null` means
    /// end-of-stream — the iterator returns nil and the `for` loop
    /// ends.
    line: ?[]const u8,
};

/// What the worker should do with this job. The scheduler fills this in
/// before submit.
pub const JobKind = union(enum) {
    sleep: struct { ms: u64 },
    cmd_exec: CmdExecSpec,
    /// Posted by a CmdHandle helper thread, not submitted to the pool.
    /// Tells the main thread to resume the coroutine waiting in
    /// `CmdHandle:wait()` with the captured exit code.
    cmd_wait_done: CmdWaitDoneSpec,
    /// Posted by a CmdHandle helper thread for each `:lines()`
    /// iteration. Resumes the coroutine with the next line or nil at
    /// EOF. Not submitted to the pool.
    cmd_read_line_done: CmdReadLineDoneSpec,
    /// Posted by a CmdHandle helper thread after a `:write()` call
    /// completes. Resumes the coroutine with `(true, nil)` on success
    /// or `(nil, "io_error: ...")` on failure. Not pool-submitted.
    cmd_write_done: CmdWriteDoneSpec,
    /// Posted by a CmdHandle helper thread after `:close_stdin()`.
    /// Resumes the coroutine with `(true, nil)`. Not pool-submitted.
    cmd_close_stdin_done: CmdCloseStdinDoneSpec,
    /// One-shot HTTP GET. Worker lives in `primitives/http.zig`.
    http_get: HttpGetSpec,
    /// One-shot HTTP POST. Worker lives in `primitives/http.zig`.
    /// Shares `JobResult.http` with `http_get` — status/body shape is
    /// identical, only the request side differs.
    http_post: HttpPostSpec,
    /// Posted by an HttpStreamHandle helper thread for each `:lines()`
    /// iteration. Resumes the coroutine with the next line or nil at
    /// EOF. Not pool-submitted — the helper thread synthesises these
    /// directly onto the completion queue.
    http_stream_line_done: HttpStreamLineDoneSpec,
    // fs lands in a later phase
};

/// Success payload handed back to the coroutine on resume. `.empty` means
/// "no meaningful value" (sleep returns nothing).
pub const JobResult = union(enum) {
    empty,
    cmd_exec: CmdExecResult,
    http: HttpResult,
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

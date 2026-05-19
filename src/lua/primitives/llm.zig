//! LLM completion primitive for `zag.llm.complete`. Synchronously
//! invokes the engine's currently-attached `llm.Provider` on a
//! `LuaIoPool` worker thread, assembles the response text from
//! returned content blocks, and hands the result back through the
//! standard `JobResult`/`err_tag` channel.
//!
//! Worker-side only. Runs off the Lua main thread, so it MUST NOT
//! touch the Lua state. On completion, exactly one of `job.result`
//! or `job.err_tag` is populated.
//!
//! Provider lifetime: the caller's `LuaEngine.current_provider`
//! pointer is taken at job submit; `runLoopStreaming` (the only
//! producer of attached providers) outlives the pool worker because
//! the worker pool joins on shutdown, so the borrow is safe for the
//! call duration. A stale or null pointer at submit time is rejected
//! by the binding before reaching the worker.

const std = @import("std");
const Allocator = std.mem.Allocator;
const job_mod = @import("../Job.zig");
const Job = job_mod.Job;
const types = @import("../../types.zig");
const llm = @import("../../llm.zig");

const log = std.log.scoped(.lua_llm);

fn parseRole(role: []const u8) ?types.Role {
    if (std.mem.eql(u8, role, "user")) return .user;
    if (std.mem.eql(u8, role, "assistant")) return .assistant;
    return null;
}

/// Map a `ProviderError` onto a stable `ErrTag` + detail string. The
/// detail is dup'd on the engine allocator so the resume path can
/// surface `"tag: detail"` to Lua.
fn setLlmErr(alloc: Allocator, job: *Job, err: anyerror) void {
    job.err_tag = switch (err) {
        error.Cancelled => .cancelled,
        error.NotLoggedIn, error.LoginExpired => .permission_denied,
        error.ConnectionTimedOut, error.ReadTimeout, error.WriteTimeout => .timeout,
        error.ConnectionRefused, error.NetworkUnreachable => .connect_failed,
        error.TlsInitializationFailed => .tls_error,
        else => .http_error,
    };
    job.err_detail = alloc.dupe(u8, @errorName(err)) catch null;
}

pub fn executeLlmComplete(alloc: Allocator, job: *Job) void {
    const spec = job.kind.llm_complete;

    if (job.scope.isCancelled()) {
        job.err_tag = .cancelled;
        return;
    }

    // Build types.Message values inside a worker-local arena. Each
    // message gets a one-block content slice holding the joined text;
    // the spec arrays are borrowed and survive until resumeFromJob.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const messages = arena_alloc.alloc(types.Message, spec.messages.len) catch {
        job.err_tag = .io_error;
        job.err_detail = alloc.dupe(u8, "OOM") catch null;
        return;
    };
    for (spec.messages, 0..) |m, i| {
        const role = parseRole(m.role) orelse {
            job.err_tag = .io_error;
            job.err_detail = alloc.dupe(u8, "invalid role") catch null;
            return;
        };
        const blocks = arena_alloc.alloc(types.ContentBlock, 1) catch {
            job.err_tag = .io_error;
            job.err_detail = alloc.dupe(u8, "OOM") catch null;
            return;
        };
        blocks[0] = .{ .text = .{ .text = m.text } };
        messages[i] = .{ .role = role, .content = blocks };
    }

    const req: llm.Request = .{
        .system_stable = spec.system,
        .system_volatile = "",
        .messages = messages,
        .tool_definitions = &.{},
        .allocator = alloc,
    };

    const response = spec.provider.call(&req) catch |err| {
        setLlmErr(alloc, job, err);
        return;
    };
    defer response.deinit(alloc);

    // Assemble the response text from every .text content block.
    // Tool_use / thinking blocks are dropped: this primitive is for
    // straight completions and the caller doesn't expect structured
    // output. If the response has zero text, we still return the empty
    // string rather than an error.
    var total: usize = 0;
    for (response.content) |block| switch (block) {
        .text => |t| total += t.text.len,
        else => {},
    };
    const buf = alloc.alloc(u8, total) catch {
        job.err_tag = .io_error;
        job.err_detail = alloc.dupe(u8, "OOM") catch null;
        return;
    };
    var off: usize = 0;
    for (response.content) |block| switch (block) {
        .text => |t| {
            @memcpy(buf[off .. off + t.text.len], t.text);
            off += t.text.len;
        },
        else => {},
    };

    job.result = .{ .llm_complete = .{
        .text = buf,
        .input_tokens = response.input_tokens,
        .output_tokens = response.output_tokens,
    } };
}

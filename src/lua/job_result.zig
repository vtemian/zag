//! Marshals async `Job` completion results onto a coroutine's Lua stack.
//!
//! Pure dispatch on `Job.Kind`: no engine state beyond an allocator used
//! to free worker-owned result slices after Lua has copied them via
//! `pushString`. Extracted from LuaEngine.zig to keep the engine module
//! focused on lifecycle and scheduling.

const std = @import("std");
const zlua = @import("zlua");
const async_job = @import("Job.zig");
const Allocator = std.mem.Allocator;
const Lua = zlua.Lua;
const log = std.log.scoped(.lua);

/// Push the (value, err) result tuple for `job` onto `co`'s stack.
/// Returns the number of values pushed (always 2 today). On error
/// pushes (nil, err_tag_string); on success pushes per-kind values
/// (sleep: true, nil). `err_detail` (if present) is borrowed for the
/// duration of this call and freed by the caller after resume.
pub fn pushJobResultOntoStack(allocator: Allocator, co: *Lua, job: *async_job.Job) i32 {
    if (job.err_tag) |tag| {
        co.pushNil();
        if (job.err_detail) |d| {
            var buf: [256]u8 = undefined;
            const formatted = std.fmt.bufPrint(
                &buf,
                "{s}: {s}",
                .{ tag.toString(), d },
            ) catch blk: {
                log.debug("err detail truncated: tag={s}, detail_len={d}", .{ tag.toString(), d.len });
                break :blk tag.toString();
            };
            _ = co.pushString(formatted);
        } else {
            _ = co.pushString(tag.toString());
        }
        return 2;
    }
    switch (job.kind) {
        .sleep => {
            co.pushBoolean(true);
            co.pushNil();
            return 2;
        },
        .cmd_exec => {
            // On success worker populated job.result.cmd_exec. Null
            // result with no err_tag is a worker bug; surface a generic
            // io_error rather than faulting so the coroutine can observe it.
            const r = blk: {
                if (job.result) |res| switch (res) {
                    .cmd_exec => |cr| break :blk cr,
                    else => {},
                };
                co.pushNil();
                _ = co.pushString("io_error: cmd_exec missing result");
                return 2;
            };

            co.newTable();
            co.pushInteger(r.code);
            co.setField(-2, "code");
            _ = co.pushString(r.stdout);
            co.setField(-2, "stdout");
            _ = co.pushString(r.stderr);
            co.setField(-2, "stderr");
            co.pushBoolean(r.truncated);
            co.setField(-2, "truncated");

            // Lua copied the bytes via pushString; the worker-owned
            // heap slices can go back to the allocator now.
            allocator.free(r.stdout);
            allocator.free(r.stderr);

            co.pushNil();
            return 2;
        },
        .cmd_wait_done => |w| {
            // CmdHandle:wait() resumes with (code, nil). Child is
            // already reaped by the helper thread; nothing else to
            // clean up here.
            co.pushInteger(w.code);
            co.pushNil();
            return 2;
        },
        .cmd_read_line_done => |r| {
            // CmdHandle:lines() iterator resumes with (line, nil)
            // on success and (nil, nil) at EOF; `for line in
            // h:lines()` reads the first return value and stops on
            // nil. An err_tag would have been handled above via
            // the generic `(nil, "io_error: ...")` path.
            if (r.line) |l| {
                _ = co.pushString(l);
                allocator.free(l);
                co.pushNil();
                return 2;
            }
            co.pushNil();
            co.pushNil();
            return 2;
        },
        .cmd_write_done => {
            // CmdHandle:write() resumes with (true, nil) on
            // success. Failure surfaces as (nil, "io_error: ...")
            // via the generic err_tag branch above; bytes_written
            // isn't exposed to Lua because `writeAll` loops
            // internally so a successful return means full write.
            co.pushBoolean(true);
            co.pushNil();
            return 2;
        },
        .cmd_close_stdin_done => {
            // CmdHandle:close_stdin() resumes with (true, nil).
            // No failure path; close doesn't surface errors the
            // caller can act on.
            co.pushBoolean(true);
            co.pushNil();
            return 2;
        },
        .http_stream_line_done => |r| {
            // HttpStreamHandle:lines() iterator; same shape as
            // cmd_read_line_done: (line, nil) on a line, (nil,
            // nil) at EOF. err_tag (io_error, oom) goes through
            // the generic `(nil, "io_error: ...")` branch above.
            if (r.line) |l| {
                _ = co.pushString(l);
                allocator.free(l);
                co.pushNil();
                return 2;
            }
            co.pushNil();
            co.pushNil();
            return 2;
        },
        .http_get, .http_post => {
            // On success the worker populated job.result.http with
            // a heap-allocated body (on engine allocator). In v1
            // `headers` is always empty (see primitives/http.zig);
            // the iteration loop below is a no-op today but already
            // handles the eventual Task 7.5 case where the worker
            // fills in real response headers.
            const r = blk: {
                if (job.result) |res| switch (res) {
                    .http => |hr| break :blk hr,
                    else => {},
                };
                co.pushNil();
                _ = co.pushString("io_error: http missing result");
                return 2;
            };

            co.newTable();
            co.pushInteger(@intCast(r.status));
            co.setField(-2, "status");
            _ = co.pushString(r.body);
            co.setField(-2, "body");

            // headers subtable: lowercase-keyed name -> value. Zero
            // entries in v1, but the loop is cheap and future-proof.
            // pushString/setTable (not setField) because h.name is
            // a plain slice, not a sentinel-terminated string.
            co.newTable();
            for (r.headers) |h| {
                _ = co.pushString(h.name);
                _ = co.pushString(h.value);
                co.setTable(-3);
            }
            co.setField(-2, "headers");

            // Lua copied the bytes via pushString; worker-owned
            // slices can go back to the allocator. Guard the
            // outer-slice free so the v1 `&.{}` sentinel (no backing
            // allocation) doesn't hit the allocator.
            allocator.free(r.body);
            for (r.headers) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            if (r.headers.len > 0) allocator.free(r.headers);

            co.pushNil();
            return 2;
        },
        .fs_read => {
            // Success: push bytes, free the engine-owned slice.
            const r = blk: {
                if (job.result) |res| switch (res) {
                    .fs_read => |rr| break :blk rr,
                    else => {},
                };
                co.pushNil();
                _ = co.pushString("io_error: fs_read missing result");
                return 2;
            };
            _ = co.pushString(r.bytes);
            allocator.free(r.bytes);
            co.pushNil();
            return 2;
        },
        .fs_write, .fs_mkdir, .fs_remove => {
            // Success path: (true, nil). `empty` result carries no
            // payload; a null result with no err_tag is a worker
            // bug and surfaces as io_error so the coroutine can see
            // it rather than faulting.
            if (job.result) |res| switch (res) {
                .empty => {
                    co.pushBoolean(true);
                    co.pushNil();
                    return 2;
                },
                else => {},
            };
            co.pushNil();
            _ = co.pushString("io_error: fs op missing result");
            return 2;
        },
        .fs_list => {
            const r = blk: {
                if (job.result) |res| switch (res) {
                    .fs_list => |lr| break :blk lr,
                    else => {},
                };
                co.pushNil();
                _ = co.pushString("io_error: fs_list missing result");
                return 2;
            };

            // Array-style Lua table: numeric keys 1..N, each value
            // `{name=string, kind=string}`. Kind is a stable string
            // tag (file/dir/symlink/other) rather than the
            // std.fs.File.Kind identifier so Lua callers aren't
            // coupled to the Zig enum layout.
            co.newTable();
            for (r.entries, 0..) |entry, i| {
                co.newTable();
                _ = co.pushString(entry.name);
                co.setField(-2, "name");
                _ = co.pushString(entry.kind.toString());
                co.setField(-2, "kind");
                co.rawSetIndex(-2, @intCast(i + 1));
            }

            for (r.entries) |entry| allocator.free(entry.name);
            if (r.entries.len > 0) allocator.free(r.entries);

            co.pushNil();
            return 2;
        },
        .fs_stat => {
            const r = blk: {
                if (job.result) |res| switch (res) {
                    .fs_stat => |sr| break :blk sr,
                    else => {},
                };
                co.pushNil();
                _ = co.pushString("io_error: fs_stat missing result");
                return 2;
            };
            co.newTable();
            _ = co.pushString(r.kind.toString());
            co.setField(-2, "kind");
            co.pushInteger(@intCast(r.size));
            co.setField(-2, "size");
            co.pushInteger(r.mtime_ms);
            co.setField(-2, "mtime_ms");
            co.pushInteger(@intCast(r.mode));
            co.setField(-2, "mode");
            co.pushNil();
            return 2;
        },
    }
}

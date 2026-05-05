//! Tests for the Lua async runtime that cannot live inline.
//!
//! These exercise zlua coroutine semantics (resume / yield / xMove)
//! directly against the C API rather than any single zag production
//! module. They live here as a regression net pinning down the
//! invariants the AsyncRuntime relies on; pairing them with a single
//! production file would be arbitrary.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;

const testing = std.testing;

test "spike: create coroutine, resume, it yields, resume again, it finishes" {
    const alloc = testing.allocator;
    const lua = try Lua.init(alloc);
    defer lua.deinit();
    lua.openLibs();

    // Load a user function that yields once
    try lua.doString(
        \\function userfn()
        \\  local first = coroutine.yield("hello")
        \\  return first + 1
        \\end
    );

    // Push userfn on main stack
    _ = lua.getGlobal("userfn") catch unreachable;
    try testing.expect(lua.isFunction(-1));

    // Create coroutine, move function to it, ref it
    const co = lua.newThread();
    // After newThread main stack is [userfn, thread]; swap so userfn is on top,
    // then xMove pops userfn into the coroutine stack.
    lua.insert(-2);
    lua.xMove(co, 1);
    const co_ref = try lua.ref(zlua.registry_index);
    defer lua.unref(zlua.registry_index, co_ref);

    // First resume: no args, expect .yield with 1 result
    var num_results: i32 = 0;
    var status = try co.resumeThread(lua, 0, &num_results);
    try testing.expectEqual(zlua.ResumeStatus.yield, status);
    try testing.expectEqual(@as(i32, 1), num_results);
    const yielded = try co.toString(-1);
    try testing.expectEqualStrings("hello", yielded);
    co.pop(num_results);

    // Second resume: push 41, expect .ok with 1 result == 42
    co.pushInteger(41);
    status = try co.resumeThread(lua, 1, &num_results);
    try testing.expectEqual(zlua.ResumeStatus.ok, status);
    try testing.expectEqual(@as(i32, 1), num_results);
    const final = try co.toInteger(-1);
    try testing.expectEqual(@as(i64, 42), final);
    co.pop(num_results);
}

/// Zig C-closure that yields back to the scheduler.
/// Reads an integer argument (discarded in this spike), pushes a marker string,
/// and calls `yield`, which is `noreturn` on Lua 5.4.
fn spikeSleep(co: *Lua) i32 {
    _ = co.toInteger(1) catch 0;
    _ = co.pushString("yielded");
    co.yield(1);
}

test "spike: Zig C-closure can yield back to scheduler" {
    const alloc = testing.allocator;
    const lua = try Lua.init(alloc);
    defer lua.deinit();
    lua.openLibs();

    // Build a `zag` global table exposing `sleep = spikeSleep`.
    lua.newTable();
    lua.pushFunction(zlua.wrap(spikeSleep));
    lua.setField(-2, "sleep");
    lua.setGlobal("zag");

    // User Lua calls into the Zig C-closure via the global table.
    try lua.doString(
        \\function userfn()
        \\  return zag.sleep(100)
        \\end
    );

    _ = try lua.getGlobal("userfn");
    try testing.expect(lua.isFunction(-1));

    const co = lua.newThread();
    // After newThread main stack is [userfn, thread]; swap so userfn is on top,
    // then xMove pops userfn into the coroutine stack.
    lua.insert(-2);
    lua.xMove(co, 1);
    const co_ref = try lua.ref(zlua.registry_index);
    defer lua.unref(zlua.registry_index, co_ref);

    // First resume: userfn calls zag.sleep(100); Zig yields "yielded".
    var num_results: i32 = 0;
    var status = try co.resumeThread(lua, 0, &num_results);
    try testing.expectEqual(zlua.ResumeStatus.yield, status);
    try testing.expectEqual(@as(i32, 1), num_results);
    const yielded = try co.toString(-1);
    try testing.expectEqualStrings("yielded", yielded);
    co.pop(num_results);

    // Second resume: scheduler pushes "woke" as the value of the yield expression.
    _ = co.pushString("woke");
    status = try co.resumeThread(lua, 1, &num_results);
    try testing.expectEqual(zlua.ResumeStatus.ok, status);
    try testing.expectEqual(@as(i32, 1), num_results);
    const final = try co.toString(-1);
    try testing.expectEqualStrings("woke", final);
    co.pop(num_results);
}

test "spike: runtime error in coroutine returns LuaRuntime, msg readable" {
    const alloc = testing.allocator;
    const lua = try Lua.init(alloc);
    defer lua.deinit();
    lua.openLibs();

    // A function whose body raises a Lua runtime error.
    try lua.doString(
        \\function crasher()
        \\  error("oops")
        \\end
    );

    _ = try lua.getGlobal("crasher");
    try testing.expect(lua.isFunction(-1));

    const co = lua.newThread();
    // After newThread main stack is [crasher, thread]; swap so crasher is on top,
    // then xMove pops crasher into the coroutine stack.
    lua.insert(-2);
    lua.xMove(co, 1);
    const co_ref = try lua.ref(zlua.registry_index);
    defer lua.unref(zlua.registry_index, co_ref);

    // Resuming the coroutine should surface the runtime error as error.LuaRuntime.
    var num_results: i32 = 0;
    try testing.expectError(error.LuaRuntime, co.resumeThread(lua, 0, &num_results));

    // On a runtime error the error object is on top of the coroutine's stack
    // (not the main state's). Lua prefixes the message with `file:line: `, so
    // substring-match for the body.
    const msg = try co.toString(-1);
    try testing.expect(std.mem.indexOf(u8, msg, "oops") != null);
    co.pop(1);
}

test {
    @import("std").testing.refAllDecls(@This());
}

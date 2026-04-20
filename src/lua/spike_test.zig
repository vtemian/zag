// src/lua/spike_test.zig
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

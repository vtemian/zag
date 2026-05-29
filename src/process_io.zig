//! Process-wide `std.Io` accessor.
//!
//! Zig 0.16 routes every filesystem and process syscall through an `std.Io`
//! interface that callers must pass explicitly. Zag performs fs reads from
//! many deep, io-free call sites (instruction walk-up, auth file load, the Lua
//! `fs`/`sessions` bindings) and the whole process shares exactly one
//! `std.Io.Threaded` instance. Rather than thread `io` through every signature
//! that only ever uses the single process io, this module captures it once at
//! startup — mirroring `env.zig`/`clock.zig`/`sync.zig` — and hands it back via
//! `get`. Hot paths and code that already carries an `io` keep passing it
//! directly; this is only for the shallow fs helpers that have no other route.

const std = @import("std");

/// The process-wide io, installed once at startup. Reading it before `init`
/// is a startup-ordering bug; `get` traps on null rather than corrupting state.
var process_io: ?std.Io = null;

/// Install the process io. Call once from `main` (and `Harness`) before any
/// fs helper that reads `get` runs.
pub fn init(io: std.Io) void {
    process_io = io;
}

/// The process-wide io. Panics if read before `init`.
pub fn get() std.Io {
    return process_io orelse @panic("process_io: used before process_io.init()");
}

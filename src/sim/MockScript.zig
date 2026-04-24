//! Parsed mock-provider script for the TUI simulator.
//!
//! The on-disk format is a JSON object with a `turns` array. Each turn
//! carries a sequence of SSE chunks that the mock server replays verbatim
//! as `data: <json>\n\n` events when the scenario produces a turn:
//!
//! ```json
//! {
//!   "turns": [
//!     {
//!       "chunks": [
//!         {"delta": {"content": "Hello "}},
//!         {"delta": {"content": "world"}, "delay_ms": 50},
//!         {"finish_reason": "stop"}
//!       ],
//!       "usage": {"prompt_tokens": 10, "completion_tokens": 5}
//!     }
//!   ]
//! }
//! ```
//!
//! Each chunk JSON is re-serialized into an owned byte slice stripped of
//! the harness-only `delay_ms` field so the server can emit it directly.
//! The script is heap-allocated so its chunk bytes keep stable addresses
//! across `nextTurn` claims; callers borrow turn pointers and must not
//! outlive `destroy`.

const std = @import("std");

const MockScript = @This();

const log = std.log.scoped(.sim_mock_script);

/// Allocator that owns this struct, the `turns` slice, every nested
/// `chunks` slice, and every `Chunk.json` byte slice.
alloc: std.mem.Allocator,

/// All turns parsed from the script, in source order.
turns: []Turn,

/// Monotonic index into `turns`. `nextTurn` bumps it; `reset` zeroes it.
turn_index: std.atomic.Value(usize) = .{ .raw = 0 },

/// A single chunk the mock server emits inside one `data:` SSE event.
pub const Chunk = struct {
    /// Raw JSON bytes that will be emitted inside an SSE `data: <bytes>\n\n`
    /// event. Owned by `MockScript`.
    json: []const u8,
    /// Optional delay before emitting this chunk (ms).
    delay_ms: u32 = 0,
};

/// Optional `usage` block replayed alongside the final chunk of a turn.
pub const Usage = struct {
    prompt_tokens: ?u32 = null,
    completion_tokens: ?u32 = null,
};

/// One assistant turn: an ordered list of chunks plus optional usage.
pub const Turn = struct {
    chunks: []Chunk,
    usage: ?Usage = null,
};

pub const LoadError = std.mem.Allocator.Error ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    std.json.ParseError(std.json.Scanner) ||
    error{ EndOfStream, StreamTooLong, InvalidChunk, FileTooBig };

/// Read `path` into memory and parse it. The whole file is slurped (mock
/// scripts are small fixtures, not streaming data).
pub fn loadFromFile(alloc: std.mem.Allocator, path: []const u8) LoadError!*MockScript {
    const max_bytes: usize = 16 * 1024 * 1024;
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(alloc, max_bytes);
    defer alloc.free(bytes);
    return loadFromSlice(alloc, bytes);
}

/// Parse `src` (a full JSON document) and return an owned script.
pub fn loadFromSlice(alloc: std.mem.Allocator, src: []const u8) LoadError!*MockScript {
    // Shape we hand to `std.json.parseFromSlice`. `delta` and `finish_reason`
    // stay as `std.json.Value` so we can serialize them back to their raw
    // on-the-wire JSON form without re-defining the provider schema here.
    const RawChunk = struct {
        delta: ?std.json.Value = null,
        finish_reason: ?std.json.Value = null,
        delay_ms: ?u32 = null,
    };
    const RawTurn = struct {
        chunks: []const RawChunk,
        usage: ?Usage = null,
    };
    const Root = struct {
        turns: []const RawTurn,
    };

    var parsed = try std.json.parseFromSlice(Root, alloc, src, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const self = try alloc.create(MockScript);
    errdefer alloc.destroy(self);

    const turns = try alloc.alloc(Turn, parsed.value.turns.len);
    errdefer alloc.free(turns);

    // Track how many turns we've fully materialized so errdefer can clean
    // up the partial prefix if a later turn fails to materialize.
    var built: usize = 0;
    errdefer freeTurns(alloc, turns[0..built]);

    for (parsed.value.turns, 0..) |raw_turn, t| {
        const chunks = try alloc.alloc(Chunk, raw_turn.chunks.len);
        errdefer alloc.free(chunks);

        var filled: usize = 0;
        errdefer freeChunks(alloc, chunks[0..filled]);

        for (raw_turn.chunks, 0..) |raw_chunk, c| {
            const json = try stringifyChunk(alloc, raw_chunk);
            errdefer alloc.free(json);
            chunks[c] = .{ .json = json, .delay_ms = raw_chunk.delay_ms orelse 0 };
            filled += 1;
        }

        turns[t] = .{ .chunks = chunks, .usage = raw_turn.usage };
        built += 1;
    }

    self.* = .{ .alloc = alloc, .turns = turns };
    return self;
}

/// Free every owned slice and the struct itself.
pub fn destroy(self: *MockScript) void {
    freeTurns(self.alloc, self.turns);
    self.alloc.free(self.turns);
    self.alloc.destroy(self);
}

/// Atomically claim the next turn. Returns `error.NoMoreTurns` when
/// exhausted. The returned pointer is stable for the lifetime of the
/// script (turns live on the heap) but must not outlive `destroy`.
pub fn nextTurn(self: *MockScript) error{NoMoreTurns}!*const Turn {
    const idx = self.turn_index.fetchAdd(1, .acq_rel);
    if (idx >= self.turns.len) {
        // Keep the index bounded so repeated calls after exhaustion don't
        // eventually wrap a `usize` — a purely defensive saturation.
        _ = self.turn_index.store(self.turns.len, .release);
        return error.NoMoreTurns;
    }
    return &self.turns[idx];
}

/// Reset to the first turn. Useful for long-lived scripts replayed across
/// multiple runs (e.g. a developer iterating on a scenario).
pub fn reset(self: *MockScript) void {
    self.turn_index.store(0, .release);
}

// --- internals --------------------------------------------------------------

/// Build the owned JSON bytes we hand to the SSE emitter. We only emit
/// whichever of `delta`/`finish_reason` is populated; `delay_ms` is harness
/// metadata and never appears on the wire.
fn stringifyChunk(
    alloc: std.mem.Allocator,
    raw: anytype,
) LoadError![]u8 {
    if (raw.delta) |delta| {
        const Wrapper = struct {
            delta: std.json.Value,
        };
        return std.json.Stringify.valueAlloc(alloc, Wrapper{ .delta = delta }, .{});
    }
    if (raw.finish_reason) |finish| {
        const Wrapper = struct {
            finish_reason: std.json.Value,
        };
        return std.json.Stringify.valueAlloc(alloc, Wrapper{ .finish_reason = finish }, .{});
    }
    return error.InvalidChunk;
}

fn freeChunks(alloc: std.mem.Allocator, chunks: []Chunk) void {
    for (chunks) |chunk| alloc.free(chunk.json);
    alloc.free(chunks);
}

fn freeTurns(alloc: std.mem.Allocator, turns: []Turn) void {
    for (turns) |turn| freeChunks(alloc, turn.chunks);
}

// --- tests ------------------------------------------------------------------

test "loadFromSlice with two turns preserves chunk bytes and delay" {
    const src =
        \\{"turns":[
        \\ {"chunks":[{"delta":{"content":"a"}},{"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":1}},
        \\ {"chunks":[{"delta":{"content":"b"},"delay_ms":50},{"finish_reason":"stop"}]}
        \\]}
    ;
    const script = try MockScript.loadFromSlice(std.testing.allocator, src);
    defer script.destroy();
    try std.testing.expectEqual(@as(usize, 2), script.turns.len);
    try std.testing.expectEqual(@as(usize, 2), script.turns[0].chunks.len);
    try std.testing.expect(std.mem.indexOf(u8, script.turns[0].chunks[0].json, "\"content\":\"a\"") != null);
    try std.testing.expectEqual(@as(u32, 50), script.turns[1].chunks[0].delay_ms);
    try std.testing.expectEqual(@as(?u32, 10), script.turns[0].usage.?.prompt_tokens);
}

test "nextTurn advances and surfaces NoMoreTurns at the end" {
    const src =
        \\{"turns":[{"chunks":[]},{"chunks":[]}]}
    ;
    const script = try MockScript.loadFromSlice(std.testing.allocator, src);
    defer script.destroy();
    _ = try script.nextTurn();
    _ = try script.nextTurn();
    try std.testing.expectError(error.NoMoreTurns, script.nextTurn());
}

test "delay_ms is stripped from emitted chunk JSON" {
    const src =
        \\{"turns":[{"chunks":[{"delta":{"content":"x"},"delay_ms":50}]}]}
    ;
    const script = try MockScript.loadFromSlice(std.testing.allocator, src);
    defer script.destroy();
    try std.testing.expect(std.mem.indexOf(u8, script.turns[0].chunks[0].json, "delay_ms") == null);
    try std.testing.expectEqual(@as(u32, 50), script.turns[0].chunks[0].delay_ms);
}

test "reset lets nextTurn start over" {
    const src =
        \\{"turns":[{"chunks":[]}]}
    ;
    const script = try MockScript.loadFromSlice(std.testing.allocator, src);
    defer script.destroy();
    _ = try script.nextTurn();
    try std.testing.expectError(error.NoMoreTurns, script.nextTurn());
    script.reset();
    _ = try script.nextTurn();
}

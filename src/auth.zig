//! Multi-provider credential reader for `~/.config/zag/auth.json`.
//!
//! On-disk shape (the OAuth plan extends this with `"type": "oauth"` later):
//! ```json
//! {
//!   "openai":    { "type": "api_key", "key": "sk-..." },
//!   "anthropic": { "type": "api_key", "key": "sk-ant-..." }
//! }
//! ```
//!
//! File mode is `0o600`. The loader treats a missing file as an empty map
//! (first-run UX); any other IO failure or malformed JSON surfaces as an
//! error. OAuth entries are recognised at load time but rejected with
//! `error.UnknownCredentialType` so api-key-only call sites fail loudly
//! instead of silently dropping the entry. The full OAuth path lands with
//! `docs/plans/2026-04-20-chatgpt-oauth.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.auth);

/// A single provider credential. Today only `api_key` is constructed by the
/// loader; the tagged union keeps room for `oauth` so the OAuth plan can
/// extend it without changing the discriminator shape at call sites.
pub const Credential = union(enum) {
    /// Bearer-style API key, owned by the enclosing `AuthFile`.
    api_key: []const u8,
};

/// In-memory view of `auth.json`. Each entry owns both its key (provider
/// name) and its value (api_key bytes) through the same allocator.
pub const AuthFile = struct {
    /// Allocator used for every duped string inside `entries`.
    allocator: Allocator,
    /// Provider-name to credential map. Keys are duped into `allocator`.
    entries: std.StringHashMap(Credential),

    /// Construct an empty `AuthFile`. Pair with `deinit`.
    pub fn init(alloc: Allocator) AuthFile {
        return .{
            .allocator = alloc,
            .entries = std.StringHashMap(Credential).init(alloc),
        };
    }

    /// Release every duped key and value, then the underlying map.
    pub fn deinit(self: *AuthFile) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeCredential(self.allocator, entry.value_ptr.*);
        }
        self.entries.deinit();
    }

    /// Insert or replace an api-key credential for `name`. Both `name` and
    /// `key` are duped into the allocator so the caller retains ownership
    /// of its inputs.
    pub fn setApiKey(self: *AuthFile, name: []const u8, key: []const u8) !void {
        const duped_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(duped_key);

        if (self.entries.getEntry(name)) |existing| {
            freeCredential(self.allocator, existing.value_ptr.*);
            existing.value_ptr.* = .{ .api_key = duped_key };
            return;
        }

        const duped_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(duped_name);

        try self.entries.put(duped_name, .{ .api_key = duped_key });
    }

    /// Return a borrowed api-key slice for `name`, or `null` if the provider
    /// has no entry. Returns `error.WrongCredentialType` if the entry exists
    /// but is not an api-key (reserved for the future OAuth case).
    pub fn getApiKey(self: *AuthFile, name: []const u8) !?[]const u8 {
        const cred = self.entries.get(name) orelse return null;
        return switch (cred) {
            .api_key => |key| key,
        };
    }
};

/// Free the bytes a `Credential` owns. Split out so `deinit` and
/// `setApiKey`'s replace path stay symmetric.
fn freeCredential(alloc: Allocator, cred: Credential) void {
    switch (cred) {
        .api_key => |key| alloc.free(key),
    }
}

/// Hard cap on the auth file size. Keeps a corrupted path from slurping
/// unbounded memory into the parser.
const max_auth_bytes: usize = 1 * 1024 * 1024;

/// True iff `mode`'s group- and world-accessible bits are clear. The
/// documented auth.json mode is `0o600`; any bit in `0o077` means the file
/// is readable or writable by someone other than the owner, and the loader
/// should warn loudly instead of silently accepting the drift.
pub fn checkFileMode(mode: std.posix.mode_t) bool {
    return (mode & 0o077) == 0;
}

/// Load the auth file at `path`. A missing file returns an empty `AuthFile`
/// (first-run UX). Any other IO or parse failure surfaces as an error.
pub fn loadAuthFile(alloc: Allocator, path: []const u8) !AuthFile {
    // Stat first so we can warn on wrong mode without failing the load.
    // Windows has no POSIX mode bits, so skip the check there.
    if (@import("builtin").os.tag != .windows) {
        if (std.fs.cwd().statFile(path)) |stat| {
            const mode: std.posix.mode_t = @intCast(stat.mode & 0o7777);
            if (!checkFileMode(mode)) {
                log.warn("auth file at '{s}' has mode 0o{o} (expected 0o600); credentials may be readable by other users", .{ path, mode });
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            // The actual load path below re-surfaces this class of error
            // with full context; we skip the mode check and log at debug
            // so the stat failure isn't silently discarded.
            else => |e| log.debug("stat for mode check failed: {s}", .{@errorName(e)}),
        }
    }

    const bytes = std.fs.cwd().readFileAlloc(alloc, path, max_auth_bytes) catch |err| switch (err) {
        error.FileNotFound => return AuthFile.init(alloc),
        else => return err,
    };
    defer alloc.free(bytes);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch {
        return error.MalformedAuthJson;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.MalformedAuthJson,
    };

    var file = AuthFile.init(alloc);
    errdefer file.deinit();

    var it = root.iterator();
    while (it.next()) |entry| {
        const provider_name = entry.key_ptr.*;
        const value_obj = switch (entry.value_ptr.*) {
            .object => |v| v,
            else => return error.MalformedAuthJson,
        };

        const type_value = value_obj.get("type") orelse return error.MalformedAuthJson;
        const type_tag = switch (type_value) {
            .string => |s| s,
            else => return error.MalformedAuthJson,
        };

        if (std.mem.eql(u8, type_tag, "api_key")) {
            const key_value = value_obj.get("key") orelse return error.MalformedAuthJson;
            const key_bytes = switch (key_value) {
                .string => |s| s,
                else => return error.MalformedAuthJson,
            };
            try file.setApiKey(provider_name, key_bytes);
        } else {
            // OAuth storage ships with the OAuth plan. Rejecting here keeps
            // callers from silently seeing a half-populated map.
            log.warn("unknown credential type '{s}' for provider '{s}'", .{ type_tag, provider_name });
            return error.UnknownCredentialType;
        }
    }

    return file;
}

/// Serialise `file` to `path` as pretty JSON with mode `0o600`. Creates the
/// parent directory if missing.
pub fn saveAuthFile(path: []const u8, file: AuthFile) !void {
    if (std.fs.path.dirname(path)) |parent| {
        std.fs.cwd().makePath(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const handle = try std.fs.cwd().createFile(path, .{ .mode = 0o600, .truncate = true });
    defer handle.close();

    var scratch: [512]u8 = undefined;
    var w = handle.writer(&scratch);
    try writeAuthJson(&w.interface, file);
    try w.interface.flush();
}

/// Emit `file` as `{ "provider": { "type": "api_key", "key": "..." }, ... }`.
/// Order is the hash map's iteration order; stable enough for a config
/// file that humans will re-read but not sort-critical.
fn writeAuthJson(w: *std.Io.Writer, file: AuthFile) !void {
    try w.writeAll("{\n");
    var first = true;
    var it = file.entries.iterator();
    while (it.next()) |entry| {
        if (!first) try w.writeAll(",\n");
        first = false;
        try w.writeAll("  ");
        try writeJsonString(w, entry.key_ptr.*);
        try w.writeAll(": { \"type\": \"api_key\", \"key\": ");
        switch (entry.value_ptr.*) {
            .api_key => |key| try writeJsonString(w, key),
        }
        try w.writeAll(" }");
    }
    try w.writeAll("\n}\n");
}

/// Minimal JSON string escaper: quotes, backslashes, and control bytes.
/// Kept local so this module has no cross-package dependency.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

// -- Tests -----------------------------------------------------------------

test "checkFileMode flags world- or group-accessible bits" {
    // 0o600 is the documented auth.json mode. Any bit in 0o077 means the file
    // is readable or writable by someone other than the owner, which is
    // exactly the drift loadAuthFile warns about.
    try std.testing.expect(checkFileMode(0o600));
    try std.testing.expect(checkFileMode(0o400));
    try std.testing.expect(!checkFileMode(0o644));
    try std.testing.expect(!checkFileMode(0o660));
    try std.testing.expect(!checkFileMode(0o666));
    try std.testing.expect(!checkFileMode(0o777));
}

test "loadAuthFile returns empty map when file missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const missing = try std.fs.path.join(std.testing.allocator, &.{ path, "auth.json" });
    defer std.testing.allocator.free(missing);

    var file = try loadAuthFile(std.testing.allocator, missing);
    defer file.deinit();
    try std.testing.expectEqual(@as(usize, 0), file.entries.count());
}

test "saveAuthFile writes mode 0600" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "auth.json" });
    defer std.testing.allocator.free(path);

    var file = AuthFile.init(std.testing.allocator);
    defer file.deinit();
    try file.setApiKey("openai", "sk-test");
    try saveAuthFile(path, file);

    const stat = try std.fs.cwd().statFile(path);
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.mode & 0o777)));
}

test "round-trip preserves api_key entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "auth.json" });
    defer std.testing.allocator.free(path);

    var write = AuthFile.init(std.testing.allocator);
    defer write.deinit();
    try write.setApiKey("openai", "sk-write");
    try write.setApiKey("anthropic", "sk-ant-write");
    try saveAuthFile(path, write);

    var read = try loadAuthFile(std.testing.allocator, path);
    defer read.deinit();
    try std.testing.expectEqualStrings("sk-write", (try read.getApiKey("openai")).?);
    try std.testing.expectEqualStrings("sk-ant-write", (try read.getApiKey("anthropic")).?);
}

test "getApiKey returns null for missing provider" {
    var file = AuthFile.init(std.testing.allocator);
    defer file.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), try file.getApiKey("openai"));
}

test "loadAuthFile rejects oauth entries with UnknownCredentialType" {
    // Option (b) from the plan: the loader rejects an oauth entry at load
    // time with `error.UnknownCredentialType` because OAuth storage lands in
    // a later plan. The test preseeds raw JSON and asserts the load error
    // surfaces instead of silently dropping the entry. Once the OAuth plan
    // extends `Credential`, this test flips to exercise `getApiKey` on a
    // successfully-loaded oauth entry and assert `error.WrongCredentialType`
    // there.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "auth.json" });
    defer std.testing.allocator.free(path);

    try tmp.dir.writeFile(.{
        .sub_path = "auth.json",
        .data =
        \\{
        \\  "openai-oauth": { "type": "oauth", "access_token": "abc" }
        \\}
        ,
    });

    try std.testing.expectError(
        error.UnknownCredentialType,
        loadAuthFile(std.testing.allocator, path),
    );
}

test {
    @import("std").testing.refAllDecls(@This());
}

//! Multi-provider credential reader for `~/.config/zag/auth.json`.
//!
//! On-disk shape:
//! ```json
//! {
//!   "openai":        { "type": "api_key", "key": "sk-..." },
//!   "anthropic":     { "type": "api_key", "key": "sk-..." },
//!   "openai-oauth":  {
//!     "type": "oauth",
//!     "id_token": "...",
//!     "access_token": "...",
//!     "refresh_token": "...",
//!     "account_id": "...",
//!     "last_refresh": "2026-04-20T12:34:56Z"
//!   }
//! }
//! ```
//!
//! File mode is `0o600`. The loader treats a missing file as an empty map
//! (first-run UX); any other IO failure or malformed JSON surfaces as an
//! error. Unknown credential `type` tags are rejected with
//! `error.UnknownCredentialType` so call sites fail loudly instead of
//! silently dropping the entry.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.auth);

/// OAuth credential bundle. Every field is owned by the enclosing
/// `AuthFile`'s allocator; `last_refresh` is an ISO-8601 UTC timestamp used
/// by the proactive-refresh path.
pub const OAuthCred = struct {
    id_token: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
    account_id: []const u8,
    last_refresh: []const u8,
};

/// A single provider credential. Both variants own their byte payloads
/// through the enclosing `AuthFile`'s allocator.
pub const Credential = union(enum) {
    /// Bearer-style API key, owned by the enclosing `AuthFile`.
    api_key: []const u8,
    /// OAuth token bundle, every field owned by the enclosing `AuthFile`.
    oauth: OAuthCred,
};

/// In-memory view of `auth.json`. Each entry owns both its key (provider
/// name) and its value bytes through the same allocator.
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
    /// but is an oauth bundle.
    pub fn getApiKey(self: *AuthFile, name: []const u8) !?[]const u8 {
        const cred = self.entries.get(name) orelse return null;
        return switch (cred) {
            .api_key => |key| key,
            .oauth => error.WrongCredentialType,
        };
    }

    /// Insert or replace an oauth credential for `name`. Every field of
    /// `cred` is duped into the allocator; if the provider already has any
    /// entry (api_key or oauth), the previous bytes are freed first.
    pub fn setOAuth(self: *AuthFile, name: []const u8, cred: OAuthCred) !void {
        const duped = try dupeOAuth(self.allocator, cred);
        errdefer freeOAuth(self.allocator, duped);

        if (self.entries.getEntry(name)) |existing| {
            freeCredential(self.allocator, existing.value_ptr.*);
            existing.value_ptr.* = .{ .oauth = duped };
            return;
        }

        const duped_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(duped_name);

        try self.entries.put(duped_name, .{ .oauth = duped });
    }

    /// Return a borrowed `OAuthCred` for `name`. Returns `error.NotFound`
    /// if the provider has no entry, or `error.WrongCredentialType` if the
    /// entry exists but is an api-key.
    pub fn getOAuth(self: *AuthFile, name: []const u8) !OAuthCred {
        const cred = self.entries.get(name) orelse return error.NotFound;
        return switch (cred) {
            .oauth => |o| o,
            .api_key => error.WrongCredentialType,
        };
    }

    /// Remove `name` from the map, freeing its duped key and credential
    /// bytes. Missing names are a no-op: the `zag auth remove <prov>`
    /// subcommand treats "not configured" as a successful end-state.
    pub fn removeEntry(self: *AuthFile, name: []const u8) void {
        const existing = self.entries.fetchRemove(name) orelse return;
        self.allocator.free(existing.key);
        freeCredential(self.allocator, existing.value);
    }
};

/// Dupe every field of `src` into `alloc`. Unwinds partial allocations on
/// failure so callers never see a half-populated `OAuthCred`.
fn dupeOAuth(alloc: Allocator, src: OAuthCred) !OAuthCred {
    const id_token = try alloc.dupe(u8, src.id_token);
    errdefer alloc.free(id_token);
    const access_token = try alloc.dupe(u8, src.access_token);
    errdefer alloc.free(access_token);
    const refresh_token = try alloc.dupe(u8, src.refresh_token);
    errdefer alloc.free(refresh_token);
    const account_id = try alloc.dupe(u8, src.account_id);
    errdefer alloc.free(account_id);
    const last_refresh = try alloc.dupe(u8, src.last_refresh);
    errdefer alloc.free(last_refresh);
    return .{
        .id_token = id_token,
        .access_token = access_token,
        .refresh_token = refresh_token,
        .account_id = account_id,
        .last_refresh = last_refresh,
    };
}

/// Free every field of an owned `OAuthCred`. Paired with `dupeOAuth`.
fn freeOAuth(alloc: Allocator, cred: OAuthCred) void {
    alloc.free(cred.id_token);
    alloc.free(cred.access_token);
    alloc.free(cred.refresh_token);
    alloc.free(cred.account_id);
    alloc.free(cred.last_refresh);
}

/// Free the bytes a `Credential` owns. Split out so `deinit` and the
/// `setApiKey`/`setOAuth` replace paths stay symmetric.
fn freeCredential(alloc: Allocator, cred: Credential) void {
    switch (cred) {
        .api_key => |key| alloc.free(key),
        .oauth => |o| freeOAuth(alloc, o),
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
        } else if (std.mem.eql(u8, type_tag, "oauth")) {
            const id_token = try stringField(value_obj, "id_token");
            const access_token = try stringField(value_obj, "access_token");
            const refresh_token = try stringField(value_obj, "refresh_token");
            const account_id = try stringField(value_obj, "account_id");
            const last_refresh = try stringField(value_obj, "last_refresh");
            try file.setOAuth(provider_name, .{
                .id_token = id_token,
                .access_token = access_token,
                .refresh_token = refresh_token,
                .account_id = account_id,
                .last_refresh = last_refresh,
            });
        } else {
            log.warn("unknown credential type '{s}' for provider '{s}'", .{ type_tag, provider_name });
            return error.UnknownCredentialType;
        }
    }

    return file;
}

/// Pull a required string field from a JSON object, returning
/// `error.MalformedAuthJson` if missing or of the wrong kind.
fn stringField(obj: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const v = obj.get(name) orelse return error.MalformedAuthJson;
    return switch (v) {
        .string => |s| s,
        else => error.MalformedAuthJson,
    };
}

/// Serialise `file` to `path` as pretty JSON with mode `0o600`. Creates the
/// parent directory if missing. Uses the tmpfile + fsync + rename pattern
/// (mirroring `Session.zig`) so a mid-write crash can never leave a
/// partially-written `auth.json`.
pub fn saveAuthFile(path: []const u8, file: AuthFile) !void {
    if (std.fs.path.dirname(path)) |parent| {
        std.fs.cwd().makePath(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{path}) catch
        return error.PathTooLong;

    const cwd = std.fs.cwd();

    // Belt-and-suspenders: a stale <path>.tmp from a prior crash would
    // otherwise inherit its old mode bits via O_CREAT|O_TRUNC. Unlinking
    // first guarantees a fresh 0o600 file.
    cwd.deleteFile(tmp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    {
        const tmp_file = try cwd.createFile(tmp_path, .{ .mode = 0o600, .truncate = true });
        defer tmp_file.close();

        var scratch: [512]u8 = undefined;
        var w = tmp_file.writer(&scratch);
        try writeAuthJson(&w.interface, file);
        try w.interface.flush();
        try tmp_file.sync();
    }

    try cwd.rename(tmp_path, path);
}

/// Emit `file` as a JSON object keyed by provider name. Order is the hash
/// map's iteration order; stable enough for a config file that humans will
/// re-read but not sort-critical.
fn writeAuthJson(w: *std.Io.Writer, file: AuthFile) !void {
    try w.writeAll("{\n");
    var first = true;
    var it = file.entries.iterator();
    while (it.next()) |entry| {
        if (!first) try w.writeAll(",\n");
        first = false;
        try w.writeAll("  ");
        try writeJsonString(w, entry.key_ptr.*);
        switch (entry.value_ptr.*) {
            .api_key => |key| {
                try w.writeAll(": { \"type\": \"api_key\", \"key\": ");
                try writeJsonString(w, key);
                try w.writeAll(" }");
            },
            .oauth => |o| {
                try w.writeAll(": { \"type\": \"oauth\", \"id_token\": ");
                try writeJsonString(w, o.id_token);
                try w.writeAll(", \"access_token\": ");
                try writeJsonString(w, o.access_token);
                try w.writeAll(", \"refresh_token\": ");
                try writeJsonString(w, o.refresh_token);
                try w.writeAll(", \"account_id\": ");
                try writeJsonString(w, o.account_id);
                try w.writeAll(", \"last_refresh\": ");
                try writeJsonString(w, o.last_refresh);
                try w.writeAll(" }");
            },
        }
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

/// Load `path`, upsert `cred` under `name`, then save. Takes an exclusive
/// advisory lock on a sidecar `<path>.lock` file so concurrent OAuth
/// refreshes (across threads or processes) cannot stomp each other's
/// writes. The lock file is created with mode `0o600` and left in place
/// between calls; subsequent callers re-open it cheaply. On macOS the lock
/// is advisory, but every writer in this codebase goes through this
/// function so serialization is guaranteed within a zag installation.
pub fn upsertOAuth(alloc: Allocator, path: []const u8, name: []const u8, cred: OAuthCred) !void {
    const lock_path = try std.fmt.allocPrint(alloc, "{s}.lock", .{path});
    defer alloc.free(lock_path);

    if (std.fs.path.dirname(path)) |parent| {
        std.fs.cwd().makePath(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const lock_file = try std.fs.cwd().createFile(lock_path, .{
        .read = true,
        .truncate = false,
        .mode = 0o600,
    });
    defer lock_file.close();
    try lock_file.lock(.exclusive);
    defer lock_file.unlock();

    var file = loadAuthFile(alloc, path) catch |err| switch (err) {
        error.FileNotFound => AuthFile.init(alloc),
        else => return err,
    };
    defer file.deinit();
    try file.setOAuth(name, cred);
    try saveAuthFile(path, file);
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

test "saveAuthFile is atomic under simulated crash" {
    // Pre-create a stale <path>.tmp from a hypothetical prior crash. The
    // atomic-save path must unlink it and still succeed, leaving the final
    // auth.json with the new contents only.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "auth.json" });
    defer std.testing.allocator.free(path);

    try tmp.dir.writeFile(.{
        .sub_path = "auth.json.tmp",
        .data = "garbage-from-a-prior-crash",
    });

    var file = AuthFile.init(std.testing.allocator);
    defer file.deinit();
    try file.setApiKey("openai", "sk-fresh");
    try saveAuthFile(path, file);

    var reloaded = try loadAuthFile(std.testing.allocator, path);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), reloaded.entries.count());
    try std.testing.expectEqualStrings("sk-fresh", (try reloaded.getApiKey("openai")).?);

    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile("auth.json.tmp"),
    );
}

test "saveAuthFile preserves 0o600 after atomic rename" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "auth.json" });
    defer std.testing.allocator.free(path);

    var file = AuthFile.init(std.testing.allocator);
    defer file.deinit();
    try file.setApiKey("openai", "sk-mode");
    try saveAuthFile(path, file);

    const stat = try std.fs.cwd().statFile(path);
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.mode & 0o777)));
}

test "removeEntry deletes existing and is a no-op for missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "auth.json" });
    defer std.testing.allocator.free(path);

    var file = AuthFile.init(std.testing.allocator);
    defer file.deinit();
    try file.setApiKey("openai", "sk-keep");
    try file.setApiKey("anthropic", "sk-ant-drop");

    file.removeEntry("anthropic");
    try std.testing.expectEqual(@as(usize, 1), file.entries.count());

    // No-op for a name that was never present.
    file.removeEntry("groq");
    try std.testing.expectEqual(@as(usize, 1), file.entries.count());

    try saveAuthFile(path, file);

    var reloaded = try loadAuthFile(std.testing.allocator, path);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), reloaded.entries.count());
    try std.testing.expectEqualStrings("sk-keep", (try reloaded.getApiKey("openai")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try reloaded.getApiKey("anthropic"));
}

test "loadAuthFile round-trips an oauth entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_abs, "auth.json" });
    defer std.testing.allocator.free(path);

    {
        var file = AuthFile.init(std.testing.allocator);
        defer file.deinit();
        try file.setOAuth("openai-oauth", .{
            .id_token = "idt",
            .access_token = "at",
            .refresh_token = "rt",
            .account_id = "acc-123",
            .last_refresh = "2026-04-20T12:34:56Z",
        });
        try saveAuthFile(path, file);
    }

    var loaded = try loadAuthFile(std.testing.allocator, path);
    defer loaded.deinit();
    const got = try loaded.getOAuth("openai-oauth");
    try std.testing.expectEqualStrings("idt", got.id_token);
    try std.testing.expectEqualStrings("at", got.access_token);
    try std.testing.expectEqualStrings("rt", got.refresh_token);
    try std.testing.expectEqualStrings("acc-123", got.account_id);
    try std.testing.expectEqualStrings("2026-04-20T12:34:56Z", got.last_refresh);
}

test "loadAuthFile preserves api_key entries alongside oauth entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_abs, "auth.json" });
    defer std.testing.allocator.free(path);

    {
        var file = AuthFile.init(std.testing.allocator);
        defer file.deinit();
        try file.setApiKey("openai", "sk-openai");
        try file.setApiKey("anthropic", "sk-ant");
        try file.setOAuth("openai-oauth", .{
            .id_token = "idt",
            .access_token = "at",
            .refresh_token = "rt",
            .account_id = "acc",
            .last_refresh = "2026-04-20T00:00:00Z",
        });
        try saveAuthFile(path, file);
    }

    var loaded = try loadAuthFile(std.testing.allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("sk-openai", (try loaded.getApiKey("openai")).?);
    try std.testing.expectEqualStrings("sk-ant", (try loaded.getApiKey("anthropic")).?);
    const oauth = try loaded.getOAuth("openai-oauth");
    try std.testing.expectEqualStrings("idt", oauth.id_token);
}

test "upsertOAuth replaces an existing oauth entry without clobbering api_key entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_abs, "auth.json" });
    defer std.testing.allocator.free(path);

    {
        var file = AuthFile.init(std.testing.allocator);
        defer file.deinit();
        try file.setApiKey("openai", "sk-should-stay");
        try file.setOAuth("openai-oauth", .{
            .id_token = "old-id",
            .access_token = "old-at",
            .refresh_token = "old-rt",
            .account_id = "acc",
            .last_refresh = "2026-04-20T00:00:00Z",
        });
        try saveAuthFile(path, file);
    }

    try upsertOAuth(std.testing.allocator, path, "openai-oauth", .{
        .id_token = "new-id",
        .access_token = "new-at",
        .refresh_token = "new-rt",
        .account_id = "acc",
        .last_refresh = "2026-04-21T00:00:00Z",
    });

    var loaded = try loadAuthFile(std.testing.allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("sk-should-stay", (try loaded.getApiKey("openai")).?);
    const oauth = try loaded.getOAuth("openai-oauth");
    try std.testing.expectEqualStrings("new-id", oauth.id_token);
    try std.testing.expectEqualStrings("new-at", oauth.access_token);
}

test "upsertOAuth serializes concurrent callers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_abs, "auth.json" });
    defer std.testing.allocator.free(path);

    // Seed the file with an api_key so we can also assert it survives both
    // concurrent writers. Without a lock, the second writer's load misses
    // one of the oauth inserts because it started from the same on-disk
    // snapshot as the first writer.
    {
        var file = AuthFile.init(std.testing.allocator);
        defer file.deinit();
        try file.setApiKey("openai", "sk-initial");
        try saveAuthFile(path, file);
    }

    const Worker = struct {
        fn run(p: []const u8, name: []const u8) void {
            upsertOAuth(std.testing.allocator, p, name, .{
                .id_token = "id",
                .access_token = "at",
                .refresh_token = "rt",
                .account_id = "acc",
                .last_refresh = "2026-04-20T00:00:00Z",
            }) catch |err| std.debug.panic("upsertOAuth failed: {}", .{err});
        }
    };

    const t1 = try std.Thread.spawn(.{}, Worker.run, .{ path, "openai-oauth-1" });
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{ path, "openai-oauth-2" });
    t1.join();
    t2.join();

    var loaded = try loadAuthFile(std.testing.allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("sk-initial", (try loaded.getApiKey("openai")).?);
    _ = try loaded.getOAuth("openai-oauth-1");
    _ = try loaded.getOAuth("openai-oauth-2");
}

test {
    @import("std").testing.refAllDecls(@This());
}

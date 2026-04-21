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

const oauth = @import("oauth.zig");

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
    // first guarantees a fresh 0o600 file. Combined with the rename-to-path
    // below, every save re-asserts 0o600 even when auth.json pre-exists with
    // laxer permissions (addressing the same concern as the POSIX fchmod
    // approach from wip/chatgpt-oauth 65a25e4).
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

// -- Unified resolve entry point ------------------------------------------

/// Result of `resolveCredential`. Every byte payload is owned by the caller
/// and must be released through `deinit`. Two variants mirror `Credential`
/// but carry only the fields downstream code actually needs when placing a
/// request: provider code doesn't look at `refresh_token` or `last_refresh`.
pub const Resolved = union(enum) {
    api_key: []const u8,
    oauth: struct {
        access_token: []const u8,
        account_id: []const u8,
    },

    /// Release every byte owned by this result.
    pub fn deinit(self: Resolved, alloc: Allocator) void {
        switch (self) {
            .api_key => |k| alloc.free(k),
            .oauth => |o| {
                alloc.free(o.access_token);
                alloc.free(o.account_id);
            },
        }
    }
};

/// Number of seconds before `exp` at which a proactive refresh kicks in.
/// Codex refreshes reactively on 401. Zag refreshes proactively so the
/// agent loop never sees a 401 (which it treats as a hard turn abort).
const refresh_margin_seconds: i64 = 5 * 60;

/// Well-known Codex OIDC token endpoint. Override via `ResolveOptions` in
/// tests that point at a local mock server.
const default_token_url: []const u8 = "https://auth.openai.com/oauth/token";

/// Codex public OAuth client id. Mirrors the value in `src/oauth.zig`
/// callers; kept local here so the resolver has no dependency on login-flow
/// knobs.
const default_client_id: []const u8 = "app_EMoamEEZ73f0CkXaXp7hrann";

/// Injection points for `resolveCredential`. Defaults hit the real Codex
/// IdP and wall-clock time; tests supply a local URL and a frozen clock.
pub const ResolveOptions = struct {
    /// Token endpoint for the refresh POST. Defaults to the Codex IdP.
    token_url: []const u8 = default_token_url,
    /// OAuth client id sent with the refresh request.
    client_id: []const u8 = default_client_id,
    /// Unix-seconds clock. Tests override to control proactive-refresh
    /// behaviour without sleeping.
    now_fn: *const fn () i64 = defaultNow,
};

fn defaultNow() i64 {
    return std.time.timestamp();
}

/// Unified credential entry point. Loads `auth.json`, looks up
/// `provider_name`, and returns usable bytes:
///
/// - `api_key` entries: duped and returned directly.
/// - `oauth` entries: if the access token's `exp` is more than
///   `refresh_margin_seconds` in the future, the current token is returned.
///   Otherwise `oauth.refreshAccessToken` is called and the result is
///   persisted via `upsertOAuth` before the new token is returned.
///
/// Errors:
/// - `error.NotLoggedIn` — no entry for `provider_name`.
/// - `error.LoginExpired` — refresh endpoint rejected the refresh token
///   (invalid_grant family). Caller should prompt `zag --login=<provider>`.
/// - Any other error from the underlying load/refresh/save propagates.
///
/// Thread safety: the load is lock-free; `upsertOAuth` takes the sidecar
/// file lock internally, so concurrent resolvers serialize writes but race
/// reads (worst case: one extra refresh round-trip).
pub fn resolveCredential(
    alloc: Allocator,
    auth_path: []const u8,
    provider_name: []const u8,
    opts: ResolveOptions,
) !Resolved {
    var file = try loadAuthFile(alloc, auth_path);
    defer file.deinit();

    const cred = file.entries.get(provider_name) orelse return error.NotLoggedIn;

    switch (cred) {
        .api_key => |k| {
            const dup = try alloc.dupe(u8, k);
            return .{ .api_key = dup };
        },
        .oauth => |o| {
            const now = opts.now_fn();
            // If the JWT is malformed, treat it as already-expired so the
            // refresh path fires. A stale token on disk shouldn't trap the
            // user in a permanent 401.
            const exp = oauth.extractExp(o.access_token) catch now;
            if (exp > now + refresh_margin_seconds) {
                const at_dup = try alloc.dupe(u8, o.access_token);
                errdefer alloc.free(at_dup);
                const acc_dup = try alloc.dupe(u8, o.account_id);
                return .{ .oauth = .{ .access_token = at_dup, .account_id = acc_dup } };
            }

            // Need to refresh. Copy the old refresh_token/id_token/account_id
            // into locals first so we can free the AuthFile before the
            // network call — `upsertOAuth` will re-load auth.json under the
            // lock and we don't want to double-hold the map.
            const old_rt = try alloc.dupe(u8, o.refresh_token);
            defer alloc.free(old_rt);
            const old_at = try alloc.dupe(u8, o.access_token);
            defer alloc.free(old_at);
            const old_id = try alloc.dupe(u8, o.id_token);
            defer alloc.free(old_id);
            const old_acc = try alloc.dupe(u8, o.account_id);
            defer alloc.free(old_acc);

            file.deinit();
            // Tombstone so the outer `defer file.deinit()` is a no-op.
            file = AuthFile.init(alloc);

            const refreshed = try oauth.refreshAccessToken(alloc, .{
                .token_url = opts.token_url,
                .refresh_token = old_rt,
                .client_id = opts.client_id,
            });
            defer refreshed.deinit(alloc);

            // The refresh response may omit id_token / refresh_token; fall
            // back to the previous values so we never store an empty field.
            const new_id = if (refreshed.id_token.len > 0) refreshed.id_token else old_id;
            const new_at = if (refreshed.access_token.len > 0) refreshed.access_token else old_at;
            const new_rt = if (refreshed.refresh_token.len > 0) refreshed.refresh_token else old_rt;

            const new_account_id = if (refreshed.id_token.len > 0)
                try oauth.extractAccountId(alloc, refreshed.id_token)
            else
                try alloc.dupe(u8, old_acc);
            defer alloc.free(new_account_id);

            const last_refresh_iso = try formatIsoNow(alloc, opts.now_fn());
            defer alloc.free(last_refresh_iso);

            try upsertOAuth(alloc, auth_path, provider_name, .{
                .id_token = new_id,
                .access_token = new_at,
                .refresh_token = new_rt,
                .account_id = new_account_id,
                .last_refresh = last_refresh_iso,
            });

            const at_dup = try alloc.dupe(u8, new_at);
            errdefer alloc.free(at_dup);
            const acc_dup = try alloc.dupe(u8, new_account_id);
            return .{ .oauth = .{ .access_token = at_dup, .account_id = acc_dup } };
        },
    }
}

/// Format `unix_seconds` as ISO-8601 UTC (`YYYY-MM-DDTHH:MM:SSZ`). Used for
/// the `last_refresh` bookkeeping field.
fn formatIsoNow(alloc: Allocator, unix_seconds: i64) ![]const u8 {
    const secs: u64 = if (unix_seconds < 0) 0 else @intCast(unix_seconds);
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const ed = es.getEpochDay();
    const ym = ed.calculateYearDay();
    const md = ym.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        ym.year,
        md.month.numeric(),
        @as(u16, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
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

test "saveAuthFile re-applies 0o600 when overwriting a file with loose mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "auth.json" });
    defer std.testing.allocator.free(path);

    // Pre-create the file with a world-readable mode, as if the user chmod'd
    // it or restored from a tarball that stripped the original 0o600.
    {
        const pre = try std.fs.cwd().createFile(path, .{ .mode = 0o644, .truncate = true });
        defer pre.close();
        try std.posix.fchmod(pre.handle, 0o644);
    }

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
    const entry = try loaded.getOAuth("openai-oauth");
    try std.testing.expectEqualStrings("idt", entry.id_token);
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
    const entry = try loaded.getOAuth("openai-oauth");
    try std.testing.expectEqualStrings("new-id", entry.id_token);
    try std.testing.expectEqualStrings("new-at", entry.access_token);
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

// -- resolveCredential tests ----------------------------------------------
//
// Shared helpers: build a tiny JWT whose payload is an arbitrary object,
// and run a one-shot mock token endpoint on a random loopback port so each
// test can control the refresh response.

fn encodeJwtWithPayload(alloc: Allocator, payload: []const u8) ![]const u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const header_buf = try alloc.alloc(u8, enc.calcSize(header.len));
    defer alloc.free(header_buf);
    const header_b64 = enc.encode(header_buf, header);

    const payload_buf = try alloc.alloc(u8, enc.calcSize(payload.len));
    defer alloc.free(payload_buf);
    const payload_b64 = enc.encode(payload_buf, payload);

    return std.fmt.allocPrint(alloc, "{s}.{s}.sig", .{ header_b64, payload_b64 });
}

fn accessTokenWithExp(alloc: Allocator, exp: i64) ![]const u8 {
    const payload = try std.fmt.allocPrint(alloc, "{{\"exp\":{d}}}", .{exp});
    defer alloc.free(payload);
    return encodeJwtWithPayload(alloc, payload);
}

fn idTokenWithAccount(alloc: Allocator, account_id: []const u8) ![]const u8 {
    const payload = try std.fmt.allocPrint(
        alloc,
        "{{\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"{s}\"}}}}",
        .{account_id},
    );
    defer alloc.free(payload);
    return encodeJwtWithPayload(alloc, payload);
}

test "resolveCredential returns api_key verbatim" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_abs, "auth.json" });
    defer std.testing.allocator.free(path);

    {
        var file = AuthFile.init(std.testing.allocator);
        defer file.deinit();
        try file.setApiKey("anthropic", "sk-ant-verbatim");
        try saveAuthFile(path, file);
    }

    const got = try resolveCredential(std.testing.allocator, path, "anthropic", .{});
    defer got.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("sk-ant-verbatim", got.api_key);
}

test "resolveCredential returns error.NotLoggedIn when entry missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_abs, "auth.json" });
    defer std.testing.allocator.free(path);

    // No auth.json at all — loader returns empty map, lookup fails.
    try std.testing.expectError(
        error.NotLoggedIn,
        resolveCredential(std.testing.allocator, path, "missing", .{}),
    );
}

test "resolveCredential returns current oauth tokens when well before expiry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_abs, "auth.json" });
    defer std.testing.allocator.free(path);

    // Frozen clock at an arbitrary epoch; access token expires one hour later.
    const frozen_now: i64 = 1_700_000_000;
    const access_token = try accessTokenWithExp(std.testing.allocator, frozen_now + 3600);
    defer std.testing.allocator.free(access_token);

    {
        var file = AuthFile.init(std.testing.allocator);
        defer file.deinit();
        try file.setOAuth("openai-oauth", .{
            .id_token = "idt",
            .access_token = access_token,
            .refresh_token = "rt",
            .account_id = "acc-fresh",
            .last_refresh = "2026-04-20T00:00:00Z",
        });
        try saveAuthFile(path, file);
    }

    const FrozenClock = struct {
        fn now() i64 {
            return 1_700_000_000;
        }
    };

    // Pointing token_url at an unreachable loopback port would panic the
    // test if the refresh path were taken — we expect it not to be.
    const got = try resolveCredential(std.testing.allocator, path, "openai-oauth", .{
        .token_url = "http://127.0.0.1:1/should-not-be-hit",
        .now_fn = FrozenClock.now,
    });
    defer got.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(access_token, got.oauth.access_token);
    try std.testing.expectEqualStrings("acc-fresh", got.oauth.account_id);
}

test "resolveCredential refreshes when within 5 minutes of expiry" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    // Mock IdP returns a fresh id_token whose account claim is acc-new, a
    // new access_token whose exp is well in the future, and a rotated
    // refresh_token.
    const frozen_now: i64 = 1_700_000_000;
    const new_access = try accessTokenWithExp(std.testing.allocator, frozen_now + 3600);
    defer std.testing.allocator.free(new_access);
    const new_id = try idTokenWithAccount(std.testing.allocator, "acc-new");
    defer std.testing.allocator.free(new_id);

    // Body assembled at runtime because the JWT lengths vary with base64
    // padding. Content-Length must match body.len exactly.
    const body = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"id_token\":\"{s}\",\"access_token\":\"{s}\",\"refresh_token\":\"NEW_RT\"}}",
        .{ new_id, new_access },
    );
    defer std.testing.allocator.free(body);
    const response = try std.fmt.allocPrint(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer std.testing.allocator.free(response);

    const ServerCtx = struct {
        fn run(srv: *std.net.Server, resp: []const u8) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            var buf: [4096]u8 = undefined;
            _ = conn.stream.read(&buf) catch {};
            _ = conn.stream.writeAll(resp) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, ServerCtx.run, .{ &server, response });
    defer t.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/oauth/token", .{port});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_abs, "auth.json" });
    defer std.testing.allocator.free(path);

    // Stale access token: expires two minutes from now (well inside the
    // 5-minute proactive-refresh margin).
    const stale_at = try accessTokenWithExp(std.testing.allocator, frozen_now + 120);
    defer std.testing.allocator.free(stale_at);

    {
        var file = AuthFile.init(std.testing.allocator);
        defer file.deinit();
        try file.setOAuth("openai-oauth", .{
            .id_token = "old-id",
            .access_token = stale_at,
            .refresh_token = "OLD_RT",
            .account_id = "acc-old",
            .last_refresh = "2026-04-20T00:00:00Z",
        });
        try saveAuthFile(path, file);
    }

    const FrozenClock = struct {
        fn now() i64 {
            return 1_700_000_000;
        }
    };

    const got = try resolveCredential(std.testing.allocator, path, "openai-oauth", .{
        .token_url = url,
        .now_fn = FrozenClock.now,
    });
    defer got.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(new_access, got.oauth.access_token);
    try std.testing.expectEqualStrings("acc-new", got.oauth.account_id);

    // auth.json must carry the rotated refresh token and the new id_token.
    var loaded = try loadAuthFile(std.testing.allocator, path);
    defer loaded.deinit();
    const persisted = try loaded.getOAuth("openai-oauth");
    try std.testing.expectEqualStrings(new_id, persisted.id_token);
    try std.testing.expectEqualStrings(new_access, persisted.access_token);
    try std.testing.expectEqualStrings("NEW_RT", persisted.refresh_token);
    try std.testing.expectEqualStrings("acc-new", persisted.account_id);
    // last_refresh was rewritten to a fresh ISO stamp (i.e. not the seeded value).
    try std.testing.expect(!std.mem.eql(u8, "2026-04-20T00:00:00Z", persisted.last_refresh));
}

test "resolveCredential refreshes when access token already expired" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const frozen_now: i64 = 1_700_000_000;
    const new_access = try accessTokenWithExp(std.testing.allocator, frozen_now + 3600);
    defer std.testing.allocator.free(new_access);
    const new_id = try idTokenWithAccount(std.testing.allocator, "acc-new");
    defer std.testing.allocator.free(new_id);

    const body = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"id_token\":\"{s}\",\"access_token\":\"{s}\",\"refresh_token\":\"NEW_RT\"}}",
        .{ new_id, new_access },
    );
    defer std.testing.allocator.free(body);
    const response = try std.fmt.allocPrint(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer std.testing.allocator.free(response);

    const ServerCtx = struct {
        fn run(srv: *std.net.Server, resp: []const u8) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            var buf: [4096]u8 = undefined;
            _ = conn.stream.read(&buf) catch {};
            _ = conn.stream.writeAll(resp) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, ServerCtx.run, .{ &server, response });
    defer t.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/oauth/token", .{port});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_abs, "auth.json" });
    defer std.testing.allocator.free(path);

    // Access token expired an hour ago.
    const expired_at = try accessTokenWithExp(std.testing.allocator, frozen_now - 3600);
    defer std.testing.allocator.free(expired_at);

    {
        var file = AuthFile.init(std.testing.allocator);
        defer file.deinit();
        try file.setOAuth("openai-oauth", .{
            .id_token = "old-id",
            .access_token = expired_at,
            .refresh_token = "OLD_RT",
            .account_id = "acc-old",
            .last_refresh = "2026-04-20T00:00:00Z",
        });
        try saveAuthFile(path, file);
    }

    const FrozenClock = struct {
        fn now() i64 {
            return 1_700_000_000;
        }
    };

    const got = try resolveCredential(std.testing.allocator, path, "openai-oauth", .{
        .token_url = url,
        .now_fn = FrozenClock.now,
    });
    defer got.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(new_access, got.oauth.access_token);
    try std.testing.expectEqualStrings("acc-new", got.oauth.account_id);
}

test "resolveCredential maps LoginExpired from refresh endpoint" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const ServerCtx = struct {
        fn run(srv: *std.net.Server) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            var buf: [4096]u8 = undefined;
            _ = conn.stream.read(&buf) catch {};
            const resp =
                "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n" ++
                "Content-Length: 69\r\nConnection: close\r\n\r\n" ++
                "{\"error\":\"invalid_grant\",\"error_description\":\"refresh token expired\"}";
            _ = conn.stream.writeAll(resp) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, ServerCtx.run, .{&server});
    defer t.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/oauth/token", .{port});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_abs, "auth.json" });
    defer std.testing.allocator.free(path);

    const frozen_now: i64 = 1_700_000_000;
    const expired_at = try accessTokenWithExp(std.testing.allocator, frozen_now - 1);
    defer std.testing.allocator.free(expired_at);

    {
        var file = AuthFile.init(std.testing.allocator);
        defer file.deinit();
        try file.setOAuth("openai-oauth", .{
            .id_token = "idt",
            .access_token = expired_at,
            .refresh_token = "rt",
            .account_id = "acc",
            .last_refresh = "2026-04-20T00:00:00Z",
        });
        try saveAuthFile(path, file);
    }

    const FrozenClock = struct {
        fn now() i64 {
            return 1_700_000_000;
        }
    };

    try std.testing.expectError(error.LoginExpired, resolveCredential(
        std.testing.allocator,
        path,
        "openai-oauth",
        .{ .token_url = url, .now_fn = FrozenClock.now },
    ));
}

test {
    @import("std").testing.refAllDecls(@This());
}

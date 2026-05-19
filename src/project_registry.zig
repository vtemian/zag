//! Global registry of cwds where zag sessions have ever been opened.
//!
//! Lives at `<config_dir>/projects.json`. The sessions sidebar reads this
//! to aggregate sessions across every project Vlad has ever launched zag
//! in. Writes are atomic (temp + rename) so a mid-write crash can never
//! leave a partially-written registry on disk; malformed file content is
//! treated as an empty registry and overwritten on the next save.
//!
//! On-disk shape:
//! ```json
//! {
//!   "projects": [
//!     { "path": "/Users/x/projects/zag", "last_seen_ms": 1747641600000 }
//!   ]
//! }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

const log = std.log.scoped(.project_registry);

const ProjectRegistry = @This();

/// A single project entry. `path` is owned by the enclosing registry's
/// allocator when stored in `projects`; `listProjects` returns a copy
/// where each `path` is owned by the caller.
pub const Project = struct {
    /// Absolute path of a cwd where zag has been launched.
    path: []const u8,
    /// Wall-clock milliseconds at the most recent launch from this cwd.
    last_seen_ms: i64,
};

/// Allocator used for every owned slice in the registry.
allocator: Allocator,
/// Owned copy of the config directory path. Freed by `deinit`.
config_dir: []const u8,
/// Owned copy of `<config_dir>/projects.json`. Freed by `deinit`.
file_path: []const u8,
/// In-memory project list. Each item's `path` is owned by `allocator`.
projects: std.ArrayList(Project),

/// Open the registry at `<config_dir>/projects.json`. Creates the parent
/// directory if missing. A missing file is treated as an empty registry;
/// malformed content is logged and recovered to empty so a corrupt file
/// can't trap the sidebar in a permanent error state.
pub fn init(allocator: Allocator, config_dir: []const u8) !ProjectRegistry {
    const dir_owned = try allocator.dupe(u8, config_dir);
    errdefer allocator.free(dir_owned);

    std.fs.cwd().makePath(dir_owned) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const file_path = try std.fs.path.join(allocator, &.{ dir_owned, "projects.json" });
    errdefer allocator.free(file_path);

    var self: ProjectRegistry = .{
        .allocator = allocator,
        .config_dir = dir_owned,
        .file_path = file_path,
        .projects = .empty,
    };
    errdefer self.freeProjects();

    self.loadFromDisk() catch |err| {
        log.warn("could not load registry at '{s}': {s} (treating as empty)", .{ file_path, @errorName(err) });
        self.freeProjects();
    };
    return self;
}

/// Release every owned slice and the backing array.
pub fn deinit(self: *ProjectRegistry) void {
    self.freeProjects();
    self.allocator.free(self.file_path);
    self.allocator.free(self.config_dir);
}

fn freeProjects(self: *ProjectRegistry) void {
    for (self.projects.items) |p| self.allocator.free(p.path);
    self.projects.clearRetainingCapacity();
    self.projects.deinit(self.allocator);
    self.projects = .empty;
}

/// Insert or bump a project entry, then persist atomically. `now_ms`
/// only overwrites a stored `last_seen_ms` if it is greater, so an
/// out-of-order clock can't move a project backwards in the sort.
pub fn register(self: *ProjectRegistry, path: []const u8, now_ms: i64) !void {
    for (self.projects.items) |*p| {
        if (std.mem.eql(u8, p.path, path)) {
            if (now_ms > p.last_seen_ms) p.last_seen_ms = now_ms;
            return self.saveAtomic();
        }
    }
    const dup = try self.allocator.dupe(u8, path);
    errdefer self.allocator.free(dup);
    try self.projects.append(self.allocator, .{ .path = dup, .last_seen_ms = now_ms });
    try self.saveAtomic();
}

/// Return a caller-owned slice of projects sorted most-recent-first.
/// Caller frees each `.path` and the outer slice with the same allocator
/// passed to `init`.
pub fn listProjects(self: *const ProjectRegistry) ![]Project {
    const out = try self.allocator.alloc(Project, self.projects.items.len);
    errdefer self.allocator.free(out);

    var filled: usize = 0;
    errdefer for (out[0..filled]) |p| self.allocator.free(p.path);

    for (self.projects.items, 0..) |p, i| {
        out[i] = .{
            .path = try self.allocator.dupe(u8, p.path),
            .last_seen_ms = p.last_seen_ms,
        };
        filled += 1;
    }
    std.mem.sort(Project, out, {}, struct {
        fn lessThan(_: void, a: Project, b: Project) bool {
            return a.last_seen_ms > b.last_seen_ms;
        }
    }.lessThan);
    return out;
}

/// Hard cap on the registry file size. A corrupt path can't slurp
/// unbounded memory into the parser.
const max_registry_bytes: usize = 1 * 1024 * 1024;

fn loadFromDisk(self: *ProjectRegistry) !void {
    const data = std.fs.cwd().readFileAlloc(self.allocator, self.file_path, max_registry_bytes) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer self.allocator.free(data);

    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return error.MalformedRegistry;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.MalformedRegistry,
    };
    const arr_value = root.get("projects") orelse return;
    const arr = switch (arr_value) {
        .array => |a| a,
        else => return error.MalformedRegistry,
    };
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const path_value = obj.get("path") orelse continue;
        const path_str = switch (path_value) {
            .string => |s| s,
            else => continue,
        };
        const ts_value = obj.get("last_seen_ms") orelse continue;
        const ts: i64 = switch (ts_value) {
            .integer => |i| i,
            else => continue,
        };
        const dup = try self.allocator.dupe(u8, path_str);
        errdefer self.allocator.free(dup);
        try self.projects.append(self.allocator, .{ .path = dup, .last_seen_ms = ts });
    }
}

fn saveAtomic(self: *ProjectRegistry) !void {
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{self.file_path}) catch
        return error.PathTooLong;

    const cwd = std.fs.cwd();

    // Belt-and-suspenders: a stale <path>.tmp from a prior crash would
    // otherwise inherit its old contents on createFile.truncate. Unlink
    // first so each save starts from a clean slate.
    cwd.deleteFile(tmp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    {
        const tmp_file = try cwd.createFile(tmp_path, .{ .truncate = true });
        defer tmp_file.close();
        var scratch: [256]u8 = undefined;
        var file_w = tmp_file.writer(&scratch);
        try writeRegistry(&file_w.interface, self.projects.items);
        try file_w.interface.flush();
        try tmp_file.sync();
    }

    try cwd.rename(tmp_path, self.file_path);
}

fn writeRegistry(w: *std.Io.Writer, items: []const Project) !void {
    try w.writeAll("{\n  \"projects\": [\n");
    for (items, 0..) |p, i| {
        try w.writeAll("    {\"path\": ");
        try types.writeJsonString(w, p.path);
        try w.print(", \"last_seen_ms\": {d}}}", .{p.last_seen_ms});
        if (i + 1 < items.len) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("  ]\n}\n");
}

// -- Tests -----------------------------------------------------------------

test "register dedupes and bumps last_seen_ms" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var reg = try ProjectRegistry.init(std.testing.allocator, tmp_path);
    defer reg.deinit();

    try reg.register("/projects/a", 1000);
    try reg.register("/projects/b", 2000);
    // Dedupes path /projects/a, bumps its last_seen_ms to 3000.
    try reg.register("/projects/a", 3000);

    const list = try reg.listProjects();
    defer {
        for (list) |p| std.testing.allocator.free(p.path);
        std.testing.allocator.free(list);
    }
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("/projects/a", list[0].path);
    try std.testing.expectEqual(@as(i64, 3000), list[0].last_seen_ms);
    try std.testing.expectEqualStrings("/projects/b", list[1].path);
    try std.testing.expectEqual(@as(i64, 2000), list[1].last_seen_ms);
}

test "register persists across reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    {
        var reg = try ProjectRegistry.init(std.testing.allocator, tmp_path);
        defer reg.deinit();
        try reg.register("/projects/a", 1000);
    }
    {
        var reg = try ProjectRegistry.init(std.testing.allocator, tmp_path);
        defer reg.deinit();
        const list = try reg.listProjects();
        defer {
            for (list) |p| std.testing.allocator.free(p.path);
            std.testing.allocator.free(list);
        }
        try std.testing.expectEqual(@as(usize, 1), list.len);
        try std.testing.expectEqualStrings("/projects/a", list[0].path);
        try std.testing.expectEqual(@as(i64, 1000), list[0].last_seen_ms);
    }
}

test "malformed registry file recovers to empty list" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    try tmp.dir.writeFile(.{
        .sub_path = "projects.json",
        .data = "{ not valid json",
    });

    var reg = try ProjectRegistry.init(std.testing.allocator, tmp_path);
    defer reg.deinit();

    const list = try reg.listProjects();
    defer std.testing.allocator.free(list);
    try std.testing.expectEqual(@as(usize, 0), list.len);

    // A subsequent register should overwrite the malformed file cleanly.
    try reg.register("/projects/x", 7000);
    const list2 = try reg.listProjects();
    defer {
        for (list2) |p| std.testing.allocator.free(p.path);
        std.testing.allocator.free(list2);
    }
    try std.testing.expectEqual(@as(usize, 1), list2.len);
    try std.testing.expectEqualStrings("/projects/x", list2[0].path);
}

test "listProjects sorts most-recent-first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var reg = try ProjectRegistry.init(std.testing.allocator, tmp_path);
    defer reg.deinit();

    // Insert out of order. listProjects must return them sorted by
    // last_seen_ms descending regardless of insertion order.
    try reg.register("/projects/oldest", 100);
    try reg.register("/projects/newest", 9000);
    try reg.register("/projects/middle", 5000);

    const list = try reg.listProjects();
    defer {
        for (list) |p| std.testing.allocator.free(p.path);
        std.testing.allocator.free(list);
    }
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("/projects/newest", list[0].path);
    try std.testing.expectEqualStrings("/projects/middle", list[1].path);
    try std.testing.expectEqualStrings("/projects/oldest", list[2].path);
}

test {
    @import("std").testing.refAllDecls(@This());
}

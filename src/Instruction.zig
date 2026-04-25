//! First-hit instruction file loader.
//!
//! On every turn the harness walks from cwd up to the worktree root looking
//! for a project-local instructions file. The first match wins. Files later
//! in `FILE_NAMES` are only consulted if earlier names are absent in that
//! same directory; the search never stacks results from multiple ancestors.
//!
//! Global instruction files attach separately via `systemPaths`, which only
//! returns paths that exist on disk so callers can hand the result straight
//! to a Lua layer without re-checking.
//!
//! Order matters: `AGENTS.md` is the canonical name used by other harnesses
//! (Codex, Cursor, etc.); `CLAUDE.md` is the Anthropic convention; `CONTEXT.md`
//! is the older zag convention. We probe in that order so AGENTS.md wins
//! across mixed repos.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const log = std.log.scoped(.instruction);

/// Hard cap on instruction file size. Prevents accidental ingestion of huge
/// generated files masquerading as docs. Files above this size are skipped
/// with a warning, as if absent.
pub const MAX_BYTES: usize = 64 * 1024;

/// Filenames probed in each directory, in priority order.
pub const FILE_NAMES = [_][]const u8{ "AGENTS.md", "CLAUDE.md", "CONTEXT.md" };

/// One found instruction file. `path` is absolute; both fields are owned by
/// the allocator passed to `findUp`. Free via `deinit`.
pub const Found = struct {
    path: []const u8,
    content: []const u8,

    pub fn deinit(self: Found, alloc: Allocator) void {
        alloc.free(self.path);
        alloc.free(self.content);
    }
};

/// Returns absolute paths to global instruction files that exist on disk:
///   - `<home>/.claude/CLAUDE.md`
///   - `<home>/.config/zag/AGENTS.md`
///
/// The returned slice and every string inside it are owned by `alloc`.
/// Free with `freeSystemPaths`.
pub fn systemPaths(home: []const u8, alloc: Allocator) ![]const []const u8 {
    const candidates = [_][]const []const u8{
        &.{ home, ".claude", "CLAUDE.md" },
        &.{ home, ".config", "zag", "AGENTS.md" },
    };

    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |p| alloc.free(p);
        paths.deinit(alloc);
    }

    for (candidates) |segments| {
        const path = try std.fs.path.join(alloc, segments);
        errdefer alloc.free(path);
        std.fs.accessAbsolute(path, .{}) catch {
            alloc.free(path);
            continue;
        };
        try paths.append(alloc, path);
    }

    return paths.toOwnedSlice(alloc);
}

/// Frees the slice returned by `systemPaths` and every path inside.
pub fn freeSystemPaths(paths: []const []const u8, alloc: Allocator) void {
    for (paths) |p| alloc.free(p);
    alloc.free(paths);
}

/// Walks from `cwd` up to `worktree` (inclusive) looking for the first
/// instruction file. Returns `null` if none of the candidates exist in any
/// ancestor between the two paths.
///
/// `cwd` and `worktree` must both be absolute. `worktree` must be a prefix
/// of `cwd` (after normalization); otherwise the walk halts at filesystem
/// root and returns `null`.
pub fn findUp(cwd: []const u8, worktree: []const u8, alloc: Allocator) !?Found {
    if (cwd.len == 0 or worktree.len == 0) return null;
    if (!std.fs.path.isAbsolute(cwd) or !std.fs.path.isAbsolute(worktree)) return null;

    const worktree_norm = trimTrailingSep(worktree);

    var current = trimTrailingSep(cwd);
    while (true) {
        if (try probeDir(current, alloc)) |found| return found;

        if (std.mem.eql(u8, current, worktree_norm)) break;

        const parent = std.fs.path.dirname(current) orelse break;
        if (parent.len == current.len) break; // root reached
        current = parent;
    }

    return null;
}

fn trimTrailingSep(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == std.fs.path.sep) end -= 1;
    return path[0..end];
}

fn probeDir(dir_abs: []const u8, alloc: Allocator) !?Found {
    for (FILE_NAMES) |name| {
        const path = try std.fs.path.join(alloc, &.{ dir_abs, name });
        errdefer alloc.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.IsDir, error.NotDir => {
                alloc.free(path);
                continue;
            },
            error.AccessDenied => {
                log.warn("permission denied reading {s}", .{path});
                alloc.free(path);
                continue;
            },
            else => {
                alloc.free(path);
                return err;
            },
        };
        defer file.close();

        const stat = file.stat() catch |err| {
            log.warn("stat {s} failed: {}", .{ path, err });
            alloc.free(path);
            continue;
        };
        if (stat.size > MAX_BYTES) {
            log.warn(
                "instruction file {s} exceeds {d}-byte cap (size={d}); skipping",
                .{ path, MAX_BYTES, stat.size },
            );
            alloc.free(path);
            continue;
        }

        const content = file.readToEndAlloc(alloc, MAX_BYTES) catch |err| switch (err) {
            error.OutOfMemory => {
                alloc.free(path);
                return err;
            },
            else => {
                log.warn("read {s} failed: {}", .{ path, err });
                alloc.free(path);
                continue;
            },
        };

        return .{ .path = path, .content = content };
    }
    return null;
}

// --- tests ---

fn writeFile(dir: std.fs.Dir, name: []const u8, body: []const u8) !void {
    var f = try dir.createFile(name, .{});
    defer f.close();
    try f.writeAll(body);
}

test "systemPaths returns only existing paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(home);

    // Neither file exists yet.
    {
        const paths = try systemPaths(home, testing.allocator);
        defer freeSystemPaths(paths, testing.allocator);
        try testing.expectEqual(@as(usize, 0), paths.len);
    }

    // Create only ~/.claude/CLAUDE.md.
    try tmp.dir.makePath(".claude");
    try writeFile(try tmp.dir.openDir(".claude", .{}), "CLAUDE.md", "global claude");
    {
        const paths = try systemPaths(home, testing.allocator);
        defer freeSystemPaths(paths, testing.allocator);
        try testing.expectEqual(@as(usize, 1), paths.len);
        try testing.expect(std.mem.endsWith(u8, paths[0], "/.claude/CLAUDE.md"));
    }

    // Add ~/.config/zag/AGENTS.md too; both should appear in declared order.
    try tmp.dir.makePath(".config/zag");
    try writeFile(try tmp.dir.openDir(".config/zag", .{}), "AGENTS.md", "global zag");
    {
        const paths = try systemPaths(home, testing.allocator);
        defer freeSystemPaths(paths, testing.allocator);
        try testing.expectEqual(@as(usize, 2), paths.len);
        try testing.expect(std.mem.endsWith(u8, paths[0], "/.claude/CLAUDE.md"));
        try testing.expect(std.mem.endsWith(u8, paths[1], "/.config/zag/AGENTS.md"));
    }
}

test "findUp returns null when nothing is present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    const result = try findUp(root, root, testing.allocator);
    try testing.expect(result == null);
}

test "findUp finds AGENTS.md in cwd" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "AGENTS.md", "hello agents");
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    const result = (try findUp(root, root, testing.allocator)).?;
    defer result.deinit(testing.allocator);
    try testing.expect(std.mem.endsWith(u8, result.path, "AGENTS.md"));
    try testing.expectEqualStrings("hello agents", result.content);
}

test "findUp prefers AGENTS.md over CLAUDE.md in same dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "CLAUDE.md", "claude wins");
    try writeFile(tmp.dir, "AGENTS.md", "agents wins");
    try writeFile(tmp.dir, "CONTEXT.md", "context wins");
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    const result = (try findUp(root, root, testing.allocator)).?;
    defer result.deinit(testing.allocator);
    try testing.expect(std.mem.endsWith(u8, result.path, "AGENTS.md"));
    try testing.expectEqualStrings("agents wins", result.content);
}

test "findUp falls back to CLAUDE.md when AGENTS.md absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "CLAUDE.md", "claude only");
    try writeFile(tmp.dir, "CONTEXT.md", "context fallback");
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    const result = (try findUp(root, root, testing.allocator)).?;
    defer result.deinit(testing.allocator);
    try testing.expect(std.mem.endsWith(u8, result.path, "CLAUDE.md"));
    try testing.expectEqualStrings("claude only", result.content);
}

test "findUp falls back to CONTEXT.md when AGENTS.md and CLAUDE.md absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "CONTEXT.md", "context only");
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    const result = (try findUp(root, root, testing.allocator)).?;
    defer result.deinit(testing.allocator);
    try testing.expect(std.mem.endsWith(u8, result.path, "CONTEXT.md"));
    try testing.expectEqualStrings("context only", result.content);
}

test "findUp walks up from nested cwd to ancestor with AGENTS.md" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "AGENTS.md", "ancestor wins");
    try tmp.dir.makePath("a/b/c");
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    const cwd = try std.fs.path.join(testing.allocator, &.{ root, "a", "b", "c" });
    defer testing.allocator.free(cwd);

    const result = (try findUp(cwd, root, testing.allocator)).?;
    defer result.deinit(testing.allocator);
    try testing.expect(std.mem.endsWith(u8, result.path, "AGENTS.md"));
    try testing.expectEqualStrings("ancestor wins", result.content);
}

test "findUp first-hit: nested AGENTS.md beats ancestor AGENTS.md" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "AGENTS.md", "ancestor");
    try tmp.dir.makePath("nested");
    try writeFile(try tmp.dir.openDir("nested", .{}), "AGENTS.md", "nested");
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    const cwd = try std.fs.path.join(testing.allocator, &.{ root, "nested" });
    defer testing.allocator.free(cwd);

    const result = (try findUp(cwd, root, testing.allocator)).?;
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("nested", result.content);
}

test "findUp stops at worktree boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // AGENTS.md sits at tmp root, but worktree is "inner".
    try writeFile(tmp.dir, "AGENTS.md", "outside worktree");
    try tmp.dir.makePath("inner/sub");
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    const worktree = try std.fs.path.join(testing.allocator, &.{ root, "inner" });
    defer testing.allocator.free(worktree);
    const cwd = try std.fs.path.join(testing.allocator, &.{ root, "inner", "sub" });
    defer testing.allocator.free(cwd);

    const result = try findUp(cwd, worktree, testing.allocator);
    try testing.expect(result == null);
}

test "findUp skips files larger than MAX_BYTES" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write an oversized AGENTS.md plus a small CLAUDE.md fallback. The walk
    // should treat AGENTS.md as if absent and surface CLAUDE.md instead.
    {
        var f = try tmp.dir.createFile("AGENTS.md", .{});
        defer f.close();
        const chunk = [_]u8{'x'} ** 4096;
        var written: usize = 0;
        while (written < MAX_BYTES + 1) : (written += chunk.len) {
            try f.writeAll(&chunk);
        }
    }
    try writeFile(tmp.dir, "CLAUDE.md", "fallback");

    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    const result = (try findUp(root, root, testing.allocator)).?;
    defer result.deinit(testing.allocator);
    try testing.expect(std.mem.endsWith(u8, result.path, "CLAUDE.md"));
    try testing.expectEqualStrings("fallback", result.content);
}

test "findUp rejects relative paths" {
    const r1 = try findUp("relative/cwd", "/abs/wt", testing.allocator);
    try testing.expect(r1 == null);
    const r2 = try findUp("/abs/cwd", "relative/wt", testing.allocator);
    try testing.expect(r2 == null);
}

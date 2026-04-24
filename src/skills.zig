//! Filesystem-backed skill registry.
//!
//! A skill is a directory containing `SKILL.md`, a markdown document whose
//! frontmatter declares `name`, `description`, and optional metadata
//! (`allowed-tools`, `license`). The registry walks a fixed set of roots,
//! parses each skill's frontmatter, and exposes the collected manifests to
//! the agent loop via `catalog()`, which renders an `<available_skills>`
//! XML block for injection into the system prompt.
//!
//! Roots are walked in precedence order:
//!
//!   1. `<project>/.zag/skills/`
//!   2. `<project>/.agents/skills/`
//!   3. `<config_home>/skills/`
//!
//! Entries discovered in a higher-priority root shadow same-named entries
//! in a lower-priority root. Invalid names (`[a-z0-9-]+`, 1-64 chars, no
//! leading/trailing hyphen, no double hyphen) are rejected with a warn
//! log and the skill is skipped. Missing required frontmatter fields are
//! also warn-and-skip. Missing directories are ignored silently.
//!
//! Rejections log at `warn` rather than `err` so a malformed SKILL.md on
//! disk does not trip the Zig test runner's error-log failure detector
//! for downstream tests that discover skills.
//!
//! Ownership: every string on a `Skill` is heap-allocated from the
//! allocator passed to `discover`. `deinit` frees all strings and the
//! backing array.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const frontmatter = @import("frontmatter.zig");

const log = std.log.scoped(.skills);

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    /// Absolute path to the skill's `SKILL.md` file.
    path: []const u8,
    allowed_tools: ?[]const u8 = null,
    license: ?[]const u8 = null,

    fn deinit(self: *Skill, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.description);
        alloc.free(self.path);
        if (self.allowed_tools) |s| alloc.free(s);
        if (self.license) |s| alloc.free(s);
    }
};

pub const SkillRegistry = struct {
    skills: std.ArrayListUnmanaged(Skill) = .empty,

    pub fn deinit(self: *SkillRegistry, alloc: Allocator) void {
        for (self.skills.items) |*skill| skill.deinit(alloc);
        self.skills.deinit(alloc);
        self.* = .{};
    }

    /// Walk the configured roots and populate the registry with every
    /// valid skill found. `project_root` may be null for user-level
    /// operation (no project roots are walked). `config_home` is the
    /// `~/.config/zag` directory equivalent; its `skills/` subdirectory
    /// is walked last.
    pub fn discover(
        alloc: Allocator,
        config_home: []const u8,
        project_root: ?[]const u8,
    ) !SkillRegistry {
        var registry: SkillRegistry = .{};
        errdefer registry.deinit(alloc);

        if (project_root) |root| {
            try walkRoot(alloc, &registry, root, ".zag/skills");
            try walkRoot(alloc, &registry, root, ".agents/skills");
        }
        try walkRoot(alloc, &registry, config_home, "skills");

        return registry;
    }

    /// Emit an `<available_skills>` XML block listing every skill. When
    /// the registry is empty, nothing is written: callers can concatenate
    /// the output unconditionally.
    pub fn catalog(self: *const SkillRegistry, writer: anytype) !void {
        if (self.skills.items.len == 0) return;

        try writer.writeAll("<available_skills>\n");
        for (self.skills.items) |skill| {
            try writer.writeAll("  <skill name=\"");
            try writeXmlEscaped(writer, skill.name);
            try writer.writeAll("\" path=\"");
            try writeXmlEscaped(writer, skill.path);
            try writer.writeAll("\">");
            try writeXmlEscaped(writer, skill.description);
            try writer.writeAll("</skill>\n");
        }
        try writer.writeAll("</available_skills>\n");
    }
};

fn walkRoot(
    alloc: Allocator,
    registry: *SkillRegistry,
    root: []const u8,
    subpath: []const u8,
) !void {
    const root_abs = try std.fs.path.join(alloc, &.{ root, subpath });
    defer alloc.free(root_abs);

    var dir = std.fs.openDirAbsolute(root_abs, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        error.AccessDenied => {
            log.warn("permission denied walking skills root: {s}", .{root_abs});
            return;
        },
        else => {
            log.warn("failed to open skills root {s}: {}", .{ root_abs, err });
            return;
        },
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch |err| {
        log.warn("iterating {s} failed: {}", .{ root_abs, err });
        return;
    }) |entry| {
        if (entry.kind != .directory) continue;

        const md_relative = try std.fs.path.join(alloc, &.{ entry.name, "SKILL.md" });
        defer alloc.free(md_relative);
        dir.access(md_relative, .{}) catch continue;

        const md_path = try std.fs.path.join(alloc, &.{ root_abs, entry.name, "SKILL.md" });
        // Ownership transfers into the Skill on successful append; free
        // here otherwise.
        loadSkill(alloc, registry, md_path) catch |err| switch (err) {
            error.OutOfMemory => {
                alloc.free(md_path);
                return err;
            },
            error.Skipped => alloc.free(md_path),
        };
    }
}

const LoadError = Allocator.Error || error{Skipped};

/// Parse a SKILL.md, validate, and append to the registry. Takes ownership
/// of `md_path` only on successful append; callers must free it on
/// `error.Skipped`.
fn loadSkill(
    alloc: Allocator,
    registry: *SkillRegistry,
    md_path: []const u8,
) LoadError!void {
    const src = std.fs.cwd().readFileAlloc(alloc, md_path, 1 * 1024 * 1024) catch |err| {
        log.warn("reading {s} failed: {}", .{ md_path, err });
        return error.Skipped;
    };
    defer alloc.free(src);

    var fm = frontmatter.parse(alloc, src) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnterminatedFrontmatter => {
            log.warn("{s}: unterminated frontmatter", .{md_path});
            return error.Skipped;
        },
    };
    defer fm.deinit(alloc);

    const name_value = fm.fields.get("name") orelse {
        log.warn("{s}: missing required field 'name'", .{md_path});
        return error.Skipped;
    };
    const name_raw = switch (name_value) {
        .string => |s| s,
        .list => {
            log.warn("{s}: 'name' must be a scalar", .{md_path});
            return error.Skipped;
        },
    };
    if (!isValidSkillName(name_raw)) {
        log.warn("{s}: invalid skill name '{s}' (must match [a-z0-9-]+, 1-64 chars, no leading/trailing or double hyphen)", .{ md_path, name_raw });
        return error.Skipped;
    }

    const desc_value = fm.fields.get("description") orelse {
        log.warn("{s}: missing required field 'description'", .{md_path});
        return error.Skipped;
    };
    const desc_raw = switch (desc_value) {
        .string => |s| s,
        .list => {
            log.warn("{s}: 'description' must be a scalar", .{md_path});
            return error.Skipped;
        },
    };

    const allowed_raw: ?[]const u8 = if (fm.fields.get("allowed-tools")) |v|
        switch (v) {
            .string => |s| s,
            .list => null,
        }
    else
        null;

    const license_raw: ?[]const u8 = if (fm.fields.get("license")) |v|
        switch (v) {
            .string => |s| s,
            .list => null,
        }
    else
        null;

    // Collision handling: project (first-walked) wins over user.
    if (findExisting(registry, name_raw)) |existing| {
        log.warn("skill name collision '{s}': keeping {s}, shadowing {s}", .{ name_raw, existing.path, md_path });
        return error.Skipped;
    }

    const name_copy = try alloc.dupe(u8, name_raw);
    errdefer alloc.free(name_copy);
    const desc_copy = try alloc.dupe(u8, desc_raw);
    errdefer alloc.free(desc_copy);
    const allowed_copy: ?[]const u8 = if (allowed_raw) |s| try alloc.dupe(u8, s) else null;
    errdefer if (allowed_copy) |s| alloc.free(s);
    const license_copy: ?[]const u8 = if (license_raw) |s| try alloc.dupe(u8, s) else null;
    errdefer if (license_copy) |s| alloc.free(s);

    try registry.skills.append(alloc, .{
        .name = name_copy,
        .description = desc_copy,
        .path = md_path,
        .allowed_tools = allowed_copy,
        .license = license_copy,
    });
}

fn findExisting(registry: *const SkillRegistry, name: []const u8) ?*const Skill {
    for (registry.skills.items) |*skill| {
        if (std.mem.eql(u8, skill.name, name)) return skill;
    }
    return null;
}

fn isValidSkillName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (name[0] == '-' or name[name.len - 1] == '-') return false;

    var prev_hyphen = false;
    for (name) |c| {
        const is_lower = c >= 'a' and c <= 'z';
        const is_digit = c >= '0' and c <= '9';
        const is_hyphen = c == '-';
        if (!(is_lower or is_digit or is_hyphen)) return false;
        if (is_hyphen and prev_hyphen) return false;
        prev_hyphen = is_hyphen;
    }
    return true;
}

fn writeXmlEscaped(writer: anytype, raw: []const u8) !void {
    for (raw) |c| {
        switch (c) {
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(c),
        }
    }
}

// --- Tests ---

fn writeSkillFile(
    dir: std.fs.Dir,
    subdir: []const u8,
    frontmatter_body: []const u8,
) !void {
    try dir.makePath(subdir);
    var skill_dir = try dir.openDir(subdir, .{});
    defer skill_dir.close();
    try skill_dir.writeFile(.{ .sub_path = "SKILL.md", .data = frontmatter_body });
}

test "discover finds skills across project and user roots" {
    const alloc = testing.allocator;

    var project_tmp = testing.tmpDir(.{});
    defer project_tmp.cleanup();
    var home_tmp = testing.tmpDir(.{});
    defer home_tmp.cleanup();

    try writeSkillFile(
        project_tmp.dir,
        ".zag/skills/skill-a",
        "---\nname: skill-a\ndescription: First skill.\n---\nBody.\n",
    );
    try writeSkillFile(
        home_tmp.dir,
        "skills/skill-b",
        "---\nname: skill-b\ndescription: Second skill.\n---\nBody.\n",
    );

    const project_root = try project_tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(project_root);
    const home_root = try home_tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(home_root);

    var registry = try SkillRegistry.discover(alloc, home_root, project_root);
    defer registry.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), registry.skills.items.len);

    var saw_a = false;
    var saw_b = false;
    for (registry.skills.items) |skill| {
        if (std.mem.eql(u8, skill.name, "skill-a")) {
            saw_a = true;
            try testing.expectEqualStrings("First skill.", skill.description);
        } else if (std.mem.eql(u8, skill.name, "skill-b")) {
            saw_b = true;
            try testing.expectEqualStrings("Second skill.", skill.description);
        }
    }
    try testing.expect(saw_a);
    try testing.expect(saw_b);
}

test "project shadows user on name collision" {
    const alloc = testing.allocator;

    var project_tmp = testing.tmpDir(.{});
    defer project_tmp.cleanup();
    var home_tmp = testing.tmpDir(.{});
    defer home_tmp.cleanup();

    try writeSkillFile(
        project_tmp.dir,
        ".zag/skills/same",
        "---\nname: same\ndescription: Project version.\n---\n",
    );
    try writeSkillFile(
        home_tmp.dir,
        "skills/same",
        "---\nname: same\ndescription: User version.\n---\n",
    );

    const project_root = try project_tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(project_root);
    const home_root = try home_tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(home_root);

    var registry = try SkillRegistry.discover(alloc, home_root, project_root);
    defer registry.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), registry.skills.items.len);
    const skill = registry.skills.items[0];
    try testing.expectEqualStrings("same", skill.name);
    try testing.expectEqualStrings("Project version.", skill.description);
    try testing.expect(std.mem.indexOf(u8, skill.path, project_root) != null);
    try testing.expect(std.mem.indexOf(u8, skill.path, ".zag/skills/same") != null);
}

test "invalid names are rejected" {
    const alloc = testing.allocator;

    var home_tmp = testing.tmpDir(.{});
    defer home_tmp.cleanup();

    // Frontmatter declares the invalid name; the on-disk subdir name is
    // incidental but we mirror it for clarity.
    try writeSkillFile(
        home_tmp.dir,
        "skills/Bad_Name",
        "---\nname: Bad_Name\ndescription: Should be rejected.\n---\n",
    );

    const home_root = try home_tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(home_root);

    var registry = try SkillRegistry.discover(alloc, home_root, null);
    defer registry.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), registry.skills.items.len);
}

test "catalog emits well-formed XML with escaping" {
    const alloc = testing.allocator;

    var registry: SkillRegistry = .{};
    defer registry.deinit(alloc);

    const name = try alloc.dupe(u8, "roll-dice");
    const desc = try alloc.dupe(u8, "Roll a die < with & \"quotes\" >.");
    const path = try alloc.dupe(u8, "/abs/path/SKILL.md");
    try registry.skills.append(alloc, .{ .name = name, .description = desc, .path = path });

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try registry.catalog(fbs.writer());
    const out = fbs.getWritten();

    try testing.expect(std.mem.indexOf(u8, out, "<available_skills>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "</available_skills>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "name=\"roll-dice\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "path=\"/abs/path/SKILL.md\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "&lt;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "&amp;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "&quot;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "&gt;") != null);
    // Inside the description span, the raw special characters from the
    // source must not appear. `&` is exempt because it legitimately
    // introduces the escape entities themselves.
    const desc_start = std.mem.indexOf(u8, out, "\">").? + 2;
    const desc_end = std.mem.indexOf(u8, out, "</skill>").?;
    const desc_rendered = out[desc_start..desc_end];
    try testing.expect(std.mem.indexOfScalar(u8, desc_rendered, '<') == null);
    try testing.expect(std.mem.indexOfScalar(u8, desc_rendered, '>') == null);
    try testing.expect(std.mem.indexOfScalar(u8, desc_rendered, '"') == null);
    // Every `&` inside the span must begin a known entity.
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, desc_rendered, i, '&')) |pos| : (i = pos + 1) {
        const tail = desc_rendered[pos..];
        const is_entity = std.mem.startsWith(u8, tail, "&lt;") or
            std.mem.startsWith(u8, tail, "&gt;") or
            std.mem.startsWith(u8, tail, "&amp;") or
            std.mem.startsWith(u8, tail, "&quot;");
        try testing.expect(is_entity);
    }
}

test "catalog is empty when no skills" {
    const alloc = testing.allocator;

    var registry: SkillRegistry = .{};
    defer registry.deinit(alloc);

    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try registry.catalog(fbs.writer());
    try testing.expectEqual(@as(usize, 0), fbs.getWritten().len);
}

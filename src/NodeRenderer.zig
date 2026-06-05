//! NodeRenderer: converts buffer nodes to styled display lines.
//!
//! Provides default renderers for each node type and a registry that allows
//! overriding renderers per node type (for plugin support). Renderers produce
//! StyledLines: each line is a sequence of styled spans that the Compositor
//! maps to screen cells.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Conversation = @import("Conversation.zig");
const BufferRegistry = @import("BufferRegistry.zig");
const Gutter = @import("Gutter.zig");
const Theme = @import("Theme.zig");
const Node = Conversation.Node;
const NodeType = Conversation.NodeType;
const StyledSpan = Theme.StyledSpan;
const StyledLine = Theme.StyledLine;

const MarkdownParser = @import("MarkdownParser.zig");

const NodeRenderer = @This();

/// Static prefix strings attached to rendered lines. Shared across frames
/// and buffers because their bytes never change; span text is a borrowed
/// slice into these constants.
///
/// `indent_pad_max` is the worst-case indentation slice. `splitAndAppendIndented`
/// asserts its `indent_count` fits within this buffer so the slice access
/// is in-bounds.
const Prefixes = struct {
    const separator = "---";
    const indent_pad_max = " " ** 64;
    /// Placeholder for an image-backed tool_result. Inline image
    /// embedding in the conversation view is a Phase D concern; for now
    /// we emit a single styled line so the user knows a binary payload
    /// exists. Static-lifetime literal so the StyledSpan borrowed-text
    /// contract holds without allocation.
    const tool_result_image_placeholder = "[image]";
    /// Header / suffix tokens for the subagent_link placeholder line.
    /// The full line reads `[subagent: <name>] <status>`.
    const subagent_open = "[subagent: ";
    const subagent_close = "] ";
    const subagent_unnamed = "<unnamed>";

    /// Prefix for body lines under a rich tool-call block. Indents
    /// the body one column.
    const tool_body_indent = " ";
    const diff_add_marker = "+ ";
    const diff_remove_marker = "- ";
};

/// Body-line cap for tool-call blocks whose body is unbounded. `bash`
/// stdout and `read` file contents can be huge; truncate inline so
/// the transcript stays scannable, and let the user opt into the
/// full body via Ctrl-R (collapsed state) or by re-running the call.
const bash_inline_lines: usize = 6;
const read_inline_lines: usize = 6;

/// Status label for a subagent_link node. Resolves the parent
/// Conversation through the node's type-erased back-pointer and
/// inspects the child's tail node to derive the label:
///
///   * `ready`:   child has no nodes yet (spawn marker, no turn).
///   * `running`: child has nodes but the tail isn't an end-state.
///   * `done`:    child's tail is `assistant_text` (the agent's
///                final summary lands as a trailing text node).
///   * `failed`:  child's tail is `err`.
///   * `missing`: back-pointer absent or index out of bounds.
///
/// Threading policy: this runs on the UI thread during render. Child tree
/// writes also happen on the UI thread now — the orchestrator drains
/// registered child runners via `ChildRunnerRegistry` earlier in the same
/// tick, before render — so reading `items.len` and the tail's `node_type`
/// here is a same-thread read, not the cross-thread race it was when
/// `runChild` drained on the parent's agent thread. See the threading-policy
/// note on `Conversation.tree` for the broader rationale.
fn subagentStatus(node: *const Node) []const u8 {
    const parent_opaque = node.subagent_parent orelse return "missing";
    const parent: *const Conversation = @ptrCast(@alignCast(parent_opaque));
    if (node.subagent_index >= parent.subagents.items.len) return "missing";
    const child = parent.subagents.items[node.subagent_index];
    // Tail-check the child's tree (ready/running/done/failed); the
    // `missing` arm above is renderer-specific (the link node may outlive
    // its child slot during a stale render). `Conversation.subagentStatus`
    // is the shared source of truth, also read by `zag.pane.subagents`.
    return child.subagentStatus();
}

/// Pre-baked decimal digit strings for the most common collapsed-tool hint
/// counts. Static-lifetime entries satisfy the StyledSpan borrowed-text
/// contract; lookup is bounded by `digit_strings.len`.
const digit_strings: [1024][]const u8 = blk: {
    @setEvalBranchQuota(200000);
    var out: [1024][]const u8 = undefined;
    for (&out, 0..) |*slot, i| {
        slot.* = std.fmt.comptimePrint("{d}", .{i});
    }
    break :blk out;
};

/// Fallback for hidden-line counts that exceed `digit_strings.len`.
const digit_overflow_label = "many";

/// Function signature for a custom node renderer.
///
/// Appends one or more StyledLines to `lines`. The renderer must uphold
/// the StyledSpan borrowed-slice contract: span text bytes must outlive
/// the span (for example, by slicing the resolved node bytes or
/// returning a static string). The caller does not free span text.
///
/// Custom renderers receive an optional `*BufferRegistry` so they can
/// dereference `node.buffer_id` themselves (via `nodeBytes`); when the
/// node uses inline content the registry pointer is unused.
pub const RenderFn = *const fn (
    node: *const Node,
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    theme: *const Theme,
    registry: *const BufferRegistry,
) anyerror!void;

/// Resolve the byte slice for a node's textual content via the
/// registry-owned TextBuffer. Tool_call nodes carry no buffer (their
/// metadata sits on `custom_tag`); for them, this returns the
/// custom_tag slice. Returns an empty slice when the handle resolves
/// to anything other than a TextBuffer (a wiring bug, but the renderer
/// must remain total).
///
/// Caller borrows; the returned slice is valid until the underlying
/// storage mutates.
pub fn nodeBytes(node: *const Node, registry: *const BufferRegistry) []const u8 {
    if (node.buffer_id) |handle| {
        const tb = registry.asText(handle) catch return &.{};
        return tb.bytesView();
    }
    return node.custom_tag orelse &.{};
}

/// Bullet state for a tool_call node, driving the gutter bullet color.
/// `.running` when no tool_result child exists yet, `.err` when any
/// tool_result child is an error, else `.ok`.
pub const BulletState = enum { running, ok, err };

pub fn toolBulletState(node: *const Node) BulletState {
    var saw_result = false;
    for (node.children.items) |child| {
        if (child.node_type != .tool_result) continue;
        saw_result = true;
        if (child.tool_result_is_error) return .err;
    }
    return if (saw_result) .ok else .running;
}

/// Returns true when the node carries a `buffer_id` that resolves to an
/// ImageBuffer. Used by the tool_result render path to switch from text
/// rendering to a placeholder line. Returns false for inline-content
/// nodes, text-backed nodes, and stale handles; the renderer must stay
/// total in the face of a torn-down buffer.
fn isImageBacked(node: *const Node, registry: *const BufferRegistry) bool {
    const handle = node.buffer_id orelse return false;
    const entry = registry.resolve(handle) catch return false;
    return entry == .image;
}

/// Custom renderer overrides keyed by node type name.
overrides: std.StringHashMap(RenderFn),
/// Whether the overrides map has been initialized with an allocator.
has_overrides: bool,

/// Create a renderer with only the built-in defaults (no override map allocated).
pub fn initDefault() NodeRenderer {
    return .{
        .overrides = undefined,
        .has_overrides = false,
    };
}

/// Create a renderer with an allocated override map for registering custom renderers.
pub fn init(allocator: Allocator) NodeRenderer {
    return .{
        .overrides = std.StringHashMap(RenderFn).init(allocator),
        .has_overrides = true,
    };
}

/// Release the override map. Only needed if init() was called (not initDefault()).
pub fn deinit(self: *NodeRenderer) void {
    if (self.has_overrides) {
        self.overrides.deinit();
    }
}

/// Register a custom renderer for a node type name.
/// The name should match the `@tagName` of the NodeType enum.
pub fn register(self: *NodeRenderer, node_type_name: []const u8, render_fn: RenderFn) !void {
    if (!self.has_overrides) return error.NoOverrideMap;
    try self.overrides.put(node_type_name, render_fn);
}

/// Render a node into styled display lines. Checks for a custom override first,
/// then falls back to the built-in default renderer for the node's type.
///
/// `registry` is forwarded to the renderer so it can resolve
/// `node.buffer_id`-backed content. Pass null when the node tree
/// pre-dates the migration (test-only path).
pub fn render(
    self: *const NodeRenderer,
    node: *const Node,
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    theme: *const Theme,
    registry: *const BufferRegistry,
) !void {
    // Check for custom override
    if (self.has_overrides) {
        const type_name = @tagName(node.node_type);
        if (self.overrides.get(type_name)) |custom_fn| {
            return custom_fn(node, lines, allocator, theme, registry);
        }
    }

    // Built-in defaults
    try renderDefault(node, lines, allocator, theme, registry);
}

/// Number of body lines hidden under a collapsed `tool_call` node, counted as
/// `(newlines + 1)` over the first `tool_result` child's content. Returns 0
/// when the node is expanded, has no `tool_result` child, or the first child's
/// content is empty. Capped at the first child to keep this O(1) in node count.
fn hiddenToolResultLineCount(node: *const Node, registry: *const BufferRegistry) usize {
    if (!node.collapsed) return 0;
    if (node.node_type != .tool_call) return 0;
    for (node.children.items) |child| {
        if (child.node_type != .tool_result) continue;
        const content = nodeBytes(child, registry);
        if (content.len == 0) return 0;
        var count: usize = 1;
        for (content) |c| {
            if (c == '\n') count += 1;
        }
        // Match splitAndAppend: a trailing newline yields no extra segment.
        if (content[content.len - 1] == '\n') count -= 1;
        return count;
    }
    return 0;
}

/// Return the number of display lines a node produces (without allocating them).
pub fn lineCountForNode(_: *const NodeRenderer, node: *const Node, registry: *const BufferRegistry) usize {
    return switch (node.node_type) {
        .separator => 1,
        .err, .thinking_redacted => 1,
        .tool_call => blk: {
            if (richToolCallLineCount(node, registry)) |n| break :blk n;
            // Collapsed tool_call with a non-empty tool_result child gets a
            // hint line under the [tool] header announcing the hidden body.
            if (hiddenToolResultLineCount(node, registry) > 0) break :blk 2;
            break :blk 1;
        },
        .thinking => blk: {
            // Collapsed thinking nodes render as a single header line; the
            // body is hidden until the user hits Ctrl-R.
            if (node.collapsed) break :blk 1;
            const content = nodeBytes(node, registry);
            // Expanded form is a header line plus one line per body line.
            if (content.len == 0) break :blk 1;
            var count: usize = 2; // header + first body line
            for (content) |c| {
                if (c == '\n') count += 1;
            }
            if (content[content.len - 1] == '\n') count -= 1;
            break :blk count;
        },
        .tool_result => blk: {
            // Image-backed tool_result renders as a single placeholder line
            // ("[image WxH]"); inline image embedding in the conversation
            // view is a Phase D-or-later concern.
            if (isImageBacked(node, registry)) break :blk 1;
            const content = nodeBytes(node, registry);
            if (content.len == 0) break :blk 1;
            var count: usize = 1;
            for (content) |c| {
                if (c == '\n') count += 1;
            }
            if (content[content.len - 1] == '\n') count -= 1;
            break :blk count;
        },
        .user_message, .assistant_text, .status, .custom => blk: {
            // Count newlines to determine line count.
            // splitAndAppend skips the trailing empty segment after a final '\n',
            // so we subtract 1 when content ends with a newline.
            const content = nodeBytes(node, registry);
            if (content.len == 0) break :blk 1;
            var count: usize = 1;
            for (content) |c| {
                if (c == '\n') count += 1;
            }
            if (content[content.len - 1] == '\n') count -= 1;
            break :blk count;
        },
        .subagent_link => 1,
    };
}

/// Create a StyledLine with two spans. Span text is borrowed: caller
/// guarantees `text1` and `text2` outlive the returned line.
fn twoSpanLine(
    allocator: Allocator,
    text1: []const u8,
    style1: Theme.CellStyle,
    text2: []const u8,
    style2: Theme.CellStyle,
) !StyledLine {
    const spans = try allocator.alloc(StyledSpan, 2);
    spans[0] = .{ .text = text1, .style = style1 };
    spans[1] = .{ .text = text2, .style = style2 };
    return .{ .spans = spans };
}

/// Split content on newlines and append one StyledLine per segment.
/// If prefix is provided, the first line gets a two-span layout (prefix + segment).
/// Subsequent lines and all lines without a prefix get single-span layout.
/// If content is empty, appends one empty line.
fn splitAndAppend(
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    content: []const u8,
    style: Theme.CellStyle,
    prefix: ?[]const u8,
    prefix_style: ?Theme.CellStyle,
) !void {
    var first = true;
    var rest: []const u8 = content;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const segment = if (nl) |n| rest[0..n] else rest;
        const line = if (first and prefix != null)
            try twoSpanLine(allocator, prefix.?, prefix_style.?, segment, style)
        else
            try Theme.singleSpanLine(allocator, segment, style);
        try lines.append(allocator, line);
        first = false;
        rest = if (nl) |n| rest[n + 1 ..] else &.{};
    }
    if (content.len == 0) {
        try lines.append(allocator, try Theme.singleSpanLine(allocator, "", style));
    }
}

/// Split content on newlines, prepending an indent string to each line.
/// `indent_count` is clamped to `Prefixes.indent_pad_max.len`; the padding
/// span text slices that interned buffer directly.
fn splitAndAppendIndented(
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    content: []const u8,
    style: Theme.CellStyle,
    indent_count: u16,
) !void {
    const pad_len = @min(indent_count, Prefixes.indent_pad_max.len);
    const padding = Prefixes.indent_pad_max[0..pad_len];

    var rest: []const u8 = content;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const segment = if (nl) |n| rest[0..n] else rest;

        const spans = try allocator.alloc(StyledSpan, 2);
        spans[0] = .{ .text = padding, .style = .{} };
        spans[1] = .{ .text = segment, .style = style };
        try lines.append(allocator, .{ .spans = spans });

        rest = if (nl) |n| rest[n + 1 ..] else &.{};
    }
    if (content.len == 0) {
        try lines.append(allocator, try Theme.singleSpanLine(allocator, "", style));
    }
}

/// Built-in renderer: produces one or more StyledLines per node using type-specific formatting.
/// Multi-line content (containing \n) is split into separate display lines.
/// Mirror of `renderRichToolCall` that only counts lines. Returns null
/// when the rich render would NOT fire (unknown tool, missing or
/// invalid `tool_input_raw`), in which case the caller falls back to
/// the legacy line-count rule.
///
/// Must stay in lockstep with `renderRichToolCall`'s output shape:
///   - 1 `Name(arg)` header line
///   - body lines:
///       * `edit`: lineCount(old_text) + lineCount(new_text)
///       * `write`: lineCount(content)
///       * `bash` / `read`: min(lineCount(result), inline_cap), plus
///         1 inline truncation hint when the cap was hit
///   - no footer
///
/// Uses a stack-allocated allocator-friendly parse path because the
/// caller (`lineCountForNode`) doesn't have an allocator to spend on
/// the JSON tree. We use a heap-backed FBA so the parse stays bounded
/// and the count survives even for inputs slightly above the buffer.
fn richToolCallLineCount(node: *const Node, registry: *const BufferRegistry) ?usize {
    const tool_name = node.custom_tag orelse return null;
    const raw = node.tool_input_raw orelse return null;

    // Workflow is dispatched BEFORE the bounded full-tree parse below: a
    // workflow script is unbounded model output, so a >16 KiB input would
    // overflow the FBA and bail to null here while `renderWorkflowBlock`
    // (real, unbounded allocator) renders the full body — diverging the
    // count from the render and corrupting scroll math. The workflow arm
    // instead counts the decoded script lines with a streaming scanner that
    // needs only O(nesting-depth) memory regardless of script size. This is
    // the shared source of truth `renderWorkflowBlock` also derives its line
    // count from (both count newlines in the same decoded `script` value),
    // so the two paths agree for ANY size.
    if (std.mem.eql(u8, tool_name, "workflow")) {
        const script_lines = workflowScriptLineCount(raw) orelse return null;
        // Collapsed: header + one fold hint. Expanded: header + one line
        // per script source line. Mirror of `renderWorkflowBlock`.
        if (node.collapsed) return 2;
        return 1 + script_lines;
    }

    // 16 KiB is enough for the four built-in tools' inputs in practice
    // (Anthropic caps `bash.command` at 16 KiB, `edit.new_text` is
    // bounded by the file body). When the buffer overflows we bail to
    // the legacy count rather than mis-counting and corrupting the
    // scroll math.
    var scratch_buf: [16 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&scratch_buf);
    const fba_alloc = fba.allocator();
    var parsed = std.json.parseFromSlice(std.json.Value, fba_alloc, raw, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const root = parsed.value.object;

    if (std.mem.eql(u8, tool_name, "edit")) {
        if (jsonString(&root, "path") == null) return null;
        const old_text = jsonString(&root, "old_text") orelse "";
        const new_text = jsonString(&root, "new_text") orelse "";
        return 1 + lineCount(old_text) + lineCount(new_text);
    } else if (std.mem.eql(u8, tool_name, "write")) {
        if (jsonString(&root, "path") == null) return null;
        const content = jsonString(&root, "content") orelse "";
        return 1 + lineCount(content);
    } else if (std.mem.eql(u8, tool_name, "bash")) {
        if (jsonString(&root, "command") == null) return null;
        return 1 + bodyLineCount(node, registry, bash_inline_lines);
    } else if (std.mem.eql(u8, tool_name, "read")) {
        if (jsonString(&root, "path") == null) return null;
        return 1 + bodyLineCount(node, registry, read_inline_lines);
    }
    return null;
}

/// Count the display lines of the decoded top-level `script` string in a
/// `workflow` tool call's raw JSON input. Returns null when `raw` is not a
/// JSON object, has no string-valued `script` key, or is malformed (the
/// caller then falls back to the generic header count).
///
/// This is the SINGLE source of truth for the workflow script line count:
/// both `richToolCallLineCount` (above) and `renderWorkflowBlock` derive
/// their line counts from it, so the count path and the render path can
/// never diverge regardless of script size. It uses `std.json.Scanner`,
/// which streams the input and only allocates O(nesting-depth) bookkeeping,
/// so a multi-megabyte script counts in bounded memory — unlike a full
/// value-tree parse through a fixed scratch buffer, which would overflow
/// and silently mis-count.
///
/// The line rule matches `lineCount`: one line per non-empty value plus one
/// per interior `\n`, with a trailing `\n` not adding a final empty line.
fn workflowScriptLineCount(raw: []const u8) ?usize {
    var scanner: std.json.Scanner = .initCompleteInput(std.heap.page_allocator, raw);
    defer scanner.deinit();

    // Walk to the top-level `script` value. `string_is_object_key` separates
    // an object key from a string value at the same nesting depth.
    if ((scanner.next() catch return null) != .object_begin) return null;
    while (true) {
        const key_tok = scanner.next() catch return null;
        switch (key_tok) {
            .object_end => return null, // no `script` key
            .string => |key| {
                if (std.mem.eql(u8, key, "script")) break;
                // Not our key: skip its value (recursively, for objects/arrays).
                scanner.skipValue() catch return null;
            },
            .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => {
                // A key spanning escape/buffer boundaries can't be "script"
                // in one token; drain to its `.string` terminator then skip
                // the value. (Object keys with escapes are rare but legal.)
                const finished = drainStringToken(&scanner) catch return null;
                _ = finished;
                scanner.skipValue() catch return null;
            },
            else => return null, // malformed: object key must be a string
        }
    }

    // `script`'s value must be a string; count newlines in its decoded form.
    var lines: usize = 0;
    var saw_any = false;
    var last_was_newline = false;
    while (true) {
        const tok = scanner.next() catch return null;
        const chunk: []const u8 = switch (tok) {
            .string => |s| s,
            .partial_string => |s| s,
            .partial_string_escaped_1 => |*b| b[0..],
            .partial_string_escaped_2 => |*b| b[0..],
            .partial_string_escaped_3 => |*b| b[0..],
            .partial_string_escaped_4 => |*b| b[0..],
            else => return null, // value was not a string
        };
        for (chunk) |c| {
            saw_any = true;
            if (c == '\n') {
                lines += 1;
                last_was_newline = true;
            } else {
                last_was_newline = false;
            }
        }
        if (tok == .string) break;
    }
    if (!saw_any) return 0;
    // First line is implicit (one line of content before any `\n`); a
    // trailing `\n` does not open a new empty line.
    var count = lines + 1;
    if (last_was_newline) count -= 1;
    return count;
}

/// Drain a string that began with a `.partial_string*` token up to and
/// including its terminating `.string` token. Returns true on a clean
/// terminator. Used to skip over object keys that span escape boundaries.
fn drainStringToken(scanner: *std.json.Scanner) !bool {
    while (true) {
        switch (try scanner.next()) {
            .string => return true,
            .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => {},
            else => return false,
        }
    }
}

/// Body line count for bash/read: the tool_result child's content
/// capped at `inline_lines`, plus 1 for the inline truncation hint when
/// the cap was hit. Matches what `appendMarkedLines` +
/// `appendInlineExpandHint` emit in the renderer.
fn bodyLineCount(node: *const Node, registry: *const BufferRegistry, inline_lines: usize) usize {
    const result = firstToolResultBytes(node, registry);
    const result_lines = lineCount(result);
    if (result_lines == 0) return 0;
    if (result_lines <= inline_lines) return result_lines;
    return inline_lines + 1; // capped body plus 1 inline truncation hint
}

/// Pi-mono-style rich rendering for the four built-in tool_call types.
/// Returns true when the node is one of `edit`/`write`/`bash`/`read`
/// AND `tool_input_raw` parses as JSON; otherwise returns false so the
/// caller can fall through to the legacy `[tool] <name>` header.
///
/// Strings extracted from the parsed JSON are duped into `allocator`
/// before the parse arena tears down, so the resulting StyledLines
/// borrow text that lives at least as long as the cache entry.
fn renderRichToolCall(
    node: *const Node,
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    theme: *const Theme,
    registry: *const BufferRegistry,
) !bool {
    const tool_name = node.custom_tag orelse return false;
    const raw = node.tool_input_raw orelse return false;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const root = parsed.value.object;

    if (std.mem.eql(u8, tool_name, "edit")) {
        return renderEditBlock(lines, allocator, theme, &root);
    } else if (std.mem.eql(u8, tool_name, "write")) {
        return renderWriteBlock(lines, allocator, theme, &root);
    } else if (std.mem.eql(u8, tool_name, "bash")) {
        return renderBashBlock(node, lines, allocator, theme, registry, &root);
    } else if (std.mem.eql(u8, tool_name, "read")) {
        return renderReadBlock(node, lines, allocator, theme, registry, &root);
    } else if (std.mem.eql(u8, tool_name, "workflow")) {
        return renderWorkflowBlock(node, lines, allocator, theme, &root);
    }
    return false;
}

fn jsonString(root: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = root.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Best-effort primary argument for a generic tool header: the first
/// string-valued field in the input JSON object. Returns "" when the value
/// is not an object or has no string field. The returned slice borrows the
/// parsed JSON, so callers must use it before tearing down the parse.
fn firstJsonStringValue(value: std.json.Value) []const u8 {
    if (value != .object) return "";
    var it = value.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* == .string) return kv.value_ptr.*.string;
    }
    return "";
}

/// Emit a `Name(arg)<suffix>` tool-call header line. The leading bullet is
/// supplied by the gutter at composite time; this is the label only. The
/// composed label is duped into `allocator` and flagged `owned` so the cache
/// (or test cleanup) frees it when the line is dropped. `suffix` is appended
/// after the closing paren (e.g. the workflow ` 2/4 done` count); pass `""`
/// for the plain `Name(arg)` header.
fn appendToolHeader(
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    theme: *const Theme,
    name: []const u8,
    arg: []const u8,
    suffix: []const u8,
) !void {
    const accent = theme.highlights.tool_call;
    var label: std.ArrayList(u8) = .empty;
    defer label.deinit(allocator);
    // Capitalize the first letter of the tool name.
    if (name.len > 0) {
        try label.append(allocator, std.ascii.toUpper(name[0]));
        try label.appendSlice(allocator, name[1..]);
    }
    try label.append(allocator, '(');
    try label.appendSlice(allocator, arg);
    try label.append(allocator, ')');
    try label.appendSlice(allocator, suffix);
    const owned = try allocator.dupe(u8, label.items);
    const spans = try allocator.alloc(StyledSpan, 1);
    spans[0] = .{ .text = owned, .style = accent, .owned = true };
    try lines.append(allocator, .{ .spans = spans });
}

/// Leading-span text for the `body_index`-th body line of a tool_call.
/// The first body line gets the corner connector (`└ `); every later
/// line gets a two-space pad so the body content aligns under it. The
/// returned slice is static, satisfying the StyledSpan borrowed-text
/// contract; callers style it with `theme.highlights.tree_connector`.
fn bodyBranchPrefix(body_index: usize) []const u8 {
    return if (body_index == 0) Gutter.branch_last else Gutter.blank_seg;
}

/// Emit the inline `… +N lines (Ctrl-R to expand)` hint used for both the
/// collapsed-tool hint and the bash/read truncation suffix. `hidden` is the
/// number of hidden/truncated lines; the digit slice borrows the static
/// `digit_strings` table (or `digit_overflow_label` when out of range).
///
/// The hint is a tool-call body line, so it gets a leading branch-prefix
/// span (`└ ` for the first body line of the node, `  ` otherwise) styled
/// `tree_connector`, ahead of the `… +N lines` text.
fn appendInlineExpandHint(
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    style: Theme.CellStyle,
    hidden: usize,
    theme: *const Theme,
    body_index: usize,
) !void {
    const digits: []const u8 = if (hidden < digit_strings.len) digit_strings[hidden] else digit_overflow_label;
    const spans = try allocator.alloc(StyledSpan, 4);
    spans[0] = .{ .text = bodyBranchPrefix(body_index), .style = theme.highlights.tree_connector };
    spans[1] = .{ .text = "\u{2026} +", .style = style };
    spans[2] = .{ .text = digits, .style = style };
    spans[3] = .{ .text = " lines (Ctrl-R to expand)", .style = style };
    try lines.append(allocator, .{ .spans = spans });
}

/// Split `content` on newlines and emit one StyledLine per segment,
/// each with a marker prefix (e.g. `+ `, `- `, ` `). Returns the
/// number of lines appended.
///
/// Every emitted line is a tool-call body line: it gets a leading
/// branch-prefix span (`└ ` for the first body line of the node, `  `
/// otherwise) styled `tree_connector`, ahead of the marker and content
/// spans. `body_index` tracks the running body-line count across all
/// emitters for the node and is advanced for each line appended.
fn appendMarkedLines(
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    theme: *const Theme,
    body_index: *usize,
    content: []const u8,
    marker: []const u8,
    marker_style: Theme.CellStyle,
    body_style: Theme.CellStyle,
    max_lines: ?usize,
) !usize {
    var emitted: usize = 0;
    var rest: []const u8 = content;
    while (rest.len > 0) {
        if (max_lines) |cap| if (emitted >= cap) break;
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const segment = if (nl) |n| rest[0..n] else rest;
        const owned = try allocator.dupe(u8, segment);
        const spans = try allocator.alloc(StyledSpan, 3);
        spans[0] = .{ .text = bodyBranchPrefix(body_index.*), .style = theme.highlights.tree_connector };
        spans[1] = .{ .text = marker, .style = marker_style };
        spans[2] = .{ .text = owned, .style = body_style, .owned = true };
        try lines.append(allocator, .{ .spans = spans });
        emitted += 1;
        body_index.* += 1;
        rest = if (nl) |n| rest[n + 1 ..] else &.{};
    }
    return emitted;
}

fn renderEditBlock(
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    theme: *const Theme,
    root: *const std.json.ObjectMap,
) !bool {
    const path = jsonString(root, "path") orelse return false;
    const old_text = jsonString(root, "old_text") orelse "";
    const new_text = jsonString(root, "new_text") orelse "";

    try appendToolHeader(lines, allocator, theme, "edit", path, "");

    const remove_style = theme.highlights.diff_remove;
    const add_style = theme.highlights.diff_add;
    var body_index: usize = 0;
    _ = try appendMarkedLines(lines, allocator, theme, &body_index, old_text, Prefixes.diff_remove_marker, remove_style, remove_style, null);
    _ = try appendMarkedLines(lines, allocator, theme, &body_index, new_text, Prefixes.diff_add_marker, add_style, add_style, null);

    return true;
}

fn renderWriteBlock(
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    theme: *const Theme,
    root: *const std.json.ObjectMap,
) !bool {
    const path = jsonString(root, "path") orelse return false;
    const content = jsonString(root, "content") orelse "";

    try appendToolHeader(lines, allocator, theme, "write", path, "");

    var body_index: usize = 0;
    _ = try appendMarkedLines(
        lines,
        allocator,
        theme,
        &body_index,
        content,
        Prefixes.tool_body_indent,
        theme.highlights.tool_result,
        theme.highlights.assistant_text,
        null,
    );
    return true;
}

fn renderBashBlock(
    node: *const Node,
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    theme: *const Theme,
    registry: *const BufferRegistry,
    root: *const std.json.ObjectMap,
) !bool {
    const cmd = jsonString(root, "command") orelse return false;

    try appendToolHeader(lines, allocator, theme, "bash", cmd, "");

    const result_bytes = firstToolResultBytes(node, registry);
    const result_lines = lineCount(result_bytes);
    var body_index: usize = 0;
    const emitted = try appendMarkedLines(
        lines,
        allocator,
        theme,
        &body_index,
        result_bytes,
        Prefixes.tool_body_indent,
        theme.highlights.tool_result,
        theme.highlights.tool_result,
        bash_inline_lines,
    );
    if (result_lines > emitted) {
        try appendInlineExpandHint(lines, allocator, theme.highlights.tool_result, result_lines - emitted, theme, body_index);
    }
    return true;
}

fn renderReadBlock(
    node: *const Node,
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    theme: *const Theme,
    registry: *const BufferRegistry,
    root: *const std.json.ObjectMap,
) !bool {
    const path = jsonString(root, "path") orelse return false;

    try appendToolHeader(lines, allocator, theme, "read", path, "");

    const result_bytes = firstToolResultBytes(node, registry);
    const result_lines = lineCount(result_bytes);
    var body_index: usize = 0;
    const emitted = try appendMarkedLines(
        lines,
        allocator,
        theme,
        &body_index,
        result_bytes,
        Prefixes.tool_body_indent,
        theme.highlights.tool_result,
        theme.highlights.tool_result,
        read_inline_lines,
    );
    if (result_lines > emitted) {
        try appendInlineExpandHint(lines, allocator, theme.highlights.tool_result, result_lines - emitted, theme, body_index);
    }
    return true;
}

/// Finished/total counts of the subagents a `workflow` tool_call spawned.
/// `total` is the number of `subagent_link` nodes in the owning
/// Conversation's `root_children` whose `spawning_tool_node` is this node;
/// `done` is how many of those have finished (status `done` or `failed`).
/// Returns null when the node carries no `workflow_owner` (no linked
/// children), so the header renders its plain, unchanged form.
///
/// Once the workflow tool_call has its own `tool_result` child the call has
/// returned, so every linked child is final: `done` is forced to `total`.
const WorkflowDoneCounts = struct { done: usize, total: usize };

fn workflowDoneCounts(node: *const Node) ?WorkflowDoneCounts {
    const owner_opaque = node.workflow_owner orelse return null;
    const owner: *const Conversation = @ptrCast(@alignCast(owner_opaque));

    var total: usize = 0;
    var done: usize = 0;
    for (owner.tree.root_children.items) |link| {
        if (link.node_type != .subagent_link) continue;
        const spawn = link.spawning_tool_node orelse continue;
        if (spawn != node) continue;
        total += 1;
        const status = subagentStatus(link);
        if (std.mem.eql(u8, status, "done") or std.mem.eql(u8, status, "failed")) {
            done += 1;
        }
    }
    if (total == 0) return null;

    // The workflow call's own tool_result means the call returned; all
    // linked children are accounted final regardless of their tail tick.
    for (node.children.items) |child| {
        if (child.node_type == .tool_result) {
            done = total;
            break;
        }
    }
    return .{ .done = done, .total = total };
}

/// Render a `workflow` tool call as a foldable Lua code block. The header
/// reports the script length (`Workflow(N lines)`) rather than the script
/// text, so the generic `firstJsonStringValue` flattening never runs. When
/// the call has linked children the header gains a live ` X/M done` suffix
/// (`Workflow(12 lines) 2/4 done`), computed at render time from the link
/// nodes grouped under this node. The suffix only changes the header TEXT,
/// not the line count, so the lockstep with `richToolCallLineCount` holds.
///
/// Collapsed: header plus one fold hint naming the hidden script lines.
/// Expanded: header plus one `md_code_block`-styled line per script source
/// line. Each script line is duped into `allocator` as an owned span so it
/// outlives the parse arena that backs `script`.
fn renderWorkflowBlock(
    node: *const Node,
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    theme: *const Theme,
    root: *const std.json.ObjectMap,
) !bool {
    const script = jsonString(root, "script") orelse return false;
    const script_lines = lineCount(script);

    const arg = try std.fmt.allocPrint(allocator, "{d} lines", .{script_lines});
    defer allocator.free(arg);
    // Live ` X/M done` suffix when this call has linked children. Empty
    // otherwise, so the header reads `Workflow(N lines)` unchanged.
    var suffix_buf: [64]u8 = undefined;
    const suffix: []const u8 = if (workflowDoneCounts(node)) |counts|
        std.fmt.bufPrint(&suffix_buf, " {d}/{d} done", .{ counts.done, counts.total }) catch ""
    else
        "";
    try appendToolHeader(lines, allocator, theme, "workflow", arg, suffix);

    if (node.collapsed) {
        try appendInlineExpandHint(lines, allocator, theme.highlights.tool_result, script_lines, theme, 0);
        return true;
    }

    const style = theme.highlights.md_code_block;
    var rest: []const u8 = script;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const segment = if (nl) |n| rest[0..n] else rest;
        const owned = try allocator.dupe(u8, segment);
        const spans = try allocator.alloc(StyledSpan, 1);
        spans[0] = .{ .text = owned, .style = style, .owned = true };
        try lines.append(allocator, .{ .spans = spans });
        rest = if (nl) |n| rest[n + 1 ..] else &.{};
    }
    return true;
}

/// Resolve the bytes of the first `tool_result` child of `node`, if
/// any. Image-backed tool_results return an empty slice (the inline
/// preview doesn't have a useful text form).
fn firstToolResultBytes(node: *const Node, registry: *const BufferRegistry) []const u8 {
    for (node.children.items) |child| {
        if (child.node_type != .tool_result) continue;
        if (isImageBacked(child, registry)) return "";
        return nodeBytes(child, registry);
    }
    return "";
}

/// Count one line per content slice plus one for every interior `\n`.
/// Trailing newlines do not count toward another line (matches the
/// rendered output shape). An empty slice yields 0 lines.
fn lineCount(content: []const u8) usize {
    if (content.len == 0) return 0;
    var count: usize = 1;
    for (content) |c| {
        if (c == '\n') count += 1;
    }
    if (content[content.len - 1] == '\n') count -= 1;
    return count;
}

fn renderDefault(
    node: *const Node,
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    theme: *const Theme,
    registry: *const BufferRegistry,
) !void {
    const content = nodeBytes(node, registry);

    switch (node.node_type) {
        .user_message => {
            const style = theme.highlights.user_message;
            try splitAndAppend(lines, allocator, content, style, null, null);
            return;
        },
        .assistant_text => {
            try MarkdownParser.parseLines(content, lines, allocator, theme);
            return;
        },
        .status, .custom => {
            const style = if (node.node_type == .status) theme.highlights.status else Theme.CellStyle{};
            try splitAndAppend(lines, allocator, content, style, null, null);
            return;
        },
        .tool_call => {
            // Rich pi-mono-style block render for the four built-in tools
            // (`edit`, `write`, `bash`, `read`). Falls back to the legacy
            // `[tool] <name>` header when the tool isn't one we know how
            // to pretty-print or when the node has no `tool_input_raw`
            // (legacy JSONL row).
            //
            // The rich render fires regardless of `collapsed` state so
            // the diff/output/path is visible by default. `collapsed`
            // still controls whether the tool_result child renders as
            // a sibling line below (see `collectVisibleLines`): Ctrl-R
            // expands the full untruncated body underneath.
            if (try renderRichToolCall(node, lines, allocator, theme, registry)) return;

            // Generic `Name(arg)` header. The tool name is the node's
            // content (custom_tag); the arg is the first string-valued
            // field of the input JSON. Parse inline so the arg slice stays
            // alive while `appendToolHeader` dupes it into an owned span.
            {
                var parsed = if (node.tool_input_raw) |raw|
                    std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch null
                else
                    null;
                defer if (parsed) |*p| p.deinit();
                const arg: []const u8 = if (parsed) |p| firstJsonStringValue(p.value) else "";
                try appendToolHeader(lines, allocator, theme, content, arg, "");
            }
            const hidden = hiddenToolResultLineCount(node, registry);
            if (hidden == 0) return;
            try appendInlineExpandHint(lines, allocator, theme.highlights.tool_result, hidden, theme, 0);
            return;
        },
        .tool_result => {
            if (isImageBacked(node, registry)) {
                const style = theme.highlights.tool_result;
                try lines.append(allocator, try Theme.singleSpanLine(allocator, Prefixes.tool_result_image_placeholder, style));
                return;
            }
            try splitAndAppendIndented(lines, allocator, content, theme.highlights.tool_result, theme.spacing.indent);
            return;
        },
        .err => {
            const style = theme.highlights.err;
            try splitAndAppend(lines, allocator, content, style, null, null);
            return;
        },
        .separator => {
            const style = theme.highlights.status;
            try lines.append(allocator, try Theme.singleSpanLine(allocator, Prefixes.separator, style));
            return;
        },
        .thinking => {
            // Reuse `tool_result` highlight for the dim/muted look; the
            // reasoning stream is metadata, not a primary voice in the
            // conversation, so it should read as de-emphasised.
            const style = theme.highlights.tool_result;
            if (node.collapsed) {
                try lines.append(allocator, try Theme.singleSpanLine(allocator, "thinking (folded, Ctrl-R to expand)", style));
                return;
            }
            try lines.append(allocator, try Theme.singleSpanLine(allocator, "thinking", style));
            if (content.len == 0) return;
            // Body lines: split on newlines and render each in the same
            // dim style. Skipping markdown parse keeps the output visually
            // distinct from assistant_text and avoids parser state mixing
            // into a block of raw reasoning text.
            try splitAndAppend(lines, allocator, content, style, null, null);
            return;
        },
        .thinking_redacted => {
            const style = theme.highlights.tool_result;
            try lines.append(allocator, try Theme.singleSpanLine(allocator, "thinking (redacted)", style));
            return;
        },
        .subagent_link => {
            // Placeholder line: `[subagent: <name>] <status>`. The text
            // spans are borrowed: `subagent_open`/`subagent_close` and
            // `subagentStatus` return static slices, and the name is owned
            // by the node (freed in `Node.deinit` after the line cache wipes
            // its entry).
            //
            // A link spawned by a workflow tool call (`spawning_tool_node`
            // set) is prefixed with the `  └ ` connector so it reads as
            // grouped under its workflow header; plain links render flush.
            // The prefix only adds spans, never a line, so the lineCount of 1
            // is unchanged.
            const style = theme.highlights.subagent_placeholder;
            const name = node.subagent_name orelse Prefixes.subagent_unnamed;
            const status = subagentStatus(node);
            const grouped = node.spawning_tool_node != null;
            const span_count: usize = if (grouped) 6 else 4;
            const spans = try allocator.alloc(StyledSpan, span_count);
            var i: usize = 0;
            if (grouped) {
                spans[i] = .{ .text = Gutter.blank_seg, .style = theme.highlights.tree_connector };
                i += 1;
                spans[i] = .{ .text = Gutter.branch_last, .style = theme.highlights.tree_connector };
                i += 1;
            }
            spans[i] = .{ .text = Prefixes.subagent_open, .style = style };
            spans[i + 1] = .{ .text = name, .style = style };
            spans[i + 2] = .{ .text = Prefixes.subagent_close, .style = style };
            spans[i + 3] = .{ .text = status, .style = style };
            try lines.append(allocator, .{ .spans = spans });
            return;
        },
    }
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

/// Helper for renderer tests: wire a fresh Conversation with a
/// registry and append a content node. Caller owns the lifetimes of
/// the registry and buffer (passed in by pointer); the helper exists
/// so each test reads less ceremony.
fn appendTestNode(
    cb: *@import("Conversation.zig"),
    parent: ?*Node,
    node_type: NodeType,
    content: []const u8,
) !*Node {
    return cb.appendNode(parent, node_type, content);
}

test "toolBulletState reflects result presence and error" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const tc = try cb.appendToolCallNode(null, "bash", "t1", "{\"command\":\"x\"}");
    try std.testing.expectEqual(BulletState.running, toolBulletState(tc));

    const res = try cb.appendNode(tc, .tool_result, "ok");
    try std.testing.expectEqual(BulletState.ok, toolBulletState(tc));

    res.tool_result_is_error = true;
    try std.testing.expectEqual(BulletState.err, toolBulletState(tc));
}

test "renderDefault user_message" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .user_message, "hello");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
}

test "renderDefault user_message emits a single bare span with user_message style" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .user_message, "hello");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

    const line = lines.items[0];
    try std.testing.expectEqual(@as(usize, 1), line.spans.len);
    try std.testing.expectEqualStrings("hello", line.spans[0].text);
    // user_message style should be bold
    try std.testing.expect(line.spans[0].style.bold);
}

test "renderDefault assistant_text" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .assistant_text, "I can help with that");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("I can help with that", text);
    // assistant_text should have one span
    try std.testing.expectEqual(@as(usize, 1), lines.items[0].spans.len);
}

test "renderDefault tool_call" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .tool_call, "bash");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    // No tool_input_raw on this node, so the generic `Name(arg)` header
    // fires with an empty arg and a capitalized tool name.
    try std.testing.expectEqualStrings("Bash()", text);

    // Single owned span styled tool_call.
    try std.testing.expectEqual(@as(usize, 1), lines.items[0].spans.len);
}

test "renderDefault tool_result shows full content" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const long_text = "a" ** 120;
    const node = try appendTestNode(&cb, null, .tool_result, long_text);

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);

    // indent (2) + full 120 chars = 122
    try std.testing.expectEqual(@as(usize, 122), text.len);
    try std.testing.expect(std.mem.startsWith(u8, text, "  "));

    // Two spans: indent (unstyled) and result content
    try std.testing.expectEqual(@as(usize, 2), lines.items[0].spans.len);
}

test "renderDefault tool_result short content not truncated" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .tool_result, "ok");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("  ok", text);
}

test "renderDefault err" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .err, "something failed");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("something failed", text);

    // err style should be bold
    try std.testing.expectEqual(@as(usize, 1), lines.items[0].spans.len);
    try std.testing.expect(lines.items[0].spans[0].style.bold);
}

test "renderDefault separator" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .separator, "");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("---", text);
    // Separator uses the status highlight.
    try std.testing.expect(std.meta.eql(lines.items[0].spans[0].style.fg, theme.highlights.status.fg));
}

test "renderDefault status" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .status, "tokens: 1500 in, 200 out");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("tokens: 1500 in, 200 out", text);
    try std.testing.expect(std.meta.eql(lines.items[0].spans[0].style.fg, theme.highlights.status.fg));
}

test "renderDefault custom" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .custom, "plugin output");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("plugin output", text);
}

test "renderDefault multiline assistant_text" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .assistant_text, "line one\nline two\nline three");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);

    const t1 = try lines.items[0].toText(allocator);
    defer allocator.free(t1);
    const t2 = try lines.items[1].toText(allocator);
    defer allocator.free(t2);
    const t3 = try lines.items[2].toText(allocator);
    defer allocator.free(t3);

    try std.testing.expectEqualStrings("line one", t1);
    try std.testing.expectEqualStrings("line two", t2);
    try std.testing.expectEqualStrings("line three", t3);
}

test "custom override replaces default renderer" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    var renderer = NodeRenderer.init(allocator);
    defer renderer.deinit();

    const custom_render = struct {
        fn render(
            node: *const Node,
            lines: *std.ArrayList(StyledLine),
            alloc: Allocator,
            theme: *const Theme,
            registry_arg: *const BufferRegistry,
        ) !void {
            _ = node;
            _ = theme;
            _ = registry_arg;
            // Static literal satisfies the borrowed-slice contract with no
            // allocation at all.
            const spans = try alloc.alloc(StyledSpan, 1);
            spans[0] = .{ .text = "CUSTOM RENDERED", .style = .{} };
            try lines.append(alloc, .{ .spans = spans });
        }
    }.render;

    try renderer.register("user_message", custom_render);

    const node = try appendTestNode(&cb, null, .user_message, "hello");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderer.render(node, &lines, allocator, &theme, &cb.buffer_registry);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("CUSTOM RENDERED", text);
}

test "renderDefault thinking collapsed emits one header line" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .thinking, "reasoning body\nover two lines");
    node.collapsed = true;

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("thinking (folded, Ctrl-R to expand)", text);

    const renderer = NodeRenderer.initDefault();
    try std.testing.expectEqual(@as(usize, 1), renderer.lineCountForNode(node, &cb.buffer_registry));
}

test "renderDefault thinking expanded emits header plus body lines" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .thinking, "step one\nstep two\nstep three");
    node.collapsed = false;

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);
    // header + 3 body lines
    try std.testing.expectEqual(@as(usize, 4), lines.items.len);

    const header = try lines.items[0].toText(allocator);
    defer allocator.free(header);
    try std.testing.expectEqualStrings("thinking", header);

    const body0 = try lines.items[1].toText(allocator);
    defer allocator.free(body0);
    try std.testing.expectEqualStrings("step one", body0);

    const renderer = NodeRenderer.initDefault();
    try std.testing.expectEqual(@as(usize, 4), renderer.lineCountForNode(node, &cb.buffer_registry));
}

test "renderDefault thinking_redacted emits a single redacted header" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .thinking_redacted, "");
    node.collapsed = true;

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "redacted") != null);
}

test "lineCountForNode returns 1 for separator" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .separator, "");

    const renderer = NodeRenderer.initDefault();
    try std.testing.expectEqual(@as(usize, 1), renderer.lineCountForNode(node, &cb.buffer_registry));
}

test "lineCountForNode counts hidden tool_result child lines when tool_call is collapsed" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const call = try appendTestNode(&cb, null, .tool_call, "bash");
    _ = try appendTestNode(&cb, call, .tool_result, "line one\nline two\nline three");

    call.collapsed = true;

    const renderer = NodeRenderer.initDefault();
    // tool_call collapsed: its own header line plus a hint line that names the hidden body.
    try std.testing.expectEqual(@as(usize, 2), renderer.lineCountForNode(call, &cb.buffer_registry));
}

test "renderDefault tool_result image-backed emits placeholder line" {
    const allocator = std.testing.allocator;

    var registry = BufferRegistry.init(allocator);
    defer registry.deinit();

    var tree = @import("ConversationTree.zig").init(allocator);
    defer tree.deinit();

    // Drive the typed-buffer path directly: allocate an ImageBuffer in the
    // registry, stamp its handle on a tool_result node. This mirrors the
    // shape `Conversation.appendImageNode` produces without pulling
    // a full Conversation into the renderer test.
    const handle = try registry.createImage("tool_result");
    const node = try tree.appendNode(null, .tool_result);
    node.buffer_id = handle;

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &registry);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("[image]", text);

    const renderer = NodeRenderer.initDefault();
    try std.testing.expectEqual(@as(usize, 1), renderer.lineCountForNode(node, &registry));
}

test "rendering a collapsed tool_call with a tool_result child does not leak under testing.allocator" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const call = try cb.appendNode(null, .tool_call, "bash");
    _ = try cb.appendNode(call, .tool_result, "row one\nrow two\nrow three");
    call.collapsed = true;

    const theme = Theme.defaultTheme();

    // Render twice with a content_version bump in between, mirroring what
    // happens when the cache invalidates and refills. testing.allocator
    // would flag a leak in either pass if span text were owned-but-never-freed.
    inline for (0..2) |_| {
        var lines: std.ArrayList(StyledLine) = .empty;
        defer Theme.freeStyledLines(&lines, allocator);
        try renderDefault(call, &lines, allocator, &theme, &cb.buffer_registry);
        try std.testing.expectEqual(@as(usize, 2), lines.items.len);
        // Confirm the inline hint line carries the expected count token. It is
        // the node's first (and only) body line, so it gets the corner connector.
        const hint_text = try lines.items[1].toText(allocator);
        defer allocator.free(hint_text);
        try std.testing.expectEqualStrings("\u{2514} \u{2026} +3 lines (Ctrl-R to expand)", hint_text);
        try std.testing.expectEqualStrings("\u{2514} ", lines.items[1].spans[0].text);
        call.markDirty();
    }
}

test "subagent_link renders status reflecting child Conversation tail node" {
    const allocator = std.testing.allocator;
    var parent = try @import("Conversation.zig").init(allocator, 0, "parent");
    defer parent.deinit();

    const child = try parent.spawnSubagent("codereview", "");
    const link = parent.tree.root_children.items[parent.tree.root_children.items.len - 1];

    const theme = Theme.defaultTheme();

    // Empty child tree -> "ready".
    {
        var lines: std.ArrayList(StyledLine) = .empty;
        defer Theme.freeStyledLines(&lines, allocator);
        try renderDefault(link, &lines, allocator, &theme, &parent.buffer_registry);
        try std.testing.expectEqual(@as(usize, 1), lines.items.len);
        const text = try lines.items[0].toText(allocator);
        defer allocator.free(text);
        try std.testing.expectEqualStrings("[subagent: codereview] ready", text);
    }

    // Non-terminal tail (a user_message) -> "running".
    _ = try child.appendNode(null, .user_message, "do the thing");
    {
        var lines: std.ArrayList(StyledLine) = .empty;
        defer Theme.freeStyledLines(&lines, allocator);
        try renderDefault(link, &lines, allocator, &theme, &parent.buffer_registry);
        const text = try lines.items[0].toText(allocator);
        defer allocator.free(text);
        try std.testing.expect(std.mem.endsWith(u8, text, "running"));
    }

    // Tail is assistant_text -> "done".
    _ = try child.appendNode(null, .assistant_text, "looks good");
    {
        var lines: std.ArrayList(StyledLine) = .empty;
        defer Theme.freeStyledLines(&lines, allocator);
        try renderDefault(link, &lines, allocator, &theme, &parent.buffer_registry);
        const text = try lines.items[0].toText(allocator);
        defer allocator.free(text);
        try std.testing.expect(std.mem.endsWith(u8, text, "done"));
    }

    // Tail is err -> "failed".
    _ = try child.appendNode(null, .err, "oops");
    {
        var lines: std.ArrayList(StyledLine) = .empty;
        defer Theme.freeStyledLines(&lines, allocator);
        try renderDefault(link, &lines, allocator, &theme, &parent.buffer_registry);
        const text = try lines.items[0].toText(allocator);
        defer allocator.free(text);
        try std.testing.expect(std.mem.endsWith(u8, text, "failed"));
    }
}

test "renderDefault edit tool_call emits diff block" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const input =
        \\{"path":"src/foo.zig","old_text":"line a\nline b","new_text":"line a\nline c\nline d"}
    ;
    const node = try cb.appendToolCallNode(null, "edit", "edit:0", input);
    _ = try cb.appendNode(node, .tool_result, "ok");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);
    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

    // Name(arg) header + 2 `-` lines + 3 `+` lines = 6 lines (no footer rule).
    try std.testing.expectEqual(@as(usize, 6), lines.items.len);

    const header = try lines.items[0].toText(allocator);
    defer allocator.free(header);
    try std.testing.expectEqualStrings("Edit(src/foo.zig)", header);

    // First body line (first removed) carries the corner connector `└ `;
    // every later body line aligns under it with a two-space pad.
    const removed = try lines.items[1].toText(allocator);
    defer allocator.free(removed);
    try std.testing.expectEqualStrings("\u{2514} - line a", removed);
    // The branch-prefix span is separate and styled `tree_connector`.
    try std.testing.expectEqualStrings("\u{2514} ", lines.items[1].spans[0].text);
    try std.testing.expect(std.meta.eql(lines.items[1].spans[0].style.fg, theme.highlights.tree_connector.fg));

    const added = try lines.items[3].toText(allocator);
    defer allocator.free(added);
    try std.testing.expectEqualStrings("  + line a", added);
    try std.testing.expectEqualStrings("  ", lines.items[3].spans[0].text);

    // Line count must match what renderDefault produced (else viewport
    // math goes wrong inside collectVisibleLines).
    const renderer = NodeRenderer.initDefault();
    try std.testing.expectEqual(@as(usize, 6), renderer.lineCountForNode(node, &cb.buffer_registry));
}

test "renderDefault bash tool_call shows command and truncated output" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const input =
        \\{"command":"ls -la"}
    ;
    const node = try cb.appendToolCallNode(null, "bash", "bash:0", input);
    // 8 output lines triggers truncation at bash_inline_lines (6).
    const big_output = "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8";
    _ = try cb.appendNode(node, .tool_result, big_output);

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);
    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

    // Name(arg) header + 6 capped body lines + 1 inline truncation hint = 8
    // (no closing rule).
    try std.testing.expectEqual(@as(usize, 8), lines.items.len);

    const header = try lines.items[0].toText(allocator);
    defer allocator.free(header);
    try std.testing.expectEqualStrings("Bash(ls -la)", header);

    // First body line carries the corner connector.
    const body0 = try lines.items[1].toText(allocator);
    defer allocator.free(body0);
    try std.testing.expectEqualStrings("\u{2514}  line1", body0);
    try std.testing.expectEqualStrings("\u{2514} ", lines.items[1].spans[0].text);

    const truncated = try lines.items[7].toText(allocator);
    defer allocator.free(truncated);
    // 8 result lines, 6 shown -> "… +2 lines (Ctrl-R to expand)". The hint is
    // the 7th body line, so it aligns under the connector with a two-space pad.
    try std.testing.expectEqualStrings("  \u{2026} +2 lines (Ctrl-R to expand)", truncated);
    try std.testing.expectEqualStrings("  ", lines.items[7].spans[0].text);

    const renderer = NodeRenderer.initDefault();
    try std.testing.expectEqual(@as(usize, 8), renderer.lineCountForNode(node, &cb.buffer_registry));
}

test "renderDefault bash tool_call renders body as a branch off the header" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try cb.appendToolCallNode(null, "bash", "bash:0", "{\"command\":\"echo hi\"}");
    _ = try cb.appendNode(node, .tool_result, "line1\nline2\nline3");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);
    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

    // Header + 3 body lines, no truncation hint (3 <= bash_inline_lines).
    try std.testing.expectEqual(@as(usize, 4), lines.items.len);

    // Header carries no branch prefix; the gutter supplies its `● ` marker.
    const header = try lines.items[0].toText(allocator);
    defer allocator.free(header);
    try std.testing.expectEqualStrings("Bash(echo hi)", header);

    // First body line: corner connector `└ ` span styled tree_connector,
    // then the body-indent marker and content.
    const b0 = try lines.items[1].toText(allocator);
    defer allocator.free(b0);
    try std.testing.expectEqualStrings("\u{2514}  line1", b0);
    try std.testing.expectEqualStrings("\u{2514} ", lines.items[1].spans[0].text);
    try std.testing.expect(std.meta.eql(lines.items[1].spans[0].style.fg, theme.highlights.tree_connector.fg));

    // Subsequent body lines: two-space pad aligning under the connector.
    const b1 = try lines.items[2].toText(allocator);
    defer allocator.free(b1);
    try std.testing.expectEqualStrings("   line2", b1);
    try std.testing.expectEqualStrings("  ", lines.items[2].spans[0].text);

    const b2 = try lines.items[3].toText(allocator);
    defer allocator.free(b2);
    try std.testing.expectEqualStrings("   line3", b2);
    try std.testing.expectEqualStrings("  ", lines.items[3].spans[0].text);

    // Line count is unchanged by the added prefix span.
    const renderer = NodeRenderer.initDefault();
    try std.testing.expectEqual(@as(usize, 4), renderer.lineCountForNode(node, &cb.buffer_registry));
}

test "renderDefault read tool_call falls back when tool_input_raw is missing" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    // Legacy node: no tool_input_raw → renderRichToolCall returns false,
    // and the generic `Name(arg)` header fires with an empty arg.
    const node = try cb.appendNode(null, .tool_call, "read");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);
    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

    try std.testing.expect(lines.items.len >= 1);
    const header = try lines.items[0].toText(allocator);
    defer allocator.free(header);
    try std.testing.expectEqualStrings("Read()", header);
}

test "renderRichToolCall bash header is Name(arg)" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();
    const node = try cb.appendToolCallNode(null, "bash", "t1", "{\"command\":\"zig build\"}");
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);
    _ = try renderRichToolCall(node, &lines, allocator, &theme, &cb.buffer_registry);
    const head = try lines.items[0].toText(allocator);
    defer allocator.free(head);
    try std.testing.expectEqualStrings("Bash(zig build)", head);
}

test "generic tool_call header uses first JSON string arg" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();
    // `grep` is not a rich-block tool, so the generic header fires. The
    // first string field of the input becomes the parenthesized arg.
    const node = try cb.appendToolCallNode(null, "grep", "t1", "{\"pattern\":\"needle\",\"path\":\"src\"}");
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);
    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);
    const head = try lines.items[0].toText(allocator);
    defer allocator.free(head);
    try std.testing.expectEqualStrings("Grep(needle)", head);
}

test "lineCountForNode matches render() for collapsed tool_call with multi-line result" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    // Collapsed generic tool_call (no rich block) with a multi-line result:
    // the off-by-one guard for the dropped footer rule. render() emits a
    // Name(arg) header plus one inline collapse hint; lineCountForNode must
    // agree with the actual line count.
    const call = try cb.appendNode(null, .tool_call, "grep");
    _ = try cb.appendNode(call, .tool_result, "hit one\nhit two\nhit three\nhit four");
    call.collapsed = true;

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);
    try renderDefault(call, &lines, allocator, &theme, &cb.buffer_registry);

    const renderer = NodeRenderer.initDefault();
    try std.testing.expectEqual(lines.items.len, renderer.lineCountForNode(call, &cb.buffer_registry));

    // And for a rich (bash) block with a truncating result.
    const bash = try cb.appendToolCallNode(null, "bash", "b1", "{\"command\":\"ls\"}");
    _ = try cb.appendNode(bash, .tool_result, "a\nb\nc\nd\ne\nf\ng\nh");
    bash.collapsed = true;
    var rich_lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&rich_lines, allocator);
    try renderDefault(bash, &rich_lines, allocator, &theme, &cb.buffer_registry);
    try std.testing.expectEqual(rich_lines.items.len, renderer.lineCountForNode(bash, &cb.buffer_registry));
}

test "workflow tool_call collapsed renders header plus fold hint" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try cb.appendToolCallNode(null, "workflow", "id1", "{\"script\":\"local a = 1\\nreturn 'x'\"}");
    node.collapsed = true;

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);
    // Header line plus one fold hint covering the hidden script body.
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);

    const header = try lines.items[0].toText(allocator);
    defer allocator.free(header);
    try std.testing.expectEqualStrings("Workflow(2 lines)", header);

    const hint = try lines.items[1].toText(allocator);
    defer allocator.free(hint);
    try std.testing.expectEqualStrings("\u{2514} \u{2026} +2 lines (Ctrl-R to expand)", hint);

    const renderer = NodeRenderer.initDefault();
    try std.testing.expectEqual(lines.items.len, renderer.lineCountForNode(node, &cb.buffer_registry));
}

test "workflow tool_call expanded renders script lines as a code block" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try cb.appendToolCallNode(null, "workflow", "id1", "{\"script\":\"local a = 1\\nreturn 'x'\"}");
    node.collapsed = false;

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);
    // Header + one code-block line per script source line.
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);

    const header = try lines.items[0].toText(allocator);
    defer allocator.free(header);
    try std.testing.expectEqualStrings("Workflow(2 lines)", header);

    const line0 = try lines.items[1].toText(allocator);
    defer allocator.free(line0);
    try std.testing.expectEqualStrings("local a = 1", line0);

    const line1 = try lines.items[2].toText(allocator);
    defer allocator.free(line1);
    try std.testing.expectEqualStrings("return 'x'", line1);

    // Script lines are styled as md_code_block, and NO span carries an
    // embedded newline (the control-char staircase guard).
    for (lines.items[1..]) |line| {
        for (line.spans) |span| {
            try std.testing.expect(std.mem.indexOfScalar(u8, span.text, '\n') == null);
            try std.testing.expect(std.meta.eql(span.style, theme.highlights.md_code_block));
        }
    }

    const renderer = NodeRenderer.initDefault();
    try std.testing.expectEqual(lines.items.len, renderer.lineCountForNode(node, &cb.buffer_registry));
}

test "workflow render twice with markDirty between leaks nothing" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try cb.appendToolCallNode(null, "workflow", "id1", "{\"script\":\"local a = 1\\nreturn 'x'\"}");
    node.collapsed = false;

    const theme = Theme.defaultTheme();

    inline for (0..2) |_| {
        var lines: std.ArrayList(StyledLine) = .empty;
        defer Theme.freeStyledLines(&lines, allocator);
        try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);
        try std.testing.expectEqual(@as(usize, 3), lines.items.len);
        node.markDirty();
    }
}

test "workflow tool_call with malformed script JSON falls back to generic header" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    // Missing `script` key: the workflow arm declines, the generic header
    // path runs without crashing.
    const node = try cb.appendToolCallNode(null, "workflow", "id1", "{\"name\":\"build\"}");
    node.collapsed = true;

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);
    const header = try lines.items[0].toText(allocator);
    defer allocator.free(header);
    // Generic `Name(arg)` header with the first string field as the arg.
    try std.testing.expectEqualStrings("Workflow(build)", header);

    const renderer = NodeRenderer.initDefault();
    try std.testing.expectEqual(lines.items.len, renderer.lineCountForNode(node, &cb.buffer_registry));
}

test "workflow tool_call over 16KiB keeps line count and render in lockstep" {
    const allocator = std.testing.allocator;

    // Build a script far larger than the 16 KiB FBA the generic count path
    // uses. The old workflow count arm bailed to the generic 1-2 count on
    // OOM while the renderer drew the full body, corrupting scroll math.
    // A line is `local v<i> = <i>` (no JSON metacharacters but the inter-line
    // `\n`), so the JSON wrapper only escapes the newlines.
    const line_count = 2000; // ~16 chars/line -> ~32 KiB decoded script
    const script = comptime blk: {
        @setEvalBranchQuota(2_000_000);
        var buf: []const u8 = "";
        for (0..line_count) |i| {
            if (i != 0) buf = buf ++ "\n";
            buf = buf ++ std.fmt.comptimePrint("local v{d} = {d}", .{ i, i });
        }
        break :blk buf;
    };
    // JSON-escape: replace each real newline with the two-byte `\n` escape.
    const json_script = comptime blk: {
        @setEvalBranchQuota(2_000_000);
        var out: []const u8 = "";
        for (script) |c| {
            out = out ++ (if (c == '\n') "\\n" else &[_]u8{c});
        }
        break :blk out;
    };
    const raw = "{\"script\":\"" ++ json_script ++ "\"}";
    try std.testing.expect(raw.len > 16 * 1024);

    const theme = Theme.defaultTheme();
    const renderer = NodeRenderer.initDefault();

    // Collapsed: count == rendered lines (header + fold hint == 2).
    {
        var cb = try @import("Conversation.zig").init(allocator, 0, "test");
        defer cb.deinit();
        const node = try cb.appendToolCallNode(null, "workflow", "id1", raw);
        node.collapsed = true;

        var lines: std.ArrayList(StyledLine) = .empty;
        defer Theme.freeStyledLines(&lines, allocator);
        try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

        try std.testing.expectEqual(@as(usize, 2), lines.items.len);
        try std.testing.expectEqual(lines.items.len, renderer.lineCountForNode(node, &cb.buffer_registry));

        // The count arm actually parsed the big script (not the generic
        // fallback): the fold-aware header must name all script lines.
        const header = try lines.items[0].toText(allocator);
        defer allocator.free(header);
        try std.testing.expectEqualStrings("Workflow(2000 lines)", header);
    }

    // Expanded: count == rendered lines (header + one line per script line).
    {
        var cb = try @import("Conversation.zig").init(allocator, 0, "test");
        defer cb.deinit();
        const node = try cb.appendToolCallNode(null, "workflow", "id1", raw);
        node.collapsed = false;

        var lines: std.ArrayList(StyledLine) = .empty;
        defer Theme.freeStyledLines(&lines, allocator);
        try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

        try std.testing.expectEqual(@as(usize, 1 + line_count), lines.items.len);
        try std.testing.expectEqual(lines.items.len, renderer.lineCountForNode(node, &cb.buffer_registry));
    }
}

/// Render `node` (a workflow tool_call) and return the header line's text.
/// Caller frees the returned slice. Also asserts the header is exactly one
/// line and that the rendered line count matches `lineCountForNode` (the
/// lockstep invariant: the done-count suffix changes only text, not lines).
fn renderWorkflowHeaderText(
    cb: *@import("Conversation.zig"),
    node: *const Node,
    theme: *const Theme,
    allocator: Allocator,
) ![]const u8 {
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);
    try renderDefault(node, &lines, allocator, theme, &cb.buffer_registry);
    const renderer = NodeRenderer.initDefault();
    try std.testing.expectEqual(lines.items.len, renderer.lineCountForNode(node, &cb.buffer_registry));
    return lines.items[0].toText(allocator);
}

test "workflow header shows live N/M done as linked children finish" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    // A collapsed workflow tool_call (header is the only line that carries
    // the count) plus two children linked to it by its tool_use_id.
    const wf = try cb.appendToolCallNode(null, "workflow", "wf1", "{\"script\":\"local a = 1\\nreturn 'x'\"}");
    wf.collapsed = true;
    const child_a = try cb.spawnSubagentLinked("childA", "", "wf1");
    const child_b = try cb.spawnSubagentLinked("childB", "", "wf1");
    // Both links resolved this workflow node and stamped its owner.
    try std.testing.expect(wf.workflow_owner != null);

    const theme = Theme.defaultTheme();

    // Both children `ready` -> 0/2 done.
    {
        const header = try renderWorkflowHeaderText(&cb, wf, &theme, allocator);
        defer allocator.free(header);
        try std.testing.expectEqualStrings("Workflow(2 lines) 0/2 done", header);
    }

    // Drive child A to `done` (tail is assistant_text) -> 1/2 done.
    _ = try child_a.appendNode(null, .assistant_text, "done A");
    {
        const header = try renderWorkflowHeaderText(&cb, wf, &theme, allocator);
        defer allocator.free(header);
        try std.testing.expectEqualStrings("Workflow(2 lines) 1/2 done", header);
    }

    // Drive child B to `failed` (tail is err) -> 2/2 done (failed counts).
    _ = try child_b.appendNode(null, .err, "boom B");
    {
        const header = try renderWorkflowHeaderText(&cb, wf, &theme, allocator);
        defer allocator.free(header);
        try std.testing.expectEqualStrings("Workflow(2 lines) 2/2 done", header);
    }
}

test "workflow header reads M/M done once the workflow tool_result lands" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const wf = try cb.appendToolCallNode(null, "workflow", "wf1", "{\"script\":\"local a = 1\\nreturn 'x'\"}");
    wf.collapsed = true;
    _ = try cb.spawnSubagentLinked("childA", "", "wf1");
    _ = try cb.spawnSubagentLinked("childB", "", "wf1");

    const theme = Theme.defaultTheme();

    // No child finished, but the workflow call returned: all children final.
    _ = try cb.appendNode(wf, .tool_result, "workflow complete");
    const header = try renderWorkflowHeaderText(&cb, wf, &theme, allocator);
    defer allocator.free(header);
    try std.testing.expectEqualStrings("Workflow(2 lines) 2/2 done", header);
}

test "workflow header unchanged when no children are linked" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const wf = try cb.appendToolCallNode(null, "workflow", "wf1", "{\"script\":\"local a = 1\\nreturn 'x'\"}");
    wf.collapsed = true;
    // No spawnSubagentLinked: workflow_owner stays null.
    try std.testing.expect(wf.workflow_owner == null);

    const theme = Theme.defaultTheme();
    const header = try renderWorkflowHeaderText(&cb, wf, &theme, allocator);
    defer allocator.free(header);
    try std.testing.expectEqualStrings("Workflow(2 lines)", header);
}

test "workflow header re-render with markDirty between leaks nothing" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const wf = try cb.appendToolCallNode(null, "workflow", "wf1", "{\"script\":\"local a = 1\\nreturn 'x'\"}");
    wf.collapsed = true;
    _ = try cb.spawnSubagentLinked("childA", "", "wf1");
    _ = try cb.spawnSubagentLinked("childB", "", "wf1");

    const theme = Theme.defaultTheme();
    // The done-count suffix is synthesized into an owned span; render twice
    // (with a dirty bump between) and free each pass to catch a leak.
    inline for (0..2) |_| {
        var lines: std.ArrayList(StyledLine) = .empty;
        defer Theme.freeStyledLines(&lines, allocator);
        try renderDefault(wf, &lines, allocator, &theme, &cb.buffer_registry);
        try std.testing.expectEqual(@as(usize, 2), lines.items.len);
        wf.markDirty();
    }
}

test "workflow-spawned subagent_link renders indented under its workflow" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "parent");
    defer cb.deinit();

    // A workflow tool_call and a child linked to it: the link is grouped.
    _ = try cb.appendToolCallNode(null, "workflow", "wf1", "{\"script\":\"x\"}");
    _ = try cb.spawnSubagentLinked("scout", "", "wf1");
    // A plain link with no spawning workflow: rendered flush.
    _ = try cb.spawnSubagent("solo", "");

    const grouped_link = cb.tree.root_children.items[1];
    const plain_link = cb.tree.root_children.items[2];
    try std.testing.expect(grouped_link.spawning_tool_node != null);
    try std.testing.expect(plain_link.spawning_tool_node == null);

    const theme = Theme.defaultTheme();
    const renderer = NodeRenderer.initDefault();

    // Grouped: prefixed with the `  └ ` connector. Both children are empty
    // (ready), so the status reads `ready`.
    {
        var lines: std.ArrayList(StyledLine) = .empty;
        defer Theme.freeStyledLines(&lines, allocator);
        try renderDefault(grouped_link, &lines, allocator, &theme, &cb.buffer_registry);
        try std.testing.expectEqual(@as(usize, 1), lines.items.len);
        try std.testing.expectEqual(lines.items.len, renderer.lineCountForNode(grouped_link, &cb.buffer_registry));
        const text = try lines.items[0].toText(allocator);
        defer allocator.free(text);
        try std.testing.expectEqualStrings("  \u{2514} [subagent: scout] ready", text);
    }

    // Plain: unchanged, no connector prefix.
    {
        var lines: std.ArrayList(StyledLine) = .empty;
        defer Theme.freeStyledLines(&lines, allocator);
        try renderDefault(plain_link, &lines, allocator, &theme, &cb.buffer_registry);
        try std.testing.expectEqual(@as(usize, 1), lines.items.len);
        const text = try lines.items[0].toText(allocator);
        defer allocator.free(text);
        try std.testing.expectEqualStrings("[subagent: solo] ready", text);
    }
}

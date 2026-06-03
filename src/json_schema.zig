//! Minimal JSON-Schema validator used by the tool registry to reject malformed
//! tool inputs before dispatch, and by structured-output spawns to validate a
//! subagent's emitted object against its declared output schema.
//!
//! Supported keywords:
//! - `type`: object, string, integer, number, boolean, array (checked at every
//!   level, not just the root).
//! - `required`: list of field names that must be present.
//! - `properties`: map of field names to a sub-schema, validated recursively to
//!   arbitrary depth.
//! - `items`: element sub-schema for arrays, validated recursively per element.
//! - `enum`: the scalar value must equal one of the listed members.
//! - `pattern`: ANCHORED LITERAL/PREFIX ONLY. The repo has no regex engine
//!   (Zig's stdlib ships none and we do not pull a dependency), so a `pattern`
//!   is interpreted as a literal, not a regex: regex metacharacters are NOT
//!   special. A leading `^` and trailing `$` are stripped as anchors; the
//!   remaining body is matched as an exact string (`^body$`) or as a required
//!   prefix (`^body`). A pattern without a leading `^` is treated as a required
//!   substring. This covers the common version-tag / id-prefix cases; richer
//!   regex is out of scope until a real engine is available.
//! - `additionalProperties:false`: reject any input key not named in
//!   `properties` (enforced at every object level).
//!
//! Unknown schema keywords are silently accepted. Unknown `type` strings do not
//! block (forward-compatible).

const std = @import("std");
const testing = std.testing;

/// Errors raised when an input does not conform to a schema, plus the
/// allocator and JSON-scanner errors that may surface while parsing either.
pub const ValidationError = error{
    NotAnObject,
    MissingRequiredField,
    WrongFieldType,
    InvalidInput,
    MalformedSchema,
    /// A scalar value was not among the schema's `enum` members.
    EnumMismatch,
    /// A string did not satisfy the schema's `pattern` (literal/prefix subset).
    PatternMismatch,
    /// An input key was not declared in `properties` while the schema set
    /// `additionalProperties:false`.
    UnexpectedProperty,
} || std.mem.Allocator.Error || std.json.ParseError(std.json.Scanner);

/// Validate `input_json` against `schema_json`. Returns `void` on success or
/// a `ValidationError` describing the first violation encountered.
pub fn validate(
    allocator: std.mem.Allocator,
    schema_json: []const u8,
    input_json: []const u8,
) ValidationError!void {
    const schema = try std.json.parseFromSlice(std.json.Value, allocator, schema_json, .{});
    defer schema.deinit();
    const input = try std.json.parseFromSlice(std.json.Value, allocator, input_json, .{});
    defer input.deinit();

    // The root schema must be an object schema and the root input must be a
    // JSON object; `NotAnObject` is the historical signal for "input isn't an
    // object" so callers keep one error name for that cause.
    if (schema.value != .object) return error.MalformedSchema;
    if (input.value != .object) return error.NotAnObject;

    try validateValue(schema.value, input.value);
}

/// Recursively validate `value` against the schema node `schema`. Applies, at
/// every level: `type`, `enum`, `pattern` (string only), `required`,
/// `properties` (recursing per declared key), `items` (recursing per element),
/// and `additionalProperties:false`. Arbitrary nesting depth is supported via
/// self-recursion on `properties`/`items` sub-schemas.
fn validateValue(schema: std.json.Value, value: std.json.Value) ValidationError!void {
    const schema_obj = switch (schema) {
        .object => |o| o,
        else => return error.MalformedSchema,
    };

    // `type`: when declared, the value must match it before any keyword that
    // assumes a particular shape runs.
    if (schema_obj.get("type")) |type_val| {
        const expected = switch (type_val) {
            .string => |s| s,
            else => return error.MalformedSchema,
        };
        if (!typeMatches(expected, value)) return error.WrongFieldType;
    }

    // `enum`: the scalar value must equal one of the listed members.
    if (schema_obj.get("enum")) |enum_val| {
        const members = switch (enum_val) {
            .array => |a| a.items,
            else => return error.MalformedSchema,
        };
        var matched = false;
        for (members) |member| {
            if (jsonScalarEql(member, value)) {
                matched = true;
                break;
            }
        }
        if (!matched) return error.EnumMismatch;
    }

    // `pattern`: literal/prefix/substring match (no regex engine in-tree).
    if (schema_obj.get("pattern")) |pattern_val| {
        const pattern = switch (pattern_val) {
            .string => |s| s,
            else => return error.MalformedSchema,
        };
        // Only strings are matched against a pattern; a non-string value with
        // a declared string type already failed the type check above, and a
        // pattern on a non-string schema is silently a no-op for non-strings.
        if (value == .string and !matchesAnchoredPattern(pattern, value.string)) {
            return error.PatternMismatch;
        }
    }

    // Object-shaped keywords: required, properties, additionalProperties.
    if (value == .object) {
        const input_obj = value.object;

        if (schema_obj.get("required")) |required| {
            const items = switch (required) {
                .array => |a| a.items,
                else => return error.MalformedSchema,
            };
            for (items) |field| {
                const name = switch (field) {
                    .string => |s| s,
                    else => return error.MalformedSchema,
                };
                if (!input_obj.contains(name)) return error.MissingRequiredField;
            }
        }

        const props_obj: ?std.json.ObjectMap = if (schema_obj.get("properties")) |props|
            switch (props) {
                .object => |o| o,
                else => return error.MalformedSchema,
            }
        else
            null;

        const additional_allowed = if (schema_obj.get("additionalProperties")) |ap|
            switch (ap) {
                .bool => |b| b,
                // Object/other forms (sub-schema for additional props) are not
                // modeled; treat anything that isn't `false` as permissive.
                else => true,
            }
        else
            true;

        for (input_obj.keys(), input_obj.values()) |name, child| {
            const child_spec = if (props_obj) |po| po.get(name) else null;
            if (child_spec) |spec| {
                try validateValue(spec, child);
            } else if (!additional_allowed) {
                return error.UnexpectedProperty;
            }
            // Unknown key with additionalProperties unset/true: allowed.
        }
    }

    // Array `items`: validate each element against the element sub-schema.
    if (value == .array) {
        if (schema_obj.get("items")) |items_schema| {
            for (value.array.items) |item| {
                try validateValue(items_schema, item);
            }
        }
    }
}

/// Compare two JSON scalars for equality (used for `enum` membership).
/// Only scalar variants are meaningful for enums; composite values never match.
fn jsonScalarEql(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .string => |s| b == .string and std.mem.eql(u8, s, b.string),
        .integer => |i| b == .integer and i == b.integer,
        .float => |f| b == .float and f == b.float,
        .bool => |x| b == .bool and x == b.bool,
        .null => b == .null,
        else => false,
    };
}

/// Match a string against an anchored literal/prefix/substring pattern. This is
/// NOT a regex engine: characters are matched literally. A leading `^` anchors
/// the start; a trailing `$` anchors the end. `^body$` requires an exact match,
/// `^body` requires `body` as a prefix, and a pattern with no `^` matches if
/// `body` appears anywhere (substring). See the module doc-comment.
fn matchesAnchoredPattern(pattern: []const u8, text: []const u8) bool {
    var body = pattern;
    var anchored_start = false;
    var anchored_end = false;
    if (body.len > 0 and body[0] == '^') {
        anchored_start = true;
        body = body[1..];
    }
    if (body.len > 0 and body[body.len - 1] == '$') {
        anchored_end = true;
        body = body[0 .. body.len - 1];
    }
    if (anchored_start and anchored_end) return std.mem.eql(u8, text, body);
    if (anchored_start) return std.mem.startsWith(u8, text, body);
    if (anchored_end) return std.mem.endsWith(u8, text, body);
    return std.mem.indexOf(u8, text, body) != null;
}

fn typeMatches(expected: []const u8, value: std.json.Value) bool {
    if (std.mem.eql(u8, expected, "string")) return value == .string;
    if (std.mem.eql(u8, expected, "integer")) return value == .integer;
    if (std.mem.eql(u8, expected, "number")) return value == .integer or value == .float;
    if (std.mem.eql(u8, expected, "boolean")) return value == .bool;
    if (std.mem.eql(u8, expected, "object")) return value == .object;
    if (std.mem.eql(u8, expected, "array")) return value == .array;
    return true; // unknown schema type: don't block
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "missing required field is detected" {
    const schema =
        \\{"type":"object","required":["cmd"],"properties":{"cmd":{"type":"string"}}}
    ;
    const input = "{\"other\":\"x\"}";
    try testing.expectError(error.MissingRequiredField, validate(testing.allocator, schema, input));
}

test "wrong type is detected" {
    const schema =
        \\{"type":"object","required":["n"],"properties":{"n":{"type":"integer"}}}
    ;
    const input = "{\"n\":\"not a number\"}";
    try testing.expectError(error.WrongFieldType, validate(testing.allocator, schema, input));
}

test "valid input passes" {
    const schema =
        \\{"type":"object","required":["cmd"],"properties":{"cmd":{"type":"string"}}}
    ;
    const input = "{\"cmd\":\"ls\"}";
    try validate(testing.allocator, schema, input);
}

test "non-object schema is MalformedSchema" {
    const schema = "true";
    const input = "{}";
    try testing.expectError(error.MalformedSchema, validate(testing.allocator, schema, input));
}

test "non-string type spec is MalformedSchema" {
    const schema =
        \\{"type":"object","properties":{"x":{"type":5}}}
    ;
    const input = "{\"x\":1}";
    try testing.expectError(error.MalformedSchema, validate(testing.allocator, schema, input));
}

test "non-array required is MalformedSchema" {
    const schema =
        \\{"type":"object","required":"cmd"}
    ;
    const input = "{\"cmd\":\"ls\"}";
    try testing.expectError(error.MalformedSchema, validate(testing.allocator, schema, input));
}

test "validate: nested object property with wrong type rejected" {
    const allocator = std.testing.allocator;

    const schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "config": {
        \\      "type": "object",
        \\      "properties": {
        \\        "count": {"type": "integer"}
        \\      }
        \\    }
        \\  }
        \\}
    ;
    const input =
        \\{"config": {"count": "not a number"}}
    ;

    const result = validate(allocator, schema, input);
    try std.testing.expectError(error.WrongFieldType, result);
}

test "validate: array items type mismatch rejected" {
    const allocator = std.testing.allocator;

    const schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "names": {
        \\      "type": "array",
        \\      "items": {"type": "string"}
        \\    }
        \\  }
        \\}
    ;
    const input =
        \\{"names": [1, 2, 3]}
    ;

    const result = validate(allocator, schema, input);
    try std.testing.expectError(error.WrongFieldType, result);
}

test "validate: nested validation passes on well-formed input" {
    const allocator = std.testing.allocator;

    const schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "config": {
        \\      "type": "object",
        \\      "properties": {
        \\        "count": {"type": "integer"}
        \\      }
        \\    }
        \\  }
        \\}
    ;
    const input =
        \\{"config": {"count": 42}}
    ;

    try validate(allocator, schema, input);
}

test "validate: enum rejects out-of-set value" {
    const allocator = std.testing.allocator;
    const schema =
        \\{"type":"object","properties":{"role":{"type":"string","enum":["planner","reviewer"]}}}
    ;
    const input =
        \\{"role":"hacker"}
    ;
    try testing.expectError(error.EnumMismatch, validate(allocator, schema, input));
}

test "validate: enum accepts in-set value" {
    const allocator = std.testing.allocator;
    const schema =
        \\{"type":"object","properties":{"role":{"type":"string","enum":["planner","reviewer"]}}}
    ;
    const input =
        \\{"role":"reviewer"}
    ;
    try validate(allocator, schema, input);
}

test "validate: pattern rejects non-matching string" {
    const allocator = std.testing.allocator;
    // Anchored literal pattern: the value must equal "v1" exactly.
    const schema =
        \\{"type":"object","properties":{"tag":{"type":"string","pattern":"^v1$"}}}
    ;
    const input =
        \\{"tag":"v2"}
    ;
    try testing.expectError(error.PatternMismatch, validate(allocator, schema, input));
}

test "validate: pattern accepts matching prefix" {
    const allocator = std.testing.allocator;
    // Anchored prefix pattern: the value must start with "v".
    const schema =
        \\{"type":"object","properties":{"tag":{"type":"string","pattern":"^v"}}}
    ;
    const input =
        \\{"tag":"v123"}
    ;
    try validate(allocator, schema, input);
}

test "validate: nested object validated to arbitrary depth" {
    const allocator = std.testing.allocator;
    // Three levels deep: outer -> middle -> inner.count must be an integer.
    const schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "outer": {
        \\      "type": "object",
        \\      "properties": {
        \\        "middle": {
        \\          "type": "object",
        \\          "properties": {
        \\            "count": {"type": "integer"}
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ;
    const input =
        \\{"outer": {"middle": {"count": "not a number"}}}
    ;
    try testing.expectError(error.WrongFieldType, validate(allocator, schema, input));
}

test "validate: additionalProperties:false rejects extra keys" {
    const allocator = std.testing.allocator;
    const schema =
        \\{"type":"object","additionalProperties":false,"properties":{"cmd":{"type":"string"}}}
    ;
    const input =
        \\{"cmd":"ls","extra":"nope"}
    ;
    try testing.expectError(error.UnexpectedProperty, validate(allocator, schema, input));
}

test "validate: additionalProperties:false allows declared keys" {
    const allocator = std.testing.allocator;
    const schema =
        \\{"type":"object","additionalProperties":false,"properties":{"cmd":{"type":"string"}}}
    ;
    const input =
        \\{"cmd":"ls"}
    ;
    try validate(allocator, schema, input);
}

test "validate: additionalProperties:false enforced in nested objects" {
    const allocator = std.testing.allocator;
    const schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "config": {
        \\      "type": "object",
        \\      "additionalProperties": false,
        \\      "properties": {"count": {"type": "integer"}}
        \\    }
        \\  }
        \\}
    ;
    const input =
        \\{"config": {"count": 1, "stray": true}}
    ;
    try testing.expectError(error.UnexpectedProperty, validate(allocator, schema, input));
}

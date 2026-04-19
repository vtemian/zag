//! Minimal JSON-Schema validator used by the tool registry to reject malformed
//! tool inputs before dispatch.
//!
//! Supported keywords: `type` (only for the root `"object"` check),
//! `required` (list of field names), and `properties` (map of field names to
//! a spec whose `type` is checked against the input value). Unknown fields
//! are allowed; unknown schema keywords are silently accepted.
//!
//! Anything beyond this subset (nested schemas, enum, pattern, etc.) is out of
//! scope until a tool actually needs it.

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

    const schema_obj = switch (schema.value) {
        .object => |o| o,
        else => return error.MalformedSchema,
    };
    const input_obj = switch (input.value) {
        .object => |o| o,
        else => return error.NotAnObject,
    };

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

    if (schema_obj.get("properties")) |props| {
        const props_obj = switch (props) {
            .object => |o| o,
            else => return error.MalformedSchema,
        };
        for (input_obj.keys(), input_obj.values()) |name, value| {
            const spec = props_obj.get(name) orelse continue; // unknown field: allow
            const spec_obj = switch (spec) {
                .object => |o| o,
                else => return error.MalformedSchema,
            };
            const type_val = spec_obj.get("type") orelse continue; // untyped spec: accept
            const expected = switch (type_val) {
                .string => |s| s,
                else => return error.MalformedSchema,
            };
            if (!typeMatches(expected, value)) return error.WrongFieldType;

            // Nested object: descend one level into declared properties and
            // check each child's declared type against the actual value.
            if (std.mem.eql(u8, expected, "object")) {
                if (spec_obj.get("properties")) |nested_props| {
                    const nested_obj = switch (nested_props) {
                        .object => |o| o,
                        else => return error.MalformedSchema,
                    };
                    const value_obj = switch (value) {
                        .object => |o| o,
                        else => return error.InvalidInput,
                    };
                    try validateNestedObject(nested_obj, value_obj);
                }
            }

            // Array items: validate each element against items.type.
            if (std.mem.eql(u8, expected, "array")) {
                if (spec_obj.get("items")) |items_schema| {
                    const items_obj = switch (items_schema) {
                        .object => |o| o,
                        else => return error.MalformedSchema,
                    };
                    const items_type_val = items_obj.get("type") orelse continue;
                    const items_expected = switch (items_type_val) {
                        .string => |s| s,
                        else => return error.MalformedSchema,
                    };
                    const array_items = switch (value) {
                        .array => |a| a.items,
                        else => return error.InvalidInput,
                    };
                    for (array_items) |item| {
                        if (!typeMatches(items_expected, item)) {
                            return error.InvalidInput;
                        }
                    }
                }
            }
        }
    }
}

/// Validate one nested level: each key present in the input object is checked
/// against its declared `type` in the nested properties map. No further
/// descent; deeper schemas are out of scope for this validator.
fn validateNestedObject(
    nested_props: std.json.ObjectMap,
    input_obj: std.json.ObjectMap,
) ValidationError!void {
    for (input_obj.keys(), input_obj.values()) |name, value| {
        const spec = nested_props.get(name) orelse continue;
        const spec_obj = switch (spec) {
            .object => |o| o,
            else => return error.MalformedSchema,
        };
        const type_val = spec_obj.get("type") orelse continue;
        const expected = switch (type_val) {
            .string => |s| s,
            else => return error.MalformedSchema,
        };
        if (!typeMatches(expected, value)) return error.InvalidInput;
    }
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
    try std.testing.expectError(error.InvalidInput, result);
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
    try std.testing.expectError(error.InvalidInput, result);
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

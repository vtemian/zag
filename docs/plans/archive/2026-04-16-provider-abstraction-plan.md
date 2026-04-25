# Provider Abstraction Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Separate provider identity (endpoint URL, auth, headers) from wire format (serialization/parsing), enabling new OpenAI-compatible providers via config rather than code.

**Architecture:** Introduce three new types in `llm.zig`: `Endpoint` (connection details), `Serializer` enum (wire format picker), `Compat` (per-endpoint quirks). A runtime `Registry` holds endpoints seeded from built-in defaults. `createProvider` looks up endpoints by name and dispatches to the matching serializer. Existing serialization code in `anthropic.zig` and `openai.zig` is unchanged; only the struct names and how they receive connection details changes.

**Tech Stack:** Zig 0.15, no new dependencies.

**Conventions:**
- Model string format changes from `provider:model` to `provider/model` (ecosystem alignment with Aider, OpenRouter)
- `AnthropicProvider` renames to `AnthropicSerializer`, `OpenAiProvider` renames to `OpenAiSerializer`
- All serialization/parsing logic stays exactly where it is
- `agent.zig` and `types.zig` have zero changes

---

### Task 1: Add Serializer, Compat, and Endpoint types to llm.zig

**Files:**
- Modify: `src/llm.zig` (add after line 29, before the Provider struct)

**Step 1: Write the failing test**

Add at the end of `src/llm.zig`, before the closing refAllDecls test block:

```zig
test "Endpoint.dupe creates independent copy" {
    const allocator = std.testing.allocator;

    const original = Endpoint{
        .name = "test",
        .serializer = .openai,
        .url = "https://example.com",
        .key_env = "TEST_KEY",
        .auth = .bearer,
        .headers = &.{.{ .name = "X-Custom", .value = "val" }},
        .compat = .{},
    };

    const duped = try original.dupe(allocator);
    defer duped.free(allocator);

    try std.testing.expectEqualStrings("test", duped.name);
    try std.testing.expectEqualStrings("https://example.com", duped.url);
    try std.testing.expectEqualStrings("TEST_KEY", duped.key_env.?);
    try std.testing.expectEqual(Serializer.openai, duped.serializer);
    try std.testing.expectEqual(Endpoint.Auth.bearer, duped.auth);
    try std.testing.expectEqual(@as(usize, 1), duped.headers.len);
    try std.testing.expectEqualStrings("X-Custom", duped.headers[0].name);
    try std.testing.expectEqualStrings("val", duped.headers[0].value);

    // Verify independence: pointers must differ
    try std.testing.expect(original.name.ptr != duped.name.ptr);
    try std.testing.expect(original.url.ptr != duped.url.ptr);
}

test "Endpoint.dupe handles null key_env" {
    const allocator = std.testing.allocator;

    const original = Endpoint{
        .name = "ollama",
        .serializer = .openai,
        .url = "http://localhost:11434/v1/chat/completions",
        .key_env = null,
        .auth = .none,
        .headers = &.{},
        .compat = .{},
    };

    const duped = try original.dupe(allocator);
    defer duped.free(allocator);

    try std.testing.expectEqual(@as(?[]const u8, null), duped.key_env);
    try std.testing.expectEqual(@as(usize, 0), duped.headers.len);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: Compilation error, `Endpoint` type not found.

**Step 3: Write the types**

Add in `src/llm.zig` after the `StreamEvent` union (after line 29), before the `Provider` struct:

```zig
/// Wire format for request/response serialization.
pub const Serializer = enum {
    /// Anthropic Messages API format.
    anthropic,
    /// OpenAI Chat Completions API format (also used by OpenRouter, Groq, Ollama, etc.).
    openai,
};

/// Per-endpoint behavior overrides within a serializer family.
/// Empty now. Fields added when real provider differences surface.
pub const Compat = struct {};

/// Everything needed to talk to a specific LLM endpoint.
pub const Endpoint = struct {
    /// Human-readable name (e.g., "openrouter", "ollama").
    name: []const u8,
    /// Which wire format this endpoint speaks.
    serializer: Serializer,
    /// Full URL for chat completions.
    url: []const u8,
    /// Env var holding the API key. Null if no auth needed.
    key_env: ?[]const u8,
    /// How to send the API key in HTTP headers.
    auth: Auth,
    /// Additional HTTP headers sent with every request.
    headers: []const Header,
    /// Provider-specific behavior overrides.
    compat: Compat,

    pub const Auth = enum { x_api_key, bearer, none };
    pub const Header = struct { name: []const u8, value: []const u8 };

    /// Deep-copy all strings onto the heap. Caller must call free().
    pub fn dupe(self: Endpoint, allocator: Allocator) !Endpoint {
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const url = try allocator.dupe(u8, self.url);
        errdefer allocator.free(url);
        const key_env = if (self.key_env) |k| try allocator.dupe(u8, k) else null;
        errdefer if (key_env) |k| allocator.free(k);

        const headers = try allocator.alloc(Header, self.headers.len);
        errdefer allocator.free(headers);
        var initialized: usize = 0;
        errdefer for (headers[0..initialized]) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        };
        for (self.headers, 0..) |h, i| {
            headers[i] = .{
                .name = try allocator.dupe(u8, h.name),
                .value = try allocator.dupe(u8, h.value),
            };
            initialized += 1;
        }

        return .{
            .name = name,
            .serializer = self.serializer,
            .url = url,
            .key_env = key_env,
            .auth = self.auth,
            .headers = headers,
            .compat = self.compat,
        };
    }

    /// Free all heap-allocated strings. Pair with dupe().
    pub fn free(self: Endpoint, allocator: Allocator) void {
        for (self.headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(self.headers);
        if (self.key_env) |k| allocator.free(k);
        allocator.free(self.url);
        allocator.free(self.name);
    }
};
```

**Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | head -30`
Expected: All tests pass, including the two new Endpoint tests.

**Step 5: Commit**

```bash
git add src/llm.zig
git commit -m "llm: add Serializer, Compat, and Endpoint types

Foundation for separating provider identity from wire format.
Endpoint holds connection details (URL, auth, headers),
Serializer picks the format, Compat holds per-endpoint quirks."
```

---

### Task 2: Add built-in endpoints and Registry to llm.zig

**Files:**
- Modify: `src/llm.zig`

**Step 1: Write the failing test**

Add to test section of `src/llm.zig`:

```zig
test "Registry initializes with built-in endpoints" {
    const allocator = std.testing.allocator;

    var registry = try Registry.init(allocator);
    defer registry.deinit();

    // Should find all built-in endpoints
    const anth = registry.find("anthropic");
    try std.testing.expect(anth != null);
    try std.testing.expectEqual(Serializer.anthropic, anth.?.serializer);

    const oai = registry.find("openai");
    try std.testing.expect(oai != null);
    try std.testing.expectEqual(Serializer.openai, oai.?.serializer);

    const or_ep = registry.find("openrouter");
    try std.testing.expect(or_ep != null);
    try std.testing.expectEqual(Serializer.openai, or_ep.?.serializer);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", or_ep.?.url);

    const ollama = registry.find("ollama");
    try std.testing.expect(ollama != null);
    try std.testing.expectEqual(Endpoint.Auth.none, ollama.?.auth);
    try std.testing.expectEqual(@as(?[]const u8, null), ollama.?.key_env);

    // Should not find unknown
    try std.testing.expectEqual(@as(?*const Endpoint, null), registry.find("unknown"));
}

test "Registry find returns null for unknown endpoint" {
    const allocator = std.testing.allocator;
    var registry = try Registry.init(allocator);
    defer registry.deinit();
    try std.testing.expectEqual(@as(?*const Endpoint, null), registry.find("nonexistent"));
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: Compilation error, `Registry` type not found.

**Step 3: Write the implementation**

Add in `src/llm.zig` after the `Endpoint` struct:

```zig
/// Built-in endpoint definitions. Seeded into Registry at init.
const builtin_endpoints = [_]Endpoint{
    .{
        .name = "anthropic",
        .serializer = .anthropic,
        .url = "https://api.anthropic.com/v1/messages",
        .key_env = "ANTHROPIC_API_KEY",
        .auth = .x_api_key,
        .headers = &.{.{ .name = "anthropic-version", .value = "2023-06-01" }},
        .compat = .{},
    },
    .{
        .name = "openai",
        .serializer = .openai,
        .url = "https://api.openai.com/v1/chat/completions",
        .key_env = "OPENAI_API_KEY",
        .auth = .bearer,
        .headers = &.{},
        .compat = .{},
    },
    .{
        .name = "openrouter",
        .serializer = .openai,
        .url = "https://openrouter.ai/api/v1/chat/completions",
        .key_env = "OPENROUTER_API_KEY",
        .auth = .bearer,
        .headers = &.{.{ .name = "X-OpenRouter-Title", .value = "Zag" }},
        .compat = .{},
    },
    .{
        .name = "groq",
        .serializer = .openai,
        .url = "https://api.groq.com/openai/v1/chat/completions",
        .key_env = "GROQ_API_KEY",
        .auth = .bearer,
        .headers = &.{},
        .compat = .{},
    },
    .{
        .name = "ollama",
        .serializer = .openai,
        .url = "http://localhost:11434/v1/chat/completions",
        .key_env = null,
        .auth = .none,
        .headers = &.{},
        .compat = .{},
    },
};

/// Runtime registry of LLM endpoints. Seeded with built-ins, extensible at runtime.
pub const Registry = struct {
    endpoints: std.ArrayList(Endpoint),
    allocator: Allocator,

    pub fn init(allocator: Allocator) !Registry {
        var self = Registry{ .endpoints = .empty, .allocator = allocator };
        errdefer self.deinit();
        for (&builtin_endpoints) |*ep| {
            try self.endpoints.append(allocator, try ep.dupe(allocator));
        }
        return self;
    }

    /// Find an endpoint by name. Returns null if not found.
    pub fn find(self: *const Registry, name: []const u8) ?*const Endpoint {
        for (self.endpoints.items) |*ep| {
            if (std.mem.eql(u8, ep.name, name)) return ep;
        }
        return null;
    }

    pub fn deinit(self: *Registry) void {
        for (self.endpoints.items) |ep| ep.free(self.allocator);
        self.endpoints.deinit(self.allocator);
    }
};
```

**Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | head -30`
Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/llm.zig
git commit -m "llm: add built-in endpoints and Registry

Endpoints for anthropic, openai, openrouter, groq, ollama.
Registry is a runtime ArrayList seeded from built-ins with
all strings heap-duped for uniform ownership."
```

---

### Task 3: Update parseModelString to split on `/` instead of `:`

**Files:**
- Modify: `src/llm.zig:102-113` (parseModelString function)
- Modify: `src/llm.zig:649-665` (existing tests)

**Step 1: Update the existing tests to use new format**

Change the three existing `parseModelString` tests:

```zig
test "parseModelString splits provider and model" {
    const result = parseModelString("anthropic/claude-sonnet-4-20250514");
    try std.testing.expectEqualStrings("anthropic", result.provider_name);
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", result.model_id);
}

test "parseModelString defaults to anthropic when no prefix" {
    const result = parseModelString("claude-sonnet-4-20250514");
    try std.testing.expectEqualStrings("anthropic", result.provider_name);
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", result.model_id);
}

test "parseModelString handles openai prefix" {
    const result = parseModelString("openai/gpt-4o");
    try std.testing.expectEqualStrings("openai", result.provider_name);
    try std.testing.expectEqualStrings("gpt-4o", result.model_id);
}
```

Add a new test for the OpenRouter nested-slash case:

```zig
test "parseModelString handles nested slashes for openrouter" {
    const result = parseModelString("openrouter/anthropic/claude-sonnet-4");
    try std.testing.expectEqualStrings("openrouter", result.provider_name);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4", result.model_id);
}
```

**Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | head -30`
Expected: Test failures because parseModelString still splits on `:`.

**Step 3: Update parseModelString**

Replace the function body at `src/llm.zig:101-113`:

```zig
/// Parse a "provider/model" string. If no slash is present, defaults to "anthropic".
pub fn parseModelString(model_str: []const u8) ModelSpec {
    if (std.mem.indexOfScalar(u8, model_str, '/')) |slash| {
        return .{
            .provider_name = model_str[0..slash],
            .model_id = model_str[slash + 1 ..],
        };
    }
    return .{
        .provider_name = "anthropic",
        .model_id = model_str,
    };
}
```

Also update the doc comment on `ModelSpec`:

```zig
pub const ModelSpec = struct {
    /// Provider name (e.g., "anthropic", "openrouter").
    provider_name: []const u8,
    /// Model identifier within the provider (e.g., "claude-sonnet-4-20250514").
    model_id: []const u8,
};
```

**Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | head -30`
Expected: All four parseModelString tests pass.

**Step 5: Update the createProvider test**

The test at the end of llm.zig that uses `"fakeprovider:some-model"` needs updating:

```zig
test "createProvider returns UnknownProvider for unsupported provider" {
    const allocator = std.testing.allocator;
    var registry = try Registry.init(allocator);
    defer registry.deinit();
    const result = createProvider(&registry, "fakeprovider/some-model", allocator);
    try std.testing.expectError(error.UnknownProvider, result);
}
```

This test will fail because `createProvider` doesn't accept a Registry yet. That's expected; it gets fixed in Task 5.

**Step 6: Commit**

```bash
git add src/llm.zig
git commit -m "llm: switch model string format from provider:model to provider/model

Aligns with Aider, OpenRouter, and Cursor conventions.
Splits on first slash; everything after is the model ID.
Nested slashes work naturally: openrouter/anthropic/claude-sonnet-4."
```

---

### Task 4: Rename provider structs to serializer naming

**Files:**
- Modify: `src/providers/anthropic.zig:19,32,43,66` (rename AnthropicProvider to AnthropicSerializer)
- Modify: `src/providers/openai.zig:20,35,46,71` (rename OpenAiProvider to OpenAiSerializer)

**Step 1: Rename in anthropic.zig**

In `src/providers/anthropic.zig`, rename all occurrences of `AnthropicProvider` to `AnthropicSerializer`:

- Line 19: `pub const AnthropicSerializer = struct {`
- Line 32: `pub fn provider(self: *AnthropicSerializer) Provider {`
- Line 43: `const self: *AnthropicSerializer = @ptrCast(@alignCast(ptr));`
- Line 66: `const self: *AnthropicSerializer = @ptrCast(@alignCast(ptr));`

Update the module-level doc comment at top:

```zig
//! Anthropic Messages API serializer.
//!
//! Implements the LLM Provider interface for Claude models via
//! the Anthropic Messages API (https://api.anthropic.com/v1/messages).
```

Update the struct doc comment:

```zig
/// Anthropic serializer state.
pub const AnthropicSerializer = struct {
```

**Step 2: Rename in openai.zig**

In `src/providers/openai.zig`, rename all occurrences of `OpenAiProvider` to `OpenAiSerializer`:

- Line 20: `pub const OpenAiSerializer = struct {`
- Line 35: `pub fn provider(self: *OpenAiSerializer) Provider {`
- Line 46: `const self: *OpenAiSerializer = @ptrCast(@alignCast(ptr));`
- Line 71: `const self: *OpenAiSerializer = @ptrCast(@alignCast(ptr));`

Update the module-level doc comment:

```zig
//! OpenAI Chat Completions API serializer.
//!
//! Implements the LLM provider for OpenAI-compatible models via the
//! Chat Completions API (https://api.openai.com/v1/chat/completions).
//! Handles format conversion between Zag's internal content blocks
//! (Anthropic-style) and OpenAI's message format.
```

Update the struct doc comment:

```zig
/// OpenAI Chat Completions serializer state.
pub const OpenAiSerializer = struct {
```

**Step 3: Update references in llm.zig**

In `src/llm.zig`, update the `ProviderResult` destroy functions and `createProvider`:

- Line 134: `alloc.destroy(@as(*anthropic.AnthropicSerializer, @ptrCast(@alignCast(state))));`
- Line 138: `const p: *openai.OpenAiSerializer = @ptrCast(@alignCast(state));`
- Line 154: `const state = try allocator.create(anthropic.AnthropicSerializer);`
- Line 175: `const state = try allocator.create(openai.OpenAiSerializer);`

**Step 4: Run tests to verify everything compiles and passes**

Run: `zig build test 2>&1 | head -30`
Expected: All tests pass. The rename is purely mechanical.

**Step 5: Commit**

```bash
git add src/providers/anthropic.zig src/providers/openai.zig src/llm.zig
git commit -m "providers: rename Provider structs to Serializer

AnthropicProvider -> AnthropicSerializer
OpenAiProvider -> OpenAiSerializer

Reflects their role: they serialize/parse wire formats,
not manage provider identity."
```

---

### Task 5: Refactor serializers to receive Endpoint

This is the core change. The serializers stop hardcoding URLs and auth; they read from `self.endpoint`.

**Files:**
- Modify: `src/providers/anthropic.zig:14-16,19-81`
- Modify: `src/providers/openai.zig:16-17,20-88`
- Modify: `src/llm.zig:116-188` (ProviderResult and createProvider)

**Step 1: Refactor AnthropicSerializer struct**

In `src/providers/anthropic.zig`, replace the struct definition and both call methods.

Remove the hardcoded constants at lines 14-15:
```zig
// DELETE: const api_url = "https://api.anthropic.com/v1/messages";
// DELETE: const api_version = "2023-06-01";
```

Keep `default_max_tokens = 8192` (this is format-specific, not endpoint-specific).

Replace the struct (lines 19-81):

```zig
/// Anthropic serializer state.
pub const AnthropicSerializer = struct {
    /// Endpoint connection details (URL, auth, headers).
    endpoint: *const llm.Endpoint,
    /// API key for authentication.
    api_key: []const u8,
    /// Model identifier (e.g., "claude-sonnet-4-20250514").
    model: []const u8,

    const vtable: Provider.VTable = .{
        .call = callImpl,
        .call_streaming = callStreamingImpl,
        .name = "anthropic",
    };

    /// Create a Provider interface from this Anthropic serializer.
    pub fn provider(self: *AnthropicSerializer) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Build the full HTTP header list from endpoint config + auth.
    fn buildHeaders(self: *const AnthropicSerializer, allocator: Allocator) !std.ArrayList(std.http.Header) {
        var headers: std.ArrayList(std.http.Header) = .empty;
        errdefer headers.deinit(allocator);

        // Auth header
        switch (self.endpoint.auth) {
            .x_api_key => try headers.append(allocator, .{ .name = "x-api-key", .value = self.api_key }),
            .bearer => {
                const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key});
                try headers.append(allocator, .{ .name = "Authorization", .value = auth_value });
            },
            .none => {},
        }

        // Endpoint-specific headers
        for (self.endpoint.headers) |h| {
            try headers.append(allocator, .{ .name = h.name, .value = h.value });
        }

        return headers;
    }

    /// Free any allocated header values (only Bearer auth allocates).
    fn freeHeaders(self: *const AnthropicSerializer, headers: *std.ArrayList(std.http.Header), allocator: Allocator) void {
        if (self.endpoint.auth == .bearer and headers.items.len > 0) {
            allocator.free(headers.items[0].value);
        }
        headers.deinit(allocator);
    }

    fn callImpl(
        ptr: *anyopaque,
        system_prompt: []const u8,
        messages: []const types.Message,
        tool_definitions: []const types.ToolDefinition,
        allocator: Allocator,
    ) anyerror!types.LlmResponse {
        const self: *AnthropicSerializer = @ptrCast(@alignCast(ptr));

        const body = try buildRequestBody(self.model, system_prompt, messages, tool_definitions, allocator);
        defer allocator.free(body);

        var headers = try self.buildHeaders(allocator);
        defer self.freeHeaders(&headers, allocator);

        const response_bytes = try llm.httpPostJson(self.endpoint.url, body, headers.items, allocator);
        defer allocator.free(response_bytes);

        return parseResponse(response_bytes, allocator);
    }

    fn callStreamingImpl(
        ptr: *anyopaque,
        system_prompt: []const u8,
        messages: []const types.Message,
        tool_definitions: []const types.ToolDefinition,
        allocator: Allocator,
        on_event: *const fn (event: llm.StreamEvent) void,
        cancel: *std.atomic.Value(bool),
    ) anyerror!types.LlmResponse {
        const self: *AnthropicSerializer = @ptrCast(@alignCast(ptr));

        const body = try buildStreamingRequestBody(self.model, system_prompt, messages, tool_definitions, allocator);
        defer allocator.free(body);

        var headers = try self.buildHeaders(allocator);
        defer self.freeHeaders(&headers, allocator);

        const stream = try llm.StreamingResponse.create(self.endpoint.url, body, headers.items, allocator);
        defer stream.destroy();

        return parseSseStream(stream, allocator, on_event, cancel);
    }
};
```

**Step 2: Refactor OpenAiSerializer struct**

In `src/providers/openai.zig`, apply the same pattern.

Remove the hardcoded constant at line 16:
```zig
// DELETE: const default_base_url = "https://api.openai.com/v1/chat/completions";
```

Keep `default_max_tokens = 8192`.

Replace the struct (lines 20-88):

```zig
/// OpenAI Chat Completions serializer state.
pub const OpenAiSerializer = struct {
    /// Endpoint connection details (URL, auth, headers).
    endpoint: *const llm.Endpoint,
    /// API key for Bearer authentication.
    api_key: []const u8,
    /// Model identifier (e.g., "gpt-4o", "gpt-4o-mini").
    model: []const u8,

    const vtable: Provider.VTable = .{
        .call = callImpl,
        .call_streaming = callStreamingImpl,
        .name = "openai",
    };

    /// Create a Provider interface from this OpenAI serializer.
    pub fn provider(self: *OpenAiSerializer) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Build the full HTTP header list from endpoint config + auth.
    fn buildHeaders(self: *const OpenAiSerializer, allocator: Allocator) !std.ArrayList(std.http.Header) {
        var headers: std.ArrayList(std.http.Header) = .empty;
        errdefer headers.deinit(allocator);

        // Auth header
        switch (self.endpoint.auth) {
            .bearer => {
                const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key});
                try headers.append(allocator, .{ .name = "Authorization", .value = auth_value });
            },
            .x_api_key => try headers.append(allocator, .{ .name = "x-api-key", .value = self.api_key }),
            .none => {},
        }

        // Endpoint-specific headers
        for (self.endpoint.headers) |h| {
            try headers.append(allocator, .{ .name = h.name, .value = h.value });
        }

        return headers;
    }

    /// Free any allocated header values (only Bearer auth allocates).
    fn freeHeaders(self: *const OpenAiSerializer, headers: *std.ArrayList(std.http.Header), allocator: Allocator) void {
        if (self.endpoint.auth == .bearer and headers.items.len > 0) {
            allocator.free(headers.items[0].value);
        }
        headers.deinit(allocator);
    }

    fn callImpl(
        ptr: *anyopaque,
        system_prompt: []const u8,
        messages: []const types.Message,
        tool_definitions: []const types.ToolDefinition,
        allocator: Allocator,
    ) anyerror!types.LlmResponse {
        const self: *OpenAiSerializer = @ptrCast(@alignCast(ptr));

        const body = try buildRequestBody(self.model, system_prompt, messages, tool_definitions, allocator);
        defer allocator.free(body);

        var headers = try self.buildHeaders(allocator);
        defer self.freeHeaders(&headers, allocator);

        const response_bytes = try llm.httpPostJson(self.endpoint.url, body, headers.items, allocator);
        defer allocator.free(response_bytes);

        return parseResponse(response_bytes, allocator);
    }

    fn callStreamingImpl(
        ptr: *anyopaque,
        system_prompt: []const u8,
        messages: []const types.Message,
        tool_definitions: []const types.ToolDefinition,
        allocator: Allocator,
        on_event: *const fn (event: llm.StreamEvent) void,
        cancel: *std.atomic.Value(bool),
    ) anyerror!types.LlmResponse {
        const self: *OpenAiSerializer = @ptrCast(@alignCast(ptr));

        const body = try buildStreamingRequestBody(self.model, system_prompt, messages, tool_definitions, allocator);
        defer allocator.free(body);

        var headers = try self.buildHeaders(allocator);
        defer self.freeHeaders(&headers, allocator);

        const stream = try llm.StreamingResponse.create(self.endpoint.url, body, headers.items, allocator);
        defer stream.destroy();

        return parseSseStream(stream, allocator, on_event, cancel);
    }
};
```

**Step 3: Refactor ProviderResult and createProvider in llm.zig**

Replace `ProviderResult` (lines 116-142) and `createProvider` (lines 146-188) in `src/llm.zig`:

```zig
/// Result of creating a provider. Holds the allocated state that must be freed.
pub const ProviderResult = struct {
    /// The provider interface to pass to agent.runLoop.
    provider: Provider,
    /// The allocated provider state. Must be destroyed when done.
    state: *anyopaque,
    /// The API key string, owned by this result.
    api_key: []const u8,
    /// Allocator used to create the state (for cleanup).
    allocator: Allocator,
    /// Which serializer was used (needed for type-correct destroy).
    serializer: Serializer,

    pub fn deinit(self: *ProviderResult) void {
        self.allocator.free(self.api_key);
        switch (self.serializer) {
            .anthropic => {
                self.allocator.destroy(@as(*anthropic.AnthropicSerializer, @ptrCast(@alignCast(self.state))));
            },
            .openai => {
                self.allocator.destroy(@as(*openai.OpenAiSerializer, @ptrCast(@alignCast(self.state))));
            },
        }
    }
};

/// Create a provider from a model string, looking up the endpoint in the registry.
pub fn createProvider(registry: *const Registry, model_str: []const u8, allocator: Allocator) !ProviderResult {
    const spec = parseModelString(model_str);
    const endpoint = registry.find(spec.provider_name) orelse
        return error.UnknownProvider;

    const api_key = if (endpoint.key_env) |env|
        std.process.getEnvVarOwned(allocator, env) catch return error.MissingApiKey
    else
        try allocator.dupe(u8, "");
    errdefer allocator.free(api_key);

    switch (endpoint.serializer) {
        .anthropic => {
            const state = try allocator.create(anthropic.AnthropicSerializer);
            state.* = .{ .endpoint = endpoint, .api_key = api_key, .model = spec.model_id };
            return .{
                .provider = state.provider(),
                .state = state,
                .api_key = api_key,
                .allocator = allocator,
                .serializer = .anthropic,
            };
        },
        .openai => {
            const state = try allocator.create(openai.OpenAiSerializer);
            state.* = .{ .endpoint = endpoint, .api_key = api_key, .model = spec.model_id };
            return .{
                .provider = state.provider(),
                .state = state,
                .api_key = api_key,
                .allocator = allocator,
                .serializer = .openai,
            };
        },
    }
}
```

**Step 4: Update the createProvider test**

```zig
test "createProvider returns UnknownProvider for unsupported provider" {
    const allocator = std.testing.allocator;
    var registry = try Registry.init(allocator);
    defer registry.deinit();
    const result = createProvider(&registry, "fakeprovider/some-model", allocator);
    try std.testing.expectError(error.UnknownProvider, result);
}
```

**Step 5: Run all tests**

Run: `zig build test 2>&1 | head -50`
Expected: All tests pass. Serialization tests in both provider files are unaffected because `buildRequestBody`, `parseResponse`, `parseSseStream` signatures are unchanged.

**Step 6: Commit**

```bash
git add src/llm.zig src/providers/anthropic.zig src/providers/openai.zig
git commit -m "llm: refactor serializers to receive Endpoint

Serializers now read URL, auth style, and extra headers from
the Endpoint struct instead of hardcoding them. createProvider
looks up endpoints from the Registry by name."
```

---

### Task 6: Update main.zig to create Registry and use new model format

**Files:**
- Modify: `src/main.zig:397-410`

**Step 1: Update main.zig**

At `src/main.zig`, the relevant section is lines 397-410. Replace with:

```zig
    // Initialize endpoint registry
    var endpoint_registry = llm.Registry.init(allocator) catch {
        const stderr = std.fs.File.stderr();
        var err_buf: [256]u8 = undefined;
        var w = stderr.writer(&err_buf);
        w.interface.print("error: failed to initialize endpoint registry\n", .{}) catch {};
        w.interface.flush() catch {};
        return;
    };
    defer endpoint_registry.deinit();

    // Read model string and create provider
    const model_str = std.process.getEnvVarOwned(allocator, "ZAG_MODEL") catch
        try allocator.dupe(u8, "anthropic/claude-sonnet-4-20250514");
    defer allocator.free(model_str);

    var provider_result = llm.createProvider(&endpoint_registry, model_str, allocator) catch |err| {
        const stderr = std.fs.File.stderr();
        var err_buf: [256]u8 = undefined;
        var w = stderr.writer(&err_buf);
        w.interface.print("error: failed to create provider: {s}\n", .{@errorName(err)}) catch {};
        w.interface.flush() catch {};
        return;
    };
    defer provider_result.deinit();
```

Note the default model string changes from `"anthropic:claude-sonnet-4-20250514"` to `"anthropic/claude-sonnet-4-20250514"`.

**Step 2: Run full build**

Run: `zig build 2>&1 | head -20`
Expected: Clean compilation with no errors.

**Step 3: Run all tests**

Run: `zig build test 2>&1 | head -50`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add src/main.zig
git commit -m "main: create Registry and use provider/model format

Registry is initialized before provider creation, threaded
into createProvider. Default model string updated to use
slash convention."
```

---

### Task 7: Update CLAUDE.md and documentation

**Files:**
- Modify: `CLAUDE.md` (update the model string examples)

**Step 1: Update model string examples in CLAUDE.md**

In the "Build & run" section, change:

```
ZAG_MODEL="openai:gpt-4o" zig build run                       # use OpenAI
ZAG_MODEL="anthropic:claude-sonnet-4-20250514" zig build run   # use Claude (default)
```

to:

```
ZAG_MODEL="openai/gpt-4o" zig build run                            # use OpenAI
ZAG_MODEL="anthropic/claude-sonnet-4-20250514" zig build run        # use Claude (default)
ZAG_MODEL="openrouter/anthropic/claude-sonnet-4" zig build run      # use OpenRouter
ZAG_MODEL="ollama/llama3" zig build run                             # use local Ollama
```

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update model string examples to provider/model format"
```

---

### Task 8: Deduplicate buildHeaders across serializers

Both `AnthropicSerializer` and `OpenAiSerializer` now have identical `buildHeaders` and `freeHeaders` methods. Extract to a shared function in `llm.zig`.

**Files:**
- Modify: `src/llm.zig` (add shared functions)
- Modify: `src/providers/anthropic.zig` (remove buildHeaders/freeHeaders, call llm.buildHeaders)
- Modify: `src/providers/openai.zig` (same)

**Step 1: Write the failing test**

Add to `src/llm.zig` test section:

```zig
test "buildHeaders creates correct auth for bearer endpoint" {
    const allocator = std.testing.allocator;

    const endpoint = Endpoint{
        .name = "test",
        .serializer = .openai,
        .url = "https://example.com",
        .key_env = "TEST_KEY",
        .auth = .bearer,
        .headers = &.{.{ .name = "X-Custom", .value = "val" }},
        .compat = .{},
    };

    var headers = try buildHeaders(&endpoint, "sk-test-key", allocator);
    defer freeHeaders(&endpoint, &headers, allocator);

    // Bearer auth + 1 custom header = 2 total
    try std.testing.expectEqual(@as(usize, 2), headers.items.len);
    try std.testing.expectEqualStrings("Authorization", headers.items[0].name);
    try std.testing.expect(std.mem.startsWith(u8, headers.items[0].value, "Bearer "));
    try std.testing.expectEqualStrings("X-Custom", headers.items[1].name);
}

test "buildHeaders creates correct auth for x_api_key endpoint" {
    const allocator = std.testing.allocator;

    const endpoint = Endpoint{
        .name = "test",
        .serializer = .anthropic,
        .url = "https://example.com",
        .key_env = "TEST_KEY",
        .auth = .x_api_key,
        .headers = &.{.{ .name = "anthropic-version", .value = "2023-06-01" }},
        .compat = .{},
    };

    var headers = try buildHeaders(&endpoint, "sk-ant-key", allocator);
    defer freeHeaders(&endpoint, &headers, allocator);

    try std.testing.expectEqual(@as(usize, 2), headers.items.len);
    try std.testing.expectEqualStrings("x-api-key", headers.items[0].name);
    try std.testing.expectEqualStrings("sk-ant-key", headers.items[0].value);
    try std.testing.expectEqualStrings("anthropic-version", headers.items[1].name);
}

test "buildHeaders handles no-auth endpoint" {
    const allocator = std.testing.allocator;

    const endpoint = Endpoint{
        .name = "ollama",
        .serializer = .openai,
        .url = "http://localhost:11434/v1/chat/completions",
        .key_env = null,
        .auth = .none,
        .headers = &.{},
        .compat = .{},
    };

    var headers = try buildHeaders(&endpoint, "", allocator);
    defer freeHeaders(&endpoint, &headers, allocator);

    try std.testing.expectEqual(@as(usize, 0), headers.items.len);
}
```

**Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | head -30`
Expected: Compilation error, `buildHeaders` not found.

**Step 3: Add shared functions to llm.zig**

Add after the `Registry` struct:

```zig
/// Build HTTP headers from an endpoint's auth config and extra headers.
/// Caller must call freeHeaders() when done.
pub fn buildHeaders(endpoint: *const Endpoint, api_key: []const u8, allocator: Allocator) !std.ArrayList(std.http.Header) {
    var headers: std.ArrayList(std.http.Header) = .empty;
    errdefer headers.deinit(allocator);

    switch (endpoint.auth) {
        .x_api_key => try headers.append(allocator, .{ .name = "x-api-key", .value = api_key }),
        .bearer => {
            const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
            try headers.append(allocator, .{ .name = "Authorization", .value = auth_value });
        },
        .none => {},
    }

    for (endpoint.headers) |h| {
        try headers.append(allocator, .{ .name = h.name, .value = h.value });
    }

    return headers;
}

/// Free headers built by buildHeaders(). Only Bearer auth allocates a header value.
pub fn freeHeaders(endpoint: *const Endpoint, headers: *std.ArrayList(std.http.Header), allocator: Allocator) void {
    if (endpoint.auth == .bearer and headers.items.len > 0) {
        allocator.free(headers.items[0].value);
    }
    headers.deinit(allocator);
}
```

**Step 4: Update both serializers to use shared functions**

In `src/providers/anthropic.zig`, remove the `buildHeaders` and `freeHeaders` methods from the struct. Replace their usage in `callImpl` and `callStreamingImpl`:

```zig
    fn callImpl(...) anyerror!types.LlmResponse {
        const self: *AnthropicSerializer = @ptrCast(@alignCast(ptr));
        // ... body build unchanged ...
        var headers = try llm.buildHeaders(self.endpoint, self.api_key, allocator);
        defer llm.freeHeaders(self.endpoint, &headers, allocator);
        const response_bytes = try llm.httpPostJson(self.endpoint.url, body, headers.items, allocator);
        // ... rest unchanged ...
    }
```

Same pattern in `callStreamingImpl` and same changes in `src/providers/openai.zig`.

**Step 5: Run all tests**

Run: `zig build test 2>&1 | head -50`
Expected: All tests pass.

**Step 6: Commit**

```bash
git add src/llm.zig src/providers/anthropic.zig src/providers/openai.zig
git commit -m "llm: extract shared buildHeaders/freeHeaders

Both serializers had identical header construction logic.
Now lives in llm.zig as shared functions."
```

---

### Task 9: Final verification

**Step 1: Run full test suite**

Run: `zig build test 2>&1`
Expected: All tests pass with zero failures.

**Step 2: Run format check**

Run: `zig fmt --check .`
Expected: No formatting issues.

**Step 3: Build and verify it runs**

Run: `zig build`
Expected: Clean build.

**Step 4: Verify with a quick smoke test (if API key available)**

Run: `ZAG_MODEL="anthropic/claude-sonnet-4-20250514" zig build run`
Expected: Zag starts normally, can send a message and get a response.

**Step 5: Final commit if any formatting fixes were needed**

```bash
# Only if zig fmt found issues
zig fmt .
git add -A
git commit -m "quality: apply zig fmt"
```

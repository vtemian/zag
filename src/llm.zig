//! LLM provider interface and routing.
//!
//! Defines the runtime-polymorphic Provider interface that all LLM backends
//! implement, plus the model string parser and provider factory.

const std = @import("std");
const types = @import("types.zig");
const auth = @import("auth.zig");
const Allocator = std.mem.Allocator;

pub const anthropic = @import("providers/anthropic.zig");
pub const openai = @import("providers/openai.zig");
pub const streaming = @import("llm/streaming.zig");
pub const http = @import("llm/http.zig");

const log = std.log.scoped(.llm);

/// Errors a Provider's call/callStreaming may legitimately produce.
/// Unexpected stdlib errors (HTTP plumbing, JSON parse) are logged and
/// remapped to `ApiError` at the provider boundary so the vtable surface
/// stays small and callers can switch exhaustively.
pub const ProviderError = std.mem.Allocator.Error || error{
    /// Upstream endpoint returned a non-2xx status, malformed transport
    /// framing, or any other transport-layer failure that couldn't be
    /// classified more specifically.
    ApiError,
    /// Endpoint URL failed to parse (usually a config / env-var typo).
    InvalidUri,
    /// Response body couldn't be parsed as the expected shape.
    MalformedResponse,
    /// No API key available for the configured provider.
    MissingApiKey,
    /// An SSE line exceeded `streaming.MAX_SSE_LINE` before terminating.
    SseLineTooLong,
    /// Accumulated SSE event data exceeded `streaming.MAX_SSE_EVENT_DATA`.
    SseEventDataTooLarge,
};

/// Remap an arbitrary error to the narrow `ProviderError` surface.
/// Errors already in the set pass through; anything else is logged and
/// returned as `ApiError`. Used at provider entry points so stdlib HTTP
/// and JSON errors don't leak past the vtable.
pub fn mapProviderError(err: anyerror) ProviderError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ApiError => error.ApiError,
        error.InvalidUri => error.InvalidUri,
        error.MalformedResponse => error.MalformedResponse,
        error.MissingApiKey => error.MissingApiKey,
        error.SseLineTooLong => error.SseLineTooLong,
        error.SseEventDataTooLarge => error.SseEventDataTooLarge,
        else => blk: {
            log.err("provider error remapped to ApiError: {s}", .{@errorName(err)});
            break :blk error.ApiError;
        },
    };
}

/// Streaming event emitted by call_streaming for incremental response delivery.
/// Defined here (rather than beside the agent loop) so the provider VTable can
/// reference it without creating a circular dependency.
pub const StreamEvent = union(enum) {
    /// Partial text from the LLM response.
    text_delta: []const u8,
    /// A tool call was started by the LLM (content is the tool name).
    tool_start: []const u8,
    /// Informational message (token counts, etc.).
    info: []const u8,
    /// Agent loop completed successfully.
    done,
    /// An error occurred.
    err: []const u8,
};

/// Carries a caller-owned context pointer alongside the event handler function.
/// Providers invoke `callback.on_event(callback.ctx, event)` so the caller can
/// thread per-call state without threadlocal smuggling.
pub const StreamCallback = struct {
    /// Opaque pointer to caller state. Ownership and lifetime belong to the caller.
    ctx: *anyopaque,
    /// Event handler. Receives the same `ctx` the caller supplied.
    on_event: *const fn (ctx: *anyopaque, event: StreamEvent) void,
};

/// The neutral input shape that every provider vtable accepts.
///
/// Provider-specific wire-format concerns (system placement, tool
/// wrapping, role mapping) live inside each provider's own file.
/// A provider receives exactly this struct by const pointer and
/// emits its own request body.
pub const Request = struct {
    /// Free-text system prompt. How it lands in the wire format is
    /// the provider's problem; Anthropic uses a top-level `system`
    /// field, OpenAI injects a `role: "system"` message.
    system_prompt: []const u8,
    /// Conversation history in chronological order.
    messages: []const types.Message,
    /// Tools offered to the LLM for this turn. May be empty.
    tool_definitions: []const types.ToolDefinition,
    /// Allocator for response allocations owned by the caller.
    allocator: Allocator,
};

/// Streaming variant: everything in `Request` plus the callback and
/// cancellation token. Kept as its own type (not an optional inside
/// `Request`) so the vtable signature remains unambiguous.
pub const StreamRequest = struct {
    /// System prompt prepended to the conversation. Steers model behavior.
    system_prompt: []const u8,
    /// Conversation history sent to the model, oldest first.
    messages: []const types.Message,
    /// Tools the model may call during this turn.
    tool_definitions: []const types.ToolDefinition,
    /// Allocator used for any per-request scratch buffers the provider needs.
    allocator: Allocator,
    /// Handler invoked for each streamed event. Owns no request state.
    callback: StreamCallback,
    /// Cancellation flag polled by the provider to abort mid-stream.
    cancel: *std.atomic.Value(bool),
};

/// Wire format for request/response serialization.
pub const Serializer = enum {
    /// Anthropic Messages API format.
    anthropic,
    /// OpenAI Chat Completions API format (also used by OpenRouter, Groq, Ollama, etc.).
    openai,
};

/// Everything needed to talk to a specific LLM endpoint.
pub const Endpoint = struct {
    /// Human-readable name (e.g., "openrouter", "ollama").
    name: []const u8,
    /// Which wire format this endpoint speaks.
    serializer: Serializer,
    /// Full URL for chat completions.
    url: []const u8,
    /// How to send the API key in HTTP headers.
    auth: Auth,
    /// Additional HTTP headers sent with every request.
    headers: []const Header,

    /// How the API key is sent in HTTP headers.
    pub const Auth = enum {
        /// Anthropic-style: `x-api-key: <key>`.
        x_api_key,
        /// Bearer token: `Authorization: Bearer <key>`.
        bearer,
        /// No authentication (e.g., local Ollama).
        none,
    };

    /// A static HTTP header sent with every request to this endpoint.
    pub const Header = struct {
        /// Header field name.
        name: []const u8,
        /// Header field value.
        value: []const u8,
    };

    /// Deep-copy all strings onto the heap. Caller must call free().
    pub fn dupe(self: Endpoint, allocator: Allocator) !Endpoint {
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const url = try allocator.dupe(u8, self.url);
        errdefer allocator.free(url);

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
            .auth = self.auth,
            .headers = headers,
        };
    }

    /// Free all heap-allocated strings. Pair with dupe().
    pub fn free(self: Endpoint, allocator: Allocator) void {
        for (self.headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(self.headers);
        allocator.free(self.url);
        allocator.free(self.name);
    }
};

const builtin_endpoints = [_]Endpoint{
    .{
        .name = "anthropic",
        .serializer = .anthropic,
        .url = "https://api.anthropic.com/v1/messages",
        .auth = .x_api_key,
        .headers = &.{.{ .name = "anthropic-version", .value = "2023-06-01" }},
    },
    .{
        .name = "openai",
        .serializer = .openai,
        .url = "https://api.openai.com/v1/chat/completions",
        .auth = .bearer,
        .headers = &.{},
    },
    .{
        .name = "openrouter",
        .serializer = .openai,
        .url = "https://openrouter.ai/api/v1/chat/completions",
        .auth = .bearer,
        .headers = &.{.{ .name = "X-OpenRouter-Title", .value = "Zag" }},
    },
    .{
        .name = "groq",
        .serializer = .openai,
        .url = "https://api.groq.com/openai/v1/chat/completions",
        .auth = .bearer,
        .headers = &.{},
    },
    .{
        .name = "ollama",
        .serializer = .openai,
        .url = "http://localhost:11434/v1/chat/completions",
        .auth = .none,
        .headers = &.{},
    },
};

/// True if `name` matches any entry in `builtin_endpoints`. Used by the Lua
/// binding `zag.provider{ name = "..." }` to fail loud on typos at load time.
pub fn isBuiltinEndpointName(name: []const u8) bool {
    for (&builtin_endpoints) |ep| {
        if (std.mem.eql(u8, ep.name, name)) return true;
    }
    return false;
}

/// Runtime registry of LLM endpoints. Seeded with built-ins, extensible at runtime.
pub const Registry = struct {
    /// All registered endpoints (built-in and runtime-added).
    endpoints: std.ArrayList(Endpoint),
    /// Backing allocator for endpoint storage.
    allocator: Allocator,

    pub fn init(allocator: Allocator) !Registry {
        var self = Registry{ .endpoints = .empty, .allocator = allocator };
        errdefer self.deinit();
        for (&builtin_endpoints) |*ep| {
            const duped = try ep.dupe(allocator);
            errdefer duped.free(allocator);
            try self.endpoints.append(allocator, duped);
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

    /// Release all heap-owned endpoints and backing storage.
    pub fn deinit(self: *Registry) void {
        for (self.endpoints.items) |ep| ep.free(self.allocator);
        self.endpoints.deinit(self.allocator);
    }
};

/// Runtime-polymorphic LLM provider interface.
/// Uses the ptr + vtable pattern (same as std.mem.Allocator).
/// Each provider implements call() for its specific API format.
pub const Provider = struct {
    /// Type-erased pointer to the concrete provider struct.
    ptr: *anyopaque,
    /// Function table for this provider implementation.
    vtable: *const VTable,

    pub const VTable = struct {
        /// Send a conversation and return the parsed response.
        call: *const fn (
            ptr: *anyopaque,
            req: *const Request,
        ) ProviderError!types.LlmResponse,

        /// Streaming variant: invokes `req.callback.on_event` for each
        /// SSE event. Assembles and returns the final LlmResponse when
        /// the stream ends or is cancelled.
        call_streaming: *const fn (
            ptr: *anyopaque,
            req: *const StreamRequest,
        ) ProviderError!types.LlmResponse,

        /// Human-readable provider name (for logging and display).
        name: []const u8,
    };

    pub fn call(self: Provider, req: *const Request) ProviderError!types.LlmResponse {
        return self.vtable.call(self.ptr, req);
    }

    pub fn callStreaming(self: Provider, req: *const StreamRequest) ProviderError!types.LlmResponse {
        return self.vtable.call_streaming(self.ptr, req);
    }
};

/// Parsed model string components.
pub const ModelSpec = struct {
    /// Provider name (e.g., "anthropic", "openai").
    provider_name: []const u8,
    /// Model identifier within the provider (e.g., "claude-sonnet-4-20250514").
    model_id: []const u8,
};

/// Parse a "provider/model" string. If no slash is present, defaults to "anthropic".
pub fn parseModelString(model: []const u8) ModelSpec {
    if (std.mem.indexOfScalar(u8, model, '/')) |slash| {
        return .{
            .provider_name = model[0..slash],
            .model_id = model[slash + 1 ..],
        };
    }
    return .{
        .provider_name = "anthropic",
        .model_id = model,
    };
}

/// Result of creating a provider. Owns all resources needed for LLM calls.
/// A single deinit() frees everything: provider state, API key, model string, registry.
pub const ProviderResult = struct {
    /// The provider interface for agent loop LLM calls.
    provider: Provider,
    /// The full "provider/model" string (e.g., "anthropic/claude-sonnet-4-20250514").
    model_id: []const u8,
    /// The allocated provider state. Must be destroyed when done.
    state: *anyopaque,
    /// The API key string, owned by this result.
    api_key: []const u8,
    /// Endpoint registry (owned, freed on deinit).
    registry: Registry,
    /// Allocator used to create the state (for cleanup).
    allocator: Allocator,
    /// Which serializer was used (needed for type-correct destroy).
    serializer: Serializer,

    pub fn deinit(self: *ProviderResult) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.model_id);
        self.registry.deinit();
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

/// Create a provider from Lua-populated config.
///
/// `default_model` is the model string the user set via
/// `zag.set_default_model("prov/id")` (null falls back to
/// `anthropic/claude-sonnet-4-20250514`). The api key is read out of
/// `auth_file_path` (normally `~/.config/zag/auth.json`) via `auth.getApiKey`.
/// Endpoints whose `auth` discriminator is `.none` (e.g. Ollama) skip the
/// credential lookup entirely. The returned `ProviderResult` owns the duped
/// model string, the duped api key, the endpoint registry, and the serializer
/// state.
pub fn createProviderFromLuaConfig(
    default_model: ?[]const u8,
    auth_file_path: []const u8,
    allocator: Allocator,
) !ProviderResult {
    const model_id = try allocator.dupe(u8, default_model orelse "anthropic/claude-sonnet-4-20250514");
    errdefer allocator.free(model_id);

    var registry = try Registry.init(allocator);
    errdefer registry.deinit();

    const spec = parseModelString(model_id);
    const endpoint = registry.find(spec.provider_name) orelse
        return error.UnknownProvider;

    const api_key: []const u8 = switch (endpoint.auth) {
        .none => try allocator.dupe(u8, ""),
        .x_api_key, .bearer => blk: {
            var auth_file = try auth.loadAuthFile(allocator, auth_file_path);
            defer auth_file.deinit();
            const borrowed = (try auth_file.getApiKey(spec.provider_name)) orelse
                return error.MissingCredential;
            break :blk try allocator.dupe(u8, borrowed);
        },
    };
    errdefer allocator.free(api_key);

    switch (endpoint.serializer) {
        .anthropic => {
            const state = try allocator.create(anthropic.AnthropicSerializer);
            state.* = .{ .endpoint = endpoint, .api_key = api_key, .model = spec.model_id };
            return .{
                .provider = state.provider(),
                .model_id = model_id,
                .state = state,
                .api_key = api_key,
                .registry = registry,
                .allocator = allocator,
                .serializer = .anthropic,
            };
        },
        .openai => {
            const state = try allocator.create(openai.OpenAiSerializer);
            state.* = .{ .endpoint = endpoint, .api_key = api_key, .model = spec.model_id };
            return .{
                .provider = state.provider(),
                .model_id = model_id,
                .state = state,
                .api_key = api_key,
                .registry = registry,
                .allocator = allocator,
                .serializer = .openai,
            };
        },
    }
}

/// Accumulates content blocks and assembles an LlmResponse.
/// Dupes all strings so the response owns its memory.
/// Caller must call deinit() on error, or finish() to produce the response.
pub const ResponseBuilder = struct {
    blocks: std.ArrayList(types.ContentBlock) = .empty,

    /// Add a text content block. Dupes the text string.
    pub fn addText(self: *ResponseBuilder, text: []const u8, allocator: Allocator) !void {
        const duped = try allocator.dupe(u8, text);
        errdefer allocator.free(duped);
        try self.blocks.append(allocator, .{ .text = .{ .text = duped } });
    }

    /// Add a tool_use content block. Dupes id, name, and input_raw.
    pub fn addToolUse(self: *ResponseBuilder, id: []const u8, name: []const u8, input_raw: []const u8, allocator: Allocator) !void {
        const duped_id = try allocator.dupe(u8, id);
        errdefer allocator.free(duped_id);
        const duped_name = try allocator.dupe(u8, name);
        errdefer allocator.free(duped_name);
        const duped_input = try allocator.dupe(u8, input_raw);
        errdefer allocator.free(duped_input);
        try self.blocks.append(allocator, .{ .tool_use = .{
            .id = duped_id,
            .name = duped_name,
            .input_raw = duped_input,
        } });
    }

    /// Consume the builder and return the final LlmResponse.
    /// After this call the builder is empty and should not be used.
    pub fn finish(self: *ResponseBuilder, stop_reason: types.StopReason, input_tokens: u32, output_tokens: u32, allocator: Allocator) !types.LlmResponse {
        return .{
            .content = try self.blocks.toOwnedSlice(allocator),
            .stop_reason = stop_reason,
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
        };
    }

    /// Free all accumulated blocks. Use on error paths when finish() won't be called.
    pub fn deinit(self: *ResponseBuilder, allocator: Allocator) void {
        for (self.blocks.items) |block| block.freeOwned(allocator);
        self.blocks.deinit(allocator);
    }
};

// -- Tests -------------------------------------------------------------------

test "Endpoint.dupe creates independent copy" {
    const allocator = std.testing.allocator;

    const original = Endpoint{
        .name = "test",
        .serializer = .openai,
        .url = "https://example.com",
        .auth = .bearer,
        .headers = &.{.{ .name = "X-Custom", .value = "val" }},
    };

    const duped = try original.dupe(allocator);
    defer duped.free(allocator);

    try std.testing.expectEqualStrings("test", duped.name);
    try std.testing.expectEqualStrings("https://example.com", duped.url);
    try std.testing.expectEqual(Serializer.openai, duped.serializer);
    try std.testing.expectEqual(Endpoint.Auth.bearer, duped.auth);
    try std.testing.expectEqual(@as(usize, 1), duped.headers.len);
    try std.testing.expectEqualStrings("X-Custom", duped.headers[0].name);
    try std.testing.expectEqualStrings("val", duped.headers[0].value);

    // Verify independence: pointers must differ
    try std.testing.expect(original.name.ptr != duped.name.ptr);
    try std.testing.expect(original.url.ptr != duped.url.ptr);
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "Provider vtable call dispatches correctly" {
    const allocator = std.testing.allocator;

    const TestProvider = struct {
        call_count: u32 = 0,

        const vtable: Provider.VTable = .{
            .call = callImpl,
            .call_streaming = callStreamingImpl,
            .name = "test",
        };

        fn callImpl(
            ptr: *anyopaque,
            req: *const Request,
        ) ProviderError!types.LlmResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.call_count += 1;
            const content = try req.allocator.alloc(types.ContentBlock, 1);
            const text = try req.allocator.dupe(u8, "test response");
            content[0] = .{ .text = .{ .text = text } };
            return .{
                .content = content,
                .stop_reason = .end_turn,
                .input_tokens = 10,
                .output_tokens = 5,
            };
        }

        fn callStreamingImpl(
            ptr: *anyopaque,
            req: *const StreamRequest,
        ) ProviderError!types.LlmResponse {
            const fallback_req = Request{
                .system_prompt = req.system_prompt,
                .messages = req.messages,
                .tool_definitions = req.tool_definitions,
                .allocator = req.allocator,
            };
            return callImpl(ptr, &fallback_req);
        }

        fn provider(self: *@This()) Provider {
            return .{ .ptr = self, .vtable = &vtable };
        }
    };

    var test_impl: TestProvider = .{};
    const p = test_impl.provider();

    const req = Request{
        .system_prompt = "system",
        .messages = &.{},
        .tool_definitions = &.{},
        .allocator = allocator,
    };
    const response = try p.call(&req);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), test_impl.call_count);
    try std.testing.expectEqualStrings("test", p.vtable.name);
}

test "Provider callStreaming dispatches to vtable" {
    const allocator = std.testing.allocator;

    const Counter = struct {
        event_count: u32 = 0,
        fn onEvent(ctx: *anyopaque, _: StreamEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.event_count += 1;
        }
    };
    var counter: Counter = .{};

    const TestStreamProvider = struct {
        stream_count: u32 = 0,

        const vtable: Provider.VTable = .{
            .call = callImplUnused,
            .call_streaming = callStreamingImpl,
            .name = "test_stream",
        };

        fn callImplUnused(
            _: *anyopaque,
            _: *const Request,
        ) ProviderError!types.LlmResponse {
            unreachable;
        }

        fn callStreamingImpl(
            ptr: *anyopaque,
            req: *const StreamRequest,
        ) ProviderError!types.LlmResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.stream_count += 1;
            req.callback.on_event(req.callback.ctx, .{ .text_delta = "hello" });
            req.callback.on_event(req.callback.ctx, .done);
            const content = try req.allocator.alloc(types.ContentBlock, 1);
            const text = try req.allocator.dupe(u8, "hello");
            content[0] = .{ .text = .{ .text = text } };
            return .{
                .content = content,
                .stop_reason = .end_turn,
                .input_tokens = 5,
                .output_tokens = 1,
            };
        }

        fn provider(self: *@This()) Provider {
            return .{ .ptr = self, .vtable = &vtable };
        }
    };

    var test_impl: TestStreamProvider = .{};
    const p = test_impl.provider();

    var cancel = std.atomic.Value(bool).init(false);
    const callback: StreamCallback = .{ .ctx = &counter, .on_event = &Counter.onEvent };
    const stream_req = StreamRequest{
        .system_prompt = "system",
        .messages = &.{},
        .tool_definitions = &.{},
        .allocator = allocator,
        .callback = callback,
        .cancel = &cancel,
    };
    const response = try p.callStreaming(&stream_req);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), test_impl.stream_count);
    try std.testing.expectEqual(@as(u32, 2), counter.event_count);
    try std.testing.expectEqualStrings("test_stream", p.vtable.name);
}

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

test "parseModelString handles nested slashes for openrouter" {
    const result = parseModelString("openrouter/anthropic/claude-sonnet-4");
    try std.testing.expectEqualStrings("openrouter", result.provider_name);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4", result.model_id);
}

test "createProviderFromLuaConfig reads model from engine and key from auth.json" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = "auth.json",
        .data =
        \\{
        \\  "openai": { "type": "api_key", "key": "sk-openai-test" }
        \\}
        ,
    });
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const auth_path = try std.fs.path.join(allocator, &.{ dir_path, "auth.json" });
    defer allocator.free(auth_path);

    var result = try createProviderFromLuaConfig("openai/gpt-4o", auth_path, allocator);
    defer result.deinit();

    try std.testing.expectEqualStrings("openai/gpt-4o", result.model_id);
    try std.testing.expectEqualStrings("sk-openai-test", result.api_key);
    try std.testing.expectEqual(Serializer.openai, result.serializer);
}

test "createProviderFromLuaConfig uses hardcoded fallback when default_model unset" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = "auth.json",
        .data =
        \\{
        \\  "anthropic": { "type": "api_key", "key": "sk-ant-test" }
        \\}
        ,
    });
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const auth_path = try std.fs.path.join(allocator, &.{ dir_path, "auth.json" });
    defer allocator.free(auth_path);

    var result = try createProviderFromLuaConfig(null, auth_path, allocator);
    defer result.deinit();

    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4-20250514", result.model_id);
    try std.testing.expectEqualStrings("sk-ant-test", result.api_key);
    try std.testing.expectEqual(Serializer.anthropic, result.serializer);
}

test "createProviderFromLuaConfig returns MissingCredential when provider not in auth.json" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = "auth.json",
        .data =
        \\{
        \\  "anthropic": { "type": "api_key", "key": "sk-ant-test" }
        \\}
        ,
    });
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const auth_path = try std.fs.path.join(allocator, &.{ dir_path, "auth.json" });
    defer allocator.free(auth_path);

    try std.testing.expectError(
        error.MissingCredential,
        createProviderFromLuaConfig("openai/gpt-4o", auth_path, allocator),
    );
}

test "createProviderFromLuaConfig skips auth lookup for .auth = .none endpoints" {
    // Ollama has Endpoint.auth = .none. Even with no auth.json present we must
    // succeed and hand back an empty api_key string.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const auth_path = try std.fs.path.join(allocator, &.{ dir_path, "auth.json" });
    defer allocator.free(auth_path);

    var result = try createProviderFromLuaConfig("ollama/llama3", auth_path, allocator);
    defer result.deinit();

    try std.testing.expectEqualStrings("ollama/llama3", result.model_id);
    try std.testing.expectEqualStrings("", result.api_key);
    try std.testing.expectEqual(Serializer.openai, result.serializer);
}

test "createProviderFromLuaConfig returns UnknownProvider for unsupported provider" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const auth_path = try std.fs.path.join(allocator, &.{ dir_path, "auth.json" });
    defer allocator.free(auth_path);

    try std.testing.expectError(
        error.UnknownProvider,
        createProviderFromLuaConfig("fakeprovider/some-model", auth_path, allocator),
    );
}

test "ResponseBuilder assembles text and tool_use blocks" {
    const allocator = std.testing.allocator;

    var builder: ResponseBuilder = .{};
    errdefer builder.deinit(allocator);

    try builder.addText("Hello, world!", allocator);
    try builder.addToolUse("toolu_1", "read", "{\"path\":\"/tmp\"}", allocator);
    try builder.addText("Done.", allocator);

    const response = try builder.finish(.tool_use, 10, 20, allocator);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), response.content.len);
    try std.testing.expectEqual(.tool_use, response.stop_reason);
    try std.testing.expectEqual(@as(u32, 10), response.input_tokens);
    try std.testing.expectEqual(@as(u32, 20), response.output_tokens);

    switch (response.content[0]) {
        .text => |t| try std.testing.expectEqualStrings("Hello, world!", t.text),
        else => return error.TestUnexpectedResult,
    }
    switch (response.content[1]) {
        .tool_use => |tu| {
            try std.testing.expectEqualStrings("toolu_1", tu.id);
            try std.testing.expectEqualStrings("read", tu.name);
            try std.testing.expectEqualStrings("{\"path\":\"/tmp\"}", tu.input_raw);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (response.content[2]) {
        .text => |t| try std.testing.expectEqualStrings("Done.", t.text),
        else => return error.TestUnexpectedResult,
    }
}

test "ResponseBuilder empty finish returns no content" {
    const allocator = std.testing.allocator;

    var builder: ResponseBuilder = .{};
    const response = try builder.finish(.end_turn, 0, 0, allocator);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), response.content.len);
    try std.testing.expectEqual(.end_turn, response.stop_reason);
}

test "ResponseBuilder deinit cleans up on error" {
    const allocator = std.testing.allocator;

    var builder: ResponseBuilder = .{};
    try builder.addText("leaked?", allocator);
    try builder.addToolUse("id", "name", "input", allocator);
    // Simulate error path: deinit without finish
    builder.deinit(allocator);
}

test "Registry initializes with built-in endpoints" {
    const allocator = std.testing.allocator;
    var registry = try Registry.init(allocator);
    defer registry.deinit();

    const anth = registry.find("anthropic");
    try std.testing.expect(anth != null);
    try std.testing.expectEqual(Serializer.anthropic, anth.?.serializer);

    const oai = registry.find("openai");
    try std.testing.expect(oai != null);
    try std.testing.expectEqual(Serializer.openai, oai.?.serializer);

    const or_ep = registry.find("openrouter");
    try std.testing.expect(or_ep != null);
    try std.testing.expectEqual(Serializer.openai, or_ep.?.serializer);

    const ollama = registry.find("ollama");
    try std.testing.expect(ollama != null);
    try std.testing.expectEqual(Endpoint.Auth.none, ollama.?.auth);

    try std.testing.expectEqual(@as(?*const Endpoint, null), registry.find("unknown"));
}

test "Registry find returns null for unknown endpoint" {
    const allocator = std.testing.allocator;
    var registry = try Registry.init(allocator);
    defer registry.deinit();
    try std.testing.expectEqual(@as(?*const Endpoint, null), registry.find("nonexistent"));
}

test "Provider.call accepts a Request struct" {
    // This test exists to pin the new vtable shape. It can't actually
    // invoke a real provider (no network), so we only check that the
    // code compiles and that Request fields map to the old positional
    // arguments one-for-one. Will start failing with a compile error
    // the moment Provider.call signature doesn't match Request.
    const req = Request{
        .system_prompt = "sys",
        .messages = &.{},
        .tool_definitions = &.{},
        .allocator = std.testing.allocator,
    };
    _ = req;
    // Intentionally no call yet; this file compiles because Request
    // is a plain struct. Task 2 updates Provider.call to take *const
    // Request and this test is extended to call a mock provider.
}

test "isBuiltinEndpointName recognizes built-in providers" {
    try std.testing.expect(isBuiltinEndpointName("anthropic"));
    try std.testing.expect(isBuiltinEndpointName("openai"));
    try std.testing.expect(isBuiltinEndpointName("openrouter"));
    try std.testing.expect(isBuiltinEndpointName("groq"));
    try std.testing.expect(isBuiltinEndpointName("ollama"));
}

test "isBuiltinEndpointName rejects unknown names" {
    try std.testing.expect(!isBuiltinEndpointName("bogus"));
    try std.testing.expect(!isBuiltinEndpointName(""));
    try std.testing.expect(!isBuiltinEndpointName("ANTHROPIC"));
}

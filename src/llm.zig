//! LLM provider interface and routing.
//!
//! Defines the runtime-polymorphic Provider interface that all LLM backends
//! implement, plus the model string parser and provider factory.

const std = @import("std");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;

pub const anthropic = @import("providers/anthropic.zig");
pub const openai = @import("providers/openai.zig");

const log = std.log.scoped(.llm);

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
            system_prompt: []const u8,
            messages: []const types.Message,
            tool_definitions: []const types.ToolDefinition,
            allocator: Allocator,
        ) anyerror!types.LlmResponse,
        /// Human-readable provider name (for logging and display).
        name: []const u8,
    };

    /// Send a conversation to the LLM and return the response.
    pub fn call(
        self: Provider,
        system_prompt: []const u8,
        messages: []const types.Message,
        tool_definitions: []const types.ToolDefinition,
        allocator: Allocator,
    ) !types.LlmResponse {
        return self.vtable.call(self.ptr, system_prompt, messages, tool_definitions, allocator);
    }
};

/// Parsed model string components.
pub const ModelSpec = struct {
    /// Provider name (e.g., "anthropic", "openai").
    provider_name: []const u8,
    /// Model identifier within the provider (e.g., "claude-sonnet-4-20250514").
    model_id: []const u8,
};

/// Parse a "provider:model" string. If no colon is present, defaults to "anthropic".
pub fn parseModelString(model_str: []const u8) ModelSpec {
    if (std.mem.indexOfScalar(u8, model_str, ':')) |colon| {
        return .{
            .provider_name = model_str[0..colon],
            .model_id = model_str[colon + 1 ..],
        };
    }
    return .{
        .provider_name = "anthropic",
        .model_id = model_str,
    };
}

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
    /// Type-erased cleanup function for the concrete provider state.
    destroy_fn: *const fn (*anyopaque, Allocator) void,

    pub fn deinit(self: *ProviderResult) void {
        self.allocator.free(self.api_key);
        self.destroy_fn(self.state, self.allocator);
    }

    fn destroyAnthropicState(state: *anyopaque, alloc: Allocator) void {
        alloc.destroy(@as(*anthropic.AnthropicProvider, @ptrCast(@alignCast(state))));
    }

    fn destroyOpenAiState(state: *anyopaque, alloc: Allocator) void {
        const p: *openai.OpenAiProvider = @ptrCast(@alignCast(state));
        alloc.free(p.base_url);
        alloc.destroy(p);
    }
};

/// Create a provider from a model string and environment variables.
/// Reads API keys from ANTHROPIC_API_KEY or OPENAI_API_KEY based on provider prefix.
pub fn createProvider(model_str: []const u8, allocator: Allocator) !ProviderResult {
    const spec = parseModelString(model_str);

    if (std.mem.eql(u8, spec.provider_name, "anthropic")) {
        const api_key = std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch
            return error.MissingApiKey;
        errdefer allocator.free(api_key);

        const state = try allocator.create(anthropic.AnthropicProvider);
        state.* = .{ .api_key = api_key, .model = spec.model_id };

        return .{
            .provider = state.provider(),
            .state = state,
            .api_key = api_key,
            .allocator = allocator,
            .destroy_fn = ProviderResult.destroyAnthropicState,
        };
    }

    if (std.mem.eql(u8, spec.provider_name, "openai")) {
        const api_key = std.process.getEnvVarOwned(allocator, "OPENAI_API_KEY") catch
            return error.MissingApiKey;
        errdefer allocator.free(api_key);

        const base_url = std.process.getEnvVarOwned(allocator, "OPENAI_API_BASE") catch
            try allocator.dupe(u8, "https://api.openai.com/v1/chat/completions");
        errdefer allocator.free(base_url);

        const state = try allocator.create(openai.OpenAiProvider);
        state.* = .{ .api_key = api_key, .model = spec.model_id, .base_url = base_url };

        return .{
            .provider = state.provider(),
            .state = state,
            .api_key = api_key,
            .allocator = allocator,
            .destroy_fn = ProviderResult.destroyOpenAiState,
        };
    }

    return error.UnknownProvider;
}

/// Send a JSON POST request and return the response body.
/// Both providers share this HTTP plumbing; only the URL and extra headers differ.
pub fn httpPostJson(
    url: []const u8,
    body: []const u8,
    extra_headers: []const std.http.Header,
    allocator: Allocator,
) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(allocator);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch unreachable;

    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .method = .POST,
        .payload = body,
        .response_writer = &out.writer,
        .extra_headers = extra_headers,
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
    }) catch return error.ApiError;

    if (result.status != .ok) {
        out.deinit();
        return error.ApiError;
    }

    return out.toOwnedSlice();
}

// -- Tests -------------------------------------------------------------------

test "Provider vtable call dispatches correctly" {
    const allocator = std.testing.allocator;

    const TestProvider = struct {
        call_count: u32 = 0,

        const vtable: Provider.VTable = .{
            .call = callImpl,
            .name = "test",
        };

        fn callImpl(
            ptr: *anyopaque,
            _: []const u8,
            _: []const types.Message,
            _: []const types.ToolDefinition,
            alloc: Allocator,
        ) anyerror!types.LlmResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.call_count += 1;
            const content = try alloc.alloc(types.ContentBlock, 1);
            const text = try alloc.dupe(u8, "test response");
            content[0] = .{ .text = .{ .text = text } };
            return .{
                .content = content,
                .stop_reason = .end_turn,
                .input_tokens = 10,
                .output_tokens = 5,
            };
        }

        fn provider(self: *@This()) Provider {
            return .{ .ptr = self, .vtable = &vtable };
        }
    };

    var test_impl: TestProvider = .{};
    const p = test_impl.provider();

    const response = try p.call("system", &.{}, &.{}, allocator);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), test_impl.call_count);
    try std.testing.expectEqualStrings("test", p.vtable.name);
}

test "parseModelString splits provider and model" {
    const result = parseModelString("anthropic:claude-sonnet-4-20250514");
    try std.testing.expectEqualStrings("anthropic", result.provider_name);
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", result.model_id);
}

test "parseModelString defaults to anthropic when no prefix" {
    const result = parseModelString("claude-sonnet-4-20250514");
    try std.testing.expectEqualStrings("anthropic", result.provider_name);
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", result.model_id);
}

test "parseModelString handles openai prefix" {
    const result = parseModelString("openai:gpt-4o");
    try std.testing.expectEqualStrings("openai", result.provider_name);
    try std.testing.expectEqualStrings("gpt-4o", result.model_id);
}

test "createProvider returns UnknownProvider for unsupported provider" {
    const allocator = std.testing.allocator;
    const result = createProvider("fakeprovider:some-model", allocator);
    try std.testing.expectError(error.UnknownProvider, result);
}

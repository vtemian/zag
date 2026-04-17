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

/// Hard cap on a single SSE line. Defends against hostile or broken endpoints
/// that stream bytes without a newline, which would otherwise grow
/// `pending_line` until the agent OOMs.
const MAX_SSE_LINE: usize = 1 * 1024 * 1024; // 1 MiB

/// Hard cap on the accumulated "data:" payload of a single SSE event, summed
/// across all data lines before the dispatching blank line.
const MAX_SSE_EVENT_DATA: usize = 4 * 1024 * 1024; // 4 MiB

/// Streaming event emitted by call_streaming for incremental response delivery.
/// Defined here (rather than in AgentThread) so the provider VTable can reference
/// it without creating a circular dependency.
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
    /// Env var holding the API key. Null if no auth needed.
    key_env: ?[]const u8,
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

const builtin_endpoints = [_]Endpoint{
    .{
        .name = "anthropic",
        .serializer = .anthropic,
        .url = "https://api.anthropic.com/v1/messages",
        .key_env = "ANTHROPIC_API_KEY",
        .auth = .x_api_key,
        .headers = &.{.{ .name = "anthropic-version", .value = "2023-06-01" }},
    },
    .{
        .name = "openai",
        .serializer = .openai,
        .url = "https://api.openai.com/v1/chat/completions",
        .key_env = "OPENAI_API_KEY",
        .auth = .bearer,
        .headers = &.{},
    },
    .{
        .name = "openrouter",
        .serializer = .openai,
        .url = "https://openrouter.ai/api/v1/chat/completions",
        .key_env = "OPENROUTER_API_KEY",
        .auth = .bearer,
        .headers = &.{.{ .name = "X-OpenRouter-Title", .value = "Zag" }},
    },
    .{
        .name = "groq",
        .serializer = .openai,
        .url = "https://api.groq.com/openai/v1/chat/completions",
        .key_env = "GROQ_API_KEY",
        .auth = .bearer,
        .headers = &.{},
    },
    .{
        .name = "ollama",
        .serializer = .openai,
        .url = "http://localhost:11434/v1/chat/completions",
        .key_env = null,
        .auth = .none,
        .headers = &.{},
    },
};

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

/// Build HTTP headers from an endpoint's auth config and extra headers.
/// The auth header value is always heap-allocated so freeHeaders() can
/// free it uniformly. Caller must call freeHeaders() when done.
pub fn buildHeaders(endpoint: *const Endpoint, api_key: []const u8, allocator: Allocator) !std.ArrayList(std.http.Header) {
    var headers: std.ArrayList(std.http.Header) = .empty;
    errdefer headers.deinit(allocator);

    switch (endpoint.auth) {
        .x_api_key => {
            const duped_key = try allocator.dupe(u8, api_key);
            errdefer allocator.free(duped_key);
            try headers.append(allocator, .{ .name = "x-api-key", .value = duped_key });
        },
        .bearer => {
            const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
            errdefer allocator.free(auth_value);
            try headers.append(allocator, .{ .name = "Authorization", .value = auth_value });
        },
        .none => {},
    }

    for (endpoint.headers) |h| {
        try headers.append(allocator, .{ .name = h.name, .value = h.value });
    }

    return headers;
}

/// Free headers built by buildHeaders(). The first header's value is always
/// heap-allocated (auth header) and must be freed.
pub fn freeHeaders(endpoint: *const Endpoint, headers: *std.ArrayList(std.http.Header), allocator: Allocator) void {
    if (endpoint.auth != .none and headers.items.len > 0) {
        allocator.free(headers.items[0].value);
    }
    headers.deinit(allocator);
}

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

        /// Streaming variant: invokes `callback.on_event` for each SSE event.
        /// Assembles and returns the final LlmResponse when stream ends.
        /// Checks cancel flag periodically; returns partial response if cancelled.
        call_streaming: *const fn (
            ptr: *anyopaque,
            system_prompt: []const u8,
            messages: []const types.Message,
            tool_definitions: []const types.ToolDefinition,
            allocator: Allocator,
            callback: StreamCallback,
            cancel: *std.atomic.Value(bool),
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

    /// Streaming variant: sends a conversation and invokes `callback.on_event`
    /// for each incremental event. Returns the fully assembled LlmResponse when
    /// the stream completes or is cancelled.
    pub fn callStreaming(
        self: Provider,
        system_prompt: []const u8,
        messages: []const types.Message,
        tool_definitions: []const types.ToolDefinition,
        allocator: Allocator,
        callback: StreamCallback,
        cancel: *std.atomic.Value(bool),
    ) !types.LlmResponse {
        return self.vtable.call_streaming(self.ptr, system_prompt, messages, tool_definitions, allocator, callback, cancel);
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

/// Create a provider from the ZAG_MODEL environment variable.
/// Reads the model string, initializes the endpoint registry, looks up the
/// provider, and returns everything bundled in a single ProviderResult.
pub fn createProviderFromEnv(allocator: Allocator) !ProviderResult {
    const model_id = std.process.getEnvVarOwned(allocator, "ZAG_MODEL") catch
        try allocator.dupe(u8, "anthropic/claude-sonnet-4-20250514");
    errdefer allocator.free(model_id);

    var registry = try Registry.init(allocator);
    errdefer registry.deinit();

    return createProviderWithRegistry(model_id, registry, allocator);
}

/// Create a provider from an explicit model string and registry.
/// Takes ownership of both model_id and registry on success.
fn createProviderWithRegistry(model_id: []const u8, registry: Registry, allocator: Allocator) !ProviderResult {
    const spec = parseModelString(model_id);
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

    const uri = std.Uri.parse(url) catch return error.InvalidUri;

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

/// Owns an HTTP client + request for incremental SSE reading.
/// Both providers share this plumbing; only the URL and extra headers differ.
///
/// Must be heap-allocated (create/destroy pattern) because the body reader
/// holds a pointer into the internal transfer buffer.
///
/// After creation, call `readLine` repeatedly to read SSE lines one at a time.
/// Each call returns a line (without trailing newline), or `null` at end of
/// stream. The returned slice is valid until the next `readLine` call.
pub const StreamingResponse = struct {
    /// HTTP client that owns the underlying TCP connection.
    client: std.http.Client,
    /// In-flight HTTP request handle for the streaming POST.
    req: std.http.Client.Request,
    /// Reader over the chunked/content-length HTTP body.
    body_reader: *std.Io.Reader,
    /// Transfer buffer for the HTTP body reader. The body reader holds a
    /// pointer into this buffer, which is why the struct must be pinned.
    transfer_buf: [8192]u8,

    /// Accumulates partial lines across network reads.
    pending_line: std.ArrayList(u8),
    /// Leftover bytes after a newline that belong to subsequent lines.
    remainder: std.ArrayList(u8),
    /// Backing allocator used for all owned resources.
    allocator: Allocator,

    /// Open a streaming HTTP POST connection.
    /// Caller must call `destroy` when done.
    pub fn create(
        url: []const u8,
        body: []const u8,
        extra_headers: []const std.http.Header,
        allocator: Allocator,
    ) !*StreamingResponse {
        const self = try allocator.create(StreamingResponse);
        errdefer allocator.destroy(self);

        self.* = .{
            .client = .{ .allocator = allocator },
            .req = undefined,
            .body_reader = undefined,
            .transfer_buf = undefined,
            .pending_line = .empty,
            .remainder = .empty,
            .allocator = allocator,
        };
        errdefer self.client.deinit();

        const uri = std.Uri.parse(url) catch return error.InvalidUri;

        self.req = self.client.request(.POST, uri, .{
            .extra_headers = extra_headers,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                // SSE streams must not be compressed; the line-based parser
                // reads raw bytes and would choke on gzip.
                .accept_encoding = .omit,
            },
            .redirect_behavior = .unhandled,
            .keep_alive = false,
        }) catch |err| {
            log.err("streaming: request creation failed: {s}", .{@errorName(err)});
            return error.ApiError;
        };
        errdefer self.req.deinit();

        // Send the request body.
        self.req.transfer_encoding = .{ .content_length = body.len };
        var bw = self.req.sendBodyUnflushed(&.{}) catch |err| {
            log.err("streaming: sendBodyUnflushed failed: {s}", .{@errorName(err)});
            return error.ApiError;
        };
        bw.writer.writeAll(body) catch |err| {
            log.err("streaming: body write failed: {s}", .{@errorName(err)});
            return error.ApiError;
        };
        bw.end() catch |err| {
            log.err("streaming: body end failed: {s}", .{@errorName(err)});
            return error.ApiError;
        };
        (self.req.connection orelse {
            log.err("streaming: no connection after body send", .{});
            return error.ApiError;
        }).flush() catch |err| {
            log.err("streaming: flush failed: {s}", .{@errorName(err)});
            return error.ApiError;
        };

        // Receive response headers.
        var redirect_buf: [0]u8 = .{};
        var response = self.req.receiveHead(&redirect_buf) catch |err| {
            log.err("streaming: receiveHead failed: {s}", .{@errorName(err)});
            return error.ApiError;
        };

        if (response.head.status != .ok) {
            log.err("streaming: HTTP status {d}", .{@intFromEnum(response.head.status)});
            return error.ApiError;
        }

        // Obtain the incremental body reader. The pointer into transfer_buf
        // is stable because self is heap-allocated.
        self.body_reader = response.reader(&self.transfer_buf);

        return self;
    }

    pub fn destroy(self: *StreamingResponse) void {
        const alloc = self.allocator;
        self.pending_line.deinit(alloc);
        self.remainder.deinit(alloc);
        self.req.deinit();
        self.client.deinit();
        alloc.destroy(self);
    }

    /// Read the next line from the SSE stream (delimited by '\n').
    /// Returns the line content without trailing '\n' or '\r\n', or
    /// `null` when the stream has ended.
    /// The returned slice is valid until the next `readLine` call.
    pub fn readLine(self: *StreamingResponse) !?[]const u8 {
        self.pending_line.clearRetainingCapacity();

        // First, consume any leftover bytes from a previous read.
        if (self.remainder.items.len > 0) {
            if (std.mem.indexOfScalar(u8, self.remainder.items, '\n')) |nl_pos| {
                try self.appendToPendingLine(self.remainder.items[0..nl_pos]);
                // Shift remainder forward past the newline.
                const after = self.remainder.items[nl_pos + 1 ..];
                std.mem.copyForwards(u8, self.remainder.items[0..after.len], after);
                self.remainder.shrinkRetainingCapacity(after.len);
                return stripCr(self.pending_line.items);
            }
            // No newline in remainder; move it all to pending_line and continue reading.
            try self.appendToPendingLine(self.remainder.items);
            self.remainder.clearRetainingCapacity();
        }

        // Read from the network until we find a newline or hit end of stream.
        while (true) {
            var chunk: [4096]u8 = undefined;
            const n = self.body_reader.readSliceShort(&chunk) catch
                return error.ApiError;
            if (n == 0) {
                // End of stream.
                if (self.pending_line.items.len > 0) return stripCr(self.pending_line.items);
                return null;
            }

            const received = chunk[0..n];
            if (std.mem.indexOfScalar(u8, received, '\n')) |nl_pos| {
                try self.appendToPendingLine(received[0..nl_pos]);
                // Save everything after the newline for subsequent calls.
                // Bounded by chunk.len (4096), but we bounds-check for shape
                // consistency with the pending_line path.
                if (nl_pos + 1 < n) {
                    if (self.remainder.items.len + (n - nl_pos - 1) > MAX_SSE_LINE) {
                        return error.SseLineTooLong;
                    }
                    try self.remainder.appendSlice(self.allocator, received[nl_pos + 1 .. n]);
                }
                return stripCr(self.pending_line.items);
            }

            // No newline yet; accumulate and keep reading.
            try self.appendToPendingLine(received);
        }
    }

    /// Append bytes to `pending_line` with a hard cap. Returns SseLineTooLong
    /// when the next append would push the line past MAX_SSE_LINE, which
    /// defends against endpoints that stream bytes without a newline.
    fn appendToPendingLine(self: *StreamingResponse, bytes: []const u8) !void {
        if (self.pending_line.items.len + bytes.len > MAX_SSE_LINE) {
            return error.SseLineTooLong;
        }
        try self.pending_line.appendSlice(self.allocator, bytes);
    }

    fn stripCr(line: []const u8) []const u8 {
        if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
        return line;
    }

    /// A single dispatched SSE event with its type and data payload.
    pub const SseEvent = struct {
        /// Event type from the "event:" field. Empty if no event field was present.
        event_type: []const u8,
        /// Data payload from the "data:" field(s).
        data: []const u8,
    };

    /// Read SSE events from the stream, yielding one at a time.
    /// Accumulates "event:" and "data:" fields across lines, dispatches on
    /// blank line. Skips comment lines (including pings). Checks the cancel
    /// flag between lines. Returns null at end of stream or cancellation.
    ///
    /// The returned slices point into `event_buf` and `event_data` and are
    /// valid until the next call.
    pub fn nextSseEvent(
        self: *StreamingResponse,
        cancel: *std.atomic.Value(bool),
        event_buf: *[128]u8,
        event_data: *std.ArrayList(u8),
    ) !?SseEvent {
        var event_len: usize = 0;
        event_data.clearRetainingCapacity();

        while (true) {
            if (cancel.load(.acquire)) return null;

            const maybe_line = try self.readLine();
            const line = maybe_line orelse {
                // End of stream: return a final event if data accumulated
                if (event_data.items.len > 0) {
                    return SseEvent{
                        .event_type = event_buf[0..event_len],
                        .data = event_data.items,
                    };
                }
                return null;
            };

            if (line.len == 0) {
                // Blank line: dispatch event if we have data
                if (event_data.items.len > 0) {
                    return SseEvent{
                        .event_type = event_buf[0..event_len],
                        .data = event_data.items,
                    };
                }
                // No data accumulated, reset and keep reading
                event_len = 0;
                continue;
            }

            // Comment lines (including ": ping"), skip
            if (line[0] == ':') continue;

            if (std.mem.startsWith(u8, line, "event: ")) {
                const val = line["event: ".len..];
                const copy_len = @min(val.len, event_buf.len);
                @memcpy(event_buf[0..copy_len], val[0..copy_len]);
                event_len = copy_len;
            } else if (std.mem.startsWith(u8, line, "event:")) {
                const val = line["event:".len..];
                const copy_len = @min(val.len, event_buf.len);
                @memcpy(event_buf[0..copy_len], val[0..copy_len]);
                event_len = copy_len;
            } else if (std.mem.startsWith(u8, line, "data: ")) {
                const val = line["data: ".len..];
                if (event_data.items.len + val.len > MAX_SSE_EVENT_DATA) {
                    return error.SseEventDataTooLarge;
                }
                try event_data.appendSlice(self.allocator, val);
            } else if (std.mem.startsWith(u8, line, "data:")) {
                const val = line["data:".len..];
                if (event_data.items.len + val.len > MAX_SSE_EVENT_DATA) {
                    return error.SseEventDataTooLarge;
                }
                try event_data.appendSlice(self.allocator, val);
            }
        }
    }
};

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
        .key_env = "TEST_KEY",
        .auth = .bearer,
        .headers = &.{.{ .name = "X-Custom", .value = "val" }},
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
    };

    const duped = try original.dupe(allocator);
    defer duped.free(allocator);

    try std.testing.expectEqual(@as(?[]const u8, null), duped.key_env);
    try std.testing.expectEqual(@as(usize, 0), duped.headers.len);
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

        fn callStreamingImpl(
            ptr: *anyopaque,
            system_prompt: []const u8,
            messages: []const types.Message,
            tool_definitions: []const types.ToolDefinition,
            alloc: Allocator,
            _: StreamCallback,
            _: *std.atomic.Value(bool),
        ) anyerror!types.LlmResponse {
            return callImpl(ptr, system_prompt, messages, tool_definitions, alloc);
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
            _: []const u8,
            _: []const types.Message,
            _: []const types.ToolDefinition,
            _: Allocator,
        ) anyerror!types.LlmResponse {
            unreachable;
        }

        fn callStreamingImpl(
            ptr: *anyopaque,
            _: []const u8,
            _: []const types.Message,
            _: []const types.ToolDefinition,
            alloc: Allocator,
            callback: StreamCallback,
            _: *std.atomic.Value(bool),
        ) anyerror!types.LlmResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.stream_count += 1;
            callback.on_event(callback.ctx, .{ .text_delta = "hello" });
            callback.on_event(callback.ctx, .done);
            const content = try alloc.alloc(types.ContentBlock, 1);
            const text = try alloc.dupe(u8, "hello");
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
    const response = try p.callStreaming("system", &.{}, &.{}, allocator, callback, &cancel);
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

test "createProviderWithRegistry returns UnknownProvider for unsupported provider" {
    const allocator = std.testing.allocator;
    const model = try allocator.dupe(u8, "fakeprovider/some-model");
    var registry = try Registry.init(allocator);
    const result = createProviderWithRegistry(model, registry, allocator);
    // On error, ownership stays with us
    defer allocator.free(model);
    defer registry.deinit();
    try std.testing.expectError(error.UnknownProvider, result);
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
    try std.testing.expectEqual(@as(?[]const u8, null), ollama.?.key_env);

    try std.testing.expectEqual(@as(?*const Endpoint, null), registry.find("unknown"));
}

test "Registry find returns null for unknown endpoint" {
    const allocator = std.testing.allocator;
    var registry = try Registry.init(allocator);
    defer registry.deinit();
    try std.testing.expectEqual(@as(?*const Endpoint, null), registry.find("nonexistent"));
}

test "buildHeaders creates correct auth for bearer endpoint" {
    const allocator = std.testing.allocator;
    const endpoint = Endpoint{
        .name = "test",
        .serializer = .openai,
        .url = "https://example.com",
        .key_env = "TEST_KEY",
        .auth = .bearer,
        .headers = &.{.{ .name = "X-Custom", .value = "val" }},
    };
    var headers = try buildHeaders(&endpoint, "sk-test-key", allocator);
    defer freeHeaders(&endpoint, &headers, allocator);
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
    };
    var headers = try buildHeaders(&endpoint, "", allocator);
    defer freeHeaders(&endpoint, &headers, allocator);
    try std.testing.expectEqual(@as(usize, 0), headers.items.len);
}

test "readLine caps pending_line at MAX_SSE_LINE" {
    const allocator = std.testing.allocator;

    // Unterminated line larger than the cap: a hostile endpoint that never
    // sends '\n' would otherwise make pending_line grow without bound.
    const hostile = try allocator.alloc(u8, MAX_SSE_LINE + 1024);
    defer allocator.free(hostile);
    @memset(hostile, 'x');

    var fake = std.Io.Reader.fixed(hostile);

    // Other StreamingResponse fields stay undefined because readLine only
    // touches pending_line, remainder, body_reader, and allocator.
    var sr: StreamingResponse = .{
        .client = undefined,
        .req = undefined,
        .body_reader = &fake,
        .transfer_buf = undefined,
        .pending_line = .empty,
        .remainder = .empty,
        .allocator = allocator,
    };
    defer sr.pending_line.deinit(allocator);
    defer sr.remainder.deinit(allocator);

    try std.testing.expectError(error.SseLineTooLong, sr.readLine());
}

test "StreamingResponse.create returns InvalidUri on malformed endpoint" {
    // A malformed URL must surface as a real error instead of panicking.
    // `create` allocates before parsing, so a failure here also exercises
    // the errdefer cleanup for the heap struct.
    const allocator = std.testing.allocator;
    const result = StreamingResponse.create("not a url", "", &.{}, allocator);
    try std.testing.expectError(error.InvalidUri, result);
}

test "httpPostJson returns InvalidUri on malformed endpoint" {
    const allocator = std.testing.allocator;
    const result = httpPostJson("not a url", "", &.{}, allocator);
    try std.testing.expectError(error.InvalidUri, result);
}

test "nextSseEvent caps event_data at MAX_SSE_EVENT_DATA" {
    const allocator = std.testing.allocator;

    // Build a stream of many short "data:" lines that collectively exceed the
    // event-data cap. Each line is well under MAX_SSE_LINE, but summed across
    // them the accumulated data blows past MAX_SSE_EVENT_DATA.
    const chunk_payload_len: usize = 4000;
    const line_count: usize = (MAX_SSE_EVENT_DATA / chunk_payload_len) + 2;
    const line_len = "data: ".len + chunk_payload_len + 1; // +1 for '\n'

    const stream = try allocator.alloc(u8, line_count * line_len);
    defer allocator.free(stream);

    var cursor: usize = 0;
    for (0..line_count) |_| {
        @memcpy(stream[cursor .. cursor + "data: ".len], "data: ");
        cursor += "data: ".len;
        @memset(stream[cursor .. cursor + chunk_payload_len], 'y');
        cursor += chunk_payload_len;
        stream[cursor] = '\n';
        cursor += 1;
    }

    var fake = std.Io.Reader.fixed(stream);

    var sr: StreamingResponse = .{
        .client = undefined,
        .req = undefined,
        .body_reader = &fake,
        .transfer_buf = undefined,
        .pending_line = .empty,
        .remainder = .empty,
        .allocator = allocator,
    };
    defer sr.pending_line.deinit(allocator);
    defer sr.remainder.deinit(allocator);

    var cancel = std.atomic.Value(bool).init(false);
    var event_buf: [128]u8 = undefined;
    var event_data: std.ArrayList(u8) = .empty;
    defer event_data.deinit(allocator);

    try std.testing.expectError(
        error.SseEventDataTooLarge,
        sr.nextSseEvent(&cancel, &event_buf, &event_data),
    );
}

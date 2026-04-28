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
pub const chatgpt = @import("providers/chatgpt.zig");
pub const cost = @import("llm/cost.zig");
pub const Usage = cost.Usage;
pub const Trajectory = @import("Trajectory.zig");
pub const streaming = @import("llm/streaming.zig");
pub const http = @import("llm/http.zig");
pub const error_detail = @import("llm/error_detail.zig");
pub const error_class = @import("llm/error_class.zig");
const registry_mod = @import("llm/registry.zig");
pub const Endpoint = registry_mod.Endpoint;
pub const Registry = registry_mod.Registry;
pub const freeOAuthSpec = registry_mod.freeOAuthSpec;

const log = std.log.scoped(.llm);

/// Errors a Provider's call/callStreaming may legitimately produce.
/// Unexpected stdlib errors (HTTP plumbing, JSON parse) are logged and
/// remapped to `ApiError` at the provider boundary so the vtable surface
/// stays small and callers can switch exhaustively.
pub const ProviderError = std.mem.Allocator.Error || CancelError || error{
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
    /// Provider signalled a mid-stream failure (e.g. Responses API
    /// `response.failed` event) and the turn cannot be assembled.
    ProviderResponseFailed,
    /// `auth.json` has no entry for the endpoint's provider name. The
    /// user needs to run `zag --login=<provider>` (for OAuth providers)
    /// or edit `auth.json` (for api-key providers).
    NotLoggedIn,
    /// Refresh token was rejected by the IdP (invalid_grant family).
    /// The user needs to re-run `zag --login=<provider>`.
    LoginExpired,
};

/// Cooperative-cancellation error, composed into ProviderError via `||`.
/// Kept as its own small set so non-provider subsystems (streaming reader,
/// bash tool) can depend on `CancelError` without pulling the full
/// provider surface.
pub const CancelError = error{
    /// The caller's cancel flag was observed set; work was aborted
    /// cooperatively. The stream/child is torn down before returning.
    Cancelled,
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
        error.Cancelled => error.Cancelled,
        error.ProviderResponseFailed => error.ProviderResponseFailed,
        error.NotLoggedIn => error.NotLoggedIn,
        error.LoginExpired => error.LoginExpired,
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
    /// Partial extended-thinking text. The `text` slice is borrowed from
    /// the SSE parser's scratch buffer and is only valid for the duration
    /// of the callback; consumers must copy before stashing.
    thinking_delta: struct { text: []const u8 },
    /// End of a thinking block. Lets consumers flush an in-flight thinking
    /// node before the next content block (text or tool_use) begins.
    thinking_stop,
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

/// Extended-thinking knob requested by the caller. Providers that don't
/// understand a given variant either coerce to their closest equivalent
/// (Codex maps `.adaptive` to `reasoning.effort`) or silently ignore it.
pub const ThinkingConfig = union(enum) {
    /// Explicitly disable thinking. Distinct from `null` (unset) so a
    /// caller can override a provider's default-on behavior.
    disabled,
    /// Fixed thinking budget. `budget_tokens` is the cap Anthropic places
    /// on reasoning tokens; providers without a token budget ignore it.
    enabled: struct { budget_tokens: u32 },
    /// Let the provider pick the depth based on task difficulty. Anthropic
    /// emits `thinking:{type:"adaptive"}` paired with `output_config.effort`.
    adaptive: struct { effort: Effort },

    pub const Effort = enum { low, medium, high };
};

/// Report whether a Claude model identifier advertises extended-thinking
/// support. Substring match, not an exhaustive catalog; the set of
/// thinking-capable Claude models grows and this function is the one place
/// to extend when a new family ships. PR 3 moves this decision into Lua.
pub fn supportsExtendedThinking(model_id: []const u8) bool {
    // Claude 4 opus / sonnet families (incl. 4-5 point-releases).
    if (std.mem.indexOf(u8, model_id, "opus-4") != null) return true;
    if (std.mem.indexOf(u8, model_id, "sonnet-4") != null) return true;
    // Claude 3.7 sonnet (the first thinking-capable Claude).
    if (std.mem.indexOf(u8, model_id, "3-7-sonnet") != null) return true;
    return false;
}

/// The neutral input shape that every provider vtable accepts.
///
/// Provider-specific wire-format concerns (system placement, tool
/// wrapping, role mapping) live inside each provider's own file.
/// A provider receives exactly this struct by const pointer and
/// emits its own request body.
pub const Request = struct {
    /// Stable portion of the system prompt. Content that doesn't change
    /// across turns (identity, tool list, guidelines). PR 5 will let
    /// Anthropic attach a `cache_control` breakpoint after this segment
    /// so the prefix stays cache-warm; for now providers simply
    /// concatenate stable + "\n\n" + volatile into a single system field.
    system_stable: []const u8 = "",
    /// Volatile portion of the system prompt. Per-turn content like
    /// environment snapshots or date stamps that would bust a prefix
    /// cache if included in `system_stable`.
    system_volatile: []const u8 = "",
    /// Conversation history in chronological order.
    messages: []const types.Message,
    /// Tools offered to the LLM for this turn. May be empty.
    tool_definitions: []const types.ToolDefinition,
    /// Allocator for response allocations owned by the caller.
    allocator: Allocator,
    /// Optional extended-thinking override. `null` lets the provider pick
    /// a sensible default for the model (Anthropic turns thinking on for
    /// any thinking-capable Claude).
    thinking: ?ThinkingConfig = null,

    /// Join the stable and volatile halves with "\n\n" into a single
    /// owned string. Providers that can only emit one system field
    /// (OpenAI Chat Completions, Responses/ChatGPT) call this; the
    /// Anthropic path will use the parts directly once PR 5 introduces
    /// the 2-element `system` array with `cache_control`.
    ///
    /// If one half is empty the separator is omitted so a purely stable
    /// prompt round-trips byte-for-byte with the pre-split API.
    pub fn joinedSystem(self: *const Request, allocator: Allocator) ![]u8 {
        return joinSystemParts(self.system_stable, self.system_volatile, allocator);
    }
};

/// Concatenate the two system prompt halves with a blank-line separator.
/// Caller owns the returned slice. When either half is empty the other
/// is returned as a pure dupe so the joined form is byte-identical to
/// the original single-string representation.
pub fn joinSystemParts(stable: []const u8, per_turn: []const u8, allocator: Allocator) ![]u8 {
    if (stable.len == 0) return allocator.dupe(u8, per_turn);
    if (per_turn.len == 0) return allocator.dupe(u8, stable);
    return std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ stable, per_turn });
}

/// Streaming variant: everything in `Request` plus the callback and
/// cancellation token. Kept as its own type (not an optional inside
/// `Request`) so the vtable signature remains unambiguous.
pub const StreamRequest = struct {
    /// Stable portion of the system prompt. See `Request.system_stable`.
    system_stable: []const u8 = "",
    /// Volatile portion of the system prompt. See `Request.system_volatile`.
    system_volatile: []const u8 = "",
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
    /// Optional extended-thinking override. See `Request.thinking`.
    thinking: ?ThinkingConfig = null,

    /// Join the stable and volatile halves. See `Request.joinedSystem`.
    pub fn joinedSystem(self: *const StreamRequest, allocator: Allocator) ![]u8 {
        return joinSystemParts(self.system_stable, self.system_volatile, allocator);
    }
};

/// Wire format for request/response serialization.
pub const Serializer = enum {
    /// Anthropic Messages API format.
    anthropic,
    /// OpenAI Chat Completions API format (also used by OpenRouter, Groq, Ollama, etc.).
    openai,
    /// OpenAI Responses API format (ChatGPT backend, used with OAuth).
    chatgpt,
};

/// Runtime-polymorphic LLM provider interface.
/// Uses the ptr + vtable pattern (same as std.mem.Allocator).
/// Each provider implements call() for its specific API format.
///
/// Provider impls must be thread-safe; see VTable comments. The task
/// tool relies on this when a child agent on a separate thread shares
/// the parent's provider.
pub const Provider = struct {
    /// Type-erased pointer to the concrete provider struct.
    ptr: *anyopaque,
    /// Function table for this provider implementation.
    vtable: *const VTable,

    pub const VTable = struct {
        /// Send a conversation and return the parsed response.
        ///
        /// Thread-safe: each call allocates its own http.Client and
        /// resolves credentials per-request, so no mutable state is
        /// shared. Multiple threads may invoke concurrently. Any
        /// future change that introduces a shared connection pool or
        /// token cache must preserve this invariant.
        call: *const fn (
            ptr: *anyopaque,
            req: *const Request,
        ) ProviderError!types.LlmResponse,

        /// Streaming variant: invokes `req.callback.on_event` for each
        /// SSE event. Assembles and returns the final LlmResponse when
        /// the stream ends or is cancelled.
        ///
        /// Thread-safe: see `call`.
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

/// Parsed model string components plus the per-model context window
/// pulled from the endpoint registry's rate card. Populated by
/// `parseModelString` (no registry lookup, `context_window = 0`) or
/// `resolveModelSpec` (with the registry, populating `context_window`
/// when the rate card carries one).
pub const ModelSpec = struct {
    /// Provider name (e.g., "anthropic", "openai").
    provider_name: []const u8,
    /// Model identifier within the provider (e.g., "claude-sonnet-4-20250514").
    model_id: []const u8,
    /// Maximum input tokens this model accepts in one request, copied from
    /// `Endpoint.models[i].context_window` when the registry knows about
    /// the model. Zero means "no rate card"; the agent loop's compaction
    /// fire helper short-circuits on a zero ceiling so unknown models
    /// don't trigger spurious compactions.
    context_window: u32 = 0,
};

/// Parse a "provider/model" string. If no slash is present, defaults to "anthropic".
/// Leaves `context_window = 0`; pair with `resolveModelSpec` for a
/// rate-card-aware spec when a registry is available.
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

/// Parse `model_string` and look up the model's context window in the
/// endpoint registry. Returns the parsed spec with `context_window`
/// populated when the registry knows about the provider AND the model id
/// appears in its `models` rate card; falls back to zero otherwise so
/// callers without a populated registry get the same behaviour as
/// `parseModelString`. The `provider_name` and `model_id` slices alias
/// `model_string`; the caller must keep that buffer alive for the
/// lifetime of the returned spec.
pub fn resolveModelSpec(
    registry_opt: ?*const Registry,
    model_string: []const u8,
) ModelSpec {
    var spec = parseModelString(model_string);
    const registry = registry_opt orelse return spec;
    const endpoint = registry.find(spec.provider_name) orelse return spec;
    for (endpoint.models) |rate| {
        if (std.mem.eql(u8, rate.id, spec.model_id)) {
            spec.context_window = rate.context_window;
            return spec;
        }
    }
    return spec;
}

/// Result of creating a provider. Owns all resources needed for LLM calls.
/// A single deinit() frees everything: provider state, auth path, model
/// string, and registry.
pub const ProviderResult = struct {
    /// The provider interface for agent loop LLM calls.
    provider: Provider,
    /// The full "provider/model" string (e.g., "anthropic/claude-sonnet-4-20250514").
    model_id: []const u8,
    /// The allocated provider state. Must be destroyed when done.
    state: *anyopaque,
    /// Absolute path to `auth.json`, owned by this result. Serializers
    /// borrow it for per-request credential resolution.
    auth_path: []const u8,
    /// Endpoint registry (owned, freed on deinit).
    registry: Registry,
    /// Allocator used to create the state (for cleanup).
    allocator: Allocator,
    /// Which serializer was used (needed for type-correct destroy).
    serializer: Serializer,

    pub fn deinit(self: *ProviderResult) void {
        self.allocator.free(self.auth_path);
        self.allocator.free(self.model_id);
        self.registry.deinit();
        switch (self.serializer) {
            .anthropic => {
                self.allocator.destroy(@as(*anthropic.AnthropicSerializer, @ptrCast(@alignCast(self.state))));
            },
            .openai => {
                self.allocator.destroy(@as(*openai.OpenAiSerializer, @ptrCast(@alignCast(self.state))));
            },
            .chatgpt => {
                self.allocator.destroy(@as(*chatgpt.ChatgptSerializer, @ptrCast(@alignCast(self.state))));
            },
        }
    }
};

/// Create a provider from Lua-populated config.
///
/// `default_model` is the model string the user set via
/// `zag.set_default_model("prov/id")` (null falls back to
/// `anthropic/claude-sonnet-4-20250514`). Credentials are not loaded
/// eagerly here; the serializer holds the path and resolves fresh bytes
/// per request via `buildHeaders`. A single up-front existence check keeps
/// the fail-fast behaviour for api-key providers: a missing entry surfaces
/// as `error.MissingCredential` before the TUI boots.
/// Endpoints whose `auth` discriminator is `.none` (e.g. Ollama) skip the
/// credential lookup entirely. The returned `ProviderResult` owns the duped
/// model string, the duped auth-file path, the endpoint registry, and the
/// serializer state.
///
/// Construct the default `auth.json` path in `buf` as
/// `$HOME/.config/zag/auth.json`, falling back to `./.config/zag/auth.json`
/// when `$HOME` is unset. Returns a slice of `buf`; no heap allocation.
fn defaultAuthPath(buf: []u8) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse ".";
    return std.fmt.bufPrint(buf, "{s}/.config/zag/auth.json", .{home});
}

/// Build a provider from `$HOME`/auth.json and a Lua-supplied model.
/// Wraps `createProviderFromLuaConfig` with the HOME lookup and path
/// construction that used to live in `main.zig`, so entry-point code can
/// just call this single factory.
///
/// `registry` is a borrowed pointer to the LuaEngine's provider registry
/// (seeded with builtins plus any `zag.provider{}` declarations from
/// config.lua). The factory deep-copies it into the returned
/// `ProviderResult` so the ProviderResult's lifetime stays independent of
/// the engine.
pub fn createProviderFromEnv(
    registry: *const Registry,
    default_model: ?[]const u8,
    allocator: Allocator,
) !ProviderResult {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const auth_path = defaultAuthPath(&path_buf) catch |err| {
        log.err("failed to construct auth.json path: {s}", .{@errorName(err)});
        return err;
    };
    return createProviderFromLuaConfig(registry, default_model, auth_path, allocator);
}

pub fn createProviderFromLuaConfig(
    registry: *const Registry,
    default_model: ?[]const u8,
    auth_file_path: []const u8,
    allocator: Allocator,
) !ProviderResult {
    const model_id = try allocator.dupe(u8, default_model orelse "anthropic/claude-sonnet-4-20250514");
    errdefer allocator.free(model_id);

    var owned_registry = try registry.dupe(allocator);
    errdefer owned_registry.deinit();

    const spec = parseModelString(model_id);
    const endpoint = owned_registry.find(spec.provider_name) orelse
        return error.UnknownProvider;

    // Fail-fast existence check before the TUI takes over. For api-key
    // providers this is a trivial lookup; for `.oauth` we call
    // `resolveCredential` so a stale token on disk is refreshed
    // up-front rather than ambushing the user mid-turn. Missing entries
    // and rejected refresh tokens both collapse to `MissingCredential`,
    // which `main.zig` maps to a `zag --login=<provider>` hint.
    switch (endpoint.auth) {
        .none => {},
        .x_api_key, .bearer => {
            var auth_file = try auth.loadAuthFile(allocator, auth_file_path);
            defer auth_file.deinit();
            const borrowed = (try auth_file.getApiKey(spec.provider_name)) orelse
                return error.MissingCredential;
            _ = borrowed;
        },
        .oauth => |oauth_spec| {
            const resolve_opts: auth.ResolveOptions = .{
                .token_url = oauth_spec.token_url,
                .client_id = oauth_spec.client_id,
                .account_id_claim_path = oauth_spec.account_id_claim_path,
            };
            const resolved = auth.resolveCredential(allocator, auth_file_path, spec.provider_name, resolve_opts) catch |err| switch (err) {
                error.NotLoggedIn, error.LoginExpired => return error.MissingCredential,
                else => return err,
            };
            resolved.deinit(allocator);
        },
    }

    const auth_path = try allocator.dupe(u8, auth_file_path);
    errdefer allocator.free(auth_path);

    switch (endpoint.serializer) {
        .anthropic => {
            const state = try allocator.create(anthropic.AnthropicSerializer);
            state.* = .{ .endpoint = endpoint, .auth_path = auth_path, .model = spec.model_id };
            return .{
                .provider = state.provider(),
                .model_id = model_id,
                .state = state,
                .auth_path = auth_path,
                .registry = owned_registry,
                .allocator = allocator,
                .serializer = .anthropic,
            };
        },
        .openai => {
            const state = try allocator.create(openai.OpenAiSerializer);
            state.* = .{ .endpoint = endpoint, .auth_path = auth_path, .model = spec.model_id };
            return .{
                .provider = state.provider(),
                .model_id = model_id,
                .state = state,
                .auth_path = auth_path,
                .registry = owned_registry,
                .allocator = allocator,
                .serializer = .openai,
            };
        },
        .chatgpt => {
            const state = try allocator.create(chatgpt.ChatgptSerializer);
            state.* = .{ .endpoint = endpoint, .auth_path = auth_path, .model = spec.model_id };
            return .{
                .provider = state.provider(),
                .model_id = model_id,
                .state = state,
                .auth_path = auth_path,
                .registry = owned_registry,
                .allocator = allocator,
                .serializer = .chatgpt,
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

    /// Add a thinking content block. Dupes text, signature, and id if present.
    ///
    /// `provider` records which wire protocol produced the block so it can be
    /// re-serialized on later turns (Anthropic requires echoing the signature;
    /// OpenAI Responses requires echoing the encrypted_content + id).
    pub fn addThinking(
        self: *ResponseBuilder,
        text: []const u8,
        signature: ?[]const u8,
        provider: types.ContentBlock.ThinkingProvider,
        allocator: Allocator,
    ) !void {
        try self.addThinkingWithId(text, signature, null, provider, allocator);
    }

    /// Variant of `addThinking` that also records a provider-assigned id. Used
    /// by the OpenAI Responses wire (Codex) where each reasoning item carries
    /// an `rs_...` identifier the follow-up request has to reference.
    pub fn addThinkingWithId(
        self: *ResponseBuilder,
        text: []const u8,
        signature: ?[]const u8,
        id: ?[]const u8,
        provider: types.ContentBlock.ThinkingProvider,
        allocator: Allocator,
    ) !void {
        const duped_text = try allocator.dupe(u8, text);
        errdefer allocator.free(duped_text);
        const duped_sig: ?[]const u8 = if (signature) |s| try allocator.dupe(u8, s) else null;
        errdefer if (duped_sig) |s| allocator.free(s);
        const duped_id: ?[]const u8 = if (id) |v| try allocator.dupe(u8, v) else null;
        errdefer if (duped_id) |v| allocator.free(v);
        try self.blocks.append(allocator, .{ .thinking = .{
            .text = duped_text,
            .signature = duped_sig,
            .provider = provider,
            .id = duped_id,
        } });
    }

    /// Add a redacted_thinking content block. Dupes the opaque ciphertext.
    pub fn addRedactedThinking(self: *ResponseBuilder, data: []const u8, allocator: Allocator) !void {
        const duped = try allocator.dupe(u8, data);
        errdefer allocator.free(duped);
        try self.blocks.append(allocator, .{ .redacted_thinking = .{ .data = duped } });
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
    pub fn finish(
        self: *ResponseBuilder,
        stop_reason: types.StopReason,
        input_tokens: u32,
        output_tokens: u32,
        cache_creation_tokens: u32,
        cache_read_tokens: u32,
        allocator: Allocator,
    ) !types.LlmResponse {
        return .{
            .content = try self.blocks.toOwnedSlice(allocator),
            .stop_reason = stop_reason,
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
            .cache_creation_tokens = cache_creation_tokens,
            .cache_read_tokens = cache_read_tokens,
        };
    }

    /// Free all accumulated blocks. Use on error paths when finish() won't be called.
    pub fn deinit(self: *ResponseBuilder, allocator: Allocator) void {
        for (self.blocks.items) |block| block.freeOwned(allocator);
        self.blocks.deinit(allocator);
    }
};

// -- Tests -------------------------------------------------------------------

/// Hand-construct a registry seeded with the providers these tests reference.
/// Production code gets its registry from Lua (`require("zag.providers.*")`);
/// the factory tests below want a deterministic fixture without booting a Lua
/// engine, so we stamp out a minimal set that matches the stdlib shape for
/// the handful of names exercised here (`anthropic`, `openai`, `ollama`,
/// `openai-oauth`).
fn testRegistryWithKnownProviders(allocator: Allocator) !Registry {
    var reg = Registry.init(allocator);
    errdefer reg.deinit();

    const anthropic_ep: Endpoint = .{
        .name = "anthropic",
        .serializer = .anthropic,
        .url = "https://api.anthropic.com/v1/messages",
        .auth = .x_api_key,
        .headers = &.{.{ .name = "anthropic-version", .value = "2023-06-01" }},
        .default_model = "claude-sonnet-4-20250514",
        .models = &.{},
    };
    try reg.add(try anthropic_ep.dupe(allocator));

    const openai_ep: Endpoint = .{
        .name = "openai",
        .serializer = .openai,
        .url = "https://api.openai.com/v1/chat/completions",
        .auth = .bearer,
        .headers = &.{},
        .default_model = "gpt-4o",
        .models = &.{},
    };
    try reg.add(try openai_ep.dupe(allocator));

    const ollama_ep: Endpoint = .{
        .name = "ollama",
        .serializer = .openai,
        .url = "http://localhost:11434/v1/chat/completions",
        .auth = .none,
        .headers = &.{},
        .default_model = "llama3",
        .models = &.{},
    };
    try reg.add(try ollama_ep.dupe(allocator));

    const openai_oauth_ep: Endpoint = .{
        .name = "openai-oauth",
        .serializer = .chatgpt,
        .url = "https://chatgpt.com/backend-api/codex/responses",
        .auth = .{ .oauth = .{
            .issuer = "https://auth.openai.com/oauth/authorize",
            .token_url = "https://auth.openai.com/oauth/token",
            .client_id = "app_EMoamEEZ73f0CkXaXp7hrann",
            .scopes = "openid profile email offline_access",
            .redirect_port = 1455,
            .account_id_claim_path = "https:~1~1api.openai.com~1auth/chatgpt_account_id",
            .extra_authorize_params = &.{},
            .inject = .{
                .header = "Authorization",
                .prefix = "Bearer ",
                .extra_headers = &.{},
                .use_account_id = true,
                .account_id_header = "chatgpt-account-id",
            },
        } },
        // Codex-specific static headers. Matches what pi-mono and
        // opencode send to `chatgpt.com/backend-api/codex/responses`:
        // the endpoint rejects requests without `OpenAI-Beta` and the
        // originator/User-Agent pair even with valid OAuth creds.
        // session_id / x-client-request-id are injected per-call by the
        // chatgpt provider since they need to vary per request.
        .headers = &.{
            .{ .name = "OpenAI-Beta", .value = "responses=experimental" },
            .{ .name = "originator", .value = "zag_cli" },
            .{ .name = "User-Agent", .value = "zag_cli" },
        },
        .default_model = "gpt-5.2",
        .models = &.{},
    };
    try reg.add(try openai_oauth_ep.dupe(allocator));

    return reg;
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
                .system_stable = req.system_stable,
                .system_volatile = req.system_volatile,
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
        .system_stable = "system",
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
        .system_stable = "system",
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

test "supportsExtendedThinking recognizes thinking-capable Claudes" {
    try std.testing.expect(supportsExtendedThinking("claude-sonnet-4-20250514"));
    try std.testing.expect(supportsExtendedThinking("claude-sonnet-4-5-20250929"));
    try std.testing.expect(supportsExtendedThinking("claude-opus-4-20250514"));
    try std.testing.expect(supportsExtendedThinking("claude-3-7-sonnet-20250219"));
}

test "supportsExtendedThinking rejects older Claudes" {
    try std.testing.expect(!supportsExtendedThinking("claude-3-5-sonnet-20241022"));
    try std.testing.expect(!supportsExtendedThinking("claude-3-5-haiku-20241022"));
    try std.testing.expect(!supportsExtendedThinking("claude-3-opus-20240229"));
    try std.testing.expect(!supportsExtendedThinking("gpt-4o"));
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

    var registry = try testRegistryWithKnownProviders(allocator);
    defer registry.deinit();
    var result = try createProviderFromLuaConfig(&registry, "openai/gpt-4o", auth_path, allocator);
    defer result.deinit();

    try std.testing.expectEqualStrings("openai/gpt-4o", result.model_id);
    try std.testing.expectEqualStrings(auth_path, result.auth_path);
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

    var registry = try testRegistryWithKnownProviders(allocator);
    defer registry.deinit();
    var result = try createProviderFromLuaConfig(&registry, null, auth_path, allocator);
    defer result.deinit();

    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4-20250514", result.model_id);
    try std.testing.expectEqualStrings(auth_path, result.auth_path);
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

    var registry = try testRegistryWithKnownProviders(allocator);
    defer registry.deinit();
    try std.testing.expectError(
        error.MissingCredential,
        createProviderFromLuaConfig(&registry, "openai/gpt-4o", auth_path, allocator),
    );
}

test "createProviderFromLuaConfig skips auth lookup for .auth = .none endpoints" {
    // Ollama has Endpoint.auth = .none. Even with no auth.json present we
    // must succeed; nothing reads the credential path for .none endpoints.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const auth_path = try std.fs.path.join(allocator, &.{ dir_path, "auth.json" });
    defer allocator.free(auth_path);

    var registry = try testRegistryWithKnownProviders(allocator);
    defer registry.deinit();
    var result = try createProviderFromLuaConfig(&registry, "ollama/llama3", auth_path, allocator);
    defer result.deinit();

    try std.testing.expectEqualStrings("ollama/llama3", result.model_id);
    try std.testing.expectEqualStrings(auth_path, result.auth_path);
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

    var registry = try testRegistryWithKnownProviders(allocator);
    defer registry.deinit();
    try std.testing.expectError(
        error.UnknownProvider,
        createProviderFromLuaConfig(&registry, "fakeprovider/some-model", auth_path, allocator),
    );
}

test "createProviderFromLuaConfig returns MissingCredential for oauth provider with no entry" {
    // First-run hazard: the user launches `zag` before `zag --login=`.
    // The factory must fail fast with `MissingCredential` so `main.zig`
    // can print the "run zag --login=openai-oauth" hint, rather than
    // letting the TUI boot and surface `ApiError` mid-turn.
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

    var registry = try testRegistryWithKnownProviders(allocator);
    defer registry.deinit();
    try std.testing.expectError(
        error.MissingCredential,
        createProviderFromLuaConfig(&registry, "openai-oauth/gpt-5-codex", auth_path, allocator),
    );
}

test "mapProviderError passes NotLoggedIn through" {
    try std.testing.expectEqual(
        @as(ProviderError, error.NotLoggedIn),
        mapProviderError(error.NotLoggedIn),
    );
}

test "mapProviderError passes LoginExpired through" {
    try std.testing.expectEqual(
        @as(ProviderError, error.LoginExpired),
        mapProviderError(error.LoginExpired),
    );
}

test "ResponseBuilder assembles text and tool_use blocks" {
    const allocator = std.testing.allocator;

    var builder: ResponseBuilder = .{};
    errdefer builder.deinit(allocator);

    try builder.addText("Hello, world!", allocator);
    try builder.addToolUse("toolu_1", "read", "{\"path\":\"/tmp\"}", allocator);
    try builder.addText("Done.", allocator);

    const response = try builder.finish(.tool_use, 10, 20, 0, 0, allocator);
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

test "ResponseBuilder finish populates all four token counts" {
    const allocator = std.testing.allocator;

    var builder: ResponseBuilder = .{};
    errdefer builder.deinit(allocator);

    try builder.addText("hi", allocator);

    const response = try builder.finish(.end_turn, 11, 22, 33, 44, allocator);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 11), response.input_tokens);
    try std.testing.expectEqual(@as(u32, 22), response.output_tokens);
    try std.testing.expectEqual(@as(u32, 33), response.cache_creation_tokens);
    try std.testing.expectEqual(@as(u32, 44), response.cache_read_tokens);
}

test "ResponseBuilder empty finish returns no content" {
    const allocator = std.testing.allocator;

    var builder: ResponseBuilder = .{};
    const response = try builder.finish(.end_turn, 0, 0, 0, 0, allocator);
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

test "Provider.call accepts a Request struct" {
    // This test exists to pin the new vtable shape. It can't actually
    // invoke a real provider (no network), so we only check that the
    // code compiles and that Request fields map to the old positional
    // arguments one-for-one. Will start failing with a compile error
    // the moment Provider.call signature doesn't match Request.
    const req = Request{
        .system_stable = "sys",
        .messages = &.{},
        .tool_definitions = &.{},
        .allocator = std.testing.allocator,
    };
    _ = req;
    // Intentionally no call yet; this file compiles because Request
    // is a plain struct. Task 2 updates Provider.call to take *const
    // Request and this test is extended to call a mock provider.
}

test "joinSystemParts concatenates stable and per-turn with blank-line separator" {
    const allocator = std.testing.allocator;
    const joined = try joinSystemParts("stable", "per-turn", allocator);
    defer allocator.free(joined);
    try std.testing.expectEqualStrings("stable\n\nper-turn", joined);
}

test "joinSystemParts omits separator when either half is empty" {
    const allocator = std.testing.allocator;

    const only_stable = try joinSystemParts("stable", "", allocator);
    defer allocator.free(only_stable);
    try std.testing.expectEqualStrings("stable", only_stable);

    const only_per_turn = try joinSystemParts("", "per-turn", allocator);
    defer allocator.free(only_per_turn);
    try std.testing.expectEqualStrings("per-turn", only_per_turn);

    const empty = try joinSystemParts("", "", allocator);
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "Request.joinedSystem round-trips a single-string prompt via system_stable" {
    const allocator = std.testing.allocator;
    const req = Request{
        .system_stable = "you are zag",
        .messages = &.{},
        .tool_definitions = &.{},
        .allocator = allocator,
    };
    const joined = try req.joinedSystem(allocator);
    defer allocator.free(joined);
    try std.testing.expectEqualStrings("you are zag", joined);
}

test "StreamRequest.joinedSystem folds stable and per-turn halves" {
    const allocator = std.testing.allocator;
    var cancel = std.atomic.Value(bool).init(false);
    const noop: StreamCallback = .{
        .ctx = @ptrFromInt(@alignOf(u8)),
        .on_event = struct {
            fn on(_: *anyopaque, _: StreamEvent) void {}
        }.on,
    };
    const req = StreamRequest{
        .system_stable = "identity + tools",
        .system_volatile = "date: 2026-04-22",
        .messages = &.{},
        .tool_definitions = &.{},
        .allocator = allocator,
        .callback = noop,
        .cancel = &cancel,
    };
    const joined = try req.joinedSystem(allocator);
    defer allocator.free(joined);
    try std.testing.expectEqualStrings("identity + tools\n\ndate: 2026-04-22", joined);
}

# 017: Compositor Status Line & Pane Prompt Caching

## Problem

`Compositor.composite()` unconditionally redraws the global status line and all pane prompts on every frame. At lines 115–128 of `src/Compositor.zig`:

- `drawStatusLine()` (line 506) iterates the full terminal width (line 511) painting styled spaces, mode label, buffer name, rect dimensions, metrics.
- `drawPanePrompts()` (line 339) recursively walks every pane and calls `drawPanePrompt()` (line 370) to clear and redraw the prompt row.

In normal mode (not typing), most frames pass the same `input.mode`, `input.status`, and per-pane draft state forward. The redraws are wasted work: cells are painted with identical content. Expected gain: 3–5% of frame time in idle mode.

## Evidence

- **Unconditional redraw**: `composite()` lines 115–128 contain no guards; `drawStatusLine` and `drawPanePrompts` are always called.
- **Status line loop**: `drawStatusLine()` line 511–517 unconditionally fills every cell on the last row.
- **Prompt clearing**: `drawPanePrompt()` line 390 unconditionally clears the prompt row, then repaints. Draft is fetched on line 412 and written on line 430.
- **Pane-per-pane walk**: `drawPanePromptsPass()` lines 348–364 walks the full tree every frame.

## Solution: Cache State & Short-Circuit

### Cache State Fields

Add three fields to the `Compositor` struct (after `layout_dirty: bool = true` at line 44):

```zig
/// Cache of last-rendered InputState for status line comparison.
/// Used to skip drawStatusLine when mode and status are unchanged.
last_status_input: InputState = .{ .mode = .normal },

/// Per-pane draft lengths cached from previous frame.
/// Maps pane pointer to draft length; reset on layout_dirty.
last_draft_lens: std.AutoHashMap(*Buffer, usize),

/// Whether the cached status state is valid (cleared on invalidation).
status_cached: bool = false,

/// Per-pane prompt cache flags; cleared on layout_dirty.
prompt_cached: std.AutoHashMap(*Buffer, bool),
```

Update `init()` to allocate the hash maps on `self.allocator` (long-lived). Update `deinit()` to free them.

### Invalidation Points

- **On layout change** (`layout_dirty == true`): clear `status_cached`, `last_draft_lens`, `prompt_cached` (line 88–105).
- **On `input.mode` change** or `input.status` change: set `status_cached = false` (line 78, before composite body).
- **On per-pane draft edit**: fetch draft length in `composite()` and compare against `last_draft_lens[buffer]` (line 78, post-layout section). Set `prompt_cached[buffer] = false` if mismatch.
- **Always invalidate when `trace.enabled` is true** (line 553): metrics change every frame, so cache is unreliable; shortcut to no-cache path.

### Short-Circuit Logic

In `composite()` at line 115–128:

**Status line** (replace lines 115–120):
```zig
if (!status_cached or 
    input.mode != last_status_input.mode or 
    !std.mem.eql(u8, input.status, last_status_input.status)) {
  var s = trace.span("status_line");
  defer s.end();
  self.drawStatusLine(focused, input.mode);
  self.last_status_input = input;
  self.status_cached = !trace.enabled;
}
```

**Pane prompts** (replace lines 122–128):
```zig
// Invalidate pane cache if any draft changed length.
if (!trace.enabled) {
  self.invalidateChangedPrompts(root);
}

{
  var s = trace.span("pane_prompts");
  defer s.end();
  self.drawPanePromptsWithCache(root, focused, input);
}
```

Helper: `invalidateChangedPrompts()` walks the tree, fetches each pane's draft, compares length against `last_draft_lens`, sets `prompt_cached[buffer] = false` on mismatch, updates the cache.

Helper: `drawPanePromptsWithCache()` is a variant of `drawPanePromptsPass` that checks `prompt_cached[buffer]` before calling `drawPanePrompt`. On draw, set `prompt_cached[buffer] = true`.

### Memory Management

- **No string duplication per frame**: `last_status_input.status` holds a slice; do NOT free or reallocate on each `composite()` call. Instead:
  - Allocate a fixed-size buffer (e.g., `[256]u8`) in `Compositor` as `status_cache_buf`.
  - In the short-circuit, copy `input.status` into `status_cache_buf`, set `last_status_input.status` to point to the valid prefix.
  - On `deinit()`, nothing to free.
- **Hash maps**: allocated once in `init()`, cleared (not freed) on `layout_dirty`, retained across frames to avoid per-frame allocation churn.

## Steps

1. Add cache fields to `Compositor` struct definition.
2. Update `init()` to allocate hash maps and zero cache flags.
3. Update `deinit()` to free hash maps.
4. Copy `status_cache_buf` logic into `composite()` pre-loop.
5. Implement `invalidateChangedPrompts()` helper to walk tree and compare draft lengths.
6. Implement `drawPanePromptsWithCache()` and update `drawPanePrompt()` callers.
7. Replace unconditional `drawStatusLine` call with guard + cache update.
8. Replace unconditional `drawPanePrompts` call with guard + helper call.
9. Clear caches on `layout_dirty = true`.

## Verification

**Unit test**: Create `test "composite twice with same input skips status and prompts"`:
  - Call `composite()` twice with identical `InputState` and stable layout.
  - Add an internal counter field (`status_draws`, `prompt_draws`) to Compositor; increment on `drawStatusLine` / `drawPanePrompt` entry.
  - Assert `status_draws == 1` after two frames (cache hit on second).
  - Assert `prompt_draws == N` for N panes on first frame, no additional draws on second frame.

**Visual test**:
  - Type in insert mode; prompt should redraw per keystroke.
  - Type in normal mode; prompt should NOT redraw (cached until layout/mode change).
  - Switch mode; status line should redraw immediately.

## Risks & Mitigations

- **Stale cache on new invalidation paths**: If a future change modifies drafts or input without hitting a known invalidation point, the cache will show stale content. *Mitigation*: Default to "invalidate on unfamiliar change." Add assertions or debug logs when cache is bypassed to catch new patterns early.
- **Flaky benchmarks**: A 3–5% gain is small and depends on terminal width, theme complexity (style resolution), and heap pressure. *Mitigation*: Use `Metrics.zig` frame time and allocation counters; run benchmark over 1000 frames in idle to average out noise.
- **Hash map lookup overhead**: Per-pane lookups on every prompt may cost more than a simple redraw on very small pane counts. *Mitigation*: Profile; if 1–2 panes, inline the cache check instead of using hash map.

## Expected Outcome

On a typical idle session (80-col terminal, 3 panes), frame time should drop by 1–2 ms (from `status_line` and `pane_prompts` spans combined). Typing and layout changes remain unaffected.

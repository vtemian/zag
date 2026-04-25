# Per-plan execution prompts

Copy the block for the plan you want, paste into a fresh Claude Code instance started in `/Users/whitemonk/projects/ai/zag`. Each prompt is self-contained.

**Every prompt follows the same contract:**
- Read the plan file, re-verify file:line citations match current code (drift check).
- Execute the Steps section.
- Run `zig fmt --check .` and `zig build test` before claiming done.
- Commit per project convention (`<subsystem>: <description>` + Co-Authored-By trailer). Do not push.
- If the plan's assumptions don't match current code, stop and report before editing.

---

## 008 - Input: Kitty Keyboard Protocol

```
Read /Users/whitemonk/projects/ai/zag/plans/008-input-kitty-keyboard-protocol.md and execute it.

Adds CSI > 3 u / CSI < u enable/disable in Terminal.zig, CSI ... u parsing in input.zig, and extends KeyEvent with event_type plus super/hyper/meta modifiers. This touches every consumer of KeyEvent — audit via grep.

Dependency: if plan 009 (input split) has landed, add the KKP parser as a dedicated submodule per the split plan.

Verify: zig build test (including a new test that feeds "\x1b[65;5u" and asserts Ctrl-A event). Manual: test on Ghostty; Ctrl-Shift-A should disambiguate. Commit as "input: add Kitty Keyboard Protocol support".
```

//! SGR mouse sequence parsing.
//!
//! Decodes the `CSI < b;x;y M/m` form that xterm and every modern
//! emulator speak. The button byte is a bitfield: low two bits select
//! button (0=left, 1=middle, 2=right, 3=release in X10), the next three
//! bits carry shift/alt/ctrl, bit 0x20 marks motion (drag), and bit 0x40
//! marks wheel events. For wheel events bit 0x01 distinguishes up (0)
//! from down (1).

const core = @import("core.zig");
const Event = core.Event;
const KeyEvent = core.KeyEvent;
const MouseEvent = core.MouseEvent;

/// Parse SGR mouse encoding: bytes after "CSI <".
/// Format: b;x;y followed by M (press) or m (release).
pub fn parseSgrMouse(seq: []const u8) Event {
    var nums: [3]u16 = .{ 0, 0, 0 };
    var idx: usize = 0;
    var is_press = true;
    var terminated = false;

    for (seq) |c| {
        if (c == ';') {
            idx += 1;
            if (idx >= 3) return Event.none;
        } else if (c >= '0' and c <= '9') {
            nums[idx] = nums[idx] *| 10 +| (c - '0');
        } else if (c == 'M') {
            is_press = true;
            terminated = true;
            break;
        } else if (c == 'm') {
            is_press = false;
            terminated = true;
            break;
        } else {
            return Event.none;
        }
    }

    if (!terminated or idx < 2) return Event.none;

    const b = nums[0];
    const is_wheel = (b & 0x40) != 0;
    const button: u8 = if (is_wheel) 0 else @as(u8, @truncate(b & 0x03));
    const kind: MouseEvent.Kind = if (is_wheel)
        (if ((b & 0x01) == 0) .wheel_up else .wheel_down)
    else if (is_press) .press else .release;
    const modifiers = KeyEvent.Modifiers{
        .shift = (b & 0x04) != 0,
        .alt = (b & 0x08) != 0,
        .ctrl = (b & 0x10) != 0,
    };

    return Event{ .mouse = .{
        .button = button,
        .x = nums[1],
        .y = nums[2],
        .is_press = is_press,
        .kind = kind,
        .modifiers = modifiers,
    } };
}

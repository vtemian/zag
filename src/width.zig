//! Terminal display width for Unicode codepoints.
//!
//! Based on East Asian Width (UAX #11) wide/fullwidth ranges plus common
//! emoji blocks. Not a full Unicode width implementation - good enough for
//! a terminal TUI, not good enough to ship as a library.

const std = @import("std");
const testing = std.testing;

test "ascii printable is width 1" {
    try testing.expectEqual(@as(u2, 1), codepointWidth('A'));
    try testing.expectEqual(@as(u2, 1), codepointWidth('~'));
    try testing.expectEqual(@as(u2, 1), codepointWidth(' '));
}

test "control codes are width 0" {
    try testing.expectEqual(@as(u2, 0), codepointWidth(0x00));
    try testing.expectEqual(@as(u2, 0), codepointWidth(0x1B));
    try testing.expectEqual(@as(u2, 0), codepointWidth(0x7F));
}

test "CJK ideographs are width 2" {
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x4E2D)); // 中
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x597D)); // 好
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x3042)); // あ
}

test "emoji are width 2" {
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x1F600)); // 😀
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x1F680)); // 🚀
}

test "combining marks are width 0" {
    try testing.expectEqual(@as(u2, 0), codepointWidth(0x0301)); // combining acute
    try testing.expectEqual(@as(u2, 0), codepointWidth(0x20D7)); // combining right arrow above
}

test "zero-width joiner and variation selector are width 0" {
    try testing.expectEqual(@as(u2, 0), codepointWidth(0x200D));
    try testing.expectEqual(@as(u2, 0), codepointWidth(0xFE0F));
}

test "CJK unified ideograph range boundaries" {
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x4E00)); // first CJK unified
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x9FFF)); // last CJK unified
}

test "Hangul syllable range boundaries" {
    try testing.expectEqual(@as(u2, 2), codepointWidth(0xD7A3)); // last Hangul syllable
    try testing.expectEqual(@as(u2, 1), codepointWidth(0xD7A4)); // just past the block
}

test "Hangul Jamo start of range" {
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x1100));
}

test "emoji skin-tone modifiers are width 2" {
    // Skin-tone modifiers form ZWJ sequences with an emoji. On their own the
    // current table reports them as width 2; terminals vary wildly.
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x1F3FB));
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x1F3FC));
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x1F3FD));
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x1F3FE));
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x1F3FF));
}

test "regional indicator symbol letters pin current behaviour" {
    // TODO: regional indicators form flags as pairs; a proper implementation
    // reports width 2 for a grouped pair and width 1 (or 0) for singletons.
    try testing.expectEqual(@as(u2, 1), codepointWidth(0x1F1E6));
}

test {
    @import("std").testing.refAllDecls(@This());
}

/// Display width in terminal cells: 0 (control/combining), 1 (normal),
/// or 2 (wide/fullwidth/emoji).
pub fn codepointWidth(cp: u21) u2 {
    // C0/C1 controls and DEL
    if (cp < 0x20) return 0;
    if (cp >= 0x7F and cp < 0xA0) return 0;

    // Zero-width: combining marks, ZWJ, ZWNJ, variation selectors, BOM, soft hyphen
    if (isZeroWidth(cp)) return 0;

    // Wide / fullwidth ranges (UAX #11 W and F categories, abbreviated)
    if (isWide(cp)) return 2;

    return 1;
}

fn isZeroWidth(cp: u21) bool {
    return switch (cp) {
        0x00AD, // soft hyphen
        0x061C, // arabic letter mark
        0x180E, // mongolian vowel separator
        0x200B...0x200F, // ZW space, ZWNJ, ZWJ, LRM, RLM
        0x202A...0x202E, // bidi overrides
        0x2060...0x2064, // word joiner, invisibles
        0x2066...0x206F, // bidi isolates
        0xFEFF, // BOM / ZWNBSP
        0xFFF9...0xFFFB, // interlinear annotation
        0x0300...0x036F, // combining diacritical marks
        0x0483...0x0489, // combining cyrillic
        0x0591...0x05BD,
        0x05BF,
        0x05C1...0x05C2,
        0x05C4...0x05C5,
        0x05C7,
        0x0610...0x061A,
        0x064B...0x065F,
        0x0670,
        0x06D6...0x06DC,
        0x06DF...0x06E4,
        0x06E7...0x06E8,
        0x06EA...0x06ED,
        0x0711,
        0x0730...0x074A,
        0x1AB0...0x1AFF,
        0x1DC0...0x1DFF,
        0x20D0...0x20FF,
        0xFE00...0xFE0F, // variation selectors
        0xFE20...0xFE2F, // combining half marks
        0xE0100...0xE01EF, // variation selectors supplement
        => true,
        else => false,
    };
}

fn isWide(cp: u21) bool {
    return switch (cp) {
        0x1100...0x115F, // Hangul Jamo
        0x2329...0x232A, // angle brackets
        0x2E80...0x303E, // CJK radicals, kangxi, etc.
        0x3041...0x33FF, // hiragana, katakana, CJK compat
        0x3400...0x4DBF, // CJK extension A
        0x4E00...0x9FFF, // CJK unified ideographs
        0xA000...0xA4CF, // Yi
        0xAC00...0xD7A3, // Hangul syllables
        0xF900...0xFAFF, // CJK compat ideographs
        0xFE10...0xFE19, // vertical forms
        0xFE30...0xFE6F, // CJK compat forms, small forms
        0xFF00...0xFF60, // fullwidth forms (excluding halfwidth at end)
        0xFFE0...0xFFE6, // fullwidth signs
        0x1F300...0x1F64F, // misc symbols and pictographs, emoticons
        0x1F680...0x1F6FF, // transport and map symbols
        0x1F700...0x1F77F, // alchemical
        0x1F780...0x1F7FF, // geometric shapes ext
        0x1F800...0x1F8FF, // supplemental arrows-c
        0x1F900...0x1F9FF, // supplemental symbols and pictographs
        0x1FA00...0x1FA6F, // chess symbols
        0x1FA70...0x1FAFF, // symbols and pictographs ext-a
        0x20000...0x2FFFD, // CJK extension B-F
        0x30000...0x3FFFD, // CJK extension G
        => true,
        else => false,
    };
}

/// One grapheme-ish cluster extracted from a UTF-8 iterator.
///
/// `base` is the starting codepoint of the cluster. This is what gets stored
/// in the primary Screen cell. Joined codepoints (ZWJ continuations, skin-tone
/// modifiers, variation selectors, combining marks) are consumed silently and
/// do not appear in the returned cluster.
///
/// `width` is the visual column count for the cluster: 0, 1, or 2.
pub const Cluster = struct {
    base: u21,
    width: u2,
};

/// Read the next cluster from a UTF-8 iterator.
///
/// Handles: ZWJ sequences (`emoji ZWJ emoji...`), skin-tone modifiers
/// (U+1F3FB..U+1F3FF), variation selector VS-16 (U+FE0F), combining marks,
/// and regional-indicator flag pairs (two U+1F1E6..U+1F1FF codepoints).
///
/// Returns null if the iterator is exhausted.
pub fn nextCluster(iter: *std.unicode.Utf8Iterator) ?Cluster {
    const first = iter.nextCodepoint() orelse return null;

    // Regional indicator pair → flag, width 2. Unpaired → width 1 (the usual
    // codepointWidth). Consume the second indicator only if present.
    if (isRegionalIndicator(first)) {
        const saved = iter.i;
        if (iter.nextCodepoint()) |second| {
            if (isRegionalIndicator(second)) {
                return .{ .base = first, .width = 2 };
            }
        }
        iter.i = saved;
        return .{ .base = first, .width = 1 };
    }

    const base_width = codepointWidth(first);

    // A width-0 base (control, stray combining mark) stands alone; do not
    // absorb trailing joiners. They'll start their own cluster and produce
    // harmless width-0 output at the call site.
    if (base_width == 0) {
        return .{ .base = first, .width = 0 };
    }

    // Absorb any trailing joiners / modifiers into this cluster. Visual width
    // stays at base_width because every absorbed codepoint contributes 0.
    while (true) {
        const saved = iter.i;
        const next = iter.nextCodepoint() orelse break;

        // Skin-tone modifier or VS-16 always absorbs.
        if (isSkinToneModifier(next) or next == 0xFE0F) continue;

        // ZWJ: consume the ZWJ and the codepoint after it (the joined
        // emoji). If nothing follows, the sequence is malformed at EOF.
        // Stop cleanly.
        if (next == 0x200D) {
            _ = iter.nextCodepoint() orelse break;
            continue;
        }

        // Generic combining / zero-width absorbs.
        if (codepointWidth(next) == 0) continue;

        // Anything else belongs to the next cluster.
        iter.i = saved;
        break;
    }

    return .{ .base = first, .width = base_width };
}

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

fn isSkinToneModifier(cp: u21) bool {
    return cp >= 0x1F3FB and cp <= 0x1F3FF;
}

fn iterOf(s: []const u8) std.unicode.Utf8Iterator {
    const view = std.unicode.Utf8View.initUnchecked(s);
    return view.iterator();
}

test "nextCluster: plain ASCII is width 1, one codepoint per cluster" {
    var iter = iterOf("hi");
    const a = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 'h'), a.base);
    try testing.expectEqual(@as(u2, 1), a.width);
    const b = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 'i'), b.base);
    try testing.expectEqual(@as(u2, 1), b.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: single wide codepoint is one cluster of width 2" {
    var iter = iterOf("中");
    const c = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x4E2D), c.base);
    try testing.expectEqual(@as(u2, 2), c.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: single emoji is one cluster of width 2" {
    var iter = iterOf("😀");
    const c = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x1F600), c.base);
    try testing.expectEqual(@as(u2, 2), c.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: combining mark fuses into the preceding letter" {
    // 'a' + combining acute → one cluster, width 1, base='a'
    var iter = iterOf("a\u{0301}");
    const c = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 'a'), c.base);
    try testing.expectEqual(@as(u2, 1), c.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: emoji + VS-16 is one cluster" {
    // ❤ + VS-16 → one cluster, base = U+2764, width = codepointWidth(U+2764)
    // U+2764 is NOT in our wide table today (width 1). We deliberately do not
    // upgrade the base's width on VS-16; just fuse the VS-16 into the cluster.
    var iter = iterOf("\u{2764}\u{FE0F}");
    const c = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x2764), c.base);
    try testing.expectEqual(@as(u2, 1), c.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: emoji + skin-tone is one cluster of width 2" {
    // 👍 + 🏻 → one cluster, base = thumbs up, width 2
    var iter = iterOf("\u{1F44D}\u{1F3FB}");
    const c = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x1F44D), c.base);
    try testing.expectEqual(@as(u2, 2), c.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: ZWJ family emoji is one cluster of width 2" {
    // 👨‍👩‍👧 → one cluster, base = man, width 2
    var iter = iterOf("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}");
    const c = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x1F468), c.base);
    try testing.expectEqual(@as(u2, 2), c.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: flag pair is one cluster of width 2" {
    // 🇺🇸 → one cluster, base = U+1F1FA, width 2
    var iter = iterOf("\u{1F1FA}\u{1F1F8}");
    const c = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x1F1FA), c.base);
    try testing.expectEqual(@as(u2, 2), c.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: lone regional indicator is width 1" {
    // A single U+1F1E6 with no partner → width 1 (matches codepointWidth)
    var iter = iterOf("\u{1F1E6}");
    const c = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x1F1E6), c.base);
    try testing.expectEqual(@as(u2, 1), c.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: two flags back-to-back emit two clusters" {
    // 🇺🇸🇯🇵 → US flag cluster + JP flag cluster, each width 2
    var iter = iterOf("\u{1F1FA}\u{1F1F8}\u{1F1EF}\u{1F1F5}");
    const us = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x1F1FA), us.base);
    try testing.expectEqual(@as(u2, 2), us.width);
    const jp = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x1F1EF), jp.base);
    try testing.expectEqual(@as(u2, 2), jp.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: emoji followed by plain ASCII emits two clusters" {
    var iter = iterOf("\u{1F600}a");
    const e = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x1F600), e.base);
    try testing.expectEqual(@as(u2, 2), e.width);
    const a = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 'a'), a.base);
    try testing.expectEqual(@as(u2, 1), a.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: trailing ZWJ with no follow-up codepoint returns the base alone" {
    // 👨 + ZWJ + <EOF>. Must not infinite loop; must not UB.
    var iter = iterOf("\u{1F468}\u{200D}");
    const c = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x1F468), c.base);
    try testing.expectEqual(@as(u2, 2), c.width);
    try testing.expect(nextCluster(&iter) == null);
}

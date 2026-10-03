const std = @import("std");

// ============================================================================
// Shaping economy: word-level shaped-run cache + packed atlas packer model.
//
// This is the testable, platform-agnostic half of the shaping path. The
// CoreText backing lives in src/platform/macos.m (shaped CTLine cache +
// single coverage-mask atlas); this file encodes the exact same contract —
// key derivation, direct-mapped eviction, shelf packing — so the behavior is
// pinned by cross-platform Zig tests without touching CoreText.
//
// Hot-path rules: zero heap allocations (all state is caller-owned fixed
// arrays embedded in the structs below; no allocator parameter exists on any
// function), O(1) direct-mapped lookup, branch-light shelf packing.
// The pixel store itself is NOT here: on macOS it is one 2048x2048 8-bit
// alpha bitmap allocated once at startup (4 MiB heap, zero bytes of binary).
// ============================================================================

pub const ATLAS_W: u16 = 2048;
pub const ATLAS_H: u16 = 2048;

/// Direct-mapped shaped-run slots. 1024 entries * 32 bytes = 32 KiB.
/// Lives in BSS on macOS (static storage), costs no binary size there;
// here it is embedded in the struct so tests own their instance.
pub const CACHE_CAPACITY: usize = 1024;

/// Style bits packed into the cache key: bold, italic, mono, heading.
pub const StyleFlags = packed struct(u8) {
    bold: bool = false,
    italic: bool = false,
    mono: bool = false,
    heading: bool = false,
    _pad: u4 = 0,
};

/// Quantized style: font size in 0.5px steps (u16 covers up to 32767.5px)
/// plus the four style bits. Two runs share a shaped entry iff both match.
pub const StyleKey = packed struct(u32) {
    font_size_q: u16,
    flags: StyleFlags,
    _pad: u8 = 0,

    pub fn init(font_size: f32, bold: bool, italic: bool, mono: bool, heading: bool) StyleKey {
        const q: u16 = @intFromFloat(@round(font_size * 2.0));
        return .{
            .font_size_q = q,
            .flags = .{ .bold = bold, .italic = italic, .mono = mono, .heading = heading },
            ._pad = 0,
        };
    }
};

/// FNV-1a 64 over the raw text bytes, then the 4 style bytes.
/// Key equality implies identical bytes AND identical style; the macOS
/// backing memcmps the bytes on hash match to rule out collisions.
pub fn runHash(text: []const u8, style: StyleKey) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (text) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    const sk: u32 = @bitCast(style);
    const bytes = std.mem.asBytes(&sk);
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

/// One cached shaped run: its key, shaped width, and atlas UV rect.
/// 32 bytes, 8-byte aligned.
pub const ShapedRun = struct {
    key: u64 = 0,
    occupied: bool = false,
    _pad: [7]u8 = [_]u8{0} ** 7,
    width: f32 = 0,
    height: f32 = 0,
    atlas_x: u16 = 0,
    atlas_y: u16 = 0,
    atlas_w: u16 = 0,
    atlas_h: u16 = 0,
};

comptime {
    std.debug.assert(@sizeOf(ShapedRun) == 32);
}

/// Per-frame blit descriptor: a textured quad into the single atlas.
/// The renderer draws ONLY these; no CTLineDraw, no per-pixel CPU loop.
pub const TexturedQuad = struct {
    atlas_x: u16,
    atlas_y: u16,
    atlas_w: u16,
    atlas_h: u16,
    shaped: bool, // true = cache hit (zero shaping CPU); false = shaped+rasterized this frame
};

/// Direct-mapped shaped-run cache. Index = key % CAPACITY; collision evicts.
/// Lookup is O(1) with no probing loop and no allocation.
pub const ShapedRunCache = struct {
    slots: [CACHE_CAPACITY]ShapedRun = [_]ShapedRun{.{}} ** CACHE_CAPACITY,
    hits: u64 = 0,
    misses: u64 = 0, // == shapes performed == atlas rasterizations
    evictions: u64 = 0,

    pub fn lookup(self: *ShapedRunCache, key: u64) ?*ShapedRun {
        const slot = &self.slots[key % CACHE_CAPACITY];
        if (slot.occupied and slot.key == key) {
            self.hits += 1;
            return slot;
        }
        return null;
    }

    /// Caller has already shaped+measured and packed an atlas rect.
    pub fn insert(self: *ShapedRunCache, key: u64, width: f32, height: f32, rect: AtlasRect) *ShapedRun {
        const slot = &self.slots[key % CACHE_CAPACITY];
        if (slot.occupied and slot.key != key) self.evictions += 1;
        slot.* = .{
            .key = key,
            .occupied = true,
            .width = width,
            .height = height,
            .atlas_x = rect.x,
            .atlas_y = rect.y,
            .atlas_w = rect.w,
            .atlas_h = rect.h,
        };
        self.misses += 1;
        return slot;
    }

    pub fn hitRate(self: *const ShapedRunCache) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }
};

pub const AtlasRect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
};

/// Shelf packer for the single shared atlas. Rows ("shelves") fill left to
/// right; a rect taller than the current shelf opens a new shelf below.
/// Returns null when the rect does not fit -> caller flushes the atlas
/// (resets cursor; cache entries are dropped with it) and retries once.
pub const AtlasPacker = struct {
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    shelf_h: u16 = 0,
    flushes: u32 = 0,

    pub fn alloc(self: *AtlasPacker, w: u16, h: u16) ?AtlasRect {
        if (w == 0 or h == 0 or w > ATLAS_W or h > ATLAS_H) return null;
        if (self.cursor_x + w > ATLAS_W) {
            self.cursor_y += self.shelf_h;
            self.cursor_x = 0;
            self.shelf_h = 0;
        }
        if (self.cursor_y + h > ATLAS_H) return null;
        const rect = AtlasRect{ .x = self.cursor_x, .y = self.cursor_y, .w = w, .h = h };
        self.cursor_x += w;
        if (h > self.shelf_h) self.shelf_h = h;
        return rect;
    }

    pub fn reset(self: *AtlasPacker) void {
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.shelf_h = 0;
        self.flushes += 1;
    }
};

/// Simulate one frame's shaping work for a run: hit -> textured quad only;
/// miss -> shape once (caller-measured width/height), pack, insert.
/// `run_w_px`/`run_h_px` stand in for the CTLine measurement the macOS
/// backing performs exactly once per unique run.
pub fn drawRun(
    cache: *ShapedRunCache,
    packer: *AtlasPacker,
    text: []const u8,
    style: StyleKey,
    run_w_px: u16,
    run_h_px: u16,
) TexturedQuad {
    const key = runHash(text, style);
    if (cache.lookup(key)) |run| {
        return .{
            .atlas_x = run.atlas_x,
            .atlas_y = run.atlas_y,
            .atlas_w = run.atlas_w,
            .atlas_h = run.atlas_h,
            .shaped = false,
        };
    }
    var rect = packer.alloc(run_w_px, run_h_px);
    if (rect == null) {
        // Atlas full: single generational flush, drop cache with it.
        packer.reset();
        cache.* = .{};
        rect = packer.alloc(run_w_px, run_h_px);
    }
    const r = rect orelse return .{
        .atlas_x = 0,
        .atlas_y = 0,
        .atlas_w = 0,
        .atlas_h = 0,
        .shaped = false,
    };
    const run = cache.insert(key, @floatFromInt(run_w_px), @floatFromInt(run_h_px), r);
    return .{
        .atlas_x = run.atlas_x,
        .atlas_y = run.atlas_y,
        .atlas_w = run.atlas_w,
        .atlas_h = run.atlas_h,
        .shaped = true,
    };
}

// ============================================================================
// Math atlas contract (issue #355): formula-level cache identity + snapped
// blit geometry, mirroring platform_draw_math in src/platform/macos_zatex.m
// (same key byte order, same snap policy as platform_draw_text). Pure
// arithmetic, zero heap allocations: no allocator parameter exists on any
// function, so the hot path stays allocation-free by construction.
// ============================================================================

/// Formula cache key: FNV-1a 64 over the raw TeX bytes, then the font-size
/// bits plus the display flag (tail mixing mirrors runHash above and
/// shape_key in macos.m). Coverage masks rasterize at RASTER_SCALE for one
/// exact size, and a display formula lays out differently from the same
/// inline bytes — so size and mode are key identity, never raster metadata.
pub fn mathRunKey(tex: []const u8, font_size: f32, display: bool) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (tex) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    const fbits: u32 = @bitCast(font_size);
    const tail = [_]u8{
        @intCast(fbits & 0xff),
        @intCast((fbits >> 8) & 0xff),
        @intCast((fbits >> 16) & 0xff),
        @intCast((fbits >> 24) & 0xff),
        if (display) 1 else 0,
    };
    for (tail) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

/// Device-grid snap for a run/formula origin at the given output scale.
/// The origin quantizes (at most half a device px); intra-run pen advances
/// stay exact, so spacing never drifts. Positive doc-space only — matches
/// the roundf policy in platform_draw_text.
pub fn snapToGrid(v: f32, scale: f32) f32 {
    return @round(v * scale) / scale;
}

/// Snapped blit destination for a cached formula raster: the origin snaps
/// to the device grid and the size is the mask size exactly (never the
/// shaped advance — no sub-pixel stretch), same contract as the body blit.
pub const MathBlit = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub fn mathBlitDest(x: f32, y_top: f32, w_px: f32, h_px: f32, scale: f32) MathBlit {
    return .{
        .x = snapToGrid(x, scale),
        .y = snapToGrid(y_top, scale),
        .w = @ceil(w_px * scale) / scale,
        .h = @ceil(h_px * scale) / scale,
    };
}

// ============================================================================
// GPU batching model (issue #389): fill-color groups + wash-before-glyph.
//
// The platform text loop hoists SetFillColor out of the run loop: runs
// sharing one ColorGroup paint as one GPU batch (no per-run state churn).
// Opaque text collapses to RGB identity; translucent runs keep alpha in the
// key so a translucent group never merges into an opaque batch. The model
// is pure (no platform calls): group equality here must match the ObjC
// run_color_group in macos.m (same inputs -> same grouping), pinned below.
// ============================================================================

/// Fill-color batch identity for one text run. Opaque to callers (equality
/// only): same group => one primed fill color covers both runs.
pub const ColorGroup = struct {
    opaque_rgb: u24,
    alpha: u8, // 255 = opaque fast path; anything else keys distinctly

    pub fn init(r: u8, g: u8, b: u8, a: u8) ColorGroup {
        if (a == 255) return .{ .opaque_rgb = @as(u24, r) << 16 | @as(u24, g) << 8 | b, .alpha = 255 };
        // Translucent: fold the bytes (same xor-fold as run_color_group in
        // macos.m) so distinct (r,g,b,a) tuples never share a group.
        const fold: u8 = r ^ g ^ b ^ a;
        return .{ .opaque_rgb = @as(u24, fold) << 16 | @as(u24, a) << 8 | 0x01, .alpha = a };
    }

    pub fn eql(self: ColorGroup, other: ColorGroup) bool {
        return self.opaque_rgb == other.opaque_rgb and self.alpha == other.alpha;
    }
};

/// Masked blits are clip-parity safe only at the raster's native scale:
/// the 2x raster blits pixel-exact on 2x dests (snapped 1:1); on 1x the
/// downsample under a damage clip resamples up to 1 LSB differently than
/// the same blit unclipped, so incremental drag repaints never match
/// fresh renders (2026-10 drag-back residue, every gesture incl. extend).
/// 1x runs take the legacy direct draw (shaping still cached).
pub fn blitScaleParityOk(output_scale: f32) bool {
    return output_scale > 1.5;
}

/// Count the fill-color groups (batches) in one pass's run-color sequence:
/// the number of SetFillColor primes the platform loop issues (first run
/// primes, each group change re-primes). Zero runs => zero primes.
pub fn batchCount(colors: []const ColorGroup) usize {
    if (colors.len == 0) return 0;
    var n: usize = 1;
    var i: usize = 1;
    while (i < colors.len) : (i += 1) {
        if (!colors[i].eql(colors[i - 1])) n += 1;
    }
    return n;
}

test "gpu batching: single-color pass primes once, no per-run churn (issue #389)" {
    const body = ColorGroup.init(224, 224, 224, 255);
    const colors = [_]ColorGroup{ body, body, body, body, body };
    try std.testing.expectEqual(@as(usize, 1), batchCount(&colors));
}

test "gpu batching: color changes re-prime exactly at group edges (issue #389)" {
    const body = ColorGroup.init(224, 224, 224, 255);
    const accent = ColorGroup.init(90, 160, 255, 255);
    const muted = ColorGroup.init(140, 140, 145, 255);
    const colors = [_]ColorGroup{ body, body, accent, accent, muted, body };
    try std.testing.expectEqual(@as(usize, 4), batchCount(&colors));
    // Same RGB, different alpha: distinct groups (never merge translucent
    // into an opaque batch).
    const wash = ColorGroup.init(224, 224, 224, 82);
    const mixed = [_]ColorGroup{ body, wash, body };
    try std.testing.expectEqual(@as(usize, 3), batchCount(&mixed));
    try std.testing.expect(batchCount(&[_]ColorGroup{}) == 0);
}

test "gpu batching: opaque grouping is RGB-identity (issue #389)" {
    // Mirrors run_color_group in macos.m: opaque collapses to RGB, so two
    // runs of the same text color always batch even across alpha-255 calls.
    const a = ColorGroup.init(18, 18, 18, 255);
    const b = ColorGroup.init(18, 18, 18, 255);
    try std.testing.expect(a.eql(b));
    const c = ColorGroup.init(18, 18, 19, 255);
    try std.testing.expect(!a.eql(c));
}

test "gpu batching: masked blit is clip-parity safe only at native scale (issue #389)" {
    // Mirrors the g_output_scale > 1.5f gate in blit_tinted_mask_batched
    // (macos.m): 1x downsamples of the 2x raster differ under a damage
    // clip by up to 1 LSB vs unclipped, breaking incremental-vs-fresh
    // pixel parity, so 1x takes the legacy direct draw.
    try std.testing.expect(!blitScaleParityOk(1.0));
    try std.testing.expect(blitScaleParityOk(2.0));
}

test "shaped-run cache: repeat run is a hit, zero re-shape" {
    var cache = ShapedRunCache{};
    var packer = AtlasPacker{};
    const style = StyleKey.init(16.0, false, false, false, false);

    const q1 = drawRun(&cache, &packer, "hello", style, 48, 20);
    try std.testing.expect(q1.shaped); // first sight: shape+rasterize
    const q2 = drawRun(&cache, &packer, "hello", style, 48, 20);
    try std.testing.expect(!q2.shaped); // second sight: textured quad only
    try std.testing.expectEqual(q1.atlas_x, q2.atlas_x);
    try std.testing.expectEqual(q1.atlas_y, q2.atlas_y);
    try std.testing.expectEqual(@as(u64, 1), cache.hits);
    try std.testing.expectEqual(@as(u64, 1), cache.misses);
}

test "shaped-run cache: style bit flip is a distinct entry" {
    var cache = ShapedRunCache{};
    var packer = AtlasPacker{};
    const plain = StyleKey.init(16.0, false, false, false, false);
    const bold = StyleKey.init(16.0, true, false, false, false);
    const bigger = StyleKey.init(16.5, false, false, false, false);

    _ = drawRun(&cache, &packer, "word", plain, 40, 20);
    _ = drawRun(&cache, &packer, "word", bold, 44, 20);
    _ = drawRun(&cache, &packer, "word", bigger, 42, 21);
    try std.testing.expectEqual(@as(u64, 3), cache.misses);
    try std.testing.expectEqual(@as(u64, 0), cache.hits);
    // Each repeats as a hit afterwards.
    _ = drawRun(&cache, &packer, "word", plain, 40, 20);
    _ = drawRun(&cache, &packer, "word", bold, 44, 20);
    try std.testing.expectEqual(@as(u64, 2), cache.hits);
}

test "atlas packer: rects never overlap and fill shelves left-to-right" {
    var packer = AtlasPacker{};
    var rects: [64]AtlasRect = undefined;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        rects[i] = packer.alloc(100, 24) orelse return error.TestUnexpectedResult;
    }
    // 20 per 2048px shelf row; second row starts below.
    try std.testing.expectEqual(@as(u16, 0), rects[0].x);
    try std.testing.expectEqual(@as(u16, 0), rects[0].y);
    try std.testing.expectEqual(@as(u16, 100), rects[1].x);
    try std.testing.expectEqual(rects[0].y + 24, rects[20].y);
    try std.testing.expectEqual(@as(u16, 0), rects[20].x);
    // Pairwise non-overlap.
    var a: usize = 0;
    while (a < 64) : (a += 1) {
        var b: usize = a + 1;
        while (b < 64) : (b += 1) {
            const separated = rects[a].x + rects[a].w <= rects[b].x or
                rects[b].x + rects[b].w <= rects[a].x or
                rects[a].y + rects[a].h <= rects[b].y or
                rects[b].y + rects[b].h <= rects[a].y;
            try std.testing.expect(separated);
        }
    }
}

test "atlas packer: oversized rect rejected, flush recovers" {
    var packer = AtlasPacker{};
    try std.testing.expect(packer.alloc(3000, 10) == null);
    try std.testing.expect(packer.alloc(10, 3000) == null);
    // Fill the atlas with tall shelves until it reports full.
    var filled: u32 = 0;
    while (packer.alloc(2048, 64) != null) {
        filled += 1;
        if (filled > 100) break;
    }
    try std.testing.expect(packer.alloc(64, 16) == null);
    packer.reset();
    try std.testing.expect(packer.alloc(64, 16) != null);
    try std.testing.expectEqual(@as(u32, 1), packer.flushes);
}

test "math atlas: formula key identity covers bytes, size, display (issue #355)" {
    // Same formula + size + display mode must hit one entry; any of the
    // three changing must rasterize separately (a display formula lays out
    // differently from the same inline bytes, and coverage masks are
    // size-specific at RASTER_SCALE).
    const k1 = mathRunKey("\\frac{x+1}{2}", 17.0, false);
    const k2 = mathRunKey("\\frac{x+1}{2}", 17.0, false);
    try std.testing.expectEqual(k1, k2);
    try std.testing.expect(mathRunKey("\\frac{x+1}{2}", 17.0, true) != k1);
    try std.testing.expect(mathRunKey("\\frac{x+1}{2}", 18.0, false) != k1);
    try std.testing.expect(mathRunKey("\\frac{x+2}{2}", 17.0, false) != k1);
}

test "math atlas: origins snap to the device grid, advances stay exact (issue #355)" {
    // Mirrors platform_draw_math / platform_draw_text: the run origin
    // quantizes (at most half a device px per run) while intra-run pen
    // advances stay exact, so spacing never drifts.
    try std.testing.expectEqual(@as(f32, 50.5), snapToGrid(50.33, 2.0));
    try std.testing.expectEqual(@as(f32, 50.0), snapToGrid(50.24, 2.0));
    const v: f32 = 123.456;
    const s = snapToGrid(v, 2.0);
    try std.testing.expect(@abs(s - v) <= 0.25 + 1e-6);
    // Snapped origin lands on an exact device pixel: 2x grid, no resample.
    try std.testing.expectEqual(@as(f32, 0.0), @rem(s * 2.0, 1.0));
}

test "math atlas: blit dest is the mask size exactly, snapped (issue #355)" {
    // Same contract as the body blit: dest size is the raster mask size
    // (never the shaped advance — no sub-pixel stretch), positioned on
    // the device grid.
    const d = mathBlitDest(50.33, 40.67, 100.2, 24.6, 2.0);
    try std.testing.expectEqual(@as(f32, 50.5), d.x);
    try std.testing.expectEqual(@as(f32, 40.5), d.y);
    try std.testing.expectEqual(@as(f32, 100.5), d.w); // ceil(100.2*2)/2
    try std.testing.expectEqual(@as(f32, 25.0), d.h); // ceil(24.6*2)/2
}

test "shaping economy: repeated document shapes once per unique run" {
    // Simulates scrolling a document where ~40 viewport runs per frame draw
    // from a ~120-word vocabulary over 60 frames (2400 run draws).
    // BEFORE (no cache): 2400 shapes. AFTER: <= unique runs + evictions.
    var cache = ShapedRunCache{};
    var packer = AtlasPacker{};
    const styles = [_]StyleKey{
        StyleKey.init(16.0, false, false, false, false),
        StyleKey.init(16.0, true, false, false, false),
        StyleKey.init(24.0, true, false, false, true),
        StyleKey.init(14.0, false, false, true, false),
    };
    const vocab = [_][]const u8{
        "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog",
        "Simplicity", "prerequisite", "reliability", "markdown", "reader",
        "viewport", "shaping", "atlas", "cache", "performance", "zero",
        "allocation", "heading", "paragraph", "blockquote", "code",
    };
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();

    var frames: usize = 0;
    var draws: usize = 0;
    while (frames < 60) : (frames += 1) {
        var r: usize = 0;
        while (r < 40) : (r += 1) {
            const w = vocab[rand.intRangeLessThan(usize, 0, vocab.len)];
            const s = styles[rand.intRangeLessThan(usize, 0, styles.len)];
            _ = drawRun(&cache, &packer, w, s, 64, 20);
            draws += 1;
        }
    }
    const shapes: usize = @intCast(cache.misses);
    std.debug.print(
        "\n[SHAPING ECONOMY] draws={d} shapes={d} hits={d} hit_rate={d:.1}% evictions={d} atlas_flushes={d}\n",
        .{ draws, shapes, cache.hits, cache.hitRate() * 100.0, cache.evictions, packer.flushes },
    );
    try std.testing.expectEqual(@as(usize, 2400), draws);
    // Vocabulary bounds unique runs to 24 words * 4 styles = 96 keys.
    try std.testing.expect(shapes <= 96 + @as(usize, @intCast(cache.evictions)));
    try std.testing.expect(cache.hitRate() > 0.90);
}

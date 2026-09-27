// ZaTeX runtime math backend (LaTeX math plugin).
//
// Included by src/platform/macos.m — one TU, so the -Oz machine outliner
// sees the same code shape as before and ship __TEXT stays attributable
// (AGENTS.md §7: this file plus its Zig seams count as plugin code; twin
// builds include macos_zatex_stub.m instead; same TU, same flags).
//
// Design: dlopen only, never linked — zero LINKED dependencies, so the
// binary keeps its size budget with the engine absent. The engine
// (libzatex.dylib, built from github.com/gregoreesmaa/zatex
// packages/zatex) lays out synchronously in microseconds over
// caller-owned buffers: no threads, no spawn, no heap on the hot path,
// no timers — the run loop stays event-driven. Absent dylib (or any
// layout failure) reports fallback and the reader renders the source
// literally, byte-identical to the pre-math reader: no indicator, no nag.
//
// Host duties (ZaTeX docs/parity.md, docs/ir.md):
// - Glyph identity + advances come from the host font (system STIX Two
//   Math; all 14 FontIds resolve to it in v1 — uniform metrics, complete
//   math coverage, no bundled fonts).
// - Optional hooks: true glyph extents and ink bounds are supplied
//   (CoreText, v4 C surface) so box geometry — the sqrt junction
//   included — uses real outlines, and MATH-table italic corrections
//   are supplied so accents center on slanted nuclei; variants and
//   kerning corrections stay NULL (deterministic fallbacks — the core
//   is correct without them). Big-delimiter growth is the known v1
//   fidelity gap, documented in docs/spec.md.
// - The frozen C surface projects filled rects only: diagonal `cancel`
//   strikes never arrive (skipped engine-side, never misdrawn).
// - Wide-accent/brace stretch (issues #354/#361): the stride-negotiated
//   `zatex_layout_utf8_ex` entry is adopted when the dylib exports it
//   (28-byte stride admits x_scale); the old dylib keeps the frozen
//   20-byte v1 path, identity everywhere. Per-run color tails are read
//   but still render ambient (a future RUN_COLOR arm).
// - Rule thickness defaults to 40/1000 em for every kind (KaTeX default).

#include <dlfcn.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <CoreText/CoreText.h>
#include <CoreGraphics/CoreGraphics.h>

// ---------------------------------------------------------------------------
// C ABI mirror (must match zatex.h / cabi.zig; _Static_asserts below).
// ---------------------------------------------------------------------------

typedef struct {
    int32_t ha, db;
} ZatexExtents;

typedef struct {
    int32_t x0, y0, x1, y1;
} ZatexInkBox;

typedef struct {
    const void *ctx;
    uint16_t (*glyph_id)(const void *ctx, uint16_t font, uint32_t cp);
    int32_t (*advance)(const void *ctx, uint16_t font, uint16_t glyph);
    int32_t (*rule_thickness)(const void *ctx, uint16_t font, uint32_t kind);
    uint16_t (*glyph_variant)(const void *ctx, uint16_t font, uint16_t glyph, int32_t min_height);
    int32_t (*italic_correction)(const void *ctx, uint16_t font, uint16_t glyph);
    int32_t (*kern_correction)(const void *ctx, uint16_t font, uint16_t glyph, int32_t height, uint32_t corner);
    ZatexExtents (*extents)(const void *ctx, uint16_t font, uint16_t glyph);
    ZatexInkBox (*ink_bounds)(const void *ctx, uint16_t font, uint16_t glyph);
} ZatexMetrics;

typedef struct {
    uint16_t font_id;
    uint16_t size_units;
    int32_t x;
    int32_t baseline_y;
    uint32_t glyph_start;
    uint32_t glyph_count;
} ZatexRun;

// Stride-negotiated run (issues #354/#361): byte-identical to the
// upstream zatex_run_t (zatex.h). The frozen 20-byte v1 prefix above is
// what old dylibs stride; x_scale (bytes 20..22) stretches the run's
// ink AND intra-run pen advances by x_scale/1000 about the run origin
// (identity 1000); the pad at 22..24 is engine-untouched; color
// (bytes 24..28, 0xRRGGBBAA, 0 = ambient) is read but not yet consumed
// (ambient paint, exactly as before — a future RUN_COLOR arm).
typedef struct {
    uint16_t font_id;
    uint16_t size_units;
    int32_t x;
    int32_t baseline_y;
    uint32_t glyph_start;
    uint32_t glyph_count;
    uint16_t x_scale;
    uint16_t _pad;
    uint32_t color;
} ZatexRunX;

typedef struct {
    int32_t x, y;
    uint32_t w, h;
} ZatexRule;

typedef struct {
    uint32_t width, height_above, depth_below;
    uint32_t nruns, nrules;
    int32_t status;
    uint32_t err_offset;
    const char *err_msg;
    size_t err_msg_len;
} ZatexLayout;

_Static_assert(sizeof(ZatexRun) == 20, "ZatexRun must match zatex_run_v1_t");
_Static_assert(sizeof(ZatexRunX) == 28, "ZatexRunX must match zatex_run_t");
_Static_assert(__builtin_offsetof(ZatexRunX, x_scale) == 20, "x_scale at byte 20");
_Static_assert(__builtin_offsetof(ZatexRunX, color) == 24, "color at byte 24");
_Static_assert(sizeof(ZatexRule) == 16, "ZatexRule must match cabi.zig CRule");
_Static_assert(sizeof(ZatexLayout) == 48, "ZatexLayout must match cabi.zig CLayout");

#define ZATEX_RUNS_CAP 256
#define ZATEX_RULES_CAP 64
#define ZATEX_GLYPHS_CAP 4096
#define ZATEX_INPUT_CAP 65536

// Status contract for platform_math_size (mirrors the Zig seam):
// 0 = laid out, dims valid; 1 = engine unavailable (no dylib);
// 2 = fallback (bad input or engine refused it — render source literally).
enum { ZATEX_OK = 0, ZATEX_UNAVAILABLE = 1, ZATEX_FALLBACK = 2 };

// ---------------------------------------------------------------------------
// Engine loading (once per process, main thread only like all UI state).
// ---------------------------------------------------------------------------

typedef int32_t (*ZatexLayoutFn)(const char *, size_t, bool, const ZatexMetrics *,
                                 ZatexRun *, size_t, ZatexRule *, size_t,
                                 uint16_t *, size_t, ZatexLayout *);
// Stride-negotiated entry (issue #203): runs elements are runs_stride
// bytes wide; the engine writes the v1 prefix plus the x_scale/color
// tails the stride admits, leaving the rest untouched.
typedef int32_t (*ZatexLayoutExFn)(const char *, size_t, bool, const ZatexMetrics *,
                                   void *, size_t, size_t, ZatexRule *, size_t,
                                   uint16_t *, size_t, ZatexLayout *);
typedef uint32_t (*ZatexVersionFn)(void);
// Metrics conformance probe (upstream #194): diagnostics against the
// host provider at a font id; 0 is a clean pass.
typedef int32_t (*ZatexConformFn)(const ZatexMetrics *, uint16_t, char *, size_t);

static void *zatex_handle = NULL;
static ZatexLayoutFn zatex_layout = NULL;
static ZatexLayoutExFn zatex_layout_ex = NULL;
static ZatexVersionFn zatex_version_fn = NULL;
static ZatexConformFn zatex_conform_fn = NULL;
// Packed engine version (major << 16 | minor << 8 | patch); 0 is the
// unversioned era (installed and current-upstream dylibs alike predate
// the #259 versioned recipe), so 0 selects the v1 baseline, never a
// gate — symbol presence stays authoritative for _ex (issue #361).
static uint32_t zatex_engine_version = 0;
static int zatex_tried_load = 0;
static int zatex_missing_noticed = 0;

static void zatex_try_load(void) {
    if (zatex_tried_load) return;
    zatex_tried_load = 1;
    // Bundle Resources first (shipped app), then the documented install
    // path. Nothing else is probed: production surfaces a minimal
    // interface, never a search-path hunt.
    static const char *paths[] = {
        NULL, // filled below: bundle Resources/libzatex.dylib
        "/usr/local/lib/libzatex.dylib",
    };
    char bundle_path[1024];
    bundle_path[0] = '\0';
    CFBundleRef bundle = CFBundleGetMainBundle();
    if (bundle) {
        CFURLRef res = CFBundleCopyResourcesDirectoryURL(bundle);
        if (res) {
            CFStringRef p = CFURLCopyFileSystemPath(res, kCFURLPOSIXPathStyle);
            if (p) {
                if (CFStringGetCString(p, bundle_path, sizeof(bundle_path) - 32, kCFStringEncodingUTF8)) {
                    size_t n = strlen(bundle_path);
                    memcpy(bundle_path + n, "/libzatex.dylib", 17);
                }
                CFRelease(p);
            }
            CFRelease(res);
        }
    }
    for (int k = 0; k < 2; k++) {
        const char *path = (k == 0) ? bundle_path : paths[k];
        if (!path || !path[0]) continue;
        void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (!h) continue;
        ZatexLayoutFn fn = (ZatexLayoutFn)dlsym(h, "zatex_layout_utf8");
        if (!fn) {
            dlclose(h);
            continue;
        }
        zatex_handle = h;
        zatex_layout = fn;
        // Optional surface (issue #361): probed once, never required —
        // an old dylib simply lacks them and the v1 path below stays
        // bit-identical. The version is CHECKED (recorded for the
        // startup note and the test-hooks reader), not just probed.
        zatex_layout_ex = (ZatexLayoutExFn)dlsym(h, "zatex_layout_utf8_ex");
        zatex_version_fn = (ZatexVersionFn)dlsym(h, "zatex_version");
        zatex_conform_fn = (ZatexConformFn)dlsym(h, "zatex_conform_metrics");
        if (zatex_version_fn) zatex_engine_version = zatex_version_fn();
        return;
    }
}

// ---------------------------------------------------------------------------
// Metrics provider over system STIX Two Math (all FontIds, v1).
// ---------------------------------------------------------------------------

#define ZATEX_FONT_PX 100.0f

static CTFontRef zatex_font = NULL;

static void zatex_ensure_font(void) {
    if (zatex_font) return;
    zatex_font = CTFontCreateWithName(CFSTR("STIXTwoMath"), ZATEX_FONT_PX, NULL);
}

// One UTF-8 codepoint; invalid bytes yield U+FFFD (missing glyph downstream).
static uint32_t zatex_decode(const char *s, int left, int *used) {
    unsigned char c0 = (unsigned char)s[0];
    if (c0 < 0x80) {
        *used = 1;
        return c0;
    }
    if ((c0 & 0xE0) == 0xC0 && left >= 2) {
        unsigned char c1 = (unsigned char)s[1];
        if ((c1 & 0xC0) == 0x80) {
            *used = 2;
            uint32_t cp = ((uint32_t)(c0 & 0x1F) << 6) | (c1 & 0x3F);
            return cp >= 0x80 ? cp : 0xFFFD;
        }
    } else if ((c0 & 0xF0) == 0xE0 && left >= 3) {
        unsigned char c1 = (unsigned char)s[1], c2 = (unsigned char)s[2];
        if (((c1 & 0xC0) == 0x80) && ((c2 & 0xC0) == 0x80)) {
            *used = 3;
            uint32_t cp = ((uint32_t)(c0 & 0x0F) << 12) | ((uint32_t)(c1 & 0x3F) << 6) | (c2 & 0x3F);
            return (cp >= 0x800 && !(cp >= 0xD800 && cp <= 0xDFFF)) ? cp : 0xFFFD;
        }
    } else if ((c0 & 0xF8) == 0xF0 && left >= 4) {
        unsigned char c1 = (unsigned char)s[1], c2 = (unsigned char)s[2], c3 = (unsigned char)s[3];
        if (((c1 & 0xC0) == 0x80) && ((c2 & 0xC0) == 0x80) && ((c3 & 0xC0) == 0x80)) {
            *used = 4;
            uint32_t cp = ((uint32_t)(c0 & 0x07) << 18) | ((uint32_t)(c1 & 0x3F) << 12) |
                          ((uint32_t)(c2 & 0x3F) << 6) | (c3 & 0x3F);
            return (cp >= 0x10000 && cp <= 0x10FFFF) ? cp : 0xFFFD;
        }
    }
    *used = 1;
    return 0xFFFD;
}

// Glyph id in host namespace; 0 = missing (engine lays out with the
// advance for 0 anyway, so tofu on screen names its (font, cp) pair).
static uint16_t zatex_glyph_id(const void *ctx, uint16_t font, uint32_t cp) {
    (void)ctx;
    (void)font;
    zatex_ensure_font();
    // No null-font guard: layout_once gates every engine path on the font
    // (same accepted precondition as the ink hook below).
    UniChar ustr[2];
    UniChar *up = ustr;
    CFIndex ulen = 0;
    if (cp > 0x10FFFF) return 0;
    if (cp >= 0x10000) {
        cp -= 0x10000;
        ustr[0] = (UniChar)(0xD800 + (cp >> 10));
        ustr[1] = (UniChar)(0xDC00 + (cp & 0x3FF));
        ulen = 2;
    } else {
        ustr[0] = (UniChar)cp;
        ulen = 1;
    }
    CGGlyph g[2] = { 0, 0 };
    if (!CTFontGetGlyphsForCharacters(zatex_font, up, g, ulen)) return 0;
    return g[0];
}

// Advance in thousandths of an em (engine unit).
// CoreText reports no advance (rc 0) exactly for zero-width glyphs —
// full-font survey 2026-09-20 vs hmtx: 6760/6760 agree (6564 direct,
// 196 zero-width, including every combining accent) — so those report
// 0 like the file. Missing glyphs (id 0) keep the 500 fallback above.
static int32_t zatex_advance(const void *ctx, uint16_t font, uint16_t glyph) {
    (void)ctx;
    (void)font;
    zatex_ensure_font();
    if (glyph == 0) return 500;
    CGGlyph g = glyph;
    CGSize adv;
    if (CTFontGetAdvancesForGlyphs(zatex_font, kCTFontOrientationHorizontal, &g, &adv, 1) == 0) return 0;
    int32_t units = (int32_t)(adv.width / (double)ZATEX_FONT_PX * 1000.0 + 0.5);
    return units > 0 ? units : 500;
}

// v4 hooks over the same 100-unit font (×10 thousandths), mirroring
// zatex-png's cg_backend. One CoreText probe serves both: ink bounds
// are floored/ceiled to thousandths (y up, unclipped; blank glyphs
// report zeros), and extents derive from the same box — -floor(x) is
// ceil(-x), so the values match separate rounding exactly while the
// two hooks can never disagree. No ensure call: every engine path
// reaches these through the advance hook first (which ensures), and
// the null-font guard degrades gracefully regardless.
static ZatexInkBox zatex_ink_bounds(const void *ctx, uint16_t font, uint16_t glyph) {
    (void)ctx;
    (void)font;
    ZatexInkBox b = { 0, 0, 0, 0 };
    // No null-font guard: every engine path reaches hooks through the
    // advance hook (which ensures the font; layout aborts without one),
    // same accepted precondition as zatex_glyph_id. CGRect needs no
    // zero-init: CoreText fully writes it for any glyph value.
    CGGlyph g = (CGGlyph)glyph;
    CGRect r;
    CTFontGetBoundingRectsForGlyphs(zatex_font, kCTFontOrientationHorizontal, &g, &r, 1);
    b.x0 = (int32_t)floor((double)r.origin.x * 10.0);
    b.y0 = (int32_t)floor((double)r.origin.y * 10.0);
    b.x1 = (int32_t)ceil((double)(r.origin.x + r.size.width) * 10.0);
    b.y1 = (int32_t)ceil((double)(r.origin.y + r.size.height) * 10.0);
    return b;
}

static ZatexExtents zatex_extents(const void *ctx, uint16_t font, uint16_t glyph) {
    ZatexInkBox b = zatex_ink_bounds(ctx, font, glyph);
    ZatexExtents z = { 0, 0 };
    if (b.y1 > 0) z.ha = b.y1;
    if (b.y0 < 0) z.db = -b.y0;
    return z;
}

// MATH-table italic corrections (accent centering, issue #350 review).
// STIX Two Math ships UPM 1000, so raw values are already thousandths.
static CFDataRef zatex_math_data = NULL;
static const uint8_t *zatex_math_bytes = NULL;
static size_t zatex_math_len = 0;
static size_t zatex_math_ici = 0;
static int zatex_math_ready = 0;

static uint32_t zatex_u16(const uint8_t *p) {
    return (uint32_t)(((uint32_t)p[0] << 8) | p[1]);
}

static void zatex_ensure_math_table(void) {
    if (zatex_math_ready) return;
    zatex_math_ready = 1;
    zatex_ensure_font();
    if (!zatex_font) return;
    CFDataRef d = CTFontCopyTable(zatex_font, (CTFontTableTag)'MATH', 0);
    if (!d) return;
    size_t n = (size_t)CFDataGetLength(d);
    const uint8_t *b = CFDataGetBytePtr(d);
    size_t gi = 0, ic_rel = 0, sub = 0;
    if (!b || n < 10) goto fail;
    gi = ((size_t)b[6] << 8) | b[7];
    if (gi == 0 || gi + 8 > n) goto fail;
    ic_rel = ((size_t)b[gi] << 8) | b[gi + 1];
    if (ic_rel == 0) goto fail;
    sub = gi + ic_rel;
    if (sub + 4 > n) goto fail;
    zatex_math_data = d;
    zatex_math_bytes = b;
    zatex_math_len = n;
    zatex_math_ici = sub;
    return;
fail:
    CFRelease(d);
}

static int32_t zatex_italic_correction(const void *ctx, uint16_t font, uint16_t glyph) {
    (void)ctx;
    (void)font;
    if (glyph == 0) return 0;
    zatex_ensure_math_table();
    if (!zatex_math_bytes) return 0;
    const uint8_t *b = zatex_math_bytes;
    size_t n = zatex_math_len, sub = zatex_math_ici;
    size_t cov = sub + zatex_u16(b + sub);
    size_t count = zatex_u16(b + sub + 2);
    if (cov + 4 > n) return 0;
    uint32_t fmt = zatex_u16(b + cov);
    uint32_t nn = zatex_u16(b + cov + 2);
    // Format 1 stores bare glyphs (stride 2, identity values); format 2
    // stores first/last/value triples (stride 6). One scan serves both.
    uint32_t stride = fmt == 1 ? 2 : fmt == 2 ? 6 : 0;
    if (stride == 0 || cov + 4 + (size_t)nn * stride > n) return 0;
    uint32_t idx = UINT32_MAX;
    for (uint32_t i = 0; i < nn; i++) {
        const uint8_t *r = b + cov + 4 + (size_t)i * stride;
        uint32_t first = zatex_u16(r);
        uint32_t last = stride == 2 ? first : zatex_u16(r + 2);
        if (glyph >= first && glyph <= last) {
            idx = (stride == 2 ? i : zatex_u16(r + 4)) + (glyph - first);
            break;
        }
    }
    if (idx == UINT32_MAX || idx >= count) return 0;
    size_t rec = sub + 4 + (size_t)idx * 4;
    if (rec + 2 > n) return 0;
    return (int32_t)(int16_t)zatex_u16(b + rec);
}

// Rule thickness in thousandths of an em: KaTeX parity 40 for every
// kind (engine RuleKind order is fraction, radical, overline,
// underline — note it differs from the MATH table order).
// Deliberately NOT the STIX file truth (68 for all four): the engine
// pins KaTeX-numeric 0.04em parity for rule weights, and 68 draws a
// 2-device-px vinculum at body size where 40 snaps to one crisp row
// (measured on screenshots/math_gallery.png). File truth would also
// widen every clearance the engine derives from the weight. Explicit
// rather than NULL so the choice survives engine default changes.
static int32_t zatex_rule_thickness(const void *ctx, uint16_t font, uint32_t kind) {
    (void)ctx;
    (void)font;
    (void)kind;
    return 40;
}

static const ZatexMetrics zatex_metrics = {
    NULL, zatex_glyph_id, zatex_advance, zatex_rule_thickness, NULL, zatex_italic_correction, NULL,
    // ink_bounds wired (issue #350 review, round 2): the engine centers
    // zero-advance combining marks by ink, not advance (U+20D7 ink hangs
    // left of its origin), and lifts low accents off the nucleus by ink
    // clearance — without it accents sit off-center. Same probe, same
    // thousandths; blank glyphs report zeros and degrade gracefully.
    zatex_extents, zatex_ink_bounds,
};

// ---------------------------------------------------------------------------
// Layout buffers (BSS; main thread only; re-laid-out per call —
// microsecond-grade, so no cache: size and draw always agree).
// ---------------------------------------------------------------------------

static ZatexRun zatex_runs[ZATEX_RUNS_CAP];
static ZatexRule zatex_rules[ZATEX_RULES_CAP];
static uint16_t zatex_glyphs[ZATEX_GLYPHS_CAP];
// _ex scratch (issue #354): 28-byte slots the negotiated entry strides.
// Downstream keeps reading zatex_runs (the normalized v1 prefix); the
// tails land in zatex_xscale below, 1000 on the v1 path.
static ZatexRunX zatex_runs_x[ZATEX_RUNS_CAP];
static uint16_t zatex_xscale[ZATEX_RUNS_CAP];
// Startup conformance (issue #361): once per process on the first live
// layout (the earliest point the STIX provider exists); skipped when
// the dylib predates the probe.
static int zatex_conform_tried = 0;
#ifdef TEST_HOOKS
static uint32_t zatex_conform_ran = 0;
static int32_t zatex_conform_count = 0;
#endif
// Draw scratch (BSS; main thread only): shared by the direct run loop and
// the atlas rasterizer below — one owner, sequential use, no nesting.
static CGPoint zatex_pos[4096];
static CGGlyph zatex_gbuf[4096];

// ---------------------------------------------------------------------------
// Formula atlas (issue #355): Retina pre-raster for math runs, mirroring
// platform_draw_text. Body text blits pre-rasterized 2x atlas slices at
// snapped origins; math drew direct via CTFontDrawGlyphs every frame (a
// full vector re-raster per frame while scrolling). Now each unique
// formula — TeX bytes + font size + display mode (masks rasterize at one
// exact size; display lays out differently from the same inline bytes) —
// rasterizes ONCE into the shared 2x coverage atlas and blits thereafter:
// steady-state draws are one ClipToMask + FillRect with no shaping, no
// copy, no allocation. Rules stay direct fills (already device-snapped);
// intra-run advances stay exact (never rounded — the known non-fix in
// #355); only the blit origin snaps, exactly like the body blit.
// ---------------------------------------------------------------------------

#define ZATEX_ATLAS_CAP 64
// Cacheable TeX length: the key hashes every byte per draw, so pathological
// inputs skip the cache and draw direct (mirrors the body >510B
// uncacheable path at formula granularity).
#define ZATEX_ATLAS_TEX_CAP 4096

typedef struct {
    uint64_t key; // FNV-1a(tex bytes, font bits, display); cf. mathRunKey
    uint64_t gen; // g_atlas_flushes at rasterize; mismatch = stale
    CGImageRef slice; // retained no-copy view into g_atlas_img, NULL = cold
    int len; // > 0 once inserted (cold slots are BSS-zero: no occupied flag)
    char head[8]; // first bytes (cheap collision guard, like ShapedEntry)
    short ax, ay, aw, ah; // atlas UV rect in device px
} ZatexAtlasEntry;

static ZatexAtlasEntry zatex_atlas[ZATEX_ATLAS_CAP]; // BSS: no binary cost

// Key byte order mirrors mathRunKey in glyph_cache.zig (pinned there in
// cross-platform tests): tex bytes, then font-bits LE, then display byte.
static uint64_t zatex_atlas_key(const char *tex, int len, float font_px, int display) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (int i = 0; i < len; i++) {
        h ^= (unsigned char)tex[i];
        h *= 0x100000001b3ULL;
    }
    uint32_t fb = 0;
    memcpy(&fb, &font_px, 4);
    for (int i = 0; i < 4; i++) {
        h ^= (uint8_t)(fb >> (i * 8));
        h *= 0x100000001b3ULL;
    }
    h ^= display ? (uint64_t)1 : (uint64_t)0;
    h *= 0x100000001b3ULL;
    return h;
}

// Generational flush hook, called from atlas_flush in macos.m (forward
// declared there): shape-cache evictions must never leave stale math
// slices viewing zeroed atlas pixels. Entries keep key identity and
// re-rasterize lazily via the gen mismatch.
void zatex_drop_math_rasters(void) {
    for (int i = 0; i < ZATEX_ATLAS_CAP; i++) {
        if (zatex_atlas[i].slice) {
            CGImageRelease(zatex_atlas[i].slice);
            zatex_atlas[i].slice = NULL;
        }
    }
}

// One retained slice blit at the snapped formula origin. Dest size is the
// mask size exactly (never the laid-out advance — no sub-pixel stretch),
// mirroring the body blit in platform_draw_text.
static void zatex_blit_cached(CGContextRef ctx, ZatexAtlasEntry *e, float x, float y_top,
                              double fr, double fg, double fb, double fa) {
    float q = g_output_scale;
    CGRect dest = CGRectMake(roundf(x * q) / q, roundf(y_top * q) / q,
                             (float)e->aw / (float)RASTER_SCALE, (float)e->ah / (float)RASTER_SCALE);
    CGContextSaveGState(ctx);
    // Bilinear, not None like the body blit: the headless harness bitmap
    // is 1x, so forced-2x masks downsample there — nearest mangles thin
    // STIX stems in that configuration (measured 143.8 vs 189.5 bilinear
    // on the same masks) while bilinear reads true mask quality. On live
    // Retina the blit is snapped 1:1, where no resampling happens either
    // way, so this changes no ship pixel — and the shared crisp budget in
    // the #355 test pins the choice (None fails it, Default clears it).
    CGContextSetInterpolationQuality(ctx, kCGInterpolationDefault);
    CGContextClipToMask(ctx, dest, e->slice);
    CGContextSetRGBFillColor(ctx, fr, fg, fb, fa);
    CGContextFillRect(ctx, dest);
    CGContextRestoreGState(ctx);
}

// Rasterize a laid-out formula into the shared 2x coverage atlas (white
// ink, like shape_rasterize_entry) and cut the entry's slice. Mirrored
// storage: the atlas ctx is y-down, so glyphs rasterize unflipped at
// absolute device coords and the ClipToMask blit in the flipped view maps
// them upright — the same trick as the body path. Returns 1 with a live
// slice, 0 to draw direct.
static int zatex_rasterize(ZatexAtlasEntry *e, const ZatexLayout *lo, double s, float font_px) {
    int pw = (int)ceil((double)lo->width * s * RASTER_SCALE);
    int ph = (int)ceil(((double)lo->height_above + (double)lo->depth_below) * s * RASTER_SCALE);
    // Larger than the atlas: draw direct every frame — a flush could never
    // fit it, and retrying would evict the body working set per frame.
    if (pw <= 0 || ph <= 0 || pw > ATLAS_PX || ph > ATLAS_PX) return 0;
    atlas_ensure();
    if (!g_atlas_ctx) return 0;
    short ax = 0, ay = 0;
    if (!atlas_alloc(pw, ph, &ax, &ay)) {
        atlas_flush(); // drops our slices too via zatex_drop_math_rasters
        if (!atlas_alloc(pw, ph, &ax, &ay)) return 0;
    }
    // White ink in the atlas's native gray space.
    CGContextSetGrayFillColor(g_atlas_ctx, 1.0, 1.0);
    for (uint32_t i = 0; i < lo->nruns; i++) {
        ZatexRun *rn = &zatex_runs[i];
        if (rn->glyph_count == 0 || rn->glyph_start + rn->glyph_count > ZATEX_GLYPHS_CAP) continue;
        double run_px = (double)font_px * (double)rn->size_units / 1000.0;
        if (run_px <= 0) continue;
        CTFontRef rf = CTFontCreateCopyWithAttributes(zatex_font, (CGFloat)(run_px * RASTER_SCALE), NULL, NULL);
        if (!rf) continue;
        double s_run = run_px / 1000.0;
        // Snap the raster origin to integer device px, mirroring the
        // screen snap and the body rasterizer (a fractional baseline
        // bakes straddled coverage edges into the mask — soft on every
        // blit thereafter). Intra-run advances stay exact; only the
        // origin quantizes, at most half a device px per run.
        double bx = floor((double)ax + (double)rn->x * s * RASTER_SCALE + 0.5);
        double by = floor((double)ay + (double)rn->baseline_y * s * RASTER_SCALE + 0.5);
        // CTFontDrawGlyphs consults and advances the context text position,
        // so drawing runs flat in one frame drifts every run right by the
        // pen left over from previous draws — resetting it per run pins
        // every run at its absolute device coords (same user-space points
        // the direct path's per-run Translate frame produces, without the
        // flip: the atlas ctx is y-down, so unflipped draws store mirrored
        // and the ClipToMask blit maps them upright, the same trick as
        // shape_rasterize_entry).
        CGContextSetTextPosition(g_atlas_ctx, 0, 0);
        // Stretched runs (issue #354): zatex.h recipe — ink AND pen
        // scale about the run origin (translate to bx, scale x), so
        // positions below go relative. Identity keeps base == bx, the
        // exact expression above (old dylib: always).
        int stretch = zatex_xscale[i] != 1000;
        double base = bx;
        if (stretch) {
            CGContextSaveGState(g_atlas_ctx);
            CGContextTranslateCTM(g_atlas_ctx, (CGFloat)bx, 0);
            CGContextScaleCTM(g_atlas_ctx, (CGFloat)((double)zatex_xscale[i] / 1000.0), 1.0);
            base = 0.0;
        }
        uint32_t n = rn->glyph_count;
        int64_t acc = 0;
        for (uint32_t k = 0; k < n; k++) {
            uint16_t gl = zatex_glyphs[rn->glyph_start + k];
            zatex_gbuf[k] = (CGGlyph)gl;
            zatex_pos[k] = CGPointMake((float)(base + acc * s_run * RASTER_SCALE), (float)by);
            acc += zatex_advance(NULL, rn->font_id, gl);
        }
        CTFontDrawGlyphs(rf, zatex_gbuf, zatex_pos, (CFIndex)n, g_atlas_ctx);
        if (stretch) CGContextRestoreGState(g_atlas_ctx);
        CFRelease(rf);
    }
    e->ax = ax;
    e->ay = ay;
    e->aw = (short)pw;
    e->ah = (short)ph;
    e->gen = g_atlas_flushes;
    e->slice = g_atlas_img ? CGImageCreateWithImageInRect(g_atlas_img, CGRectMake(ax, ay, pw, ph)) : NULL;
    return e->slice != NULL;
}

static int zatex_layout_once(const char *tex, int tex_len, int display, ZatexLayout *out) {
    if (!tex || tex_len <= 0 || tex_len > ZATEX_INPUT_CAP) return ZATEX_FALLBACK;
    zatex_try_load();
    zatex_ensure_font();
    if (!zatex_layout || !zatex_font) return ZATEX_UNAVAILABLE;
    // Startup conformance (issue #361): first live layout is the
    // earliest point the STIX provider exists; cold path only, skipped
    // when the dylib predates the probe (installed dylib: silent no-op).
    if (!zatex_conform_tried) {
        zatex_conform_tried = 1;
        if (zatex_conform_fn) {
            char diag[256];
            diag[0] = '\0';
            int32_t n = zatex_conform_fn(&zatex_metrics, 0, diag, sizeof(diag));
#ifdef TEST_HOOKS
            zatex_conform_ran = 1;
            zatex_conform_count = n;
#endif
            if (n != 0) fprintf(stderr, "read: STIX metrics conform: %d\n%.255s\n", n, diag);
        }
    }
    int32_t rc;
    if (zatex_layout_ex) {
        // Negotiated path (issue #354): 28-byte stride admits x_scale
        // (and color, unread). Normalized below so downstream keeps one
        // view; a 0 tail reads as identity (defensive, never emitted).
        rc = zatex_layout_ex(tex, (size_t)tex_len, display ? true : false, &zatex_metrics,
                             zatex_runs_x, ZATEX_RUNS_CAP, sizeof(ZatexRunX),
                             zatex_rules, ZATEX_RULES_CAP,
                             zatex_glyphs, ZATEX_GLYPHS_CAP, out);
        if (rc == 0) {
            uint32_t n = out->nruns < ZATEX_RUNS_CAP ? out->nruns : ZATEX_RUNS_CAP;
            for (uint32_t i = 0; i < n; i++) {
                memcpy(&zatex_runs[i], &zatex_runs_x[i], sizeof(ZatexRun));
                uint16_t xs = zatex_runs_x[i].x_scale;
                zatex_xscale[i] = xs ? xs : 1000;
            }
        }
    } else {
        // Frozen v1 path: old dylib strides 20 and never writes tails —
        // identity everywhere, bit-identical to before (issue #354
        // acceptance on the installed dylib).
        rc = zatex_layout(tex, (size_t)tex_len, display ? true : false, &zatex_metrics,
                          zatex_runs, ZATEX_RUNS_CAP, zatex_rules, ZATEX_RULES_CAP,
                          zatex_glyphs, ZATEX_GLYPHS_CAP, out);
        if (rc == 0) {
            uint32_t n = out->nruns < ZATEX_RUNS_CAP ? out->nruns : ZATEX_RUNS_CAP;
            for (uint32_t i = 0; i < n; i++) zatex_xscale[i] = 1000;
        }
    }
    return rc == 0 ? ZATEX_OK : ZATEX_FALLBACK;
}

// Formula-raster counters (issue #355): hits are textured-quad blits with
// zero shaping, misses are layout + 2x rasterize. BSS storage (no binary
// cost); the reader is TEST_HOOKS-only, same gate as
// platform_glyph_cache_stats in macos.m.
static uint64_t zatex_atlas_hits = 0, zatex_atlas_misses = 0;
#ifdef TEST_HOOKS
void platform_math_atlas_stats(uint64_t *hits, uint64_t *misses) {
    if (hits) *hits = zatex_atlas_hits;
    if (misses) *misses = zatex_atlas_misses;
}
// Engine negotiation state (issues #354/#361): packed version from
// zatex_version() (0 = unversioned era), whether the stride-negotiated
// _ex entry was adopted, and the startup conformance outcome.
void platform_math_engine_info(uint32_t *version, uint32_t *use_ex,
                               uint32_t *conform_ran, int32_t *conform_n) {
    if (version) *version = zatex_engine_version;
    if (use_ex) *use_ex = zatex_layout_ex ? 1 : 0;
    if (conform_ran) *conform_ran = zatex_conform_ran;
    if (conform_n) *conform_n = zatex_conform_count;
}
#endif

// Synchronous size query for the Zig box path (mirrors image_size_fn):
// dims are px at font_px (units are thousandths of an em).
int platform_math_size(const char *tex, int tex_len, int display, float font_px,
                       float *out_w, float *out_above, float *out_below) {
    float w = 0, above = 0, below = 0;
    int st = ZATEX_FALLBACK;
    if (tex && tex_len > 0 && font_px > 0) {
        ZatexLayout lo;
        st = zatex_layout_once(tex, tex_len, display, &lo);
        if (st == ZATEX_UNAVAILABLE && !zatex_missing_noticed) {
            zatex_missing_noticed = 1;
            fprintf(stderr, "read: libzatex.dylib unavailable — math renders as source text\n");
        }
        if (st == ZATEX_OK) {
            double s = (double)font_px / 1000.0;
            w = (float)(lo.width * s);
            above = (float)(lo.height_above * s);
            below = (float)(lo.depth_below * s);
        }
    }
    if (out_w) *out_w = w;
    if (out_above) *out_above = above;
    if (out_below) *out_below = below;
    return st;
}

// Draw a laid-out formula: runs through CTFont glyph drawing at the
// text baseline, rules as filled rects. y_top is the formula ink top;
// the Zig box path derives it from the same dims above.
void platform_draw_math(const char *tex, int tex_len, int display, float font_px,
                        float x, float y_top,
                        unsigned char r, unsigned char g, unsigned char b, unsigned char a) {
    extern CGContextRef g_current_cg_context;
    if (!g_current_cg_context || !tex || tex_len <= 0 || font_px <= 0) return;
    ZatexLayout lo;
    if (zatex_layout_once(tex, tex_len, display, &lo) != ZATEX_OK) return;
    CGContextRef ctx = g_current_cg_context;
    double s = (double)font_px / 1000.0;
    // Normalized once here and shared with the atlas blit below, so the
    // blit reuses these exact doubles instead of re-dividing in float.
    double fr = r / 255.0, fg = g / 255.0, fb = b / 255.0, fa = a / 255.0;
    CGContextSetRGBFillColor(ctx, fr, fg, fb, fa);
    // Rules first (under ink, like fraction bars behind nothing — order
    // is irrelevant for disjoint rects; one fill color for all).
    for (uint32_t i = 0; i < lo.nrules; i++) {
        ZatexRule *rl = &zatex_rules[i];
        CGRect rr = CGRectMake((float)(x + rl->x * s), (float)(y_top + rl->y * s),
                               (float)(rl->w * s), (float)(rl->h * s));
        // All engine rules are horizontal bars (fraction, vinculum,
        // over/underline): snap y to device pixels so subpixel bars
        // draw crisp instead of fringing across two rows. x/width stay
        // exact (centering must not shift). Round, never cover: a
        // sub-pixel KaTeX weight (0.68px at body) must rasterize one
        // row, not inflate to two; the 1px floor keeps hairlines from
        // vanishing at small sizes. Position stays within half a pixel
        // of layout, so bar-to-ink junctions still meet.
        double y0 = floor(rr.origin.y + 0.5);
        double y1 = floor(rr.origin.y + rr.size.height + 0.5);
        if (y1 <= y0) y1 = y0 + 1.0;
        rr.origin.y = y0;
        rr.size.height = y1 - y0;
        CGContextFillRect(ctx, rr);
    }
    // Runs: one flipped frame per run, mirroring platform_draw_text
    // (Translate to the run baseline origin, Scale(1,-1), draw at
    // relative offsets). Each run draws at its own size (script sizes
    // ride size_units, per-mille of ambient) via an exact-size font
    // copy — drawing with the shared 100-unit font would scale ink by
    // 100/font_px. Offsets accumulate the SAME integer advances the
    // engine laid out with (units, exact), converted once to px, so ink
    // lands exactly where layout put it.
    // Formula atlas (issue #355): on 2x destinations a cached raster
    // blits 1:1 at the snapped formula origin; everywhere else (1x, or
    // uncacheable input) the legacy direct path below draws — the same
    // scale policy as platform_draw_text, so 1x screenshots never
    // downsample 2x art.
    if (g_output_scale > 1.5f && tex_len <= ZATEX_ATLAS_TEX_CAP) {
        uint64_t key = zatex_atlas_key(tex, tex_len, font_px, display);
        ZatexAtlasEntry *e = &zatex_atlas[key % ZATEX_ATLAS_CAP];
        int hl = tex_len < 8 ? tex_len : 8;
        if (e->slice && e->gen == g_atlas_flushes &&
            e->key == key && e->len == tex_len &&
            memcmp(e->head, tex, (size_t)hl) == 0) {
            zatex_blit_cached(ctx, e, x, y_top, fr, fg, fb, fa);
            zatex_atlas_hits++;
            return;
        }
        // Miss: evict the collision (if any) and take the slot. The rect
        // and slice arrive in zatex_rasterize; a failed rasterize leaves
        // the slot cold (NULL slice) and draws direct below.
        if (e->slice) {
            CGImageRelease(e->slice);
            e->slice = NULL;
        }
        e->key = key;
        e->len = tex_len;
        memcpy(e->head, tex, (size_t)hl);
        if (zatex_rasterize(e, &lo, s, font_px)) {
            zatex_blit_cached(ctx, e, x, y_top, fr, fg, fb, fa);
            zatex_atlas_misses++;
            return;
        }
    }
    for (uint32_t i = 0; i < lo.nruns; i++) {
        ZatexRun *rn = &zatex_runs[i];
        if (rn->glyph_count == 0 || rn->glyph_start + rn->glyph_count > ZATEX_GLYPHS_CAP) continue;
        double run_px = (double)font_px * (double)rn->size_units / 1000.0;
        if (run_px <= 0) continue;
        CTFontRef rf = CTFontCreateCopyWithAttributes(zatex_font, (CGFloat)run_px, NULL, NULL);
        if (!rf) continue;
        double s_run = run_px / 1000.0;
        CGContextSaveGState(ctx);
        // Snap the run origin to the device grid, mirroring
        // platform_draw_text: a fractional origin resamples every glyph
        // mask (soft edges); a snapped origin rasterizes 1:1 (crisp).
        // Intra-run pen advances stay exact, so spacing never drifts;
        // only the origin quantizes (at most half a device px per run).
        // g_output_scale is always positive (clamped >= 1 at every setter),
        // so the snap below never divides by zero.
        double q = (double)g_output_scale;
        double ox = floor((x + rn->x * s) * q + 0.5) / q;
        double oy = floor((y_top + rn->baseline_y * s) * q + 0.5) / q;
        CGContextTranslateCTM(ctx, (CGFloat)ox, (CGFloat)oy);
        // Stretched runs (issue #354): zatex.h recipe — scale x about
        // the run origin so ink AND pen stretch (positions below stay
        // relative). Identity is the exact call as before (old dylib:
        // always), keeping the fast path untouched.
        if (zatex_xscale[i] != 1000)
            CGContextScaleCTM(ctx, (CGFloat)((double)zatex_xscale[i] / 1000.0), -1.0);
        else
            CGContextScaleCTM(ctx, 1.0, -1.0);
        CGContextSetTextPosition(ctx, 0, 0);
        uint32_t n = rn->glyph_count;
        int64_t acc = 0;
        for (uint32_t k = 0; k < n; k++) {
            uint16_t g = zatex_glyphs[rn->glyph_start + k];
            zatex_gbuf[k] = (CGGlyph)g;
            zatex_pos[k] = CGPointMake((float)(acc * s_run), 0);
            acc += zatex_advance(NULL, rn->font_id, g);
        }
        CTFontDrawGlyphs(rf, zatex_gbuf, zatex_pos, (CFIndex)n, ctx);
        CGContextRestoreGState(ctx);
        CFRelease(rf);
    }
}

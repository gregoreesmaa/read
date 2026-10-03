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
// - Normalization owner (issue #374, host-owns per upstream #265 /
//   docs/unicode.md: the engine performs none, NFC and NFD lay out
//   differently). Normalized once per layout call at this boundary:
//   ASCII inputs skip zero-copy (already NFC); non-ASCII takes one
//   NSString NFC pass over BSS scratch. No 100KB tables in-ship.
// - Optional hooks: true glyph extents and ink bounds are supplied
//   (CoreText, v4 C surface) so box geometry — the sqrt junction
//   included — uses real outlines, and MATH-table italic corrections
//   are supplied so accents center on slanted nuclei; variants and
//   kerning corrections stay NULL (deterministic fallbacks — the core
//   is correct without them). Big-delimiter growth is the known v1
//   fidelity gap, documented in docs/spec.md.
// - The frozen C surface projects filled rects only: diagonal `cancel`
//   strikes never arrive (skipped engine-side, never misdrawn).
// - Wide-accent/brace stretch (issues #354/#361/#364): the
//   stride-negotiated `zatex_layout_utf8_ex` entry is adopted per the
//   zatex_capabilities() word when the dylib offers it (X_SCALE bit),
//   per-symbol presence on older dylibs; the old dylib keeps the frozen
//   20-byte v1 path, identity scale and ambient paint. Per-run color
//   tails (issue #365, zatex#251) paint per run, 0 = ambient; any
//   painted run takes the whole formula direct (one white atlas raster
//   cannot tint two paints).
// - Rule thickness defaults to 40/1000 em for every kind (KaTeX default).
// - Typed failures (issues #366/#377): the engine refines nonzero
//   statuses with err_code/err_offset (zatex#273) and space failures
//   with exact needs (zatex#263). The bridge reports 0 ok, 1 engine
//   unavailable, 2 fallback (bad input — render source literally, error
//   byte marked via the latch below), 3 overflow (needs exceed the
//   engine ceilings — growing cannot help, diagnostic on stderr), 4
//   unsupported (engine lacks the command). Retry note: our buffers ARE
//   the engine ceilings (256 runs / 64 rules; glyphs 4096 over the
//   engine's 2048 temp), so nonzero needs within our caps are
//   unreachable on a conforming engine — 6/7 always arrive zeroed (over
//   capacity) and correctly take the overflow arm, never a blind retry.

#include <dlfcn.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h> // write(2) diagnostics (no fprintf/stdio, issue #391)
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

// Stride-negotiated run (issues #354/#361, #365): byte-identical to the
// upstream zatex_run_t (zatex.h). The frozen 20-byte v1 prefix above is
// what old dylibs stride; x_scale (bytes 20..22) stretches the run's
// ink AND intra-run pen advances by x_scale/1000 about the run origin
// (identity 1000); the pad at 22..24 is engine-untouched; color
// (bytes 24..28, 0xRRGGBBAA, 0 = ambient) paints per run, normalizing
// into zatex_colors/uniform below.
//
// Size negotiation (issue #375, upstream #271 decided): the stride
// parameter IS the negotiation — a first-field size cannot stride an
// array, so the run struct carries no size field of its own (upstream
// contract). min(host,engine) sizing: the host slots are CUR bytes;
// the engine admits tails per the caps word (or per-symbol presence on
// old dylibs); zatex_negotiated_ex precomputes the smaller side below.
#define ZATEX_RUN_SIZE_V1 20
#define ZATEX_RUN_SIZE_CUR 28
typedef struct {
    uint16_t font_id;
    uint16_t size_units;
    int32_t x;
    int32_t baseline_y;
    uint32_t glyph_start;
    uint32_t glyph_count;
    // Stretch factor (issue #376, upstream #272 decided): u16 per-mille
    // kept — float would only re-encode the truncated ratio with binary
    // error while the core stays integer-only. Identity 1000; the two
    // (double)xs/1000.0 conversions below are the single conversion
    // points a future float shape changes (inputs pre-normalized: the
    // layout_once loop maps a 0 tail to 1000).
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
    int32_t err_code;
} ZatexLayout;

_Static_assert(sizeof(ZatexRun) == ZATEX_RUN_SIZE_V1, "ZatexRun must match zatex_run_v1_t");
_Static_assert(sizeof(ZatexRunX) == ZATEX_RUN_SIZE_CUR, "ZatexRunX must match zatex_run_t");
_Static_assert(__builtin_offsetof(ZatexRunX, x_scale) == 20, "x_scale at byte 20");
_Static_assert(__builtin_offsetof(ZatexRunX, color) == 24, "color at byte 24");
_Static_assert(sizeof(ZatexRule) == 16, "ZatexRule must match cabi.zig CRule");
_Static_assert(sizeof(ZatexLayout) == 56, "ZatexLayout must match cabi.zig CLayout");
_Static_assert(__builtin_offsetof(ZatexLayout, err_code) == 48, "err_code appended, old readers ignore the tail");

#define ZATEX_RUNS_CAP 256
#define ZATEX_RULES_CAP 64
#define ZATEX_GLYPHS_CAP 4096
// Input ceiling (issue #388: was 65536 — a full 64 KiB BSS scratch for one
// NFC pass; 4096 covers every formula layout pass below, which strides
// runs/glyphs at the same bound, and longer inputs already fall back).
#define ZATEX_INPUT_CAP 4096

// Status contract for platform_math_size (mirrors the Zig seam):
// 0 = laid out, dims valid; 1 = engine unavailable (no dylib);
// 2 = fallback (bad input — render source literally, error byte marked);
// 3 = overflow (space/limit past the ceilings — literally, + diagnostic);
// 4 = unsupported (engine lacks the command — render source literally).
enum { ZATEX_OK = 0, ZATEX_UNAVAILABLE = 1, ZATEX_FALLBACK = 2, ZATEX_OVERFLOW = 3, ZATEX_UNSUPPORTED = 4 };

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
// DIET: the version and conformance-probe typedefs retired with their
// call sites (zatex_version / zatex_conform_metrics no longer resolved).
// Capability word (upstream #262, issue #364): negotiated once via
// zatex_capabilities(); absent on unversioned-era dylibs (v1 fallback).
typedef uint32_t (*ZatexCapsFn)(void);
#define ZATEX_CAP_X_SCALE (1u << 0)
#define ZATEX_CAP_RUN_COLOR (1u << 1)
#define ZATEX_CAP_NEED_COUNTS (1u << 2)
#define ZATEX_CAP_ERR_CODE (1u << 3)

static void *zatex_handle = NULL;
static ZatexLayoutFn zatex_layout = NULL;
static ZatexLayoutExFn zatex_layout_ex = NULL;
// DIET: version query retired (see ZATEX_ADOPT); no version static remains.

// Negotiated caps (issue #364): valid only when zatex_has_caps (the
// dylib exports zatex_capabilities); otherwise the v1 baseline below,
// never a gate — per-symbol presence stays authoritative (issue #361).
static uint32_t zatex_engine_caps = 0;
static int zatex_has_caps = 0;
// Precomputed _ex adoption (issue #364): the caps word is authoritative
// when offered, per-symbol presence otherwise — use sites read one int
// instead of re-branching.
static int zatex_negotiated_ex = 0;
// DIET: version reporting retired — engine_info reports 0 permanently
// (every shippable dylib to date cuts 0.0.0; the use_ex/caps tripwires
// still detect engine upgrades).
static int zatex_tried_load = 0;
static int zatex_missing_noticed = 0;

// Wire one opened handle: the required v1 entry plus the optional
// surface (issues #361/#364). Macro so the ship loop and the TEST_HOOKS
// double path below share it with zero call overhead: caps are
// negotiated once here and precomputed into zatex_negotiated_ex; old
// dylibs simply lack the symbols and the v1 path stays bit-identical.
#define ZATEX_ADOPT(h, ok) do { \
    ZatexLayoutFn fn = (ZatexLayoutFn)dlsym(h, "zatex_layout_utf8"); \
    ok = (fn != NULL); \
    if (ok) { \
        zatex_handle = h; \
        zatex_layout = fn; \
        zatex_layout_ex = (ZatexLayoutExFn)dlsym(h, "zatex_layout_utf8_ex"); \
        ZatexCapsFn cf = (ZatexCapsFn)dlsym(h, "zatex_capabilities"); \
        zatex_engine_caps = 0; \
        zatex_has_caps = 0; \
        if (cf) { \
            zatex_engine_caps = cf(); \
            zatex_has_caps = 1; \
        } \
        zatex_negotiated_ex = zatex_layout_ex != NULL && \
            (!zatex_has_caps || (zatex_engine_caps & ZATEX_CAP_X_SCALE) != 0); \
    } \
} while (0)

static void zatex_try_load(void) {
    if (zatex_tried_load) return;
    zatex_tried_load = 1;
#ifdef TEST_HOOKS
    // Scripted double (issue #378): CI points ZATEX_TEST_DYLIB at the
    // libzatex_test build to exercise OK + no_space + bad-input paths
    // deterministically. Compile-time gate: ship never sees this.
    const char *td = getenv("ZATEX_TEST_DYLIB");
    if (td && td[0]) {
        void *th = dlopen(td, RTLD_NOW | RTLD_LOCAL);
        if (th) {
            int tok = 0;
            ZATEX_ADOPT(th, tok);
            if (!tok) dlclose(th);
            else return;
        }
    }
#endif
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
        int ok = 0;
        ZATEX_ADOPT(h, ok);
        if (!ok) {
            dlclose(h);
            continue;
        }
        return;
    }
}

// ---------------------------------------------------------------------------
// Metrics provider over system STIX Two Math (all FontIds, v1).
//
// Blessed-provider evaluation (issue #380, upstream #256 shipped but
// unadopted on purpose): the blessed C provider links the engine core
// (link EITHER the bridge OR libzatex.a, never both) and answers from
// vendored font file bytes, while this host stays dlopen-only with zero
// linked dependencies (size budget, AGENTS.md §1) over the system face.
// Adopting it would link the engine and re-face every formula, so no
// part is fully superseded and nothing is retired: the hand-rolled MATH
// parsing stays, and the startup conformance probe above is the parity
// evidence against blessed expectations (clean pass required). The seam
// a future provider would fill is this ZatexMetrics table itself.
// ---------------------------------------------------------------------------

#define ZATEX_FONT_PX 100.0f

static CTFontRef zatex_font = NULL;

static void zatex_ensure_font(void) {
    if (zatex_font) return;
    zatex_font = CTFontCreateWithName(CFSTR("STIXTwoMath"), ZATEX_FONT_PX, NULL);
}

// DIET NOTE: a hand-rolled UTF-8 decoder (zatex_decode) lived here with no
// callers — deleted (0 __TEXT either way: clang strips unreferenced
// statics). All codepoint work goes through CoreText (zatex_glyph_id).

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
// DIET (#380): hand-rolled MATH-table parsing retired — italic-correction
// table walk (zatex_ensure_math_table/zatex_italic_correction), ink-bounds
// and extents probes deleted; the three hooks below are NULL and the
// engine's deterministic fallbacks cover the shipped paths (gallery
// pixel-identical, suite green). The blessed C file provider stays
// unadopted: it links the engine core into the host (zero-linked-deps
// budget, AGENTS.md section 1), and no shippable dylib exports it.
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
    NULL, zatex_glyph_id, zatex_advance, zatex_rule_thickness, NULL, NULL, NULL,
    // Glyph variant + kern stay NULL (deterministic engine fallbacks);
    // extents/ink_bounds NULL with the MATH retirement above.
    NULL, NULL,
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
// tails land in zatex_xscale (1000 on the v1 path) and zatex_colors
// below (issue #365: 0 ambient on the v1 path).
static ZatexRunX zatex_runs_x[ZATEX_RUNS_CAP];
static uint16_t zatex_xscale[ZATEX_RUNS_CAP];
// DIET: conformance probe retired; the TEST_HOOKS counters below stay for
// the engine_info reader (permanently 0 — the zeros the suite asserts).
#ifdef TEST_HOOKS
static uint32_t zatex_conform_ran = 0;
static int32_t zatex_conform_count = 0;
#endif
// Draw scratch (BSS; main thread only): shared by the direct run loop and
// the atlas rasterizer below — one owner, sequential use, no nesting.
// Issue #388: 1024 glyphs/points per run (was 4096) — runs stride glyphs
// at ZATEX_GLYPHS_CAP only in aggregate; a single CTFontDrawGlyphs call
// never needs more than one run's worth, and runs past the cap skip.
static CGPoint zatex_pos[1024];
static CGGlyph zatex_gbuf[1024];

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
// NOTE (diet round, measured 0B): a shared zatex_fnv helper for the two
// FNV-1a byte loops (here + zatex_key_of) saves nothing — the -Oz
// outliner already merges them — so the loops stay open-coded.
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
    // #389 (GPU): None when the blit is snapped 1:1 (dest device size ==
    // mask size: no resampling either way, so no pixel change on live
    // Retina), Default only while actually downsampling (headless 1x
    // harness drawing forced-2x masks: nearest mangles thin STIX stems,
    // measured 142.8 vs 149.9 bilinear on the corrected raster). The math
    // crisp budget in the #355 test pins both arms: it runs forced-scale
    // (downsample arm) and would fail loudly if the 1:1 arm ever resampled.
    // The snapped origin above is exact on the device grid by construction
    // (roundf-then-divide), and the dest size is the mask size exactly, so
    // the 1:1 arm is taken exactly when no resampling happens.
    float dest_w_dev = dest.size.width * q;
    float dest_h_dev = dest.size.height * q;
    BOOL snapped_one_to_one = (dest_w_dev == (float)e->aw && dest_h_dev == (float)e->ah);
    CGContextSaveGState(ctx);
    CGContextSetInterpolationQuality(ctx, snapped_one_to_one ? kCGInterpolationNone : kCGInterpolationDefault);
    CGContextClipToMask(ctx, dest, e->slice);
    CGContextSetRGBFillColor(ctx, fr, fg, fb, fa);
    CGContextFillRect(ctx, dest);
    CGContextRestoreGState(ctx);
}

// Rasterize a laid-out formula into the shared 2x coverage atlas (white
// ink, like shape_rasterize_entry) and cut the entry's slice. Mirrored
// storage, exactly like the body path: the flipped-view ClipToMask blit
// maps image rows bottom-up, so the formula must be stored bottom-up
// reversed — visual top at image bottom — with run baselines anchored
// from the slice bottom (ay + ph - rel). An unmirrored (top-anchored)
// raster stores the formula upright in the image and the same blit then
// shows it vertically mirrored (numerators swap with denominators).
// Returns 1 with a live slice, 0 to draw direct.
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
        uint32_t n = rn->glyph_count;
        // Scratch bound (issue #388: zatex_gbuf/zatex_pos are 1024 now);
        // over-cap runs skip exactly like zero-count runs above.
        if (n > 1024) continue;
        double run_px = (double)font_px * (double)rn->size_units / 1000.0;
        if (run_px <= 0) continue;
        CTFontRef rf = CTFontCreateCopyWithAttributes(zatex_font, (CGFloat)(run_px * RASTER_SCALE), NULL, NULL);
        if (!rf) continue;
        double s_run = run_px / 1000.0;
        // Snap the raster origin to integer device px, mirroring the
        // screen snap and the body rasterizer (a fractional baseline
        // bakes straddled coverage edges into the mask — soft on every
        // blit thereafter). Intra-run advances stay exact; only the
        // origin quantizes, at most half a device px per run. The
        // baseline anchors from the slice BOTTOM (ay + ph - rel): image
        // rows map bottom-up at the blit, so a top-anchored origin would
        // store the formula upright and display it vertically mirrored.
        double bx = floor((double)ax + (double)rn->x * s * RASTER_SCALE + 0.5);
        double by = floor((double)ay + (double)ph - (double)rn->baseline_y * s * RASTER_SCALE + 0.5);
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
        // n already bounded to 1024 by the loop guard above.
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

// Typed-failure latch (issues #366/#377): the last engine failure's
// identity (FNV-1a over bytes + display) with its byte offset and typed
// code. platform_math_last_error answers only on identity match, so a
// fallback never marks a stale formula's position. Main thread only,
// like all layout state below.
static uint64_t zatex_err_key = 0;
static uint32_t zatex_err_offset = 0;
static int32_t zatex_err_code = 0;
static uint64_t zatex_last_diag_key = 0; // overflow stderr, once per formula

static uint64_t zatex_key_of(const char *s, int n, int display) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (int i = 0; i < n; i++) {
        h ^= (unsigned char)s[i];
        h *= 0x100000001b3ULL;
    }
    h ^= display ? (uint64_t)1 : (uint64_t)0;
    h *= 0x100000001b3ULL;
    return h ? h : 1;
}

// NFC boundary scratch (issue #374): BSS, main thread only, reused across
// calls — normalization allocates nothing on the hot path (the NSString
// pass only runs for non-ASCII formulas, which take the one cold copy).
static char zatex_nfc_buf[ZATEX_INPUT_CAP];

// Normalization owner: the host (issue #374). ASCII is already NFC:
// zero-copy. Anything else takes one platform NFC pass into BSS scratch;
// invalid UTF-8 or an overlong result keeps the raw bytes so the engine
// still reports its typed Invalid (with offset) instead of a silent drop.
static const char *zatex_nfc(const char *tex, int tex_len, int *n) {
    int ascii = 1;
    for (int i = 0; i < tex_len; i++) {
        if ((unsigned char)tex[i] >= 0x80) {
            ascii = 0;
            break;
        }
    }
    if (ascii) {
        *n = tex_len;
        return tex;
    }
    NSString *raw = [[NSString alloc] initWithBytes:tex length:(NSUInteger)tex_len encoding:NSUTF8StringEncoding];
    if (!raw) {
        *n = tex_len;
        return tex;
    }
    NSString *nfc = [raw precomposedStringWithCanonicalMapping];
    const char *u = [nfc UTF8String];
    size_t m = u ? strlen(u) : 0;
    if (m == 0 || m > ZATEX_INPUT_CAP) {
        *n = tex_len;
        return tex;
    }
    memcpy(zatex_nfc_buf, u, m);
    *n = (int)m;
    return zatex_nfc_buf;
}

// Per-run paint (issue #365): 0xRRGGBBAA from the _ex tail, 0 = ambient.
// Any painted run takes the whole formula direct (one white atlas raster
// cannot tint two paints); rules stay ambient. Binary diet: no
// uniform-paint fast path (direct is the pre-color path, pixels equal).
static uint32_t zatex_colors[ZATEX_RUNS_CAP];
static int zatex_has_color = 0;

// write(2) diagnostics, never fprintf (issue #391 __TEXT diet): the two
// one-shot notices below are the only prints in this TU, and the format
// call pulls stdio machinery into the binary. stderr is unbuffered, so
// bytes hit the fd in order either way. Literal + one dynamic part.
static void zatex_diag2(const char *a, const char *b) {
    if (a) (void)write(2, a, strlen(a));
    if (b) (void)write(2, b, strlen(b));
    (void)write(2, "\n", 1);
}

static int zatex_layout_once(const char *tex, int tex_len, int display, ZatexLayout *out) {
    if (!tex || tex_len <= 0 || tex_len > ZATEX_INPUT_CAP) return ZATEX_FALLBACK;
    zatex_try_load();
    zatex_ensure_font();
    if (!zatex_layout || !zatex_font) return ZATEX_UNAVAILABLE;
    // DIET: startup conformance probe retired — the gallery
    // tripwires re-shoot on any dylib change, so metric drift still
    // surfaces (as pixels, not stderr); engine_info conform fields stay 0.
    // Host normalization (issue #374): NFC bytes reach the engine, so the
    // NFC-vs-NFD divergence (upstream #265) cannot split one formula into
    // two layouts. The latch below keys on the caller bytes while the
    // offset is in engine coordinates — identical whenever normalization
    // is a no-op (all ASCII, the common case), near-exact otherwise.
    int nlen = 0;
    const char *ntx = zatex_nfc(tex, tex_len, &nlen);
    // Old-dylib pairing (zatex#273): a dylib predating CAP_ERR_CODE never
    // writes err_code, so the zeroed shape keeps code 0 there — and the
    // needs below stay zeroed on old space failures, which correctly read
    // as over-capacity (issue #366).
    memset(out, 0, sizeof(*out));
    // Negotiated call (issues #354/#364/#365): the caps-word gate admits
    // the CUR-byte stride (x_scale and color tails) via _ex; old dylibs
    // take the frozen v1 stride-20 path, bit-identical to before (issue
    // #354 acceptance on the installed dylib). One shared post-pass below
    // normalizes tails (0 tail reads as identity/ambient, defensive).
    int32_t rc;
    if (zatex_negotiated_ex)
        rc = zatex_layout_ex(ntx, (size_t)nlen, display ? true : false, &zatex_metrics,
                             zatex_runs_x, ZATEX_RUNS_CAP, ZATEX_RUN_SIZE_CUR,
                             zatex_rules, ZATEX_RULES_CAP,
                             zatex_glyphs, ZATEX_GLYPHS_CAP, out);
    else
        rc = zatex_layout(ntx, (size_t)nlen, display ? true : false, &zatex_metrics,
                          zatex_runs, ZATEX_RUNS_CAP, zatex_rules, ZATEX_RULES_CAP,
                          zatex_glyphs, ZATEX_GLYPHS_CAP, out);
    if (rc == 0) {
        uint32_t n = out->nruns < ZATEX_RUNS_CAP ? out->nruns : ZATEX_RUNS_CAP;
        if (zatex_negotiated_ex) {
            int any = 0;
            for (uint32_t i = 0; i < n; i++) {
                memcpy(&zatex_runs[i], &zatex_runs_x[i], sizeof(ZatexRun));
                uint16_t xs = zatex_runs_x[i].x_scale;
                zatex_xscale[i] = xs ? xs : 1000;
                uint32_t c = zatex_runs_x[i].color;
                zatex_colors[i] = c;
                if (c) any = 1;
            }
            zatex_has_color = any;
        } else {
            for (uint32_t i = 0; i < n; i++) zatex_xscale[i] = 1000;
            zatex_has_color = 0;
        }
    }
    if (rc == 0) return ZATEX_OK;
    // Typed routing (issues #366/#377): latch the caller-identity failure
    // for the error-mark query, then branch — never one blind FALLBACK.
    zatex_err_key = zatex_key_of(tex, tex_len, display);
    zatex_err_offset = out->err_offset;
    zatex_err_code = out->err_code;
    if (rc == 1) return ZATEX_UNSUPPORTED;
    if (rc == 6 || rc == 7) {
        // Overflow, not retryable: our buffers are the engine ceilings
        // (see the header note), so needs arrive zeroed — even maximum
        // buffers cannot lay this formula out. One diagnostic per
        // formula; the reader still falls back literally.
        if (zatex_last_diag_key != zatex_err_key) {
            zatex_last_diag_key = zatex_err_key;
            // Status + needs are numeric: three short decimal parts, no
            // format call. Message text unchanged.
            char nbuf[72];
            int n = 0;
            unsigned vals[3];
            vals[0] = (unsigned)rc;
            vals[1] = out->nruns;
            vals[2] = out->nrules;
            const char *seps[3] = { "read: math over engine ceilings (status ", ", need ", " runs/" };
            for (int k = 0; k < 3; k++) {
                const char *s = seps[k];
                while (*s && n < (int)sizeof(nbuf) - 24) nbuf[n++] = *s++;
                unsigned v = vals[k];
                char rev[12];
                int rn = 0;
                if (v == 0) rev[rn++] = '0';
                while (v > 0 && rn < (int)sizeof(rev)) { rev[rn++] = (char)('0' + v % 10); v /= 10; }
                while (rn > 0 && n < (int)sizeof(nbuf) - 24) nbuf[n++] = rev[--rn];
            }
            const char *tail = " rules) — literal fallback";
            while (*tail && n < (int)sizeof(nbuf) - 2) nbuf[n++] = *tail++;
            nbuf[n] = '\0';
            zatex_diag2(nbuf, NULL);
        }
        return ZATEX_OVERFLOW;
    }
    return ZATEX_FALLBACK;
}

// Typed-failure latch query for fallback error marks (issue #377): 1 with
// the latched byte offset and err_code on identity match, else 0.
int platform_math_last_error(const char *tex, int tex_len, int display,
                             unsigned int *out_offset, int *out_code) {
    if (!tex || tex_len <= 0 || zatex_err_key == 0) return 0;
    if (zatex_key_of(tex, tex_len, display) != zatex_err_key) return 0;
    if (out_offset) *out_offset = zatex_err_offset;
    if (out_code) *out_code = zatex_err_code;
    return 1;
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
// Engine negotiation state (issues #354/#361/#364): version retired (E3,
// always 0), whether the stride-negotiated _ex entry was adopted, the
// startup conformance outcome (E2, always 0), and the negotiated caps
// word (0 on unversioned-era dylibs without zatex_capabilities()).
void platform_math_engine_info(uint32_t *version, uint32_t *use_ex,
                               uint32_t *conform_ran, int32_t *conform_n,
                               uint32_t *caps) {
    if (version) *version = 0;
    if (use_ex) *use_ex = zatex_negotiated_ex ? 1 : 0;
    if (conform_ran) *conform_ran = zatex_conform_ran;
    if (conform_n) *conform_n = zatex_conform_count;
    if (caps) *caps = zatex_engine_caps;
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
            zatex_diag2("read: libzatex.dylib unavailable — math renders as source text; install to /usr/local/lib (see docs/engine.md)", NULL);
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
    // Rules ride the ambient paint (issue #365 diet: painted formulas draw
    // direct per run below; rules staying ambient matches the pre-color
    // path bit-for-bit on old dylibs and costs nothing new).
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
    // downsample 2x art. Painted formulas (issue #365) skip the cache
    // and draw direct: one white raster cannot tint two paints.
    if (g_output_scale > 1.5f && tex_len <= ZATEX_ATLAS_TEX_CAP && !zatex_has_color) {
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
    // Painted runs (issue #365): switch the fill when the run's own paint
    // differs (unpainted formulas never enter this arm — the fill above
    // already matches every run).
    uint32_t ambient_w = ((uint32_t)r << 24) | ((uint32_t)g << 16) | ((uint32_t)b << 8) | a;
    uint32_t cur_w = ambient_w;
    for (uint32_t i = 0; i < lo.nruns; i++) {
        ZatexRun *rn = &zatex_runs[i];
        if (rn->glyph_count == 0 || rn->glyph_start + rn->glyph_count > ZATEX_GLYPHS_CAP) continue;
        uint32_t n = rn->glyph_count;
        // Scratch bound (issue #388: 1024 now); over-cap runs skip, same
        // rule as the atlas rasterizer above.
        if (n > 1024) continue;
        if (zatex_has_color) {
            uint32_t c = zatex_colors[i];
            uint32_t want = c ? c : ambient_w;
            if (want != cur_w) {
                CGContextSetRGBFillColor(ctx, ((want >> 24) & 255) / 255.0,
                                              ((want >> 16) & 255) / 255.0,
                                              ((want >> 8) & 255) / 255.0,
                                              (want & 255) / 255.0);
                cur_w = want;
            }
        }
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
        // relative). Identity folds exactly (1000/1000.0 is 1.0), so the
        // v1 path issues the identical call with no branch (old dylib:
        // always 1000).
        CGContextScaleCTM(ctx, (CGFloat)((double)zatex_xscale[i] / 1000.0), -1.0);
        CGContextSetTextPosition(ctx, 0, 0);
        // n already bounded to 1024 by the loop guard above.
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

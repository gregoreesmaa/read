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
// - Optional hooks (variants, italic/kerning corrections, extents, ink)
//   stay NULL: the core is correct without them (deterministic
//   fallbacks); big-delimiter growth and accent placement are the known
//   v1 fidelity gap, documented in docs/spec.md.
// - The frozen C surface projects filled rects only (cabi.zig): diagonal
//   `cancel` strikes never arrive (skipped engine-side, never misdrawn)
//   and per-run `\color` is dropped engine-side (runs take ambient).
// - Rule thickness defaults to 40/1000 em for every kind (KaTeX default).

#include <dlfcn.h>
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
    const void *ctx;
    uint16_t (*glyph_id)(const void *ctx, uint16_t font, uint32_t cp);
    int32_t (*advance)(const void *ctx, uint16_t font, uint16_t glyph);
    int32_t (*rule_thickness)(const void *ctx, uint16_t font, uint32_t kind);
    uint16_t (*glyph_variant)(const void *ctx, uint16_t font, uint16_t glyph, int32_t min_height);
    int32_t (*italic_correction)(const void *ctx, uint16_t font, uint16_t glyph);
    int32_t (*kern_correction)(const void *ctx, uint16_t font, uint16_t glyph, int32_t height, uint32_t corner);
} ZatexMetrics;

typedef struct {
    uint16_t font_id;
    uint16_t size_units;
    int32_t x;
    int32_t baseline_y;
    uint32_t glyph_start;
    uint32_t glyph_count;
} ZatexRun;

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

_Static_assert(sizeof(ZatexRun) == 20, "ZatexRun must match cabi.zig CRun");
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

static void *zatex_handle = NULL;
static ZatexLayoutFn zatex_layout = NULL;
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
    if (!zatex_font) {
        CFStringRef path = CFSTR("/System/Library/Fonts/Supplemental/STIXTwoMath.otf");
        CFURLRef url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, false);
        if (url) {
            CFArrayRef ds = CTFontManagerCreateFontDescriptorsFromURL(url);
            if (ds && CFArrayGetCount(ds) > 0) {
                CTFontDescriptorRef d = (CTFontDescriptorRef)CFArrayGetValueAtIndex(ds, 0);
                zatex_font = CTFontCreateWithFontDescriptor(d, ZATEX_FONT_PX, NULL);
                CFRelease(ds);
            }
            CFRelease(url);
        }
    }
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
    if (!zatex_font) return 0;
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
static int32_t zatex_advance(const void *ctx, uint16_t font, uint16_t glyph) {
    (void)ctx;
    (void)font;
    zatex_ensure_font();
    if (!zatex_font || glyph == 0) return 500;
    CGGlyph g = glyph;
    CGSize adv;
    if (CTFontGetAdvancesForGlyphs(zatex_font, kCTFontOrientationHorizontal, &g, &adv, 1) == 0) return 500;
    int32_t units = (int32_t)(adv.width / (double)ZATEX_FONT_PX * 1000.0 + 0.5);
    return units > 0 ? units : 500;
}

static const ZatexMetrics zatex_metrics = {
    NULL, zatex_glyph_id, zatex_advance, NULL, NULL, NULL, NULL,
};

// ---------------------------------------------------------------------------
// Layout buffers (BSS; main thread only; re-laid-out per call —
// microsecond-grade, so no cache: size and draw always agree).
// ---------------------------------------------------------------------------

static ZatexRun zatex_runs[ZATEX_RUNS_CAP];
static ZatexRule zatex_rules[ZATEX_RULES_CAP];
static uint16_t zatex_glyphs[ZATEX_GLYPHS_CAP];

static int zatex_layout_once(const char *tex, int tex_len, int display, ZatexLayout *out) {
    if (!tex || tex_len <= 0 || tex_len > ZATEX_INPUT_CAP) return ZATEX_FALLBACK;
    zatex_try_load();
    if (!zatex_layout) return ZATEX_UNAVAILABLE;
    zatex_ensure_font();
    if (!zatex_font) return ZATEX_UNAVAILABLE;
    int32_t rc = zatex_layout(tex, (size_t)tex_len, display ? true : false, &zatex_metrics,
                              zatex_runs, ZATEX_RUNS_CAP, zatex_rules, ZATEX_RULES_CAP,
                              zatex_glyphs, ZATEX_GLYPHS_CAP, out);
    return rc == 0 ? ZATEX_OK : ZATEX_FALLBACK;
}

// Synchronous size query for the Zig box path (mirrors image_size_fn):
// dims are px at font_px (units are thousandths of an em).
int platform_math_size(const char *tex, int tex_len, int display, float font_px,
                       float *out_w, float *out_above, float *out_below) {
    if (out_w) *out_w = 0;
    if (out_above) *out_above = 0;
    if (out_below) *out_below = 0;
    if (!tex || tex_len <= 0 || font_px <= 0) return ZATEX_FALLBACK;
    ZatexLayout lo;
    int st = zatex_layout_once(tex, tex_len, display, &lo);
    if (st == ZATEX_UNAVAILABLE && !zatex_missing_noticed) {
        zatex_missing_noticed = 1;
        fprintf(stderr, "read: libzatex.dylib unavailable — math renders as source text\n");
    }
    if (st != ZATEX_OK) return st;
    double s = (double)font_px / 1000.0;
    if (out_w) *out_w = (float)(lo.width * s);
    if (out_above) *out_above = (float)(lo.height_above * s);
    if (out_below) *out_below = (float)(lo.depth_below * s);
    return ZATEX_OK;
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
    CGContextSetRGBFillColor(ctx, r / 255.0, g / 255.0, b / 255.0, a / 255.0);
    // Rules first (under ink, like fraction bars behind nothing — order
    // is irrelevant for disjoint rects; one fill color for all).
    for (uint32_t i = 0; i < lo.nrules; i++) {
        ZatexRule *rl = &zatex_rules[i];
        CGRect rr = CGRectMake((float)(x + rl->x * s), (float)(y_top + rl->y * s),
                               (float)(rl->w * s), (float)(rl->h * s));
        CGContextFillRect(ctx, rr);
    }
    // Runs: batch glyph draw per run at its own size (script sizes ride
    // size_units, per-mille of ambient). Glyph origins accumulate the
    // SAME integer advances the engine laid out with (units, exact),
    // converted once to px — ink lands exactly where layout put it,
    // with no float-drift between the size query and the draw.
    static CGPoint zatex_pos[256];
    for (uint32_t i = 0; i < lo.nruns; i++) {
        ZatexRun *rn = &zatex_runs[i];
        if (rn->glyph_count == 0 || rn->glyph_start + rn->glyph_count > ZATEX_GLYPHS_CAP) continue;
        double run_px = (double)font_px * (double)rn->size_units / 1000.0;
        if (run_px <= 0 || !zatex_font) continue;
        // Same-size fast path keeps the shared font; odd sizes copy it.
        CTFontRef rf = zatex_font;
        CTFontRef owned = NULL;
        if (rn->size_units != 1000) {
            owned = CTFontCreateCopyWithAttributes(zatex_font, (CGFloat)run_px, NULL, NULL);
            if (owned) rf = owned;
        }
        uint32_t n = rn->glyph_count;
        double base = y_top + rn->baseline_y * s;
        int64_t acc = 0;
        uint32_t done = 0;
        while (done < n) {
            uint32_t m = n - done;
            if (m > 256) m = 256;
            CGGlyph gbuf[256];
            for (uint32_t k = 0; k < m; k++) {
                uint16_t g = zatex_glyphs[rn->glyph_start + done + k];
                gbuf[k] = (CGGlyph)g;
                zatex_pos[k] = CGPointMake((float)(x + (rn->x + acc) * s), base);
                acc += zatex_advance(NULL, rn->font_id, g);
            }
            CTFontDrawGlyphs(rf, gbuf, zatex_pos, (CFIndex)m, ctx);
            done += m;
        }
        if (owned) CFRelease(owned);
    }
}

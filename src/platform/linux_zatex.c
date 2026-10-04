// ZaTeX runtime math backend for the Linux X11 port.
//
// Included by src/platform/linux.c — one TU, same discipline as
// macos.m including macos_zatex.m (AGENTS.md §7: this file plus its Zig
// seams count as plugin code; twin builds include linux_zatex_stub.c
// instead; same TU, same flags).
//
// Design mirrors macos_zatex.m: dlopen only, never linked. The engine
// (libzatex.so, built from the pinned third_party/zatex submodule)
// lays out synchronously over caller-owned BSS buffers. Absent engine
// (or any layout failure) reports fallback and the reader renders the
// source literally.
//
// Host duties (differs from macOS only in the font stack):
// - Glyph identity + advances come from one cached FreeType math face
//   (first layout resolves it via the per-glyph fontconfig fallback
//   path: STIX Two Math when installed, else the fontconfig match for
//   the probe codepoint — same "whatever covers math" stance as body
//   text; per-OS screenshot baselines absorb the raster difference).
// - Rule thickness is KaTeX parity 40/1000em for every kind (same
//   constant as macOS: explicit, not file truth, not NULL).
// - Variants, italic/kerning corrections, extents, ink bounds stay NULL
//   (deterministic engine fallbacks, same as macOS after the #380 diet).
// - ASCII formulas skip normalization zero-copy (already NFC); non-ASCII
//   passes through raw: the engine reports typed Invalid with offset
//   (no 100KB tables in-ship, same stance as macOS minus the NSString
//   pass — a divergence only for non-ASCII formulas, which still lay
//   out or fall back deterministically).
// - Draw consults the formula atlas (issue #355, same 2x/supersample
//   policy and key/identity contract as macos_zatex.m) with a FreeType
//   raster backend: a cached entry blits 1:1 at the snapped formula
//   origin; misses rasterize once at the destination scale into a
//   malloc'd 8-bit coverage slice. 1x draws and painted formulas
//   (issue #365: one white raster cannot tint two paints) stay on the
//   direct FreeType path below.
// - Caps negotiation (zatex_capabilities / _ex stride / x_scale / color
//   tails / typed latch) mirrors macos_zatex.m exactly.

#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <fontconfig/fontconfig.h>

// ---------------------------------------------------------------------------
// C ABI mirror (must match zatex.h / macos_zatex.m; _Static_asserts below).
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

#define ZATEX_RUN_SIZE_V1 20
#define ZATEX_RUN_SIZE_CUR 28
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
#define ZATEX_INPUT_CAP 65536

enum { ZATEX_OK = 0, ZATEX_UNAVAILABLE = 1, ZATEX_FALLBACK = 2, ZATEX_OVERFLOW = 3, ZATEX_UNSUPPORTED = 4 };

// ---------------------------------------------------------------------------
// Engine loading (once per process).
// ---------------------------------------------------------------------------

typedef int32_t (*ZatexLayoutFn)(const char *, size_t, _Bool, const ZatexMetrics *,
                                 ZatexRun *, size_t, ZatexRule *, size_t,
                                 uint16_t *, size_t, ZatexLayout *);
typedef int32_t (*ZatexLayoutExFn)(const char *, size_t, _Bool, const ZatexMetrics *,
                                   void *, size_t, size_t, ZatexRule *, size_t,
                                   uint16_t *, size_t, ZatexLayout *);
typedef uint32_t (*ZatexCapsFn)(void);
#define ZATEX_CAP_X_SCALE (1u << 0)
#define ZATEX_CAP_RUN_COLOR (1u << 1)
#define ZATEX_CAP_NEED_COUNTS (1u << 2)
#define ZATEX_CAP_ERR_CODE (1u << 3)

static void *zatex_handle = NULL;
static ZatexLayoutFn zatex_layout = NULL;
static ZatexLayoutExFn zatex_layout_ex = NULL;
static uint32_t zatex_engine_caps = 0;
static int zatex_has_caps = 0;
static int zatex_negotiated_ex = 0;
static int zatex_tried_load = 0;
static int zatex_missing_noticed = 0;

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

// Engine search order: $READ_ZATEX_LIB (CI/test, absolute path from the
// pinned submodule build) → exe-relative lib (installed layout) →
// system path. dlopen only, never linked.
static void zatex_try_load(void) {
    if (zatex_tried_load) return;
    zatex_tried_load = 1;
#ifdef TEST_HOOKS
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
    const char *env = getenv("READ_ZATEX_LIB");
    if (env && env[0]) {
        void *h = dlopen(env, RTLD_NOW | RTLD_LOCAL);
        if (h) {
            int ok = 0;
            ZATEX_ADOPT(h, ok);
            if (!ok) dlclose(h);
            else return;
        }
    }
    // Only the documented install path is probed (plus $READ_ZATEX_LIB
    // above): production surfaces a minimal interface, never a
    // search-path hunt (macos_zatex.m stance).
    static const char *paths[] = {
        "/usr/local/lib/libzatex.so",
    };
    for (unsigned k = 0; k < sizeof(paths) / sizeof(paths[0]); k++) {
        void *h = dlopen(paths[k], RTLD_NOW | RTLD_LOCAL);
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
// Metrics provider over one cached FreeType math face.
// ---------------------------------------------------------------------------
// linux.c owns: g_ft (FT_Library), fb_face_for(cp, is_mono) (per-glyph
// fontconfig fallback), blend_px, fill_rect_px, g_output_scale.

static FT_Face zatex_face = NULL;

static void zatex_ensure_face(void) {
    if (zatex_face || !g_ft) return;
    // Probe codepoint in the math core (infix fraction slash): whatever
    // face the fallback chain resolves for it becomes the math face, so
    // glyph ids, advances, and draw pixels can never disagree.
    zatex_face = fb_face_for(0x2215, 0);
}

// Per-font-id faces (the engine addresses styled alphabets by font id:
// rm/mathit/bold/... map to Unicode math blocks the single fallback
// face may not cover). Latin Modern Math covers them; the fontconfig
// fallback chain resolves per codepoint otherwise. Unused slots stay
// NULL and read as the base face (same "whatever covers math" stance
// as body text; per-OS baselines absorb the difference).
#define ZATEX_FACE_SLOTS 16
static FT_Face zatex_faces[ZATEX_FACE_SLOTS];
static uint16_t zatex_glyph_id(const void *ctx, uint16_t font, uint32_t cp) {
    (void)ctx;
    zatex_ensure_face();
    if (!zatex_face) return 0;
    if (cp > 0x10FFFF) return 0;
    // Styled ids resolve their own face once (same fb_face_for probe
    // discipline as the base face: U+2215 coverage proves a math face).
    // A slot that resolves nothing reads as the base face — partial
    // coverage degrades to base rendering instead of tofu.
    FT_Face face = zatex_face;
    if (font < ZATEX_FACE_SLOTS && font != 0) {
        if (!zatex_faces[font]) {
            // fb_face_for lives in linux.c (same TU via #include):
            // resolve the requesting codepoint itself so styled
            // alphabets land on a face that covers them.
            FT_Face cand = fb_face_for(cp, 0);
            zatex_faces[font] = cand ? cand : zatex_face;
        }
        face = zatex_faces[font] ? zatex_faces[font] : zatex_face;
    }
    // A codepoint with no mapping reports 0 (the engine's styled-glyph
    // fallback path), never the .notdef stand-in: FT_Get_Char_Index
    // answers 0 for missing.
    return (uint16_t)FT_Get_Char_Index(face, (FT_ULong)cp);
}

// Advance in thousandths of an em (engine unit), at the 100-unit face
// the engine sizes per run (ZATEX_FONT_PX below mirrors macos_zatex.m).
#define ZATEX_FONT_PX 100.0f

static int32_t zatex_advance(const void *ctx, uint16_t font, uint16_t glyph) {
    (void)ctx;
    zatex_ensure_face();
    if (!zatex_face || glyph == 0) return 500;
    // Advances come from the same per-font-id face the ids did (ids
    // are face-local: measuring on another face misreads them).
    FT_Face face = zatex_face;
    if (font < ZATEX_FACE_SLOTS && font != 0 && zatex_faces[font]) face = zatex_faces[font];
    if (FT_Set_Pixel_Sizes(face, 0, (FT_UInt)ZATEX_FONT_PX) != 0) return 500;
    if (FT_Load_Glyph(face, (FT_UInt)glyph, FT_LOAD_DEFAULT) != 0) return 500;
    // 26.6 fixed-point advance at 100px = thousandths of an em directly.
    // Zero-width glyphs (combining accents) report 0 like the file;
    // load failures keep the 500 missing-glyph fallback.
    int32_t units = (int32_t)((face->glyph->advance.x + 32) >> 6);
    return units < 0 ? 500 : units;
}

// KaTeX parity 40/1000em for every rule kind (macos_zatex.m: explicit,
// not file truth, not NULL — same reasoning).
static int32_t zatex_rule_thickness(const void *ctx, uint16_t font, uint32_t kind) {
    (void)ctx;
    (void)font;
    (void)kind;
    return 40;
}

static const ZatexMetrics zatex_metrics = {
    NULL, zatex_glyph_id, zatex_advance, zatex_rule_thickness, NULL, NULL, NULL,
    NULL, NULL,
};

// ---------------------------------------------------------------------------
// Layout buffers (BSS; main thread only).
// ---------------------------------------------------------------------------

static ZatexRun zatex_runs[ZATEX_RUNS_CAP];
static ZatexRule zatex_rules[ZATEX_RULES_CAP];
static uint16_t zatex_glyphs[ZATEX_GLYPHS_CAP];
static ZatexRunX zatex_runs_x[ZATEX_RUNS_CAP];
static uint16_t zatex_xscale[ZATEX_RUNS_CAP];
// Per-glyph advances in thousandths, filled by the layout post-pass for
// every laid-out glyph id: draw reads the cache instead of re-measuring
// (which would also thrash the face size between run_px and 100 mid-run).
static int16_t zatex_adv_cache[ZATEX_GLYPHS_CAP];
static uint32_t zatex_colors[ZATEX_RUNS_CAP];
static int zatex_has_color = 0;
#ifdef TEST_HOOKS
static uint32_t zatex_conform_ran = 0;
static int32_t zatex_conform_count = 0;
#endif

static uint64_t zatex_err_key = 0;
static uint32_t zatex_err_offset = 0;
static int32_t zatex_err_code = 0;
static uint64_t zatex_last_diag_key = 0;

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

static int zatex_layout_once(const char *tex, int tex_len, int display, ZatexLayout *out) {
    if (!tex || tex_len <= 0 || tex_len > ZATEX_INPUT_CAP) return ZATEX_FALLBACK;
    zatex_try_load();
    zatex_ensure_face();
    if (!zatex_layout || !zatex_face) return ZATEX_UNAVAILABLE;
    // Bytes pass through raw (no normalization tables in-ship; ASCII is
    // already NFC): the engine still reports typed Invalid with offset
    // instead of a silent drop.
    memset(out, 0, sizeof(*out));
    // Space-pressure routing (issues #366/#378): status 6 with nonzero
    // needs inside the ceilings routes to FALLBACK (same rule as
    // macos_zatex.m — the double's NOSPACE script is in-ceiling on
    // every call, so a re-issue could never satisfy it).
    int32_t rc;
    if (zatex_negotiated_ex)
        rc = zatex_layout_ex(tex, (size_t)tex_len, display, &zatex_metrics,
                             zatex_runs_x, ZATEX_RUNS_CAP, ZATEX_RUN_SIZE_CUR,
                             zatex_rules, ZATEX_RULES_CAP,
                             zatex_glyphs, ZATEX_GLYPHS_CAP, out);
    else
        rc = zatex_layout(tex, (size_t)tex_len, display, &zatex_metrics,
                          zatex_runs, ZATEX_RUNS_CAP, zatex_rules, ZATEX_RULES_CAP,
                          zatex_glyphs, ZATEX_GLYPHS_CAP, out);
    if (rc == 6) {
        if (out->nruns <= ZATEX_RUNS_CAP && out->nrules <= ZATEX_RULES_CAP &&
            (out->nruns > 0 || out->nrules > 0)) {
            zatex_err_key = zatex_key_of(tex, tex_len, display);
            zatex_err_offset = out->err_offset;
            zatex_err_code = out->err_code;
            return ZATEX_FALLBACK;
        }
    }
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
        // Advance cache for the draw pass (per glyph id; ids repeat
        // across runs, so re-measuring is pure waste — and measuring
        // here keeps draw's face size untouched).
        for (uint32_t i = 0; i < n; i++) {
            ZatexRun *rn = &zatex_runs[i];
            if (rn->glyph_start + rn->glyph_count > ZATEX_GLYPHS_CAP) continue;
            for (uint32_t k = 0; k < rn->glyph_count; k++) {
                uint16_t gl = zatex_glyphs[rn->glyph_start + k];
                int32_t a = zatex_advance(NULL, rn->font_id, gl);
                zatex_adv_cache[k + rn->glyph_start] = a > 32767 ? 32767 : (int16_t)a;
            }
        }
    }
    if (rc == 0) return ZATEX_OK;
    zatex_err_key = zatex_key_of(tex, tex_len, display);
    zatex_err_offset = out->err_offset;
    zatex_err_code = out->err_code;
    if (rc == 1) return ZATEX_UNSUPPORTED;
    if (rc == 6 || rc == 7) {
        // Overflow: zeroed or over-ceiling needs (same comment as
        // macos_zatex.m).
        if (zatex_last_diag_key != zatex_err_key) {
            zatex_last_diag_key = zatex_err_key;
            fprintf(stderr, "read: math over engine ceilings (status %d, need %u runs/%u rules) — literal fallback\n",
                    rc, out->nruns, out->nrules);
        }
        return ZATEX_OVERFLOW;
    }
    return ZATEX_FALLBACK;
}

int platform_math_last_error(const char *tex, int tex_len, int display,
                             unsigned int *out_offset, int *out_code) {
    if (!tex || tex_len <= 0 || zatex_err_key == 0) return 0;
    if (zatex_key_of(tex, tex_len, display) != zatex_err_key) return 0;
    if (out_offset) *out_offset = zatex_err_offset;
    if (out_code) *out_code = zatex_err_code;
    return 1;
}

// Formula atlas (issue #355): TEST_HOOKS-only Retina pre-raster for
// math runs (the read-test 2x supersample exercise). X11 has no live
// Retina scale, so ship draws direct every frame — but the atlas
// counters and reuse contract still pin through the test binary, which
// shares this TU. Each unique formula — TeX bytes + font size +
// display mode — rasterizes ONCE into a cached 8-bit coverage slice and
// blits thereafter: steady-state draws are one masked blit with no
// shaping, no copy, no allocation. Rules stay direct fills (already
// device-snapped); intra-run advances stay exact (never rounded); only
// the blit origin snaps, exactly like the body blit.
// Key byte order mirrors zatex_atlas_key in macos_zatex.m (pinned in
// cross-platform tests there): tex bytes, then font-bits LE bytes, then
// the display byte. Entry identity (key + len + 8-byte head) and
// slot/eviction/counter semantics match macos_zatex.m exactly; only the
// raster backend differs (FreeType gray coverage instead of CoreText).
// Ship builds compile all of it out (BSS + code): the q == 1 fold in
// platform_draw_math below is the only ship survivor.
#define ZATEX_ATLAS_CAP 64
// Cacheable TeX length: the key hashes every byte per draw, so
// pathological inputs skip the cache and draw direct (macOS parity).
#define ZATEX_ATLAS_TEX_CAP 4096
#ifdef TEST_HOOKS
typedef struct {
    uint64_t key; // FNV-1a(tex bytes, font bits, display)
    int len; // > 0 once inserted (cold slots are BSS-zero)
    char head[8]; // first bytes (cheap collision guard)
    int w, h; // slice size in device px (dest size exactly, never scaled)
    int ox, oy; // formula origin inside the slice, device px
    unsigned char *px; // coverage slice (malloc'd, freed on evict/flush)
} ZatexAtlasEntry;
static ZatexAtlasEntry zatex_atlas[ZATEX_ATLAS_CAP]; // BSS: no binary cost
static uint64_t zatex_atlas_hits = 0, zatex_atlas_misses = 0;
static uint64_t zatex_atlas_key(const char *tex, int len, float font_px, int display) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (int i = 0; i < len; i++) {
        h ^= (unsigned char)tex[i];
        h *= 0x100000001b3ULL;
    }
    uint32_t fb = 0;
    memcpy(&fb, &font_px, 4);
    for (int i = 0; i < 4; i++) {
        h ^= (uint64_t)((fb >> (i * 8)) & 255);
        h *= 0x100000001b3ULL;
    }
    h ^= display ? (uint64_t)1 : (uint64_t)0;
    h *= 0x100000001b3ULL;
    return h;
}
#endif
#ifdef TEST_HOOKS
void platform_math_atlas_stats(uint64_t *hits, uint64_t *misses) {
    if (hits) *hits = zatex_atlas_hits;
    if (misses) *misses = zatex_atlas_misses;
}
void platform_math_engine_info(unsigned int *version, unsigned int *use_ex,
                               unsigned int *conform_ran, int *conform_n,
                               unsigned int *caps) {
    if (version) *version = 0;
    if (use_ex) *use_ex = zatex_negotiated_ex ? 1 : 0;
    if (conform_ran) *conform_ran = zatex_conform_ran;
    if (conform_n) *conform_n = zatex_conform_count;
    if (caps) *caps = zatex_engine_caps;
}
#endif

#ifdef TEST_HOOKS
// Generational flush hook, called from the shape-cache flush in linux.c
// (forward declared there): evictions must never leave stale math
// slices. Freed entries re-rasterize lazily on next draw.
void zatex_drop_math_rasters(void) {
    for (unsigned i = 0; i < ZATEX_ATLAS_CAP; i++) {
        if (zatex_atlas[i].px) { free(zatex_atlas[i].px); zatex_atlas[i].px = NULL; }
        zatex_atlas[i].w = 0;
        zatex_atlas[i].h = 0;
    }
}
#else
void zatex_drop_math_rasters(void) {}
#endif

// One cached-slice blit at the snapped formula origin. Dest size is the
// slice size exactly (never the laid-out advance — no sub-pixel
// stretch), mirroring the macOS blit. Coverage tints by the ambient
// paint through the same blend_px the direct path uses.
#ifdef TEST_HOOKS
static void zatex_blit_cached(ZatexAtlasEntry *e, float x, float y_top,
                              unsigned char r, unsigned char g, unsigned char b, unsigned char a) {
    // No live Retina scale on X11: the headless supersample factor
    // (g_test_scale, TEST_HOOKS only, defined in linux.c) is the only
    // >1x destination. Ship builds fold to q == 1.
    extern float g_test_scale;
    float q = g_test_scale > 0.0f ? g_test_scale : 1.0f;
    // Blend core lives in linux.c (same TU via #include): BGRX order,
    // like blend_px. Canvas words are extern there, not static, so the
    // backend reads them directly.
    extern unsigned char *g_canvas_px;
    extern int g_win_w, g_win_h;
    if (!e->px || !g_canvas_px) return;
    int dx = (int)(x * q + 0.5f);
    int dy = (int)(y_top * q + 0.5f);
    unsigned ia = a;
    for (int row = 0; row < e->h; row++) {
        int yy = dy + e->oy + row;
        if (yy < 0 || yy >= g_win_h) continue;
        unsigned char *srow = e->px + (size_t)row * e->w;
        for (int col = 0; col < e->w; col++) {
            int xx = dx + e->ox + col;
            if (xx < 0 || xx >= g_win_w) continue;
            unsigned cov = srow[col];
            unsigned eff = cov * ia / 255;
            if (!eff) continue;
            size_t o = ((size_t)yy * g_win_w + (size_t)xx) * 4;
            unsigned inv = 255 - eff;
            // BGRX order, like blend_px.
            g_canvas_px[o] = (unsigned char)((b * eff + g_canvas_px[o] * inv + 127) / 255);
            g_canvas_px[o + 1] = (unsigned char)((g * eff + g_canvas_px[o + 1] * inv + 127) / 255);
            g_canvas_px[o + 2] = (unsigned char)((r * eff + g_canvas_px[o + 2] * inv + 127) / 255);
        }
    }
}

// Rasterize a laid-out formula into a cached 8-bit coverage slice at
// the destination device scale: one FreeType gray render per glyph at
// run_px * q, composited max-coverage into the slice. Returns 1 with a
// live slice, 0 to draw direct.
#ifdef TEST_HOOKS
static int zatex_rasterize(ZatexAtlasEntry *e, const ZatexLayout *lo, double s, float font_px,
                           float x, float y_top) {
    extern float g_test_scale;
    float q = g_test_scale > 0.0f ? g_test_scale : 1.0f;
    extern FT_Face zatex_face;
    int pw = (int)((double)lo->width * s * q + 0.5);
    int ph = (int)(((double)lo->height_above + (double)lo->depth_below) * s * q + 0.5);
    // Larger than a working-set slice: draw direct every frame.
    if (pw <= 0 || ph <= 0 || pw > 1024 || ph > 1024 || !zatex_face) return 0;
    unsigned char *slice = (unsigned char *)calloc((size_t)pw * ph, 1);
    if (!slice) return 0;
    // Snapshot origin: the formula's ink box maps to slice (0,0); the
    // blit re-adds the snapped destination origin (ox/oy fold the
    // sub-device remainder, exactly like the macOS blit origin snap).
    double ox = (double)x * q, oy = (double)y_top * q;
    int ix = (int)(ox + 0.5), iy = (int)(oy + 0.5);
    double s2 = s * q;
    for (uint32_t i = 0; i < lo->nrules; i++) {
        const ZatexRule *rl = &zatex_rules[i];
        int rx = (int)((double)rl->x * s2 + 0.5) - ix;
        int ry = (int)((double)rl->y * s2 + 0.5) - iy;
        int rw = (int)((double)rl->w * s2 + 0.5), rh = (int)((double)rl->h * s2 + 0.5);
        if (rh <= 0) rh = 1;
        for (int yy = ry; yy < ry + rh; yy++) {
            if (yy < 0 || yy >= ph) continue;
            for (int xx = rx; xx < rx + rw; xx++) {
                if (xx < 0 || xx >= pw) continue;
                slice[(size_t)yy * pw + xx] = 255;
            }
        }
    }
    for (uint32_t i = 0; i < lo->nruns; i++) {
        const ZatexRun *rn = &zatex_runs[i];
        if (rn->glyph_count == 0 || rn->glyph_start + rn->glyph_count > ZATEX_GLYPHS_CAP) continue;
        // Same per-font-id face as the direct path (ids are face-local).
        FT_Face face = zatex_face;
        if (rn->font_id < ZATEX_FACE_SLOTS && rn->font_id != 0 && zatex_faces[rn->font_id])
            face = zatex_faces[rn->font_id];
        double run_px = (double)font_px * (double)rn->size_units / 1000.0 * q;
        if (run_px <= 0) continue;
        if (FT_Set_Pixel_Sizes(face, 0, (FT_UInt)(run_px + 0.5)) != 0) continue;
        // Stretched runs (issue #354): ink AND pen scale about the run
        // origin by x_scale/1000 (same recipe as the direct path).
        double xs = (double)zatex_xscale[i] / 1000.0;
        double bx = (double)rn->x * s2 - ix;
        double baseline = (double)rn->baseline_y * s2 - iy;
        double acc = 0.0;
        for (uint32_t k = 0; k < rn->glyph_count; k++) {
            uint16_t gl = zatex_glyphs[rn->glyph_start + k];
            if (FT_Load_Glyph(face, (FT_UInt)gl, FT_LOAD_RENDER) != 0) {
                acc += zatex_adv_cache[rn->glyph_start + k];
                continue;
            }
            FT_Bitmap *bm = &face->glyph->bitmap;
            double s_run = run_px / 1000.0;
            int dx = (int)(bx + acc * s_run * xs + 0.5);
            int dy = (int)(baseline - face->glyph->bitmap_top + 0.5);
            for (int row = 0; row < (int)bm->rows; row++) {
                int yy = dy + row;
                if (yy < 0 || yy >= ph) continue;
                for (int col = 0; col < (int)bm->width; col++) {
                    int xx = dx + col;
                    if (xx < 0 || xx >= pw) continue;
                    unsigned char cov = bm->buffer[row * bm->pitch + col];
                    unsigned char *dst = &slice[(size_t)yy * pw + xx];
                    if (cov > *dst) *dst = cov;
                }
            }
            acc += zatex_adv_cache[rn->glyph_start + k];
        }
    }
    if (e->px) free(e->px);
    e->px = slice;
    e->w = pw;
    e->h = ph;
    e->ox = ix - (int)(ox + 0.5);
    e->oy = iy - (int)(oy + 0.5);
    return 1;
}
#endif

int platform_math_size(const char *tex, int tex_len, int display, float font_px,
                       float *out_w, float *out_above, float *out_below) {
    float w = 0, above = 0, below = 0;
    int st = ZATEX_FALLBACK;
    if (tex && tex_len > 0 && font_px > 0) {
        ZatexLayout lo;
        st = zatex_layout_once(tex, tex_len, display, &lo);
        if (st == ZATEX_UNAVAILABLE && !zatex_missing_noticed) {
            zatex_missing_noticed = 1;
            fprintf(stderr, "read: libzatex.so unavailable — math renders as source text (see docs/engine.md)\n");
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

// Draw a laid-out formula: rules as filled rects, runs as FreeType glyph
// blits at the run baseline. y_top is the formula ink top from the same
// dims platform_math_size reported.
void platform_draw_math(const char *tex, int tex_len, int display, float font_px,
                        float x, float y_top,
                        unsigned char r, unsigned char g, unsigned char b, unsigned char a) {
    if (!g_canvas_px || !tex || tex_len <= 0 || font_px <= 0) return;
    ZatexLayout lo;
    if (zatex_layout_once(tex, tex_len, display, &lo) != ZATEX_OK) return;
    double s = (double)font_px / 1000.0;
#ifdef TEST_HOOKS
    // Formula atlas (issue #355): on supersampled destinations a cached
    // raster blits 1:1 at the snapped formula origin; everywhere else
    // (1x, or uncacheable input) the legacy direct path below draws.
    // Painted formulas (issue #365) skip the cache and draw direct: one
    // white raster cannot tint two paints.
    extern float g_test_scale;
    if (g_test_scale > 1.5f && tex_len <= ZATEX_ATLAS_TEX_CAP && !zatex_has_color) {
        uint64_t key = zatex_atlas_key(tex, tex_len, font_px, display);
        ZatexAtlasEntry *e = &zatex_atlas[key % ZATEX_ATLAS_CAP];
        int hl = tex_len < 8 ? tex_len : 8;
        if (e->px && e->key == key && e->len == tex_len &&
            memcmp(e->head, tex, (size_t)hl) == 0) {
            zatex_blit_cached(e, x, y_top, r, g, b, a);
            zatex_atlas_hits++;
            return;
        }
        // Miss: evict the collision (if any) and take the slot. A failed
        // rasterize leaves the slot cold (NULL slice) and draws direct.
        if (e->px) { free(e->px); e->px = NULL; }
        e->key = key;
        e->len = tex_len;
        memcpy(e->head, tex, (size_t)hl);
        if (zatex_rasterize(e, &lo, s, font_px, x, y_top)) {
            zatex_blit_cached(e, x, y_top, r, g, b, a);
            zatex_atlas_misses++;
            return;
        }
    }
#endif
    for (uint32_t i = 0; i < lo.nrules; i++) {
        ZatexRule *rl = &zatex_rules[i];
        float rx = (float)(x + rl->x * s), ry = (float)(y_top + rl->y * s);
        float rw = (float)(rl->w * s), rh = (float)(rl->h * s);
        // Snap bar rows to device pixels (macos_zatex.m rule arm).
        float y0 = floorf(ry + 0.5f), y1 = floorf(ry + rh + 0.5f);
        if (y1 <= y0) y1 = y0 + 1.0f;
        fill_rect_px(rx, y0, rw, y1 - y0, r, g, b, a);
    }
    if (!zatex_face) return;
    for (uint32_t i = 0; i < lo.nruns; i++) {
        ZatexRun *rn = &zatex_runs[i];
        if (rn->glyph_count == 0 || rn->glyph_start + rn->glyph_count > ZATEX_GLYPHS_CAP) continue;
        // Glyph ids are face-local: render on the same per-font-id
        // face the ids and advances came from.
        FT_Face face = zatex_face;
        if (rn->font_id < ZATEX_FACE_SLOTS && rn->font_id != 0 && zatex_faces[rn->font_id])
            face = zatex_faces[rn->font_id];
        double run_px = (double)font_px * (double)rn->size_units / 1000.0;
        if (run_px <= 0) continue;
        if (FT_Set_Pixel_Sizes(face, 0, (FT_UInt)(run_px + 0.5)) != 0) continue;
        double s_run = run_px / 1000.0;
        // Stretched runs (issue #354): ink AND pen scale about the run
        // origin by x_scale/1000 (zatex.h recipe); identity folds exact.
        double xs = (double)zatex_xscale[i] / 1000.0;
        double bx = (double)x + (double)rn->x * s;
        double baseline = (double)y_top + (double)rn->baseline_y * s;
        // Per-run paint (issue #365): ambient unless the run's own paint
        // differs; rules above already rode ambient.
        unsigned char pr = r, pg = g, pb = b, pa = a;
        if (zatex_has_color && zatex_colors[i]) {
            uint32_t c = zatex_colors[i];
            pr = (unsigned char)(c >> 24); pg = (unsigned char)((c >> 16) & 255);
            pb = (unsigned char)((c >> 8) & 255); pa = (unsigned char)(c & 255);
        }
        // Clip bounds hoisted to row/col ranges (drawn formulas are
        // small; the per-pixel check costs more than it saves).
        double acc = 0.0;
        for (uint32_t k = 0; k < rn->glyph_count; k++) {
            uint16_t gl = zatex_glyphs[rn->glyph_start + k];
            int32_t adv = zatex_adv_cache[rn->glyph_start + k];
            if (FT_Load_Glyph(face, (FT_UInt)gl, FT_LOAD_RENDER) != 0) {
                acc += adv;
                continue;
            }
            FT_Bitmap *bm = &face->glyph->bitmap;
            int dx = (int)(bx + acc * s_run * xs + 0.5);
            int dy = (int)(baseline - face->glyph->bitmap_top + 0.5);
            int c0 = 0, c1 = (int)bm->width, r0 = 0, r1 = (int)bm->rows;
            if (dx < g_clip_x0) c0 = (int)(g_clip_x0 - dx);
            if (dy < g_clip_y0) r0 = (int)(g_clip_y0 - dy);
            if (dx + c1 > g_clip_x1) c1 = (int)(g_clip_x1 - dx);
            if (dy + r1 > g_clip_y1) r1 = (int)(g_clip_y1 - dy);
            if (c0 < 0) c0 = 0;
            if (r0 < 0) r0 = 0;
            if (c1 > (int)bm->width) c1 = (int)bm->width;
            if (r1 > (int)bm->rows) r1 = (int)bm->rows;
            for (int row = r0; row < r1; row++) {
                for (int col = c0; col < c1; col++) {
                    unsigned char cov = bm->buffer[row * bm->pitch + col];
                    if (!cov) continue;
                    unsigned eff = (unsigned)cov * pa / 255;
                    blend_px(dx + col, dy + row, pr, pg, pb, (unsigned char)eff);
                }
            }
            acc += adv;
        }
    }
}

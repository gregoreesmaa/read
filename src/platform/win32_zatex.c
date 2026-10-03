// ZaTeX runtime math backend for the Windows Win32 port.
//
// Included by src/platform/win32.c — one TU, same discipline as
// macos.m including macos_zatex.m (AGENTS.md §7: this file plus its Zig
// seams count as plugin code; twin builds include win32_zatex_stub.c
// instead; same TU, same flags).
//
// Design mirrors macos_zatex.m: LoadLibrary only, never linked. The
// engine (zatex.dll, built from the pinned third_party/zatex submodule)
// lays out synchronously over caller-owned BSS buffers. Absent engine
// (or any layout failure) reports fallback and the reader renders the
// source literally.
//
// Host duties (differs from macOS only in the font stack):
// - Glyph identity + advances come from one cached GDI math face:
//   "STIX Two Math" when installed, else "Cambria Math" (stock since
//   Vista, present on CI runners), verified at resolve time by probing
//   U+2215 (infix fraction slash) via GetGlyphIndicesW — a face that
//   lacks it is skipped. Per-OS screenshot baselines absorb the raster
//   difference.
// - Advances are honest GDI ABC widths at the 100-unit face, so the
//   ETO_GLYPH_INDEX draw below (which uses the font's own advances)
//   lands ink exactly where layout put it.
// - Rule thickness is KaTeX parity 40/1000em for every kind (same
//   constant as macOS: explicit, not file truth, not NULL).
// - Variants, italic/kerning corrections, extents, ink bounds stay NULL
//   (deterministic engine fallbacks, same as macOS after the #380 diet).
// - Bytes pass through raw (no normalization tables in-ship; ASCII is
//   already NFC): the engine still reports typed Invalid with offset.
// - Draw is direct (no formula atlas v1): per-run ExtTextOutW with
//   ETO_GLYPH_INDEX at the run baseline, rules via fill_rgba.
//   Stretched runs (issue #354) scale x about the run origin via the
//   advanced graphics mode world transform. Headless screenshots are 1x
//   where macOS also draws direct, so shots stay comparable.
// - Caps negotiation (zatex_capabilities / _ex stride / x_scale / color
//   tails / typed latch) mirrors macos_zatex.m exactly.

#include <stdint.h>
#include <stdio.h>
#include <string.h>

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
// win32.c owns: utf8_to_wide, normalize_path, fill_rgba, g_draw_dc,
// g_memdc, g_force_bilevel (TEST_HOOKS).

typedef int32_t (__cdecl *ZatexLayoutFn)(const char *, size_t, BOOL, const ZatexMetrics *,
                                        ZatexRun *, size_t, ZatexRule *, size_t,
                                        uint16_t *, size_t, ZatexLayout *);
typedef int32_t (__cdecl *ZatexLayoutExFn)(const char *, size_t, BOOL, const ZatexMetrics *,
                                           void *, size_t, size_t, ZatexRule *, size_t,
                                           uint16_t *, size_t, ZatexLayout *);
typedef uint32_t (__cdecl *ZatexCapsFn)(void);
#define ZATEX_CAP_X_SCALE (1u << 0)
#define ZATEX_CAP_RUN_COLOR (1u << 1)
#define ZATEX_CAP_NEED_COUNTS (1u << 2)
#define ZATEX_CAP_ERR_CODE (1u << 3)

static HMODULE zatex_module = NULL;
static ZatexLayoutFn zatex_layout = NULL;
static ZatexLayoutExFn zatex_layout_ex = NULL;
static uint32_t zatex_engine_caps = 0;
static int zatex_has_caps = 0;
static int zatex_negotiated_ex = 0;
static int zatex_tried_load = 0;
static int zatex_missing_noticed = 0;

#define ZATEX_ADOPT(m, ok) do { \
    ZatexLayoutFn fn = (ZatexLayoutFn)GetProcAddress(m, "zatex_layout_utf8"); \
    ok = (fn != NULL); \
    if (ok) { \
        zatex_module = m; \
        zatex_layout = fn; \
        zatex_layout_ex = (ZatexLayoutExFn)GetProcAddress(m, "zatex_layout_utf8_ex"); \
        ZatexCapsFn cf = (ZatexCapsFn)GetProcAddress(m, "zatex_capabilities"); \
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

// Engine search order: %READ_ZATEX_LIB% (CI/test, absolute path from the
// pinned submodule build) → exe-relative zatex.dll (installed layout) →
// system search path. LoadLibrary only, never linked.
static void zatex_try_load(void) {
    if (zatex_tried_load) return;
    zatex_tried_load = 1;
#ifdef TEST_HOOKS
    {
        char td[2048] = { 0 };
        DWORD tn = GetEnvironmentVariableA("ZATEX_TEST_DYLIB", td, 2047);
        if (tn > 0 && tn < 2047 && td[0]) {
            WCHAR wtd[2048];
            int wn = utf8_to_wide(td, (int)strlen(td), wtd, 2047);
            if (wn > 0) {
                wtd[wn] = 0;
                HMODULE th = LoadLibraryW(wtd);
                if (th) {
                    int tok = 0;
                    ZATEX_ADOPT(th, tok);
                    if (!tok) FreeLibrary(th);
                    else return;
                }
            }
        }
    }
#endif
    {
        char env[2048] = { 0 };
        DWORD en = GetEnvironmentVariableA("READ_ZATEX_LIB", env, 2047);
        if (en > 0 && en < 2047 && env[0]) {
            WCHAR wenv[2048];
            int wn = utf8_to_wide(env, (int)strlen(env), wenv, 2047);
            if (wn > 0) {
                wenv[wn] = 0;
                HMODULE h = LoadLibraryW(wenv);
                if (h) {
                    int ok = 0;
                    ZATEX_ADOPT(h, ok);
                    if (!ok) FreeLibrary(h);
                    else return;
                }
            }
        }
    }
    {
        // NOTE: no exe-relative probe v1 — release packaging does not
        // install zatex.dll beside read.exe yet (see scripts/make_dist.sh);
        // CI sets %READ_ZATEX_LIB% and local installs use the system path
        // below. Revisit when per-OS bundling lands.
        HMODULE h = LoadLibraryW(L"zatex.dll");
        if (h) {
            int ok = 0;
            ZATEX_ADOPT(h, ok);
            if (!ok) FreeLibrary(h);
            else return;
        }
    }
}

// ---------------------------------------------------------------------------
// Metrics provider over one cached GDI math face.
// ---------------------------------------------------------------------------

#define ZATEX_FONT_PX 100

static WCHAR zatex_face_name[64] = { 0 };
static HFONT zatex_face_font = NULL;
static int zatex_face_px = 0;

// Measurement DC: process-lifetime screen DC (same class as the cached
// HFONT below — GDI objects held once, never churned per glyph).
static HDC zatex_measure_dc(void) {
    static HDC dc = NULL;
    if (!dc) dc = GetDC(NULL);
    return dc;
}

// Resolve the math face once: first family covering the U+2215 probe
// wins; the resolved name is cached so glyph ids, advances, and draw
// pixels can never disagree.
static int zatex_ensure_face(void) {
    if (zatex_face_name[0]) return 1;
    static const WCHAR *cands[] = { L"STIX Two Math", L"Cambria Math" };
    HDC dc = zatex_measure_dc();
    if (!dc) return 0;
    int found = 0;
    for (unsigned k = 0; k < sizeof(cands) / sizeof(cands[0]) && !found; k++) {
        HFONT f = CreateFontW(-ZATEX_FONT_PX, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                              DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                              CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, cands[k]);
        if (!f) continue;
        HFONT old = (HFONT)SelectObject(dc, f);
        WCHAR probe = (WCHAR)0x2215;
        WORD gi = 0;
        DWORD ng = GetGlyphIndicesW(dc, &probe, 1, &gi, GGI_MARK_NONEXISTING_GLYPHS);
        SelectObject(dc, old);
        DeleteObject(f);
        if (ng == 1 && gi != 0xFFFF) {
            wcsncpy_s(zatex_face_name, 64, cands[k], _TRUNCATE);
            found = 1;
        }
    }
    return found;
}

// Realized math font at px (one-entry cache; runs vary per formula).
static HFONT zatex_font_at(int px) {
    if (px < 1) px = 1;
    if (zatex_face_font && zatex_face_px == px) return zatex_face_font;
    if (zatex_face_font) { DeleteObject(zatex_face_font); zatex_face_font = NULL; }
    if (!zatex_ensure_face()) return NULL;
    zatex_face_font = CreateFontW(-px, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                                  DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                                  CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
                                  zatex_face_name);
    zatex_face_px = zatex_face_font ? px : 0;
    return zatex_face_font;
}

static uint16_t zatex_glyph_id(const void *ctx, uint16_t font, uint32_t cp) {
    (void)ctx;
    (void)font;
    if (!zatex_ensure_face()) return 0;
    if (cp > 0xFFFF) return 0; // astral math coverage arrives via the surrogate path below
    HFONT f = zatex_font_at(ZATEX_FONT_PX);
    if (!f) return 0;
    HDC dc = zatex_measure_dc();
    if (!dc) return 0;
    HFONT old = (HFONT)SelectObject(dc, f);
    uint16_t id = 0;
    if (cp < 0xD800 || (cp > 0xDFFF && cp <= 0xFFFF)) {
        WCHAR w = (WCHAR)cp;
        WORD gi = 0;
        if (GetGlyphIndicesW(dc, &w, 1, &gi, GGI_MARK_NONEXISTING_GLYPHS) == 1 && gi != 0xFFFF)
            id = gi;
    } else {
        // Surrogate pair: encode astral cp as UTF-16 and map both units.
        uint32_t v = cp - 0x10000;
        WCHAR w[2] = { (WCHAR)(0xD800 + (v >> 10)), (WCHAR)(0xDC00 + (v & 0x3FF)) };
        WORD gi[2] = { 0, 0 };
        if (GetGlyphIndicesW(dc, w, 2, gi, GGI_MARK_NONEXISTING_GLYPHS) == 2 &&
            gi[0] != 0xFFFF && gi[0] == gi[1])
            id = gi[0];
    }
    SelectObject(dc, old);
    return id;
}

// Advance in thousandths of an em (engine unit), at the 100px face:
// ABC widths in px at 100px read directly as thousandths.
static int32_t zatex_advance(const void *ctx, uint16_t font, uint16_t glyph) {
    (void)ctx;
    (void)font;
    if (glyph == 0) return 500;
    HFONT f = zatex_font_at(ZATEX_FONT_PX);
    if (!f) return 500;
    HDC dc = zatex_measure_dc();
    if (!dc) return 500;
    HFONT old = (HFONT)SelectObject(dc, f);
    int32_t units = 500;
    WORD gi = glyph;
    ABCFLOAT abc;
    if (GetCharABCWidthsFloatW(dc, gi, gi, &abc)) {
        float adv = abc.abcfA + abc.abcfB + abc.abcfC;
        int32_t u = (int32_t)(adv * 10.0f + 0.5f);
        // Zero-width glyphs (combining accents) report 0 like the file.
        units = u < 0 ? 500 : u;
    }
    SelectObject(dc, old);
    return units;
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
    if (!zatex_layout || !zatex_ensure_face()) return ZATEX_UNAVAILABLE;
    // Bytes pass through raw (no normalization tables in-ship; ASCII is
    // already NFC): the engine still reports typed Invalid with offset
    // instead of a silent drop.
    memset(out, 0, sizeof(*out));
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
    zatex_err_key = zatex_key_of(tex, tex_len, display);
    zatex_err_offset = out->err_offset;
    zatex_err_code = out->err_code;
    if (rc == 1) return ZATEX_UNSUPPORTED;
    if (rc == 6 || rc == 7) {
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

static uint64_t zatex_atlas_hits = 0, zatex_atlas_misses = 0;
#ifdef TEST_HOOKS
void platform_math_atlas_stats(unsigned long long *hits, unsigned long long *misses) {
    // Direct-draw backend v1: no formula atlas, nothing to count.
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

void zatex_drop_math_rasters(void) {}

int platform_math_size(const char *tex, int tex_len, int display, float font_px,
                       float *out_w, float *out_above, float *out_below) {
    float w = 0, above = 0, below = 0;
    int st = ZATEX_FALLBACK;
    if (tex && tex_len > 0 && font_px > 0) {
        ZatexLayout lo;
        st = zatex_layout_once(tex, tex_len, display, &lo);
        if (st == ZATEX_UNAVAILABLE && !zatex_missing_noticed) {
            zatex_missing_noticed = 1;
            fprintf(stderr, "read: zatex.dll unavailable — math renders as source text (see docs/engine.md)\n");
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

// Draw a laid-out formula: rules as filled rects, runs via ExtTextOutW
// with ETO_GLYPH_INDEX at the run baseline (engine glyph indices in the
// resolved math face). y_top is the formula ink top from the same dims
// platform_math_size reported. No-op outside a draw pass or when layout
// fails (the caller falls back literally, never reaching here then).
void platform_draw_math(const char *tex, int tex_len, int display, float font_px,
                        float x, float y_top,
                        unsigned char r, unsigned char g, unsigned char b, unsigned char a) {
    if (!g_draw_dc || !tex || tex_len <= 0 || font_px <= 0) return;
    ZatexLayout lo;
    if (zatex_layout_once(tex, tex_len, display, &lo) != ZATEX_OK) return;
    HDC dc = g_draw_dc;
    double s = (double)font_px / 1000.0;
    // Rules first (ambient paint; macos_zatex.m rule arm, same snap).
    for (uint32_t i = 0; i < lo.nrules; i++) {
        ZatexRule *rl = &zatex_rules[i];
        float rx = (float)(x + rl->x * s), ry = (float)(y_top + rl->y * s);
        float rw = (float)(rl->w * s), rh = (float)(rl->h * s);
        float y0 = floorf(ry + 0.5f), y1 = floorf(ry + rh + 0.5f);
        if (y1 <= y0) y1 = y0 + 1.0f;
        fill_rgba(rx, y0, rw, y1 - y0, r, g, b, a);
    }
    int prev_bk = SetBkMode(dc, TRANSPARENT);
    COLORREF prev_c = SetTextColor(dc, RGB(r, g, b));
    // Runs: one ExtTextOutW per run at its baseline origin. GDI advances
    // are the font's own — identical to the ABC widths layout used — so
    // ink lands where layout put it.
    for (uint32_t i = 0; i < lo.nruns; i++) {
        ZatexRun *rn = &zatex_runs[i];
        if (rn->glyph_count == 0 || rn->glyph_start + rn->glyph_count > ZATEX_GLYPHS_CAP) continue;
        double run_px = (double)font_px * (double)rn->size_units / 1000.0;
        if (run_px <= 0) continue;
        HFONT f = zatex_font_at((int)(run_px + 0.5));
        if (!f) continue;
        if (zatex_has_color && zatex_colors[i]) {
            // Per-run paint (issue #365): GDI text has no per-call alpha,
            // so tinted-but-translucent paints draw opaque (documented v1
            // gap; body text shares it).
            uint32_t c = zatex_colors[i];
            SetTextColor(dc, RGB((unsigned char)(c >> 24),
                                 (unsigned char)((c >> 16) & 255),
                                 (unsigned char)((c >> 8) & 255)));
        }
        HFONT old = (HFONT)SelectObject(dc, f);
        // View coords are non-negative in the visible band GDI clips to.
        int ox = (int)((double)x + (double)rn->x * s + 0.5);
        int oy = (int)((double)y_top + (double)rn->baseline_y * s + 0.5);
        double xs = (double)zatex_xscale[i] / 1000.0;
        if (xs != 1.0) {
            // Stretched runs (issue #354): scale x about the run origin
            // (zatex.h recipe), restoring the transform after.
            int gm = SetGraphicsMode(dc, GM_ADVANCED);
            if (gm) {
                // Fixed point at the run origin: x' = xs*x + eDx pins
                // x' = ox when x = ox, so eDx = ox*(1-xs).
                XFORM xf;
                xf.eM11 = (FLOAT)xs; xf.eM12 = 0.0f;
                xf.eM21 = 0.0f; xf.eM22 = 1.0f;
                xf.eDx = (FLOAT)((double)ox * (1.0 - xs));
                xf.eDy = 0.0f;
                SetWorldTransform(dc, &xf);
            }
        }
        {
            uint32_t n = rn->glyph_count;
            static WCHAR gbuf[4096];
            for (uint32_t k = 0; k < n; k++) gbuf[k] = (WCHAR)zatex_glyphs[rn->glyph_start + k];
            ExtTextOutW(dc, ox, oy, ETO_GLYPH_INDEX, NULL, gbuf, n, NULL);
        }
        if (xs != 1.0) {
            ModifyWorldTransform(dc, NULL, MWT_IDENTITY);
            SetGraphicsMode(dc, GM_COMPATIBLE);
        }
        if (zatex_has_color && zatex_colors[i]) SetTextColor(dc, RGB(r, g, b));
        SelectObject(dc, old);
    }
    SetTextColor(dc, prev_c);
    SetBkMode(dc, prev_bk);
}

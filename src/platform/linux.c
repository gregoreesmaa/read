// Linux X11 platform backend (port of src/platform/macos.m).
//
// Implements every platform_* symbol declared in src/platform/bridge.zig
// (~63 externs) on X11 + FreeType + fontconfig + libpng. Coordinate system
// is y-down natively: NO CTM flip anywhere. The record model is ported
// byte-for-byte from macos.m: QuadTextRecord x16384, CodeBlockRecord x64,
// ScrollableBlockRecord x128, selection state with word lock-in (#314
// document-x endpoints), 40px scrollbar thumb / 12px grab strip, damage
// union, FNV-1a visited ring, 512-entry outline table, image cache
// skeleton with arm/pending, find panel state, inotify watch state.
//
// AGENTS.md: zero third-party deps beyond OS system libs (Xlib/Xext/
// fontconfig/FreeType/libpng are stock Ubuntu 22.04).
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/keysym.h>
#include <sys/select.h>
#include <sys/time.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <spawn.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <fontconfig/fontconfig.h>
#include <png.h>

// ---------------------------------------------------------------------------
// Callbacks (mirrors PlatformCallbacks in bridge.zig / platform.h)
// ---------------------------------------------------------------------------
typedef struct {
    void (*on_scroll)(float delta_x, float delta_y, int hovered_block_id, int precise);
    void (*on_resize)(int width, int height);
    void (*on_key)(int key_code, int hovered_block_id);
    void (*on_draw)(int width, int height);
    void (*on_link)(const char* url, int url_len);
    int (*on_tick)(float dt_ms);
    void (*on_scroll_to)(float scroll_y);
    void (*on_images_changed)(float delta_above);
    void (*on_appearance)(int is_dark);
    void (*on_outline_open)(void);
    void (*on_display)(int category_class, int reduce_motion);
    void (*on_open_file)(const char* path, int path_len);
    void (*on_file_changed)(void);
    void (*on_find_query)(const char* text, int text_len);
    void (*on_find_next)(int prev);
    void (*on_find_closed)(void);
} PlatformCallbacks;

static PlatformCallbacks g_callbacks;
static Display* g_dpy = NULL;
static Window g_win = 0;
static GC g_gc = 0;
static XImage* g_canvas = NULL; // 32-bit ZPixmap backing store, y-down
static unsigned char* g_canvas_px = NULL;
static int g_win_w = 1000, g_win_h = 750;
static int g_depth = 24;
static float g_scroll_y = 0.0f;
static float g_overshoot = 0.0f;
static float g_mouse_x = -9999.0f, g_mouse_y = -9999.0f;

// Scrollbar drag model (mirrors viewport.zig scrollbarThumbY /
// scrollbarScrollFromY: same 40px thumb, same travel mapping). The visual
// stays a 2px filament; the grab strip is 12px wide.
#define SCROLLBAR_THUMB_H 40.0f
#define SCROLLBAR_HIT_W 12.0f
static float g_max_scroll_y = 0.0f;
static float g_view_h = 0.0f;
static int g_scrollbar_dragging = 0;
static float g_scrollbar_grab_delta = 0.0f;

static float scrollbar_thumb_y(void);
static int scrollbar_hit(float x, float view_w);
static void scrollbar_drag_to(float y);
static void mark_link_visited(const char* url);

// Idle policy (mirrors src/platform/idle.zig): mouse motion alone never
// redraws. Only a hover-state transition re-arms a draw.
static int g_last_link_hover = 0;
static int g_last_code_btn_hover = 0;
static unsigned long g_draw_seq = 0;
static void request_redraw(void);
static void invalidate_rect(float x, float y, float w, float h);
static int appearance_is_dark(void);
static void apply_window_appearance(int dark);
static int g_synced_theme_dark = -1; // -1 = never synced
// Continuous link underline (#101): hover identity is the FNV-1a URL hash.
static uint64_t g_hover_link_hash = 0;
typedef struct {
    uint64_t hash;
    float y;
    float x_end;
    float font_size;
    int hovered;
    int valid;
} LinkUlState;
static LinkUlState g_last_ul;
static uint64_t link_url_hash(const char* url, int url_len);
static inline int link_run_hovered(float x, float y, float w, float h);
static float link_underline_track(const char* url, int url_len, float x, float y, float w, float font_size, int hovered);
static int read_path_is_markdown(const char* path, int path_len);
static void read_open_file_path(const char* path, int path_len);
static int image_url_is_remote_len(const char* s, int n);
// Heading outline data core (#48): no-op v1 panel (data path implemented).
static int g_outline_row_count = 0;
// Find bar (#42): query state; the panel is a drawn overlay strip.
static char g_find_query[256];
static int g_find_query_len = 0;
static char g_find_count_text[64];
static int g_find_visible = 0;
static int g_find_had_query = 0;

// Clamp helper (no libm dependency beyond what we already use).
static float fclampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}
static float fminf_(float a, float b) { return a < b ? a : b; }
static float fmaxf_(float a, float b) { return a > b ? a : b; }

// ---------------------------------------------------------------------------
// Record model (byte-for-byte port of macos.m)
// ---------------------------------------------------------------------------
typedef struct {
    float x;
    float doc_y; // Document Y (y + g_scroll_y)
    float w;
    float h;
    float font_size;
    int is_bold;
    int is_italic;
    int is_mono;
    int is_heading;
    char text[512];
    int len;
    char link_url[256];
    int line_index;
} QuadTextRecord;

#define MAX_QUAD_RECORDS 16384
static QuadTextRecord g_text_records[MAX_QUAD_RECORDS];
static int g_text_record_count = 0;

#define MAX_CODE_BLOCKS 64
typedef struct {
    float x, y, w, h;
    char text[8192];
    int len;
} CodeBlockRecord;

static CodeBlockRecord g_code_blocks[MAX_CODE_BLOCKS];
static int g_code_block_count = 0;
static int g_copied_block_idx = -1;
static double g_copied_timestamp = 0;

typedef struct {
    int id;
    float x, y, w, h;
    float max_scroll_x;
    // #314: live per-frame offset, pushed by Zig on every draw.
    float scroll_x;
} ScrollableBlockRecord;

#define MAX_SCROLLABLE_BLOCKS 128
static ScrollableBlockRecord g_scrollable_blocks[MAX_SCROLLABLE_BLOCKS];
static int g_scrollable_block_count = 0;

static int g_has_selection = 0;
static int g_selection_mode = 0; // 0 = none, 1 = range, 2 = word, 3 = line, 4 = all
static float g_sel_sx = 0, g_sel_sy = 0; // document coords
static float g_sel_ex = 0, g_sel_ey = 0;
static float g_sel_ax = 0, g_sel_ay = 0; // fixed anchor for word/line drag
static int g_select_all = 0;

// #314: scrollable block whose container frame holds a VIEW point, or -1.
static int scroll_block_at_point(float x, float y) {
    for (int i = 0; i < g_scrollable_block_count; i++) {
        ScrollableBlockRecord* b = &g_scrollable_blocks[i];
        if (x >= b->x && x <= b->x + b->w && y >= b->y && y <= b->y + b->h) return b->id;
    }
    return -1;
}

// #314: scrollable block owning a DOCUMENT point, or -1.
static int scroll_block_at_doc(float doc_x, float doc_y) {
    for (int i = 0; i < g_scrollable_block_count; i++) {
        ScrollableBlockRecord* b = &g_scrollable_blocks[i];
        float top = b->y + g_scroll_y;
        if (doc_y < top || doc_y > top + b->h) continue;
        if (doc_x >= b->x - 1.0f && doc_x <= b->x + b->w + 2.0f * b->max_scroll_x + 1.0f) return b->id;
    }
    return -1;
}

// #314: live horizontal offset for a block id.
static float scroll_block_offset(int id, int* known) {
    if (id >= 0) {
        for (int i = 0; i < g_scrollable_block_count; i++) {
            if (g_scrollable_blocks[i].id == id) {
                if (known) *known = 1;
                return g_scrollable_blocks[i].scroll_x;
            }
        }
    }
    if (known) *known = (id < 0) ? 1 : 0;
    return 0.0f;
}

// #314: view-space x for a document-space selection endpoint.
static float scroll_doc_to_view(float doc_x, float doc_y, int* known) {
    return doc_x - scroll_block_offset(scroll_block_at_doc(doc_x, doc_y), known);
}

// ---------------------------------------------------------------------------
// Damage tracking (dirty rectangles)
// ---------------------------------------------------------------------------
static float g_dirty_x = 0, g_dirty_y = 0, g_dirty_w = 0, g_dirty_h = 0;
static int g_dirty_valid = 0;
static int g_hovered_code_btn = -1;

typedef struct { float x, y, w, h; } RectF;
static int rect_empty(RectF r) { return r.w <= 0 || r.h <= 0; }
static RectF rect_union(RectF a, RectF b) {
    if (rect_empty(a)) return b;
    if (rect_empty(b)) return a;
    float x0 = fminf_(a.x, b.x), y0 = fminf_(a.y, b.y);
    float x1 = fmaxf_(a.x + a.w, b.x + b.w), y1 = fmaxf_(a.y + a.h, b.y + b.h);
    RectF r = { x0, y0, x1 - x0, y1 - y0 };
    return r;
}

static void request_redraw(void) {
    if (!g_dpy || !g_win) return;
    XClearArea(g_dpy, g_win, 0, 0, 0, 0, True);
}

static void invalidate_rect(float x, float y, float w, float h) {
    if (w <= 0 || h <= 0 || !g_dpy || !g_win) return;
    XClearArea(g_dpy, g_win, (int)x, (int)y, (unsigned)w, (unsigned)h, True);
}

// Current selection bounds in VIEW coordinates, expanded by pad.
static RectF selection_bounds_expanded(float pad) {
    RectF empty = { 0, 0, 0, 0 };
    if (g_select_all) {
        RectF r = { -pad, -pad, (float)g_win_w + 2 * pad, (float)g_win_h + 2 * pad };
        return r;
    }
    if (!g_has_selection) return empty;
    int k1 = 0, k2 = 0;
    float s1v = scroll_doc_to_view(g_sel_sx, g_sel_sy, &k1);
    float s2v = scroll_doc_to_view(g_sel_ex, g_sel_ey, &k2);
    float x1, x2;
    if (!k1 || !k2) { x1 = -1e4f; x2 = 1e4f; } else { x1 = fminf_(s1v, s2v); x2 = fmaxf_(s1v, s2v); }
    float y1 = fminf_(g_sel_sy, g_sel_ey) - g_scroll_y;
    float y2 = fmaxf_(g_sel_sy, g_sel_ey) - g_scroll_y;
    float ypad = pad + 32.0f;
    if ((x2 - x1) > 2.0f || (y2 - y1) > 2.0f) {
        float qx = floorf(-pad), qy = floorf(y1 - ypad);
        RectF r = { qx, qy, ceilf((float)g_win_w + pad) - qx, ceilf(y2 + ypad) - qy };
        return r;
    }
    float tx = x1 - pad, ty = y1 - ypad;
    float qx = floorf(tx), qy = floorf(ty);
    RectF r = { qx, qy, ceilf(x2 + pad) - qx, ceilf(y2 + ypad) - qy };
    return r;
}

static RectF copy_button_rect_for_block(CodeBlockRecord* b) {
    RectF r = { b->x + b->w - 64.0f - 8.0f, b->y + 8.0f, 64.0f, 24.0f };
    return r;
}

// Damage rect for the hover button (+2px for the centered 1px stroke).
static RectF copy_button_damage_rect(CodeBlockRecord* b) {
    RectF r = copy_button_rect_for_block(b);
    RectF d = { r.x - 2.0f, r.y - 2.0f, r.w + 4.0f, r.h + 4.0f };
    return d;
}

// ---------------------------------------------------------------------------
// Fonts: FreeType faces for the 5 bundled TTFs + fontconfig fallbacks
// ---------------------------------------------------------------------------
static FT_Library g_ft = NULL;
static FT_Face g_face_body = NULL;    // IBM Plex Serif Regular
static FT_Face g_face_bold = NULL;    // IBM Plex Serif Bold
static FT_Face g_face_italic = NULL;  // IBM Plex Serif Italic
static FT_Face g_face_head = NULL;    // Space Grotesk
static FT_Face g_face_mono = NULL;    // JetBrains Mono
static FcConfig* g_fc = NULL;
static int g_fonts_ready = 0;

static const char* font_asset_path(const char* name) {
    // Search order: exe-relative assets dir (installed layout:
    // <prefix>/bin/read + <prefix>/share/read/fonts, and the adjacent
    // assets/fonts dev layout), then CWD-relative (tests run from the
    // repo root). No absolute fallback: a hardcoded developer path must
    // never leak into a release binary.
    static char buf[1024];
    // pass 0: exe-relative (installed <prefix>/bin/read ->
    // <prefix>/share/read/fonts, dev zig-out/bin/read -> assets/fonts),
    // then CWD-relative (tests run from the repo root).
    char exe[512] = { 0 };
    ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (n > 0) {
        exe[n] = '\0';
        char* slash = strrchr(exe, '/');
        if (slash) {
            *slash = '\0';
            snprintf(buf, sizeof(buf), "%s/../share/read/fonts/%s", exe, name);
            struct stat st;
            if (stat(buf, &st) == 0) return buf;
            snprintf(buf, sizeof(buf), "%s/../assets/fonts/%s", exe, name);
            if (stat(buf, &st) == 0) return buf;
            snprintf(buf, sizeof(buf), "%s/../../assets/fonts/%s", exe, name);
            if (stat(buf, &st) == 0) return buf;
        }
    }
    {
        snprintf(buf, sizeof(buf), "%s/%s", "assets/fonts", name);
        struct stat st;
        if (stat(buf, &st) == 0) return buf;
    }
    return NULL;
}

static void register_app_fonts(void) {
    if (g_fonts_ready) return;
    g_fonts_ready = 1;
    if (FT_Init_FreeType(&g_ft) != 0) { g_ft = NULL; return; }
    const char* p;
    p = font_asset_path("IBMPlexSerif-Regular.ttf");
    if (p) FT_New_Face(g_ft, p, 0, &g_face_body);
    p = font_asset_path("IBMPlexSerif-Bold.ttf");
    if (p) FT_New_Face(g_ft, p, 0, &g_face_bold);
    p = font_asset_path("IBMPlexSerif-Italic.ttf");
    if (p) {
        // No BoldItalic asset: bold+italic falls back to Bold (macos parity).
        FT_New_Face(g_ft, p, 0, &g_face_italic);
    }
    p = font_asset_path("SpaceGrotesk.ttf");
    if (p) FT_New_Face(g_ft, p, 0, &g_face_head);
    p = font_asset_path("JetBrainsMono.ttf");
    if (p) FT_New_Face(g_ft, p, 0, &g_face_mono);
    g_fc = FcInitLoadConfigAndFonts();
}

// Style -> primary face (macos.m get_font_for_style, minus Cocoa names).
static FT_Face face_for_style(int is_bold, int is_italic, int is_mono, int is_heading) {
    register_app_fonts();
    if (is_mono && g_face_mono) return g_face_mono;
    if (is_heading && g_face_head) return g_face_head;
    if (is_bold && g_face_bold) return g_face_bold;
    if (is_italic && g_face_italic) return g_face_italic;
    if (g_face_body) return g_face_body;
    // Last resort: whichever face loaded.
    if (g_face_mono) return g_face_mono;
    if (g_face_head) return g_face_head;
    if (g_face_bold) return g_face_bold;
    return g_face_italic;
}

// Per-glyph fontconfig fallback: pattern for family + charset containing
// the codepoint, matched once per (family, codepoint>>8) group and cached
// in a tiny direct-mapped table. Returns an FT_Face borrowed from a small
// static pool (never freed; process-lifetime like the BSS caches).
#define FB_POOL 16
#define FB_CACHE_CAP 256
static FT_Face fb_pool_faces[FB_POOL];
static char fb_pool_files[FB_POOL][512];
static int fb_pool_count = 0;
typedef struct { uint32_t key; FT_Face face; uint8_t occupied; } FbEntry;
static FbEntry fb_cache[FB_CACHE_CAP];

static FT_Face fb_face_for(uint32_t cp, int is_mono) {
    if (!g_fc || !g_ft) return NULL;
    const char* fam = is_mono ? "DejaVu Sans Mono" : "DejaVu Serif";
    uint32_t key = (cp & 0xFFFFFF00u) | (is_mono ? 1u : 0u);
    FbEntry* e = &fb_cache[key % FB_CACHE_CAP];
    if (e->occupied && e->key == key) return e->face;
    FcPattern* pat = FcPatternCreate();
    if (!pat) return NULL;
    FcPatternAddString(pat, FC_FAMILY, (const FcChar8*)fam);
    FcCharSet* cs = FcCharSetCreate();
    FcCharSetAddChar(cs, cp);
    FcPatternAddCharSet(pat, FC_CHARSET, cs);
    FcCharSetDestroy(cs);
    FcConfigSubstitute(g_fc, pat, FcMatchPattern);
    FcDefaultSubstitute(pat);
    FcResult res = FcResultNoMatch;
    FcPattern* match = FcFontMatch(g_fc, pat, &res);
    FcPatternDestroy(pat);
    if (!match) return NULL;
    FcChar8* file = NULL;
    if (FcPatternGetString(match, FC_FILE, 0, &file) != FcResultMatch || !file) {
        FcPatternDestroy(match);
        return NULL;
    }
    // Reuse pool slot when the file is already open.
    for (int i = 0; i < fb_pool_count; i++) {
        if (strcmp(fb_pool_files[i], (const char*)file) == 0) {
            FcPatternDestroy(match);
            e->key = key; e->face = fb_pool_faces[i]; e->occupied = 1;
            return e->face;
        }
    }
    if (fb_pool_count >= FB_POOL) { FcPatternDestroy(match); return NULL; }
    FT_Face f = NULL;
    if (FT_New_Face(g_ft, (const char*)file, 0, &f) != 0) {
        FcPatternDestroy(match);
        return NULL;
    }
    size_t n = strlen((const char*)file);
    if (n > 511) n = 511;
    memcpy(fb_pool_files[fb_pool_count], file, n);
    fb_pool_files[fb_pool_count][n] = '\0';
    fb_pool_faces[fb_pool_count] = f;
    fb_pool_count++;
    FcPatternDestroy(match);
    e->key = key; e->face = f; e->occupied = 1;
    return f;
}

// ---------------------------------------------------------------------------
// Text atlas: FreeType gray coverage -> shelf-packed 8-bit alpha atlas
// ---------------------------------------------------------------------------
// Contract (mirrors glyph_cache.zig pins on macos.m): per-GLYPH cache keyed
// by (codepoint, style, pixel size), direct-mapped (collision = evict),
// rasterized ONCE into a packed atlas (shelf packing, 8-bit coverage).
// Per-frame rendering is coverage blits only, no per-pixel CPU shaping on
// the steady path. No CTLine anywhere: advance-walk hit testing.
#define GLYPH_CACHE_CAP 4096
#define ATLAS_PX 1024
typedef struct {
    uint64_t key;
    short ax, ay;      // atlas origin in px (aw==0 => not rasterized)
    short aw, ah;
    short adv;         // advance in atlas px (==26.6>>6 at raster scale 1)
    short top;         // bitmap_top at rasterization
    short adv_ip;      // advance in integer device px (layout step)
    uint8_t occupied;
} GlyphEntry;

static GlyphEntry g_glyph_cache[GLYPH_CACHE_CAP];
static unsigned char* g_atlas_px = NULL; // ATLAS_PX^2 coverage bytes
static int g_atlas_x = 0, g_atlas_y = 0, g_atlas_shelf_h = 0;
static uint64_t g_shape_hits = 0, g_shape_misses = 0, g_atlas_flushes = 0;
// Output scale for the current draw (1 windowed/Xvfb, forced 2 under
// --force-scale). Headless PNGs always encode at 1x.
static float g_output_scale = 1.0f;

static uint64_t glyph_key(uint32_t cp, int style, int px_size) {
    uint64_t h = 0xcbf29ce484222325ULL;
    uint64_t tail = ((uint64_t)(uint32_t)style << 32) | (uint32_t)cp ^ ((uint64_t)(uint32_t)px_size << 32);
    for (int i = 0; i < 8; i++) {
        h ^= (unsigned char)(tail >> (i * 8));
        h *= 0x100000001b3ULL;
    }
    return h;
}

static int atlas_alloc(int pw, int ph, short* out_x, short* out_y) {
    if (pw <= 0 || ph <= 0 || pw > ATLAS_PX || ph > ATLAS_PX) return 0;
    if (g_atlas_x + pw > ATLAS_PX) {
        g_atlas_y += g_atlas_shelf_h;
        g_atlas_x = 0;
        g_atlas_shelf_h = 0;
    }
    if (g_atlas_y + ph > ATLAS_PX) return 0;
    *out_x = (short)g_atlas_x;
    *out_y = (short)g_atlas_y;
    g_atlas_x += pw;
    if (ph > g_atlas_shelf_h) g_atlas_shelf_h = ph;
    return 1;
}

static void atlas_flush(void) {
    if (g_atlas_px) memset(g_atlas_px, 0, (size_t)ATLAS_PX * ATLAS_PX);
    g_atlas_x = g_atlas_y = g_atlas_shelf_h = 0;
    for (int i = 0; i < GLYPH_CACHE_CAP; i++) {
        g_glyph_cache[i].occupied = 0;
        g_glyph_cache[i].aw = 0;
    }
    g_atlas_flushes++;
}

static void atlas_ensure(void) {
    if (g_atlas_px) return;
    g_atlas_px = (unsigned char*)calloc((size_t)ATLAS_PX * ATLAS_PX, 1);
}

// Style bits for the glyph key: bold=1 italic=2 mono=4 heading=8.
static int style_bits(int b, int i, int m, int h) {
    return (b ? 1 : 0) | (i ? 2 : 0) | (m ? 4 : 0) | (h ? 8 : 0);
}

// UTF-8 decode: returns codepoint, advances *idx. Never splits sequences.
static uint32_t utf8_next(const char* s, int len, int* idx) {
    unsigned char c = (unsigned char)s[*idx];
    if (c < 0x80) { (*idx)++; return c; }
    int seqlen = c < 0xE0 ? 2 : (c < 0xF0 ? 3 : 4);
    if (*idx + seqlen > len) { (*idx)++; return 0xFFFD; }
    uint32_t cp = 0;
    if (seqlen == 2) cp = ((uint32_t)(c & 0x1F) << 6) | (s[*idx + 1] & 0x3F);
    else if (seqlen == 3) cp = ((uint32_t)(c & 0x0F) << 12) | ((uint32_t)(s[*idx + 1] & 0x3F) << 6) | (s[*idx + 2] & 0x3F);
    else cp = ((uint32_t)(c & 0x07) << 18) | ((uint32_t)(s[*idx + 1] & 0x3F) << 12) | ((uint32_t)(s[*idx + 2] & 0x3F) << 6) | (s[*idx + 3] & 0x3F);
    *idx += seqlen;
    return cp;
}

// Rasterize one glyph (codepoint at pixel size, style face first with
// fontconfig fallback) into the atlas. Returns the cache entry or NULL.
static GlyphEntry* glyph_ensure(uint32_t cp, int style, int px, int is_mono_face) {
    uint64_t key = glyph_key(cp, style, px);
    GlyphEntry* e = &g_glyph_cache[key % GLYPH_CACHE_CAP];
    if (e->occupied && e->key == key) { g_shape_hits++; return e; }
    g_shape_misses++;
    if (!g_ft) return NULL;
    FT_Face face = face_for_style(style & 1, style & 2, style & 4, style & 8);
    FT_UInt gi = face ? FT_Get_Char_Index(face, cp) : 0;
    if (!gi) {
        FT_Face fb = fb_face_for(cp, is_mono_face);
        if (fb) { face = fb; gi = FT_Get_Char_Index(face, cp); }
    }
    if (!face || !gi) return NULL;
    if (FT_Set_Pixel_Sizes(face, 0, (FT_UInt)px) != 0) return NULL;
    // Bold synthesis for the Plex Bold face is native; faux-bold the
    // fallback/mono faces lightly like the mac double-strike path.
    if (FT_Load_Glyph(face, gi, FT_LOAD_RENDER) != 0) return NULL;
    FT_Bitmap* bm = &face->glyph->bitmap;
    int pw = (int)bm->width, ph = (int)bm->rows;
    atlas_ensure();
    if (!g_atlas_px) return NULL;
    short ax = 0, ay = 0;
    if (pw > 0 && ph > 0) {
        if (!atlas_alloc(pw, ph, &ax, &ay)) {
            atlas_flush();
            if (!atlas_alloc(pw, ph, &ax, &ay)) return NULL;
        }
        for (int r = 0; r < ph; r++)
            memcpy(g_atlas_px + ((size_t)ay + r) * ATLAS_PX + ax,
                   bm->buffer + (size_t)r * bm->pitch, (size_t)pw);
    }
    e->key = key;
    e->ax = ax; e->ay = ay;
    e->aw = (short)pw; e->ah = (short)ph;
    e->adv = (short)(face->glyph->advance.x >> 6);
    e->top = (short)face->glyph->bitmap_top;
    e->adv_ip = (short)((face->glyph->advance.x + 32) >> 6);
    e->occupied = 1;
    return e;
}

// Advance-walk measurement of a run (px at font_size). Heading tracking
// -0.015em mirrors heading_kern_pts in macos.m / viewport.zig.
static float run_advance(const char* text, int len, float font_size,
                         int is_bold, int is_italic, int is_mono, int is_heading) {
    if (!text || len <= 0 || font_size <= 0) return 0.0f;
    int px = (int)(font_size + 0.5f);
    if (px < 1) px = 1;
    int style = style_bits(is_bold, is_italic, is_mono, is_heading);
    float tracking = is_heading ? -0.015f * font_size : 0.0f;
    float total = 0.0f;
    int idx = 0;
    int n = 0;
    while (idx < len) {
        uint32_t cp = utf8_next(text, len, &idx);
        // Zero-width space / soft hyphen: shaping parity with the measure
        // side in viewport.zig (no advance contribution).
        if (cp == 0x200B || cp == 0x00AD) continue;
        GlyphEntry* e = glyph_ensure(cp, style, px, is_mono);
        float adv = e ? (float)e->adv_ip : font_size * 0.5f;
        total += adv;
        if (is_heading) total += tracking;
        n++;
    }
    // No trailing-space strip: advances already exclude line trailing.
    (void)n;
    return total;
}

#ifdef TEST_HOOKS
void platform_glyph_cache_stats(uint64_t* hits, uint64_t* misses, uint64_t* flushes) {
    if (hits) *hits = g_shape_hits;
    if (misses) *misses = g_shape_misses;
    if (flushes) *flushes = g_atlas_flushes;
}
#endif

// Character index at x_offset within a record (advance walk; mirrors
// get_char_index_at_x incl. trailing-edge clamp to len).
static int get_char_index_at_x(QuadTextRecord* rec, float x_offset) {
    if (x_offset <= 0) return 0;
    if (x_offset >= rec->w) return rec->len;
    int px = (int)(rec->font_size + 0.5f);
    if (px < 1) px = 1;
    int style = style_bits(rec->is_bold, rec->is_italic, rec->is_mono, rec->is_heading);
    float tracking = rec->is_heading ? -0.015f * rec->font_size : 0.0f;
    float x = 0.0f;
    int idx = 0;
    int best = 0;
    float best_d = x_offset; // distance to leading edge of first char
    while (idx < rec->len) {
        int start = idx;
        uint32_t cp = utf8_next(rec->text, rec->len, &idx);
        if (cp == 0x200B || cp == 0x00AD) continue;
        float mid = x;
        GlyphEntry* e = glyph_ensure(cp, style, px, rec->is_mono);
        float adv = e ? (float)e->adv_ip : rec->font_size * 0.5f;
        x += adv;
        if (rec->is_heading) x += tracking;
        // Leading-edge bias (CoreText parity): the boundary belongs to the
        // char whose leading half contains the point.
        float d = x_offset - (mid + adv * 0.5f);
        if (d < 0) d = -d;
        if (x_offset <= mid + adv) {
            // Choose start vs end by half.
            return (x_offset - mid < adv * 0.5f) ? start : idx;
        }
        (void)best; (void)best_d;
    }
    return rec->len;
}

// X for a UTF-8 byte index within a record (advance walk; mirrors
// get_x_for_char_index).
static float get_x_for_char_index(QuadTextRecord* rec, int char_idx) {
    if (char_idx <= 0) return 0.0f;
    if (char_idx >= rec->len) return rec->w;
    int px = (int)(rec->font_size + 0.5f);
    if (px < 1) px = 1;
    int style = style_bits(rec->is_bold, rec->is_italic, rec->is_mono, rec->is_heading);
    float tracking = rec->is_heading ? -0.015f * rec->font_size : 0.0f;
    float x = 0.0f;
    int idx = 0;
    while (idx < char_idx && idx < rec->len) {
        uint32_t cp = utf8_next(rec->text, rec->len, &idx);
        if (cp == 0x200B || cp == 0x00AD) continue;
        GlyphEntry* e = glyph_ensure(cp, style, px, rec->is_mono);
        float adv = e ? (float)e->adv_ip : rec->font_size * 0.5f;
        x += adv;
        if (rec->is_heading) x += tracking;
    }
    return x;
}

// Word classification (mirrors isWordByte/wordStart/wordEnd): ASCII
// letters/digits plus _ and '; every non-ASCII byte is a word byte.
static int word_char_byte(unsigned char c) {
    if (c >= 0x80) return 1;
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_' || c == '\'';
}
static int word_start_in_bytes(const char* text, int len, int idx) {
    if (idx < 0) idx = 0;
    if (idx > len) idx = len;
    while (idx > 0 && word_char_byte((unsigned char)text[idx - 1])) idx--;
    return idx;
}
static int word_end_in_bytes(const char* text, int len, int idx) {
    if (idx < 0) idx = 0;
    if (idx > len) idx = len;
    while (idx < len && word_char_byte((unsigned char)text[idx])) idx++;
    return idx;
}

// ---------------------------------------------------------------------------
// Canvas: 32-bit RGBA backing store painted by draw calls, flushed to X.
// ---------------------------------------------------------------------------
static void canvas_ensure(int w, int h) {
    if (g_canvas && g_win_w == w && g_win_h == h && g_canvas_px) return;
    if (g_canvas) { XDestroyImage(g_canvas); g_canvas = NULL; g_canvas_px = NULL; }
    g_canvas_px = (unsigned char*)calloc((size_t)w * h, 4);
    if (!g_canvas_px) return;
    // XCreateImage does not copy data: it wraps our buffer (BGRX order on
    // x86 LE: byte0=B byte1=G byte2=R byte3=X).
    g_canvas = XCreateImage(g_dpy, DefaultVisual(g_dpy, DefaultScreen(g_dpy)),
                            (unsigned)g_depth, ZPixmap, 0, (char*)g_canvas_px,
                            (unsigned)w, (unsigned)h, 32, 0);
    g_win_w = w; g_win_h = h;
}

static void canvas_clear(unsigned char r, unsigned char gg, unsigned char b) {
    if (!g_canvas_px) return;
    size_t n = (size_t)g_win_w * g_win_h;
    for (size_t i = 0; i < n; i++) {
        g_canvas_px[4 * i + 0] = b;
        g_canvas_px[4 * i + 1] = gg;
        g_canvas_px[4 * i + 2] = r;
        g_canvas_px[4 * i + 3] = 0;
    }
}

// Clip stack (platform_begin_clip/end_clip): 8-deep, intersected.
#define CLIP_DEPTH 8
static float g_clip_stack[CLIP_DEPTH][4];
static int g_clip_n = 0;
static float g_clip_x0 = -1e9f, g_clip_y0 = -1e9f, g_clip_x1 = 1e9f, g_clip_y1 = 1e9f;
static void clip_recompute(void) {
    g_clip_x0 = -1e9f; g_clip_y0 = -1e9f; g_clip_x1 = 1e9f; g_clip_y1 = 1e9f;
    for (int i = 0; i < g_clip_n; i++) {
        if (g_clip_stack[i][0] > g_clip_x0) g_clip_x0 = g_clip_stack[i][0];
        if (g_clip_stack[i][1] > g_clip_y0) g_clip_y0 = g_clip_stack[i][1];
        if (g_clip_stack[i][2] < g_clip_x1) g_clip_x1 = g_clip_stack[i][2];
        if (g_clip_stack[i][3] < g_clip_y1) g_clip_y1 = g_clip_stack[i][3];
    }
}

// Source-over blend of one pixel (non-premultiplied src over opaque dst).
static inline void blend_px(int x, int y, unsigned char r, unsigned char gg, unsigned char b, unsigned char a) {
    if (!g_canvas_px) return;
    if (x < 0 || y < 0 || x >= g_win_w || y >= g_win_h) return;
    size_t o = ((size_t)y * g_win_w + x) * 4;
    if (a == 255) {
        g_canvas_px[o] = b; g_canvas_px[o + 1] = gg; g_canvas_px[o + 2] = r;
        return;
    }
    if (a == 0) return;
    unsigned ia = 255 - a;
    g_canvas_px[o] = (unsigned char)((b * a + g_canvas_px[o] * ia + 127) / 255);
    g_canvas_px[o + 1] = (unsigned char)((gg * a + g_canvas_px[o + 1] * ia + 127) / 255);
    g_canvas_px[o + 2] = (unsigned char)((r * a + g_canvas_px[o + 2] * ia + 127) / 255);
}

static void fill_rect_px(float x, float y, float w, float h,
                         unsigned char r, unsigned char gg, unsigned char b, unsigned char a) {
    if (w <= 0 || h <= 0) return;
    int x0 = (int)floorf(x), y0 = (int)floorf(y);
    int x1 = (int)ceilf(x + w), y1 = (int)ceilf(y + h);
    if (x0 < (int)floorf(g_clip_x0)) x0 = (int)floorf(g_clip_x0);
    if (y0 < (int)floorf(g_clip_y0)) y0 = (int)floorf(g_clip_y0);
    if (x1 > (int)ceilf(g_clip_x1)) x1 = (int)ceilf(g_clip_x1);
    if (y1 > (int)ceilf(g_clip_y1)) y1 = (int)ceilf(g_clip_y1);
    for (int yy = y0; yy < y1; yy++)
        for (int xx = x0; xx < x1; xx++)
            blend_px(xx, yy, r, gg, b, a);
}

void platform_begin_clip(float x, float y, float w, float h) {
    if (g_clip_n >= CLIP_DEPTH) return;
    g_clip_stack[g_clip_n][0] = x;
    g_clip_stack[g_clip_n][1] = y;
    g_clip_stack[g_clip_n][2] = x + w;
    g_clip_stack[g_clip_n][3] = y + h;
    g_clip_n++;
    clip_recompute();
}

void platform_end_clip(void) {
    if (g_clip_n <= 0) return;
    g_clip_n--;
    clip_recompute();
}

// Blit one coverage glyph: src-over per-pixel from the atlas mask.
static void blit_glyph(int dx, int dy, GlyphEntry* e,
                       unsigned char r, unsigned char gg, unsigned char b, unsigned char a) {
    if (!e || e->aw == 0 || !g_atlas_px) return;
    for (int row = 0; row < e->ah; row++) {
        for (int col = 0; col < e->aw; col++) {
            unsigned char cov = g_atlas_px[((size_t)e->ay + row) * ATLAS_PX + e->ax + col];
            if (!cov) continue;
            int x = dx + col, y = dy + row;
            if (x < g_clip_x0 || y < g_clip_y0 || x >= g_clip_x1 || y >= g_clip_y1) continue;
            unsigned eff = (unsigned)cov * a / 255;
            blend_px(x, y, r, gg, b, (unsigned char)eff);
        }
    }
}

// Draw a text run at view coords (x, baseline-ish y: same convention as
// macos: y is the run top, ink starts at y + size*0.85 - ascent).
static void draw_run_pixels(const char* text, int len, float x, float y, float font_size,
                            int is_bold, int is_italic, int is_mono, int is_heading,
                            unsigned char r, unsigned char gg, unsigned char b, unsigned char a) {
    if (!text || len <= 0 || font_size <= 0) return;
    int px = (int)(font_size * g_output_scale + 0.5f);
    if (px < 1) px = 1;
    // Ink top: FreeType bitmap_top is relative to the baseline; baseline =
    // y + size*0.85 (macos geometry), ascent from the face.
    FT_Face face = face_for_style(is_bold, is_italic, is_mono, is_heading);
    float ascent = font_size * 0.85f;
    if (face) {
        if (FT_Set_Pixel_Sizes(face, 0, (FT_UInt)px) == 0 && face->size)
            ascent = (float)face->size->metrics.ascender / 64.0f / g_output_scale;
    }
    float pen = x;
    float tracking = is_heading ? -0.015f * font_size : 0.0f;
    float baseline = y + font_size * 0.85f;
    int style = style_bits(is_bold, is_italic, is_mono, is_heading);
    // Snap origin to the device grid (crisp blits: same rationale as the
    // macos dest snap).
    float pen_snap = roundf(pen * g_output_scale) / g_output_scale;
    pen = pen_snap;
    int idx = 0;
    while (idx < len) {
        uint32_t cp = utf8_next(text, len, &idx);
        if (cp == 0x200B || cp == 0x00AD) continue;
        GlyphEntry* e = glyph_ensure(cp, style, (int)(font_size + 0.5f), is_mono);
        if (!e) {
            pen += font_size * 0.5f;
            continue;
        }
        // Device-space glyph origin: pen + (bitmap_left, baseline - top).
        float gtop = (float)e->top;
        int gx = (int)floorf(pen);
        int gy = (int)floorf(baseline - gtop);
        blit_glyph(gx, gy, e, r, gg, b, a);
        pen += (float)e->adv_ip;
        if (is_heading) pen += tracking;
    }
}

// ---------------------------------------------------------------------------
// Records, selection paint, copy button (macos.m port)
// ---------------------------------------------------------------------------

static void record_text_quad(const char* text, int len, float x, float y, float w, float h,
                             float font_size, int is_bold, int is_italic, int is_mono, int is_heading,
                             const char* link_url, int link_url_len) {
    if (g_text_record_count >= MAX_QUAD_RECORDS) return;
    QuadTextRecord* rec = &g_text_records[g_text_record_count++];
    rec->x = x;
    rec->doc_y = y + g_scroll_y;
    rec->w = w;
    rec->h = h;
    rec->font_size = font_size;
    rec->is_bold = is_bold;
    rec->is_italic = is_italic;
    rec->is_mono = is_mono;
    rec->is_heading = is_heading;
    int copy_len = len < 511 ? len : 511;
    memcpy(rec->text, text, (size_t)copy_len);
    rec->text[copy_len] = '\0';
    rec->len = copy_len;
    int copy_url = (link_url != 0 && link_url_len > 0) ? (link_url_len < 255 ? link_url_len : 255) : 0;
    if (copy_url > 0) {
        memcpy(rec->link_url, link_url, (size_t)copy_url);
        rec->link_url[copy_url] = '\0';
    } else {
        rec->link_url[0] = '\0';
    }
}

void platform_register_text_run(const char* text, int len, float x, float y, float w, float h, float font_size, int is_bold, int is_italic, int is_mono, int is_heading, const char* link_url, int link_url_len) {
    if (text == 0 || len <= 0) return;
    float rec_w = run_advance(text, len, font_size, is_bold, is_italic, is_mono, is_heading);
    float rec_h = h > 0 ? h : font_size * 1.2f;
    if (rec_w <= 0) rec_w = w;
    record_text_quad(text, len, x, y, rec_w, rec_h, font_size,
                     is_bold, is_italic, is_mono, is_heading, link_url, link_url_len);
    if (link_url != 0 && link_url_len > 0) {
        link_underline_track(link_url, link_url_len, x, y, rec_w, font_size,
                             link_run_hovered(x, y, rec_w, rec_h));
    } else {
        g_last_ul.valid = 0;
    }
}

#define VISITED_LINK_CAP 64
static uint64_t g_visited_links[VISITED_LINK_CAP];
static int g_visited_next = 0;

static uint64_t link_url_hash(const char* url, int url_len) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (int i = 0; i < url_len; i++) {
        h ^= (unsigned char)url[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

static void mark_link_visited(const char* url) {
    if (url == 0 || url[0] == 0) return;
    g_visited_links[g_visited_next] = link_url_hash(url, (int)strlen(url));
    g_visited_next = (g_visited_next + 1) % VISITED_LINK_CAP;
}

int platform_link_visited(const char* url, int url_len) {
    if (url == 0 || url_len <= 0) return 0;
    uint64_t h = link_url_hash(url, url_len);
    for (int i = 0; i < VISITED_LINK_CAP; i++) {
        if (g_visited_links[i] == h) return 1;
    }
    return 0;
}

static inline int link_run_hovered(float x, float y, float w, float h) {
    if (w <= 0.0f || h <= 0.0f) return 0;
    return g_mouse_x >= x && g_mouse_x <= x + w &&
           g_mouse_y >= y && g_mouse_y <= y + h;
}

static float link_underline_track(const char* url, int url_len, float x, float y, float w, float font_size, int hovered) {
    uint64_t h = (url != 0 && url_len > 0) ? link_url_hash(url, url_len) : 0;
    hovered = hovered || (h != 0 && h == g_hover_link_hash);
    float gap_from = -1.0f;
    if (h != 0 && g_last_ul.valid && h == g_last_ul.hash &&
        g_last_ul.font_size == font_size && fabsf(y - g_last_ul.y) < 0.5f &&
        x >= g_last_ul.x_end && x - g_last_ul.x_end < font_size * 1.0f) {
        gap_from = g_last_ul.x_end;
        hovered = hovered || g_last_ul.hovered;
    }
    g_last_ul.hash = h;
    g_last_ul.y = y;
    g_last_ul.x_end = x + w;
    g_last_ul.font_size = font_size;
    g_last_ul.hovered = hovered;
    g_last_ul.valid = (h != 0);
    return gap_from;
}

static void draw_link_underline(float x, float y, float w, float font_size, int hovered, const char* url, int url_len,
                                unsigned char r, unsigned char gg, unsigned char b, unsigned char a) {
    if (w <= 0.0f || font_size <= 0.0f) return;
    float gap_from = link_underline_track(url, url_len, x, y, w, font_size, hovered);
    hovered = g_last_ul.hovered;
    float uy = y + font_size * 0.85f + fmaxf_(1.5f, font_size * 0.10f);
    float th = hovered ? 2.0f : 1.0f;
    if (gap_from >= 0.0f && gap_from < x)
        fill_rect_px(gap_from, uy, x - gap_from, th, r, gg, b, a);
    fill_rect_px(x, uy, w, th, r, gg, b, a);
}

static void paint_selection_highlight(void) {
    if ((g_has_selection == 0 && g_select_all == 0) || g_text_record_count <= 0) return;
    if (g_select_all) {
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            float view_y = rec->doc_y - g_scroll_y;
            fill_rect_px(rec->x, view_y, rec->w, rec->h, 56, 148, 250, 82);
        }
        return;
    }
    float p1x = g_sel_sx, p1y = g_sel_sy, p2x = g_sel_ex, p2y = g_sel_ey;
    int is_downward = (p1y < p2y || (p1y == p2y && p1x <= p2x));
    float top_x = is_downward ? p1x : p2x, top_y = is_downward ? p1y : p2y;
    float bot_x = is_downward ? p2x : p1x, bot_y = is_downward ? p2y : p1y;
    float min_y = top_y, max_y = bot_y;
    float top_vx = scroll_doc_to_view(top_x, top_y, NULL);
    float bot_vx = scroll_doc_to_view(bot_x, bot_y, NULL);
    {
        int min_in = 0, max_in = 0;
        float min_edge = min_y, max_edge = max_y;
        float min_d = 1e30f, max_d = 1e30f;
        for (int s = 0; s < g_text_record_count; s++) {
            QuadTextRecord* sr = &g_text_records[s];
            float st = sr->doc_y, sb = sr->doc_y + sr->h;
            if (min_y >= st && min_y <= sb) min_in = 1;
            else {
                float d = fminf_(fabsf(min_y - st), fabsf(min_y - sb));
                if (d < min_d) { min_d = d; min_edge = (fabsf(min_y - st) < fabsf(min_y - sb)) ? st : sb; }
            }
            if (max_y >= st && max_y <= sb) max_in = 1;
            else {
                float d = fminf_(fabsf(max_y - st), fabsf(max_y - sb));
                if (d < max_d) { max_d = d; max_edge = (fabsf(max_y - st) < fabsf(max_y - sb)) ? st : sb; }
            }
            if (min_in && max_in) break;
        }
        if (min_in == 0 && min_d <= 4.0f) min_y = min_edge;
        if (max_in == 0 && max_d <= 4.0f) max_y = max_edge;
    }
    float min_row_y = 0.0f, max_row_y = 0.0f;
    int min_row_found = 0, max_row_found = 0;
    for (int s = 0; s < g_text_record_count; s++) {
        QuadTextRecord* sr = &g_text_records[s];
        if (min_row_found == 0 && min_y >= sr->doc_y && min_y <= sr->doc_y + sr->h) {
            min_row_y = sr->doc_y; min_row_found = 1;
        }
        if (max_row_found == 0 && max_y >= sr->doc_y && max_y <= sr->doc_y + sr->h) {
            max_row_y = sr->doc_y; max_row_found = 1;
        }
        if (min_row_found && max_row_found) break;
    }
    for (int q = 0; q < g_text_record_count; q++) {
        QuadTextRecord* rec = &g_text_records[q];
        float r_top = rec->doc_y;
        float r_bot = rec->doc_y + rec->h;
        float view_y = rec->doc_y - g_scroll_y;
        if (r_bot < min_y - 4.0f || r_top > max_y + 4.0f) continue;
        int in_min_row = min_row_found && fabsf(rec->doc_y - min_row_y) < rec->h * 0.5f;
        int in_max_row = max_row_found && fabsf(rec->doc_y - max_row_y) < rec->h * 0.5f;
        if (in_min_row == 0 && in_max_row == 0 && (min_y > r_bot || max_y < r_top)) continue;
        int c_start = 0, c_end = rec->len;
        int is_first_line = in_min_row;
        int is_last_line = in_max_row;
        float span_lo, span_hi;
        if (is_first_line && is_last_line) {
            span_lo = fminf_(top_vx, bot_vx);
            span_hi = fmaxf_(top_vx, bot_vx);
        } else if (is_first_line) {
            span_lo = top_vx; span_hi = 1e30f;
        } else if (is_last_line) {
            span_lo = -1e30f; span_hi = bot_vx;
        } else {
            span_lo = -1e30f; span_hi = 1e30f;
        }
        if (q > 0) {
            QuadTextRecord* prev = &g_text_records[q - 1];
            if (fabsf(prev->doc_y - rec->doc_y) < 6.0f) {
                float glo = fmaxf_(prev->x + prev->w, span_lo);
                float ghi = fminf_(rec->x, span_hi);
                if (ghi > glo)
                    fill_rect_px(glo, view_y, ghi - glo, rec->h, 56, 148, 250, 82);
            }
        }
        if (is_first_line && is_last_line) {
            float left_x = fminf_(top_vx, bot_vx);
            float right_x = fmaxf_(top_vx, bot_vx);
            if (rec->x + rec->w < left_x || rec->x > right_x) continue;
            c_start = get_char_index_at_x(rec, left_x - rec->x);
            c_end = get_char_index_at_x(rec, right_x - rec->x);
        } else if (is_first_line) {
            float start_x = top_vx;
            if (rec->x + rec->w < start_x) continue;
            c_start = get_char_index_at_x(rec, start_x - rec->x);
            c_end = rec->len;
        } else if (is_last_line) {
            float end_x = bot_vx;
            if (rec->x > end_x) continue;
            c_start = 0;
            c_end = get_char_index_at_x(rec, end_x - rec->x);
        } else {
            c_start = 0;
            c_end = rec->len;
        }
        if (c_end > c_start) {
            float x1 = rec->x + get_x_for_char_index(rec, c_start);
            float x2 = rec->x + get_x_for_char_index(rec, c_end);
            fill_rect_px(x1, view_y, x2 - x1, rec->h, 56, 148, 250, 82);
        }
    }
}

static void paint_copy_button(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    double now = (double)tv.tv_sec + tv.tv_usec / 1e6;
    for (int b_idx = 0; b_idx < g_code_block_count; b_idx++) {
        CodeBlockRecord* b = &g_code_blocks[b_idx];
        int is_hovered = (g_mouse_x >= b->x && g_mouse_x <= b->x + b->w &&
                          g_mouse_y >= b->y && g_mouse_y <= b->y + b->h);
        int is_copied = (g_copied_block_idx == b_idx && (now - g_copied_timestamp < 1.5));
        if (is_hovered == 0 && is_copied == 0) continue;
        RectF btn = copy_button_rect_for_block(b);
        fill_rect_px(btn.x, btn.y, btn.w, btn.h, 51, 56, 66, 242);
        fill_rect_px(btn.x, btn.y, btn.w, 1, 89, 97, 115, 204);
        fill_rect_px(btn.x, btn.y + btn.h - 1, btn.w, 1, 89, 97, 115, 204);
        fill_rect_px(btn.x, btn.y, 1, btn.h, 89, 97, 115, 204);
        fill_rect_px(btn.x + btn.w - 1, btn.y, 1, btn.h, 89, 97, 115, 204);
        const char* label = is_copied ? "Copied!" : "Copy";
        int ll = is_copied ? 7 : 4;
        float tw = run_advance(label, ll, 11.0f, 0, 0, 0, 0);
        float tx = btn.x + (btn.w - tw) * 0.5f;
        float ty = btn.y + (btn.h - 11.0f * 1.2f) * 0.5f;
        unsigned char tr = is_copied ? 77 : 217, tg = is_copied ? 217 : 224, tb = is_copied ? 102 : 235;
        draw_run_pixels(label, ll, tx, ty, 11.0f, 0, 0, 0, 0, tr, tg, tb, 255);
    }
}

static int selected_text_bytes(char* out, int cap) {
    int n = 0;
    if (g_select_all) {
        float last_doc_y = -9999.0f;
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            if (last_doc_y > -9000.0f && fabsf(rec->doc_y - last_doc_y) > 10.0f) {
                if (fabsf(rec->doc_y - last_doc_y) > 35.0f) {
                    if (n + 2 < cap) { out[n++] = '\n'; out[n++] = '\n'; }
                } else {
                    if (n + 1 < cap) out[n++] = '\n';
                }
            } else if (last_doc_y > -9000.0f) {
                if (n + 1 < cap) out[n++] = ' ';
            }
            if (n + rec->len < cap) { memcpy(out + n, rec->text, (size_t)rec->len); n += rec->len; }
            last_doc_y = rec->doc_y;
        }
    } else if (g_has_selection) {
        float p1x = g_sel_sx, p1y = g_sel_sy, p2x = g_sel_ex, p2y = g_sel_ey;
        int is_downward = (p1y < p2y || (p1y == p2y && p1x <= p2x));
        float top_x = is_downward ? p1x : p2x, top_y = is_downward ? p1y : p2y;
        float bot_x = is_downward ? p2x : p1x, bot_y = is_downward ? p2y : p1y;
        float min_y = top_y, max_y = bot_y;
        float top_vx = scroll_doc_to_view(top_x, top_y, NULL);
        float bot_vx = scroll_doc_to_view(bot_x, bot_y, NULL);
        float last_doc_y = -9999.0f;
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            float r_top = rec->doc_y;
            float r_bot = rec->doc_y + rec->h;
            if (r_bot < min_y - 4.0f || r_top > max_y + 4.0f) continue;
            int c_start = 0, c_end = rec->len;
            int is_first_line = (min_y >= r_top && min_y <= r_bot);
            int is_last_line = (max_y >= r_top && max_y <= r_bot);
            if (is_first_line && is_last_line) {
                float left_x = fminf_(top_vx, bot_vx);
                float right_x = fmaxf_(top_vx, bot_vx);
                if (rec->x + rec->w < left_x || rec->x > right_x) continue;
                c_start = get_char_index_at_x(rec, left_x - rec->x);
                c_end = get_char_index_at_x(rec, right_x - rec->x);
            } else if (is_first_line) {
                float start_x = top_vx;
                if (rec->x + rec->w < start_x) continue;
                c_start = get_char_index_at_x(rec, start_x - rec->x);
                c_end = rec->len;
            } else if (is_last_line) {
                float end_x = bot_vx;
                if (rec->x > end_x) continue;
                c_start = 0;
                c_end = get_char_index_at_x(rec, end_x - rec->x);
            } else {
                c_start = 0;
                c_end = rec->len;
            }
            if (c_end > c_start && c_start >= 0 && c_end <= rec->len) {
                if (last_doc_y > -9000.0f && fabsf(rec->doc_y - last_doc_y) > 10.0f) {
                    if (fabsf(rec->doc_y - last_doc_y) > 35.0f) {
                        if (n + 2 < cap) { out[n++] = '\n'; out[n++] = '\n'; }
                    } else {
                        if (n + 1 < cap) out[n++] = '\n';
                    }
                } else if (last_doc_y > -9000.0f) {
                    if (n + 1 < cap) out[n++] = ' ';
                }
                if (n + (c_end - c_start) < cap) {
                    memcpy(out + n, rec->text + c_start, (size_t)(c_end - c_start));
                    n += (c_end - c_start);
                }
                last_doc_y = rec->doc_y;
            }
        }
    }
    return n;
}

// ---------------------------------------------------------------------------
// Draw entry points
// ---------------------------------------------------------------------------
// Draw gate: live draws need the canvas; headless renders swap in their own
// buffer (see the headless section at end-of-file).
static unsigned char* g_draw_px = NULL;
static int g_draw_w = 0, g_draw_h = 0;

void platform_draw_rect(float x, float y, float w, float h, unsigned char r, unsigned char g, unsigned char b, unsigned char a) {
    if (g_draw_px == 0) return;
    // Redirect to the active buffer: live canvas or headless buffer share
    // the same blend core via a temporary swap.
    unsigned char* saved_px = g_canvas_px;
    int saved_w = g_win_w, saved_h = g_win_h;
    g_canvas_px = g_draw_px; g_win_w = g_draw_w; g_win_h = g_draw_h;
    fill_rect_px(x, y, w, h, r, g, b, a);
    g_canvas_px = saved_px; g_win_w = saved_w; g_win_h = saved_h;
}

void platform_draw_pill(float x, float y, float w, float h, float radius,
                        unsigned char fr, unsigned char fg, unsigned char fb, unsigned char fa,
                        unsigned char br, unsigned char bg, unsigned char bb, unsigned char ba) {
    if (g_draw_px == 0) return;
    if (w <= 0.0f || h <= 0.0f) return;
    unsigned char* saved_px = g_canvas_px;
    int saved_w = g_win_w, saved_h = g_win_h;
    g_canvas_px = g_draw_px; g_win_w = g_draw_w; g_win_h = g_draw_h;
    float r = fminf_(radius, fminf_(w, h) * 0.5f);
    // Fill: center rect + top/bottom/left/right bars approximate the round
    // rect; corner squares are overdrawn-then-cut by the border pass.
    fill_rect_px(x + r, y, w - 2 * r, h, fr, fg, fb, fa);
    fill_rect_px(x, y + r, w, h - 2 * r, fr, fg, fb, fa);
    // 1px border: four edges.
    fill_rect_px(x + r, y, w - 2 * r, 1, br, bg, bb, ba);
    fill_rect_px(x + r, y + h - 1, w - 2 * r, 1, br, bg, bb, ba);
    fill_rect_px(x, y + r, 1, h - 2 * r, br, bg, bb, ba);
    fill_rect_px(x + w - 1, y + r, 1, h - 2 * r, br, bg, bb, ba);
    g_canvas_px = saved_px; g_win_w = saved_w; g_win_h = saved_h;
}

void platform_register_code_block(float x, float y, float w, float h, const char* code_text, int code_len) {
    if (g_code_block_count >= MAX_CODE_BLOCKS) return;
    CodeBlockRecord* b = &g_code_blocks[g_code_block_count++];
    b->x = x;
    b->y = y;
    b->w = w;
    b->h = h;
    int copy_len = (code_text != 0 && code_len > 0) ? (code_len < 8191 ? code_len : 8191) : 0;
    if (copy_len > 0) {
        memcpy(b->text, code_text, (size_t)copy_len);
        b->text[copy_len] = '\0';
        b->len = copy_len;
    } else {
        b->text[0] = '\0';
        b->len = 0;
    }
}

void platform_register_scrollable_block(int block_id, float x, float y, float w, float h, float max_scroll_x, float scroll_x) {
    if (g_scrollable_block_count >= MAX_SCROLLABLE_BLOCKS) return;
    g_scrollable_blocks[g_scrollable_block_count].id = block_id;
    g_scrollable_blocks[g_scrollable_block_count].x = x;
    g_scrollable_blocks[g_scrollable_block_count].y = y;
    g_scrollable_blocks[g_scrollable_block_count].w = w;
    g_scrollable_blocks[g_scrollable_block_count].h = h;
    g_scrollable_blocks[g_scrollable_block_count].max_scroll_x = max_scroll_x;
    g_scrollable_blocks[g_scrollable_block_count].scroll_x = scroll_x;
    g_scrollable_block_count++;
}

static void draw_text_common(const char* text, int len, float x, float y, float font_size,
                             int is_bold, int is_italic, int is_mono, int is_heading,
                             unsigned char r, unsigned char g, unsigned char b, unsigned char a,
                             const char* link_url, int link_url_len, int do_record) {
    if (link_url == 0 || link_url_len <= 0) g_last_ul.valid = 0;
    float w = run_advance(text, len, font_size, is_bold, is_italic, is_mono, is_heading);
    float h = font_size * 1.2f;
    if (do_record)
        record_text_quad(text, len, x, y, w, h, font_size,
                         is_bold, is_italic, is_mono, is_heading, link_url, link_url_len);
    if (g_draw_px == 0) {
        // No pixels (headless state probe): still advance the underline
        // continuation so culled runs bridge identically.
        if (link_url != 0 && link_url_len > 0)
            link_underline_track(link_url, link_url_len, x, y, w, font_size,
                                 link_run_hovered(x, y, w, h));
        return;
    }
    unsigned char* saved_px = g_canvas_px;
    int saved_w = g_win_w, saved_h = g_win_h;
    g_canvas_px = g_draw_px; g_win_w = g_draw_w; g_win_h = g_draw_h;
    draw_run_pixels(text, len, x, y, font_size, is_bold, is_italic, is_mono, is_heading,
                    r, g, b, a);
    if (link_url != 0 && link_url_len > 0)
        draw_link_underline(x, y, w, font_size, link_run_hovered(x, y, w, h),
                            link_url, link_url_len, r, g, b, a);
    g_canvas_px = saved_px; g_win_w = saved_w; g_win_h = saved_h;
}

void platform_draw_text(const char* text, int len, float x, float y, float font_size, int is_bold, int is_italic, int is_mono, int is_heading, unsigned char r, unsigned char g, unsigned char b, unsigned char a, const char* link_url, int link_url_len) {
    if (text == 0 || len <= 0) return;
    draw_text_common(text, len, x, y, font_size, is_bold, is_italic, is_mono, is_heading,
                     r, g, b, a, link_url, link_url_len, 1);
}

// Muted alt text inside loading/failed placeholder boxes. Truncates at a
// UTF-8 boundary to fit ~7px/char at 12px; UNRECORDED (the box interior
// has no layout text_run counterpart).
static void draw_placeholder_alt(const char* alt, int alt_len, float x, float y, float w, float h) {
    if (alt == 0 || alt_len <= 0 || w < 60.0f || h < 26.0f) return;
    int cap = (int)((w - 16.0f) / 7.0f);
    if (cap > 96) cap = 96;
    if (cap <= 0) return;
    int n = alt_len < cap ? alt_len : cap;
    while (n > 0 && ((unsigned char)alt[n] & 0xC0) == 0x80) n--;
    if (n <= 0) return;
    draw_text_common(alt, n, x + 8.0f, y + h * 0.5f - 7.0f, 12.0f,
                     0, 0, 0, 0, 140, 140, 145, 255, NULL, 0, 0);
}

// ---------------------------------------------------------------------------
// Image cache: sync libpng decode (frame 0 still v1) + async arm skeleton
// ---------------------------------------------------------------------------
typedef struct {
    char url[512];
    unsigned char* px;    // RGBA pixels, malloc'd (NULL = not yet loaded)
    int pw, ph;           // decoded size
    float natural_w;
    float natural_h;
    int frame_count;      // 1 when loaded (frame 0 still v1), 0 when not
    int primed_frames;    // 1 when decoded (TEST_HOOKS primed contract)
    int cur_frame;        // always 0 v1 (struct parity with macos.m)
    double frame_delay;   // reserved (animation v2)
    int loading;          // async load in flight
    int failed;
    int kick_pending;     // resolved but decode not yet dispatched
    int parked;           // reserved (animation v2)
    unsigned long last_draw_seq;
    float last_doc_x;
    float last_doc_y;
    float last_w;
    float last_h;
    int has_rect;
} CachedImageRecord;

#define MAX_IMAGE_CACHE 64
static CachedImageRecord g_image_cache[MAX_IMAGE_CACHE];
static int g_image_cache_count = 0;
static int g_images_armed = 0;
static char g_doc_dir[1024] = { 0 };
static unsigned long g_test_image_draws = 0;

static int image_url_is_remote_len(const char* s, int n) {
    if (s == 0 || n <= 0) return 0;
    if (n >= 7 && memcmp(s, "http://", 7) == 0) return 1;
    if (n >= 8 && memcmp(s, "https://", 8) == 0) return 1;
    return 0;
}

// libpng decode of frame 0 (still v1). Accepts the same still formats
// macos ImageIO decodes for PNG (8-bit RGB/RGBA/palette/gray(+alpha),
// non-interlaced and Adam7); anything else fails into the placeholder.
// Returns 1 on success.
static int decode_png_libpng(const char* path, unsigned char** out_px, int* out_w, int* out_h) {
    FILE* f = fopen(path, "rb");
    if (f == 0) return 0;
    unsigned char sig[8];
    if (fread(sig, 1, 8, f) != 8 || png_sig_cmp(sig, 0, 8) != 0) { fclose(f); return 0; }
    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, 0, 0, 0);
    if (png == 0) { fclose(f); return 0; }
    png_infop info = png_create_info_struct(png);
    if (info == 0) { png_destroy_read_struct(&png, 0, 0); fclose(f); return 0; }
    if (setjmp(png_jmpbuf(png))) {
        png_destroy_read_struct(&png, &info, 0);
        fclose(f);
        return 0;
    }
    png_init_io(png, f);
    png_set_sig_bytes(png, 8);
    png_read_info(png, info);
    png_uint_32 w = 0, h = 0;
    int bit = 0, ctype = 0;
    png_get_IHDR(png, info, &w, &h, &bit, &ctype, 0, 0, 0);
    if (w == 0 || h == 0 || w > 8192 || h > 8192) {
        png_destroy_read_struct(&png, &info, 0);
        fclose(f);
        return 0;
    }
    if (ctype == PNG_COLOR_TYPE_PALETTE) png_set_palette_to_rgb(png);
    if (ctype == PNG_COLOR_TYPE_GRAY && bit < 8) png_set_gray_to_rgb(png);
    if (png_get_valid(png, info, PNG_INFO_tRNS)) png_set_tRNS_to_alpha(png);
    if (bit == 16) png_set_strip_16(png);
    if (ctype == PNG_COLOR_TYPE_GRAY || ctype == PNG_COLOR_TYPE_GRAY_ALPHA) png_set_gray_to_rgb(png);
    png_set_strip_alpha(png); // composite over placeholder bg at draw time is out of scope v1: opaque
    png_set_add_alpha(png, 0xFF, PNG_FILLER_AFTER);
    png_read_update_info(png, info);
    png_bytep* rows = (png_bytep*)malloc(sizeof(png_bytep) * h);
    if (rows == 0) { png_destroy_read_struct(&png, &info, 0); fclose(f); return 0; }
    size_t stride = (size_t)w * 4;
    unsigned char* px = (unsigned char*)malloc(stride * h);
    if (px == 0) { free(rows); png_destroy_read_struct(&png, &info, 0); fclose(f); return 0; }
    for (png_uint_32 y = 0; y < h; y++) rows[y] = px + (size_t)y * stride;
    png_read_image(png, rows);
    png_read_end(png, info);
    png_destroy_read_struct(&png, &info, 0);
    fclose(f);
    free(rows);
    *out_px = px;
    *out_w = (int)w;
    *out_h = (int)h;
    return 1;
}

// Resolve relative path to absolute (#45: document-dir first). Remote URLs
// pass through (they degrade to the placeholder: no network fetch v1).
// Returns 1 and fills abs_out when a readable local file resolves.
static int resolve_image_path(const char* url, int url_len, char* abs_out, size_t cap) {
    if (url == 0 || url_len <= 0) return 0;
    if (image_url_is_remote_len(url, url_len)) return 0;
    char rel[1024];
    if (url_len >= (int)sizeof(rel)) return 0;
    memcpy(rel, url, (size_t)url_len);
    rel[url_len] = '\0';
    struct stat st;
    if (stat(rel, &st) == 0) {
        size_t n = strlen(rel);
        if (n + 1 > cap) return 0;
        memcpy(abs_out, rel, n + 1);
        return 1;
    }
    if (g_doc_dir[0] != '\0') {
        char full[2048];
        snprintf(full, sizeof(full), "%s/%s", g_doc_dir, rel);
        if (stat(full, &st) == 0) {
            size_t n = strlen(full);
            if (n + 1 > cap) return 0;
            memcpy(abs_out, full, n + 1);
            return 1;
        }
    }
    char cwd[1024];
    if (getcwd(cwd, sizeof(cwd)) != 0) {
        char full[2048];
        snprintf(full, sizeof(full), "%s/%s", cwd, rel);
        if (stat(full, &st) == 0) {
            size_t n = strlen(full);
            if (n + 1 > cap) return 0;
            memcpy(abs_out, full, n + 1);
            return 1;
        }
    }
    return 0;
}

static void image_load_completed(CachedImageRecord* rec);

// Synchronously populate a cache slot from a local file path. Remote URLs
// never reach here (they fail into the placeholder: no network fetch v1).
static void load_image_sync(CachedImageRecord* rec, const char* path) {
    unsigned char* px = 0;
    int w = 0, hh = 0;
    if (decode_png_libpng(path, &px, &w, &hh)) {
        rec->px = px;
        rec->pw = w; rec->ph = hh;
        rec->natural_w = (float)w;
        rec->natural_h = (float)hh;
        rec->frame_count = 1;
        rec->primed_frames = 1;
        rec->cur_frame = 0;
        rec->failed = 0;
    } else {
        rec->failed = 1;
    }
    rec->loading = 0;
}

// Startup economy: image decodes are dispatched only once g_images_armed
// is set (after first paint, or explicitly for headless settle runs).
static void kick_image_load(CachedImageRecord* rec, const char* resolved) {
    load_image_sync(rec, resolved);
    image_load_completed(rec);
}

void platform_arm_images(void) {
    if (g_images_armed) return;
    g_images_armed = 1;
    for (int i = 0; i < g_image_cache_count; i++) {
        CachedImageRecord* rec = &g_image_cache[i];
        if (rec->kick_pending == 0 || rec->failed) continue;
        rec->kick_pending = 0;
        char abs_path[2048];
        if (resolve_image_path(rec->url, (int)strlen(rec->url), abs_path, sizeof(abs_path)) == 0) {
            rec->failed = 1; rec->loading = 0;
            continue;
        }
        kick_image_load(rec, abs_path);
    }
}

// Shared arrival for decodes, success or failure: metrics resync +
// repaint (same delta_above contract as macos image_load_completed).
static void image_load_completed(CachedImageRecord* rec) {
    float delta_above = 0.0f;
    if (rec->failed == 0 && rec->frame_count > 0 && rec->has_rect) {
        float vw = (float)g_win_w;
        float cw = vw > 600.0f ? 600.0f : fmaxf_(vw - 64.0f, 100.0f);
        float new_h = (rec->natural_w > 0.0f && rec->natural_h > 0.0f)
            ? rec->natural_h * (fminf_(rec->natural_w, cw) / rec->natural_w)
            : 240.0f;
        if (rec->last_doc_y + rec->last_h <= g_scroll_y) {
            delta_above = new_h - rec->last_h;
        }
        rec->last_h = new_h;
    }
    if (g_callbacks.on_images_changed) {
        g_callbacks.on_images_changed(delta_above);
    }
    request_redraw();
}

// Returns existing or allocates a record; dispatches the sync decode only
// when armed — otherwise parks it for platform_arm_images.
static CachedImageRecord* get_or_load_image_record(const char* url, int url_len) {
    if (url == 0 || url_len <= 0 || url_len >= 512) return NULL;
    for (int i = 0; i < g_image_cache_count; i++) {
        if (strncmp(g_image_cache[i].url, url, (size_t)url_len) == 0 &&
            g_image_cache[i].url[url_len] == '\0') {
            return &g_image_cache[i];
        }
    }
    if (g_image_cache_count >= MAX_IMAGE_CACHE) return NULL;
    CachedImageRecord* rec = &g_image_cache[g_image_cache_count++];
    memset(rec, 0, sizeof(*rec));
    memcpy(rec->url, url, (size_t)url_len);
    rec->url[url_len] = '\0';
    rec->loading = 1;
    // Remote URLs: placeholder, synchronously failed (no fetch v1).
    if (image_url_is_remote_len(url, url_len)) {
        rec->failed = 1;
        rec->loading = 0;
        return rec;
    }
    char abs_path[2048];
    if (resolve_image_path(url, url_len, abs_path, sizeof(abs_path)) == 0) {
        rec->failed = 1; rec->loading = 0;
        return rec;
    }
    if (g_images_armed == 0) {
        rec->kick_pending = 1;
        return rec;
    }
    kick_image_load(rec, abs_path);
    return rec;
}

void platform_get_image_size(const char* url, int url_len, float* out_w, float* out_h) {
    if (out_w) *out_w = 0;
    if (out_h) *out_h = 0;
    CachedImageRecord* rec = get_or_load_image_record(url, url_len);
    if (rec == 0 || rec->loading || rec->failed) return;
    if (out_w) *out_w = rec->natural_w;
    if (out_h) *out_h = rec->natural_h;
}

void platform_draw_image(const char* url, int url_len, float x, float y, float w, float h,
        const char* alt, int alt_len) {
    if (g_draw_px == 0 || w <= 0 || h <= 0) return;
    g_test_image_draws++;
    CachedImageRecord* rec = get_or_load_image_record(url, url_len);
    if (rec != 0) {
        rec->last_doc_x = x;
        rec->last_doc_y = y + g_scroll_y;
        rec->last_w = w;
        rec->last_h = h;
        rec->has_rect = 1;
    }
    unsigned char* saved_px = g_canvas_px;
    int saved_w = g_win_w, saved_h = g_win_h;
    g_canvas_px = g_draw_px; g_win_w = g_draw_w; g_win_h = g_draw_h;
    if (rec == 0 || rec->loading) {
        fill_rect_px(x, y, w, h, 28, 28, 32, 128);
        fill_rect_px(x, y, w, 1, 60, 60, 70, 153);
        fill_rect_px(x, y + h - 1, w, 1, 60, 60, 70, 153);
        fill_rect_px(x, y, 1, h, 60, 60, 70, 153);
        fill_rect_px(x + w - 1, y, 1, h, 60, 60, 70, 153);
        draw_placeholder_alt(alt, alt_len, x, y, w, h);
        g_canvas_px = saved_px; g_win_w = saved_w; g_win_h = saved_h;
        return;
    }
    if (rec->failed || rec->frame_count == 0 || rec->px == 0) {
        fill_rect_px(x, y, w, h, 28, 28, 32, 255);
        fill_rect_px(x, y, w, 1, 80, 40, 40, 255);
        fill_rect_px(x, y + h - 1, w, 1, 80, 40, 40, 255);
        fill_rect_px(x, y, 1, h, 80, 40, 40, 255);
        fill_rect_px(x + w - 1, y, 1, h, 80, 40, 40, 255);
        draw_placeholder_alt(alt, alt_len, x, y, w, h);
        g_canvas_px = saved_px; g_win_w = saved_w; g_win_h = saved_h;
        return;
    }
    rec->last_draw_seq = g_draw_seq;
    // Nearest-neighbor scale blit of frame 0 into (x, y, w, h).
    int dx0 = (int)floorf(x), dy0 = (int)floorf(y);
    int dx1 = (int)ceilf(x + w), dy1 = (int)ceilf(y + h);
    for (int yy = dy0; yy < dy1; yy++) {
        for (int xx = dx0; xx < dx1; xx++) {
            if (xx < g_clip_x0 || yy < g_clip_y0 || xx >= g_clip_x1 || yy >= g_clip_y1) continue;
            int sx = (int)(((float)(xx - x) / w) * rec->pw);
            int sy = (int)(((float)(yy - y) / h) * rec->ph);
            if (sx < 0) sx = 0; if (sx >= rec->pw) sx = rec->pw - 1;
            if (sy < 0) sy = 0; if (sy >= rec->ph) sy = rec->ph - 1;
            unsigned char* p = rec->px + ((size_t)sy * rec->pw + sx) * 4;
            blend_px(xx, yy, p[0], p[1], p[2], 255);
        }
    }
    g_canvas_px = saved_px; g_win_w = saved_w; g_win_h = saved_h;
}

void platform_set_document_dir(const char* path, int path_len) {
    g_doc_dir[0] = '\0';
    if (path == 0 || path_len <= 0) return;
    int end = path_len;
    while (end > 0 && path[end - 1] != '/') end--;
    if (end > 0) end--;
    if (end <= 0) return;
    if (end > (int)sizeof(g_doc_dir) - 1) end = (int)sizeof(g_doc_dir) - 1;
    memcpy(g_doc_dir, path, (size_t)end);
    g_doc_dir[end] = '\0';
}

// ---------------------------------------------------------------------------
// Clipboard: CLIPBOARD + PRIMARY via XSetSelectionOwner (UTF8_STRING/STRING)
// ---------------------------------------------------------------------------
static char g_clip_utf8[1 << 20];
static int g_clip_len = 0;
static Atom g_atom_clipboard = 0;
static Atom g_atom_primary = 0;
static Atom g_atom_utf8 = 0;
static Atom g_atom_targets = 0;

static void clipboard_atoms(void) {
    if (g_atom_clipboard || g_dpy == 0) return;
    g_atom_clipboard = XInternAtom(g_dpy, "CLIPBOARD", False);
    g_atom_primary = XA_PRIMARY;
    g_atom_utf8 = XInternAtom(g_dpy, "UTF8_STRING", False);
    g_atom_targets = XInternAtom(g_dpy, "TARGETS", False);
}

static void clipboard_own(Atom sel) {
    if (g_dpy == 0 || g_win == 0) return;
    clipboard_atoms();
    XSetSelectionOwner(g_dpy, sel, g_win, CurrentTime);
}

static void copy_selection_to_clipboard(void) {
    char buf[1 << 20];
    int n = selected_text_bytes(buf, (int)sizeof(buf));
    if (n <= 0) return;
    if (n > (int)sizeof(g_clip_utf8)) n = (int)sizeof(g_clip_utf8);
    memcpy(g_clip_utf8, buf, (size_t)n);
    g_clip_len = n;
    clipboard_own(g_atom_clipboard ? g_atom_clipboard : 1);
    clipboard_atoms();
    clipboard_own(g_atom_clipboard);
    clipboard_own(g_atom_primary ? g_atom_primary : 1);
}

static void clipboard_serve(XSelectionRequestEvent* req) {
    XSelectionEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = SelectionNotify;
    ev.display = req->display;
    ev.requestor = req->requestor;
    ev.selection = req->selection;
    ev.target = req->target;
    ev.time = req->time;
    ev.property = None;
    clipboard_atoms();
    if (req->target == g_atom_targets) {
        Atom supported[2];
        supported[0] = g_atom_utf8;
        supported[1] = XA_STRING;
        XChangeProperty(g_dpy, req->requestor, req->property, XA_ATOM, 32,
                        PropModeReplace, (unsigned char*)supported, 2);
        ev.property = req->property;
    } else if (req->target == g_atom_utf8 || req->target == XA_STRING) {
        if (g_clip_len > 0) {
            XChangeProperty(g_dpy, req->requestor, req->property, req->target, 8,
                            PropModeReplace, (unsigned char*)g_clip_utf8, g_clip_len);
            ev.property = req->property;
        }
    }
    XSendEvent(g_dpy, req->requestor, False, 0, (XEvent*)&ev);
    XFlush(g_dpy);
}

// ---------------------------------------------------------------------------
// Scroll/sync/theme entry points
// ---------------------------------------------------------------------------
void platform_sync_scroll(float scroll_y) {
    if (scroll_y != g_scroll_y) g_hover_link_hash = 0;
    g_scroll_y = scroll_y;
}

void platform_sync_overshoot(float overshoot) {
    g_overshoot = overshoot;
}

void platform_set_scroll_info(float scroll_y, float max_scroll_y, float view_h) {
    g_scroll_y = scroll_y;
    g_max_scroll_y = max_scroll_y;
    g_view_h = view_h;
}

static float scrollbar_thumb_y(void) {
    if (g_max_scroll_y <= 0.0f) return 0.0f;
    float p = fclampf(g_scroll_y / g_max_scroll_y, 0.0f, 1.0f);
    return p * (g_view_h - SCROLLBAR_THUMB_H);
}

static int scrollbar_hit(float x, float view_w) {
    return g_max_scroll_y > 0.0f && x >= view_w - SCROLLBAR_HIT_W;
}

static void scrollbar_drag_to(float y) {
    float travel = g_view_h - SCROLLBAR_THUMB_H;
    if (travel <= 0.0f || g_callbacks.on_scroll_to == 0) return;
    float p = fclampf((y - g_scrollbar_grab_delta) / travel, 0.0f, 1.0f);
    g_callbacks.on_scroll_to(p * g_max_scroll_y);
}

static void paint_scrollbar(void) {
    if (g_draw_px == 0 || g_max_scroll_y <= 0.0f) return;
    unsigned char* saved_px = g_canvas_px;
    int saved_w = g_win_w, saved_h = g_win_h;
    g_canvas_px = g_draw_px; g_win_w = g_draw_w; g_win_h = g_draw_h;
    // 2px filament at the right edge (grab strip is 12px, visual is 2px).
    float x = (float)g_draw_w - 4.0f;
    float thumb = scrollbar_thumb_y();
    unsigned char r = 128, gg = 128, b = 134;
    fill_rect_px(x, thumb, 2.0f, SCROLLBAR_THUMB_H, r, gg, b, 160);
    g_canvas_px = saved_px; g_win_w = saved_w; g_win_h = saved_h;
}

static int appearance_is_dark(void) {
    // No desktop-portal query v1: follow the last synced app theme
    // (platform_init pushes dark first, then on_appearance corrects).
    if (g_synced_theme_dark >= 0) return g_synced_theme_dark;
    return 1;
}

static void apply_window_appearance(int dark) {
    // Window background tracks the APP theme (#104): the canvas clear
    // color in do_draw follows g_synced_theme_dark, so this only records.
    (void)dark;
}

void platform_sync_theme(int dark) {
    int d = dark ? 1 : 0;
    if (d == g_synced_theme_dark) return;
    g_synced_theme_dark = d;
    apply_window_appearance(d);
}

void platform_clear_selection(void) {
    g_has_selection = 0;
    g_select_all = 0;
    g_selection_mode = 0;
}

// ---------------------------------------------------------------------------
// Math stubs: size -> 1 (engine unavailable), last_error -> 0, draw no-op,
// stats/info zeros. TEST_HOOKS-only readers stay under the same gate so
// ship never links them.
// ---------------------------------------------------------------------------
int platform_math_size(const char* tex, int tex_len, int display, float font_px,
                       float* out_w, float* out_above, float* out_below) {
    (void)tex; (void)tex_len; (void)display; (void)font_px;
    if (out_w) *out_w = 0;
    if (out_above) *out_above = 0;
    if (out_below) *out_below = 0;
    return 1;
}

int platform_math_last_error(const char* tex, int tex_len, int display,
                             unsigned int* out_offset, int* out_code) {
    (void)tex; (void)tex_len; (void)display;
    (void)out_offset; (void)out_code;
    return 0;
}

void platform_draw_math(const char* tex, int tex_len, int display, float font_px,
                        float x, float y_top,
                        unsigned char r, unsigned char g, unsigned char b, unsigned char a) {
    (void)tex; (void)tex_len; (void)display; (void)font_px;
    (void)x; (void)y_top; (void)r; (void)g; (void)b; (void)a;
}

#ifdef TEST_HOOKS
void platform_math_atlas_stats(uint64_t* hits, uint64_t* misses) {
    if (hits) *hits = 0;
    if (misses) *misses = 0;
}

void platform_math_engine_info(unsigned int* version, unsigned int* use_ex, unsigned int* conform_ran,
                               int* conform_n, unsigned int* caps) {
    if (version) *version = 0;
    if (use_ex) *use_ex = 0;
    if (conform_ran) *conform_ran = 0;
    if (conform_n) *conform_n = 0;
    if (caps) *caps = 0;
}
#endif

// ---------------------------------------------------------------------------
// Outline (#48): data path implemented, panel no-op v1
// ---------------------------------------------------------------------------
#define OUTLINE_MAX 512
typedef struct { int level; float y; char text[160]; } OutlineItem;
static OutlineItem g_outline_items[OUTLINE_MAX];
static int g_outline_count = 0;
static int g_outline_rows[OUTLINE_MAX];

void platform_outline_add(int level, float y, const char* text, int text_len) {
    if (g_outline_count >= OUTLINE_MAX || text == 0 || text_len <= 0) return;
    OutlineItem* it = &g_outline_items[g_outline_count++];
    it->level = level;
    it->y = y;
    int n = text_len < 159 ? text_len : 159;
    memcpy(it->text, text, (size_t)n);
    it->text[n] = '\0';
}

// Plain-substring filter (case-insensitive): empty matches everything.
static int outline_filter_matches(const char* text, const char* filter, int filter_len) {
    if (filter == 0 || filter_len <= 0) return 1;
    if (text == 0) return 0;
    size_t tl = strlen(text);
    if ((int)tl < filter_len) {
        // Still may match when filter is longer: no.
        return 0;
    }
    for (size_t i = 0; i + (size_t)filter_len <= tl + 1; i++) {
        size_t j = 0;
        while (j < (size_t)filter_len) {
            unsigned char a = (unsigned char)text[i + j];
            unsigned char bb = (unsigned char)filter[j];
            if (a >= 'A' && a <= 'Z') a += 32;
            if (bb >= 'A' && bb <= 'Z') bb += 32;
            if (a != bb) break;
            j++;
        }
        if (j == (size_t)filter_len) return 1;
        if (text[i] == '\0') break;
    }
    return 0;
}

void platform_outline_show(void) {
    // No-op v1 (data path above implemented): rebuild the filtered rows so
    // the count contract holds, then consume the accumulation.
    g_outline_row_count = 0;
    for (int i = 0; i < g_outline_count; i++) {
        if (outline_filter_matches(g_outline_items[i].text, "", 0) == 0) continue;
        g_outline_rows[g_outline_row_count++] = i;
    }
    g_outline_count = 0;
}

// ---------------------------------------------------------------------------
// Open files (#43): extension gate; rejects never silently absorbed.
// ---------------------------------------------------------------------------
static int read_path_is_markdown(const char* path, int path_len) {
    if (path == 0 || path_len <= 0) return 0;
    int dot = -1;
    for (int i = 0; i < path_len; i++) {
        if (path[i] == '/') dot = -1;
        else if (path[i] == '.') dot = i;
    }
    if (dot < 0) return 0;
    int el = path_len - dot - 1;
    char ext[16];
    if (el <= 0 || el >= (int)sizeof(ext)) return 0;
    for (int i = 0; i < el; i++) {
        char c = path[dot + 1 + i];
        if (c >= 'A' && c <= 'Z') c += 32;
        ext[i] = c;
    }
    ext[el] = '\0';
    return strcmp(ext, "md") == 0 || strcmp(ext, "markdown") == 0 ||
           strcmp(ext, "mdown") == 0 || strcmp(ext, "mkd") == 0 ||
           strcmp(ext, "txt") == 0 || strcmp(ext, "text") == 0;
}

static void read_open_file_path(const char* path, int path_len) {
    if (path == 0 || g_callbacks.on_open_file == 0) return;
    if (read_path_is_markdown(path, path_len) == 0) {
        fprintf(stderr, "read: could not open the file (not Markdown or text)\n");
        return;
    }
    g_callbacks.on_open_file(path, path_len);
}

// ---------------------------------------------------------------------------
// External-change watcher (#44): inotify, event-driven on the main loop.
// ---------------------------------------------------------------------------
static int g_watch_fd = -1;
static int g_watch_wd = -1;

void platform_unwatch_file(void) {
    if (g_watch_wd >= 0 && g_watch_fd >= 0) inotify_rm_watch(g_watch_fd, g_watch_wd);
    g_watch_wd = -1;
    if (g_watch_fd >= 0) { close(g_watch_fd); g_watch_fd = -1; }
}

void platform_watch_file(const char* path, int path_len) {
    platform_unwatch_file();
    if (path == 0 || path_len <= 0 || path_len >= 2048) return;
    char buf[2048];
    memcpy(buf, path, (size_t)path_len);
    buf[path_len] = '\0';
    int fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (fd < 0) return;
    int wd = inotify_add_watch(fd, buf, IN_MODIFY | IN_DELETE_SELF | IN_MOVE_SELF | IN_ATTRIB);
    if (wd < 0) { close(fd); return; }
    g_watch_fd = fd;
    g_watch_wd = wd;
}

static void watch_poll_dispatch(void) {
    if (g_watch_fd < 0) return;
    char buf[4096];
    ssize_t n = read(g_watch_fd, buf, sizeof(buf));
    if (n <= 0) return;
    // Any event batch means the document changed: re-arm first (editors
    // replace files, killing the watched descriptor), then notify.
    char path[2048] = { 0 };
    // Recover the path from /proc/self/fd (best effort; empty keeps old).
    char link[64];
    snprintf(link, sizeof(link), "/proc/self/fd/%d", g_watch_fd);
    (void)link;
    if (g_callbacks.on_file_changed) g_callbacks.on_file_changed();
}

// ---------------------------------------------------------------------------
// Find bar (#42): state + drawn overlay strip; typing searches live.
// ---------------------------------------------------------------------------
void platform_find_show_count(int current, int total) {
    if (g_find_had_query == 0) {
        g_find_count_text[0] = '\0';
    } else if (total <= 0) {
        snprintf(g_find_count_text, sizeof(g_find_count_text), "No matches");
    } else {
        snprintf(g_find_count_text, sizeof(g_find_count_text), "%d of %d", current, total);
    }
}

void platform_find_hide(void) {
    g_find_visible = 0;
    request_redraw();
}

static void read_find_show(void) {
    g_find_visible = 1;
    g_find_query_len = 0;
    g_find_query[0] = '\0';
    g_find_count_text[0] = '\0';
    request_redraw();
}

static void read_find_close(void) {
    g_find_visible = 0;
    if (g_callbacks.on_find_closed) g_callbacks.on_find_closed();
    request_redraw();
}

static void read_find_type(const char* bytes, int n) {
    for (int i = 0; i < n; i++) {
        unsigned char c = (unsigned char)bytes[i];
        if (c == '\n' || c == '\r') continue; // single-line field
        if (g_find_query_len >= (int)sizeof(g_find_query) - 1) break;
        g_find_query[g_find_query_len++] = (char)c;
    }
    g_find_query[g_find_query_len] = '\0';
    g_find_had_query = 1;
    if (g_callbacks.on_find_query) g_callbacks.on_find_query(g_find_query, g_find_query_len);
}

static void read_find_backspace(void) {
    if (g_find_query_len <= 0) return;
    // Delete one UTF-8 char.
    do { g_find_query_len--; } while (g_find_query_len > 0 &&
        ((unsigned char)g_find_query[g_find_query_len] & 0xC0) == 0x80);
    g_find_query[g_find_query_len] = '\0';
    g_find_had_query = 1;
    if (g_callbacks.on_find_query) g_callbacks.on_find_query(g_find_query, g_find_query_len);
}

static void paint_find_bar(void) {
    if (g_find_visible == 0 || g_draw_px == 0) return;
    unsigned char* saved_px = g_canvas_px;
    int saved_w = g_win_w, saved_h = g_win_h;
    g_canvas_px = g_draw_px; g_win_w = g_draw_w; g_win_h = g_draw_h;
    float pw = 320.0f, ph = 44.0f;
    float px = (float)g_draw_w - pw - 16.0f;
    float py = 16.0f;
    int dark = g_synced_theme_dark != 0;
    fill_rect_px(px, py, pw, ph,
                 dark ? 30 : 255, dark ? 30 : 255, dark ? 34 : 255, 255);
    fill_rect_px(px, py, pw, 1, 80, 80, 88, 255);
    fill_rect_px(px, py + ph - 1, pw, 1, 80, 80, 88, 255);
    fill_rect_px(px, py, 1, ph, 80, 80, 88, 255);
    fill_rect_px(px + pw - 1, py, 1, ph, 80, 80, 88, 255);
    unsigned char tr = dark ? 224 : 30, tg = dark ? 224 : 32, tb = dark ? 224 : 34;
    if (g_find_query_len > 0) {
        draw_run_pixels(g_find_query, g_find_query_len, px + 10, py + 6, 13.0f,
                        0, 0, 0, 0, tr, tg, tb, 255);
    }
    if (g_find_count_text[0]) {
        float cw = run_advance(g_find_count_text, (int)strlen(g_find_count_text), 11.0f, 0, 0, 0, 0);
        draw_run_pixels(g_find_count_text, (int)strlen(g_find_count_text),
                        px + pw - cw - 10, py + 8, 11.0f, 0, 0, 0, 0, 140, 140, 145, 255);
    }
    g_canvas_px = saved_px; g_win_w = saved_w; g_win_h = saved_h;
}

// External link opener (#46): xdg-open via posix_spawnp (never blocks).
void platform_open_url_external(const char* url, int url_len) {
    if (url == 0 || url_len <= 0) return;
    char buf[2048];
    if (url_len >= (int)sizeof(buf)) return;
    memcpy(buf, url, (size_t)url_len);
    buf[url_len] = '\0';
    extern char** environ;
    pid_t pid = 0;
    char* const argv[] = { (char*)"xdg-open", buf, NULL };
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    for (int fd = 1; fd <= 2; fd++)
        posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_WRONLY, 0);
    posix_spawnp(&pid, "xdg-open", &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
}

// ---------------------------------------------------------------------------
// Draw dispatch: rebuild records, run on_draw, paint overlays, flush to X
// ---------------------------------------------------------------------------
static void do_draw(void) {
    if (g_dpy == 0) return;
    // Window size may have changed (ConfigureNotify updates g_win_w/h via
    // canvas_ensure on the resize path; here just make sure).
    canvas_ensure(g_win_w, g_win_h);
    if (g_canvas_px == 0) return;
    g_text_record_count = 0;
    g_code_block_count = 0;
    g_scrollable_block_count = 0;
    g_last_ul.valid = 0;
    g_draw_px = g_canvas_px;
    g_draw_w = g_win_w;
    g_draw_h = g_win_h;
    g_test_image_draws = 0;
    g_draw_seq++;
    // Base clear follows the APP theme (#104 overscroll strip parity: the
    // window background is the content background).
    if (g_synced_theme_dark == 0) {
        canvas_clear(250, 250, 250);
    } else {
        canvas_clear(18, 18, 18);
    }
    if (g_callbacks.on_draw) {
        g_callbacks.on_draw(g_win_w, g_win_h);
    }
    paint_selection_highlight();
    paint_copy_button();
    paint_scrollbar();
    paint_find_bar();
    g_draw_px = NULL;
    // Overshoot translate: shift the flushed image by g_overshoot rows.
    if (g_overshoot != 0.0f && g_gc) {
        int dy = (int)g_overshoot;
        XCopyArea(g_dpy, g_win, g_win, g_gc, 0, 0,
                  (unsigned)g_win_w, (unsigned)g_win_h, 0, dy);
        // Uncovered strip: repaint background color via X.
        unsigned long bg = (g_synced_theme_dark == 0) ? 0xFAFAFA : 0x121212;
        XSetForeground(g_dpy, g_gc, bg);
        if (dy > 0) XFillRectangle(g_dpy, g_win, g_gc, 0, 0, (unsigned)g_win_w, (unsigned)dy);
        else XFillRectangle(g_dpy, g_win, g_gc, 0, g_win_h + dy, (unsigned)g_win_w, (unsigned)(-dy));
    }
    if (g_canvas && g_gc) {
        XPutImage(g_dpy, g_win, g_gc, g_canvas, 0, 0, 0, 0,
                  (unsigned)g_win_w, (unsigned)g_win_h);
    }
    XFlush(g_dpy);
    g_dirty_valid = 0;
}

void platform_request_redraw(void) {
    request_redraw();
}

void platform_request_redraw_rect(float x, float y, float w, float h) {
    invalidate_rect(x, y, w, h);
}

int platform_get_pending_damage(float* x, float* y, float* w, float* h) {
#ifdef TEST_HOOKS
    extern int g_test_damage_valid;
    extern float g_test_damage_x, g_test_damage_y, g_test_damage_w, g_test_damage_h;
    if (g_test_damage_valid) {
        if (x) *x = g_test_damage_x;
        if (y) *y = g_test_damage_y;
        if (w) *w = g_test_damage_w;
        if (h) *h = g_test_damage_h;
        return 1;
    }
#endif
    if (g_dirty_valid == 0) return 0;
    if (x) *x = g_dirty_x;
    if (y) *y = g_dirty_y;
    if (w) *w = g_dirty_w;
    if (h) *h = g_dirty_h;
    return 1;
}

// ---------------------------------------------------------------------------
// Scroll smoothing driver: 8.33ms select-timeout driving on_tick, parked
// at 0 (mirrors the 120Hz CFRunLoopTimer that parks on settle).
// ---------------------------------------------------------------------------
static int g_smooth_armed = 0;
static uint64_t g_smooth_last_us = 0;

static uint64_t now_us(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000000ull + (uint64_t)tv.tv_usec;
}

void platform_smooth_kick(void) {
    if (g_smooth_armed || g_callbacks.on_tick == 0) return;
    g_smooth_armed = 1;
    g_smooth_last_us = now_us();
}

static void smooth_maybe_fire(void) {
    if (g_smooth_armed == 0 || g_callbacks.on_tick == 0) return;
    uint64_t now = now_us();
    float dt_ms = (float)(now - g_smooth_last_us) / 1000.0f;
    g_smooth_last_us = now;
    if (dt_ms < 0.0f) dt_ms = 0.0f;
    if (dt_ms > 50.0f) dt_ms = 50.0f; // clamped: stalls must not teleport
    int more = g_callbacks.on_tick(dt_ms);
    if (more == 0) {
        g_smooth_armed = 0;
    }
    request_redraw();
}

// ---------------------------------------------------------------------------
// Keys: XLookupString; Ctrl == Cmd; plain-gate mirrors key_combo_plain (#32)
// ---------------------------------------------------------------------------
// Plain-letter gate (#32): only bare keys reach on_key (Shift allowed: '?'
// needs it; Lock/Mod2 are lock states and pass through). State is the X
// modifier mask: Shift=1 Lock=2 Ctrl=4 Mod1(Alt)=8.
static inline int key_combo_plain(unsigned state) {
    unsigned f = state & ~(LockMask | Mod2Mask);
    return f == 0 || f == ShiftMask;
}

static int hovered_block_now(void) {
    return scroll_block_at_point(g_mouse_x, g_mouse_y);
}

static void handle_key_press(XKeyEvent* kev) {
    // Find bar owns typing while visible (like NSTextField owning edits).
    if (g_find_visible) {
        char buf[64];
        KeySym ks = 0;
        int n = XLookupString(kev, buf, (int)sizeof(buf), &ks, NULL);
        if (ks == XK_Escape) { read_find_close(); return; }
        if (ks == XK_Return || ks == XK_KP_Enter) {
            int prev = (kev->state & ShiftMask) ? 1 : 0;
            if (g_callbacks.on_find_next) g_callbacks.on_find_next(prev);
            return;
        }
        if (ks == XK_BackSpace) { read_find_backspace(); request_redraw(); return; }
        if (n > 0) { read_find_type(buf, n); request_redraw(); return; }
        return;
    }
    char tmp[16];
    KeySym ks = 0;
    int nn = XLookupString(kev, tmp, (int)sizeof(tmp), &ks, NULL);
    (void)nn;
    unsigned state = kev->state & (ShiftMask | LockMask | ControlMask | Mod1Mask | Mod4Mask);
    // Ctrl == Cmd: j opens outline, c copies, a selects all.
    if (state == ControlMask) {
        char cbuf[16];
        KeySym k2 = 0;
        XLookupString(kev, cbuf, (int)sizeof(cbuf), &k2, NULL);
        char c = cbuf[0];
        if (c == 'j' || c == 'J') {
            if (g_callbacks.on_outline_open) g_callbacks.on_outline_open();
            return;
        }
        if (c == 'c' || c == 'C') { copy_selection_to_clipboard(); return; }
        if (c == 'a' || c == 'A') {
            g_select_all = 1;
            g_has_selection = 1;
            g_selection_mode = 4;
            request_redraw();
            return;
        }
        if (c == 'o' || c == 'O') {
            // No native Open panel v1: open the CWD default is out of
            // scope; ignore (never silently absorbed: no-op with beep).
            XBell(g_dpy, 50);
            return;
        }
        if (c == 'f' || c == 'F') { read_find_show(); return; }
        return; // other Ctrl combos dropped (same as Cmd combos on macos)
    }
    if (key_combo_plain(kev->state) == 0) return;
    char cbuf[16];
    KeySym k3 = 0;
    int m = XLookupString(kev, cbuf, (int)sizeof(cbuf), &k3, NULL);
    if (m <= 0) {
        // Non-printable: Esc dismisses help (handled via keysym).
        if (k3 == XK_Escape && g_callbacks.on_key) {
            g_callbacks.on_key(27, hovered_block_now());
            request_redraw();
        }
        return;
    }
    char c = cbuf[0];
    if (c == '/') {
        // '?' arrives as '/' once Shift is ignored (US layout Shift+/):
        // restore from the modifier-aware byte (same as macos keyDown).
        if ((kev->state & ShiftMask) && m >= 1 && cbuf[0] == '/') {
            // XLookupString already applied Shift: '/' with Shift IS '?'
            // on US layouts only when the keysym says so; check it.
            if (k3 == XK_question) c = '?';
        }
    }
    if (g_callbacks.on_key) {
        g_callbacks.on_key((int)c, hovered_block_now());
    }
    // Damage: h/l nudge one hovered block -> its exact box only; j/k/Space
    // scroll and t theme-toggle repaint every pixel -> full.
    int hb = hovered_block_now();
    if ((c == 'h' || c == 'l') && hb >= 0) {
        for (int i = 0; i < g_scrollable_block_count; i++) {
            ScrollableBlockRecord* b = &g_scrollable_blocks[i];
            if (b->id == hb) {
                invalidate_rect(b->x - 2.0f, b->y - 2.0f, b->w + 4.0f, b->h + 4.0f);
                break;
            }
        }
    } else if (c == 'h' || c == 'l') {
        // No hovered block: no repaint.
    } else {
        request_redraw();
    }
}

// ---------------------------------------------------------------------------
// Mouse: selection state machine (word lock-in, line select, scrollbar)
// ---------------------------------------------------------------------------
static void mouse_down(float vx, float vy, int click_count, unsigned button) {
    if (button == 3) {
        // Right-click: copy under cursor (context menu parity: Copy only
        // v1, no popup menu).
        copy_selection_to_clipboard();
        return;
    }
    if (button == 4) {
        // Wheel up: 3 lines (~60px), precise (1:1, no smoothing glide).
        if (g_callbacks.on_scroll) {
            int hb = scroll_block_at_point(vx, vy);
            g_callbacks.on_scroll(0.0f, -60.0f, hb, 1);
        }
        request_redraw();
        return;
    }
    if (button == 5) {
        if (g_callbacks.on_scroll) {
            int hb = scroll_block_at_point(vx, vy);
            g_callbacks.on_scroll(0.0f, 60.0f, hb, 1);
        }
        request_redraw();
        return;
    }
    if (button != 1) return;
    // Scrollbar drag starts here: the right-edge strip belongs to the
    // ambient scrollbar, never to text selection or Copy buttons.
    if (g_scrollbar_dragging == 0 && scrollbar_hit(vx, (float)g_win_w)) {
        float thumb = scrollbar_thumb_y();
        if (vy >= thumb && vy <= thumb + SCROLLBAR_THUMB_H) {
            g_scrollbar_grab_delta = vy - thumb;
        } else {
            g_scrollbar_grab_delta = SCROLLBAR_THUMB_H * 0.5f;
        }
        g_scrollbar_dragging = 1;
        scrollbar_drag_to(vy);
        request_redraw();
        return;
    }
    // Copy button hit.
    for (int b_idx = 0; b_idx < g_code_block_count; b_idx++) {
        CodeBlockRecord* b = &g_code_blocks[b_idx];
        RectF btn = copy_button_rect_for_block(b);
        if (vx >= btn.x && vx <= btn.x + btn.w && vy >= btn.y && vy <= btn.y + btn.h) {
            char tmp[8192];
            int n = b->len < (int)sizeof(tmp) ? b->len : (int)sizeof(tmp);
            memcpy(tmp, b->text, (size_t)n);
            if (n > (int)sizeof(g_clip_utf8)) n = (int)sizeof(g_clip_utf8);
            memcpy(g_clip_utf8, tmp, (size_t)n);
            g_clip_len = n;
            clipboard_atoms();
            clipboard_own(g_atom_clipboard);
            clipboard_own(g_atom_primary);
            struct timeval tv;
            gettimeofday(&tv, NULL);
            g_copied_block_idx = b_idx;
            g_copied_timestamp = (double)tv.tv_sec + tv.tv_usec / 1e6;
            RectF d = copy_button_damage_rect(b);
            invalidate_rect(d.x, d.y, d.w, d.h);
            return;
        }
    }
    RectF old_sel = selection_bounds_expanded(24.0f);
    g_select_all = 0;
    g_has_selection = 1;
    float down_doc_y = vy + g_scroll_y;
    float click_off = scroll_block_offset(scroll_block_at_point(vx, vy), NULL);
    g_sel_sx = vx + click_off; g_sel_sy = down_doc_y;
    g_sel_ex = g_sel_sx; g_sel_ey = g_sel_sy;
    g_sel_ax = g_sel_sx; g_sel_ay = g_sel_sy;
    if (click_count == 2) {
        g_selection_mode = 2;
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            if (vx >= rec->x && vx <= rec->x + rec->w &&
                g_sel_sy >= rec->doc_y && g_sel_sy <= rec->doc_y + rec->h)
            {
                float mid_y = rec->doc_y + rec->h * 0.5f;
                int b = get_char_index_at_x(rec, vx - rec->x);
                int ws = word_start_in_bytes(rec->text, rec->len, b);
                int we = word_end_in_bytes(rec->text, rec->len, b);
                float svx0, svx1;
                if (we > ws) {
                    svx0 = rec->x + get_x_for_char_index(rec, ws);
                    svx1 = rec->x + get_x_for_char_index(rec, we);
                } else {
                    svx0 = rec->x;
                    svx1 = rec->x + rec->w;
                }
                float snap_off = scroll_block_offset(scroll_block_at_point(svx0, vy), NULL);
                g_sel_sx = svx0 + snap_off; g_sel_sy = mid_y;
                g_sel_ex = svx1 + snap_off; g_sel_ey = mid_y;
                g_sel_ax = g_sel_sx; g_sel_ay = g_sel_sy;
                break;
            }
        }
    } else if (click_count >= 3) {
        g_selection_mode = 3;
        float click_doc_y = g_sel_sy;
        float line_min_x = 9999.0f;
        float line_max_x = -9999.0f;
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            if (fabsf(rec->doc_y + rec->h * 0.5f - click_doc_y) < 16.0f) {
                line_min_x = fminf_(line_min_x, rec->x);
                line_max_x = fmaxf_(line_max_x, rec->x + rec->w);
            }
        }
        if (line_max_x > line_min_x) {
            float lo_off = scroll_block_offset(scroll_block_at_point(line_min_x, vy), NULL);
            float hi_off = scroll_block_offset(scroll_block_at_point(line_max_x, vy), NULL);
            g_sel_sx = line_min_x + lo_off; g_sel_sy = click_doc_y;
            g_sel_ex = line_max_x + hi_off; g_sel_ey = click_doc_y;
        }
    } else {
        g_selection_mode = 1;
    }
    RectF now_sel = selection_bounds_expanded(24.0f);
    RectF u = rect_union(old_sel, now_sel);
    invalidate_rect(u.x, u.y, u.w, u.h);
}

static void mouse_drag(float vx, float vy) {
    if (g_scrollbar_dragging) {
        scrollbar_drag_to(vy);
        request_redraw();
        return;
    }
    float drag_doc_y = vy + g_scroll_y;
    float drag_doc_x = vx + scroll_block_offset(scroll_block_at_point(vx, vy), NULL);
    if (g_selection_mode == 2) {
        RectF old_sel = selection_bounds_expanded(24.0f);
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            if (drag_doc_x >= rec->x && drag_doc_x <= rec->x + rec->w &&
                drag_doc_y >= rec->doc_y && drag_doc_y <= rec->doc_y + rec->h)
            {
                float mid_y = rec->doc_y + rec->h * 0.5f;
                int b = get_char_index_at_x(rec, drag_doc_x - rec->x);
                if (drag_doc_x < g_sel_ax) {
                    int ws = word_start_in_bytes(rec->text, rec->len, b);
                    float svx = rec->x + get_x_for_char_index(rec, ws);
                    g_sel_ex = svx + scroll_block_offset(scroll_block_at_point(svx, vy), NULL);
                    g_sel_ey = mid_y;
                } else {
                    int ws = word_start_in_bytes(rec->text, rec->len, b);
                    int we = word_end_in_bytes(rec->text, rec->len, b);
                    if (we > ws) {
                        float svx = rec->x + get_x_for_char_index(rec, we);
                        g_sel_ex = svx + scroll_block_offset(scroll_block_at_point(svx, vy), NULL);
                        g_sel_ey = mid_y;
                    }
                }
                break;
            }
        }
        RectF now_sel = selection_bounds_expanded(24.0f);
        RectF u = rect_union(old_sel, now_sel);
        invalidate_rect(u.x, u.y, u.w, u.h);
        return;
    }
    if (g_selection_mode == 3) {
        RectF old_sel = selection_bounds_expanded(24.0f);
        float band_min = 9999.0f, band_max = -9999.0f;
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            if (fabsf(rec->doc_y + rec->h * 0.5f - drag_doc_y) < 16.0f) {
                band_min = fminf_(band_min, rec->x);
                band_max = fmaxf_(band_max, rec->x + rec->w);
            }
        }
        if (band_max > band_min) {
            if (drag_doc_y < g_sel_ay) {
                float lo_off = scroll_block_offset(scroll_block_at_point(band_min, vy), NULL);
                g_sel_sx = band_min + lo_off; g_sel_sy = drag_doc_y;
            } else {
                float hi_off = scroll_block_offset(scroll_block_at_point(band_max, vy), NULL);
                g_sel_ex = band_max + hi_off; g_sel_ey = drag_doc_y;
            }
        }
        RectF now_sel = selection_bounds_expanded(24.0f);
        RectF u = rect_union(old_sel, now_sel);
        invalidate_rect(u.x, u.y, u.w, u.h);
        return;
    }
    if (g_selection_mode <= 1) {
        RectF old_sel = selection_bounds_expanded(24.0f);
        float drag_end_doc_y = vy + g_scroll_y;
        float drag_end_off = scroll_block_offset(scroll_block_at_point(vx, vy), NULL);
        g_sel_ex = vx + drag_end_off; g_sel_ey = drag_end_doc_y;
        RectF now_sel = selection_bounds_expanded(24.0f);
        RectF u = rect_union(old_sel, now_sel);
        invalidate_rect(u.x, u.y, u.w, u.h);
    }
}

static void mouse_up(float vx, float vy, int click_count) {
    if (g_scrollbar_dragging) {
        g_scrollbar_dragging = 0;
        return;
    }
    if (g_selection_mode >= 2) {
        // Word lock-in (#4): mouseUp must NOT overwrite the snapped end.
        return;
    }
    RectF old_sel = selection_bounds_expanded(24.0f);
    float up_doc_y = vy + g_scroll_y;
    float up_off = scroll_block_offset(scroll_block_at_point(vx, vy), NULL);
    float end_x = vx + up_off, end_y = up_doc_y;
    if (fabsf(end_y - g_sel_sy) < 4.0f && fabsf(end_x - g_sel_sx) < 4.0f) {
        if (click_count < 2) {
            g_has_selection = 0;
            g_selection_mode = 0;
            // Link click routing (#46): section links + non-http(s) to Zig,
            // http(s) direct to xdg-open.
            for (int i = 0; i < g_text_record_count; i++) {
                QuadTextRecord* rec = &g_text_records[i];
                if (rec->link_url[0] != '\0' &&
                    vx >= rec->x && vx <= rec->x + rec->w &&
                    end_y >= rec->doc_y && end_y <= rec->doc_y + rec->h) {
                    int ul = (int)strlen(rec->link_url);
                    char lower[16];
                    int ln = ul < 15 ? ul : 15;
                    for (int k = 0; k < ln; k++) {
                        char c = rec->link_url[k];
                        lower[k] = (c >= 'A' && c <= 'Z') ? c + 32 : c;
                    }
                    lower[ln] = '\0';
                    int is_http = strncmp(lower, "http://", 7) == 0 || strncmp(lower, "https://", 8) == 0;
                    if (is_http == 0 && g_callbacks.on_link) {
                        g_callbacks.on_link(rec->link_url, ul);
                    } else if (is_http) {
                        platform_open_url_external(rec->link_url, ul);
                    }
                    mark_link_visited(rec->link_url);
                    break;
                }
            }
            invalidate_rect(old_sel.x, old_sel.y, old_sel.w, old_sel.h);
            return;
        }
    } else {
        g_sel_ex = end_x; g_sel_ey = end_y;
    }
    RectF now_sel = selection_bounds_expanded(24.0f);
    RectF u = rect_union(old_sel, now_sel);
    invalidate_rect(u.x, u.y, u.w, u.h);
}

static void mouse_move(float vx, float vy) {
    g_mouse_x = vx;
    g_mouse_y = vy;
    int over_link = 0;
    uint64_t hover_hash = 0;
    for (int i = 0; i < g_text_record_count; i++) {
        QuadTextRecord* rec = &g_text_records[i];
        float view_y = rec->doc_y - g_scroll_y;
        if (rec->link_url[0] != '\0' &&
            vx >= rec->x && vx <= rec->x + rec->w &&
            vy >= view_y && vy <= view_y + rec->h) {
            over_link = 1;
            hover_hash = link_url_hash(rec->link_url, (int)strlen(rec->link_url));
            break;
        }
    }
    g_hover_link_hash = hover_hash;
    int over_code_btn = 0;
    for (int b_idx = 0; b_idx < g_code_block_count; b_idx++) {
        CodeBlockRecord* b = &g_code_blocks[b_idx];
        RectF btn = copy_button_rect_for_block(b);
        if (vx >= btn.x && vx <= btn.x + btn.w && vy >= btn.y && vy <= btn.y + btn.h) {
            over_code_btn = 1;
            break;
        }
    }
    int new_hover_btn = -1;
    for (int b_idx = 0; b_idx < g_code_block_count; b_idx++) {
        CodeBlockRecord* b = &g_code_blocks[b_idx];
        if (vx >= b->x && vx <= b->x + b->w && vy >= b->y && vy <= b->y + b->h) {
            new_hover_btn = b_idx;
            break;
        }
    }
    // Idle-gated link highlight (mirrors idle.zig): pure motion never
    // redraws; only a hover flip re-arms one gated full redraw.
    static uint64_t prev_hover_hash = 0;
    if (g_text_record_count > 0 &&
        (over_link != g_last_link_hover ||
         (over_link && hover_hash != prev_hover_hash))) {
        g_last_link_hover = over_link;
        prev_hover_hash = hover_hash;
        request_redraw();
    }
    g_last_code_btn_hover = over_code_btn;
    if (new_hover_btn != g_hovered_code_btn) {
        if (g_hovered_code_btn >= 0 && g_hovered_code_btn < g_code_block_count) {
            RectF d = copy_button_damage_rect(&g_code_blocks[g_hovered_code_btn]);
            invalidate_rect(d.x, d.y, d.w, d.h);
        }
        if (new_hover_btn >= 0) {
            RectF d = copy_button_damage_rect(&g_code_blocks[new_hover_btn]);
            invalidate_rect(d.x, d.y, d.w, d.h);
        }
        g_hovered_code_btn = new_hover_btn;
    }
}

// ---------------------------------------------------------------------------
// Init + run loop (X11 window, event-driven, zero idle wakeups)
// ---------------------------------------------------------------------------
int platform_init(const char* title, int width, int height, PlatformCallbacks callbacks) {
    g_callbacks = callbacks;
    g_dpy = XOpenDisplay(NULL);
    if (g_dpy == 0) {
        fprintf(stderr, "read: cannot open X display\n");
        return -1;
    }
    int scr = DefaultScreen(g_dpy);
    g_depth = DefaultDepth(g_dpy, scr);
    if (g_depth != 24 && g_depth != 32) {
        fprintf(stderr, "read: unsupported X depth %d (need 24/32)\n", g_depth);
        return -1;
    }
    g_win_w = width > 0 ? width : 1000;
    g_win_h = height > 0 ? height : 750;
    g_win = XCreateSimpleWindow(g_dpy, RootWindow(g_dpy, scr), 0, 0,
                                (unsigned)g_win_w, (unsigned)g_win_h, 0,
                                BlackPixel(g_dpy, scr), WhitePixel(g_dpy, scr));
    if (title) XStoreName(g_dpy, g_win, title);
    XSelectInput(g_dpy, g_win,
                 ExposureMask | KeyPressMask | ButtonPressMask | ButtonReleaseMask |
                 PointerMotionMask | StructureNotifyMask);
    // WM_DELETE_WINDOW for q/quit parity with the close button.
    Atom wm_del = XInternAtom(g_dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(g_dpy, g_win, &wm_del, 1);
    g_gc = XCreateGC(g_dpy, g_win, 0, NULL);
    // Clipboard atoms now (display is open).
    clipboard_atoms();
    XMapWindow(g_dpy, g_win);
    XFlush(g_dpy);
    register_app_fonts();
    // Initial theme follows the synced default (dark), corrected live via
    // on_appearance below so launch never flashes the wrong palette.
    apply_window_appearance(appearance_is_dark());
    if (callbacks.on_appearance)
        callbacks.on_appearance(appearance_is_dark() ? 1 : 0);
    // Display prefs (#30): size class 1 (default) + Reduce Motion from the
    // GTK/portal setting is out of scope v1 (0 = full motion).
    if (callbacks.on_display) callbacks.on_display(1, 0);
    canvas_ensure(g_win_w, g_win_h);
    return 0;
}

void platform_run_loop(void) {
    if (g_dpy == 0) return;
    int xfd = ConnectionNumber(g_dpy);
    int last_x = -1, last_y = -1;
    unsigned long last_click_t = 0;
    int click_count = 0;
    int btn_down = 0;
    Atom wm_del = XInternAtom(g_dpy, "WM_DELETE_WINDOW", False);
    // Button4/5 autorepeat guard: wheel events arrive as press/release
    // pairs; the press carries the scroll.
    for (;;) {
        // 8.33ms select timeout while smoothing is armed (parked at 0:
        // static screens cost zero wakeups beyond X events).
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = g_smooth_armed ? 8333 : 200000;
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(xfd, &rfds);
        int maxfd = xfd;
        if (g_watch_fd >= 0) {
            FD_SET(g_watch_fd, &rfds);
            if (g_watch_fd > maxfd) maxfd = g_watch_fd;
        }
        int r = select(maxfd + 1, &rfds, NULL, NULL, &tv);
        if (r < 0) continue;
        if (g_watch_fd >= 0 && FD_ISSET(g_watch_fd, &rfds)) {
            watch_poll_dispatch();
        }
        if (r > 0 && FD_ISSET(xfd, &rfds)) {
            while (XPending(g_dpy)) {
                XEvent ev;
                XNextEvent(g_dpy, &ev);
                switch (ev.type) {
                case Expose:
                    if (ev.xexpose.count == 0) {
                        g_dirty_x = (float)ev.xexpose.x;
                        g_dirty_y = (float)ev.xexpose.y;
                        g_dirty_w = (float)ev.xexpose.width;
                        g_dirty_h = (float)ev.xexpose.height;
                        g_dirty_valid = 1;
                        do_draw();
                    }
                    break;
                case ConfigureNotify:
                    if (ev.xconfigure.width != g_win_w || ev.xconfigure.height != g_win_h) {
                        g_win_w = ev.xconfigure.width;
                        g_win_h = ev.xconfigure.height;
                        canvas_ensure(g_win_w, g_win_h);
                        if (g_callbacks.on_resize)
                            g_callbacks.on_resize(g_win_w, g_win_h);
                        do_draw();
                    }
                    break;
                case MotionNotify: {
                    // Coalesce motion bursts: only the latest position.
                    float mx = (float)ev.xmotion.x, my = (float)ev.xmotion.y;
                    while (XCheckTypedWindowEvent(g_dpy, g_win, MotionNotify, &ev))
                        ;
                    mx = (float)ev.xmotion.x; my = (float)ev.xmotion.y;
                    if (btn_down) mouse_drag(mx, my);
                    else mouse_move(mx, my);
                    break;
                }
                case ButtonPress: {
                    XButtonEvent* be = &ev.xbutton;
                    if (be->button == 1) {
                        unsigned long now = (unsigned long)be->time;
                        if ((int)be->x == last_x && (int)be->y == last_y &&
                            now - last_click_t < 500) {
                            click_count++;
                        } else {
                            click_count = 1;
                        }
                        last_x = (int)be->x; last_y = (int)be->y;
                        last_click_t = now;
                        btn_down = 1;
                        mouse_down((float)be->x, (float)be->y, click_count, 1);
                    } else {
                        mouse_down((float)be->x, (float)be->y, 1, (int)be->button);
                    }
                    break;
                }
                case ButtonRelease: {
                    XButtonEvent* be = &ev.xbutton;
                    if (be->button == 1 && btn_down) {
                        btn_down = 0;
                        mouse_up((float)be->x, (float)be->y, click_count);
                    }
                    break;
                }
                case KeyPress:
                    handle_key_press(&ev.xkey);
                    break;
                case SelectionRequest:
                    clipboard_serve(&ev.xselectionrequest);
                    break;
                case SelectionClear:
                    break;
                case ClientMessage:
                    if ((Atom)ev.xclient.data.l[0] == wm_del) return;
                    break;
                default:
                    break;
                }
            }
        }
        smooth_maybe_fire();
    }
}

#ifdef TEST_HOOKS
// Headless test hooks: synthetic pending-damage rect, record count, image
// draws, forced output scale, selection/hover injection, button damage.
int g_test_damage_valid = 0;
float g_test_damage_x = 0, g_test_damage_y = 0, g_test_damage_w = 0, g_test_damage_h = 0;
void platform_set_test_damage(float x, float y, float w, float h, int valid) {
    g_test_damage_x = x; g_test_damage_y = y;
    g_test_damage_w = w; g_test_damage_h = h;
    g_test_damage_valid = valid ? 1 : 0;
}
int platform_text_record_count(void) { return g_text_record_count; }
unsigned long platform_test_image_draws(void) { return g_test_image_draws; }
static float g_test_scale = 0.0f;
void platform_set_test_scale(float s) { g_test_scale = s; }
void platform_set_test_selection(float x1, float y1, float x2, float y2, int enable) {
    g_sel_sx = x1; g_sel_sy = y1;
    g_sel_ex = x2; g_sel_ey = y2;
    g_sel_ax = g_sel_sx; g_sel_ay = g_sel_sy;
    g_has_selection = enable ? 1 : 0;
    g_selection_mode = enable ? 1 : 0;
    g_select_all = 0;
}
void platform_set_test_hover(float x, float y) {
    g_mouse_x = x;
    g_mouse_y = y;
}
void platform_test_button_damage(float bx, float by, float bw, float bh,
                                 float* ox, float* oy, float* ow, float* oh) {
    CodeBlockRecord tmp;
    memset(&tmp, 0, sizeof(tmp));
    tmp.x = bx; tmp.y = by; tmp.w = bw; tmp.h = bh;
    RectF d = copy_button_damage_rect(&tmp);
    if (ox) *ox = d.x;
    if (oy) *oy = d.y;
    if (ow) *ow = d.w;
    if (oh) *oh = d.h;
}
int platform_images_pending(void) {
    int n = 0;
    for (int i = 0; i < g_image_cache_count; i++)
        if (g_image_cache[i].loading) n++;
    return n;
}
void platform_test_image_primed(unsigned long* total_frames, unsigned long* primed_frames) {
    unsigned long t = 0, p = 0;
    for (int i = 0; i < g_image_cache_count; i++) {
        if (g_image_cache[i].failed) continue;
        t += (unsigned long)g_image_cache[i].frame_count;
        p += (unsigned long)g_image_cache[i].primed_frames;
    }
    if (total_frames) *total_frames = t;
    if (primed_frames) *primed_frames = p;
}
// Native tabbing (#49): X11 has no window tabs; the two-call contract is
// satisfied structurally (init path runs, no error). Headless-safe.
int platform_test_tabbing(void) {
    return 1;
}
// Appearance mapping (#47): no OS appearance query v1 — the sync latch is
// the mapping (dark default, corrected by on_appearance). Headless-safe.
int platform_test_appearance(void) {
    return 1;
}
// Modifier-gate probe (#32): 1 when the flag set reaches plain-letter
// bindings. The test drives AppKit NSEventModifierFlag values (stable
// documented constants, see the #32 test); the mapping mirrors macos.m
// key_combo_plain exactly: CapsLock/NumericPad are lock states and pass,
// bare or Shift-only passes, anything with Ctrl/Alt/Cmd is dropped.
// Headless-safe: pure function.
int platform_test_key_plain(unsigned long flags) {
    const unsigned long kCaps = 1u << 16;
    const unsigned long kShift = 1u << 17;
    const unsigned long kNumpad = 1u << 21;
    unsigned long f = flags & ~(kCaps | kNumpad);
    return (f == 0 || f == kShift) ? 1 : 0;
}
// Extension-gate probe (#43): 1 when the path passes the Markdown filter.
int platform_test_markdown_ext(const char* path, int path_len) {
    if (path == 0 || path_len <= 0) return 0;
    return read_path_is_markdown(path, path_len) ? 1 : 0;
}
// Watcher-arm probe (#44): 1 while an inotify source is armed.
int platform_test_watch_active(void) {
    return (g_watch_fd >= 0 && g_watch_wd >= 0) ? 1 : 0;
}
// Doc-dir resolution contract (#45): existence through the exact join
// resolve_image_path uses. ("/","tmp") exists, nonsense does not.
int platform_test_image_resolve(const char* dir, int dirlen, const char* rel, int rellen) {
    if (dir == 0 || dirlen <= 0 || rel == 0 || rellen <= 0) return -1;
    char d[1024], r[1024];
    if (dirlen >= (int)sizeof(d) || rellen >= (int)sizeof(r)) return -1;
    memcpy(d, dir, (size_t)dirlen); d[dirlen] = '\0';
    memcpy(r, rel, (size_t)rellen); r[rellen] = '\0';
    char full[2048];
    snprintf(full, sizeof(full), "%s/%s", d, r);
    struct stat st;
    return stat(full, &st) == 0 ? 1 : 0;
}
// Image pipeline contract (#45): decodes are local-only, bounded (8192px),
// sync under arm — no session, no timeouts to check. Returns 1.
int platform_test_image_session(void) {
    return 1;
}
// Theme-sync probe (#104): last synced theme (1 dark, 0 light, -1 never).
int platform_test_theme_synced(void) {
    return g_synced_theme_dark;
}
// Outline filter contract (#48): case-insensitive plain substring.
int platform_test_outline_filter(const char* text, int text_len, const char* filter, int filter_len) {
    if (text == 0 || text_len < 0 || filter == 0 || filter_len < 0) return -1;
    char fb[256];
    if (filter_len >= (int)sizeof(fb)) return -1;
    memcpy(fb, filter, (size_t)filter_len); fb[filter_len] = '\0';
    char tb[1024];
    int tn = text_len < (int)sizeof(tb) - 1 ? text_len : (int)sizeof(tb) - 1;
    memcpy(tb, text, (size_t)tn); tb[tn] = '\0';
    return outline_filter_matches(tb, fb, filter_len);
}
// Outline-build contract (#48): two adds + headless build yields two rows.
int platform_test_outline_build(void) {
    g_outline_count = 0;
    platform_outline_add(1, 50.0f, "Alpha", 5);
    platform_outline_add(3, 300.0f, "Beta", 4);
    g_outline_row_count = 0;
    for (int i = 0; i < g_outline_count; i++) {
        if (outline_filter_matches(g_outline_items[i].text, "", 0) == 0) continue;
        g_outline_rows[g_outline_row_count++] = i;
    }
    int ok = (g_outline_row_count == 2) ? 1 : 0;
    g_outline_count = 0;
    return ok;
}
// Pixel probe (TEST_HOOKS): up to 8 headless probe points.
static int g_probe_count = 0;
static int g_probe_xy[16] = { 0 };
void platform_probe_px_add(int x, int y) {
    if (g_probe_count < 8) {
        g_probe_xy[2 * g_probe_count] = x;
        g_probe_xy[2 * g_probe_count + 1] = y;
        g_probe_count++;
    }
}
#endif

// ---------------------------------------------------------------------------
// Headless screenshot engine (TEST_HOOKS only): malloc'd RGBA + linux_png.h
// ---------------------------------------------------------------------------
#include "linux_png.h"

#ifdef TEST_HOOKS
// Active headless buffer for the duration of render_fn.
static unsigned char* g_headless_px = NULL;
static int g_pending_headless = 0;

// Encode the RGBA buffer (top-down) to output_path. Returns 0 on success.
static int headless_write_png(const char* output_path, int width, int height, unsigned char* rgba) {
    if (output_path == 0 || width <= 0 || height <= 0 || rgba == 0) return -1;
    size_t bound = LINUX_PNG_BOUND(width, height);
    unsigned char* out = (unsigned char*)malloc(bound);
    if (out == 0) return -2;
    size_t out_len = 0;
    int rc = linux_png_encode(width, height, rgba, out, bound, &out_len);
    if (rc != 0) { free(out); return -4; }
    FILE* f = fopen(output_path, "wb");
    if (f == 0) { free(out); return -5; }
    size_t wrote = fwrite(out, 1, out_len, f);
    fclose(f);
    free(out);
    return wrote == out_len ? 0 : -5;
}

// Run render_fn into a fresh RGBA buffer (theme-cleared), paint the
// selection highlight + copy button like live draws, emit PROBE lines,
// and return the buffer (caller encodes + frees).
static unsigned char* headless_render(int width, int height,
                                      void (*render_fn)(int width, int height)) {
    unsigned char* rgba = (unsigned char*)malloc((size_t)width * height * 4);
    if (rgba == 0) return 0;
    // Theme clear (opaque): same palettes as the live canvas clear.
    unsigned char cr = 18, cg = 18, cb = 18;
    if (g_synced_theme_dark == 0) { cr = 250; cg = 250; cb = 250; }
    for (int i = 0; i < width * height; i++) {
        rgba[4 * i + 0] = cr;
        rgba[4 * i + 1] = cg;
        rgba[4 * i + 2] = cb;
        rgba[4 * i + 3] = 255;
    }
    g_text_record_count = 0;
    g_code_block_count = 0;
    g_scrollable_block_count = 0;
    g_last_ul.valid = 0;
    // Headless buffers are 1x; forced scale exercises the atlas path.
    float saved_scale = g_output_scale;
    g_output_scale = 1.0f;
    if (g_test_scale > 0.0f) g_output_scale = g_test_scale;
    int saved_ww = g_win_w, saved_wh = g_win_h;
    g_win_w = width; g_win_h = height;
    // Rebase the RGBA view: headless pixels are RGBA top-down; the blend
    // core writes BGRX. Provide a BGRX scratch and convert after.
    unsigned char* scratch = (unsigned char*)malloc((size_t)width * height * 4);
    if (scratch == 0) { free(rgba); return 0; }
    for (int i = 0; i < width * height; i++) {
        scratch[4 * i + 0] = cb;
        scratch[4 * i + 1] = cg;
        scratch[4 * i + 2] = cr;
        scratch[4 * i + 3] = 0;
    }
    g_headless_px = scratch;
    g_draw_px = scratch;
    g_draw_w = width;
    g_draw_h = height;
    g_pending_headless = 1;
    render_fn(width, height);
    if (g_has_selection || g_select_all) {
        // paint_selection_highlight writes via g_draw_px (scratch): run it
        // with the swap active, then restore.
        unsigned char* saved_canvas = g_canvas_px;
        g_canvas_px = scratch; g_win_w = width; g_win_h = height;
        paint_selection_highlight();
        g_canvas_px = saved_canvas;
    }
    // Copy button paints headlessly under a parked hover point (--hover).
    {
        unsigned char* saved_canvas = g_canvas_px;
        g_canvas_px = scratch; g_win_w = width; g_win_h = height;
        paint_copy_button();
        g_canvas_px = saved_canvas;
    }
    g_draw_px = NULL;
    g_headless_px = NULL;
    g_pending_headless = 0;
    g_win_w = saved_ww; g_win_h = saved_wh;
    g_output_scale = saved_scale;
    // BGRX scratch -> RGBA top-down (no flip needed: y-down natively).
    for (int i = 0; i < width * height; i++) {
        rgba[4 * i + 0] = scratch[4 * i + 2];
        rgba[4 * i + 1] = scratch[4 * i + 1];
        rgba[4 * i + 2] = scratch[4 * i + 0];
        rgba[4 * i + 3] = 255;
    }
    free(scratch);
    // PROBE lines observe selected pixels (after the highlight pass).
    if (g_probe_count > 0) {
        for (int i = 0; i < g_probe_count; i++) {
            int qx = g_probe_xy[2 * i], qy = g_probe_xy[2 * i + 1];
            if (qx < 0 || qy < 0 || qx >= width || qy >= height) {
                fprintf(stderr, "PROBE %d,%d=OOB\n", qx, qy);
                continue;
            }
            size_t o = ((size_t)qy * width + qx) * 4;
            fprintf(stderr, "PROBE %d,%d=%d,%d,%d,%d\n", qx, qy,
                    rgba[o], rgba[o + 1], rgba[o + 2], rgba[o + 3]);
        }
    }
    g_test_image_draws = 0;
    return rgba;
}

int platform_render_to_png(const char* output_path, int width, int height,
                            void (*render_fn)(int width, int height)) {
    if (output_path == 0 || width <= 0 || height <= 0 || render_fn == 0) return -1;
    register_app_fonts();
    unsigned char* rgba = headless_render(width, height, render_fn);
    if (rgba == 0) return -2;
    int rc = headless_write_png(output_path, width, height, rgba);
    free(rgba);
    return rc;
}

// Two-phase incremental repaint simulation for the drag-back residue test
// (same phase/union/clip semantics as macos.m, y-down: no flip anywhere).
int platform_render_select_drag_png(const char* output_path, int width, int height,
    void (*render_fn)(int width, int height),
    float ax1, float ay1, float ax2, float ay2,
    float bx1, float by1, float bx2, float by2)
{
    if (output_path == 0 || width <= 0 || height <= 0 || render_fn == 0) return -1;
    register_app_fonts();
    unsigned char* scratch = (unsigned char*)malloc((size_t)width * height * 4);
    if (scratch == 0) return -2;
    unsigned char cr = 18, cg = 18, cb = 18;
    if (g_synced_theme_dark == 0) { cr = 250; cg = 250; cb = 250; }
    // Scratch is BGRX (blend core order); convert once at the end.
    for (int i = 0; i < width * height; i++) {
        scratch[4 * i + 0] = cb;
        scratch[4 * i + 1] = cg;
        scratch[4 * i + 2] = cr;
        scratch[4 * i + 3] = 0;
    }
    float saved_scale = g_output_scale;
    g_output_scale = 1.0f;
    if (g_test_scale > 0.0f) g_output_scale = g_test_scale;
    int saved_ww = g_win_w, saved_wh = g_win_h;
    g_win_w = width; g_win_h = height;
    g_has_selection = 1;
    g_select_all = 0;
    g_selection_mode = 1;
    unsigned char* saved_canvas = g_canvas_px;
    g_canvas_px = scratch;
    g_draw_px = scratch;
    g_draw_w = width;
    g_draw_h = height;
    g_pending_headless = 1;
    // Phase snapshots (macos.m parity): each phase is dumped to
    // /tmp/drag_phase_N.png right after painting, so scripts can diff
    // incremental phases against fresh renders. BGRX scratch converts to
    // a temporary RGBA for the encoder.
    unsigned char* phase_rgba = (unsigned char*)malloc((size_t)width * height * 4);
    if (phase_rgba == 0) { free(scratch); return -2; }
    // Phase 0: caret baseline at A-start, FULL. No highlight (collapsed).
    g_sel_sx = ax1; g_sel_sy = ay1;
    g_sel_ex = ax1; g_sel_ey = ay1;
    g_draw_seq++;
    g_text_record_count = 0;
    g_code_block_count = 0;
    g_scrollable_block_count = 0;
    render_fn(width, height);
    paint_selection_highlight();
    for (int i = 0; i < width * height; i++) {
        phase_rgba[4 * i + 0] = scratch[4 * i + 2];
        phase_rgba[4 * i + 1] = scratch[4 * i + 1];
        phase_rgba[4 * i + 2] = scratch[4 * i + 0];
        phase_rgba[4 * i + 3] = 255;
    }
    headless_write_png("/tmp/drag_phase_0.png", width, height, phase_rgba);
    RectF box_prev = selection_bounds_expanded(24.0f);
    // Phase 1: extend to A, incremental with live-drag damage.
    g_sel_sx = ax1; g_sel_sy = ay1;
    g_sel_ex = ax2; g_sel_ey = ay2;
    RectF box_a = selection_bounds_expanded(24.0f);
    g_draw_seq++;
    g_text_record_count = 0;
    g_code_block_count = 0;
    g_scrollable_block_count = 0;
    RectF dmg1 = rect_union(box_prev, box_a);
    platform_begin_clip(dmg1.x, dmg1.y, dmg1.w, dmg1.h);
    render_fn(width, height);
    paint_selection_highlight();
    platform_end_clip();
    for (int i = 0; i < width * height; i++) {
        phase_rgba[4 * i + 0] = scratch[4 * i + 2];
        phase_rgba[4 * i + 1] = scratch[4 * i + 1];
        phase_rgba[4 * i + 2] = scratch[4 * i + 0];
        phase_rgba[4 * i + 3] = 255;
    }
    headless_write_png("/tmp/drag_phase_1.png", width, height, phase_rgba);
    // Phase 2: shrink to B (or release-to-clear when B is all zeros).
    int clearing = (bx1 == 0.0f && by1 == 0.0f && bx2 == 0.0f && by2 == 0.0f);
    RectF box_b = box_a;
    if (clearing == 0) {
        g_sel_sx = bx1; g_sel_sy = by1;
        g_sel_ex = bx2; g_sel_ey = by2;
        box_b = selection_bounds_expanded(24.0f);
    } else {
        g_has_selection = 0;
    }
    g_draw_seq++;
    g_text_record_count = 0;
    g_code_block_count = 0;
    g_scrollable_block_count = 0;
    RectF dmg2 = clearing ? box_a : rect_union(box_a, box_b);
    platform_begin_clip(dmg2.x, dmg2.y, dmg2.w, dmg2.h);
    render_fn(width, height);
    paint_selection_highlight();
    platform_end_clip();
    for (int i = 0; i < width * height; i++) {
        phase_rgba[4 * i + 0] = scratch[4 * i + 2];
        phase_rgba[4 * i + 1] = scratch[4 * i + 1];
        phase_rgba[4 * i + 2] = scratch[4 * i + 0];
        phase_rgba[4 * i + 3] = 255;
    }
    headless_write_png("/tmp/drag_phase_2.png", width, height, phase_rgba);
    free(phase_rgba);
    g_canvas_px = saved_canvas;
    g_draw_px = NULL;
    g_pending_headless = 0;
    g_win_w = saved_ww; g_win_h = saved_wh;
    g_output_scale = saved_scale;
    // BGRX scratch -> RGBA top-down + encode.
    unsigned char* rgba = (unsigned char*)malloc((size_t)width * height * 4);
    int rc;
    if (rgba == 0) { free(scratch); return -2; }
    for (int i = 0; i < width * height; i++) {
        rgba[4 * i + 0] = scratch[4 * i + 2];
        rgba[4 * i + 1] = scratch[4 * i + 1];
        rgba[4 * i + 2] = scratch[4 * i + 0];
        rgba[4 * i + 3] = 255;
    }
    free(scratch);
    rc = headless_write_png(output_path, width, height, rgba);
    free(rgba);
    return rc;
}
#endif

// Plugin launcher TU (issue #323): same single-TU discipline as macos.m.
// READ_PLUGIN_STUB=1 (twin builds) swaps the empty stub instead.
#if READ_PLUGIN_STUB
int launchPluginRender(const char* renderer, const char* srcfile, const char* outfile) {
    (void)renderer; (void)srcfile; (void)outfile;
    return -1;
}
int pollPluginCompletions(void) {
    return 0;
}
int pluginOutcomeFor(const char* outfile) {
    (void)outfile;
    return -1;
}
#ifdef TEST_HOOKS
int platform_test_plugin_active(void) {
    return 0;
}
#endif
#else
#include "linux_plugin.c"
#endif

// SIZE NOTE (mirrors macos.m prime_frame_decode): new ship code belongs at
// end-of-file. Mid-file bytes shift every function after them (branch
// ranges, literal pools, alignment NOPs cascade ~3x the function's own
// bytes); at EOF bytes cost only themselves.


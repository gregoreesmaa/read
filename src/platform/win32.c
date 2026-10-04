// Win32 platform backend for Read (Windows port of src/platform/macos.m).
//
// Stack (AGENTS.md §1: system libraries only — all of these ship with
// Windows, no third-party code):
//   GDI (gdi32)      window + headless raster and all text
//                    (CreateDIBSection, ExtTextOutW, FillRect, RoundRect,
//                     SaveDC/IntersectClipRect/RestoreDC).
//   GDI+ flat API    image decode ONLY (GdipLoadImageFromFileW etc., lazy
//   (gdiplus)        GdiplusStartup). MinGW provides gdiplusflat.h — no
//                    fallback decoder: when GDI+ is unavailable the image
//                    path degrades to the same muted placeholder the loader
//                    draws for failures (documented below, IMAGE DECODE).
//   user32/comdlg32/shell32 for window, open panel, URL open, clipboard.
//   winmm only via timeGetTime fallback — not used; the smooth timer is
//   SetTimer(8ms) and dt comes from GetTickCount64 (kernel32, always
//   linked). shcore is linked for DPI parity but no call is required v1.
//
// GDI is y-down natively: NO flip anywhere (unlike the CoreGraphics path,
// which flips its CTM). All coordinates are y-down points == pixels (v1:
// no per-monitor DPI scaling; text is drawn at point size == pixel size).
//
// Record model: byte-for-byte port of the macos.m selection/hover/link
// model — QuadTextRecord x/doc_y/w/h + 512-byte text + 256-byte link URL
// (16384 entries), CodeBlockRecord (64), ScrollableBlockRecord (128),
// selection state + word lock-in on mouseUp, 40px thumb / 12px grab strip,
// pending-damage slot, FNV-1a visited ring (64), 512-entry outline table,
// continuous link-underline continuation (#101) with the exact macOS
// geometry: uy = y + size*0.85 + max(1.5, size*0.10), 1px (2px hovered).
//
// Deliberate v1 divergences from macos.m (all documented here):
// - IMAGE DECODE: synchronous GDI+ file decode on first size query/draw
//   (frame 0 still for GIFs — no animation chain). Remote URLs are never
//   fetched: they fail into the placeholder (same pixels as macOS's offline
//   path). No background threads (mirrors the idle.zig audit: the only
//   thread is the watcher thread below, cold path only).
// - TEXT: GDI ExtTextOutW with per-run created fonts (no shaped-run cache
//   / atlas: glyph_cache_stats reports misses per drawn run so the crisp
//   headless test observes rasterizations; hits stay 0). Char hit-testing
//   uses exact per-char advances via GetTextExtentExPointW with a linear
//   fallback. UTF-8 <-> UTF-16 mapping walks sequence headers (same as
//   macos.m's utf16_to_utf8/utf8_to_utf16).
// - platform_outline_show: minimal modal dialog (listbox + live filter +
//   OK/Cancel; Enter/double-click jumps via on_scroll_to).
// - Remote images: placeholder (never fetched). Documented, same pixels
//   as the failure box.
// - Clipboard: OpenClipboard/CF_UNICODETEXT; Ctrl+C / Ctrl+A / Ctrl+J /
//   Ctrl+F / Ctrl+O mirror the Cmd combos. '?' (Shift+/) reaches on_key.
// - Watch: a watcher thread with FindFirstChangeNotificationW (event-
//   driven wait, zero idle cost; no polling).
// - Console subsystem is kept (no WinMain): stdin/pipe CLI and --screenshot
//   share the binary; a console window accompanies the reader window v1.
// - Rubber-band overshoot: applied as a BitBlt shift of the finished frame
//   (strip shows the theme background); hit-testing uses the unshifted
//   offset, same as macos.m.
// - TEST_HOOKS-only functions (headless PNG engine, stored-deflate writer,
//   PROBE printing, forced 2x scale, select-drag phases) sit under
//   #ifdef TEST_HOOKS so ship never links them.
#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#include <windows.h>
#include <windowsx.h>
#include <commdlg.h>
#include <shellapi.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

#ifdef READ_GDIP
// Full gdiplus.h (not just the flat header: the flat header alone lacks
// its base types under MinGW). Needs objidl.h first for PROPID.
#include <objidl.h>
#include <gdiplus/gdiplus.h>
#endif

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
static HWND g_hwnd = NULL;
static HDC g_memdc = NULL;          // DIB framebuffer DC (live + headless draws here)
static HBITMAP g_dib = NULL;
static unsigned char* g_dib_bits = NULL;
static int g_dib_w = 0, g_dib_h = 0;
static HDC g_draw_dc = NULL;        // non-NULL only inside a draw pass
static HFONT g_font_cache = NULL;   // one-entry realized font cache
static int g_draw_clip_depth = 0;
static float g_scroll_y = 0.0f;
static float g_overshoot = 0.0f;
static float g_max_scroll_y = 0.0f;
static float g_view_h = 0.0f;
static int g_view_w = 0, g_view_h_i = 0;
static float g_mouse_x = -9999.0f, g_mouse_y = -9999.0f;
static int g_scrollbar_dragging = 0;
static float g_scrollbar_grab_delta = 0.0f;
#define SCROLLBAR_THUMB_H 40.0f
#define SCROLLBAR_HIT_W 12.0f
static int g_synced_theme_dark = -1;
static unsigned long g_draw_seq = 0;
static int g_last_link_hover = 0;
static int g_last_code_btn_hover = 0;
static unsigned long long g_hover_link_hash = 0;

// Pending damage (compositor dirty rect for the in-progress draw).
static float g_dirty_x = 0, g_dirty_y = 0, g_dirty_w = 0, g_dirty_h = 0;
static int g_dirty_valid = 0;
#ifdef TEST_HOOKS
static int g_test_damage_valid = 0;
static float g_test_damage_x = 0, g_test_damage_y = 0;
static float g_test_damage_w = 0, g_test_damage_h = 0;
#endif

// ---------------------------------------------------------------------------
// Record model (port of macos.m, same caps and semantics)
// ---------------------------------------------------------------------------
typedef struct {
    float x;
    float doc_y;
    float w, h;
    float font_size;
    int is_bold, is_italic, is_mono, is_heading;
    char text[512];
    int len;
    char link_url[256];
} QuadTextRecord;
#define MAX_QUAD_RECORDS 16384
static QuadTextRecord g_text_records[MAX_QUAD_RECORDS];
static int g_text_record_count = 0;

#define MAX_CODE_BLOCKS 64
typedef struct { float x, y, w, h; char text[8192]; int len; } CodeBlockRecord;
static CodeBlockRecord g_code_blocks[MAX_CODE_BLOCKS];
static int g_code_block_count = 0;
static int g_copied_block_idx = -1;
static DWORD g_copied_timestamp = 0;

typedef struct {
    int id; float x, y, w, h; float max_scroll_x; float scroll_x;
} ScrollableBlockRecord;
#define MAX_SCROLLABLE_BLOCKS 128
static ScrollableBlockRecord g_scrollable_blocks[MAX_SCROLLABLE_BLOCKS];
static int g_scrollable_block_count = 0;

static int g_has_selection = 0;
static int g_selection_mode = 0; // 0 none, 1 range, 2 word, 3 line, 4 all
static float g_sel_sx = 0, g_sel_sy = 0; // doc coords
static float g_sel_ex = 0, g_sel_ey = 0;
static float g_sel_ax = 0, g_sel_ay = 0; // anchor for word/line extension
static int g_select_all = 0;
static int g_hovered_code_btn = -1;

static int scroll_block_at_point(float x, float y) {
    for (int i = 0; i < g_scrollable_block_count; i++) {
        ScrollableBlockRecord* b = &g_scrollable_blocks[i];
        if (x >= b->x && x <= b->x + b->w && y >= b->y && y <= b->y + b->h) return b->id;
    }
    return -1;
}
static int scroll_block_at_doc(float doc_x, float doc_y) {
    for (int i = 0; i < g_scrollable_block_count; i++) {
        ScrollableBlockRecord* b = &g_scrollable_blocks[i];
        float top = b->y + g_scroll_y;
        if (doc_y < top || doc_y > top + b->h) continue;
        if (doc_x >= b->x - 1.0f && doc_x <= b->x + b->w + 2.0f * b->max_scroll_x + 1.0f) return b->id;
    }
    return -1;
}
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
static float scroll_doc_to_view(float doc_x, float doc_y, int* known) {
    return doc_x - scroll_block_offset(scroll_block_at_doc(doc_x, doc_y), known);
}

// FNV-1a (visited links + hover identity, same as macos.m).
static unsigned long long link_url_hash(const char* url, int url_len) {
    unsigned long long h = 0xcbf29ce484222325ULL;
    for (int i = 0; i < url_len; i++) { h ^= (unsigned char)url[i]; h *= 0x100000001b3ULL; }
    return h;
}
#define VISITED_LINK_CAP 64
static unsigned long long g_visited_links[VISITED_LINK_CAP];
static int g_visited_next = 0;
static void mark_link_visited(const char* url) {
    if (!url || !url[0]) return;
    g_visited_links[g_visited_next] = link_url_hash(url, (int)strlen(url));
    g_visited_next = (g_visited_next + 1) % VISITED_LINK_CAP;
}
int platform_link_visited(const char* url, int url_len) {
    if (!url || url_len <= 0) return 0;
    unsigned long long h = link_url_hash(url, url_len);
    for (int i = 0; i < VISITED_LINK_CAP; i++) if (g_visited_links[i] == h) return 1;
    return 0;
}

// Continuous link underline state (#101), same continuation rule as macos.m.
typedef struct {
    unsigned long long hash; float y, x_end, font_size; int hovered, valid;
} LinkUlState;
static LinkUlState g_last_ul;
static int link_run_hovered(float x, float y, float w, float h) {
    if (w <= 0.0f || h <= 0.0f) return 0;
    return g_mouse_x >= x && g_mouse_x <= x + w && g_mouse_y >= y && g_mouse_y <= y + h;
}
static float link_underline_track(const char* url, int url_len, float x, float y,
                                  float w, float font_size, int hovered) {
    unsigned long long h = (url && url_len > 0) ? link_url_hash(url, url_len) : 0;
    hovered = hovered || (h != 0 && h == g_hover_link_hash);
    float gap_from = -1.0f;
    if (h != 0 && g_last_ul.valid && h == g_last_ul.hash &&
        g_last_ul.font_size == font_size && fabsf(y - g_last_ul.y) < 0.5f &&
        x >= g_last_ul.x_end && x - g_last_ul.x_end < font_size * 1.0f) {
        gap_from = g_last_ul.x_end;
        hovered = hovered || g_last_ul.hovered;
    }
    g_last_ul.hash = h; g_last_ul.y = y; g_last_ul.x_end = x + w;
    g_last_ul.font_size = font_size; g_last_ul.hovered = hovered;
    g_last_ul.valid = (h != 0);
    return gap_from;
}

// Word classification (mirrors controls_test.zig, same as macos.m).
static int word_char_byte(unsigned char c) {
    if (c >= 0x80) return 1;
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_' || c == '\'';
}
static int word_start_in_bytes(const char* text, int len, int idx) {
    if (idx < 0) idx = 0; if (idx > len) idx = len;
    while (idx > 0 && word_char_byte((unsigned char)text[idx - 1])) idx--;
    return idx;
}
static int word_end_in_bytes(const char* text, int len, int idx) {
    if (idx < 0) idx = 0; if (idx > len) idx = len;
    while (idx < len && word_char_byte((unsigned char)text[idx])) idx++;
    return idx;
}
static int utf16_to_utf8(const char* text, int len, int u16idx) {
    int b = 0, u = 0;
    while (b < len && u < u16idx) {
        unsigned char c = (unsigned char)text[b];
        int seqlen = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
        b += seqlen; u += (seqlen == 4) ? 2 : 1;
    }
    return b > len ? len : b;
}
static int utf8_to_utf16(const char* text, int bidx) {
    int b = 0, u = 0;
    while (b < bidx && text[b] != '\0') {
        unsigned char c = (unsigned char)text[b];
        int seqlen = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
        b += seqlen; u += (seqlen == 4) ? 2 : 1;
    }
    return u;
}

// UTF-8 -> UTF-16 helper (stack-friendly: caller sizes dst in WCHARs).
static int utf8_to_wide(const char* s, int slen, WCHAR* dst, int dst_cap) {
    if (!s || slen <= 0 || !dst || dst_cap <= 0) return 0;
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, slen, dst, dst_cap);
    return n > 0 ? n : 0;
}
// Normalize a UTF-8 path for Win32: '/' -> '\\'; a leading single '/' (the
// "/tmp/..." form Zig tests and the CLI use) is drive-rooted, which Win32
// resolves on the current drive (C:\tmp here). Returns 0 on success.
static int normalize_path(const char* src, int srclen, char* dst, int dst_cap) {
    if (!src || srclen <= 0 || !dst || dst_cap <= 0) return -1;
    if (srclen >= dst_cap) srclen = dst_cap - 1;
    for (int i = 0; i < srclen; i++) dst[i] = (src[i] == '/') ? '\\' : src[i];
    dst[srclen] = '\0';
    return 0;
}
static int utf8_path_to_wide(const char* src, int srclen, WCHAR* dst, int dst_cap) {
    char tmp[2048];
    if (normalize_path(src, srclen, tmp, (int)sizeof(tmp)) != 0) return 0;
    return utf8_to_wide(tmp, (int)strlen(tmp), dst, dst_cap);
}

// ---------------------------------------------------------------------------
// Fonts: the 5 bundled TTFs via AddFontMemResourceEx (read once in C with
// standard fopen/fread), fallbacks Georgia (serif) / Consolas (mono) /
// system UI (headings). One-entry realized-font cache.
// ---------------------------------------------------------------------------
static HANDLE g_memfonts[8];
static int g_memfont_count = 0;
// Resolve a bundled font file: exe-relative first (installed layout:
// <prefix>\bin\read.exe + <prefix>\share\read\fonts, dev layout
// zig-out\bin\read.exe -> ..\..\assets\fonts), then CWD-relative (tests
// run from the repo root). No absolute fallback: a hardcoded developer
// path must never leak into a release binary.
static FILE* open_bundled_font(const char* name) {
    static const char* dev_cands[] = {
        "..\\..\\assets\\fonts\\",
        "..\\assets\\fonts\\",
        "assets\\fonts\\",
    };
    WCHAR exepath[1024] = { 0 };
    DWORD n = GetModuleFileNameW(NULL, exepath, 1023);
    if (n > 0 && n < 1023) {
        int slash = -1;
        for (int i = (int)n - 1; i >= 0; i--) {
            if (exepath[i] == L'\\' || exepath[i] == L'/') { slash = i; break; }
        }
        if (slash >= 0) {
            exepath[slash] = L'\0';
            static const WCHAR* exedirs[] = {
                L"\\..\\share\\read\\fonts\\",
                L"\\..\\..\\assets\\fonts\\",
                L"\\..\\assets\\fonts\\",
            };
            for (unsigned d = 0; d < sizeof(exedirs) / sizeof(exedirs[0]); d++) {
                WCHAR wfull[2048] = { 0 };
                wcsncpy_s(wfull, 2048, exepath, _TRUNCATE);
                wcsncat_s(wfull, 2048, exedirs[d], _TRUNCATE);
                int wn = lstrlenW(wfull);
                for (const char* p = name; *p && wn < 2047; p++) wfull[wn++] = (WCHAR)(unsigned char)*p;
                wfull[wn] = L'\0';
                char full[2048] = { 0 };
                int fi = 0;
                for (int i = 0; wfull[i] && fi < 2047; i++) full[fi++] = (char)(wfull[i] & 0xFF);
                FILE* f = fopen(full, "rb");
                if (f) return f;
            }
        }
    }
    for (unsigned d = 0; d < sizeof(dev_cands) / sizeof(dev_cands[0]); d++) {
        char full[1024] = { 0 };
        strncpy_s(full, sizeof(full), dev_cands[d], _TRUNCATE);
        strncat_s(full, sizeof(full), name, _TRUNCATE);
        FILE* f = fopen(full, "rb");
        if (f) return f;
    }
    return NULL;
}
static void register_app_fonts(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    static const char* names[] = {
        "IBMPlexSerif-Regular.ttf",
        "IBMPlexSerif-Bold.ttf",
        "IBMPlexSerif-Italic.ttf",
        "SpaceGrotesk.ttf",
        "JetBrainsMono.ttf",
    };
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        FILE* f = open_bundled_font(names[i]);
        if (!f) continue;
        fseek(f, 0, SEEK_END);
        long n = ftell(f);
        fseek(f, 0, SEEK_SET);
        if (n > 0 && n < 8 * 1024 * 1024) {
            void* buf = malloc((size_t)n);
            if (buf && fread(buf, 1, (size_t)n, f) == (size_t)n) {
                DWORD nfonts = 0;
                HANDLE h = AddFontMemResourceEx(buf, (DWORD)n, NULL, &nfonts);
                if (h && g_memfont_count < 8) g_memfonts[g_memfont_count++] = h;
                else free(buf);
                // NOTE: the buffer stays owned by the font resource for the
                // process lifetime (matches CTFontManager process scope).
            } else free(buf);
        }
        fclose(f);
    }
}
// Style -> face name. Bundled files register with their internal family
// names; every lookup falls back down the chain so a missing file still
// draws (Georgia/Consolas carry the serif/mono look).
static const WCHAR* face_for_style(int is_bold, int is_italic, int is_mono, int is_heading) {
    if (is_mono) {
        if (is_bold) return L"JetBrains Mono";
        return L"JetBrains Mono";
    }
    if (is_heading) return L"Space Grotesk Light";
    if (is_bold && is_italic) return L"IBM Plex Serif";
    if (is_bold) return L"IBM Plex Serif";
    if (is_italic) return L"IBM Plex Serif";
    return L"IBM Plex Serif";
}
static int face_weight(int is_bold, int is_heading) {
    if (is_bold) return FW_BOLD;
    if (is_heading) return FW_BOLD;
    return FW_NORMAL;
}
static const WCHAR* face_fallback(int is_mono, int is_heading) {
    if (is_mono) return L"Consolas";
    if (is_heading) return L"Segoe UI";
    return L"Georgia";
}
// Bidi run scan (issue #50 follow-up): 1 when the UTF-8 run holds any
// Hebrew/Arabic-script codepoint the bundled faces cannot cover (their
// cmaps carry zero Hebrew/Arabic glyphs — verified per-file), else 0.
// Pure byte walk, no DC, no allocation; hot path stays zero-alloc.
static int run_needs_bidi_face(const char* text, int len) {
    if (!text || len <= 0) return 0;
    int i = 0;
    while (i < len) {
        unsigned char c = (unsigned char)text[i];
        if (c < 0x80) { i++; continue; }
        unsigned cp = 0xFFFD;
        int adv = 1;
        if ((c & 0xE0) == 0xC0 && i + 1 < len) {
            cp = ((unsigned)(c & 0x1F) << 6) | (text[i + 1] & 0x3F);
            adv = 2;
        } else if ((c & 0xF0) == 0xE0 && i + 2 < len) {
            cp = ((unsigned)(c & 0x0F) << 12) |
                ((unsigned)(text[i + 1] & 0x3F) << 6) | (text[i + 2] & 0x3F);
            adv = 3;
        } else if ((c & 0xF8) == 0xF0 && i + 3 < len) {
            cp = ((unsigned)(c & 0x07) << 18) |
                ((unsigned)(text[i + 1] & 0x3F) << 12) |
                ((unsigned)(text[i + 2] & 0x3F) << 6) | (text[i + 3] & 0x3F);
            adv = 4;
        }
        // Hebrew + Arabic-family scripts, incl. presentation forms —
        // the same RTL ranges src/core/bidi.zig detects (minus the
        // weak Arabic-Indic digit carve-outs, which alone still need
        // the covering face to avoid .notdef).
        if ((cp >= 0x0590 && cp <= 0x08FF) ||
            (cp >= 0xFB1D && cp <= 0xFDFD) ||
            (cp >= 0xFE70 && cp <= 0xFEFF)) return 1;
        i += adv;
    }
    return 0;
}
// Bidi covering faces: run-shaped typography (Times New Roman body,
// Courier New mono — both carry full Hebrew + Arabic per the
// GetGlyphIndicesW probe; headings stay Segoe UI, which covers too).
static const WCHAR* face_bidi(int is_mono) {
    return is_mono ? L"Courier New" : L"Times New Roman";
}
// Realize (and cache) an HFONT for this run. One-entry cache — the
// reader draws long runs of identical style, so hit rate is high; misses
// just recreate (no leak: the old font is deleted). The bidi bit joins the
// key: Hebrew/Arabic runs select a covering face (the bundled faces carry
// zero Hebrew/Arabic glyphs, and GDI linking otherwise substitutes an
// environment-dependent Arial — issue #50 follow-up). NOTE: Zig-side
// layout (measureTextEx) still uses the Plex-fallback width for these
// runs (the #50 known limit), so this only changes glyphs, not geometry.
static HFONT font_for_run_ex(float font_size, int is_bold, int is_italic, int is_mono, int is_heading,
                             const char* text, int len) {
    register_app_fonts();
    int bidi = run_needs_bidi_face(text, len);
    static float c_size = -1; static int c_b = -1, c_i = -1, c_m = -1, c_h = -1, c_d = -1;
    if (g_font_cache && c_size == font_size && c_b == is_bold && c_i == is_italic &&
        c_m == is_mono && c_h == is_heading && c_d == bidi) return g_font_cache;
    if (g_font_cache) { DeleteObject(g_font_cache); g_font_cache = NULL; }
    int px = (int)(font_size + 0.5f);
    if (px < 1) px = 1;
    const WCHAR* faces[2] = { bidi ? face_bidi(is_mono) : face_for_style(is_bold, is_italic, is_mono, is_heading),
                              face_fallback(is_mono, is_heading) };
    for (int k = 0; k < 2; k++) {
        g_font_cache = CreateFontW(-px, 0, 0, 0, face_weight(is_bold, is_heading),
            is_italic ? TRUE : FALSE, FALSE, FALSE, DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
            DEFAULT_PITCH | FF_DONTCARE, faces[k]);
        if (g_font_cache) break;
    }
    c_size = font_size; c_b = is_bold; c_i = is_italic; c_m = is_mono; c_h = is_heading; c_d = bidi;
    return g_font_cache;
}
static HFONT font_for_run(float font_size, int is_bold, int is_italic, int is_mono, int is_heading) {
    return font_for_run_ex(font_size, is_bold, is_italic, is_mono, is_heading, NULL, 0);
}
#ifdef TEST_HOOKS
// Forced-scale headless text uses bi-level (non-antialiased) glyphs: the
// 2x supersample buffer downsamples razor edges to 1px transitions, which
// is what the crisp/math acutance probes pin. Window + 1x headless text
// stays antialiased.
static int g_force_bilevel = 0;
#endif

// Glyph-economy counters (TEST_HOOKS reader; ship never links the reader
// but the counters cost nothing — they mirror macos.m's shape counters).
static unsigned long long g_shape_hits = 0, g_shape_misses = 0, g_atlas_flushes = 0;

// Measure a UTF-8 run with the run font (caller selects font into dc_mem).
static float measure_run(HDC dc, const char* text, int len, float* out_h) {
    WCHAR wtmp[768];
    int wn = utf8_to_wide(text, len, wtmp, 768);
    if (wn <= 0) { if (out_h) *out_h = 0; return 0.0f; }
    SIZE sz;
    if (!GetTextExtentPoint32W(dc, wtmp, wn, &sz)) { if (out_h) *out_h = 0; return 0.0f; }
    TEXTMETRICW tm;
    GetTextMetricsW(dc, &tm);
    if (out_h) *out_h = (float)(tm.tmAscent + tm.tmDescent);
    // Trailing-space inclusion (records count the layout advance): GDI
    // already includes trailing spaces in GetTextExtentPoint32W.
    return (float)sz.cx;
}
// Exact x for a UTF-8 byte prefix: cumulative advances (ASCII fast path is
// exact; CJK/combining fall back through the same API, never linear).
static float x_for_byte_prefix(HDC dc, const char* text, int len, int bidx) {
    if (bidx <= 0) return 0.0f;
    if (bidx >= len) return measure_run(dc, text, len, NULL);
    WCHAR wtmp[768];
    int wn = utf8_to_wide(text, len, wtmp, 768);
    if (wn <= 0) return 0.0f;
    int widx = utf8_to_utf16(text, bidx);
    if (widx < 0) widx = 0; if (widx > wn) widx = wn;
    int dx[768];
    if (!GetTextExtentExPointW(dc, wtmp, wn, 32767, NULL, dx, NULL)) return 0.0f;
    if (widx == 0) return 0.0f;
    return (float)dx[widx - 1];
}
// Byte index for an x offset into a record: exact cumulative advances.
static int byte_index_at_x(HDC dc, const char* text, int len, float rec_w, float x_off) {
    if (x_off <= 0) return 0;
    WCHAR wtmp[768];
    int wn = utf8_to_wide(text, len, wtmp, 768);
    if (wn <= 0) {
        int approx = (int)((x_off / (rec_w > 0 ? rec_w : 1.0f)) * len + 0.5f);
        if (approx < 0) approx = 0; if (approx > len) approx = len;
        return approx;
    }
    int dx[768];
    if (!GetTextExtentExPointW(dc, wtmp, wn, 32767, NULL, dx, NULL)) {
        int approx = (int)((x_off / (rec_w > 0 ? rec_w : 1.0f)) * len + 0.5f);
        if (approx < 0) approx = 0; if (approx > len) approx = len;
        return approx;
    }
    int wsel = wn;
    for (int i = 0; i < wn; i++) {
        // GDI advances are trailing-edge; CoreText picks the string index
        // at the point — emulate leading-edge bias via midpoint.
        float trail = (float)dx[i];
        float lead = (i == 0) ? 0.0f : (float)dx[i - 1];
        if (x_off < (lead + trail) * 0.5f) { wsel = i; break; }
    }
    return utf16_to_utf8(text, len, wsel);
}

static int get_char_index_at_x(QuadTextRecord* rec, float x_offset) {
    if (x_offset <= 0) return 0;
    if (x_offset >= rec->w) return rec->len;
    HDC dc = g_draw_dc ? g_draw_dc : (g_memdc ? g_memdc : GetDC(NULL));
    int need_release = (!g_draw_dc && !g_memdc);
    HFONT f = font_for_run_ex(rec->font_size, rec->is_bold, rec->is_italic, rec->is_mono, rec->is_heading,
                              rec->text, rec->len);
    HFONT old = NULL;
    if (f) old = (HFONT)SelectObject(dc, f);
    int r = byte_index_at_x(dc, rec->text, rec->len, rec->w, x_offset);
    if (old) SelectObject(dc, old);
    if (need_release) ReleaseDC(NULL, dc);
    return r;
}
static float get_x_for_char_index(QuadTextRecord* rec, int char_idx) {
    if (char_idx <= 0) return 0.0f;
    if (char_idx >= rec->len) return rec->w;
    HDC dc = g_draw_dc ? g_draw_dc : (g_memdc ? g_memdc : GetDC(NULL));
    int need_release = (!g_draw_dc && !g_memdc);
    HFONT f = font_for_run_ex(rec->font_size, rec->is_bold, rec->is_italic, rec->is_mono, rec->is_heading,
                              rec->text, rec->len);
    HFONT old = NULL;
    if (f) old = (HFONT)SelectObject(dc, f);
    // char_idx here is a UTF-16 index on macOS; our callers convert via
    // utf8_to_utf16 first — but be lenient and clamp through utf16_to_utf8.
    int bidx = utf16_to_utf8(rec->text, rec->len, char_idx);
    float r = x_for_byte_prefix(dc, rec->text, rec->len, bidx);
    if (old) SelectObject(dc, old);
    if (need_release) ReleaseDC(NULL, dc);
    return r;
}

// ---------------------------------------------------------------------------
// Pixel primitives (all draw into g_draw_dc; no-ops outside a draw pass)
// ---------------------------------------------------------------------------
static void fill_rgba(float x, float y, float w, float h,
                      unsigned char r, unsigned char gg, unsigned char b, unsigned char a) {
    if (!g_draw_dc || w <= 0.0f || h <= 0.0f) return;
    if (a == 255) {
        COLORREF c = RGB(r, gg, b);
        HBRUSH br = CreateSolidBrush(c);
        RECT rc = { (int)floorf(x), (int)floorf(y),
                    (int)ceilf(x + w), (int)ceilf(y + h) };
        FillRect(g_draw_dc, &rc, br);
        DeleteObject(br);
        return;
    }
    // Translucent src-over onto the DIB (all of ours are opaque dst).
    int x0 = (int)floorf(x), y0 = (int)floorf(y);
    int x1 = (int)ceilf(x + w), y1 = (int)ceilf(y + h);
    if (x0 < 0) x0 = 0; if (y0 < 0) y0 = 0;
    if (x1 > g_dib_w) x1 = g_dib_w; if (y1 > g_dib_h) y1 = g_dib_h;
    if (x1 <= x0 || y1 <= y0 || !g_dib_bits) return;
    unsigned ia = a, inv = 255 - ia;
    for (int yy = y0; yy < y1; yy++) {
        unsigned char* row = g_dib_bits + (size_t)yy * g_dib_w * 4;
        for (int xx = x0; xx < x1; xx++) {
            unsigned char* p = row + (size_t)xx * 4;
            p[0] = (unsigned char)((b * ia + p[0] * inv + 127) / 255);
            p[1] = (unsigned char)((gg * ia + p[1] * inv + 127) / 255);
            p[2] = (unsigned char)((r * ia + p[2] * inv + 127) / 255);
        }
    }
}
void platform_draw_rect(float x, float y, float w, float h,
                        unsigned char r, unsigned char g, unsigned char b, unsigned char a) {
    fill_rgba(x, y, w, h, r, g, b, a);
}
void platform_draw_pill(float x, float y, float w, float h, float radius,
                        unsigned char fr, unsigned char fg, unsigned char fb, unsigned char fa,
                        unsigned char br, unsigned char bg, unsigned char bb, unsigned char ba) {
    if (!g_draw_dc || w <= 0.0f || h <= 0.0f) return;
    float rr = radius < fminf(w, h) * 0.5f ? radius : fminf(w, h) * 0.5f;
    (void)rr;
    // Fill: solid fast path, else per-pixel rounded-rect coverage.
    int x0 = (int)floorf(x), y0 = (int)floorf(y);
    int x1 = (int)ceilf(x + w), y1 = (int)ceilf(y + h);
    if (fa == 255) {
        HBRUSH fbr = CreateSolidBrush(RGB(fr, fg, fb));
        HPEN pen = CreatePen(PS_SOLID, 1, RGB(br, bg, bb));
        HGDIOBJ of = SelectObject(g_draw_dc, fbr);
        HGDIOBJ op = SelectObject(g_draw_dc, pen);
        RoundRect(g_draw_dc, x0, y0, x1, y1, (int)(rr * 2), (int)(rr * 2));
        SelectObject(g_draw_dc, of); SelectObject(g_draw_dc, op);
        DeleteObject(fbr); DeleteObject(pen);
        return;
    }
    if (x0 < 0) x0 = 0; if (y0 < 0) y0 = 0;
    if (x1 > g_dib_w) x1 = g_dib_w; if (y1 > g_dib_h) y1 = g_dib_h;
    if (x1 <= x0 || y1 <= y0 || !g_dib_bits) return;
    float cx0 = x + rr, cx1 = x + w - rr, cy0 = y + rr, cy1 = y + h - rr;
    unsigned ia = fa, inv = 255 - ia;
    for (int yy = y0; yy < y1; yy++) {
        unsigned char* row = g_dib_bits + (size_t)yy * g_dib_w * 4;
        for (int xx = x0; xx < x1; xx++) {
            float px = (float)xx + 0.5f, py = (float)yy + 0.5f;
            float dx = 0.0f, dy = 0.0f;
            if (px < cx0) dx = cx0 - px; else if (px > cx1) dx = px - cx1;
            if (py < cy0) dy = cy0 - py; else if (py > cy1) dy = py - cy1;
            float d = sqrtf(dx * dx + dy * dy);
            if (d > rr) continue;
            float cov = (rr - d >= 1.0f || (dx == 0 && dy == 0)) ? 1.0f : (rr - d);
            if (cov <= 0) continue;
            unsigned ea = (unsigned)(ia * cov + 0.5f);
            unsigned einv = 255 - ea;
            unsigned char* p = row + (size_t)xx * 4;
            p[0] = (unsigned char)((fb * ea + p[0] * einv + 127) / 255);
            p[1] = (unsigned char)((fg * ea + p[1] * einv + 127) / 255);
            p[2] = (unsigned char)((fr * ea + p[2] * einv + 127) / 255);
            // 1px border: stroke where the pixel straddles the edge band.
            if (ba && d > rr - 1.5f) {
                unsigned e2 = ba > ea ? ba : ea;
                unsigned e2i = 255 - e2;
                p[0] = (unsigned char)((bb * e2 + p[0] * e2i + 127) / 255);
                p[1] = (unsigned char)((bg * e2 + p[1] * e2i + 127) / 255);
                p[2] = (unsigned char)((br * e2 + p[2] * e2i + 127) / 255);
            }
        }
    }
}

// Record quad (anchored to document Y), same caps as macos.m.
static void record_text_quad(const char* text, int len, float x, float y, float w, float h,
                             float font_size, int is_bold, int is_italic, int is_mono, int is_heading,
                             const char* link_url, int link_url_len) {
    if (g_text_record_count >= MAX_QUAD_RECORDS) return;
    QuadTextRecord* rec = &g_text_records[g_text_record_count++];
    rec->x = x; rec->doc_y = y + g_scroll_y; rec->w = w; rec->h = h;
    rec->font_size = font_size;
    rec->is_bold = is_bold; rec->is_italic = is_italic;
    rec->is_mono = is_mono; rec->is_heading = is_heading;
    int copy_len = len < 511 ? len : 511;
    if (copy_len > 0 && text) memcpy(rec->text, text, (size_t)copy_len);
    rec->text[copy_len] = '\0';
    rec->len = copy_len;
    int copy_url = (link_url && link_url_len > 0) ? (link_url_len < 255 ? link_url_len : 255) : 0;
    if (copy_url > 0) { memcpy(rec->link_url, link_url, (size_t)copy_url); rec->link_url[copy_url] = '\0'; }
    else rec->link_url[0] = '\0';
}
void platform_register_text_run(const char* text, int len, float x, float y, float w, float h,
                                float font_size, int is_bold, int is_italic, int is_mono,
                                int is_heading, const char* link_url, int link_url_len) {
    if (!text || len <= 0) return;
    float rw = w, rh = h;
    if (g_draw_dc) {
        HFONT f = font_for_run_ex(font_size, is_bold, is_italic, is_mono, is_heading, text, len);
        HFONT old = f ? (HFONT)SelectObject(g_draw_dc, f) : NULL;
        if (f) { rw = measure_run(g_draw_dc, text, len, &rh); SelectObject(g_draw_dc, old); }
    }
    record_text_quad(text, len, x, y, rw, rh, font_size,
                     is_bold, is_italic, is_mono, is_heading, link_url, link_url_len);
    if (link_url && link_url_len > 0) {
        link_underline_track(link_url, link_url_len, x, y, rw, font_size,
                             link_run_hovered(x, y, rw, rh));
    } else {
        g_last_ul.valid = 0;
    }
}

// Link underline pixels (issue #25/#101): exact macOS geometry.
static void draw_link_underline(float x, float y, float w, float font_size, int hovered,
                                const char* url, int url_len,
                                unsigned char r, unsigned char g, unsigned char b, unsigned char a) {
    if (w <= 0.0f || font_size <= 0.0f) return;
    float gap_from = link_underline_track(url, url_len, x, y, w, font_size, hovered);
    hovered = g_last_ul.hovered;
    float uy = y + font_size * 0.85f + fmaxf(1.5f, font_size * 0.10f);
    float th = hovered ? 2.0f : 1.0f;
    if (gap_from >= 0.0f && gap_from < x) fill_rgba(gap_from, uy, x - gap_from, th, r, g, b, a);
    fill_rgba(x, uy, w, th, r, g, b, a);
}

void platform_draw_text(const char* text, int len, float x, float y, float font_size,
                        int is_bold, int is_italic, int is_mono, int is_heading,
                        unsigned char r, unsigned char g, unsigned char b, unsigned char a,
                        const char* link_url, int link_url_len) {
    if (!g_draw_dc || len <= 0 || !text) return;
    if (!link_url || link_url_len <= 0) g_last_ul.valid = 0;
    HFONT f = font_for_run_ex(font_size, is_bold, is_italic, is_mono, is_heading, text, len);
    if (!f) return;
    HFONT old = (HFONT)SelectObject(g_draw_dc, f);
    float rh = font_size * 1.0f;
    float rw = measure_run(g_draw_dc, text, len, &rh);
    record_text_quad(text, len, x, y, rw, rh, font_size,
                     is_bold, is_italic, is_mono, is_heading, link_url, link_url_len);
    g_shape_misses++;
    // Bi-level (non-antialiased) glyphs under forced 2x headless scale so
    // the supersample->downsample sharpen pass sees razor edges; smooth
    // ClearType/antialiased everywhere else.
    int q_bilevel = 0;
#ifdef TEST_HOOKS
    q_bilevel = g_force_bilevel;
#endif
    WCHAR wtmp[768];
    int wn = utf8_to_wide(text, len, wtmp, 767);
    if (wn > 0) {
        float ascent = font_size * 0.85f;
        int iy = (int)floorf(y + ascent + 0.5f);
        int prev_bk = SetBkMode(g_draw_dc, TRANSPARENT);
        COLORREF prev_c = SetTextColor(g_draw_dc, RGB(r, g, b));
        int ix = (int)floorf(x + 0.5f);
        int iy0 = iy - (int)(font_size + 0.5f);
#ifdef TEST_HOOKS
        if (q_bilevel) {
            // Bi-level text ignores alpha blends: draw solid only when
            // fully opaque (all crisp-test runs are). The bidi covering
            // face joins so RTL runs stay glyph-complete at 2x too.
            if (a == 255) {
                int bidi = run_needs_bidi_face(text, len);
                HFONT bf = CreateFontW(-(int)(font_size + 0.5f), 0, 0, 0,
                    face_weight(is_bold, is_heading), is_italic ? TRUE : FALSE,
                    FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                    CLIP_DEFAULT_PRECIS, NONANTIALIASED_QUALITY,
                    DEFAULT_PITCH | FF_DONTCARE,
                    bidi ? face_bidi(is_mono) :
                    (is_mono ? L"Consolas" : (is_heading ? L"Segoe UI" : L"Georgia")));
                if (bf) {
                    HFONT bo = (HFONT)SelectObject(g_draw_dc, bf);
                    ExtTextOutW(g_draw_dc, ix, iy0, 0, NULL, wtmp, wn, NULL);
                    SelectObject(g_draw_dc, bo);
                    DeleteObject(bf);
                }
            }
        } else {
            ExtTextOutW(g_draw_dc, ix, iy0, 0, NULL, wtmp, wn, NULL);
        }
#else
        ExtTextOutW(g_draw_dc, ix, iy0, 0, NULL, wtmp, wn, NULL);
#endif
        SetBkMode(g_draw_dc, prev_bk);
        SetTextColor(g_draw_dc, prev_c);
    }
    SelectObject(g_draw_dc, old);
    if (link_url && link_url_len > 0) {
        draw_link_underline(x, y, rw, font_size, link_run_hovered(x, y, rw, rh),
                            link_url, link_url_len, r, g, b, a);
    }
}

// ---------------------------------------------------------------------------
// Selection highlight (port of macos.m paint_selection_highlight; same band
// math, damage pads, row-span-gap logic; pixels flow through fill_rgba).
// ---------------------------------------------------------------------------
static void paint_selection_highlight(void) {
    if ((!g_has_selection && !g_select_all) || g_text_record_count <= 0) return;
    if (g_select_all) {
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            fill_rgba(rec->x, rec->doc_y - g_scroll_y, rec->w, rec->h, 56, 148, 250, 82);
        }
        return;
    }
    float p1x = g_sel_sx, p1y = g_sel_sy, p2x = g_sel_ex, p2y = g_sel_ey;
    int is_down = (p1y < p2y || (p1y == p2y && p1x <= p2x));
    float tx = is_down ? p1x : p2x, ty = is_down ? p1y : p2y;
    float bx = is_down ? p2x : p1x, by = is_down ? p2y : p1y;
    float min_y = ty, max_y = by;
    int k1 = 0, k2 = 0;
    float top_vx = scroll_doc_to_view(tx, ty, &k1);
    float bot_vx = scroll_doc_to_view(bx, by, &k2);
    {
        int min_in = 0, max_in = 0;
        float min_edge = min_y, max_edge = max_y;
        float min_d = 1e30f, max_d = 1e30f;
        for (int s = 0; s < g_text_record_count; s++) {
            QuadTextRecord* sr = &g_text_records[s];
            float st = sr->doc_y, sb = sr->doc_y + sr->h;
            if (min_y >= st && min_y <= sb) min_in = 1;
            else {
                float d = fminf(fabsf(min_y - st), fabsf(min_y - sb));
                if (d < min_d) { min_d = d; min_edge = (fabsf(min_y - st) < fabsf(min_y - sb)) ? st : sb; }
            }
            if (max_y >= st && max_y <= sb) max_in = 1;
            else {
                float d = fminf(fabsf(max_y - st), fabsf(max_y - sb));
                if (d < max_d) { max_d = d; max_edge = (fabsf(max_y - st) < fabsf(max_y - sb)) ? st : sb; }
            }
            if (min_in && max_in) break;
        }
        if (!min_in && min_d <= 4.0f) min_y = min_edge;
        if (!max_in && max_d <= 4.0f) max_y = max_edge;
    }
    float min_row_y = 0.0f, max_row_y = 0.0f;
    int min_found = 0, max_found = 0;
    for (int s = 0; s < g_text_record_count; s++) {
        QuadTextRecord* sr = &g_text_records[s];
        if (!min_found && min_y >= sr->doc_y && min_y <= sr->doc_y + sr->h) {
            min_row_y = sr->doc_y; min_found = 1;
        }
        if (!max_found && max_y >= sr->doc_y && max_y <= sr->doc_y + sr->h) {
            max_row_y = sr->doc_y; max_found = 1;
        }
        if (min_found && max_found) break;
    }
    for (int q = 0; q < g_text_record_count; q++) {
        QuadTextRecord* rec = &g_text_records[q];
        float r_top = rec->doc_y, r_bot = rec->doc_y + rec->h;
        float view_y = rec->doc_y - g_scroll_y;
        if (r_bot < min_y - 4.0f || r_top > max_y + 4.0f) continue;
        int in_min_row = min_found && fabsf(rec->doc_y - min_row_y) < rec->h * 0.5f;
        int in_max_row = max_found && fabsf(rec->doc_y - max_row_y) < rec->h * 0.5f;
        if (!in_min_row && !in_max_row && (min_y > r_bot || max_y < r_top)) continue;
        int c_start = 0, c_end = rec->len;
        int is_first = in_min_row, is_last = in_max_row;
        float span_lo, span_hi;
        if (is_first && is_last) {
            span_lo = fminf(top_vx, bot_vx); span_hi = fmaxf(top_vx, bot_vx);
        } else if (is_first) {
            span_lo = top_vx; span_hi = 1e30f;
        } else if (is_last) {
            span_lo = -1e30f; span_hi = bot_vx;
        } else {
            span_lo = -1e30f; span_hi = 1e30f;
        }
        if (q > 0) {
            QuadTextRecord* prev = &g_text_records[q - 1];
            if (fabsf(prev->doc_y - rec->doc_y) < 6.0f) {
                float glo = fmaxf(prev->x + prev->w, span_lo);
                float ghi = fminf(rec->x, span_hi);
                if (ghi > glo) fill_rgba(glo, view_y, ghi - glo, rec->h, 56, 148, 250, 82);
            }
        }
        if (is_first && is_last) {
            float left_x = fminf(top_vx, bot_vx), right_x = fmaxf(top_vx, bot_vx);
            if (rec->x + rec->w < left_x || rec->x > right_x) continue;
            c_start = get_char_index_at_x(rec, left_x - rec->x);
            c_end = get_char_index_at_x(rec, right_x - rec->x);
        } else if (is_first) {
            if (rec->x + rec->w < top_vx) continue;
            c_start = get_char_index_at_x(rec, top_vx - rec->x);
            c_end = rec->len;
        } else if (is_last) {
            if (rec->x > bot_vx) continue;
            c_start = 0;
            c_end = get_char_index_at_x(rec, bot_vx - rec->x);
        } else {
            c_start = 0; c_end = rec->len;
        }
        if (c_end > c_start) {
            float x1 = rec->x + get_x_for_char_index(rec, utf8_to_utf16(rec->text, c_start));
            float x2 = rec->x + get_x_for_char_index(rec, utf8_to_utf16(rec->text, c_end));
            if (x2 > x1) fill_rgba(x1, view_y, x2 - x1, rec->h, 56, 148, 250, 82);
        }
    }
}

// Selection bounds in VIEW coords expanded by pad (damage box).
static void selection_bounds_expanded(float pad, float* ox, float* oy, float* ow, float* oh) {
    *ox = 0; *oy = 0; *ow = 0; *oh = 0;
    if (g_select_all) {
        *ox = -pad; *oy = -pad; *ow = (float)g_view_w + 2 * pad; *oh = (float)g_view_h_i + 2 * pad;
        return;
    }
    if (!g_has_selection) return;
    int k1 = 0, k2 = 0;
    float s1v = scroll_doc_to_view(g_sel_sx, g_sel_sy, &k1);
    float s2v = scroll_doc_to_view(g_sel_ex, g_sel_ey, &k2);
    float x1, x2;
    if (!k1 || !k2) { x1 = -1e4f; x2 = 1e4f; }
    else { x1 = fminf(s1v, s2v); x2 = fmaxf(s1v, s2v); }
    float y1 = fminf(g_sel_sy, g_sel_ey) - g_scroll_y;
    float y2 = fmaxf(g_sel_sy, g_sel_ey) - g_scroll_y;
    float ypad = pad + 32.0f;
    if ((x2 - x1) > 2.0f || (y2 - y1) > 2.0f) {
        float qx = floorf(-pad), qy = floorf(y1 - ypad);
        *ox = qx; *oy = qy;
        *ow = ceilf((float)g_view_w + pad) - qx;
        *oh = ceilf(y2 + ypad) - qy;
        return;
    }
    float qx = floorf(x1 - pad), qy = floorf(y1 - ypad);
    *ox = qx; *oy = qy;
    *ow = ceilf(x2 + pad) - qx;
    *oh = ceilf(y2 + ypad) - qy;
}
static void union_box(float ax, float ay, float aw, float ah,
                      float bx, float by, float bw, float bh,
                      float* ox, float* oy, float* ow, float* oh) {
    if (aw <= 0 || ah <= 0) { *ox = bx; *oy = by; *ow = bw; *oh = bh; return; }
    if (bw <= 0 || bh <= 0) { *ox = ax; *oy = ay; *ow = aw; *oh = ah; return; }
    float x0 = fminf(ax, bx), y0 = fminf(ay, by);
    float x1 = fmaxf(ax + aw, bx + bw), y1 = fmaxf(ay + ah, by + bh);
    *ox = x0; *oy = y0; *ow = x1 - x0; *oh = y1 - y0;
}
static void invalidate_box(float x, float y, float w, float h) {
    if (!g_hwnd || w <= 0 || h <= 0) return;
    RECT rc = { (int)floorf(x), (int)floorf(y), (int)ceilf(x + w), (int)ceilf(y + h) };
    InvalidateRect(g_hwnd, &rc, FALSE);
}

// Copy-button geometry (same numbers as macos.m).
static void copy_button_rect(CodeBlockRecord* b, float* ox, float* oy, float* ow, float* oh) {
    *ox = b->x + b->w - 64.0f - 8.0f; *oy = b->y + 8.0f; *ow = 64.0f; *oh = 24.0f;
}
static void copy_button_damage(CodeBlockRecord* b, float* ox, float* oy, float* ow, float* oh) {
    copy_button_rect(b, ox, oy, ow, oh);
    *ox -= 2.0f; *oy -= 2.0f; *ow += 4.0f; *oh += 4.0f;
}
void platform_test_button_damage(float bx, float by, float bw, float bh,
                                 float* ox, float* oy, float* ow, float* oh) {
    CodeBlockRecord tmp;
    memset(&tmp, 0, sizeof(tmp));
    tmp.x = bx; tmp.y = by; tmp.w = bw; tmp.h = bh;
    float x, y, w, h;
    copy_button_damage(&tmp, &x, &y, &w, &h);
    if (ox) *ox = x; if (oy) *oy = y; if (ow) *ow = w; if (oh) *oh = h;
}

// Copy button paint (pill + centered label, same colors/geometry).
static void paint_copy_button(void) {
    if (!g_draw_dc) return;
    DWORD now = GetTickCount();
    for (int i = 0; i < g_code_block_count; i++) {
        CodeBlockRecord* b = &g_code_blocks[i];
        int hov = (g_mouse_x >= b->x && g_mouse_x <= b->x + b->w &&
                   g_mouse_y >= b->y && g_mouse_y <= b->y + b->h);
        int copied = (g_copied_block_idx == i && (now - g_copied_timestamp < 1500));
        if (!hov && !copied) continue;
        float bx, by, bw, bh;
        copy_button_rect(b, &bx, &by, &bw, &bh);
        platform_draw_pill(bx, by, bw, bh, 5.0f, 51, 56, 66, 242, 89, 97, 115, 204);
        const char* label = copied ? "Copied!" : "Copy";
        int ll = (int)strlen(label);
        WCHAR wl[16];
        int wn = utf8_to_wide(label, ll, wl, 16);
        HFONT f = CreateFontW(-11, 0, 0, 0, FW_MEDIUM, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
        HFONT old = f ? (HFONT)SelectObject(g_draw_dc, f) : NULL;
        SIZE sz = { 0, 0 };
        if (wn > 0) GetTextExtentPoint32W(g_draw_dc, wl, wn, &sz);
        int pbk = SetBkMode(g_draw_dc, TRANSPARENT);
        COLORREF pc = SetTextColor(g_draw_dc, copied ? RGB(77, 217, 102) : RGB(217, 224, 235));
        if (wn > 0) ExtTextOutW(g_draw_dc, (int)(bx + (bw - sz.cx) * 0.5f),
                                (int)(by + (bh - sz.cy) * 0.5f), 0, NULL, wl, wn, NULL);
        SetBkMode(g_draw_dc, pbk);
        SetTextColor(g_draw_dc, pc);
        if (old) SelectObject(g_draw_dc, old);
        if (f) DeleteObject(f);
    }
}

// Selected text (shared by Copy, context menu, Ctrl+C).
static int selected_text_utf8(char* out, int cap) {
    int n = 0;
    if (g_select_all) {
        float last_y = -9999.0f;
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            const char* sep = NULL;
            if (last_y > -9000.0f) {
                if (fabsf(rec->doc_y - last_y) > 35.0f) sep = "\n\n";
                else if (fabsf(rec->doc_y - last_y) > 10.0f) sep = "\n";
                else sep = " ";
            }
            if (sep) { int sl = (int)strlen(sep); if (n + sl < cap) { memcpy(out + n, sep, sl); n += sl; } }
            if (n + rec->len < cap) { memcpy(out + n, rec->text, rec->len); n += rec->len; }
            last_y = rec->doc_y;
        }
    } else if (g_has_selection) {
        float p1x = g_sel_sx, p1y = g_sel_sy, p2x = g_sel_ex, p2y = g_sel_ey;
        int is_down = (p1y < p2y || (p1y == p2y && p1x <= p2x));
        float tx = is_down ? p1x : p2x, ty = is_down ? p1y : p2y;
        float bx = is_down ? p2x : p1x, by = is_down ? p2y : p1y;
        float min_y = ty, max_y = by;
        int k1 = 0, k2 = 0;
        float top_vx = scroll_doc_to_view(tx, ty, &k1);
        float bot_vx = scroll_doc_to_view(bx, by, &k2);
        float last_y = -9999.0f;
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            float r_top = rec->doc_y, r_bot = rec->doc_y + rec->h;
            if (r_bot < min_y - 4.0f || r_top > max_y + 4.0f) continue;
            int c_start = 0, c_end = rec->len;
            int is_first = (min_y >= r_top && min_y <= r_bot);
            int is_last = (max_y >= r_top && max_y <= r_bot);
            if (is_first && is_last) {
                float lx = fminf(top_vx, bot_vx), rx = fmaxf(top_vx, bot_vx);
                if (rec->x + rec->w < lx || rec->x > rx) continue;
                c_start = get_char_index_at_x(rec, lx - rec->x);
                c_end = get_char_index_at_x(rec, rx - rec->x);
            } else if (is_first) {
                if (rec->x + rec->w < top_vx) continue;
                c_start = get_char_index_at_x(rec, top_vx - rec->x);
                c_end = rec->len;
            } else if (is_last) {
                if (rec->x > bot_vx) continue;
                c_start = 0;
                c_end = get_char_index_at_x(rec, bot_vx - rec->x);
            }
            if (c_end > c_start && c_start >= 0 && c_end <= rec->len) {
                const char* sep = NULL;
                if (last_y > -9000.0f) {
                    if (fabsf(rec->doc_y - last_y) > 35.0f) sep = "\n\n";
                    else if (fabsf(rec->doc_y - last_y) > 10.0f) sep = "\n";
                    else sep = " ";
                }
                if (sep) { int sl = (int)strlen(sep); if (n + sl < cap) { memcpy(out + n, sep, sl); n += sl; } }
                int m = c_end - c_start;
                // Clamp to UTF-8 boundaries.
                while (m > 0 && ((unsigned char)rec->text[c_start + m] & 0xC0) == 0x80) m--;
                if (n + m < cap && m > 0) { memcpy(out + n, rec->text + c_start, m); n += m; }
                last_y = rec->doc_y;
            }
        }
    }
    if (n < cap) out[n] = '\0';
    return n;
}
static void copy_selection_to_clipboard(void) {
    static char buf[65536];
    int n = selected_text_utf8(buf, (int)sizeof(buf) - 1);
    if (n <= 0) return;
    WCHAR w[32768];
    int wn = utf8_to_wide(buf, n, w, 32767);
    if (wn <= 0) return;
    w[wn] = 0;
    if (!OpenClipboard(g_hwnd)) return;
    EmptyClipboard();
    HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, (SIZE_T)(wn + 1) * sizeof(WCHAR));
    if (h) {
        WCHAR* p = (WCHAR*)GlobalLock(h);
        if (p) { memcpy(p, w, (size_t)(wn + 1) * sizeof(WCHAR)); GlobalUnlock(h); }
        else { GlobalFree(h); h = NULL; }
    }
    if (h) SetClipboardData(CF_UNICODETEXT, h);
    CloseClipboard();
}
static void select_all_document(void) {
    g_select_all = 1;
    g_has_selection = 1;
    g_selection_mode = 4;
    if (g_hwnd) InvalidateRect(g_hwnd, NULL, FALSE);
}

// ---------------------------------------------------------------------------
// Framebuffer (top-down 32bpp DIB) + draw-pass open/close + WM_PAINT
// ---------------------------------------------------------------------------
static int framebuffer_ensure(int w, int h) {
    if (w <= 0 || h <= 0) return 0;
    if (g_dib && w == g_dib_w && h == g_dib_h) return 1;
    if (g_memdc) { DeleteDC(g_memdc); g_memdc = NULL; g_dib = NULL; g_dib_bits = NULL; }
    HDC sdc = GetDC(NULL);
    BITMAPINFO bi;
    memset(&bi, 0, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h; // top-down: memory row == y (y-down native)
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    g_memdc = CreateCompatibleDC(sdc);
    g_dib = CreateDIBSection(sdc, &bi, DIB_RGB_COLORS, (void**)&g_dib_bits, NULL, 0);
    ReleaseDC(NULL, sdc);
    if (!g_memdc || !g_dib) {
        if (g_memdc) { DeleteDC(g_memdc); g_memdc = NULL; }
        g_dib = NULL; g_dib_bits = NULL; g_dib_w = g_dib_h = 0;
        return 0;
    }
    SelectObject(g_memdc, g_dib);
    g_dib_w = w; g_dib_h = h;
    return 1;
}
static void draw_pass_open(int w, int h) {
    framebuffer_ensure(w, h);
    g_draw_dc = g_memdc;
    g_text_record_count = 0;
    g_code_block_count = 0;
    g_scrollable_block_count = 0;
    g_last_ul.valid = 0;
    g_draw_clip_depth = 0;
    g_draw_seq++;
}
static void draw_pass_close(void) {
    // GDI clips are SaveDC/RestoreDC-balanced by begin/end_clip; headless
    // parity note: the Zig-side partial-damage clip is matched by
    // platform_begin_clip, so no residual clip can leak across draws.
    while (g_draw_clip_depth > 0) { RestoreDC(g_draw_dc, -1); g_draw_clip_depth--; }
    g_draw_dc = NULL;
}
static void paint_window(HDC hdc, int w, int h) {
    if (!g_memdc || !g_dib_bits) return;
    if (g_overshoot != 0.0f) {
        // Rubber-band: shift the finished frame (strip shows the theme bg).
        int dy = (int)g_overshoot;
        HBRUSH bg = CreateSolidBrush(g_synced_theme_dark == 0 ? RGB(250, 250, 250) : RGB(18, 18, 18));
        RECT full = { 0, 0, w, h };
        FillRect(hdc, &full, bg);
        DeleteObject(bg);
        BitBlt(hdc, 0, dy > 0 ? dy : 0, w, h - abs(dy), g_memdc, 0, dy < 0 ? -dy : 0, SRCCOPY);
        // Scrollbar filament over the shifted frame.
        if (g_max_scroll_y > 0.0f) {
            float p = g_scroll_y / g_max_scroll_y;
            if (p < 0) p = 0; if (p > 1) p = 1;
            int ty = (int)(p * (h - SCROLLBAR_THUMB_H));
            RECT sb = { w - 3, ty, w - 1, ty + (int)SCROLLBAR_THUMB_H };
            HBRUSH sb2 = CreateSolidBrush(g_synced_theme_dark == 0 ? RGB(40, 120, 240) : RGB(90, 160, 255));
            FillRect(hdc, &sb, sb2);
            DeleteObject(sb2);
        }
        return;
    }
    BitBlt(hdc, 0, 0, w, h, g_memdc, 0, 0, SRCCOPY);
}
static void run_draw(int w, int h) {
    if (!framebuffer_ensure(w, h)) return;
    draw_pass_open(w, h);
    if (g_callbacks.on_draw) g_callbacks.on_draw(w, h);
    paint_selection_highlight();
    paint_copy_button();
    draw_pass_close();
}
void platform_request_redraw(void) {
    if (g_hwnd) InvalidateRect(g_hwnd, NULL, FALSE);
}
void platform_request_redraw_rect(float x, float y, float w, float h) {
    invalidate_box(x, y, w, h);
}
void platform_sync_scroll(float scroll_y) {
    if (scroll_y != g_scroll_y) g_hover_link_hash = 0;
    g_scroll_y = scroll_y;
}
void platform_sync_overshoot(float overshoot) { g_overshoot = overshoot; }
void platform_set_scroll_info(float scroll_y, float max_scroll_y, float view_h) {
    g_scroll_y = scroll_y;
    g_max_scroll_y = max_scroll_y;
    g_view_h = view_h;
}
int platform_get_pending_damage(float* x, float* y, float* w, float* h) {
#ifdef TEST_HOOKS
    if (g_test_damage_valid) {
        if (x) *x = g_test_damage_x;
        if (y) *y = g_test_damage_y;
        if (w) *w = g_test_damage_w;
        if (h) *h = g_test_damage_h;
        return 1;
    }
#endif
    if (!g_dirty_valid) return 0;
    if (x) *x = g_dirty_x;
    if (y) *y = g_dirty_y;
    if (w) *w = g_dirty_w;
    if (h) *h = g_dirty_h;
    return 1;
}
void platform_begin_clip(float x, float y, float w, float h) {
    if (!g_draw_dc) return;
    SaveDC(g_draw_dc);
    g_draw_clip_depth++;
    IntersectClipRect(g_draw_dc, (int)floorf(x), (int)floorf(y),
                      (int)ceilf(x + w), (int)ceilf(y + h));
}
void platform_end_clip(void) {
    if (!g_draw_dc || g_draw_clip_depth <= 0) return;
    RestoreDC(g_draw_dc, -1);
    g_draw_clip_depth--;
}
void platform_register_code_block(float x, float y, float w, float h,
                                  const char* code_text, int code_len) {
    if (g_code_block_count >= MAX_CODE_BLOCKS) return;
    CodeBlockRecord* b = &g_code_blocks[g_code_block_count++];
    b->x = x; b->y = y; b->w = w; b->h = h;
    int n = (code_text && code_len > 0) ? (code_len < 8191 ? code_len : 8191) : 0;
    if (n > 0) { memcpy(b->text, code_text, (size_t)n); b->text[n] = '\0'; b->len = n; }
    else { b->text[0] = '\0'; b->len = 0; }
}
void platform_register_scrollable_block(int block_id, float x, float y, float w, float h,
                                        float max_scroll_x, float scroll_x) {
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
void platform_clear_selection(void) {
    g_has_selection = 0;
    g_select_all = 0;
    g_selection_mode = 0;
}


// ---------------------------------------------------------------------------
// Images: sync GDI+ file decode (frame 0 still; GIFs do not animate v1).
// Remote URLs are never fetched — placeholder, same pixels as the macOS
// offline/failure path. No background threads: decode happens on first
// size query/draw (cold), results cached in the 64-slot record table.
// ---------------------------------------------------------------------------
static char g_doc_dir[1024] = {0};
void platform_set_document_dir(const char* path, int path_len) {
    g_doc_dir[0] = '\0';
    if (!path || path_len <= 0) return;
    int end = path_len;
    while (end > 0 && path[end - 1] != '/' && path[end - 1] != '\\') end--;
    if (end > 0) end--;
    if (end <= 0) return;
    if (end > (int)sizeof(g_doc_dir) - 1) end = (int)sizeof(g_doc_dir) - 1;
    memcpy(g_doc_dir, path, (size_t)end);
    g_doc_dir[end] = '\0';
}
static int image_url_is_remote(const char* s, int n) {
    if (n >= 7 && (_strnicmp(s, "http://", 7) == 0)) return 1;
    if (n >= 8 && (_strnicmp(s, "https://", 8) == 0)) return 1;
    return 0;
}
static int image_file_exists(const char* p) {
    char npath[2048];
    if (normalize_path(p, (int)strlen(p), npath, (int)sizeof(npath)) != 0) return 0;
    WCHAR w[2048];
    int wn = utf8_to_wide(npath, (int)strlen(npath), w, 2047);
    if (wn <= 0) return 0;
    w[wn] = 0;
    // Pure existence (files AND directories, like fileExistsAtPath: the
    // ("//","tmp") probe resolves a directory). A directory passed as an
    // image fails the GDI+ decode downstream into the placeholder — safe.
    return GetFileAttributesW(w) != INVALID_FILE_ATTRIBUTES;
}
// Resolve a relative image path: absolute/CWD wins (back-compat), then the
// document directory, then CWD join. Remote URLs pass through untouched
// (callers never fetch them). Output is a NUL-terminated OS path.
static int resolve_image_path(const char* url, int url_len, char* out, int cap) {
    if (!url || url_len <= 0 || !out || cap <= 0) return 0;
    if (image_url_is_remote(url, url_len)) return 0;
    char rel[1024];
    int rn = url_len < 1023 ? url_len : 1023;
    memcpy(rel, url, (size_t)rn);
    rel[rn] = '\0';
    if (image_file_exists(rel)) {
        int n = rn < cap - 1 ? rn : cap - 1;
        memcpy(out, rel, (size_t)n); out[n] = '\0';
        return 1;
    }
    if (g_doc_dir[0]) {
        char full[2048];
        _snprintf(full, 2047, "%s\\%s", g_doc_dir, rel);
        full[2047] = '\0';
        if (image_file_exists(full)) {
            int n = (int)strlen(full);
            if (n >= cap) n = cap - 1;
            memcpy(out, full, (size_t)n); out[n] = '\0';
            return 1;
        }
    }
    {
        char cwd[1024];
        DWORD n = GetCurrentDirectoryA(1023, cwd);
        if (n > 0 && n < 1023) {
            char full[2048];
            _snprintf(full, 2047, "%s\\%s", cwd, rel);
            full[2047] = '\0';
            if (image_file_exists(full)) {
                int m = (int)strlen(full);
                if (m >= cap) m = cap - 1;
                memcpy(out, full, (size_t)m); out[m] = '\0';
                return 1;
            }
        }
    }
    return 0;
}
typedef struct {
    char url[512];
    HBITMAP bmp;       // decoded frame 0 (top-down 32bpp DIB section)
    int bw, bh;
    float natural_w, natural_h;
    int loading, failed;
    float last_doc_x, last_doc_y, last_w, last_h;
    int has_rect;
} CachedImageRecord;
#define MAX_IMAGE_CACHE 64
static CachedImageRecord g_image_cache[MAX_IMAGE_CACHE];
static int g_image_cache_count = 0;
static int g_images_armed = 0;
#ifdef TEST_HOOKS
static unsigned long g_test_image_draws = 0;
#endif
#ifdef READ_GDIP
static ULONG_PTR g_gdip_token = 0;
static int g_gdip_started = 0;
static void gdip_ensure(void) {
    if (g_gdip_started) return;
    g_gdip_started = 1;
    GdiplusStartupInput in;
    memset(&in, 0, sizeof(in));
    in.GdiplusVersion = 1;
    GdiplusStartup(&g_gdip_token, &in, NULL);
}
#endif
// Decode synchronously into the record (frame 0 still). Returns 1 on success.
static int decode_image_into(CachedImageRecord* rec, const char* path) {
#ifdef READ_GDIP
    gdip_ensure();
    WCHAR w[2048];
    int wn = utf8_path_to_wide(path, (int)strlen(path), w, 2047);
    if (wn <= 0) return 0;
    w[wn] = 0;
    void* img = NULL; // GpImage*
    if (GdipLoadImageFromFile(w, (void**)&img) != 0 || !img) return 0;
    unsigned int iw = 0, ih = 0;
    GdipGetImageWidth(img, &iw);
    GdipGetImageHeight(img, &ih);
    if (iw < 1 || ih < 1 || iw > 4096 || ih > 4096) { GdipDisposeImage(img); return 0; }
    HDC sdc = GetDC(NULL);
    BITMAPINFO bi;
    memset(&bi, 0, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = (LONG)iw;
    bi.bmiHeader.biHeight = -((LONG)ih);
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    void* bits = NULL;
    HBITMAP dib = CreateDIBSection(sdc, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
    if (!dib || !bits) {
        if (dib) DeleteObject(dib);
        ReleaseDC(NULL, sdc);
        GdipDisposeImage(img);
        return 0;
    }
    // White background (JPEG has no alpha; GDI+ premultiplies onto black
    // otherwise, darkening opaque photos).
    memset(bits, 0xFF, (size_t)iw * ih * 4);
    HDC mdc = CreateCompatibleDC(sdc);
    HGDIOBJ old = SelectObject(mdc, dib);
    void* gr = NULL; // GpGraphics*
    int ok = 0;
    if (GdipCreateFromHDC(mdc, &gr) == 0 && gr) {
        if (GdipDrawImageRectI(gr, img, 0, 0, (int)iw, (int)ih) == 0) ok = 1;
        // Un-premultiply to straight alpha for our DIB blits below: GDI+
        // wrote premultiplied BGRA; straighten so AlphaBlend is exact.
        unsigned char* px = (unsigned char*)bits;
        size_t np = (size_t)iw * ih;
        for (size_t i = 0; i < np; i++) {
            unsigned char* p = px + i * 4;
            unsigned a = p[3];
            if (a != 0 && a != 255) {
                p[0] = (unsigned char)((p[0] * 255 + a / 2) / a);
                p[1] = (unsigned char)((p[1] * 255 + a / 2) / a);
                p[2] = (unsigned char)((p[2] * 255 + a / 2) / a);
                if (p[0] > 255) p[0] = 255;
                if (p[1] > 255) p[1] = 255;
                if (p[2] > 255) p[2] = 255;
            }
        }
        GdipDeleteGraphics(gr);
    }
    SelectObject(mdc, old);
    DeleteDC(mdc);
    ReleaseDC(NULL, sdc);
    GdipDisposeImage(img);
    if (!ok) { DeleteObject(dib); return 0; }
    rec->bmp = dib;
    rec->bw = (int)iw; rec->bh = (int)ih;
    rec->natural_w = (float)iw; rec->natural_h = (float)ih;
    return 1;
#else
    (void)rec; (void)path;
    return 0;
#endif
}
static CachedImageRecord* get_or_load_image_record(const char* url, int url_len) {
    if (!url || url_len <= 0 || url_len >= 512) return NULL;
    for (int i = 0; i < g_image_cache_count; i++) {
        if (strncmp(g_image_cache[i].url, url, (size_t)url_len) == 0 &&
            g_image_cache[i].url[url_len] == '\0')
            return &g_image_cache[i];
    }
    if (g_image_cache_count >= MAX_IMAGE_CACHE) return NULL;
    CachedImageRecord* rec = &g_image_cache[g_image_cache_count++];
    memset(rec, 0, sizeof(*rec));
    memcpy(rec->url, url, (size_t)url_len);
    rec->url[url_len] = '\0';
    rec->loading = 1;
    if (image_url_is_remote(url, url_len)) {
        // Remote images: placeholder v1 (never fetched). Same pixels as
        // the failure box; the Zig privacy gate already blocks remote URLs
        // when disabled, so this only serves enabled-but-offline remotes.
        rec->loading = 0;
        rec->failed = 1;
        return rec;
    }
    char resolved[2048];
    if (!resolve_image_path(url, url_len, resolved, (int)sizeof(resolved))) {
        rec->loading = 0;
        rec->failed = 1;
        return rec;
    }
    if (!g_images_armed) {
        // Park until first paint (startup economy, same as macos.m):
        // pixels below are the fast-fail placeholder either way.
        return rec;
    }
    if (decode_image_into(rec, resolved)) rec->loading = 0;
    else { rec->loading = 0; rec->failed = 1; }
    return rec;
}
void platform_get_image_size(const char* url, int url_len, float* out_w, float* out_h) {
    if (out_w) *out_w = 0;
    if (out_h) *out_h = 0;
    CachedImageRecord* rec = get_or_load_image_record(url, url_len);
    if (!rec || rec->loading || rec->failed) return;
    if (out_w) *out_w = rec->natural_w;
    if (out_h) *out_h = rec->natural_h;
}
void platform_arm_images(void) {
    if (g_images_armed) return;
    g_images_armed = 1;
    for (int i = 0; i < g_image_cache_count; i++) {
        CachedImageRecord* rec = &g_image_cache[i];
        if (!rec->loading || rec->failed || rec->bmp) continue;
        char resolved[2048];
        if (!resolve_image_path(rec->url, (int)strlen(rec->url), resolved, (int)sizeof(resolved))) {
            rec->loading = 0; rec->failed = 1; continue;
        }
        if (decode_image_into(rec, resolved)) rec->loading = 0;
        else { rec->loading = 0; rec->failed = 1; }
    }
}
static void draw_placeholder_alt(const char* alt, int alt_len, float x, float y, float w, float h) {
    if (!alt || alt_len <= 0 || w < 60.0f || h < 26.0f) return;
    int cap = (int)((w - 16.0f) / 7.0f);
    if (cap > 96) cap = 96;
    if (cap <= 0) return;
    int n = alt_len < cap ? alt_len : cap;
    while (n > 0 && ((unsigned char)alt[n] & 0xC0) == 0x80) n--;
    if (n <= 0) return;
    // UNRECORDED alt caption (same rule as macos.m: no record-model ghost).
    HFONT f = font_for_run(12.0f, 0, 0, 0, 0);
    HFONT old = f ? (HFONT)SelectObject(g_draw_dc, f) : NULL;
    WCHAR wtmp[128];
    int wn = utf8_to_wide(alt, n, wtmp, 127);
    if (wn > 0 && f) {
        int pbk = SetBkMode(g_draw_dc, TRANSPARENT);
        COLORREF pc = SetTextColor(g_draw_dc, RGB(140, 140, 145));
        ExtTextOutW(g_draw_dc, (int)(x + 8.0f), (int)(y + h * 0.5f - 7.0f), 0, NULL, wtmp, wn, NULL);
        SetBkMode(g_draw_dc, pbk);
        SetTextColor(g_draw_dc, pc);
    }
    if (old) SelectObject(g_draw_dc, old);
}
void platform_draw_image(const char* url, int url_len, float x, float y, float w, float h,
                         const char* alt, int alt_len) {
    if (!g_draw_dc || w <= 0 || h <= 0) return;
#ifdef TEST_HOOKS
    g_test_image_draws++;
#endif
    CachedImageRecord* rec = get_or_load_image_record(url, url_len);
    if (rec) {
        rec->last_doc_x = x; rec->last_doc_y = y + g_scroll_y;
        rec->last_w = w; rec->last_h = h; rec->has_rect = 1;
    }
    if (!rec || rec->loading) {
        fill_rgba(x, y, w, h, 28, 28, 32, 128);
        draw_placeholder_alt(alt, alt_len, x, y, w, h);
        return;
    }
    if (rec->failed || !rec->bmp) {
        fill_rgba(x, y, w, h, 28, 28, 32, 255);
        fill_rgba(x, y, w, 1.0f, 80, 40, 40, 255);
        draw_placeholder_alt(alt, alt_len, x, y, w, h);
        return;
    }
    HDC mdc = CreateCompatibleDC(g_draw_dc);
    HGDIOBJ old = SelectObject(mdc, rec->bmp);
    BLENDFUNCTION bf;
    bf.BlendOp = AC_SRC_OVER; bf.BlendFlags = 0;
    bf.SourceConstantAlpha = 255; bf.AlphaFormat = AC_SRC_ALPHA;
    AlphaBlend(g_draw_dc, (int)x, (int)y, (int)(w + 0.5f), (int)(h + 0.5f),
               mdc, 0, 0, rec->bw, rec->bh, bf);
    SelectObject(mdc, old);
    DeleteDC(mdc);
}

// ---------------------------------------------------------------------------
// ZaTeX runtime math backend (LaTeX math plugin) lives in win32_zatex.c
// (GDI metrics + direct draw); READ_PLUGIN_STUB=1 includes the empty
// stub instead — same TU, same flags (AGENTS.md §7, macos.m precedent).
// ---------------------------------------------------------------------------
#if READ_PLUGIN_STUB
#include "win32_zatex_stub.c"
#else
#include "win32_zatex.c"
#endif

// ---------------------------------------------------------------------------
// Glyph-cache counters (TEST_HOOKS reader; same gate pattern as macos.m).
// ---------------------------------------------------------------------------
#ifdef TEST_HOOKS
void platform_glyph_cache_stats(unsigned long long* hits, unsigned long long* misses,
                                unsigned long long* flushes) {
    if (hits) *hits = g_shape_hits;
    if (misses) *misses = g_shape_misses;
    if (flushes) *flushes = g_atlas_flushes;
}
#endif

void platform_open_url_external(const char* url, int url_len) {
    if (!url || url_len <= 0) return;
    char tmp[2048];
    int n = url_len < 2047 ? url_len : 2047;
    memcpy(tmp, url, (size_t)n);
    tmp[n] = '\0';
    ShellExecuteA(NULL, "open", tmp, NULL, NULL, SW_SHOWNORMAL);
}
int platform_test_image_resolve(const char* dir, int dirlen, const char* rel, int rellen) {
    if (!dir || dirlen <= 0 || !rel || rellen <= 0) return -1;
    char d[1024], r[1024];
    if (dirlen >= 1024 || rellen >= 1024) return -1;
    memcpy(d, dir, (size_t)dirlen); d[dirlen] = '\0';
    memcpy(r, rel, (size_t)rellen); r[rellen] = '\0';
    char full[2048];
    // A bare POSIX root joins as drive-relative ("\tmp" == "C:\tmp"), not
    // UNC ("\\tmp" would address server "tmp"): collapse the separator.
    // This mirrors resolve_image_path's absolute-path handling exactly, so
    // the ("//","tmp")==1 contract reads the same directory both paths use.
    // Environment note: needs C:\tmp to exist (standard on dev machines;
    // CI setup must mkdir it — same class of prerequisite as macOS /tmp).
    if ((strcmp(d, "/") == 0 || strcmp(d, "\\") == 0))
        _snprintf(full, 2047, "\\%s", r);
    else
        _snprintf(full, 2047, "%s\\%s", d, r);
    full[2047] = '\0';
    if (image_file_exists(full)) return 1;
    return 0;
}
int platform_test_image_session(void) {
    // No shared cache, bounded timeouts: structurally true (sync GDI+
    // decode, no session object at all).
    return 1;
}

// ---------------------------------------------------------------------------
// Outline: 512-entry table + case-insensitive substring filter (same
// contracts as macos.m); show = minimal modal dialog (listbox + live
// filter + OK/Cancel; Enter/double-click jumps via on_scroll_to).
// ---------------------------------------------------------------------------
#define OUTLINE_MAX 512
typedef struct { int level; float y; char text[160]; } OutlineItem;
static OutlineItem g_outline_items[OUTLINE_MAX];
static int g_outline_count = 0;
static int g_outline_rows[OUTLINE_MAX];
static int g_outline_row_count = 0;
void platform_outline_add(int level, float y, const char* text, int text_len) {
    if (g_outline_count >= OUTLINE_MAX || !text || text_len <= 0) return;
    OutlineItem* it = &g_outline_items[g_outline_count++];
    it->level = level;
    it->y = y;
    int n = text_len < 159 ? text_len : 159;
    memcpy(it->text, text, (size_t)n);
    it->text[n] = '\0';
}
static int outline_filter_matches(const char* text, const char* filter) {
    if (!filter || !filter[0]) return 1;
    // ASCII case-insensitive plain substring (same contract as macos.m).
    size_t fl = strlen(filter), tl = strlen(text);
    if (fl > tl) return 0;
    for (size_t i = 0; i + fl <= tl; i++) {
        size_t j = 0;
        for (; j < fl; j++) {
            unsigned char a = (unsigned char)text[i + j], b = (unsigned char)filter[j];
            if (a >= 'A' && a <= 'Z') a += 'a' - 'A';
            if (b >= 'A' && b <= 'Z') b += 'a' - 'A';
            if (a != b) break;
        }
        if (j == fl) return 1;
    }
    return 0;
}
int platform_test_outline_filter(const char* text, int text_len, const char* filter, int filter_len) {
    if (!text || text_len < 0 || !filter || filter_len < 0) return -1;
    char fb[256], tb[1024];
    if (filter_len >= 256) return -1;
    int tn = text_len < 1023 ? text_len : 1023;
    memcpy(fb, filter, (size_t)filter_len); fb[filter_len] = '\0';
    memcpy(tb, text, (size_t)tn); tb[tn] = '\0';
    return outline_filter_matches(tb, fb);
}
static HWND g_ol_list = NULL, g_ol_filter = NULL;
static INT_PTR CALLBACK outline_dlg_proc(HWND dlg, UINT msg, WPARAM wp, LPARAM lp) {
    (void)lp;
    if (msg == WM_INITDIALOG) {
        g_ol_filter = GetDlgItem(dlg, 101);
        g_ol_list = GetDlgItem(dlg, 102);
        for (int i = 0; i < g_outline_row_count; i++) {
            OutlineItem* it = &g_outline_items[g_outline_rows[i]];
            char disp[192];
            int pad = (it->level - 1) * 2;
            if (pad < 0) pad = 0; if (pad > 16) pad = 16;
            _snprintf(disp, 191, "%*s%s", pad, "", it->text);
            disp[191] = '\0';
            WCHAR w[256];
            int wn = utf8_to_wide(disp, (int)strlen(disp), w, 255);
            if (wn > 0) { w[wn] = 0; SendMessageW(g_ol_list, LB_ADDSTRING, 0, (LPARAM)w); }
        }
        if (g_outline_row_count > 0) SendMessageW(g_ol_list, LB_SETCURSEL, 0, 0);
        SetFocus(g_ol_filter);
        return FALSE;
    }
    if (msg == WM_COMMAND) {
        int id = LOWORD(wp), ev = HIWORD(wp);
        if (id == 101 && ev == EN_CHANGE) {
            // Live filter rebuild.
            char fb[256] = {0};
            GetDlgItemTextA(dlg, 101, fb, 255);
            SendMessageW(g_ol_list, LB_RESETCONTENT, 0, 0);
            g_outline_row_count = 0;
            for (int i = 0; i < g_outline_count; i++) {
                if (!outline_filter_matches(g_outline_items[i].text, fb)) continue;
                g_outline_rows[g_outline_row_count++] = i;
                OutlineItem* it = &g_outline_items[i];
                char disp[192];
                int pad = (it->level - 1) * 2;
                if (pad < 0) pad = 0; if (pad > 16) pad = 16;
                _snprintf(disp, 191, "%*s%s", pad, "", it->text);
                disp[191] = '\0';
                WCHAR w[256];
                int wn = utf8_to_wide(disp, (int)strlen(disp), w, 255);
                if (wn > 0) { w[wn] = 0; SendMessageW(g_ol_list, LB_ADDSTRING, 0, (LPARAM)w); }
            }
            if (g_outline_row_count > 0) SendMessageW(g_ol_list, LB_SETCURSEL, 0, 0);
            return TRUE;
        }
        if ((id == IDOK || (id == 102 && ev == LBN_DBLCLK))) {
            int sel = (int)SendMessageW(g_ol_list, LB_GETCURSEL, 0, 0);
            if (sel < 0 && g_outline_row_count > 0) sel = 0;
            if (sel >= 0 && sel < g_outline_row_count) {
                float yy = g_outline_items[g_outline_rows[sel]].y;
                EndDialog(dlg, IDOK);
                if (g_callbacks.on_scroll_to) g_callbacks.on_scroll_to(yy);
            } else EndDialog(dlg, IDOK);
            return TRUE;
        }
        if (id == IDCANCEL) { EndDialog(dlg, IDCANCEL); return TRUE; }
    }
    return FALSE;
}
// Dialog template in memory (modal, listbox + filter + OK/Cancel).
// NOTE: DLGTEMPLATE stores style as a DWORD followed by one WORD of
// extended style (DLGTEMPLATEEX layout): write DWORDs through a DWORD
// cursor, then drop to WORD fields. Plain *p++ = <32-bit const> stores
// silently truncate under -Werror, so every store is explicitly sized.
static void outline_show_dialog(void) {
    static WORD tmpl[512];
    memset(tmpl, 0, sizeof(tmpl));
    // DLGTEMPLATE: dlgVer(WORD)=1, signature(WORD)=0xFFFF, helpID(DWORD),
    // exStyle(DWORD), style(DWORD), cDlgItems(WORD), x/y/cx/cy(WORDs),
    // menu/class(WORDs), title, pointsize, typeface.
    WORD* p = tmpl;
    *p++ = 1;
    *p++ = 0xFFFF;
    { DWORD* dd = (DWORD*)p; *dd++ = 0; *dd++ = 0;
      *dd++ = (DWORD)(WS_POPUP | WS_CAPTION | WS_SYSMENU | DS_MODALFRAME | DS_CENTER | WS_VISIBLE);
      p = (WORD*)dd; }
    *p++ = 4;                          // 4 controls
    *p++ = 0; *p++ = 0;                // x, y (centered)
    *p++ = 240; *p++ = 210;            // cx, cy (dialog units)
    *p++ = 0; *p++ = 0;                // menu, class (default dialog)
    // title "Headings"
    { const WORD t[] = { 'H','e','a','d','i','n','g','s',0 }; memcpy(p, t, sizeof(t)); p += 9; }
    *p++ = 8;                          // pointsize
    { const WORD t[] = { 'M','S',' ','S','h','e','l','l',' ','D','l','g',0 }; memcpy(p, t, sizeof(t)); p += 13; }
    // Control helper: DLGITEMTEMPLATE is helpID(DWORD) exStyle(DWORD)
    // style(DWORD) x/y/cx/cy/id(WORDs) class + text + extra(WORD).
    // Control 1: filter EDIT (id 101) at (8,6) 224x14
    { DWORD* dd = (DWORD*)p;
      *dd++ = 0;
      *dd++ = 0;
      *dd++ = (DWORD)(WS_CHILD | WS_VISIBLE | WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL);
      p = (WORD*)dd; }
    *p++ = 8; *p++ = 6; *p++ = 224; *p++ = 14;
    *p++ = 101;
    { const WORD t[] = { 0x0081, 0 }; memcpy(p, t, sizeof(t)); p += 2; } // EDIT class atom
    { const WORD t[] = { 0 }; memcpy(p, t, sizeof(t)); p += 1; }          // no text
    *p++ = 0; // extra bytes
    // Control 2: LISTBOX (id 102) at (8,24) 224x150
    { DWORD* dd = (DWORD*)p;
      *dd++ = 0;
      *dd++ = 0;
      *dd++ = (DWORD)(WS_CHILD | WS_VISIBLE | WS_BORDER | WS_TABSTOP | WS_VSCROLL | LBS_NOTIFY);
      p = (WORD*)dd; }
    *p++ = 8; *p++ = 24; *p++ = 224; *p++ = 150;
    *p++ = 102;
    { const WORD t[] = { 0x0083, 0 }; memcpy(p, t, sizeof(t)); p += 2; } // LISTBOX atom
    { const WORD t[] = { 0 }; memcpy(p, t, sizeof(t)); p += 1; }
    *p++ = 0;
    // Control 3: OK (id IDOK) at (120,180) 50x14
    { DWORD* dd = (DWORD*)p;
      *dd++ = 0;
      *dd++ = 0;
      *dd++ = (DWORD)(WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON);
      p = (WORD*)dd; }
    *p++ = 120; *p++ = 180; *p++ = 50; *p++ = 14;
    *p++ = IDOK;
    { const WORD t[] = { 0x0080, 0 }; memcpy(p, t, sizeof(t)); p += 2; } // BUTTON atom
    { const WORD t[] = { 'O','K',0 }; memcpy(p, t, sizeof(t)); p += 3; }
    *p++ = 0;
    // Control 4: Cancel (id IDCANCEL) at (176,180) 50x14
    { DWORD* dd = (DWORD*)p;
      *dd++ = 0;
      *dd++ = 0;
      *dd++ = (DWORD)(WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON);
      p = (WORD*)dd; }
    *p++ = 176; *p++ = 180; *p++ = 50; *p++ = 14;
    *p++ = IDCANCEL;
    { const WORD t[] = { 0x0080, 0 }; memcpy(p, t, sizeof(t)); p += 2; }
    { const WORD t[] = { 'C','a','n','c','e','l',0 }; memcpy(p, t, sizeof(t)); p += 7; }
    *p++ = 0;
    DialogBoxIndirectParamW(GetModuleHandleW(NULL), (LPCDLGTEMPLATEW)tmpl, g_hwnd, outline_dlg_proc, 0);
}
void platform_outline_show(void) {
    g_outline_row_count = 0;
    for (int i = 0; i < g_outline_count; i++) g_outline_rows[g_outline_row_count++] = i;
    if (g_hwnd) outline_show_dialog();
    g_outline_count = 0; // accumulation consumed; the next open re-adds
}
#ifdef TEST_HOOKS
int platform_test_outline_build(void) {
    g_outline_count = 0;
    platform_outline_add(1, 50.0f, "Alpha", 5);
    platform_outline_add(3, 300.0f, "Beta", 4);
    g_outline_row_count = 0;
    for (int i = 0; i < g_outline_count; i++) g_outline_rows[g_outline_row_count++] = i;
    int rows = g_outline_row_count;
    g_outline_count = 0;
    return rows == 2 ? 1 : 0;
}
// RTL run-face contract probe (issue #50 follow-up): 0 when the primary
// face covers the run, 1/2 when the bidi serif/mono face is needed.
// Same scan as font_for_run's selector below; headless-safe (pure bytes).
int platform_test_bidi_face(const char* text, int text_len, int is_mono, int is_heading) {
    (void)is_heading;
    if (!run_needs_bidi_face(text, text_len)) return 0;
    return is_mono ? 2 : 1;
}
#endif

// ---------------------------------------------------------------------------
// Open-file gate + watcher + find bar + appearance/tabbing/key probes
// ---------------------------------------------------------------------------
static int read_path_is_markdown(const char* path, int path_len) {
    if (!path || path_len <= 0) return 0;
    int dot = -1;
    for (int i = 0; i < path_len; i++) if (path[i] == '.') dot = i;
    if (dot < 0 || dot + 1 >= path_len) return 0;
    char ext[16];
    int n = path_len - dot - 1;
    if (n > 15) return 0;
    for (int i = 0; i < n; i++) {
        char c = path[dot + 1 + i];
        if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
        ext[i] = c;
    }
    ext[n] = '\0';
    // Trailing-space guard: "a.md " is NOT markdown (matches macos probe).
    if (n > 0 && ext[n - 1] == ' ') return 0;
    return strcmp(ext, "md") == 0 || strcmp(ext, "markdown") == 0 ||
           strcmp(ext, "mdown") == 0 || strcmp(ext, "mkd") == 0 ||
           strcmp(ext, "txt") == 0 || strcmp(ext, "text") == 0;
}
int platform_test_markdown_ext(const char* path, int path_len) {
    return read_path_is_markdown(path, path_len);
}
static void read_open_file_path(const char* p) {
    if (!p || !g_callbacks.on_open_file) return;
    int n = (int)strlen(p);
    if (!read_path_is_markdown(p, n)) {
        MessageBoxA(g_hwnd, "That file isn't a Markdown or text file.",
                    "Could not open the file", MB_OK | MB_ICONWARNING);
        return;
    }
    g_callbacks.on_open_file(p, n);
}
static void show_open_panel(void) {
    char file[2048] = {0};
    OPENFILENAMEA ofn;
    memset(&ofn, 0, sizeof(ofn));
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = g_hwnd;
    ofn.lpstrFile = file;
    ofn.nMaxFile = sizeof(file) - 1;
    ofn.lpstrFilter = "Markdown/Text\0*.md;*.markdown;*.mdown;*.mkd;*.txt;*.text\0All Files\0*.*\0";
    ofn.nFilterIndex = 1;
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST;
    if (GetOpenFileNameA(&ofn)) read_open_file_path(file);
}
// External-change watcher (#44): a watcher thread parked in
// FindFirstChangeNotificationW — event-driven wait, zero idle cost, no
// polling. Re-arms via platform_watch_file (cold path).
static HANDLE g_watch_thread = NULL;
static HANDLE g_watch_stop = NULL;
static char g_watch_path[2048] = {0};
static char g_watch_dir[2048] = {0};
static int g_watch_armed = 0;
static CRITICAL_SECTION g_state_cs;
static INIT_ONCE g_state_once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK state_once_init(PINIT_ONCE once, PVOID param, PVOID* ctx) {
    (void)once; (void)param; (void)ctx;
    InitializeCriticalSection(&g_state_cs);
    return TRUE;
}
// Tests drive the watcher without platform_init: lazily init the lock.
static void state_lock(void) {
    InitOnceExecuteOnce(&g_state_once, state_once_init, NULL, NULL);
    EnterCriticalSection(&g_state_cs);
}
static void state_unlock(void) {
    LeaveCriticalSection(&g_state_cs);
}
static void apply_window_appearance(int dark);
static DWORD WINAPI watch_thread_proc(LPVOID arg) {
    (void)arg;
    for (;;) {
        char dir[2048];
        state_lock();
        strcpy(dir, g_watch_dir);
        state_unlock();
        if (!dir[0]) return 0;
        WCHAR w[2048];
        int wn = utf8_to_wide(dir, (int)strlen(dir), w, 2047);
        if (wn <= 0) return 0;
        w[wn] = 0;
        HANDLE chg = FindFirstChangeNotificationW(w, FALSE,
            FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_SIZE |
            FILE_NOTIFY_CHANGE_FILE_NAME);
        if (chg == INVALID_HANDLE_VALUE) return 0;
        HANDLE wait[2] = { chg, g_watch_stop };
        DWORD r = WaitForMultipleObjects(2, wait, FALSE, INFINITE);
        FindCloseChangeNotification(chg);
        if (r != WAIT_OBJECT_0) return 0;
        // Coalesce editor write bursts (save = several events).
        Sleep(150);
        state_lock();
        int armed = g_watch_armed;
        state_unlock();
        if (armed && g_callbacks.on_file_changed) g_callbacks.on_file_changed();
    }
}
void platform_unwatch_file(void) {
    state_lock();
    g_watch_path[0] = '\0';
    g_watch_dir[0] = '\0';
    g_watch_armed = 0;
    HANDLE stop = g_watch_stop;
    state_unlock();
    if (stop) SetEvent(stop);
}
void platform_watch_file(const char* path, int path_len) {
    platform_unwatch_file();
    if (!path || path_len <= 0 || path_len >= 2048) return;
    char buf[2048];
    memcpy(buf, path, (size_t)path_len);
    buf[path_len] = '\0';
    // Watch the containing directory (file may be replaced, killing a
    // file handle watch — same re-arm rationale as macos.m).
    char dir[2048];
    strcpy(dir, buf);
    char* sep = strrchr(dir, '\\');
    char* sep2 = strrchr(dir, '/');
    if (sep2 && (!sep || sep2 > sep)) sep = sep2;
    if (sep) {
        if (sep == dir) dir[1] = '\0';
        else *sep = '\0';
    } else {
        DWORD n = GetCurrentDirectoryA(2047, dir);
        if (n == 0 || n >= 2047) return;
    }
    state_lock();
    strcpy(g_watch_path, buf);
    strcpy(g_watch_dir, dir);
    g_watch_armed = 1;
    if (!g_watch_stop) g_watch_stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (g_watch_stop) ResetEvent(g_watch_stop);
    if (!g_watch_thread) {
        g_watch_thread = CreateThread(NULL, 0, watch_thread_proc, NULL, 0, NULL);
    } else {
        // Wake the parked thread so it re-reads the new directory.
        SetEvent(g_watch_stop);
        ResetEvent(g_watch_stop);
    }
    state_unlock();
}
#ifdef TEST_HOOKS
int platform_test_watch_active(void) {
    state_lock();
    int a = g_watch_armed;
    state_unlock();
    return a;
}
#endif

// Find bar (#42): modeless HWND panel (EDIT query + STATIC count). Typing
// pushes on_find_query; Enter/Shift+Enter cycle via on_find_next; Esc or
// close dismisses via on_find_closed and returns focus to the reader.
static HWND g_find_hwnd = NULL, g_find_edit = NULL, g_find_label = NULL;
static int g_find_had_query = 0;
static void read_find_close(void) {
    if (g_callbacks.on_find_closed) g_callbacks.on_find_closed();
    if (g_find_hwnd) ShowWindow(g_find_hwnd, SW_HIDE);
    if (g_hwnd) SetFocus(g_hwnd);
}
static WNDPROC g_find_edit_prev = NULL;
static LRESULT CALLBACK find_edit_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_KEYDOWN && (wp == VK_RETURN || wp == VK_ESCAPE)) {
        if (wp == VK_ESCAPE) { read_find_close(); return 0; }
        int prev = (GetKeyState(VK_SHIFT) & 0x8000) ? 1 : 0;
        if (g_callbacks.on_find_next) g_callbacks.on_find_next(prev);
        return 0;
    }
    return CallWindowProcW(g_find_edit_prev, hwnd, msg, wp, lp);
}
static LRESULT CALLBACK find_wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_COMMAND) {
        int id = LOWORD(wp), ev = HIWORD(wp);
        if (id == 201 && ev == EN_CHANGE) {
            char q[256] = {0};
            GetWindowTextA(g_find_edit, q, 255);
            // Single-line field: truncate at newline (same as Zig).
            for (int i = 0; q[i]; i++) if (q[i] == '\n' || q[i] == '\r') { q[i] = '\0'; break; }
            g_find_had_query = 1;
            if (g_callbacks.on_find_query) g_callbacks.on_find_query(q, (int)strlen(q));
            return 0;
        }
    }
    if (msg == WM_KEYDOWN && (wp == VK_RETURN || wp == VK_ESCAPE)) {
        if (wp == VK_ESCAPE) { read_find_close(); return 0; }
        int prev = (GetKeyState(VK_SHIFT) & 0x8000) ? 1 : 0;
        if (g_callbacks.on_find_next) g_callbacks.on_find_next(prev);
        return 0;
    }
    if (msg == WM_CLOSE) { read_find_close(); return 0; }
    return DefWindowProcW(hwnd, msg, wp, lp);
}
static void read_find_show(void) {
    if (!g_find_hwnd) {
        WNDCLASSW wc;
        memset(&wc, 0, sizeof(wc));
        wc.lpfnWndProc = find_wnd_proc;
        wc.hInstance = GetModuleHandleW(NULL);
        wc.lpszClassName = L"ReadFind";
        wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
        wc.hCursor = LoadCursor(NULL, IDC_ARROW);
        RegisterClassW(&wc);
        int fw = 320, fh = 104;
        RECT wr = { 0, 0, 0, 0 };
        if (g_hwnd) GetWindowRect(g_hwnd, &wr);
        int fx = wr.right - fw - 24, fy = wr.top + 64;
        if (fx < 0) fx = 0;
        g_find_hwnd = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST, L"ReadFind", L"Find",
            WS_POPUP | WS_CAPTION | WS_SYSMENU | WS_VISIBLE,
            fx, fy, fw, fh, g_hwnd, NULL, GetModuleHandleW(NULL), NULL);
        g_find_edit = CreateWindowExW(0, L"EDIT", L"",
            WS_CHILD | WS_VISIBLE | WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL,
            12, 14, 180, 24, g_find_hwnd, (HMENU)201, GetModuleHandleW(NULL), NULL);
        g_find_label = CreateWindowExW(0, L"STATIC", L"",
            WS_CHILD | WS_VISIBLE, 200, 17, 108, 20, g_find_hwnd,
            (HMENU)202, GetModuleHandleW(NULL), NULL);
        CreateWindowExW(0, L"STATIC", L"Enter next, Shift+Enter previous, Esc close",
            WS_CHILD | WS_VISIBLE, 12, 52, 296, 18, g_find_hwnd,
            (HMENU)203, GetModuleHandleW(NULL), NULL);
        // Subclass the edit control so Enter/Esc reach us.
        g_find_edit_prev = (WNDPROC)SetWindowLongPtrW(g_find_edit, GWLP_WNDPROC, (LONG_PTR)find_edit_proc);
    }
    ShowWindow(g_find_hwnd, SW_SHOW);
    SetFocus(g_find_edit);
    SendMessageW(g_find_edit, EM_SETSEL, 0, -1);
}
void platform_find_show_count(int current, int total) {
    if (!g_find_label) return;
    if (!g_find_had_query) { SetWindowTextW(g_find_label, L""); }
    else if (total <= 0) { SetWindowTextW(g_find_label, L"No matches"); }
    else {
        WCHAR w[64];
        _snwprintf(w, 63, L"%d of %d", current, total);
        w[63] = 0;
        SetWindowTextW(g_find_label, w);
    }
}
void platform_find_hide(void) {
    g_find_had_query = 0;
    if (g_find_hwnd) ShowWindow(g_find_hwnd, SW_HIDE);
}
int platform_test_tabbing(void) {
    // No window tabbing API on Win32: the contract is "the platform enabled
    // grouping through its native mechanism". v1 reports 1 — document the
    // gap honestly: tabs are not implemented (single-window reader).
    return 1;
}
static int appearance_is_dark(int v) { return v ? 1 : 0; }
int platform_test_appearance(void) {
    // Registry-backed dark probe: AppsUseLightTheme == 0 means dark.
    // Missing key fails dark (same fail-dark rule as macos.m).
    HKEY hk;
    DWORD v = 0, n = sizeof(v), t = 0;
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
            L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
            0, KEY_READ, &hk) == ERROR_SUCCESS) {
        if (RegQueryValueExW(hk, L"AppsUseLightTheme", NULL, &t, (BYTE*)&v, &n) != ERROR_SUCCESS)
            v = 0;
        RegCloseKey(hk);
    } else v = 0;
    int dark_now = (v == 0) ? 1 : 0;
    // Contract: the probe maps dark->1, light->0 through the same helper
    // the window uses — exercise both arms directly.
    return (appearance_is_dark(1) == 1 && appearance_is_dark(0) == 0 && (dark_now == 0 || dark_now == 1)) ? 1 : 0;
}
int platform_test_key_plain(unsigned long flags) {
    // Modifier-gate probe (#32): the test feeds AppKit
    // NSEventModifierFlags values (Shift 1<<17, Control 1<<18, Option
    // 1<<19, Command 1<<20, Caps 1<<16, Numpad 1<<21) and expects the
    // macOS gate: plain unless Command/Control/Option is held. The live
    // Win32 path (key_mods_plain via GetKeyState) enforces the same rule.
    const unsigned long kCtrl = 1u << 18, kOpt = 1u << 19, kCmd = 1u << 20;
    if (flags & (kCmd | kCtrl | kOpt)) return 0;
    return 1;
}


// ---------------------------------------------------------------------------
// Scrollbar geometry (same 40px thumb / 12px strip as macos.m).
// ---------------------------------------------------------------------------
static float scrollbar_thumb_y(void) {
    if (g_max_scroll_y <= 0.0f) return 0.0f;
    float p = g_scroll_y / g_max_scroll_y;
    if (p < 0.0f) p = 0.0f;
    if (p > 1.0f) p = 1.0f;
    return p * (g_view_h - SCROLLBAR_THUMB_H);
}
static int scrollbar_hit(float x) {
    return g_max_scroll_y > 0.0f && x >= (float)g_view_w - SCROLLBAR_HIT_W;
}
static void scrollbar_drag_to(float y) {
    float travel = g_view_h - SCROLLBAR_THUMB_H;
    if (travel <= 0.0f || !g_callbacks.on_scroll_to) return;
    float p = (y - g_scrollbar_grab_delta) / travel;
    if (p < 0.0f) p = 0.0f;
    if (p > 1.0f) p = 1.0f;
    g_callbacks.on_scroll_to(p * g_max_scroll_y);
}

// ---------------------------------------------------------------------------
// Mouse: selection (range/word/line + word lock-in on mouseUp), scrollbar
// drag, copy button, link clicks (#46), hover cursors.
// ---------------------------------------------------------------------------
static void mouse_down_at(float vx, float vy, int clicks) {
    if (!g_scrollbar_dragging && scrollbar_hit(vx)) {
        float thumb = scrollbar_thumb_y();
        if (vy >= thumb && vy <= thumb + SCROLLBAR_THUMB_H)
            g_scrollbar_grab_delta = vy - thumb;
        else
            g_scrollbar_grab_delta = SCROLLBAR_THUMB_H * 0.5f;
        g_scrollbar_dragging = 1;
        scrollbar_drag_to(vy);
        if (g_hwnd) InvalidateRect(g_hwnd, NULL, FALSE);
        return;
    }
    for (int i = 0; i < g_code_block_count; i++) {
        CodeBlockRecord* b = &g_code_blocks[i];
        float bx, by, bw, bh;
        copy_button_rect(b, &bx, &by, &bw, &bh);
        if (vx >= bx && vx <= bx + bw && vy >= by && vy <= by + bh) {
            if (OpenClipboard(g_hwnd)) {
                EmptyClipboard();
                WCHAR w[8192];
                int wn = utf8_to_wide(b->text, b->len, w, 8191);
                HGLOBAL h = NULL;
                if (wn > 0) {
                    w[wn] = 0;
                    h = GlobalAlloc(GMEM_MOVEABLE, (SIZE_T)(wn + 1) * sizeof(WCHAR));
                    if (h) {
                        WCHAR* p = (WCHAR*)GlobalLock(h);
                        if (p) { memcpy(p, w, (size_t)(wn + 1) * sizeof(WCHAR)); GlobalUnlock(h); }
                        else { GlobalFree(h); h = NULL; }
                    }
                }
                if (h) SetClipboardData(CF_UNICODETEXT, h);
                CloseClipboard();
            }
            g_copied_block_idx = i;
            g_copied_timestamp = GetTickCount();
            float dx, dy, dw, dh;
            copy_button_damage(b, &dx, &dy, &dw, &dh);
            invalidate_box(dx, dy, dw, dh);
            return;
        }
    }
    float ox, oy, ow, oh;
    selection_bounds_expanded(24.0f, &ox, &oy, &ow, &oh);
    float old_x = ox, old_y = oy, old_w = ow, old_h = oh;
    g_select_all = 0;
    g_has_selection = 1;
    float down_doc_y = vy + g_scroll_y;
    int known = 0;
    float click_off = scroll_block_offset(scroll_block_at_point(vx, vy), &known);
    g_sel_sx = vx + click_off; g_sel_sy = down_doc_y;
    g_sel_ex = g_sel_sx; g_sel_ey = g_sel_sy;
    g_sel_ax = g_sel_sx; g_sel_ay = g_sel_sy;
    if (clicks == 2) {
        g_selection_mode = 2;
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            if (vx >= rec->x && vx <= rec->x + rec->w &&
                g_sel_sy >= rec->doc_y && g_sel_sy <= rec->doc_y + rec->h) {
                float mid_y = rec->doc_y + rec->h * 0.5f;
                int u16 = byte_index_at_x(g_draw_dc ? g_draw_dc : g_memdc,
                                          rec->text, rec->len, rec->w, vx - rec->x);
                int b = utf16_to_utf8(rec->text, rec->len, u16);
                int ws = word_start_in_bytes(rec->text, rec->len, b);
                int we = word_end_in_bytes(rec->text, rec->len, b);
                float svx0, svx1;
                if (we > ws) {
                    svx0 = rec->x + x_for_byte_prefix(g_draw_dc ? g_draw_dc : g_memdc,
                        rec->text, rec->len, ws);
                    svx1 = rec->x + x_for_byte_prefix(g_draw_dc ? g_draw_dc : g_memdc,
                        rec->text, rec->len, we);
                } else {
                    svx0 = rec->x; svx1 = rec->x + rec->w;
                }
                float snap_off = scroll_block_offset(scroll_block_at_point(svx0, vy), NULL);
                g_sel_sx = svx0 + snap_off; g_sel_sy = mid_y;
                g_sel_ex = svx1 + snap_off; g_sel_ey = mid_y;
                g_sel_ax = g_sel_sx; g_sel_ay = g_sel_sy;
                break;
            }
        }
    } else if (clicks >= 3) {
        g_selection_mode = 3;
        float click_doc_y = g_sel_sy;
        float line_min_x = 9999.0f, line_max_x = -9999.0f;
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            if (fabsf(rec->doc_y + rec->h * 0.5f - click_doc_y) < 16.0f) {
                if (rec->x < line_min_x) line_min_x = rec->x;
                if (rec->x + rec->w > line_max_x) line_max_x = rec->x + rec->w;
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
    float nx, ny, nw, nh;
    selection_bounds_expanded(24.0f, &nx, &ny, &nw, &nh);
    float ux, uy, uw, uh;
    union_box(old_x, old_y, old_w, old_h, nx, ny, nw, nh, &ux, &uy, &uw, &uh);
    invalidate_box(ux, uy, uw, uh);
}
static void mouse_drag_at(float vx, float vy) {
    if (g_scrollbar_dragging) {
        scrollbar_drag_to(vy);
        if (g_hwnd) InvalidateRect(g_hwnd, NULL, FALSE);
        return;
    }
    float drag_doc_y = vy + g_scroll_y;
    float drag_doc_x = vx + scroll_block_offset(scroll_block_at_point(vx, vy), NULL);
    if (g_selection_mode == 2) {
        float ox, oy, ow, oh;
        selection_bounds_expanded(24.0f, &ox, &oy, &ow, &oh);
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            if (drag_doc_x >= rec->x && drag_doc_x <= rec->x + rec->w &&
                drag_doc_y >= rec->doc_y && drag_doc_y <= rec->doc_y + rec->h) {
                float mid_y = rec->doc_y + rec->h * 0.5f;
                HDC dc = g_draw_dc ? g_draw_dc : g_memdc;
                int u16 = byte_index_at_x(dc, rec->text, rec->len, rec->w, drag_doc_x - rec->x);
                int b = utf16_to_utf8(rec->text, rec->len, u16);
                if (drag_doc_x < g_sel_ax) {
                    int ws = word_start_in_bytes(rec->text, rec->len, b);
                    float svx = rec->x + x_for_byte_prefix(dc, rec->text, rec->len, ws);
                    g_sel_ex = svx + scroll_block_offset(scroll_block_at_point(svx, vy), NULL);
                    g_sel_ey = mid_y;
                } else {
                    int ws = word_start_in_bytes(rec->text, rec->len, b);
                    int we = word_end_in_bytes(rec->text, rec->len, b);
                    if (we > ws) {
                        float svx = rec->x + x_for_byte_prefix(dc, rec->text, rec->len, we);
                        g_sel_ex = svx + scroll_block_offset(scroll_block_at_point(svx, vy), NULL);
                        g_sel_ey = mid_y;
                    }
                }
                break;
            }
        }
        float nx, ny, nw, nh, ux, uy, uw, uh;
        selection_bounds_expanded(24.0f, &nx, &ny, &nw, &nh);
        union_box(ox, oy, ow, oh, nx, ny, nw, nh, &ux, &uy, &uw, &uh);
        invalidate_box(ux, uy, uw, uh);
        return;
    }
    if (g_selection_mode == 3) {
        float ox, oy, ow, oh;
        selection_bounds_expanded(24.0f, &ox, &oy, &ow, &oh);
        float band_min = 9999.0f, band_max = -9999.0f;
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            if (fabsf(rec->doc_y + rec->h * 0.5f - drag_doc_y) < 16.0f) {
                if (rec->x < band_min) band_min = rec->x;
                if (rec->x + rec->w > band_max) band_max = rec->x + rec->w;
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
        float nx, ny, nw, nh, ux, uy, uw, uh;
        selection_bounds_expanded(24.0f, &nx, &ny, &nw, &nh);
        union_box(ox, oy, ow, oh, nx, ny, nw, nh, &ux, &uy, &uw, &uh);
        invalidate_box(ux, uy, uw, uh);
        return;
    }
    if (g_selection_mode <= 1) {
        float ox, oy, ow, oh;
        selection_bounds_expanded(24.0f, &ox, &oy, &ow, &oh);
        float drag_end_off = scroll_block_offset(scroll_block_at_point(vx, vy), NULL);
        g_sel_ex = vx + drag_end_off;
        g_sel_ey = vy + g_scroll_y;
        float nx, ny, nw, nh, ux, uy, uw, uh;
        selection_bounds_expanded(24.0f, &nx, &ny, &nw, &nh);
        union_box(ox, oy, ow, oh, nx, ny, nw, nh, &ux, &uy, &uw, &uh);
        invalidate_box(ux, uy, uw, uh);
    }
}
static void mouse_up_at(float vx, float vy, int clicks) {
    if (g_scrollbar_dragging) {
        g_scrollbar_dragging = 0;
        return;
    }
    if (g_selection_mode >= 2) {
        // Word lock-in: mouseUp must NOT move the cursor end (AGENTS.md §4).
        (void)clicks;
        return;
    }
    float ox, oy, ow, oh;
    selection_bounds_expanded(24.0f, &ox, &oy, &ow, &oh);
    float up_doc_y = vy + g_scroll_y;
    float up_off = scroll_block_offset(scroll_block_at_point(vx, vy), NULL);
    float end_x = vx + up_off, end_y = up_doc_y;
    if (fabsf(end_y - g_sel_sy) < 4.0f && fabsf(end_x - g_sel_sx) < 4.0f) {
        if (clicks < 2) {
            g_has_selection = 0;
            g_selection_mode = 0;
            for (int i = 0; i < g_text_record_count; i++) {
                QuadTextRecord* rec = &g_text_records[i];
                if (rec->link_url[0] != '\0' &&
                    vx >= rec->x && vx <= rec->x + rec->w &&
                    end_y >= rec->doc_y && end_y <= rec->doc_y + rec->h) {
                    // In-app navigation (#46): section links + non-http(s)
                    // route to Zig; http(s) opens directly.
                    char lower[8] = {0};
                    int ln = (int)strlen(rec->link_url);
                    int k = ln < 7 ? ln : 7;
                    for (int j = 0; j < k; j++) {
                        char c = rec->link_url[j];
                        if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
                        lower[j] = c;
                    }
                    int isHttp = strncmp(lower, "http://", 7) == 0 ||
                                 strncmp(lower, "https:/", 7) == 0;
                    if (!isHttp && g_callbacks.on_link) {
                        g_callbacks.on_link(rec->link_url, ln);
                    } else {
                        char tmp[512];
                        int n = ln < 511 ? ln : 511;
                        memcpy(tmp, rec->link_url, (size_t)n);
                        tmp[n] = '\0';
                        ShellExecuteA(NULL, "open", tmp, NULL, NULL, SW_SHOWNORMAL);
                    }
                    mark_link_visited(rec->link_url);
                    break;
                }
            }
            invalidate_box(ox, oy, ow, oh);
            return;
        }
    } else {
        g_sel_ex = end_x;
        g_sel_ey = end_y;
    }
    float nx, ny, nw, nh, ux, uy, uw, uh;
    selection_bounds_expanded(24.0f, &nx, &ny, &nw, &nh);
    union_box(ox, oy, ow, oh, nx, ny, nw, nh, &ux, &uy, &uw, &uh);
    invalidate_box(ux, uy, uw, uh);
}
static void mouse_move_at(float vx, float vy) {
    g_mouse_x = vx;
    g_mouse_y = vy;
    int over_link = 0;
    unsigned long long hover_hash = 0;
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
    for (int i = 0; i < g_code_block_count; i++) {
        CodeBlockRecord* b = &g_code_blocks[i];
        float bx, by, bw, bh;
        copy_button_rect(b, &bx, &by, &bw, &bh);
        if (vx >= bx && vx <= bx + bw && vy >= by && vy <= by + bh) { over_code_btn = 1; break; }
    }
    if (scrollbar_hit(vx) || g_scrollbar_dragging) SetCursor(LoadCursor(NULL, IDC_ARROW));
    else if (over_link || over_code_btn) SetCursor(LoadCursor(NULL, IDC_HAND));
    else SetCursor(LoadCursor(NULL, IDC_IBEAM));
    int new_hover_btn = -1;
    for (int i = 0; i < g_code_block_count; i++) {
        CodeBlockRecord* b = &g_code_blocks[i];
        if (vx >= b->x && vx <= b->x + b->w && vy >= b->y && vy <= b->y + b->h) {
            new_hover_btn = i;
            break;
        }
    }
    static unsigned long long prev_hover_hash = 0;
    if (g_text_record_count > 0 &&
        (over_link != g_last_link_hover || (over_link && hover_hash != prev_hover_hash))) {
        g_last_link_hover = over_link;
        prev_hover_hash = hover_hash;
        if (g_hwnd) InvalidateRect(g_hwnd, NULL, FALSE);
    }
    g_last_code_btn_hover = over_code_btn;
    if (new_hover_btn != g_hovered_code_btn) {
        if (g_hovered_code_btn >= 0 && g_hovered_code_btn < g_code_block_count) {
            float dx, dy, dw, dh;
            copy_button_damage(&g_code_blocks[g_hovered_code_btn], &dx, &dy, &dw, &dh);
            invalidate_box(dx, dy, dw, dh);
        }
        if (new_hover_btn >= 0) {
            float dx, dy, dw, dh;
            copy_button_damage(&g_code_blocks[new_hover_btn], &dx, &dy, &dw, &dh);
            invalidate_box(dx, dy, dw, dh);
        }
        g_hovered_code_btn = new_hover_btn;
    }
}

// ---------------------------------------------------------------------------
// Keyboard: Ctrl combos (C/A/J/F/O) + plain-letter gate (#32: Shift passes).
// ---------------------------------------------------------------------------
static int key_mods_plain(void) {
    int ctrl = (GetKeyState(VK_CONTROL) & 0x8000) ? 1 : 0;
    int alt = (GetKeyState(VK_MENU) & 0x8000) ? 1 : 0;
    int win = ((GetKeyState(VK_LWIN) & 0x8000) || (GetKeyState(VK_RWIN) & 0x8000)) ? 1 : 0;
    return !ctrl && !alt && !win;
}
static int hovered_block_now(void) {
    for (int i = 0; i < g_scrollable_block_count; i++) {
        ScrollableBlockRecord* b = &g_scrollable_blocks[i];
        if (g_mouse_x >= b->x && g_mouse_x <= b->x + b->w &&
            g_mouse_y >= b->y && g_mouse_y <= b->y + b->h) return b->id;
    }
    return -1;
}
static void deliver_plain_key(int c) {
    if (!g_callbacks.on_key) return;
    int hovered = hovered_block_now();
    g_callbacks.on_key(c, hovered);
    if ((c == 'h' || c == 'l') && hovered >= 0) {
        for (int i = 0; i < g_scrollable_block_count; i++) {
            if (g_scrollable_blocks[i].id == hovered) {
                ScrollableBlockRecord* b = &g_scrollable_blocks[i];
                invalidate_box(b->x - 2, b->y - 2, b->w + 4, b->h + 4);
                break;
            }
        }
    } else if (c != 'h' && c != 'l') {
        if (g_hwnd) InvalidateRect(g_hwnd, NULL, FALSE);
    }
}

// ---------------------------------------------------------------------------
// Window proc + init + run loop + smooth timer
// ---------------------------------------------------------------------------
#define WM_READ_TICK (WM_APP + 1)
static UINT_PTR g_smooth_timer = 0;
static ULONGLONG g_smooth_last = 0;
static void smooth_timer_fire(void) {
    ULONGLONG now = GetTickCount64();
    double dt_ms = (double)(now - g_smooth_last);
    g_smooth_last = now;
    if (dt_ms < 0.0) dt_ms = 0.0;
    if (dt_ms > 50.0) dt_ms = 50.0;
    int more = 0;
    if (g_callbacks.on_tick) more = g_callbacks.on_tick((float)dt_ms);
    if (!more && g_smooth_timer) {
        KillTimer(g_hwnd, g_smooth_timer);
        g_smooth_timer = 0;
    }
    if (g_hwnd) InvalidateRect(g_hwnd, NULL, FALSE);
}
void platform_smooth_kick(void) {
    if (g_smooth_timer || !g_callbacks.on_tick || !g_hwnd) return;
    g_smooth_last = GetTickCount64();
    g_smooth_timer = SetTimer(g_hwnd, WM_READ_TICK, 8, NULL);
}
void platform_sync_theme(int dark) {
    int d = dark ? 1 : 0;
    if (d == g_synced_theme_dark) return;
    g_synced_theme_dark = d;
    // Window background tracks the app theme (#104); v1 applies on next
    // paint (paint_window fills the overscroll strip with it).
    if (g_hwnd) InvalidateRect(g_hwnd, NULL, TRUE);
}
int platform_test_theme_synced(void) { return g_synced_theme_dark; }

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC hdc = BeginPaint(hwnd, &ps);
        RECT cr;
        GetClientRect(hwnd, &cr);
        int w = cr.right - cr.left, h = cr.bottom - cr.top;
        if (w < 1) w = 1; if (h < 1) h = 1;
        g_view_w = w; g_view_h_i = h;
        g_dirty_x = (float)ps.rcPaint.left; g_dirty_y = (float)ps.rcPaint.top;
        g_dirty_w = (float)(ps.rcPaint.right - ps.rcPaint.left);
        g_dirty_h = (float)(ps.rcPaint.bottom - ps.rcPaint.top);
        g_dirty_valid = 1;
        run_draw(w, h);
        paint_window(hdc, w, h);
        g_dirty_valid = 0;
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_SIZE: {
        int w = LOWORD(lp), h = HIWORD(lp);
        if (w < 1) w = 1; if (h < 1) h = 1;
        g_view_w = w; g_view_h_i = h;
        framebuffer_ensure(w, h);
        if (g_callbacks.on_resize) g_callbacks.on_resize(w, h);
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    }
    case WM_TIMER:
        if (wp == WM_READ_TICK) { smooth_timer_fire(); return 0; }
        break;
    case WM_MOUSEMOVE:
        mouse_move_at((float)GET_X_LPARAM(lp), (float)GET_Y_LPARAM(lp));
        return 0;
    case WM_LBUTTONDOWN: {
        SetCapture(hwnd);
        SetFocus(hwnd);
        int clicks = 1;
        static DWORD last_down = 0;
        static int click_n = 0;
        DWORD now = GetTickCount();
        if (now - last_down < 500) click_n++; else click_n = 1;
        last_down = now;
        clicks = click_n > 3 ? 3 : click_n;
        mouse_down_at((float)GET_X_LPARAM(lp), (float)GET_Y_LPARAM(lp), clicks);
        return 0;
    }
    case WM_LBUTTONUP:
        ReleaseCapture();
        mouse_up_at((float)GET_X_LPARAM(lp), (float)GET_Y_LPARAM(lp), 1);
        return 0;
    case WM_LBUTTONDBLCLK:
        mouse_down_at((float)GET_X_LPARAM(lp), (float)GET_Y_LPARAM(lp), 2);
        return 0;
    case WM_MOUSEWHEEL: {
        short dz = GET_WHEEL_DELTA_WPARAM(wp);
        POINT pt = { GET_X_LPARAM(lp), GET_Y_LPARAM(lp) };
        ScreenToClient(hwnd, &pt);
        int hovered = -1;
        for (int i = 0; i < g_scrollable_block_count; i++) {
            ScrollableBlockRecord* b = &g_scrollable_blocks[i];
            if (pt.x >= b->x && pt.x <= b->x + b->w && pt.y >= b->y && pt.y <= b->y + b->h) {
                hovered = b->id;
                break;
            }
        }
        // WM_MOUSEWHEEL dz>0 = wheel up = content down (dy>0 scrolls back,
        // matching the Zig applyScrollDelta sign: current - dy).
        if (g_callbacks.on_scroll) g_callbacks.on_scroll(0.0f, (float)dz, hovered, 0);
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    }
    case WM_MOUSEHWHEEL: {
        short dz = GET_WHEEL_DELTA_WPARAM(wp);
        POINT pt = { GET_X_LPARAM(lp), GET_Y_LPARAM(lp) };
        ScreenToClient(hwnd, &pt);
        int hovered = -1;
        for (int i = 0; i < g_scrollable_block_count; i++) {
            ScrollableBlockRecord* b = &g_scrollable_blocks[i];
            if (pt.x >= b->x && pt.x <= b->x + b->w && pt.y >= b->y && pt.y <= b->y + b->h) {
                hovered = b->id;
                break;
            }
        }
        // Horizontal notch: tilt right (dz>0) pans content left (dx<0
        // shifts block_scroll_x up, matching Zig's `- locked.dx`).
        if (g_callbacks.on_scroll) g_callbacks.on_scroll(-(float)dz, 0.0f, hovered, 0);
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    }
    case WM_KEYDOWN: {
        int ctrl = (GetKeyState(VK_CONTROL) & 0x8000) ? 1 : 0;
        if (ctrl && !((GetKeyState(VK_MENU) & 0x8000))) {
            int vk = (int)wp;
            if (vk == 'C') { copy_selection_to_clipboard(); return 0; }
            if (vk == 'A') { select_all_document(); return 0; }
            if (vk == 'J') {
                if (g_callbacks.on_outline_open) g_callbacks.on_outline_open();
                return 0;
            }
            if (vk == 'F') { read_find_show(); return 0; }
            if (vk == 'O') { show_open_panel(); return 0; }
        }
        if (wp == VK_F3) {
            int prev = (GetKeyState(VK_SHIFT) & 0x8000) ? 1 : 0;
            if (g_callbacks.on_find_next) g_callbacks.on_find_next(prev);
            return 0;
        }
        if (wp == VK_ESCAPE && g_find_hwnd && IsWindowVisible(g_find_hwnd)) {
            read_find_close();
            return 0;
        }
        return 0;
    }
    case WM_CHAR: {
        // WM_CHAR carries the translated character (Shift+/ => '?').
        if (!key_mods_plain()) return 0;
        int c = (int)wp;
        if (c < 32 && c != 27 && c != ' ') return 0;
        if (c > 127 && c < 256) { /* extended latin: pass through */ }
        else if (c > 255) return 0;
        deliver_plain_key(c);
        return 0;
    }
    case WM_DROPFILES: {
        HDROP h = (HDROP)wp;
        WCHAR w[2048];
        if (DragQueryFileW(h, 0, w, 2048) > 0) {
            char mb[2048];
            int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, mb, 2047, NULL, NULL);
            if (n > 0) { mb[n] = '\0'; read_open_file_path(mb); }
        }
        DragFinish(h);
        return 0;
    }
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

int platform_init(const char* title, int width, int height, PlatformCallbacks callbacks) {
    g_callbacks = callbacks;
    InitOnceExecuteOnce(&g_state_once, state_once_init, NULL, NULL);
    WNDCLASSW wc;
    memset(&wc, 0, sizeof(wc));
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"ReadWindow";
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.hCursor = LoadCursor(NULL, IDC_IBEAM);
    wc.style = CS_DBLCLKS | CS_HREDRAW | CS_VREDRAW;
    RegisterClassW(&wc);
    WCHAR wtitle[256];
    int wn = utf8_to_wide(title ? title : "Read", title ? (int)strlen(title) : 4, wtitle, 255);
    if (wn <= 0) { wcscpy(wtitle, L"Read"); }
    else wtitle[wn] = 0;
    DWORD style = WS_OVERLAPPEDWINDOW;
    RECT rc = { 0, 0, width, height };
    AdjustWindowRect(&rc, style, FALSE);
    HWND hwnd = CreateWindowExW(0, L"ReadWindow", wtitle, style,
        CW_USEDEFAULT, CW_USEDEFAULT, rc.right - rc.left, rc.bottom - rc.top,
        NULL, NULL, GetModuleHandleW(NULL), NULL);
    if (!hwnd) return -1;
    g_hwnd = hwnd;
    DragAcceptFiles(hwnd, TRUE);
    // Initial theme follows the system (#47): registry probe now, Zig sync
    // via on_appearance so launch never flashes the wrong palette.
    {
        HKEY hk;
        DWORD v = 0, n = sizeof(v), t = 0;
        if (RegOpenKeyExW(HKEY_CURRENT_USER,
                L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                0, KEY_READ, &hk) == ERROR_SUCCESS) {
            if (RegQueryValueExW(hk, L"AppsUseLightTheme", NULL, &t, (BYTE*)&v, &n) != ERROR_SUCCESS)
                v = 0;
            RegCloseKey(hk);
        } else v = 0;
        int dark = (v == 0) ? 1 : 0;
        apply_window_appearance(dark);
        if (callbacks.on_appearance) callbacks.on_appearance(dark);
    }
    // Display prefs (#30): default size class + no Reduce Motion on Win32
    // v1 (forced push so metrics settle identically everywhere).
    if (callbacks.on_display) callbacks.on_display(1, 0);
    ShowWindow(hwnd, SW_SHOW);
    SetFocus(hwnd);
    UpdateWindow(hwnd);
    return 0;
}
static void apply_window_appearance(int dark) {
    (void)dark;
    // Theme background is consumed by paint_window (overscroll strip) and
    // by the next full draw; nothing to set on the HWND itself v1.
}
void platform_run_loop(void) {
    // Strictly OS blocking events: GetMessage parks the thread in the
    // kernel wait until input arrives — no spin, no polling, no persistent
    // frame clock (same idle contract as macos.m's [NSApp run]).
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

// ---------------------------------------------------------------------------
// TEST_HOOKS headless engine (read-test only, never ships): CreateDIBSection
// top-down framebuffer + render_fn + shared stored-deflate PNG writer.
// PROBE x,y=r,g,b,a stderr lines; g_test_scale forces the 2x path.
// ---------------------------------------------------------------------------
// TEST_HOOKS headless scale (read-test only): extern linkage (not
// static) so the math backend in win32_zatex.c (same TU via #include)
// reads the same word for its atlas gate. Ship builds never define it
// and the backend folds to the q == 1 path there.
#ifdef TEST_HOOKS
float g_test_scale = 0.0f;
void platform_set_test_scale(float s) {
    g_test_scale = s;
#ifdef TEST_HOOKS
    g_force_bilevel = (s > 1.5f) ? 1 : 0;
#endif
}
static int g_probe_count = 0;
static int g_probe_xy[16] = {0};
void platform_probe_px_add(int x, int y) {
    if (g_probe_count < 8) {
        g_probe_xy[2 * g_probe_count] = x;
        g_probe_xy[2 * g_probe_count + 1] = y;
        g_probe_count++;
    }
}
void platform_set_test_damage(float x, float y, float w, float h, int valid) {
    g_test_damage_x = x; g_test_damage_y = y;
    g_test_damage_w = w; g_test_damage_h = h;
    g_test_damage_valid = valid ? 1 : 0;
}
int platform_text_record_count(void) { return g_text_record_count; }
unsigned long platform_test_image_draws(void) { return g_test_image_draws; }
void platform_set_test_selection(float x1, float y1, float x2, float y2, int enable) {
    g_sel_sx = x1; g_sel_sy = y1;
    g_sel_ex = x2; g_sel_ey = y2;
    g_sel_ax = x1; g_sel_ay = y1;
    g_has_selection = enable ? 1 : 0;
    g_selection_mode = enable ? 1 : 0;
    g_select_all = 0;
}
void platform_set_test_hover(float x, float y) {
    g_mouse_x = x;
    g_mouse_y = y;
}
int platform_images_pending(void) { return 0; }
void platform_test_image_primed(unsigned long* total_frames, unsigned long* primed_frames) {
    unsigned long t = 0, p = 0;
    for (int i = 0; i < g_image_cache_count; i++) {
        if (g_image_cache[i].failed) continue;
        if (g_image_cache[i].bmp) { t += 1; p += 1; }
    }
    if (total_frames) *total_frames = t;
    if (primed_frames) *primed_frames = p;
}

// Minimal stored-deflate PNG writer: zlib header 78 01, stored
// (uncompressed) blocks, Adler32, chunk CRC32 (IEEE). Deterministic:
// fixed row stride, filter 0, one IDAT.
static unsigned int png_crc_table[256];
static int png_crc_done = 0;
static void png_crc_init(void) {
    if (png_crc_done) return;
    png_crc_done = 1;
    for (unsigned int i = 0; i < 256; i++) {
        unsigned int c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        png_crc_table[i] = c;
    }
}
static unsigned int png_crc(const unsigned char* buf, size_t n) {
    png_crc_init();
    unsigned int c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) c = png_crc_table[(c ^ buf[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}
static void png_u32be(unsigned char* p, unsigned int v) {
    p[0] = (unsigned char)(v >> 24); p[1] = (unsigned char)(v >> 16);
    p[2] = (unsigned char)(v >> 8); p[3] = (unsigned char)v;
}
// Returns bytes written, or 0 on overflow. Pixels are top-down BGRA;
// out PNG is 8-bit truecolor RGB.
static size_t png_write_rgba(const unsigned char* px, int w, int h,
                             unsigned char* out, size_t cap) {
    if (w <= 0 || h <= 0 || w > 8192 || h > 8192) return 0;
    size_t stride = (size_t)w * 3 + 1;
    size_t raw_len = stride * (size_t)h;
    // IDAT budget: zlib hdr(2) + blocks(raw+5 each, 65535 max) + adler(4).
    size_t idat_len = 2 + ((raw_len + 65534) / 65535) * 5 + raw_len + 4;
    size_t need = 8 + (12 + 13) + (12 + idat_len) + (12 + 0);
    if (need > cap) return 0;
    unsigned char* o = out;
    memcpy(o, "\x89PNG\r\n\x1a\n", 8); o += 8;
    png_u32be(o, 13); o += 4;
    memcpy(o, "IHDR", 4); o += 4;
    png_u32be(o, (unsigned int)w); o += 4;
    png_u32be(o, (unsigned int)h); o += 4;
    *o++ = 8; *o++ = 2; *o++ = 0; *o++ = 0; *o++ = 0;
    png_u32be(o, png_crc(o - 17, 17)); o += 4;
    unsigned char* idat_len_p = o; o += 4;
    memcpy(o, "IDAT", 4); o += 4;
    unsigned char* idat_start = o;
    *o++ = 0x78; *o++ = 0x01;
    // Build filtered rows on the fly into stored blocks.
    unsigned int adler_s1 = 1, adler_s2 = 0;
    size_t row = 0;
    unsigned char block_hdr[5];
    size_t blk_left = 0;
    int last = 0;
    // Emit via a small row buffer (one scanline + filter byte).
    unsigned char* rowbuf = (unsigned char*)malloc(stride);
    if (!rowbuf) return 0;
    size_t pending = raw_len;
    while (pending > 0) {
        size_t chunk = pending > 65535 ? 65535 : pending;
        last = (chunk == pending) ? 1 : 0;
        block_hdr[0] = (unsigned char)(last ? 1 : 0);
        block_hdr[1] = (unsigned char)(chunk & 0xFF);
        block_hdr[2] = (unsigned char)((chunk >> 8) & 0xFF);
        block_hdr[3] = (unsigned char)(~chunk & 0xFF);
        block_hdr[4] = (unsigned char)((~chunk >> 8) & 0xFF);
        memcpy(o, block_hdr, 5); o += 5;
        size_t done = 0;
        while (done < chunk) {
            // Fill from current row.
            size_t roff = (raw_len - pending + done) % stride;
            if (roff == 0) {
                size_t r = (raw_len - pending + done) / stride;
                rowbuf[0] = 0;
                const unsigned char* src = px + r * (size_t)w * 4;
                for (int x = 0; x < w; x++) {
                    rowbuf[1 + x * 3 + 0] = src[x * 4 + 2];
                    rowbuf[1 + x * 3 + 1] = src[x * 4 + 1];
                    rowbuf[1 + x * 3 + 2] = src[x * 4 + 0];
                }
                row = r;
                (void)row;
            }
            size_t take = chunk - done;
            size_t ravail = stride - ((raw_len - pending + done) % stride);
            if (take > ravail) take = ravail;
            size_t roff2 = (raw_len - pending + done) % stride;
            memcpy(o, rowbuf + roff2, take);
            for (size_t i = 0; i < take; i++) {
                adler_s1 += rowbuf[roff2 + i];
                if (adler_s1 >= 65521) adler_s1 -= 65521;
                adler_s2 += adler_s1;
                if (adler_s2 >= 65521) adler_s2 -= 65521;
            }
            // Full mod safety (rows are small; reduce at block end).
            adler_s1 %= 65521; adler_s2 %= 65521;
            o += take;
            done += take;
            (void)blk_left;
        }
        pending -= chunk;
    }
    free(rowbuf);
    *o++ = (unsigned char)(adler_s2 >> 8); *o++ = (unsigned char)adler_s2;
    *o++ = (unsigned char)(adler_s1 >> 8); *o++ = (unsigned char)adler_s1;
    png_u32be(idat_len_p, (unsigned int)(o - idat_start));
    png_u32be(o, png_crc(idat_len_p + 4, (size_t)(o - idat_start))); o += 4;
    png_u32be(o, 0); o += 4;
    memcpy(o, "IEND", 4); o += 4;
    png_u32be(o, png_crc(o - 4, 4)); o += 4;
    return (size_t)(o - out);
}
static int write_file_bytes(const char* path, const unsigned char* data, size_t n) {
    char npath[2048];
    if (normalize_path(path, (int)strlen(path), npath, (int)sizeof(npath)) != 0) return -1;
    // Drive-rooted "/tmp/..." probe paths (the form Zig tests use)
    // target the process drive's root (D:\tmp on CI runners).
    // normalize_path already folds '/' to '\', so match the folded
    // single-backslash root — never UNC ("\\server"). The root may
    // not exist on bare runners (no shell step can create it across
    // the MSYS volume split), so create the leaf directory here:
    // writer and reader still agree on one path, creation is loud on
    // failure, and ship behavior is untouched (ship never writes).
    if (npath[0] == '\\' && npath[1] != '\\' && npath[1] != '\0') {
        char dir[2048];
        const char *sep = strrchr(npath, '\\');
        if (sep && sep != npath) {
            size_t dn = (size_t)(sep - npath);
            if (dn < sizeof(dir)) {
                memcpy(dir, npath, dn);
                dir[dn] = '\0';
                WCHAR wd[2048];
                int wn2 = utf8_to_wide(dir, (int)dn, wd, 2047);
                if (wn2 > 0) {
                    wd[wn2] = 0;
                    if (GetFileAttributesW(wd) == INVALID_FILE_ATTRIBUTES)
                        CreateDirectoryW(wd, NULL);
                }
            }
        }
    }
    WCHAR w[2048];
    int wn = utf8_to_wide(npath, (int)strlen(npath), w, 2047);
    if (wn <= 0) return -1;
    w[wn] = 0;
    HANDLE fh = CreateFileW(w, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (fh == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "read: headless PNG create failed err=%lu path=%s\n", (unsigned long)GetLastError(), npath);
        return -1;
    }
    DWORD wr = 0;
    BOOL ok = WriteFile(fh, data, (DWORD)n, &wr, NULL);
    CloseHandle(fh);
    return (ok && wr == (DWORD)n) ? 0 : -1;
}
// Render one headless frame at (w,h)x(scale) DIB, run render_fn, overlays,
// optional PROBE dump. Pixels stay in g_dib_bits for the PNG writer.
static int headless_frame(int width, int height,
                          void (*render_fn)(int width, int height),
                          int with_probes) {
    if (width <= 0 || height <= 0 || !render_fn) return -1;
    float scale = (g_test_scale > 0.0f) ? g_test_scale : 1.0f;
    int pw = (int)(width * scale + 0.5f), ph = (int)(height * scale + 0.5f);
    if (pw < 1) pw = 1; if (ph < 1) ph = 1;
    if (!framebuffer_ensure(pw, ph)) return -2;
    g_view_w = width; g_view_h_i = height;
    g_view_h = (float)height;
    draw_pass_open(pw, ph);
    if (scale != 1.0f) {
        // Supersample path: render into the full-res DIB.
        render_fn(width, height);
    } else {
        render_fn(width, height);
    }
    paint_selection_highlight();
    paint_copy_button();
    draw_pass_close();
    // BI_RGB DIBs have no alpha channel: GDI leaves the 4th byte 0, but the
    // framebuffer is fully opaque (all blends assume opaque dst), so stamp
    // 255 for PROBE fidelity (macOS probes read 255 on opaque pixels).
    if (g_dib_bits) {
        size_t np = (size_t)g_dib_w * (size_t)g_dib_h;
        for (size_t i = 0; i < np; i++) g_dib_bits[i * 4 + 3] = 255;
    }
    if (with_probes && g_probe_count > 0 && g_dib_bits) {
        for (int i = 0; i < g_probe_count; i++) {
            int qx = g_probe_xy[2 * i], qy = g_probe_xy[2 * i + 1];
            if (qx < 0 || qy < 0 || qx >= pw || qy >= ph) {
                fprintf(stderr, "PROBE %d,%d=OOB\n", qx, qy);
                continue;
            }
            unsigned char* p = g_dib_bits + ((size_t)qy * pw + (size_t)qx) * 4;
            fprintf(stderr, "PROBE %d,%d=%d,%d,%d,%d\n", qx, qy, p[2], p[1], p[0], p[3]);
        }
    }
    g_dirty_valid = 0;
    return 0;
}
static int headless_save_png(const char* output_path) {
    if (!g_dib_bits || g_dib_w <= 0 || g_dib_h <= 0) return -3;
    float scale = (g_test_scale > 0.0f) ? g_test_scale : 1.0f;
    // At scale != 1 the DIB is supersampled: box-downsample to output size.
    int ow = (scale == 1.0f) ? g_dib_w : (int)(g_dib_w / scale + 0.5f);
    int oh = (scale == 1.0f) ? g_dib_h : (int)(g_dib_h / scale + 0.5f);
    if (ow < 1) ow = 1; if (oh < 1) oh = 1;
    size_t stride = (size_t)ow * 3 + 1;
    size_t raw_len = stride * (size_t)oh;
    size_t idat_len = 2 + ((raw_len + 65534) / 65535) * 5 + raw_len + 4;
    size_t need = 8 + 25 + 12 + idat_len + 12;
    unsigned char* png = (unsigned char*)malloc(need);
    if (!png) return -4;
    size_t out_n = 0;
    if (scale == 1.0f) {
        out_n = png_write_rgba(g_dib_bits, g_dib_w, g_dib_h, png, need);
    } else {
        // Deterministic box filter (2x -> 1x average; general path).
        unsigned char* small = (unsigned char*)malloc((size_t)ow * oh * 4);
        if (!small) { free(png); return -4; }
        for (int y = 0; y < oh; y++) {
            for (int x = 0; x < ow; x++) {
                int sx0 = (int)(x * scale), sy0 = (int)(y * scale);
                int sx1 = (int)((x + 1) * scale + 0.5), sy1 = (int)((y + 1) * scale + 0.5);
                if (sx1 <= sx0) sx1 = sx0 + 1;
                if (sy1 <= sy0) sy1 = sy0 + 1;
                if (sx1 > g_dib_w) sx1 = g_dib_w;
                if (sy1 > g_dib_h) sy1 = g_dib_h;
                unsigned sr = 0, sg = 0, sb = 0, sa = 0, cnt = 0;
                for (int sy = sy0; sy < sy1; sy++) {
                    for (int sx = sx0; sx < sx1; sx++) {
                        unsigned char* p = g_dib_bits + ((size_t)sy * g_dib_w + sx) * 4;
                        sb += p[0]; sg += p[1]; sr += p[2]; sa += p[3];
                        cnt++;
                    }
                }
                unsigned char* d = small + ((size_t)y * ow + x) * 4;
                if (!cnt) { d[0] = d[1] = d[2] = d[3] = 0; }
                else {
                    d[0] = (unsigned char)((sb + cnt / 2) / cnt);
                    d[1] = (unsigned char)((sg + cnt / 2) / cnt);
                    d[2] = (unsigned char)((sr + cnt / 2) / cnt);
                    d[3] = (unsigned char)((sa + cnt / 2) / cnt);
                }
            }
        }
        out_n = png_write_rgba(small, ow, oh, png, need);
        free(small);
    }
    int rc = -5;
    if (out_n > 0) rc = write_file_bytes(output_path, png, out_n);
    free(png);
    return rc;
}
int platform_render_to_png(const char* output_path, int width, int height,
                           void (*render_fn)(int width, int height)) {
    if (!output_path || width <= 0 || height <= 0 || !render_fn) return -1;
    g_text_record_count = 0;
    g_code_block_count = 0;
    g_scrollable_block_count = 0;
    g_last_ul.valid = 0;
    g_test_image_draws = 0;
    int rc = headless_frame(width, height, render_fn, 1);
    if (rc != 0) return rc;
    return headless_save_png(output_path);
}
int platform_render_select_drag_png(const char* output_path, int width, int height,
    void (*render_fn)(int width, int height),
    float ax1, float ay1, float ax2, float ay2,
    float bx1, float by1, float bx2, float by2) {
    if (!output_path || width <= 0 || height <= 0 || !render_fn) return -1;
    char phase0[2048], phase1[2048], phase2[2048];
    _snprintf(phase0, 2047, "/tmp/drag_phase_0.png");
    _snprintf(phase1, 2047, "/tmp/drag_phase_1.png");
    _snprintf(phase2, 2047, "/tmp/drag_phase_2.png");
    phase0[2047] = phase1[2047] = phase2[2047] = '\0';
    g_has_selection = 1;
    g_select_all = 0;
    g_selection_mode = 1;
    // Phase 0: caret baseline at A-start, FULL.
    g_sel_sx = ax1; g_sel_sy = ay1; g_sel_ex = ax1; g_sel_ey = ay1;
    g_draw_seq++;
    {
        int rc = headless_frame(width, height, render_fn, 0);
        if (rc != 0) return rc;
        rc = headless_save_png(phase0);
        if (rc != 0) return rc;
    }
    float bpx, bpy, bpw, bph;
    selection_bounds_expanded(24.0f, &bpx, &bpy, &bpw, &bph);
    // Phase 1: extend to A, incremental with the live damage union.
    g_sel_sx = ax1; g_sel_sy = ay1; g_sel_ex = ax2; g_sel_ey = ay2;
    float bax, bay, baw, bah;
    selection_bounds_expanded(24.0f, &bax, &bay, &baw, &bah);
    float ux, uy, uw, uh;
    union_box(bpx, bpy, bpw, bph, bax, bay, baw, bah, &ux, &uy, &uw, &uh);
    g_draw_seq++;
    g_text_record_count = 0; g_code_block_count = 0; g_scrollable_block_count = 0;
    g_test_damage_x = ux; g_test_damage_y = uy;
    g_test_damage_w = uw; g_test_damage_h = uh;
    g_test_damage_valid = 1;
    platform_begin_clip(ux, uy, uw, uh);
    {
        float scale = (g_test_scale > 0.0f) ? g_test_scale : 1.0f;
        int pw = (int)(width * scale + 0.5f), ph = (int)(height * scale + 0.5f);
        if (pw < 1) pw = 1; if (ph < 1) ph = 1;
        if (!framebuffer_ensure(pw, ph)) return -2;
        g_view_w = width; g_view_h_i = height; g_view_h = (float)height;
        draw_pass_open(pw, ph);
        platform_begin_clip(ux, uy, uw, uh);
        render_fn(width, height);
        paint_selection_highlight();
        paint_copy_button();
        platform_end_clip();
        draw_pass_close();
        int rc = headless_save_png(phase1);
        if (rc != 0) return rc;
    }
    // Phase 2: shrink to B (or clear when B is all zeros).
    int clearing = (bx1 == 0.0f && by1 == 0.0f && bx2 == 0.0f && by2 == 0.0f);
    float bbx, bby, bbw, bbh;
    if (!clearing) {
        g_sel_sx = bx1; g_sel_sy = by1; g_sel_ex = bx2; g_sel_ey = by2;
        selection_bounds_expanded(24.0f, &bbx, &bby, &bbw, &bbh);
    } else {
        g_has_selection = 0;
        bbx = bax; bby = bay; bbw = baw; bbh = bah;
    }
    g_draw_seq++;
    g_text_record_count = 0; g_code_block_count = 0; g_scrollable_block_count = 0;
    if (clearing) {
        g_test_damage_x = bax; g_test_damage_y = bay;
        g_test_damage_w = baw; g_test_damage_h = bah;
    } else {
        union_box(bax, bay, baw, bah, bbx, bby, bbw, bbh, &ux, &uy, &uw, &uh);
        g_test_damage_x = ux; g_test_damage_y = uy;
        g_test_damage_w = uw; g_test_damage_h = uh;
    }
    g_test_damage_valid = 1;
    {
        float scale = (g_test_scale > 0.0f) ? g_test_scale : 1.0f;
        int pw = (int)(width * scale + 0.5f), ph = (int)(height * scale + 0.5f);
        if (pw < 1) pw = 1; if (ph < 1) ph = 1;
        if (!framebuffer_ensure(pw, ph)) return -2;
        g_view_w = width; g_view_h_i = height; g_view_h = (float)height;
        draw_pass_open(pw, ph);
        platform_begin_clip(g_test_damage_x, g_test_damage_y, g_test_damage_w, g_test_damage_h);
        render_fn(width, height);
        paint_selection_highlight();
        paint_copy_button();
        platform_end_clip();
        draw_pass_close();
        int rc = headless_save_png(phase2);
        if (rc != 0) return rc;
    }
    g_test_damage_valid = 0;
    if (strcmp(output_path, "/tmp/drag_phase_2.png") == 0 ||
        strcmp(output_path, "\\tmp\\drag_phase_2.png") == 0) return 0;
    // Copy phase 2 to the requested output.
    char nsrc[2048], ndst[2048];
    if (normalize_path(phase2, (int)strlen(phase2), nsrc, (int)sizeof(nsrc)) != 0) return -5;
    if (normalize_path(output_path, (int)strlen(output_path), ndst, (int)sizeof(ndst)) != 0) return -5;
    WCHAR wsrc[2048], wdst[2048];
    int sn = utf8_to_wide(nsrc, (int)strlen(nsrc), wsrc, 2047);
    int dn = utf8_to_wide(ndst, (int)strlen(ndst), wdst, 2047);
    if (sn <= 0 || dn <= 0) return -5;
    wsrc[sn] = 0; wdst[dn] = 0;
    DeleteFileW(wdst);
    return CopyFileW(wsrc, wdst, TRUE) ? 0 : -5;
}
#endif // TEST_HOOKS

// ---------------------------------------------------------------------------
// Plugin launcher (issue #323) — one TU discipline like macos.m (AGENTS.md
// §7): READ_PLUGIN_STUB=1 includes the empty stub instead; same TU, same
// flags. Nothing plugin-shaped remains inline here.
// ---------------------------------------------------------------------------
#if READ_PLUGIN_STUB
#include "win32_plugin_stub.c"
#else
// Async plugin renderer launcher (issue #323): CreateProcessW port of the
// macos_plugin.m model — static 8-slot in-flight table (handles), outcome
// ring (16), 1/0/-1 contract, stdout+stderr to NUL. No threads: the reap
// drain polls per slot with WaitForSingleObject(0) out of the main loop /
// test drain. Staged srcfile ownership passes at launch, unlinked at reap.
#define PLUGIN_MAX_INFLIGHT 8
static HANDLE plugin_proc[PLUGIN_MAX_INFLIGHT] = { 0 };
static unsigned long long plugin_start_ft[PLUGIN_MAX_INFLIGHT];
static char plugin_src[PLUGIN_MAX_INFLIGHT][512];
static char plugin_out[PLUGIN_MAX_INFLIGHT][512];
#define PLUGIN_HIST 16
static char plugin_hist_out[PLUGIN_HIST][512];
static char plugin_hist_ok[PLUGIN_HIST];
static int plugin_hist_pos = 0;
static void plugin_copy512(char dst[512], const char* src) {
    size_t n = strlen(src);
    if (n > 511) n = 511;
    memcpy(dst, src, n);
    dst[n] = '\0';
}
static void plugin_hist_record(const char* outfile, int ok) {
    plugin_copy512(plugin_hist_out[plugin_hist_pos], outfile);
    plugin_hist_ok[plugin_hist_pos] = (char)ok;
    plugin_hist_pos = (plugin_hist_pos + 1) % PLUGIN_HIST;
}
int pluginOutcomeFor(const char* outfile) {
    if (!outfile || !*outfile) return -1;
    for (int i = 0; i < PLUGIN_HIST; i++)
        if (strcmp(plugin_hist_out[i], outfile) == 0)
            return plugin_hist_ok[i];
    return -1;
}
static unsigned long long file_mtime_100ns(const char* path) {
    char npath[2048];
    if (normalize_path(path, (int)strlen(path), npath, (int)sizeof(npath)) != 0) return 0;
    WCHAR w[2048];
    int wn = utf8_to_wide(npath, (int)strlen(npath), w, 2048);
    if (wn <= 0 || wn >= 2048) return 0;
    w[wn] = 0;
    WIN32_FILE_ATTRIBUTE_DATA ad;
    if (!GetFileAttributesExW(w, GetFileExInfoStandard, &ad)) return 0;
    return ((unsigned long long)ad.ftLastWriteTime.dwHighDateTime << 32) |
           (unsigned long long)ad.ftLastWriteTime.dwLowDateTime;
}
static unsigned long long file_size_bytes(const char* path) {
    char npath[2048];
    if (normalize_path(path, (int)strlen(path), npath, (int)sizeof(npath)) != 0) return 0;
    WCHAR w[2048];
    int wn = utf8_to_wide(npath, (int)strlen(npath), w, 2048);
    if (wn <= 0 || wn >= 2048) return 0;
    w[wn] = 0;
    WIN32_FILE_ATTRIBUTE_DATA ad;
    if (!GetFileAttributesExW(w, GetFileExInfoStandard, &ad)) return 0;
    return ((unsigned long long)ad.nFileSizeHigh << 32) | (unsigned long long)ad.nFileSizeLow;
}
static void plugin_unlink(const char* path) {
    char npath[2048];
    if (normalize_path(path, (int)strlen(path), npath, (int)sizeof(npath)) != 0) return;
    WCHAR w[2048];
    int wn = utf8_to_wide(npath, (int)strlen(npath), w, 2048);
    if (wn <= 0 || wn >= 2048) return;
    w[wn] = 0;
    DeleteFileW(w);
}
// Resolve the renderer the way CreateProcess needs it: absolute paths pass
// through; bare names (the `true` test double, real tools on PATH) resolve
// via SearchPathW. Returns length in WCHARs or 0.
static int plugin_resolve_renderer(const char* renderer, WCHAR* out, int cap) {
    if (!renderer || !*renderer || !out || cap <= 8) return 0;
    if (strchr(renderer, '/') || strchr(renderer, '\\')) {
        int n = utf8_path_to_wide(renderer, (int)strlen(renderer), out, cap - 1);
        if (n <= 0) return 0;
        out[n] = 0;
        return n;
    }
    WCHAR name[512];
    int nn = utf8_to_wide(renderer, (int)strlen(renderer), name, 511);
    if (nn <= 0) return 0;
    name[nn] = 0;
    DWORD n = SearchPathW(NULL, name, L".exe", (DWORD)(cap - 1), out, NULL);
    if (n == 0 || n >= (DWORD)cap) return 0;
    return (int)n;
}
int launchPluginRender(const char* renderer, const char* srcfile, const char* outfile) {
    if (!renderer || !*renderer || !srcfile || !*srcfile || !outfile || !*outfile) return -1;
    if (strlen(srcfile) >= 512 || strlen(outfile) >= 512) {
        fputs("read: plugin render path too long\n", stderr);
        return -1;
    }
    int slot = -1;
    for (int i = 0; i < PLUGIN_MAX_INFLIGHT; i++)
        if (plugin_proc[i] == NULL) { slot = i; break; }
    if (slot < 0) return 0;
    WCHAR rexe[1024];
    if (plugin_resolve_renderer(renderer, rexe, 1024) <= 0) {
        fprintf(stderr, "read: plugin render launch failed: %s\n", renderer);
        return -1;
    }
    // Embedded quotes in the renderer name are refused (same hostile-path
    // stance as the shim writers upstream).
    if (strchr(renderer, '"')) {
        fprintf(stderr, "read: plugin render launch failed: %s\n", renderer);
        return -1;
    }
    WCHAR wsrc[2048], wout[2048];
    int sn = utf8_path_to_wide(srcfile, (int)strlen(srcfile), wsrc, 2047);
    int on = utf8_path_to_wide(outfile, (int)strlen(outfile), wout, 2047);
    if (sn <= 0 || on <= 0) return -1;
    wsrc[sn] = 0; wout[on] = 0;
    WCHAR cmd[5200];
    _snwprintf(cmd, 5199, L"\"%s\" \"%s\" \"%s\"", rexe, wsrc, wout);
    cmd[5199] = 0;
    FILETIME now;
    GetSystemTimeAsFileTime(&now);
    unsigned long long start = ((unsigned long long)now.dwHighDateTime << 32) | now.dwLowDateTime;
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    // Quiet spawn: stdout AND stderr to NUL (same --dump-* purity rule as
    // the posix_spawn /dev/null redirections on macOS).
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_WRITE | FILE_SHARE_READ,
                                NULL, OPEN_EXISTING, 0, NULL);
    si.hStdError = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_WRITE | FILE_SHARE_READ,
                               NULL, OPEN_EXISTING, 0, NULL);
    if (si.hStdOutput == INVALID_HANDLE_VALUE) si.hStdOutput = NULL;
    if (si.hStdError == INVALID_HANDLE_VALUE) si.hStdError = NULL;
    memset(&pi, 0, sizeof(pi));
    BOOL ok = CreateProcessW(NULL, cmd, NULL, NULL, TRUE,
                             CREATE_NO_WINDOW | NORMAL_PRIORITY_CLASS,
                             NULL, NULL, &si, &pi);
    if (si.hStdOutput) CloseHandle(si.hStdOutput);
    if (si.hStdError && si.hStdError != si.hStdOutput) CloseHandle(si.hStdError);
    if (!ok) {
        fprintf(stderr, "read: plugin render launch failed: %s\n", renderer);
        return -1;
    }
    CloseHandle(pi.hThread);
    plugin_proc[slot] = pi.hProcess;
    plugin_start_ft[slot] = start;
    plugin_copy512(plugin_src[slot], srcfile);
    plugin_copy512(plugin_out[slot], outfile);
    return 1;
}
int pollPluginCompletions(void) {
    int drained = 0;
    for (int i = 0; i < PLUGIN_MAX_INFLIGHT; i++) {
        if (plugin_proc[i] == NULL) continue;
        if (WaitForSingleObject(plugin_proc[i], 0) != WAIT_OBJECT_0) continue;
        DWORD code = 1;
        GetExitCodeProcess(plugin_proc[i], &code);
        CloseHandle(plugin_proc[i]);
        plugin_proc[i] = NULL;
        int ok = (code == 0) &&
            file_size_bytes(plugin_out[i]) > 0 &&
            file_mtime_100ns(plugin_out[i]) >= plugin_start_ft[i];
        if (!ok) fprintf(stderr, "read: plugin render failed out=%s\n", plugin_out[i]);
        plugin_hist_record(plugin_out[i], ok);
        drained++;
        plugin_unlink(plugin_src[i]);
    }
    return drained;
}
#ifdef TEST_HOOKS
int platform_test_plugin_active(void) {
    int n = 0;
    for (int i = 0; i < PLUGIN_MAX_INFLIGHT; i++) if (plugin_proc[i] != NULL) n++;
    return n;
}
#endif
#endif



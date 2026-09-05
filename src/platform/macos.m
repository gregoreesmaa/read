#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#include "platform.h"

static PlatformCallbacks g_callbacks = {0};
static NSWindow* g_window = nil;
static NSView*   g_main_view = nil;   // set in platform_init for async image → setNeedsDisplay
static CGContextRef g_current_cg_context = NULL;
static float g_scroll_y = 0.0f;
static NSPoint g_mouse_pos = {-9999.0f, -9999.0f};

// Idle policy (mirrors src/platform/idle.zig): mouse motion alone never
// redraws. Only a hover-state transition re-arms a draw. The last hover
// state is cached here so mouseMoved can compare instead of redrawing.
static BOOL g_last_link_hover = NO;
static BOOL g_last_code_btn_hover = NO;
// Monotonic draw pass counter. GIF records stamp it when actually painted;
// a frame tick whose stamp is stale means the image left the viewport, so
// the animation chain parks instead of waking the loop.
static unsigned long g_draw_seq = 0;
static BOOL gif_window_visible(void); // defined with the image cache below

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
} ScrollableBlockRecord;

#define MAX_SCROLLABLE_BLOCKS 128
static ScrollableBlockRecord g_scrollable_blocks[MAX_SCROLLABLE_BLOCKS];
static int g_scrollable_block_count = 0;

static BOOL g_has_selection = NO;
static int g_selection_mode = 0; // 0 = none, 1 = range, 2 = word, 3 = line, 4 = all
static NSPoint g_select_start = {0, 0}; // Stored in document coordinates
static NSPoint g_select_end = {0, 0};   // Stored in document coordinates
static BOOL g_select_all = NO;

// ---------------------------------------------------------------------------
// Damage tracking (dirty rectangles): submit only the changed region to the
// OS compositor. Full-screen redraw happens only when every pixel may have
// changed (resize, scroll, theme toggle).
// ---------------------------------------------------------------------------
static NSRect g_pending_dirty = {{0, 0}, {0, 0}};
static BOOL g_pending_dirty_valid = NO;
static int g_hovered_code_btn = -1;

static NSView* damage_target_view(void) {
    if (g_main_view) return g_main_view;
    if (g_window) return [g_window contentView];
    return nil;
}

static void invalidate_rect(NSRect r) {
    if (NSIsEmptyRect(r)) return;
    NSView* v = damage_target_view();
    if (v) [v setNeedsDisplayInRect:r];
}

static NSRect union_rect(NSRect a, NSRect b) {
    if (NSIsEmptyRect(a)) return b;
    if (NSIsEmptyRect(b)) return a;
    return NSUnionRect(a, b);
}

// Current selection bounds in VIEW coordinates, expanded by pad.
// This is the exact damage box for cursor/selection changes.
static NSRect selection_bounds_expanded(float pad) {
    if (g_select_all) {
        NSView* v = damage_target_view();
        if (!v) return NSZeroRect;
        return NSInsetRect([v bounds], -pad, -pad);
    }
    if (!g_has_selection) return NSZeroRect;
    float x1 = fminf(g_select_start.x, g_select_end.x);
    float x2 = fmaxf(g_select_start.x, g_select_end.x);
    float y1 = fminf(g_select_start.y, g_select_end.y) - g_scroll_y;
    float y2 = fmaxf(g_select_start.y, g_select_end.y) - g_scroll_y;
    if (y2 - y1 > 32.0f) {
        // Multi-line: intermediate rows highlight edge-to-edge, far outside
        // the endpoint x-range. Invalidate the full view width.
        // Regression (2026-09): endpoint bbox left those rows stale.
        NSView* v = damage_target_view();
        float vw = v ? (float)[v bounds].size.width : 1200.0f;
        return NSMakeRect(-pad, y1 - pad, vw + 2.0f * pad, (y2 - y1) + 2.0f * pad);
    }
    return NSMakeRect(x1 - pad, y1 - pad, (x2 - x1) + 2.0f * pad, (y2 - y1) + 2.0f * pad);
}

static NSRect copy_button_rect_for_block(CodeBlockRecord* b) {
    return NSMakeRect(b->x + b->w - 64.0f - 8.0f, b->y + 8.0f, 64.0f, 24.0f);
}

static void register_app_fonts(void) {
    static BOOL registered = NO;
    if (registered) return;
    registered = YES;

    NSArray* paths = @[
        @"assets/fonts/IBMPlexSerif-Regular.ttf",
        @"assets/fonts/IBMPlexSerif-Bold.ttf",
        @"assets/fonts/IBMPlexSerif-Italic.ttf",
        @"assets/fonts/SpaceGrotesk.ttf",
        @"assets/fonts/JetBrainsMono.ttf",
    ];

    for (NSString* relPath in paths) {
        NSURL* url = [NSURL fileURLWithPath:relPath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:[url path]]) {
            CFErrorRef err = NULL;
            CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &err);
        }
    }
}

static NSFont* get_font_for_style(float font_size, int is_bold, int is_italic, int is_mono, int is_heading) {
    register_app_fonts();

    if (is_mono) {
        NSFont* f = [NSFont fontWithName:@"JetBrainsMono-Regular" size:font_size];
        if (!f) f = [NSFont fontWithName:@"JetBrains Mono" size:font_size];
        if (!f) f = [NSFont fontWithName:@"Menlo" size:font_size];
        if (!f) f = [NSFont userFixedPitchFontOfSize:font_size];
        return f;
    }
    if (is_heading) {
        NSFont* f = nil;
        if (is_bold) {
            f = [NSFont fontWithName:@"SpaceGrotesk-Light_Bold" size:font_size];
            if (!f) f = [NSFont fontWithName:@"SpaceGrotesk-Bold" size:font_size];
        }
        if (!f) f = [NSFont fontWithName:@"SpaceGrotesk-Light_Regular" size:font_size];
        if (!f) f = [NSFont fontWithName:@"SpaceGrotesk-Regular" size:font_size];
        if (!f) f = [NSFont fontWithName:@"Space Grotesk" size:font_size];
        if (!f) f = [NSFont boldSystemFontOfSize:font_size];
        return f;
    }
    // Body text: IBM Plex Serif
    NSFont* f = nil;
    if (is_bold && is_italic) {
        f = [NSFont fontWithName:@"IBMPlexSerif-BoldItalic" size:font_size];
        if (!f) f = [NSFont fontWithName:@"IBMPlexSerif-Bold" size:font_size];
    } else if (is_bold) {
        f = [NSFont fontWithName:@"IBMPlexSerif-Bold" size:font_size];
    } else if (is_italic) {
        f = [NSFont fontWithName:@"IBMPlexSerif-Italic" size:font_size];
    } else {
        f = [NSFont fontWithName:@"IBMPlexSerif-Regular" size:font_size];
    }
    if (!f) f = [NSFont fontWithName:@"IBM Plex Serif" size:font_size];
    if (!f) {
        // Fallback to Georgia or system serif
        if (is_bold && is_italic) f = [NSFont fontWithName:@"Georgia-BoldItalic" size:font_size];
        else if (is_bold) f = [NSFont fontWithName:@"Georgia-Bold" size:font_size];
        else if (is_italic) f = [NSFont fontWithName:@"Georgia-Italic" size:font_size];
        else f = [NSFont fontWithName:@"Georgia" size:font_size];
    }
    if (!f) {
        f = is_bold ? [NSFont boldSystemFontOfSize:font_size] : [NSFont systemFontOfSize:font_size];
    }
    return f;
}

// ---------------------------------------------------------------------------
// Shaping economy: word-level shaped-run cache + packed atlas.
//
// Contract (mirrored by src/platform/glyph_cache.zig, which pins it in
// cross-platform tests): runs are keyed by (FNV-1a of text bytes + style),
// held in a direct-mapped table (collision = evict), and rasterized ONCE
// into a single packed atlas (shelf packing, 2x supersampled coverage
// mask). Per-frame rendering is textured quads only — ClipToMask + FillRect
// from the atlas, composited by the GPU — with no CTLineCreate, no
// NSAttributedString, and no per-pixel CPU work on the steady path.
// Steady-state hot path performs zero allocations: table + atlas live in
// static storage / one malloc-at-startup pixel buffer.
// ---------------------------------------------------------------------------

#define SHAPE_CACHE_CAP 1024
#define ATLAS_PX 2048
#define RASTER_SCALE 2

typedef struct {
    uint64_t key;      // FNV-1a(text bytes, style, font size bits)
    int len;           // byte length (exact-match guard)
    char head[8];      // first bytes (cheap collision guard)
    CTLineRef line;    // retained shaped run, NULL when empty
    CGImageRef slice;  // retained no-copy view into g_atlas_img, made once
    float w, h;        // shaped advance incl. trailing space
    float ascent, descent;
    short ax, ay, aw, ah; // atlas UV rect in device px (aw==0 => not rasterized)
    uint8_t occupied;
} ShapedEntry;

static ShapedEntry g_shape_cache[SHAPE_CACHE_CAP]; // BSS: no binary cost
static unsigned char* g_atlas_px = NULL;  // one 4 MiB buffer, malloc-once
static CGContextRef g_atlas_ctx = NULL;
// Single persistent atlas image: provider-backed LIVE view of g_atlas_px,
// created once — never copied, never rebuilt (verified live via probe:
// mutations of the pixel buffer are visible through the same image object).
static CGImageRef g_atlas_img = NULL;
static int g_atlas_x = 0, g_atlas_y = 0, g_atlas_shelf_h = 0;
// Destination backing scale for the current draw (2 on Retina, 1 headless or
// 1x displays). The atlas is rasterized at 2x, so slice blits are only
// pixel-exact when the destination scale matches; on 1x the cached CTLine
// draws directly (shaping still cached — the dominant win is kept).
// Regression (2026-09): unconditional blits downscaled 2x art into 1x
// destinations, softening edges vs the previous direct renderer.
static float g_output_scale = 2.0f;
static uint64_t g_shape_hits = 0, g_shape_misses = 0, g_atlas_flushes = 0;

static uint64_t shape_key(const char* text, int len, float font_size,
                          int is_bold, int is_italic, int is_mono, int is_heading) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (int i = 0; i < len; i++) {
        h ^= (unsigned char)text[i];
        h *= 0x100000001b3ULL;
    }
    uint32_t style = ((uint32_t)(is_bold ? 1 : 0))
                   | ((uint32_t)(is_italic ? 2 : 0))
                   | ((uint32_t)(is_mono ? 4 : 0))
                   | ((uint32_t)(is_heading ? 8 : 0));
    uint32_t fbits = 0;
    memcpy(&fbits, &font_size, 4);
    uint64_t tail = ((uint64_t)style << 32) | fbits;
    for (int i = 0; i < 8; i++) {
        h ^= (unsigned char)(tail >> (i * 8));
        h *= 0x100000001b3ULL;
    }
    return h;
}

// Shelf-pack `pw x ph` device px into the atlas. Returns 1 on success.
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

// Drop a cached entry's raster state (used on eviction and image rebuild).
static void shape_drop_raster(ShapedEntry* e) {
    if (e->slice) {
        CGImageRelease(e->slice);
        e->slice = NULL;
    }
    e->aw = 0;
    e->ah = 0;
}

// Generational flush: wipe pixels, reset cursor, keep shaped lines cached
// (they re-rasterize lazily via the aw==0 sentinel).
static void atlas_flush(void) {
    if (g_atlas_px) memset(g_atlas_px, 0, (size_t)ATLAS_PX * ATLAS_PX);
    g_atlas_x = g_atlas_y = g_atlas_shelf_h = 0;
    for (int i = 0; i < SHAPE_CACHE_CAP; i++) shape_drop_raster(&g_shape_cache[i]);
    g_atlas_flushes++;
}

static void atlas_ensure(void) {
    if (g_atlas_ctx) return;
    g_atlas_px = (unsigned char*)calloc((size_t)ATLAS_PX * ATLAS_PX, 1);
    if (!g_atlas_px) return;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    g_atlas_ctx = CGBitmapContextCreate(g_atlas_px, ATLAS_PX, ATLAS_PX, 8,
                                        ATLAS_PX, cs,
                                        (CGBitmapInfo)kCGImageAlphaNone);
    // Y-down so drawing uses the same orientation as the flipped view.
    CGContextTranslateCTM(g_atlas_ctx, 0, ATLAS_PX);
    CGContextScaleCTM(g_atlas_ctx, 1.0f, -1.0f);
    // Persistent live image over the same pixels: zero copies, ever.
    CGDataProviderRef prov = CGDataProviderCreateWithData(
        NULL, g_atlas_px, (size_t)ATLAS_PX * ATLAS_PX, NULL);
    if (prov) {
        g_atlas_img = CGImageCreate(ATLAS_PX, ATLAS_PX, 8, 8, ATLAS_PX, cs,
                                    (CGBitmapInfo)kCGImageAlphaNone, prov, NULL, false,
                                    kCGRenderingIntentDefault);
        CGDataProviderRelease(prov);
    }
    CGColorSpaceRelease(cs);
}

static void shape_rasterize_entry(ShapedEntry* e, NSFont* nsFont, NSString* str);

// One shared attributed-line constructor for the three CTLine creation sites
// (shape miss, atlas rasterize, legacy draw): a single noinline copy keeps
// __TEXT small, and every line shares identical attribute construction.
static __attribute__((noinline)) CTLineRef ctline_with_font(NSString* str, NSFont* nsFont, CGColorRef fg) {
    if (!str || !nsFont) return NULL;
    NSDictionary* attrs = fg ? @{
        (id)kCTFontAttributeName: nsFont,
        (id)kCTForegroundColorAttributeName: (__bridge id)fg,
    } : @{
        (id)kCTFontAttributeName: nsFont,
    };
    NSAttributedString* as = [[NSAttributedString alloc] initWithString:str attributes:attrs];
    if (!as) return NULL;
    return CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
}

// Shape (or hit) a run. On hit returns the entry with zero shaping work.
// On miss shapes exactly once, retains the CTLine, and rasterizes into the
// atlas when `rasterize` is set (measure-only callers pass 0 and the rect
// is produced lazily on first draw). NULL only when text is not cacheable.
static ShapedEntry* shape_run(const char* text, int len, float font_size,
                              int is_bold, int is_italic, int is_mono, int is_heading,
                              int rasterize) {
    if (!text || len <= 0 || len >= 511) return NULL;
    uint64_t key = shape_key(text, len, font_size, is_bold, is_italic, is_mono, is_heading);
    ShapedEntry* e = &g_shape_cache[key % SHAPE_CACHE_CAP];
    if (e->occupied && e->key == key && e->len == len &&
        memcmp(e->head, text, len < 8 ? len : 8) == 0) {
        g_shape_hits++;
        if (rasterize && e->aw == 0 && e->line) {
            // Shaped earlier by the measure path; rasterize lazily now.
            NSString* rstr = [[NSString alloc] initWithBytes:text length:len encoding:NSUTF8StringEncoding];
            if (rstr) {
                NSFont* rfont = get_font_for_style(font_size, is_bold, is_italic, is_mono, is_heading);
                shape_rasterize_entry(e, rfont, rstr);
            }
        }
        return e;
    }
    g_shape_misses++;

    NSString* str = [[NSString alloc] initWithBytes:text length:len encoding:NSUTF8StringEncoding];
    if (!str) return NULL;
    NSFont* nsFont = get_font_for_style(font_size, is_bold, is_italic, is_mono, is_heading);
    CTLineRef line = ctline_with_font(str, nsFont, NULL);
    if (!line) return NULL;

    CGFloat ascent, descent, leading;
    double mw = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    double trailing = CTLineGetTrailingWhitespaceWidth(line);

    if (e->occupied) {
        if (e->line) CFRelease(e->line);
        shape_drop_raster(e);
    }
    e->key = key;
    e->len = len;
    memcpy(e->head, text, len < 8 ? len : 8);
    e->line = line; // retained by Create; cache owns it now
    e->w = (float)(mw + trailing);
    e->h = (float)(ascent + descent);
    e->ascent = (float)ascent;
    e->descent = (float)descent;
    e->aw = 0;
    e->ah = 0;
    e->occupied = 1;

    if (rasterize) shape_rasterize_entry(e, nsFont, str);
    return e;
}

// Rasterize an already-shaped entry into the atlas (idempotent).
static void shape_rasterize_entry(ShapedEntry* e, NSFont* nsFont, NSString* str) {
    if (!e || !e->line || e->aw != 0) return;
    atlas_ensure();
    if (!g_atlas_ctx) return;

    int pw = (int)ceil(e->w * RASTER_SCALE);
    int ph = (int)ceil(e->h * RASTER_SCALE);
    if (pw <= 0 || ph <= 0) return;
    short ax = 0, ay = 0;
    if (!atlas_alloc(pw, ph, &ax, &ay)) {
        atlas_flush();
        if (!atlas_alloc(pw, ph, &ax, &ay)) return; // larger than atlas: caller draws direct
    }

    // White coverage mask, 2x supersampled for Retina-crisp blits.
    CTLineRef wline = ctline_with_font(str, nsFont, [NSColor whiteColor].CGColor);
    if (!wline) return;

    // NOTE: stored vertically mirrored: the per-frame ClipToMask blit in the
    // flipped view context maps image rows bottom-up, so a mirrored mask
    // blits upright (verified visually via /tmp/shape_probe renders).
    CGContextSaveGState(g_atlas_ctx);
    CGContextTranslateCTM(g_atlas_ctx, ax, ay + (float)ph - e->ascent * RASTER_SCALE);
    CGContextScaleCTM(g_atlas_ctx, (float)RASTER_SCALE, (float)RASTER_SCALE);
    CGContextSetTextPosition(g_atlas_ctx, 0, 0);
    CTLineDraw(wline, g_atlas_ctx);
    CGContextRestoreGState(g_atlas_ctx);
    CFRelease(wline);

    e->ax = ax;
    e->ay = ay;
    e->aw = (short)pw;
    e->ah = (short)ph;
    // Slice once: the atlas image is a live view, so it already sees the
    // pixels just drawn — no refresh, no copy, no per-frame allocation.
    if (g_atlas_img) {
        CGRect src = CGRectMake(ax, ay, pw, ph);
        e->slice = CGImageCreateWithImageInRect(g_atlas_img, src);
    }
}

// Read-only probe for selection/measure fast paths (no insert, no raster).
static CTLineRef shape_cached_line(const char* text, int len, float font_size,
                                   int is_bold, int is_italic, int is_mono, int is_heading) {
    if (!text || len <= 0 || len >= 511) return NULL;
    uint64_t key = shape_key(text, len, font_size, is_bold, is_italic, is_mono, is_heading);
    ShapedEntry* e = &g_shape_cache[key % SHAPE_CACHE_CAP];
    if (e->occupied && e->key == key && e->len == len &&
        memcmp(e->head, text, len < 8 ? len : 8) == 0 && e->line) {
        g_shape_hits++;
        return e->line;
    }
    return NULL;
}

void platform_glyph_cache_stats(uint64_t* hits, uint64_t* misses, uint64_t* flushes) {
    if (hits) *hits = g_shape_hits;
    if (misses) *misses = g_shape_misses;
    if (flushes) *flushes = g_atlas_flushes;
}

static int get_char_index_at_x(QuadTextRecord* rec, float x_offset) {
    if (x_offset <= 0) return 0;
    if (x_offset >= rec->w) return rec->len;

    // Shaping-economy fast path: hit-test on the cached run, no new CTLine.
    CTLineRef cached = shape_cached_line(rec->text, rec->len, rec->font_size,
                                         rec->is_bold, rec->is_italic, rec->is_mono, rec->is_heading);
    if (cached) {
        CFIndex idx = CTLineGetStringIndexForPosition(cached, CGPointMake(x_offset, 0));
        if (idx < 0) idx = 0;
        if (idx > rec->len) idx = rec->len;
        return (int)idx;
    }

    NSString* str = [[NSString alloc] initWithBytesNoCopy:(void*)rec->text length:rec->len encoding:NSUTF8StringEncoding freeWhenDone:NO];
    if (!str) return (int)roundf((x_offset / rec->w) * rec->len);

    NSFont* nsFont = get_font_for_style(rec->font_size, rec->is_bold, rec->is_italic, rec->is_mono, rec->is_heading);
    NSDictionary* attrs = @{(id)kCTFontAttributeName: nsFont};
    NSAttributedString* as = [[NSAttributedString alloc] initWithString:str attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
    if (!line) return (int)roundf((x_offset / rec->w) * rec->len);

    CFIndex idx = CTLineGetStringIndexForPosition(line, CGPointMake(x_offset, 0));
    CFRelease(line);
    if (idx < 0) idx = 0;
    if (idx > rec->len) idx = rec->len;
    return (int)idx;
}

static float get_x_for_char_index(QuadTextRecord* rec, int char_idx) {
    if (char_idx <= 0) return 0.0f;
    if (char_idx >= rec->len) return rec->w;

    // Shaping-economy fast path: measure the prefix on the cached run.
    CTLineRef cached = shape_cached_line(rec->text, rec->len, rec->font_size,
                                         rec->is_bold, rec->is_italic, rec->is_mono, rec->is_heading);
    if (cached) {
        CGFloat off = CTLineGetOffsetForStringIndex(cached, char_idx, NULL);
        return (float)off;
    }

    NSString* str = [[NSString alloc] initWithBytesNoCopy:(void*)rec->text length:char_idx encoding:NSUTF8StringEncoding freeWhenDone:NO];
    if (!str) return (float)char_idx / rec->len * rec->w;

    NSFont* nsFont = get_font_for_style(rec->font_size, rec->is_bold, rec->is_italic, rec->is_mono, rec->is_heading);
    NSDictionary* attrs = @{(id)kCTFontAttributeName: nsFont};
    NSAttributedString* as = [[NSAttributedString alloc] initWithString:str attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
    if (!line) return (float)char_idx / rec->len * rec->w;

    CGFloat a, d, l;
    double w = CTLineGetTypographicBounds(line, &a, &d, &l);
    double tr = CTLineGetTrailingWhitespaceWidth(line);
    CFRelease(line);
    return (float)(w + tr);
}

@interface ReadView : NSView
- (void)copySelectionToClipboard;
- (void)selectAllDocument;
- (void)openClickedLink:(id)sender;
- (void)copyClickedLink:(id)sender;
@end

@implementation ReadView

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    NSTrackingArea* area = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                       options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                                         owner:self
                                                      userInfo:nil];
    [self addTrackingArea:area];
}

// Flowing per-line selection highlight over the rebuilt text records.
// Shared by live drawRect and headless screenshots so --select captures
// exercise the real painter (regression: highlight used to render as a
// bare start-end rectangle when records went stale).
static __attribute__((noinline)) void paint_selection_highlight(CGContextRef ctx) {
// Draw flowing standard text selection highlight
if ((g_has_selection || g_select_all) && g_text_record_count > 0) {
    CGContextSetRGBFillColor(ctx, 0.22f, 0.58f, 0.98f, 0.32f);

    if (g_select_all) {
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            float view_y = rec->doc_y - g_scroll_y;
            CGContextFillRect(ctx, CGRectMake(rec->x, view_y, rec->w, rec->h));
        }
    } else {
        NSPoint pt1 = g_select_start;
        NSPoint pt2 = g_select_end;
        BOOL is_downward = (pt1.y < pt2.y || (pt1.y == pt2.y && pt1.x <= pt2.x));
        NSPoint top_pt = is_downward ? pt1 : pt2;
        NSPoint bot_pt = is_downward ? pt2 : pt1;

        float min_y = top_pt.y;
        float max_y = bot_pt.y;

        int last_selected_idx = -1;

        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            float r_top = rec->doc_y;
            float r_bot = rec->doc_y + rec->h;
            float view_y = rec->doc_y - g_scroll_y;

            if (r_bot < min_y - 4.0f || r_top > max_y + 4.0f) {
                continue;
            }

            int c_start = 0;
            int c_end = rec->len;

            BOOL is_first_line = (min_y >= r_top && min_y <= r_bot);
            BOOL is_last_line = (max_y >= r_top && max_y <= r_bot);

            if (is_first_line && is_last_line) {
                float left_x = fminf(top_pt.x, bot_pt.x);
                float right_x = fmaxf(top_pt.x, bot_pt.x);
                if (rec->x + rec->w < left_x || rec->x > right_x) continue;
                c_start = get_char_index_at_x(rec, left_x - rec->x);
                c_end = get_char_index_at_x(rec, right_x - rec->x);
            } else if (is_first_line) {
                float start_x = top_pt.x;
                if (rec->x + rec->w < start_x) continue;
                c_start = get_char_index_at_x(rec, start_x - rec->x);
                c_end = rec->len;
            } else if (is_last_line) {
                float end_x = bot_pt.x;
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
                CGContextFillRect(ctx, CGRectMake(x1, view_y, x2 - x1, rec->h));

                // Highlight space between adjacent selected words on the same line
                if (last_selected_idx >= 0 && last_selected_idx == q - 1) {
                    QuadTextRecord* prev = &g_text_records[last_selected_idx];
                    if (fabs(prev->doc_y - rec->doc_y) < 6.0f) {
                        float gap_x = prev->x + prev->w;
                        float gap_w = rec->x - gap_x;
                        if (gap_w > 0) {
                            CGContextFillRect(ctx, CGRectMake(gap_x, view_y, gap_w, rec->h));
                        }
                    }
                }
                last_selected_idx = q;
            }
        }
    }
}
}

- (void)drawRect:(NSRect)dirtyRect {
    // Record the compositor's dirty rect so the Zig draw callback can cull
    // off-region commands. Never ignored: partial damage skips pixels.
    g_pending_dirty = dirtyRect;
    g_pending_dirty_valid = YES;
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!ctx) return;
    g_draw_seq++;

    g_text_record_count = 0;
    g_code_block_count = 0;
    g_scrollable_block_count = 0;
    g_current_cg_context = ctx;
    NSScreen* draw_screen = [self.window screen];
    g_output_scale = draw_screen ? (float)[draw_screen backingScaleFactor] : 1.0f;
    if (g_output_scale < 1.0f) g_output_scale = 1.0f;

    if (g_callbacks.on_draw) {
        g_callbacks.on_draw((int)self.bounds.size.width, (int)self.bounds.size.height);
    }

    paint_selection_highlight(ctx);

    // Draw visible-on-hover Copy Button for Code Blocks
    double now = [NSDate timeIntervalSinceReferenceDate];
    for (int b_idx = 0; b_idx < g_code_block_count; b_idx++) {
        CodeBlockRecord* b = &g_code_blocks[b_idx];
        BOOL is_hovered = (g_mouse_pos.x >= b->x && g_mouse_pos.x <= b->x + b->w &&
                           g_mouse_pos.y >= b->y && g_mouse_pos.y <= b->y + b->h);

        BOOL is_copied = (g_copied_block_idx == b_idx && (now - g_copied_timestamp < 1.5));

        if (is_hovered || is_copied) {
            float btn_w = 64.0f;
            float btn_h = 24.0f;
            float btn_x = b->x + b->w - btn_w - 8.0f;
            float btn_y = b->y + 8.0f;

            // Background pill
            NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(btn_x, btn_y, btn_w, btn_h) xRadius:5.0 yRadius:5.0];
            [[NSColor colorWithCalibratedRed:0.20 green:0.22 blue:0.26 alpha:0.95] setFill];
            [path fill];
            [[NSColor colorWithCalibratedRed:0.35 green:0.38 blue:0.45 alpha:0.8] setStroke];
            [path setLineWidth:1.0];
            [path stroke];

            // Text
            NSString* label = is_copied ? @"Copied!" : @"Copy";
            NSColor* textColor = is_copied ? [NSColor colorWithCalibratedRed:0.3 green:0.85 blue:0.4 alpha:1.0] :
                                             [NSColor colorWithCalibratedRed:0.85 green:0.88 blue:0.92 alpha:1.0];
            NSDictionary* attrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium],
                NSForegroundColorAttributeName: textColor,
            };
            NSSize textSize = [label sizeWithAttributes:attrs];
            float text_x = btn_x + (btn_w - textSize.width) * 0.5f;
            float text_y = btn_y + (btn_h - textSize.height) * 0.5f;
            [label drawAtPoint:NSMakePoint(text_x, text_y) withAttributes:attrs];
        }
    }

    g_current_cg_context = NULL;
    g_pending_dirty_valid = NO;
}

- (void)mouseMoved:(NSEvent *)event {
    g_mouse_pos = [self convertPoint:[event locationInWindow] fromView:nil];

    BOOL over_link = NO;
    for (int i = 0; i < g_text_record_count; i++) {
        QuadTextRecord* rec = &g_text_records[i];
        float view_y = rec->doc_y - g_scroll_y;
        if (rec->link_url[0] != '\0' &&
            g_mouse_pos.x >= rec->x && g_mouse_pos.x <= rec->x + rec->w &&
            g_mouse_pos.y >= view_y && g_mouse_pos.y <= view_y + rec->h) {
            over_link = YES;
            break;
        }
    }

    BOOL over_code_btn = NO;
    for (int b_idx = 0; b_idx < g_code_block_count; b_idx++) {
        CodeBlockRecord* b = &g_code_blocks[b_idx];
        float btn_w = 64.0f;
        float btn_h = 24.0f;
        float btn_x = b->x + b->w - btn_w - 8.0f;
        float btn_y = b->y + 8.0f;
        if (g_mouse_pos.x >= btn_x && g_mouse_pos.x <= btn_x + btn_w &&
            g_mouse_pos.y >= btn_y && g_mouse_pos.y <= btn_y + btn_h) {
            over_code_btn = YES;
            break;
        }
    }

    if (over_link || over_code_btn) {
        [[NSCursor pointingHandCursor] set];
    } else {
        [[NSCursor IBeamCursor] set];
    }

    // Damage: cursor changes need no repaint. Only the hover Copy button
    // changing visibility dirties pixels: invalidate old + new button rects.
    int new_hover_btn = -1;
    NSRect new_btn_rect = NSZeroRect;
    for (int b_idx = 0; b_idx < g_code_block_count; b_idx++) {
        CodeBlockRecord* b = &g_code_blocks[b_idx];
        if (g_mouse_pos.x >= b->x && g_mouse_pos.x <= b->x + b->w &&
            g_mouse_pos.y >= b->y && g_mouse_pos.y <= b->y + b->h) {
            new_hover_btn = b_idx;
            new_btn_rect = copy_button_rect_for_block(b);
            break;
        }
    }
    // Idle-gated link highlight (mirrors idle.zig shouldRedrawOnHover): pure
    // mouse motion never redraws. A link-highlight flip re-arms one gated
    // full redraw (no exact record handy); copy-button-only flips stay
    // rect-precise below.
    if (g_text_record_count > 0 && over_link != g_last_link_hover) {
        g_last_link_hover = over_link;
        [self setNeedsDisplay:YES];
    }
    g_last_code_btn_hover = over_code_btn;
    if (new_hover_btn != g_hovered_code_btn) {
        if (g_hovered_code_btn >= 0 && g_hovered_code_btn < g_code_block_count) {
            invalidate_rect(copy_button_rect_for_block(&g_code_blocks[g_hovered_code_btn]));
        }
        if (new_hover_btn >= 0) {
            invalidate_rect(new_btn_rect);
        }
        g_hovered_code_btn = new_hover_btn;
    }
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    g_mouse_pos = NSMakePoint(-9999.0f, -9999.0f);
    // Clear button hover with its exact rect; link hover via one gated redraw.
    if (g_hovered_code_btn >= 0 && g_hovered_code_btn < g_code_block_count) {
        invalidate_rect(copy_button_rect_for_block(&g_code_blocks[g_hovered_code_btn]));
        g_hovered_code_btn = -1;
    }
    if (g_last_link_hover || g_last_code_btn_hover) {
        g_last_link_hover = NO;
        g_last_code_btn_hover = NO;
        [[NSCursor IBeamCursor] set];
        [self setNeedsDisplay:YES];
    }
}
- (void)mouseDown:(NSEvent *)event {
    NSPoint view_pt = [self convertPoint:[event locationInWindow] fromView:nil];

    // Check if clicked Copy button on a code block
    for (int b_idx = 0; b_idx < g_code_block_count; b_idx++) {
        CodeBlockRecord* b = &g_code_blocks[b_idx];
        NSRect btn = copy_button_rect_for_block(b);
        if (view_pt.x >= btn.origin.x && view_pt.x <= btn.origin.x + btn.size.width &&
            view_pt.y >= btn.origin.y && view_pt.y <= btn.origin.y + btn.size.height) {
            NSPasteboard* pb = [NSPasteboard generalPasteboard];
            [pb clearContents];
            NSString* s = [[NSString alloc] initWithBytes:b->text length:b->len encoding:NSUTF8StringEncoding];
            if (s) [pb setString:s forType:NSPasteboardTypeString];
            g_copied_block_idx = b_idx;
            g_copied_timestamp = [NSDate timeIntervalSinceReferenceDate];
            // Damage: only the button label flips to "Copied!".
            invalidate_rect(btn);
            return;
        }
    }

    // Damage: capture pre-click selection bounds; the redraw covers
    // old bounds + new caret/word/line box only.
    NSRect old_sel = selection_bounds_expanded(24.0f);

    g_select_all = NO;
    g_has_selection = YES;
    g_select_start = NSMakePoint(view_pt.x, view_pt.y + g_scroll_y);
    g_select_end = g_select_start;

    // Double click: word selection
    if ([event clickCount] == 2) {
        g_selection_mode = 2;
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            if (g_select_start.x >= rec->x && g_select_start.x <= rec->x + rec->w &&
                g_select_start.y >= rec->doc_y && g_select_start.y <= rec->doc_y + rec->h)
            {
                g_select_start = NSMakePoint(rec->x, rec->doc_y + rec->h * 0.5f);
                g_select_end = NSMakePoint(rec->x + rec->w, rec->doc_y + rec->h * 0.5f);
                break;
            }
        }
    }
    // Triple click: line selection
    else if ([event clickCount] >= 3) {
        g_selection_mode = 3;
        float click_doc_y = g_select_start.y;
        float line_min_x = 9999.0f;
        float line_max_x = -9999.0f;
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            if (fabs(rec->doc_y + rec->h * 0.5f - click_doc_y) < 16.0f) {
                line_min_x = fminf(line_min_x, rec->x);
                line_max_x = fmaxf(line_max_x, rec->x + rec->w);
            }
        }
        if (line_max_x > line_min_x) {
            g_select_start = NSMakePoint(line_min_x, click_doc_y);
            g_select_end = NSMakePoint(line_max_x, click_doc_y);
        }
    } else {
        g_selection_mode = 1;
    }

    // Damage: old selection bounds + new caret/word/line box only.
    invalidate_rect(union_rect(old_sel, selection_bounds_expanded(24.0f)));
}

- (void)mouseDragged:(NSEvent *)event {
    if (g_selection_mode <= 1) {
        // Damage: the selection spans start->end across full line widths, not
        // just the cursor path, so invalidate old + new full bounds.
        // Regression: a cursor strip left newly selected lines stale.
        // Contract pinned by dragSelectionDamage tests in damage.zig.
        NSRect old_sel = selection_bounds_expanded(24.0f);
        NSPoint view_pt = [self convertPoint:[event locationInWindow] fromView:nil];
        g_select_end = NSMakePoint(view_pt.x, view_pt.y + g_scroll_y);
        invalidate_rect(union_rect(old_sel, selection_bounds_expanded(24.0f)));
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (g_selection_mode >= 2) {
        // Prohibit mouseUp from moving g_select_end on double or triple click.
        // Damage: selection did not change, so no repaint is needed.
        return;
    }

    // Damage: capture pre-release bounds; invalidate old + final only.
    NSRect old_sel = selection_bounds_expanded(24.0f);

    NSPoint view_pt = [self convertPoint:[event locationInWindow] fromView:nil];
    NSPoint end_doc = NSMakePoint(view_pt.x, view_pt.y + g_scroll_y);

    // If simple click without drag:
    if (fabs(end_doc.y - g_select_start.y) < 4.0f && fabs(end_doc.x - g_select_start.x) < 4.0f) {
        if ([event clickCount] < 2) {
            g_has_selection = NO;
            g_selection_mode = 0;

            // Check if link was clicked
            for (int i = 0; i < g_text_record_count; i++) {
                QuadTextRecord* rec = &g_text_records[i];
                if (rec->link_url[0] != '\0' &&
                    end_doc.x >= rec->x && end_doc.x <= rec->x + rec->w &&
                    end_doc.y >= rec->doc_y && end_doc.y <= rec->doc_y + rec->h) {
                    NSString* urlStr = [NSString stringWithUTF8String:rec->link_url];
                    NSURL* url = [NSURL URLWithString:urlStr];
                    if (url) {
                        [[NSWorkspace sharedWorkspace] openURL:url];
                    }
                    break;
                }
            }
            // Damage: cleared selection repaints its old bounds only.
            invalidate_rect(old_sel);
            return;
        }
    } else {
        g_select_end = end_doc;
    }

    invalidate_rect(union_rect(old_sel, selection_bounds_expanded(24.0f)));
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Context Menu"];
    NSPoint view_pt = [self convertPoint:[event locationInWindow] fromView:nil];
    NSPoint doc_pt = NSMakePoint(view_pt.x, view_pt.y + g_scroll_y);

    char link_url[256] = {0};
    for (int i = 0; i < g_text_record_count; i++) {
        QuadTextRecord* rec = &g_text_records[i];
        if (rec->link_url[0] != '\0' &&
            doc_pt.x >= rec->x && doc_pt.x <= rec->x + rec->w &&
            doc_pt.y >= rec->doc_y && doc_pt.y <= rec->doc_y + rec->h) {
            strncpy(link_url, rec->link_url, 255);
            break;
        }
    }

    if (link_url[0] != '\0') {
        NSMenuItem *openLink = [[NSMenuItem alloc] initWithTitle:@"Open Link in Browser" action:@selector(openClickedLink:) keyEquivalent:@""];
        openLink.representedObject = [NSString stringWithUTF8String:link_url];
        [menu addItem:openLink];

        NSMenuItem *copyLink = [[NSMenuItem alloc] initWithTitle:@"Copy Link Address" action:@selector(copyClickedLink:) keyEquivalent:@""];
        copyLink.representedObject = [NSString stringWithUTF8String:link_url];
        [menu addItem:copyLink];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    NSMenuItem *copyItem = [[NSMenuItem alloc] initWithTitle:@"Copy" action:@selector(copySelectionToClipboard) keyEquivalent:@"c"];
    if (!g_has_selection && !g_select_all) {
        [copyItem setEnabled:NO];
    }
    [menu addItem:copyItem];

    NSMenuItem *selectAllItem = [[NSMenuItem alloc] initWithTitle:@"Select All" action:@selector(selectAllDocument) keyEquivalent:@"a"];
    [menu addItem:selectAllItem];

    return menu;
}

- (void)openClickedLink:(NSMenuItem *)sender {
    NSString* urlStr = sender.representedObject;
    if (urlStr) {
        NSURL* url = [NSURL URLWithString:urlStr];
        if (url) [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

- (void)copyClickedLink:(NSMenuItem *)sender {
    NSString* urlStr = sender.representedObject;
    if (urlStr) {
        NSPasteboard* pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:urlStr forType:NSPasteboardTypeString];
    }
}

- (void)copy:(id)sender {
    (void)sender;
    [self copySelectionToClipboard];
}

- (void)selectAllDocument {
    g_select_all = YES;
    g_has_selection = YES;
    g_selection_mode = 4;
    [self setNeedsDisplay:YES];
}

- (void)copySelectionToClipboard {
    NSMutableString* result = [NSMutableString string];

    if (g_select_all) {
        float last_doc_y = -9999.0f;
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            NSString* s = [[NSString alloc] initWithBytes:rec->text length:rec->len encoding:NSUTF8StringEncoding];
            if (s) {
                if (last_doc_y > -9000.0f && fabs(rec->doc_y - last_doc_y) > 10.0f) {
                    if (fabs(rec->doc_y - last_doc_y) > 35.0f) {
                        [result appendString:@"\n\n"];
                    } else {
                        [result appendString:@"\n"];
                    }
                } else if (last_doc_y > -9000.0f) {
                    [result appendString:@" "];
                }
                [result appendString:s];
                last_doc_y = rec->doc_y;
            }
        }
    } else if (g_has_selection) {
        NSPoint pt1 = g_select_start;
        NSPoint pt2 = g_select_end;
        BOOL is_downward = (pt1.y < pt2.y || (pt1.y == pt2.y && pt1.x <= pt2.x));
        NSPoint top_pt = is_downward ? pt1 : pt2;
        NSPoint bot_pt = is_downward ? pt2 : pt1;

        float min_y = top_pt.y;
        float max_y = bot_pt.y;

        float last_doc_y = -9999.0f;

        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            float r_top = rec->doc_y;
            float r_bot = rec->doc_y + rec->h;

            if (r_bot < min_y - 4.0f || r_top > max_y + 4.0f) continue;

            int c_start = 0;
            int c_end = rec->len;

            BOOL is_first_line = (min_y >= r_top && min_y <= r_bot);
            BOOL is_last_line = (max_y >= r_top && max_y <= r_bot);

            if (is_first_line && is_last_line) {
                float left_x = fminf(top_pt.x, bot_pt.x);
                float right_x = fmaxf(top_pt.x, bot_pt.x);
                if (rec->x + rec->w < left_x || rec->x > right_x) continue;
                c_start = get_char_index_at_x(rec, left_x - rec->x);
                c_end = get_char_index_at_x(rec, right_x - rec->x);
            } else if (is_first_line) {
                float start_x = top_pt.x;
                if (rec->x + rec->w < start_x) continue;
                c_start = get_char_index_at_x(rec, start_x - rec->x);
                c_end = rec->len;
            } else if (is_last_line) {
                float end_x = bot_pt.x;
                if (rec->x > end_x) continue;
                c_start = 0;
                c_end = get_char_index_at_x(rec, end_x - rec->x);
            } else {
                c_start = 0;
                c_end = rec->len;
            }

            if (c_end > c_start && c_start >= 0 && c_end <= rec->len) {
                NSString* s = [[NSString alloc] initWithBytes:&rec->text[c_start] length:(c_end - c_start) encoding:NSUTF8StringEncoding];
                if (s) {
                    if (last_doc_y > -9000.0f && fabs(rec->doc_y - last_doc_y) > 10.0f) {
                        if (fabs(rec->doc_y - last_doc_y) > 35.0f) {
                            [result appendString:@"\n\n"];
                        } else {
                            [result appendString:@"\n"];
                        }
                    } else if (last_doc_y > -9000.0f) {
                        [result appendString:@" "];
                    }
                    [result appendString:s];
                    last_doc_y = rec->doc_y;
                }
            }
        }
    }

    if ([result length] > 0) {
        NSPasteboard* pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:result forType:NSPasteboardTypeString];
    }
}

- (void)scrollWheel:(NSEvent *)event {
    if (g_callbacks.on_scroll) {
        // Both the finger phase and the kinetic momentum phase are honored
        // (mirrors idle.zig isGestureEnd). Momentum delivers its own event
        // stream, so redraws stay armed exactly while it is live and the
        // loop returns to idle the instant either phase ends.
        NSEventPhase phase = [event phase];
        NSEventPhase momentum = [event momentumPhase];
        if (phase == NSEventPhaseEnded || phase == NSEventPhaseCancelled ||
            momentum == NSEventPhaseEnded || momentum == NSEventPhaseCancelled) {
            g_callbacks.on_scroll(0.0f, 0.0f, -1);
            // Damage: scroll-lock reset changes no pixels, so no repaint.
            return;
        }

        CGFloat dx = [event scrollingDeltaX];
        CGFloat dy = [event scrollingDeltaY];
        if (![event hasPreciseScrollingDeltas]) {
            dx *= 20.0;
            dy *= 20.0;
        }
        NSPoint win_pt = [event locationInWindow];
        NSPoint view_pt = [self convertPoint:win_pt fromView:nil];
        int hovered_block_id = -1;
        for (int i = 0; i < g_scrollable_block_count; i++) {
            ScrollableBlockRecord* b = &g_scrollable_blocks[i];
            if (view_pt.x >= b->x && view_pt.x <= b->x + b->w &&
                view_pt.y >= b->y && view_pt.y <= b->y + b->h) {
                hovered_block_id = b->id;
                break;
            }
        }
        g_callbacks.on_scroll((float)dx, (float)dy, hovered_block_id);
    }
    [self setNeedsDisplay:YES];
}

- (void)keyDown:(NSEvent *)event {
    NSUInteger flags = [event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask;
    NSString* chars = [event charactersIgnoringModifiers];

    if (flags == NSEventModifierFlagCommand) {
        if ([chars isEqualToString:@"c"]) {
            [self copySelectionToClipboard];
            return;
        }
        if ([chars isEqualToString:@"a"]) {
            [self selectAllDocument];
            return;
        }
    }

    if ([chars length] > 0) {
        unichar c = [chars characterAtIndex:0];
        int hovered_block_id = -1;
        for (int i = 0; i < g_scrollable_block_count; i++) {
            ScrollableBlockRecord* b = &g_scrollable_blocks[i];
            if (g_mouse_pos.x >= b->x && g_mouse_pos.x <= b->x + b->w &&
                g_mouse_pos.y >= b->y && g_mouse_pos.y <= b->y + b->h) {
                hovered_block_id = b->id;
                break;
            }
        }
        if (g_callbacks.on_key) {
            g_callbacks.on_key((int)c, hovered_block_id);
        }
        // Damage: h/l nudge one hovered block -> its exact box only.
        // j/k/Space scroll and t theme-toggle repaint every pixel -> full.
        if ((c == 'h' || c == 'l') && hovered_block_id >= 0) {
            for (int i = 0; i < g_scrollable_block_count; i++) {
                ScrollableBlockRecord* b = &g_scrollable_blocks[i];
                if (b->id == hovered_block_id) {
                    invalidate_rect(NSInsetRect(NSMakeRect(b->x, b->y, b->w, b->h), -2.0f, -2.0f));
                    break;
                }
            }
        } else if (c == 'h' || c == 'l') {
            // No hovered block: scroll offsets unchanged, no repaint.
        } else {
            [self setNeedsDisplay:YES];
        }
    }
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    if (g_callbacks.on_resize) {
        g_callbacks.on_resize((int)newSize.width, (int)newSize.height);
    }
    [self setNeedsDisplay:YES];
}

@end

@interface ReadAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

@implementation ReadAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

// Visibility changes are OS events, not wakeups: a single redraw on restore
// lets platform_draw_image re-arm any parked animation chain. While hidden,
// parked chains schedule nothing, so idle stays at zero wakeups.
- (void)windowDidDeminiaturize:(NSNotification *)notification {
    (void)notification;
    [g_main_view setNeedsDisplay:YES];
}

- (void)windowDidChangeOcclusionState:(NSNotification *)notification {
    (void)notification;
    if (gif_window_visible()) [g_main_view setNeedsDisplay:YES];
}

@end

int platform_init(const char* title, int width, int height, PlatformCallbacks callbacks) {
    g_callbacks = callbacks;

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    static ReadAppDelegate* delegate = nil;
    delegate = [[ReadAppDelegate alloc] init];
    [NSApp setDelegate:delegate];

    NSRect frame = NSMakeRect(0, 0, width, height);
    NSUInteger styleMask = NSWindowStyleMaskTitled |
                           NSWindowStyleMaskClosable |
                           NSWindowStyleMaskMiniaturizable |
                           NSWindowStyleMaskResizable |
                           NSWindowStyleMaskFullSizeContentView;

    g_window = [[NSWindow alloc] initWithContentRect:frame
                                           styleMask:styleMask
                                             backing:NSBackingStoreBuffered
                                               defer:NO];

    [g_window setTitle:[NSString stringWithUTF8String:title]];
    [g_window setTitlebarAppearsTransparent:YES];
    [g_window setTitleVisibility:NSWindowTitleHidden];
    [g_window setBackgroundColor:[NSColor colorWithCalibratedRed:18.0f/255.0f green:18.0f/255.0f blue:18.0f/255.0f alpha:1.0]];
    [g_window center];

    ReadView* view = [[ReadView alloc] initWithFrame:frame];
    g_main_view = view;  // for async image load → setNeedsDisplay callbacks
    [g_window setContentView:view];
    [g_window setDelegate:delegate];
    [g_window makeKeyAndOrderFront:nil];
    [g_window makeFirstResponder:view];

    return 0;
}

void platform_run_loop(void) {
    // Strictly OS blocking events: [NSApp run] parks the thread in the
    // kernel event wait until input, window, or scheduled-callback events
    // arrive. No spin, no polling loop, and no persistent frame clock exists
    // in this codebase, so a static screen costs zero wakeups (0% CPU).
    [NSApp run];
}

void platform_request_redraw(void) {
    if (g_window && [g_window contentView]) {
        [[g_window contentView] setNeedsDisplay:YES];
    }
}

// Damage tracking: submit an exact bounding box to the OS compositor
// instead of a full-screen redraw (cursor blink, keystroke line, GIF tick).
void platform_request_redraw_rect(float x, float y, float w, float h) {
    invalidate_rect(NSMakeRect(x, y, w, h));
}

#ifdef TEST_HOOKS
// Headless test hooks (damage/selection parity tests): inject a synthetic
// pending-damage rect and read back the rebuilt text-record count.
static BOOL g_test_damage_valid = NO;
static NSRect g_test_damage; // zero-initialized == NSZeroRect
void platform_set_test_damage(float x, float y, float w, float h, int valid) {
    g_test_damage = NSMakeRect(x, y, w, h);
    g_test_damage_valid = valid ? YES : NO;
}
int platform_text_record_count(void) { return g_text_record_count; }
void platform_set_test_selection(float x1, float y1, float x2, float y2, int enable) {
    g_select_start = NSMakePoint(x1, y1);
    g_select_end = NSMakePoint(x2, y2);
    g_has_selection = enable ? YES : NO;
    g_selection_mode = enable ? 1 : 0;
    g_select_all = NO;
}
#endif

// Returns the dirty rect AppKit reported for the in-progress draw, for
// compositor culling in the Zig draw callback. 0 = no pending damage.
int platform_get_pending_damage(float* x, float* y, float* w, float* h) {
#ifdef TEST_HOOKS
    if (g_test_damage_valid) {
        if (x) *x = g_test_damage.origin.x;
        if (y) *y = g_test_damage.origin.y;
        if (w) *w = g_test_damage.size.width;
        if (h) *h = g_test_damage.size.height;
        return 1;
    }
#endif
    if (!g_pending_dirty_valid) return 0;
    if (x) *x = g_pending_dirty.origin.x;
    if (y) *y = g_pending_dirty.origin.y;
    if (w) *w = g_pending_dirty.size.width;
    if (h) *h = g_pending_dirty.size.height;
    return 1;
}

void platform_sync_scroll(float scroll_y) {
    g_scroll_y = scroll_y;
}

void platform_draw_rect(float x, float y, float w, float h, unsigned char r, unsigned char g, unsigned char b, unsigned char a) {
    if (!g_current_cg_context) return;
    CGContextRef ctx = g_current_cg_context;

    CGContextSetRGBFillColor(ctx, r / 255.0f, g / 255.0f, b / 255.0f, a / 255.0f);
    CGContextFillRect(ctx, CGRectMake(x, y, w, h));
}

void platform_register_code_block(float x, float y, float w, float h, const char* code_text, int code_len) {
    if (g_code_block_count >= MAX_CODE_BLOCKS) return;
    CodeBlockRecord* b = &g_code_blocks[g_code_block_count++];
    b->x = x;
    b->y = y;
    b->w = w;
    b->h = h;
    int copy_len = (code_text && code_len > 0) ? (code_len < 8191 ? code_len : 8191) : 0;
    if (copy_len > 0) {
        memcpy(b->text, code_text, copy_len);
        b->text[copy_len] = '\0';
        b->len = copy_len;
    } else {
        b->text[0] = '\0';
        b->len = 0;
    }
}

void platform_register_scrollable_block(int block_id, float x, float y, float w, float h, float max_scroll_x) {
    if (g_scrollable_block_count >= MAX_SCROLLABLE_BLOCKS) return;
    g_scrollable_blocks[g_scrollable_block_count++] = (ScrollableBlockRecord){
        .id = block_id,
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .max_scroll_x = max_scroll_x,
    };
}

void platform_begin_clip(float x, float y, float w, float h) {
    if (!g_current_cg_context) return;
    CGContextSaveGState(g_current_cg_context);
    CGContextClipToRect(g_current_cg_context, CGRectMake(x, y, w, h));
}

void platform_end_clip(void) {
    if (!g_current_cg_context) return;
    CGContextRestoreGState(g_current_cg_context);
}

// Record quad for mouse text selection & copying (anchored to document Y).
// noinline: called from 4 sites (register/draw/legacy); one shared copy keeps
// __TEXT off the next page boundary (binary budget < 500 KiB).
static __attribute__((noinline)) void record_text_quad(const char* text, int len, float x, float y, float w, float h,
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
    memcpy(rec->text, text, copy_len);
    rec->text[copy_len] = '\0';
    rec->len = copy_len;

    int copy_url = (link_url && link_url_len > 0) ? (link_url_len < 255 ? link_url_len : 255) : 0;
    if (copy_url > 0) {
        memcpy(rec->link_url, link_url, copy_url);
        rec->link_url[copy_url] = '\0';
    } else {
        rec->link_url[0] = '\0';
    }
}

// Record-only registration for culled text runs: the selection/hover/link
// model (g_text_records) must be rebuilt on EVERY draw, including partial
// damage draws that skip pixels. Uses the same shaping cache as the draw
// path (measure-only, no rasterize) so records match drawn runs exactly.
// Regression guard: src/layout/damage.zig documents the invariant.
void platform_register_text_run(const char* text, int len, float x, float y, float w, float h, float font_size, int is_bold, int is_italic, int is_mono, int is_heading, const char* link_url, int link_url_len) {
    if (!text || len <= 0) return;
    // Measure-only: a miss shapes exactly once (cached thereafter), so the
    // recorded width matches the draw path's shaped width in all cases.
    ShapedEntry* e = shape_run(text, len, font_size, is_bold, is_italic, is_mono, is_heading, 0);
    if (e && e->line) {
        record_text_quad(text, len, x, y, e->w, e->h, font_size,
                         is_bold, is_italic, is_mono, is_heading, link_url, link_url_len);
    } else {
        record_text_quad(text, len, x, y, w, h, font_size,
                         is_bold, is_italic, is_mono, is_heading, link_url, link_url_len);
    }
}

// Legacy direct text draw with a fresh explicit-color line (pixel-identical
// to the pre-atlas renderer). Records the run only when do_record is set, so
// callers that already recorded with shaped dims never double-record.
static __attribute__((noinline)) void draw_text_legacy(CGContextRef ctx, const char* text, int len, float x, float y, float font_size, int is_bold, int is_italic, int is_mono, int is_heading, unsigned char r, unsigned char g, unsigned char b, unsigned char a, int do_record, const char* link_url, int link_url_len) {
    NSString* str = [[NSString alloc] initWithBytes:text length:len encoding:NSUTF8StringEncoding];
    if (!str) return;
    NSFont* nsFont = get_font_for_style(font_size, is_bold, is_italic, is_mono, is_heading);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGFloat components[4] = { r / 255.0f, g / 255.0f, b / 255.0f, a / 255.0f };
    CGColorRef fontColor = CGColorCreate(colorSpace, components);
    CTLineRef ctLine = ctline_with_font(str, nsFont, fontColor);
    if (ctLine && do_record) {
        // Uncacheable run: measure for the record. The shaped call site
        // already recorded exact dims, so it passes do_record=0 and skips
        // these two CoreText queries on every 1x frame.
        CGFloat ascent, descent, leading;
        double measuredWidth = CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading);
        double trailing = CTLineGetTrailingWhitespaceWidth(ctLine);
        record_text_quad(text, len, x, y, (float)(measuredWidth + trailing), (float)(ascent + descent),
                         font_size, is_bold, is_italic, is_mono, is_heading, link_url, link_url_len);
    }
    if (ctLine) {
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, x, y + font_size * 0.85f);
        CGContextScaleCTM(ctx, 1.0f, -1.0f);
        CGContextSetTextPosition(ctx, 0, 0);
        CTLineDraw(ctLine, ctx);
        CGContextRestoreGState(ctx);
        CFRelease(ctLine);
    }
    CGColorRelease(fontColor);
    CGColorSpaceRelease(colorSpace);
}

void platform_draw_text(const char* text, int len, float x, float y, float font_size, int is_bold, int is_italic, int is_mono, int is_heading, unsigned char r, unsigned char g, unsigned char b, unsigned char a, const char* link_url, int link_url_len) {
    if (!g_current_cg_context || len <= 0 || !text) return;
    CGContextRef ctx = g_current_cg_context;

    // Shaping economy: shape once per unique run (cached thereafter). Only
    // rasterize when this destination will actually blit (2x); on 1x the
    // legacy path draws directly, so rasterizing would just churn the atlas
    // toward a pointless flush every frame (observed live: ~96% of draws).
    ShapedEntry* e = shape_run(text, len, font_size, is_bold, is_italic, is_mono, is_heading,
                               (g_output_scale > 1.5f) ? 1 : 0);
    if (e && e->line) {
        // Record EXACTLY ONCE per call with shaped dims; every branch below
        // is pixels-only (regression: an earlier fall-through recorded twice).
        record_text_quad(text, len, x, y, e->w, e->h, font_size,
                         is_bold, is_italic, is_mono, is_heading, link_url, link_url_len);
        // Per-frame render is ONE retained slice blit: no shaping, no copy,
        // no allocation, no CPU compositing. Only when the destination scale
        // matches the 2x raster, otherwise the downsample softens edges.
        if (e->aw != 0 && e->slice && g_output_scale > 1.5f) {
            // Destination: same geometry as the old CTLineDraw baseline
            // (y + size*0.85, ascent above) so layout is pixel-identical.
            float dest_y = y + font_size * 0.85f - e->ascent;
            CGRect dest = CGRectMake(x, dest_y, e->w, e->h);
            CGContextSaveGState(ctx);
            CGContextClipToMask(ctx, dest, e->slice);
            CGContextSetRGBFillColor(ctx, r / 255.0f, g / 255.0f, b / 255.0f, a / 255.0f);
            CGContextFillRect(ctx, dest);
            CGContextRestoreGState(ctx);
            return; // textured quad done: no shaping, no CPU compositing
        }
        // 1x destination (or missing slice): legacy pixels, no re-record.
        // NOTE: drawing the cached font-only line via the context fill color
        // was measured rendering every glyph dim (0 bright pixels over a full
        // document vs ~27k on the explicit-color path), so that shortcut
        // stays removed until the cause is understood. The shaping cache
        // still serves measure/hit-test paths with zero re-shape cost.
        draw_text_legacy(ctx, text, len, x, y, font_size, is_bold, is_italic, is_mono, is_heading,
                         r, g, b, a, 0, link_url, link_url_len);
        return;
    }

    // Uncacheable run (>510 bytes): legacy pixels + record.
    draw_text_legacy(ctx, text, len, x, y, font_size, is_bold, is_italic, is_mono, is_heading,
                     r, g, b, a, 1, link_url, link_url_len);
}

// ---------------------------------------------------------------------------
// Image Cache: async load + animated GIF frame cycling
// ---------------------------------------------------------------------------

typedef struct {
    char     url[512];
    // Decoded frames (NULL = not yet loaded, count 0 = failed)
    CGImageRef* frames;         // malloc'd array of CGImageRef
    double*     frame_delays;   // malloc'd array of per-frame delay in seconds
    int         frame_count;
    int         cur_frame;      // current display frame index
    float       natural_w;      // logical pixel size at 72 dpi
    float       natural_h;
    BOOL        loading;        // async load in flight
    BOOL        failed;
    BOOL        parked;         // animation chain parked: no timer scheduled
    unsigned long last_draw_seq; // g_draw_seq of the pass that last painted this image
    // Last drawn rect in DOCUMENT coordinates for exact GIF-tick damage.
    float       last_doc_x;
    float       last_doc_y;
    float       last_w;
    float       last_h;
    BOOL        has_rect;
} CachedImageRecord;

#define MAX_IMAGE_CACHE 64
static CachedImageRecord g_image_cache[MAX_IMAGE_CACHE];
static int  g_image_cache_count = 0;

// Forward declarations
static void gif_schedule_next_frame(CachedImageRecord* rec);
static BOOL gif_window_visible(void);

// The window is a valid animation sink only while it is actually on screen.
// Hidden, miniaturized, or fully occluded windows never advance or schedule:
// the chain parks and consumes zero wakeups until the next genuine draw.
static BOOL gif_window_visible(void) {
    if (!g_window) return NO;
    if ([g_window isMiniaturized]) return NO;
    if (![g_window isVisible]) return NO;
    if (([g_window occlusionState] & NSWindowOcclusionStateVisible) == 0) return NO;
    return YES;
}

// GIF animation timer callback. There is deliberately no persistent frame
// clock (no display link, no repeating timer): each tick re-arms at most one
// successor, and only while the image is visibly animating (mirrors
// idle.zig GifGate.shouldAdvance). The instant the window hides or the image
// scrolls out of the painted viewport, the chain parks: no timer remains
// scheduled and the run loop sleeps. platform_draw_image re-arms it on the
// next event-driven draw.
// GIF animation timer callback: damage is the frame's exact bounding box.
static void gif_advance_frame(CachedImageRecord* rec) {
    if (!rec || rec->frame_count <= 1) return;
    if (!gif_window_visible() || rec->last_draw_seq != g_draw_seq) {
        rec->parked = YES;
        return;
    }
    rec->cur_frame = (rec->cur_frame + 1) % rec->frame_count;
    if (rec->has_rect) {
        // Document -> view coordinates at current scroll offset.
        invalidate_rect(NSMakeRect(
            rec->last_doc_x,
            rec->last_doc_y - g_scroll_y,
            rec->last_w,
            rec->last_h));
    } else if (g_main_view) {
        [g_main_view setNeedsDisplay:YES];
    }
    gif_schedule_next_frame(rec);
}

static void gif_schedule_next_frame(CachedImageRecord* rec) {
    if (!rec || rec->frame_count <= 1) return;
    if (!gif_window_visible()) {
        rec->parked = YES;
        return;
    }
    rec->parked = NO;
    double delay = rec->frame_delays[rec->cur_frame];
    if (delay < 0.02) delay = 0.1; // clamp degenerate GIFs
    // One-shot wakeup on the main run-loop only; never a repeating driver.
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{ gif_advance_frame(rec); }
    );
}

// Resolve relative path to absolute
static NSString* resolve_image_path(NSString* pathStr) {
    if ([pathStr hasPrefix:@"http://"] || [pathStr hasPrefix:@"https://"]) return pathStr;
    if ([[NSFileManager defaultManager] fileExistsAtPath:pathStr]) return pathStr;
    NSString* cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    NSString* full = [cwd stringByAppendingPathComponent:pathStr];
    if ([[NSFileManager defaultManager] fileExistsAtPath:full]) return full;
    return nil;
}

// Decode all frames from a CGImageSource into the cache record
static void load_image_source_into_record(CGImageSourceRef src, CachedImageRecord* rec) {
    size_t count = CGImageSourceGetCount(src);
    if (count == 0) { rec->failed = YES; return; }

    // Get natural pixel size from first frame
    CGImageRef first = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    if (!first) { rec->failed = YES; return; }
    rec->natural_w = (float)CGImageGetWidth(first);
    rec->natural_h = (float)CGImageGetHeight(first);

    rec->frames       = (CGImageRef*)malloc(sizeof(CGImageRef) * count);
    rec->frame_delays = (double*)malloc(sizeof(double) * count);
    rec->frame_count  = (int)count;
    rec->frames[0]    = first; // already retained by Create

    for (size_t i = 1; i < count; i++) {
        rec->frames[i] = CGImageSourceCreateImageAtIndex(src, i, NULL);
    }

    // Extract per-frame delays (GIF {GIFDelayTime} property)
    for (size_t i = 0; i < count; i++) {
        double delay = 0.1;
        NSDictionary* props = (__bridge_transfer NSDictionary*)
            CGImageSourceCopyPropertiesAtIndex(src, i, NULL);
        NSDictionary* gifProps = props[(id)kCGImagePropertyGIFDictionary];
        if (gifProps) {
            NSNumber* d = gifProps[(id)kCGImagePropertyGIFUnclampedDelayTime];
            if (!d || [d doubleValue] <= 0)
                d = gifProps[(id)kCGImagePropertyGIFDelayTime];
            if (d) delay = [d doubleValue];
        }
        rec->frame_delays[i] = delay;
    }
}

// Synchronously populate a cache slot from a URL/path string
static void load_image_sync(CachedImageRecord* rec, NSString* pathStr) {
    CGImageSourceRef src = nil;
    if ([pathStr hasPrefix:@"http://"] || [pathStr hasPrefix:@"https://"]) {
        NSURL* u = [NSURL URLWithString:pathStr];
        if (u) {
            NSData* data = [NSData dataWithContentsOfURL:u];
            if (data) src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        }
    } else {
        NSURL* fu = [NSURL fileURLWithPath:pathStr];
        if (fu) src = CGImageSourceCreateWithURL((__bridge CFURLRef)fu, NULL);
    }

    if (src) {
        load_image_source_into_record(src, rec);
        CFRelease(src);
    } else {
        rec->failed = YES;
    }
    rec->loading = NO;
}

// Returns existing or initiates async load; returns NULL if not yet ready
static CachedImageRecord* get_or_load_image_record(const char* url, int url_len) {
    if (!url || url_len <= 0 || url_len >= 512) return NULL;

    // Cache hit
    for (int i = 0; i < g_image_cache_count; i++) {
        if (strncmp(g_image_cache[i].url, url, url_len) == 0 &&
            g_image_cache[i].url[url_len] == '\0') {
            return &g_image_cache[i];
        }
    }
    if (g_image_cache_count >= MAX_IMAGE_CACHE) return NULL;

    // Allocate slot
    CachedImageRecord* rec = &g_image_cache[g_image_cache_count++];
    memset(rec, 0, sizeof(*rec));
    memcpy(rec->url, url, url_len);
    rec->url[url_len] = '\0';
    rec->loading = YES;

    NSString* pathStr = [[NSString alloc] initWithBytes:url length:url_len
                                               encoding:NSUTF8StringEncoding];
    NSString* resolved = resolve_image_path(pathStr);
    if (!resolved) { rec->failed = YES; rec->loading = NO; return rec; }

    // Capture for block
    NSString* resolvedCopy = [resolved copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        load_image_sync(rec, resolvedCopy);
        dispatch_async(dispatch_get_main_queue(), ^{
            [g_main_view setNeedsDisplay:YES];
            // Kick off GIF animation if multi-frame
            if (!rec->failed && rec->frame_count > 1) {
                gif_schedule_next_frame(rec);
            }
        });
    });

    return rec;
}

// Query natural pixel dimensions of an image (returns 0,0 if not yet loaded)
void platform_get_image_size(const char* url, int url_len, float* out_w, float* out_h) {
    *out_w = 0; *out_h = 0;
    CachedImageRecord* rec = get_or_load_image_record(url, url_len);
    if (!rec || rec->loading || rec->failed) return;
    *out_w = rec->natural_w;
    *out_h = rec->natural_h;
}

void platform_draw_image(const char* url, int url_len, float x, float y, float w, float h) {
    if (!g_current_cg_context || w <= 0 || h <= 0) return;
    CGContextRef ctx = g_current_cg_context;

    CachedImageRecord* rec = get_or_load_image_record(url, url_len);

    // Record the frame rect in document coordinates so GIF ticks can
    // invalidate exactly this box (scroll-compensated at tick time).
    if (rec) {
        rec->last_doc_x = x;
        rec->last_doc_y = y + g_scroll_y;
        rec->last_w = w;
        rec->last_h = h;
        rec->has_rect = YES;
    }

    // Still loading — draw subtle placeholder outline
    if (!rec || rec->loading) {
        CGContextSaveGState(ctx);
        CGContextSetRGBFillColor(ctx, 28.0f/255, 28.0f/255, 32.0f/255, 0.5f);
        CGContextFillRect(ctx, CGRectMake(x, y, w, h));
        CGContextSetRGBStrokeColor(ctx, 60.0f/255, 60.0f/255, 70.0f/255, 0.6f);
        CGContextStrokeRect(ctx, CGRectMake(x, y, w, h));
        CGContextRestoreGState(ctx);
        return;
    }
    if (rec->failed || rec->frame_count == 0) {
        CGContextSaveGState(ctx);
        CGContextSetRGBFillColor(ctx, 28.0f/255, 28.0f/255, 32.0f/255, 1.0f);
        CGContextFillRect(ctx, CGRectMake(x, y, w, h));
        CGContextSetRGBStrokeColor(ctx, 80.0f/255, 40.0f/255, 40.0f/255, 1.0f);
        CGContextStrokeRect(ctx, CGRectMake(x, y, w, h));
        CGContextRestoreGState(ctx);
        return;
    }

    // The layout engine passes exactly the right draw_w / draw_h (natural size capped
    // to content width with proper aspect ratio), so we just draw at (x,y,w,h).
    // Stamp this pass: proves the image is inside the painted viewport, and
    // re-arms a parked animation chain from this genuine event-driven draw.
    rec->last_draw_seq = g_draw_seq;
    if (rec->parked && rec->frame_count > 1) {
        gif_schedule_next_frame(rec);
    }
    CGImageRef frame = rec->frames[rec->cur_frame];
    if (!frame) return;

    CGContextSaveGState(ctx);
    // Flip Y for CG coordinate system
    CGContextTranslateCTM(ctx, x, y + h);
    CGContextScaleCTM(ctx, 1.0f, -1.0f);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), frame);
    CGContextRestoreGState(ctx);
}

float platform_measure_text(const char* text, int len, float font_size, int is_bold, int is_mono) {
    if (!text || len <= 0) return 0.0f;

    // Shaping-economy fast path: shape-only (no atlas raster yet; the first
    // draw rasterizes lazily). Shares entries with the draw path wherever
    // the style bits coincide (plain body/mono runs, i.e. the hot case).
    ShapedEntry* e = shape_run(text, len, font_size, is_bold, 0, is_mono, 0, 0);
    if (e) return e->w;
    // Uncacheable run: fall through to direct measure below.

    NSString* str = [[NSString alloc] initWithBytesNoCopy:(void*)text length:len encoding:NSUTF8StringEncoding freeWhenDone:NO];
    if (!str) {
        str = [[NSString alloc] initWithBytes:text length:len encoding:NSISOLatin1StringEncoding];
    }
    if (!str) return (float)len * font_size * 0.60f;

    NSFont* nsFont = get_font_for_style(font_size, is_bold, 0, is_mono, 0);
    CTFontRef font = (__bridge CTFontRef)nsFont;

    NSDictionary* attributes = @{
        (id)kCTFontAttributeName: (__bridge id)font,
    };

    NSAttributedString* attrStr = [[NSAttributedString alloc] initWithString:str attributes:attributes];
    CTLineRef ctLine = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attrStr);
    if (!ctLine) return (float)len * font_size * 0.60f;

    CGFloat ascent, descent, leading;
    double measuredWidth = CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading);
    double trailing = CTLineGetTrailingWhitespaceWidth(ctLine);
    CFRelease(ctLine);

    return (float)(measuredWidth + trailing);
}

// Headless screenshot engine: renders directly to a PNG image file
int platform_render_to_png(const char* output_path, int width, int height, void (*render_fn)(int width, int height)) {
    if (!output_path || width <= 0 || height <= 0 || !render_fn) return -1;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        NULL,
        width,
        height,
        8,
        width * 4,
        colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorSpace);

    if (!ctx) return -2;

    // Flip context coordinate space to match flipped view
    CGContextTranslateCTM(ctx, 0, height);
    CGContextScaleCTM(ctx, 1.0f, -1.0f);

    g_text_record_count = 0;
    g_code_block_count = 0;
    g_scrollable_block_count = 0;
    g_current_cg_context = ctx;
    // Headless render has no AppKit dirty rect: full redraw.
    g_pending_dirty_valid = NO;
    // Headless bitmap contexts are 1x: cached lines draw directly so
    // screenshots match the pre-atlas renderer pixel-for-pixel.
    g_output_scale = 1.0f;

    render_fn(width, height);

    // Headless selection captures paint the same highlight as live draws.
    if (g_has_selection || g_select_all) paint_selection_highlight(ctx);

    g_current_cg_context = NULL;

    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);

    if (!image) return -3;

    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    CGImageRelease(image);

    NSData* pngData = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!pngData) return -4;

    NSString* pathStr = [NSString stringWithUTF8String:output_path];
    BOOL success = [pngData writeToFile:pathStr atomically:YES];

    return success ? 0 : -5;
}

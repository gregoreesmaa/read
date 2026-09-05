#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#include "platform.h"

static PlatformCallbacks g_callbacks = {0};
static NSWindow* g_window = nil;
static CGContextRef g_current_cg_context = NULL;

typedef struct {
    float x, y, w, h;
    char text[512];
    int len;
} QuadTextRecord;

#define MAX_QUAD_RECORDS 8192
static QuadTextRecord g_text_records[MAX_QUAD_RECORDS];
static int g_text_record_count = 0;

static BOOL g_has_selection = NO;
static NSPoint g_select_start = {0, 0};
static NSPoint g_select_end = {0, 0};
static BOOL g_select_all = NO;

@interface ReadView : NSView
- (void)copySelectionToClipboard;
@end

@implementation ReadView

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:[NSCursor IBeamCursor]];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!ctx) return;

    g_text_record_count = 0;
    g_current_cg_context = ctx;

    if (g_callbacks.on_draw) {
        g_callbacks.on_draw((int)self.bounds.size.width, (int)self.bounds.size.height);
    }

    // Draw flowing standard text selection highlight (like browsers & PDF viewers)
    if ((g_has_selection || g_select_all) && g_text_record_count > 0) {
        CGContextSetRGBFillColor(ctx, 0.22f, 0.58f, 0.98f, 0.32f);

        if (g_select_all) {
            for (int q = 0; q < g_text_record_count; q++) {
                QuadTextRecord* rec = &g_text_records[q];
                CGContextFillRect(ctx, CGRectMake(rec->x, rec->y, rec->w, rec->h));
            }
        } else {
            NSPoint pt1 = g_select_start;
            NSPoint pt2 = g_select_end;
            BOOL is_downward = (pt1.y <= pt2.y);
            NSPoint top_pt = is_downward ? pt1 : pt2;
            NSPoint bot_pt = is_downward ? pt2 : pt1;

            float min_y = top_pt.y;
            float max_y = bot_pt.y;

            BOOL is_single_line = (fabs(max_y - min_y) < 18.0f);

            for (int q = 0; q < g_text_record_count; q++) {
                QuadTextRecord* rec = &g_text_records[q];
                float r_top = rec->y;
                float r_bot = rec->y + rec->h;

                if (r_bot < min_y - 4.0f || r_top > max_y + 4.0f) {
                    continue; // Completely outside vertical bounds
                }

                if (is_single_line) {
                    // Single line: clamp between start_x and end_x
                    float left_x = fminf(top_pt.x, bot_pt.x);
                    float right_x = fmaxf(top_pt.x, bot_pt.x);

                    float h_left = fmaxf(rec->x, left_x);
                    float h_right = fminf(rec->x + rec->w, right_x);
                    if (h_right > h_left) {
                        CGContextFillRect(ctx, CGRectMake(h_left, rec->y, h_right - h_left, rec->h));
                    }
                } else {
                    // Multi-line selection flow:
                    BOOL is_first_line = (r_top <= min_y && r_bot >= min_y);
                    BOOL is_last_line = (r_top <= max_y && r_bot >= max_y);

                    if (is_first_line) {
                        float start_x = is_downward ? top_pt.x : bot_pt.x;
                        float h_left = fmaxf(rec->x, start_x);
                        float h_right = rec->x + rec->w;
                        if (h_right > h_left) {
                            CGContextFillRect(ctx, CGRectMake(h_left, rec->y, h_right - h_left, rec->h));
                        }
                    } else if (is_last_line) {
                        float end_x = is_downward ? bot_pt.x : top_pt.x;
                        float h_left = rec->x;
                        float h_right = fminf(rec->x + rec->w, end_x);
                        if (h_right > h_left) {
                            CGContextFillRect(ctx, CGRectMake(h_left, rec->y, h_right - h_left, rec->h));
                        }
                    } else {
                        // Intermediate lines: full highlight
                        CGContextFillRect(ctx, CGRectMake(rec->x, rec->y, rec->w, rec->h));
                    }
                }
            }
        }
    }

    g_current_cg_context = NULL;
}

- (void)mouseDown:(NSEvent *)event {
    g_select_all = NO;
    g_has_selection = YES;
    g_select_start = [self convertPoint:[event locationInWindow] fromView:nil];
    g_select_end = g_select_start;

    // Double click: word selection
    if ([event clickCount] == 2) {
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            if (g_select_start.x >= rec->x && g_select_start.x <= rec->x + rec->w &&
                g_select_start.y >= rec->y && g_select_start.y <= rec->y + rec->h)
            {
                g_select_start = NSMakePoint(rec->x, rec->y + rec->h * 0.5f);
                g_select_end = NSMakePoint(rec->x + rec->w, rec->y + rec->h * 0.5f);
                break;
            }
        }
    }
    // Triple click: line selection
    else if ([event clickCount] >= 3) {
        float click_y = g_select_start.y;
        float line_min_x = 9999.0f;
        float line_max_x = -9999.0f;
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            if (fabs(rec->y + rec->h * 0.5f - click_y) < 16.0f) {
                line_min_x = fminf(line_min_x, rec->x);
                line_max_x = fmaxf(line_max_x, rec->x + rec->w);
            }
        }
        if (line_max_x > line_min_x) {
            g_select_start = NSMakePoint(line_min_x, click_y);
            g_select_end = NSMakePoint(line_max_x, click_y);
        }
    }

    [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event {
    g_select_end = [self convertPoint:[event locationInWindow] fromView:nil];
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
    g_select_end = [self convertPoint:[event locationInWindow] fromView:nil];
    if (fabs(g_select_end.y - g_select_start.y) < 3.0 && fabs(g_select_end.x - g_select_start.x) < 3.0) {
        if ([event clickCount] < 2) {
            g_has_selection = NO;
        }
    }
    [self setNeedsDisplay:YES];
}

- (void)copy:(id)sender {
    (void)sender;
    [self copySelectionToClipboard];
}

- (void)copySelectionToClipboard {
    NSMutableString* result = [NSMutableString string];

    if (g_select_all) {
        float last_y = -999.0f;
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            NSString* s = [[NSString alloc] initWithBytes:rec->text length:rec->len encoding:NSUTF8StringEncoding];
            if (s) {
                if (last_y > -900.0f && fabs(rec->y - last_y) > 12.0f) {
                    [result appendString:@"\n"];
                } else if (last_y > -900.0f) {
                    [result appendString:@" "];
                }
                [result appendString:s];
                last_y = rec->y;
            }
        }
    } else if (g_has_selection) {
        NSPoint pt1 = g_select_start;
        NSPoint pt2 = g_select_end;
        float min_y = fminf(pt1.y, pt2.y);
        float max_y = fmaxf(pt1.y, pt2.y);
        float min_x = fminf(pt1.x, pt2.x);
        float max_x = fmaxf(pt1.x, pt2.x);
        BOOL is_single_line = (fabs(max_y - min_y) < 18.0f);

        float last_y = -999.0f;
        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            float r_top = rec->y;
            float r_bot = rec->y + rec->h;

            if (r_bot < min_y - 4.0f || r_top > max_y + 4.0f) continue;

            if (is_single_line) {
                if (rec->x + rec->w < min_x || rec->x > max_x) continue;
            }

            NSString* s = [[NSString alloc] initWithBytes:rec->text length:rec->len encoding:NSUTF8StringEncoding];
            if (s) {
                if (last_y > -900.0f && fabs(rec->y - last_y) > 12.0f) {
                    [result appendString:@"\n"];
                } else if (last_y > -900.0f) {
                    [result appendString:@" "];
                }
                [result appendString:s];
                last_y = rec->y;
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
        CGFloat dy = [event scrollingDeltaY];
        if (![event hasPreciseScrollingDeltas]) {
            dy *= 20.0;
        }
        g_callbacks.on_scroll((float)dy);
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
            g_select_all = YES;
            g_has_selection = YES;
            [self setNeedsDisplay:YES];
            return;
        }
    }

    if ([chars length] > 0) {
        unichar c = [chars characterAtIndex:0];
        if (g_callbacks.on_key) {
            g_callbacks.on_key((int)c);
        }
        [self setNeedsDisplay:YES];
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
    [g_window setBackgroundColor:[NSColor colorWithCalibratedRed:0.08 green:0.08 blue:0.09 alpha:1.0]];
    [g_window center];

    ReadView* view = [[ReadView alloc] initWithFrame:frame];
    [g_window setContentView:view];
    [g_window setDelegate:delegate];
    [g_window makeKeyAndOrderFront:nil];
    [g_window makeFirstResponder:view];

    return 0;
}

void platform_run_loop(void) {
    [NSApp run];
}

void platform_request_redraw(void) {
    if (g_window && [g_window contentView]) {
        [[g_window contentView] setNeedsDisplay:YES];
    }
}

void platform_draw_rect(float x, float y, float w, float h, unsigned char r, unsigned char g, unsigned char b, unsigned char a) {
    if (!g_current_cg_context) return;
    CGContextRef ctx = g_current_cg_context;

    CGContextSetRGBFillColor(ctx, r / 255.0f, g / 255.0f, b / 255.0f, a / 255.0f);
    CGContextFillRect(ctx, CGRectMake(x, y, w, h));
}

void platform_draw_text(const char* text, int len, float x, float y, float font_size, int is_bold, int is_italic, int is_mono, unsigned char r, unsigned char g, unsigned char b, unsigned char a) {
    if (!g_current_cg_context || len <= 0 || !text) return;
    CGContextRef ctx = g_current_cg_context;

    NSString* str = [[NSString alloc] initWithBytes:text length:len encoding:NSUTF8StringEncoding];
    if (!str) return;

    NSFont* nsFont = is_mono ? [NSFont userFixedPitchFontOfSize:font_size] :
                    (is_bold ? [NSFont boldSystemFontOfSize:font_size] : [NSFont systemFontOfSize:font_size]);
    CTFontRef font = (__bridge CTFontRef)nsFont;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGFloat components[4] = { r / 255.0f, g / 255.0f, b / 255.0f, a / 255.0f };
    CGColorRef fontColor = CGColorCreate(colorSpace, components);

    NSDictionary* attributes = @{
        (id)kCTFontAttributeName: (__bridge id)font,
        (id)kCTForegroundColorAttributeName: (__bridge id)fontColor,
    };

    NSAttributedString* attrStr = [[NSAttributedString alloc] initWithString:str attributes:attributes];
    CTLineRef ctLine = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attrStr);

    CGFloat ascent, descent, leading;
    double measuredWidth = CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading);
    double trailing = CTLineGetTrailingWhitespaceWidth(ctLine);

    // Record quad for mouse text selection & copying
    if (g_text_record_count < MAX_QUAD_RECORDS) {
        QuadTextRecord* rec = &g_text_records[g_text_record_count++];
        rec->x = x;
        rec->y = y;
        rec->w = (float)(measuredWidth + trailing);
        rec->h = (float)(ascent + descent);
        int copy_len = len < 511 ? len : 511;
        memcpy(rec->text, text, copy_len);
        rec->text[copy_len] = '\0';
        rec->len = copy_len;
    }

    CGContextSaveGState(ctx);

    CGContextTranslateCTM(ctx, x, y + font_size * 0.85f);
    CGContextScaleCTM(ctx, 1.0f, -1.0f);

    CGContextSetTextPosition(ctx, 0, 0);
    CTLineDraw(ctLine, ctx);

    CGContextRestoreGState(ctx);

    CFRelease(ctLine);
    CGColorRelease(fontColor);
    CGColorSpaceRelease(colorSpace);
}

float platform_measure_text(const char* text, int len, float font_size, int is_bold, int is_mono) {
    if (!text || len <= 0) return 0.0f;

    NSString* str = [[NSString alloc] initWithBytesNoCopy:(void*)text length:len encoding:NSUTF8StringEncoding freeWhenDone:NO];
    if (!str) {
        str = [[NSString alloc] initWithBytes:text length:len encoding:NSISOLatin1StringEncoding];
    }
    if (!str) return (float)len * font_size * 0.60f;

    NSFont* nsFont = is_mono ? [NSFont userFixedPitchFontOfSize:font_size] :
                    (is_bold ? [NSFont boldSystemFontOfSize:font_size] : [NSFont systemFontOfSize:font_size]);
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
    g_current_cg_context = ctx;

    render_fn(width, height);

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

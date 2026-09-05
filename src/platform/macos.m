#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#include "platform.h"

static PlatformCallbacks g_callbacks = {0};
static NSWindow* g_window = nil;
static CGContextRef g_current_cg_context = NULL;
static float g_scroll_y = 0.0f;
static NSPoint g_mouse_pos = {-9999.0f, -9999.0f};

typedef struct {
    float x;
    float doc_y; // Document Y (y + g_scroll_y)
    float w;
    float h;
    float font_size;
    int is_bold;
    int is_mono;
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

static BOOL g_has_selection = NO;
static NSPoint g_select_start = {0, 0}; // Stored in document coordinates
static NSPoint g_select_end = {0, 0};   // Stored in document coordinates
static BOOL g_select_all = NO;

static int get_char_index_at_x(QuadTextRecord* rec, float x_offset) {
    if (x_offset <= 0) return 0;
    if (x_offset >= rec->w) return rec->len;

    NSString* str = [[NSString alloc] initWithBytesNoCopy:(void*)rec->text length:rec->len encoding:NSUTF8StringEncoding freeWhenDone:NO];
    if (!str) return (int)roundf((x_offset / rec->w) * rec->len);

    NSFont* nsFont = rec->is_mono ? [NSFont userFixedPitchFontOfSize:rec->font_size] :
                    (rec->is_bold ? [NSFont boldSystemFontOfSize:rec->font_size] : [NSFont systemFontOfSize:rec->font_size]);
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

    NSString* str = [[NSString alloc] initWithBytesNoCopy:(void*)rec->text length:char_idx encoding:NSUTF8StringEncoding freeWhenDone:NO];
    if (!str) return (float)char_idx / rec->len * rec->w;

    NSFont* nsFont = rec->is_mono ? [NSFont userFixedPitchFontOfSize:rec->font_size] :
                    (rec->is_bold ? [NSFont boldSystemFontOfSize:rec->font_size] : [NSFont systemFontOfSize:rec->font_size]);
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
                                                       options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                                         owner:self
                                                      userInfo:nil];
    [self addTrackingArea:area];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!ctx) return;

    g_text_record_count = 0;
    g_code_block_count = 0;
    g_current_cg_context = ctx;

    if (g_callbacks.on_draw) {
        g_callbacks.on_draw((int)self.bounds.size.width, (int)self.bounds.size.height);
    }

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
            BOOL is_single_line = (fabs(max_y - min_y) < 18.0f);

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

                if (is_single_line) {
                    float left_x = fminf(top_pt.x, bot_pt.x);
                    float right_x = fmaxf(top_pt.x, bot_pt.x);

                    if (rec->x + rec->w < left_x || rec->x > right_x) continue;

                    c_start = get_char_index_at_x(rec, left_x - rec->x);
                    c_end = get_char_index_at_x(rec, right_x - rec->x);
                } else {
                    BOOL is_first_line = (r_top <= min_y && r_bot >= min_y);
                    BOOL is_last_line = (r_top <= max_y && r_bot >= max_y);

                    if (is_first_line) {
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

    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint view_pt = [self convertPoint:[event locationInWindow] fromView:nil];

    // Check if clicked Copy button on a code block
    for (int b_idx = 0; b_idx < g_code_block_count; b_idx++) {
        CodeBlockRecord* b = &g_code_blocks[b_idx];
        float btn_w = 64.0f;
        float btn_h = 24.0f;
        float btn_x = b->x + b->w - btn_w - 8.0f;
        float btn_y = b->y + 8.0f;
        if (view_pt.x >= btn_x && view_pt.x <= btn_x + btn_w &&
            view_pt.y >= btn_y && view_pt.y <= btn_y + btn_h) {
            NSPasteboard* pb = [NSPasteboard generalPasteboard];
            [pb clearContents];
            NSString* s = [[NSString alloc] initWithBytes:b->text length:b->len encoding:NSUTF8StringEncoding];
            if (s) [pb setString:s forType:NSPasteboardTypeString];
            g_copied_block_idx = b_idx;
            g_copied_timestamp = [NSDate timeIntervalSinceReferenceDate];
            [self setNeedsDisplay:YES];
            return;
        }
    }

    g_select_all = NO;
    g_has_selection = YES;
    g_select_start = NSMakePoint(view_pt.x, view_pt.y + g_scroll_y);
    g_select_end = g_select_start;

    // Double click: word selection
    if ([event clickCount] == 2) {
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
    }

    [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint view_pt = [self convertPoint:[event locationInWindow] fromView:nil];
    g_select_end = NSMakePoint(view_pt.x, view_pt.y + g_scroll_y);
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint view_pt = [self convertPoint:[event locationInWindow] fromView:nil];
    NSPoint end_doc = NSMakePoint(view_pt.x, view_pt.y + g_scroll_y);

    // If simple click without drag:
    if (fabs(end_doc.y - g_select_start.y) < 4.0f && fabs(end_doc.x - g_select_start.x) < 4.0f) {
        if ([event clickCount] < 2) {
            g_has_selection = NO;

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
        }
    } else {
        g_select_end = end_doc;
    }

    [self setNeedsDisplay:YES];
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
                if (last_doc_y > -9000.0f && fabs(rec->doc_y - last_doc_y) > 12.0f) {
                    [result appendString:@"\n"];
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
        BOOL is_single_line = (fabs(max_y - min_y) < 18.0f);

        float last_doc_y = -9999.0f;

        for (int q = 0; q < g_text_record_count; q++) {
            QuadTextRecord* rec = &g_text_records[q];
            float r_top = rec->doc_y;
            float r_bot = rec->doc_y + rec->h;

            if (r_bot < min_y - 4.0f || r_top > max_y + 4.0f) continue;

            int c_start = 0;
            int c_end = rec->len;

            if (is_single_line) {
                float left_x = fminf(top_pt.x, bot_pt.x);
                float right_x = fmaxf(top_pt.x, bot_pt.x);

                if (rec->x + rec->w < left_x || rec->x > right_x) continue;

                c_start = get_char_index_at_x(rec, left_x - rec->x);
                c_end = get_char_index_at_x(rec, right_x - rec->x);
            } else {
                BOOL is_first_line = (r_top <= min_y && r_bot >= min_y);
                BOOL is_last_line = (r_top <= max_y && r_bot >= max_y);

                if (is_first_line) {
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
            }

            if (c_end > c_start && c_start >= 0 && c_end <= rec->len) {
                NSString* s = [[NSString alloc] initWithBytes:&rec->text[c_start] length:(c_end - c_start) encoding:NSUTF8StringEncoding];
                if (s) {
                    if (last_doc_y > -9000.0f && fabs(rec->doc_y - last_doc_y) > 12.0f) {
                        [result appendString:@"\n"];
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
        CGFloat dx = [event scrollingDeltaX];
        CGFloat dy = [event scrollingDeltaY];
        if (![event hasPreciseScrollingDeltas]) {
            dx *= 20.0;
            dy *= 20.0;
        }
        g_callbacks.on_scroll((float)dx, (float)dy);
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

void platform_draw_text(const char* text, int len, float x, float y, float font_size, int is_bold, int is_italic, int is_mono, unsigned char r, unsigned char g, unsigned char b, unsigned char a, const char* link_url, int link_url_len) {
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

    // Record quad for mouse text selection & copying (anchored to document Y)
    if (g_text_record_count < MAX_QUAD_RECORDS) {
        QuadTextRecord* rec = &g_text_records[g_text_record_count++];
        rec->x = x;
        rec->doc_y = y + g_scroll_y;
        rec->w = (float)(measuredWidth + trailing);
        rec->h = (float)(ascent + descent);
        rec->font_size = font_size;
        rec->is_bold = is_bold;
        rec->is_mono = is_mono;
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
    g_code_block_count = 0;
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

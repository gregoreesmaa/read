const std = @import("std");
const simd = @import("../core/simd.zig");
const parser = @import("../core/parser.zig");
const layout = @import("../layout/viewport.zig");

test "spec compliance: ATX headings h1 through h6 and trailing hashes" {
    const doc =
        \\# Heading 1
        \\## Heading 2 ##
        \\### Heading 3
        \\#### Heading 4
        \\##### Heading 5
        \\###### Heading 6
    ;

    var lines: [16]simd.Line = undefined;
    var fence = false;
    const n = simd.scanLines(doc, &lines, &fence);

    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqual(simd.BlockType.heading1, lines[0].block_type);
    try std.testing.expectEqual(simd.BlockType.heading2, lines[1].block_type);
    try std.testing.expectEqual(simd.BlockType.heading3, lines[2].block_type);
    try std.testing.expectEqual(simd.BlockType.heading4, lines[3].block_type);
    try std.testing.expectEqual(simd.BlockType.heading5, lines[4].block_type);
    try std.testing.expectEqual(simd.BlockType.heading6, lines[5].block_type);
}

test "spec compliance: Setext headings h1 (===) and h2 (---)" {
    const doc =
        \\Header One Setext
        \\=================
        \\
        \\Header Two Setext
        \\-----------------
    ;

    var lines: [16]simd.Line = undefined;
    var fence = false;
    const n = simd.scanLines(doc, &lines, &fence);

    try std.testing.expectEqual(@as(usize, 5), n);

    var cmds: [64]layout.DrawCommand = undefined;
    const config = layout.ViewportConfig{
        .window_width = 800.0,
        .window_height = 800.0,
        .scroll_y = 0.0,
    };
    const cmd_count = layout.layoutViewport(doc, lines[0..n], config, &cmds);

    var found_h1 = false;
    var found_h2 = false;
    for (cmds[0..cmd_count]) |c| {
        if (c.kind == .text_run and c.style.heading and std.mem.eql(u8, c.text, "One")) {
            found_h1 = true;
            // H1 font size is 2.2x base font size
            try std.testing.expect(c.font_size >= config.base_font_size * 2.0);
        }
        if (c.kind == .text_run and c.style.heading and std.mem.eql(u8, c.text, "Two")) {
            found_h2 = true;
            // H2 font size is 1.7x base font size
            try std.testing.expect(c.font_size >= config.base_font_size * 1.5);
        }
    }
    try std.testing.expect(found_h1);
    try std.testing.expect(found_h2);
}

test "spec compliance: thematic breaks (horizontal rules ---, ***, ___)" {
    const doc =
        \\---
        \\***
        \\___
    ;

    var lines: [8]simd.Line = undefined;
    var fence = false;
    const n = simd.scanLines(doc, &lines, &fence);

    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(simd.BlockType.hr, lines[0].block_type);
    try std.testing.expectEqual(simd.BlockType.hr, lines[1].block_type);
    try std.testing.expectEqual(simd.BlockType.hr, lines[2].block_type);
}

test "spec compliance: fenced code blocks (``` and ~~~)" {
    const doc =
        \\```zig
        \\pub fn main() void {}
        \\```
        \\~~~python
        \\print("hello")
        \\~~~
    ;

    var lines: [16]simd.Line = undefined;
    var fence = false;
    const n = simd.scanLines(doc, &lines, &fence);

    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqual(simd.BlockType.code_fence_start, lines[0].block_type);
    try std.testing.expectEqual(simd.BlockType.code_line, lines[1].block_type);
    try std.testing.expectEqual(simd.BlockType.code_fence_end, lines[2].block_type);
    try std.testing.expectEqual(simd.BlockType.code_fence_start, lines[3].block_type);
    try std.testing.expectEqual(simd.BlockType.code_line, lines[4].block_type);
    try std.testing.expectEqual(simd.BlockType.code_fence_end, lines[5].block_type);
}

test "spec compliance: blockquotes and nested quotes" {
    const doc =
        \\> Single level quote
        \\>> Nested level quote
        \\> > Space separated nested quote
    ;

    var lines: [8]simd.Line = undefined;
    var fence = false;
    const n = simd.scanLines(doc, &lines, &fence);

    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(simd.BlockType.quote, lines[0].block_type);
    try std.testing.expectEqual(simd.BlockType.quote, lines[1].block_type);
    try std.testing.expectEqual(simd.BlockType.quote, lines[2].block_type);

    var cmds: [64]layout.DrawCommand = undefined;
    const vp_cfg = layout.ViewportConfig{
        .window_width = 800,
        .window_height = 600,
        .scroll_y = 0,
        .content_max_width = 600,
    };
    const cmd_count = layout.layoutViewport(doc, lines[0..n], vp_cfg, &cmds);
    try std.testing.expect(cmd_count > 0);

    // Count fill_rect commands (the quote bars)
    var bar_count: usize = 0;
    for (cmds[0..cmd_count]) |cmd| {
        if (cmd.kind == .fill_rect and cmd.rect.w == 3.0) {
            bar_count += 1;
        }
    }
    // Line 0 (depth 1): 1 bar
    // Line 1 (depth 2): 2 bars
    // Line 2 (depth 2): 2 bars
    // Total = 5 bars
    try std.testing.expectEqual(@as(usize, 5), bar_count);
}

test "spec compliance: unordered lists (*, -, +) and ordered lists (1., 1))" {
    const doc =
        \\* Star bullet
        \\- Hyphen bullet
        \\+ Plus bullet
        \\1. Dot ordered
        \\2) Paren ordered
    ;

    var lines: [16]simd.Line = undefined;
    var fence = false;
    const n = simd.scanLines(doc, &lines, &fence);

    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqual(simd.BlockType.bullet_list, lines[0].block_type);
    try std.testing.expectEqual(simd.BlockType.bullet_list, lines[1].block_type);
    try std.testing.expectEqual(simd.BlockType.bullet_list, lines[2].block_type);
    try std.testing.expectEqual(simd.BlockType.ordered_list, lines[3].block_type);
    try std.testing.expectEqual(simd.BlockType.ordered_list, lines[4].block_type);
}

test "spec compliance: task lists (- [ ], - [x], * [X])" {
    const doc =
        \\- [ ] Incomplete task
        \\- [x] Complete task
        \\* [X] Capital complete task
    ;

    var lines: [8]simd.Line = undefined;
    var fence = false;
    const n = simd.scanLines(doc, &lines, &fence);

    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(simd.BlockType.task_list, lines[0].block_type);
    try std.testing.expectEqual(simd.BlockType.task_list, lines[1].block_type);
    try std.testing.expectEqual(simd.BlockType.task_list, lines[2].block_type);
}

test "spec compliance: backslash escapes for markdown punctuation" {
    const line = "\\*not italic\\* and \\[not a link\\] and \\`not code\\`";
    var spans: [16]parser.InlineSpan = undefined;
    const count = parser.parseInlines(line, &spans);

    // None of the spans should have italic, link, or code styles set
    for (spans[0..count]) |s| {
        try std.testing.expect(!s.style.italic);
        try std.testing.expect(!s.style.link);
        try std.testing.expect(!s.style.code);
    }
}

test "spec compliance: autolinks (<https://...> and <email@...>) and images (![alt](url))" {
    const line = "Visit <https://commonmark.org> or email <developer@read.io> or see ![App Logo](logo.png)";
    var spans: [16]parser.InlineSpan = undefined;
    const count = parser.parseInlines(line, &spans);

    var found_web_autolink = false;
    var found_email_autolink = false;
    var found_image = false;

    for (spans[0..count]) |s| {
        if (s.style.link) {
            if (s.link_target) |t| {
                if (std.mem.eql(u8, t, "https://commonmark.org")) found_web_autolink = true;
                if (std.mem.eql(u8, t, "developer@read.io")) found_email_autolink = true;
                if (std.mem.eql(u8, t, "logo.png")) {
                    found_image = true;
                    try std.testing.expectEqualStrings("App Logo", s.text);
                }
            }
        }
    }

    try std.testing.expect(found_web_autolink);
    try std.testing.expect(found_email_autolink);
    try std.testing.expect(found_image);
}

test "spec compliance: triple emphasis (***bold and italic*** and ___bold and italic___)" {
    const line = "Text with ***triple emphasis*** and ___underscore triple___ formatting.";
    var spans: [16]parser.InlineSpan = undefined;
    const count = parser.parseInlines(line, &spans);

    var found_triple1 = false;
    var found_triple2 = false;

    for (spans[0..count]) |s| {
        if (s.style.bold and s.style.italic) {
            if (std.mem.eql(u8, s.text, "triple emphasis")) found_triple1 = true;
            if (std.mem.eql(u8, s.text, "underscore triple")) found_triple2 = true;
        }
    }

    try std.testing.expect(found_triple1);
    try std.testing.expect(found_triple2);
}

test "spec compliance: standalone image block parsing and viewport command generation" {
    const md =
        \\# Visual Gallery
        \\
        \\![PNG Example](assets/images/sample_png.png)
        \\![SVG Vector Graphic](assets/images/sample_svg.svg)
        \\![WebP Graphic](assets/images/sample_webp.webp)
        \\![GIF Animation](assets/images/sample_gif.gif)
        \\![JPEG Photographic](assets/images/sample_jpeg.jpg)
        \\![TIFF Archival](assets/images/sample_tiff.tiff)
        \\![BMP Bitmap](assets/images/sample_bmp.bmp)
        \\![HEIC Mobile](assets/images/sample_heic.heic)
    ;

    var lines: [16]simd.Line = undefined;
    var fence = false;
    const line_count = simd.scanLines(md, &lines, &fence);

    try std.testing.expectEqual(@as(usize, 10), line_count);
    try std.testing.expectEqual(simd.BlockType.heading1, lines[0].block_type);
    try std.testing.expectEqual(simd.BlockType.blank, lines[1].block_type);
    try std.testing.expectEqual(simd.BlockType.image, lines[2].block_type);
    try std.testing.expectEqual(simd.BlockType.image, lines[3].block_type);
    try std.testing.expectEqual(simd.BlockType.image, lines[4].block_type);
    try std.testing.expectEqual(simd.BlockType.image, lines[5].block_type);
    try std.testing.expectEqual(simd.BlockType.image, lines[6].block_type);
    try std.testing.expectEqual(simd.BlockType.image, lines[7].block_type);
    try std.testing.expectEqual(simd.BlockType.image, lines[8].block_type);
    try std.testing.expectEqual(simd.BlockType.image, lines[9].block_type);

    const vp_config = layout.ViewportConfig{
        .window_width = 1000.0,
        .window_height = 800.0,
        .scroll_y = 0.0,
    };

    var commands: [64]layout.DrawCommand = undefined;
    const cmd_count = layout.layoutViewport(md, lines[0..line_count], vp_config, &commands);
    try std.testing.expect(cmd_count > 0);

    var img_cmd_count: usize = 0;
    for (commands[0..cmd_count]) |cmd| {
        if (cmd.kind == .image) {
            img_cmd_count += 1;
            try std.testing.expect(cmd.rect.w > 0.0);
            try std.testing.expect(cmd.rect.h > 0.0);
            try std.testing.expect(cmd.link_target != null);
        }
    }
    try std.testing.expect(img_cmd_count >= 1);
}

test "situation: mixed CRLF, LF, and trailing bare line endings" {
    const doc = "Line 1 CRLF\r\nLine 2 LF\nLine 3 CRLF\r\nLine 4 EOF no newline";
    var lines: [8]simd.Line = undefined;
    var in_fence = false;
    const n = simd.scanLines(doc, &lines, &in_fence);

    try std.testing.expectEqual(@as(usize, 4), n);

    const l1 = doc[lines[0].offset..][0..lines[0].len];
    const l2 = doc[lines[1].offset..][0..lines[1].len];
    const l3 = doc[lines[2].offset..][0..lines[2].len];
    const l4 = doc[lines[3].offset..][0..lines[3].len];

    try std.testing.expectEqualStrings("Line 1 CRLF", l1);
    try std.testing.expectEqualStrings("Line 2 LF", l2);
    try std.testing.expectEqualStrings("Line 3 CRLF", l3);
    try std.testing.expectEqualStrings("Line 4 EOF no newline", l4);
}

test "situation: extreme and pathological line lengths" {
    const allocator = std.testing.allocator;
    var long_line: std.ArrayList(u8) = .empty;
    defer long_line.deinit(allocator);

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        try long_line.appendSlice(allocator, "word_segment_");
    }
    try long_line.append(allocator, '\n');

    var lines: [4]simd.Line = undefined;
    var in_fence = false;
    const n = simd.scanLines(long_line.items, &lines, &in_fence);

    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u20, @intCast(long_line.items.len - 1)), lines[0].len);

    var cmds: [256]layout.DrawCommand = undefined;
    const cfg = layout.ViewportConfig{
        .window_width = 600.0,
        .window_height = 800.0,
        .scroll_y = 0.0,
    };
    const cmd_count = layout.layoutViewport(long_line.items, lines[0..n], cfg, &cmds);
    try std.testing.expect(cmd_count > 0);
}

test "situation: deeply nested blockquotes (up to 8 levels)" {
    const doc =
        \\> Level 1
        \\>> Level 2
        \\>>> Level 3
        \\>>>> Level 4
        \\>>>>> Level 5
        \\>>>>>> Level 6
        \\>>>>>>> Level 7
        \\>>>>>>>> Level 8
    ;

    var lines: [16]simd.Line = undefined;
    var in_fence = false;
    const n = simd.scanLines(doc, &lines, &in_fence);

    try std.testing.expectEqual(@as(usize, 8), n);
    for (lines[0..n]) |l| {
        try std.testing.expectEqual(simd.BlockType.quote, l.block_type);
    }

    var cmds: [128]layout.DrawCommand = undefined;
    const cfg = layout.ViewportConfig{
        .window_width = 800.0,
        .window_height = 1000.0,
        .scroll_y = 0.0,
    };
    const count = layout.layoutViewport(doc, lines[0..n], cfg, &cmds);
    try std.testing.expect(count > 0);

    // Verify quote bars: 1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 = 36 bars total
    var bar_count: usize = 0;
    for (cmds[0..count]) |c| {
        if (c.kind == .fill_rect and c.rect.w == 3.0) {
            bar_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 36), bar_count);
}

test "situation: unclosed code fence and malformed block elements" {
    const doc =
        \\```zig
        \\pub fn unclosed() void {
        \\    // This fence never closes before EOF
        \\
    ;

    var lines: [8]simd.Line = undefined;
    var in_fence = false;
    const n = simd.scanLines(doc, &lines, &in_fence);

    try std.testing.expect(n >= 3);
    try std.testing.expectEqual(simd.BlockType.code_fence_start, lines[0].block_type);
    try std.testing.expectEqual(simd.BlockType.code_line, lines[1].block_type);
    try std.testing.expectEqual(simd.BlockType.code_line, lines[2].block_type);
    try std.testing.expect(in_fence);

    var cmds: [64]layout.DrawCommand = undefined;
    const cfg = layout.ViewportConfig{
        .window_width = 800.0,
        .window_height = 600.0,
        .scroll_y = 0.0,
    };
    const count = layout.layoutViewport(doc, lines[0..n], cfg, &cmds);
    try std.testing.expect(count > 0);
}

test "situation: Unicode UTF-8 multi-byte robustness across headings and inlines" {
    const doc =
        \\# Überschrift mit Umlauten und Emojis 🚀
        \\
        \\Text with **fettgedruckten Äpfeln**, *kursiven Büchern*, and [Webseite](https://example.de/ökologie).
        \\
        \\- Item with Cyrillic: Привет, мир!
        \\- Item with CJK: こんにちは世界
    ;

    var lines: [16]simd.Line = undefined;
    var in_fence = false;
    const n = simd.scanLines(doc, &lines, &in_fence);

    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqual(simd.BlockType.heading1, lines[0].block_type);
    try std.testing.expectEqual(simd.BlockType.blank, lines[1].block_type);
    try std.testing.expectEqual(simd.BlockType.paragraph, lines[2].block_type);
    try std.testing.expectEqual(simd.BlockType.blank, lines[3].block_type);
    try std.testing.expectEqual(simd.BlockType.bullet_list, lines[4].block_type);
    try std.testing.expectEqual(simd.BlockType.bullet_list, lines[5].block_type);

    var cmds: [128]layout.DrawCommand = undefined;
    const cfg = layout.ViewportConfig{
        .window_width = 800.0,
        .window_height = 800.0,
        .scroll_y = 0.0,
    };
    const count = layout.layoutViewport(doc, lines[0..n], cfg, &cmds);
    try std.testing.expect(count > 0);
}

test "situation: extreme viewport dimensions and overscroll boundaries" {
    const doc =
        \\# Boundary Test
        \\Testing extreme layout dimensions.
        \\- Bullet one
        \\- Bullet two
    ;

    var lines: [8]simd.Line = undefined;
    var in_fence = false;
    const n = simd.scanLines(doc, &lines, &in_fence);

    var cmds: [64]layout.DrawCommand = undefined;

    // 1. Tiny viewport (50x50)
    const cfg_tiny = layout.ViewportConfig{
        .window_width = 50.0,
        .window_height = 50.0,
        .scroll_y = 0.0,
    };
    const count_tiny = layout.layoutViewport(doc, lines[0..n], cfg_tiny, &cmds);
    try std.testing.expect(count_tiny > 0);

    // 2. 4K Ultra-wide viewport (3840x2160)
    const cfg_4k = layout.ViewportConfig{
        .window_width = 3840.0,
        .window_height = 2160.0,
        .scroll_y = 0.0,
    };
    const count_4k = layout.layoutViewport(doc, lines[0..n], cfg_4k, &cmds);
    try std.testing.expect(count_4k > 0);

    // 3. Negative scroll (overscroll bounce)
    const cfg_neg = layout.ViewportConfig{
        .window_width = 800.0,
        .window_height = 600.0,
        .scroll_y = -300.0,
    };
    const count_neg = layout.layoutViewport(doc, lines[0..n], cfg_neg, &cmds);
    try std.testing.expect(count_neg > 0);

    // 4. Past EOF scroll
    const cfg_eof = layout.ViewportConfig{
        .window_width = 800.0,
        .window_height = 600.0,
        .scroll_y = 100_000.0,
    };
    const count_eof = layout.layoutViewport(doc, lines[0..n], cfg_eof, &cmds);
    // Background fill command only
    try std.testing.expectEqual(@as(usize, 1), count_eof);
}

test "situation: arbitrary scroll position checkpoint invariance across rich document" {
    const allocator = std.testing.allocator;
    const chunk =
        \\# Section Heading
        \\Paragraph with some **bold** and *italic* styling.
        \\| Col A | Col B |
        \\| --- | --- |
        \\| Val 1 | Val 2 |
        \\```zig
        \\const x = 42;
        \\```
        \\> Quote text
        \\- [x] Task complete
        \\
    ;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        try buf.appendSlice(allocator, chunk);
    }

    const mem = buf.items;
    const lines = try allocator.alloc(simd.Line, 3000);
    defer allocator.free(lines);

    var in_fence = false;
    const line_count = simd.scanLines(mem, lines, &in_fence);

    var checkpoints: [128]layout.Checkpoint = undefined;
    var cp_count: usize = 0;

    const base_cfg = layout.ViewportConfig{
        .window_width = 900.0,
        .window_height = 700.0,
        .scroll_y = 0.0,
    };

    const doc_h = layout.computeDocumentHeightEx(
        mem,
        lines[0..line_count],
        base_cfg,
        &checkpoints,
        &cp_count,
    );

    try std.testing.expect(cp_count > 0);

    // Test a sweep of diverse scroll positions
    const scroll_positions = [_]f32{ 0.0, 500.0, 1500.0, 3200.0, 6400.0, doc_h * 0.5, doc_h * 0.85 };

    for (scroll_positions) |s_y| {
        const cfg_no_cp = layout.ViewportConfig{
            .window_width = 900.0,
            .window_height = 700.0,
            .scroll_y = s_y,
        };
        const cfg_cp = layout.ViewportConfig{
            .window_width = 900.0,
            .window_height = 700.0,
            .scroll_y = s_y,
            .checkpoints = checkpoints[0..cp_count],
        };

        var cmds_a: [512]layout.DrawCommand = undefined;
        var cmds_b: [512]layout.DrawCommand = undefined;

        const count_a = layout.layoutViewport(mem, lines[0..line_count], cfg_no_cp, &cmds_a);
        const count_b = layout.layoutViewport(mem, lines[0..line_count], cfg_cp, &cmds_b);

        try std.testing.expectEqual(count_a, count_b);
        for (cmds_a[0..count_a], 0..) |ca, idx| {
            const cb = cmds_b[idx];
            try std.testing.expectEqual(ca.kind, cb.kind);
            try std.testing.expectApproxEqAbs(ca.rect.x, cb.rect.x, 0.01);
            try std.testing.expectApproxEqAbs(ca.rect.y, cb.rect.y, 0.1);
            try std.testing.expectApproxEqAbs(ca.rect.w, cb.rect.w, 0.01);
            try std.testing.expectApproxEqAbs(ca.rect.h, cb.rect.h, 0.01);
        }
    }
}

fn testCfg() layout.ViewportConfig {
    return layout.ViewportConfig{
        .window_width = 800,
        .window_height = 600,
        .scroll_y = 0,
        .content_max_width = 600,
    };
}

fn scanDoc(doc: []const u8, lines: []simd.Line) usize {
    var fence = false;
    return simd.scanLines(doc, lines, &fence);
}

test "regression: lazy blockquote continuation keeps quote styling and bar" {
    const doc =
        \\> This is a blockquote with two paragraphs. Lorem ipsum dolor sit amet,
        \\consectetuer adipiscing elit. Aliquam hendrerit mi posuere lectus.
        \\Vestibulum enim wisi, viverra nec, fringilla in, laoreet vitae, risus.
        \\
        \\> Donec sit amet nisl. Aliquam semper ipsum sit amet velit. Suspendisse
        \\id sem consectetuer libero luctus adipiscing.
    ;
    var lines: [16]simd.Line = undefined;
    const n = scanDoc(doc, &lines);
    try std.testing.expectEqual(@as(usize, 6), n);

    var cmds: [256]layout.DrawCommand = undefined;
    const count = layout.layoutViewport(doc, lines[0..n], testCfg(), &cmds);

    const muted = layout.Theme.dark.muted;
    var vest_y: f32 = -1;
    var text_runs: usize = 0;
    for (cmds[0..count]) |c| {
        if (c.kind != .text_run) continue;
        text_runs += 1;
        // No white intruding paragraph text; everything stays quoted.
        try std.testing.expectEqual(muted, c.color);
        // No text runs through the bar column (bar at content_x + 4).
        try std.testing.expect(c.rect.x >= 100.0 + 16.0 - 0.01);
        if (std.mem.eql(u8, c.text, "Vestibulum")) vest_y = c.rect.y;
    }
    try std.testing.expect(text_runs > 0);
    try std.testing.expect(vest_y >= 0);

    // Two bars (one per `>` line); the first spans leader + lazy tail.
    var bars: [4]layout.DrawCommand = undefined;
    var nb: usize = 0;
    for (cmds[0..count]) |c| {
        if (c.kind == .fill_rect and c.rect.w == 3.0) {
            bars[nb] = c;
            nb += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), nb);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), bars[0].rect.y, 0.01);
    try std.testing.expect(bars[0].rect.y + bars[0].rect.h >= vest_y + 29.75 - 0.5);
    try std.testing.expect(bars[1].rect.y > bars[0].rect.y + bars[0].rect.h);

    // Height parity with the fully-marked form.
    const explicit_doc =
        \\> This is a blockquote with two paragraphs. Lorem ipsum dolor sit amet,
        \\> consectetuer adipiscing elit. Aliquam hendrerit mi posuere lectus.
        \\> Vestibulum enim wisi, viverra nec, fringilla in, laoreet vitae, risus.
        \\
        \\> Donec sit amet nisl. Aliquam semper ipsum sit amet velit. Suspendisse
        \\> id sem consectetuer libero luctus adipiscing.
    ;
    var lines2: [16]simd.Line = undefined;
    const n2 = scanDoc(explicit_doc, &lines2);
    const h_lazy = layout.computeDocumentHeightEx(doc, lines[0..n], testCfg(), null, null);
    const h_exp = layout.computeDocumentHeightEx(explicit_doc, lines2[0..n2], testCfg(), null, null);
    try std.testing.expectApproxEqAbs(h_lazy, h_exp, 0.01);
}

test "regression: hard-wrapped paragraph lines flow as one paragraph" {
    const wrapped =
        \\alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu
        \\xi omicron pi rho sigma tau upsilon phi chi psi omega second line here
    ;
    const joined =
        \\alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega second line here
    ;
    var l1: [8]simd.Line = undefined;
    var l2: [8]simd.Line = undefined;
    const n1 = scanDoc(wrapped, &l1);
    const n2 = scanDoc(joined, &l2);
    try std.testing.expectEqual(@as(usize, 2), n1);
    try std.testing.expectEqual(@as(usize, 1), n2);

    const h1 = layout.computeDocumentHeightEx(wrapped, l1[0..n1], testCfg(), null, null);
    const h2 = layout.computeDocumentHeightEx(joined, l2[0..n2], testCfg(), null, null);
    try std.testing.expectApproxEqAbs(h1, h2, 0.01);

    // Identical word streams: the soft break behaves like a space.
    var ca: [128]layout.DrawCommand = undefined;
    var cb: [128]layout.DrawCommand = undefined;
    const na = layout.layoutViewport(wrapped, l1[0..n1], testCfg(), &ca);
    const nb = layout.layoutViewport(joined, l2[0..n2], testCfg(), &cb);
    try std.testing.expectEqual(na, nb);
    for (ca[0..na], 0..) |c, k| {
        try std.testing.expectEqual(c.kind, cb[k].kind);
        try std.testing.expectEqualStrings(c.text, cb[k].text);
        try std.testing.expectApproxEqAbs(c.rect.x, cb[k].rect.x, 0.01);
        try std.testing.expectApproxEqAbs(c.rect.y, cb[k].rect.y, 0.01);
    }
}

test "regression: headers, lists, tasks, and code render inside blockquotes" {
    const doc =
        \\> ## Quoted Head
        \\> 1. First quoted item
        \\> 1. Second quoted item
        \\> - Quoted bullet
        \\> - [x] Quoted task done
        \\>     quotedCode()
    ;
    var lines: [16]simd.Line = undefined;
    const n = scanDoc(doc, &lines);

    var store = layout.OrderedMarkerStore{};
    var cfg = testCfg();
    cfg.ordered_markers = &store;
    var cmds: [256]layout.DrawCommand = undefined;
    const count = layout.layoutViewport(doc, lines[0..n], cfg, &cmds);

    var saw_heading = false;
    var saw_bullet = false;
    var saw_code = false;
    var saw_num1 = false;
    var saw_num2 = false;
    var bars: usize = 0;
    for (cmds[0..count]) |c| {
        if (c.kind == .fill_rect and c.rect.w == 3.0) bars += 1;
        if (c.kind != .text_run) continue;
        // No literal markers leak into quoted output.
        try std.testing.expect(c.text.len == 0 or c.text[0] != '#');
        if (c.style.heading and c.font_size > 17.0) {
            if (!saw_heading) try std.testing.expectEqualStrings("Quoted", c.text);
            saw_heading = true;
        }
        if (std.mem.eql(u8, c.text, "•")) saw_bullet = true;
        if (c.style.code and std.mem.eql(u8, c.text, "quotedCode()")) saw_code = true;
        if (!c.style.code and !c.style.heading and c.font_size < 17.0) {
            if (std.mem.eql(u8, c.text, "1.")) saw_num1 = true;
            if (std.mem.eql(u8, c.text, "2.")) saw_num2 = true;
        }
    }
    try std.testing.expect(saw_heading);
    try std.testing.expect(saw_bullet);
    try std.testing.expect(saw_code);
    try std.testing.expect(saw_num1 and saw_num2);
    try std.testing.expectEqual(@as(usize, 6), bars);

    // Checkbox box for the checked quoted task.
    var box = false;
    for (cmds[0..count]) |c| {
        if (c.kind == .fill_rect and c.rect.w == 16.0 and c.rect.h == 16.0) box = true;
    }
    try std.testing.expect(box);
}

test "regression: ordered list markers renumber per CommonMark" {
    const doc =
        \\1. Bird
        \\1. McHale
        \\1. Parish
    ;
    const doc2 =
        \\3. Bird
        \\1. McHale
        \\8. Parish
    ;
    var l1: [8]simd.Line = undefined;
    var l2: [8]simd.Line = undefined;
    const n1 = scanDoc(doc, &l1);
    const n2 = scanDoc(doc2, &l2);

    var store = layout.OrderedMarkerStore{};
    var cfg = testCfg();
    cfg.ordered_markers = &store;
    var cmds: [64]layout.DrawCommand = undefined;
    const c1 = layout.layoutViewport(doc, l1[0..n1], cfg, &cmds);
    var got1: [3][]const u8 = undefined;
    var k: usize = 0;
    for (cmds[0..c1]) |c| {
        if (c.kind == .text_run and c.font_size < 17.0 and c.rect.w == 18.0 and k < 3) {
            got1[k] = c.text;
            k += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), k);
    try std.testing.expectEqualStrings("1.", got1[0]);
    try std.testing.expectEqualStrings("2.", got1[1]);
    try std.testing.expectEqualStrings("3.", got1[2]);

    var store2 = layout.OrderedMarkerStore{};
    cfg.ordered_markers = &store2;
    var cmds2: [64]layout.DrawCommand = undefined;
    const c2 = layout.layoutViewport(doc2, l2[0..n2], cfg, &cmds2);
    var got2: [3][]const u8 = undefined;
    k = 0;
    for (cmds2[0..c2]) |c| {
        if (c.kind == .text_run and c.font_size < 17.0 and c.rect.w == 18.0 and k < 3) {
            got2[k] = c.text;
            k += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), k);
    try std.testing.expectEqualStrings("3.", got2[0]);
    try std.testing.expectEqualStrings("4.", got2[1]);
    try std.testing.expectEqualStrings("5.", got2[2]);

    // Without a store the source markers echo verbatim (fallback).
    var cmds3: [64]layout.DrawCommand = undefined;
    const c3 = layout.layoutViewport(doc, l1[0..n1], testCfg(), &cmds3);
    k = 0;
    for (cmds3[0..c3]) |c| {
        if (c.kind == .text_run and c.font_size < 17.0 and c.rect.w == 18.0 and k < 3) {
            try std.testing.expectEqualStrings("1. ", c.text);
            k += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), k);
}

test "regression: lazy list continuations match hanging indents" {
    const indented =
        \\*   Lorem ipsum dolor sit amet, consectetuer adipiscing elit.
        \\    Aliquam hendrerit mi posuere lectus. Vestibulum enim wisi,
        \\    viverra nec, fringilla in, laoreet vitae, risus.
    ;
    const lazy =
        \\*   Lorem ipsum dolor sit amet, consectetuer adipiscing elit.
        \\Aliquam hendrerit mi posuere lectus. Vestibulum enim wisi,
        \\viverra nec, fringilla in, laoreet vitae, risus.
    ;
    var l1: [8]simd.Line = undefined;
    var l2: [8]simd.Line = undefined;
    const n1 = scanDoc(indented, &l1);
    const n2 = scanDoc(lazy, &l2);
    var ca: [128]layout.DrawCommand = undefined;
    var cb: [128]layout.DrawCommand = undefined;
    const na = layout.layoutViewport(indented, l1[0..n1], testCfg(), &ca);
    const nb = layout.layoutViewport(lazy, l2[0..n2], testCfg(), &cb);
    try std.testing.expectEqual(na, nb);
    for (ca[0..na], 0..) |c, k| {
        try std.testing.expectEqual(c.kind, cb[k].kind);
        try std.testing.expectEqualStrings(c.text, cb[k].text);
        try std.testing.expectApproxEqAbs(c.rect.x, cb[k].rect.x, 0.01);
        try std.testing.expectApproxEqAbs(c.rect.y, cb[k].rect.y, 0.01);
    }
    // Continuation rows keep the item indent (no full-bleed text).
    for (cb[0..nb]) |c| {
        if (c.kind == .text_run and !std.mem.eql(u8, c.text, "•")) {
            try std.testing.expect(c.rect.x >= 100.0 + 18.0 - 0.01);
        }
    }
}

test "regression: list multi-paragraph items keep indent; bare lines end them" {
    const doc =
        \\1.  First paragraph one here.
        \\
        \\    Second paragraph two here.
        \\
        \\2.  Next item here.
    ;
    var lines: [16]simd.Line = undefined;
    const n = scanDoc(doc, &lines);
    var cmds: [128]layout.DrawCommand = undefined;
    var store = layout.OrderedMarkerStore{};
    var cfg = testCfg();
    cfg.ordered_markers = &store;
    const count = layout.layoutViewport(doc, lines[0..n], cfg, &cmds);
    var second_x: f32 = -1;
    var saw_2 = false;
    for (cmds[0..count]) |c| {
        if (c.kind != .text_run) continue;
        if (std.mem.eql(u8, c.text, "Second")) second_x = c.rect.x;
        if (std.mem.eql(u8, c.text, "2.")) saw_2 = true;
    }
    try std.testing.expect(saw_2);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0 + 18.0), second_x, 0.5);

    // A col-0 paragraph after a blank ends the item instead.
    const doc2 =
        \\1.  First here.
        \\
        \\Second col zero here.
    ;
    var l2: [8]simd.Line = undefined;
    const n2 = scanDoc(doc2, &l2);
    var cmds2: [64]layout.DrawCommand = undefined;
    const c2 = layout.layoutViewport(doc2, l2[0..n2], testCfg(), &cmds2);
    var sx: f32 = -1;
    for (cmds2[0..c2]) |c| {
        if (c.kind == .text_run and std.mem.eql(u8, c.text, "Second")) sx = c.rect.x;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), sx, 0.5);
}

test "regression: quotes and code indent inside list items" {
    const doc =
        \\*   A list item with a blockquote:
        \\
        \\    > This is a blockquote
        \\    > inside a list item.
        \\
        \\*   A list item with a code block:
        \\
        \\        <code goes here>
    ;
    var lines: [16]simd.Line = undefined;
    const n = scanDoc(doc, &lines);
    var cmds: [256]layout.DrawCommand = undefined;
    const count = layout.layoutViewport(doc, lines[0..n], testCfg(), &cmds);

    // Quote bar sits at the item column, not the left margin.
    var bar_x: f32 = -1;
    var quote_x: f32 = -1;
    for (cmds[0..count]) |c| {
        if (c.kind == .fill_rect and c.rect.w == 3.0) bar_x = c.rect.x;
        if (c.kind == .text_run and std.mem.eql(u8, c.text, "This")) quote_x = c.rect.x;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 100.0 + 18.0 + 16.0 - 12.0), bar_x, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0 + 18.0 + 16.0), quote_x, 0.5);

    // Code card sits at the item column with mono rows.
    var bg_x: f32 = -1;
    var code_mono = false;
    for (cmds[0..count]) |c| {
        if (c.kind == .code_block_bg) bg_x = c.rect.x;
        if (c.kind == .text_run and c.style.code and std.mem.indexOf(u8, c.text, "<code") != null) code_mono = true;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 100.0 + 18.0 - 12.0), bg_x, 0.5);
    try std.testing.expect(code_mono);
}

test "regression: indented code blocks render as code cards" {
    const doc =
        \\This is a normal paragraph:
        \\
        \\    This is a code block.
        \\
        \\Here is an example of AppleScript:
        \\
        \\    tell application "Foo"
        \\        beep
        \\    end tell
    ;
    var lines: [16]simd.Line = undefined;
    const n = scanDoc(doc, &lines);
    var cmds: [256]layout.DrawCommand = undefined;
    const count = layout.layoutViewport(doc, lines[0..n], testCfg(), &cmds);

    var bgs: usize = 0;
    var copy_ok = false;
    var mono_rows: usize = 0;
    for (cmds[0..count]) |c| {
        if (c.kind == .code_block_bg) {
            bgs += 1;
            if (std.mem.indexOf(u8, c.text, "This is a code block.") != null) copy_ok = true;
        }
        if (c.kind == .text_run and c.style.code) mono_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), bgs);
    try std.testing.expect(copy_ok);
    try std.testing.expectEqual(@as(usize, 4), mono_rows);

    // Blank line inside the code stays in the same card.
    const doc2 =
        \\    first line here
        \\
        \\    second line here
    ;
    var l2: [8]simd.Line = undefined;
    const n2 = scanDoc(doc2, &l2);
    var cmds2: [64]layout.DrawCommand = undefined;
    const c2 = layout.layoutViewport(doc2, l2[0..n2], testCfg(), &cmds2);
    var bgs2: usize = 0;
    for (cmds2[0..c2]) |c| {
        if (c.kind == .code_block_bg) {
            bgs2 += 1;
            try std.testing.expect(std.mem.indexOf(u8, c.text, "first") != null);
            try std.testing.expect(std.mem.indexOf(u8, c.text, "second") != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), bgs2);

    // Indented `===` is code, never a setext heading.
    const doc3 =
        \\Para here.
        \\
        \\    ===
    ;
    var l3: [8]simd.Line = undefined;
    const n3 = scanDoc(doc3, &l3);
    var cmds3: [64]layout.DrawCommand = undefined;
    const c3 = layout.layoutViewport(doc3, l3[0..n3], testCfg(), &cmds3);
    var code_eq = false;
    var head_eq = false;
    for (cmds3[0..c3]) |c| {
        if (c.kind == .text_run and std.mem.eql(u8, c.text, "===")) {
            if (c.style.code) code_eq = true;
            if (c.style.heading) head_eq = true;
        }
    }
    try std.testing.expect(code_eq);
    try std.testing.expect(!head_eq);
}

test "regression: section-link anchors resolve to headings" {
    var sbuf: [128]u8 = undefined;
    const slug = struct {
        fn run(text: []const u8, buf: []u8) []const u8 {
            return buf[0..layout.slugifyHeading(text, buf)];
        }
    }.run;
    try std.testing.expectEqualStrings("overview", slug("Overview", &sbuf));
    try std.testing.expectEqualStrings("inline-html", slug("Inline HTML", &sbuf));
    try std.testing.expectEqualStrings("block-elements", slug("Block Elements", &sbuf));

    const cases = [_][2][]const u8{
        .{ "overview", "overview" },
        .{ "philosophy", "philosophy" },
        .{ "html", "inline-html" },
        .{ "autoescape", "automatic-escaping-for-special-characters" },
        .{ "block", "block-elements" },
        .{ "p", "paragraphs-and-line-breaks" },
        .{ "header", "headers" },
        .{ "blockquote", "blockquotes" },
        .{ "list", "lists" },
        .{ "precode", "code-blocks" },
        .{ "hr", "horizontal-rules" },
        .{ "span", "span-elements" },
        .{ "link", "links" },
        .{ "em", "emphasis" },
        .{ "code", "code" },
        .{ "img", "images" },
        .{ "misc", "miscellaneous" },
        .{ "backslash", "backslash-escapes" },
        .{ "autolink", "automatic-links" },
    };
    for (cases) |c| {
        try std.testing.expect(layout.anchorMatchesSlug(c[0], c[1]));
    }
    try std.testing.expect(!layout.anchorMatchesSlug("zzz", "overview"));

    const doc =
        \\# Top Title
        \\
        \\Some intro text here.
        \\
        \\### Blockquotes
        \\
        \\Quoted text below.
        \\
        \\## Lists
    ;
    var lines: [16]simd.Line = undefined;
    const n = scanDoc(doc, &lines);
    const y_bq = layout.anchorScrollY(doc, lines[0..n], testCfg(), "blockquote");
    const y_lists = layout.anchorScrollY(doc, lines[0..n], testCfg(), "list");
    const y_none = layout.anchorScrollY(doc, lines[0..n], testCfg(), "nope");
    const y_top = layout.anchorScrollY(doc, lines[0..n], testCfg(), "");
    try std.testing.expect(y_bq != null);
    try std.testing.expect(y_lists != null);
    try std.testing.expect(y_lists.? > y_bq.?);
    try std.testing.expect(y_none == null);
    try std.testing.expectEqual(@as(f32, 0.0), y_top.?);

    // Anchor y matches the rendered heading geometry (unit start + margin).
    var cmds: [128]layout.DrawCommand = undefined;
    const count = layout.layoutViewport(doc, lines[0..n], testCfg(), &cmds);
    var head_y: f32 = -1;
    for (cmds[0..count]) |c| {
        if (c.kind == .text_run and std.mem.eql(u8, c.text, "Blockquotes")) head_y = c.rect.y;
    }
    try std.testing.expect(head_y >= 0);
    // h3 margin_top = 17 * 1.3 * 2.5
    try std.testing.expectApproxEqAbs(head_y, y_bq.? + 17.0 * 1.3 * 2.5, 1.0);
}

test "regression: trailing whitespace terminates layout" {
    // Trailing spaces/tabs after text, headings, and closing hashes must
    // be trimmed, never spin: the trailing-trim slice drops the last byte.
    const doc = "<!-- foo -->   \nPara with trailing spaces   \n### Heading with trailing   \n## Closed ##   \n";
    var lines: [16]simd.Line = undefined;
    const n = scanDoc(doc, &lines);
    var cmds: [128]layout.DrawCommand = undefined;
    const count = layout.layoutViewport(doc, lines[0..n], testCfg(), &cmds);
    try std.testing.expect(count > 0);
    // Trimmed heading text keeps its slug (anchor still resolves).
    const y = layout.anchorScrollY(doc, lines[0..n], testCfg(), "heading-with-trailing");
    try std.testing.expect(y != null);
}

test "regression: exact slug wins over earlier fuzzy anchor match" {
    // `#code` must target "Code", not the earlier prefix match
    // "Code Blocks"; `#precode` still resolves to "Code Blocks".
    const doc =
        \\### Code Blocks
        \\
        \\Some code block docs here.
        \\
        \\### Code
        \\
        \\Some code span docs here.
    ;
    var lines: [16]simd.Line = undefined;
    const n = scanDoc(doc, &lines);
    const y_blocks = layout.anchorScrollY(doc, lines[0..n], testCfg(), "precode");
    const y_code = layout.anchorScrollY(doc, lines[0..n], testCfg(), "code");
    try std.testing.expect(y_blocks != null);
    try std.testing.expect(y_code != null);
    try std.testing.expect(y_code.? > y_blocks.?);

    // Both ys match rendered heading geometry (multi-word headings emit
    // per-word runs, so collect the "Code" runs in document order).
    var cmds: [128]layout.DrawCommand = undefined;
    const count = layout.layoutViewport(doc, lines[0..n], testCfg(), &cmds);
    var hy: [2]f32 = .{ -1, -1 };
    var hn: usize = 0;
    for (cmds[0..count]) |c| {
        if (c.kind == .text_run and std.mem.eql(u8, c.text, "Code") and hn < 2) {
            hy[hn] = c.rect.y;
            hn += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), hn);
    try std.testing.expectApproxEqAbs(hy[0], y_blocks.? + 17.0 * 1.3 * 2.5, 1.0);
    try std.testing.expectApproxEqAbs(hy[1], y_code.? + 17.0 * 1.3 * 2.5, 1.0);

    // Tiered resolution: `#blockquote` targets "Blockquotes", not the
    // earlier affix match "Block Elements"; `#link` targets "Links", not
    // the earlier subsequence match "Paragraphs and Line Breaks".
    const doc2 =
        \\## Block Elements
        \\
        \\### Paragraphs and Line Breaks
        \\
        \\### Blockquotes
        \\
        \\### Links
    ;
    var lines2: [16]simd.Line = undefined;
    const n2 = scanDoc(doc2, &lines2);
    const y_bq = layout.anchorScrollY(doc2, lines2[0..n2], testCfg(), "blockquote");
    const y_link = layout.anchorScrollY(doc2, lines2[0..n2], testCfg(), "link");
    const y_blk = layout.anchorScrollY(doc2, lines2[0..n2], testCfg(), "block");
    try std.testing.expect(y_bq != null and y_link != null and y_blk != null);
    try std.testing.expect(y_bq.? > y_blk.?);
    try std.testing.expect(y_link.? > y_bq.?);
}

test "regression: hanging indent parity for padded and lazy list items" {
    // Marker padding (`*   `, `1.  `) must not shift the first visual
    // line: every flowed line starts exactly at the item text column.
    const docs = [_][]const u8{
        "*   Lorem ipsum dolor sit amet, consectetuer adipiscing elit.\n    Aliquam hendrerit mi posuere lectus. Vestibulum enim wisi,\n    viverra nec, fringilla in, laoreet vitae, risus.\n",
        "*   Lorem ipsum dolor sit amet, consectetuer adipiscing elit.\nAliquam hendrerit mi posuere lectus. Vestibulum enim wisi,\nviverra nec, fringilla in, laoreet vitae, risus.\n",
        "1.  This is a list item with two paragraphs. Lorem ipsum dolor\n    sit amet, consectetuer adipiscing elit. Aliquam hendrerit\n    mi posuere lectus.\n",
    };
    for (docs) |doc| {
        var lines: [16]simd.Line = undefined;
        const n = scanDoc(doc, &lines);
        var cmds: [256]layout.DrawCommand = undefined;
        const count = layout.layoutViewport(doc, lines[0..n], testCfg(), &cmds);
        // Every visual line starts at the same x (marker runs skipped).
        var first_x: f32 = -1;
        var last_y: f32 = -1;
        for (cmds[0..count]) |c| {
            if (c.kind != .text_run) continue;
            // Skip marker adornments ("•", "1.", "1. " echo) first so
            // the marker's own line still contributes a reference x.
            var t = c.text;
            if (t.len > 0 and t[t.len - 1] == ' ') t = t[0 .. t.len - 1];
            if (std.mem.eql(u8, t, "•")) continue;
            var digits = t.len > 1 and
                (t[t.len - 1] == '.' or t[t.len - 1] == ')');
            var k: usize = 0;
            while (digits and k < t.len - 1) : (k += 1) {
                if (t[k] < '0' or t[k] > '9') digits = false;
            }
            if (digits) continue;
            if (c.rect.y == last_y) continue;
            last_y = c.rect.y;
            if (first_x < 0) {
                first_x = c.rect.x;
            } else {
                try std.testing.expectApproxEqAbs(first_x, c.rect.x, 0.5);
            }
        }
        try std.testing.expect(first_x >= 0);
    }
}

test "regression: checkpoints agree on continuation-heavy documents" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const chunk =
        \\# Chunk Title
        \\Lead paragraph first line here
        \\second line of the same paragraph here
        \\> Quote line one here
        \\lazy quote tail here
        \\* Bullet item one here
        \\lazy bullet tail here
        \\1. Ordered item one here
        \\1. Ordered item two here
        \\
    ;
    var rep: usize = 0;
    while (rep < 60) : (rep += 1) {
        buf.appendSlice(std.testing.allocator, chunk) catch unreachable;
    }
    const mem = buf.items;
    const lines = std.testing.allocator.alloc(simd.Line, 1200) catch unreachable;
    defer std.testing.allocator.free(lines);
    var fence = false;
    const line_count = simd.scanLines(mem, lines, &fence);

    var checkpoints: [64]layout.Checkpoint = undefined;
    var cp_count: usize = 0;
    const cfg = layout.ViewportConfig{ .window_width = 900.0, .window_height = 700.0, .scroll_y = 0.0 };
    _ = layout.computeDocumentHeightEx(mem, lines[0..line_count], cfg, &checkpoints, &cp_count);
    try std.testing.expect(cp_count > 0);

    const scrolls = [_]f32{ 0.0, 900.0, 2500.0, 9000.0 };
    for (scrolls) |s_y| {
        const cfg_plain = layout.ViewportConfig{ .window_width = 900.0, .window_height = 700.0, .scroll_y = s_y };
        const cfg_cp = layout.ViewportConfig{ .window_width = 900.0, .window_height = 700.0, .scroll_y = s_y, .checkpoints = checkpoints[0..cp_count] };
        var ca: [512]layout.DrawCommand = undefined;
        var cb: [512]layout.DrawCommand = undefined;
        const na = layout.layoutViewport(mem, lines[0..line_count], cfg_plain, &ca);
        const nb = layout.layoutViewport(mem, lines[0..line_count], cfg_cp, &cb);
        try std.testing.expectEqual(na, nb);
        for (ca[0..na], 0..) |c, k| {
            try std.testing.expectEqual(c.kind, cb[k].kind);
            try std.testing.expectApproxEqAbs(c.rect.x, cb[k].rect.x, 0.01);
            try std.testing.expectApproxEqAbs(c.rect.y, cb[k].rect.y, 0.1);
            try std.testing.expectEqualStrings(c.text, cb[k].text);
        }
    }
}



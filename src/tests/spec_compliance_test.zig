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



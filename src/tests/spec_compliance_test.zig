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

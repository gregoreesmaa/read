const std = @import("std");

/// Table-driven syntax tinting for fenced code blocks (issue #39).
///
/// Zero-dependency, zero-heap: the caller passes a stack buffer; tokenize
/// returns segments (byte ranges + class) into it. Single left-to-right
/// pass, no backtracking. Only viewport-visible lines are tokenized by the
/// renderer, preserving virtualized rendering.
///
/// Minimal cut, documented limits:
/// - Showcase languages only (zig, c, python, js, bash, diff), exact
///   case-sensitive match on the first info-string token. Anything else
///   (including missing info string) returns null and renders exactly as
///   today (single mono run).
/// - Per-line tokenization: a `/*` opened but not closed on the same line
///   tints to end-of-line; the next line starts fresh.
/// - Lines containing tabs or non-ASCII bytes return null (mono advance
///   math is byte-exact only for ASCII without tabs), rendering as today.
/// - More than MAX_SEGMENTS tokens on one line returns null (plain run),
///   bounding draw-command growth.

pub const Lang = enum {
    none,
    zig,
    c,
    python,
    js,
    bash,
    diff,
};

pub const Class = enum {
    plain,
    keyword,
    string,
    comment,
    number,
};

pub const Segment = struct {
    start: u32,
    end: u32,
    class: Class,
};

pub const MAX_SEGMENTS: usize = 32;

/// Language from a raw fence-start line (leading indent and trailing
/// whitespace tolerated). First info-string token, exact match.
pub fn langFromFenceLine(line: []const u8) Lang {
    var s = line;
    while (s.len > 0 and (s[0] == ' ' or s[0] == '\t' or s[0] == '\r' or s[0] == '\n')) : (s = s[1..]) {}
    while (s.len > 0 and (s[s.len - 1] == ' ' or s[s.len - 1] == '\t' or s[s.len - 1] == '\r' or s[s.len - 1] == '\n')) : (s = s[0 .. s.len - 1]) {}
    if (s.len < 3) return .none;
    const fc = s[0];
    if (fc != '`' and fc != '~') return .none;
    var p: usize = 0;
    while (p < s.len and s[p] == fc) : (p += 1) {}
    if (p < 3) return .none;
    while (p < s.len and (s[p] == ' ' or s[p] == '\t')) : (p += 1) {}
    const start = p;
    while (p < s.len and s[p] != ' ' and s[p] != '\t') : (p += 1) {}
    const token = s[start..p];
    if (token.len == 0) return .none;
    if (std.mem.eql(u8, token, "zig")) return .zig;
    if (std.mem.eql(u8, token, "c")) return .c;
    if (std.mem.eql(u8, token, "python")) return .python;
    if (std.mem.eql(u8, token, "js")) return .js;
    if (std.mem.eql(u8, token, "bash")) return .bash;
    if (std.mem.eql(u8, token, "diff")) return .diff;
    return .none;
}

const zig_keywords = [_][]const u8{
    "const", "var",    "fn",      "pub",      "return", "if",    "else",
    "while", "for",    "switch",  "break",    "continue", "defer",
    "errdefer", "try", "catch",   "orelse",   "and",    "or",    "struct",
    "enum",  "union",  "test",    "comptime", "inline", "noinline",
    "extern", "threadlocal", "usingnamespace", "asm",   "volatile",
    "unreachable", "null", "true", "false",   "undefined",
};

const c_keywords = [_][]const u8{
    "int",   "char",   "float",  "double", "void",   "long",   "short",
    "signed", "unsigned", "const", "static", "extern", "volatile",
    "register", "auto", "return", "if",     "else",   "while",  "for",
    "do",    "switch", "case",   "default", "break",  "continue",
    "goto",  "sizeof", "typedef", "struct", "union",  "enum",   "true",
    "false", "NULL",
};

const python_keywords = [_][]const u8{
    "def",  "return", "if",   "elif",  "else",  "while", "for",  "in",
    "not",  "and",    "or",   "is",    "None",  "True",  "False", "class",
    "import", "from", "as",   "pass",  "break", "continue", "lambda",
    "with", "try",    "except", "finally", "raise", "yield", "global",
    "assert", "del",  "async", "await",
};

const js_keywords = [_][]const u8{
    "const", "let",    "var",      "function", "return", "if",       "else",
    "while", "for",    "do",       "switch",   "case",   "default",  "break",
    "continue", "new", "delete",   "typeof",   "instanceof", "in",   "of",
    "try",   "catch",  "finally",  "throw",    "class",  "extends",  "import",
    "export", "from",  "default",  "async",    "await",  "this",     "null",
    "true",  "false",  "undefined",
};

const bash_keywords = [_][]const u8{
    "if",   "then", "else", "elif", "fi",   "for",  "while", "until",
    "do",   "done", "case", "esac", "in",   "function", "select",
    "time", "echo", "exit", "return", "local", "export", "true", "false",
};

fn keywordsFor(lang: Lang) []const []const u8 {
    return switch (lang) {
        .zig => &zig_keywords,
        .c => &c_keywords,
        .python => &python_keywords,
        .js => &js_keywords,
        .bash => &bash_keywords,
        .none, .diff => &.{},
    };
}

fn isKeyword(lang: Lang, word: []const u8) bool {
    for (keywordsFor(lang)) |kw| {
        if (word.len == kw.len and std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

const Tokenizer = struct {
    line: []const u8,
    out: []Segment,
    count: usize = 0,
    seg_start: usize = 0,
    seg_class: Class = .plain,

    fn pushRun(self: *Tokenizer, end: usize, class: Class) bool {
        // Close the open run at `end` and start a new one of `class`.
        // Same-class calls are no-ops (the trailing run is closed once by
        // finish). Returns false on overflow.
        if (class == self.seg_class) return true;
        if (end > self.seg_start) {
            if (self.count >= self.out.len) return false;
            self.out[self.count] = .{
                .start = @intCast(self.seg_start),
                .end = @intCast(end),
                .class = self.seg_class,
            };
            self.count += 1;
        }
        self.seg_start = end;
        self.seg_class = class;
        return true;
    }

    fn finish(self: *Tokenizer) bool {
        // Emit the still-open trailing run (pushRun only closes a run when
        // the class changes, so the tail would otherwise be lost).
        if (self.line.len > self.seg_start) {
            if (self.count >= self.out.len) return false;
            self.out[self.count] = .{
                .start = @intCast(self.seg_start),
                .end = @intCast(self.line.len),
                .class = self.seg_class,
            };
            self.count += 1;
        }
        return true;
    }

    fn segments(self: *Tokenizer) []Segment {
        return self.out[0..self.count];
    }
};

/// Tokenize one code line. Returns null when the line must render as a
/// plain run (unsupported language, tab/non-ASCII content, or segment
/// overflow). Otherwise returns segments covering the line; an empty
/// slice means an empty line.
pub fn tokenize(lang: Lang, line: []const u8, out: []Segment) ?[]Segment {
    if (lang == .none) return null;
    for (line) |c| {
        if (c == '\t' or c >= 0x80) return null;
    }
    if (lang == .diff) return tokenizeDiff(line, out);

    const line_comment_slash = lang == .zig or lang == .c or lang == .js;
    const line_comment_hash = lang == .python or lang == .bash;
    const block_comment = lang == .zig or lang == .c or lang == .js;
    const backtick = lang == .js;

    var t = Tokenizer{ .line = line, .out = out };
    var p: usize = 0;
    while (p < line.len) {
        const c = line[p];
        // Line comments.
        if (line_comment_slash and c == '/' and p + 1 < line.len and line[p + 1] == '/') {
            if (!t.pushRun(p, .comment)) return null;
            t.seg_class = .comment;
            p = line.len;
            break;
        }
        if (line_comment_hash and c == '#') {
            const hash_ok = if (lang == .bash)
                p == 0 or line[p - 1] == ' ' or line[p - 1] == '\t' or line[p - 1] == ';'
            else
                true;
            if (hash_ok) {
                if (!t.pushRun(p, .comment)) return null;
                t.seg_class = .comment;
                p = line.len;
                break;
            }
        }
        // Block comments (same-line close; unclosed tints to end-of-line).
        if (block_comment and c == '/' and p + 1 < line.len and line[p + 1] == '*') {
            if (!t.pushRun(p, .comment)) return null;
            t.seg_class = .comment;
            var q = p + 2;
            var closed = false;
            while (q + 1 < line.len) : (q += 1) {
                if (line[q] == '*' and line[q + 1] == '/') {
                    closed = true;
                    q += 2;
                    break;
                }
            }
            if (!t.pushRun(if (closed) q else line.len, .plain)) return null;
            t.seg_class = .plain;
            if (!closed) {
                p = line.len;
                break;
            }
            p = q;
            continue;
        }
        // Strings.
        const is_dq = c == '"';
        const is_sq = c == '\'';
        const is_bt = backtick and c == '`';
        if (is_dq or is_sq or is_bt) {
            // Bash single-quotes take no escapes; everything else does.
            const escapes = !(lang == .bash and is_sq);
            if (!t.pushRun(p, .string)) return null;
            t.seg_class = .string;
            var q = p + 1;
            var done = false;
            while (q < line.len) {
                if (escapes and line[q] == '\\' and q + 1 < line.len) {
                    q += 2;
                    continue;
                }
                if (line[q] == c) {
                    done = true;
                    q += 1;
                    break;
                }
                q += 1;
            }
            if (!t.pushRun(if (done) q else line.len, .plain)) return null;
            t.seg_class = .plain;
            if (!done) {
                p = line.len;
                break;
            }
            p = q;
            continue;
        }
        // Numbers: digit at a word start consumes alnum/underscore/dots
        // (covers 42, 3.14, 0xFF, 1_000).
        if (isDigit(c) and (p == 0 or !isWordChar(line[p - 1]))) {
            if (!t.pushRun(p, .number)) return null;
            t.seg_class = .number;
            var q = p + 1;
            while (q < line.len and (isWordChar(line[q]) or line[q] == '.')) : (q += 1) {}
            if (!t.pushRun(q, .plain)) return null;
            t.seg_class = .plain;
            p = q;
            continue;
        }
        // Words: keyword lookup, else plain.
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_') {
            if (p == 0 or !isWordChar(line[p - 1])) {
                var q = p + 1;
                while (q < line.len and isWordChar(line[q])) : (q += 1) {}
                if (isKeyword(lang, line[p..q])) {
                    if (!t.pushRun(p, .keyword)) return null;
                    t.seg_class = .keyword;
                    if (!t.pushRun(q, .plain)) return null;
                    t.seg_class = .plain;
                    p = q;
                    continue;
                }
            }
        }
        p += 1;
    }
    if (!t.finish()) return null;
    return t.segments();
}

/// Diff tinting by first character: `+` additions, `-` removals, `@@`
/// hunk headers, file headers muted. No keyword table.
fn tokenizeDiff(line: []const u8, out: []Segment) ?[]Segment {
    if (out.len == 0) return null;
    if (line.len == 0) return out[0..0];
    const class: Class = if (line.len >= 2 and line[0] == '@' and line[1] == '@')
        .keyword
    else if (line[0] == '+')
        // `+++` file headers read as muted metadata, not additions.
        (if (line.len >= 3 and line[1] == '+' and line[2] == '+') .comment else .string)
    else if (line[0] == '-')
        (if (line.len >= 3 and line[1] == '-' and line[2] == '-') .comment else .number)
    else if (std.mem.startsWith(u8, line, "diff ") or std.mem.startsWith(u8, line, "index "))
        .comment
    else
        .plain;
    out[0] = .{ .start = 0, .end = @intCast(line.len), .class = class };
    return out[0..1];
}

test "fence info string language detection" {
    try std.testing.expectEqual(Lang.zig, langFromFenceLine("```zig"));
    try std.testing.expectEqual(Lang.python, langFromFenceLine("   ```python extra"));
    try std.testing.expectEqual(Lang.js, langFromFenceLine("~~~js"));
    try std.testing.expectEqual(Lang.bash, langFromFenceLine("```bash  "));
    try std.testing.expectEqual(Lang.c, langFromFenceLine("```c"));
    try std.testing.expectEqual(Lang.diff, langFromFenceLine("```diff"));
    try std.testing.expectEqual(Lang.none, langFromFenceLine("```"));
    try std.testing.expectEqual(Lang.none, langFromFenceLine("```rust"));
    try std.testing.expectEqual(Lang.none, langFromFenceLine("```ZIG"));
    try std.testing.expectEqual(Lang.none, langFromFenceLine("not a fence"));
    try std.testing.expectEqual(Lang.none, langFromFenceLine("```javascript"));
}

fn classAt(segs: []Segment, idx: usize) Class {
    return segs[idx].class;
}

fn textOf(line: []const u8, seg: Segment) []const u8 {
    return line[seg.start..seg.end];
}

test "zig keyword string comment number" {
    const line = "const x: i32 = 42; // answer";
    var buf: [MAX_SEGMENTS]Segment = undefined;
    const segs = tokenize(.zig, line, &buf).?;
    // First segment is the keyword "const".
    try std.testing.expectEqualStrings("const", textOf(line, segs[0]));
    try std.testing.expectEqual(Class.keyword, classAt(segs, 0));
    // Some segment is the number 42, last is the comment.
    var saw_number = false;
    for (segs) |sg| {
        if (std.mem.eql(u8, textOf(line, sg), "42"))
            saw_number = sg.class == .number;
        // i32 must NOT be a keyword.
        if (std.mem.eql(u8, textOf(line, sg), "i32"))
            try std.testing.expectEqual(Class.plain, sg.class);
    }
    try std.testing.expect(saw_number);
    try std.testing.expectEqual(Class.comment, classAt(segs, segs.len - 1));
    try std.testing.expectEqualStrings("// answer", textOf(line, segs[segs.len - 1]));
}

test "strings with escapes and block comments" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    {
        const line = "const s = \"a\\\"b\"; /* done */ const t = 1;";
        const segs = tokenize(.zig, line, &buf).?;
        var saw_string = false;
        var saw_block = false;
        var saw_second_const = false;
        for (segs) |sg| {
            const t = textOf(line, sg);
            if (std.mem.eql(u8, t, "\"a\\\"b\"")) saw_string = sg.class == .string;
            if (std.mem.eql(u8, t, "/* done */")) saw_block = sg.class == .comment;
            if (std.mem.eql(u8, t, "const") and sg.start > 0) saw_second_const = sg.class == .keyword;
        }
        try std.testing.expect(saw_string);
        try std.testing.expect(saw_block);
        try std.testing.expect(saw_second_const);
    }
    {
        // Unclosed block comment tints to end-of-line.
        const line = "const x = 1; /* trailing";
        const segs = tokenize(.c, line, &buf).?;
        try std.testing.expectEqual(Class.comment, classAt(segs, segs.len - 1));
        try std.testing.expectEqualStrings("/* trailing", textOf(line, segs[segs.len - 1]));
    }
}

test "python and bash hash comments" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    {
        const line = "def f(): # hello";
        const segs = tokenize(.python, line, &buf).?;
        try std.testing.expectEqual(Class.keyword, classAt(segs, 0));
        try std.testing.expectEqualStrings("def", textOf(line, segs[0]));
        try std.testing.expectEqual(Class.comment, classAt(segs, segs.len - 1));
    }
    {
        // Bash # needs line-start/space/semicolon; the $# stays out of
        // any comment: exactly one comment segment, the trailing one.
        const line = "echo $#; # count";
        const segs = tokenize(.bash, line, &buf).?;
        try std.testing.expectEqual(Class.keyword, classAt(segs, 0));
        var comment_count: usize = 0;
        for (segs) |sg| {
            if (sg.class == .comment) comment_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), comment_count);
        try std.testing.expectEqual(Class.comment, classAt(segs, segs.len - 1));
        try std.testing.expectEqualStrings("# count", textOf(line, segs[segs.len - 1]));
    }
    {
        // Bash single-quotes take no escapes.
        const line = "echo 'a\\nb'";
        const segs = tokenize(.bash, line, &buf).?;
        var saw = false;
        for (segs) |sg| {
            if (std.mem.eql(u8, textOf(line, sg), "'a\\nb'")) saw = sg.class == .string;
        }
        try std.testing.expect(saw);
    }
}

test "js backtick strings and diff lines" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    {
        const line = "const s = `hi ${x}`; // done";
        const segs = tokenize(.js, line, &buf).?;
        var saw_tick = false;
        for (segs) |sg| {
            if (std.mem.eql(u8, textOf(line, sg), "`hi ${x}`")) saw_tick = sg.class == .string;
        }
        try std.testing.expect(saw_tick);
        try std.testing.expectEqual(Class.comment, classAt(segs, segs.len - 1));
    }
    {
        const added = tokenize(.diff, "+const x = 1;", &buf).?;
        try std.testing.expectEqual(Class.string, classAt(added, 0));
        const removed = tokenize(.diff, "-const x = 1;", &buf).?;
        try std.testing.expectEqual(Class.number, classAt(removed, 0));
        const hunk = tokenize(.diff, "@@ -1,2 +3,4 @@", &buf).?;
        try std.testing.expectEqual(Class.keyword, classAt(hunk, 0));
        const header = tokenize(.diff, "--- a/f.md", &buf).?;
        try std.testing.expectEqual(Class.comment, classAt(header, 0));
        const ctx = tokenize(.diff, " context", &buf).?;
        try std.testing.expectEqual(Class.plain, classAt(ctx, 0));
    }
}

test "plain fallback cases" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    // Unknown language.
    try std.testing.expect(tokenize(.none, "const x = 1;", &buf) == null);
    // Tab or non-ASCII bails to the plain run.
    try std.testing.expect(tokenize(.zig, "const\tx = 1;", &buf) == null);
    try std.testing.expect(tokenize(.zig, "const x = \"héllo\";", &buf) == null);
    // Segment overflow bails rather than truncating colors.
    var long: [512]u8 = undefined;
    const unit = "a\"b\" ";
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        @memcpy(long[i * unit.len ..][0..unit.len], unit);
    }
    try std.testing.expect(tokenize(.zig, long[0 .. 40 * unit.len], &buf) == null);
    // Empty line yields no segments (renderer emits the plain run).
    const empty = tokenize(.zig, "", &buf).?;
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

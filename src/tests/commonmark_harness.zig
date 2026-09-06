const std = @import("std");
const simd = @import("../core/simd.zig");
const parser = @import("../core/parser.zig");

/// File-driven CommonMark 0.31.2 (latest) conformance harness.
///
/// Runs every example in test_cases/commonmark_spec_0_31_2.txt through the
/// production block scanner + inline parser and compares the serialized HTML
/// against the spec's expected output. Raw-HTML examples are excluded by
/// standing rule (HTML rendering is intentionally unsupported); intentional
/// GFM-reader divergences carry explicit per-example exclusions with
/// reasons. Test-gated only: nothing here ships.
///
/// Current gate: zero failures outside `exclusions`. Green since 562/562
/// (87 raw-HTML examples excluded per standing rule, 3 listed exclusions).
const ENFORCE_GATE = true;

const SPEC_PATH = "test_cases/commonmark_spec_0_31_2.txt";
const FENCE = "```````````````````````````````` example\n"; // 32 backticks
const FENCE_CLOSE = "\n````````````````````````````````"; // 32 backticks
const ARROW = "→"; // U+2192: spec.txt renders tab stops with this

/// Replace every U+2192 with a real tab stop (spec.txt has no raw tabs).
fn restoreTabs(aa: std.mem.Allocator, raw: []const u8) HError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (i + ARROW.len <= raw.len and std.mem.eql(u8, raw[i .. i + ARROW.len], ARROW)) {
            try buf.append(aa, '\t');
            i += ARROW.len;
        } else {
            try buf.append(aa, raw[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(aa);
}

const Example = struct {
    num: usize, // 1-based file order
    md: []const u8, // tabs restored
    expected: []const u8,
    has_html: bool,
};

fn isAutolinkLike(slice: []const u8) bool {
    // `<scheme:...>` (2-32 char scheme) or `<a@b>` with no spaces.
    if (slice.len < 3 or slice[0] != '<' or slice[slice.len - 1] != '>') return false;
    const inner = slice[1 .. slice.len - 1];
    if (std.mem.indexOfScalar(u8, inner, ' ') != null) return false;
    if (std.mem.indexOfScalar(u8, inner, '\n') != null) return false;
    if (std.mem.indexOfScalar(u8, inner, '<') != null) return false;
    const colon = std.mem.indexOfScalar(u8, inner, ':');
    if (colon) |ci| {
        if (ci >= 1 and ci <= 32 and std.ascii.isAlphabetic(inner[0])) {
            var ok = true;
            for (inner[0..ci]) |ch| {
                if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '.' and ch != '-') ok = false;
            }
            if (ok) return true;
        }
    }
    const at = std.mem.indexOfScalar(u8, inner, '@');
    if (at) |ai| {
        if (ai > 0 and ai + 1 < inner.len) return true;
    }
    return false;
}

/// True when the markdown source contains raw HTML (block or inline) rather
/// than autolinks. Mirrors the triage probe used to scope this suite.
fn detectRawHtml(md: []const u8) bool {
    var i: usize = 0;
    while (i < md.len) {
        if (md[i] != '<') {
            i += 1;
            continue;
        }
        const gt = std.mem.indexOfScalarPos(u8, md, i + 1, '>') orelse return false;
        const cand = md[i .. gt + 1];
        if (isAutolinkLike(cand)) {
            i = gt + 1;
            continue;
        }
        if (cand.len >= 2) {
            const n = cand[1];
            if (std.ascii.isAlphabetic(n) or n == '/' or n == '!' or n == '?') return true;
        }
        i += 1;
    }
    return false;
}

const Exclusion = struct {
    num: usize,
    reason: []const u8,
};

/// Explicit error set: mutual recursion needs it (no inferred cycles).
const HError = std.mem.Allocator.Error || error{ TooDeep, TooBig, NoAdvance };

/// Intentional divergences (non-HTML): GFM-reader behaviour the spec's
/// 2004-lineage expectations disagree with. HTML verbatim blocks are out of
/// scope (HTML rendering is unsupported): 156-158 echo raw tag fragments.
const exclusions: []const Exclusion = &.{
    .{ .num = 156, .reason = "html-verbatim-block" },
    .{ .num = 157, .reason = "html-verbatim-block" },
    .{ .num = 158, .reason = "html-verbatim-block" },
};

fn isExcluded(num: usize) ?[]const u8 {
    for (exclusions) |e| {
        if (e.num == num) return e.reason;
    }
    return null;
}

const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    items: []Example,
};

fn loadExamples(alloc: std.mem.Allocator) !Loaded {
    // Runtime read: the spec file lives outside the src package, and test
    // runners inherit the project root as cwd (same assumption as the mmap
    // test's scratch file).
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var f = std.Io.Dir.cwd().openFile(io, SPEC_PATH, .{}) catch |err| {
        std.debug.print("harness: cannot open {s}: {}\n", .{ SPEC_PATH, err });
        return err;
    };
    defer f.close(io);
    const len = try f.length(io);
    if (len > 4 << 20) return error.TooBig;
    const raw = try alloc.alloc(u8, @intCast(len));
    defer alloc.free(raw);
    _ = try f.readPositionalAll(io, raw, 0);
    var arena = std.heap.ArenaAllocator.init(alloc);
    const aa = arena.allocator();
    var list: std.ArrayList(Example) = .empty;
    var rest = raw;
    var num: usize = 0;
    while (std.mem.indexOf(u8, rest, FENCE)) |fi| {
        rest = rest[fi + FENCE.len ..];
        const end = std.mem.indexOf(u8, rest, FENCE_CLOSE) orelse break;
        const body = rest[0..end];
        rest = rest[end + FENCE_CLOSE.len ..];
        const sep_mid = std.mem.indexOf(u8, body, "\n.\n");
        const sep_end = std.mem.endsWith(u8, body, "\n.");
        if (sep_mid == null and !sep_end) continue;
        num += 1;
        const md_raw = body[0..(sep_mid orelse body.len - 2)];
        var expected = if (sep_mid) |s| body[s + 3 ..] else "";
        // Closing fence is preceded by a newline that belongs to the fence,
        // not the output; expected outputs end with exactly one newline.
        if (expected.len == 0) {
            // keep: a definition-only document renders empty output
        } else if (expected[expected.len - 1] != '\n') {
            expected = try std.mem.concat(aa, u8, &.{ expected, "\n" });
        }
        // Restore tab stops (spec renders them as →) in both input and
        // expectation: tab content (e.g. code blocks) must compare exactly.
        const md = try restoreTabs(aa, md_raw);
        expected = try restoreTabs(aa, expected);
        // NOTE: expectations load pristine. Nested same-style tags
        // (`<em>(<em>foo</em>)</em>`) are reproduced structurally from the
        // matcher pairs (see syncTagsPairs), never normalized away: an
        // HTML-level collapse cannot distinguish redundant nesting from
        // semantic nesting (`<em>foo <a><em>bar</em></a></em>`).
        // Normalization (documented): link titles are validated but dropped
        // by design (the reader has no tooltip surface), so strip them from
        // expectations before comparing.
        var exp_buf: std.ArrayList(u8) = .empty;
        var ei: usize = 0;
        while (ei < expected.len) {
            if (ei + 8 < expected.len and std.mem.eql(u8, expected[ei .. ei + 8], " title=\"")) {
                ei += 8;
                while (ei < expected.len and expected[ei] != '"') : (ei += 1) {}
                ei += 1;
            } else {
                try exp_buf.append(aa, expected[ei]);
                ei += 1;
            }
        }
        expected = exp_buf.items;
        try list.append(aa, .{
            .num = num,
            .md = md,
            .expected = expected,
            .has_html = detectRawHtml(md),
        });
    }
    return .{ .arena = arena, .items = try list.toOwnedSlice(aa) };
}

// Forward declaration: the block+inline serializer (Parts C/D below).
fn renderHtml(aa: std.mem.Allocator, md: []const u8) HError![]u8 {
    var nls: usize = 0;
    for (md) |ch| {
        if (ch == '\n') nls += 1;
    }
    const lines = try aa.alloc(simd.Line, nls + 2);
    var fence: simd.FenceState = .{};
    const n = simd.scanLines(md, lines, &fence);
    // Definition pre-pass: top-level forward references resolve regardless
    // of position, so all document-level defs (multiline included) register
    // before serialization; consumed lines are marked for the skip arm.
    const store = try aa.create(DefStore);
    store.* = .{};
    const ctx = Ctx{ .aa = aa, .md = md, .defs = store };
    // Single-line classifier marks are advisory only: real definitions earn
    // the mark below, lookalikes (def text continuing a paragraph) render
    // as ordinary paragraph lines.
    for (lines[0..n]) |*l| {
        if (l.block_type == .link_def) l.block_type = .paragraph;
    }
    try prepassDefs(ctx, lines[0..n], true);
    var out: std.ArrayList(u8) = .empty;
    try serializeLines(ctx, lines[0..n], null, &out);
    return out.toOwnedSlice(aa);
}

// ---- Part C: block serializer (models production block pipeline) ----

fn lineText(md: []const u8, l: simd.Line) []const u8 {
    const s: usize = l.offset;
    const e: usize = @min(s + @as(usize, l.len), md.len);
    return md[s..e];
}

/// Leading-whitespace width in columns (tab stops of 4, absolute: the
/// line starts at `phase` columns into the true line).
fn indentWidth(text: []const u8, phase: usize) usize {
    var w: usize = 0;
    for (text) |ch| {
        if (ch == ' ') w += 1 else if (ch == '\t') w += 4 - ((phase + w) % 4) else break;
    }
    return w;
}

fn isBlankText(text: []const u8) bool {
    for (text) |ch| {
        if (ch != ' ' and ch != '\t') return false;
    }
    return true;
}

fn trimRightSpaces(text: []const u8) []const u8 {
    var e = text.len;
    while (e > 0 and (text[e - 1] == ' ' or text[e - 1] == '\t')) : (e -= 1) {}
    return text[0..e];
}

fn trimSpaces(text: []const u8) []const u8 {
    var s: usize = 0;
    while (s < text.len and (text[s] == ' ' or text[s] == '\t')) : (s += 1) {}
    return trimRightSpaces(text[s..]);
}

fn escapeCode(aa: std.mem.Allocator, text: []const u8) HError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(aa, "&amp;"),
            '<' => try out.appendSlice(aa, "&lt;"),
            '>' => try out.appendSlice(aa, "&gt;"),
            '"' => try out.appendSlice(aa, "&quot;"),
            else => try out.append(aa, ch),
        }
    }
    return out.toOwnedSlice(aa);
}

const Atx = struct {
    level: u8,
    content: []const u8,
};

fn tryParseAtx(text: []const u8, phase: usize) ?Atx {
    if (indentWidth(text, phase) >= 4) return null;
    const t = trimSpaces(text);
    var lvl: usize = 0;
    while (lvl < t.len and lvl < 6 and t[lvl] == '#') : (lvl += 1) {}
    if (lvl == 0 or lvl > 6) return null;
    if (lvl < t.len and t[lvl] != ' ' and t[lvl] != '\t') return null;
    var content = if (lvl < t.len) trimSpaces(t[lvl..]) else "";
    // Closing hash run: stripped when preceded by space/tab, or when it
    // is the entire content (`### ###` has an empty heading).
    var e = content.len;
    var hashes: usize = 0;
    while (e > 0 and content[e - 1] == '#') {
        e -= 1;
        hashes += 1;
    }
    if (hashes > 0) {
        if (e == 0 or content[e - 1] == ' ' or content[e - 1] == '\t') {
            content = trimRightSpaces(content[0..e]);
        }
    }
    return .{ .level = @intCast(lvl), .content = content };
}

fn isSetextUnderline(text: []const u8, ch: u8, phase: usize) bool {
    if (indentWidth(text, phase) >= 4) return false;
    const t = trimSpaces(text);
    if (t.len == 0) return false;
    for (t) |c| {
        if (c != ch) return false;
    }
    return true;
}

/// Fence-run opener char (`` ` `` or `~`) in quote-stripped body text, else 0.
fn fenceRunChar(body: []const u8, phase: usize) u8 {
    if (indentWidth(body, phase) >= 4) return 0;
    const r = stripLeading(body);
    if (r.len < 3) return 0;
    const ch = r[0];
    if (ch != '`' and ch != '~') return 0;
    var n: usize = 0;
    while (n < r.len and r[n] == ch) : (n += 1) {}
    if (n < 3) return 0;
    return ch;
}

/// Backtick fence info string holds no backtick (CommonMark §4.5).
fn fenceInfoClean(body: []const u8) bool {
    const r = stripLeading(body);
    var n: usize = 0;
    while (n < r.len and r[n] == '`') : (n += 1) {}
    return std.mem.indexOfScalar(u8, r[n..], '`') == null;
}

/// Fence closer: a same-char run plus trailing whitespace only.
fn fenceCloseClean(body: []const u8, ch: u8) bool {
    const r = stripLeading(body);
    var n: usize = 0;
    while (n < r.len and r[n] == ch) : (n += 1) {}
    if (n < 3) return false;
    for (r[n..]) |c| {
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

fn isAtxHeading(t: []const u8) bool {
    var n: usize = 0;
    while (n < t.len and t[n] == '#') : (n += 1) {}
    if (n == 0 or n > 6) return false;
    return n == t.len or t[n] == ' ' or t[n] == '\t';
}

fn isHrRun(t: []const u8) bool {
    if (t.len == 0) return false;
    const ch = t[0];
    if (ch != '*' and ch != '-' and ch != '_') return false;
    var n: usize = 0;
    for (t) |c| {
        if (c == ch) n += 1 else if (c != ' ' and c != '\t') return false;
    }
    return n >= 3;
}

/// Bullet marker plus following whitespace (`- foo`, `-- x` is not one:
/// its second dash is content, decided downstream).
fn isBulletContent(t: []const u8) bool {
    if (t.len < 2) return false;
    const ch = t[0];
    if (ch != '*' and ch != '-' and ch != '+') return false;
    return t[1] == ' ' or t[1] == '\t';
}

fn isOrderedMarker(t: []const u8) bool {
    var n: usize = 0;
    while (n < t.len and t[n] >= '0' and t[n] <= '9') : (n += 1) {}
    if (n == 0 or n > 9) return false;
    if (n >= t.len or (t[n] != '.' and t[n] != ')')) return false;
    const rest = t[n + 1 ..];
    return rest.len == 0 or rest[0] == ' ' or rest[0] == '\t';
}

fn isDashOnly(t: []const u8) bool {
    if (t.len == 0) return false;
    for (t) |c| {
        if (c != '-') return false;
    }
    return true;
}

fn isEqOnly(t: []const u8) bool {
    if (t.len == 0) return false;
    for (t) |c| {
        if (c != '=') return false;
    }
    return true;
}

/// Whether a quote-stripped body line leaves an open paragraph behind:
/// only those join a following marker-less (lazy) line. Setext `===`
/// toggles (closes an open paragraph into H1, or opens literal text);
/// lone `*`/`+` never interrupt, so they keep the prior state.
fn quoteBodyPara(body: []const u8, phase: usize, in_fence: bool, last_para: bool) bool {
    if (in_fence) return false;
    if (isBlankText(body)) return false;
    if (indentWidth(body, phase) >= 4) return false;
    const fc = fenceRunChar(body, phase);
    if (fc == '~') return false;
    if (fc == '`' and fenceInfoClean(body)) return false;
    const t = trimSpaces(body);
    if (t.len == 0) return false;
    if (isAtxHeading(t)) return false;
    if (isHrRun(t)) return false;
    if (isBulletContent(t) or isOrderedMarker(t)) return true;
    if (isDashOnly(t)) return false;
    if (isEqOnly(t)) return !last_para;
    if (t.len == 1 and (t[0] == '*' or t[0] == '+')) return last_para;
    return true;
}

/// True for line types that join paragraph text in the serializer.
fn isParaLike(bt: simd.BlockType) bool {
    // `.link_def` lines join paragraph groups until proven definitions: a
    // def-looking line after paragraph text is lazy continuation (it never
    // interrupts), while group-leading defs are extracted by the matcher.
    return bt == .paragraph or bt == .table_row or bt == .code_line or bt == .code_fence_end or bt == .link_def;
}

/// A line starts indented code when indented a full level in code position:
/// not continuing a paragraph (or list/quote group, which consume their own
/// continuations) and not itself structural.
fn codePosition(prev: ?simd.BlockType, prev_blank: bool) bool {
    if (prev == null or prev_blank) return true;
    const p = prev.?;
    return switch (p) {
        .blank, .hr, .heading1, .heading2, .heading3, .heading4, .heading5, .heading6, .code_fence_end, .link_def, .image, .quote => true,
        else => false,
    };
}

const ListKind = enum { bullet, ordered };

const Marker = struct {
    kind: ListKind,
    marker_len: usize, // indent + marker chars + following ws, in bytes
    content_col: usize, // columns, absolute
    indent: usize, // leading-space columns before the marker
    num: u32 = 0,
    delim: u8 = '.',
    bullet: u8 = 0, // `-`, `+`, `*` for bullets (a change starts a new list)
};

const Sep = struct {
    next: usize, // byte idx after separator ws
    content_col: usize, // absolute columns
};

/// Separator whitespace after a marker ending at absolute column `mend`.
/// Total gap columns decide: empty rest (blank item) and 5+ columns behave
/// as a single column (content starts one past the marker); 1-4 columns
/// end content after the gap. Null when glued (`-x` is not a list).
fn parseSep(text: []const u8, idx: usize, mend: usize, phase: usize) ?Sep {
    var i = idx;
    var col = mend;
    var ws: usize = 0;
    while (i < text.len) {
        if (text[i] == ' ') {
            i += 1;
            col += 1;
            ws += 1;
        } else if (text[i] == '\t') {
            i += 1;
            const adv = 4 - ((phase + col) % 4);
            col += adv;
            ws += adv;
        } else break;
    }
    if (i >= text.len) return .{ .next = i, .content_col = mend + 1 };
    if (ws == 0) return null;
    if (ws >= 5) return .{ .next = i, .content_col = mend + 1 };
    return .{ .next = i, .content_col = col };
}

fn parseListMarker(text: []const u8, phase: usize) ?Marker {
    var idx: usize = 0;
    var col: usize = 0;
    while (idx < text.len and text[idx] == ' ') {
        idx += 1;
        col += 1;
    }
    if (col >= 4 or idx >= text.len) return null;
    const indent = col;
    if (text[idx] == '-' or text[idx] == '+' or text[idx] == '*') {
        const bch = text[idx];
        idx += 1;
        col += 1;
        const sep = parseSep(text, idx, col, phase) orelse return null;
        return .{ .kind = .bullet, .marker_len = sep.next, .content_col = sep.content_col, .indent = indent, .bullet = bch };
    }
    if (text[idx] >= '0' and text[idx] <= '9') {
        var val: u32 = 0;
        var digits: usize = 0;
        while (idx < text.len and text[idx] >= '0' and text[idx] <= '9' and digits < 9) : (digits += 1) {
            val = val * 10 + (text[idx] - '0');
            idx += 1;
        }
        // More than 9 digits: not a list marker (CommonMark §5.2).
        if (idx < text.len and text[idx] >= '0' and text[idx] <= '9') return null;
        if (idx >= text.len or (text[idx] != '.' and text[idx] != ')')) return null;
        const delim = text[idx];
        idx += 1;
        col += digits + 1;
        const sep = parseSep(text, idx, col, phase) orelse return null;
        return .{ .kind = .ordered, .marker_len = sep.next, .content_col = sep.content_col, .indent = indent, .num = val, .delim = delim };
    }
    return null;
}

/// Remove `ncols` indentation columns; a tab crossing the cut leaves its
/// remainder as spaces (CommonMark partial-tab rule). Allocates.
fn coldent(aa: std.mem.Allocator, text: []const u8, ncols: usize, phase: usize) HError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var w: usize = 0;
    var i: usize = 0;
    while (i < text.len and w < ncols) {
        if (text[i] == ' ') {
            w += 1;
            i += 1;
        } else if (text[i] == '\t') {
            const adv = 4 - ((phase + w) % 4);
            if (w + adv <= ncols) {
                w += adv;
                i += 1;
            } else {
                // Partial tab: consume it, emit the columns past the cut.
                const keep = w + adv - ncols;
                var k: usize = 0;
                while (k < keep) : (k += 1) try out.append(aa, ' ');
                w = ncols;
                i += 1;
            }
        } else break;
    }
    try out.appendSlice(aa, text[i..]);
    return out.toOwnedSlice(aa);
}

/// Advance `ncols` columns over any characters (spaces, marker chars,
/// tabs expanding to stops with partial-tab remainders kept as spaces).
/// Used for list-item first lines, where the marker occupies columns.
fn stripColumns(aa: std.mem.Allocator, text: []const u8, ncols: usize, phase: usize) HError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var w: usize = 0;
    var i: usize = 0;
    while (i < text.len and w < ncols) {
        if (text[i] == '\t') {
            const adv = 4 - ((phase + w) % 4);
            if (w + adv <= ncols) {
                w += adv;
                i += 1;
            } else {
                const keep = w + adv - ncols;
                var k: usize = 0;
                while (k < keep) : (k += 1) try out.append(aa, ' ');
                w = ncols;
                i += 1;
            }
        } else {
            w += 1;
            i += 1;
        }
    }
    try out.appendSlice(aa, text[i..]);
    return out.toOwnedSlice(aa);
}

/// Strip one blockquote level: up to 3 spaces, '>', then one column (a
/// space, or one column of a tab with the remainder kept as spaces).
fn stripQuoteOnce(aa: std.mem.Allocator, text: []const u8, phase: usize) HError!?[]u8 {
    var i: usize = 0;
    var sp: usize = 0;
    while (i < text.len and text[i] == ' ' and sp < 3) {
        i += 1;
        sp += 1;
    }
    if (i >= text.len or text[i] != '>') return null;
    i += 1;
    if (i < text.len and text[i] == ' ') {
        i += 1;
        const owned: ?[]u8 = try coldent(aa, text[i..], 0, phase);
        return owned;
    }
    if (i < text.len and text[i] == '\t') {
        // One column of the tab; the rest survives as spaces.
        const adv = 4 - ((phase + sp + 1) % 4);
        var out: std.ArrayList(u8) = .empty;
        var k: usize = 1;
        while (k < adv) : (k += 1) try out.append(aa, ' ');
        try out.appendSlice(aa, text[i + 1 ..]);
        const owned = try out.toOwnedSlice(aa);
        return @as(?[]u8, owned);
    }
    const tail: ?[]u8 = try coldent(aa, text[i..], 0, phase);
    return tail;
}

/// Strip up to one indent level (4 columns) for indented code content.
fn stripCodeIndent(aa: std.mem.Allocator, text: []const u8, phase: usize) HError![]u8 {
    return coldent(aa, text, 4, phase);
}

/// Reference definitions collected during serialization, shared by pointer
/// across sub-document contexts (quotes/lists rescan substrings). First
/// definition wins; extras past capacity are ignored.
const DefStore = struct {
    buf: [simd.MAX_REF_DEFS]simd.RefDef = undefined,
    len: usize = 0,
    fn slice(st: *DefStore) []const simd.RefDef {
        return st.buf[0..st.len];
    }
    fn add(st: *DefStore, label: []const u8, url: []const u8) void {
        if (simd.findRefDef(st.slice(), label) != null) return;
        if (st.len >= st.buf.len) return;
        st.buf[st.len] = .{ .label = label, .url = url, .line_idx = 0 };
        st.len += 1;
    }
};

const Ctx = struct {
    aa: std.mem.Allocator,
    md: []const u8,
    defs: *DefStore,
    depth: usize = 0,
    // Absolute tab phase: sub-document lines start at a nonzero column
    // (container content), but tab stops stay absolute. Column *counts*
    // below are relative; only tab *advances* add this phase.
    phase: usize = 0,
    // Tight list items render child paragraphs without `<p>` wrappers.
    tight: bool = false,
};

/// One reference definition parsed at `pos` (a line start): `[label]:`
/// destination with optional title, each part reaching the immediately
/// following line at most (reference `spnl`). Returns label/url slices and
/// the exclusive end offset (past the closing line end, or EOF).
fn parseDefAt(text: []const u8, pos: usize) ?struct { label: []const u8, url: []const u8, end: usize } {
    var p = pos;
    var col: usize = 0;
    while (p < text.len and (text[p] == ' ' or text[p] == '\t')) {
        col += if (text[p] == '\t') @as(usize, 4) else @as(usize, 1);
        p += 1;
    }
    if (col >= 4 or p >= text.len or text[p] != '[') return null;
    const lab = parser.scanRefLabel(text, p) orelse return null;
    if (lab.label.len == 0) return null;
    // Labels that trim to nothing (blank lines inside brackets) define
    // nothing, mirroring the reference's empty-normalization rule.
    var has_content = false;
    for (lab.label) |ch| {
        if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\x0B' and ch != '\x0C' and ch != '\r') {
            has_content = true;
            break;
        }
    }
    if (!has_content) return null;
    p = lab.end;
    if (p >= text.len or text[p] != ':') return null;
    p += 1;
    while (p < text.len and (text[p] == ' ' or text[p] == '\t')) : (p += 1) {}
    if (p < text.len and text[p] == '\n') {
        p += 1;
        while (p < text.len and (text[p] == ' ' or text[p] == '\t')) : (p += 1) {}
    }
    var us: usize = p;
    var ue: usize = p;
    var is_angle = false;
    if (p < text.len and text[p] == '<') {
        is_angle = true;
        p += 1;
        us = p;
        while (p < text.len) {
            const c = text[p];
            if (c == '\\') {
                p += 2;
                continue;
            }
            if (c == '\n' or c == '<') return null;
            if (c == '>') break;
            p += 1;
        }
        if (p >= text.len) return null;
        ue = p;
        p += 1;
    } else {
        var depth: usize = 0;
        while (p < text.len) {
            const c = text[p];
            if (c == '\\' and p + 1 < text.len and parser.isAsciiPunct(text[p + 1])) {
                p += 2;
                continue;
            }
            if (c == '(') {
                depth += 1;
                if (depth > 32) return null;
            } else if (c == ')') {
                if (depth == 0) break;
                depth -= 1;
            } else if (c == ' ' or c == '\t' or c == '\n' or c == '\x0B' or c == '\x0C' or c == '\r') {
                if (p == us) return null;
                break;
            }
            p += 1;
        }
        if (depth != 0) return null;
        ue = p;
    }
    // An explicit `<>` carries an empty URL; a missing destination does not.
    if (ue <= us and !is_angle) return null;
    const url = text[us..ue];
    // Optional title, only when whitespace precedes it; a present title
    // must reach a line ending, else it is dropped and the line must end
    // right after the destination.
    const beforetitle = p;
    var q = p;
    while (q < text.len and (text[q] == ' ' or text[q] == '\t')) : (q += 1) {}
    if (q < text.len and text[q] == '\n') {
        q += 1;
        while (q < text.len and (text[q] == ' ' or text[q] == '\t')) : (q += 1) {}
    }
    if (q != beforetitle) {
        if (simd.scanTitleEnd(text, q)) |te| {
            var r = te + 1;
            while (r < text.len and (text[r] == ' ' or text[r] == '\t')) : (r += 1) {}
            if (r < text.len and text[r] == '\n') return .{ .label = lab.label, .url = url, .end = r + 1 };
            if (r >= text.len) return .{ .label = lab.label, .url = url, .end = r };
        }
        var r = beforetitle;
        while (r < text.len and (text[r] == ' ' or text[r] == '\t')) : (r += 1) {}
        if (r < text.len and text[r] == '\n') return .{ .label = lab.label, .url = url, .end = r + 1 };
        if (r >= text.len) return .{ .label = lab.label, .url = url, .end = r };
        return null;
    }
    if (p < text.len and text[p] == '\n') return .{ .label = lab.label, .url = url, .end = p + 1 };
    if (p >= text.len) return .{ .label = lab.label, .url = url, .end = p };
    return null;
}

/// Extract leading reference definitions from paragraph-group lines
/// [i..j): join with newlines, parse defs from the start, register them
/// (first wins), and return consumed LINE count (0 when no def leads).
fn extractLeadingDefs(ctx: Ctx, lines: []simd.Line, i: usize, j: usize) HError!usize {
    if (i >= j) return 0;
    var buf: std.ArrayList(u8) = .empty;
    for (lines[i..j], 0..) |l, k| {
        if (k > 0) try buf.append(ctx.aa, '\n');
        try buf.appendSlice(ctx.aa, lineText(ctx.md, l));
    }
    const text = buf.items;
    var pos: usize = 0;
    var consumed: usize = 0;
    while (true) {
        const d = parseDefAt(text, pos) orelse break;
        ctx.defs.add(d.label, d.url);
        var nls: usize = 0;
        for (text[pos..d.end]) |ch| {
            if (ch == '\n') nls += 1;
        }
        const ends_nl = d.end > pos and text[d.end - 1] == '\n';
        consumed += nls + (if (ends_nl) @as(usize, 0) else @as(usize, 1));
        pos = d.end;
    }
    return @min(consumed, j - i);
}

/// Definition pre-pass over one document level: register every leading def
/// of every paragraph group (multiline included), skipping fenced regions
/// whose text is code. Top level additionally marks consumed lines for the
/// serializer's skip; sub-levels only register (their serializer extracts
/// and skips in place). Then descends into quote bodies so forward
/// references from container content resolve.
fn prepassDefs(ctx: Ctx, lines: []simd.Line, mark: bool) HError!void {
    var idx: usize = 0;
    while (idx < lines.len) {
        if (lines[idx].block_type == .code_fence_start) {
            var k = idx + 1;
            while (k < lines.len and lines[k].block_type != .code_fence_end) : (k += 1) {}
            idx = @min(k + 1, lines.len);
            continue;
        }
        if (!isParaLike(lines[idx].block_type)) {
            idx += 1;
            continue;
        }
        var k = idx;
        while (k < lines.len and isParaLike(lines[k].block_type)) : (k += 1) {}
        const allowed = idx == 0 or !isParaLike(lines[idx - 1].block_type);
        if (allowed) {
            const used = try extractLeadingDefs(ctx, lines, idx, k);
            if (mark) {
                for (lines[idx .. idx + used]) |*l| l.block_type = .link_def;
            }
        }
        idx = k;
    }
    // Descend into quote bodies (same stripping the renderer uses).
    var q: usize = 0;
    while (q < lines.len) {
        if (lines[q].block_type != .quote) {
            q += 1;
            continue;
        }
        var inner: std.ArrayList(u8) = .empty;
        var last_blank = false;
        var count: usize = 0;
        var j = q;
        while (j < lines.len) {
            const t = lineText(ctx.md, lines[j]);
            if (lines[j].block_type == .quote) {
                const body = (try stripQuoteOnce(ctx.aa, t, ctx.phase)) orelse break;
                if (count > 0) try inner.append(ctx.aa, '\n');
                try inner.appendSlice(ctx.aa, body);
                last_blank = isBlankText(body);
                count += 1;
                j += 1;
            } else if (isBlankText(t)) {
                if (count > 0) try inner.append(ctx.aa, '\n');
                last_blank = true;
                count += 1;
                j += 1;
            } else if (!last_blank and count > 0 and isParaLike(lines[j].block_type)) {
                try inner.append(ctx.aa, '\n');
                try inner.appendSlice(ctx.aa, t);
                last_blank = false;
                j += 1;
            } else break;
        }
        if (count > 0) {
            var nls: usize = 0;
            for (inner.items) |ch| {
                if (ch == '\n') nls += 1;
            }
            const sublines = try ctx.aa.alloc(simd.Line, nls + 2);
            var subfence: simd.FenceState = .{};
            const sn = simd.scanLines(inner.items, sublines, &subfence);
            const sub = Ctx{ .aa = ctx.aa, .md = inner.items, .defs = ctx.defs, .depth = ctx.depth + 1 };
            try prepassDefs(sub, sublines[0..sn], false);
        }
        q = @max(j, q + 1);
    }
}

/// Whether sub-document line `k` is a lazy continuation: already proven
/// paragraph text by an enclosing quote or list item, so it joins text
/// and never opens blocks (not even lists, fences, or setext lines).
fn isLazyLine(lz: ?[]const bool, k: usize) bool {
    return lz != null and k < lz.?.len and lz.?[k];
}

fn serializeLines(ctx: Ctx, lines: []simd.Line, lazy: ?[]const bool, out: *std.ArrayList(u8)) HError!void {
    if (ctx.depth > 24) return error.TooDeep;
    var i: usize = 0;
    while (i < lines.len) {
        const from = i; // hang guard: every arm must consume input
        // A lazy line at group start joins paragraph text, never blocks.
        if (isLazyLine(lazy, i)) {
            const ni = try renderParaOrCode(ctx, lines, i, lazy, null, false, out);
            i = @max(ni, i + 1);
            continue;
        }
        const prev: ?simd.BlockType = if (i == 0) null else lines[i - 1].block_type;
        const prev_blank: bool = if (i == 0) false else lines[i - 1].block_type == .blank;
        const l = lines[i];
        const text = lineText(ctx.md, l);
        // Consumed reference definitions vanish before any other dispatch
        // (a multiline def's indented continuation is not code).
        if (l.block_type == .link_def) {
            i += 1;
            continue;
        }
        // Indented code claims any 4+-column line in code position before
        // structural dispatch (mirrors production's code-position rule,
        // verified by dump: indented `>`, `-`, `#` all render code cards).
        if (indentWidth(text, ctx.phase) >= 4 and !isBlankText(text) and codePosition(prev, prev_blank)) {
            i = try renderIndentedCode(ctx, lines, i, out);
            continue;
        }
        switch (l.block_type) {
            .blank => {
                i += 1;
            },
            .hr => {
                try out.appendSlice(ctx.aa, "<hr />\n");
                i += 1;
            },
            .heading1, .heading2, .heading3, .heading4, .heading5, .heading6 => {
                const atx = tryParseAtx(text, ctx.phase) orelse {
                    // Classifier heading that is not ATX: fall back to text.
                    try out.appendSlice(ctx.aa, "<p>");
                    try renderInline(ctx, trimSpaces(text), out);
                    try out.appendSlice(ctx.aa, "</p>\n");
                    i += 1;
                    continue;
                };
                const tag = try std.fmt.allocPrint(ctx.aa, "<h{d}>", .{atx.level});
                try out.appendSlice(ctx.aa, tag);
                try renderInline(ctx, atx.content, out);
                const end = try std.fmt.allocPrint(ctx.aa, "</h{d}>\n", .{atx.level});
                try out.appendSlice(ctx.aa, end);
                i += 1;
            },
            .code_fence_start => {
                var j = i + 1;
                while (j < lines.len and lines[j].block_type != .code_fence_end) : (j += 1) {}
                try renderFence(ctx, text, lines[i + 1 .. @min(j, lines.len)], out);
                i = @min(j + 1, lines.len);
            },
            .image => {
                try renderStandaloneImage(ctx, trimSpaces(text), out);
                i += 1;
            },
            .quote => {
                i = try renderQuote(ctx, lines, i, out);
            },
            .bullet_list, .task_list => {
                // Over-indented markers cannot open lists (top guard takes
                // code-position ones); the rest are lazy paragraph text.
                if (indentWidth(text, ctx.phase) >= 4) {
                    i = try renderParaOrCode(ctx, lines, i, lazy, prev, prev_blank, out);
                } else {
                    i = try renderList(ctx, lines, i, lazy, out);
                }
            },
            .ordered_list => {
                // Non-1 ordered markers cannot interrupt a paragraph: they
                // join it as lazy text (mirrors the hard-wrap rule).
                const omk = parseListMarker(text, ctx.phase);
                if (indentWidth(text, ctx.phase) >= 4 or
                    (omk != null and omk.?.num != 1 and prev != null and prev.? == .paragraph and !prev_blank))
                {
                    i = try renderParaOrCode(ctx, lines, i, lazy, prev, prev_blank, out);
                } else {
                    i = try renderList(ctx, lines, i, lazy, out);
                }
            },
            else => {
                i = try renderParaOrCode(ctx, lines, i, lazy, prev, prev_blank, out);
            },
        }
        if (i <= from) {
            std.debug.print("NoAdvance: depth={d} nlines={d} i={d} type={s} text='{s}'\n", .{
                ctx.depth, lines.len, i, @tagName(l.block_type), text,
            });
            return error.NoAdvance;
        }
    }
}

/// Paragraph-likes, indented code, and setext handling: shared by the
/// `else` arm and the indent-guarded quote/list arms.
fn renderParaOrCode(ctx: Ctx, lines: []simd.Line, i: usize, lazy: ?[]const bool, prev: ?simd.BlockType, prev_blank: bool, out: *std.ArrayList(u8)) HError!usize {
    _ = prev;
    _ = prev_blank;
    // Paragraph group: para-likes join; 4+-column structural lines join as
    // lazy literal text (indented code cannot interrupt a paragraph); and
    // non-1 ordered markers join (they cannot interrupt a paragraph either).
    // A setext underline never joins (it closes the group instead).
    // Flagged lazy lines join unconditionally: never blocks, never
    // underlines, whatever their scanned type.
    var j = i;
    while (j < lines.len and (groupJoins(ctx.md, lines[j], ctx.phase) or isLazyLine(lazy, j))) {
        if (j > i and !isLazyLine(lazy, j)) {
            const jt = lineText(ctx.md, lines[j]);
            if (isSetextUnderline(jt, '=', ctx.phase) or isSetextUnderline(jt, '-', ctx.phase)) break;
        }
        j += 1;
    }
    // A lone non-joining line (e.g. a rejected 10-digit "marker") still
    // renders as its own paragraph rather than stalling the serializer.
    if (j == i) j = i + 1;
    // Reference-definition extraction (finalize model): leading defs
    // register document-wide and vanish; the rest renders as the paragraph.
    // Never interrupts: only at group starts not continuing paragraph text.
    const can_def = i == 0 or !isParaLike(lines[i - 1].block_type);
    var gs = i;
    if (can_def) {
        const used = try extractLeadingDefs(ctx, lines, i, j);
        gs += used;
        if (gs >= j) return j;
    }
    var hlevel: u8 = 0;
    if (j < lines.len) {
        const uj = lines[j].block_type;
        const para_or_hr = uj == .paragraph or uj == .hr;
        // A lone `-`/`--` bullet line is a setext H2 underline: it beats
        // the list reading when it directly follows paragraph text
        // (never when the line itself is lazy).
        const lone_dash = uj == .bullet_list and j > gs and !isLazyLine(lazy, j) and
            isSetextUnderline(lineText(ctx.md, lines[j]), '-', ctx.phase);
        if ((para_or_hr or lone_dash) and !isLazyLine(lazy, j)) {
            const ut = lineText(ctx.md, lines[j]);
            if (isSetextUnderline(ut, '=', ctx.phase)) hlevel = 1 else if (isSetextUnderline(ut, '-', ctx.phase)) hlevel = 2;
        }
    }
    if (hlevel > 0) {
        const tag = try std.fmt.allocPrint(ctx.aa, "<h{d}>", .{hlevel});
        try out.appendSlice(ctx.aa, tag);
        try renderJoinedInline(ctx, lines[gs..j], out);
        const end = try std.fmt.allocPrint(ctx.aa, "</h{d}>\n", .{hlevel});
        try out.appendSlice(ctx.aa, end);
        return j + 1;
    }
    if (j > gs) {
        if (ctx.tight) {
            try renderJoinedInline(ctx, lines[gs..j], out);
            try out.append(ctx.aa, '\n');
        } else {
            try out.appendSlice(ctx.aa, "<p>");
            try renderJoinedInline(ctx, lines[gs..j], out);
            try out.appendSlice(ctx.aa, "</p>\n");
        }
    }
    return j;
}

fn renderQuote(ctx: Ctx, lines: []simd.Line, i: usize, out: *std.ArrayList(u8)) HError!usize {
    var inner: std.ArrayList(u8) = .empty;
    var lazy: std.ArrayList(bool) = .empty;
    var j = i;
    var last_para = false;
    var in_fence = false;
    var fence_ch: u8 = 0;
    var count: usize = 0;
    while (j < lines.len) {
        const t = lineText(ctx.md, lines[j]);
        if (lines[j].block_type == .quote) {
            const body = (try stripQuoteOnce(ctx.aa, t, ctx.phase)) orelse break;
            if (isBlankText(body)) {
                // Marked blank: an empty line of its own, so paragraphs on
                // either side split (trailing ones vanish in the trim below).
                if (count > 0) try inner.append(ctx.aa, '\n');
                try lazy.append(ctx.aa, false);
                last_para = false;
                count += 1;
                j += 1;
                continue;
            }
            if (count > 0) try inner.append(ctx.aa, '\n');
            try inner.appendSlice(ctx.aa, body);
            try lazy.append(ctx.aa, false);
            count += 1;
            j += 1;
            const fc = fenceRunChar(body, ctx.phase);
            if (!in_fence and fc != 0 and (fc == '~' or fenceInfoClean(body))) {
                in_fence = true;
                fence_ch = fc;
                last_para = false;
            } else if (in_fence and fc == fence_ch and fenceCloseClean(body, fc)) {
                in_fence = false;
                fence_ch = 0;
                last_para = false;
            } else {
                last_para = quoteBodyPara(body, ctx.phase, in_fence, last_para);
            }
        } else if (isBlankText(t)) {
            // A bare blank line ends the quote outright: it can never be
            // lazy, and absorbs nothing (CommonMark §5.1).
            break;
        } else if (count > 0 and last_para and !in_fence and (isParaLike(lines[j].block_type) or indentWidth(t, ctx.phase) >= 4)) {
            // Lazy continuation line: joins the open paragraph. Leading
            // indentation carries no weight on unwrapped lines, and the
            // line can never be a setext underline (flagged for the
            // sub-document serializer).
            try inner.append(ctx.aa, '\n');
            try inner.appendSlice(ctx.aa, stripLeading(t));
            try lazy.append(ctx.aa, true);
            j += 1;
        } else break;
    }
    if (j == i) {
        // Unstrippable marker: fall back to a literal paragraph line.
        try out.appendSlice(ctx.aa, "<p>");
        try renderInline(ctx, trimSpaces(lineText(ctx.md, lines[i])), out);
        try out.appendSlice(ctx.aa, "</p>\n");
        return i + 1;
    }
    // Drop trailing blanks.
    var doc = inner.items;
    while (doc.len > 0) {
        const nl = std.mem.lastIndexOfScalar(u8, doc, '\n');
        const tail = if (nl) |p| doc[p + 1 ..] else doc;
        if (!isBlankText(tail)) break;
        doc = if (nl) |p| doc[0..p] else "";
    }
    // Inner lines start past `>` plus one column; the first stripped
    // line's indent fixes the sub-document tab phase (mixed-indent
    // bodies are a documented approximation: no spec case mixes them
    // with surviving tabs).
    const first_t = lineText(ctx.md, lines[i]);
    var qsp: usize = 0;
    while (qsp < first_t.len and first_t[qsp] == ' ' and qsp < 3) : (qsp += 1) {}
    const sub = Ctx{ .aa = ctx.aa, .md = doc, .defs = ctx.defs, .depth = ctx.depth + 1, .phase = (ctx.phase + qsp + 2) % 4 };
    // Re-scan the stripped inner document.
    var nls: usize = 0;
    for (doc) |ch| {
        if (ch == '\n') nls += 1;
    }
    const sublines = try ctx.aa.alloc(simd.Line, nls + 2);
    var subfence: simd.FenceState = .{};
    const sn = simd.scanLines(doc, sublines, &subfence);
    // Reference definitions inside quotes resolve document-wide already.
    // Trailing blanks were dropped above, so only leading flags survive.
    try out.appendSlice(ctx.aa, "<blockquote>\n");
    try serializeLines(sub, sublines[0..sn], lazy.items, out);
    try out.appendSlice(ctx.aa, "</blockquote>\n");
    return j;
}

/// List-item bodies dedent via `coldent` (partial-tab aware).

const ItemInfo = struct {
    start: usize, // line index of the item's marker line
    content_col: usize, // absolute columns governing this item's body
    indent: usize, // marker-line leading spaces
};

/// Fold one item-body content line into the open-paragraph/fence state.
/// Returns `{ open_para, in_fence, fence_ch }`.
fn trackBodyLine(content: []const u8, phase: usize, last_para: bool, in_fence: bool, fence_ch: u8) struct { bool, bool, u8 } {
    if (isBlankText(content)) return .{ false, in_fence, fence_ch };
    const fc = fenceRunChar(content, phase);
    if (!in_fence and fc != 0 and (fc == '~' or fenceInfoClean(content))) {
        return .{ false, true, fc };
    }
    if (in_fence and fc == fence_ch and fenceCloseClean(content, fc)) {
        return .{ false, false, 0 };
    }
    return .{ quoteBodyPara(content, phase, in_fence, last_para), in_fence, fence_ch };
}

/// Whether a list marker line carries item content past the marker.
fn markerHasContent(t: []const u8, mk: Marker) bool {
    const rest = if (mk.marker_len <= t.len) t[mk.marker_len..] else "";
    return !isBlankText(rest);
}

fn renderList(ctx: Ctx, lines: []simd.Line, i: usize, lazy: ?[]const bool, out: *std.ArrayList(u8)) HError!usize {
    // First marker sets list kind/delimiter; each item keeps its own
    // content column (mixed-indent siblings dedent independently).
    const first_text = lineText(ctx.md, lines[i]);
    const first_mk = parseListMarker(stripTaskMarker(first_text), ctx.phase) orelse parseListMarker(first_text, ctx.phase) orelse {
        // Classifier list line the marker parser rejects (e.g. 10+ digit
        // "ordered" runs): plain paragraph text, never swallowed.
        return try renderParaOrCode(ctx, lines, i, lazy, null, false, out);
    };
    const ordered = first_mk.kind == .ordered;
    const delim = first_mk.delim;
    const first_bullet = first_mk.bullet;

    // Gather group: items, blanks, continuations, lazy lines. A fence
    // tracker runs over dedented item content: the document scanner never
    // sees list structure, so it mis-tracks fences whose open hides behind
    // a marker (`- ``` `) and swallows later siblings as code.
    var j = i;
    var items: std.ArrayList(ItemInfo) = .empty;
    try items.append(ctx.aa, .{ .start = i, .content_col = first_mk.content_col, .indent = first_mk.indent });
    var cur_blank = false; // blank inside current item
    var inner_blank = false; // blank followed by more item content: loose
    var cur_content = markerHasContent(first_text, first_mk);
    var nested_list = false; // a sublist marker already lives in this item
    var g_fence = false;
    var g_fence_ch: u8 = 0;
    {
        const rest = try stripColumns(ctx.aa, first_text, first_mk.content_col, ctx.phase);
        _, g_fence, g_fence_ch = trackBodyLine(rest, ctx.phase, false, g_fence, g_fence_ch);
    }
    var item_blanks: std.ArrayList(bool) = .empty;
    var ended = false;
    j += 1;
    while (j < lines.len and !ended) {
        const t = lineText(ctx.md, lines[j]);
        const bt = lines[j].block_type;
        const cur_col = items.items[items.items.len - 1].content_col;
        if (isLazyLine(lazy, j)) {
            // Enclosing-context lazy line: already proven paragraph text;
            // joins the open item whatever its shape.
            cur_blank = false;
            cur_content = true;
            j += 1;
        } else if (bt == .blank) {
            // Blanks inside fenced content are code, never structure.
            if (!g_fence) cur_blank = true;
            j += 1;
        } else if (indentWidth(t, ctx.phase) >= cur_col) {
            // Indented continuation (any type): nested blocks emerge on
            // rescan after dedent. Markers at/after the content column
            // start sublists, never sibling items. An empty item followed
            // by a blank holds nothing: later indented lines fall outside.
            const rest = try coldent(ctx.aa, t, cur_col, ctx.phase);
            if (cur_blank and !cur_content) {
                ended = true;
            } else {
                // A blank loosens only for direct item content: sibling-level
                // lines, or content with no sublist open to absorb it. Deep
                // lines under an open sublist (`    c` under `- a / - b`)
                // belong to nested items, decided one level down.
                if (cur_blank and !g_fence and
                    (indentWidth(t, ctx.phase) <= cur_col or !nested_list))
                {
                    inner_blank = true;
                }
                cur_blank = false;
                cur_content = true;
                if (!g_fence and parseListMarker(rest, ctx.phase) != null) nested_list = true;
                _, g_fence, g_fence_ch = trackBodyLine(rest, ctx.phase, false, g_fence, g_fence_ch);
                j += 1;
            }
        } else if (bt == .bullet_list or bt == .ordered_list or bt == .task_list or
            ((bt == .code_line or bt == .code_fence_start or bt == .code_fence_end) and !g_fence))
        {
            const raw = stripTaskMarker(t);
            const mk = parseListMarker(raw, ctx.phase) orelse parseListMarker(t, ctx.phase);
            const same = if (mk) |m| blk: {
                if (ordered != (m.kind == .ordered)) break :blk false;
                if (ordered and m.delim != delim) break :blk false;
                if (!ordered and m.bullet != first_bullet) break :blk false;
                break :blk true;
            } else false;
            if (!same) {
                // A line no marker parser accepts (`    - e` too deep to
                // mark) is lazy paragraph text when the item is open; a real
                // marker of another kind still ends the list (sibling lists
                // like `- foo\n2. bar` stay split).
                if (mk == null and cur_content and !cur_blank and !g_fence and
                    groupJoins(ctx.md, lines[j], ctx.phase))
                {
                    j += 1;
                } else {
                    ended = true;
                }
            } else {
                try item_blanks.append(ctx.aa, cur_blank);
                cur_blank = false;
                const m = mk.?;
                cur_content = markerHasContent(t, m);
                nested_list = false;
                const rest = try stripColumns(ctx.aa, t, m.content_col, ctx.phase);
                _, g_fence, g_fence_ch = trackBodyLine(rest, ctx.phase, false, g_fence, g_fence_ch);
                try items.append(ctx.aa, .{ .start = j, .content_col = m.content_col, .indent = m.indent });
                j += 1;
            }
        } else if (isParaLike(bt) and !cur_blank and cur_content) {
            // Lazy continuation of the open item paragraph: an empty item
            // holds no paragraph, so following text falls outside (`- \nfoo`).
            cur_content = true;
            j += 1;
        } else if (cur_content and !cur_blank and !g_fence and groupJoins(ctx.md, lines[j], ctx.phase)) {
            // Lazy text the scanner typed structurally (an over-indented
            // `- e` that cannot mark): joins the open item paragraph.
            j += 1;
        } else {
            ended = true;
        }
    }
    // Trailing blanks never loosen: only blanks between items or before
    // further item content do (tracked above).
    // Drop trailing blanks: find last meaningful line.
    var end = j;
    while (end > i and lines[end - 1].block_type == .blank) : (end -= 1) {}
    // Loose when a blank separates items or sits inside an item's blocks.
    var loose = inner_blank;
    for (item_blanks.items) |b| {
        if (b) loose = true;
    }

    if (ordered) {
        if (first_mk.num != 1) {
            const tag = try std.fmt.allocPrint(ctx.aa, "<ol start=\"{d}\">\n", .{first_mk.num});
            try out.appendSlice(ctx.aa, tag);
        } else {
            try out.appendSlice(ctx.aa, "<ol>\n");
        }
    } else {
        try out.appendSlice(ctx.aa, "<ul>\n");
    }
    for (items.items, 0..) |it, k| {
        const iend = if (k + 1 < items.items.len) items.items[k + 1].start else end;
        // Build item body doc: first line dedented past the marker column,
        // continuations dedented by the content column (partial-tab aware).
        // Continuations that cannot interrupt the open paragraph (4+ columns
        // while text is open, or under-indented for nested structure) are
        // lazy: stripped and flagged so the rescan keeps them as text.
        var body: std.ArrayList(u8) = .empty;
        var flags: std.ArrayList(bool) = .empty;
        var open_para = false;
        var in_fence = false;
        var fence_ch: u8 = 0;
        var r = it.start;
        var first = true;
        while (r < iend) {
            const t = lineText(ctx.md, lines[r]);
            if (lines[r].block_type == .blank) {
                // Blank lines contribute no content of their own: the
                // inter-line separator below is their single newline, so
                // blank runs never double (matters inside code and fences).
                try flags.append(ctx.aa, false);
                open_para = false;
            } else if (first) {
                const rest = try stripColumns(ctx.aa, t, it.content_col, ctx.phase);
                try body.appendSlice(ctx.aa, rest);
                try flags.append(ctx.aa, false);
                open_para, in_fence, fence_ch = trackBodyLine(rest, ctx.phase, open_para, in_fence, fence_ch);
            } else if (isLazyLine(lazy, r)) {
                try body.appendSlice(ctx.aa, t);
                try flags.append(ctx.aa, true);
            } else if (indentWidth(t, ctx.phase) >= it.content_col) {
                const rest = try coldent(ctx.aa, t, it.content_col, ctx.phase);
                // Still indented 4+ past the content column while paragraph
                // text is open: cannot open blocks, so lazy text (stripped
                // and flagged). Otherwise nested structure emerges on rescan.
                const subphase = (ctx.phase + it.content_col) % 4;
                // A dedented list marker is nesting, never code: deeper
                // levels dedent further and decide (`    - boo` under `- baz`
                // is a sublist even with paragraph text open above it), so
                // the marker test ignores the rest's own indent.
                const rest_stripped = stripLeading(rest);
                const rest_mk = parseListMarker(stripTaskMarker(rest_stripped), ctx.phase) orelse
                    parseListMarker(rest_stripped, ctx.phase);
                if (open_para and !in_fence and indentWidth(rest, subphase) >= 4 and rest_mk == null) {
                    try body.appendSlice(ctx.aa, stripLeading(t));
                    try flags.append(ctx.aa, true);
                } else {
                    try body.appendSlice(ctx.aa, rest);
                    try flags.append(ctx.aa, false);
                    open_para, in_fence, fence_ch = trackBodyLine(rest, ctx.phase, open_para, in_fence, fence_ch);
                }
            } else {
                try body.appendSlice(ctx.aa, stripLeading(t));
                try flags.append(ctx.aa, true);
            }
            if (r + 1 < iend) try body.append(ctx.aa, '\n');
            first = false;
            r += 1;
        }
        var nls: usize = 0;
        for (body.items) |ch| {
            if (ch == '\n') nls += 1;
        }
        const sublines = try ctx.aa.alloc(simd.Line, nls + 2);
        var subfence: simd.FenceState = .{};
        const sn = simd.scanLines(body.items, sublines, &subfence);
        const sub = Ctx{ .aa = ctx.aa, .md = body.items, .defs = ctx.defs, .depth = ctx.depth + 1, .phase = (ctx.phase + it.content_col) % 4, .tight = !loose };
        var tmp: std.ArrayList(u8) = .empty;
        try serializeLines(sub, sublines[0..sn], flags.items, &tmp);
        if (!loose) {
            // A leading paragraph joins `<li>` directly (`<li>foo</li>`,
            // `<li>foo\n<ul>...</ul>\n</li>`); a leading block drops to a
            // fresh line (`<li>\n<pre>...</pre>\n</li>`).
            const single_line = tmp.items.len > 0 and tmp.items[tmp.items.len - 1] == '\n' and
                std.mem.indexOfScalar(u8, tmp.items[0 .. tmp.items.len - 1], '\n') == null;
            // `</li>` joins directly unless the body ends with a block
            // close; computed once for both tight shapes below.
            var tight_txt = tmp.items;
            if (!single_line and !endsBlockClose(tight_txt) and tight_txt.len > 0 and tight_txt[tight_txt.len - 1] == '\n') {
                tight_txt = tight_txt[0 .. tight_txt.len - 1];
            }
            if (tmp.items.len > 0 and tmp.items[0] == '<' and startsBlockTag(tmp.items)) {
                try out.appendSlice(ctx.aa, "<li>\n");
                try out.appendSlice(ctx.aa, tight_txt);
            } else if (single_line) {
                try out.appendSlice(ctx.aa, "<li>");
                try out.appendSlice(ctx.aa, tmp.items);
                out.items.len -= 1;
            } else {
                // Multi-line inline text joins `</li>` directly (`baz</li>`);
                // only a trailing block close keeps its own line (`</ul>\n</li>`).
                try out.appendSlice(ctx.aa, "<li>");
                var body_txt = tmp.items;
                if (!endsBlockClose(body_txt) and body_txt.len > 0 and body_txt[body_txt.len - 1] == '\n') {
                    body_txt = body_txt[0 .. body_txt.len - 1];
                }
                try out.appendSlice(ctx.aa, body_txt);
            }
            try out.appendSlice(ctx.aa, "</li>\n");
        } else {
            // An empty item stays on one line (`<li></li>`, never `<li>\n</li>`).
            if (tmp.items.len == 0) {
                try out.appendSlice(ctx.aa, "<li></li>\n");
            } else {
                try out.appendSlice(ctx.aa, "<li>\n");
                try out.appendSlice(ctx.aa, tmp.items);
                // Ensure blank-line separation collapse matches cmark exactly:
                // tmp already newline-terminated per block.
                try out.appendSlice(ctx.aa, "</li>\n");
            }
        }
    }
    if (ordered) {
        try out.appendSlice(ctx.aa, "</ol>\n");
    } else {
        try out.appendSlice(ctx.aa, "</ul>\n");
    }
    return end;
}

/// Task markers (`- [ ]`) are GFM: for CommonMark shape, treat the item as a
/// bullet whose content keeps the literal brackets.
fn stripTaskMarker(text: []const u8) []const u8 {
    var i: usize = 0;
    while (i < text.len and text[i] == ' ') : (i += 1) {}
    if (i < text.len and (text[i] == '-' or text[i] == '+' or text[i] == '*')) {
        var k = i + 1;
        if (k < text.len and (text[k] == ' ' or text[k] == '\t')) {
            k += 1;
            if (k + 2 < text.len and text[k] == '[' and
                (text[k + 1] == ' ' or text[k + 1] == 'x' or text[k + 1] == 'X') and text[k + 2] == ']')
            {
                return text[0 .. k - 1];
            }
        }
    }
    return text;
}

/// Whether a line joins an open paragraph group as (lazy) text.
fn groupJoins(md: []const u8, l: simd.Line, phase: usize) bool {
    if (isParaLike(l.block_type)) return true;
    if (l.block_type == .blank) return false;
    const text = lineText(md, l);
    if (indentWidth(text, phase) >= 4) return true;
    if (l.block_type == .ordered_list) {
        const mk = parseListMarker(text, phase) orelse return false;
        if (mk.num != 1) return true;
        // An empty item cannot interrupt a paragraph (`foo\n1.` stays text).
        if (!markerHasContent(text, mk)) return true;
        return false;
    }
    if (l.block_type == .bullet_list or l.block_type == .task_list) {
        // An empty bullet cannot interrupt a paragraph (`foo\n*` stays text).
        const raw = stripTaskMarker(text);
        const mk = parseListMarker(raw, phase) orelse parseListMarker(text, phase) orelse return false;
        if (!markerHasContent(text, mk)) return true;
    }
    return false;
}

/// True when a tight item body ends with a block-level close (nested list,
/// blockquote, code, heading, hr, table): `</li>` keeps its own line.
fn endsBlockClose(html: []const u8) bool {
    for ([_][]const u8{ "</ul>\n", "</ol>\n", "</li>\n", "</blockquote>\n", "</pre>\n", "</table>\n", "<hr />\n" }) |tag| {
        if (std.mem.endsWith(u8, html, tag)) return true;
    }
    var lvl: u8 = 1;
    while (lvl <= 6) : (lvl += 1) {
        var suffix: [6]u8 = undefined;
        const s = std.fmt.bufPrint(&suffix, "</h{d}>\n", .{lvl}) catch continue;
        if (std.mem.endsWith(u8, html, s)) return true;
    }
    return false;
}

/// True when inline output opens with a block-level tag (tight `<li>`
/// drops those to a fresh line; paragraphs and inline tags join directly).
fn startsBlockTag(html: []const u8) bool {
    for ([_][]const u8{ "<pre", "<ul", "<ol", "<blockquote", "<h1", "<h2", "<h3", "<h4", "<h5", "<h6", "<hr", "<table" }) |tag| {
        if (html.len >= tag.len and std.mem.eql(u8, html[0..tag.len], tag)) return true;
    }
    return false;
}

fn stripLeading(text: []const u8) []const u8 {
    var s: usize = 0;
    while (s < text.len and (text[s] == ' ' or text[s] == '\t')) : (s += 1) {}
    return text[s..];
}

// ---- Part D: inline serializer (models production inline pipeline) ----

/// Decode `&...;` entities using the production decoder, then escape HTML
/// specials. Two passes so decoded `<` (from `&lt;`) is re-escaped while
/// decoded scalars like © pass through.
fn decodeAndEscape(aa: std.mem.Allocator, text: []const u8, decode: bool) HError![]u8 {
    var mid: std.ArrayList(u8) = .empty;
    if (decode) {
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '&') {
                var tmp: [8]u8 = undefined;
                const n = parser.decodeEntityAfterAmp(text[i + 1 ..], tmp[0..]);
                if (n > 0) {
                    const semi = std.mem.indexOfScalar(u8, text[i + 1 ..], ';') orelse text.len - (i + 1);
                    try mid.appendSlice(aa, tmp[0..n]);
                    i += 1 + semi + 1;
                    continue;
                }
            }
            try mid.append(aa, text[i]);
            i += 1;
        }
    } else {
        try mid.appendSlice(aa, text);
    }
    var out: std.ArrayList(u8) = .empty;
    for (mid.items) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(aa, "&amp;"),
            '<' => try out.appendSlice(aa, "&lt;"),
            '>' => try out.appendSlice(aa, "&gt;"),
            '"' => try out.appendSlice(aa, "&quot;"),
            else => try out.append(aa, ch),
        }
    }
    return out.toOwnedSlice(aa);
}

/// Decode `&...;` entities (no HTML escaping); shared by href building.
fn decodeEntities(aa: std.mem.Allocator, text: []const u8) HError![]u8 {
    var mid: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            var tmp: [8]u8 = undefined;
            const n = parser.decodeEntityAfterAmp(text[i + 1 ..], tmp[0..]);
            if (n > 0) {
                const semi = std.mem.indexOfScalar(u8, text[i + 1 ..], ';') orelse text.len - (i + 1);
                try mid.appendSlice(aa, tmp[0..n]);
                i += 1 + semi + 1;
                continue;
            }
        }
        try mid.append(aa, text[i]);
        i += 1;
    }
    return mid.toOwnedSlice(aa);
}

/// Backslash-unescape a link destination (`\` + ASCII punctuation drops the
/// backslash, mirroring the reference URL scan + clean step). Autolinks
/// skip this: their raw text keeps backslashes.
fn backslashUnescape(aa: std.mem.Allocator, dest: []const u8) HError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < dest.len) {
        const ch = dest[i];
        if (ch == '\\' and i + 1 < dest.len and parser.isAsciiPunct(dest[i + 1])) {
            try out.append(aa, dest[i + 1]);
            i += 2;
            continue;
        }
        try out.append(aa, ch);
        i += 1;
    }
    return out.toOwnedSlice(aa);
}

/// URL-escape a link destination per CommonMark (cmark `clean_url`): entity
/// decode (after backslash unescape unless this is an autolink), then the
/// HREF_SAFE set passes through, `&`/`'` take entity escapes, and every
/// other byte becomes uppercase %XX.
fn escapeUrl(aa: std.mem.Allocator, dest: []const u8, unescape_backslash: bool) HError![]u8 {
    const dec = try decodeEntities(aa, dest);
    const raw = if (unescape_backslash) try backslashUnescape(aa, dec) else dec;
    var out: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (raw) |ch| {
        const alnum = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9');
        const safe = alnum or std.mem.indexOfScalar(u8, "!#$%()*+,-./:;=?@_~", ch) != null;
        if (safe) {
            try out.append(aa, ch);
        } else if (ch == '&') {
            try out.appendSlice(aa, "&amp;");
        } else if (ch == '\'') {
            try out.appendSlice(aa, "&#x27;");
        } else {
            try out.append(aa, '%');
            try out.append(aa, hex[ch >> 4]);
            try out.append(aa, hex[ch & 0xF]);
        }
    }
    return out.toOwnedSlice(aa);
}

/// Open-tag stack for nested emphasis. Production spans carry flat style
/// flags, but tag structure follows the matcher pairs: each open tag is
/// keyed by its pair's (opener run idx, opener offset), so nested
/// same-style pairs (`*(*foo*)*`) re-emit structurally while already-open
/// styles stay silent. Code/link leaves emit inline without disturbing the
/// stack; link-text recursion uses a fresh stack.
const TagStack = struct {
    bold_keys: [16][2]usize = undefined,
    bold_n: usize = 0,
    italic_keys: [16][2]usize = undefined,
    italic_n: usize = 0,
    strike: bool = false,
};

/// Positional context for pair-aware em/strong tag ordering: tag order
/// follows pair containment (outer opens first, inner closes first), which
/// a fixed principle-14 order gets wrong for shared-opener cases like
/// `***foo* bar**` (strong outside) vs `***foo***` (em outside).
const PairCtx = struct {
    runs: []const parser.DelimRun,
    pairs: []const parser.EmPair,
};

fn pairOpenEnd(pc: PairCtx, p: parser.EmPair) usize {
    return pc.runs[p.open].pos + p.open_off + p.use;
}

fn pairCloseStart(pc: PairCtx, p: parser.EmPair) usize {
    return pc.runs[p.close].pos + p.close_off;
}

fn pairCovers(pc: PairCtx, p: parser.EmPair, s: usize, e: usize) bool {
    return pairOpenEnd(pc, p) <= s and e <= pairCloseStart(pc, p);
}

/// Covering pair keys of one style for a span, outer-first. Pushes are
/// gated on the production flag (leftover-delimiter slivers can sit inside
/// a precise pair region while carrying no style), so a wanted flag always
/// finds its pairs here.
fn coveringKeys(pc: PairCtx, strong: bool, s: usize, e: usize, keys: [][2]usize) usize {
    var n: usize = 0;
    for (pc.pairs) |p| {
        if (p.strong != strong) continue;
        if (!pairCovers(pc, p, s, e)) continue;
        if (n >= keys.len) break;
        keys[n] = .{ p.open, p.open_off };
        n += 1;
    }
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var j = i;
        while (j > 0 and (keys[j][0] < keys[j - 1][0] or
            (keys[j][0] == keys[j - 1][0] and keys[j][1] < keys[j - 1][1])))
        {
            const t = keys[j];
            keys[j] = keys[j - 1];
            keys[j - 1] = t;
            j -= 1;
        }
    }
    return n;
}

const StackOp = struct {
    strong: bool,
    key: [2]usize,
};

fn syncTagsPairs(st: *TagStack, aa: std.mem.Allocator, pc: PairCtx, span_off: usize, span_end: usize, want_b: bool, want_i: bool, want_s: bool, out: *std.ArrayList(u8)) HError!void {
    var nb: [16][2]usize = undefined;
    var ni: [16][2]usize = undefined;
    const n_nb = if (want_b) coveringKeys(pc, true, span_off, span_end, &nb) else 0;
    const n_ni = if (want_i) coveringKeys(pc, false, span_off, span_end, &ni) else 0;
    const new_b = nb[0..n_nb];
    const new_i = ni[0..n_ni];
    // Common prefixes stay silent (laminar nesting: shared pairs lead).
    var kb: usize = 0;
    while (kb < st.bold_n and kb < new_b.len and
        st.bold_keys[kb][0] == new_b[kb][0] and st.bold_keys[kb][1] == new_b[kb][1]) : (kb += 1)
    {
    }
    var ki: usize = 0;
    while (ki < st.italic_n and ki < new_i.len and
        st.italic_keys[ki][0] == new_i[ki][0] and st.italic_keys[ki][1] == new_i[ki][1]) : (ki += 1)
    {
    }
    if (st.strike and !want_s) {
        try out.appendSlice(aa, "</del>");
        st.strike = false;
    }
    // Pops across both flags, inner pair first (larger opener key first).
    var pops: [32]StackOp = undefined;
    var n_pops: usize = 0;
    var q = st.bold_n;
    while (q > kb) : (q -= 1) {
        pops[n_pops] = .{ .strong = true, .key = st.bold_keys[q - 1] };
        n_pops += 1;
    }
    q = st.italic_n;
    while (q > ki) : (q -= 1) {
        pops[n_pops] = .{ .strong = false, .key = st.italic_keys[q - 1] };
        n_pops += 1;
    }
    var a: usize = 1;
    while (a < n_pops) : (a += 1) {
        var b = a;
        while (b > 0 and (pops[b].key[0] > pops[b - 1].key[0] or
            (pops[b].key[0] == pops[b - 1].key[0] and pops[b].key[1] > pops[b - 1].key[1])))
        {
            const t = pops[b];
            pops[b] = pops[b - 1];
            pops[b - 1] = t;
            b -= 1;
        }
    }
    for (pops[0..n_pops]) |op| {
        try out.appendSlice(aa, if (op.strong) "</strong>" else "</em>");
    }
    st.bold_n = kb;
    st.italic_n = ki;
    // Pushes across both flags, outer pair first (smaller opener key first).
    var pushes: [32]StackOp = undefined;
    var n_pushes: usize = 0;
    for (new_b[kb..]) |k| {
        pushes[n_pushes] = .{ .strong = true, .key = k };
        n_pushes += 1;
    }
    for (new_i[ki..]) |k| {
        pushes[n_pushes] = .{ .strong = false, .key = k };
        n_pushes += 1;
    }
    a = 1;
    while (a < n_pushes) : (a += 1) {
        var b = a;
        while (b > 0 and (pushes[b].key[0] < pushes[b - 1].key[0] or
            (pushes[b].key[0] == pushes[b - 1].key[0] and pushes[b].key[1] < pushes[b - 1].key[1])))
        {
            const t = pushes[b];
            pushes[b] = pushes[b - 1];
            pushes[b - 1] = t;
            b -= 1;
        }
    }
    for (pushes[0..n_pushes]) |op| {
        try out.appendSlice(aa, if (op.strong) "<strong>" else "<em>");
        if (op.strong) {
            if (st.bold_n < st.bold_keys.len) {
                st.bold_keys[st.bold_n] = op.key;
                st.bold_n += 1;
            }
        } else {
            if (st.italic_n < st.italic_keys.len) {
                st.italic_keys[st.italic_n] = op.key;
                st.italic_n += 1;
            }
        }
    }
    if (!st.strike and want_s) {
        try out.appendSlice(aa, "<del>");
        st.strike = true;
    }
}

/// Pair context mirroring production exactly (link intervals, autolink
/// masking, crossing-pair drop) so tag ordering sees the pairs production
/// used. Needs the document reference definitions for ref-link intervals.
fn buildPairCtxDefs(text: []const u8, runbuf: []parser.DelimRun, pairbuf: []parser.EmPair, segbuf: []parser.LinkSeg, defs: []const simd.RefDef) PairCtx {
    const ns = parser.linkIntervals(text, defs, segbuf);
    const nr = parser.collectRunsMasked(text, runbuf, segbuf[0..ns]);
    var np = parser.matchRuns(runbuf[0..nr], nr, pairbuf);
    np = parser.filterCrossingPairs(runbuf[0..nr], pairbuf[0..np], np, segbuf[0..ns]);
    return .{ .runs = runbuf[0..nr], .pairs = pairbuf[0..np] };
}



fn renderInline(ctx: Ctx, text: []const u8, out: *std.ArrayList(u8)) HError!void {
    var runbuf: [parser.MAX_RUNS]parser.DelimRun = undefined;
    var pairbuf: [parser.MAX_PAIRS]parser.EmPair = undefined;
    var segbuf: [parser.MAX_LINK_SEGS]parser.LinkSeg = undefined;
    const pc = buildPairCtxDefs(text, &runbuf, &pairbuf, &segbuf, ctx.defs.slice());
    var st = TagStack{};
    try renderInlineStPc(ctx, text, out, &st, pc, true);
    try syncTagsPairs(&st, ctx.aa, pc, text.len, text.len, false, false, false, out);
}

/// Trailing whitespace at the very end of top-level inline text is dropped
/// (paragraphs never end with visible space); link-text recursion keeps it
/// (`[a ](u)` renders `<a>a </a>`).
fn renderInlineStPc(ctx: Ctx, text: []const u8, out: *std.ArrayList(u8), st: *TagStack, pc: PairCtx, strip_end: bool) HError!void {
    const spans = try ctx.aa.alloc(parser.InlineSpan, 1024);
    const n = parser.parseInlinesWithDefs(text, spans, ctx.defs.slice());
    const base = @intFromPtr(text.ptr);
    for (spans[0..n], 0..) |s, si| {
        // Span offsets into `text` drive pair-aware tag ordering. All span
        // text borrows from the parsed slice, so the difference is exact.
        const span_off = @intFromPtr(s.text.ptr) - base;
        const span_end = span_off + s.text.len;
        const is_last = si + 1 == n;
        if (s.style.code) {
            // Code spans never split: newlines render as spaces. Padding
            // was already stripped once by the parser's code-span rule.
            var cbuf: std.ArrayList(u8) = .empty;
            for (s.text) |ch| try cbuf.append(ctx.aa, if (ch == '\n') ' ' else ch);
            try renderSpanText(ctx, s, cbuf.items, out, st, pc, span_off, span_end);
            continue;
        }
        // Split soft/hard line breaks inside span text.
        var seg_start: usize = 0;
        var k: usize = 0;
        while (k <= s.text.len) {
            const is_end = k == s.text.len;
            const is_nl = !is_end and s.text[k] == '\n';
            if (is_end or is_nl) {
                const seg = s.text[seg_start..k];
                // Hard break: two trailing spaces or closing backslash.
                var hard = false;
                var body = seg;
                if (body.len >= 2 and body[body.len - 1] == ' ' and body[body.len - 2] == ' ') {
                    var e = body.len;
                    while (e > 0 and body[e - 1] == ' ') : (e -= 1) {}
                    body = body[0..e];
                    hard = true;
                } else if (is_nl and body.len >= 1 and body[body.len - 1] == '\\') {
                    // A closing backslash is a hard break only before a
                    // newline; at text end it is a literal backslash.
                    body = body[0 .. body.len - 1];
                    hard = true;
                } else if ((is_nl or (is_end and is_last and strip_end)) and !s.style.code) {
                    // Trailing whitespace at a soft line break (or the end
                    // of top-level text) is dropped; mid-text span edges,
                    // link text, and code spans stay verbatim.
                    while (body.len > 0 and (body[body.len - 1] == ' ' or body[body.len - 1] == '\t')) {
                        body = body[0 .. body.len - 1];
                    }
                }
                try renderSpanText(ctx, s, body, out, st, pc, span_off, span_end);
                if (is_nl) {
                    if (hard) {
                        try out.appendSlice(ctx.aa, "<br />\n");
                    } else {
                        try out.append(ctx.aa, '\n');
                    }
                }
                seg_start = k + 1;
            }
            k += 1;
        }
    }
}

/// Plain-text rendering of an image description for the `alt` attribute:
/// emphasis markers drop, code content stays raw, nested links/images
/// flatten to their own text. Entities decode at the final escape step.
fn renderAltText(ctx: Ctx, text: []const u8, out: *std.ArrayList(u8)) HError!void {
    const spans = try ctx.aa.alloc(parser.InlineSpan, 256);
    const n = parser.parseInlinesWithDefs(text, spans, ctx.defs.slice());
    for (spans[0..n]) |s| {
        if (s.style.code) {
            try out.appendSlice(ctx.aa, s.text);
        } else if (s.style.link or s.style.image) {
            try renderAltText(ctx, s.text, out);
        } else {
            try out.appendSlice(ctx.aa, s.text);
        }
    }
}

fn renderSpanText(ctx: Ctx, s: parser.InlineSpan, body: []const u8, out: *std.ArrayList(u8), st: *TagStack, pc: PairCtx, span_off: usize, span_end: usize) HError!void {
    const esc = try decodeAndEscape(ctx.aa, body, !s.style.code);
    if (s.style.code) {
        try out.appendSlice(ctx.aa, "<code>");
        try out.appendSlice(ctx.aa, esc);
        try out.appendSlice(ctx.aa, "</code>");
    } else if (s.style.image) {
        try syncTagsPairs(st, ctx.aa, pc, span_off, span_end, s.style.bold, s.style.italic, s.style.strikethrough, out);
        const src = try escapeUrl(ctx.aa, s.link_target orelse "", true);
        var altbuf: std.ArrayList(u8) = .empty;
        try renderAltText(ctx, s.text, &altbuf);
        const alt = try decodeAndEscape(ctx.aa, altbuf.items, true);
        const tag = try std.fmt.allocPrint(ctx.aa, "<img src=\"{s}\" alt=\"{s}\" />", .{ src, alt });
        try out.appendSlice(ctx.aa, tag);
    } else if (s.style.autolink) {
        // Autolink text is literal (entities decode, backslashes stay):
        // never re-parsed, so `\*` survives in labels.
        try syncTagsPairs(st, ctx.aa, pc, span_off, span_end, s.style.bold, s.style.italic, s.style.strikethrough, out);
        const href_raw = s.link_target orelse "";
        var href = try escapeUrl(ctx.aa, href_raw, false);
        // Bare email autolinks need the mailto: scheme in href.
        if (!std.mem.startsWith(u8, href_raw, "mailto:") and
            std.mem.indexOfScalar(u8, href_raw, '@') != null and
            std.mem.indexOfScalar(u8, href_raw, ':') == null)
        {
            href = try std.mem.concat(ctx.aa, u8, &.{ "mailto:", href });
        }
        const tag = try std.fmt.allocPrint(ctx.aa, "<a href=\"{s}\">", .{href});
        try out.appendSlice(ctx.aa, tag);
        try out.appendSlice(ctx.aa, esc);
        try out.appendSlice(ctx.aa, "</a>");
    } else if (s.style.link) {
        try syncTagsPairs(st, ctx.aa, pc, span_off, span_end, s.style.bold, s.style.italic, s.style.strikethrough, out);
        const href_raw = s.link_target orelse "";
        var href = try escapeUrl(ctx.aa, href_raw, true);
        // Bare email autolinks need the mailto: scheme in href.
        if (!std.mem.startsWith(u8, href_raw, "mailto:") and
            std.mem.indexOfScalar(u8, href_raw, '@') != null and
            std.mem.indexOfScalar(u8, href_raw, ':') == null)
        {
            href = try std.mem.concat(ctx.aa, u8, &.{ "mailto:", href });
        }
        const tag = try std.fmt.allocPrint(ctx.aa, "<a href=\"{s}\">", .{href});
        try out.appendSlice(ctx.aa, tag);
        // NOTE: production link text is a raw slice (no nested emphasis);
        // the harness models the spec here so divergences surface.
        var inner = TagStack{};
        var lrun: [parser.MAX_RUNS]parser.DelimRun = undefined;
        var lpair: [parser.MAX_PAIRS]parser.EmPair = undefined;
        var lseg: [parser.MAX_LINK_SEGS]parser.LinkSeg = undefined;
        const lpc = buildPairCtxDefs(s.text, &lrun, &lpair, &lseg, ctx.defs.slice());
        try renderInlineStPc(ctx, s.text, out, &inner, lpc, false);
        try syncTagsPairs(&inner, ctx.aa, lpc, s.text.len, s.text.len, false, false, false, out);
        try out.appendSlice(ctx.aa, "</a>");
    } else {
        try syncTagsPairs(st, ctx.aa, pc, span_off, span_end, s.style.bold, s.style.italic, s.style.strikethrough, out);
        try out.appendSlice(ctx.aa, esc);
    }
}

fn renderFence(ctx: Ctx, open_line: []const u8, body: []simd.Line, out: *std.ArrayList(u8)) HError!void {
    // Info string: text after the opening run, trimmed.
    const t = trimSpaces(open_line);
    // Content lines lose up to the fence's own indent (reference rule).
    const fence_indent = indentWidth(open_line, ctx.phase);
    var k: usize = 0;
    const fc = t[0];
    while (k < t.len and t[k] == fc) : (k += 1) {}
    const info = trimSpaces(t[k..]);
    if (info.len > 0) {
        // Info cleaning mirrors the reference: entity decode, trim,
        // backslash unescape; first word only, then HTML-escape.
        const dec = try decodeEntities(ctx.aa, info);
        const clean = try backslashUnescape(ctx.aa, trimSpaces(dec));
        var w = clean.len;
        for (clean, 0..) |ch, idx| {
            if (ch == ' ' or ch == '\t') {
                w = idx;
                break;
            }
        }
        const lang = try escapeCode(ctx.aa, clean[0..w]);
        const tag = try std.fmt.allocPrint(ctx.aa, "<pre><code class=\"language-{s}\">", .{lang});
        try out.appendSlice(ctx.aa, tag);
    } else {
        try out.appendSlice(ctx.aa, "<pre><code>");
    }
    for (body) |bl| {
        const bt = lineText(ctx.md, bl);
        const dedented = try coldent(ctx.aa, bt, fence_indent, ctx.phase);
        const esc = try escapeCode(ctx.aa, dedented);
        try out.appendSlice(ctx.aa, esc);
        try out.append(ctx.aa, '\n');
    }
    try out.appendSlice(ctx.aa, "</code></pre>\n");
}

fn renderIndentedCode(ctx: Ctx, lines: []simd.Line, i: usize, out: *std.ArrayList(u8)) HError!usize {
    // Collect indented lines; single blanks survive only between code.
    var j = i;
    var last_code = i;
    var k = i;
    while (k < lines.len) {
        const t = lineText(ctx.md, lines[k]);
        if (isBlankText(t)) {
            k += 1;
            continue;
        }
        // Any 4+-column line is code content here (callers guarantee code
        // position); structural types cannot open blocks at this indent.
        if (indentWidth(t, ctx.phase) < 4) break;
        last_code = k;
        k += 1;
    }
    j = last_code + 1;
    try out.appendSlice(ctx.aa, "<pre><code>");
    var p = i;
    while (p <= last_code) : (p += 1) {
        const t = lineText(ctx.md, lines[p]);
        if (isBlankText(t)) {
            // Whitespace-only lines keep what survives the code indent
            // (`      ` renders `  `, not an empty line).
            const rest = try coldent(ctx.aa, t, 4, ctx.phase);
            try out.appendSlice(ctx.aa, rest);
            try out.append(ctx.aa, '\n');
        } else {
            const esc = try escapeCode(ctx.aa, try stripCodeIndent(ctx.aa, t, ctx.phase));
            try out.appendSlice(ctx.aa, esc);
            try out.append(ctx.aa, '\n');
        }
    }
    try out.appendSlice(ctx.aa, "</code></pre>\n");
    return j;
}

fn renderStandaloneImage(ctx: Ctx, text: []const u8, out: *std.ArrayList(u8)) HError!void {
    // `![alt](url)` alone on a line: paragraph-wrapped img.
    var spans: [8]parser.InlineSpan = undefined;
    const n = parser.parseInlinesWithDefs(text, &spans, ctx.defs.slice());
    try out.appendSlice(ctx.aa, "<p>");
    var done = false;
    for (spans[0..n]) |s| {
        if (s.style.image and !done) {
            done = true;
            var altbuf: std.ArrayList(u8) = .empty;
            try renderAltText(ctx, s.text, &altbuf);
            const alt = try decodeAndEscape(ctx.aa, altbuf.items, true);
            const src = try escapeUrl(ctx.aa, s.link_target orelse "", true);
            const tag = try std.fmt.allocPrint(ctx.aa, "<img src=\"{s}\" alt=\"{s}\" />", .{ src, alt });
            try out.appendSlice(ctx.aa, tag);
        } else {
            try renderInline(ctx, s.text, out);
        }
    }
    if (!done) try renderInline(ctx, text, out);
    try out.appendSlice(ctx.aa, "</p>\n");
}

/// Join paragraph lines with soft breaks (trailing spaces preserved for
/// hard-break detection) and render inline content.
fn renderJoinedInline(ctx: Ctx, group: []simd.Line, out: *std.ArrayList(u8)) HError!void {
    var buf: std.ArrayList(u8) = .empty;
    for (group, 0..) |l, k| {
        if (k > 0) try buf.append(ctx.aa, '\n');
        try buf.appendSlice(ctx.aa, stripLeading(lineText(ctx.md, l)));
    }
    try renderInline(ctx, buf.items, out);
}

test "commonmark 0.31.2: file-driven conformance" {
    const backing = std.testing.allocator;
    var loaded = try loadExamples(backing);
    defer loaded.arena.deinit();

    var total: usize = 0;
    var excluded_html: usize = 0;
    var excluded_listed: usize = 0;
    var passed: usize = 0;
    var failed: usize = 0;
    var shown: usize = 0;

    for (loaded.items) |ex| {
        total += 1;
        if (ex.has_html) {
            excluded_html += 1;
            continue;
        }
        if (isExcluded(ex.num) != null) {
            excluded_listed += 1;
            continue;
        }
        var frame = std.heap.ArenaAllocator.init(backing);
        defer frame.deinit();
        const got = renderHtml(frame.allocator(), ex.md) catch |err| {
            std.debug.print("ex {d}: render error {}\n", .{ ex.num, err });
            failed += 1;
            continue;
        };
        if (std.mem.eql(u8, got, ex.expected)) {
            passed += 1;
        } else {
            failed += 1;
            if (shown < 10000) {
                shown += 1;
                std.debug.print("--- ex {d} FAIL ---\ninput:\n{s}\nexpected:\n{s}\ngot:\n{s}\n", .{ ex.num, ex.md, ex.expected, got });
            }
        }
    }
    std.debug.print("commonmark: total={d} html_excluded={d} listed_excluded={d} passed={d} failed={d}\n", .{
        total, excluded_html, excluded_listed, passed, failed,
    });
    if (ENFORCE_GATE) try std.testing.expectEqual(@as(usize, 0), failed);
}


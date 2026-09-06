const std = @import("std");

/// Remote-image privacy policy (issue #52).
///
/// Pure, zero-allocation URL classification + the transport contract.
/// The Zig side enforces the policy at two choke points in `src/main.zig`
/// (size queries and draws): a blocked URL never reaches the platform
/// loader, so no fetch is ever kicked for it — this holds both today
/// (remote loads degrade to placeholders) and once #45 lands its async
/// loader. Transport-level rules (redirects, timeouts, cookies) are
/// normative constants below: the platform loader MUST honor them.
///
/// Proposal implemented (per #52): load remote content by default (per
/// #45) with a visible indicator + one-key toggle (`i`) that drops all
/// remote content to placeholders.
pub const RemoteEnabledDefault = true;

/// Transport contract for the platform image loader (#45). Pinned by
/// tests below so the limits cannot be silently loosened.
pub const MAX_REDIRECTS: u8 = 3;
pub const FETCH_TIMEOUT_MS: u32 = 8_000;
pub const MAX_HEADER_BYTES: usize = 16 * 1024;
pub const MAX_IMAGE_BYTES: usize = 8 * 1024 * 1024;

/// Trims ASCII whitespace and C0 controls from both ends. Returns the
/// trimmed slice (same backing memory, zero allocation).
fn trimNoise(url: []const u8) []const u8 {
    var s = url;
    while (s.len > 0 and (s[0] <= 0x20 or s[0] == 0x7F)) s = s[1..];
    while (s.len > 0 and (s[s.len - 1] <= 0x20 or s[s.len - 1] == 0x7F)) s = s[0 .. s.len - 1];
    return s;
}

fn startsWithIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (hay.len < needle.len) return false;
    for (needle, 0..) |c, i| {
        var h = hay[i];
        if (h >= 'A' and h <= 'Z') h += 'a' - 'A';
        var n = c;
        if (n >= 'A' and n <= 'Z') n += 'a' - 'A';
        if (h != n) return false;
    }
    return true;
}

/// True for `http://` / `https://` URLs (case-insensitive scheme, leading
/// noise trimmed). Everything else — relative paths, absolute paths,
/// `data:` URIs, protocol-relative `//host/…` — is local/inline content
/// that performs no fetch and is never gated. Unknown input fails safe:
/// unparseable text is not remote, so it can only ever hit the local
/// resolver (which fails closed to a placeholder).
pub fn isRemoteUrl(url: []const u8) bool {
    const s = trimNoise(url);
    // A bare scheme with no authority ("https://") is not fetchable: fail
    // safe to local handling (placeholder), never to the network.
    if (s.len > 8 and startsWithIgnoreCase(s, "https://")) return true;
    if (s.len > 7 and startsWithIgnoreCase(s, "http://")) return true;
    return false;
}

/// True only for `https://` (same trimming/folding as `isRemoteUrl`).
pub fn isHttpsUrl(url: []const u8) bool {
    return startsWithIgnoreCase(trimNoise(url), "https://");
}

/// True when the authority carries `user:pass@` credentials
/// (`https://user:pass@host/…`). An `@` after the first `/`, `?`, or `#`
/// is a path character, not credentials.
pub fn hasCredentials(url: []const u8) bool {
    const s = trimNoise(url);
    var i: usize = 0;
    // Skip the scheme.
    while (i < s.len and s[i] != ':') : (i += 1) {}
    if (i + 2 >= s.len or s[i + 1] != '/' or s[i + 2] != '/') return false;
    i += 3;
    const auth_start = i;
    while (i < s.len and s[i] != '/' and s[i] != '?' and s[i] != '#') : (i += 1) {}
    return std.mem.indexOfScalar(u8, s[auth_start..i], '@') != null;
}

/// The single enforcement predicate. True = do not fetch: render the
/// placeholder instead and never hand the URL to the platform loader.
///   - Remote content with the `i` toggle off: blocked.
///   - Plain `http://`: blocked even when enabled (HTTPS-only; no
///     silent cleartext leak, no downgrade negotiation).
///   - Remote URLs with embedded credentials: blocked (nothing secret
///     is ever sent on the wire by accident or malice).
/// Local/inline content is never blocked.
pub fn blockedByPolicy(url: []const u8, remote_enabled: bool) bool {
    if (!isRemoteUrl(url)) return false;
    if (!remote_enabled) return true;
    if (!isHttpsUrl(url)) return true;
    if (hasCredentials(url)) return true;
    return false;
}

/// Decompression-bomb / oversized-header guard for the loader: reject a
/// response whose declared or accumulated body exceeds the cap. Pure so it
/// is unit-testable here; the platform loader calls the same predicate.
pub fn fitsImageBudget(body_bytes: usize) bool {
    return body_bytes <= MAX_IMAGE_BYTES;
}

test "remote policy: local content is never gated" {
    const local = [_][]const u8{
        "./assets/shot.png",
        "assets/shot.png",
        "/abs/path/shot.png",
        "shot.png",
        "data:image/png;base64,iVBOR",
        "",
        "   ",
        "#fragment",
    };
    for (local) |u| {
        try std.testing.expect(!isRemoteUrl(u));
        try std.testing.expect(!blockedByPolicy(u, true));
        try std.testing.expect(!blockedByPolicy(u, false));
    }
}

test "remote policy: https loads by default, drops with the toggle" {
    const u = "https://example.com/img.png";
    try std.testing.expect(isRemoteUrl(u));
    try std.testing.expect(isHttpsUrl(u));
    try std.testing.expect(!blockedByPolicy(u, true));
    try std.testing.expect(blockedByPolicy(u, false));
}

test "remote policy: http is blocked even when remote is enabled" {
    const u = "http://example.com/img.png";
    try std.testing.expect(isRemoteUrl(u));
    try std.testing.expect(!isHttpsUrl(u));
    try std.testing.expect(blockedByPolicy(u, true));
    try std.testing.expect(blockedByPolicy(u, false));
}

test "remote policy: hostile scheme spellings fail safe" {
    // Case folding must not smuggle http past the https-only rule…
    try std.testing.expect(blockedByPolicy("HTTP://example.com/a.png", true));
    try std.testing.expect(blockedByPolicy("HtTp://example.com/a.png", true));
    try std.testing.expect(!blockedByPolicy("HTTPS://example.com/a.png", true));
    try std.testing.expect(blockedByPolicy("HTTPS://example.com/a.png", false));
    // …leading noise is trimmed, not trusted…
    try std.testing.expect(!blockedByPolicy("  \t\nhttps://example.com/a.png  ", true));
    try std.testing.expect(blockedByPolicy("\x01https://example.com/a.png", false));
    // …and malformed schemes are not remote at all (local resolver fails
    // closed to a placeholder; nothing is fetched).
    const not_remote = [_][]const u8{
        "https ://example.com/a.png",
        "https://",
        "http:/example.com",
        "httpx://example.com/a.png",
        "//example.com/a.png",
        "java\tscript:https://example.com/a.png",
    };
    for (not_remote) |u| {
        try std.testing.expect(!isRemoteUrl(u));
    }
    // Protocol-relative URLs stay local (never fetched as remote).
    try std.testing.expect(!blockedByPolicy("//example.com/a.png", true));
}

test "remote policy: embedded credentials are never sent" {
    try std.testing.expect(hasCredentials("https://user:pass@example.com/a.png"));
    try std.testing.expect(hasCredentials("https://user@example.com/a.png"));
    try std.testing.expect(blockedByPolicy("https://user:pass@example.com/a.png", true));
    try std.testing.expect(!hasCredentials("https://example.com/a@b.png"));
    try std.testing.expect(!hasCredentials("https://example.com/@user/a.png"));
    try std.testing.expect(!blockedByPolicy("https://example.com/a@b.png", true));
    try std.testing.expect(!hasCredentials("./local@file.png"));
}

test "remote policy: transport contract is pinned" {
    // The loader (#45) MUST honor these; the values are asserted here so
    // a transport change cannot silently relax them.
    try std.testing.expectEqual(@as(u8, 3), MAX_REDIRECTS);
    try std.testing.expectEqual(@as(u32, 8_000), FETCH_TIMEOUT_MS);
    try std.testing.expectEqual(@as(usize, 16 * 1024), MAX_HEADER_BYTES);
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), MAX_IMAGE_BYTES);
    try std.testing.expect(fitsImageBudget(0));
    try std.testing.expect(fitsImageBudget(MAX_IMAGE_BYTES));
    try std.testing.expect(!fitsImageBudget(MAX_IMAGE_BYTES + 1));
    // No credentials/cookies/Referer are ever stored or sent: the policy
    // carries no jars, no caches keyed by origin, no referrer field —
    // enforced by construction (this module has no state at all).
}

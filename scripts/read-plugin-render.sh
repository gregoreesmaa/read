#!/bin/sh
# Plugin renderer driver (spec docs/plugins-async-spec.md §3).
# Usage: read-plugin-render.sh probe <renderer>
#        read-plugin-render.sh render <renderer> <srcfile> <outfile>
# probe: exit 0 when the renderer is usable, 1 otherwise. For the math
#   slot this is a CAPABILITY CANARY (see below), not a presence check.
# render: re-probes, renders SRC to OUT atomically (OUT.tmp + rename).
set -eu

tool_for() {
    case "$1" in
        mermaid) echo "mmdc" ;;
        # math has no single tool: probe/render below try katex, mjpage,
        # mathjax in order (shared slot, issues #326/#327).
        *) echo "" ;;
    esac
}

# --- math capability canary (issues #326/#327) ---
# No canonical PNG CLI exists for TeX math: the KaTeX CLI is TeX→HTML
# only, and stock mjpage/mathjax CLIs likewise emit no PNG, so a
# presence probe (`command -v katex`) would lie — probe-true with
# render-always-fail. The math probe is therefore a CAPABILITY CANARY:
# each first-present tool in katex→mjpage→mathjax order renders a
# minimal TeX snippet to a tmp file with the convention flags, and the
# probe passes only when those bytes carry PNG magic (89 50 4E 47).
# The first tool passing wins; its name is recorded in the canary file
# so the render path reuses the proven tool. Probe verdicts stay
# session-cached by the launcher (spec §5); the file is an
# intra-session handoff only, re-validated at every render, so a stale
# entry fails closed, never open.
math_canary_file() {
    echo "${READ_MATH_CANARY_FILE:-${TMPDIR:-/tmp}/read-math-canary}"
}

is_png() {
    command -v od >/dev/null 2>&1 || return 1
    [ -f "$1" ] || return 1
    [ "$(head -c 4 "$1" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \t\n')" = "89504e47" ]
}

# Render SRC to DST with TOOL under the math convention flags: katex
# and mjpage take `TOOL SRC -o DST`, mathjax takes `TOOL SRC DST`.
# User wrappers that speak the convention light up; anything else
# fails the canary and stays naive.
math_render_with() {
    mc_tool="$1"; mc_src="$2"; mc_dst="$3"
    case "$mc_tool" in
        katex|mjpage) "$mc_tool" "$mc_src" -o "$mc_dst" 2>/dev/null ;;
        mathjax) "$mc_tool" "$mc_src" "$mc_dst" 2>/dev/null ;;
        *) return 1 ;;
    esac
}

# Run TOOL's canary: minimal TeX through the convention flags, PNG
# magic required. Records the winner in the canary file on success.
math_try_tool() {
    mc_try="$1"
    command -v "$mc_try" >/dev/null 2>&1 || return 1
    mc_tmpdir="${TMPDIR:-/tmp}"
    mc_src=$(mktemp "$mc_tmpdir/read-math-src.XXXXXX") || return 1
    mc_dst="$mc_src.png"
    printf 'x^2\n' > "$mc_src"
    if math_render_with "$mc_try" "$mc_src" "$mc_dst" && is_png "$mc_dst"; then
        printf '%s\n' "$mc_try" > "$(math_canary_file)"
        rm -f "$mc_src" "$mc_dst"
        return 0
    fi
    rm -f "$mc_src" "$mc_dst"
    return 1
}

# Probe entry: first capable tool wins; none capable → false (naive).
math_canary() {
    for mc_t in katex mjpage mathjax; do
        math_try_tool "$mc_t" && return 0
    done
    rm -f "$(math_canary_file)"
    return 1
}

# Render entry: the canary-proven tool — cached winner re-validated,
# else a fresh canary — so one broken CLI cannot wedge the slot.
math_capable_tool() {
    mc_cache="$(math_canary_file)"
    if [ -f "$mc_cache" ]; then
        mc_tool=$(head -n 1 "$mc_cache" 2>/dev/null || true)
        case "$mc_tool" in
            katex|mjpage|mathjax)
                if command -v "$mc_tool" >/dev/null 2>&1; then
                    printf '%s\n' "$mc_tool"
                    return 0
                fi
                ;;
        esac
    fi
    for mc_t in katex mjpage mathjax; do
        if math_try_tool "$mc_t"; then
            printf '%s\n' "$mc_t"
            return 0
        fi
    done
    return 1
}

if [ "${1:-}" = "probe" ]; then
    if [ "${2:-}" = "math" ]; then
        # Capability canary, not presence: stock katex/mjpage/mathjax
        # CLIs cannot emit PNG, so they probe false → naive code cards
        # (no spawn, no indicator flicker).
        if math_canary; then exit 0; else exit 1; fi
    fi
    tool=$(tool_for "${2:-}")
    [ -n "$tool" ] && command -v "$tool" >/dev/null 2>&1
    exit $?
fi

if [ "${1:-}" = "render" ]; then
    renderer="$2"; src="$3"; out="$4"
    if [ "$renderer" != "math" ]; then
        tool=$(tool_for "$renderer")
        [ -n "$tool" ] || exit 1
        command -v "$tool" >/dev/null 2>&1 || exit 1
    fi
    # Drop any stale tmp from a crashed earlier run so a succeeding render
    # can never promote previous bytes (Task 5 scope: OUT.tmp + rename).
    rm -f "$out.tmp"
    case "$renderer" in
        mermaid) "$tool" -i "$src" -o "$out.tmp" ;;
        math)
            # Render with the canary-proven tool only; promote PNG
            # bytes or nothing (the reader-side decode check fails
            # closed on top of this).
            if mc_winner=$(math_capable_tool); then
                math_render_with "$mc_winner" "$src" "$out.tmp" || true
            fi
            if ! is_png "$out.tmp"; then
                rm -f "$out.tmp"
            fi
            ;;
    esac
    [ -f "$out.tmp" ] && mv "$out.tmp" "$out"
    exit 0
fi

echo "usage: $0 probe|render ..." >&2
exit 2

#!/bin/sh
# Two-account binary footprint gate (see AGENTS.md §7: the ship binary
# carries a core account and a plugin account, measured via the
# differential twin).
#
# Builds the ship binary and its no-plugins twin, then compares __TEXT
# segment bytes (never file bytes — page padding lies: file bytes can jump
# a full 16 KiB page on a few dozen bytes of __text):
#   plugin_bytes = __TEXT(ship) - __TEXT(twin)
#   core_bytes   = __TEXT(ship) - plugin_bytes (= __TEXT(twin))
# FAILs when core exceeds CORE_BUDGET or plugin exceeds PLUGIN_BUDGET.
# Also reports __TEXT headroom to the next 16 KiB page: a headroom warning
# is advisory, not a failure — but treat it as a diet order for the next
# platform-glue change. New ship code belongs at end-of-file (see the SIZE
# NOTE on prime_frame_decode in src/platform/macos.m).
#
# Usage: scripts/size_gate.sh [ship-binary]
set -eu

cd "$(dirname "$0")/.."

BIN="${1:-zig-out/bin/read}"
TWIN="zig-out/twin/read-noplugins"
# Windows: the ship binary is read.exe, and the twin keeps the same name
# under twin/ (build.zig renames to read-noplugins only when the name
# does not already carry the platform .exe suffix... it does not, so
# probe both spellings). Resolved after the builds below.
OPTIMIZE="${SIZE_GATE_OPTIMIZE:-ReleaseFast}"

# OS id for the text-segment reader below. Hoisted out of the function:
# `$(uname -s)` in a case pattern inside a function body returns empty
# under this repo's Git sh (5.3.9 cygwin) — observed as `++ uname -s`
# with no output — while the identical substitution at top level works.
OS_ID=other
case "$(uname -s)" in
    Linux) OS_ID=linux ;;
    MINGW*|MSYS*|CYGWIN*) OS_ID=pe ;;
esac

# Budgets (see AGENTS.md §7 budget history). The 200 KiB number is the
# Mach-O/ELF first-party-code budget (dynamic libc: libSystem, musl-static
# actually measures SMALLER on ELF — 156 KiB core on Linux 2026-10).
# Windows links the CRT + startup code statically into .text, so its
# first-party ruler starts higher: PE core budget is 280 KiB (measured
# 258560 ship .text on 2026-10-03 with the Win32 backend: ~35 KiB C glue
# + shared Zig + ~60 KiB static CRT/startup that Mach-O/ELF get from the
# system). Same plugin account everywhere (twin differential).
CORE_BUDGET=$((200 * 1024))
if [ "$OS_ID" = "pe" ]; then CORE_BUDGET=$((280 * 1024)); fi
# Plugin account: twin-measured 8062 bytes on 2026-09-12 + 4 KiB headroom,
# rounded up to a whole KiB; bumped to 13 KiB by owner decision 2026-09-20
# (§7 5%: 12*1.05=12.6, round up) for the MATH rule-thickness hook;
# bumped to 15 KiB by owner decision 2026-09-27 (§7 5%: 13*1.05=13.65,
# round up to 14, but measured 14508 needs 15) for the #355 Retina formula atlas;
# bumped to 16 KiB by coordinator decision 2026-09-28 (§7 5%: 15*1.05=15.75,
# round up) for #348 native math/ARM after exhausted honest diet (residual 694 B
# plugin over: 4 area agents + whole-view ±0 + round-2/round-3/finisher/micro-diet
# with measured probes, lean audit clean, small-loss evaluated, nothing qualifying).
PLUGIN_BUDGET_KIB=16
PLUGIN_BUDGET=$((PLUGIN_BUDGET_KIB * 1024))

# Build both accounts; zig-cache incrementality makes this a fast no-op
# when artifacts are current (no caching hacks here).
zig build -Doptimize="$OPTIMIZE"
zig build -Doptimize="$OPTIMIZE" -Dplugin_stub=true

# Twin spelling: build.zig names it read-noplugins, but Windows appends
# .exe to every artifact (read-noplugins.exe under twin/).
case "$TWIN" in
    *.exe) ;;
    *) if [ ! -f "$TWIN" ] && [ -f "$TWIN.exe" ]; then TWIN="$TWIN.exe"; fi ;;
esac
# Same for the ship binary when invoked with the extensionless default.
case "$BIN" in
    *.exe) ;;
    *) if [ ! -f "$BIN" ] && [ -f "$BIN.exe" ]; then BIN="$BIN.exe"; fi ;;
esac

[ -f "$BIN" ] || { echo "FAIL: ship binary not found: $BIN"; exit 2; }
[ -f "$TWIN" ] || { echo "FAIL: twin binary not found: $TWIN"; exit 2; }

# (OS_ID + CORE_BUDGET settled at the top, before the plugin history.)

# PESIZE prints "272384\r\n" (CRLF: the tool writes \n, the MSYS layer
# translates). This repo's Git sh (5.3.9 cygwin) cannot hold newlines
# from a native .exe in $(...): the capture arrives empty even though
# the same bytes print fine un-captured. So the PE branch writes the
# number to a temp file and the caller reads it back — no capture.
textseg_to() {
    case "$OS_ID" in
        linux)
            # ELF: the `text` column of size -B (Berkeley) plays the __TEXT
            # role (executable segment bytes, never file bytes — page padding
            # lies the same way). Same budgets as Darwin (AGENTS.md §7).
            size -B "$2" 2>/dev/null | awk 'NR==2 {print $1}' > "$1"
            ;;
        pe)
            # PE (Windows runners): .text raw bytes via scripts/pesize.zig
            # (compiled once per job into $RUNNER_TEMP/pesize.exe; Zig 0.16
            # ships no llvm-size). Same budgets as Darwin (AGENTS.md §7).
            # The number goes through a small batch file: cmd.exe
            # interactive banners ("Microsoft Windows...") pollute direct
            # `cmd /c` stdout under sh, but a .bat's redirected output is
            # clean. PESIZE is passed Windows-form (C:\...) — cmd's %1
            # keeps it intact (no MSYS path mangling inside the batch).
            if [ -n "${PESIZE:-}" ]; then
                PESIZE_BIN="$PESIZE"
            elif [ -n "${RUNNER_TEMP:-}" ]; then
                PESIZE_BIN="$RUNNER_TEMP/pesize.exe"
            elif [ -n "${TEMP:-}" ]; then
                PESIZE_BIN="$TEMP/pesize.exe"
            else
                PESIZE_BIN="C:/Windows/Temp/pesize.exe"
            fi
            # Backslash translation uses sed (this repo's tr mishandles
            # backslash sets — "missing operand").
            to_bsl() { echo "$2" | sed 's/\//\\/g'; }
            if command -v cygpath >/dev/null 2>&1; then
                GATE_BAT="$(cygpath -u "${RUNNER_TEMP:-$TEMP}")/size-gate-tmp/run.bat"
            else
                GATE_BAT="${RUNNER_TEMP:-$TEMP}/size-gate-tmp/run.bat"
            fi
            mkdir -p "$(dirname "$GATE_BAT")"
            PESIZE_BSL="$(to_bsl x "$PESIZE_BIN")"
            # Run through the batch file (MSYS executes a POSIX-spelled
            # .bat via cmd itself): the .bat carries the redirect, so
            # sh-side capture/redirection quirks never enter. Redirect
            # targets inside a .bat resolve correctly ONLY to absolute
            # Windows-form paths (observed: repo-relative writes 0
            # bytes). Inputs likewise must be absolute Windows-form.
            # Everything is recomputed per call (no stale globals: the
            # caller invokes ship first, twin second).
            case "$2" in
                /*) GATE_IN_POSIX="$2" ;;
                *) GATE_IN_POSIX="$(pwd)/$2" ;;
            esac
            if command -v cygpath >/dev/null 2>&1; then
                GATE_IN_WIN="$(cygpath -w "$GATE_IN_POSIX")"
                GATE_OUT_WIN="$(cygpath -w "$(pwd)/$1")"
            else
                GATE_IN_WIN="$GATE_IN_POSIX"
                GATE_OUT_WIN="$1"
            fi
            printf '@echo off\r\n"%s" "%s" "%s"\r\n' "$PESIZE_BSL" "$GATE_IN_WIN" "$GATE_OUT_WIN" > "$GATE_BAT"
            # Execute the .bat the way that works from sh: bare C:/... forward
            # path (observed: writes bytes; cmd /c and quoted forms re-enter
            # interactive cmd or mangle the path). The .bat's own redirect
            # does the file writing, so sh never touches the .exe's stdout.
            # The .bat MUST run with stdout connected to the terminal: with
            # `> /dev/null` the redirect target inherits the null handle
            # (observed: 0-byte outputs). Stderr stays on the job log.
            if command -v cygpath >/dev/null 2>&1; then
                GATE_BAT_WIN="$(cygpath -w "$GATE_BAT")"
                case "$GATE_BAT_WIN" in
                    *:*) GATE_BAT_RUN="$(echo "$GATE_BAT_WIN" | sed 's/\\/\//g')" ;;
                    *) GATE_BAT_RUN="$GATE_BAT_WIN" ;;
                esac
            else
                GATE_BAT_RUN="$GATE_BAT"
            fi
            "$GATE_BAT_RUN" 2>/dev/null
            ;;
        *)
            size -m "$2" 2>/dev/null | sed -n 's/^Segment __TEXT: \([0-9][0-9]*\).*/\1/p' > "$1"
            ;;
    esac
}

# Number files: POSIX branches write into ./.zig-cache (same dir the
# script cd'd into); the PE branch uses the same paths (the batch file
# receives Windows spellings via cygpath -w; outputs return to the
# repo-relative POSIX paths directly).
GATE_TMP="./.zig-cache/size-gate-tmp"
mkdir -p "$GATE_TMP"
SHIP_TXT="$GATE_TMP/ship.txt"
TWIN_TXT="$GATE_TMP/twin.txt"
textseg_to "$SHIP_TXT" "$BIN"
textseg_to "$TWIN_TXT" "$TWIN"
ship_text=$(cat "$SHIP_TXT")
twin_text=$(cat "$TWIN_TXT")
rm -f "$SHIP_TXT" "$TWIN_TXT"
[ -n "$ship_text" ] || { echo "FAIL: no __TEXT segment in $BIN"; exit 2; }
[ -n "$twin_text" ] || { echo "FAIL: no __TEXT segment in $TWIN"; exit 2; }

plugin=$((ship_text - twin_text))
[ "$plugin" -ge 0 ] || { echo "FAIL: twin __TEXT ($twin_text) exceeds ship __TEXT ($ship_text)"; exit 2; }
core=$((ship_text - plugin))

bytes=$(stat -f%z "$BIN" 2>/dev/null || stat -c%s "$BIN")
pages=$(( (ship_text + 16383) / 16384 ))
headroom=$(( pages * 16384 - ship_text ))

echo "core=$core bytes plugin=$plugin bytes total __TEXT=$ship_text bytes (file=$bytes bytes)"
echo "budgets: core<=$CORE_BUDGET plugin<=$PLUGIN_BUDGET"

fail=0
if [ "$core" -gt "$CORE_BUDGET" ]; then
    echo "FAIL: core account is $core bytes (> $CORE_BUDGET = 200 KiB budget)"
    fail=1
fi
if [ "$plugin" -gt "$PLUGIN_BUDGET" ]; then
    echo "FAIL: plugin account is $plugin bytes (> $PLUGIN_BUDGET = ${PLUGIN_BUDGET_KIB} KiB budget)"
    fail=1
fi
if [ "$headroom" -lt 512 ]; then
    echo "WARN: only ${headroom}B of __TEXT headroom to the next page; the next glue change likely costs 16 KiB"
fi

if [ "$fail" = 0 ]; then
    echo "PASS: core and plugin accounts within budget"
fi
exit $fail

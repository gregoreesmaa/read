#!/bin/sh
# Parser + line-scanner short fuzz (issue #34: malformed + huge inputs).
#
# Builds the standalone harness (`zig build fuzz` installs
# zig-out/bin/fuzz-parser, which shares only the platform-independent core
# and is never shipped) and runs it over the checked-in seed corpus plus
# generated hostile inputs: 1 MiB single line, 2 MiB single line (past the
# u20 Line.len clamp), 50k-line and 300k-line files (line-index truncation
# path), NUL bytes, bare CRs, deterministic random bytes, deep delimiter
# nesting. Every case must exit 0; any crash, hang (the CI job timeout is
# the backstop), or nonzero exit fails.
#
# The 50k-line worst case also reports scan/total µs for the log; the
# binding <400 µs gate is owned by src/core/strict_benchmarks.zig.
#
# Usage: sh scripts/fuzz_parser.sh [corpus-dir]
set -eu

cd "$(dirname "$0")/.."

CORPUS="${1:-test/fuzz/corpus}"
FUZZDIR="${TMPDIR:-/tmp}/read-fuzz-$$"
mkdir -p "$FUZZDIR"

echo "building fuzz harness..."
zig build fuzz -Doptimize=ReleaseFast
BIN="zig-out/bin/fuzz-parser"

# $1 = file, $2 = label
run_one() {
    out=$("$BIN" "$1" 2>&1) || {
        echo "FAIL: $2 exited nonzero: $out"
        return 1
    }
    case "$out" in
        "ok: "*) echo "ok: $2 -- $out" ;;
        *) echo "FAIL: $2 unexpected output: $out"; return 1 ;;
    esac
}

fail=0
cases=0
run() {
    cases=$((cases + 1))
    run_one "$@" || fail=1
}

echo "--- seed corpus ($CORPUS) ---"
for seed in "$CORPUS"/*.md; do
    run "$seed" "seed $(basename "$seed")"
done

echo "--- generated hostile inputs ---"
# 1 MiB single line (the u20 Line.len clamp edge is at 1048575 bytes).
python3 - "$FUZZDIR" <<'EOF'
import sys
d = sys.argv[1]
open(d + '/line_1m.txt', 'w').write('a' * 1048576 + '\n')
open(d + '/line_2m.txt', 'w').write('# ' + 'b' * 2097152 + '\n')
chunk = ['# Title %d' % i if i % 5 == 0 else
         '> quote %d' % i if i % 5 == 1 else
         '- item `code %d` **bold** and *it*' % i if i % 5 == 2 else
         '' if i % 5 == 3 else
         'para %d with [link](https://e.com/%d)' % (i, i)
         for i in range(50000)]
open(d + '/lines_50k.md', 'w').write('\n'.join(chunk) + '\n')
open(d + '/lines_300k.md', 'w').write(''.join('- item %d **b**\n' % i for i in range(300000)))
open(d + '/nul.bin', 'wb').write(b'\x00' * 4096 + b'# h\x00i\n' + bytes(range(256)) * 16)
import random
random.seed(3401)
alpha = b'`*[#]>|\t\r\n ~_abZ09:/.()!-<&\x00\xff'
open(d + '/rand.bin', 'wb').write(bytes(random.choice(alpha) for _ in range(65536)))
open(d + '/nest.md', 'w').write('*' * 5000 + '\n' + '_' * 5000 + '\n' + '[' * 2000 + 'x' + ']' * 2000 + '\n')
EOF
run "$FUZZDIR/line_1m.txt" "1MiB single line"
run "$FUZZDIR/line_2m.txt" "2MiB single line (past len clamp)"
run "$FUZZDIR/lines_50k.md" "50k lines"
run "$FUZZDIR/lines_300k.md" "300k lines (index truncation)"
run "$FUZZDIR/nul.bin" "NUL/high bytes"
run "$FUZZDIR/rand.bin" "random bytes (seed 3401)"
run "$FUZZDIR/nest.md" "deep nesting"
# Empty + newline-only + no-trailing-newline edges.
: > "$FUZZDIR/empty.md"
printf '\n\n\n' > "$FUZZDIR/newlines.md"
printf '# no trailing newline' > "$FUZZDIR/noeol.md"
run "$FUZZDIR/empty.md" "empty file"
run "$FUZZDIR/newlines.md" "newlines only"
run "$FUZZDIR/noeol.md" "no trailing newline"

rm -rf "$FUZZDIR"
if [ "$fail" = 0 ]; then
    echo "PASS: parser fuzz clean ($cases cases, no crash/hang/OOM)"
fi
exit $fail

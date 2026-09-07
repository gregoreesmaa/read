#!/bin/sh
# test_cases discipline gate (see AGENTS.md §6, CONTRIBUTING.md).
#
# Fails when the screenshotted suite drifts: the four showcase documents
# must exist, and exactly one scrollable-document case
# (test_cases/scrollable_doc.md) may exist. Extra *scroll* cases, or a
# missing showcase case, fail the commit. Runs anywhere (no macOS needed).
set -eu

cd "$(dirname "$0")/.."

fail=0
deny() { echo "FAIL: $1"; fail=1; }

for f in text_wrapping.md spacings_headings.md code_and_tasks.md tables_formatting.md; do
    [ -f "test_cases/$f" ] || deny "missing showcase case test_cases/$f"
done

n_scroll=$(ls test_cases/*scroll*.md 2>/dev/null | wc -l | tr -d ' ')
if [ "$n_scroll" != "1" ]; then
    deny "want exactly 1 scrollable-doc test case, found $n_scroll"
elif [ ! -f test_cases/scrollable_doc.md ]; then
    deny "the single scrollable-doc case must be test_cases/scrollable_doc.md"
fi

if [ "$fail" = 0 ]; then
    echo "PASS: test_cases discipline holds (4 showcase + 1 scrollable-doc case)"
fi
exit $fail

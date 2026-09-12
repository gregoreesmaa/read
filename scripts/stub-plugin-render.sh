#!/bin/sh
# Test-only stub: probe always true, render copies the fixture PNG.
set -eu
FIXTURE="${STUB_FIXTURE:-test_cases/assets/stub-plugin.png}"
if [ "${1:-}" = "probe" ]; then exit 0; fi
if [ "${1:-}" = "render" ]; then cp "$FIXTURE" "$4"; exit 0; fi
exit 2

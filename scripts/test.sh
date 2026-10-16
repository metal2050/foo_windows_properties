#!/usr/bin/env bash
usage() {
  cat <<'USAGE'
Usage: scripts/test.sh
Builds (native architecture, -Wall -Wextra) and runs the unit tests:
  wpe_tests       the pure C++ model: merge, display, edits, plan/apply (no SDK, no Cocoa)
  wpe_sdk_tests   the SDK bridge: file_info adapter and the tag-writing filter
  wpe_ui_tests    the real Properties window driven by synthesized key/mouse events against an
                  in-memory backend; the window is never shown and nothing is saved
                  (skipped automatically when there is no window server session). It runs in the
                  classic AppKit design, as in foobar2000 (UIDesignRequiresCompatibility)
  wpe_ui_tests_macos26  the same tests in the macOS 26 design
  WPE_TEST_ONLY=a,b  run only the tests whose names contain one of these
  SDK_ROOT=/path  directory containing foobar2000/ and pfc/ (default: third_party/foobar2000-sdk)
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
set -euo pipefail
source "$(dirname "$0")/common.sh"
require_sdk
cd "$REPO"

cmake -S . -B build/tests -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Debug -DSDK_ROOT="$SDK_ROOT" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 >/dev/null
log=build/tests/build.log
if ! make -C build/tests wpe_tests wpe_sdk_tests wpe_ui_tests wpe_ui_tests_macos26 -j"$JOBS" >"$log" 2>&1; then
  grep -E 'error|warning' "$log" >&2 || tail -40 "$log" >&2
  echo "test.sh: build failed (log: $log)" >&2
  exit 1
fi
grep -E 'warning:' "$log" || true
echo "tests built, $(grep -c 'warning:' "$log" || true) warning(s)"

# perl's alarm stands in for timeout(1), which macOS does not ship.
run() { perl -e 'alarm shift; exec @ARGV or die "exec: $!"' 120 "$@"; }
for t in wpe_tests wpe_sdk_tests wpe_ui_tests wpe_ui_tests_macos26; do
  echo "== $t"
  run "build/tests/$t"
done
echo "all tests passed"

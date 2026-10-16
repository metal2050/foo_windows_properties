#!/usr/bin/env bash
usage() {
  cat <<'USAGE'
Usage: scripts/build.sh
Builds the universal (arm64 + x86_64) component bundle -> build/foo_windows_properties.component
and ad-hoc signs it. Uses Unix Makefiles.
  SDK_ROOT=/path   directory containing foobar2000/ and pfc/ from the foobar2000 SDK
                   (default: third_party/foobar2000-sdk, see scripts/fetch-sdk.sh)
  JOBS=n           parallel make jobs
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
set -euo pipefail
source "$(dirname "$0")/common.sh"
require_sdk
cd "$REPO"

[ "$(uname)" = Darwin ] || { echo "build.sh: macOS only" >&2; exit 1; }
NAME=foo_windows_properties
OUT="build/$NAME.component"
for arch in arm64 x86_64; do
  cmake -S . -B "build/$arch" -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release -DSDK_ROOT="$SDK_ROOT" \
    -DCMAKE_OSX_ARCHITECTURES=$arch -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 -DWPE_BUILD_TESTS=OFF >/dev/null
  log="build/$arch/build.log"
  if ! make -C "build/$arch" $NAME -j"$JOBS" >"$log" 2>&1; then
    grep -E 'error|warning' "$log" >&2 || tail -40 "$log" >&2
    echo "build.sh: $arch build failed (log: $log)" >&2
    exit 1
  fi
  warnings=$(grep -c 'warning:' "$log" || true)
  grep -E 'warning:' "$log" || true
  echo "$arch: built, $warnings warning(s)"
done
rm -rf "$OUT"
cp -R "build/arm64/$NAME.component" "$OUT"
lipo -create "build/arm64/$NAME.component/Contents/MacOS/$NAME" "build/x86_64/$NAME.component/Contents/MacOS/$NAME" \
  -output "$OUT/Contents/MacOS/$NAME"
codesign --force --sign - "$OUT"
codesign --verify --strict "$OUT"
archs=$(lipo -archs "$OUT/Contents/MacOS/$NAME")
for want in arm64 x86_64; do
  case " $archs " in
    *" $want "*) ;;
    *) echo "build.sh: missing $want slice (got: $archs)" >&2; exit 1 ;;
  esac
done
minos=$(otool -l -arch arm64 "$OUT/Contents/MacOS/$NAME" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
echo "built: $OUT ($archs, macOS $minos+, ad-hoc signed)"

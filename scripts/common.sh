# Shared settings for the build scripts (sourced).
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The foobar2000 SDK: SDK_ROOT if set, else third_party/foobar2000-sdk in this repository
# (where scripts/fetch-sdk.sh puts it; not committed).
SDK_ROOT="${SDK_ROOT:-$REPO/third_party/foobar2000-sdk}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"

require_sdk() {
  if [ ! -d "$SDK_ROOT/foobar2000/SDK" ] || [ ! -d "$SDK_ROOT/pfc" ]; then
    echo "foobar2000 SDK not found in $SDK_ROOT (it needs foobar2000/ and pfc/)." >&2
    echo "Run scripts/fetch-sdk.sh, or set SDK_ROOT=/path/to/foobar2000-sdk." >&2
    exit 1
  fi
  SDK_ROOT="$(cd "$SDK_ROOT" && pwd)"
}

#!/usr/bin/env bash
# Downloads the foobar2000 SDK this component is built and tested with and unpacks it into
# third_party/foobar2000-sdk (not committed; the build scripts look there unless SDK_ROOT is set).
usage() {
  cat <<'USAGE'
Usage: scripts/fetch-sdk.sh [--force] [DEST]
Downloads the foobar2000 SDK (version 2026-10-01) from foobar2000.org and unpacks it into DEST
(default: third_party/foobar2000-sdk in this repository; SDK_ROOT is not used as a destination, so a shared SDK
elsewhere is never touched unless you name it as DEST).
  --force               replace a foobar2000 SDK of another version that is already in DEST (any other
                        non-empty folder is never replaced)
  SDK_ARCHIVE=/path     use an SDK-2026-10-01.7z you already downloaded instead of downloading it
  SDK_SHA256=hex        expect this SHA-256 instead of the pinned one (only if the archive is republished);
                        an archive with any other hash is refused
The archive is 7-Zip. macOS's own tar (bsdtar) unpacks it; 7zz or 7z are used when tar cannot.
USAGE
}
set -euo pipefail

SDK_VERSION=2026-10-01
SDK_VERSION_MACRO=20261001   # foobar2000/SDK/foobar2000-versions.h: FOOBAR2000_SDK_VERSION
SDK_URL="https://www.foobar2000.org/downloads/SDK-$SDK_VERSION.7z"   # linked from https://www.foobar2000.org/SDK
SDK_SHA256="${SDK_SHA256:-d4c55077336fae81bf8df0259b5b2748fa45ea84132c656ead93eb123cbcdc26}"   # of that archive (793738 bytes)
REPO="$(cd "$(dirname "$0")/.." && pwd)"

FORCE=0
DEST=""
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --force) FORCE=1 ;;
    -*) echo "fetch-sdk.sh: unknown option: $arg" >&2; usage >&2; exit 2 ;;
    *) DEST="$arg" ;;
  esac
done
DEST="${DEST:-$REPO/third_party/foobar2000-sdk}"

is_sdk() { [ -f "$1/foobar2000/SDK/foobar2000.h" ] && [ -d "$1/pfc" ] && [ -d "$1/foobar2000/helpers-mac" ]; }
sdk_version_of() {   # prints the FOOBAR2000_SDK_VERSION of an unpacked SDK, or nothing
  local h="$1/foobar2000/SDK/foobar2000-versions.h"
  [ -f "$h" ] && sed -n 's/^#define FOOBAR2000_SDK_VERSION[[:space:]]*\([0-9]*\).*/\1/p' "$h" | head -n 1
}

if is_sdk "$DEST"; then
  have="$(sdk_version_of "$DEST" || true)"
  if [ "$have" = "$SDK_VERSION_MACRO" ]; then
    echo "foobar2000 SDK $SDK_VERSION already present: $DEST"
    exit 0
  fi
  if [ "$FORCE" = 0 ]; then
    echo "fetch-sdk.sh: $DEST holds SDK ${have:-of unknown version}, not $SDK_VERSION; use --force to replace it" >&2
    exit 1
  fi
fi
# Only an empty folder or an SDK (with --force) is ever replaced.
if [ -e "$DEST" ] && ! is_sdk "$DEST" && [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
  echo "fetch-sdk.sh: $DEST exists and is not a foobar2000 SDK; choose an empty or new folder" >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fb2k-sdk.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ARCHIVE="$TMP/SDK-$SDK_VERSION.7z"

if [ -n "${SDK_ARCHIVE:-}" ]; then
  [ -f "$SDK_ARCHIVE" ] || { echo "fetch-sdk.sh: $SDK_ARCHIVE not found" >&2; exit 1; }
  cp "$SDK_ARCHIVE" "$ARCHIVE"
  echo "using $SDK_ARCHIVE"
else
  echo "downloading $SDK_URL"
  curl -fL --proto '=https' --tlsv1.2 --retry 2 -o "$ARCHIVE" "$SDK_URL"
fi

magic="$(head -c 6 "$ARCHIVE" | od -An -tx1 | tr -d ' \n')"
if [ "$magic" != "377abcaf271c" ]; then
  echo "fetch-sdk.sh: $(basename "$ARCHIVE") is not a 7-Zip archive (the download may have failed)" >&2
  exit 1
fi
sum="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
echo "SHA-256 $sum"
if [ "$sum" != "$SDK_SHA256" ]; then
  echo "fetch-sdk.sh: SHA-256 mismatch (expected $SDK_SHA256; set SDK_SHA256=... only if foobar2000.org republished the archive)" >&2
  exit 1
fi

OUT="$TMP/unpacked"
mkdir -p "$OUT"
if tar -xf "$ARCHIVE" -C "$OUT" 2>"$TMP/tar.log"; then
  :
elif command -v 7zz >/dev/null 2>&1; then
  rm -rf "$OUT"; mkdir -p "$OUT"; 7zz x -y -o"$OUT" "$ARCHIVE" >/dev/null
elif command -v 7z >/dev/null 2>&1; then
  rm -rf "$OUT"; mkdir -p "$OUT"; 7z x -y -o"$OUT" "$ARCHIVE" >/dev/null
else
  cat "$TMP/tar.log" >&2
  echo "fetch-sdk.sh: could not unpack the archive with tar; install 7-Zip (for example 'brew install sevenzip')" >&2
  echo "and run this script again, or unpack $SDK_URL yourself and set SDK_ROOT to the folder that holds" >&2
  echo "foobar2000/ and pfc/." >&2
  exit 1
fi

# The archive holds foobar2000/, pfc/, libPPUI/ and the readme at its top level; accept one enclosing folder too.
ROOT="$OUT"
if ! is_sdk "$ROOT"; then
  for d in "$OUT"/*/; do
    if is_sdk "${d%/}"; then ROOT="${d%/}"; break; fi
  done
fi
is_sdk "$ROOT" || { echo "fetch-sdk.sh: the archive does not contain foobar2000/SDK, foobar2000/helpers-mac and pfc/" >&2; exit 1; }
got="$(sdk_version_of "$ROOT" || true)"
[ "$got" = "$SDK_VERSION_MACRO" ] || { echo "fetch-sdk.sh: the archive is SDK ${got:-?}, not $SDK_VERSION_MACRO" >&2; exit 1; }

mkdir -p "$(dirname "$DEST")"
if [ -e "$DEST" ]; then
  # only an empty folder or (with --force) a foobar2000 SDK gets here; check again right before replacing it
  if is_sdk "$DEST" || [ -z "$(ls -A "$DEST" 2>/dev/null)" ]; then
    mv "$DEST" "$TMP/previous"   # removed with the temporary folder once the new SDK is in place
  else
    echo "fetch-sdk.sh: $DEST is not a foobar2000 SDK any more; nothing replaced" >&2
    exit 1
  fi
fi
mv "$ROOT" "$DEST"
echo "foobar2000 SDK $SDK_VERSION unpacked into $DEST"

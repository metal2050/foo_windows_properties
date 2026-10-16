#!/usr/bin/env bash
usage() {
  cat <<'USAGE'
Usage: scripts/package.sh [--no-build]
Builds the universal release bundle (scripts/build.sh), checks it and writes the installable package
  dist/foo_windows_properties-<version>.fb2k-component
a ZIP (deflate) holding exactly mac/foo_windows_properties.component/** (the package format foobar2000 for Mac
installs from Preferences > Components > "+"), then prints its listing
and SHA-256 (also written to <package>.sha256).
Checks: lipo -archs is exactly x86_64 + arm64, codesign --verify --strict passes, and the bundle's
CFBundleShortVersionString and CFBundleVersion equal the component version (project VERSION in CMakeLists.txt).
The ZIP is deterministic: sorted paths, file entries only, fixed timestamps (SOURCE_DATE_EPOCH, else the
commit time of HEAD), normalised permissions (0644, 0755 for the executable), no extended attributes,
no __MACOSX/ or .DS_Store.
  --no-build       package build/foo_windows_properties.component as it is (it is still checked)
  SDK_ROOT, JOBS   passed on to scripts/build.sh
USAGE
}
NO_BUILD=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --no-build) NO_BUILD=1 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
[ "$(uname)" = Darwin ] || { echo "package.sh: macOS only" >&2; exit 1; }
die() { echo "package.sh: $*" >&2; exit 1; }

NAME=foo_windows_properties
BUNDLE="build/$NAME.component"
EXE="$BUNDLE/Contents/MacOS/$NAME"
PLIST="$BUNDLE/Contents/Info.plist"

# The component version: CMakeLists.txt's project VERSION is the one source (WPE_VERSION, Info.plist).
VERSION="$(sed -n -E 's/^project\([A-Za-z0-9_]+ VERSION ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' CMakeLists.txt | head -1)"
[ -n "$VERSION" ] || die "no project VERSION in CMakeLists.txt"
fallback="$(sed -n -E 's/^#define WPE_VERSION "([^"]*)"/\1/p' src/wpe_entry.h)"
[ "$fallback" = "$VERSION" ] || die "src/wpe_entry.h WPE_VERSION fallback is '$fallback', CMakeLists.txt says $VERSION"

if [ "$NO_BUILD" -eq 0 ]; then
  "$REPO/scripts/build.sh"
fi
[ -d "$BUNDLE" ] && [ -f "$EXE" ] && [ -f "$PLIST" ] || die "no built bundle at $BUNDLE (run scripts/build.sh)"

# ---- checks ---------------------------------------------------------------------------------------------------------
archs="$(lipo -archs "$EXE" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
[ "$archs" = "arm64 x86_64" ] || die "lipo -archs: expected exactly x86_64 arm64, got '$(lipo -archs "$EXE")'"
codesign --verify --strict --deep "$BUNDLE" || die "codesign --verify failed for $BUNDLE"
short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
long="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
[ "$short" = "$VERSION" ] && [ "$long" = "$VERSION" ] \
  || die "Info.plist says CFBundleShortVersionString=$short CFBundleVersion=$long, the component version is $VERSION (rebuild)"
[ -z "$(find "$BUNDLE" ! -type f ! -type d)" ] || die "the bundle holds something other than files and folders (symlink?)"
echo "checked: $BUNDLE ($(lipo -archs "$EXE"), codesign ok, version $VERSION)"

# ---- the package ----------------------------------------------------------------------------------------------------
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
  SOURCE_DATE_EPOCH="$(git -C "$REPO" log -1 --format=%ct 2>/dev/null || echo 315532800)"
fi
mkdir -p dist
OUT="dist/$NAME-$VERSION.fb2k-component"
TMP="$(mktemp "dist/.$NAME.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
python3 -I - "$BUNDLE" "$TMP" "$SOURCE_DATE_EPOCH" "$NAME" <<'PY'
import os, sys, time, zipfile
bundle, out, epoch, name = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
top = os.path.basename(bundle.rstrip("/"))            # foo_windows_properties.component
exe_rel = "Contents/MacOS/" + name
when = time.gmtime(max(epoch, 315532800))[:6]          # ZIP dates start in 1980; stored as UTC wall time
files = []
for root, dirs, names in os.walk(bundle):
    dirs[:] = [d for d in dirs if d != "__MACOSX"]
    for n in names:
        if n == ".DS_Store" or n.startswith("._"):
            continue
        p = os.path.join(root, n)
        files.append(os.path.relpath(p, bundle).replace(os.sep, "/"))
files.sort()
with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for rel in files:
        zi = zipfile.ZipInfo("mac/%s/%s" % (top, rel), date_time=when)
        zi.compress_type = zipfile.ZIP_DEFLATED
        zi.create_system = 3                            # Unix: unzip/ditto apply the mode bits below
        mode = 0o755 if rel == exe_rel else 0o644
        zi.external_attr = (0o100000 | mode) << 16
        with open(os.path.join(bundle, rel), "rb") as f:
            z.writestr(zi, f.read())
# Re-read what was written.
with zipfile.ZipFile(out) as z:
    if z.testzip() is not None:
        sys.exit("package.sh: CRC check failed")
    got = [i.filename for i in z.infolist()]
    want = ["mac/%s/%s" % (top, r) for r in files]
    if got != want:
        sys.exit("package.sh: the archive's entries differ from the bundle's files")
    for i in z.infolist():
        parts = i.filename.split("/")
        if parts[:2] != ["mac", top] or "__MACOSX" in parts or ".DS_Store" in parts or i.extra:
            sys.exit("package.sh: unexpected entry " + i.filename)
        if i.compress_type != zipfile.ZIP_DEFLATED:
            sys.exit("package.sh: not deflated: " + i.filename)
    for need in ("Contents/Info.plist", exe_rel, "Contents/_CodeSignature/CodeResources"):
        if "mac/%s/%s" % (top, need) not in got:
            sys.exit("package.sh: missing " + need)
PY
mv -f "$TMP" "$OUT"
trap - EXIT
sha="$(shasum -a 256 "$OUT" | awk '{print $1}')"
printf '%s  %s\n' "$sha" "$(basename "$OUT")" > "$OUT.sha256"

echo
unzip -l "$OUT"
echo
echo "package: $REPO/$OUT ($(stat -f %z "$OUT") bytes)"
echo "SHA-256: $sha"

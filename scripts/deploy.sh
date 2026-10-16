#!/usr/bin/env bash
# Windows Properties - installation handover.
#
#   scripts/deploy.sh             PRINTS the exact commands and exits (no side effects).
#   scripts/deploy.sh --install   performs them, with foobar2000 closed (refuses while it runs).
#
# The bundle goes directly into ~/Library/foobar2000-v2/user-components/foo_windows_properties.component.
# Early development builds of this component were called foo_properties_mac.component. Both bundles register
# the same menu commands (same GUIDs) and the same Objective-C classes, so the old one must not stay next to
# the new one: --install moves an installed foo_properties_mac.component out of user-components into a backup
# folder (it is never deleted). Settings carry over: the window's remembered frame, columns and tab live
# under fixed keys in foobar2000's own defaults, and key bindings refer to the unchanged command GUIDs.
usage() {
  cat <<'USAGE'
Usage: scripts/deploy.sh [--install]
  (no args)   print the install commands for build/foo_windows_properties.component
  --install   run them (refuses while foobar2000 is running); moves an installed
              foo_properties_mac.component (the old name) to a backup folder first
  BACKUP_DIR=/path   where the old bundle is moved (default: install-backups/ in this repository)
USAGE
}

set -euo pipefail

INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "deploy.sh: unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"
NAME=foo_windows_properties
OLD_NAMES=(foo_properties_mac)   # earlier bundle names of this component
SRC="$REPO/build/$NAME.component"
PROFILE="$HOME/Library/foobar2000-v2"
DEST_DIR="$PROFILE/user-components"
DEST="$DEST_DIR/$NAME.component"
BACKUP_DIR="${BACKUP_DIR:-$REPO/install-backups}"
BACKUP="$BACKUP_DIR/windows-properties-install-$(date +%Y%m%d-%H%M%S)"

q() { printf '%q' "$1"; }

print_commands() {
  echo "# 1. foobar2000 must not be running (this must print nothing):"
  echo "pgrep -x foobar2000"
  echo "# 2. move the bundle installed under its old name (if present) to a backup folder:"
  local old
  for old in "${OLD_NAMES[@]}"; do
    echo "[ -e $(q "$DEST_DIR/$old.component") ] && mkdir -p $(q "$BACKUP") && mv $(q "$DEST_DIR/$old.component") $(q "$BACKUP/")"
  done
  cat <<CMDS
# 3. install the ad-hoc signed universal bundle:
mkdir -p $(q "$DEST_DIR")
rm -rf $(q "$DEST")
cp -R $(q "$SRC") $(q "$DEST_DIR/")
codesign --force --sign - $(q "$DEST")
codesign -dv $(q "$DEST")
lipo -archs $(q "$DEST/Contents/MacOS/$NAME")
# 4. start foobar2000; the context menu shows "Properties (Windows style)…" as before.
# Uninstall (foobar2000 closed):
#   rm -rf $(q "$DEST")
CMDS
}

if [ "$INSTALL" = 0 ]; then
  [ -d "$SRC" ] || echo "# NOTE: $SRC does not exist yet - run scripts/build.sh first." >&2
  print_commands
  exit 0
fi

# ---- --install ----
[ -d "$SRC" ] || { echo "deploy.sh: $SRC not found - run scripts/build.sh first" >&2; exit 1; }
if pgrep -x foobar2000 >/dev/null 2>&1; then
  echo "deploy.sh: foobar2000 is running - quit it first" >&2
  exit 1
fi
for old in "${OLD_NAMES[@]}"; do
  if [ -e "$DEST_DIR/$old.component" ]; then
    mkdir -p "$BACKUP"
    mv "$DEST_DIR/$old.component" "$BACKUP/"
    echo "moved: $DEST_DIR/$old.component -> $BACKUP/"
  fi
done
set -x
mkdir -p "$DEST_DIR"
rm -rf "$DEST"
cp -R "$SRC" "$DEST_DIR/"
codesign --force --sign - "$DEST"
codesign -dv "$DEST"
lipo -archs "$DEST/Contents/MacOS/$NAME"
set +x
echo "installed: $DEST (start foobar2000 to load it)"

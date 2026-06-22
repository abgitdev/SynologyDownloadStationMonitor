#!/bin/bash
# Reproducible build for the single-file SwiftUI app.
# Compiles SynologyDownloadStationMonitor.swift into a runnable .app bundle and drops a
# version-stamped copy on the Desktop. The build number is read from Info.plist as-is and
# is NOT auto-incremented; bump it deliberately with `./build.sh bump` when cutting a release.
#
# Usage:
#   ./build.sh           # debug build
#   ./build.sh release   # optimized build
#   ./build.sh run       # build (debug) then launch the app
#   ./build.sh release run
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="SynologyDownloadStationMonitor"
SRC="$ROOT/$APP_NAME.swift"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
PLIST="$ROOT/Info.plist"
PB="/usr/libexec/PlistBuddy"
DESKTOP="$HOME/Desktop"

MODE="${1:-debug}"
OPT_FLAGS=( -Onone -g )
EXTRA_FLAGS=()
if [ "$MODE" = "release" ]; then
  OPT_FLAGS=( -O )
fi

echo "› Cleaning previous bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "› Compiling ($MODE)…"
# -parse-as-library: required so @main works alongside the file's global declarations.
# -*-prefix-map: keep the developer's absolute home path / macOS username out of the
# compiled binary so the published build doesn't leak it (audit R1-04).
swiftc -parse-as-library "${OPT_FLAGS[@]}" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
  -file-prefix-map "$ROOT=." -debug-prefix-map "$ROOT=." \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  "$SRC"

# Version + build are read from Info.plist AS-IS — NOT auto-incremented per compile.
# Convention: CFBundleShortVersionString is semver (MAJOR.MINOR.PATCH); CFBundleVersion
# is a build number bumped DELIBERATELY per release (e.g. `./build.sh bump`), then the
# release is cut as a git tag `vX.Y.Z`. This keeps the number meaningful instead of
# ballooning on every rebuild.
if [ "$MODE" = "bump" ] || [ "${2:-}" = "bump" ]; then
  CUR_BUILD="$("$PB" -c "Print CFBundleVersion" "$PLIST")"
  if ! [[ "$CUR_BUILD" =~ ^[0-9]+$ ]]; then
    echo "✗ CFBundleVersion '$CUR_BUILD' is not a plain integer; refusing to bump." >&2
    exit 1
  fi
  "$PB" -c "Set CFBundleVersion $(( CUR_BUILD + 1 ))" "$PLIST"
fi
SHORT_VER="$("$PB" -c "Print CFBundleShortVersionString" "$PLIST")"
NEW_BUILD="$("$PB" -c "Print CFBundleVersion" "$PLIST")"
echo "› Version: $SHORT_VER (build $NEW_BUILD)"

echo "› Assembling bundle…"
cp "$PLIST" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "› Ad-hoc code signing…"
# Do NOT mask codesign's exit code — a failed signature must fail the build (set -e) instead
# of silently shipping a broken/unsigned bundle (audit F20).
codesign --force --sign - "$APP"

echo "✓ Built: $APP"

# Drop a version-stamped copy on the Desktop. Keep exactly one current build there:
# remove only our own previous stamped copies (strict glob), never anything else.
DEST="$DESKTOP/$APP_NAME v$SHORT_VER.app"
shopt -s nullglob
for old in "$DESKTOP/$APP_NAME v"*.app; do
  # Belt-and-suspenders: only ever rm a real directory that lives directly on the Desktop
  # and ends in .app — never anything else (audit F52).
  case "$old" in
    "$DESKTOP/"*".app")
      if [ -d "$old" ]; then
        echo "› Removing old Desktop build: $(basename "$old")"
        rm -rf "$old"
      fi
      ;;
  esac
done
shopt -u nullglob
cp -R "$APP" "$DEST"
codesign --force --sign - "$DEST"
echo "✓ Desktop: $DEST"

if [ "$MODE" = "run" ] || [ "${2:-}" = "run" ]; then
  echo "› Launching…"
  open "$DEST"
fi

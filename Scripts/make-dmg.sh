#!/bin/bash
# Builds a disk image for download from a built Culla.app: the app and a link to /Applications,
# compressed. It neither signs nor notarizes anything; see Scripts/release.md for the steps that
# need a Developer ID. Use it to rehearse the release with an unsigned Release build.
#
# Usage: Scripts/make-dmg.sh [--app <Culla.app>] [--out <Culla-1.0.dmg>] [--build]
#   --app <path>   the app to package (default: the Release build in $CULLA_DERIVED_DATA, or
#                  the one --build makes)
#   --out <path>   where the disk image goes (default: Culla-<version>.dmg in the current folder)
#   --build        build the Release configuration first (unsigned, ad hoc), into its own
#                  DerivedData outside the repository
#
# Exit status: 0 on success, 1 on a problem with the app, 2 when a tool failed.
set -euo pipefail

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${CULLA_DERIVED_DATA:-${TMPDIR:-/tmp}/culla-release-derived}"
APP=""
OUT=""
BUILD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --build) BUILD=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option $1" >&2; usage 2 ;;
    esac
done

if [ "$BUILD" -eq 1 ]; then
    echo "Building the Release configuration into ${DERIVED}…" >&2
    xcodebuild -project "$REPO/Culla.xcodeproj" -scheme Culla -configuration Release \
        -destination 'platform=macOS' -derivedDataPath "$DERIVED" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build >"$DERIVED.build.log" 2>&1 \
        || { grep -E "error:" "$DERIVED.build.log" | head -20 >&2; echo "Build failed; log: $DERIVED.build.log" >&2; exit 2; }
fi
[ -n "$APP" ] || APP="$DERIVED/Build/Products/Release/Culla.app"
[ -d "$APP" ] || { echo "No app at $APP (build it, or pass --app)" >&2; exit 1; }

PLIST="$APP/Contents/Info.plist"
plutil -lint "$PLIST" >/dev/null || { echo "Info.plist does not lint" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
[ -n "$OUT" ] || OUT="$PWD/Culla-$VERSION.dmg"

# Refuse an app that still holds the automation harness: only Release builds are shipped.
if strings "$APP/Contents/MacOS/Culla" | grep -q "CullaAutomation"; then
    echo "$APP contains the automation harness: package a Release build" >&2
    exit 1
fi

# Exactly the three entitlements Culla needs: the sandbox, user-selected files, app-scoped bookmarks.
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || echo '{}')"
EXPECTED='{"com.apple.security.app-sandbox":true,"com.apple.security.files.bookmarks.app-scope":true,"com.apple.security.files.user-selected.read-write":true}'
if [ "$(printf '%s' "$ENTITLEMENTS" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True, separators=(",", ":")))')" != "$EXPECTED" ]; then
    echo "Unexpected entitlements: $ENTITLEMENTS" >&2
    echo "(get-task-allow comes from a debug-style signature: build with CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO, as --build does)" >&2
    exit 1
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/culla-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Culla.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create -volname "Culla $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null 2>&1 \
    || { echo "hdiutil failed" >&2; exit 2; }
hdiutil verify "$OUT" >/dev/null || { echo "The disk image does not verify" >&2; exit 2; }

# How the app is signed: the leaf authority (Developer ID), an ad hoc signature, or none that verifies.
# `codesign -dv` prints the Authority= lines only from --verbose=2 on.
SIGNED="no valid signature"
if codesign --verify --strict "$APP" 2>/dev/null; then
    SIGNATURE="$(codesign -dv --verbose=2 "$APP" 2>&1)"
    SIGNED="$(printf '%s\n' "$SIGNATURE" | sed -n 's/^Authority=//p' | head -1)"
    if [ -z "$SIGNED" ]; then
        if printf '%s\n' "$SIGNATURE" | grep -qx "Signature=adhoc"; then SIGNED="ad hoc signature"; else SIGNED="signed, authority unknown"; fi
    fi
fi
echo "Wrote $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '), Culla $VERSION, $SIGNED)"

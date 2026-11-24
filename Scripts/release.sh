#!/bin/bash
# Builds the release disk image: archives Culla, exports it signed with Developer ID, checks the
# app, makes the image with make-dmg.sh, signs it, notarizes it, staples the ticket and asks
# Gatekeeper about it. The same script runs on the owner's Mac and in .github/workflows/release.yml.
#
# Usage: Scripts/release.sh [--tag <tag>] [--out <folder>] [--keychain-profile <name>]
#                           [--team <team id>] [--skip-notarize] [--preflight]
#   --tag <tag>               fail unless the tag is exactly v<version> (default: $GITHUB_REF_NAME
#                             when GitHub Actions runs for a tag; otherwise no tag is checked)
#   --out <folder>            where the archive, the export, the logs and the image go
#                             (default: build/release in the repository, which git ignores)
#   --keychain-profile <name> the notarytool keychain profile (default: culla-notary); not used
#                             when NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID are set,
#                             which select an App Store Connect API key instead (as in CI)
#   --team <team id>          the Developer ID team (default: Z32TPH2T97)
#   --skip-notarize           a rehearsal: stop after signing the image, which is named
#                             Culla-<version>-not-notarized.dmg so it cannot pass for the release
#   --preflight               check the version, the tag, the identity and the credentials, then stop
#
# Exit status: 0 on success, 1 when a release check failed, 2 when a tool or the build failed,
# 3 on a bad option, a wrong tag, or a missing identity or credentials.
# On success the last lines name the image, its size in bytes and its SHA-256; under GitHub
# Actions they are also written to $GITHUB_OUTPUT as dmg, file, version, size and sha256.
set -euo pipefail

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
say() { echo "$*" >&2; }
fail() { local status="$1"; shift; echo "release.sh: $*" >&2; exit "$status"; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEAM="Z32TPH2T97"
BUNDLE_ID="com.kpirliyev.Culla"
IDENTITY_NAME="Developer ID Application"
PROFILE="culla-notary"
OUT="$REPO/build/release"
TAG=""
SKIP_NOTARIZE=0
PREFLIGHT=0

need_value() { [ $# -ge 2 ] && [ -n "$2" ] || fail 3 "$1 needs a value"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --tag) need_value "$@"; TAG="$2"; shift 2 ;;
        --out) need_value "$@"; OUT="$2"; shift 2 ;;
        --keychain-profile) need_value "$@"; PROFILE="$2"; shift 2 ;;
        --team) need_value "$@"; TEAM="$2"; shift 2 ;;
        --skip-notarize) SKIP_NOTARIZE=1; shift ;;
        --preflight) PREFLIGHT=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option $1" >&2; usage 3 ;;
    esac
done
if [ -z "$TAG" ] && [ "${GITHUB_ACTIONS:-}" = "true" ] && [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
    TAG="${GITHUB_REF_NAME:-}"
fi

for tool in xcodebuild codesign plutil otool strings hdiutil shasum python3; do
    command -v "$tool" >/dev/null || fail 2 "$tool is not installed"
done

# --- Version and tag: checked before anything is built --------------------------------------
VERSION="$(xcodebuild -project "$REPO/Culla.xcodeproj" -scheme Culla -configuration Release -showBuildSettings 2>/dev/null \
    | awk '$1 == "MARKETING_VERSION" { print $3; exit }')" || true
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail 2 "could not read MARKETING_VERSION from the project (got '${VERSION}')"
if [ -n "$TAG" ] && [ "$TAG" != "v$VERSION" ]; then
    fail 3 "the tag '$TAG' does not match the project's version $VERSION: the tag must be v$VERSION"
fi
say "Culla $VERSION${TAG:+, tag $TAG}"

# --- Developer ID identity --------------------------------------------------------------------
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$IDENTITY_NAME: " | grep -F "($TEAM)\"" || true)"
[ -n "$IDENTITIES" ] || fail 3 "no valid '$IDENTITY_NAME' identity for team $TEAM in the keychain search list; refusing to build an unsigned release"
IDENTITY_HASH="$(printf '%s\n' "$IDENTITIES" | head -1 | awk '{ print $2 }')"
IDENTITY_LABEL="$(printf '%s\n' "$IDENTITIES" | head -1 | sed 's/^[^"]*"//; s/"$//')"
if [ "$(printf '%s\n' "$IDENTITIES" | wc -l | tr -d ' ')" -gt 1 ]; then
    say "Note: several '$IDENTITY_NAME' identities for team $TEAM; the image is signed with the first."
fi
say "Signing identity: $IDENTITY_LABEL"

# --- Notarization credentials -----------------------------------------------------------------
NOTARY_ARGS=()
if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    command -v xcrun >/dev/null || fail 2 "xcrun is not installed"
    if [ -n "${NOTARY_KEY_PATH:-}${NOTARY_KEY_ID:-}${NOTARY_ISSUER_ID:-}" ]; then
        [ -n "${NOTARY_KEY_PATH:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ] \
            || fail 3 "an App Store Connect API key needs all of NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID"
        [ -s "$NOTARY_KEY_PATH" ] || fail 3 "NOTARY_KEY_PATH does not name a readable, non-empty key file"
        NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
        CREDENTIALS="an App Store Connect API key"
    else
        NOTARY_ARGS=(--keychain-profile "$PROFILE")
        CREDENTIALS="the keychain profile '$PROFILE'"
    fi
    # A read-only request (the last submission) proves the credentials before a long build.
    if ! NOTARY_CHECK="$(xcrun notarytool history "${NOTARY_ARGS[@]}" --output-format json 2>&1 >/dev/null)"; then
        printf '%s\n' "$NOTARY_CHECK" | tail -3 >&2
        fail 3 "the notary service does not accept $CREDENTIALS; store a profile with 'xcrun notarytool store-credentials $PROFILE …' or set NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID (or pass --skip-notarize for a rehearsal)"
    fi
    say "Notarization credentials: $CREDENTIALS"
else
    say "Rehearsal (--skip-notarize): the image is signed but will not be notarized."
fi

if [ "$PREFLIGHT" -eq 1 ]; then
    say "Preflight passed."
    exit 0
fi

# --- Archive and export ------------------------------------------------------------------------
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
ARCHIVE="$OUT/Culla.xcarchive"
EXPORT="$OUT/export"
rm -rf "$ARCHIVE" "$EXPORT"

say "Archiving into ${ARCHIVE}…"
xcodebuild -project "$REPO/Culla.xcodeproj" -scheme Culla -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$OUT/DerivedData" \
    -archivePath "$ARCHIVE" archive \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY_NAME" DEVELOPMENT_TEAM="$TEAM" \
    ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp" \
    >"$OUT/archive.log" 2>&1 \
    || { grep -E "error:" "$OUT/archive.log" | head -20 >&2; fail 2 "the archive failed; log: $OUT/archive.log"; }

cat >"$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$IDENTITY_NAME</string>
</dict></plist>
PLIST

say "Exporting with Developer ID…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$EXPORT" \
    >"$OUT/export.log" 2>&1 \
    || { grep -E "error" "$OUT/export.log" | head -20 >&2; fail 2 "the export failed; log: $OUT/export.log"; }
APP="$EXPORT/Culla.app"
[ -d "$APP" ] || fail 2 "the export made no Culla.app; log: $OUT/export.log"

# --- What a release build must be (Scripts/release.md) -------------------------------------------
# make-dmg.sh checks the automation harness and the four entitlements again; these are the rest.
check() { say "  ok  $1"; }
say "Checking ${APP}…"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail 1 "Info.plist does not lint"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[ "$APP_VERSION" = "$VERSION" ] || fail 1 "the app says version $APP_VERSION, the project $VERSION"
[ "$APP_ID" = "$BUNDLE_ID" ] || fail 1 "the bundle identifier is $APP_ID, expected $BUNDLE_ID"
LINTED=0
while IFS= read -r -d '' plist; do
    plutil -lint "$plist" >/dev/null || fail 1 "$plist does not lint"
    LINTED=$((LINTED + 1))
done < <(find "$APP" -name '*.plist' -print0)
check "$LINTED property lists lint; version $APP_VERSION, $APP_ID"

ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || echo '{}')"
EXPECTED='{"com.apple.security.app-sandbox":true,"com.apple.security.files.bookmarks.app-scope":true,"com.apple.security.files.user-selected.read-write":true,"com.apple.security.network.client":true}'
[ "$(printf '%s' "$ENTITLEMENTS" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True, separators=(",", ":")))')" = "$EXPECTED" ] \
    || fail 1 "unexpected entitlements: $ENTITLEMENTS"
check "exactly the four entitlements (sandbox, user-selected files, bookmarks, outgoing connections)"

BINARY="$APP/Contents/MacOS/Culla"
if otool -L "$BINARY" | grep -E "CFNetwork\.framework|/Network\.framework" >&2; then
    fail 1 "the app links a network framework of its own"
fi
check "no CFNetwork or Network.framework linked"
# URLSession comes with Foundation, so linking says nothing about who uses it: the sources say.
# Every network call of the project is in CullaKit/Sources/CullaUpdates (the update check).
NETWORK_USES="$(grep -rlE --include='*.swift' \
    'URLSession|NSURLConnection|CFNetwork|CFSocket|CFStream|NWConnection|NWListener|NWPathMonitor|NWBrowser|^[[:space:]]*import[[:space:]]+Network([[:space:]]|$)' \
    "$REPO/Culla" "$REPO/CullaKit/Sources" | grep -v "^$REPO/CullaKit/Sources/CullaUpdates/" || true)"
[ -z "$NETWORK_USES" ] || { printf '%s\n' "$NETWORK_USES" >&2; fail 1 "network code outside CullaKit/Sources/CullaUpdates"; }
check "network code only in CullaKit/Sources/CullaUpdates"
if strings "$BINARY" | grep -q "CullaAutomation"; then
    fail 1 "the app contains the automation harness (CullaAutomation)"
fi
check "no CullaAutomation in the binary"

codesign --verify --deep --strict "$APP" 2>"$OUT/verify.log" || { cat "$OUT/verify.log" >&2; fail 1 "the app's signature does not verify"; }
SIGNATURE="$(codesign -dv --verbose=4 "$APP" 2>&1)"
printf '%s\n' "$SIGNATURE" | grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]*\([^)]*runtime' || fail 1 "the hardened runtime flag is missing"
check "signature verifies (deep, strict); hardened runtime on"
AUTHORITY="$(printf '%s\n' "$SIGNATURE" | sed -n 's/^Authority=//p' | head -1)"
[[ "$AUTHORITY" == "$IDENTITY_NAME: "*"($TEAM)" ]] || fail 1 "signed by '${AUTHORITY:-nobody}', expected $IDENTITY_NAME for team $TEAM"
printf '%s\n' "$SIGNATURE" | grep -qx "TeamIdentifier=$TEAM" || fail 1 "the team identifier is not $TEAM"
printf '%s\n' "$SIGNATURE" | grep -q '^Timestamp=' || fail 1 "the signature has no secure timestamp"
check "$AUTHORITY, secure timestamp"
ARCHS="$(lipo -archs "$BINARY" 2>/dev/null || echo unknown)"
check "architectures: $ARCHS"

# --- Disk image ------------------------------------------------------------------------------------
if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    DMG="$OUT/Culla-$VERSION-not-notarized.dmg"
else
    DMG="$OUT/Culla-$VERSION.dmg"
fi
rm -f "$OUT/Culla-$VERSION.dmg" "$OUT/Culla-$VERSION-not-notarized.dmg"
"$REPO/Scripts/make-dmg.sh" --app "$APP" --out "$DMG" || exit $?

say "Signing the image…"
codesign --sign "$IDENTITY_HASH" --timestamp "$DMG" >/dev/null 2>"$OUT/sign-dmg.log" \
    || { cat "$OUT/sign-dmg.log" >&2; fail 2 "signing the image failed"; }
codesign --verify --strict "$DMG" || fail 1 "the image's signature does not verify"
DMG_SIGNATURE="$(codesign -dv --verbose=2 "$DMG" 2>&1)"
printf '%s\n' "$DMG_SIGNATURE" | grep -qx "Authority=$IDENTITY_LABEL" || fail 1 "the image is not signed by $IDENTITY_LABEL"
printf '%s\n' "$DMG_SIGNATURE" | grep -q '^Timestamp=' || fail 1 "the image's signature has no secure timestamp"
check "image signed by $IDENTITY_LABEL, secure timestamp"

# --- Notarize, staple, assess --------------------------------------------------------------------
if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    say "Submitting to the notary service and waiting (this takes minutes)…"
    xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait --output-format json >"$OUT/notarize.json" 2>"$OUT/notarize.log" || true
    read -r SUBMISSION STATUS < <(python3 -c 'import json,sys
try: d = json.load(open(sys.argv[1]))
except Exception: d = {}
print(d.get("id") or "-", d.get("status") or "-")' "$OUT/notarize.json")
    if [ "$STATUS" != "Accepted" ]; then
        tail -5 "$OUT/notarize.log" >&2
        if [ "$SUBMISSION" != "-" ]; then
            xcrun notarytool log "$SUBMISSION" "${NOTARY_ARGS[@]}" "$OUT/notarize-log.json" >/dev/null 2>&1 || true
            fail 1 "notarization ended '$STATUS' (submission $SUBMISSION); the notary's log is in $OUT/notarize-log.json"
        fi
        fail 2 "the submission to the notary service failed; see $OUT/notarize.log"
    fi
    check "notarized (submission $SUBMISSION)"
    xcrun stapler staple "$DMG" >"$OUT/staple.log" 2>&1 || { cat "$OUT/staple.log" >&2; fail 2 "stapling failed"; }
    xcrun stapler validate "$DMG" >>"$OUT/staple.log" 2>&1 || { cat "$OUT/staple.log" >&2; fail 1 "the stapled ticket does not validate"; }
    check "ticket stapled and validated"
    ASSESSMENT="$(spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1)" \
        || { say "$ASSESSMENT"; fail 1 "Gatekeeper rejects the image"; }
    printf '%s\n' "$ASSESSMENT" | grep -q "source=Notarized Developer ID" || { say "$ASSESSMENT"; fail 1 "Gatekeeper accepts the image, but not as Notarized Developer ID"; }
    check "Gatekeeper: accepted, source=Notarized Developer ID"
fi

# --- Summary -------------------------------------------------------------------------------------
SIZE="$(stat -f %z "$DMG")"
SHA256="$(shasum -a 256 "$DMG" | awk '{ print $1 }')"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "dmg=$DMG"
        echo "file=$(basename "$DMG")"
        echo "version=$VERSION"
        echo "size=$SIZE"
        echo "sha256=$SHA256"
    } >>"$GITHUB_OUTPUT"
fi
if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    say "REHEARSAL ONLY: signed with Developer ID but NOT notarized; do not publish this image."
else
    say "Signed, notarized and stapled."
fi
echo "Image:   $DMG"
echo "Size:    $SIZE bytes"
echo "SHA-256: $SHA256"

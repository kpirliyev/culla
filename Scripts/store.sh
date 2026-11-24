#!/bin/bash
# Builds the Mac App Store package: archives the AppStore configuration (the app's update check
# compiled out, no network entitlement), exports it for App Store Connect as a signed installer
# package, checks the app inside it, and with --upload validates and uploads it. Scripts/store.md explains the
# steps and the one-time setup; the disk image for download is Scripts/release.sh's.
#
# Usage: Scripts/store.sh [--rehearse | --preflight] [--upload] [--out <folder>]
#                         [--team <team id>] [--profile <name>]
#   --rehearse         no Apple account needed: build the AppStore configuration ad hoc signed,
#                      run the checks on it, then stop
#   --preflight        check the version, the signing identities, the provisioning profile
#                      (and with --upload the API key's settings), then stop
#   --upload           after every check passed, validate the package with App Store Connect
#                      and upload it, with the API key named by ASC_KEY_PATH, ASC_KEY_ID and
#                      ASC_ISSUER_ID; without it the script never contacts Apple
#   --out <folder>     where the archive, the export, the logs and the package go
#                      (default: build/store in the repository, which git ignores)
#   --team <team id>   the team that signs (default: Z32TPH2T97)
#   --profile <name>   the Mac App Store provisioning profile (default: Culla Mac App Store)
#
# Exit status: 0 on success, 1 when a check failed, 2 when a tool, the build or App Store
# Connect failed, 3 on a bad option or a missing identity, profile or API key.
# On success the last line names the package (or, for --rehearse, the app).
set -euo pipefail

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
say() { echo "$*" >&2; }
fail() { local status="$1"; shift; echo "store.sh: $*" >&2; exit "$status"; }
check() { say "  ok  $1"; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEAM="Z32TPH2T97"
BUNDLE_ID="com.kpirliyev.Culla"
CATEGORY="public.app-category.photography"
PROFILE="Culla Mac App Store"
OUT="$REPO/build/store"
GUIDE="Scripts/store.md, \"One-time setup\""
# Current names first; the legacy names are what older certificates are called.
APP_IDENTITY_NAMES=("Apple Distribution" "3rd Party Mac Developer Application")
INSTALLER_IDENTITY_NAMES=("3rd Party Mac Developer Installer" "Mac Installer Distribution")
MODE="package"
UPLOAD=0

need_value() { [ $# -ge 2 ] && [ -n "$2" ] || fail 3 "$1 needs a value"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --rehearse) [ "$MODE" = "package" ] || fail 3 "--rehearse and --preflight exclude each other"; MODE="rehearse"; shift ;;
        --preflight) [ "$MODE" = "package" ] || fail 3 "--rehearse and --preflight exclude each other"; MODE="preflight"; shift ;;
        --upload) UPLOAD=1; shift ;;
        --out) need_value "$@"; OUT="$2"; shift 2 ;;
        --team) need_value "$@"; TEAM="$2"; shift 2 ;;
        --profile) need_value "$@"; PROFILE="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option $1" >&2; usage 3 ;;
    esac
done
[ "$MODE" = "rehearse" ] && [ "$UPLOAD" -eq 1 ] && fail 3 "--upload needs a signed package: it cannot go with --rehearse"

for tool in xcodebuild codesign plutil otool security python3 pkgutil; do
    command -v "$tool" >/dev/null || fail 2 "$tool is not installed"
done

# --- Version: read before anything is built ---------------------------------------------------
SETTINGS="$(xcodebuild -project "$REPO/Culla.xcodeproj" -scheme Culla -configuration AppStore -showBuildSettings 2>/dev/null)" || true
VERSION="$(printf '%s\n' "$SETTINGS" | awk '$1 == "MARKETING_VERSION" { print $3; exit }')"
BUILD="$(printf '%s\n' "$SETTINGS" | awk '$1 == "CURRENT_PROJECT_VERSION" { print $3; exit }')"
DISTRIBUTION="$(printf '%s\n' "$SETTINGS" | awk '$1 == "CULLA_DISTRIBUTION" { print $3; exit }')"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail 2 "could not read MARKETING_VERSION of the AppStore configuration (got '${VERSION}')"
[[ "$BUILD" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail 2 "could not read CURRENT_PROJECT_VERSION of the AppStore configuration (got '${BUILD}')"
[ "$DISTRIBUTION" = "appStore" ] || fail 2 "the AppStore configuration says CULLA_DISTRIBUTION=${DISTRIBUTION:-nothing}, expected appStore"
say "Culla $VERSION (build $BUILD), Mac App Store variant"

# --- Identities, profile and API key (not for a rehearsal) ---------------------------------------
# Finds the first valid identity whose name starts with one of the given names, for the team.
# Prints "<SHA-1> <full name>". Installer certificates are not code signing identities, so every
# valid identity is listed, whatever its policy.
find_identity() {
    local listing name line
    listing="$(security find-identity -v 2>/dev/null || true)"
    for name in "$@"; do
        line="$(printf '%s\n' "$listing" | grep -F "\"$name: " | grep -F "($TEAM)\"" | head -1 || true)"
        if [ -n "$line" ]; then
            printf '%s %s\n' "$(printf '%s\n' "$line" | awk '{ print $2 }')" "$(printf '%s\n' "$line" | sed 's/^[^"]*"//; s/"$//')"
            return 0
        fi
    done
    return 1
}

# Looks for the provisioning profile by name where Xcode keeps them and checks it is a Mac App
# Store profile for this app and team, unexpired, and holds the app's certificate. Prints
# "<UUID>\t<path>\t<expiry>"; otherwise prints why not and fails.
find_profile() {
    python3 - "$PROFILE" "$TEAM" "$BUNDLE_ID" "${1:-}" <<'PY'
import datetime, glob, hashlib, os, plistlib, subprocess, sys
name, team, bundle, certificate = sys.argv[1:5]
folders = [os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles"),
           os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")]
found, reasons = [], []
for folder in folders:
    for path in sorted(glob.glob(os.path.join(folder, "*.provisionprofile")) + glob.glob(os.path.join(folder, "*.mobileprovision"))):
        decoded = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True).stdout
        try:
            profile = plistlib.loads(decoded)
        except Exception:
            continue
        if profile.get("Name") != name:
            continue
        problems = []
        if "OSX" not in profile.get("Platform", []):
            problems.append("it is not a macOS profile")
        if team not in profile.get("TeamIdentifier", []):
            problems.append(f"it belongs to team {', '.join(profile.get('TeamIdentifier', [])) or 'none'}")
        entitlements = profile.get("Entitlements", {})
        app_id = entitlements.get("com.apple.application-identifier") or entitlements.get("application-identifier")
        if app_id != f"{team}.{bundle}":
            problems.append(f"its App ID is {app_id}, not {team}.{bundle}")
        if profile.get("ProvisionedDevices") or entitlements.get("get-task-allow") or profile.get("ProvisionsAllDevices"):
            problems.append("it is a development or Developer ID profile, not a Mac App Store one")
        expiry = profile.get("ExpirationDate")
        # plistlib gives naive dates that are in UTC.
        if expiry and expiry.replace(tzinfo=datetime.timezone.utc) < datetime.datetime.now(datetime.timezone.utc):
            problems.append(f"it expired on {expiry:%Y-%m-%d}")
        if certificate:
            hashes = {hashlib.sha1(der).hexdigest().upper() for der in profile.get("DeveloperCertificates", [])}
            if certificate.upper() not in hashes:
                problems.append("it does not hold the Apple Distribution certificate found in the keychain")
        if problems:
            reasons.append(f"{path}: " + "; ".join(problems))
        else:
            found.append((expiry or datetime.datetime.max, profile.get("UUID"), path))
if found:
    expiry, uuid, path = max(found)
    print(f"{uuid}\t{path}\t{expiry:%Y-%m-%d}")
    sys.exit(0)
if reasons:
    print("a profile named '" + name + "' was found, but " + " / ".join(reasons))
else:
    print(f"no provisioning profile named '{name}' in {' or '.join(folders)}")
sys.exit(1)
PY
}

if [ "$MODE" != "rehearse" ]; then
    MISSING=()
    if APP_IDENTITY="$(find_identity "${APP_IDENTITY_NAMES[@]}")"; then
        APP_IDENTITY_HASH="${APP_IDENTITY%% *}"
        APP_IDENTITY_LABEL="${APP_IDENTITY#* }"
        say "App signing identity: $APP_IDENTITY_LABEL"
    else
        APP_IDENTITY_HASH=""
        MISSING+=("no valid '${APP_IDENTITY_NAMES[0]}' identity (or legacy '${APP_IDENTITY_NAMES[1]}') for team $TEAM in the keychain")
    fi
    if INSTALLER_IDENTITY="$(find_identity "${INSTALLER_IDENTITY_NAMES[@]}")"; then
        INSTALLER_IDENTITY_LABEL="${INSTALLER_IDENTITY#* }"
        say "Package signing identity: $INSTALLER_IDENTITY_LABEL"
    else
        MISSING+=("no valid '${INSTALLER_IDENTITY_NAMES[0]}' identity (or '${INSTALLER_IDENTITY_NAMES[1]}') for team $TEAM in the keychain")
    fi
    if PROFILE_FOUND="$(find_profile "$APP_IDENTITY_HASH")"; then
        IFS=$'\t' read -r PROFILE_UUID PROFILE_PATH PROFILE_EXPIRY <<<"$PROFILE_FOUND"
        say "Provisioning profile: '$PROFILE' ($PROFILE_UUID, expires $PROFILE_EXPIRY)"
    else
        MISSING+=("$PROFILE_FOUND")
    fi
    if [ "$UPLOAD" -eq 1 ]; then
        command -v xcrun >/dev/null || fail 2 "xcrun is not installed"
        if [ -z "${ASC_KEY_PATH:-}" ] || [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ]; then
            MISSING+=("--upload needs an App Store Connect API key: set all of ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID")
        elif [ ! -s "$ASC_KEY_PATH" ]; then
            MISSING+=("ASC_KEY_PATH does not name a readable, non-empty key file")
        else
            say "App Store Connect API key: $ASC_KEY_ID (not tried until the upload)"
        fi
    fi
    if [ "${#MISSING[@]}" -gt 0 ]; then
        for problem in "${MISSING[@]}"; do say "Missing: $problem"; done
        fail 3 "refusing to build the App Store package; see $GUIDE"
    fi
fi

if [ "$MODE" = "preflight" ]; then
    say "Preflight passed."
    exit 0
fi

# --- The checks every store build must pass ------------------------------------------------------
# check_app <Culla.app> <signed: 0 or 1>
check_app() {
    local app="$1" signed="$2"
    local plist="$app/Contents/Info.plist" binary="$app/Contents/MacOS/Culla"
    say "Checking ${app}…"
    [ -x "$binary" ] || fail 1 "no executable at $binary"

    plutil -lint "$plist" >/dev/null || fail 1 "Info.plist does not lint"
    local linted=0
    while IFS= read -r -d '' file; do
        plutil -lint "$file" >/dev/null || fail 1 "$file does not lint"
        linted=$((linted + 1))
    done < <(find "$app" -name '*.plist' -print0)
    local app_version app_build app_id category encryption
    app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
    app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
    app_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
    [ "$app_version" = "$VERSION" ] || fail 1 "the app says version $app_version, the project $VERSION"
    [ "$app_build" = "$BUILD" ] || fail 1 "the app says build $app_build, the project $BUILD"
    [ "$app_id" = "$BUNDLE_ID" ] || fail 1 "the bundle identifier is $app_id, expected $BUNDLE_ID"
    check "$linted property lists lint; version $app_version (build $app_build), $app_id"
    category="$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$plist" 2>/dev/null || true)"
    [ "$category" = "$CATEGORY" ] || fail 1 "LSApplicationCategoryType is '${category}', expected $CATEGORY"
    encryption="$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$plist" 2>/dev/null || true)"
    [ "$encryption" = "false" ] || fail 1 "ITSAppUsesNonExemptEncryption is '${encryption:-missing}', expected false"
    check "category $category; ITSAppUsesNonExemptEncryption false"

    # Exactly the three entitlements: the sandbox, user-selected files and app-scoped bookmarks;
    # no outgoing-connections entitlement, so the sandbox refuses every connection (the store
    # variant compiles the app's update check out; the store updates the app). A signed build also
    # carries the App ID and the team the profile grants, and nothing else.
    local entitlements expected
    entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || echo '{}')"
    expected='{"com.apple.security.app-sandbox":true,"com.apple.security.files.bookmarks.app-scope":true,"com.apple.security.files.user-selected.read-write":true}'
    if [ "$signed" -eq 1 ]; then
        expected="{\"com.apple.application-identifier\":\"$TEAM.$BUNDLE_ID\",\"com.apple.developer.team-identifier\":\"$TEAM\",${expected#\{}"
    fi
    [ "$(printf '%s' "$entitlements" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True, separators=(",", ":")))')" = "$expected" ] \
        || fail 1 "unexpected entitlements: $entitlements (expected $expected)"
    if [ "$signed" -eq 1 ]; then
        check "exactly the three entitlements (sandbox, user-selected files, bookmarks) with the App ID and team $TEAM"
    else
        check "exactly the three entitlements (sandbox, user-selected files, bookmarks); no outgoing-connections entitlement"
    fi

    if otool -L "$binary" | grep -E "CFNetwork\.framework|/Network\.framework" >&2; then
        fail 1 "the app links a network framework of its own"
    fi
    check "no CFNetwork or Network.framework linked"
    # URLSession comes with Foundation, so linking says nothing about who uses it: the sources say.
    local network_uses
    network_uses="$(grep -rlE --include='*.swift' \
        'URLSession|NSURLConnection|CFNetwork|CFSocket|CFStream|NWConnection|NWListener|NWPathMonitor|NWBrowser|^[[:space:]]*import[[:space:]]+Network([[:space:]]|$)' \
        "$REPO/Culla" "$REPO/CullaKit/Sources" | grep -v "^$REPO/CullaKit/Sources/CullaUpdates/" || true)"
    [ -z "$network_uses" ] || { printf '%s\n' "$network_uses" >&2; fail 1 "network code outside CullaKit/Sources/CullaUpdates"; }
    check "network code only in CullaKit/Sources/CullaUpdates"
    if LC_ALL=C grep -a -q -F "CullaAutomation" "$binary"; then
        fail 1 "the app contains the automation harness (CullaAutomation)"
    fi
    check "no CullaAutomation in the binary"

    # No update check of the app's own: Culla/Updates and every call into it are compiled out
    # under APP_STORE. Every marker here is in a Release build.
    local marker found=()
    for marker in "C5Culla13UpdateChecker" "menu.checkForUpdates" "settings.section.updates"; do
        if LC_ALL=C grep -a -q -F "$marker" "$binary"; then found+=("$marker"); fi
    done
    [ "${#found[@]}" -eq 0 ] || fail 1 "the app still holds the app's update check (${found[*]})"
    check "no update check of the app (UpdateChecker, Check for Updates…, the Updates section)"
    # The package's code (CullaKit/Sources/CullaUpdates) is still in the binary: Xcode links every
    # package product of the target as its own object file, in every configuration, and dead
    # stripping keeps its classes and type metadata. Nothing in the store variant calls it, and
    # without the outgoing-connections entitlement the sandbox refuses any connection it could
    # make. So this is a note for the log, not a failure.
    local dormant=()
    for marker in "cullaapp.com/update.json" "cullaapp.com/download" "CullaUpdates"; do
        if LC_ALL=C grep -a -q -F "$marker" "$binary"; then dormant+=("$marker"); fi
    done
    if [ "${#dormant[@]}" -gt 0 ]; then
        say "  note CullaUpdates is linked but never called, and the sandbox would refuse its connection (${dormant[*]})"
    fi

    codesign --verify --deep --strict "$app" 2>"$OUT/verify.log" || { cat "$OUT/verify.log" >&2; fail 1 "the app's signature does not verify"; }
    local signature authority
    signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
    if [ "$signed" -eq 1 ]; then
        authority="$(printf '%s\n' "$signature" | sed -n 's/^Authority=//p' | head -1)"
        [[ "$authority" == "${APP_IDENTITY_NAMES[0]}: "*"($TEAM)" || "$authority" == "${APP_IDENTITY_NAMES[1]}: "*"($TEAM)" ]] \
            || fail 1 "signed by '${authority:-nobody}', expected ${APP_IDENTITY_NAMES[0]} for team $TEAM"
        printf '%s\n' "$signature" | grep -qx "TeamIdentifier=$TEAM" || fail 1 "the team identifier is not $TEAM"
        [ -f "$app/Contents/embedded.provisionprofile" ] || fail 1 "the app has no embedded provisioning profile"
        check "signature verifies (deep, strict); $authority; profile embedded"
    else
        printf '%s\n' "$signature" | grep -qx "Signature=adhoc" || fail 1 "a rehearsal build should be ad hoc signed"
        check "signature verifies (deep, strict); ad hoc (rehearsal)"
    fi
    check "architectures: $(lipo -archs "$binary" 2>/dev/null || echo unknown)"
}

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# --- Rehearsal: an ad hoc build of the AppStore configuration ------------------------------------
if [ "$MODE" = "rehearse" ]; then
    say "Building the AppStore configuration (ad hoc signed) into $OUT/DerivedData…"
    xcodebuild -project "$REPO/Culla.xcodeproj" -scheme Culla -configuration AppStore \
        -destination 'generic/platform=macOS' -derivedDataPath "$OUT/DerivedData" build \
        >"$OUT/build.log" 2>&1 \
        || { grep -E "error:" "$OUT/build.log" | head -20 >&2; fail 2 "the build failed; log: $OUT/build.log"; }
    APP="$OUT/DerivedData/Build/Products/AppStore/Culla.app"
    [ -d "$APP" ] || fail 2 "the build made no Culla.app; log: $OUT/build.log"
    check_app "$APP" 0
    say "REHEARSAL ONLY: ad hoc signed, not for App Store Connect."
    echo "App: $APP"
    exit 0
fi

# --- Archive and export ------------------------------------------------------------------------
ARCHIVE="$OUT/Culla.xcarchive"
EXPORT="$OUT/export"
rm -rf "$ARCHIVE" "$EXPORT" "$OUT/expanded"

# The profile goes through CULLA_PROFILE, which only the app target reads:
# PROVISIONING_PROFILE_SPECIFIER on the command line would reach the package targets too.
say "Archiving into ${ARCHIVE}…"
xcodebuild -project "$REPO/Culla.xcodeproj" -scheme Culla -configuration AppStore \
    -destination 'generic/platform=macOS' -derivedDataPath "$OUT/DerivedData" \
    -archivePath "$ARCHIVE" archive \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$APP_IDENTITY_LABEL" DEVELOPMENT_TEAM="$TEAM" CULLA_PROFILE="$PROFILE" \
    >"$OUT/archive.log" 2>&1 \
    || { grep -E "error:" "$OUT/archive.log" | head -20 >&2; fail 2 "the archive failed; log: $OUT/archive.log"; }

# destination export: the package is written here and nothing is sent; --upload sends it below.
cat >"$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$APP_IDENTITY_LABEL</string>
  <key>installerSigningCertificate</key><string>$INSTALLER_IDENTITY_LABEL</string>
  <key>provisioningProfiles</key><dict>
    <key>$BUNDLE_ID</key><string>$PROFILE_UUID</string>
  </dict>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST
plutil -lint "$OUT/ExportOptions.plist" >/dev/null || fail 2 "the export options do not lint"

say "Exporting for App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$EXPORT" \
    >"$OUT/export.log" 2>&1 \
    || { grep -E "error" "$OUT/export.log" | head -20 >&2; fail 2 "the export failed; log: $OUT/export.log"; }
PKG="$(find "$EXPORT" -maxdepth 1 -name '*.pkg' | head -1)"
[ -n "$PKG" ] || fail 2 "the export made no installer package; log: $OUT/export.log"

# --- The package and the app inside it -------------------------------------------------------------
pkgutil --check-signature "$PKG" >"$OUT/pkg-signature.log" 2>&1 || { cat "$OUT/pkg-signature.log" >&2; fail 1 "the package is not signed"; }
grep -qF "$INSTALLER_IDENTITY_LABEL" "$OUT/pkg-signature.log" || { cat "$OUT/pkg-signature.log" >&2; fail 1 "the package is not signed by $INSTALLER_IDENTITY_LABEL"; }
check "package signed by $INSTALLER_IDENTITY_LABEL"
pkgutil --expand-full "$PKG" "$OUT/expanded" >"$OUT/expand.log" 2>&1 || { cat "$OUT/expand.log" >&2; fail 2 "the package could not be expanded"; }
APP="$(find "$OUT/expanded" -type d -name 'Culla.app' -prune | head -1)"
[ -n "$APP" ] || fail 1 "the package holds no Culla.app"
check_app "$APP" 1
rm -rf "$OUT/expanded"

# --- Upload: only when asked ----------------------------------------------------------------------
if [ "$UPLOAD" -eq 1 ]; then
    ASC_ARGS=(--api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --p8-file-path "$ASC_KEY_PATH" --output-format json)
    say "Validating with App Store Connect…"
    xcrun altool --validate-app "$PKG" "${ASC_ARGS[@]}" >"$OUT/validate.json" 2>"$OUT/validate.log" \
        || { tail -20 "$OUT/validate.json" "$OUT/validate.log" >&2; fail 2 "App Store Connect did not validate the package; see $OUT/validate.json"; }
    check "validated by App Store Connect"
    say "Uploading to App Store Connect…"
    xcrun altool --upload-package "$PKG" "${ASC_ARGS[@]}" >"$OUT/upload.json" 2>"$OUT/upload.log" \
        || { tail -20 "$OUT/upload.json" "$OUT/upload.log" >&2; fail 2 "the upload failed; see $OUT/upload.json"; }
    check "uploaded; App Store Connect's answer is in $OUT/upload.json"
else
    say "Not uploaded (pass --upload to validate and upload)."
fi

echo "Package: $PKG"

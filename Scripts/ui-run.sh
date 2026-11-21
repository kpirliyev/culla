#!/bin/bash
# Builds the Debug app, copies a test shoot into the app's sandbox container, runs a UI
# automation script in the background and prints the folder holding its snapshots and dumps.
#
# Usage: Scripts/ui-run.sh <script.json> [options]
#   --shoot <folder>   the shoot to copy in (default: the generated 35-photo sample)
#   --keep-shoot       reuse the shoot already in the container instead of copying it again
#                      (to test files added or removed between runs)
#   --reset            delete the automation database, thumbnails and settings first
#                      (first-launch behaviour); by default they are kept, to test reopening
#   --no-build         skip xcodebuild
#   --timeout <s>      give up after this many seconds (default 300)
#
# Environment: CULLA_DERIVED_DATA overrides the DerivedData folder.
# Exit status: 0 when every step passed, 1 when a step failed, 2 when the build failed,
# 124 on timeout. See Scripts/README.md for the script format.
set -euo pipefail

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

SCRIPT=""
SHOOT=""
KEEP_SHOOT=0
RESET=0
BUILD=1
TIMEOUT=300
while [ $# -gt 0 ]; do
    case "$1" in
        --shoot) SHOOT="$2"; shift 2 ;;
        --keep-shoot) KEEP_SHOOT=1; shift ;;
        --reset) RESET=1; shift ;;
        --no-build) BUILD=0; shift ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        -*) echo "Unknown option $1" >&2; usage 2 ;;
        *) if [ -z "$SCRIPT" ]; then SCRIPT="$1"; shift; else echo "Unexpected $1" >&2; usage 2; fi ;;
    esac
done
[ -n "$SCRIPT" ] || usage 2
[ -f "$SCRIPT" ] || { echo "No such script: $SCRIPT" >&2; exit 2; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${CULLA_DERIVED_DATA:-/private/tmp/claude-501/-Users-kpirliyev--claude-spares-spare-GbpzHL/8f631fd4-fb21-48e3-9a6a-52261335d745/scratchpad/DerivedData-ui}"
APP="$DERIVED/Build/Products/Debug/Culla.app"
CONTAINER="$HOME/Library/Containers/com.kpirliyev.Culla/Data"
AUTO="$CONTAINER/tmp/CullaAutomation"

# 1. Build.
if [ "$BUILD" -eq 1 ]; then
    mkdir -p "$DERIVED"
    BUILD_LOG="$DERIVED/ui-run-build.log"
    if ! xcodebuild -project "$REPO/Culla.xcodeproj" -scheme Culla -configuration Debug \
        -destination 'platform=macOS' -derivedDataPath "$DERIVED" build >"$BUILD_LOG" 2>&1; then
        grep -E "error:" "$BUILD_LOG" | head -20 >&2 || tail -20 "$BUILD_LOG" >&2
        echo "Build failed; log: $BUILD_LOG" >&2
        exit 2
    fi
fi
[ -x "$APP/Contents/MacOS/Culla" ] || { echo "No app at $APP; build first" >&2; exit 2; }

# 2. The shoot, copied into the container where the sandboxed app can read it without a panel.
if [ -z "$SHOOT" ]; then
    SHOOT="$DERIVED/CullaSampleShoot"
    if [ ! -d "$SHOOT" ]; then
        echo "Generating the sample shoot in $SHOOT" >&2
        python3 "$REPO/Scripts/make_sample_shoot.py" "$SHOOT" >&2
    fi
fi
[ -d "$SHOOT" ] || { echo "No such shoot folder: $SHOOT" >&2; exit 2; }
SHOOT_NAME="$(basename "$SHOOT")"
DEST="$AUTO/shoots/$SHOOT_NAME"
mkdir -p "$AUTO/shoots" "$AUTO/scripts" "$AUTO/runs"
# An empty folder, for scripts that check the empty-shoot state: "$SHOOT/../Empty".
mkdir -p "$AUTO/shoots/Empty"
# A script may have left the copy read-only or unreadable (a locked card or a pulled card,
# simulated): make it ours again first.
[ -d "$DEST" ] && chmod -R u+rwX "$DEST" 2>/dev/null || true
if [ "$KEEP_SHOOT" -eq 0 ] || [ ! -d "$DEST" ]; then
    # -a keeps modification dates, so unchanged files stay unchanged for the app.
    rsync -a --delete "$SHOOT/" "$DEST/"
fi

# 3. The script and the output folder.
SCRIPT_NAME="$(basename "$SCRIPT" .json)"
cp "$SCRIPT" "$AUTO/scripts/$SCRIPT_NAME.json"
OUT="$AUTO/runs/$SCRIPT_NAME-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$OUT"

# 4. Run in the background: no activation, no focus change. Only automation instances of the
#    app are ever stopped here.
pkill -f "Culla.app/Contents/MacOS/Culla -CullaAutomation" 2>/dev/null || true
#    The app runs in English unless the script asks for another language with a top-level
#    "language" ("ru", "tk"): the argument domain overrides the Mac's language and any language
#    chosen in Culla's Settings, so results never depend on either.
LANGUAGE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("language") or "en")' "$SCRIPT")"
case "$LANGUAGE" in en|ru|tk) ;; *) echo "Unknown language $LANGUAGE in $SCRIPT (en, ru or tk)" >&2; exit 2 ;; esac
ARGS=(-CullaAutomation "$AUTO/scripts/$SCRIPT_NAME.json" -CullaAutomationOutput "$OUT" -CullaShoot "$DEST"
      -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO -AppleLanguages "($LANGUAGE)")
[ "$RESET" -eq 1 ] && ARGS+=(-CullaAutomationReset YES)
"$APP/Contents/MacOS/Culla" "${ARGS[@]}" >"$OUT/app.log" 2>&1 &
PID=$!

START=$(date +%s)
while kill -0 "$PID" 2>/dev/null; do
    if [ $(( $(date +%s) - START )) -ge "$TIMEOUT" ]; then
        kill -9 "$PID" 2>/dev/null || true
        echo "Timed out after $TIMEOUT s; output: $OUT" >&2
        echo "$OUT"
        exit 124
    fi
    sleep 0.2
done
wait "$PID" 2>/dev/null || true

# 5. Report.
grep "^\[automation\]" "$OUT/app.log" >&2 || true
echo "$OUT"
if [ -f "$OUT/result.json" ] && python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("ok") else 1)' "$OUT/result.json"; then
    exit 0
fi
[ -f "$OUT/result.json" ] || echo "No result.json: the app ended without finishing the script" >&2
exit 1

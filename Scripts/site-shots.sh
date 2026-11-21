#!/bin/bash
# Makes the landing page's screenshots from the app: the five slots in English, Russian and
# Turkmen, written to site/public/shots/<slot>.<lang>.png (fifteen files, replaced on every run).
#
# Usage: Scripts/site-shots.sh [shoot folder] [--no-build] [--out <folder>] [--evidence <file name>] [--stack-gap <s>]
#   shoot folder   the photos to show (default: culla-demo-shoot/photos)
#   --no-build     use the Debug app already built
#   --out <folder> write the PNGs there instead of site/public/shots
#   --evidence <file name>
#                  the Eyes Closed photo to show in vision-evidence (its original name), when
#                  the one chosen by state is a photo Culla flagged wrongly (its eyes are open)
#   --stack-gap <s> the shoot's stack time gap for the capture (default 300; the app's own
#                  default, 10 s, is not changed)
#
# Only finished image files are used: a download still being written (.part) and hidden files
# are left out. They are copied, renamed IMG_4101.jpg upward in capture-time order, to a staging
# folder named "Portraits" (the name the window shows)
# and from there into the app's sandbox container, so nothing is written into the shoot folder.
# The runs use the automation database, caches and settings, never the real ones.
#
# Environment: CULLA_DERIVED_DATA as for ui-run.sh. The staging folder and the generated
# scripts are kept in $TMPDIR/culla-site-shots.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SHOOT=""
SHOTS="$REPO/site/public/shots"
EVIDENCE=()
# The demo photos are published frames taken minutes apart, so the screenshots are taken with
# the stack time gap set to 300 s, as the open shoot's own tuning (the tuning panel's way). The
# app's default (10 s) and every other threshold are unchanged.
STACK_GAP=300
BUILD=1
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0; shift ;;
        --out) SHOTS="$2"; shift 2 ;;
        --evidence) EVIDENCE=("$2"); shift 2 ;;
        --stack-gap) STACK_GAP="$2"; shift 2 ;;
        -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Unknown option $1" >&2; exit 2 ;;
        *) if [ -z "$SHOOT" ]; then SHOOT="$1"; shift; else echo "Unexpected $1" >&2; exit 2; fi ;;
    esac
done
SHOOT="${SHOOT:-$REPO/culla-demo-shoot/photos}"

WORK="${TMPDIR:-/tmp}/culla-site-shots"
STAGE="$WORK/Portraits"

# 1. The photos: finished image files only, copied under camera-style names (IMG_4101.jpg
#    upward, in capture-time order) so no photographer's name or source shows in a screenshot.
#    The copies are byte for byte the originals, so the app reads the same capture times.
[ -d "$SHOOT" ] || { echo "No shoot folder at $SHOOT" >&2; exit 2; }
mkdir -p "$WORK"
COUNT="$(python3 "$REPO/Scripts/site-shots.py" stage "$SHOOT" "$STAGE" "$WORK/names.json")" || exit 2
echo "Using $COUNT photos from $SHOOT" >&2

# 2. Build once.
NO_BUILD=(--no-build)
if [ "$BUILD" -eq 1 ]; then NO_BUILD=(); fi

run() {
    # $1: script, then ui-run.sh options. Prints the run folder; fails with the run's error.
    local out code=0
    out="$("$REPO/Scripts/ui-run.sh" "$1" --reset --shoot "$STAGE" --timeout 1500 "${@:2}")" || code=$?
    if [ "$code" -ne 0 ]; then
        python3 -c 'import json,sys
try: print("Failed:", json.load(open(sys.argv[1] + "/result.json")).get("error"), file=sys.stderr)
except Exception: pass' "$out" 2>&1 >&2 || true
        echo "$(basename "$1") failed (exit $code); output: $out" >&2
        exit 1
    fi
    echo "$out"
}

# 3. What Culla finds in the shoot, to choose what each slot shows.
echo "Analysing the shoot…" >&2
python3 "$REPO/Scripts/site-shots.py" probe "$STACK_GAP" "$WORK/site-shots-probe.json"
PROBE="$(run "$WORK/site-shots-probe.json" ${NO_BUILD[@]+"${NO_BUILD[@]}"})"

# 4. The capture, once per language.
mkdir -p "$SHOTS"
for LANG_CODE in en ru tk; do
    SCRIPT="$WORK/site-shots-$LANG_CODE.json"
    python3 "$REPO/Scripts/site-shots.py" script "$PROBE/probe.json" "$LANG_CODE" "$SCRIPT" "$STACK_GAP" "$WORK/names.json" ${EVIDENCE[@]+"${EVIDENCE[@]}"}
    echo "Capturing in $LANG_CODE…" >&2
    OUT="$(run "$SCRIPT" --no-build --keep-shoot)"
    python3 "$REPO/Scripts/site-shots.py" finish "$OUT" "$LANG_CODE" "$SHOTS" >/dev/null
done

echo "Wrote 15 screenshots to $SHOTS:" >&2
ls -1 "$SHOTS"/*.png

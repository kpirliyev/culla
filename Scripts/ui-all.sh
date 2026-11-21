#!/bin/bash
# Runs every UI automation script in Scripts/ui/ in order, each with the setup its "needs" header
# asks for, and prints a pass/fail table. Builds the Debug app once.
#
# Usage: Scripts/ui-all.sh [--quick] [--optimized] [--only <pattern>] [--no-build]
#   --quick          skip the slow scripts (those marked "slow": large shoots)
#   --optimized      build the Debug app (with the harness) with the optimizer on, into its own
#                    DerivedData, for performance numbers: unoptimized pixel loops make analysis about three times
#                    slower than culla-eval
#   --only <pattern> run only scripts whose file name contains the pattern (dependencies are
#                    not added; run them yourself)
#   --no-build       use the app already built
#
# Each script's needs are data, in a "needs" object at the top of its JSON:
#   "reset": true          start from nothing (--reset)
#   "shoot": "sample"      which shoot: sample (35 photos), large (make_large_photos.py),
#                          2000, 5000 or 10000 (make_sample_shoot.py --count N)
#   "after": "<script>"    must run after that script (skipped when it failed or did not run)
#   "keepShoot": true      reuse the container's copy of the shoot (--keep-shoot)
#   "prepare": [...]       file changes in the container's copy first, each
#                          ["copy", from, to] (copied, then touched) or ["remove", name]
#   "slow": true           left out by --quick
#   "timeout": 600         seconds before ui-run.sh gives up
#
# Fixtures that are missing are generated once into a cache folder outside the repository:
# $CULLA_FIXTURES (default: next to the DerivedData folder ui-run.sh uses). Point
# CULLA_SHOOT_2000, CULLA_SHOOT_5000, CULLA_SHOOT_10000 or CULLA_LARGE_PHOTOS at existing folders to skip that.
# Exit status: 0 when every script that ran passed, 1 otherwise, 2 when the build failed.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${CULLA_DERIVED_DATA:-/private/tmp/claude-501/-Users-kpirliyev--claude-spares-spare-GbpzHL/8f631fd4-fb21-48e3-9a6a-52261335d745/scratchpad/DerivedData-ui}"
FIXTURES="${CULLA_FIXTURES:-$(dirname "$DERIVED")/culla-fixtures}"
SAMPLE="$DERIVED/CullaSampleShoot"
CONTAINER_SHOOTS="$HOME/Library/Containers/com.kpirliyev.Culla/Data/tmp/CullaAutomation/shoots"

QUICK=0
ONLY=""
BUILD=1
EXTRA=()
while [ $# -gt 0 ]; do
    case "$1" in
        --quick) QUICK=1; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        --no-build) BUILD=0; shift ;;
        --optimized) DERIVED="$DERIVED-optimized"; EXTRA=(SWIFT_OPTIMIZATION_LEVEL=-O GCC_OPTIMIZATION_LEVEL=s SWIFT_COMPILATION_MODE=wholemodule); shift ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option $1" >&2; exit 2 ;;
    esac
done

export CULLA_DERIVED_DATA="$DERIVED"

# 1. Build once.
if [ "$BUILD" -eq 1 ]; then
    mkdir -p "$DERIVED"
    echo "Building…" >&2
    if ! xcodebuild -project "$REPO/Culla.xcodeproj" -scheme Culla -configuration Debug \
        -destination 'platform=macOS' -derivedDataPath "$DERIVED" ${EXTRA[@]+"${EXTRA[@]}"} build >"$DERIVED/ui-all-build.log" 2>&1; then
        grep -E "error:" "$DERIVED/ui-all-build.log" | head -20 >&2
        echo "Build failed; log: $DERIVED/ui-all-build.log" >&2
        exit 2
    fi
fi

# The SwiftUI views' accessibility labels, checked in the source (the harness reads only the
# AppKit side of the accessibility tree).
A11Y_SOURCE=0
python3 "$REPO/Scripts/check-accessibility.py" >&2 || A11Y_SOURCE=1

# 2. Fixtures, made only when a script needs one.
fixture() {
    case "$1" in
        sample)
            local dir="$SAMPLE"
            [ -d "$dir" ] || python3 "$REPO/Scripts/make_sample_shoot.py" "$dir" >&2
            echo "$dir" ;;
        large)
            local dir="${CULLA_LARGE_PHOTOS:-$FIXTURES/large-photos}"
            if [ ! -d "$dir" ]; then echo "Generating $dir" >&2; python3 "$REPO/Scripts/make_large_photos.py" "$dir" >&2; fi
            echo "$dir" ;;
        2000|5000|10000)
            local var="CULLA_SHOOT_$1"
            local dir="${!var:-$FIXTURES/shoot-$1}"
            if [ ! -d "$dir" ]; then echo "Generating $dir (this takes a while)" >&2; python3 "$REPO/Scripts/make_sample_shoot.py" "$dir" --count "$1" >&2; fi
            echo "$dir" ;;
        *) echo "Unknown shoot $1" >&2; return 1 ;;
    esac
}

# Reads a script's needs as shell assignments.
needs() {
    python3 - "$1" <<'PY'
import json, shlex, sys
script = json.load(open(sys.argv[1]))
needs = script.get("needs", {})
def out(name, value):
    print(f"{name}={shlex.quote(str(value))}")
out("N_RESET", 1 if needs.get("reset") else 0)
out("N_SHOOT", needs.get("shoot", "sample"))
out("N_AFTER", needs.get("after", ""))
out("N_KEEP", 1 if needs.get("keepShoot") else 0)
out("N_SLOW", 1 if needs.get("slow") else 0)
out("N_TIMEOUT", needs.get("timeout", 300))
out("N_PREPARE", json.dumps(needs.get("prepare", [])))
PY
}

prepare() {
    # $1: the container's copy of the shoot, $2: the JSON list of changes.
    python3 - "$1" "$2" <<'PY'
import json, os, shutil, sys, time
folder, changes = sys.argv[1], json.loads(sys.argv[2])
for change in changes:
    if change[0] == "copy":
        source, target = os.path.join(folder, change[1]), os.path.join(folder, change[2])
        shutil.copyfile(source, target)
        now = time.time()
        os.utime(target, (now, now))
    elif change[0] == "remove":
        path = os.path.join(folder, change[1])
        if os.path.exists(path):
            os.remove(path)
    else:
        raise SystemExit(f"Unknown change {change}")
PY
}

# 3. Run.
NAMES=(); RESULTS=(); TIMES=(); OUTS=()
# Status by script name, as lines "name status" (Bash 3 has no associative arrays).
STATUS_LINES=""
set_status() { STATUS_LINES="$STATUS_LINES$1 $2"$'\n'; }
status_of() { printf '%s' "$STATUS_LINES" | awk -v n="$1" '$1 == n { s = $2 } END { print s }'; }
FAILED=0
for SCRIPT in "$REPO"/Scripts/ui/*.json; do
    NAME="$(basename "$SCRIPT" .json)"
    [ -n "$ONLY" ] && [[ "$NAME" != *"$ONLY"* ]] && continue
    eval "$(needs "$SCRIPT")"
    if [ "$QUICK" -eq 1 ] && [ "$N_SLOW" -eq 1 ]; then
        NAMES+=("$NAME"); RESULTS+=("skipped (slow)"); TIMES+=("-"); OUTS+=("")
        set_status "$NAME" skipped
        continue
    fi
    if [ -n "$N_AFTER" ] && [ -z "$ONLY" ] && [ "$(status_of "$N_AFTER")" != "pass" ]; then
        NAMES+=("$NAME"); RESULTS+=("skipped ($N_AFTER did not pass)"); TIMES+=("-"); OUTS+=("")
        set_status "$NAME" skipped
        FAILED=1
        continue
    fi
    SHOOT_DIR="$(fixture "$N_SHOOT")" || { NAMES+=("$NAME"); RESULTS+=("FAIL (no fixture)"); TIMES+=("-"); OUTS+=(""); FAILED=1; continue; }
    ARGS=(--no-build --shoot "$SHOOT_DIR" --timeout "$N_TIMEOUT")
    [ "$N_RESET" -eq 1 ] && ARGS+=(--reset)
    [ "$N_KEEP" -eq 1 ] && ARGS+=(--keep-shoot)
    if [ "$N_PREPARE" != "[]" ]; then
        prepare "$CONTAINER_SHOOTS/$(basename "$SHOOT_DIR")" "$N_PREPARE" || { NAMES+=("$NAME"); RESULTS+=("FAIL (prepare)"); TIMES+=("-"); OUTS+=(""); FAILED=1; continue; }
    fi
    echo "▶ $NAME ${ARGS[*]}" >&2
    START=$(date +%s)
    OUT="$("$REPO/Scripts/ui-run.sh" "$SCRIPT" "${ARGS[@]}" 2>"$DERIVED/ui-all-$NAME.log")"
    CODE=$?
    ELAPSED=$(( $(date +%s) - START ))
    NAMES+=("$NAME"); TIMES+=("${ELAPSED}s"); OUTS+=("$OUT")
    if [ "$CODE" -eq 0 ]; then
        RESULTS+=("pass"); set_status "$NAME" pass
    else
        REASON="$(python3 -c 'import json,sys
try:
    r = json.load(open(sys.argv[1] + "/result.json")); print((r.get("error") or "")[:110])
except Exception: print("no result (exit '"$CODE"')")' "$OUT" 2>/dev/null)"
        RESULTS+=("FAIL: $REASON"); set_status "$NAME" fail; FAILED=1
        grep "✗" "$DERIVED/ui-all-$NAME.log" >&2 || true
    fi
done

[ "$A11Y_SOURCE" -eq 0 ] || { echo "Scripts/check-accessibility.py found unnamed SwiftUI controls" >&2; FAILED=1; }

# 4. Report.
printf '\n%-36s %-7s %s\n' "Script" "Time" "Result"
printf '%-36s %-7s %s\n' "------" "----" "------"
for i in "${!NAMES[@]}"; do
    printf '%-36s %-7s %s\n' "${NAMES[$i]}" "${TIMES[$i]}" "${RESULTS[$i]}"
done
echo
for i in "${!NAMES[@]}"; do
    [ -n "${OUTS[$i]}" ] && echo "${NAMES[$i]}: ${OUTS[$i]}"
done
exit "$FAILED"

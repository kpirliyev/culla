#!/usr/bin/env bash
# Builds and tests the site in podman containers. Needs only podman on the
# Mac (with its machine running); never uses the Mac's own Node or Python.
#
#   site/test.sh [all]    everything below, in this order
#   site/test.sh build    npm ci (when package-lock.json changed) and
#                         npm run generate in a Node container, then checks
#                         the build; writes site/.output/public/
#   site/test.sh unit     python3 -m unittest discover -s site/deploy/test
#   site/test.sh deploy   site/deploy/test/run-deploy-tests.sh
#   site/test.sh nginx    site/deploy/test/run-nginx-tests.sh
#
#   site/test.sh preview  serves the last build on http://localhost:4173 with
#                         the production CSP (npm run preview:static, in the
#                         Node container) until Ctrl-C; not part of all
#
# Several can be given, for example `site/test.sh unit deploy`.
#
# Images (pulled or built the first time, then reused):
#   docker.io/library/node:26.13.1-trixie-slim   the build
#   localhost/culla-site-test:<hash>              the tests: the official
#       nginx image with python3 and rsync added, from
#       site/containers/test.Containerfile; rebuilt only when that file or
#       the nginx image changes. CULLA_NGINX_IMAGE picks another nginx image
#       (default docker.io/library/nginx:1.26.3-bookworm).
# Volumes: culla-site-node-modules (the build's node_modules, never the
# Mac's site/node_modules) and culla-site-npm-cache (npm's download cache).
# `site/test.sh clean` removes both volumes and the test images.
#
# The tests run with no network (--network none). The build needs the npm
# registry for npm ci, the first time and after the lockfile changes.
# Exit status: 0 everything passed, 1 something failed, 2 podman is not usable.

set -uo pipefail

site="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$site")"

NODE_IMAGE=docker.io/library/node:26.13.1-trixie-slim
NGINX_IMAGE="${CULLA_NGINX_IMAGE:-docker.io/library/nginx:1.26.3-bookworm}"
TEST_REPO=localhost/culla-site-test
CONTAINERFILE="$site/containers/test.Containerfile"
VOL_MODULES=culla-site-node-modules
VOL_NPM=culla-site-npm-cache

say() { printf 'test: %s\n' "$*"; }

# --- Podman ------------------------------------------------------------------

if ! command -v podman >/dev/null 2>&1; then
    echo "test: podman is not installed; install it (brew install podman), then run: podman machine init && podman machine start" >&2
    exit 2
fi
if ! podman info >/dev/null 2>&1; then
    echo "test: podman is not running; start it with: podman machine start" >&2
    exit 2
fi

# Every container gets a name of ours, so that an interrupted run can remove
# it. They all run with --rm and are gone when they exit anyway.
containers=()
cleanup() {
    local n
    for n in ${containers[@]+"${containers[@]}"}; do
        podman rm -f --time 2 "$n" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

run() {  # run <name> <podman run arguments...>
    local name="culla-site-$1-$$" pid; shift
    containers+=("$name")
    # In the background and waited for, so that a signal to this script runs
    # the trap at once (it removes the container) instead of after the
    # container has finished. --init makes the container stop on SIGTERM.
    podman run --rm --init --name "$name" "$@" </dev/null &
    pid=$!
    wait "$pid"
}

ensure_pulled() {  # ensure_pulled <image>
    podman image exists "$1" || podman pull -q "$1" >/dev/null
}

TEST_IMAGE=""
ensure_test_image() {
    [ -z "$TEST_IMAGE" ] || return 0
    local hash
    hash="$( { cat "$CONTAINERFILE"; printf '%s\n' "$NGINX_IMAGE"; } | shasum -a 256 | cut -c1-12)"
    TEST_IMAGE="$TEST_REPO:$hash"
    if ! podman image exists "$TEST_IMAGE"; then
        say "building $TEST_IMAGE from site/containers/test.Containerfile on $NGINX_IMAGE"
        ensure_pulled "$NGINX_IMAGE" || return 1
        podman build -q --layers=false --build-arg "NGINX_IMAGE=$NGINX_IMAGE" \
            -t "$TEST_IMAGE" -f "$CONTAINERFILE" "$site/containers" >/dev/null || return 1
        # Older builds of the test image are of no further use.
        local old
        for old in $(podman images --format '{{.Repository}}:{{.Tag}}' "$TEST_REPO" | grep -vx "$TEST_IMAGE"); do
            podman rmi "$old" >/dev/null 2>&1 || true
        done
    fi
}

# The tests see the repository's site/ read-only, at the same path as on the
# Mac, and run from the repository's root. Mounts are given with --mount:
# podman 6.1 on macOS mangles some `-v <path>:<path>:ro` (the repository's
# root came out mounted at ".../Cullao"), --mount is parsed strictly.
test_mounts=(--mount "type=bind,src=$site,dst=$site,ro" -w "$repo")

# --- Steps -------------------------------------------------------------------

step_build() {
    ensure_pulled "$NODE_IMAGE" || return 1
    local extra=()
    if [ -n "${CULLA_ICON_SRC:-}" ]; then
        local src
        src="$(cd "$(dirname "$CULLA_ICON_SRC")" 2>/dev/null && pwd)/$(basename "$CULLA_ICON_SRC")"
        [ -f "$src" ] || { echo "test: CULLA_ICON_SRC: no such file: $CULLA_ICON_SRC" >&2; return 1; }
        extra=(--mount "type=bind,src=$src,dst=$src,ro" -e "CULLA_ICON_SRC=$src")
    fi
    # The repository read-only (for the app icon and the workspace root),
    # site/ writable, and the two volumes over node_modules and npm's cache.
    run build \
        --mount "type=bind,src=$repo,dst=$repo,ro" --mount "type=bind,src=$site,dst=$site" \
        --mount "type=volume,src=$VOL_MODULES,dst=$site/node_modules" \
        --mount "type=volume,src=$VOL_NPM,dst=/root/.npm" \
        -w "$site" -e CULLA_IN_CONTAINER=1 -e NUXT_TELEMETRY_DISABLED=1 -e CI=1 \
        ${extra[@]+"${extra[@]}"} \
        "$NODE_IMAGE" bash containers/build.sh
}

step_unit() {
    ensure_test_image || return 1
    run unit --network none --user tester "${test_mounts[@]}" "$TEST_IMAGE" \
        python3 -m unittest discover -s site/deploy/test
}

step_deploy() {
    ensure_test_image || return 1
    run deploy --network none --user tester "${test_mounts[@]}" "$TEST_IMAGE" \
        bash site/deploy/test/run-deploy-tests.sh
}

step_nginx() {
    ensure_test_image || return 1
    # As root inside the container, so nginx can listen on 80 and 443. IPv6
    # is switched on so that `listen [::]:443` passes nginx -t.
    run nginx --network none --sysctl net.ipv6.conf.all.disable_ipv6=0 \
        "${test_mounts[@]}" -e "CULLA_NGINX_IMAGE=$NGINX_IMAGE" "$TEST_IMAGE" \
        bash site/deploy/test/run-nginx-tests.sh
}

step_preview() {
    ensure_pulled "$NODE_IMAGE" || return 1
    [ -s "$site/.output/public/en/index.html" ] || { echo "test: no build yet; run site/test.sh build first" >&2; return 1; }
    run preview -p 127.0.0.1:4173:4173 \
        --mount "type=bind,src=$site,dst=$site,ro" -w "$site" \
        "$NODE_IMAGE" node scripts/preview.mjs
}

clean() {
    podman volume rm -f "$VOL_MODULES" "$VOL_NPM" >/dev/null 2>&1 || true
    local img
    for img in $(podman images --format '{{.Repository}}:{{.Tag}}' "$TEST_REPO"); do
        podman rmi "$img" >/dev/null 2>&1 || true
    done
    say "removed the volumes $VOL_MODULES and $VOL_NPM and the $TEST_REPO images"
    say "the pulled images stay; remove them with: podman rmi $NODE_IMAGE $NGINX_IMAGE"
}

# --- Main --------------------------------------------------------------------

[ $# -gt 0 ] || set -- all
steps=()
for arg in "$@"; do
    case "$arg" in
        all) steps+=(build unit deploy nginx) ;;
        build|unit|deploy|nginx|preview) steps+=("$arg") ;;
        clean) clean; exit 0 ;;
        -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "test: unknown step: $arg (build, unit, deploy, nginx, all, preview or clean)" >&2; exit 2 ;;
    esac
done

results=()
failed=0
total_start=$SECONDS
for s in "${steps[@]}"; do
    printf '\n=== %s\n' "$s"
    start=$SECONDS
    if "step_$s"; then
        results+=("$(printf 'ok     %-7s %4ss' "$s" $((SECONDS - start)))")
    else
        results+=("$(printf 'FAILED %-7s %4ss' "$s" $((SECONDS - start)))")
        failed=1
    fi
done

printf '\n=== summary\n'
printf '%s\n' "${results[@]}"
if [ "$failed" = 0 ]; then
    printf 'all passed in %ss\n' $((SECONDS - total_start))
else
    printf 'FAILED (%ss)\n' $((SECONDS - total_start))
fi
exit "$failed"

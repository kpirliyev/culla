#!/usr/bin/env bash
# Deploy cullaapp.com from the owner's Mac.
#
#   site/deploy/deploy.sh                    build the site, upload it and
#                                            point /download at the release
#                                            named in site/release.json
#   site/deploy/deploy.sh --check            the same, but only shows what
#                                            it would change
#   site/deploy/deploy.sh --nginx            install Culla's nginx files
#                                            (configuration, snippets, error
#                                            pages) after a change to them
#   site/deploy/deploy.sh --upload-setup     copy site/deploy/ to the server
#                                            for setup-host.sh (see SETUP.md)
#
# The disk images are assets of the releases on GitHub, not files on this
# server. site/release.json names the newest one:
#   { "repository": "<owner>/<name>", "version": "1.0",
#     "file": "Culla-1.0.dmg", ..., "date": "" }
# While "date" is empty the release is not published and /download answers
# 503 with a friendly page. Once "date" is set, /download redirects to
#   https://github.com/<repository>/releases/download/v<version>/<file>
#
# Needs in the environment (never written into the repository):
#   CULLA_DEPLOY_HOST   the server's address
#   CULLA_DEPLOY_USER   the SSH user on the server (owner of the web root)
#   CULLA_DEPLOY_PORT   optional, the SSH port (default 22)
#   CULLA_DEPLOY_KEY    optional, an SSH identity file; ssh and rsync then
#                       use only that key (-i <file> -o IdentitiesOnly=yes)
#
# --nginx needs root on the server, and so does an ordinary deploy when it
# changes where /download points (only then). If setup-host.sh was run with
# CULLA_PASSWORDLESS=yes, `sudo -n /usr/local/sbin/cullaapp-install` works
# without a password and is used; otherwise remote-install.sh is run over
# `ssh -t` and sudo asks for the password. The exact commands are listed at
# the top of remote-install.sh. Uploading the site needs neither.
# The first-time setup, count.py, the logrotate rule and the crontab are
# setup-host.sh's, run by the owner as root on the server.
#
# It never writes to or deletes from /data/cullaapp.com/log/.
#
# Test hooks (used by test/run-deploy-tests.sh, not for normal use):
#   CULLA_DEPLOY_LOCAL=1           "server" is this machine: no ssh, rsync to
#                                  local paths, remote commands run locally
#   CULLA_DEPLOY_WWW_ROOT          default /data/cullaapp.com/www
#   CULLA_DEPLOY_SKIP_BUILD=1      do not build (no site/test.sh build)
#   CULLA_DEPLOY_OUTPUT            default site/.output/public
#   CULLA_DEPLOY_RELEASE_JSON      default site/release.json
#   CULLA_ROOT                     prefixes /etc/... when reading the current
#                                  /download target (as in remote-install.sh)
#   CULLA_DEPLOY_SSH               the ssh command (default ssh)
#   CULLA_DEPLOY_SUDO              default "sudo -n"
#   CULLA_DEPLOY_INSTALLER         default /usr/local/sbin/cullaapp-install
#   CULLA_DEPLOY_SETUP_DIR         where --upload-setup puts the files
#                                  (default cullaapp-setup in the home folder)

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
site="$(dirname "$here")"

WWW_ROOT="${CULLA_DEPLOY_WWW_ROOT:-/data/cullaapp.com/www}"
OUTPUT="${CULLA_DEPLOY_OUTPUT:-$site/.output/public}"
RELEASE_JSON="${CULLA_DEPLOY_RELEASE_JSON:-$site/release.json}"
LOCAL="${CULLA_DEPLOY_LOCAL:-0}"
TARGET_FILE="${CULLA_ROOT:-}/etc/nginx/cullaapp/download-target.conf"

die() { printf 'deploy: %s\n' "$*" >&2; exit 1; }
say() { printf 'deploy: %s\n' "$*"; }

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# --- Arguments --------------------------------------------------------------

mode=site
check=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check) check=1 ;;
        --nginx) mode=nginx ;;
        --upload-setup) mode=upload-setup ;;
        -h|--help) usage 0 ;;
        *) printf 'deploy: unknown argument: %s\n\n' "$1" >&2; usage 2 ;;
    esac
    shift
done

[ -n "${CULLA_DEPLOY_HOST:-}" ] || die "set CULLA_DEPLOY_HOST to the server's address"
[ -n "${CULLA_DEPLOY_USER:-}" ] || die "set CULLA_DEPLOY_USER to the SSH user on the server"
PORT="${CULLA_DEPLOY_PORT:-22}"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "CULLA_DEPLOY_PORT must be a number"
TARGET="$CULLA_DEPLOY_USER@$CULLA_DEPLOY_HOST"
SSH="${CULLA_DEPLOY_SSH:-ssh}"
SUDO_N="${CULLA_DEPLOY_SUDO-sudo -n}"
INSTALLER="${CULLA_DEPLOY_INSTALLER:-/usr/local/sbin/cullaapp-install}"
SETUP_DIR="${CULLA_DEPLOY_SETUP_DIR:-cullaapp-setup}"
case "/$SETUP_DIR/" in
    //|*/../*|*/./*) die "CULLA_DEPLOY_SETUP_DIR must name a folder of its own" ;;
esac

SSH_OPTS=(-p "$PORT")
if [ -n "${CULLA_DEPLOY_KEY:-}" ]; then
    # rsync splits its -e command at spaces, so the path must not have any.
    [[ "$CULLA_DEPLOY_KEY" =~ ^[A-Za-z0-9_./+-]+$ ]] \
        || die "CULLA_DEPLOY_KEY must be a path without spaces, quotes or ~ (use \$HOME/...)"
    [ -f "$CULLA_DEPLOY_KEY" ] || die "no such key file: $CULLA_DEPLOY_KEY"
    SSH_OPTS+=(-i "$CULLA_DEPLOY_KEY" -o IdentitiesOnly=yes)
fi

# --- Talking to the server --------------------------------------------------

# remote <command string>: run a command on the server.
# remote_tty: the same with a terminal, so that sudo can ask for a password.
# dest <path>: an rsync destination on the server.
if [ "$LOCAL" = 1 ]; then
    remote()     { bash -c "$1"; }
    remote_tty() { bash -c "$1"; }
    dest()       { printf '%s' "$1"; }
    RSYNC_SSH=()
else
    remote()     { "$SSH" "${SSH_OPTS[@]}" "$TARGET" "$1"; }
    remote_tty() { "$SSH" -t "${SSH_OPTS[@]}" "$TARGET" "$1"; }
    dest()       { printf '%s:%s' "$TARGET" "$1"; }
    RSYNC_SSH=(-e "$SSH ${SSH_OPTS[*]}")
fi

q() { printf '%q' "$1"; }  # quote one argument for a remote shell

# --- The release ------------------------------------------------------------

# read_release: check site/release.json and set release_args to either
# "none" (not published yet) or "<repository> <version> <file>". The three
# values go into the nginx configuration, so anything unexpected is refused
# before the site is built or anything is uploaded. remote-install.sh checks
# them again on the server.
read_release() {
    [ -f "$RELEASE_JSON" ] || die "no $RELEASE_JSON"
    local out
    out="$(python3 - "$RELEASE_JSON" <<'EOF'
import json, re, sys

def refuse(message):
    sys.stderr.write("deploy: %s: %s\n" % (sys.argv[1], message))
    sys.exit(1)

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        release = json.load(f)
except (OSError, ValueError) as error:
    refuse("cannot read it: %s" % error)
if not isinstance(release, dict):
    refuse("expected one JSON object")

def text(key):
    value = release.get(key)
    if not isinstance(value, str):
        refuse('"%s" must be a string' % key)
    return value

repository, version, file, date = text("repository"), text("version"), text("file"), text("date")
name = r"(?=[A-Za-z0-9_.-]*[A-Za-z0-9_-])[A-Za-z0-9_.-]+"   # not only dots
if not re.fullmatch(name + "/" + name, repository):
    refuse('"repository" is "%s"; expected owner/name with only letters, digits, ".", "_" and "-"' % repository)
if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version):
    refuse('"version" is "%s"; expected digits and dots, such as 1.0' % version)
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*\.dmg", file):
    refuse('"file" is "%s"; expected a plain .dmg file name' % file)
if date and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
    refuse('"date" is "%s"; expected YYYY-MM-DD, or empty while the release is not published' % date)
print("%s %s %s" % (repository, version, file) if date else "none")
EOF
)" || die "release.json refused; nothing was built or uploaded"
    # shellcheck disable=SC2206  # the values were checked to contain no spaces
    release_args=($out)
}

release_line() {  # the line download-target.conf holds for release_args
    printf 'return 302 https://github.com/%s/releases/download/v%s/%s;' \
        "${release_args[0]}" "${release_args[1]}" "${release_args[2]}"
}

# point_download: make /download match site/release.json. Asks the server
# for sudo only when something changes.
point_download() {
    local current wanted
    current="$(remote "if [ -f $(q "$TARGET_FILE") ]; then grep -v '^#' $(q "$TARGET_FILE") || true; else echo none; fi")"
    if [ "${release_args[0]}" = none ]; then
        wanted=none
    else
        wanted="$(release_line)"
    fi
    if [ "$current" = "$wanted" ]; then
        if [ "$wanted" = none ]; then
            say "/download: no release published yet, it answers 503 (unchanged)"
        else
            say "/download: already redirects to v${release_args[1]}/${release_args[2]} on GitHub (unchanged)"
        fi
        return
    fi
    if [ "$check" = 1 ]; then
        say "dry run: /download would change from \"$current\" to \"$wanted\""
        return
    fi
    if [ "$wanted" = none ]; then
        say "/download: release.json has no date; going back to the 503 page"
    else
        say "/download: redirecting to v${release_args[1]}/${release_args[2]} on GitHub"
    fi
    with_staging download-target "${release_args[@]}"
}

# --- The site ---------------------------------------------------------------

build_site() {
    if [ "${CULLA_DEPLOY_SKIP_BUILD:-0}" = 1 ]; then
        say "skipping the build (CULLA_DEPLOY_SKIP_BUILD=1)"
    else
        # In a podman container, exactly as `site/test.sh build`: the Mac's
        # own Node is never used.
        say "building the site in a container (site/test.sh build)"
        "$site/test.sh" build || die "the build failed; nothing was uploaded"
    fi

    local missing=0 f
    for f in en/index.html ru/index.html tk/index.html 404.html; do
        if [ ! -s "$OUTPUT/$f" ]; then
            printf 'deploy: missing from the build: %s\n' "$OUTPUT/$f" >&2
            missing=1
        fi
    done
    [ "$missing" = 0 ] || die "the build is incomplete; nothing was uploaded"
    if ! find "$OUTPUT" -name '*.gz' -print -quit | grep -q .; then
        say "warning: no pre-compressed .gz files in the build; nginx will send files uncompressed"
    fi
}

upload_site() {
    local flags=(-az --delay-updates --delete-after
                 --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r)
    if [ "$check" = 1 ]; then
        flags+=(--dry-run --itemize-changes)
        say "dry run: rsync shows what it would change"
    fi
    # --delay-updates puts every changed file in place together at the end;
    # --delete-after removes files no longer in the build only after that,
    # so a visitor never gets half of an old and half of a new version.
    rsync "${flags[@]}" ${RSYNC_SSH[@]+"${RSYNC_SSH[@]}"} "$OUTPUT/" "$(dest "$WWW_ROOT/")"
    [ "$check" = 1 ] || say "site uploaded to $WWW_ROOT"
}

# --- Files that need root ---------------------------------------------------

# passwordless: true when the server lets this user run the root-owned
# installer with sudo and no password (setup-host.sh CULLA_PASSWORDLESS=yes).
passwordless() {
    [ -n "$SUDO_N" ] || [ "$LOCAL" = 1 ] || return 1
    remote "$SUDO_N $(q "$INSTALLER") --version" >/dev/null 2>&1
}

# with_staging <mode> [args...]: run the installer on the server. For nginx,
# Culla's nginx files go to a temporary folder on the server first, which is
# removed again afterwards.
with_staging() {
    local what="$1" stage="" arg
    shift
    local args=("$@")
    local files=("$here/remote-install.sh")
    if [ "$what" = nginx ]; then
        files+=("$here/cullaapp.com.conf" "$here/cullaapp.com.bootstrap.conf"
                "$here/snippets" "$here/errors")
    fi
    local fast=0
    if passwordless; then
        fast=1
        say "using $INSTALLER on the server (sudo without a password)"
    fi
    if [ "$what" = nginx ] || [ "$fast" = 0 ]; then
        stage="$(remote 'mktemp -d "${TMPDIR:-/tmp}/cullaapp-deploy.XXXXXX"')"
        [ -n "$stage" ] || die "could not make a temporary folder on the server"
        # shellcheck disable=SC2064
        trap "remote $(q "rm -rf $(q "$stage")") || true" EXIT
        rsync -a --chmod=Du=rwx,Dgo=,Fu=rw,Fgo= ${RSYNC_SSH[@]+"${RSYNC_SSH[@]}"} "${files[@]}" "$(dest "$stage/")"
    fi
    [ "$what" = nginx ] && args=("$stage")
    local command
    if [ "$fast" = 1 ]; then
        command="$SUDO_N $(q "$INSTALLER") $(q "$what")"
        for arg in "${args[@]}"; do command+=" $(q "$arg")"; done
        remote "$command"
    else
        command="bash $(q "$stage/remote-install.sh") $(q "$what")"
        for arg in "${args[@]}"; do command+=" $(q "$arg")"; done
        remote_tty "$command"
    fi
}

# upload_setup: copy site/deploy/ (without its tests) to the server for
# setup-host.sh. Uses tar over ssh, since rsync may not be installed yet.
upload_setup() {
    if [ "$check" = 1 ]; then
        say "--check with --upload-setup: would copy site/deploy/ (without test/) to ~/$SETUP_DIR on the server"
        return
    fi
    local dir; dir="$(q "$SETUP_DIR")"
    COPYFILE_DISABLE=1 tar -C "$site" --exclude 'deploy/test' -cf - deploy \
        | remote "cd && rm -rf $dir && mkdir -m 700 $dir && tar -C $dir --strip-components=1 -xf - && chmod 755 $dir/setup-host.sh"
    say "copied site/deploy/ to ~/$SETUP_DIR on the server. There, run as yourself:"
    say "  cd ~/$SETUP_DIR && sudo CULLA_DEPLOY_USER=$CULLA_DEPLOY_USER ./setup-host.sh"
    say "(add CULLA_WITH_WWW=yes, CULLA_PASSWORDLESS=yes or CERTBOT_AGREE_TOS=yes as SETUP.md explains)"
}

# --- Main -------------------------------------------------------------------

case "$mode" in
    site)
        read_release
        build_site
        upload_site
        point_download
        ;;
    nginx)
        if [ "$check" = 1 ]; then
            say "--check with --nginx: would install these files with the installer on the server"
            ls -1 "$here/cullaapp.com.conf" "$here"/snippets/* "$here"/errors/*
            exit 0
        fi
        with_staging nginx
        ;;
    upload-setup)
        upload_setup
        ;;
esac

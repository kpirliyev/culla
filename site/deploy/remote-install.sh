#!/usr/bin/env bash
# The installer for Culla's nginx files. Runs ON THE SERVER as root (or as
# the deploy user, with sudo for each step). It installs only
#   /etc/nginx/conf.d/cullaapp.com.conf
#   /etc/nginx/cullaapp/**   (snippets, error pages, the /download target)
# checks the configuration with nginx -t and reloads nginx only when the
# check passes and something changed. If the check fails, the previous files
# are put back and nginx keeps running with its old configuration.
#
#   remote-install.sh nginx     <stage-dir>   the full configuration, its
#                                             snippets and error pages
#   remote-install.sh bootstrap <stage-dir>   the HTTP-only configuration, for
#                                             the first certificate
#   remote-install.sh download-target <repository> <version> <file>
#                               e.g. kpirliyev/culla 1.0 Culla-1.0.dmg:
#                               /download redirects to that asset of release
#                               v<version> on GitHub
#   remote-install.sh download-target none
#                               no release published: /download answers 503
#   remote-install.sh render <file>   print a configuration file as it would
#                               be installed (test copy only, needs no root)
#   remote-install.sh --version
#
# Who runs it:
#   setup-host.sh (as root, run by the owner) for bootstrap and nginx. It
#     also installs everything root later executes (count.py, the logrotate
#     rule, the crontab line); this installer never does.
#   deploy.sh over SSH for nginx and download-target. With
#     CULLA_PASSWORDLESS=yes, setup-host.sh installs a root-owned copy as
#     /usr/local/sbin/cullaapp-install, which the deploy user may run with
#     sudo and no password; otherwise deploy.sh runs this file and sudo asks
#     for the password for each step.
#
# What it checks before installing anything (the root-owned copy can be run
# by whoever holds the deploy user's SSH key, so these are its limits):
#   - It reads only cullaapp.com.conf, cullaapp.com.bootstrap.conf,
#     snippets/<name>.conf and errors/<name>.html|.css from the stage folder,
#     never through a symbolic link, only regular files of at most 1 MB, and
#     (root-owned copy) only files owned by the user who called sudo. It
#     copies them to a private folder first and works only on that copy.
#   - Every nginx file it installs is parsed; only a fixed list of
#     directives is accepted (ALLOWED below). access_log and error_log must
#     write under /data/cullaapp.com/log/, root and alias must point under
#     /data/cullaapp.com/www or /etc/nginx/cullaapp/, include may name only
#     Culla's snippets, the /download target and the host's acme snippet,
#     the certificate only /etc/letsencrypt/live/cullaapp.com/. No variables
#     and no ".." in those paths. server_name may name only cullaapp.com
#     and www.cullaapp.com, listen only 80, [::]:80, 443 ssl and
#     [::]:443 ssl (no default_server, no other port), so no other site's
#     name or traffic can be taken over. load_module, user, proxy_pass, lua,
#     perl, js_ and every other directive not on the list are refused.
#   - It refuses to write through a symbolic link at the destination.
#   - The /download target is built here from three checked values.
#
# Variants. cullaapp.com.conf and cullaapp.com.bootstrap.conf are one source
# each; lines are kept or dropped by two settings, yes or no:
#   www    default no    also serve www.cullaapp.com (redirect)
#   ipv6   default yes   listen on [::] as well
# They come from /etc/cullaapp/host.conf, written by setup-host.sh
# ("www=yes" and "ipv6=no" lines). A line ending in "#@www" is kept only
# with www, "#@!www" only without; the same for "#@ipv6" and "#@!ipv6".
# Lines between "#@begin www" and "#@end www" (or ipv6) are kept only with
# it. The markers are removed.
#
# The only commands run as root:
#   install ...    put files in place (with mode), make Culla's folders
#   cp -p ...      keep and restore backups
#   rm -f ...      remove a file on rollback that did not exist before, or
#                  download-target.conf for "none"
#   tee /etc/nginx/cullaapp/download-target.conf
#   nginx -t
#   systemctl reload nginx
#
# Backups go to /var/backups/cullaapp/<date-time>/. It never touches
# /data/cullaapp.com/.
#
# Test hooks, honoured only while CULLA_HOOKS below is "yes" (setup-host.sh
# sets it to "no" in the root-owned copy, which then ignores all of them):
# CULLA_ROOT prefixes every system path, CULLA_SUDO replaces "sudo" (empty =
# run directly), CULLA_NGINX and CULLA_SYSTEMCTL replace the two commands,
# CULLA_WITH_WWW and CULLA_WITH_IPV6 override host.conf.

set -euo pipefail
umask 022

CULLA_HOOKS=yes
VERSION=2

if [ "$CULLA_HOOKS" = yes ]; then
    ROOT="${CULLA_ROOT:-}"
    SUDO="${CULLA_SUDO-sudo}"
    NGINX="${CULLA_NGINX:-nginx}"
    SYSTEMCTL="${CULLA_SYSTEMCTL:-systemctl}"
    OWNER_UID=""          # files are not checked for their owner
    PYTHON=python3
else
    # The root-owned copy run through sudo: nothing from the caller counts.
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    unset TMPDIR PYTHONPATH PYTHONHOME
    ROOT=""
    SUDO=""
    NGINX=nginx
    SYSTEMCTL=systemctl
    PYTHON=/usr/bin/python3
    if [ "${1:-}" != --version ] && [ "$(id -u)" != 0 ]; then
        echo "cullaapp-install: run it with sudo" >&2; exit 1
    fi
    # sudo sets SUDO_UID itself; the caller cannot choose it.
    OWNER_UID="${SUDO_UID:-0}"
    [[ "$OWNER_UID" =~ ^[0-9]+$ ]] || { echo "cullaapp-install: bad SUDO_UID" >&2; exit 1; }
fi

CONF="$ROOT/etc/nginx/conf.d/cullaapp.com.conf"
OWN="$ROOT/etc/nginx/cullaapp"
TARGET="$OWN/download-target.conf"
SETTINGS="$ROOT/etc/cullaapp/host.conf"
BACKUP="$ROOT/var/backups/cullaapp/$(date +%Y%m%d-%H%M%S)"

say() { printf 'server: %s\n' "$*"; }
as_root() { if [ -n "$SUDO" ]; then "$SUDO" "$@"; else "$@"; fi; }

# --- Settings ---------------------------------------------------------------

setting() {  # setting <name> <default>: from host.conf, strictly yes or no
    local value=""
    if [ -f "$SETTINGS" ]; then
        value="$(grep -E "^$1=(yes|no)\$" "$SETTINGS" | tail -1 | cut -d= -f2)" || true
    fi
    printf '%s' "${value:-$2}"
}
WITH_WWW="$(setting www no)"
WITH_IPV6="$(setting ipv6 yes)"
if [ "$CULLA_HOOKS" = yes ]; then
    WITH_WWW="${CULLA_WITH_WWW:-$WITH_WWW}"
    WITH_IPV6="${CULLA_WITH_IPV6:-$WITH_IPV6}"
fi

# --- The checker --------------------------------------------------------------

# check.py stage <stage> <private-dir> <owner-uid or "">
#     copy the files the installer may read from the stage folder
# check.py conf [--top] <file>...
#     parse nginx files and refuse anything outside the allowed directives
read -r -d '' CHECKER <<'PY' || true
import os, re, stat, sys

def fail(message):
    sys.stderr.write("server: refused: %s\n" % message)
    sys.exit(1)

NAME = r"[a-z0-9][a-z0-9._-]*"
FILES = [("", re.compile(r"cullaapp\.com(\.bootstrap)?\.conf")),
         ("snippets", re.compile(NAME + r"\.conf")),
         ("errors", re.compile(NAME + r"\.(html|css)"))]
LIMIT = 1024 * 1024

def open_dir(path, parent=None):
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    try:
        return os.open(path, flags, dir_fd=parent) if parent is not None else os.open(path, flags)
    except OSError as error:
        fail("%s is not a folder (or is a symbolic link): %s" % (path, error.strerror))

def check_owner(st, what, uid):
    if uid is not None and st.st_uid != uid:
        fail("%s belongs to another user" % what)

def stage(source, target, uid):
    if os.path.islink(source):
        fail("the stage folder %s is a symbolic link" % source)
    top = open_dir(source)
    check_owner(os.fstat(top), source, uid)
    copied = 0
    for sub, pattern in FILES:
        if sub:
            try:
                st = os.stat(sub, dir_fd=top, follow_symlinks=False)
            except FileNotFoundError:
                continue
            if not stat.S_ISDIR(st.st_mode):
                fail("%s/%s is not a folder (or is a symbolic link)" % (source, sub))
            fd = open_dir(sub, top)
            check_owner(os.fstat(fd), "%s/%s" % (source, sub), uid)
            os.makedirs(os.path.join(target, sub), exist_ok=True)
        else:
            fd = top
        for name in sorted(os.listdir(fd)):
            if not pattern.fullmatch(name):
                if sub:
                    fail("unexpected file %s/%s/%s" % (source, sub, name))
                continue
            what = os.path.join(source, sub, name)
            try:
                f = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            except OSError as error:
                fail("cannot open %s without following a link: %s" % (what, error.strerror))
            st = os.fstat(f)
            if not stat.S_ISREG(st.st_mode):
                fail("%s is not a regular file" % what)
            check_owner(st, what, uid)
            if st.st_size > LIMIT:
                fail("%s is larger than 1 MB" % what)
            data = b""
            while True:
                chunk = os.read(f, 65536)
                if not chunk:
                    break
                data += chunk
                if len(data) > LIMIT:
                    fail("%s is larger than 1 MB" % what)
            os.close(f)
            with open(os.path.join(target, sub, name), "wb") as out:
                out.write(data)
            copied += 1
        if sub:
            os.close(fd)
    os.close(top)
    if not copied:
        fail("nothing to install in %s" % source)

# --- nginx files ---------------------------------------------------------------

ALLOWED = {
    "server", "listen", "server_name", "access_log", "error_log", "server_tokens",
    "include", "location", "return", "ssl_certificate", "ssl_certificate_key",
    "root", "index", "log_not_found", "charset", "absolute_redirect", "gzip",
    "gzip_static", "gzip_vary", "add_header", "error_page", "internal", "alias",
    "default_type", "http2", "log_format", "map", "try_files", "types", "expires",
    "etag", "if_modified_since",
}
TOP_LEVEL = {"map", "log_format", "server"}       # in conf.d, i.e. the http block
BLOCKS = {"server", "location", "map", "types"}
TABLES = {"map", "types"}                         # their lines are entries, not directives
INCLUDES = re.compile(r"/etc/nginx/snippets/acme-challenge\.conf|/etc/nginx/cullaapp/download-target\.con\[f\]"
                      r"|/etc/nginx/cullaapp/snippets/" + NAME + r"\.conf")
NAMES = {"cullaapp.com", "www.cullaapp.com"}
LISTENS = {("80",), ("[::]:80",), ("443", "ssl"), ("[::]:443", "ssl")}
CERTS = {"ssl_certificate": "/etc/letsencrypt/live/cullaapp.com/fullchain.pem",
         "ssl_certificate_key": "/etc/letsencrypt/live/cullaapp.com/privkey.pem"}

def tokens(text, where):
    """Yield (kind, value, line): kind is "word", ";", "{" or "}"."""
    i, n, line = 0, len(text), 1
    while i < n:
        ch = text[i]
        if ch == "\n":
            line += 1; i += 1
        elif ch in " \t\r":
            i += 1
        elif ch == "#":
            while i < n and text[i] != "\n":
                i += 1
        elif ch in ";{}":
            yield ch, ch, line; i += 1
        elif ch in "\"'":
            j, value = i + 1, []
            while j < n and text[j] != ch:
                if text[j] == "\\" and j + 1 < n:
                    j += 1
                if text[j] == "\n":
                    line += 1
                value.append(text[j]); j += 1
            if j >= n:
                fail("%s: unclosed quote" % where)
            yield "word", "".join(value), line
            i = j + 1
        else:
            j = i
            while j < n and text[j] not in " \t\r\n;{}\"'":
                if text[j] == "$" and j + 1 < n and text[j + 1] == "{":
                    close = text.find("}", j)
                    if close < 0:
                        fail("%s: unclosed ${" % where)
                    j = close
                j += 1
            yield "word", text[i:j], line
            i = j

def statements(text, where):
    """Yield (name, args, opens_block, line, parents)."""
    stack, words = [], []
    for kind, value, line in tokens(text, where):
        if kind == "word":
            words.append((value, line))
        elif kind in ";{":
            if not words:
                fail("%s:%d: empty statement" % (where, line))
            name, args = words[0][0], [w for w, _ in words[1:]]
            yield name, args, kind == "{", words[0][1], list(stack)
            if kind == "{":
                stack.append(name)
            words = []
        else:
            if words or not stack:
                fail("%s:%d: unbalanced }" % (where, line))
            stack.pop()
    if words or stack:
        fail("%s: unfinished block or statement" % where)

def clean_path(path):
    return "$" not in path and ".." not in path.split("/") and os.path.normpath(path) == path.rstrip("/")

def under(path, *bases):
    return clean_path(path) and any(path == b.rstrip("/") or path.startswith(b) for b in bases)

def conf(paths, top):
    for path in paths:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        for name, args, block, line, parents in statements(text, path):
            at = "%s:%d: %s" % (os.path.basename(path), line, name)
            if parents and parents[-1] in TABLES:
                if name == "include" or block:
                    fail("%s is not allowed inside %s" % (at, parents[-1]))
                continue
            if name not in ALLOWED:
                fail("%s is not an allowed directive" % at)
            if block != (name in BLOCKS):
                fail("%s %s" % (at, "must not open a block" if block else "must open a block"))
            if top and not parents and name not in TOP_LEVEL:
                fail("%s is not allowed at http level" % at)
            if parents and name in TOP_LEVEL - {"server"}:
                fail("%s is allowed only at http level" % at)
            if name == "server" and parents:
                fail("%s inside another block" % at)
            if name in ("access_log", "error_log"):
                if not args or not (args[0] == "off" and name == "access_log"
                                    or under(args[0], "/data/cullaapp.com/log/")):
                    fail("%s must write under /data/cullaapp.com/log/" % at)
            elif name in ("root", "alias"):
                if len(args) != 1 or not under(args[0], "/data/cullaapp.com/www/", "/etc/nginx/cullaapp/"):
                    fail("%s must point under /data/cullaapp.com/www or /etc/nginx/cullaapp/" % at)
            elif name == "include":
                if len(args) != 1 or not INCLUDES.fullmatch(args[0]):
                    fail("%s %s is not one of Culla's snippets or the host's acme snippet" % (at, " ".join(args)))
            elif name in CERTS:
                if args != [CERTS[name]]:
                    fail("%s must be %s" % (at, CERTS[name]))
            elif name == "server_name":
                if not args or not set(args) <= NAMES:
                    fail("%s may name only cullaapp.com and www.cullaapp.com" % at)
            elif name == "listen":
                if tuple(args) not in LISTENS:
                    fail("%s %s is not one of: 80, [::]:80, 443 ssl, [::]:443 ssl" % (at, " ".join(args)))
            elif name == "log_format":
                if not args or not re.fullmatch(r"cullaapp_\w+", args[0]):
                    fail("%s must be named cullaapp_..." % at)

if sys.argv[1] == "stage":
    stage(sys.argv[2], sys.argv[3], int(sys.argv[4]) if sys.argv[4] else None)
elif sys.argv[1] == "conf":
    top = sys.argv[2] == "--top"
    conf(sys.argv[3:] if top else sys.argv[2:], top)
else:
    fail("unknown check")
PY

check() { "$PYTHON" -I -c "$CHECKER" "$@"; }

# --- Installing with backup and rollback ------------------------------------

# Files this run replaces; each is backed up first and restored on failure.
touched=()
changed=0

no_link() {  # refuse to write through a symbolic link
    local path
    for path in "$@"; do
        if [ -L "$path" ]; then say "refused: $path is a symbolic link"; exit 1; fi
    done
}

backup() {
    local file="$1"
    no_link "$file"
    touched+=("$file")
    if [ -e "$file" ]; then
        as_root install -d -m 700 "$BACKUP$(dirname "$file")"
        as_root cp -p "$file" "$BACKUP$file"
    fi
}

restore() {
    local file
    say "restoring the previous files"
    for file in "${touched[@]}"; do
        if [ -e "$BACKUP$file" ]; then
            as_root cp -p "$BACKUP$file" "$file"
        else
            as_root rm -f "$file"
        fi
    done
}

put() {  # put <mode> <source> <destination-file>; skips an identical file
    no_link "$3"
    if [ -f "$3" ] && cmp -s "$2" "$3"; then
        return 0
    fi
    backup "$3"
    as_root install -m "$1" "$2" "$3"
    changed=1
}

render() {  # render <file>: print it with the variant lines chosen
    case "$WITH_WWW/$WITH_IPV6" in
        yes/yes|yes/no|no/yes|no/no) ;;
        *) say "www and ipv6 must be yes or no"; return 1 ;;
    esac
    printf '# Installed from %s with www=%s, ipv6=%s.\n' "$(basename "$1")" "$WITH_WWW" "$WITH_IPV6"
    awk -v www="$WITH_WWW" -v ipv6="$WITH_IPV6" '
        function on(name) { return (name == "www" && www == "yes") || (name == "ipv6" && ipv6 == "yes") }
        /^[ \t]*#@begin (www|ipv6)[ \t]*$/ { split($0, a, " "); depth++; keep[depth] = on(a[2]); next }
        /^[ \t]*#@end (www|ipv6)[ \t]*$/   { depth--; next }
        {
            for (i = 1; i <= depth; i++) if (!keep[i]) next
            if (match($0, /[ \t]*#@!?(www|ipv6)[ \t]*$/)) {
                tag = substr($0, RSTART, RLENGTH); gsub(/[ \t#@]/, "", tag)
                want = 1
                if (substr(tag, 1, 1) == "!") { want = 0; tag = substr(tag, 2) }
                if (on(tag) != want) next
                $0 = substr($0, 1, RSTART - 1)
            }
            print
        }
        END { if (depth != 0) { print "unbalanced #@begin/#@end" > "/dev/stderr"; exit 1 } }
    ' "$1"
}

check_and_reload() {
    if [ "$changed" = 0 ]; then
        say "nothing changed; nginx not reloaded"
        return 0
    fi
    if as_root "$NGINX" -t; then
        as_root "$SYSTEMCTL" reload nginx
        say "nginx configuration test passed; nginx reloaded"
        [ -d "$BACKUP" ] && say "previous files kept in $BACKUP"
        return 0
    fi
    say "nginx -t FAILED; nothing was reloaded"
    restore
    if as_root "$NGINX" -t >/dev/null 2>&1; then
        say "previous configuration restored and passes nginx -t"
    else
        say "WARNING: the restored configuration does not pass nginx -t either"
    fi
    return 1
}

# install_stage <conf name in stage> [with snippets and errors]
install_stage() {
    local stage="$1" name="$2" full="$3" work f
    [ -n "$stage" ] || { say "no stage folder given"; exit 2; }
    work="$(mktemp -d "${TMPDIR:-/tmp}/cullaapp-install.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" EXIT
    mkdir "$work/copy"
    check stage "$stage" "$work/copy" "$OWNER_UID"
    [ -f "$work/copy/$name" ] || { say "refused: no $name in $stage"; exit 1; }
    render "$work/copy/$name" > "$work/$name"
    chmod 644 "$work/$name"
    local snippets=()
    if [ "$full" = yes ] && [ -d "$work/copy/snippets" ]; then
        for f in "$work/copy/snippets"/*.conf; do [ -e "$f" ] && snippets+=("$f"); done
    fi
    check conf --top "$work/$name"
    [ ${#snippets[@]} = 0 ] || check conf "${snippets[@]}"

    no_link "$(dirname "$CONF")" "$OWN" "$OWN/snippets" "$OWN/errors"
    as_root install -d -m 755 "$(dirname "$CONF")"
    put 644 "$work/$name" "$CONF"
    if [ "$full" = yes ]; then
        as_root install -d -m 755 "$OWN" "$OWN/snippets" "$OWN/errors"
        for f in ${snippets[@]+"${snippets[@]}"}; do put 644 "$f" "$OWN/snippets/$(basename "$f")"; done
        if [ -d "$work/copy/errors" ]; then
            for f in "$work/copy/errors"/*; do [ -e "$f" ] && put 644 "$f" "$OWN/errors/$(basename "$f")"; done
        fi
    fi
    check_and_reload
}

mode="${1:-}"
arg="${2:-}"

case "$mode" in
    --version)
        echo "cullaapp-install $VERSION"
        ;;
    nginx)
        install_stage "$arg" cullaapp.com.conf yes
        ;;
    bootstrap)
        install_stage "$arg" cullaapp.com.bootstrap.conf no
        ;;
    download-target)
        no_link "$OWN" "$TARGET"
        if [ "$arg" = none ] && [ $# -eq 2 ]; then
            if [ ! -e "$TARGET" ]; then
                say "no release published; /download already answers 503"
                exit 0
            fi
            backup "$TARGET"
            as_root rm -f "$TARGET"
            changed=1
            check_and_reload
            exit
        fi
        repository="$arg"
        version="${3:-}"
        file="${4:-}"
        name_re='[A-Za-z0-9_.-]*[A-Za-z0-9_-][A-Za-z0-9_.-]*'   # not only dots
        if [ $# -ne 4 ] \
           || ! [[ "$repository" =~ ^${name_re}/${name_re}$ ]] \
           || ! [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] \
           || ! [[ "$file" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*\.dmg$ ]]; then
            say "refusing download target '$repository' '$version' '$file'"
            say "(expected owner/name, a version of digits and dots, and a plain .dmg name)"
            exit 1
        fi
        line="return 302 https://github.com/$repository/releases/download/v$version/$file;"
        if [ -e "$TARGET" ] && [ "$(grep -v '^#' "$TARGET")" = "$line" ]; then
            say "/download already points at v$version/$file"
            exit 0
        fi
        as_root install -d -m 755 "$OWN"
        backup "$TARGET"
        printf '# Written by deploy.sh from site/release.json. /download redirects here.\n%s\n' "$line" \
            | as_root tee "$TARGET" >/dev/null
        changed=1
        check_and_reload
        ;;
    render)
        if [ "$CULLA_HOOKS" != yes ]; then say "render is for the test copy only"; exit 2; fi
        [ -f "$arg" ] || { say "no such file: $arg"; exit 1; }
        render "$arg"
        ;;
    *)
        echo "usage: $0 nginx|bootstrap <stage-dir> | download-target <repository> <version> <file> | download-target none | render <file> | --version" >&2
        exit 2
        ;;
esac

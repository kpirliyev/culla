#!/usr/bin/env bash
# Local tests of deploy.sh and remote-install.sh. No server, no network:
# CULLA_DEPLOY_LOCAL=1 makes a temporary folder stand in for the server, and
# fake nginx/systemctl commands stand in for the real ones.
#
#   site/test.sh deploy
#
# It runs in the test container (site/containers/test.Containerfile) as an
# ordinary user with no network; run on the Mac, it hands over to
# site/test.sh deploy.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deploy="$(dirname "$here")"
if [ "${CULLA_IN_CONTAINER:-}" != 1 ]; then
    exec "$(dirname "$deploy")/test.sh" deploy
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/culla-deploy-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

bash -n "$deploy/deploy.sh" && ok "bash -n deploy.sh"
bash -n "$deploy/remote-install.sh" && ok "bash -n remote-install.sh"

# --- A fake build and a fake server ------------------------------------------

out="$work/build"
www="$work/server/data/cullaapp.com/www"
logdir="$work/server/data/cullaapp.com/log"
mkdir -p "$out"/{en,ru,tk} "$out/_nuxt" "$www/_nuxt" "$logdir"
for l in en ru tk; do
    echo "<html>$l</html>" > "$out/$l/index.html"
done
echo "<html>404</html>" > "$out/404.html"
echo "new()" > "$out/_nuxt/app.NEW.js"
gzip -k "$out/_nuxt/app.NEW.js"
# What an earlier deploy left on the server:
echo "old()" > "$www/_nuxt/app.OLD.js"
echo "stale" > "$www/stale.html"
echo "access" > "$logdir/access.log"
log_before="$(ls -lR "$logdir" | shasum)"

export CULLA_DEPLOY_LOCAL=1 CULLA_DEPLOY_SKIP_BUILD=1
export CULLA_DEPLOY_OUTPUT="$out" CULLA_DEPLOY_WWW_ROOT="$www"
export CULLA_DEPLOY_HOST=stand-in-server CULLA_DEPLOY_USER=deploy
# No password-free installer on this "server" until a test sets one up.
export CULLA_DEPLOY_SUDO="" CULLA_DEPLOY_INSTALLER="$work/no-installer"

# site/release.json stand-in: not published yet.
release="$work/release.json"
export CULLA_DEPLOY_RELEASE_JSON="$release"
unpublished() {
    printf '{ "repository": "kpirliyev/culla", "version": "1.0", "file": "Culla-1.0.dmg", "size": 0, "sha256": "", "date": "" }\n' > "$release"
}
published() {  # published [repository] [version] [file]
    printf '{ "repository": "%s", "version": "%s", "file": "%s", "size": 25000000, "sha256": "%s", "date": "2026-11-20" }\n' \
        "${1-kpirliyev/culla}" "${2-1.0}" "${3-Culla-1.0.dmg}" "$(printf 'a%.0s' $(seq 64))" > "$release"
}
unpublished

# --- Fake root commands for remote-install.sh --------------------------------

root="$work/server"
bin="$work/bin"
mkdir -p "$bin" "$root/etc/nginx/conf.d"
cat > "$bin/nginx" <<'EOF'
#!/usr/bin/env bash
# Fake "nginx -t": fails when the installed config contains BROKEN.
if grep -rq BROKEN "$CULLA_ROOT/etc/nginx/conf.d" "$CULLA_ROOT/etc/nginx/cullaapp" 2>/dev/null; then
    echo "nginx: [emerg] fake failure" >&2; exit 1
fi
echo "nginx: configuration file test is successful"
EOF
cat > "$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CULLA_ROOT/systemctl.calls"
EOF
chmod +x "$bin/nginx" "$bin/systemctl"
export CULLA_ROOT="$root" CULLA_SUDO="" CULLA_NGINX="$bin/nginx" CULLA_SYSTEMCTL="$bin/systemctl"


# --- Refuses without host and user -------------------------------------------

if env -u CULLA_DEPLOY_HOST "$deploy/deploy.sh" >/dev/null 2>&1; then
    fail "runs without CULLA_DEPLOY_HOST"
fi
if env -u CULLA_DEPLOY_USER "$deploy/deploy.sh" >/dev/null 2>&1; then
    fail "runs without CULLA_DEPLOY_USER"
fi
ok "refuses to run without CULLA_DEPLOY_HOST / CULLA_DEPLOY_USER"

# --- --check changes nothing -------------------------------------------------

snapshot() { (cd "$www" && find . -type f | sort | xargs shasum) ; }
before="$(snapshot)"
check_out="$("$deploy/deploy.sh" --check)"
[ "$(snapshot)" = "$before" ] || fail "--check changed the server"
# rsync 3 itemizes it as "*deleting   stale.html", older ones as "deleting stale.html".
grep -Eq 'deleting +stale\.html$' <<<"$check_out" || fail "--check does not show stale.html going: $check_out"
ok "--check shows the changes (stale.html would go) and changes nothing"

# --- A real deploy -----------------------------------------------------------

"$deploy/deploy.sh" >/dev/null
[ -f "$www/en/index.html" ] && [ -f "$www/tk/index.html" ] || fail "pages not uploaded"
[ -f "$www/_nuxt/app.NEW.js.gz" ] || fail ".gz not uploaded"
[ ! -e "$www/stale.html" ] && [ ! -e "$www/_nuxt/app.OLD.js" ] || fail "stale files survived"
ok "deploy uploads the build and removes stale files"

# A folder left from the time disk images were served from here goes too.
mkdir -p "$www/downloads" && echo old > "$www/downloads/Culla-0.9.dmg"
"$deploy/deploy.sh" >/dev/null
[ ! -e "$www/downloads" ] || fail "an old downloads/ folder survived a deploy"
ok "a deploy removes an old downloads/ folder"

# --- Sanity check of the build -----------------------------------------------

mv "$out/ru/index.html" "$work/ru-index.html"
if "$deploy/deploy.sh" >/dev/null 2>&1; then fail "deployed a build without ru/index.html"; fi
mv "$work/ru-index.html" "$out/ru/index.html"
ok "refuses an incomplete build"

# --- /download from release.json -------------------------------------------

conf="$root/etc/nginx/cullaapp/download-target.conf"
url="https://github.com/kpirliyev/culla/releases/download/v1.0/Culla-1.0.dmg"
reloads() { if [ -f "$root/systemctl.calls" ]; then grep -c 'reload nginx' "$root/systemctl.calls" || true; else echo 0; fi; }

# Not published: no include, so nginx answers 503; nothing needs root.
[ ! -e "$conf" ] || fail "download-target.conf written for an unpublished release"
[ "$(reloads)" = 0 ] || fail "nginx reloaded for an unpublished release"
msg="$("$deploy/deploy.sh")"
grep -q "no release published yet" <<<"$msg" || fail "unclear message: $msg"
ok "release.json without a date: no /download include (503 page), no sudo, no reload"

# Published: the include is written and nginx reloaded.
published
before="$(snapshot)"
msg="$("$deploy/deploy.sh" --check)"
grep -q "would change" <<<"$msg" || fail "--check does not show the /download change: $msg"
[ ! -e "$conf" ] && [ "$(reloads)" = 0 ] && [ "$(snapshot)" = "$before" ] || fail "--check changed something"
ok "--check shows the /download change and writes nothing"

"$deploy/deploy.sh" >/dev/null
[ "$(grep -v '^#' "$conf")" = "return 302 $url;" ] || fail "download-target.conf: $(cat "$conf")"
[ "$(reloads)" = 1 ] || fail "nginx not reloaded once"
ok "release.json with a date: /download redirects to $url, nginx reloaded"

"$deploy/deploy.sh" >/dev/null
[ "$(reloads)" = 1 ] || fail "an unchanged release reloaded nginx again"
ok "a second deploy with the same release changes nothing on the server"

published kpirliyev/culla 1.1 Culla-1.1.dmg
"$deploy/deploy.sh" >/dev/null
grep -qx 'return 302 https://github.com/kpirliyev/culla/releases/download/v1.1/Culla-1.1.dmg;' "$conf" \
    || fail "new release not written: $(cat "$conf")"
[ "$(reloads)" = 2 ] || fail "nginx not reloaded for the new release"
ok "a new version in release.json moves /download to it"

# Values that would end up in nginx's configuration are refused.
good_conf="$(cat "$conf")"
refused() {  # refused <what> <repository> <version> <file>
    published "$2" "$3" "$4"
    local snap; snap="$(snapshot)"
    if msg="$("$deploy/deploy.sh" 2>&1)"; then fail "accepted $1"; fi
    grep -q "release.json refused" <<<"$msg" || fail "$1: unclear message: $msg"
    [ "$(cat "$conf")" = "$good_conf" ] || fail "$1: download-target.conf changed"
    [ "$(snapshot)" = "$snap" ] || fail "$1: the site was uploaded"
}
refused "a repository with a space"   "kpirliyev/culla x" 1.0 Culla-1.0.dmg
refused "a repository with ;"         'kpirliyev/culla;return' 1.0 Culla-1.0.dmg
refused "a repository without owner"  culla 1.0 Culla-1.0.dmg
refused "a repository with a path"    kpirliyev/culla/x 1.0 Culla-1.0.dmg
refused "a repository of dots"        kpirliyev/.. 1.0 Culla-1.0.dmg
refused "a version with letters"      kpirliyev/culla 1.0b Culla-1.0.dmg
refused "a version with ;"            kpirliyev/culla '1.0;' Culla-1.0.dmg
refused "an empty version"            kpirliyev/culla "" Culla-1.0.dmg
refused "a file name with a path"     kpirliyev/culla 1.0 ../Culla-1.0.dmg
refused "a file that is not a .dmg"   kpirliyev/culla 1.0 Culla-1.0.zip
refused "a file name with a space"    kpirliyev/culla 1.0 'Culla 1.0.dmg'
printf '{ "repository": "kpirliyev/culla", "version": "1.0", "file": "Culla-1.0.dmg", "date": "soon" }\n' > "$release"
if "$deploy/deploy.sh" >/dev/null 2>&1; then fail "accepted a date that is not YYYY-MM-DD"; fi
printf '{ "version": "1.0", "file": "Culla-1.0.dmg", "date": "" }\n' > "$release"
if "$deploy/deploy.sh" >/dev/null 2>&1; then fail "accepted a release.json without repository"; fi
printf 'not json\n' > "$release"
if "$deploy/deploy.sh" >/dev/null 2>&1; then fail "accepted a release.json that is not JSON"; fi
[ "$(cat "$conf")" = "$good_conf" ] || fail "download-target.conf changed"
ok "bad repository, version, file, date or JSON in release.json: refused before anything is uploaded"

# remote-install.sh checks the values again on its own.
for args in "kpirliyev/culla 1.0;x Culla-1.0.dmg" "a/b 1.0 x.dmg;" "a 1.0 x.dmg" "a/b 1.0" "nonsense"; do
    # shellcheck disable=SC2086
    if bash "$deploy/remote-install.sh" download-target $args >/dev/null 2>&1; then
        fail "remote-install.sh accepted: $args"
    fi
done
if bash "$deploy/remote-install.sh" download-target 'a/b' '1.0' $'x.dmg\nreturn 200' >/dev/null 2>&1; then
    fail "remote-install.sh accepted a file name with a newline"
fi
[ "$(cat "$conf")" = "$good_conf" ] || fail "remote-install.sh changed download-target.conf"
ok "remote-install.sh refuses bad download targets by itself"

# A redirect that fails nginx -t is rolled back.
echo "BROKEN;" > "$root/etc/nginx/cullaapp/BROKEN.conf"
published kpirliyev/culla 2.0 Culla-2.0.dmg
if msg="$("$deploy/deploy.sh" 2>&1)"; then fail "a failing nginx -t was not reported"; fi
grep -q "nginx -t FAILED" <<<"$msg" || fail "did not fail at nginx -t: $msg"
[ "$(cat "$conf")" = "$good_conf" ] || fail "download-target.conf not restored"
[ "$(reloads)" = 2 ] || fail "nginx reloaded after a failed test"
rm "$root/etc/nginx/cullaapp/BROKEN.conf"
ok "a new /download target that fails nginx -t is rolled back"

# Back to unpublished: the include goes and the 503 page answers again.
unpublished
"$deploy/deploy.sh" >/dev/null
[ ! -e "$conf" ] || fail "download-target.conf left behind for an unpublished release"
[ "$(reloads)" = 3 ] || fail "nginx not reloaded after removing the redirect"
ok "release.json without a date again: the include is removed and nginx reloaded"

published
"$deploy/deploy.sh" >/dev/null
[ "$(grep -v '^#' "$conf")" = "return 302 $url;" ] || fail "redirect not written again"

# --- deploy.sh --nginx (asks for a password: the fallback) --------------------

render() {  # render <www> <ipv6> <file>: what the installer would install
    CULLA_WITH_WWW="$1" CULLA_WITH_IPV6="$2" bash "$deploy/remote-install.sh" render "$3"
}
rm -f "$root/systemctl.calls"
"$deploy/deploy.sh" --nginx >/dev/null
[ "$(cat "$root/etc/nginx/conf.d/cullaapp.com.conf")" = "$(render no yes "$deploy/cullaapp.com.conf")" ] \
    || fail "config not installed as rendered (www=no, ipv6=yes without host.conf)"
for f in snippets/security-headers.conf snippets/tls.conf snippets/download-default.conf \
         errors/50x.html errors/download-503.html errors/errors.css; do
    cmp -s "$deploy/$f" "$root/etc/nginx/cullaapp/$f" || fail "$f not installed"
done
[ ! -e "$root/etc/logrotate.d" ] && [ ! -e "$root/usr/local/lib/cullaapp" ] \
    || fail "--nginx installed something root executes"
[ -f "$conf" ] || fail "--nginx removed the /download include"
[ "$(reloads)" = 1 ] || fail "nginx not reloaded once"
"$deploy/deploy.sh" --nginx >/dev/null
[ "$(reloads)" = 1 ] || fail "an unchanged --nginx reloaded nginx"
ok "--nginx installs only Culla's nginx files (rendered config, snippets, error pages), keeps the /download include; unchanged files: no reload"

# host.conf chooses the variant.
mkdir -p "$root/etc/cullaapp"
printf 'www=yes\nipv6=no\n' > "$root/etc/cullaapp/host.conf"
"$deploy/deploy.sh" --nginx >/dev/null
[ "$(cat "$root/etc/nginx/conf.d/cullaapp.com.conf")" = "$(env -u CULLA_WITH_WWW bash -c "cd / && CULLA_WITH_WWW=yes CULLA_WITH_IPV6=no bash '$deploy/remote-install.sh' render '$deploy/cullaapp.com.conf'")" ] \
    || fail "host.conf www=yes ipv6=no not followed"
grep -q 'server_name www.cullaapp.com;' "$root/etc/nginx/conf.d/cullaapp.com.conf" || fail "no www server"
grep -q 'listen \[::\]' "$root/etc/nginx/conf.d/cullaapp.com.conf" && fail "ipv6 lines kept with ipv6=no"
rm "$root/etc/cullaapp/host.conf"
"$deploy/deploy.sh" --nginx >/dev/null
ok "the installer follows /etc/cullaapp/host.conf (www and ipv6)"

# A configuration that fails nginx -t is rolled back and nginx is not reloaded.
good="$(shasum < "$root/etc/nginx/conf.d/cullaapp.com.conf")"
cp -R "$deploy" "$work/deploy-broken"
echo "# BROKEN" >> "$work/deploy-broken/cullaapp.com.conf"
echo "# BROKEN" >> "$work/deploy-broken/snippets/tls.conf"
echo "# new snippet" > "$work/deploy-broken/snippets/new.conf"
rm -f "$root/systemctl.calls"
if "$work/deploy-broken/deploy.sh" --nginx >/dev/null 2>&1; then fail "a failing nginx -t was not reported"; fi
[ "$(shasum < "$root/etc/nginx/conf.d/cullaapp.com.conf")" = "$good" ] || fail "config not restored"
cmp -s "$deploy/snippets/tls.conf" "$root/etc/nginx/cullaapp/snippets/tls.conf" || fail "snippet not restored"
[ ! -e "$root/etc/nginx/cullaapp/snippets/new.conf" ] || fail "new file not removed on rollback"
[ ! -e "$root/systemctl.calls" ] || fail "nginx was reloaded after a failed test"
ok "--nginx with a failing nginx -t restores every file and does not reload"

# --- The installer's checks --------------------------------------------------

nginx_tree() { (cd "$root/etc/nginx" && find . | sort && find . -type f | sort | xargs shasum); }
new_stage() {  # new_stage: a fresh copy of Culla's nginx files; prints its path
    local s; s="$(mktemp -d "$work/stage.XXXXXX")"
    cp -R "$deploy/cullaapp.com.conf" "$deploy/cullaapp.com.bootstrap.conf" "$deploy/snippets" "$deploy/errors" "$s/"
    printf '%s' "$s"
}
refuses() {  # refuses <what> <stage> [mode]: the installer refuses and changes nothing
    local before msg
    before="$(nginx_tree)"
    if msg="$(bash "$deploy/remote-install.sh" "${3:-nginx}" "$2" 2>&1)"; then fail "installer accepted $1"; fi
    grep -q "refused" <<<"$msg" || fail "$1: unclear message: $msg"
    [ "$(nginx_tree)" = "$before" ] || fail "$1: files changed"
}
with_line() {  # with_line <what> <file in stage> <after this line> <new line> [mode]
    local s; s="$(new_stage)"
    python3 - "$s/$2" "$3" "$4" <<'EOF'
import sys
path, after, new = sys.argv[1:]
text = open(path).read()
assert after in text, after
open(path, "w").write(text.replace(after, after + "\n" + new, 1))
EOF
    refuses "$1" "$s" "${5:-nginx}"
}
https="    index index.html;"
with_line "access_log outside the log folder"   cullaapp.com.conf "$https" "    access_log /tmp/x.log cullaapp_access;"
with_line "access_log to syslog"                cullaapp.com.conf "$https" "    access_log syslog:server=127.0.0.1 cullaapp_access;"
with_line "error_log outside the log folder"    cullaapp.com.conf "$https" "    error_log /var/log/x.log;"
with_line "a log path with .."                  cullaapp.com.conf "$https" "    access_log /data/cullaapp.com/log/../../../tmp/x cullaapp_access;"
with_line "root /"                              cullaapp.com.conf "$https" "    root /;"
with_line "root with .."                        cullaapp.com.conf "$https" "    root /data/cullaapp.com/www/../../../etc;"
with_line "root with a variable"                cullaapp.com.conf "$https" "    root \$document_root;"
with_line "alias outside"                       cullaapp.com.conf "$https" "    location /x/ { alias /etc/; }"
with_line "include outside"                     cullaapp.com.conf "$https" "    include /etc/passwd;"
with_line "include of an error page"            cullaapp.com.conf "$https" "    include /etc/nginx/cullaapp/errors/50x.html;"
with_line "include with a glob"                 cullaapp.com.conf "$https" "    include /etc/nginx/cullaapp/snippets/*.conf;"
with_line "load_module"                         cullaapp.com.conf "$https" "    load_module modules/x.so;"
with_line "user"                                cullaapp.com.conf "$https" "    user root;"
with_line "proxy_pass"                          cullaapp.com.conf "$https" "    location /p { proxy_pass http://127.0.0.1:9000; }"
with_line "lua"                                 cullaapp.com.conf "$https" "    lua_code_cache on;"
with_line "content_by_lua_block"                cullaapp.com.conf "$https" "    location /l { content_by_lua_block { ngx.say(1) } }"
with_line "perl"                                cullaapp.com.conf "$https" "    perl_modules /tmp;"
with_line "js_"                                 cullaapp.com.conf "$https" "    js_import /tmp/x.js;"
with_line "dav_methods"                         cullaapp.com.conf "$https" "    dav_methods PUT;"
with_line "another certificate"                 cullaapp.com.conf "$https" "    ssl_certificate /etc/shadow;"
with_line "an http-level setting"               cullaapp.com.conf "# Log format (one JSON object per line)" "server_tokens on;"
with_line "a log format of another name"        cullaapp.com.conf "# Log format (one JSON object per line)" "log_format x '\$remote_addr';"
with_line "include inside a map"                cullaapp.com.conf "map \$cullaapp_lang_found \$cullaapp_lang {" "    include /etc/passwd;"
with_line "another site's name"                cullaapp.com.conf "$https" "    server_name cullaapp.com another-name;"
with_line "a catch-all name"                    cullaapp.com.conf "$https" "    server_name _;"
with_line "listen default_server"               cullaapp.com.conf "$https" "    listen 443 ssl default_server;"
with_line "listen on another port"              cullaapp.com.conf "$https" "    listen 8443 ssl;"
with_line "listen on an address"                cullaapp.com.conf "$https" "    listen 127.0.0.1:80;"
with_line "a forbidden directive in a snippet"  snippets/security-headers.conf "# HSTS starts at 30 days" "proxy_pass http://127.0.0.1;"
with_line "include outside in a snippet"        snippets/tls.conf "ssl_certificate_key /etc/letsencrypt/live/cullaapp.com/privkey.pem;" "include /root/x.conf;"
with_line "a forbidden directive at bootstrap"  cullaapp.com.bootstrap.conf "    server_tokens off;" "    root /;" bootstrap
ok "the installer refuses log paths, root/alias, include, certificates and directives outside Culla's limits (31 cases), changing nothing"

s="$(new_stage)"; ln -sf /etc/hosts "$s/snippets/hosts.conf"
refuses "a snippet that is a symbolic link" "$s"
s="$(new_stage)"; rm "$s/cullaapp.com.conf"; ln -s "$deploy/cullaapp.com.conf" "$s/cullaapp.com.conf"
refuses "a configuration that is a symbolic link" "$s"
s="$(new_stage)"; mv "$s/snippets" "$s.snippets"; ln -s "$s.snippets" "$s/snippets"
refuses "a snippets folder that is a symbolic link" "$s"
s="$(new_stage)"; ln -s "$s" "$work/stage-link"
refuses "a stage folder that is a symbolic link" "$work/stage-link"
s="$(new_stage)"; echo 'echo hi' > "$s/errors/run.sh"
refuses "an unexpected file in errors/" "$s"
s="$(new_stage)"; echo x > "$s/snippets/Bad Name.conf"
refuses "a snippet name with a space" "$s"
s="$(new_stage)"; head -c 1100000 /dev/zero > "$s/errors/big.html"
refuses "a file over 1 MB" "$s"
s="$(new_stage)"; mkfifo "$s/errors/pipe.html"
refuses "a file that is not a regular file" "$s"
mv "$root/etc/nginx/cullaapp/errors" "$work/errors-real"; ln -s "$work/errors-real" "$root/etc/nginx/cullaapp/errors"
refuses "a destination folder that is a symbolic link" "$(new_stage)"
rm "$root/etc/nginx/cullaapp/errors"; mv "$work/errors-real" "$root/etc/nginx/cullaapp/errors"
mv "$conf" "$work/target-real"; ln -s "$work/target-real" "$conf"
before="$(nginx_tree)"
if bash "$deploy/remote-install.sh" download-target kpirliyev/culla 1.1 Culla-1.1.dmg >/dev/null 2>&1; then
    fail "installer wrote the /download target through a symbolic link"
fi
[ "$(nginx_tree)" = "$before" ] || fail "symbolic link target: files changed"
rm "$conf"; mv "$work/target-real" "$conf"
ok "the installer refuses symbolic links (stage, folders, files, destinations), unexpected names, big files and non-regular files"

# --- deploy.sh with the password-free installer ---------------------------------

cat > "$work/installer" <<EOF
#!/usr/bin/env bash
# Stands in for /usr/local/sbin/cullaapp-install run through sudo -n.
echo "\$*" >> "$work/installer.calls"
exec bash "$deploy/remote-install.sh" "\$@"
EOF
chmod +x "$work/installer"
export CULLA_DEPLOY_INSTALLER="$work/installer"
published kpirliyev/culla 1.2 Culla-1.2.dmg
msg="$("$deploy/deploy.sh" 2>&1)"
grep -q "sudo without a password" <<<"$msg" || fail "the password-free installer was not used: $msg"
grep -qx -- "--version" "$work/installer.calls" || fail "no probe"
grep -qx "download-target kpirliyev/culla 1.2 Culla-1.2.dmg" "$work/installer.calls" || fail "download-target not run: $(cat "$work/installer.calls")"
grep -qx 'return 302 https://github.com/kpirliyev/culla/releases/download/v1.2/Culla-1.2.dmg;' "$conf" || fail "target not written"
echo "# changed" >> "$work/deploy-broken/errors/errors.css"; sed -i.bak '/BROKEN/d' "$work/deploy-broken/cullaapp.com.conf" "$work/deploy-broken/snippets/tls.conf"
rm -f "$work/deploy-broken"/*.bak "$work/deploy-broken"/snippets/*.bak "$work/deploy-broken/snippets/new.conf"
"$work/deploy-broken/deploy.sh" --nginx >/dev/null
grep -q "^nginx .*cullaapp-deploy" "$work/installer.calls" || fail "--nginx did not use the installer: $(cat "$work/installer.calls")"
cmp -s "$work/deploy-broken/errors/errors.css" "$root/etc/nginx/cullaapp/errors/errors.css" || fail "--nginx through the installer did not install"
"$deploy/deploy.sh" --nginx >/dev/null
export CULLA_DEPLOY_INSTALLER="$work/no-installer"
published
"$deploy/deploy.sh" >/dev/null
ok "with the password-free installer, /download changes and --nginx run through it without a terminal; without it, the fallback is used"

# --- Over ssh with CULLA_DEPLOY_KEY --------------------------------------------

cat > "$work/fake-ssh" <<EOF
#!/usr/bin/env bash
# Stands in for ssh: notes its arguments, then runs the command here.
echo "\$*" >> "$work/ssh.calls"
while [ \$# -gt 0 ]; do
    case "\$1" in -p|-i|-o|-l) shift 2 ;; -t) shift ;; *) break ;; esac
done
shift   # user@host, or the host after "-l user" (rsync 3 passes the user so)
exec bash -c "\$*"
EOF
chmod +x "$work/fake-ssh"
echo "not a real key" > "$work/id_test"
echo "<html>en v2</html>" > "$out/en/index.html"
CULLA_DEPLOY_LOCAL=0 CULLA_DEPLOY_SSH="$work/fake-ssh" CULLA_DEPLOY_KEY="$work/id_test" "$deploy/deploy.sh" >/dev/null
grep -q "en v2" "$www/en/index.html" || fail "site not uploaded over (fake) ssh"
[ -s "$work/ssh.calls" ] || fail "ssh not used"
if grep -v -- "-p 22 -i $work/id_test -o IdentitiesOnly=yes" "$work/ssh.calls" | grep -q .; then
    fail "an ssh call without the key: $(cat "$work/ssh.calls")"
fi
grep -q "rsync --server" "$work/ssh.calls" || fail "rsync did not go through ssh with the key"
if CULLA_DEPLOY_LOCAL=0 CULLA_DEPLOY_SSH="$work/fake-ssh" CULLA_DEPLOY_KEY="$work/no such key" "$deploy/deploy.sh" >/dev/null 2>&1; then
    fail "accepted a key path with spaces"
fi
if CULLA_DEPLOY_LOCAL=0 CULLA_DEPLOY_SSH="$work/fake-ssh" CULLA_DEPLOY_KEY="$work/missing-key" "$deploy/deploy.sh" >/dev/null 2>&1; then
    fail "accepted a missing key file"
fi
ok "CULLA_DEPLOY_KEY: ssh and rsync's ssh get -i <file> -o IdentitiesOnly=yes; bad or missing key paths are refused"

# --- --upload-setup ---------------------------------------------------------------

CULLA_DEPLOY_SETUP_DIR="$work/setup-upload" "$deploy/deploy.sh" --upload-setup >/dev/null
for f in setup-host.sh remote-install.sh cullaapp.com.conf count.py crontab.txt snippets/tls.conf errors/50x.html; do
    cmp -s "$deploy/$f" "$work/setup-upload/$f" || fail "--upload-setup: $f missing or different"
done
[ -x "$work/setup-upload/setup-host.sh" ] || fail "--upload-setup: setup-host.sh not executable"
[ ! -e "$work/setup-upload/test" ] || fail "--upload-setup copied the tests"
ok "--upload-setup copies site/deploy/ without its tests, setup-host.sh executable"

# --- setup-host.sh in a stand-in for the shared host ---------------------------

host="$work/host"
hbin="$work/host-bin"
fx="$here/fixtures/host"
mkdir -p "$hbin" "$host/etc/nginx/conf.d" "$host/etc/nginx/snippets" "$host/var/www/letsencrypt" \
         "$host/etc/letsencrypt/renewal-hooks/deploy" "$host/data/cullaapp.com"/{www,log,ssl} \
         "$host/usr/local/sbin" "$host/etc/sudoers.d"
chmod 755 "$host/usr/local/sbin"
cp "$fx/00-default.conf" "$fx/other-site.conf" "$host/etc/nginx/conf.d/"
cp "$fx/acme-challenge.conf" "$host/etc/nginx/snippets/"
printf '#!/bin/sh\nsystemctl reload nginx\n' > "$host/etc/letsencrypt/renewal-hooks/deploy/reload-nginx"
printf '17 */12 * * * certbot renew --quiet\n' > "$host/crontab.root"
others() {  # the host's and the other site's files
    (cd "$host" && shasum etc/nginx/conf.d/00-default.conf etc/nginx/conf.d/other-site.conf \
        etc/nginx/snippets/acme-challenge.conf etc/letsencrypt/renewal-hooks/deploy/reload-nginx)
    grep certbot "$host/crontab.root"
}
others_before="$(others)"

cat > "$hbin/nginx" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    -v) echo "nginx version: nginx/${FAKE_NGINX_VERSION:-1.26.3}" >&2 ;;
    -t) if grep -rq BROKEN "$CULLA_ROOT/etc/nginx/conf.d" "$CULLA_ROOT/etc/nginx/cullaapp" 2>/dev/null; then
            echo "nginx: [emerg] fake failure" >&2; exit 1
        fi
        echo "nginx: configuration file test is successful" ;;
esac
EOF
cat > "$hbin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CULLA_ROOT/systemctl.calls"
EOF
cat > "$hbin/certbot" <<'EOF'
#!/usr/bin/env bash
# Fake certbot: "certificates" lists the domains; "certonly" makes the files.
live="$CULLA_ROOT/etc/letsencrypt/live/cullaapp.com"
if [ "$1" = certificates ]; then
    [ -f "$live/domains" ] && echo "    Domains: $(cat "$live/domains")"
    exit 0
fi
echo "$*" >> "$CULLA_ROOT/certbot.calls"
grep -q 'acme-challenge.conf' "$CULLA_ROOT/etc/nginx/conf.d/cullaapp.com.conf" 2>/dev/null \
    || { echo "no Culla config with the acme snippet while certbot runs" >&2; exit 1; }
grep -q 'being set up' "$CULLA_ROOT/etc/nginx/conf.d/cullaapp.com.conf" && echo bootstrap >> "$CULLA_ROOT/certbot.calls"
accounts="$CULLA_ROOT/etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory"
if ! ls "$accounts"/*/regr.json >/dev/null 2>&1; then
    case " $* " in *" --agree-tos "*) mkdir -p "$accounts/abc" && echo '{}' > "$accounts/abc/regr.json" ;;
                   *) echo "certbot: no account and no --agree-tos" >&2; exit 1 ;; esac
fi
domains=""; prev=""
for a in "$@"; do [ "$prev" = -d ] && domains="$domains $a"; prev="$a"; done
mkdir -p "$live"
echo cert > "$live/fullchain.pem"; echo key > "$live/privkey.pem"
echo "${domains# }" > "$live/domains"
EOF
cat > "$hbin/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CULLA_ROOT/apt.calls"
printf '#!/bin/sh\n' > "$(dirname "$0")/$CULLA_RSYNC"; chmod +x "$(dirname "$0")/$CULLA_RSYNC"
EOF
cat > "$hbin/crontab" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    -l) [ -f "$CULLA_ROOT/crontab.root" ] || { echo "no crontab for root" >&2; exit 1; }; cat "$CULLA_ROOT/crontab.root" ;;
    -)  cat > "$CULLA_ROOT/crontab.root" ;;
esac
EOF
cat > "$hbin/chown" <<'EOF'
#!/usr/bin/env bash
# Fake chown: notes what root would own (the tests do not run as root).
echo "$*" >> "$CULLA_ROOT/chown.calls"
EOF
cat > "$hbin/visudo" <<'EOF'
#!/usr/bin/env bash
# Fake visudo -cf <file>: fails on request or when the rule is not the expected one.
[ "$1" = -cf ] || exit 2
[ "${FAKE_VISUDO_FAIL:-0}" = 1 ] && { echo "parse error" >&2; exit 1; }
grep -Eqx '[a-z_][a-z0-9_-]* ALL=\(root\) NOPASSWD: /usr/local/sbin/cullaapp-install' "$2"
EOF
chmod +x "$hbin"/*

me="$(id -un)"; mygroup="$(id -gn)"
[[ "$me" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || fail "these tests need a plain account name, not $me"
setup() {  # setup [VAR=value ...]: run setup-host.sh in the stand-in host
    env -u CULLA_NGINX -u CULLA_SYSTEMCTL -u CULLA_SUDO -u CULLA_WITH_WWW -u CULLA_WITH_IPV6 \
        PATH="$hbin:$PATH" CULLA_SETUP_TEST=1 CULLA_ROOT="$host" CULLA_RSYNC=rsync-not-installed \
        CULLA_DEPLOY_USER="$me" "$@" "$setup_script"
}
setup_script="$deploy/setup-host.sh"
host_tree() { (cd "$host" && find . | sort && find . -type f | sort | xargs shasum); }
mode_of() { python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }

if [ "$(id -u)" != 0 ]; then
    if msg="$(CULLA_DEPLOY_USER="$me" "$deploy/setup-host.sh" 2>&1)"; then fail "setup-host.sh ran without root"; fi
    grep -q "run it as root" <<<"$msg" || fail "unclear message: $msg"
fi
before="$(host_tree)"
if msg="$(setup CULLA_DEPLOY_USER= 2>&1)"; then fail "ran without CULLA_DEPLOY_USER"; fi
grep -q "set CULLA_DEPLOY_USER" <<<"$msg" || fail "unclear message: $msg"
for bad in 'Bad' 'a;b' 'a b' '-x' root "$(printf 'x%.0s' $(seq 40))"; do
    if setup CULLA_DEPLOY_USER="$bad" >/dev/null 2>&1; then fail "accepted the account name '$bad'"; fi
done
if setup CULLA_DEPLOY_USER="$me" CULLA_WITH_WWW=maybe >/dev/null 2>&1; then fail "accepted CULLA_WITH_WWW=maybe"; fi
if msg="$(setup 2>&1)"; then fail "asked for a new certificate without an account or CERTBOT_AGREE_TOS"; fi
grep -q "CERTBOT_AGREE_TOS=yes" <<<"$msg" || fail "unclear message: $msg"
if msg="$(setup FAKE_NGINX_VERSION=1.22.1 CERTBOT_AGREE_TOS=yes 2>&1)"; then fail "accepted nginx 1.22"; fi
grep -q "older than 1.25.1" <<<"$msg" || fail "unclear message: $msg"
mv "$host/etc/nginx/snippets/acme-challenge.conf" "$work/acme.conf"
if msg="$(setup CERTBOT_AGREE_TOS=yes 2>&1)"; then fail "ran without the host's acme snippet"; fi
grep -q "acme-challenge.conf" <<<"$msg" || fail "unclear message: $msg"
mv "$work/acme.conf" "$host/etc/nginx/snippets/acme-challenge.conf"
mv "$host/etc/nginx/conf.d/00-default.conf" "$work/00-default.conf"
if msg="$(setup CERTBOT_AGREE_TOS=yes 2>&1)"; then fail "ran without the host's default servers"; fi
grep -q "no default server on port 80" <<<"$msg" || fail "unclear message: $msg"
mv "$work/00-default.conf" "$host/etc/nginx/conf.d/00-default.conf"
[ "$(host_tree)" = "$before" ] || fail "a refused run changed something"
ok "setup-host.sh refuses: without root, without CULLA_DEPLOY_USER, bad account names, bad yes/no, no account and no CERTBOT_AGREE_TOS, nginx older than 1.25.1, no acme snippet, no default servers; nothing changed"

out1="$(setup CERTBOT_AGREE_TOS=yes)"
[ "$(cat "$host/certbot.calls")" = "certonly --webroot -w $host/var/www/letsencrypt --cert-name cullaapp.com -d cullaapp.com --non-interactive --agree-tos --register-unsafely-without-email
bootstrap" ] || fail "certbot: $(cat "$host/certbot.calls")"
[ "$(cat "$host/etc/nginx/conf.d/cullaapp.com.conf")" = "$(render no no "$deploy/cullaapp.com.conf")" ] \
    || fail "full config not installed with www=no, ipv6=no (the stand-in default servers have no IPv6)"
[ "$(cat "$host/etc/cullaapp/host.conf")" = "$(printf '# Written by setup-host.sh; read by remote-install.sh.\nwww=no\nipv6=no')" ] \
    || fail "host.conf: $(cat "$host/etc/cullaapp/host.conf")"
cmp -s "$deploy/logrotate.conf" "$host/etc/logrotate.d/cullaapp.com" || fail "logrotate rule"
cmp -s "$deploy/count.py" "$host/usr/local/lib/cullaapp/count.py" && [ -x "$host/usr/local/lib/cullaapp/count.py" ] || fail "count.py"
[ "$(cat "$host/crontab.root")" = "17 */12 * * * certbot renew --quiet
30 1 * * * /usr/bin/python3 /usr/local/lib/cullaapp/count.py 2>&1 | logger -t cullaapp-count" ] \
    || fail "crontab: $(cat "$host/crontab.root")"
grep -q "install -y --no-install-recommends rsync" "$host/apt.calls" || fail "rsync not installed"
grep -qx -- "-R $me:$mygroup $host/data/cullaapp.com/www" "$host/chown.calls" || fail "www owner: $(cat "$host/chown.calls")"
grep -qx "root:adm $host/data/cullaapp.com/log" "$host/chown.calls" || fail "log owner"
grep -qx "root:adm $host/data/cullaapp.com/stats" "$host/chown.calls" || fail "stats owner"
[ "$(mode_of "$host/data/cullaapp.com/log")" = 750 ] && [ "$(mode_of "$host/data/cullaapp.com/stats")" = 750 ] \
    && [ "$(mode_of "$host/data/cullaapp.com/www")" = 755 ] || fail "folder modes"
[ -d "$host/data/cullaapp.com/ssl" ] && ! grep -q "/ssl" "$host/chown.calls" || fail "ssl/ was touched"
[ "$(grep -c 'reload nginx' "$host/systemctl.calls")" = 2 ] || fail "nginx not reloaded after bootstrap and full config"
[ ! -e "$host/usr/local/sbin/cullaapp-install" ] && [ -z "$(ls -A "$host/etc/sudoers.d")" ] \
    || fail "password-free files made without CULLA_PASSWORDLESS=yes"
grep -q "Check now" <<<"$out1" || fail "no summary"
ok "first run: rsync, folders, host.conf, HTTP-only config, certbot --webroot (new account), full config, logrotate, count.py, one crontab line; no sudoers rule"

rm -f "$host/certbot.calls" "$host/systemctl.calls"
crontab_before="$(cat "$host/crontab.root")"; before="$(host_tree)"
out2="$(setup)"
[ ! -e "$host/certbot.calls" ] && [ ! -e "$host/systemctl.calls" ] || fail "second run asked certbot or reloaded nginx"
[ "$(cat "$host/crontab.root")" = "$crontab_before" ] || fail "second run changed the crontab"
grep -q "nothing needed changing" <<<"$out2" || fail "second run did something: $out2"
[ "$(host_tree | grep -v chown.calls)" = "$(printf '%s\n' "$before" | grep -v chown.calls)" ] || fail "second run changed files"
ok "a second run changes nothing (no certbot, no reload, crontab as it was)"

setup CULLA_WITH_WWW=yes >/dev/null
[ "$(cat "$host/certbot.calls")" = "certonly --webroot -w $host/var/www/letsencrypt --cert-name cullaapp.com -d cullaapp.com -d www.cullaapp.com --non-interactive --expand" ] \
    || fail "certbot for www: $(cat "$host/certbot.calls")"
[ "$(cat "$host/etc/nginx/conf.d/cullaapp.com.conf")" = "$(render yes no "$deploy/cullaapp.com.conf")" ] || fail "www config"
ok "CULLA_WITH_WWW=yes: the certificate is expanded with the existing account (no terms needed) and the www server added"

cp -R "$deploy" "$work/setup-broken"
echo "# BROKEN" >> "$work/setup-broken/cullaapp.com.conf"
good="$(cat "$host/etc/nginx/conf.d/cullaapp.com.conf")"
rm -f "$host/systemctl.calls"
if msg="$(setup_script="$work/setup-broken/setup-host.sh" setup CULLA_WITH_WWW=yes 2>&1)"; then fail "a failing nginx -t was not reported"; fi
grep -q "rolled back" <<<"$msg" || fail "unclear message: $msg"
[ "$(cat "$host/etc/nginx/conf.d/cullaapp.com.conf")" = "$good" ] || fail "config not restored"
[ ! -e "$host/systemctl.calls" ] || fail "nginx reloaded after a failed test"
ok "setup-host.sh with a configuration that fails nginx -t restores Culla's files and does not reload"

setup CULLA_WITH_WWW=yes CULLA_PASSWORDLESS=yes >/dev/null
inst="$host/usr/local/sbin/cullaapp-install"
[ -f "$inst" ] && [ "$(mode_of "$inst")" = 755 ] || fail "installer copy missing or mode $(mode_of "$inst")"
grep -qx 'CULLA_HOOKS=no' "$inst" && ! grep -qx 'CULLA_HOOKS=yes' "$inst" || fail "test hooks not switched off in the copy"
[ "$(diff <(sed 's/^CULLA_HOOKS=no$/CULLA_HOOKS=yes/' "$inst") "$deploy/remote-install.sh")" = "" ] || fail "the copy differs in more than the hooks line"
[ "$(cat "$host/etc/sudoers.d/cullaapp")" = "# Written by setup-host.sh: $me may run Culla's nginx installer as root without a password.
$me ALL=(root) NOPASSWD: /usr/local/sbin/cullaapp-install" ] || fail "sudoers: $(cat "$host/etc/sudoers.d/cullaapp")"
[ "$(mode_of "$host/etc/sudoers.d/cullaapp")" = 440 ] || fail "sudoers mode $(mode_of "$host/etc/sudoers.d/cullaapp")"
grep -q "^root:root $host/usr/local/sbin/.cullaapp-install" "$host/chown.calls" || fail "installer not given to root"
grep -q "^root:root $host/etc/sudoers.d/.cullaapp" "$host/chown.calls" || fail "sudoers file not given to root"
[ "$(ls -A "$host/etc/sudoers.d")" = cullaapp ] && [ -z "$(ls -A "$host/usr/local/sbin" | grep -v '^cullaapp-install$')" ] \
    || fail "temporary files left behind"
[ "$("$inst" --version)" = "cullaapp-install 2" ] || fail "the copy does not answer --version"
if msg="$(CULLA_ROOT="$root" "$inst" nginx "$(new_stage)" 2>&1)"; then fail "the copy ran without root"; fi
grep -q "run it with sudo" <<<"$msg" || fail "unclear message: $msg"
if CULLA_ROOT="$root" "$inst" render "$deploy/cullaapp.com.conf" >/dev/null 2>&1; then fail "the copy renders files"; fi
ok "CULLA_PASSWORDLESS=yes: root-owned installer copy (0755, test hooks off, refuses without sudo) and the sudoers rule (0440, exact line)"

rm "$host/etc/sudoers.d/cullaapp"
if setup CULLA_WITH_WWW=yes CULLA_PASSWORDLESS=yes FAKE_VISUDO_FAIL=1 >/dev/null 2>&1; then fail "a rule visudo rejects was accepted"; fi
[ -z "$(ls -A "$host/etc/sudoers.d")" ] || fail "a sudoers file was left after visudo rejected it: $(ls -A "$host/etc/sudoers.d")"
chmod 775 "$host/usr/local/sbin"
if setup CULLA_WITH_WWW=yes CULLA_PASSWORDLESS=yes >/dev/null 2>&1; then fail "accepted a group-writable /usr/local/sbin"; fi
chmod 755 "$host/usr/local/sbin"
setup CULLA_WITH_WWW=yes CULLA_PASSWORDLESS=yes >/dev/null
[ -f "$host/etc/sudoers.d/cullaapp" ] || fail "rule not installed again"
msg="$(setup CULLA_WITH_WWW=yes)"
grep -q "left as they are" <<<"$msg" || fail "no note about the existing password-free files"
ok "a sudoers rule visudo rejects is never left behind; a writable /usr/local/sbin is refused"

[ "$(others)" = "$others_before" ] || fail "the host's or the other site's files changed"
ok "the host's files, the other site's file and the certbot crontab line are byte-for-byte unchanged"

# Temporary folders on the "server" are removed.
if ls "${TMPDIR:-/tmp}"/cullaapp-deploy.* >/dev/null 2>&1; then fail "staging folder left behind"; fi
ok "staging folders are removed"

# --- The log folder was never touched ----------------------------------------

[ "$(ls -lR "$logdir" | shasum)" = "$log_before" ] || fail "the log folder changed"
ok "the log folder was not touched"

printf '\n%d checks passed\n' "$pass"

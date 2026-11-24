#!/usr/bin/env bash
# Tests the real nginx behaviour of cullaapp.com.conf and the bootstrap
# config with the official nginx image's nginx, a self-signed certificate and
# a fixture web root.
#
#   site/test.sh nginx
#   CULLA_NGINX_IMAGE=docker.io/library/nginx:1.24 site/test.sh nginx
#
# The whole test runs inside one throwaway container of the test image
# (site/containers/test.Containerfile: the nginx image plus python3 and
# rsync), started by site/test.sh with no network: this script puts the
# host's stand-in files and Culla's rendered configuration into the
# container's /etc/nginx, starts and stops nginx there, and talks to it with
# curl over the container's loopback. Run on the Mac, it hands over to
# site/test.sh nginx.
#
# Exit status: 0 all passed, 1 a check failed, 2 podman is not usable.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deploy="$(dirname "$here")"

if [ "${CULLA_IN_CONTAINER:-}" != 1 ]; then
    exec "$(dirname "$deploy")/test.sh" nginx
fi
# It rewrites /etc/nginx: never anywhere but in a container.
if [ ! -e /run/.containerenv ] || [ "$(id -u)" != 0 ] || ! command -v nginx >/dev/null; then
    echo "run-nginx-tests.sh: only for the test container as root; run site/test.sh nginx" >&2
    exit 2
fi

IMAGE="${CULLA_NGINX_IMAGE:-the test image}"
HTTP=80
HTTPS=443

work="$(mktemp -d "${TMPDIR:-/tmp}/culla-nginx-test.XXXXXX")"
nginx_out="$work/nginx.out"   # nginx's own output: the stand-in nginx.conf logs to stdout and stderr
stop_nginx() {
    if [ -s /run/nginx.pid ]; then
        local pid; pid="$(cat /run/nginx.pid)"
        kill -QUIT "$pid" 2>/dev/null || true
        for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        kill -KILL "$pid" 2>/dev/null || true
        rm -f /run/nginx.pid
    fi
}
cleanup() {
    stop_nginx
    rm -rf "$work"
}
trap cleanup EXIT

pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$*"; }
fail() {
    printf 'FAIL %s\n' "$*" >&2
    echo "--- nginx output" >&2; tail -20 "$nginx_out" 2>/dev/null >&2 || true
    echo "--- error.log" >&2; tail -20 "$log/error.log" 2>/dev/null >&2 || true
    exit 1
}

# --- Files as they will be on the server ---------------------------------------

# The host's own files are stand-ins from fixtures/host/ (nginx.conf with the
# host's http-level settings, conf.d/00-default.conf with its TLS settings
# and default servers, and the acme-challenge snippet). Culla's
# configuration goes on top, rendered by remote-install.sh as setup-host.sh
# installs it. The stand-in default servers listen on IPv4 only, so Culla's
# files are rendered with ipv6=no, as setup-host.sh would choose there.
fx="$here/fixtures/host"
mkdir -p "$work"/{conf.d,conf-nowww.d,boot.d,boot-www.d,check.d,cullaapp/snippets,cullaapp/errors,tls,www} \
         "$work"/{bootlog,log,log2,stats,targets,snippets} "$work/letsencrypt/.well-known/acme-challenge"
render() {  # render <www> <ipv6> <file>
    CULLA_ROOT="$work/none" CULLA_WITH_WWW="$1" CULLA_WITH_IPV6="$2" bash "$deploy/remote-install.sh" render "$3"
}
for d in conf.d conf-nowww.d boot.d boot-www.d check.d; do cp "$fx/00-default.conf" "$work/$d/"; done
render yes no "$deploy/cullaapp.com.conf"           > "$work/conf.d/cullaapp.com.conf"
render no  no "$deploy/cullaapp.com.conf"           > "$work/conf-nowww.d/cullaapp.com.conf"
render no  no "$deploy/cullaapp.com.bootstrap.conf" > "$work/boot.d/cullaapp.com.conf"
render yes no "$deploy/cullaapp.com.bootstrap.conf" > "$work/boot-www.d/cullaapp.com.conf"
cp "$fx/acme-challenge.conf" "$work/snippets/"
echo "token-for-the-test" > "$work/letsencrypt/.well-known/acme-challenge/test-token"
cp "$deploy"/snippets/*.conf "$work/cullaapp/snippets/"
cp "$deploy"/errors/* "$work/cullaapp/errors/"
# The only change for the test: the certificate is a self-signed one.
sed 's#/etc/letsencrypt/live/cullaapp.com/#/test/tls/#' "$deploy/snippets/tls.conf" \
    > "$work/cullaapp/snippets/tls.conf"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=cullaapp.com" \
    -addext "subjectAltName=DNS:cullaapp.com,DNS:www.cullaapp.com" \
    -keyout "$work/tls/privkey.pem" -out "$work/tls/fullchain.pem" >/dev/null 2>&1

w="$work/www"
for l in en ru tk; do
    mkdir -p "$w/$l"
    echo "<!doctype html><title>$l</title><p>page $l</p>" > "$w/$l/index.html"
done
echo "<!doctype html><title>404</title><p>fixture 404 page</p>" > "$w/404.html"
# What the build writes from release.json; the app reads it to learn whether
# a newer version exists.
echo '{ "version": "1.1", "minimumSystem": "26.0", "date": "2026-12-01" }' > "$w/update.json"
mkdir -p "$w/_nuxt"
head -c 30000 /dev/zero | tr '\0' 'a' > "$w/_nuxt/app.abc123.js"
gzip -k -9 "$w/_nuxt/app.abc123.js"
chmod -R a+rX "$work"
chmod 777 "$work/bootlog" "$work/log" "$work/log2"

# The files go where they will be on the server, in this container only:
# the host's nginx.conf, its snippets and acme webroot, Culla's files, the
# test certificate, the web root, the log folder and conf.d. The log folder
# and conf.d change between the steps below (use_config).
cp "$fx/nginx.conf" /etc/nginx/nginx.conf
rm -rf /etc/nginx/snippets /etc/nginx/cullaapp /var/www/letsencrypt /test /data/cullaapp.com
mkdir -p /var/www /test /data/cullaapp.com
cp -R "$work/snippets" /etc/nginx/snippets
cp -R "$work/cullaapp" /etc/nginx/cullaapp
cp -R "$work/letsencrypt" /var/www/letsencrypt
cp -R "$work/tls" /test/tls
cp -R "$work/www" /data/cullaapp.com/www
# nginx -t and the bootstrap config log into bootlog/, each full config into
# a fresh folder.
log="$work/bootlog"

use_config() {  # use_config <conf dir>: it becomes conf.d; logs go to $log
    rm -rf /etc/nginx/conf.d /data/cullaapp.com/log
    cp -R "$1" /etc/nginx/conf.d
    ln -s "$log" /data/cullaapp.com/log
}

# --- nginx -t: the host's stand-in files plus each variant of Culla's ---------

nginx_t() {  # nginx_t <conf dir> <what>
    use_config "$1"
    nginx -t >"$work/nginx-t.out" 2>&1 \
        || { cat "$work/nginx-t.out" >&2; fail "nginx -t fails for $2"; }
}
nginx_t "$work/check.d" "the host's stand-in files alone"
for www in no yes; do
    for ipv6 in no yes; do
        for f in cullaapp.com.conf cullaapp.com.bootstrap.conf; do
            render "$www" "$ipv6" "$deploy/$f" > "$work/check.d/cullaapp.com.conf"
            nginx_t "$work/check.d" "$f with www=$www ipv6=$ipv6"
        done
    done
done
sed 's/#.*//' "$work/conf.d/cullaapp.com.conf" "$work/boot-www.d/cullaapp.com.conf" | grep -q "default_server" && fail "Culla's configuration declares a default_server"
ok "nginx -t passes for the host's stand-in nginx.conf and 00-default.conf with Culla's full and HTTP-only configuration, www and IPv6 each on and off (no duplicate http-level setting, no second default_server)"

start() {  # start <conf dir>: a fresh nginx with that conf.d; logs go to $log
    stop_nginx
    use_config "$1"
    nginx >>"$nginx_out" 2>&1 || fail "nginx did not start"
    for _ in $(seq 1 50); do
        # The host's default server closes connections for unknown names, so
        # ask for a challenge file, which every configuration answers.
        curl -s -o /dev/null -H "Host: cullaapp.com" \
            "http://127.0.0.1:$HTTP/.well-known/acme-challenge/test-token" && return 0
        sleep 0.2
    done
    fail "nginx did not start"
}

H="cullaapp.com"
c() {  # curl against nginx as if it were the real host names
    curl -sk --max-time 10 \
        --resolve "cullaapp.com:$HTTP:127.0.0.1" --resolve "www.cullaapp.com:$HTTP:127.0.0.1" \
        --resolve "cullaapp.com:$HTTPS:127.0.0.1" --resolve "www.cullaapp.com:$HTTPS:127.0.0.1" "$@"
}
status_of() { c -o /dev/null -w '%{http_code}' "$@"; }
headers_of() { c -o /dev/null -D - "$@" | tr -d '\r'; }
header() {  # header <headers> <name>: the value, or nothing
    printf '%s\n' "$1" | awk -v n="$(printf '%s' "$2" | tr 'A-Z' 'a-z')" \
        'BEGIN{FS=": "} tolower($1)==n {sub(/^[^:]*: /,""); print; exit}'
}
expect_header() {  # expect_header <headers> <name> <value> <what>
    local got; got="$(header "$1" "$2")"
    [ "$got" = "$3" ] || fail "$4: $2 is '$got', expected '$3'"
}

# --- Bootstrap config answers on HTTP ----------------------------------------

acme() {  # acme <host> <what>: the challenge file is served on port 80
    local body; body="$(c "http://$1:$HTTP/.well-known/acme-challenge/test-token")"
    [ "$body" = "token-for-the-test" ] || fail "$2: challenge for $1 not served: '$body'"
}
start "$work/boot-www.d"
[ "$(status_of "http://$H:$HTTP/")" = 503 ] || fail "bootstrap: / is not 503"
[ "$(status_of "http://www.$H:$HTTP/")" = 503 ] || fail "bootstrap: www not answered"
acme "$H" "bootstrap"; acme "www.$H" "bootstrap with www"
[ "$(status_of "http://$H:$HTTP/.well-known/acme-challenge/none")" = 404 ] || fail "bootstrap: a missing challenge is not 404"
grep -q '"ip":"127\.0\.0\.1"' "$log/access.log" || fail "bootstrap: the client's address is not in access.log"
ok "bootstrap config (with www) serves HTTP for both names, answers challenges from the host's webroot and logs the client's address"
log="$work/log"

# --- Full config ---------------------------------------------------------------

start "$work/conf.d"
S="https://$H:$HTTPS"

# Language choice.
lang_case() {  # lang_case <expected> [Accept-Language]
    local h
    if [ $# -ge 2 ]; then h="$(headers_of -H "Accept-Language: $2" "$S/")"
    else h="$(headers_of -H "Accept-Language:" "$S/")"; fi
    printf '%s\n' "$h" | head -1 | grep -q ' 302' || fail "/ with '${2-}' is not 302"
    expect_header "$h" Location "/$1/" "Accept-Language '${2-<missing>}'"
}
lang_case ru "ru-RU,ru;q=0.9,en;q=0.8"
lang_case tk "tk"
lang_case en "de,fr"
lang_case ru "de,ru"
lang_case en
lang_case en "en-GB,en;q=0.9,ru;q=0.5"
ok "/ redirects by Accept-Language (ru-RU, tk, de/fr, de/ru, missing, en-GB)"

# Security headers everywhere.
CSP="default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; form-action 'self'; base-uri 'self'; frame-ancestors 'none'"
security() {  # security <what> <curl args...>
    local what="$1" h; shift
    h="$(headers_of "$@")"
    expect_header "$h" Content-Security-Policy "$CSP" "$what"
    expect_header "$h" Strict-Transport-Security "max-age=2592000" "$what"
    expect_header "$h" X-Content-Type-Options "nosniff" "$what"
    expect_header "$h" Referrer-Policy "strict-origin-when-cross-origin" "$what"
}
security "HTML page"       "$S/en/"
security "asset"           "$S/_nuxt/app.abc123.js"
security "404 page"        "$S/nope"
security "language redirect" "$S/"
security "/download 503"   "$S/download"
security "HTTP redirect"   "http://$H:$HTTP/en/"
security "www redirect"    "https://www.$H:$HTTPS/en/"
security "dir redirect"    "$S/en"
ok "security headers (exact CSP, HSTS, nosniff, Referrer-Policy) on pages, assets, redirects and error pages"

# Certificate challenges in the full configuration, for both names. The
# acme location comes from the host's snippet and adds no header, so the
# server's security headers reach it, like its sibling the redirect.
acme "$H" "full config"; acme "www.$H" "full config with www"
security "acme challenge"  "http://$H:$HTTP/.well-known/acme-challenge/test-token"
security "acme challenge for www" "http://www.$H:$HTTP/.well-known/acme-challenge/test-token"
h="$(headers_of "http://$H:$HTTP/.well-known/acme-challenge/test-token")"
printf '%s\n' "$h" | head -1 | grep -q ' 200' || fail "challenge is not 200"
expect_header "$h" Content-Type "text/plain" "challenge"
h="$(headers_of "http://$H:$HTTP/.well-known/acme-challengeX")"
expect_header "$h" Location "https://cullaapp.com/.well-known/acme-challengeX" "near-miss of the challenge path"
ok "port 80 answers challenges from the host's webroot for cullaapp.com and www.cullaapp.com, with the security headers; everything else redirects"

h="$(headers_of "http://www.$H:$HTTP/ru/?x=1")"
expect_header "$h" Location "https://cullaapp.com/ru/?x=1" "HTTP redirect"
h="$(headers_of "https://www.$H:$HTTPS/tk/")"
expect_header "$h" Location "https://cullaapp.com/tk/" "www redirect"
ok "plain HTTP and www redirect to https://cullaapp.com with the path"

# Caching and compression.
h="$(headers_of "$S/en/")"; expect_header "$h" Cache-Control "no-cache" "HTML"
h="$(headers_of -H 'Accept-Encoding: gzip' "$S/_nuxt/app.abc123.js")"
expect_header "$h" Cache-Control "public, max-age=31536000, immutable" "asset"
expect_header "$h" Content-Encoding "gzip" "asset with gzip_static"
# gzip_static sends the .gz file made at build time byte for byte (on-the-fly
# gzip is off, so a match proves the pre-compressed file was used).
c -H 'Accept-Encoding: gzip' -o "$work/got.gz" "$S/_nuxt/app.abc123.js"
cmp -s "$work/got.gz" "$w/_nuxt/app.abc123.js.gz" || fail "asset body is not the pre-compressed .gz file"
h="$(headers_of "$S/_nuxt/app.abc123.js")"
[ -z "$(header "$h" Content-Encoding)" ] || fail "asset compressed for a client without gzip"
ok "HTML no-cache, /_nuxt/ immutable, gzip_static serves the build's .gz byte for byte"

# /update.json, as the app asks for it: no query string, no cookies, the
# fixed User-Agent "Culla". A root-level static file served by "location /":
# never redirected by language, revalidated on every check.
for al in "" "ru-RU,ru;q=0.9" "tk"; do
    h="$(headers_of -A Culla -H "Accept-Language: $al" "$S/update.json")"
    printf '%s\n' "$h" | head -1 | grep -q ' 200' || fail "/update.json with Accept-Language '$al' is not 200: $(printf '%s' "$h" | head -1)"
    [ -z "$(header "$h" Location)" ] || fail "/update.json with Accept-Language '$al' redirects"
    expect_header "$h" Content-Type "application/json" "/update.json"
    expect_header "$h" Cache-Control "no-cache" "/update.json"
done
c -A Culla -o "$work/update.json" "$S/update.json"
cmp -s "$work/update.json" "$w/update.json" || fail "/update.json body is not the file in the web root"
security "/update.json" -A Culla "$S/update.json"
[ "$(status_of -A Culla "http://$H:$HTTP/update.json")" = 301 ] || fail "http://cullaapp.com/update.json is not redirected to HTTPS"
[ "$(header "$(headers_of "http://$H:$HTTP/update.json")" Location)" = "https://cullaapp.com/update.json" ] \
    || fail "http://cullaapp.com/update.json redirects elsewhere"
ok "/update.json: 200, application/json, no-cache, the security headers, the file byte for byte, never sent to a language; over HTTP 301 to HTTPS"

# 404 from the web root.
[ "$(status_of "$S/nope")" = 404 ] || fail "/nope is not 404"
c "$S/nope" | grep -q "fixture 404 page" || fail "404 page is not the site's 404.html"
for gone in /contact /downloads/Culla-1.0.dmg /_errors/413.html /_errors/429.html; do
    [ "$(status_of "$S$gone")" = 404 ] || fail "$gone is not 404"
done
ok "404 uses the site's 404.html; the old form address, /downloads/ and the 413/429 pages are gone"

# /download before and after a release. The include is written by
# remote-install.sh itself (with a stand-in root and no real nginx), so this
# checks the exact line deploy.sh puts on the server.
#
# Each step gets a fresh stand-in root (a copy of the one before);
# download-target.conf is then copied from it into /etc/nginx/cullaapp, or
# removed there when the step removed it, and nginx reloads.
GITHUB_URL="https://github.com/kpirliyev/culla/releases/download/v1.0/Culla-1.0.dmg"
step=0
install_target() {  # install_target <remote-install.sh download-target arguments>
    step=$((step + 1))
    if [ "$step" = 1 ]; then mkdir -p "$work/targets/$step"
    else cp -R "$work/targets/$((step - 1))" "$work/targets/$step"; fi
    CULLA_ROOT="$work/targets/$step" CULLA_SUDO="" CULLA_NGINX=true CULLA_SYSTEMCTL=true \
        bash "$deploy/remote-install.sh" download-target "$@" >/dev/null
    chmod -R a+rX "$work/targets/$step"
    rm -f /etc/nginx/cullaapp/download-target.conf
    local f="$work/targets/$step/etc/nginx/cullaapp/download-target.conf"
    if [ -f "$f" ]; then cp "$f" /etc/nginx/cullaapp/; fi
    nginx -s reload >>"$nginx_out" 2>&1 || fail "nginx did not reload after download-target $*"
    sleep 1
}
download_503() {  # download_503 <what>
    [ "$(status_of "$S/download")" = 503 ] || fail "$1: /download is not 503"
    c "$S/download" | grep -q "not available yet" || fail "$1: /download 503 page missing"
    local h; h="$(headers_of "$S/download")"
    [ -z "$(header "$h" Location)" ] || fail "$1: /download 503 has a Location"
    # The page comes from /_errors/, whose Cache-Control applies.
    expect_header "$h" Cache-Control "no-cache" "/download 503"
}
download_503 "before a release"
install_target kpirliyev/culla 1.0 Culla-1.0.dmg
h="$(headers_of "$S/download")"
printf '%s\n' "$h" | head -1 | grep -q ' 302' || fail "/download after a release is not 302: $(printf '%s' "$h" | head -1)"
expect_header "$h" Location "$GITHUB_URL" "/download after release"
expect_header "$h" Cache-Control "no-store" "/download 302"
security "/download 302" "$S/download"
h="$(headers_of "$S/download?from=page")"
expect_header "$h" Location "$GITHUB_URL" "/download with a query string"
install_target none
download_503 "after going back to no release"
install_target kpirliyev/culla 1.0 Culla-1.0.dmg
ok "/download: friendly 503 before the first release, 302 to $GITHUB_URL after, with the security headers and no-store"

# Counting: the visit from access.log, the downloads from GitHub's answer
# (a fixture file here, so no network is used).
c -o /dev/null "$S/en/"
sleep 1
grep -q '"uri":"/download"' "$work/log/access.log" || fail "the /download redirect is not in access.log"
# The app's update checks are logged like any request (the site says so),
# and count.py does not count them as visits (en stays at 1 below).
grep -q '"uri":"/update.json","status":200,.*"ua":"Culla"' "$work/log/access.log" || fail "the update check is not in access.log"
day="$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["time"][:10])' "$work/log/access.log")"
CULLA_LOG_DIR="$work/log" CULLA_STATS_DIR="$work/stats" PYTHONDONTWRITEBYTECODE=1 \
    python3 "$deploy/count.py" --date "$day" --releases-file "$here/fixtures/github-releases.json"
grep -q "^$day,en,1," "$work/stats/visits.csv" || fail "visits.csv: $(cat "$work/stats/visits.csv")"
grep -q ",v1.0,Culla-1.0.dmg,57,57$" "$work/stats/downloads.csv" || fail "downloads.csv: $(cat "$work/stats/downloads.csv")"
ok "count.py counts the visit from the real access.log and the downloads from GitHub's answer"

# Every access.log line is one JSON object with the expected fields and the
# client's full address (the test talks to nginx from 127.0.0.1).
python3 - "$work/log" <<'EOF' || fail "access.log lines are not as expected"
import glob, json, sys
FIELDS = ["time", "ip", "host", "method", "uri", "status", "bytes", "referrer", "ua"]
lines = 0
for line in open(sys.argv[1] + "/access.log", encoding="utf-8"):
    entry = json.loads(line)
    assert list(entry) == FIELDS, entry
    assert entry["ip"] == "127.0.0.1", entry
    assert isinstance(entry["status"], int) and isinstance(entry["bytes"], int), entry
    lines += 1
assert lines, "nothing logged"
files = sorted(glob.glob(sys.argv[1] + "/*"))
assert any(p.endswith("/error.log") for p in files), "error.log was not created"
print("files checked:", ", ".join(p.rsplit("/", 1)[1] for p in files), "-", lines, "access.log lines")
EOF
files="$(ls "$work/log" | tr '\n' ' ')"
[ "$files" = "access.log error.log " ] || fail "unexpected log files: $files"
ok "only access.log and error.log are written; every access.log line is JSON with the expected fields and the client's full address"

# --- Without www.cullaapp.com ---------------------------------------------------

log="$work/log2"
start "$work/conf-nowww.d"
acme "$H" "full config without www"
# www.cullaapp.com is the host's business now: its default servers answer.
acme "www.$H" "the host's default server"
code="$(status_of "http://www.$H:$HTTP/en/" || true)"
[ "$code" = 000 ] || fail "http://www.cullaapp.com/en/ answered $code; expected the default server to close the connection"
if c -o /dev/null "https://www.$H:$HTTPS/en/"; then fail "https://www.cullaapp.com/ completed a TLS handshake"; fi
security "page without www" "$S/en/"
security "HTTP redirect without www" "http://$H:$HTTP/en/"
security "acme challenge without www" "http://$H:$HTTP/.well-known/acme-challenge/test-token"
[ "$(status_of "$S/en/")" = 200 ] || fail "page without www"
sed 's/#.*//' "$work/conf-nowww.d/cullaapp.com.conf" | grep -q 'www\.cullaapp\.com' && fail "the no-www configuration names www.cullaapp.com"
sleep 1
python3 - "$work/log2" <<'EOF' || fail "access.log lines are not as expected (no-www run)"
import json, sys
lines = 0
for line in open(sys.argv[1] + "/access.log", encoding="utf-8"):
    assert json.loads(line)["ip"] == "127.0.0.1", line
    lines += 1
assert lines, "nothing logged"
EOF
ok "without www: cullaapp.com works as before; www.cullaapp.com is left to the host's default servers (challenges answered, otherwise closed, TLS refused)"

printf '\n%d checks passed against %s\n' "$pass" "$IMAGE"

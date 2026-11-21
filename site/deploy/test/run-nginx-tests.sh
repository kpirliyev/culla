#!/usr/bin/env bash
# Tests the real nginx behaviour of cullaapp.com.conf and the bootstrap
# config in a throwaway podman container (official nginx image), with a
# self-signed certificate and a fixture web root. Needs podman (on a Mac, a
# running podman machine) and network access to pull the image the first time.
#
#   site/deploy/test/run-nginx-tests.sh
#   CULLA_NGINX_IMAGE=docker.io/library/nginx:1.24 site/deploy/test/run-nginx-tests.sh
#
# Exit status: 0 all passed, 1 a check failed, 2 skipped (podman not usable).
# Ports 18080 and 18443 on 127.0.0.1 are used while it runs.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deploy="$(dirname "$here")"
# Fully qualified, so podman never asks which registry to pull from.
IMAGE="${CULLA_NGINX_IMAGE:-docker.io/library/nginx:1.26}"
NAME="culla-nginx-test-$$"
HTTP=18080
HTTPS=18443

if ! command -v podman >/dev/null || ! podman info >/dev/null 2>&1; then
    echo "SKIPPED: podman is missing or not running (on a Mac: podman machine start); nginx behaviour is untested." >&2
    exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/culla-nginx-test.XXXXXX")"
cleanup() {
    podman rm -f "$NAME" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$*"; }
fail() {
    printf 'FAIL %s\n' "$*" >&2
    echo "--- container log" >&2; podman logs "$NAME" 2>&1 | tail -20 >&2 || true
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
mkdir -p "$w/_nuxt"
head -c 30000 /dev/zero | tr '\0' 'a' > "$w/_nuxt/app.abc123.js"
gzip -k -9 "$w/_nuxt/app.abc123.js"
chmod -R a+rX "$work"
chmod 777 "$work/bootlog" "$work/log" "$work/log2"

# /etc/nginx/cullaapp is writable only so that the container itself can put
# download-target.conf in place and take it away again (see install_target).
mounts=(-v "$fx/nginx.conf:/etc/nginx/nginx.conf:ro"
        -v "$work/snippets:/etc/nginx/snippets:ro"
        -v "$work/letsencrypt:/var/www/letsencrypt:ro"
        -v "$work/cullaapp:/etc/nginx/cullaapp"
        -v "$work/targets:/test/targets:ro"
        -v "$work/tls:/test/tls:ro"
        -v "$work/www:/data/cullaapp.com/www:ro")
# nginx -t and the bootstrap config log into bootlog/, each full config into
# a fresh folder. One folder emptied with rm between two runs does not work
# under a podman machine: once the host deletes a file the VM created, the VM
# cannot create a file of that name again, and nginx fails to open its logs.
log="$work/bootlog"

podman pull -q "$IMAGE" >/dev/null

# --- nginx -t: the host's stand-in files plus each variant of Culla's ---------

nginx_t() {  # nginx_t <conf dir> <what>
    podman run --rm --sysctl net.ipv6.conf.all.disable_ipv6=0 "${mounts[@]}" \
        -v "$log:/data/cullaapp.com/log" -v "$1:/etc/nginx/conf.d:ro" "$IMAGE" nginx -t >"$work/nginx-t.out" 2>&1 \
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

start() {  # start <conf dir>; logs go to $log
    podman rm -f "$NAME" >/dev/null 2>&1 || true
    podman run -d --name "$NAME" --sysctl net.ipv6.conf.all.disable_ipv6=0 \
        -p "127.0.0.1:$HTTP:80" -p "127.0.0.1:$HTTPS:443" \
        "${mounts[@]}" -v "$log:/data/cullaapp.com/log" -v "$1:/etc/nginx/conf.d:ro" "$IMAGE" >/dev/null
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
c() {  # curl against the container as if it were the real host names
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
grep -q '"ip":"[0-9.]*\.0"' "$log/access.log" || fail "bootstrap: no shortened address in access.log"
ok "bootstrap config (with www) serves HTTP for both names, answers challenges from the host's webroot and logs shortened addresses"
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
# Each step gets a fresh stand-in root (a copy of the one before), and the
# container copies or removes download-target.conf itself: under a podman
# machine, once the host deletes a file the VM has seen, the VM does not see
# a new file of that name, so the host must never delete and recreate one.
GITHUB_URL="https://github.com/kpirliyev/culla/releases/download/v1.0/Culla-1.0.dmg"
step=0
install_target() {  # install_target <remote-install.sh download-target arguments>
    step=$((step + 1))
    if [ "$step" = 1 ]; then mkdir -p "$work/targets/$step"
    else cp -R "$work/targets/$((step - 1))" "$work/targets/$step"; fi
    CULLA_ROOT="$work/targets/$step" CULLA_SUDO="" CULLA_NGINX=true CULLA_SYSTEMCTL=true \
        bash "$deploy/remote-install.sh" download-target "$@" >/dev/null
    chmod -R a+rX "$work/targets/$step"
    podman exec "$NAME" sh -c "
        rm -f /etc/nginx/cullaapp/download-target.conf
        f=/test/targets/$step/etc/nginx/cullaapp/download-target.conf
        if [ -f \"\$f\" ]; then cp \"\$f\" /etc/nginx/cullaapp/; fi
        nginx -s reload" 2>/dev/null || fail "nginx did not reload after download-target $*"
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
day="$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["time"][:10])' "$work/log/access.log")"
CULLA_LOG_DIR="$work/log" CULLA_STATS_DIR="$work/stats" PYTHONDONTWRITEBYTECODE=1 \
    python3 "$deploy/count.py" --date "$day" --releases-file "$here/fixtures/github-releases.json"
grep -q "^$day,en,1," "$work/stats/visits.csv" || fail "visits.csv: $(cat "$work/stats/visits.csv")"
grep -q ",v1.0,Culla-1.0.dmg,57,57$" "$work/stats/downloads.csv" || fail "downloads.csv: $(cat "$work/stats/downloads.csv")"
ok "count.py counts the visit from the real access.log and the downloads from GitHub's answer"

# No full client address anywhere on disk.
python3 - "$work/log" <<'EOF' || fail "a full client address was written to a log"
import glob, json, re, sys
shorts = set()
for path in glob.glob(sys.argv[1] + "/*.log"):
    if path.endswith("error.log"):
        continue
    for line in open(path, encoding="utf-8"):
        ip = json.loads(line)["ip"]
        assert re.match(r"^(\d+\.\d+\.\d+\.0|[0-9a-f:]*::|-)$", ip), (path, ip)
        shorts.add(ip)
assert shorts, "no addresses logged"
files = sorted(glob.glob(sys.argv[1] + "/*"))
assert any(p.endswith("/error.log") for p in files), "error.log was not created"
text = "".join(open(p, encoding="utf-8", errors="replace").read() for p in files)
print("files checked:", ", ".join(p.rsplit("/", 1)[1] for p in files))
for ip in shorts:
    if ip.endswith(".0"):
        prefix = re.escape(ip[:-1])
        found = re.findall(prefix + r"(?:[1-9]\d{0,2})\b", text)
        assert not found, found
print("addresses logged:", ", ".join(sorted(shorts)))
EOF
files="$(ls "$work/log" | tr '\n' ' ')"
[ "$files" = "access.log error.log " ] || fail "unexpected log files: $files"
ok "only access.log and error.log are written, and neither holds a full client address"

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
python3 - "$work/log2" <<'EOF' || fail "a full client address was written to a log (no-www run)"
import glob, json, re, sys
for path in glob.glob(sys.argv[1] + "/access.log"):
    for line in open(path, encoding="utf-8"):
        ip = json.loads(line)["ip"]
        assert re.match(r"^(\d+\.\d+\.\d+\.0|[0-9a-f:]*::|-)$", ip), (path, ip)
EOF
ok "without www: cullaapp.com works as before; www.cullaapp.com is left to the host's default servers (challenges answered, otherwise closed, TLS refused)"

printf '\n%d checks passed against %s\n' "$pass" "$IMAGE"

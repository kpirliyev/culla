#!/usr/bin/env bash
# One-time (and repeatable) setup of cullaapp.com on a server that may be
# shared with other sites. The owner runs it as root on the server, from an
# uploaded copy of site/deploy/:
#
#   sudo CULLA_DEPLOY_USER=<upload account> ./setup-host.sh
#
# Settings (environment):
#   CULLA_DEPLOY_USER    required: the account that uploads the site over SSH
#   CULLA_WITH_WWW       yes = also serve www.cullaapp.com (needs its DNS
#                        record first); default no
#   CULLA_PASSWORDLESS   yes = let CULLA_DEPLOY_USER run Culla's nginx
#                        installer with sudo and no password (see SETUP.md
#                        for what that allows); default no
#   CERTBOT_AGREE_TOS    yes = accept Let's Encrypt's terms; needed only when
#                        this host has no Let's Encrypt account yet
#   CERTBOT_EMAIL        optional address for Let's Encrypt's expiry notices
#                        when a new account is made
#
# It follows the host's conventions and leaves the host's own files alone:
# nginx.conf, conf.d/00-default.conf (TLS settings and the default servers),
# /etc/nginx/snippets/acme-challenge.conf, other sites' files, the certbot
# crontab line and renewal hook. If the acme snippet or the default servers
# are missing it stops instead of making its own.
#
# What it does, in order (every step is skipped when already done):
#   1. checks, without changing anything: root, the settings, nginx 1.25.1
#      or later, certbot, python3, the acme snippet and its webroot, the
#      host's default servers on 80 and 443 (and whether they listen on
#      IPv6, which Culla then follows), a Let's Encrypt account or
#      CERTBOT_AGREE_TOS=yes when a certificate is needed
#   2. apt-get install -y rsync, if rsync is missing
#   3. /data/cullaapp.com/www (the upload account), log and stats (root:adm,
#      0750); /data/cullaapp.com/ssl is left as it is
#   4. /etc/cullaapp/host.conf: www=..., ipv6=... (read by the installer)
#   5. no certificate yet: the HTTP-only configuration (remote-install.sh
#      bootstrap: nginx -t, reload), then certbot certonly --webroot; a
#      certificate without www.cullaapp.com while www is wanted: certbot
#      certonly --webroot --expand
#   6. the full configuration, snippets and error pages (remote-install.sh
#      nginx: nginx -t, reload, its own files put back if the test fails)
#   7. the logrotate rule and count.py
#   8. the count.py line in root's crontab
#   9. only with CULLA_PASSWORDLESS=yes: /usr/local/sbin/cullaapp-install
#      and /etc/sudoers.d/cullaapp (checked with visudo -cf first)
#
# Test hooks (used by test/run-deploy-tests.sh, never on a server):
#   CULLA_SETUP_TEST=1   allow running without root; needs CULLA_ROOT
#   CULLA_ROOT           prefixes every system path
#   CULLA_RSYNC          the command checked for "rsync is installed"

set -euo pipefail
umask 022

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die()  { printf 'setup-host: %s\n' "$*" >&2; exit 1; }
say()  { printf 'setup-host: %s\n' "$*"; }
done_list=()
did()  { done_list+=("$*"); say "$*"; }

# --- 1. Checks (nothing is changed before they all pass) ---------------------

if [ "${CULLA_SETUP_TEST:-0}" = 1 ]; then
    ROOT="${CULLA_ROOT:?CULLA_SETUP_TEST needs CULLA_ROOT}"
    TESTING=1
else
    [ "$(id -u)" = 0 ] || die "run it as root: sudo CULLA_DEPLOY_USER=<account> $0"
    ROOT=""
    TESTING=0
fi

USER_NAME="${CULLA_DEPLOY_USER:-}"
[ -n "$USER_NAME" ] || die "set CULLA_DEPLOY_USER to the account that uploads the site"
[[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
    || die "CULLA_DEPLOY_USER must be a plain account name (lower-case letters, digits, _ and -)"
id -u "$USER_NAME" >/dev/null 2>&1 || die "there is no account called $USER_NAME"
[ "$USER_NAME" != root ] || die "CULLA_DEPLOY_USER must not be root"
USER_GROUP="$(id -gn "$USER_NAME")"

yes_no() {  # yes_no <variable name> <value>
    case "$2" in yes|no) ;; *) die "$1 must be yes or no, not \"$2\"" ;; esac
}
WITH_WWW="${CULLA_WITH_WWW:-no}";            yes_no CULLA_WITH_WWW "$WITH_WWW"
PASSWORDLESS="${CULLA_PASSWORDLESS:-no}";    yes_no CULLA_PASSWORDLESS "$PASSWORDLESS"
AGREE_TOS="${CERTBOT_AGREE_TOS:-no}";        yes_no CERTBOT_AGREE_TOS "$AGREE_TOS"
EMAIL="${CERTBOT_EMAIL:-}"
if [ -n "$EMAIL" ] && ! [[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    die "CERTBOT_EMAIL does not look like an address"
fi

for command in nginx certbot python3 crontab; do
    command -v "$command" >/dev/null || die "$command is not installed"
done
[ "$PASSWORDLESS" = no ] || command -v visudo >/dev/null || die "visudo is not installed (package sudo)"

nginx_version="$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9][0-9.]*\).*#\1#p')"
python3 -c 'import sys; v = [int(p) for p in sys.argv[1].split(".")]; sys.exit(0 if v >= [1, 25, 1] else 1)' \
    "${nginx_version:-0}" 2>/dev/null \
    || die "nginx ${nginx_version:-of unknown version} is older than 1.25.1, which \"http2 on;\" needs (see SETUP.md)"

ACME_SNIPPET="$ROOT/etc/nginx/snippets/acme-challenge.conf"
WEBROOT="$ROOT/var/www/letsencrypt"
[ -f "$ACME_SNIPPET" ] || die "the host has no $ACME_SNIPPET; set up the host's certificate challenges first"
[ -d "$WEBROOT" ] || die "the host has no $WEBROOT for certbot --webroot"

# The host's default servers: listen lines with default_server in any
# configuration other than Culla's.
host_files=()
for f in "$ROOT"/etc/nginx/conf.d/*.conf "$ROOT"/etc/nginx/sites-enabled/*; do
    [ -f "$f" ] && [ "$(basename "$f")" != cullaapp.com.conf ] && host_files+=("$f")
done
defaults=""
[ ${#host_files[@]} = 0 ] || defaults="$(grep -hE '^[[:space:]]*listen[[:space:]][^#;]*default_server' "${host_files[@]}" || true)"
grep -Eq 'listen[[:space:]]+([^[:space:];]*:)?80[[:space:];]' <<<"$defaults" \
    || die "no default server on port 80 found in the host's nginx files; set one up first"
grep -Eq 'listen[[:space:]]+([^[:space:];]*:)?443[[:space:];]' <<<"$defaults" \
    || die "no default server on port 443 found in the host's nginx files; set one up first"
if grep -Eq 'listen[[:space:]]+\[::\]:80[[:space:];]' <<<"$defaults"; then WITH_IPV6=yes; else WITH_IPV6=no; fi

LIVE="$ROOT/etc/letsencrypt/live/cullaapp.com"
cert_action=none
if [ ! -f "$LIVE/fullchain.pem" ]; then
    cert_action=new
elif [ "$WITH_WWW" = yes ]; then
    domains="$(certbot certificates --cert-name cullaapp.com 2>/dev/null | sed -n 's/^ *Domains: //p')"
    grep -qw 'www\.cullaapp\.com' <<<"$domains" || cert_action=expand
fi
certbot_args=(certonly --webroot -w "$WEBROOT" --cert-name cullaapp.com -d cullaapp.com)
[ "$WITH_WWW" = yes ] && certbot_args+=(-d www.cullaapp.com)
certbot_args+=(--non-interactive)
[ "$cert_action" = expand ] && certbot_args+=(--expand)
if [ "$cert_action" != none ]; then
    if compgen -G "$ROOT/etc/letsencrypt/accounts/*/directory/*/regr.json" >/dev/null; then
        say "a Let's Encrypt account exists on this host; it is used"
    elif [ "$AGREE_TOS" = yes ]; then
        certbot_args+=(--agree-tos)
        if [ -n "$EMAIL" ]; then certbot_args+=(--email "$EMAIL"); else certbot_args+=(--register-unsafely-without-email); fi
    else
        die "a certificate is needed and this host has no Let's Encrypt account: read Let's Encrypt's terms and run again with CERTBOT_AGREE_TOS=yes (and CERTBOT_EMAIL=<address> if you want expiry notices)"
    fi
fi

SBIN="$ROOT/usr/local/sbin"
SUDOERS_D="$ROOT/etc/sudoers.d"
if [ "$PASSWORDLESS" = yes ]; then
    [ -d "$SBIN" ] && [ ! -L "$SBIN" ] || die "$SBIN is missing or a symbolic link"
    if [ -n "$(find "$SBIN" -maxdepth 0 \( -perm -0020 -o -perm -0002 \))" ]; then
        die "$SBIN can be written by others than root; the installer cannot be kept there safely"
    fi
    if [ "$TESTING" = 0 ] && [ "$(stat -c %u "$SBIN")" != 0 ]; then die "$SBIN does not belong to root"; fi
    [ -d "$SUDOERS_D" ] || die "$SUDOERS_D is missing (is sudo installed and does /etc/sudoers read it?)"
fi

say "checks passed (www: $WITH_WWW, IPv6 like the host's default servers: $WITH_IPV6, certificate: $cert_action)"

# --- 2. rsync ------------------------------------------------------------------

if ! command -v "${CULLA_RSYNC:-rsync}" >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends rsync \
        || { apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends rsync; }
    did "installed rsync (deploy.sh uploads the site with it)"
fi

# --- 3. Folders ----------------------------------------------------------------

DATA="$ROOT/data/cullaapp.com"
install -d -m 755 "$DATA/www" "$DATA/log" "$DATA/stats"
# The site: written by the upload account, read by everyone.
chown -R "$USER_NAME:$USER_GROUP" "$DATA/www"
chmod 755 "$DATA/www"
# The logs: opened by nginx's master process (root), which hands them to
# its workers; readable by adm, not by others. Owned by root and writable
# only by root, as logrotate requires of a folder it rotates in.
chown root:adm "$DATA/log"
chmod 750 "$DATA/log"
# The counts: written by root's cron, readable by adm.
chown root:adm "$DATA/stats"
chmod 750 "$DATA/stats"
say "folders: $DATA/www for $USER_NAME, $DATA/log and $DATA/stats root:adm 0750"
if [ -n "$(find "$DATA" -maxdepth 0 \( -perm -0020 -o -perm -0002 \))" ]; then
    say "WARNING: $DATA itself can be written by its group or by everyone; whoever can write"
    say "         there can replace log/ with a link. Consider: chown root:root $DATA && chmod 755 $DATA"
fi

# --- 4. Settings for the installer --------------------------------------------

install -d -m 755 "$ROOT/etc/cullaapp"
settings="$(printf '# Written by setup-host.sh; read by remote-install.sh.\nwww=%s\nipv6=%s\n' "$WITH_WWW" "$WITH_IPV6")"
if [ "$(cat "$ROOT/etc/cullaapp/host.conf" 2>/dev/null || true)" != "$settings" ]; then
    printf '%s\n' "$settings" > "$ROOT/etc/cullaapp/host.conf"
    chmod 644 "$ROOT/etc/cullaapp/host.conf"
    chown root:root "$ROOT/etc/cullaapp/host.conf"
    did "wrote /etc/cullaapp/host.conf (www=$WITH_WWW, ipv6=$WITH_IPV6)"
fi

installer() {  # installer <mode> <args>: Culla's installer, as root
    env -u CULLA_NGINX -u CULLA_SYSTEMCTL \
        CULLA_ROOT="$ROOT" CULLA_SUDO="" CULLA_WITH_WWW="$WITH_WWW" CULLA_WITH_IPV6="$WITH_IPV6" \
        bash "$here/remote-install.sh" "$@"
}

# --- 5. Certificate ------------------------------------------------------------

if [ "$cert_action" = new ]; then
    installer bootstrap "$here" || die "the HTTP-only configuration did not pass nginx -t; nothing else was changed"
    did "installed the HTTP-only configuration for the first certificate"
fi
if [ "$cert_action" != none ]; then
    say "certbot ${certbot_args[*]}"
    certbot "${certbot_args[@]}" || die "certbot did not get the certificate (see /var/log/letsencrypt/letsencrypt.log)"
    [ -f "$LIVE/fullchain.pem" ] || die "certbot finished but $LIVE/fullchain.pem is missing"
    did "certificate for cullaapp.com$([ "$WITH_WWW" = yes ] && echo ' and www.cullaapp.com') ($cert_action)"
fi

# --- 6. Full configuration ----------------------------------------------------

result="$(installer nginx "$here")" \
    || { printf '%s\n' "$result"; die "the full configuration did not pass nginx -t and was rolled back; nginx runs as before"; }
printf '%s\n' "$result"
if grep -q "nothing changed" <<<"$result"; then
    say "the full nginx configuration is already in place"
else
    did "full nginx configuration, snippets and error pages in place (nginx -t passed, reloaded)"
fi

# --- 7. Logrotate rule and count.py -------------------------------------------

put_root() {  # put_root <mode> <source> <destination>
    if [ -f "$3" ] && cmp -s "$2" "$3"; then return 0; fi
    install -d -m 755 "$(dirname "$3")"
    install -m "$1" "$2" "$3"
    chown root:root "$3"
    did "installed ${3#"$ROOT"}"
}
put_root 644 "$here/logrotate.conf" "$ROOT/etc/logrotate.d/cullaapp.com"
put_root 755 "$here/count.py" "$ROOT/usr/local/lib/cullaapp/count.py"

# --- 8. Crontab ------------------------------------------------------------------

cron_line="$(grep -E '^[^#].*/usr/local/lib/cullaapp/count\.py' "$here/crontab.txt")"
current="$(crontab -l 2>/dev/null || true)"
if ! grep -qF '/usr/local/lib/cullaapp/count.py' <<<"$current"; then
    if [ -n "$current" ]; then printf '%s\n%s\n' "$current" "$cron_line"; else printf '%s\n' "$cron_line"; fi | crontab -
    did "added the count.py line to root's crontab"
fi

# --- 9. Password-free installs (only when asked for) ----------------------------

if [ "$PASSWORDLESS" = yes ]; then
    tmp_installer="$(mktemp "$SBIN/.cullaapp-install.XXXXXX")"
    tmp_sudoers="$(mktemp "$SUDOERS_D/.cullaapp.XXXXXX")"   # a name with a dot is never read by sudo
    trap 'rm -f "$tmp_installer" "$tmp_sudoers"' EXIT

    # The root-owned copy ignores every test hook and every setting from the caller.
    sed 's/^CULLA_HOOKS=yes$/CULLA_HOOKS=no/' "$here/remote-install.sh" > "$tmp_installer"
    grep -qx 'CULLA_HOOKS=no' "$tmp_installer" && ! grep -qx 'CULLA_HOOKS=yes' "$tmp_installer" \
        || die "could not switch off the test hooks in the installer copy"
    chmod 755 "$tmp_installer"
    chown root:root "$tmp_installer"
    if cmp -s "$tmp_installer" "$SBIN/cullaapp-install" 2>/dev/null; then
        rm -f "$tmp_installer"
    else
        mv -f "$tmp_installer" "$SBIN/cullaapp-install"
        did "installed /usr/local/sbin/cullaapp-install (root:root 0755)"
    fi

    printf '# Written by setup-host.sh: %s may run Culla'"'"'s nginx installer as root without a password.\n%s ALL=(root) NOPASSWD: /usr/local/sbin/cullaapp-install\n' \
        "$USER_NAME" "$USER_NAME" > "$tmp_sudoers"
    chmod 440 "$tmp_sudoers"
    chown root:root "$tmp_sudoers"
    visudo -cf "$tmp_sudoers" >/dev/null || die "visudo rejected the sudoers rule; nothing was installed in $SUDOERS_D"
    if cmp -s "$tmp_sudoers" "$SUDOERS_D/cullaapp" 2>/dev/null; then
        rm -f "$tmp_sudoers"
    else
        mv -f "$tmp_sudoers" "$SUDOERS_D/cullaapp"
        did "installed /etc/sudoers.d/cullaapp (root:root 0440): $USER_NAME ALL=(root) NOPASSWD: /usr/local/sbin/cullaapp-install"
    fi
elif [ -e "$SBIN/cullaapp-install" ] || [ -e "$SUDOERS_D/cullaapp" ]; then
    say "note: password-free installs were set up earlier and are left as they are;"
    say "      to end them: rm /etc/sudoers.d/cullaapp /usr/local/sbin/cullaapp-install"
fi

# --- Summary -------------------------------------------------------------------

echo
if [ ${#done_list[@]} = 0 ]; then
    say "nothing needed changing"
else
    say "done:"
    for line in "${done_list[@]}"; do printf '  - %s\n' "$line"; done
fi
cat <<EOF

Check now (see SETUP.md, "Check that everything works"):
  nginx -t
  curl -sI http://cullaapp.com/          (301 to https://cullaapp.com/)
  curl -sI https://cullaapp.com/download (503 until a release is published)
  certbot renew --dry-run                (the host's renewal also covers cullaapp.com)
  crontab -l                             (one count.py line, the host's certbot line unchanged)
Then, on the Mac: site/deploy/deploy.sh uploads the site as $USER_NAME.
EOF

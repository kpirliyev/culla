# Setting up the server for cullaapp.com

The server holds the site and its logs, nothing else. The disk images are
assets of the releases on GitHub (`kpirliyev/culla`), and
`https://cullaapp.com/download` is a short link that redirects there. The
server makes one outbound request a day, to `api.github.com`, to note how
often each disk image has been downloaded; nothing a visitor sends is
stored except the access log, kept 30 days (see the end).

The server may be shared with other sites. Culla adds its own files and
leaves the host's alone: `nginx.conf`, `conf.d/00-default.conf` (TLS
settings and the default servers), `/etc/nginx/snippets/acme-challenge.conf`,
other sites' files, and the host's `certbot renew` crontab line and renewal
hook.

On the Mac, the commands below run from the repository folder with the
server's address and the upload account in the environment (never written
into the repository). The Mac needs podman with its machine running
(`podman machine start`) for the build, and ssh and rsync for the upload:

```bash
export CULLA_DEPLOY_HOST=<server address>
export CULLA_DEPLOY_USER=<upload account>
export CULLA_DEPLOY_PORT=22                  # only if SSH is on another port
export CULLA_DEPLOY_KEY=$HOME/.ssh/<key>     # only to use one particular key
```

## What the host must have

`setup-host.sh` checks these and stops, changing nothing, if one is missing:

- nginx 1.25.1 or newer (the configuration uses `http2 on;`), certbot,
  python3. On an older nginx, change `listen 443 ssl;` plus `http2 on;` to
  `listen 443 ssl http2;` in every HTTPS server of `cullaapp.com.conf` and
  remove the version check in `setup-host.sh`.
- `/etc/nginx/snippets/acme-challenge.conf`, serving
  `/.well-known/acme-challenge/` from `/var/www/letsencrypt`.
- Default servers for unknown names on ports 80 and 443 (in `conf.d/` or
  `sites-enabled/`). Culla declares none. If they also listen on `[::]`,
  Culla does too; otherwise it listens on IPv4 only.
- The host's own renewal: `certbot renew` from cron or a timer, and a
  renewal hook that reloads nginx.
- DNS: `cullaapp.com` points at the server. Add `www.cullaapp.com` only once
  it has a record too.

On a server of its own, the stand-ins in `site/deploy/test/fixtures/host/`
(`00-default.conf`, `acme-challenge.conf`) show what those two host files
hold; put them in place, adjust, and continue below.

## First-time setup

1. **Copy the files to the server** (nothing is installed yet; rsync may be
   missing, so this uses tar over SSH):
   ```bash
   site/deploy/deploy.sh --upload-setup        # to ~/cullaapp-setup on the server
   ```
2. **On the server, read `setup-host.sh`, then run it.** It lists every step
   at its top and prints what it did at the end. It is safe to run again: a
   step that is already done is skipped.
   ```bash
   cd ~/cullaapp-setup
   sudo CULLA_DEPLOY_USER=<upload account> ./setup-host.sh
   ```
   Add to the same line as needed:
   - `CERTBOT_AGREE_TOS=yes` the first time, if this host has no Let's
     Encrypt account yet: it means you accept Let's Encrypt's terms. Add
     `CERTBOT_EMAIL=<address>` for expiry notices; without it the account is
     made without an address. With an existing account neither is needed.
   - `CULLA_WITH_WWW=yes` to serve `www.cullaapp.com` as a redirect (needs
     its DNS record first). It adds the name to the certificate and the www
     server to the configuration. The choice is kept in
     `/etc/cullaapp/host.conf` until the script runs again.
   - `CULLA_PASSWORDLESS=yes` for password-free nginx changes later (below).
3. **Upload the site, from the Mac:**
   ```bash
   site/test.sh                # optional first: build and every test, in podman
   site/deploy/deploy.sh
   ```
   `deploy.sh` builds the site in a podman container first, exactly as
   `site/test.sh build` does (it needs the podman machine running:
   `podman machine start`), then uploads `site/.output/public/` with rsync
   over SSH from the Mac. The Mac's own Node is never used.

What `setup-host.sh` does, in order, as root:

1. The checks above; nothing changes before they pass.
2. `apt-get install -y --no-install-recommends rsync` if rsync is missing.
3. `/data/cullaapp.com/www` owned by the upload account (mode 755);
   `/data/cullaapp.com/log` and `/data/cullaapp.com/stats` owned by
   `root:adm`, mode 750 (nginx's master process opens the logs as root;
   logrotate refuses a folder others can write to). `ssl/` is left as it is.
   It warns when `/data/cullaapp.com` itself can be written by its group.
4. Writes `/etc/cullaapp/host.conf` (`www=` and `ipv6=`).
5. Without a certificate: installs the HTTP-only configuration (which
   includes the acme snippet), `nginx -t`, reload, then
   `certbot certonly --webroot -w /var/www/letsencrypt --cert-name cullaapp.com -d cullaapp.com --non-interactive`
   (with `-d www.cullaapp.com` for www, and `--agree-tos` plus `--email` or
   `--register-unsafely-without-email` only when there is no account yet).
   With a certificate that lacks www while www is wanted: the same with
   `--expand`.
6. Installs the full configuration, snippets and error pages through
   `remote-install.sh nginx`: backups in `/var/backups/cullaapp/`, then
   `nginx -t`, and a reload only if it passes. If it fails, Culla's files
   are put back and nginx keeps running as before, other sites included.
7. Installs `/etc/logrotate.d/cullaapp.com` and
   `/usr/local/lib/cullaapp/count.py`.
8. Adds the line from `crontab.txt` to root's crontab, if it is not there.
   No certbot line: renewal is the host's.
9. Only with `CULLA_PASSWORDLESS=yes`: the installer copy and the sudoers
   rule (below).

## Later changes

- **The site:** `site/deploy/deploy.sh`. It needs no sudo, except when
  `/download` has to change (see the next section).
- **Culla's nginx files** (`cullaapp.com.conf`, `snippets/`, `errors/`):
  `site/deploy/deploy.sh --nginx`.
- **`count.py`, the logrotate rule, the crontab line, www on or off:**
  `deploy.sh --upload-setup`, then `setup-host.sh` again on the server.

Both `--nginx` and a `/download` change need root on the server. With
password-free installs set up, `deploy.sh` uses them; otherwise it opens
`ssh -t` and sudo asks for your password.

### Password-free nginx changes

With `CULLA_PASSWORDLESS=yes`, `setup-host.sh` installs a copy of
`remote-install.sh` as `/usr/local/sbin/cullaapp-install` (root:root, 0755,
with its test hooks switched off) and `/etc/sudoers.d/cullaapp`
(root:root, 0440, checked with `visudo -cf` before it is put in place):

```
<upload account> ALL=(root) NOPASSWD: /usr/local/sbin/cullaapp-install
```

That copy installs only `/etc/nginx/conf.d/cullaapp.com.conf` and files under
`/etc/nginx/cullaapp/`, or writes and removes the `/download` target, always
with a backup, `nginx -t`, rollback and reload. It refuses symbolic links,
unexpected file names and files of other users, and accepts only a fixed
list of nginx directives, with logs only under `/data/cullaapp.com/log/`,
`root` and `alias` only under `/data/cullaapp.com/www` or
`/etc/nginx/cullaapp/`, and `include` only of Culla's snippets and the
host's acme snippet (the full list is at the top of `remote-install.sh`).
It never installs anything root later runs; `count.py`, the logrotate rule
and the crontab stay with `setup-host.sh`.

**What this allows, honestly.** Whoever holds the upload account's SSH key
can, without any password, change how nginx serves cullaapp.com: send its
visitors elsewhere, serve other pages under its name, switch the site off,
make nginx reload, or install a configuration that passes the checks but
breaks cullaapp.com. They cannot, as far as the checks reach, make nginx
read or write files outside Culla's folders, touch other sites' files, or
run programs as root. This is weaker than asking for a password: a stolen
key is enough. A mistake in the installer's checks would be root access. To
end it: `sudo rm /etc/sudoers.d/cullaapp /usr/local/sbin/cullaapp-install`.

## /download and site/release.json

`site/release.json` names the newest release:

```json
{ "repository": "kpirliyev/culla", "version": "1.0", "minimumSystem": "26.0", "file": "Culla-1.0.dmg", "size": 0, "sha256": "", "date": "" }
```

While `date` is empty, `https://cullaapp.com/download` shows a small "not
available yet" page (503). Once the release is on GitHub (tag
`v<version>`, with `<file>` attached), fill in `date` (`YYYY-MM-DD`) and the
other values and run `deploy.sh`. It writes
`/etc/nginx/cullaapp/download-target.conf` (one line,
`return 302 https://github.com/<repository>/releases/download/v<version>/<file>;`)
only when it differs from what is there, and an empty `date` removes it
again. `deploy.sh` refuses anything other than `owner/name`, digits and dots
for the version and `minimumSystem`, and a plain `.dmg` name. It does not
check that the asset exists: open `https://cullaapp.com/download` afterwards.

The build also writes `/update.json` from it, the one file the app reads
from the internet to learn whether a newer version exists:
`{ "version": "1.0", "minimumSystem": "26.0", "date": "" }`. It is an
ordinary static file in the web root, served by `location /` with
`Cache-Control: no-cache`, so the nginx configuration has nothing of its own
for it. `deploy.sh` refuses a build whose `update.json` does not match
`release.json`. Check it with `curl -s https://cullaapp.com/update.json`.

## Check that everything works

1. `sudo nginx -t`: "syntax is ok" and "test is successful".
2. `sudo certbot renew --dry-run`: cullaapp.com is among the simulated renewals.
3. Addresses and headers:
   ```bash
   curl -sI http://cullaapp.com/            # 301 to https://cullaapp.com/
   curl -sI -H 'Accept-Language: ru-RU,ru;q=0.9' https://cullaapp.com/   # 302, Location: /ru/
   curl -sI https://cullaapp.com/en/ | grep -iE 'strict|content-security|nosniff|referrer'
   curl -sI https://www.cullaapp.com/       # with www: 301 to https://cullaapp.com/
   ```
4. `/download`: before a release `curl -sI https://cullaapp.com/download`
   answers 503; after one, 302 with
   `Location: https://github.com/kpirliyev/culla/releases/download/v<version>/<file>`.
5. The counts. Run the script once by hand (cron does the same every night;
   a second run on one day replaces that day's rows):
   ```bash
   sudo python3 /usr/local/lib/cullaapp/count.py
   sudo cat /data/cullaapp.com/stats/visits.csv      # <yesterday>,en,<visits>,<page views> ...
   sudo cat /data/cullaapp.com/stats/downloads.csv   # <today>,v1.0,Culla-1.0.dmg,<total>,<new>
   ```
   Before the first release `downloads.csv` holds only its header line.
6. `sudo logrotate -d /etc/logrotate.d/cullaapp.com`: prints what it would do
   and changes nothing; it must not say "insecure permissions".
7. The access log is one JSON object per line, with the visitor's address:
   `sudo tail -n 3 /data/cullaapp.com/log/access.log`.
8. `sudo crontab -l`: the host's certbot line as before, and one `count.py` line.

## What the logs keep, and for how long

All in `/data/cullaapp.com/log/`, rotated daily, kept 30 days (the newest
rotation stays plain as `.1`, older ones are `.N.gz`). Each line is one JSON
object.

| File | One line per | Fields |
| --- | --- | --- |
| `access.log` | page, asset or redirect (`/download` too) | time, IP address, host, method, path, status, bytes, referrer, browser |
| `error.log` | serious nginx error | nginx's own format |

**Address.** The access log keeps the visitor's IP address in full, as
nginx sees it (`$remote_addr`), like any web server's log. It is deleted
with the log after 30 days; the counts keep no addresses.

**error.log** is written at level `crit`, which keeps the everyday noise
out (missing files, closed connections, failed TLS handshakes). What
remains is rare and about the server itself. Requests for
names nginx does not serve are answered by the host's default servers and
logged in the host's own logs, not cullaapp.com's.

The counts in `/data/cullaapp.com/stats/` are kept for good; they hold
numbers, not addresses:

| File | One row per | Columns |
| --- | --- | --- |
| `visits.csv` | day and language | `date,lang,visits,page_views` |
| `downloads.csv` | day and disk image on GitHub | `date,tag,file,total,new` |

In `downloads.csv`, `total` is GitHub's own count of downloads so far and
`new` is the difference from the previous row for the same file, such as
`2026-11-21,v1.0,Culla-1.0.dmg,57,4`. If a disk image is replaced on GitHub
its count starts again from 0; `new` is then the new total, never negative.

## HSTS

The site sends `Strict-Transport-Security: max-age=2592000` (30 days),
without `includeSubDomains` and without `preload`. Once HTTPS has worked
without trouble for a few weeks, raise it in
`site/deploy/snippets/security-headers.conf` (for example to `31536000`, one
year) and run `deploy.sh --nginx`. Preloading is hard to undo; decide it
separately.

## Rolling back

- **nginx configuration.** Every install keeps the files it replaced in
  `/var/backups/cullaapp/<date-time>/`, under their full path:
  ```bash
  ls /var/backups/cullaapp/
  sudo cp -p /var/backups/cullaapp/<date-time>/etc/nginx/conf.d/cullaapp.com.conf /etc/nginx/conf.d/
  sudo nginx -t && sudo systemctl reload nginx
  ```
  Or check out an earlier commit on the Mac and run `deploy.sh --nginx`.
- **The site.** Check out an earlier commit and run `deploy.sh`.
- **A release.** Older releases stay on GitHub. Check out the earlier
  `site/release.json` and run `deploy.sh`.
- **Everything.** Remove `/etc/nginx/conf.d/cullaapp.com.conf`, then
  `sudo nginx -t && sudo systemctl reload nginx`; remove the `count.py` line
  from root's crontab, `/etc/logrotate.d/cullaapp.com`,
  `/usr/local/lib/cullaapp/`, `/etc/nginx/cullaapp/`, `/etc/cullaapp/` and,
  if set up, `/etc/sudoers.d/cullaapp` and `/usr/local/sbin/cullaapp-install`.
  The certificate (`sudo certbot delete --cert-name cullaapp.com`) and the
  files in `/data/cullaapp.com/` stay until you delete them.

## If something goes wrong

- **`setup-host.sh` stops.** Its last line says why; nothing after that step
  was changed. Fix the cause and run it again.
- **certbot fails.** `/var/log/letsencrypt/letsencrypt.log`. Usually DNS
  (`www.cullaapp.com` without a record) or the acme snippet not being served
  on port 80.
- **`/download` answers 404 from GitHub.** The release or its asset is not
  there under the name in `site/release.json`.
- **No downloads row for a day.** `journalctl -t cullaapp-count` says why
  (GitHub unreachable, rate limited, an error). The totals are cumulative,
  so the next day's row includes the missed day.

## The commands run as root

`setup-host.sh`, run by you, uses: `apt-get install`, `install`, `chown`,
`chmod`, `mv`, `crontab`, `certbot certonly`, `visudo -cf` (with
password-free installs) and, through `remote-install.sh`, `install`,
`cp -p`, `rm -f`, `tee`, `nginx -t` and `systemctl reload nginx`.

`deploy.sh` needs root only for `--nginx` and `/download` changes, through
`remote-install.sh` (sudo asks for the password over `ssh -t`) or
`sudo -n /usr/local/sbin/cullaapp-install`. Uploading the site needs no sudo:
the upload account owns `/data/cullaapp.com/www/`. A deploy removes anything
there that is not in the build, and never writes to or deletes from
`/data/cullaapp.com/log/`.

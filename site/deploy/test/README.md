# Tests for site/deploy

All run on the Mac, touch no server and use no network (except podman
pulling the nginx image the first time). Run them from the repository root.

| Command | What it checks | Needs |
| --- | --- | --- |
| `python3 -m unittest discover -s site/deploy/test` | `count.py`, and the nginx files without nginx | python3, bash |
| `site/deploy/test/run-deploy-tests.sh` | `deploy.sh`, `remote-install.sh` and `setup-host.sh` against temporary folders standing in for the server | bash, rsync, python3, tar |
| `site/deploy/test/run-nginx-tests.sh` | The real nginx behaviour in a throwaway container, on top of stand-ins for the host's files | podman (on a Mac, a running podman machine) |

`fixtures/host/` holds stand-ins for the shared host's own files
(`nginx.conf`, `conf.d/00-default.conf`, the acme-challenge snippet, another
site's configuration). They are used only by the tests and are never
installed.

- `test_count.py`: visits from `access.log` (page views, 304s, robots, IPv6,
  logs spread over `.log`, `.1` and `.2.gz`, a file seen twice during
  rotation, re-runs, `--backfill`); the GitHub snapshot in `downloads.csv`
  (the request's address and headers, only `.dmg` assets, new downloads
  since the previous row, two runs on one day, a count that went down, tags
  in version order, an old-format file set aside) and the soft failures
  (GitHub unreachable, timed out, rate limited, an HTTP error, an answer that
  is not a list of releases). GitHub's answer comes from a function passed to
  `count.main()` or from `fixtures/github-releases.json`.
- `test_nginx_conf.py`: the address-shortening and language maps, the exact
  CSP, the security headers in every block with its own `add_header`; for
  every variant (www and IPv6 on and off) of both configurations, as
  `remote-install.sh` renders them: the listen lines, `http2 on;`, the
  server names, the acme snippet in the port-80 server, no `default_server`,
  and nothing at http level but maps, the log format and servers; `tls.conf`
  holds only the certificate.
- `run-deploy-tests.sh`:
  - `deploy.sh`: `--check` changes nothing; stale files go; incomplete
    builds are refused; `/download` follows `release.json`; bad values are
    refused; over (stand-in) ssh with `CULLA_DEPLOY_KEY`, every ssh and rsync
    call carries `-i <key> -o IdentitiesOnly=yes`; `--upload-setup`; with the
    password-free installer, `/download` and `--nginx` go through it.
  - `remote-install.sh`: `--nginx` installs only Culla's nginx files,
    rendered from `/etc/cullaapp/host.conf`, skips unchanged files and rolls
    back on a failing `nginx -t`; it refuses 31 kinds of forbidden directive
    or path, symbolic links in the stage and at the destination, unexpected
    names, big and non-regular files, changing nothing.
  - `setup-host.sh` in a stand-in host (apt-get, certbot, nginx, systemctl,
    crontab, chown and visudo stubbed): its refusals (no root, no or a bad
    `CULLA_DEPLOY_USER`, no account without `CERTBOT_AGREE_TOS=yes`, old
    nginx, no acme snippet, no default servers) change nothing; the first
    run; a second run that changes nothing; www added later; rollback; the
    password-free installer and sudoers rule (content, modes, owners, no
    leftovers when visudo rejects it, none without `CULLA_PASSWORDLESS=yes`);
    the host's and the other site's files byte-for-byte unchanged.
- `run-nginx-tests.sh`: `nginx -t` with the host's stand-ins and every
  variant of Culla's files; certificate challenges on port 80 for
  cullaapp.com and www.cullaapp.com (bootstrap and full configuration, with
  and without www, where the host's default server answers); language
  redirects; security headers on pages, assets, redirects, challenges and
  error pages; caching and `gzip_static`; the removed addresses answer 404;
  `/download` before and after a release; `count.py` on the real
  `access.log`; only `access.log` and `error.log`, without a full client
  address. Exits 2 and prints `SKIPPED` when podman is missing or not running
  (on a Mac, run `podman machine start`). Set `CULLA_NGINX_IMAGE` to try
  another nginx version (default `docker.io/library/nginx:1.26`).

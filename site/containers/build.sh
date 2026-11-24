#!/usr/bin/env bash
# Builds the site inside the Node container that site/test.sh starts, then
# checks the result. Not meant to be run by hand: run `site/test.sh build`.
#
# The working folder is site/ of the repository, mounted at the same path as
# on the Mac, so .output/public/ lands where deploy.sh expects it.
# node_modules/ is a podman volume over site/node_modules (the Mac's own
# folder is hidden, never read or written) and ~/.npm is another, so a
# second build neither downloads nor installs anything.

set -euo pipefail

[ "${CULLA_IN_CONTAINER:-}" = 1 ] || { echo "build: run site/test.sh build instead" >&2; exit 2; }

say() { printf 'build: %s\n' "$*"; }
fail() { printf 'build: FAIL %s\n' "$*" >&2; exit 1; }

# --- Dependencies ----------------------------------------------------------

# npm ci only when package-lock.json or Node changed since the last install
# into this volume.
stamp=node_modules/.culla-installed
want="$(sha256sum package-lock.json | cut -d' ' -f1) node-$(node -v) $(uname -m)"
if [ "$(cat "$stamp" 2>/dev/null || true)" = "$want" ]; then
    say "node_modules is up to date with package-lock.json (Node $(node -v))"
else
    say "npm ci (Node $(node -v), npm $(npm -v))"
    npm ci --no-audit --no-fund --loglevel=error
    printf '%s\n' "$want" > "$stamp"
fi

# --- Build -----------------------------------------------------------------

say "npm run generate"
npm run generate

# --- Checks ----------------------------------------------------------------

out=.output/public
missing=0
for f in index.html en/index.html ru/index.html tk/index.html 404.html \
         sitemap.xml robots.txt update.json \
         favicon.ico favicon-32.png apple-touch-icon.png icon-64.png icon-128.png \
         icon-192.png icon-512.png og-image.png; do
    if [ ! -s "$out/$f" ]; then
        printf 'build: missing from the build: %s\n' "$out/$f" >&2
        missing=1
    fi
done
[ "$missing" = 0 ] || fail "the build is incomplete"
for l in en ru tk; do
    [ -s "$out/$l/release-notes/index.html" ] || fail "missing $out/$l/release-notes/index.html"
done
say "ok   every page and icon is there"

find "$out" -name '*.gz' -print -quit | grep -q . || fail "no pre-compressed .gz files"
say "ok   pre-compressed .gz copies for nginx's gzip_static"

# Every page must work under script-src 'self'; style-src 'self'. JSON-LD
# (type="application/ld+json") is data, not a script, and is allowed.
inline="$(grep -rl --include='*.html' -e '<style' -e ' style=' -e ' onerror=' "$out" || true)"
[ -z "$inline" ] || fail "inline style or handler in: $inline"
inline="$(grep -rlP --include='*.html' '<script(?![^>]*\b(?:src=|type="application/ld\+json"))' "$out" || true)"
[ -z "$inline" ] || fail "inline <script> in: $inline"
say "ok   no inline style, script or event handler in any page"

node --input-type=module - "$out" <<'EOF' || fail "an icon has the wrong size or format"
import sharp from 'sharp'
import { readFileSync } from 'node:fs'
const out = process.argv[2]
const want = { 'favicon-32.png': [32, 32], 'apple-touch-icon.png': [180, 180], 'icon-64.png': [64, 64],
  'icon-128.png': [128, 128], 'icon-192.png': [192, 192], 'icon-512.png': [512, 512], 'og-image.png': [1200, 630] }
let bad = 0
for (const [name, [w, h]] of Object.entries(want)) {
  const m = await sharp(`${out}/${name}`).metadata()
  if (m.format !== 'png' || m.width !== w || m.height !== h || m.channels !== 4 || m.depth !== 'uchar') {
    console.error(`build: ${name} is ${m.format} ${m.width}x${m.height}, ${m.channels} channels, ${m.depth}`)
    bad = 1
  }
}
const ico = readFileSync(`${out}/favicon.ico`)
const sizes = []
for (let i = 0; i < ico.readUInt16LE(4); i++) {
  const e = 6 + 16 * i
  const png = ico.subarray(ico.readUInt32LE(e + 12), ico.readUInt32LE(e + 12) + ico.readUInt32LE(e + 8))
  const m = await sharp(png).metadata()
  sizes.push(`${m.format}:${m.width}x${m.height}`)
}
if (ico.readUInt16LE(2) !== 1 || sizes.join(' ') !== 'png:16x16 png:32x32') {
  console.error(`build: favicon.ico holds ${sizes.join(' ')}`)
  bad = 1
}
process.exit(bad)
EOF
say "ok   icons: favicon.ico (16 and 32), the PNGs at their sizes, og-image.png 1200 x 630, all RGBA PNG"

# /update.json, which the app reads to learn whether a newer version exists:
# valid JSON, exactly the three fields, and the same values as release.json.
node --input-type=module - "$out/update.json" release.json <<'EOF' || fail "update.json does not agree with release.json"
import { readFileSync } from 'node:fs'
const [file, releaseFile] = process.argv.slice(2)
let update
try {
  update = JSON.parse(readFileSync(file, 'utf8'))
} catch (error) {
  console.error(`build: ${file}: ${error.message}`)
  process.exit(1)
}
const release = JSON.parse(readFileSync(releaseFile, 'utf8'))
let bad = 0
const keys = Object.keys(update ?? {}).join(',')
if (update === null || typeof update !== 'object' || Array.isArray(update) || keys !== 'version,minimumSystem,date') {
  console.error(`build: update.json has the fields "${keys}"; expected version, minimumSystem, date`)
  process.exit(1)
}
for (const key of ['version', 'minimumSystem', 'date']) {
  if (typeof update[key] !== 'string' || update[key] !== release[key]) {
    console.error(`build: update.json "${key}" is ${JSON.stringify(update[key])}, release.json has ${JSON.stringify(release[key])}`)
    bad = 1
  }
}
if (!/^[0-9]+(?:\.[0-9]+)*$/.test(update.version) || !/^[0-9]+(?:\.[0-9]+)*$/.test(update.minimumSystem)
    || !/^(?:\d{4}-\d{2}-\d{2})?$/.test(update.date)) {
  console.error(`build: update.json has a value of the wrong shape: ${JSON.stringify(update)}`)
  bad = 1
}
process.exit(bad)
EOF
say "ok   update.json agrees with release.json: $(cat "$out/update.json")"

# The writer itself, on a published and an unpublished release and on values
# of the wrong shape, whatever release.json holds today.
node --input-type=module - <<'EOF' || fail "scripts/update-json.mjs"
import { updateJson } from './scripts/update-json.mjs'
const base = { repository: 'kpirliyev/culla', file: 'Culla-1.1.dmg', size: 25000000, sha256: '' }
const cases = [
  [{ ...base, version: '1.1', minimumSystem: '26.0', date: '2026-12-01' },
   '{ "version": "1.1", "minimumSystem": "26.0", "date": "2026-12-01" }\n'],
  [{ ...base, version: '1.0', minimumSystem: '26.0', date: '' },
   '{ "version": "1.0", "minimumSystem": "26.0", "date": "" }\n'],
]
let bad = 0
for (const [release, want] of cases) {
  const got = updateJson(release)
  if (got !== want) { console.error(`build: updateJson gave ${JSON.stringify(got)}, expected ${JSON.stringify(want)}`); bad = 1 }
}
for (const wrong of [{ minimumSystem: '26.0b' }, { minimumSystem: undefined }, { minimumSystem: 26 },
                     { version: '1.0;' }, { date: 'soon' }, { date: undefined }]) {
  const release = { ...base, version: '1.0', minimumSystem: '26.0', date: '', ...wrong }
  try { updateJson(release); console.error(`build: updateJson accepted ${JSON.stringify(wrong)}`); bad = 1 } catch {}
}
process.exit(bad)
EOF
say "ok   scripts/update-json.mjs: published and unpublished releases, values of the wrong shape refused"

say "built $(find "$out" -type f | wc -l) files into site/$out"

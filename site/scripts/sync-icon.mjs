// Copies the app's icon into the site, so the page always shows the icon the
// Xcode project ships with.
//
// Source: the largest PNG listed in Culla/Assets.xcassets/AppIcon.appiconset/
// Contents.json (file names are read from there, not assumed). Set
// CULLA_ICON_SRC to a PNG file to use another image instead, for example to
// try a new icon before it goes into the asset catalog.
//
// Output (git-ignored build output) in site/public/:
//   favicon.ico (16 + 32), favicon-32.png, apple-touch-icon.png (180),
//   icon-192.png, icon-512.png, icon-64.png and icon-128.png (top bar, 1x and 2x),
//   og-image.png (1200 x 630, the icon on the page's dark grey).
//
// Resizing uses `sips`, which ships with macOS. No npm package is needed.

import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const siteDir = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const publicDir = join(siteDir, 'public')
const iconSetDir = resolve(siteDir, '../Culla/Assets.xcassets/AppIcon.appiconset')

// The page's dark background, so the Open Graph image matches the site.
const OG_BACKGROUND = '18181A'

function fail(message) {
  console.error(`sync-icon: ${message}`)
  process.exit(1)
}

function pixelSize(contentsEntry) {
  const [w] = String(contentsEntry.size ?? '0x0').split('x').map(Number)
  const scale = Number(String(contentsEntry.scale ?? '1x').replace('x', '')) || 1
  return w * scale
}

function findSource() {
  const override = process.env.CULLA_ICON_SRC
  if (override) {
    const path = resolve(process.cwd(), override)
    if (!existsSync(path)) fail(`CULLA_ICON_SRC points at ${path}, which does not exist`)
    return path
  }
  const contentsPath = join(iconSetDir, 'Contents.json')
  if (!existsSync(contentsPath)) fail(`no Contents.json in ${iconSetDir}`)
  const contents = JSON.parse(readFileSync(contentsPath, 'utf8'))
  const candidates = (contents.images ?? [])
    .filter((image) => image.filename && image.filename.toLowerCase().endsWith('.png'))
    .map((image) => ({ path: join(iconSetDir, image.filename), px: pixelSize(image) }))
    .filter((image) => existsSync(image.path))
    .sort((a, b) => b.px - a.px)
  if (candidates.length === 0) fail(`no PNG listed in ${contentsPath} exists`)
  return candidates[0].path
}

function sips(args) {
  execFileSync('sips', args, { stdio: ['ignore', 'ignore', 'pipe'] })
}

function resized(source, size, out) {
  sips(['-s', 'format', 'png', '-z', String(size), String(size), source, '--out', out])
}

// An ICO file may hold PNG images directly; every browser in use reads that.
function writeIco(pngPaths, out) {
  const images = pngPaths.map(({ path, size }) => ({ data: readFileSync(path), size }))
  const header = Buffer.alloc(6)
  header.writeUInt16LE(0, 0)
  header.writeUInt16LE(1, 2)
  header.writeUInt16LE(images.length, 4)
  const entries = []
  let offset = 6 + 16 * images.length
  for (const image of images) {
    const entry = Buffer.alloc(16)
    entry.writeUInt8(image.size >= 256 ? 0 : image.size, 0)
    entry.writeUInt8(image.size >= 256 ? 0 : image.size, 1)
    entry.writeUInt8(0, 2)
    entry.writeUInt8(0, 3)
    entry.writeUInt16LE(1, 4)
    entry.writeUInt16LE(32, 6)
    entry.writeUInt32LE(image.data.length, 8)
    entry.writeUInt32LE(offset, 12)
    entries.push(entry)
    offset += image.data.length
  }
  writeFileSync(out, Buffer.concat([header, ...entries, ...images.map((image) => image.data)]))
}

const source = findSource()
const work = mkdtempSync(join(tmpdir(), 'culla-icon-'))
try {
  const square = (size, name) => {
    const out = join(publicDir, name)
    resized(source, size, out)
    return out
  }
  square(32, 'favicon-32.png')
  square(180, 'apple-touch-icon.png')
  square(192, 'icon-192.png')
  square(512, 'icon-512.png')
  square(64, 'icon-64.png')
  square(128, 'icon-128.png')

  const ico16 = join(work, '16.png')
  const ico32 = join(work, '32.png')
  resized(source, 16, ico16)
  resized(source, 32, ico32)
  writeIco([{ path: ico16, size: 16 }, { path: ico32, size: 32 }], join(publicDir, 'favicon.ico'))

  const ogIcon = join(work, 'og-icon.png')
  resized(source, 400, ogIcon)
  sips(['-s', 'format', 'png', '--padToHeightWidth', '630', '1200', '--padColor', OG_BACKGROUND, ogIcon, '--out', join(publicDir, 'og-image.png')])
} finally {
  rmSync(work, { recursive: true, force: true })
}

const kb = (name) => `${Math.round(statSync(join(publicDir, name)).size / 1024)} KB`
console.log(`sync-icon: ${source} -> public/ (favicon.ico ${kb('favicon.ico')}, og-image.png ${kb('og-image.png')})`)

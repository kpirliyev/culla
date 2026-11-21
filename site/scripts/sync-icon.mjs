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
// Resizing uses sharp, which @nuxt/image already installs (through ipx), so
// the same code runs on macOS and in the Linux build container. No npm
// package is added for it. The PNGs are 8-bit RGBA without metadata; with no
// colour chunk a browser reads them as sRGB, which is what the source is.

import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import sharp from 'sharp'

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

// resized: the source scaled to size x size, as 8-bit RGBA PNG data.
function resized(source, size) {
  return sharp(source)
    .resize(size, size, { fit: 'fill' })
    .ensureAlpha()
    .png()
    .toBuffer()
}

// An ICO file may hold PNG images directly; every browser in use reads that.
function writeIco(pngs, out) {
  const images = pngs.map(({ data, size }) => ({ data, size }))
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
try {
  for (const [size, name] of [
    [32, 'favicon-32.png'],
    [180, 'apple-touch-icon.png'],
    [192, 'icon-192.png'],
    [512, 'icon-512.png'],
    [64, 'icon-64.png'],
    [128, 'icon-128.png'],
  ]) {
    writeFileSync(join(publicDir, name), await resized(source, size))
  }

  writeIco(
    [{ data: await resized(source, 16), size: 16 }, { data: await resized(source, 32), size: 32 }],
    join(publicDir, 'favicon.ico'),
  )

  // The icon at 400 x 400 in the middle of a 1200 x 630 background, laid
  // over it (its transparent corners show the background), fully opaque.
  const OG_W = 1200, OG_H = 630, OG_ICON = 400
  const left = (OG_W - OG_ICON) / 2, top = Math.floor((OG_H - OG_ICON) / 2)
  const background = {
    r: parseInt(OG_BACKGROUND.slice(0, 2), 16),
    g: parseInt(OG_BACKGROUND.slice(2, 4), 16),
    b: parseInt(OG_BACKGROUND.slice(4, 6), 16),
    alpha: 1,
  }
  const og = await sharp(await resized(source, OG_ICON))
    .flatten({ background })
    .extend({ top, bottom: OG_H - OG_ICON - top, left, right: OG_W - OG_ICON - left, background })
    .ensureAlpha(1)
    .png()
    .toBuffer()
  writeFileSync(join(publicDir, 'og-image.png'), og)
} catch (error) {
  fail(`could not make the icons from ${source}: ${error.message}`)
}

const kb = (name) => `${Math.round(statSync(join(publicDir, name)).size / 1024)} KB`
console.log(`sync-icon: ${source} -> public/ (favicon.ico ${kb('favicon.ico')}, og-image.png ${kb('og-image.png')})`)

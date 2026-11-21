// Serves .output/public the way nginx will, close enough to try the site:
// the same Content-Security-Policy, `/` sent to /en/, /download as the server
// answers it (see below), and 404.html for anything missing.
// Usage: npm run preview:static [-- --port 4173]
import { createReadStream, existsSync, readFileSync, statSync } from 'node:fs'
import { createServer } from 'node:http'
import { extname, join, normalize, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { githubLinks } from '../composables/github.mjs'

const root = resolve(fileURLToPath(new URL('../.output/public', import.meta.url)))
// The "not yet" page and its stylesheet, which nginx serves from outside the web root.
const errorsDir = resolve(fileURLToPath(new URL('../deploy/errors', import.meta.url)))
const releaseFile = fileURLToPath(new URL('../release.json', import.meta.url))
const portArg = process.argv.indexOf('--port')
const port = Number(portArg > 0 ? process.argv[portArg + 1] : process.env.PORT || 4173)

const CSP = "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; form-action 'self'; base-uri 'self'; frame-ancestors 'none'"
const TYPES = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon',
  '.webp': 'image/webp', '.avif': 'image/avif', '.txt': 'text/plain; charset=utf-8', '.xml': 'application/xml',
}

function send(res, status, file) {
  res.writeHead(status, { 'Content-Type': TYPES[extname(file)] ?? 'application/octet-stream', 'Content-Security-Policy': CSP, 'Cache-Control': 'no-cache' })
  createReadStream(file).pipe(res)
}

createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost')
  // /download: while release.json has no date, the "not yet" page with a 503;
  // with one, a redirect to the disk image on GitHub. Read on every request,
  // so editing release.json needs no restart.
  if (url.pathname === '/download') {
    const release = JSON.parse(readFileSync(releaseFile, 'utf8'))
    if (release.date) {
      res.writeHead(302, { Location: githubLinks(release).asset, 'Cache-Control': 'no-cache' })
      return res.end()
    }
    return send(res, 503, join(errorsDir, 'download-503.html'))
  }
  if (url.pathname.startsWith('/_errors/')) {
    const file = normalize(join(errorsDir, url.pathname.slice('/_errors/'.length)))
    if (file.startsWith(errorsDir + '/') && existsSync(file) && statSync(file).isFile()) return send(res, 200, file)
  }
  if (url.pathname === '/') {
    res.writeHead(302, { Location: '/en/' })
    return res.end()
  }
  const path = normalize(join(root, decodeURIComponent(url.pathname)))
  if (!path.startsWith(root)) { res.writeHead(400); return res.end() }
  if (existsSync(path) && statSync(path).isDirectory()) {
    if (!url.pathname.endsWith('/')) { res.writeHead(301, { Location: `${url.pathname}/` }); return res.end() }
    const index = join(path, 'index.html')
    if (existsSync(index)) return send(res, 200, index)
  } else if (existsSync(path)) {
    return send(res, 200, path)
  }
  send(res, 404, join(root, '404.html'))
}).listen(port, () => console.log(`Culla site on http://localhost:${port}/ (with the production CSP)`))

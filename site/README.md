# cullaapp.com

The landing page for Culla, a Nuxt 4 site generated as plain static files. The plan it follows is `docs/landing-page-plan.md`.

## Commands

The build and every test run in podman containers; the Mac needs only podman
with its machine running (`podman machine start`), not Node or Python. From
the repository root:

```bash
site/test.sh              # all: build, unit, deploy, nginx; a summary at the end
site/test.sh build        # npm ci (when package-lock.json changed) + npm run generate + checks
site/test.sh unit         # python3 -m unittest discover -s site/deploy/test
site/test.sh deploy       # site/deploy/test/run-deploy-tests.sh
site/test.sh nginx        # site/deploy/test/run-nginx-tests.sh
site/test.sh clean        # remove the volumes and the test image
```

The exit status is 0 when everything passed, 1 when something failed and 2
when podman is missing or not running. `site/deploy/deploy.sh` builds through
`site/test.sh build` too.

- **The build** runs in `docker.io/library/node:26.13.1-trixie-slim` (Node 26,
  the current LTS line; Nuxt 4.6 needs Node 22.22, 24.15 or 26). The
  repository is mounted at the same path as on the Mac, read-only except
  `site/`, so `.output/public/`, `.nuxt/` and the icons in `public/` land in
  the working tree, owned by you. `node_modules` is the podman volume
  `culla-site-node-modules` laid over `site/node_modules` (a Mac
  `node_modules`, if there is one, is neither used nor changed) and npm's
  cache is the volume `culla-site-npm-cache`; `npm ci` runs only when
  `package-lock.json` or the Node version changed. The steps are in
  `containers/build.sh`; after `npm run generate` it checks that every page
  and icon is there, that `.gz` copies exist, that no page has an inline
  style, script or event handler, and the icons' sizes and formats. It needs
  the npm registry for `npm ci`.
- **The tests** run in `localhost/culla-site-test:<hash>`, built from
  `containers/test.Containerfile` (the official nginx image
  `docker.io/library/nginx:1.26.3-bookworm` with python3 and rsync) and
  rebuilt only when that file or the nginx image changes; with no network,
  `site/` mounted read-only. See `deploy/test/README.md`.

`npm run preview:static` and `npm run dev` are left for a Mac that has a
suitable Node (they are not tests); `npm run icons` refreshes only the icon
files.

The build writes `.output/public/`, with a `.gz` copy of every text file for nginx's `gzip_static`. That folder is what the deploy copies to the server.

`preview:static` behaves like nginx closely enough to try the site: it sends the same `Content-Security-Policy`, redirects `/` to `/en/`, answers `/download` as the server does (the "not yet" page from `deploy/errors/` while `release.json` has no `date`, a redirect to the disk image on GitHub once it has one), and shows `404.html` for anything missing.

## How the site is put together

- **No JavaScript framework reaches the browser.** `features.noScripts` keeps the Nuxt runtime out of the pages, and `features.inlineStyles: false` keeps the CSS in one file. `server/plugins/clean-html.ts` removes the few inline bits Nuxt and `@nuxt/image` still add (a speculation-rules script, an `onerror` attribute on images, hydration comments), so every page works under `script-src 'self'; style-src 'self'`.
- **One small script**, `public/js/culla.js`, adds the keyboard demo and the "Copy link for your Mac" button. Everything else works with JavaScript off. The demo's text comes from the language files through `data-` attributes.
- **Languages.** `i18n/locales/en.json`, `ru.json`, `tk.json`. Every address carries its language (`/en/`, `/ru/`, `/tk/`). `root-fallback/index.html` becomes `/index.html`, a plain page that sends a visitor to `/en/` when nginx's redirect by language is not in front of it.
- **Pages.** `pages/index.vue` (one component per section in `components/`), `pages/release-notes.vue`, and `error.vue`, which is generated once as `/404.html`.
- **Feedback.** There is no form. "Not finished yet", the Questions and the footer link to the GitHub issue forms (`.github/ISSUE_TEMPLATE/` at the repository root) and Discussions. Links that leave the site open in the same tab with `rel="noopener"`; the pages load nothing from GitHub.
- **Styles.** `assets/css/main.css`, plain CSS with custom properties. Dark unless the system asks for light. System fonts only.

## The release

`release.json` holds the version on the page:

```json
{ "repository": "kpirliyev/culla", "version": "1.0", "file": "Culla-1.0.dmg", "size": 0, "sha256": "", "date": "" }
```

`repository` is the GitHub repository; every GitHub address on the page (the repository, the release, the issue forms, Discussions, `CONTRIBUTING.md`, `LICENSE`) is built from it in `composables/github.mjs`, which `composables/site.ts` and the preview server share. The disk image is an asset of the GitHub Release `v<version>`, and `/download` redirects to it. `size` is in bytes; while it is 0 the size is left out of the version line. `date` is `YYYY-MM-DD`; while it is empty no date is shown. The release notes page shows `sha256` when it is filled in. The text of the release notes is in `data/release-notes/<lang>.json`; a note can be a string, or `{ "text": "…", "beta": true }` to carry the Beta label.

## The app icon

The page uses the app's own icon. `scripts/sync-icon.mjs` reads `Culla/Assets.xcassets/AppIcon.appiconset/Contents.json`, takes the largest PNG listed there, and writes with `sharp` (installed with `@nuxt/image`, so it works on macOS and in the Linux build container alike):

- `favicon.ico` (16 and 32), `favicon-32.png`, `apple-touch-icon.png` (180), `icon-192.png`, `icon-512.png`
- `icon-64.png` and `icon-128.png` for the top bar
- `og-image.png`, the 1200 × 630 sharing picture: the icon on the page's dark grey

These files are build output and are not committed. After the icon in the Xcode project changes, `site/test.sh build` is all it takes. The PNGs are 8-bit RGBA without metadata (read as sRGB, like the source); `og-image.png` is fully opaque. To try another picture without touching the asset catalog:

```bash
CULLA_ICON_SRC=/path/to/icon-1024.png site/test.sh build
```

## Screenshots

The screenshots come from the app. `Scripts/site-shots.sh` (run from the repository root) builds the Debug app, captures the five slots in English, Russian and Turkmen on the demo photos in `culla-demo-shoot/photos` (not committed; another folder can be given), and writes the fifteen PNGs to `public/shots/`, replacing the old ones. The screenshots are taken with the stack time gap set to 300 s, because the demo photos are published frames taken minutes apart; the app's default is unchanged. The copies get camera-style names, so no photographer's name shows. `Scripts/README.md` says how it chooses what each slot shows. A slot without a file shows a drawn grey placeholder with a short label. The slots are:

| Slot | Where | Shown at most | Make the PNG at least |
| --- | --- | --- | --- |
| `hero-stack-review` | First screen, stack review | 640 × 400 | 1280 × 800 (16:10) |
| `how-1-open` | How it works, step 1 | 400 × 300 | 800 × 600 (4:3) |
| `how-2-groups` | How it works, step 2 | 400 × 300 | 800 × 600 (4:3) |
| `how-3-decide` | How it works, step 3 | 400 × 300 | 800 × 600 (4:3) |
| `vision-evidence` | Apple Vision, evidence on a photo | 600 × 400 | 1200 × 800 (3:2) |

To put one in, save it as `public/shots/<slot>.<lang>.png`, for example `public/shots/hero-stack-review.ru.png`, and run `site/test.sh build`. The build finds the file by itself; there is no list to edit. A language without its own file shows the English one, so `<slot>.en.png` alone is enough to start. Keep each picture at the slot's proportions; it is cropped to fill the slot otherwise. `@nuxt/image` makes AVIF and WebP copies at the slot's size and twice that, with a PNG fallback; those copies live under `/_ipx/` in the output and keep a `.png` name whatever their format, which browsers read correctly.

The alt text for each slot is in the language files under `shots.<slot>.alt`. Check that it still describes the picture.

## Checks before a deploy

```bash
site/test.sh              # the build with its checks, and every test
```

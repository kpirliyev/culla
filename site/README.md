# cullaapp.com

The landing page for Culla, a Nuxt 4 site generated as plain static files. The plan it follows is `docs/landing-page-plan.md`.

## Commands

```bash
npm install
npm run generate          # builds .output/public (runs `npm run icons` first)
npm run preview:static    # serves .output/public on http://localhost:4173 with the production CSP
npm run dev               # live editing (runs `npm run icons` first)
npm run icons             # only refresh the icon files
```

`npm run generate` writes `.output/public/`, with a `.gz` copy of every text file for nginx's `gzip_static`. That folder is what the deploy copies to the server.

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

The page uses the app's own icon. `scripts/sync-icon.mjs` reads `Culla/Assets.xcassets/AppIcon.appiconset/Contents.json`, takes the largest PNG listed there, and writes with `sips`:

- `favicon.ico` (16 and 32), `favicon-32.png`, `apple-touch-icon.png` (180), `icon-192.png`, `icon-512.png`
- `icon-64.png` and `icon-128.png` for the top bar
- `og-image.png`, the 1200 × 630 sharing picture: the icon on the page's dark grey

These files are build output and are not committed. After the icon in the Xcode project changes, `npm run generate` is all it takes. To try another picture without touching the asset catalog:

```bash
CULLA_ICON_SRC=/path/to/icon-1024.png npm run generate
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

To put one in, save it as `public/shots/<slot>.<lang>.png`, for example `public/shots/hero-stack-review.ru.png`, and run `npm run generate`. The build finds the file by itself; there is no list to edit. A language without its own file shows the English one, so `<slot>.en.png` alone is enough to start. Keep each picture at the slot's proportions; it is cropped to fill the slot otherwise. `@nuxt/image` makes AVIF and WebP copies at the slot's size and twice that, with a PNG fallback; those copies live under `/_ipx/` in the output and keep a `.png` name whatever their format, which browsers read correctly.

The alt text for each slot is in the language files under `shots.<slot>.alt`. Check that it still describes the picture.

## Checks before a deploy

```bash
npm run generate
grep -l '<style\| style=\| onerror=' .output/public -r --include='*.html'   # prints nothing
```

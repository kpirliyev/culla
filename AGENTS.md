# Working on Culla

Culla is a free Mac app for culling photos. Read `docs/architecture.md`, `docs/design.md`, `docs/user-flows.md` and `docs/implementation-plan.md` before changing anything.

## How work is divided

- **Coding and interface design are done by Opus subagents.** The main session plans, writes the brief, reviews the result and verifies it by building, testing and running. It does not write project code itself. Spawn the subagent with the Opus model and give it the files to touch, what done looks like, and how to check it.
- Documentation, running builds and tests, and reviewing diffs stay in the main session.
- **Keep going.** The owner wants the implementation plan carried out milestone by milestone without check-ins. Stop only for a decision that is drastic: one that is costly to reverse, changes what the product is, needs something only the owner has (credentials, an Apple Developer account, their judgement of their own photos), or touches their files outside this repository.
- **Detection tuning is the last milestone (M7).** Until then leave the thresholds as they are and keep every one of them an adjustable `Tuning` value shown in Settings.

## Rules

- **Supported Apple APIs only.** Detection uses Vision, Core Image and ImageIO. A feature that would need a private interface is dropped, not approximated.
- **Docs live in this repository** as Markdown in `docs/`. `docs/implementation-plan.md` holds the milestone checklists; tick a box when its task is done.
- **Nothing is written into a shoot folder** until the user applies their decisions. Tools write their output elsewhere.
- GRDB is the only third-party package planned. Do not add others without asking.
- **No fixed English in the interface.** Every piece of text a person sees or VoiceOver reads comes from a string catalog through `Localizer`, as a whole sentence with plural variations, with a comment for the translator. The app ships in English, Russian and Turkmen; read `docs/localization.md` before adding or changing text. What is written to disk stays English.

## Layout

- `CullaKit/` is a Swift package: `CullaCore` (models), `CullaFiles` (scanning, metadata, image I/O), `CullaAnalysis` (detectors, grouping), and the `culla-eval` command-line tool.
- `Culla.xcodeproj` and `Culla/` are the Mac app. Files added under `Culla/` join the app target automatically. The app is sandboxed and has no network access.
- `docs/` holds the design, the user flows and the plan.
- `site/` is the landing page, `https://cullaapp.com`: a Nuxt 4 site generated as static files, in English, Russian and Turkmen. `site/deploy/` holds the nginx configuration, the deploy script and the server's cron script, with their tests. Read `docs/landing-page-plan.md` before changing either; its rules on wording (free and open source under the MIT licence, no performance claims, sidecars labelled Beta, no email address anywhere) bind every text on the site. The site has no contact form: bugs, ideas and questions go to GitHub Issues and Discussions in `kpirliyev/culla`, and the disk image is downloaded from that repository's Releases. The site's icon is made from the app icon in `Culla/Assets.xcassets` at every build.

## Concurrency

Never run blocking work on Swift's cooperative thread pool: image decoding and encoding, pixel loops, and above all Core Image's `CIDetector`, which is built on Vision and waits for it synchronously. Run such work through `BlockingQueue` in `CullaCore`. Doing it on the pool made `culla-eval` hang once eight photos were in flight.

## Commands

```bash
cd CullaKit && swift build
cd CullaKit && swift test
cd CullaKit && swift run -c release culla-eval <folder>
xcodebuild -project Culla.xcodeproj -scheme Culla -configuration Debug build
```

After adding or changing text, run `python3 Scripts/l10n.py check --require ru,tk`; it fails on missing translations, missing translator comments and mismatched placeholders.

`culla-eval` writes scores and contact sheets to `culla-eval-output/`, which is not committed.

The site:

```bash
cd site && npm install && npm run generate
cd site && npm run preview:static
python3 -m unittest discover -s site/deploy/test
site/deploy/test/run-deploy-tests.sh
site/deploy/test/run-nginx-tests.sh
```

`preview:static` serves the built site on port 4173 with the same Content-Security-Policy as the server. `run-nginx-tests.sh` runs the configuration in the official nginx image with podman and needs the podman machine running (`podman machine start`). Containers are run with podman only, never Docker. Testing on the Mac goes through podman containers: run the site's build and the tests of `site/deploy/` in a container, not with the Mac's own Node or Python. The app itself (Xcode, Swift, the interface scripts) can only run on macOS.

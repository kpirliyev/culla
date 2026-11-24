# Culla — Implementation Plan

Last updated: 2026-11-24

Culla is built in nine milestones, each ending in something you can run and judge. The first checks that detection works at all on a real shoot; fine-tuning it is deliberately the last one to be done, so every threshold stays an adjustable setting until then. The structure all of it is built to is in [Architecture](architecture.md). The plan implements [Design](design.md) and [User Flows](user-flows.md) with all twelve open questions confirmed as proposed.

Task lists below are the progress record: tick a box when its task is done.

## Roadmap

| Milestone | Adds | Done when |
| --- | --- | --- |
| M0 Detector check | Detectors and `culla-eval`, no interface | Contact sheets from your shoots put the bad photos first |
| M1 Culler | Open a folder, grid, loupe, manual decisions | A 5,000-photo folder is culled by hand and resumes |
| M2 Defects | Analysis pipeline and defect groups | Defect groups fill, and regroup when a threshold changes |
| M3 Stacks | Stacks, duplicates and compare | A good stack takes one key |
| M4 Apply | Review and apply, sidecars, undo | Apply, then Undo Apply, loses nothing |
| M5 Settings | Settings, presets and tuning | Every setting works with no restart |
| M6 Release | Polish, signing and notarization | The notarized 1.0 passes all eight flows |
| M7 Tuning | Detection fine-tuning on real shoots | You trust each group's defaults on your own photos |
| M8 Updates | The update check | A copy of Culla learns of a newer version from `cullaapp.com` and says so on the welcome view |

From M1 on, every milestone adds flows to an app that already runs. Detection tuning was moved from M0 to M7 on 2026-11-09: the app is built first with the values chosen from the first shoot, and tuned once it can be used on real shoots. M7 can run before M6's release steps. M8 was added on 2026-11-24 and built straight away; M7 is still the last work to be done. No dates are set; the order and the gates are what this plan fixes.

## Decisions carried in

Answers to the open questions, confirmed in review:

| Question | Decision |
| --- | --- |
| Keep, reject and clear keys | P / X / U |
| What happens to rejects | Moved to a `_Rejected` folder |
| Stacks in All Photos | Collapsed to one tile |
| Inspector | Hidden by default, opened with I |
| Appearance | Dark by default |
| Star ratings | In the first version |
| Unreviewed photos on Apply | Count as kept |
| Memory cards | Read in place |
| After the last stack | Offer the next group |
| Bulk reject of Certain photos | One confirmation |
| Videos | Fully ignored |
| Near-duplicates | Reviewed set by set |

Technical choices this plan makes:

| Area | Choice | Reason |
| --- | --- | --- |
| Language | Swift 6 with strict concurrency | Analysis runs on many cores; data races are caught at compile time |
| Minimum system | macOS 26 | Gives the newer Vision requests, including lens smudge |
| Interface | SwiftUI, with AppKit views for the grid, filmstrip and zoomable loupe | SwiftUI is quick to build; AppKit keeps 10,000 tiles scrolling smoothly |
| Detection | Vision, Core Image and ImageIO only | The requirement: built-in frameworks, no third-party models |
| Storage | SQLite through GRDB, the only third-party package | Fast filtered queries over the scores of 10,000 or more photos |
| Session data | Kept in the app's own support folder | Nothing is written into the shoot folder until Apply |
| Distribution | Open source under the MIT licence at `github.com/kpirliyev/culla`; the notarized disk image is a GitHub Release asset, linked from `cullaapp.com` | The Mac App Store can follow later |
| Detection testing | By eye, on contact sheets and in the app; no labelled test set | You test manually as the app is built |
| Neural Engine usage figure | Not shown | macOS has no supported reading of it |
| Documentation | Markdown in this repository's `docs/` folder | Docs are versioned with the code |
| Updates | The app checks `cullaapp.com/update.json` and tells the person; the download stays in the browser. No in-app installer and no update framework (decided on 2026-11-24) | It keeps GRDB the only package and limits the app's network use to one request for a static file |

## Project layout

All logic lives in a Swift package, so it can be tested and run from the command line without the interface.

| Part | Kind | Holds |
| --- | --- | --- |
| `Culla` | App target | Windows, views, key handling, settings panes |
| `CullaCore` | Package module | Photo, score and geometry models |
| `CullaFiles` | Package module | Folder scanning, RAW+JPEG pairing, previews and the thumbnail cache, bookmarks, XMP sidecars, apply and undo-apply |
| `CullaAnalysis` | Package module | Detectors, scores, thresholds and tiers, stack and duplicate grouping |
| `CullaSession` | Package module | The state of one open shoot: decisions, ratings, groups, undo |
| `CullaStore` | Package module | The SQLite store: sessions, decisions, cached scores |
| `CullaCommands` | Package module | Commands, the key map, selection logic |
| `CullaPipeline` | Package module | Background analysis: scheduler, score cache use, grouping and best picks |
| `CullaUpdates` | Package module | The update check: versions, the decision, the schedule and the one network request |
| `culla-eval` | Command-line tool | Runs the detectors over a folder and writes scores and contact sheets |
| Tests | One target per module | Unit tests |

The app and `culla-eval` run the same analysis code, so what you judge in M0 is what ships.

## M0 — Detector check

Goal: see, on your own shoots and before any interface is built, whether eyes-closed, blur and similarity detection can be trusted. There is no labelled test set; you judge the results by eye.

- [x] Create the Git repository.
- [x] Create the Xcode project and the package skeleton.
- [x] Build `culla-eval`: run every detector over a folder and write one row of scores per photo.
- [x] Eye openness: Vision face landmarks, cross-checked with Core Image's blink flag. Faces too small in the frame for Vision's whole-image landmarks are measured again on a cut-out of the face.
- [x] Sharpness: edge strength measured on the subject region from Vision saliency and face boxes, plus face capture quality.
- [x] Similarity: capture-time gaps plus Vision feature-print distance; exact duplicates by file hash.
- [x] Exposure clipping, aesthetics score, lens smudge and horizon, read alongside EXIF data.
- [x] Contact sheets: for each detector, one page of thumbnails sorted from worst score to best with the score under each; for similarity, one row per stack.
- [x] Run `culla-eval` on a real shoot and choose starting values from its sheets (see "First real shoot" below). Further shoots moved to M7.
- [x] Put the chosen starting values in the code as adjustable settings. Confirming them, and the Certain and Likely cut-offs, moved to M7.
- [x] Measure photos per second and record which processor each request runs on.

**Gate.** Passed on 2026-11-09 in its reduced form: every detector runs on a real shoot and produces usable scores, and starting values are in place. Whether the defaults can be trusted is M7's gate.

### Running the detector check

```bash
cd CullaKit && swift run -c release culla-eval /path/to/a/shoot
```

Results go to `CullaKit/culla-eval-output/<folder name>/`; open `index.html` there. The shoot folder is only read, never changed. A second run reuses the saved scores, so trying other grouping settings (`--gap`, `--similarity`, `--near-duplicate`) takes a moment. `culla-eval --help` lists every option.

### First real shoot

On 2026-11-09 `culla-eval` ran on a family dinner shoot: 108 photos from a Nikon D3200 (100 RAW, 8 JPEG), 281 faces. It ran at 8.4 photos per second; decoding takes about 0.5 s of the 0.9 s spent per photo.

Thresholds chosen from the contact sheets, now the defaults:

| Setting | Value | Flags in this shoot |
| --- | --- | --- |
| Eyes closed when eye openness is below | 0.26 | 18 of the 99 photos with a main face |
| Blurry when sharpness is below | 25 | 23 of 108 |
| Stack time gap | 10 s | 25 stacks holding 71 photos, together with the distance below |
| Stack feature distance | 0.60 | |
| Clipped highlights flagged above | 30% of the frame (provisional) | 0 |
| Clipped shadows flagged above | 50% of the frame (provisional) | 0 |
| Low aesthetics when the score is below | 0.30 | 6 of 108 |

The first exposure proposals (15% and 25%) flagged perfectly fine photos. The most clipped photos in this shoot sit at 15% and 27%, so the new values are simply well above those; they have not been checked against a photo that really is ruined.

What the shoot uncovered:

- **Most faces got no eye reading.** Vision's landmark model returns unusable landmarks for a face shorter than about 9% of the image height, whatever the resolution. Only 77 of 281 faces had readings, so 44 photos with a main face never reached the Eyes Closed sheet. Each such face is now measured again on a cut-out in which it fills more of the frame. After the fix 280 of 281 faces have readings and all 99 photos get an eye score. The readings of the original 77 faces did not change.
- **Small faces read noisier.** About 14% of the newly covered faces fall below 0.26, against 3% of the larger ones, and measuring the same small face twice can differ by 0.04 to 0.1. Sixteen of the 18 flagged photos are flagged by a small face, mostly in group shots. A single threshold may be too strict for small faces; this needs your eyes on the regenerated Eyes Closed sheet.
- **Stacks grew from 6 to 25** under the wider gap and distance. Worth a look on the Similar Stacks sheet for unrelated photos joined together.
- **Core Image's blink flag fires more often than the openness score** (10 photos against 2 on the first run), so the two do not simply agree. How to combine them into Certain and Likely tiers is undecided.
- **Decoding is the slow part.** For these Nikon files ImageIO already hands back the camera's embedded full-size JPEG rather than developing the RAW, so the 0.5 s is a 24 MP JPEG decode and resize. Analysing at 3008 px instead of 4096 px would raise speed from about 8.5 to 12.8 photos per second, but it moves the scores (20 of 108 photos change flags), so it is left for M7.

### First measurements

Measured on 2026-11-09 on an 8-core Apple M2, with a generated sample of 35 JPEGs of 3000 x 2000 pixels. Real camera files are larger and will be slower.

| Photos analysed at once | Photos per second |
| --- | --- |
| 1 | 11 |
| 2 | 19 to 20 |
| 4 | 24 to 26 |
| 8 (the default) | 25 to 31 |
| 16 | 26 to 31 |

Speed levels off above 6 at once; the limit is Vision's own processing, not the CPU.

Processors Vision says each request can use (it chooses among them itself and does not report which one a run used):

| Request | Processors |
| --- | --- |
| Face capture quality, feature print, aesthetics, attention saliency | Neural Engine, GPU, CPU |
| Lens smudge | Neural Engine |
| Horizon | CPU |
| Face landmarks | None reported |

What the sample run showed:

- A real photo scored about 90 for sharpness; the same photo blurred slightly scored 32, and blurred heavily 14 to 18.
- Stacks, exact copies, resized near-duplicates, RAW+JPEG pairing and an unreadable file all came out as expected.
- A heavily under-exposed copy of a sharp photo scored 27, so very dark photos read as soft. To watch for on real shoots.
- Exact copies taken at the same instant also form a stack, so they appear on both the Duplicates and the Stacks sheet.
- The sample has no people in it, so nothing about eyes or faces has been seen working yet.

## M1 — Shell and manual culling

Goal: a usable manual culler. Open a folder, see it at once, decide with keys, and pick up later where you stopped. Covers Flows 1 and 5.

- [x] Welcome window: drop target, Open Folder (⌘O) and recent sessions.
- [x] Folder access that survives relaunch, including memory cards read in place.
- [x] Scan with subfolders, pair RAW+JPEG into one photo, ignore videos.
- [x] Thumbnails from embedded previews, with an on-disk cache.
- [x] Main window in the dark appearance: toolbar, sidebar, photo area, status bar, inspector hidden until I.
- [x] Grid of All Photos in capture order with a size slider.
- [x] Loupe with filmstrip, zoom to 100% (Z) and panning. Zoom level and position stay put when moving between photos, so the same spot can be compared across a burst.
- [x] Decisions: P, X and U with advance, star ratings 0 to 5, tints and ticks on tiles.
- [x] Sidebar groups that need no analysis: All Photos, Unreviewed, Kept, Rejected.
- [x] Undo and redo for every decision.
- [x] Status bar counts of kept, rejected and left.
- [x] Session saved continuously and restored when the same folder is reopened; new files marked New.

Measured on a generated 5,002-photo shoot on an Apple M2:

| Measure | Result |
| --- | --- |
| Photos known after opening | 0.55 s |
| Grid populated | 0.85 s |
| Longest main-thread stall while opening | about 65 ms |
| Longest stall paging through the whole shoot | under 50 ms |
| Longest stall over 200 steps in the loupe | 3 to 6 ms |
| Z to a pixel-sharp 24 MP image | about 0.15 s |
| Next photo while zoomed to 100% | 1 to 2 ms when stepping normally |
| Memory after scrolling to the end | about 215 MB footprint |

**Gate status.** Met on generated shoots, checked by 13 scripted interface runs. Not yet checked by you on a real shoot.

**Gate.** A 5,000-photo folder opens to a scrolling grid without a visible stall, can be culled by hand from the keyboard alone, and quitting and reopening restores every decision and your place.

## M2 — Analysis pipeline and defect groups

Goal: Culla finds the defects and you clear them one key at a time. Covers Flow 3.

- [x] Background pipeline: several photos at once, visible photos and the open group first, pause and resume.
- [x] Score cache keyed by file path, size and modification date, so reopening a shoot re-analyses nothing.
- [x] The M0 detectors moved into the app unchanged.
- [x] Threshold layer that turns stored scores into flags and tiers at view time, never at analysis time.
- [x] Sidebar groups Eyes Closed, Blurry, Exposure and Other Issues, with live "left / total" counts.
- [x] Reason badges on tiles: solid for Certain, outlined for Likely.
- [x] Loupe opens zoomed to the evidence; face boxes outlined by eye state; Tab moves between faces.
- [x] Clipping overlay for the Exposure group.
- [x] Inspector contents: flags with scores, capture data, file details.
- [x] ⇧X bulk reject of remaining Certain photos, with one confirmation showing the count.
- [x] Toolbar analysis progress, the summary banner and Start Reviewing.
- [x] Empty-group and unreadable-file states.
- [x] A tuning popover in each group's header with that group's controls and a live count of what each would flag. Settings reuses the same controls in M5.

Measured on a generated 2,000-photo shoot on an Apple M2, with an optimised build:

| Measure | Result |
| --- | --- |
| Analysis speed in the app | 49 to 58 photos per second (the command-line tool: about 55 to 59) |
| Opening to the first group showing a count | 0.75 s |
| Longest main-thread stall paging the grid while analysing | 14 ms |
| Longest stall stepping and deciding in the loupe while analysing | 6 ms |
| Peak memory with eight photos in flight | about 700 MB |
| Reopening with everything cached | groups fully populated 0.28 s after opening; nothing analysed |

How many photos are analysed at once: the engine's default of 8, capped by memory (4 on a Mac with 8 GB), halved on battery when that setting is on, and reduced further when macOS reports memory pressure.

**Gate status.** Met on generated shoots: each defect group matches what `culla-eval` reports for the same folder, culling stays responsive while analysis runs, and moving a slider regroups with no re-analysis. The Eyes Closed path has only been exercised with simulated faces, never with a real photo of a person inside the app.

## M3 — Stacks, duplicates and compare

Goal: bursts and copies are grouped correctly and cleared in one or two keys. Covers Flows 2 and 4.

- [x] Stack grouping: capture-time gap as the hard limit, feature-print distance inside it, the camera's burst data where present.
- [x] Best-pick scoring per stack from sharpness, eye state and face quality.
- [x] Stack review screen: current frame, pinned best pick, filmstrip, Return to accept, ↓ to skip.
- [x] Face strip: match each person across the frames of a stack and show 100% crops, closed eyes outlined.
- [x] Compare view (C) for two to four photos with linked zoom and pan.
- [x] Manual correction: G adds to a stack, ⇧G splits a frame out.
- [x] Stacks collapse to one tile with a count in All Photos.
- [x] Duplicates: exact copies by file hash, near-duplicates by very small feature-print distance.
- [x] Duplicate sets side by side with the pre-picked copy; Accept All Exact Duplicates.
- [x] After the last stack or set, offer the next group.

Measured with an optimised build on an Apple M2: accepting 100 stacks in a row on a 2,000-photo shoot, the longest main-thread stall was 46 ms and the next stack was fully shown in a median of 16 ms. On a 24 MP burst the face strip shows first crops in about 3 ms and sharp 100% crops for all 17 faces in about 0.3 s.

Rules settled while building it:

- When the current frame is the best pick, the right pane shows the runner-up instead of the same picture twice.
- ⇧S makes the current frame the best pick (and, on a hand-chosen pick, returns to Culla's); S expands and collapses all stacks in the grid.
- P, X, U and the rating keys never decide a collapsed stack. They act on single photos in the selection and say how many stacks were left alone. Return or a double-click opens the stack.
- Manual stack edits and hand-chosen picks are saved and survive automatic regrouping.
- ⇧Return accepts all exact duplicate sets at once; near-duplicates are always one set at a time.

**Gate status.** Met on generated shoots with simulated faces, checked by scripted runs. The face strip's matching of the same person across frames has never been seen on real photos.

**Gate.** On your own shoots, a stack whose pick you agree with takes one key and a corrected one four or fewer. Every exact duplicate is found, and no near-duplicate is accepted in bulk.

## M4 — Review and apply

Goal: decisions become changes on disk once, safely, and can be taken back. Covers Flows 7 and 8.

- [x] Review and Apply screen (⌘Return): summary line, rejects grouped by reason, rescue with P.
- [x] The three reject actions: move to `_Rejected` (default), mark only, move to Trash.
- [x] XMP sidecars: write keep and reject flags and star ratings; merge into an existing sidecar without touching its other fields.
- [x] A journal of every move and sidecar change, which powers Undo Apply.
- [x] After-apply banner: Undo, Reveal Keepers in Finder, Open Keepers In an editor.
- [x] Read-only folders and locked cards: Copy Keepers To another folder instead of moving rejects.
- [x] Disconnected volume: pause, dim tiles, keep decisions, resume on return.
- [x] Files moved or renamed outside Culla: rescan when the window regains focus.
- [x] Partial failure: stop, report what moved, offer undo for that part.

Built and checked on 2026-11-10 with scripted runs on generated shoots. With an optimised build on an Apple M2: the screen opens in under 40 ms on a 2,000-photo shoot with 499 rejects; applying them with sidecars takes about 0.55 s and undoing it about 0.2 s, after which the folder's listing, contents and modification times are identical to before. A rescan of 5,000 unchanged photos costs the main thread nothing measurable.

Rules settled while building it:

- The primary button always names the action and the exact count ("Move 9 Photos to _Rejected"); it is red for the Trash and disabled when nothing would change.
- The choice made on the screen is for this apply only; "Use These Choices by Default" changes the setting.
- After an apply the decision history is cleared, and ⌘Z means Undo Apply (asking first, since it moves files) until a new decision is made. The banner's Undo button does not ask.
- Failed or cancelled runs can be undone as far as they ran; a partly undone run offers to try again.
- Nothing changes decisions while a run is under way.
- Persistent notices dock above the photos instead of covering them; the analysis summary is shown in the grid only and goes away once reviewing starts.
- A shoot counts as disconnected when its folder cannot be listed; culling continues, analysis pauses, and applying is unavailable until it returns.

Open:
- Nobody has yet opened Culla's sidecars in an editor. Your editor is Photomator; the check there is part of this milestone's gate. If Photomator stores its own flags and ratings in different fields, the quickest fix is to rate and reject one RAW file in Photomator and read the sidecar it writes, then have Culla write the same fields.
- Move to the Trash and its undo have not been run inside the app, because the automation fixtures live in the app's container and their Trash is the real one. The logic is tested outside the app.
- Not tried with real hardware: a card pulled mid-session, a locked card, a bookmark to a folder on another volume.

**Gate.** After Apply and then Undo Apply, the folder's file list and checksums match the start exactly. Your editor shows Culla's flags and ratings on import. A forced failure half-way through leaves no file lost or duplicated.

## M5 — Settings and tuning

Goal: every detection parameter is adjustable, and adjusting it shows its effect at once. Covers Flow 6.

- [x] Settings window (⌘,) with the panes from the Design doc: General, Eyes, Blur, Similarity, Duplicates, Exposure, Other, Performance, Keys.
- [x] Lenient, Balanced and Strict presets, set from the M0 results.
- [x] A live count beside every detection slider of the photos it would flag in the open shoot.
- [x] Tuning popover in each group header with that group's two or three main controls.
- [x] Session-only changes by default; Save as Default keeps them.
- [x] Key remapping for every shortcut, with conflict warnings.
- [x] Performance options: reduced speed on battery, cache size limit.

Built and checked on 2026-11-10. Every row of the Design's Settings table exists, built from the same control descriptions as the tuning popover so the two cannot disagree.

Rules settled while building it:

- Settings holds the default tuning. A shoot follows the default until a value is changed from its own tuning popover; from then on it keeps its own tuning across reopening. "Save as Default" copies it to the default; "Reset to Default" drops it.
- Balanced is exactly today's values. Lenient and Strict move every slider a quarter of the way from Balanced towards fewer or more flags (for example blur 19 / 25 / 39, eyes 0.21 / 0.26 / 0.32). Both are provisional until M7.
- Eyes and Blur sensitivity show 0 to 100 with 50 at the Balanced value and a note giving the raw threshold.
- Key remapping records one key per command, warns about conflicts by naming the other command, and leaves ⌘Q and the other system keys fixed.
- Two toggles, "Include subfolders" and "Treat RAW+JPEG as one photo", rescan the open shoot at once; photos that drop out lose their decisions. M6 adds a confirmation.

Also fixed in this milestone: the interface scripts no longer assert borderline detector outputs (Vision's lens-smudge confidence for two sample photos had moved across the provisional threshold between runs), the sidecar lookup before an apply is linear instead of quadratic, and photos whose analysis failed while a folder was unreachable are analysed when it returns.

**Gate.** Every row of the Design doc's Settings table exists and takes effect without a restart. Dragging a slider on a 5,000-photo shoot updates the group as you drag. Decisions made before a change are untouched by it.

## M6 — Polish and release

Goal: a signed 1.0 that a stranger can download and use without help.

- [x] Performance pass on a 10,000-photo shoot: grid, analysis, memory.
- [x] Accessibility: VoiceOver labels, full keyboard access, Reduce Motion, larger text. (Labels, Reduce Motion and Increase Contrast are done and checked; full keyboard access and larger text are checked in the source but not yet by hand, see below.)
- [x] Remaining empty, error and first-run states.
- [x] App icon and About window.
- [x] README, licence and contribution notes in the repository.
- [x] Signing, notarization and a disk image for download. The steps are written down in `Scripts/release.md`. They were first run on 2026-11-21, from the working tree before it was committed: the image was signed with Developer ID (team `Z32TPH2T97`), notarized, stapled, and accepted by Gatekeeper as "Notarized Developer ID". It is not published; the image to publish is rebuilt from the tagged commit. `Scripts/release.sh` now runs all of the steps (first full run, notarized and accepted, on 2026-11-21), and `.github/workflows/release.yml` runs it when a tag `v<version>` is pushed and attaches the image to a draft GitHub Release; the workflow first ran to the end on 2026-11-21 and left the `v1.0` draft release with a notarized image.
- [ ] Full pass of all eight flows on a fresh macOS user account.

Built and checked on 2026-11-10, up to signing. 504 unit tests and all 63 interface scripts pass; the Release build has no warnings, no network framework linked, and exactly the three sandbox entitlements when built with `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`.

Measured on the 10,000-photo generated shoot (optimised build, `Scripts/ui/59-performance-10000.json` and `60-reopen-10000-cached.json`; every number is written to the dump under `measurements`):

- The grid is shown about 1.2 s after opening; reopening from the cache has every group full at 1.5 s. The longest main-thread stall while opening is about 60 ms, within the 100 ms target.
- Paging through the whole grid during analysis, 300 loupe steps and accepting 100 stacks (median 7 ms) all stall for under 20 ms.
- Analysis runs at about 58 photos/s with 8 in flight on 1500 × 1000 files, peaking at about 1 GB. On 24 MP files decoding dominates at about 8 photos/s, and 8 in flight peak at about 2 GB, which is why the in-flight cap is physical memory ÷ 2 GB.
- 5,000 rejects, their undo, applying them (about 11 s) and Undo Apply (about 2 s) stall for under 50 ms. The Review and Apply plan is computed off the main thread for shoots over 3,000 photos, and Apply is disabled while a newer plan is pending, so a photo just rescued can never be applied.
- Memory is 318 MB after scrolling to the end, and 40 rounds of 24 mixed actions ended lower than they started (405 → 267 MB).
- Still over 50 ms: opening a Settings pane for the first time (200–300 ms, mostly setting the window frame, the same with no shoot open); opening Review and Apply (55 ms, SwiftUI building the screen); one stall of about 52 ms in an hour of mixed work. Fast paging delays analysis by several seconds, because analysis runs at utility priority and yields to the interface.

Rules settled while building it:

- Every tile, face-strip cell, key cap and toolbar control is a VoiceOver element with a name and, where it acts, actions (Keep, Reject, Clear Decision on tiles). The automation harness can dump a window's accessibility tree, but SwiftUI builds its elements only for a connected assistive app, so SwiftUI controls are checked in the source by `Scripts/check-accessibility.py`, which `ui-all.sh` runs first.
- Nothing depends on colour alone: selection has an outline, rejected frames in a mixed stack have a dashed ring and unreviewed ones a thin ring, the clipping overlay stripes shadows and fills highlights, closed-eye face boxes carry an eye-slash badge, and a failed save shows a warning in the status bar. Increase Contrast gives badges opaque rims and heavier outlines. All animation goes through one `SystemAccessibility` helper that honours Reduce Motion.
- The two rescanning toggles ask first, and only when photos would actually leave the session, giving the counts of photos and of decisions that would be lost.
- A key cap remaps only that key; + adds an alternate, so pairs such as ⌘= / ⌘+ survive. ⌘/ and ⇧⌘/ are reserved for Help ▸ Keyboard Shortcuts.
- The first-run introduction, the cheat sheet and the Dock menu read from live data (the key map, the recent shoots), never from fixed text. The one exception is the stack-review legend, which does not follow remapped keys.
- Help ▸ Culla Documentation opens the docs folder; a Release build only finds a `docs` folder beside the app, so it never leaks the build path.
- The icon is drawn by `Scripts/make_icon.swift` into the asset catalog: a 3 × 3 grid of photos with the middle one green and ticked, no text; below 64 px the tiles snap to whole pixels and the tick is dropped.

Not yet checked, needing a person or another Mac: VoiceOver used for real, Full Keyboard Access turned on, larger text sizes, focus rings (they draw only in a key window, which an automation run never has), a card pulled mid-session and a locked card, Photomator reading the sidecars, Trash and its undo in the app, and closed eyes on real faces.

Changes after the owner's first use, 2026-11-11:

- The thumbnail-size control in the toolbar sat outside its glass capsule: the system draws the capsule around the item's view, and the view had no insets. It now has a fixed size with 11 pt insets. The scripted snapshots do not draw the toolbar glass, so toolbar changes are checked with a real screen capture of the Debug build on the sample shoot.
- Stack review: H shows or hides the best pick pane (also View menu and Settings ▸ General, remembered for every shoot); with it hidden the current frame fills the row. Hiding the face strip with F now gives its height to the frames; before, the hidden strip kept its space. A stack with no faces shows no strip. Checked by `Scripts/ui/64-stack-review-panes.json`.
- Stack review: F now means faces on or off. It hides the boxes over faces on both frames together with the strip, the hint line reads "F hide faces" or "F show faces", the View menu item reads "Hide Faces" or "Show Faces" there, and the face-box command (B) is disabled while faces are hidden. The loupe is unchanged. Script 64 checks the box counts, the hint and B. Not checked by running: the greyed menu item and its missing checkmark, which no script can read.
- Key text follows remapped keys everywhere: the Settings notes, the stack, compare and duplicate review hint lines, tooltips, the undo notices and the apply screen were fixed text. `KeyText` in `CullaCommands` now builds them. Left as fixed text: the collapsed-stack tile's tooltip ("Return or double-click to review it"), which has no access to the key map.
- A thumbnail that failed to load at the moment a folder disconnected was never loaded again, so its tile stayed blank after the folder returned (script 47 failed about 1 run in 15). The same gap existed for the loupe image and the stack, compare and duplicate panes. Failed loads now wait for the folder and retry; script 47 forces the ordering and passed 40 runs in a row. Not covered by a script: the compare and duplicate panes after a disconnect, and the 2 s retry for a folder that returns before the monitor saw it go.

Localization, 2026-11-12 (after v1):

- The interface is in English, Russian and Turkmen: 1,130 entries in 8 string catalogs, every one with a translator's comment, all translated in both languages (`Scripts/l10n.py check --require ru,tk`). Rules, style and glossary are in `docs/localization.md`; how it is built is in `docs/architecture.md`.
- Every sentence is one catalog entry with plural variations; the roughly 60 places that chose a plural with `count == 1` or joined fragments are gone. Several English sentences changed for grammar on the way (for example "1 stack decided", "Copies 3 photos…").
- Settings ▸ General ▸ Language: System default, English, Русский, Türkmençe, with a button to quit and reopen. System default follows the system's language order and falls back to English.
- Keys work by position on layouts that do not type Latin letters: «з» on the P key keeps, «ч» on the X key rejects, and a key recorded in Settings on such a layout is stored as its Latin position. Checked by `Scripts/ui/68-keys-other-layouts.json`.
- Layout for longer text: the sidebar is as wide as its longest group name; hint lines never lose their start and drop whole hints from the end (`HintLine`); the tuning popover, result banner, loupe badges, duplicate review header, copy card, preset picker and the NEW pill reflow or grow. Checked at 1280 pt and at the 900 pt minimum width.
- Mark Only's explanation now follows the sidecar settings for the reject rating and label; it used to say "rating −1 and the Red label" whatever they were.
- Verification: `65-screens-en`, `66-screens-ru` and `67-screens-tk` walk the same 49 screens and save snapshots, menu titles and accessibility trees; `Scripts/l10n-screens.py` reports no text left in English in either language.
- Not checked: a language change made in Settings taking effect on a real relaunch (runs set the language on the command line, and the quit-and-reopen button is only recorded); what an Xcode IDE build writes into the package catalogs (`Scripts/l10n.py clean` removes it); the face strip's ordinal row labels on screen; the Turkmen text read by a native speaker.

Top bar, 2026-11-12 (after localization):

- The main window's toolbar is replaced by a flat bar the app draws itself, in the style the owner asked for: no glass capsules, icon buttons without a background until hovered, a flat view switch, plain status text, a thin slider, and Review and Apply as the one filled button. It is 40 pt tall, 12 pt less than the system toolbar, so the photo area gains that height (script 64's pane heights changed accordingly).
- While analysing, the pause button sits directly after the status text.
- The bar holds English, Russian and Turkmen at 1280 pt and at the 900 pt minimum width; the walks snapshot it analysing and paused at both widths.
- Not checked: real pointer use (hover fills, dragging the window by the bar, double-click to zoom or minimise), full screen, macOS 26, Full Keyboard Access through the bar, and the system's Increase Contrast setting on the bar.

Release pipeline, 2026-11-21:

- The first run of the release workflow on GitHub's runner (a virtual Mac without a Neural Engine) lost two test processes to a trap inside Vision's lens-smudge request. The analyzer now skips a Vision request this Mac has no device for (`VisionAvailability`); the tests pass on the runner with lens smudge skipped there.
- The second run stopped in `release.sh`: in the C locale of GitHub's runner, bash read the first byte of an ellipsis as part of the variable name before it. Such variables are braced now.
- Not done: on a Mac without a Neural Engine, Settings still shows the Lens smudge switch, its threshold and a count that is always 0, which reads as "no smudged photos" although the check never ran. Saying so needs new text in three languages.
- Not checked: an Intel Mac. The app is built for both architectures, but nothing has been run on one.

**Gate.** The notarized build opens without a security warning on a Mac that has never seen it, and all eight flows pass from the keyboard alone.

## M7 — Detection tuning

Goal: defaults you trust on your own photos. Done last, in the finished app, where a slider shows its effect at once.

- [ ] Run the app on several different shoots: portraits, groups, low light, daylight, phone photos.
- [ ] Eyes closed: confirm or replace 0.26, and decide whether small faces need their own, stricter value.
- [ ] Decide how Core Image's blink flag and the openness score combine.
- [ ] Blurry: confirm or replace 25; check very dark photos, which read as soft.
- [ ] Exposure: replace the provisional 30% and 50% using photos that really are ruined.
- [ ] Stacks and duplicates: confirm the 10 s gap, the 0.60 distance and the 0.08 near-duplicate distance.
- [ ] Set the Certain cut-offs for eyes closed and blurry, which decide what ⇧X may reject in bulk. Until then they are provisional values in Settings.
- [ ] Set the Lenient and Strict presets around the confirmed Balanced values.

**Gate.** On three shoots of different kinds, you agree with what each group flags at the Balanced preset, and the Certain tier contains no photo you would keep.

## M8 — Checking for updates

Goal: a person running an older Culla hears that a newer one exists, without the app doing anything else online and without being interrupted while culling. The rules are in `docs/architecture.md` ("Checking for updates"); what the person sees is in `docs/design.md` and Flow 9 of `docs/user-flows.md`.

- [x] `CullaUpdates` in the package: version comparison, the update document, the decision, the schedule and the skip rule as pure functions with unit tests, and the request itself (ephemeral, no cookies, no cache, three fixed headers, HTTPS only, no redirects, 64 KB at most), tested against a stub. 34 tests.
- [x] The app: the automatic check at most once a day, the line on the welcome view with Download, Release Notes and Skip This Version, Culla ▸ Check for Updates… with its four answers, and the Updates section in Settings ▸ General.
- [x] Text in English, Russian and Turkmen: 22 entries.
- [x] Interface scripts with canned outcomes (`Scripts/ui/69` to `71`, and the update screens in the three language walks); under automation the app never touches the network.
- [ ] Run those scripts through `Scripts/ui-run.sh`. On 2026-11-24 they passed only against an unsandboxed Debug copy with a four-photo shoot, because the session that built them was refused access to the app's container by macOS and had no Pillow for the sample shoot. The Russian and Turkmen walks stopped after the update screens for want of the 35-photo sample.
- [x] The fourth entitlement, `com.apple.security.network.client`, and the release scripts' checks for exactly four. `otool` still shows no network framework linked (URLSession comes with Foundation), so `release.sh` also refuses network code in the sources outside `CullaUpdates`.
- [x] The site: `update.json` written from `release.json` at build, tests for it, and the wording about the network corrected in three languages. Neither the nginx configuration nor `count.py` changed, so the server needs no root step.
- [x] The docs: architecture, design, user flows, README, contributing, the release guide and the landing page plan.
- [x] Deploy the site so `https://cullaapp.com/update.json` exists. Deployed on 2026-11-24; the file answers with an empty date until 1.0 is published.
- [x] Decide which version first carries the check: 1.0. Its release on GitHub was still a draft, so 1.0 is built again as build 2 and every published copy has the check (decided on 2026-11-24).
- [x] Build 1.0 again. Done on 2026-11-24: the draft with build 1 was deleted, the `v1.0` tag was moved to `373844a` and pushed, and the release workflow ran to the end and left a new draft with the notarized build 2.
- [x] Publish the draft, fill in `site/release.json` and deploy the site. Done on 2026-11-24: 1.0 is published, `/download` redirects to its image and `update.json` carries the date.
- [ ] Open the published 1.0 and choose Culla ▸ Check for Updates…: it must answer that 1.0 is the newest version (owner).

Checked on 2026-11-24: every package test run passes, the Debug and Release configurations build, the Release image passes the four-entitlement check, the translation and accessibility checks pass, and `site/test.sh` passes. The request was captured on a local listener and carries only the fixed headers.

**Gate.** Not passed yet: it waits for the interface scripts under `Scripts/ui-run.sh` and for the deployed site. With a canned answer naming a newer version, the welcome view shows the line and Skip This Version removes it; a real check against the deployed site answers "this is the newest version"; the Release build has exactly the four entitlements and no network code outside `CullaUpdates`.

## Testing

Each layer is checked the cheapest way that still catches its failures.

| Layer | How it is checked | When |
| --- | --- | --- |
| Detectors | `culla-eval` re-runs a shoot and lists the photos whose scores or groups changed; you review those by eye | On every detector change |
| Thresholds and grouping | Unit tests on fixed tables of scores, with no images involved | On every build |
| Files: pairing, sidecars, apply, undo | Unit tests on temporary folders, including a forced failure mid-apply | On every build |
| Key flows 1, 2, 3 and 7 | Automated interface tests driven by the keyboard | Before each milestone gate |
| Remaining flows and edge cases | By hand, against the User Flows doc | At each milestone gate |
| Speed and memory | A generated 10,000-photo folder | M1, M2 and M6 |

## Risks

The two detection risks are the ones that could change the product, which is why M0 comes first.

| Risk | What it would cause | Fallback |
| --- | --- | --- |
| Eyes-closed detection raises false alarms on sunglasses, profiles, laughter and small faces | A group nobody trusts | Limit it to large frontal faces; ship it as Likely-only with no bulk reject |
| The blur measure flags intentional soft backgrounds or panning shots | Good photos flagged | Measure the subject only; inside a stack, rank frames against each other instead of an absolute bar |
| Stacks merge different scenes or split one burst | Manual fixing in every shoot | Keep the time gap as a hard limit; tune on your shoots; G and ⇧G for corrections |
| Matching the same person across frames is unreliable | Face strip rows mix people | Order faces by position in the frame; fall back to crops per frame without rows |
| A RAW format decodes slowly or is unsupported | Slow analysis or missing photos | Analyse the embedded preview; show unsupported files as unreadable |
| The sandbox limits moving files or writing sidecars beside photos | Apply fails | Access is granted for the whole opened folder; verified in M1, before M4 depends on it |
| Thresholds tuned by eye on a few shoots do not suit other cameras or subjects | Too many or too few flags for other people | Presets and sliders let each person adjust; defaults are revisited whenever you report a bad shoot |
| A 10,000-photo session strains memory | A sluggish grid | Thumbnails cached on disk and decoded only when visible |

## Needed from you

Nothing blocks the start of M0. The open items are needed at the milestone each one names.

- [x] Git repository created in the Culla folder.
- [x] Go-ahead to create the Xcode project.
- [x] A bundle identifier for the app: `com.kpirliyev.Culla`, confirmed on 2026-11-21.
- [x] Licence for the open-source release: MIT.
- [ ] Two or three of your real shoots on disk to run `culla-eval` and the app on, ideally with bursts, group shots and some blurry frames. No sorting or labelling. Needed when the M0 detectors run. Keep them outside this repository.
- [ ] The cameras or phones you shoot with, so their RAW formats are tested.
- [x] The editor you hand off to: Photomator. Whether it reads Culla's sidecars (stars, the reject mark, the colour label) is to be checked in the application as part of M4's gate.
- [x] An Apple Developer account for signing and notarization. In place since 2026-11-21; the bundle identifier stays `com.kpirliyev.Culla`.

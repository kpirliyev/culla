# Scripts

- `make_sample_shoot.py <dir> [--count N]` builds a test shoot from the wallpapers that ship with macOS. Use only these generated shoots to check the interface; the owner's photos are private.
- `make_large_photos.py <dir>` builds ten photos for the loupe's zoom: a burst of six 24 MP frames (6000 × 4000) with a resolution chart near (0.6, 0.4) that is crisp only at 100%, an over- and an under-exposed frame, a portrait and a small photo.
- `ui-run.sh <script.json> [options]` runs a UI automation script against a Debug build and prints the folder holding its results.
- `ui-all.sh [--quick] [--optimized] [--only <pattern>]` builds once and runs every script in `ui/` with the setup its `needs` header asks for, then prints a pass/fail table (see below).
- `ui/` holds the example scripts.
- `make_icon.swift [appiconset] [--preview <folder>]` draws the app icon with Core Graphics and fills every slot of `Culla/Assets.xcassets/AppIcon.appiconset`; `--preview` also writes 16, 32, 128 and 1024 pixel renders to check legibility.
- `check-accessibility.py` checks the SwiftUI sources for controls VoiceOver could not name (`ui-all.sh` runs it first).
- `l10n-screens.py <run> <English run> [--allow <file>]` lists the text a run in Russian or Turkmen still shows exactly as the English run does (menus, accessibility trees, dump text), leaving out what is the same in every language. See "Screens in other languages" below.
- `l10n.py` checks, exports and imports the translations in every `*.xcstrings` catalog (Python standard library only; the translator's file format is described at the top of the script). `l10n.py check` finds entries without a comment, placeholders that differ from the English, missing plural forms and stale or duplicate keys; `check --require ru,tk` also fails on anything untranslated. `l10n.py stats` counts translated and missing entries per catalog. `l10n.py clean [--dry-run]` undoes what building in the Xcode IDE may do to the catalogs: it removes entries Xcode's string extraction added (not `manual`, no comment; the extraction files a key of its own such as "hint.pick" again under its English default) and marks a stale entry the Swift code still uses `manual` again, listing stale entries nothing uses. It writes only when something changed. The app target has extraction off (`SWIFT_EMIT_LOC_STRINGS = NO`); Swift packages have no supported setting to turn it off, so run `clean` (and then `check`) after working on the package in Xcode. `l10n.py export ru --out ru.json [--missing-only]` writes what a translator needs, and `l10n.py import ru ru.json` merges it back after checking it. See `docs/localization.md`.
- `site-shots.sh [shoot folder] [--evidence <file name>]` makes the landing page's screenshots; see "Screenshots for the site" below.
- `make-dmg.sh [--build] [--app <Culla.app>] [--out <dmg>]` makes a disk image from a Release build, after checking it holds no automation code and exactly the four entitlements (sandbox, user-selected files, app-scoped bookmarks, outgoing connections for Check for Updates). It signs nothing; with `--build` the app is ad hoc signed, for a rehearsal without an account.
- `release.sh [--tag <tag>] [--out <folder>] [--skip-notarize] [--preflight]` makes the release image: archives, exports with Developer ID, checks the app, makes the image with `make-dmg.sh`, signs it, notarizes it, staples the ticket and asks Gatekeeper. `.github/workflows/release.yml` runs it when a tag `v<version>` is pushed and attaches the image to a draft GitHub Release. `release.md` explains every step and the one-time setup.
- `crash-reports.py [--minutes N] [--max-reports N] [--max-lines N]` prints the newest macOS crash reports: the exception, the termination reason and the crashed thread's backtrace. The GitHub workflows run it when the package's tests fail, because a test process that dies inside a system framework leaves nothing in the test output. `.github/workflows/tests.yml` runs the tests and the translation check on GitHub's runner without a release tag (on pushes to `main` that touch the code, or started by hand).

## Running a script

```bash
Scripts/ui-run.sh Scripts/ui/01-first-open.json --reset
```

`ui-run.sh` builds the Debug app (DerivedData outside the repo; override with `CULLA_DERIVED_DATA`), copies the shoot into the app's sandbox container under `~/Library/Containers/com.kpirliyev.Culla/Data/tmp/CullaAutomation/shoots/`, starts the app in the background with the script, waits for it to quit, and prints the output folder (`…/CullaAutomation/runs/<script>-<time>-<pid>/`). It holds the PNG snapshots, the JSON dumps, `result.json` (every step with its time, and the failure if any) and `app.log`.

| Option | Meaning |
| --- | --- |
| `--shoot <folder>` | The shoot to copy in. Default: the 35-photo sample, generated once. Inside the script it is `$SHOOT`. |
| `--keep-shoot` | Reuse the copy already in the container, so files you add to or remove from it between runs stay that way. |
| `--reset` | Start from nothing: delete the automation database, thumbnails and settings. Without it they are kept, which is how reopening is tested. |
| `--no-build` | Skip the build. |
| `--timeout <s>` | Kill the app after this long (default 300). |
| `--store` | Build and run the Debug Mac App Store variant (`CULLA_DISTRIBUTION=appStore`: no update check, three entitlements) into a DerivedData folder of its own, the usual one with `-store` added. |

Exit status: 0 when every step passed, 1 when a step failed, 2 when the build failed, 124 on timeout.

Automation runs never touch a person's sessions: they use their own database (`Application Support/Culla-Automation`), thumbnail cache and settings. The app runs without a Dock icon, never takes focus, and quits by itself; a watchdog ends it when the script's `timeout` passes. Keys are sent through the same key router real key presses use. The harness is compiled into Debug builds only.

## Running every script

```bash
CULLA_SHOOT_2000=<2,000-photo shoot> CULLA_SHOOT_5000=<5,000-photo shoot> Scripts/ui-all.sh
Scripts/ui-all.sh --quick          # leaves out the slow large-shoot scripts
Scripts/ui-all.sh --optimized --only 22   # performance numbers with the optimizer on
```

Each script says what it needs in a `needs` object at its top, so the setup is data rather than knowledge in the shell script:

| Key | Meaning |
| --- | --- |
| `"reset": true` | Run with `--reset`. |
| `"shoot": "sample"` | `sample` (35 photos, the default), `large` (`make_large_photos.py`), `2000`, `5000` or `10000` (`make_sample_shoot.py --count N`). Missing fixtures are generated once into `$CULLA_FIXTURES` (default: `culla-fixtures` beside the DerivedData folder); `CULLA_SHOOT_2000`, `CULLA_SHOOT_5000` and `CULLA_LARGE_PHOTOS` point at existing ones. |
| `"after": "<script>"` | Runs only when that script passed earlier in the same run (scripts run in file-name order). |
| `"keepShoot": true` | Run with `--keep-shoot`. |
| `"prepare": [["copy", "a.jpg", "b.jpg"], ["remove", "c.jpg"]]` | Changes the container's copy of the shoot first (a copy is touched, so it is newer). |
| `"slow": true` | Left out by `--quick`. |
| `"timeout": 600` | Seconds before `ui-run.sh` gives up. |
| `"store": true` | For the Mac App Store variant only. `ui-all.sh` builds the direct variant and skips the script; run it with `ui-run.sh --store`. |

`--optimized` builds the Debug app (harness included) with `-O` into its own DerivedData. Use it for analysis speed: unoptimized pixel loops make analysis in a plain Debug build about three times slower than `culla-eval`.

## Script format

A script is a JSON object with a `steps` list and optionally `needs` (above), `timeout` (seconds, default 180), `window` (`[width, height]` of the window in points), `language` (`en`, the default, `ru` or `tk`: `ui-run.sh` launches the app with `-AppleLanguages (<language>)`, so a run never depends on the Mac's language or the language chosen in Settings) and `output` (a folder; `ui-run.sh` sets it). Each step is an object whose key names the action:

| Step | Does |
| --- | --- |
| `{"open": "$SHOOT"}` | Opens a folder (no open panel) and waits until it has loaded. Relative paths are relative to the script. |
| `{"openRecent": 0}` | Opens a recent session by position or by name. `"allowProblem": true` lets a failed open pass, to check the message. |
| `{"close": true}` | Closes the shoot. |
| `{"wait": "idle", "timeout": 60}` | Waits until nothing is loading, saving or decoding and every visible tile has its thumbnail (or the loupe its image). Background analysis does not count: it never holds up `idle`. |
| `{"wait": "analysis"}` | Waits until analysis has finished and its final grouping is applied, then for `idle`. |
| `{"wait": "grouping"}` | As `analysis`, and also until the stacks and duplicate sets asked for by the last tuning change are applied. |
| `{"wait": "confirmation"}` | Waits until the ⇧X confirmation sheet is up. |
| `{"analysis": "pause"}` | Pauses analysis (or `"resume"`) and waits until the engine says so. Photos already in flight still finish. |
| `{"tuning": {"blurryBelow": 15}}` | Sets the open shoot's `Tuning` values by name (`TuningKey` in CullaCommands; switches take `true`/`false`), the way the tuning panel does: regroups at once, and the shoot keeps its own tuning with its session (the default is untouched). `{"reset": "blurry"}` resets that group's controls to the default's values. |
| `{"popover": "tuning"}` | Opens the tuning panel of the current group and waits until it shows (`"close"` closes it). Snapshots include it. |
| `{"confirm": true, "question": "Reject 6 photos that are certainly blurry?"}` | Answers the ⇧X confirmation (`true` or `"cancel"`), checking its question when given. |
| `{"sleep": 0.5}` | Waits this many seconds. |
| `{"key": "p", "repeat": 3, "interval": 0.03}` | Presses a key through the key router. Keys: a character (`p`, `3`, `]`) or `left right up down space return tab escape delete home end pageup pagedown`, with `cmd+`, `shift+`, `opt+`, `ctrl+` before them, such as `shift+cmd+z`. Fails when the key is not bound. |
| `{"keys": ["left", "shift+right"]}` | Presses several keys in turn. |
| `{"key": "з", "keyCode": 35, "modifiers": "cmd"}` | A key event as another keyboard layout delivers it: the typed characters on the key with that virtual key code (`kVK_ANSI_P` is 35, `kVK_ANSI_X` 7), read by the same conversion real events go through, so a typed character that is not printable ASCII counts as the key's US-layout position. Fails when the result is not bound. |
| `{"command": "keep", "repeat": 1}` | Sends a command by name (see `Command` in CullaKit/Sources/CullaCommands). Fails when it is unavailable unless `"allowUnavailable": true`. |
| `{"group": "unreviewed"}` | Opens a sidebar group (`allPhotos duplicates similarStacks eyesClosed blurry exposure otherIssues unreviewed kept rejected`). |
| `{"click": "a.jpg", "modifiers": "cmd"}` | Clicks a tile, by photo id or position in the view; `shift` extends, `cmd` toggles, `"count": 2` opens the loupe (a collapsed stack: stack review). `"in": "filmstrip"` clicks the loupe's filmstrip cell instead, `"in": "stack"` a frame of stack review's filmstrip. In All Photos a collapsed stack is clicked by the photo its tile shows (`gridOrder` in the dump). |
| `{"faceCell": [row, column]}` | Clicks a cell of the face strip on screen (stack review, or the loupe's with F), counting from 0. |
| `{"comparePane": 1}` | Clicks a compare pane, which gives it the focus. |
| `{"windowSize": [1280, 800]}` | Sets the window size. |
| `{"snapshot": "name"}` | Writes `name.png`: the window as drawn by the app (`NSView.cacheDisplay` of the window frame, sheets drawn over it), at the screen's scale. `"scale": 2` (or `1`) for that many pixels per point whatever screen the window is on, `"method": "layer"` for `CALayer.render` instead. No screen-recording permission is needed. |
| `{"dump": "name", "photos": false}` | Writes `name.json`: screen, totals, group counts, current group, view mode, focus, selection, undo and redo with their menu titles, the longest main-thread stall, memory (with `peakFootprintMB`), open timings, the last Reveal in Finder or Copy File Name (`lastFileAction`), the loupe's state (below), analysis (below), `stacks` (members, best pick), `duplicateSets` (kind, members), `stackCount`, `exactDuplicateSets`, `nearDuplicateSets`, `tuning` (every `TuningKey`), `tuningPanel` (group, shown, `groupTotal` before and after, count `lines`), `emptyReason`, `summaryBanner`, `notice`, `completedGroup`, `nextGroupToReview`, `confirmation`, `certainLeft`, `pinnedScores`, `power`, and (unless `photos` is false) `groupMembers` and every photo's decision, rating, marks, flags, `tiers` (flag to `certain`/`likely`), `hasScores` and main faces. |
| `{"expect": {"totals.kept": 2, "photo:a.jpg.decision": "kept"}}` | Checks values of the dump; the run fails on the first mismatch. Paths are dotted (`groups.kept.total`, `recents.0.name`, `loupe.zoomPercent`); `photo:<id>.<field>` reads one photo (`decision`, `rating`, `flags`, `mainFaces`, `tiers.blurry`). `"tolerance": 0.002` lets numbers, alone or in lists, differ by that much. |
| `{"injectScores": "burst", "frames": ["a.jpg", "b.jpg"], "people": [{"box": [x, y, w, h], "eyes": 0.8}], "blink": [[1, 0]], "missing": [[2, 1]], "drift": 0.003, "sharpness": [55, 60]}` | Gives the frames of a burst consistent faces: each person at nearly the same place in every frame (moved by `drift` per frame and a small wobble), the listed `[frame, person]` blinking (eyes 0.08) or missing, each frame's sharpness from the list (default 60). Frames and people count from 0. Stacks holding injected photos get the best pick `BestPick` makes from the injected scores. |
| `{"injectScores": {"a.jpg": {...}, "b.jpg": null}}` | Gives photos made-up scores, as analysis would (debug builds only): `{"faces": [{"box": [x, y, w, h], "eyes": [left, right], "size": 0.2, "yaw": 0, "sharpness": 40, "peak": [x, y]}], "focus": [x, y], "sharpness": 60, "clipping": [highlights, shadows]}`. Boxes and points are unit image coordinates, origin top left; `size` defaults to the box height; `null` removes a photo's scores. Groups, badges and the loupe follow at once. **With real analysis:** injected photos are pinned until the shoot closes; analysis results for them (scores or unreadable) are ignored, and injected scores are never saved to the cache. Inject after `{"wait": "analysis"}` when a script also expects counts that real analysis contributes to. |
| `{"zoom": 1, "centre": [0.6, 0.4]}` | Sets the loupe's zoom: a factor (1 is 100%, one image pixel per display pixel) about a centre in unit image coordinates (default: where it is), or `"fit"`. |
| `{"pan": [0.6, 0.4]}` | Moves a zoomed loupe's centre. |
| `{"contextMenu": "a.jpg", "item": "Reject"}` | Opens a tile's context menu (`"in": "filmstrip"` for a filmstrip cell) and chooses an item by title (a rating by its own title, such as `"3 Stars"`). `"items": [...]` checks the enabled items first, submenu items as `"Rating ▸ 3 Stars"`. Menus are built and run, not drawn: a snapshot does not show them. |
| `{"band": ["a.jpg", "d.jpg"]}` | Drags a rubber band in the grid from the gap above and left of one tile to the middle of another, through the grid's own mouse handlers. `"modifiers": "shift"` adds to the selection. |
| `{"menuItem": ["File", "Open Recent", "Clear Menu"]}` | Chooses a menu bar item by its path of titles; fails when it is disabled. |
| `{"resetStalls": true}` | Starts a new stall-measuring window (`stall.windowLongestMs` in the dump). |
| `{"settings": {"advanceAfterDecision": false}}` | Changes settings as the Settings window does (`advanceAfterDecision`, `includeSubfolders`, `thumbnailSize`, `reduceAnalysisOnBattery`), or acts as if on battery: `"simulateBattery": true` (`null` follows the real power source again). |
| `{"settings": {"rejectAction": "markOnly", "writeSidecars": false, "editorApplication": "/Applications/Photomator.app"}}` | The apply settings too (the editor need not exist: automation only records Open Keepers In). |
| `{"applyScreen": "open"}` | Opens Review and Apply (⌘Return) and waits for its plan and visible thumbnails; `"close"` leaves it. |
| `{"applyAction": "markOnly", "sidecars": false, "makeDefault": true}` | Chooses the action (`moveToRejectedFolder`, `markOnly`, `moveToTrash`) and sidecars on the screen, optionally saving them as the default. |
| `{"applyFocus": "a.jpg", "modifiers": "shift"}` | Clicks a reject on the screen (then P rescues, Space peeks). |
| `{"fault": {"failAt": 4, "crashAt": 5, "cancelAt": 3, "holdAt": 2, "delayMs": 20}}` | Injects a fault into the next run, by step index: fail that step; end the app abruptly before it (after writing a passing `result.json`, so a following script can expect the recovery offer); cancel after it; hold before it until `{"releaseHold": true}` (for snapshots of progress); slow every step. |
| `{"releaseHold": true}` | Lets a held run go on. |
| `{"undoApply": true}` | Undo Apply without its confirmation, and waits for it. (The menu item and ⌘Z ask first: answer with `confirm`.) |
| `{"bannerAction": "undo"}` | Uses a button of the banner: `undo`, `retryUndo`, `recoveryUndo`, `keepAsIs`, `reveal`, `openKeepers`, `done`. Undo waits for the undo to end. |
| `{"copyKeepersTo": "$SHOOT/../CullaCopyDest"}` | On the read-only screen: (re)creates that folder in the container and plans Copy Keepers To into it. |
| `{"fixture": {...}}` | Changes the shoot copy while the app is open: `{"rename": [a, b]}`, `{"add": [from, to]}` (made newer), `{"delete": a}`, `{"modify": a}` (appends a byte), `{"write": [path, text]}`, `{"readOnly": true}`, `{"disconnect": true}` (the folder made unreadable, as a pulled card; `false` brings it back), `{"move": "NewName"}`. Refused outside the container. |
| `{"rescan": "focus"}` | Rescans as when the window becomes key again (`"menu"`: Rescan Folder), and waits for it. |
| `{"saveHash": "name"}`, `{"expectHash": "name"}` | Saves the listing hash of the shoot folder (in the container's `tmp/CullaAutomation/hashes`, so a later script can compare), or fails unless the folder's paths, sizes, contents and (unless `"stamps": false`) modification times equal it. |
| `{"fileContains": "a.xmp", "text": ["Green"], "absent": ["Red"]}` | Checks a file in the shoot. |
| `{"wait": "apply"}` and `applied`, `undone`, `held`, `disconnected`, `reconnected`, `undoable`, `recovery` | Waits for the plan, the end of a run, a held run, the shoot to go or come back, an undoable run, the recovery offer. |
| `{"settingsWindow": "eyes"}` | Shows the Settings window on a pane (`general eyes blur similarity duplicates exposure other performance keys`), without taking the focus, and waits until it is laid out; `"viaKey": true` opens it with ⌘, through the key router first. `"close"` closes it. |
| `{"snapshot": "name", "window": "settings"}` | Snapshots the Settings window instead of the main window. |
| `{"settings": {"default": {"blurryBelow": 15}, "resetPane": "blur"}}` | Detection defaults as the Settings panes set them (`TuningKey` names; the open shoot follows unless it has its own tuning), and a pane's Reset to Defaults. The `settings` step also takes `pairRAWWithRendered`, `collapseStacksInAllPhotos`, `showsBestPickPane`, `cacheLimitGB`, `writesRating`, `rejectedRating`, `keptLabel`, `rejectedLabel`, `language` (`en`, `ru`, `tk` or `system`, as Settings ▸ General ▸ Language sets it; kept in the automation suite only and never applied to the run, whose language the script's `language` sets) and `"quitAndReopen": true` (the Language setting's button; automation records it in `language.quitAndReopenRequested` instead of quitting). |
| `{"preset": "lenient"}` | Chooses a preset in Settings (`lenient balanced strict`). |
| `{"tuningAction": "saveAsDefault"}` | The tuning panel's Save as Default, or `resetToDefault`; `useDefaultFromSettings` is Settings' Use Defaults for This Shoot. Waits for the save. |
| `{"bindKey": "keep", "chord": "k", "replace": true}` | Settings ▸ Keys: clicks the command's key and presses the chord through the recorder. A chord in use leaves the conflict warning up (`settingsWindow.conflict`) unless `replace` takes it from the other command. It replaces only that key, by default the command's first; `"replacing": "cmd++"` picks another, `"add": true` clicks + to add one. Without `chord` it only starts recording. `"typed": "л", "keyCode": 40` instead of `chord` presses a key as another layout delivers it, as in the `key` step. |
| `{"keyRecorder": "cancel"}` | `cancel`, `confirm` (take the chord from the other command) or `resetAll`. |
| `{"cache": "measure"}` | Measures the caches into the dump's `cache`; `clear` removes every thumbnail, `clearWithMemory` also those held in memory (new tiles must then read the photos), `clearAll` also every cached score, `prune` applies the size limit. |
| `{"expectMatch": {"summaryBanner": "^35 photos · \\d+ stacks"}}` | Like `expect`, but each value is a regular expression the dumped value's text must match. For numbers that come from a borderline detector reading. |
| `"expectFailure": "<pattern>"` on any step | The step passes only when it fails, with an error whose text matches the regular expression: for checking that something is refused, such as an `updates` step in the Mac App Store variant. |
| `{"log": "text"}` | Writes a line to the log. |
| `{"record": "open", "values": {"shownMs": "open.shownMs"}}` | Records a measurement under `measurements.<name>` in every later dump: the longest main-thread stall since the last `resetStalls`, stalls over 50 and 100 ms, the stretch's length, memory now and at peak, and the dump values named. |
| `{"expectAtMost": {"measurements.open.longestStallMs": 100}}` | Fails when a dumped number is larger. |
| `{"dragSlider": "blurryBelow", "from": 25, "to": 45, "steps": 40, "interval": 0.016, "in": "settings"}` | Moves a detection slider in small steps as a drag does, in Settings (the default tuning) or `"in": "panel"` (the open shoot's tuning panel). |
| `{"loop": 40, "steps": [...]}` | Runs the steps that many times; each inner step is listed in the dump's `loopSteps` with when it began. |
| `{"accessibility": "main", "save": "a11y-grid", "check": {"unlabelled": 0, "contains": [["AXImage", "sonoma_0.jpg"]], "absent": [...], "atLeast": [["AXImage", "", 10]], "actions": [["AXImage", "sonoma_0.jpg", "Keep"]]}}` | Reads the accessibility tree of a window (`main`, `settings`, `about`, `help`): role, name, value and actions of every element, written to `<save>.json`, and checks it (an empty role matches any). It sees the AppKit side (toolbars, tiles, filmstrips, face-strip cells, the loupe, window buttons); SwiftUI builds its elements only for a connected assistive app, so controls inside SwiftUI views are listed under `swiftUIUnnamed`, not counted, and checked by `check-accessibility.py` instead. |
| `{"window": "about"}` | Shows the About window, `help` the keyboard cheat sheet, `close` both; `docs` records the folder Help ▸ Culla Documentation would open (`auxiliary.opened`), `dockMenu` the Dock menu's items (`auxiliary.dockMenu`). Snapshot them with `{"snapshot": "x", "window": "about"}`. |
| `{"firstRun": "dismiss"}` | Dismisses the welcome view's introduction (`reset` shows it again); the dump's `introductionShown` says whether it shows. |
| `{"scanToggle": "includeSubfolders", "value": false}` | Changes a setting that rescans as Settings does, through its confirmation (`settingsWindow.scanConfirmation`); `{"scanToggle": "confirm"}` or `"cancel"` answers it. Also `pairRAWWithRendered`. |
| `{"systemAccessibility": {"increaseContrast": true, "reduceMotion": true}}` | Stands in for the system's display settings (`null` follows the system again). |
| `{"keyboardFocus": "next", "repeat": 3, "window": "settings"}` | Moves the key view as Tab does; the dump's `keyboardFocus` (and `settingsWindow.keyboardFocus`) names it, `fullKeyboardAccess` says whether the system setting is on. Focus rings draw only in the key window, which an automation run never is. |
| `{"updates": "canned", "outcome": "available", "version": "1.1", "minimumSystem": "26.0", "delayMs": 0}` | Check for updates under automation, which never touches the network and never checks on its own: sets the answer later checks get, as a made-up update file that `CullaUpdates` decides on (`available`, `upToDate`, `unpublished`, `needsNewerSystem` with `minimumSystem` default 99.0, `invalid`) or no answer (`failed`); `delayMs` holds the answer back. `{"updates": "check"}` is Culla ▸ Check for Updates… (`"from": "settings"`: Check Now, the alert on the Settings window) and waits for its alert (`"background": true` returns at once; `{"updates": "awaitAlert"}` waits). `{"updates": "automatic"}` runs an automatic check as if one were due. `{"updates": "alert", "button": 0}` (or a title) clicks the alert's button; `{"updates": "notice", "button": "skip"}` (`download`, `releaseNotes`) the welcome line's; `{"updates": "automaticSetting", "value": false}` the Settings switch. Links are recorded, never opened. The dump's `updates` object: `isChecking`, `checksAutomatically`, `hasLastCheck`, `lastCheckFailed`, `lastCheckedText`, `current`, `newestKnown`, `skipped`, `notice`, `noticeText`, `lastOutcome`, `lastTrigger`, `checksFinished`, `lastOpenedLink`, `menuItem` (`title`, `enabled`, `index`) and `alert` (`message`, `detail`, `buttons`, `on`: `main` or `settings`). |
| `{"quit": true}` | Quits. A script that ends without it quits too. |

Every dump also has `language` (`running`: the language the text is in; `preferredLocalizations` and `localizations` of the main bundle; `launchChoice` and the stored choice's `reopenOffered`; `quitAndReopenRequested`), `mainMenu` (the menu bar as it would show now: each menu's `title` and `items`, with `key` for an item's key equivalent; separators, hidden items and the system's Services left out), `slowSections` (main-thread sections over 4 ms — opening, regrouping, the grid's reloads, Settings' panes, the apply plan — with when they ended, to say which part of a stall was which), `splitWidths`, `introductionShown` and `systemAccessibility`.

The dump's settings objects: `settings` (every setting in effect, `language` among them), `tuningDefault` (the default tuning, every `TuningKey`) beside `tuning` (the open shoot's), `tuningScope` (`hasOwnTuning`, `differsFromDefault`, `preset`), `preset` (the default's: `lenient`, `balanced`, `strict` or `custom`), `flagCounts` (photos per flag, any tier), `keyMap` (chords per command), `keyConflicts`, `menuKeys` (the key each command's menu item shows), `cache` (`thumbnailBytes`, `cachedScores`, `databaseBytes`, `limitBytes`, after a `cache` step or the Performance pane), and `settingsWindow` (`shown`, `pane`, `title`, `recording`, `conflict`, and on detection panes `scopeNote`, `preset` and `lines`: each shown count line by `TuningKey`, null when the pane has no count to show).

Every dump also has `distribution`, `direct` or `appStore`, and `shownViews`, the sorted names of the views on screen that the source marks with `automationMark(_:)`: `settingsUpdatesSection` and `welcomeUpdateLine` so far. SwiftUI keeps such views out of the accessibility tree the harness reads, so the mark is how a script checks that one is or is not shown. In the Mac App Store variant `updates` is `null` and every `updates` step is refused.

Scripts must not assert detector readings that sit close to a threshold. Vision's models change between macOS updates: in November 2026 the lens smudge confidence of `horizon_0_under.jpg` and `sonoma_0_over.jpg` crossed 0.5. Check flags far from their thresholds (`photo:<id>.tiers.<flag>`, `flagCounts.<flag>`) or use `expectMatch`.

Waiting for `idle` in the loupe also waits for the full-size image the zoom needs, the clipping overlay, and the filmstrip's thumbnails. Reveal in Finder and Copy File Name never reach the Finder or the clipboard in automation; they are recorded in `lastFileAction`.

The dump's `loupe` object, once the loupe has been shown:

| Key | Meaning |
| --- | --- |
| `zoomFactor`, `zoomPercent`, `fitFactor`, `isFit` | The zoom on screen, in display pixels per image pixel (1 = 100%), and the factor of fit |
| `visibleRect`, `visibleCentre`, `visibleRectPixels` | What shows, in unit image coordinates (x, y, width, height; origin top left) and in image pixels |
| `pixelSize`, `imageSize`, `screenImageSize` | The photo's full size, the image on top and the screen-size image under it |
| `resolution` | `thumbnail`, `screen` or `full`: the sharpest image on screen (`full` also when the screen-size image holds every pixel) |
| `fullImageInUse`, `fullImageTiles`, `fullImagesHeld`, `loadingFullSize` | Whether the decoded full-size image is shown, how many of its 1,024-pixel tiles were handed to Core Animation, which photos' full-size images are held (the one in view and the next), and whether one is decoding |
| `magnificationFilter` | `nearest` from 100% on (pixels drawn as crisp squares), else `linear` |
| `targetedFace`, `faceOrder` | The face Z or Tab zoomed to and the order Tab visits the main faces (indices into the photo's faces) |
| `faceBoxes`, `clipping`, `clippingMeasured` | Which overlays are on, and the share of the photo clipped as the overlay measures it |
| `lastZoomToSharpMs`, `lastStepToSharpMs`, `lastStepToFirstImageMs` | From the last zoom command (or step to another photo) to a sharp image on screen, and from a step to the first image |
| `filmstripVisible`, `filmstripTilesWithoutImage` | The filmstrip's cells on screen |

The dump's review objects:

| Key | Meaning |
| --- | --- |
| `stackReview` | `stackIndex`, `stackCount`, `stacksLeft`, `frames`, `current`, `pick`, `handPicked`, `rightPane` and `rightPaneRole` (`bestPick`, or `runnerUp` when the current frame is the pick), `currentNotes`, `pickReason`, `title`, `done` (every stack decided), `origin` (the view a stack opened from the grid returns to), `zoom`, `faceRow`, `currentPane` and `pickPane` (`photo`, `zoomPercent`, `isFit`, `resolution`, `faceBoxes`, `visibleCentre`, `firstImageMs`, `sharpMs`), `hints` (the header's key line), `faceStripShown`, `faceStripWanted` (F's state: faces on or off), `faceBoxesShown` (F and the B overlay both on), `faceBoxesEnabled` (whether B can run: not while F hides the faces), `currentPaneFaceBoxes` and `pickPaneFaceBoxes` (boxes drawn on each pane; 0 for a hidden pick pane), `pickPaneShown`, `faceStripHeight`, `panesHeight`, `lastStackShownMs` (Return or ↓ to the next stack shown sharp with its strip and frames), `lastFrameShownMs`, and over the run `stackShownMedianMs`, `stackShownMaxMs` |
| `faceStrip` | The strip on screen: `rows`, `rowLabels`, `columns`, `filled` and `outlined` (per row and column), `currentColumn`, `pickColumn`, `byPosition` (rows by left-to-right order, not people), `crops`, `cropsShown`, `sharpCrops`, `decodes`, `fullSizeDecodes`, `decodeMs`, `cropMemoryKB`, `firstCropsMs`, `sharpCropsMs` |
| `compare` | `photos`, `focusedPane`, `focused`, `origin`, `zoom`, `panes` |
| `duplicates` | `setIndex`, `setCount`, `kind`, `members`, `current`, `pick`, `reason`, `exactLeft`, `nearLeft`, `lastBulkAccept`, `done` |
| `gridEntries`, `gridEntryCount`, `gridOrder` | With stacks collapsed (All Photos): each tile (`photo`, or `stack` with `representative`, `frameCount`, `decisions`, `summary`: `unreviewed`, `kept`, `rejected` or `mixed`), and the photos the tiles show |
| `stackEdits`, `stacksExpanded`, `stacksLeft`, `exactSetsLeft`, `nearSetsLeft`, `collapsedTargets` | Manual stack edits (`joined`, `splitOut`, `bestPicks`), whether S expanded the stacks, what is left, collapsed stacks in the selection |

The dump's apply and disk objects:

| Key | Meaning |
| --- | --- |
| `apply` | `screenOpen`, `preparing`, `readOnly`, `writability`, `action`, `writeSidecars`, `buttonTitle`, `canApply`, `focus`, `selected`, `peek`, `rejectOrder`, `rescuedThisVisit`, `differsFromDefault`, `openMs` (⌘Return to the plan shown), `plan` (summary numbers, `blocker`, `summaryLine`), `groups` (`reason`, `title`, `photos`), `run` (in progress: `done`, `total`, `cancelling`, `held`), `result` (the last run: `state`, `headline`, `details`, counts, `skippedSidecars`, `trashedPaths`, `ms`), `undoable` (the run Undo Apply acts on), `undoMenuTitle`, `undoReport` (`state`, `restored`, `skipped` with `path`, `reason`, `message`, `ms`), `banner`, `lastFileAction` (Reveal Keepers, Open Keepers In, recorded) |
| `disk` | `disconnected`, `readOnly`, `rescan` (`count`, `running`, `last`: `trigger`, `ms`, `mainMs`, `changed`, `added`, `removed`, `modified`, `renamed`), `undoApplyRequest`, and with `"listing": true` on the dump step (or an `expect` on `disk.listing…`) `listing`: `files` (path, size), `dirs`, `fileCount`, `hash` (paths, sizes, contents), `stampsHash` (paths, modification times) |
| `noticeBar`, `applyScreenShown` | The docked notices' height, and whether Review and Apply is on screen |

The dump's `analysis` object, once a shoot is open:

| Key | Meaning |
| --- | --- |
| `phase` | `starting`, `running`, `paused`, `finished` or `cancelled` |
| `done`, `total`, `running`, `unreadable`, `cached` | The engine's progress: photos analysed in this open of those queued, in flight, found unreadable, and read from the cache |
| `photosPerSecond`, `secondsRemaining`, `overallPhotosPerSecond` | The engine's rate over its last 20 s, its estimate, and photos analysed per second since analysis started |
| `concurrency`, `concurrencyReason` | Photos analysed at once and why (`AnalysisConcurrency`) |
| `analysedThisOpen`, `cachedCount`, `groupingsApplied`, `groupingPending`, `events` | Counts of what arrived |
| `statusText` | The toolbar's line |
| `timings` | Seconds since the open started: `shownS`, `startedS`, `cachedAppliedS`, `firstResultS`, `firstGroupCountS` (a group found by analysis first had a member), `firstGroupingS`, `finishedS` |

Example:

```json
{
  "window": [1280, 800],
  "steps": [
    {"open": "$SHOOT"},
    {"wait": "idle"},
    {"key": "p"},
    {"key": "x"},
    {"expect": {"totals.kept": 1, "totals.rejected": 1, "undoTitle": "Undo Reject"}},
    {"key": "cmd+z"},
    {"wait": "idle"},
    {"snapshot": "after-undo"},
    {"dump": "after-undo"},
    {"quit": true}
  ]
}
```

## The example scripts

| Script | Checks | Run |
| --- | --- | --- |
| `ui/01-first-open.json` | First open of the sample: counts, the RAW+JPEG pair, the unreadable file, inspector, loupe, empty groups | `--reset` |
| `ui/02-cull-and-undo.json` | P, X, U, ratings, Shift and Command selection, bulk decisions, undo and redo, the Unreviewed group, small thumbnails | `--reset` |
| `ui/03-reopen.json` | Reopening from the recent list brings back every decision, rating, the group, the focus and the view mode | after 02, `--keep-shoot` |
| `ui/04-reopen-with-changes.json` | A file added since is marked New, a removed one is gone | after 03: add a file to and remove `sonoma_4_small.jpg` from the container copy of the shoot, then `--keep-shoot` |
| `ui/05-empty-states.json` | An empty folder, an empty group, an empty defect group | `--reset` |
| `ui/06-large-shoot-performance.json` | Open, page through and cull a large shoot; stalls and memory in the dumps | `--reset --shoot <5,000-photo shoot>` |
| `ui/07-loupe-zoom.json` | Fit, Z to 100% with the full-size image, panning, sticky zoom across a burst, 400%, back to fit | `--reset` |
| `ui/08-loupe-faces.json` | Injected faces: Z to the worst eyes in Eyes Closed and to the focus point elsewhere, Tab and Shift-Tab, B | `--reset` |
| `ui/09-loupe-overlays.json` | The clipping overlay in Exposure and with J, face boxes and clipping together, zoomed | `--reset` |
| `ui/10-loupe-decisions-filmstrip.json` | P, X, U, ratings, undo and redo in the loupe; the filmstrip's marks, clicks and context menu; Unreviewed advancing | `--reset` |
| `ui/11-context-menu-band-recents.json` | The grid's context menu on a selection and on another photo, rubber-band selection, Open Recent ▸ Clear Menu | `--reset` |
| `ui/12-loupe-large-photos.json` | Z to a sharp 24 MP image (pixel for pixel), stepping at 100%, the full-size image let go at fit; timings in the dumps | `--reset --shoot <make_large_photos.py output>` |
| `ui/13-loupe-stepping-performance.json` | 200 steps in the loupe at fit and 50 at 100% on a large shoot; stalls and memory in the dumps | `--reset --shoot <5,000-photo shoot>` |
| `ui/14-analysis-first-open.json` | Analysis on first open: groups, stacks and duplicate sets as `culla-eval` finds them, badges at the default and smallest size, the inspector's Flags, the summary banner, Start Reviewing | `--reset` |
| `ui/15-analysis-reopen-cached.json` | Reopening: every score from the cache, nothing analysed, groups full within a second, no banner, Start Reviewing from the Go menu | after 14 |
| `ui/16-evidence-loupe.json` | Eyes Closed (injected faces) and Blurry open the loupe zoomed to the evidence, X moves on and the zoom follows; Exposure with the clipping overlay; a view chosen by hand sticks | `--reset` |
| `ui/17-clear-defect-group.json` | Clearing Exposure with P and X to "all decided", the next group offered, undo | `--reset` |
| `ui/18-bulk-reject.json` | ⇧X: confirmation, cancel, accept, one undo step, "none left" and Likely-only groups | `--reset` |
| `ui/19-tuning-panel.json` | The tuning panel: live counts, regrouping without analysis or decision changes, reset, stacks regrouped | `--reset` |
| `ui/20-pause-resume.json` | Pausing and resuming analysis, culling meanwhile | `--reset` |
| `ui/21-empty-states.json` | Empty groups: not analysed yet, still analysing, none found, all decided | `--reset` |
| `ui/22-culling-while-analysing.json` | Paging the grid and culling in the loupe while 2,000 photos are analysed; stalls, speed, memory | `--reset --shoot <2,000-photo shoot>` |
| `ui/23-reopen-large-cached.json` | Reopening the 2,000-photo shoot from the cache | after 22 |
| `ui/24-stack-review-accept.json` | Stack review: Return on a right pick, P on other frames then Return, ↓ to skip, undo, coming round to skipped stacks, the end screen and its offer of the next group | `--reset` |
| `ui/25-stack-split-and-pick.json` | ⇧G and its undo, the current frame being the pick (runner-up on the right), ⇧S choosing a pick by hand | `--reset` |
| `ui/26-stack-edits-reopen.json` | The pick and the split survive reopening and a regrouping after a tuning change | after 25 |
| `ui/27-face-strip.json` | Injected faces: rows and columns, the closed-eye outline, notes, a cell click zooming both panes, Tab, F; one photo's faces in the loupe | `--reset` |
| `ui/28-compare.json` | Compare two and four photos: focus, P X and ratings on the focused pane, linked zoom, Escape and C back; from stack review | `--reset` |
| `ui/29-duplicates.json` | Duplicate review: accept, keep the other copy, Accept All Exact Duplicates as one step, near sets untouched, the end screen | `--reset` |
| `ui/30-collapsed-stacks.json` | Collapsed stacks in All Photos: P and X leave them alone, Return and double click open them and come back, S, G joining photos and stacks, the smallest size | `--reset` |
| `ui/31-stack-review-large.json` | Stack review of the 24 MP burst: crops from full-size decodes, 100% in both panes, stepping at 100%; timings and memory | `--reset --shoot <make_large_photos.py output>` |
| `ui/32-accept-many-stacks.json` | 100 Returns in a row on the 2,000-photo shoot: the longest stall and Return-to-shown times | after 23 |
| `ui/33-apply-move-undo.json` | Review and Apply with reason groups, the three actions, a closer look, Move to `_Rejected`, the grid and loupe after, Reveal and Open Keepers In recorded, Undo: the folder's hash and dates as at the start | `--reset` |
| `ui/34-apply-mark-only.json` | Mark Only (sidecars written, nothing moves), Mark Only without sidecars (nothing to apply), ⌘Z offering Undo Apply with its confirmation | `--reset` |
| `ui/35-apply-sidecars-merge.json` | An existing sidecar merged (other fields kept), an unreadable one left alone and listed, undo byte for byte | `--reset` |
| `ui/36-apply-trash-guard.json` | Move to the Trash on the screen; the harness refuses a Trash outside the container, and nothing changes | `--reset` |
| `ui/37-apply-rescue.json` | P rescues, ⌘Z puts back, a selection rescued, leaving and coming back, apply moves only the rest | `--reset` |
| `ui/38-apply-failure-undo.json` | A failure injected part-way: the banner, Undo What Was Done back to the original hash | `--reset` |
| `ui/39-apply-progress-cancel.json` | Progress held mid-run, decisions locked, Escape cancels between files, undo | `--reset` |
| `ui/40-apply-crash.json` / `41-apply-crash-recovery.json` | The app ended abruptly mid-apply; reopening offers to undo what was done, back to the original hash | `--reset` / after 40 |
| `ui/42-apply-then-quit.json` / `43-undo-after-reopen.json` | Undo Apply from the File menu after quitting and reopening | `--reset` / after 42 |
| `ui/44-undo-changed-file.json` | A moved file changed before undo: reported, not overwritten, Try Undo Again offered | `--reset` |
| `ui/45-read-only-copy-keepers.json` | A read-only shoot: why Apply is unavailable, Copy Keepers To, its result and undo; the shoot unchanged | `--reset` |
| `ui/46-rescan-rename-add.json` | A rename, an added and a deleted file picked up by a focus rescan, decisions following, focus kept; unchanged rescans | `--reset` |
| `ui/47-disconnect-return.json` | The shoot disconnecting during analysis and coming back | `--reset` |
| `ui/48-banners-do-not-cover.json` | The analysis summary docked above the grid, gone in stack review and the loupe | `--reset` |
| `ui/49-apply-large.json` | 500 rejects of the 2,000-photo shoot: opening the screen, applying, undoing; stalls | `--reset --shoot <2,000>` |
| `ui/50-rescan-large.json` | Focus rescans of 5,000 unchanged photos: time and stall | `--reset --shoot <5,000>` |
| `ui/52-settings-panes.json` | Every Settings pane, without a shoot (the note in detection panes) and with the analysed sample (live counts) | `--reset` |
| `ui/53-settings-live-count.json` | A detection slider in Settings: the count line, the sidebar following at once, stacks regrouped, nothing analysed again, Reset to Defaults | `--reset` |
| `ui/54-presets.json` | Lenient and Strict change the counts, a slider moved by hand shows Custom, Balanced is the defaults | `--reset` |
| `ui/55-tuning-default-vs-shoot.json` / `56-tuning-after-relaunch.json` | The tuning panel changes only its shoot, kept across a reopen and a relaunch; another shoot follows the default; Save as Default, Reset to Default, Use Defaults for This Shoot | `--reset` / after 55 |
| `ui/57-key-remap.json` | A key remapped in Settings works at once and shows in the menus; a key in use warns and names its command; ⌘Q is refused; Reset All | `--reset` |
| `ui/58-cache.json` | Cache usage, Clear Cache with and without scores, the size limit, the shoot analysed again after scores were cleared | `--reset` |
| `ui/59-performance-10000.json` | The performance pass on 10,000 photos: opening, paging the whole grid and 300 loupe steps while analysing, analysis speed and peak memory, 100 stacks accepted, sliders dragged in Settings and the tuning panel, a focus rescan, 5,000 rejects and their undo, Review and Apply and Undo Apply on them, an hour-like loop of mixed work and the memory after it; every number under `measurements` | `--reset --shoot <10,000-photo shoot>`, best `--optimized` |
| `ui/60-reopen-10000-cached.json` | A fresh launch reopening the 10,000 photos with every score cached: time to the grid and to populated groups | after 59 |
| `ui/61-first-run-help-about.json` | The first-run introduction (keys from the live key map), Help ▸ Keyboard Shortcuts following a remapped key, About, Help ▸ Culla Documentation, the Dock menu's recent shoots, the window title, the sidebar width remembered | `--reset` |
| `ui/62-settings-confirm-keys-panes.json` | The confirmations of Include Subfolders and Treat RAW+JPEG as One Photo, with the number of decided photos that would leave; keys replaced one at a time and added; the tall panes scrolling within a 13-inch screen; Tab in Settings | `--reset` |
| `ui/63-accessibility.json` | The accessibility tree of the grid, loupe, stack review with its face strip, duplicates, compare, a defect group, the inspector, Review and Apply and every Settings pane; Increase Contrast and Reduce Motion | `--reset` |
| `ui/69-updates-welcome.json` | Check for updates on the welcome view: the line after an automatic check finds a newer version, at the minimum width too; Download and Release Notes recorded; Skip This Version removing it until a newer version; silence for a newer macOS, a failure, an invalid or unpublished file, and over an open shoot | `--reset` |
| `ui/70-updates-check-now.json` | Culla ▸ Check for Updates…: the item below About Culla, disabled while checking; the alert for each outcome, a skipped version still reported, the alert over an open shoot | `--reset` |
| `ui/71-updates-settings.json` | Settings ▸ General ▸ Updates: the switch and what it sends, Check Now with its alert on the Settings window, the last-checked line (never, a time, no answer), switching off removing the welcome line | `--reset` |
| `ui/72-store-no-update-check.json` | The Mac App Store variant has no update check: `distribution` and `updates` in the dump, no Check for Updates… in the Culla menu, no Updates section in Settings ▸ General, no line on the welcome view, and every `updates` step refused. Skipped by `ui-all.sh` | `--store --reset` |

For 04:

```bash
SHOOT=~/Library/Containers/com.kpirliyev.Culla/Data/tmp/CullaAutomation/shoots/CullaSampleShoot
cp "$SHOOT/horizon_1.jpg" "$SHOOT/added_late.jpg"; touch "$SHOOT/added_late.jpg"; rm "$SHOOT/sonoma_4_small.jpg"
Scripts/ui-run.sh Scripts/ui/04-reopen-with-changes.json --keep-shoot
```

## Screens in other languages

`65-screens-en.json`, `66-screens-ru.json` and `67-screens-tk.json` walk the same screens in English, Russian and Turkmen: first run, Keyboard Shortcuts, About, the grid with and without the inspector, the loupe with its overlays, a defect group with its tuning panel and ⇧X confirmation, empty groups, stack review with two panes, one pane and no faces, duplicate review, compare, Review and Apply with each action, the result and undo banners, the welcome view's update line and the four Check for Updates alerts (`03b-` to `03f-`), every Settings pane, the Language choice with its Quit and Reopen button, the rescan confirmation and a key conflict, then the main screens again at the window's 900-point minimum width (`40-narrow-…` to `50-narrow-…`) and a tile with the NEW pill (`51-new-pill`). Each saves snapshots, the accessibility tree of every window (`a11y-*.json`) and dumps with the menu bar (`mainMenu`). Until translations are imported the app's own text shows in English.

```bash
Scripts/ui-all.sh --only screens          # all three; or one:
Scripts/ui-run.sh Scripts/ui/66-screens-ru.json --reset
Scripts/l10n-screens.py <66-screens-ru run folder> <65-screens-en run folder>
```

`l10n-screens.py` prints each string the translated run shows exactly as the English one, with where it was seen, and leaves out Culla, file names, numbers, key symbols, language names and the lines of an `--allow` file (`re:` for a pattern). `68-keys-other-layouts.json` checks that keys count by position on the Russian and Turkmen layouts.

## Screenshots for the site

```bash
Scripts/site-shots.sh                       # the demo shoot in culla-demo-shoot/photos
Scripts/site-shots.sh <folder> --no-build   # another folder, the app already built
```

`site-shots.sh` makes the five screenshots of the landing page in English, Russian and Turkmen and writes them to `site/public/shots/<slot>.<lang>.png`, replacing what is there. It copies the folder's finished photos (not `.part` files) to a staging folder called `Portraits`, the name the window shows, renamed `IMG_4101.jpg` upward in capture-time order so no photographer's name or source shows in a screenshot (the copies are unchanged, so capture times are kept). The screenshots are taken with the stack time gap set to 300 s (`--stack-gap` changes it), because the demo photos are published frames taken minutes apart; it is set as the open shoot's own tuning, as the tuning panel would, and the app's default and every other threshold are unchanged. Then:

1. runs a probe script once to analyse the shoot and dump what Culla found;
2. `site-shots.py script` writes a capture script per language from that dump, choosing what each slot shows by state: a stack of three or more frames with faces in the most frames for the hero, another stack for P and X, the Eyes Closed photo rated certain with the most faces for the evidence. When the shoot has nothing for a slot it says so and falls back (no stacks: the grid; no closed eyes: Blurry, then face boxes);
3. each capture runs with `--reset`, so it starts from nothing and uses the automation database and settings;
4. `site-shots.py finish` crops and scales each snapshot to its slot with `site-shots/crop.swift`.

| Slot | Window (points) | Part kept | PNG |
| --- | --- | --- | --- |
| `how-1-open` | 1024 × 640, just opened, analysing | top left 720 × 540 | 800 × 600 |
| `how-2-groups` | 1024 × 640, All Photos after analysis | top left 640 × 480 | 800 × 600 |
| `hero-stack-review` | 1152 × 720, stack review (720 points tall, so two rows of the face strip fit) | all | 1280 × 800 |
| `vision-evidence` | 960 × 640, Eyes Closed in the loupe | all | 1200 × 800 |
| `how-3-decide` | 960 × 720, stack review after P and X | all | 800 × 600 |

Snapshots are taken at 2× and scaled down, so each PNG is twice the largest size the page shows it at. The app is always dark, as the site is by default. `--evidence <file name>` (the original name) picks the Eyes Closed photo by hand when the one chosen is a photo whose eyes are in fact open. The scripts are outside `ui/`, so `ui-all.sh` never runs them.


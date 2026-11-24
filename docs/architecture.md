# Culla — Architecture

Last updated: 2026-11-24

This is the contract every part of the code is built to. [Design](design.md) says what the app shows, [User Flows](user-flows.md) say how it is used, and the [Implementation Plan](implementation-plan.md) says in which order it is built. Change this file in the same change that breaks one of its rules.

## Modules

| Module | Depends on | Holds |
| --- | --- | --- |
| `CullaCore` | nothing | Value models (`PhotoFile`, `PhotoMetadata`, `PhotoScores`, `FaceScores`, geometry), `BlockingQueue` |
| `CullaFiles` | Core | Scanning, metadata, image decoding at three sizes, the disk thumbnail cache, folder bookmarks, XMP sidecars, applying and undoing file moves |
| `CullaAnalysis` | Core | Detectors, `Tuning`, `PhotoSummary` and flags, stack and duplicate grouping, best-pick scoring |
| `CullaSession` | Core, Analysis | `SessionState`: the photos of one shoot with their decisions, ratings, scores, groups and undo history. Pure logic, no I/O, no UI |
| `CullaStore` | Core, Session, GRDB | SQLite persistence through `CullaDatabase`: sessions, decisions, cached scores, and later manual stack edits and the apply journal |
| `CullaCommands` | Session | Every user action as one `Command` enum, the key map as data, key matching, grid selection logic, undo names; also the text and small decisions the interface needs but that have nothing to do with AppKit: the review guide (which group opens next), bulk-reject rules, loupe zoom targets, stack-review layout, the Review and Apply wording, the tuning control descriptions shared by Settings and the tuning popover, and the three presets |
| `CullaPipeline` | Core, Files, Analysis, Session, Store | `ShootApplier`, the facade for applying and undoing; and background analysis of a shoot: `AnalysisScheduler` (priorities, pause, adjustable concurrency) and `ShootAnalysis` (cache first, analyse the misses, save in batches, deliver events, compute stacks, duplicates and best picks) |
| `CullaUpdates` | nothing | The update check: version comparison, the update document, the decision and the schedule as pure functions, and the one network request the app makes. All network code of the project is in this module |
| `culla-eval` | Core, Files, Analysis | The command-line detector check |
| `Culla` (app) | all of the above | SwiftUI and AppKit interface, `SessionModel`, commands and key bindings, settings |

Logic goes in the package, where it is unit-tested without the interface. The app target holds views and the thin glue that connects them to the package. GRDB is the only third-party package.

## State

- **`SessionState`** (in `CullaSession`) is a value type holding everything about an open shoot that is not a view concern: photos in capture order, each with a `Decision` (unreviewed, kept, rejected), a rating of 0 to 5, cached `PhotoScores`, and the stacks and duplicate sets. Every change goes through one mutating entry point that records its inverse, so undo and redo cover every decision, including bulk ones, as single steps.
- **Groups** are derived, never stored. `SessionState` answers "which photos are in group X" and "how many are left to review" from decisions, scores and the current `Tuning`. Changing a threshold therefore regroups at once and never touches a decision.
- **`SessionModel`** (in the app, `@MainActor @Observable`) owns one `SessionState` plus view state: the focused photo, the selection, the current group, the view mode, thumbnail size, inspector visibility. Views read it and call its intent methods (`keep()`, `reject()`, `rate(_:)`, `move(_:)`). Views never change state any other way.
- **View preferences are not session state.** Choices that apply to every shoot (thumbnail size, whether stack review shows the best pick pane) live in `AppSettings`, are remembered across launches, and never enter the undo history.
- **Unreviewed photos count as kept.** Nothing in the code may treat "unreviewed" as a problem to be resolved before applying.
- **A failed load is not an unreadable file while the folder is unreachable.** A thumbnail or image that fails to load when the shoot's folder cannot be reached waits for the folder and loads again when it returns; a file is marked unreadable only after it fails with the folder reachable. Tiles keep the image they already had, dimmed.
- **Unreadable files** appear only in All Photos. They are left out of every other group and of the kept, rejected and left counts, and are never moved.
- **Speed.** Each photo carries a bit set of the groups it is in and counts are kept up to date on every change, so a decision plus all counts costs about a quarter of a millisecond on 20,000 photos.

## Persistence

- One SQLite database in the app's Application Support folder, through `CullaStore`. Schema changes go through numbered migrations.
- A session is identified by its folder. It stores a security-scoped bookmark to the folder, and per photo the relative path, file size, modification date, decision and rating, plus where the user was (group, focused photo, view mode).
- Decisions are saved as they are made, off the main thread. Quitting at any moment loses nothing.
- Scores are cached one row per file path. A lookup hits only when size, modification date and the scores version all match, so reopening a shoot analyses nothing again and a changed file replaces its own row.
- Per photo the store also keeps the metadata read from the file, so reopening does not read every file's headers again.
- **Nothing is written into the shoot folder until the user applies.** Thumbnails, scores and session data live in the app's own container.

## Applying decisions to disk

This is the only code that moves or writes the user's files. The app goes through one facade, `ShootApplier`.

- **Plan first.** `SessionState.applyPlan` computes, without touching the disk, what would happen: which files move where, which sidecars are written, and the summary the Review and Apply screen shows. A photo is all of its files (the shown file, the RAW of a pair, an existing sidecar) and they move together. For shoots over 3,000 photos the plan is computed off the main thread, and Apply is disabled until the newest plan is in, so a photo rescued a moment ago is never applied from an older plan.
- **Write-ahead journal.** Every step is recorded in the database as started before it runs and marked done after. A failed, cancelled or crashed apply therefore knows exactly what it did, and the part that ran can be undone. An interrupted run is found on the next launch.
- **Nothing is ever overwritten.** Moves and new files are exclusive; a name already taken in the destination gets a numbered suffix shared by all of a photo's files.
- **Undo checks before it acts.** A file is moved back only if it is still the file that was moved (size and modification date) and nothing new sits at its original path. Anything else is skipped and reported, and can be retried.
- **After a move or trash** the rejected photos leave the session, since `_Rejected` is not scanned. Undoing the apply brings them back with their decisions, ratings and scores. The decision undo history is cleared at apply: the way back from an apply is Undo Apply, not undoing individual decisions.
- **Sidecars** are `<name>.xmp` beside the photo. Culla never modifies an image file. An existing sidecar is merged by splicing only the changed values; everything else is preserved byte for byte, and a sidecar that cannot be parsed is left alone and reported.
- **Read-only shoots** (a locked card) cannot be applied in place; Copy Keepers To copies kept and unreviewed photos elsewhere, journalled the same way.
- **Files renamed or moved outside Culla** are matched on rescan by size, modification date and capture time when the match is unique in both directions, and keep their decision, rating and scores.

## Images

Three sizes, each with one job:

| Size | Used for | Source |
| --- | --- | --- |
| Thumbnail, 512 px long side | Grid, filmstrip, stacks | For RAW files the preview the camera embedded (about 37 ms on a 24 MP file); for JPEG and HEIC a reduced-size decode, which is as fast. Cached on disk and in memory |
| Screen size | Loupe and compare, fitted to the window | Decoded on demand, a few kept in memory |
| Full size | 100% zoom | Decoded on demand for the photo in view only |

Decoding never happens on the main thread or on Swift's cooperative pool; it goes through `BlockingQueue`. Work for tiles that scrolled out of view is cancelled.

## Analysis in the app

The app runs the same `PhotoAnalyzer` as `culla-eval`, on the same pixels: both load the image to analyse through `AnalysisImageLoader` (long side up to 4096 px; for RAW files the camera's embedded full-size preview, not a RAW development).

One `ShootAnalysis` per open shoot does the work. It delivers cached scores first, analyses only the photos without any, several at a time with the visible photos and the open group first, and can be paused and resumed. It saves new scores in batches and sends the app a stream of events (scores arrived, photos unreadable, progress, grouping ready, finished), batched so the main thread is woken a few times a second at most. `SessionModel` applies each event to `SessionState`. The interface never waits for analysis: every view works with whatever scores exist so far.

**A Vision request this Mac cannot run is skipped.** Vision does not throw for a request that has no device to run on: it traps, which ends the process. So `VisionAvailability` asks once per process which of the analyzer's requests have a device here (the request's `supportedComputeStageDevices` against Core ML's `MLComputeDevice.allComputeDevices`), and `PhotoAnalyzer` performs only those; a skipped request leaves its score empty, as a failed one does. The lens-smudge request runs only on the Neural Engine and is skipped on a Mac without one, such as a virtual machine. Only the face landmarks request is allowed to report no devices, because it never reports any and runs regardless; a new request added to the analyzer must be added to `VisionRequestKind`. `culla-eval`'s device report and the tests print what is performed and skipped on the machine they run on.

Stacks, duplicate sets and each stack's best pick are computed off the main thread from the scores so far, at intervals while analysis runs and again when it finishes or tuning changes. A best pick the user chose by hand is never replaced.

Scores are raw measurements. Flags and tiers are computed from them with the current `Tuning` each time they are needed, so changing a setting never analyses anything again. Detection tuning is the last milestone, so every threshold must be a `Tuning` value reachable from Settings, never a constant buried in a view.

**Two tunings.** Settings holds the default `Tuning`. A shoot follows the default until a value is changed from its own tuning popover; from then on the shoot keeps its own tuning, stored with the session, across reopening. "Save as Default" copies it to the default; "Reset to Default" drops it. Settings and the popover are built from the same `TuningControls` descriptions in `CullaCommands`, so a slider's range, label and live count cannot differ between the two. The presets are a rule, not a table: Balanced is the defaults, and Lenient and Strict move every slider a quarter of the way towards fewer or more flags.

Flag counts for sliders and the sidebar are cached per session change; a Settings pane on a 10,000-photo shoot must never count the shoot again on every redraw.

Memory: eight photos in flight at 4096 px peak at about 2 GB on 24 MP files. The number analysed at once is the engine's default of 8, capped at physical memory divided by 2 GB (4 on an 8 GB Mac), halved on battery when the setting is on, halved again on a memory-pressure warning and reduced to 1 when memory is critical. It follows changes while running.

## Commands and keys

Every user action is a case of one `Command` enum. `KeyBindings` maps key presses to commands, with the defaults from the Design doc's key table, and is the only place that knows about keys, so remapping is a data change. A command may have several keys; remapping replaces one key and + adds another, so pairs such as ⌘= / ⌘+ survive. ⌘Q and the other application and window menu keys, and ⌘/ for the shortcut sheet, are reserved. A single router turns key events into commands and sends them to `SessionModel`. Menu items, toolbar buttons and keys all send the same commands.

Anything that shows keys to the user (menus, the first-run introduction, Help ▸ Keyboard Shortcuts, the Settings Keys pane, header hint lines, tooltips, notices such as "⌘Z takes it back") reads the live key map; fixed key text is a bug. `KeyText` in `CullaCommands` builds these strings: a command with no key is left out of a hint line, and a sentence that would name a missing key names the menu item instead. The exceptions are the key recorder's own fixed controls (Esc, Delete) and the reserved system keys.

## Interface structure

- The app uses the AppKit life cycle, with SwiftUI and AppKit views inside, for full control of key routing, menus, Dock drops and snapshots.
- One window. It shows the welcome view until a shoot is open, then the shoot: the top bar on top, sidebar on the left, the photo area in the middle, the inspector on the right (hidden until asked for), the status bar at the bottom.
- The top bar is the app's own view (`ShootTopBar`, with its controls in `TopBarControls`), not `NSToolbar` items: on macOS 26 and later the system wraps every toolbar item in a glass capsule and offers no supported way to draw custom items without it. The window has a full-size content view, a transparent title bar and an empty compact toolbar whose only job is to give the title bar the bar's height, so the traffic lights centre on the controls. The bar lays itself out by hand from measured text, because the order in which its parts give way depends on their widths in the current language. It is an accessibility toolbar holding ordinary buttons, a radio group, a slider and the status. Empty bar space drags the window, and a double-click follows the system's setting.
- The photo area switches between grid, loupe, compare, stack review and duplicate review. All of them share the model's focused photo and selection.
- A part of a view that is switched off takes no space and does no work. In stack review, `StackReviewLayout` (in `CullaCommands`) decides whether the best pick pane, the face strip and the face boxes show and how tall the strip is (F switches the strip and the boxes together, and the face-box command is disabled while they are hidden); a hidden pane is released and left out of the settle checks, and a hidden strip has zero height, so the frames get the room. A pane that grows re-fits its image and asks for a larger screen-size image when the one on show is too small.
- AppKit is used where SwiftUI cannot keep up: the grid and filmstrip are `NSCollectionView`s, and the loupe is a zoomable `NSScrollView`. Everything else is SwiftUI.
- Dark appearance by default. Colour carries meaning only (green kept, red rejected, amber flagged) and is always paired with an icon or a shape: selection has an outline, rejected frames in a stack a dashed ring, the clipping overlay stripes shadows and fills highlights.
- Every interactive element is a VoiceOver element with a name and, where it acts, actions. AppKit views that draw many items in one layer (face-strip cells, key caps) publish them as `NSAccessibilityElement`s through `AccessibilityElements`. All animation goes through `SystemAccessibility`, which honours Reduce Motion; Increase Contrast thickens rims and outlines.

## Verifying the interface without a person

Debug builds accept a launch argument naming a JSON script. The script opens a folder, waits for work to settle, sends commands or key presses, and writes PNG snapshots of the window and JSON dumps of the session state to an output folder, then quits. `Scripts/ui-run.sh` builds the app, copies a generated sample shoot into the app's sandbox container, runs a script and prints where the results are. Scripts can also assert on the dumped state with `expect` steps, and the dump records every main-thread stall. Waiting for idle skips only the tiles that wait for a missing folder; every other tile without an image keeps the app busy, so a blank tile fails a script. Automation runs use their own database, caches and settings, never the real ones. The format is in `Scripts/README.md`; examples are in `Scripts/ui/`.

This is how changes to the interface are checked: read the snapshots and the state dumps. The harness is compiled out of release builds; only the names of the separate data folders and defaults domain an automation run uses remain in the binary.

The dump also records named section timings (`slowSections`) and per-step timestamps inside loops, so a stall can be traced to its cause, and a script can dump a window's accessibility tree. SwiftUI builds its accessibility elements only for a connected assistive app, so SwiftUI controls are checked in the source by `Scripts/check-accessibility.py`, which `Scripts/ui-all.sh` runs before the scripts.

Test images come from `Scripts/make_sample_shoot.py`, which builds a shoot from the wallpapers that ship with macOS. **The owner's own photos are private.** Tools may run on them when the owner asks, but nobody opens, views or snapshots them for verification.

## Localization

The app ships in English, Russian and Turkmen. `docs/localization.md` holds what is and is not translated, the style rules and the glossary.

- **Catalogs.** Every target that shows text has a string catalog: `Culla/Localizable.xcstrings`, `Culla/InfoPlist.xcstrings` and one `Localizable.xcstrings` in each package target with text. Entries are written by hand, each with a comment for the translator; the compiler's own extraction is switched off for the app, because it would add entries without comments.
- **One way to get text.** `Localizer` in `CullaCore` reads a target's catalog: `let localized = Localizer(bundle: .module)` in a package target, `Localizer(bundle: .main)` in the app. It reads the language's own table together with that language's locale, so plural forms follow the language of the text (Russian has four) and not the Mac's region. An entry that is not translated yet falls back to English, never to its key. SwiftUI views take their text from the same `Localizer`.
- **Which language.** `Localization` in `CullaCore` decides: a task-local override (tests), else English in any test process, else the main bundle's preferred localization mapped to English, Russian or Turkmen, else English. Package text follows the app's language because the app declares all three languages; a tool whose main bundle declares none stays English throughout.
- **The language setting** stores the choice as the `AppleLanguages` preference of the app, the chosen language first and the system's own order after it, so the panels macOS draws fall back sensibly (macOS has no Turkmen). It takes effect at the next launch; Settings offers to quit and reopen. System default removes the preference.
- **Sentences are whole.** No sentence is joined from fragments and no plural is chosen with `count == 1`. A sentence with two counts uses the catalog's substitutions. Numbers, percentages, sizes and lists go through `Localization`'s formatters.
- **Stored text stays English.** What is written to disk (the `_Rejected` folder, sidecar values, the apply journal) is the same in every language; only the displayed form is translated. An error has an English `description` for the journal and logs and a localized `errorDescription` for the screen.
- **Keys work by position.** A key event becomes a chord from its typed character when that is printable ASCII or a special key, and otherwise from the key's position on the US layout (the 47 keys of the main block). So P, X and U keep working on a Russian or Turkmen layout, and a key recorded in Settings on such a layout is stored as its Latin position.
- **Tooling.** `Scripts/l10n.py` checks the catalogs (comments, placeholders, plural forms, stale and duplicate keys, and with `--require ru,tk` completeness), prints statistics, and exports and imports a translator's file. Unit tests always run in English and can render any language with `Localization.withLanguage`.
- **Verification.** Interface scripts launch the app in English unless a script names a language. Three scripts walk the same screens in English, Russian and Turkmen and save snapshots, menu titles and accessibility trees; `Scripts/l10n-screens.py` lists text that is identical to the English run, which is how leftover English is found.

## Checking for updates

The one thing Culla asks the network is whether a newer version exists. Decided on 2026-11-24; before that the app had no network access at all.

- **One request.** A GET of `https://cullaapp.com/update.json`, a static file the site's build writes from `site/release.json`: `version`, `minimumSystem` and `date`. An empty `date` means nothing is published.
- **Nothing is sent but the request.** No query string, no cookies, no cache, and three fixed headers: `User-Agent: Culla`, `Accept: application/json` and `Accept-Language: en`. The language is pinned because the system would otherwise send the person's language list. So the request carries neither the app's version nor anything about the Mac or the person; a capture on 2026-11-24 showed that the system adds only `Host`, `Cache-Control: no-cache`, `Accept-Encoding` and `Connection`. HTTPS only, redirects refused, a 15 second timeout, at most 64 KB read.
- **The answer is only compared.** The app never opens an address taken from the response. Download opens `https://cullaapp.com/download` and Release Notes opens the site's release notes page in the browser; both addresses are built into the app. Culla does not download or install anything itself.
- **When.** At most once in 24 hours, at launch or when the app becomes active, if "Check for updates automatically" is on (the default); and whenever the person chooses Culla ▸ Check for Updates… or Check Now in Settings.
- **What the person sees.** An automatic check that finds a newer version adds one line to the welcome view, with Download, Release Notes and Skip This Version. It never shows a dialog and never shows anything over an open shoot; a failed check and a version that needs a newer macOS are silent. The line is remembered between launches, and goes when a check finds nothing newer, when the version is skipped, or when automatic checks are switched off. A manual check always answers, with an alert on the window it was asked from.
- **Where the code is.** `CullaUpdates` holds the request and every decision. The app holds the checker's state, the menu item, the Settings section and the text. `com.apple.security.network.client` is the fourth and last entitlement; `Scripts/release.sh` refuses a build with any other set, and refuses one whose sources name `URLSession` or the Network framework outside `CullaUpdates`.
- **Under automation** the app never checks and never touches the network; scripts feed the checker a canned outcome.

## Rules

- Supported Apple APIs only. A feature that would need a private interface is dropped.
- No blocking work on Swift's cooperative pool or the main thread.
- The app is sandboxed. Its only use of the network is the update check described above; no other code may open a connection, and no network code lives outside `CullaUpdates`.
- No file is moved, deleted or written beside a photo except by the apply step, and the apply step is journalled so it can be undone.

# Culla

Culla is a free Mac app for culling photos. Open a shoot, and Culla sorts it into groups of likely rejects and lookalikes; you clear them from the keyboard, one key per photo or one key per burst, and nothing on disk changes until you review and apply your decisions.

This application was made with the use of AI tools.

Website: <https://cullaapp.com>. Releases: <https://github.com/kpirliyev/culla/releases>.

It is for anyone who comes home with hundreds or thousands of photos and wants to throw out the bad ones before editing: event, family and travel photographers, and anyone who shoots in bursts.

## What it finds

- **Closed eyes** on the main faces of a photo.
- **Blur**: a soft or motion-blurred subject, measured on the subject rather than the whole frame.
- **Exposure**: heavily clipped highlights or shadows.
- **Other issues**: a face cut by the frame's edge, lens smudge, a tilted horizon, accidental shots and a low aesthetics score.
- **Similar stacks**: bursts and frames taken close together that look alike, each with a best pick.
- **Duplicates**: byte-identical copies, and near-identical images such as a resized copy.

Detection uses Apple's Vision, Core Image and ImageIO frameworks, on your Mac. The lens smudge check needs the Neural Engine, so it is left out on a Mac without one, such as a virtual machine. Every threshold is a setting with a live count of what it would flag.

## How culling works

1. Drop a folder or memory card on the window, or press ⌘O. The grid fills at once; analysis runs in the background.
2. Clear the groups in the sidebar, starting with Duplicates and Similar Stacks. **P** keeps, **X** rejects, **U** clears a decision, **Space** switches between the grid and one large photo, **Return** accepts a stack (keep the pick, reject the rest).
3. Unreviewed photos count as kept, so you only ever have to find the rejects.
4. Press ⌘Return to review the rejects, then Apply: rejects move to a `_Rejected` folder inside the shoot (or are only marked in XMP sidecars, or go to the Trash). Apply can be undone.

Every key can be changed in Settings ▸ Keys; Help ▸ Keyboard Shortcuts (⌘/) lists them all.

## Privacy

- Everything happens on your Mac, and nothing is uploaded. The only thing Culla asks the internet is whether a newer version exists: at most once a day it reads one small file, `https://cullaapp.com/update.json`, sending nothing about you, your Mac or your photos. Settings ▸ General turns the automatic check off.
- Nothing is written into a shoot folder until you apply. Thumbnails, scores and decisions live in Culla's own container (`~/Library/Containers/com.kpirliyev.Culla`).
- Culla never changes an image file. Ratings and decisions go into `<name>.xmp` sidecars beside each photo, and an existing sidecar is merged, keeping everything else in it.

## Building from source

Requirements: a Mac with macOS 26 or later and Xcode 27.

```bash
git clone https://github.com/kpirliyev/culla.git Culla && cd Culla
open Culla.xcodeproj          # then Product ▸ Run
# or from the command line:
xcodebuild -project Culla.xcodeproj -scheme Culla -configuration Release build
```

The logic lives in a Swift package, `CullaKit`, which builds and tests on its own:

```bash
cd CullaKit && swift build && swift test
```

The one third-party dependency is [GRDB](https://github.com/groue/GRDB.swift), fetched by Swift Package Manager.

## The command-line detector check

`culla-eval` runs every detector over a folder and writes scores and contact sheets, without the app. The folder is only read.

```bash
cd CullaKit && swift run -c release culla-eval /path/to/a/shoot
open culla-eval-output/<folder name>/index.html
```

`culla-eval --help` lists its options, such as `--gap`, `--similarity` and `--near-duplicate` for trying other grouping settings on the saved scores.

## Languages

Culla's interface is in English, Russian and Turkmen. It follows the system language and falls back to English; Settings ▸ General can set the language for Culla alone. Translators: see `docs/localization.md` and `Scripts/l10n.py`.

## Status

Culla 1.0 is feature-complete and has been checked mostly on generated test shoots. Plainly:

- **Verified** on generated shoots of 35 to 10,000 photos made from the wallpapers that ship with macOS, by more than sixty scripted interface runs: opening, culling from the keyboard, stacks, duplicates, compare, Review and Apply with its undo, read-only and disconnected folders, settings and key remapping, speed and memory.
- **Verified on one real shoot** (108 photos from a Nikon D3200, run through `culla-eval`): every detector produces usable scores, and the default thresholds were chosen by eye from its contact sheets.
- **Not yet verified on real photos inside the app:** closed-eye detection and the face strip have only been exercised with simulated faces; the matching of a person across the frames of a burst has never been seen on real photos.
- **Detection defaults are provisional.** Tuning them on several real shoots (portraits, groups, low light, phone photos) is the next milestone. The exposure thresholds and the Certain cut-offs, which decide what ⇧X may reject in bulk, are marked Provisional in Settings.
- **Not yet checked:** whether Photomator reads Culla's sidecars; Move to the Trash and its undo inside the app; a memory card pulled out mid-session or a locked card on real hardware.
- Releases are signed with Developer ID and notarized by Apple.

## Feedback

Found a bug or missing something? Open an issue: <https://github.com/kpirliyev/culla/issues/new/choose>. Questions go to Discussions: <https://github.com/kpirliyev/culla/discussions>. English, Russian and Turkmen are all fine. To change the code, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Documentation

The design, the user flows, the architecture and the plan are Markdown files in [`docs/`](docs). Help ▸ Culla Documentation opens that folder in a build made from this repository.

## Licence

Culla is free and open source under the [MIT License](LICENSE). Copyright © 2026 Kerim Pirliyev.

# Contributing to Culla

Thank you for helping. Culla is small on purpose: a keyboard-first culler that never deletes anything by accident.

## Bugs, ideas and questions

Report a bug or suggest a feature with the forms at <https://github.com/kpirliyev/culla/issues/new/choose>. Ask questions in [Discussions](https://github.com/kpirliyev/culla/discussions). Please do not attach photos you would not show in public.

## Read first

The documentation is in [`docs/`](docs): [architecture](docs/architecture.md) (the rules the code is built to), [design](docs/design.md) (what the app shows), [user flows](docs/user-flows.md) and the [implementation plan](docs/implementation-plan.md). A change that breaks a rule in the architecture doc changes that doc in the same pull request.

## Build and test

Requires macOS 26 or later and Xcode 27.

```bash
cd CullaKit && swift build && swift test          # the package: all logic, unit-tested
xcodebuild -project Culla.xcodeproj -scheme Culla -configuration Debug build
Scripts/ui-all.sh --quick                          # interface scripts on generated shoots
Scripts/ui-all.sh                                  # all of them, including the slow large-shoot ones
```

The interface is checked by scripts that drive a Debug build and write snapshots and state dumps; see [`Scripts/README.md`](Scripts/README.md). Read the snapshots of the screens you changed. Test photos come from `Scripts/make_sample_shoot.py`, which builds shoots from the wallpapers that ship with macOS. Never use other people's photos as test data.

## Rules

- **Supported Apple APIs only.** Detection uses Vision, Core Image and ImageIO. A feature that would need a private interface is dropped, not approximated.
- **Nothing is written into a shoot folder** until the person applies their decisions, and the apply step is journalled so it can be undone. Tools write their output elsewhere.
- **No new packages.** GRDB is the only third-party dependency; ask before adding one.
- **One network request only.** The app is sandboxed with user-selected read and write access, app-scoped bookmarks and outgoing connections. The only connection it makes is the update check, which reads `https://cullaapp.com/update.json`. All network code lives in `CullaUpdates`; nothing else may open a connection. The Mac App Store variant (`Scripts/store.md`) leaves the update check out and has no network entitlement, so update code in the app stays inside `#if !APP_STORE`.
- **No blocking work on the main thread or Swift's cooperative pool.** Image decoding, pixel loops and Core Image's `CIDetector` run through `BlockingQueue` in `CullaCore`.
- **Logic goes in the package**, where it is unit-tested without the interface; the app target holds views and thin glue.
- **Every detection threshold is a `Tuning` value** shown in Settings, never a constant in a view.
- **Every user action is a `Command`**, so keys, menus and buttons stay in step and keys can be remapped.
- **Accessibility:** every control has a VoiceOver label, colour is never the only carrier of meaning, and animations follow Reduce Motion.

## Pull requests

Keep a pull request to one change, say what you checked (tests, scripts, snapshots read), and include the docs it affects.

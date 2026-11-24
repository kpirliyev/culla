# Publishing Culla on the Mac App Store

The steps that turn the source into a package App Store Connect accepts. `Scripts/store.sh` builds, checks and (only when asked) uploads it. The disk image for download from `cullaapp.com` is a separate thing and stays as it is: `Scripts/release.sh` and `Scripts/release.md`.

**Where this stands (2026-11-24).** The store variant builds and passes every check of `Scripts/store.sh --rehearse`. The signed path has never been run: the keychain holds no App Store certificates yet, so everything from "One-time setup" on is still to do and is the owner's. The list at the end says what has not been verified.

## The short way

```bash
Scripts/store.sh --rehearse
```

Needs no Apple account. Builds the store variant ad hoc signed into `build/store/` and runs the checks listed below.

```bash
Scripts/store.sh --preflight
```

Checks the version, the two signing identities and the provisioning profile, and says exactly what is missing.

```bash
Scripts/store.sh
```

Archives, exports the signed installer package, checks the app inside it and prints the package's path. It does not contact App Store Connect.

```bash
ASC_KEY_PATH=<AuthKey_….p8> ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer id> Scripts/store.sh --upload
```

The same, then validates the package with App Store Connect and uploads it. Only this form sends anything to Apple. An upload publishes nothing: the build appears in App Store Connect, where the owner chooses it and submits it for review.

## What the store build is

One project, one target, two variants. The build setting `CULLA_DISTRIBUTION` (`direct` or `appStore`), which only the app target reads, decides:

| | Disk image (`direct`) | Mac App Store (`appStore`) |
| --- | --- | --- |
| Configuration | `Release` | `AppStore`, a copy of `Release` |
| Compilation condition | none | `APP_STORE` |
| Entitlements | `Culla/Culla.entitlements`: four, with outgoing connections | `Culla/Culla-AppStore.entitlements`: three, without |
| Update check | Yes (`docs/architecture.md`, "Checking for updates") | None |
| Signed with | Developer ID, notarized | Apple Distribution, in a package signed with the installer certificate |

- **No update check.** Apple requires Mac App Store apps to update through the store (App Review Guideline 2.4.5), so under `APP_STORE` every file in `Culla/Updates/` is left out: there is no Culla ▸ Check for Updates…, no Updates section in Settings ▸ General, no line on the welcome view and no automatic check. The text for them stays in the string catalog, unused.
- **No network at all.** Without `com.apple.security.network.client` the sandbox refuses every connection. The `CullaUpdates` module is still linked into the binary, because Xcode links every package product of a target in every configuration and a single target cannot drop one per configuration; nothing calls it, and it could not connect if something did. `store.sh` says so in a note line. A second app target without the module would remove it, at the price of two targets to keep in step; decided against on 2026-11-24.
- **Same bundle identifier, same version.** Both variants are `com.kpirliyev.Culla` and share `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. App Store Connect refuses a build number it has already seen for a version, so raise the build number for every upload.
- **A Debug store build** for the interface scripts is `-configuration Debug CULLA_DISTRIBUTION=appStore`, which is what `Scripts/ui-run.sh --store` does.

`Scripts/store.sh` checks all of this on the built app and stops if one check fails:

- The property lists lint; the version, the build number and the bundle identifier are the project's.
- `LSApplicationCategoryType` is `public.app-category.photography` and `ITSAppUsesNonExemptEncryption` is false (so an upload asks no export compliance question).
- Exactly the three entitlements. In a signed build also the App ID and the team the profile grants, and nothing else: no `get-task-allow`, no `network.client`.
- No CFNetwork or Network.framework linked, and no network code in the sources outside `CullaKit/Sources/CullaUpdates`.
- No automation harness and none of the app's update code in the binary.
- The signature verifies; in a signed build it is the Apple Distribution identity of team `Z32TPH2T97`, a provisioning profile is embedded, and the package is signed with the installer identity.

## One-time setup

All of it is the owner's: it needs the Apple Developer account. Team `Z32TPH2T97`.

1. **Two certificates.** Xcode ▸ Settings ▸ Accounts ▸ the team ▸ Manage Certificates ▸ +, once for **Apple Distribution** and once for **Mac Installer Distribution**. They land in the login keychain as "Apple Distribution: …" and "3rd Party Mac Developer Installer: …". The Developer ID certificate cannot sign for the store.
2. **The App ID.** At developer.apple.com ▸ Certificates, Identifiers & Profiles ▸ Identifiers, register an explicit App ID for `com.kpirliyev.Culla`, platform macOS, with no extra capabilities. Skip it if it is already there.
3. **The provisioning profile.** Profiles ▸ + ▸ Distribution ▸ **Mac App Store Connect**; choose the App ID and the Apple Distribution certificate; name it exactly `Culla Mac App Store` (or pass another name with `--profile`). Then Xcode ▸ Settings ▸ Accounts ▸ the team ▸ Download Manual Profiles, which puts it in `~/Library/Developer/Xcode/UserData/Provisioning Profiles`, where `store.sh` looks.
4. **The app record.** In App Store Connect ▸ Apps ▸ + ▸ New App: platform macOS, the name, the primary language, the bundle identifier `com.kpirliyev.Culla` and any SKU. The name must be free on the store; if "Culla" is taken, a longer name such as "Culla: Photo Culling" is the usual way out. Not checked.
5. **An API key for the upload.** The App Store Connect API key that notarization already uses (`Scripts/release.md`) should do; give its `.p8` file, key ID and issuer ID in `ASC_KEY_PATH`, `ASC_KEY_ID` and `ASC_ISSUER_ID`. The values never go into a file in the repository or into a chat.

Then `Scripts/store.sh --preflight` must pass.

## The listing

Filled in by the owner in App Store Connect. The wording rules of `docs/landing-page-plan.md` hold here too: free and open source under the MIT licence, no performance claims, sidecars labelled Beta.

| Field | Note |
| --- | --- |
| Name, subtitle | 30 characters each |
| Description, keywords | 4,000 and 100 characters; in English and Russian. App Store Connect has no Turkmen as far as known, so the listing has two languages while the app ships three; check the language list |
| Screenshots | At least one, 16:10: 1280×800, 1440×900, 2560×1600 or 2880×1800. Made from the generated sample shoot, never from the owner's photos |
| Category | Photography |
| Price | Free |
| Support URL | `https://github.com/kpirliyev/culla/issues` |
| Privacy policy URL | Required for every app, and **there is none yet**: the site has no privacy page. A page on `cullaapp.com` in three languages, or a `PRIVACY.md` in the repository, is needed before submitting |
| App privacy | "Data Not Collected" is true for the store variant: it makes no connection |
| Age rating | The questionnaire; nothing in Culla raises it |
| Copyright | As in the app's Info.plist |
| Review notes | No account or sign-in. To try it: open any folder of photos; nothing is written into the folder until Apply |
| Seller | On an individual account the store shows the owner's legal name |
| EU trader status | A declaration the owner must make. A trader's address, phone number and email are shown on the store page in the EU; a free app with no income can usually be declared as non-trader. The owner's decision |

Two things a reviewer may question: the "Beta" label on sidecars (the guidelines discourage beta software on the store), and why the app asks for whole folders (it moves rejected photos and writes sidecars beside the kept ones, only inside the folder the person opened).

`cullaapp.com` must not mention the App Store until the app is approved and live (`docs/landing-page-plan.md`, "Not to claim").

## Upload and submit

1. Raise `CURRENT_PROJECT_VERSION` if this version's build number was uploaded before.
2. `Scripts/store.sh --upload` with the API key's three variables. It ends by saying where App Store Connect's answer is (`build/store/upload.json`).
3. Wait for the build to finish processing in App Store Connect (an email says so), choose it for the version and submit for review. The first review typically takes a few days and may come back once with questions about the listing.
4. Every later release goes out twice: the disk image (`Scripts/release.md`) and the store package. The disk image's users hear of it from the update check, the store's from the store.

## Not verified yet

- **The signed path of `store.sh`**: the archive with the Apple Distribution identity, the export, the package's signature, the entitlements of a signed build and the upload. It is written from what Xcode 27.1's `xcodebuild -help` and `xcrun altool --help` (27.0.5) document: export method `app-store-connect` (`app-store` is deprecated), `destination` `export`, `manageAppVersionAndBuildNumber` off so Xcode leaves the build number alone, and `altool --validate-app` / `--upload-package` with `--api-key`, `--api-issuer` and `--p8-file-path`. Whether altool accepts `--p8-file-path` together with `--api-key`, and whether a manual-signing export stays offline, are not known until the first run.
- **The interface scripts.** `Scripts/ui/72-store-no-update-check.json` (run with `Scripts/ui-run.sh … --store --reset`) asserts that the store variant shows no update check. It has not been run, and scripts 69 to 71 have not been run since the update views moved into `Culla/Updates/UpdateViews.swift`: macOS refused the session that built this access to the app's container. What is verified instead is the binary: the store build holds no `UpdateChecker`, no menu item and no Updates section.
- **Moving from the disk image to the store copy on one Mac.** Both use the container of `com.kpirliyev.Culla`, so settings and sessions should carry over, since both are signed by the same team. Check it once with the first store build.

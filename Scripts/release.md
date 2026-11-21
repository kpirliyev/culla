# Releasing Culla

The steps that turn the source into a signed, notarized disk image anyone can download. `Scripts/release.sh` runs all of them with one command, on the owner's Mac or on GitHub when a tag is pushed; the sections numbered 1 to 5 describe the same steps one by one, for understanding a failure or doing them by hand.

## The short way

**From this Mac.** With the Developer ID certificate in the login keychain and the notarization profile stored (section 2):

```bash
Scripts/release.sh --tag v1.0
```

It checks that the tag matches the project's version, archives, exports with Developer ID, runs the checks listed below, makes and signs the image, notarizes it, staples the ticket and asks Gatekeeper. The image, the logs and the archive land in `build/release/`; the last lines print the image's path, size and SHA-256. `--preflight` checks the version, the certificate and the credentials without building; `--skip-notarize` makes a rehearsal image named `Culla-<version>-not-notarized.dmg`. Then continue at section 5.

**From a tag, on GitHub.** `.github/workflows/release.yml` runs when a tag `v<version>` is pushed:

```bash
git tag v1.0
git push origin v1.0
```

It runs the package's tests and the translation check, imports the certificate into a temporary keychain, runs `Scripts/release.sh`, and attaches `Culla-<version>.dmg` to a **draft** release whose notes hold the size and the SHA-256. Nothing is public until the owner has checked the draft's image (section 5) and published it; then section 6, step 4 tells the site. The workflow refuses a tag that does not match `MARKETING_VERSION` and never overwrites an existing release.

The workflow needs five repository secrets, set once by the owner (the values never go into a file in the repository or into a chat):

```bash
base64 -i <Developer ID certificate and key>.p12 | gh secret set DEVELOPER_ID_P12_BASE64 --repo kpirliyev/culla
gh secret set DEVELOPER_ID_P12_PASSWORD --repo kpirliyev/culla      # asks for the .p12's password
base64 -i AuthKey_<key id>.p8 | gh secret set NOTARY_KEY_P8_BASE64 --repo kpirliyev/culla
gh secret set NOTARY_KEY_ID --repo kpirliyev/culla
gh secret set NOTARY_ISSUER_ID --repo kpirliyev/culla
```

The `.p12` comes from Keychain Access: select the "Developer ID Application" certificate together with its private key, File ▸ Export Items, and give it a password. The `.p8`, its key ID and the issuer ID are an App Store Connect API key (Users and Access ▸ Integrations ▸ Team Keys, role Developer).

The workflow runs on GitHub's `xcode-27` image and selects Xcode 27.1. It first ran to the end on 2026-11-21 for `v1.0` and left the draft with a notarized image. If a run fails, its log names the step; a failed test step also prints the crash reports. As a fallback, release from this Mac and attach the image by hand (section 6).

## What a release build must be

`Scripts/release.sh` checks all of these and stops if one fails. By hand, on the built app before signing:

```bash
APP=build/Release/Culla.app      # wherever the build put it
plutil -lint "$APP/Contents/Info.plist"
codesign -d --entitlements - "$APP"          # exactly: app-sandbox, files.user-selected.read-write, files.bookmarks.app-scope
otool -L "$APP/Contents/MacOS/Culla"          # no CFNetwork or Network.framework of its own
strings "$APP/Contents/MacOS/Culla" | grep -c CullaAutomation   # 0: the harness is compiled out ("Culla-Automation" and "isAutomation", the names of the separate data folders, remain and are harmless)
```

- Version 1.0, build 1 (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` in the project). Raise the build number for every upload to notarization.
- Hardened runtime is on (`ENABLE_HARDENED_RUNTIME = YES`); it is required for notarization.
- No `com.apple.security.get-task-allow`. With ad hoc signing (`CODE_SIGN_IDENTITY = "-"`) Xcode would add it to Release builds too, and notarization refuses it, so the Release configuration sets `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`. The commands below pass it as well, so they hold even if the project setting is ever lost.
- No network entitlement: the app never goes online.

## 1. Rehearse without an account

```bash
Scripts/make-dmg.sh --build --out ~/Desktop/Culla-1.0-unsigned.dmg
```

This builds the Release configuration (ad hoc signed, which is what the project does without an identity), checks it holds no automation code and exactly the three entitlements, and makes a compressed disk image with the app and a link to Applications. On another Mac, Gatekeeper refuses an unsigned download; that is expected until the steps below are done.

## 2. One-time setup (owner)

1. Join the Apple Developer Program and, in Xcode ▸ Settings ▸ Accounts, sign in with that Apple ID.
2. Create a **Developer ID Application** certificate (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ +). It lands in the login keychain.
3. The bundle identifier is `com.kpirliyev.Culla`, settled on 2026-11-21. Do not change it: a change moves everyone's settings and sessions to a new container.
4. Store notarization credentials once, under the profile name `culla-notary`, with an App Store Connect API key (the same key the GitHub workflow uses) or with an app-specific password from account.apple.com:

```bash
xcrun notarytool store-credentials culla-notary --key AuthKey_<key id>.p8 --key-id <key id> --issuer <issuer id>
xcrun notarytool store-credentials culla-notary --apple-id <apple id> --team-id <TEAMID>     # asks for the app-specific password
```

The team ID is `Z32TPH2T97`; `Scripts/release.sh` uses it by default, and it replaces `<TEAMID>` in the commands below.

## 3. Archive and sign with Developer ID

```bash
xcodebuild -project Culla.xcodeproj -scheme Culla -configuration Release \
  -archivePath build/Culla.xcarchive archive \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=<TEAMID> \
  ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp"
```

Export the signed app from the archive (Developer ID distribution keeps the hardened runtime and adds a secure timestamp):

```bash
cat > build/ExportOptions.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>TEAMID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath build/Culla.xcarchive -exportOptionsPlist build/ExportOptions.plist -exportPath build/export
```

Check the signature, the hardened runtime (`flags=0x10000(runtime)`) and the entitlements:

```bash
codesign --verify --deep --strict --verbose=2 build/export/Culla.app
codesign -dv --verbose=4 build/export/Culla.app 2>&1 | grep -E "Authority|flags|TeamIdentifier|Timestamp"
codesign -d --entitlements - build/export/Culla.app
```

## 4. Make the disk image, sign it, notarize it, staple it

```bash
Scripts/make-dmg.sh --app build/export/Culla.app --out build/Culla-1.0.dmg
codesign --sign "Developer ID Application" --timestamp build/Culla-1.0.dmg
xcrun notarytool submit build/Culla-1.0.dmg --keychain-profile culla-notary --wait
xcrun stapler staple build/Culla-1.0.dmg
xcrun stapler validate build/Culla-1.0.dmg
```

If notarization reports "Invalid", read why with `xcrun notarytool log <submission id> --keychain-profile culla-notary`. The usual causes are a missing secure timestamp or the hardened runtime being off.

## 5. Check like a stranger

On a Mac (or a fresh user account) that has never seen Culla:

```bash
spctl --assess --type open --context context:primary-signature -v build/Culla-1.0.dmg   # accepted, source=Notarized Developer ID
```

Download the image the way a person would (a browser sets the quarantine flag), open it, drag Culla to Applications and open it: there must be no security warning beyond the usual "downloaded from the internet" question. Then run all eight user flows from the keyboard (docs/user-flows.md) on a shoot of your own.

## 6. Publish

The disk image is published as an asset of a GitHub Release in `kpirliyev/culla`. The site's download button and `https://cullaapp.com/download` lead to that asset, so the tag and the file name must follow the pattern exactly: tag `v<version>`, file `Culla-<version>.dmg`.

1. Take the checksum and the size:

   ```bash
   shasum -a 256 build/Culla-1.0.dmg
   stat -f %z build/Culla-1.0.dmg
   ```

2. Create the release with the image attached (skip this step when the GitHub workflow made the draft: check its image as in section 5, then publish the draft). The notes are the "Status" section of the README and the checksum:

   ```bash
   gh release create v1.0 build/Culla-1.0.dmg --repo kpirliyev/culla --title "Culla 1.0" --notes-file <notes file>
   ```

3. Download the asset from the release page in a browser and repeat step 5 on it.

4. Only then tell the site: fill in `site/release.json` (`version`, `file`, `size`, `sha256` and `date`; an empty `date` means "not released yet") and the release notes in `site/data/release-notes/`, and deploy the site (`site/deploy/deploy.sh`). From that deploy on, `/download` redirects to the asset. Done in this order, the page never links to a file that is not there.

GitHub counts the downloads of each asset; the server reads that count once a day (`site/deploy/count.py`).

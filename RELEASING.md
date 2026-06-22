# Releasing (signed + notarized DMG)

How the maintainer builds a signed, notarized `.dmg` for a GitHub Release.

> **No secrets live in this repo.** You run these commands locally; your
> Developer ID certificate / private key stay in your login keychain and never
> leave your Mac. The published `.dmg` only contains your *public* signing
> identity (name + Team ID), which is inherent to any Developer-ID-signed app.

All paths below assume you start in the `app/` directory.

---

## One-time setup

1. **Apple Developer Program** — $99/yr (<https://developer.apple.com/programs/>).
   ⚠️ *Individual* enrollment puts your **legal name** into the signature (visible
   in the DMG). Use *Organization* enrollment (needs a D-U-N-S number) if you want
   an org name shown instead. Decide before signing a public build.

2. **Developer ID Application certificate** — create it in Xcode → Settings →
   Accounts → *Manage Certificates* → **+** → *Developer ID Application*. Confirm:

   ```bash
   security find-identity -v -p codesigning
   # → should list:  Developer ID Application: YOUR NAME (TEAMID)
   ```

3. **create-dmg**:

   ```bash
   brew install create-dmg
   ```

4. **App-specific password + notarytool profile** (store once, no secrets in
   scripts afterward). Make an app-specific password at
   <https://account.apple.com> → *Sign-In & Security* → *App-Specific Passwords*:

   ```bash
   xcrun notarytool store-credentials "mt-notary" \
     --apple-id "you@example.com" --team-id "TEAMID" \
     --password "abcd-efgh-ijkl-mnop"
   ```

---

## Release steps

Set your identity once for the session:

```bash
cd app
export SIGN_ID="Developer ID Application: YOUR NAME (TEAMID)"
```

### 1. (optional) Bump the version

Edit `app/Info.plist`: `CFBundleShortVersionString` (e.g. `0.1.0`) and
`CFBundleVersion` (e.g. `1`).

### 2. Build + sign (release, Hardened Runtime, entitlements, timestamp)

```bash
SIGN_ID="$SIGN_ID" ./make-app.sh release
```

Verify the signature and entitlements:

```bash
codesign -dvvv --entitlements - "Multitrack Tap.app"
# expect: Authority=Developer ID Application: YOUR NAME (TEAMID)
#         flags=...runtime...
#         com.apple.security.device.audio-input = true
codesign --verify --strict "Multitrack Tap.app"   # no output = OK
```

### 3. Notarize the app, then staple

```bash
ditto -c -k --keepParent "Multitrack Tap.app" "MultitrackTap.zip"
xcrun notarytool submit "MultitrackTap.zip" --keychain-profile "mt-notary" --wait
#  → status: Accepted
xcrun stapler staple "Multitrack Tap.app"
rm "MultitrackTap.zip"
```

If it comes back **Invalid**, read why:

```bash
xcrun notarytool log <submission-id> --keychain-profile "mt-notary"
```

### 4. Build the DMG (from the stapled app)

```bash
# The installer window is branded: a retina background (PNG masters in assets/,
# Grok source assets/dmg-bg-source.jpg) + the app icon as the volume icon.
# Regenerate the background .tiff from the PNG masters first:
tiffutil -cathidpicheck \
  "../assets/dmg-background.png" "../assets/dmg-background@2x.png" \
  -out "../assets/dmg-background.tiff"

mkdir -p dmg-staging && cp -R "Multitrack Tap.app" dmg-staging/
rm -f "Multitrack Tap.dmg"
create-dmg \
  --volname "Multitrack Tap" \
  --volicon "AppIcon.icns" \
  --background "../assets/dmg-background.tiff" \
  --window-pos 240 120 \
  --window-size 600 400 \
  --icon-size 128 \
  --icon "Multitrack Tap.app" 160 210 \
  --app-drop-link 440 210 \
  --hide-extension "Multitrack Tap.app" \
  "Multitrack Tap.dmg" \
  "dmg-staging/"
rm -rf dmg-staging
```

### 5. Sign + notarize + staple the DMG

```bash
codesign --force --sign "$SIGN_ID" --timestamp "Multitrack Tap.dmg"   # no --options runtime for a DMG
xcrun notarytool submit "Multitrack Tap.dmg" --keychain-profile "mt-notary" --wait
xcrun stapler staple "Multitrack Tap.dmg"
```

### 6. Verify (the real end-user check)

```bash
xcrun stapler validate "Multitrack Tap.dmg"
spctl -a -vvv -t install "Multitrack Tap.dmg"
#  → accepted, source=Notarized Developer ID
```

Best: upload it somewhere, download it on a clean Mac, double-click — it should
open with no Gatekeeper block, and the Microphone + System Audio Recording
prompts should appear.

---

## Publish

Hand the finished `Multitrack Tap.dmg` to the maintainer flow / CI, or attach it
to a GitHub Release:

```bash
gh release create v0.1.0 "Multitrack Tap.dmg" \
  --title "Multitrack Tap 0.1.0" \
  --notes "First signed, notarized release."
```

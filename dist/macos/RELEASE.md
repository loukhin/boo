# Boo macOS release (local)

Local mirror of the Ghostty CI release pipeline. Produces a signed,
notarized, stapled `Boo.app` (+ optional `.dmg`) suitable for
distribution outside the App Store.

Pipeline is in `dist/macos/release-local.sh`. This doc covers the
one-time setup.

---

## Prerequisites

Install once:

- macOS with Xcode ≥ 16 + command line tools.
- `zig` matching `build.zig`'s expected version (use `mise` / `asdf`).
- Apple Developer Program membership ($99/year) — required for
  Developer ID Application signing and notarization.
- Optional: `npm i -g create-dmg` if you want a `.dmg`.
- Optional: Sparkle tools for appcast signing (`sign_update`). Ships in
  the Sparkle release zip from
  <https://github.com/sparkle-project/Sparkle/releases>.

---

## 1. Apple Developer Portal setup

All steps happen at <https://developer.apple.com/account>.

### 1a. Developer ID Application certificate

This is the certificate that signs the app bundle.

1. Account → **Certificates, Identifiers & Profiles** → **Certificates**
   → **+**.
2. Pick **Developer ID Application** (NOT "Apple Development" —
   that's only for local testing and can't be notarized).
3. Follow the CSR instructions: in *Keychain Access* →
   *Certificate Assistant* → *Request a Certificate From a
   Certificate Authority…* → save to disk. Upload the `.certSigningRequest`.
4. Download the resulting `.cer`, double-click to install into the
   login keychain.
5. Verify it's present:
   ```sh
   security find-identity -p codesigning -v | grep 'Developer ID Application'
   ```
   Note the full identity string, e.g.
   `Developer ID Application: Your Name (ABCDE12345)`.
   That string is `MACOS_CERTIFICATE_NAME`. The parenthesized part is
   your Team ID.

> The private key stays in your keychain. Back it up by exporting the
> identity to a `.p12` from Keychain Access.

### 1b. App Identifier (bundle ID)

Boo uses `town.lop.boo` (see
`PRODUCT_BUNDLE_IDENTIFIER` in `macos/Ghostty.xcodeproj/project.pbxproj`).

1. **Identifiers** → **+** → *App IDs* → *App*.
2. Description: `Boo`. Bundle ID (explicit): `town.lop.boo`.
3. Capabilities: leave defaults (Boo isn't sandboxed; the
   `macos/Boo.entitlements` file already lists what's needed —
   hardened runtime gives you everything).
4. Register.

Also register the dock tile plugin bundle ID `town.lop.boo-dock-tile`
the same way. (Not strictly required for notarization, but avoids a
warning.)

### 1c. App Store Connect API key (for notarization)

`notarytool` uses an App Store Connect key, not an Apple ID + app
password. This is the modern, scriptable path.

1. Go to <https://appstoreconnect.apple.com/access/integrations/api>.
2. **Keys** tab → **Generate API Key**.
3. Name: `Boo Notarization`. Access: **Developer** is sufficient for
   notarization (no need for Admin).
4. Download the `.p8` file. **You can only download it once.** Store it
   at something like `~/Library/Keys/AuthKey_XXXXXXXXXX.p8`.
5. Record three values from the Keys page:
   - **Issuer ID** (UUID at the top of the page) →
     `APPLE_NOTARIZATION_ISSUER`.
   - **Key ID** (10-character string next to the key) →
     `APPLE_NOTARIZATION_KEY_ID`.
   - Path to the `.p8` file → `APPLE_NOTARIZATION_KEY`.

### 1d. (Optional) Sparkle update signing

Only needed if Boo uses Sparkle to auto-update.

```sh
# Generate an ed25519 keypair (one time, from the Sparkle release zip):
./generate_keys
# -> creates dsa_pub.pem and dsa_priv.pem (Sparkle calls them that even
#    though they're actually ed25519 with modern Sparkle).
```

- Put the **public key** string into `Ghostty-Info.plist` under
  `SUPublicEDKey`.
- Keep the **private key** in a safe place; pass its path as
  `BOO_SPARKLE_KEY` to the release script.

---

## 2. Local environment

Create `~/.config/boo-release.env` (never commit this):

```sh
# From step 1a
export MACOS_CERTIFICATE_NAME="Developer ID Application: Your Name (ABCDE12345)"

# From step 1c
export APPLE_NOTARIZATION_ISSUER="00000000-0000-0000-0000-000000000000"
export APPLE_NOTARIZATION_KEY_ID="ABCDEFGHIJ"
export APPLE_NOTARIZATION_KEY="$HOME/Library/Keys/AuthKey_ABCDEFGHIJ.p8"

# Optional Sparkle
# export BOO_SPARKLE_KEY="$HOME/Library/Keys/boo_sparkle_priv.pem"
# export BOO_SPARKLE_PUB="paste-public-key-string-here"

# Optional: produce a signed .dmg as well
# export BOO_MAKE_DMG=1
```

Source it before running the release script:

```sh
source ~/.config/boo-release.env
```

---

## 3. Run the release

```sh
./dist/macos/release-local.sh
```

Output ends up in `dist/out/`:

- `boo-macos-universal.zip` — the app, ready to distribute.
- `boo-macos-universal-dsym.zip` — debug symbols (keep for crash
  symbolication).
- `Boo <version>.dmg` + `Boo <version>.dmg.sparkle.txt` — only if
  `BOO_MAKE_DMG=1`.

### Useful flags

| Env | Effect |
|---|---|
| `SKIP_NOTARIZE=1` | Build + sign only. Fast sanity check. |
| `SKIP_LIBGHOSTTY=1` | Reuse existing `GhosttyKit.xcframework`; skip `zig build`. |
| `CONFIGURATION=ReleaseLocal` | Ad-hoc signed build (won't notarize, runs only on your Mac). |
| `OPTIMIZE=Debug` | `zig -Doptimize=Debug`. Matches CI `debug-slow`. |

---

## 4. What each pipeline step does

The script follows upstream Ghostty's `release-tip.yml`:

1. `zig build -Demit-macos-app=false` → produces
   `macos/GhosttyKit.xcframework`.
2. `xcodebuild -target Boo -configuration Release` → produces
   `macos/build/Release/Boo.app`. Runs in a scrubbed env (`env -i`)
   because Nix's `NIX_CFLAGS_COMPILE` etc. breaks `xcodebuild`.
3. `PlistBuddy` stamps `CFBundleVersion` (= commit count),
   `CFBundleShortVersionString` (= short SHA), and optionally
   `SUPublicEDKey`.
4. `codesign -f -o runtime` with your Developer ID identity, in this
   exact order: Sparkle XPCs → Sparkle Autoupdate → Sparkle Updater.app
   → Sparkle.framework → DockTilePlugin → app bundle (with
   `Boo.entitlements`). Hardened runtime is **required** for
   notarization.
5. `notarytool submit --wait` uploads a zipped app to Apple. Typically
   finishes in 1–5 minutes. Apple returns `Accepted` / `Invalid`.
6. `stapler staple` embeds the notarization ticket so Gatekeeper
   works offline.
7. `spctl -a -vvv --type execute` verifies the final bundle.
8. `zip -r --symlinks` preserves the Sparkle symlink structure
   (critical — `zip` without `--symlinks` corrupts `Sparkle.framework`).

---

## 5. Troubleshooting

- **`errSecInternalComponent` from codesign**: your login keychain is
  locked. Run `security unlock-keychain login.keychain`.
- **Notarization `Invalid` with "The binary is not signed with a valid
  Developer ID certificate"**: you used "Apple Development" instead of
  "Developer ID Application". Re-check `security find-identity`.
- **`The executable does not have the hardened runtime enabled`**: a
  nested binary was missed by the `sign()` loop. Run
  `codesign -dv --verbose=4 path/to/nested` to inspect. Hardened runtime
  shows up as `flags=0x10000(runtime)`.
- **`ditto` vs `zip` for notarization upload**: always use `ditto -c -k
  --keepParent` (what the script does). Plain `zip` loses xattrs and
  notarization fails.
- **Want to inspect a rejection**: `xcrun notarytool log <submission-id>
  --keychain-profile boo-notarytool`.

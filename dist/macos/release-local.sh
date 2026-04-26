#!/usr/bin/env bash
#
# Local mirror of Ghostty's CI release pipeline, adapted for Boo.
# Builds, signs, notarizes, staples, and zips Boo.app.
#
# Prerequisites: see dist/macos/RELEASE.md.
#
# Required environment variables (export these or put in a .env you source):
#   MACOS_CERTIFICATE_NAME      "Developer ID Application: Your Name (TEAMID)"
#   APPLE_NOTARIZATION_ISSUER   App Store Connect API issuer UUID
#   APPLE_NOTARIZATION_KEY_ID   App Store Connect API key ID (10-char)
#   APPLE_NOTARIZATION_KEY      Path to AuthKey_*.p8 file
#
# Optional:
#   BOO_SPARKLE_KEY             Path to Sparkle private ed25519 key (for sign_update)
#   BOO_MAKE_DMG=1              Produce a signed .dmg (requires `create-dmg` via npm)
#   SKIP_NOTARIZE=1             Skip notarization + stapling (for faster local smoke tests)
#   SKIP_LIBGHOSTTY=1           Reuse existing GhosttyKit.xcframework, skip zig build
#   CONFIGURATION=Release       Xcode configuration (default Release)
#   OPTIMIZE=ReleaseFast        zig -Doptimize value (default ReleaseFast)
#
set -euo pipefail

# --- sanity checks --------------------------------------------------------

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: must run on macOS" >&2
  exit 1
fi

: "${MACOS_CERTIFICATE_NAME:?set MACOS_CERTIFICATE_NAME to your Developer ID Application identity}"

CONFIGURATION="${CONFIGURATION:-Release}"
OPTIMIZE="${OPTIMIZE:-ReleaseFast}"
APP_NAME="Boo"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_PATH="${REPO_ROOT}/macos/build/${CONFIGURATION}/${APP_NAME}.app"
DSYM_PATH="${APP_PATH}.dSYM"
DIST_DIR="${REPO_ROOT}/dist/out"
mkdir -p "${DIST_DIR}"

BUILD_COMMIT="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
BUILD_NUMBER="$(git -C "${REPO_ROOT}" rev-list --count HEAD)"

echo ">> Boo local release"
echo "   commit:  ${BUILD_COMMIT}"
echo "   build:   ${BUILD_NUMBER}"
echo "   config:  ${CONFIGURATION}"
echo "   app:     ${APP_PATH}"

# --- 1. libghostty (zig) --------------------------------------------------

if [[ "${SKIP_LIBGHOSTTY:-0}" != "1" ]]; then
  echo ">> [1/7] zig build (libghostty, no macos app)"
  (cd "${REPO_ROOT}" && zig build "-Doptimize=${OPTIMIZE}" -Demit-macos-app=false)
else
  echo ">> [1/7] SKIPPED zig build"
fi

# --- 2. xcodebuild --------------------------------------------------------

echo ">> [2/7] xcodebuild -target Boo -configuration ${CONFIGURATION}"
# Run in a clean env so Nix (if present) doesn't poison xcodebuild.
env -i HOME="${HOME}" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  xcodebuild -project "${REPO_ROOT}/macos/Ghostty.xcodeproj" \
             -target "${APP_NAME}" \
             -configuration "${CONFIGURATION}"

# --- 3. stamp Info.plist --------------------------------------------------

echo ">> [3/7] stamp Info.plist"
PLIST="${APP_PATH}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${PLIST}" || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${BUILD_COMMIT}" "${PLIST}" || true
# If you have the GhosttyCommit key in your plist, uncomment:
# /usr/libexec/PlistBuddy -c "Set :GhosttyCommit ${BUILD_COMMIT}" "${PLIST}" || true

if [[ -n "${BOO_SPARKLE_PUB:-}" ]]; then
  # SUPublicEDKey is intentionally absent from the committed Info.plist
  # (Boo doesn't ship ghostty's key). Try Set first for the (rare) case
  # where the plist already carries the key, then fall back to Add.
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey ${BOO_SPARKLE_PUB}" "${PLIST}" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${BOO_SPARKLE_PUB}" "${PLIST}"
fi

# --- 4. codesign ----------------------------------------------------------

echo ">> [4/7] codesign (hardened runtime)"
sign() {
  /usr/bin/codesign --verbose -f -s "${MACOS_CERTIFICATE_NAME}" -o runtime "$@"
}

SPARKLE="${APP_PATH}/Contents/Frameworks/Sparkle.framework"
if [[ -d "${SPARKLE}" ]]; then
  sign "${SPARKLE}/Versions/B/XPCServices/Downloader.xpc"
  sign "${SPARKLE}/Versions/B/XPCServices/Installer.xpc"
  sign "${SPARKLE}/Versions/B/Autoupdate"
  sign "${SPARKLE}/Versions/B/Updater.app"
  sign "${SPARKLE}"
fi

DOCKTILE="${APP_PATH}/Contents/PlugIns/DockTilePlugin.plugin"
if [[ -d "${DOCKTILE}" ]]; then
  sign "${DOCKTILE}"
fi

/usr/bin/codesign --verbose -f -s "${MACOS_CERTIFICATE_NAME}" -o runtime \
  --entitlements "${REPO_ROOT}/macos/Boo.entitlements" \
  "${APP_PATH}"

/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

# --- 5. notarize + staple -------------------------------------------------

if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  : "${APPLE_NOTARIZATION_ISSUER:?set APPLE_NOTARIZATION_ISSUER}"
  : "${APPLE_NOTARIZATION_KEY_ID:?set APPLE_NOTARIZATION_KEY_ID}"
  : "${APPLE_NOTARIZATION_KEY:?set APPLE_NOTARIZATION_KEY (path to AuthKey_*.p8)}"

  echo ">> [5/7] notarize"
  # Register credentials once per machine (idempotent: xcrun overwrites).
  xcrun notarytool store-credentials "boo-notarytool" \
    --key "${APPLE_NOTARIZATION_KEY}" \
    --key-id "${APPLE_NOTARIZATION_KEY_ID}" \
    --issuer "${APPLE_NOTARIZATION_ISSUER}" >/dev/null

  NOTARIZE_ZIP="${DIST_DIR}/notarize.zip"
  /usr/bin/ditto -c -k --keepParent "${APP_PATH}" "${NOTARIZE_ZIP}"
  xcrun notarytool submit "${NOTARIZE_ZIP}" --keychain-profile "boo-notarytool" --wait
  rm -f "${NOTARIZE_ZIP}"

  echo ">> [6/7] staple"
  xcrun stapler staple "${APP_PATH}"
  /usr/bin/spctl -a -vvv --type execute "${APP_PATH}"
else
  echo ">> [5/7] SKIP notarize"
  echo ">> [6/7] SKIP staple"
fi

# --- 7. package -----------------------------------------------------------

echo ">> [7/7] package"
ZIP_OUT="${DIST_DIR}/boo-macos-universal.zip"
DSYM_ZIP="${DIST_DIR}/boo-macos-universal-dsym.zip"
(cd "${REPO_ROOT}/macos/build/${CONFIGURATION}" && \
  /usr/bin/zip -9 -r --symlinks "${ZIP_OUT}" "${APP_NAME}.app")
if [[ -d "${DSYM_PATH}" ]]; then
  (cd "${REPO_ROOT}/macos/build/${CONFIGURATION}" && \
    /usr/bin/zip -9 -r --symlinks "${DSYM_ZIP}" "${APP_NAME}.app.dSYM")
fi
echo "   -> ${ZIP_OUT}"
[[ -f "${DSYM_ZIP}" ]] && echo "   -> ${DSYM_ZIP}"

if [[ "${BOO_MAKE_DMG:-0}" == "1" ]]; then
  echo ">> make dmg"
  command -v create-dmg >/dev/null || { echo "create-dmg not found: npm i -g create-dmg"; exit 1; }
  (cd "${DIST_DIR}" && create-dmg --identity="${MACOS_CERTIFICATE_NAME}" "${APP_PATH}")
  # Sparkle signature for appcast
  if [[ -n "${BOO_SPARKLE_KEY:-}" ]]; then
    command -v sign_update >/dev/null || { echo "sign_update (Sparkle) not in PATH"; exit 1; }
    DMG="$(ls -1t "${DIST_DIR}"/*.dmg | head -n1)"
    sign_update -f "${BOO_SPARKLE_KEY}" "${DMG}" | tee "${DMG}.sparkle.txt"
  fi
fi

echo ">> done."

#!/usr/bin/env bash
# Assembles the Multitrack Tap SwiftUI executable into a non-sandboxed .app
# bundle so macOS TCC can attribute the audio-capture (System Audio Recording)
# permission to it. A bare CLI/binary has no Info.plist / bundle identity, so
# capturing other apps' audio is silently denied (0 callbacks).
#
# Signing:
#   - Default: ad-hoc (`codesign --sign -`). Works, BUT the audio-capture grant
#     is keyed to the code signature and will NOT persist across rebuilds — you
#     re-grant every time.
#   - Stable identity: set SIGN_ID to a signing identity (self-signed or
#     Developer ID) to get a persistent TCC grant across rebuilds:
#         SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./make-app.sh
#
# After building, launch the app bundle (so it has bundle identity):
#     open "Multitrack Tap.app"
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP="Multitrack Tap.app"
BIN_NAME="MultitrackTap"
BUNDLE_ID="com.github.zhiii0x.multitracktap"

echo "Building (${CONFIG})..."
swift build -c "${CONFIG}"
BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${BIN_NAME}"

echo "Assembling ${APP} ..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"
cp "${BIN_PATH}" "${APP}/Contents/MacOS/${BIN_NAME}"
cp "Info.plist" "${APP}/Contents/Info.plist"
cp "AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"

if [[ -n "${SIGN_ID:-}" ]]; then
    echo "Signing with stable identity: ${SIGN_ID}"
    # Hardened Runtime (--options runtime) + the audio-input entitlement (needed
    # for mic access under Hardened Runtime) + a secure timestamp, so the result
    # is ready for notarization with a Developer ID identity. The same flags make
    # a self-signed dev identity give a persistent TCC grant across rebuilds.
    codesign --force --sign "${SIGN_ID}" --identifier "${BUNDLE_ID}" \
        --options runtime --timestamp \
        --entitlements "MultitrackTap.entitlements" "${APP}"
    echo "  -> signed + hardened; audio-capture grant persists with this identity."
else
    echo "Signing (ad-hoc)..."
    codesign --force --sign - "${APP}"
    echo ""
    echo "WARNING: ad-hoc signature. The System Audio Recording (audio-capture)"
    echo "         grant will NOT persist across rebuilds — you'll re-grant each"
    echo "         time. Set SIGN_ID to a stable identity to avoid this:"
    echo "             SIGN_ID=\"Developer ID Application: …\" ./make-app.sh"
fi

echo ""
echo "Done -> ${APP}"
echo "Launch it (gives the app bundle identity so TCC can grant the permission):"
echo "  open \"${APP}\""
echo ""
echo "Headless engine checks (no GUI, no permission needed for --match):"
echo "  \"${APP}/Contents/MacOS/${BIN_NAME}\" --list"
echo "  \"${APP}/Contents/MacOS/${BIN_NAME}\" --match com.google.Chrome"

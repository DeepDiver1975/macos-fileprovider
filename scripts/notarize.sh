#!/usr/bin/env bash
#
# Notarize and staple the release artifacts (release automation).
#
# Without notarization Gatekeeper refuses to open a downloaded app at all ("Apple
# cannot check it for malicious software"), so this is not optional polish — an
# un-notarized .dmg is close to unusable for the people it is built for.
#
# Two submissions, in this order, because a stapled ticket lives in the artifact it
# was stapled to:
#
#   1. the .app  — so a user who drags the app out of the image and onto another Mac
#                  still has a ticket, even offline
#   2. the .dmg  — so the download itself passes Gatekeeper before it is ever opened
#
# The .dmg must therefore be rebuilt *after* the app is stapled; this script drives
# that ordering by calling make-dmg.sh's packaging half itself.
#
# Usage:
#   VERSION=1.2.0 BUILD=147 scripts/notarize.sh
#
# Credentials (all required — an App Store Connect API key, not an Apple ID):
#   ASC_KEY_PATH   path to the .p8 private key
#   ASC_KEY_ID     the key's ID
#   ASC_ISSUER_ID  the issuer UUID

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

readonly APP_NAME="ownCloud File Provider.app"
readonly VOLUME_NAME="ownCloud File Provider"
readonly DIST_DIR="dist"
readonly EXPORT_DIR="$DIST_DIR/export"
readonly STAGE_DIR="$DIST_DIR/dmg-stage"
readonly EXPORTED_APP="$EXPORT_DIR/$APP_NAME"

# No VERSION here: the artifact's name comes from make-dmg.sh via
# dist/artifact-path.txt, so this script cannot disagree with it.
: "${ASC_KEY_PATH:?ASC_KEY_PATH is required (App Store Connect .p8)}"
: "${ASC_KEY_ID:?ASC_KEY_ID is required}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required}"

if [[ ! -d "$EXPORTED_APP" ]]; then
    echo "notarize: $EXPORTED_APP not found — run scripts/make-dmg.sh first" >&2
    exit 1
fi

# An unsigned build (make-dmg.sh SIGNING=none, the per-PR smoke tier) cannot be
# notarized: the notary service rejects anything that is not Developer ID signed. Caught
# here rather than at Apple, because the rejection arrives minutes later and reads as a
# notarization failure rather than "you built the wrong thing".
readonly SIGNING_MODE_FILE="$DIST_DIR/signing-mode.txt"
if [[ -f "$SIGNING_MODE_FILE" ]] && [[ "$(cat "$SIGNING_MODE_FILE")" == "none" ]]; then
    echo "notarize: dist/ holds an UNSIGNED build (signing-mode.txt says 'none')." >&2
    echo "          Notarization requires a Developer ID signature. Rebuild with" >&2
    echo "          the default SIGNING=developer-id before notarizing." >&2
    exit 1
fi

# Taken from make-dmg.sh rather than re-derived from VERSION/DMG_NAME here: this
# script rebuilds the image in place, and two independent guesses at the same
# filename would diverge the first time the naming changed, leaving the original
# .dmg un-notarized next to a stapled one nobody publishes.
readonly ARTIFACT_PATH_FILE="$DIST_DIR/artifact-path.txt"
if [[ ! -f "$ARTIFACT_PATH_FILE" ]]; then
    echo "notarize: $ARTIFACT_PATH_FILE not found — run scripts/make-dmg.sh first" >&2
    exit 1
fi
readonly DMG_PATH="$(cat "$ARTIFACT_PATH_FILE")"
if [[ ! -f "$DMG_PATH" ]]; then
    echo "notarize: $DMG_PATH (from $ARTIFACT_PATH_FILE) does not exist" >&2
    exit 1
fi

declare -ra NOTARY_AUTH=(
    --key "$ASC_KEY_PATH"
    --key-id "$ASC_KEY_ID"
    --issuer "$ASC_ISSUER_ID"
)

# Submits one artifact and waits for the verdict. `--wait` turns a rejection into a
# non-zero exit, so a failed notarization fails the release rather than publishing an
# artifact users cannot open.
submit() {
    local path="$1"
    echo "==> notarytool submit $(basename "$path")"
    xcrun notarytool submit "$path" "${NOTARY_AUTH[@]}" --wait
}

# --- 1. the app --------------------------------------------------------------
# notarytool takes a container, not a bundle, so the .app goes up zipped. ditto with
# --keepParent preserves the bundle structure and its symlinks; `zip -r` would not.
echo "==> Notarizing the app"
readonly APP_ZIP="$DIST_DIR/app-for-notarization.zip"
ditto -c -k --keepParent "$EXPORTED_APP" "$APP_ZIP"
submit "$APP_ZIP"
rm -f "$APP_ZIP"

# Staple the ticket into the .app itself (the zip was only a transport).
echo "==> Stapling the app"
xcrun stapler staple "$EXPORTED_APP"

# --- 2. rebuild the image around the stapled app -----------------------------
# Rebuilt rather than patched: the ticket has to be inside the copy of the app that
# the image carries.
echo "==> Rebuilding the disk image around the stapled app"
rm -rf "$STAGE_DIR" "$DMG_PATH"
mkdir -p "$STAGE_DIR"
cp -R "$EXPORTED_APP" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"
rm -rf "$STAGE_DIR"

readonly SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
codesign --sign "$SIGN_IDENTITY" --timestamp --force "$DMG_PATH"

# --- 3. the image ------------------------------------------------------------
echo "==> Notarizing the disk image"
submit "$DMG_PATH"
echo "==> Stapling the disk image"
xcrun stapler staple "$DMG_PATH"

# --- 4. verify what will actually be published -------------------------------
# Checked here rather than trusted: each of these has a distinct failure mode, and all
# of them are silent until a user hits them.
echo "==> Verifying the artifacts"

echo "--- codesign (app, deep) ---"
codesign --verify --deep --strict --verbose=2 "$EXPORTED_APP"

echo "--- stapler validate (app) ---"
xcrun stapler validate "$EXPORTED_APP"

echo "--- stapler validate (dmg) ---"
xcrun stapler validate "$DMG_PATH"

# The closest thing to what Gatekeeper does when a user opens the download.
echo "--- spctl assessment (dmg) ---"
spctl -a -vvv -t install "$DMG_PATH"

echo "==> Notarized and stapled: $DMG_PATH"

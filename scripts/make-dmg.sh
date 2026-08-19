#!/usr/bin/env bash
#
# Build the release artifact: a signed .dmg containing the app with both extensions
# embedded (release automation).
#
# Lives in a script rather than in the workflow so a release is reproducible on a
# developer Mac with the same commands CI runs — progress.md AC-4, "no CI-only
# wiring". Called by `make dmg` and by .github/workflows/release.yml.
#
# Usage:
#   VERSION=1.2.0 BUILD=147 scripts/make-dmg.sh                 # signed release
#   SIGNING=none VERSION=0.0.0 BUILD=1 scripts/make-dmg.sh      # unsigned smoke build
#
# Environment:
#   VERSION   (required) marketing version, e.g. 1.2.0 — numeric only, no `v`, no
#             prerelease suffix; Apple rejects those in CFBundleShortVersionString.
#             scripts/release-version.sh derives it from the tag.
#   BUILD     (required) build number -> CFBundleVersion. CI passes the run number.
#   SIGNING   (optional) `developer-id` (default) or `none`. See below.
#   DMG_NAME  (optional) artifact basename; defaults to the full tag version when
#             ARTIFACT_VERSION is set, otherwise VERSION.
#   ARTIFACT_VERSION (optional) full tag version incl. any prerelease suffix, used
#             only for naming so `-rc.1` is visible in the download.
#   ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID (optional) App Store Connect API key,
#             letting automatic signing mint Developer ID profiles unattended. Absent
#             locally, where Xcode's own signed-in account already has them.
#
# SIGNING=none exists so the release path is exercised on every PR and push rather
# than first running on a tag (progress.md Task 9.7). It needs no certificate, no
# provisioning profile and no App Store Connect key, so it runs on a fork PR and on
# a developer Mac with no Xcode account — which is exactly where the signed path
# cannot run at all. It proves that the Release configuration builds, that the
# version reaches all three bundles and that packaging works; it proves nothing
# about signing, entitlements or notarization, and three steps are skipped
# accordingly (export, the entitlements guard, and signing the image). The artifact
# is therefore named `-unsigned` and dist/signing-mode.txt records the mode so
# notarize.sh cannot be pointed at it.
#
# Output: dist/<name>.dmg, plus dist/export/<app> for the notarize step to staple.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

readonly APP_NAME="ownCloud File Provider.app"
readonly VOLUME_NAME="ownCloud File Provider"
readonly DIST_DIR="dist"
readonly ARCHIVE_PATH="$DIST_DIR/App.xcarchive"
readonly EXPORT_DIR="$DIST_DIR/export"
readonly STAGE_DIR="$DIST_DIR/dmg-stage"

: "${VERSION:?VERSION is required (e.g. VERSION=1.2.0)}"
: "${BUILD:?BUILD is required (e.g. BUILD=147)}"

# Apple accepts one to three dot-separated integers here and nothing else; catching a
# stray `v` or `-rc.1` now beats failing at the notary step twenty minutes later.
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "make-dmg: VERSION '$VERSION' must be numeric dotted digits (got a prefix or suffix?)" >&2
    exit 1
fi

readonly SIGNING="${SIGNING:-developer-id}"
case "$SIGNING" in
    developer-id|none) ;;
    *)
        echo "make-dmg: SIGNING must be 'developer-id' or 'none', got '$SIGNING'" >&2
        exit 1
        ;;
esac

# The `-unsigned` suffix is appended here rather than left to the caller: an unsigned
# image skips the entitlements guard, so it must be impossible to produce one whose
# filename is indistinguishable from a release artifact. A caller-supplied DMG_NAME is
# suffixed too, for the same reason.
artifact_name="${DMG_NAME:-ownCloud-File-Provider-${ARTIFACT_VERSION:-$VERSION}}"
if [[ "$SIGNING" == "none" ]]; then
    artifact_name="${artifact_name}-unsigned"
fi
readonly ARTIFACT_NAME="$artifact_name"
readonly DMG_PATH="$DIST_DIR/${ARTIFACT_NAME}.dmg"

echo "==> Building $VERSION ($BUILD), signing=$SIGNING -> $DMG_PATH"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# The image's path, for whoever consumes it next (notarize.sh, the release workflow's
# checksum and upload steps). Written rather than reconstructed: the name depends on
# VERSION, ARTIFACT_VERSION and DMG_NAME, and a consumer that rebuilt that expression
# would break quietly the first time the naming here changed.
readonly ARTIFACT_PATH_FILE="$DIST_DIR/artifact-path.txt"
printf '%s\n' "$DMG_PATH" > "$ARTIFACT_PATH_FILE"

# How this image was signed, for notarize.sh to refuse an unsigned one. Recorded as
# state rather than inferred from the filename: a `-unsigned` suffix is a naming
# convention, and notarization failing loudly here beats submitting an ad-hoc-signed
# image to Apple and reading the rejection twenty minutes later.
readonly SIGNING_MODE_FILE="$DIST_DIR/signing-mode.txt"
printf '%s\n' "$SIGNING" > "$SIGNING_MODE_FILE"

# --- 1. generate the project -------------------------------------------------
# The .xcodeproj is not committed (PROJECT.md); project.yml is the source of truth.
echo "==> xcodegen generate"
xcodegen generate

# --- 2. archive --------------------------------------------------------------
# The version override on the command line outranks project.yml's development
# defaults and reaches all three bundles, because every Info.plist references
# $(MARKETING_VERSION)/$(CURRENT_PROJECT_VERSION) rather than a literal.
declare -a auth_flags=()
if [[ -n "${ASC_KEY_PATH-}" ]]; then
    auth_flags=(
        -authenticationKeyPath "$ASC_KEY_PATH"
        -authenticationKeyID "${ASC_KEY_ID:?ASC_KEY_ID required with ASC_KEY_PATH}"
        -authenticationKeyIssuerID "${ASC_ISSUER_ID:?ASC_ISSUER_ID required with ASC_KEY_PATH}"
    )
fi

# Signing flags. `-allowProvisioningUpdates` is deliberately absent when unsigned:
# with automatic signing xcodebuild would go looking for Developer ID profiles, which
# is precisely what an unsigned build exists to avoid needing. CODE_SIGN_STYLE=Manual
# for the same reason.
declare -a signing_flags=(-allowProvisioningUpdates)
if [[ "$SIGNING" == "none" ]]; then
    signing_flags=(
        CODE_SIGNING_ALLOWED=NO
        CODE_SIGNING_REQUIRED=NO
        CODE_SIGN_IDENTITY=""
        CODE_SIGN_ENTITLEMENTS=""
        CODE_SIGN_STYLE=Manual
    )
fi

echo "==> xcodebuild archive"
xcodebuild archive \
    -project OwnCloudFileProvider.xcodeproj \
    -scheme App \
    -configuration Release \
    -destination 'platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    "${signing_flags[@]}" \
    "${auth_flags[@]}"

readonly EXPORTED_APP="$EXPORT_DIR/$APP_NAME"

# --- 3. export ---------------------------------------------------------------
# This is what re-signs the embedded .appex bundles for Developer ID distribution;
# copying the .app out of the archive by hand would leave them development-signed.
if [[ "$SIGNING" == "none" ]]; then
    # Nothing to re-sign, and -exportArchive would fail anyway: developer-id export
    # requires an account and a profile per bundle id. Copying the app out of the
    # archive keeps every later stage identical between the two modes, so the packaging
    # half is exercised by the same code either way.
    echo "==> Skipping -exportArchive (SIGNING=none): copying the app out of the archive"
    mkdir -p "$EXPORT_DIR"
    cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME" "$EXPORT_DIR/"
else
    echo "==> xcodebuild -exportArchive"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist scripts/ExportOptions.plist \
        -allowProvisioningUpdates \
        "${auth_flags[@]}"
fi

if [[ ! -d "$EXPORTED_APP" ]]; then
    echo "make-dmg: no $APP_NAME in $EXPORT_DIR" >&2
    ls -la "$EXPORT_DIR" >&2
    exit 1
fi

# --- 4. assert the version actually propagated -------------------------------
# The whole point of the release is that the tag reaches the bundles. Extensions are
# a separate target each, so a settings mistake could stamp the app and miss them —
# and the About window would then report versions that disagree. Check all three.
echo "==> Verifying $VERSION in all three bundles"
for plist in \
    "Contents/Info.plist" \
    "Contents/PlugIns/FileProviderExtension.appex/Contents/Info.plist" \
    "Contents/PlugIns/FileProviderUIExtension.appex/Contents/Info.plist"
do
    got_version="$(plutil -extract CFBundleShortVersionString raw "$EXPORTED_APP/$plist")"
    got_build="$(plutil -extract CFBundleVersion raw "$EXPORTED_APP/$plist")"
    if [[ "$got_version" != "$VERSION" || "$got_build" != "$BUILD" ]]; then
        echo "make-dmg: $plist reports $got_version ($got_build), expected $VERSION ($BUILD)" >&2
        exit 1
    fi
    echo "    $plist -> $got_version ($got_build)"
done

# --- 4b. assert the shipped entitlements ------------------------------------
# The testing-mode entitlement must not ship (see the Release entitlements file).
#
# Written to a file and parsed rather than piped and grepped, because a *failed*
# dump also produces no match: an ad-hoc-signed or unreadable binary would sail
# through a bare `| grep -q testing-mode` and report success. So the dump must
# parse, and two entitlements the extension cannot work without must be present —
# that positive control proves real entitlements are being read before the
# absence of testing-mode is allowed to mean anything.
#
# Skipped entirely when unsigned, and loudly: an unsigned .appex is ad-hoc
# (linker-signed), and `codesign -d --entitlements` then exits **0** while writing no
# file at all. The positive control below would catch that — PlistBuddy fails on the
# missing file — but it would be reported as "entitlements did not survive export",
# which is a misleading diagnosis for a build that was never signed. The declarations
# are covered instead by ReleaseEntitlementsTests in the core suite, which runs on
# every PR; this check remains the only thing that inspects the *artifact*.
readonly ENTITLEMENTS_PLIST="$DIST_DIR/shipped-appex.entitlements.plist"

# PlistBuddy rather than `plutil -extract`: plutil treats dots in a key as keypath
# separators, so it reports every reverse-DNS entitlement key as missing.
has_entitlement() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$ENTITLEMENTS_PLIST" >/dev/null 2>&1
}

verify_shipped_entitlements() {
    echo "==> Verifying the shipped extension's entitlements"
    if ! codesign -d --entitlements "$ENTITLEMENTS_PLIST" --xml \
            "$EXPORTED_APP/Contents/PlugIns/FileProviderExtension.appex" 2>&1; then
        echo "make-dmg: could not read the shipped extension's entitlements" >&2
        return 1
    fi

    local required
    for required in com.apple.security.app-sandbox com.apple.security.application-groups; do
        if ! has_entitlement "$required"; then
            echo "make-dmg: $required missing from the shipped extension — the entitlements" >&2
            echo "          did not survive export, so the testing-mode check below is not" >&2
            echo "          trustworthy either. Refusing to package." >&2
            return 1
        fi
    done

    if has_entitlement com.apple.developer.fileprovider.testing-mode; then
        echo "make-dmg: the shipped FileProviderExtension carries the testing-mode" >&2
        echo "          entitlement — check that project.yml maps the Release config to" >&2
        echo "          FileProviderExtension-Release.entitlements." >&2
        return 1
    fi
    echo "    app-sandbox + app group present, testing-mode absent"
}

if [[ "$SIGNING" == "none" ]]; then
    echo "==> Skipping the entitlements check (SIGNING=none)"
    echo "    An unsigned .appex carries no entitlements blob to read, so this check"
    echo "    cannot pass and must not appear to. ReleaseEntitlementsTests pins the"
    echo "    declarations; only a signed build can be checked as an artifact."
else
    verify_shipped_entitlements
fi

echo "==> Package the disk image"

# --- 5. stage and build the image -------------------------------------------
# hdiutil deliberately, not create-dmg: this machine has no Homebrew image tooling
# (the same finding that shaped the icon generator in issue #18), and hdiutil is
# present on every macOS runner.
mkdir -p "$STAGE_DIR"
cp -R "$EXPORTED_APP" "$STAGE_DIR/"
# The drag-to-install affordance. macOS requires the app in an Applications folder
# for the File Provider extension to be discovered at all (progress.md Task 5.1), so
# this symlink is functional, not decorative.
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"

# --- 6. sign the image -------------------------------------------------------
# Gatekeeper checks the disk image's own signature before the app inside it.
if [[ "$SIGNING" == "none" ]]; then
    echo "==> Skipping codesign of the disk image (SIGNING=none)"
    echo "    Gatekeeper will refuse this image on another Mac. It is a build check,"
    echo "    not something to hand to a user."
else
    readonly SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
    echo "==> codesign the disk image"
    codesign --sign "$SIGN_IDENTITY" --timestamp --force "$DMG_PATH"
    codesign --verify --verbose "$DMG_PATH"
fi

rm -rf "$STAGE_DIR"

echo "==> Done: $DMG_PATH"

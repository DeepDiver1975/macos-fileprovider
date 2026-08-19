# Xcode project structure

This repository does **not** commit a generated `.xcodeproj`. The project is
generated from the committed **`project.yml`** (XcodeGen) — SPM has no product
type that emits an `.appex`, so the two extensions cannot be SPM targets (see
`progress.md` Task 1.1). This file records the intended structure; `project.yml`
is the machine-readable source of truth.

## Generating and building

```sh
brew install xcodegen        # one-time
xcodegen generate            # writes OwnCloudFileProvider.xcodeproj from project.yml
xcodebuild -project OwnCloudFileProvider.xcodeproj -scheme App \
  -destination 'platform=macOS' build         # builds app + both .appex
xcodebuild test -project OwnCloudFileProvider.xcodeproj -scheme App \
  -destination 'platform=macOS'               # runs the OwnCloudCore suite
```

The generated `.xcodeproj` is git-ignored; regenerate it after editing
`project.yml`.

## Targets

| Target | Type | Sources | Info.plist | Entitlements |
|---|---|---|---|---|
| `App` | macOS App | `App/Sources/` | `App/SupportingFiles/Info.plist` | `App/SupportingFiles/App.entitlements` |
| `FileProviderExtension` | File Provider Extension (`.appex`) | `FileProviderExtension/Sources/` | `FileProviderExtension/SupportingFiles/Info.plist` | `FileProviderExtension.entitlements` (Debug) / `FileProviderExtension-Release.entitlements` (Release) — see [Releasing](#releasing) |
| `FileProviderUIExtension` | File Provider UI Extension (`.appex`) | `FileProviderUIExtension/Sources/` | `FileProviderUIExtension/SupportingFiles/Info.plist` | `FileProviderUIExtension/SupportingFiles/FileProviderUIExtension.entitlements` |

The App target **embeds** both `.appex` targets in `Contents/PlugIns` (Xcode:
"Frameworks, Libraries, and Embedded Content" → Embed Without Signing is wrong
here; use the extension's own signing).

## Shared app icon (issue #18)

All three targets list the same `Resources/Assets.xcassets` in their `sources:`,
so the ownCloud cloud mark ships in the app bundle **and** in both `.appex`
bundles — which bundle macOS reads for a sync root's Finder icon is undocumented,
so covering all three removes the guess.

The `AppIcon.appiconset` PNGs are generated and committed; regenerate them with

```sh
make icons                   # swift Resources/Icon/make-icon.swift
```

which rasterizes the committed upstream logo. `Resources/Icon/README.md` records
the artwork's provenance and the two non-obvious wiring details (see
[Build settings that matter](#build-settings-that-matter)).

## Shared core

All three targets depend on the local SPM package **`OwnCloudCore`** (`Core/`),
which holds the backend-agnostic logic (WebDAV XML parsing, oCIS Graph models,
credential/session management). Add it via File → Add Package Dependencies →
Add Local… → select `Core/`, then add the `OwnCloudCore` library to each target's
"Frameworks, Libraries, and Embedded Content".

`OwnCloudCore` is intentionally Linux-buildable (Foundation +
FoundationNetworking only) so its clients can be driven against both backends in
Docker on `ubuntu-latest` in CI (see `progress.md` AC-2, backend-contract tier).

## Build settings that matter

- `MACOSX_DEPLOYMENT_TARGET = 14.0` on every target.
- `PRODUCT_BUNDLE_IDENTIFIER`:
  - App: `com.owncloud.macos.fileprovider`
  - Extension: `com.owncloud.macos.fileprovider.FileProvider`
  - UI Extension: `com.owncloud.macos.fileprovider.FileProviderUI`
  - (Extension bundle ids must be prefixed by the app's bundle id.)
- App group `group.com.owncloud.macos.fileprovider` and keychain group
  `<AppIdentifierPrefix>com.owncloud.macos.fileprovider.shared` on all three
  targets (see the `.entitlements` files).
- `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` on the **two extension** targets.
  An app target gets this for free; an extension target does not, and without it
  `actool` runs but the `.appex` ships an empty `Contents/Resources` — no icon,
  no error.
- `CFBundleIconName` / `CFBundleIconFile` = `AppIcon` written explicitly into all
  three `Info.plist`s. `GENERATE_INFOPLIST_FILE = NO` here, so `actool`'s partial
  plist is never merged and the keys would otherwise be absent.
- `NSHumanReadableCopyright` on the App target (Finder's Get Info reads it).
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` are development defaults
  (`0.0.1` / `1`). A release overrides both on the `xcodebuild` command line — see
  [Releasing](#releasing).
- `ENABLE_HARDENED_RUNTIME = YES` on every target. Required for notarization; the
  notary service rejects a submission whose executables were built without it.

## Releasing

Pushing a `v*` tag builds a signed, notarized `.dmg` and publishes it as a GitHub
release (`.github/workflows/release.yml`).

### Tag convention

| Tag | `CFBundleShortVersionString` | Release |
|---|---|---|
| `v1.2.0` | `1.2.0` | normal release |
| `v1.2.0-rc.1` | `1.2.0` | **pre**release, titled `v1.2.0-rc.1` |

Apple accepts only one to three dot-separated integers in
`CFBundleShortVersionString`, so a prerelease suffix cannot reach the bundle: the
numeric core stamps the bundles while the full tag names the release and the
artifact. `scripts/release-version.sh` owns that split and is tested —
`make release-version-test` — because it is the one piece of release logic with
real edge cases. A malformed tag fails the run rather than shipping a bundle
whose version is empty.

`CFBundleVersion` is the workflow run number, so the About window's `1.2.0 (147)`
identifies the CI run that produced the build.

### How the version reaches all three bundles

All three `Info.plist`s reference `$(MARKETING_VERSION)` and
`$(CURRENT_PROJECT_VERSION)` rather than literals, and command-line build settings
outrank project settings — so one

```sh
xcodebuild … MARKETING_VERSION=1.2.0 CURRENT_PROJECT_VERSION=147
```

stamps the app and both extensions. `scripts/make-dmg.sh` then **asserts** the
result in all three `Info.plist`s and fails the build on a mismatch: the
extensions are separate targets, so a settings mistake could stamp the app and
miss them, and the About window would report versions that disagree.

### Two things that had to change before a release was possible

1. **`ENABLE_HARDENED_RUNTIME`** was set nowhere. Notarization rejects a
   submission without it, so every release would have failed at the notary step.
2. **`com.apple.developer.fileprovider.testing-mode`** is a *restricted*
   entitlement that Apple grants only through a development provisioning profile.
   A Developer ID profile does not carry it and signing fails outright, so
   Release builds use `FileProviderExtension-Release.entitlements` — the same file
   minus that key. Correct regardless of signing: the entitlement exists so the
   acceptance suite can drive `NSFileProviderDomain.testingModes`
   deterministically (`progress.md` AC-3), which is a developer capability, not a
   user one. **Keep the two entitlements files in step when either changes.**
   `make-dmg.sh` verifies the shipped extension has the app sandbox and app group
   but *not* testing-mode; the first two are a positive control, so a dump that
   silently failed cannot be mistaken for a stripped entitlement.
   `AppGroupIdentifierTests` reads the Release file too, because it is the one that
   ships: a bare `group.…` id there would deny the extension its container in
   released builds only, while every Debug build kept working.

### Running it locally

The workflow only supplies credentials; the build itself lives in scripts, so a
release is reproducible on a developer Mac with the same commands CI runs
(`progress.md` AC-4 — no CI-only wiring):

```sh
make release-version-test                # the tag parser's own tests
make dmg VERSION=1.2.0 BUILD=1           # archive → export → signed dist/*.dmg
make notarize                            # submit, staple, verify (needs an ASC key)
```

`make dmg` needs a `Developer ID Application` identity and a Developer ID
provisioning profile for each of the three bundle ids. With no Xcode account
signed in, `xcodebuild -exportArchive` fails with `No Accounts` / `No profiles for
'com.owncloud.macos.fileprovider' were found`; sign in to Xcode, or pass an App
Store Connect key (`ASC_KEY_PATH`, `ASC_KEY_ID`, `ASC_ISSUER_ID`) so automatic
signing can mint them unattended, which is what CI does.

`make notarize` takes no `VERSION`: it reads the image's path from
`dist/artifact-path.txt`, written by `make dmg`, so the two cannot disagree about
the filename.

### Why a `.dmg`, and why `hdiutil`

A `.pkg` would need a `Developer ID Installer` certificate, which this team does
not have; the `.dmg` is signed with the `Developer ID Application` certificate
that does exist. It is built with `hdiutil` rather than `create-dmg` because
Homebrew image tooling is absent here and `hdiutil` ships with every macOS runner.

The app is stapled **before** the image is built around it, so a user who drags
the app out of the image onto another Mac still has a valid ticket offline. That
is why `notarize.sh` rebuilds the `.dmg` rather than patching it.

### Required repository secrets

None of these exist yet; a release cannot run until they are configured.

| Secret | Contents |
|---|---|
| `MACOS_CERTIFICATE_P12` | base64 of the `Developer ID Application` `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | its export password |
| `KEYCHAIN_PASSWORD` | any value; unlocks the job's temporary keychain |
| `APPLE_API_KEY_P8` | base64 of the App Store Connect `.p8` private key |
| `APPLE_API_KEY_ID` | the key's ID |
| `APPLE_API_ISSUER_ID` | the issuer UUID |

## Test harness (Task 1.4)

- `swift test` from `Core/` covers the SPM core package. **Sandbox note:** the
  Xcode module cache is outside the default command sandbox, so `swift test`
  must run with the sandbox disabled in this environment.
- `xcodebuild test` covers XCTest targets inside the Xcode project (added on the
  Mac once the project exists).

## Why a generated project

A hand-written `.pbxproj` is fragile and unreviewable. Instead the reviewable
artifacts — sources, Info.plists, entitlements, and the `project.yml` manifest —
are committed; the `.xcodeproj` is generated from them with XcodeGen. This keeps
project changes as readable diffs to `project.yml`.

Verified on Xcode 16.4 / macOS 26: `xcodegen generate` + `xcodebuild build`
produces the app bundle embedding both `.appex` extensions in `Contents/PlugIns`,
and `embeddedBinaryValidationUtility` confirms the two extension-point
identifiers (`com.apple.fileprovider-nonui`, `com.apple.fileprovider-actionsui`).

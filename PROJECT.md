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
| `FileProviderExtension` | File Provider Extension (`.appex`) | `FileProviderExtension/Sources/` | `FileProviderExtension/SupportingFiles/Info.plist` | `FileProviderExtension/SupportingFiles/FileProviderExtension.entitlements` |
| `FileProviderUIExtension` | File Provider UI Extension (`.appex`) | `FileProviderUIExtension/Sources/` | `FileProviderUIExtension/SupportingFiles/Info.plist` | `FileProviderUIExtension/SupportingFiles/FileProviderUIExtension.entitlements` |

The App target **embeds** both `.appex` targets in `Contents/PlugIns` (Xcode:
"Frameworks, Libraries, and Embedded Content" → Embed Without Signing is wrong
here; use the extension's own signing).

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

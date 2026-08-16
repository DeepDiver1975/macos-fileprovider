# Xcode project structure

This repository does **not** commit a generated `.xcodeproj`. The project must be
assembled on a Mac in Xcode (SPM has no product type that emits an `.appex`, so
the two extensions cannot be SPM targets — see `progress.md` Task 1.1). This file
records the intended structure so the project can be reconstructed identically.

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

## Why no committed project file

No `xcodegen`/`tuist` is available in the loop environment, and a hand-written
`.pbxproj` is fragile and unreviewable. The reviewable artifacts — sources,
Info.plists, entitlements — are committed; the `.xcodeproj` is generated from
them on the Mac. If a project generator is later adopted, its manifest
(`project.yml` for XcodeGen) should be committed here and this note updated.

# macOS ownCloud File Provider Extension - Master Progress & Development Plan

## Project Architecture & Core Objectives

* **Target OS:** macOS 14+ (Sonoma and newer) using the modern `FileProvider` and `FileProviderUI` frameworks.
* **Extension model:** `NSFileProviderReplicatedExtension` (the modern replicated provider). This is mutually exclusive with the legacy `NSFileProviderExtension` — do not mix the two APIs.
* **Backends Supported:** ownCloud Classic (WebDAV / SabreDAV XML) and ownCloud Infinite Scale (oCIS via Graph API / OIDC).
* **Architecture Style:** Test-Driven Development (TDD) loop engineering framework combining OpenCode/Claude Code with strict discipline enforcement.

---

## Phase 1: Project Skeleton & Entitlements Setup

* [ ] **Task 1.1:** Create the **Xcode project** with three targets: the containing app, the File Provider extension (`.appex`), and the FileProviderUI extension (`.appex`). SPM has no product type that emits an `.appex`, so the extensions cannot be SPM targets. Place backend-agnostic core logic (WebDAV XML parsing, Graph models, credential/session management) in a **local SPM package** consumed by all three targets.
* [ ] **Task 1.2:** Configure `Info.plist` for **each** extension target separately:
  * File Provider extension → `NSExtensionPointIdentifier` = `com.apple.fileprovider-nonui`
  * FileProviderUI extension → `NSExtensionPointIdentifier` = `com.apple.fileprovider-actionsui`
  * Add `NSExtensionFileProviderSupportsPickingFolders` if folder picking is required.
  * Note: there is no `NSFileProviderDomainUsageDescription` key — FileProvider has no privacy purpose string.
* [ ] **Task 1.3:** Setup code signing entitlements. The extension is sandboxed, so it needs:
  * `com.apple.security.app-sandbox`
  * `com.apple.security.network.client` — **required**; without it every request in Phase 2 fails immediately
  * `keychain-access-groups` (or `com.apple.security.application-groups`) so the containing app's sign-in flow and the extension can share credentials (needed by Tasks 2.5, 5.1, 5.2) — must be provisioned up front, not retrofitted
  * `com.apple.developer.fileprovider.testing-mode` for the Task 5.3 integration suite
  * Do **not** add `com.apple.security.files.downloads.read-write` / `files.user-selected.read-write` to the extension — those are host-app file-picker entitlements; a replicated provider writes into the system-provided domain directory.
* [ ] **Task 1.4:** Establish the test harness: `swift test` covers the local SPM core package; the extension targets are covered by XCTest targets inside the Xcode project (`xcodebuild test`).

## Phase 2: Core Protocols & Networking Layer (TDD)

* [ ] **Task 2.1:** Write failing unit test for parsing ownCloud Classic WebDAV `PROPFIND` multi-status XML responses into native domain models.
* [ ] **Task 2.2:** Implement robust XML parser (`XMLParser` delegate or lightweight parser) to pass Task 2.1.
* [ ] **Task 2.3:** Write failing unit test for oCIS Graph API JSON deserialization (drives, item lists, delta sync tokens).
* [ ] **Task 2.4:** Implement oCIS Graph API client structures to pass Task 2.3.
* [ ] **Task 2.5:** Implement unified credential and session manager handling basic auth (Classic) and OAuth2/OIDC token refresh (oCIS).

## Phase 3: File Provider Domain & Enumeration (`NSFileProviderEnumerating`)

* [ ] **Task 3.1:** Write failing unit test for `NSFileProviderEnumerator` container initialization mapping remote container roots to `NSFileProviderItem`.
* [ ] **Task 3.2:** Implement root and child item enumeration logic supporting pagination and sync anchors (`NSFileProviderSyncAnchor`).
* [ ] **Task 3.3:** Implement change tracking enumeration (`enumerateChanges(for:from:)`, taking an `NSFileProviderChangeObserver` and a `from:` sync anchor) handling server-side additions, modifications, and deletions.

## Phase 4: File Operations & Synchronization (`NSFileProviderReplicatedExtension`)

* [ ] **Task 4.1:** Write failing unit test for file hydration via `fetchContents(for:version:request:completionHandler:)`. Note the replicated contract: the extension downloads to a location **it** chooses and hands that URL back, after which the system takes ownership of the file and moves it into its own replicated store.
* [ ] **Task 4.2:** Implement remote item fetch and content streaming to a temporary URL returned to the system. Do **not** maintain a separate long-lived disk cache — the system already stores hydrated content, so a self-managed cache double-stores every file.
* [ ] **Task 4.3:** Write failing unit test for local file modification detection and upload queuing.
* [ ] **Task 4.4:** Implement the push synchronization handlers of `NSFileProviderReplicatedExtension` (`createItem`, `modifyItem`, `deleteItem`) routing requests to either WebDAV or oCIS backends.

## Phase 5: UI & Extension Lifecycle Integration

* [ ] **Task 5.1:** Implement `NSFileProviderManager` domain setup, connection, and user sign-in flow initialization. **Prerequisite:** on macOS the extension is only discovered and launched when the containing app resides in `/Applications` (or `~/Applications`), or FileProvider testing mode is enabled. Launched straight from Xcode's DerivedData, `add(domain:)` reports success and Finder silently shows nothing.
* [ ] **Task 5.2:** Build File Provider UI extension for authentication credential inputs and domain removal actions.
* [ ] **Task 5.3:** Run end-to-end integration test suite validating Finder synchronization performance and error recovery states.

---

## Log & Execution History

* *2026-08-16*: Initialized `process.md` tracking layout for macOS File Provider extension TDD loop engineering.
* *2026-08-16*: Corrected Apple API names, extension point identifiers, `Info.plist` keys and sandbox entitlements after review of PR #1. API names still to be re-verified against Apple's documentation at the start of Phase 1.

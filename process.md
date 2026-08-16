# macOS ownCloud File Provider Extension - Master Progress & Development Plan

## Project Architecture & Core Objectives

* **Target OS:** macOS 14+ (Sonoma and newer) using the modern `FileProvider` and `FileProviderUI` frameworks.
* **Backends Supported:** ownCloud Classic (WebDAV / SabreDAV XML) and ownCloud Infinite Scale (oCIS via Graph API / OIDC).
* **Architecture Style:** Test-Driven Development (TDD) loop engineering framework combining OpenCode/Claude Code with strict discipline enforcement.

---

## Phase 1: Project Skeleton & Entitlements Setup

* [ ] **Task 1.1:** Initialize Swift Package Manager / Xcode project structure with a dedicated macOS File Provider Extension target and FileProviderUI target.
* [ ] **Task 1.2:** Configure mandatory `Info.plist` keys (`NSExtensionPointIdentifier` = `com.apple.fileproviderservices`, `NSFileProviderDomainUsageDescription`).
* [ ] **Task 1.3:** Setup proper code signing entitlements (`com.apple.security.files.downloads.read-write`, `com.apple.security.files.user-selected.read-write`, and File Provider specific domain access).
* [ ] **Task 1.4:** Establish base unit test harness (`swift test` target configuration).

## Phase 2: Core Protocols & Networking Layer (TDD)

* [ ] **Task 2.1:** Write failing unit test for parsing ownCloud Classic WebDAV `PROPFIND` multi-status XML responses into native domain models.
* [ ] **Task 2.2:** Implement robust XML parser (`XMLParser` delegate or lightweight parser) to pass Task 2.1.
* [ ] **Task 2.3:** Write failing unit test for oCIS Graph API JSON deserialization (drives, item lists, delta sync tokens).
* [ ] **Task 2.4:** Implement oCIS Graph API client structures to pass Task 2.3.
* [ ] **Task 2.5:** Implement unified credential and session manager handling basic auth (Classic) and OAuth2/OIDC token refresh (oCIS).

## Phase 3: File Provider Domain & Enumeration (`NSFileProviderEnumerating`)

* [ ] **Task 3.1:** Write failing unit test for `NSFileProviderEnumerator` container initialization mapping remote container roots to `NSFileProviderItem`.
* [ ] **Task 3.2:** Implement root and child item enumeration logic supporting pagination and sync anchors (`NSFileProviderSyncAnchor`).
* [ ] **Task 3.3:** Implement change tracking enumeration (`enumerateChanges(for:upTo:)`) handling server-side additions, modifications, and deletions.

## Phase 4: File Operations & Synchronization (`NSFileProviderReuestProviding`)

* [ ] **Task 4.1:** Write failing unit test for file hydration/download routing (fetching remote content stream and staging it at the requested URL).
* [ ] **Task 4.2:** Implement remote item fetch and content streaming into local disk cache.
* [ ] **Task 4.3:** Write failing unit test for local file modification detection and upload queuing.
* [ ] **Task 4.4:** Implement push synchronization handlers (`createItem`, `modifyItem`, `deleteItem`) routing requests to either WebDAV or oCIS backends.

## Phase 5: UI & Extension Lifecycle Integration

* [ ] **Task 5.1:** Implement `NSFileProviderManager` domain setup, connection, and user sign-in flow initialization.
* [ ] **Task 5.2:** Build File Provider UI extension for authentication credential inputs and domain removal actions.
* [ ] **Task 5.3:** Run end-to-end integration test suite validating Finder synchronization performance and error recovery states.

---

## Log & Execution History

* *2026-08-16*: Initialized `progress.md` tracking layout for macOS File Provider extension TDD loop engineering.

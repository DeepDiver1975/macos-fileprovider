# macOS ownCloud File Provider Extension - Master Progress & Development Plan

## Project Architecture & Core Objectives

* **Target OS:** macOS 14+ (Sonoma and newer) using the modern `FileProvider` and `FileProviderUI` frameworks.
* **Extension model:** `NSFileProviderReplicatedExtension` (the modern replicated provider). This is mutually exclusive with the legacy `NSFileProviderExtension` — do not mix the two APIs.
* **Backends Supported:** ownCloud Classic (WebDAV / SabreDAV XML) and ownCloud Infinite Scale (oCIS via Graph API / OIDC).
* **Architecture Style:** Test-Driven Development (TDD) loop engineering framework combining OpenCode/Claude Code with strict discipline enforcement.

---

## Phase 1: Project Skeleton & Entitlements Setup

* [ ] **Task 1.1:** Create the **Xcode project** with three targets: the containing app, the File Provider extension (`.appex`), and the FileProviderUI extension (`.appex`). SPM has no product type that emits an `.appex`, so the extensions cannot be SPM targets (build-system behaviour, not something Apple's API reference documents — reconfirm on the Mac). Place backend-agnostic core logic (WebDAV XML parsing, Graph models, credential/session management) in a **local SPM package** consumed by all three targets.
* [ ] **Task 1.2:** Configure `Info.plist` for **each** extension target separately:
  * File Provider extension → `NSExtensionPointIdentifier` = `com.apple.fileprovider-nonui`
  * FileProviderUI extension → `NSExtensionPointIdentifier` = `com.apple.fileprovider-actionsui`
  * Both identifier strings come from Xcode's target templates, **not** from Apple's documentation: the `NSExtensionPointIdentifier` reference page enumerates no permitted values, and neither the FileProvider nor the FileProviderUI articles print them. Confirm them against the `.xctemplate` `Info.plist` inside `Xcode.app` before relying on them — a wrong extension point identifier signs cleanly and then simply never loads.
  * Optional `NSExtension` children, all documented, if the feature is wanted: `NSExtensionFileProviderActions` (context-menu actions), `NSExtensionFileProviderDownloadPipelineDepth` / `NSExtensionFileProviderUploadPipelineDepth` (sync concurrency tuning).
  * `NSExtensionFileProviderSupportsPickingFolders` is **not** in Apple's `NSExtension` key index — do not add it on the strength of this document; verify it exists first.
  * `NSFileProviderDomainUsageDescription` (macOS 10.15+) does exist, but it belongs to apps that *consume* file-provider content: it is the purpose string shown the first time an app reaches files owned by someone else's provider. Neither our extension nor our containing app needs it, unless the app itself reads third-party providers' files.
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
* [ ] **Task 3.2:** Implement root and child item enumeration logic in `enumerateItems(for:startingAt:)`, supporting pagination and sync anchors (`NSFileProviderSyncAnchor`, surfaced through `currentSyncAnchor(completionHandler:)`).
* [ ] **Task 3.3:** Implement change tracking enumeration (`enumerateChanges(for:from:)`, taking an `NSFileProviderChangeObserver` and a `from:` sync anchor) handling server-side additions, modifications, and deletions.

## Phase 4: File Operations & Synchronization (`NSFileProviderReplicatedExtension`)

* [ ] **Task 4.1:** Write failing unit test for file hydration via `fetchContents(for:version:request:completionHandler:)`. Note the replicated contract: the extension downloads to a location **it** chooses and hands that URL back, after which the system takes ownership of the file and moves it into its own replicated store.
* [ ] **Task 4.2:** Implement remote item fetch and content streaming to a temporary URL returned to the system. Do **not** maintain a separate long-lived disk cache — the system already stores hydrated content, so a self-managed cache double-stores every file.
* [ ] **Task 4.3:** Write failing unit test for local file modification detection and upload queuing.
* [ ] **Task 4.4:** Implement the push synchronization handlers of `NSFileProviderReplicatedExtension` — `createItem(basedOn:fields:contents:options:request:completionHandler:)`, `modifyItem(_:baseVersion:changedFields:contents:options:request:completionHandler:)` and `deleteItem(identifier:baseVersion:options:request:completionHandler:)` — routing requests to either WebDAV or oCIS backends.

## Phase 5: UI & Extension Lifecycle Integration

* [ ] **Task 5.1:** Implement `NSFileProviderManager` domain setup, connection, and user sign-in flow initialization. **Prerequisite:** on macOS the extension is only discovered and launched when the containing app resides in `/Applications` (or `~/Applications`), or FileProvider testing mode is enabled. Launched straight from Xcode's DerivedData, `add(domain:)` reports success and Finder silently shows nothing. (Deployment behaviour rather than documented API — reconfirm on the Mac.)
* [ ] **Task 5.2:** Build File Provider UI extension (`FPUIActionExtensionViewController`) for authentication credential inputs and domain removal actions. Scope note: from macOS 11 on, custom actions can be declared directly in the File Provider extension via `NSExtensionFileProviderActions` and run without presenting UI — so the UI extension is only needed for the flows that actually show something, such as sign-in.
* [ ] **Task 5.3:** Run end-to-end integration test suite validating Finder synchronization performance and error recovery states.

---

## References

Every Apple symbol, entitlement and `Info.plist` key named above was checked
against these pages. Re-check them rather than re-deriving the names — Apple
serves the machine-readable form at
`https://developer.apple.com/tutorials/data/documentation/<path>.json`, which is
what to fetch; the HTML pages are a JavaScript shell.

* Framework: [FileProvider](https://developer.apple.com/documentation/fileprovider) · [FileProviderUI](https://developer.apple.com/documentation/fileproviderui)
* Extension models: [Replicated File Provider extension](https://developer.apple.com/documentation/fileprovider/replicated-file-provider-extension) · [Nonreplicated File Provider extension](https://developer.apple.com/documentation/fileprovider/nonreplicated-file-provider-extension)
* Protocols and types: [NSFileProviderReplicatedExtension](https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension) · [NSFileProviderEnumerating](https://developer.apple.com/documentation/fileprovider/nsfileproviderenumerating) · [NSFileProviderEnumerator](https://developer.apple.com/documentation/fileprovider/nsfileproviderenumerator) · [NSFileProviderChangeObserver](https://developer.apple.com/documentation/fileprovider/nsfileproviderchangeobserver) · [NSFileProviderSyncAnchor](https://developer.apple.com/documentation/fileprovider/nsfileprovidersyncanchor) · [NSFileProviderManager](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager)
* Entitlements: [App Sandbox](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.app-sandbox) · [network.client](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client) · [Keychain Access Groups](https://developer.apple.com/documentation/bundleresources/entitlements/keychain-access-groups) · [App Groups](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups) · [fileprovider.testing-mode](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fileprovider.testing-mode)
* `Info.plist`: [NSExtension](https://developer.apple.com/documentation/bundleresources/information-property-list/nsextension) · [NSExtensionPointIdentifier](https://developer.apple.com/documentation/bundleresources/information-property-list/nsextension/nsextensionpointidentifier) · [NSFileProviderDomainUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsfileproviderdomainusagedescription)

Still **not** settled by these docs, and flagged inline above: the two
`NSExtensionPointIdentifier` values, the SPM-cannot-emit-`.appex` constraint, and
the `/Applications` discovery prerequisite. All three need a Mac to confirm.

---

## Log & Execution History

* *2026-08-16*: Initialized `progress.md` tracking layout for macOS File Provider extension TDD loop engineering.
* *2026-08-16*: Corrected Apple API names, extension point identifiers, `Info.plist` keys and sandbox entitlements after review of PR #1.
* *2026-08-16*: Re-verified every Apple claim against `developer.apple.com` (see References). All protocol, selector and entitlement names hold exactly as written. Two claims from the previous pass were wrong and are fixed: `NSFileProviderDomainUsageDescription` does exist (it is a consuming app's key, not ours), and `NSExtensionFileProviderSupportsPickingFolders` is absent from Apple's key index. The two extension point identifiers could not be confirmed from the documentation and are now labelled as Xcode-template values pending a check on the Mac.

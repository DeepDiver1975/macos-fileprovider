# macOS ownCloud File Provider Extension - Master Progress & Development Plan

## Project Architecture & Core Objectives

* **Target OS:** macOS 14+ (Sonoma and newer) using the modern `FileProvider` and `FileProviderUI` frameworks.
* **Extension model:** `NSFileProviderReplicatedExtension` (the modern replicated provider). This is mutually exclusive with the legacy `NSFileProviderExtension` — do not mix the two APIs.
* **Backends Supported:** ownCloud Classic (WebDAV / SabreDAV XML) and ownCloud Infinite Scale (oCIS via Graph API / OIDC).
* **Architecture Style:** Test-Driven Development (TDD) loop engineering framework combining OpenCode/Claude Code with strict discipline enforcement.
* **Definition of done:** no phase counts as complete until its behaviour is demonstrated by acceptance scenarios passing against **both** backends — ownCloud Classic v11 and oCIS, run from Docker fixtures. See [Acceptance Criteria](#acceptance-criteria).

---

**Checkbox legend:** `[ ]` not started · `[~]` partially done — the reviewable,
headless-verifiable artifacts exist and `swift test` is green, but a step that
genuinely requires a Mac (Xcode GUI to emit the `.xcodeproj`, a paid signing
team, or Docker) remains before it can be ticked `[x]`. Each `[~]` task carries
a **Loop status** note saying exactly what is done and what is blocked.

---

## Phase 1: Project Skeleton & Entitlements Setup

* [x] **Task 1.1:** Create the **Xcode project** with three targets: the containing app, the File Provider extension (`.appex`), and the FileProviderUI extension (`.appex`). SPM has no product type that emits an `.appex`, so the extensions cannot be SPM targets (build-system behaviour, not something Apple's API reference documents — reconfirm on the Mac). Place backend-agnostic core logic (WebDAV XML parsing, Graph models, credential/session management) in a **local SPM package** consumed by all three targets.
  * **Done (Mac, Xcode 16.4 / macOS 26):** committed a reviewable [`project.yml`](project.yml) (XcodeGen) that wires all three targets to the committed sources/Info.plists/entitlements and the local `OwnCloudCore` package. `xcodegen generate` + `xcodebuild -scheme App build` → **BUILD SUCCEEDED**, producing `ownCloud File Provider.app` with both `FileProviderExtension.appex` and `FileProviderUIExtension.appex` embedded in `Contents/PlugIns` (validated by `embeddedBinaryValidationUtility`). The generated `.xcodeproj` is git-ignored; the manifest is the source of truth.
* [~] **Task 1.2:** Configure `Info.plist` for **each** extension target separately:
  * File Provider extension → `NSExtensionPointIdentifier` = `com.apple.fileprovider-nonui`
  * FileProviderUI extension → `NSExtensionPointIdentifier` = `com.apple.fileprovider-actionsui`
  * Both identifier strings come from Xcode's target templates, **not** from Apple's documentation: the `NSExtensionPointIdentifier` reference page enumerates no permitted values, and neither the FileProvider nor the FileProviderUI articles print them. Confirm them against the `.xctemplate` `Info.plist` inside `Xcode.app` before relying on them — a wrong extension point identifier signs cleanly and then simply never loads.
  * Optional `NSExtension` children, all documented, if the feature is wanted: `NSExtensionFileProviderActions` (context-menu actions), `NSExtensionFileProviderDownloadPipelineDepth` / `NSExtensionFileProviderUploadPipelineDepth` (sync concurrency tuning).
  * `NSExtensionFileProviderSupportsPickingFolders` is **not** in Apple's `NSExtension` key index — do not add it on the strength of this document; verify it exists first.
  * `NSFileProviderDomainUsageDescription` (macOS 10.15+) does exist, but it belongs to apps that *consume* file-provider content: it is the purpose string shown the first time an app reaches files owned by someone else's provider. Neither our extension nor our containing app needs it, unless the app itself reads third-party providers' files.
  * **Done (Mac):** all three `Info.plist` files carry the correct `NSExtensionPointIdentifier` values, principal-class keys, and no `NSFileProviderDomainUsageDescription`. The two identifier strings — the item flagged "pending a check on the Mac" — are now **confirmed by a real build**: both `.appex` bundles embed and pass `embeddedBinaryValidationUtility`, and the built plists read back `com.apple.fileprovider-nonui` / `com.apple.fileprovider-actionsui`.
* [x] **Task 1.3:** Setup code signing entitlements. The extension is sandboxed, so it needs:
  * `com.apple.security.app-sandbox`
  * `com.apple.security.network.client` — **required**; without it every request in Phase 2 fails immediately
  * `keychain-access-groups` (or `com.apple.security.application-groups`) so the containing app's sign-in flow and the extension can share credentials (needed by Tasks 2.5, 5.1, 5.2) — must be provisioned up front, not retrofitted
  * `com.apple.developer.fileprovider.testing-mode` for the Task 5.3 integration suite and the deterministic path of AC-3 — subject to Task 6.1, since it needs a provisioning profile from a paid Apple Developer team
  * Do **not** add `com.apple.security.files.downloads.read-write` / `files.user-selected.read-write` to the extension — those are host-app file-picker entitlements; a replicated provider writes into the system-provided domain directory.
  * **Done (Mac, 2026-08-17):** three `.entitlements` files written — app, extension, UI extension — each with app-sandbox, network.client, the shared app group and keychain group, the extension carrying `fileprovider.testing-mode`, and none carrying the file-picker entitlements. **Development signing now works** (automatic / Xcode-managed): `xcodebuild -scheme App -allowProvisioningUpdates build` → **BUILD SUCCEEDED**, signing app + both `.appex` with `Apple Development: Thomas Mueller` under team `4AP2STM4H5` (ownCloud GmbH), Mac App Development profiles minted and embedded, and `codesign --verify --deep --strict` passes. The `com.apple.developer.fileprovider.testing-mode` managed entitlement processed cleanly against the generated profile — no separate portal capability toggle was needed. (Setup gotcha recorded: on Apple Silicon the Provisioning UDID to register in the portal Devices list is the short `system_profiler SPHardwareDataType` value, **not** `IOPlatformUUID`.)
* [x] **Task 1.4:** Establish the test harness: `swift test` covers the local SPM core package; the extension targets are covered by XCTest targets inside the Xcode project (`xcodebuild test`).
  * **Done (Mac):** both halves are green — `swift test` over `Core/` (82 tests) and `xcodebuild test -scheme App -destination 'platform=macOS'`, which runs the `OwnCloudCore` suite through the generated project (82 tests, wired via the App scheme's `test:` block in [`project.yml`](project.yml)). Extension-specific XCTest targets are added as the Mac-only adapters (Phases 3–5) gain testable logic. **Sandbox caveat recorded in [`PROJECT.md`](PROJECT.md):** the Xcode module cache lives outside the default command sandbox, so `swift test` runs with the sandbox disabled in this environment.

## Phase 2: Core Protocols & Networking Layer (TDD)

* [x] **Task 2.1:** Write failing unit test for parsing ownCloud Classic WebDAV `PROPFIND` multi-status XML responses into native domain models. *(Done: `WebDAVMultiStatusParserTests` — 7 tests over a Depth:1 SabreDAV multistatus fixture covering collection/file resourcetype, `oc:id`/`oc:size`/`oc:permissions`/`oc:favorite`, RFC-1123 dates, percent-decoded names, malformed-XML error.)*
* [x] **Task 2.2:** Implement robust XML parser (`XMLParser` delegate or lightweight parser) to pass Task 2.1. *(Done: `WebDAVItem` domain model + namespace-aware `WebDAVMultiStatusParser` on Foundation `XMLParser`/`FoundationXML` so it stays Linux-buildable. All green under `swift test`.)*
* [x] **Task 2.3:** Write failing unit test for oCIS Graph API JSON deserialization (drives, item lists, delta sync tokens). *(Done: `GraphModelsTests` — drive list with quota/root, children list with folder/file facets + `parentReference`, ISO-8601 dates, `$token` from `@odata.deltaLink`/`nextLink`, `deleted` facet, malformed-JSON error.)*
* [x] **Task 2.4:** Implement oCIS Graph API client structures to pass Task 2.3. *(Done: `GraphDrive`/`GraphQuota`/`GraphItem`/`GraphItemCollection` domain models + `GraphJSONDecoder` mapping `Codable` wire types to them. Foundation-only.)*
* [~] **Task 2.5:** Implement unified credential and session manager handling basic auth (Classic) and OAuth2/OIDC token refresh (oCIS). *(Done: `Credentials` (basic/bearer), injectable `CredentialStore` protocol, and `SessionManager` — `Authorization` header building, expiry/leeway-based `needsTokenRefresh()`, and persisted `refreshTokenIfNeeded()`. 10 tests green with injected clock + refresh handler.)* *(Done 2026-08-17: the concrete **Keychain-backed `CredentialStore`** — `CredentialCoder` (pure `Credentials`↔JSON payload, 5 tests) in the Linux-buildable core, and `KeychainCredentialStore` in `FileProviderSupport` over an injectable `KeychainBackend` seam with a real `SecItem` implementation (`SecItemKeychainBackend`) and an in-memory fake for tests — 7 tests covering round-trip, addressing by the account's stable id + shared access group, upsert-on-resave, clear, corrupt-blob tolerance. Wired into `FileProviderExtension.authorization(for:)`: it now builds a `KeychainCredentialStore` over the shared access group + a `SessionManager` and returns a real header instead of `nil`.)* *(Done 2026-08-17: the pure OIDC token-refresh pieces — `OIDCTokenRequestBuilder.refresh(refreshToken:clientID:scope:)` shapes the OAuth2 `grant_type=refresh_token` form-encoded POST (values percent-escaped to the unreserved set; `scope` omitted when nil), and `OIDCTokenResponse.credentials(from:now:previousRefreshToken:)` decodes the token JSON into `Credentials.bearer`, turning the relative `expires_in` into an absolute expiry against an injected clock, retaining the previous refresh token when the response omits one, and throwing `OIDCTokenError.malformedResponse` on garbage / a missing `access_token` — 6 tests.)* **Remaining:** the live `SecItem` round-trip runs only on a signed/entitled host (Task 6.0); wiring the pure OIDC pieces into a live `RefreshHandler` needs the async token-endpoint POST + `/.well-known/openid-configuration` discovery of the endpoint (and reconciling the sync `RefreshHandler` signature with async networking), which is Mac/Task 6.0-gated.

## Phase 3: File Provider Domain & Enumeration (`NSFileProviderEnumerating`)

* [x] **Task 3.1:** Write failing unit test for `NSFileProviderEnumerator` container initialization mapping remote container roots to `NSFileProviderItem`. *(Done: `FileProviderItemDescriptionTests` — backend-agnostic `FileProviderItemDescription` value type (identifier, parent, filename, size, version/etag, content type, capabilities) with `ItemIdentifier`/`ItemCapabilities`, plus `WebDAVItem` and `GraphItem` mappers and a `rootContainer` synthesizer. The `NSFileProviderItem` adapter stays a Mac-only wrapper over this type.)*
* [x] **Task 3.2:** Implement root and child item enumeration logic in `enumerateItems(for:startingAt:)`, supporting pagination and sync anchors (`NSFileProviderSyncAnchor`, surfaced through `currentSyncAnchor(completionHandler:)`). *(Done in core: `SyncAnchor` (Data round-trip), `PageCursor`, `EnumerationPage`, and `Paginator` that walks pages until no cursor and captures the final anchor — backend fetch injected. Tested with multi-page and single-page sources.)* *(Mac adapter: `FileProviderSupport.ItemEnumerator` conforms `NSFileProviderEnumerator` over the `Paginator`, vends `FileProviderItem`s, and surfaces the final anchor via `currentSyncAnchor`; `EnumeratorAdapterTests` drive multi-page enumeration, fetch-error surfacing, and anchor plumbing with fake observers.)*
* [x] **Task 3.3:** Implement change tracking enumeration (`enumerateChanges(for:from:)`, taking an `NSFileProviderChangeObserver` and a `from:` sync anchor) handling server-side additions, modifications, and deletions. *(Done in core: `ChangeSet` — `init(from:to:)` diffs two listings by identifier + `versionIdentifier` (WebDAV, no delta API), `init(graphDelta:)` splits an oCIS delta page's live vs. `deleted`-facet items. Additions/modifications/deletions covered.)* *(Mac adapter: `ItemEnumerator.enumerateChanges` maps a `ChangeSet` onto `didUpdate`/`didDeleteItems` and finishes with the new anchor via an injected change provider; covered by `EnumeratorAdapterTests` including error surfacing.)*
* **Acceptance gate:** the enumeration scenario group — items appear in the domain without being downloaded, server-side additions/modifications/deletions are reflected, and a folder large enough to force pagination enumerates completely. *(Gate stays open — requires the Phase 6 acceptance suite on a Mac against both backends.)*

## Phase 4: File Operations & Synchronization (`NSFileProviderReplicatedExtension`)

* [~] **Task 4.1:** Write failing unit test for file hydration via `fetchContents(for:version:request:completionHandler:)`. Note the replicated contract: the extension downloads to a location **it** chooses and hands that URL back, after which the system takes ownership of the file and moves it into its own replicated store. *(Done in core: `RemoteRequestBuilderTests` drive the fetch requests; `ContentDownloaderTests` drive `ContentDownloader` — send the fetch request over a `RemoteClient`, write the body to a fresh unique temp file, return that URL; failure writes nothing.)* *(Mac adapter: `FileProviderExtension.fetchContents` builds the backend fetch request via `BackendConnection`, runs `ContentDownloader.download`, and hands the temp URL back / maps `RemoteError` to an `NSFileProviderError`.)* **Remaining:** exercising the hand-off live needs a signed, installed app + credentials (Keychain store) — the Task 6.0 spike.
* [~] **Task 4.2:** Implement remote item fetch and content streaming to a temporary URL returned to the system. Do **not** maintain a separate long-lived disk cache — the system already stores hydrated content, so a self-managed cache double-stores every file. *(Done: `ContentDownloader` streams to a chosen temp URL with no self-managed cache; wired into `fetchContents` above. `BackendConnection` shapes the per-backend fetch request — Classic path-addressed, oCIS `/items/{id}/content`.)* **Remaining:** the live download + FileProvider hand-off runs only with a signed/installed app and credentials (Task 6.0 / Keychain store).
* [x] **Task 4.3:** Write failing unit test for local file modification detection and upload queuing. *(Done: `UploadQueueTests` — enqueue new/modified (version differs), skip unchanged, dedupe already-pending, FIFO dequeue, re-enqueue after a post-dequeue change.)*
* [~] **Task 4.4:** Implement the push synchronization handlers of `NSFileProviderReplicatedExtension` — `createItem(basedOn:fields:contents:options:request:completionHandler:)`, `modifyItem(_:baseVersion:changedFields:contents:options:request:completionHandler:)` and `deleteItem(identifier:baseVersion:options:request:completionHandler:)` — routing requests to either WebDAV or oCIS backends. *(Done in core: `RemoteRequest` + `WebDAVRequestBuilder` (PUT/MKCOL/DELETE/MOVE, `If-Match` for optimistic concurrency, `Destination`/`Overwrite: F` on move) and `GraphRequestBuilder` (PUT `/content`, DELETE item, POST `/children` folder with `conflictBehavior: fail`), plus `UploadQueue`. These are the routed requests each handler issues.)* *(Done 2026-08-17: `BackendConnection` now exposes the push request shaping per backend — `createFileRequest`/`createDirectoryRequest`/`modifyContentsRequest(path:…)`/`deleteRequest(path:)`/`moveRequest` for Classic (path-addressed) and `modifyContentsRequest(itemID:…)`/`deleteRequest(itemID:)`/`createFolderRequest` for oCIS (ID-addressed), 10 tests. `FileProviderExtension.deleteItem` is wired end-to-end: it issues the backend DELETE over the `RemoteClient` and reports success / a mapped `NSFileProviderError` — no metadata read-back needed for delete. Signed `xcodebuild` BUILD SUCCEEDED.)* *(Done 2026-08-17: **oCIS `createItem` wired end-to-end.** `GraphRequestBuilder` gained root-relative variants (`uploadNewFileUnderRoot`, `createFolderUnderRoot`) and `BackendConnection.createItemRequest(parentID:name:isDirectory:)` makes the two routing decisions in one tested place — root (`root` segment) vs. a specific parent, and folder (POST `/children`) vs. file (PUT `:/name:/content`), 6 tests. `FileProviderExtension.createItem` routes on backend: for oCIS it shapes the request, streams the file body (or the folder JSON), decodes the returned driveItem via `GraphJSONDecoder.decodeItem`, and hands back a reconciled `FileProviderItem`; `RemoteError` → `NSFileProviderError`. Signed `xcodebuild` BUILD SUCCEEDED.)* *(Done 2026-08-17: **Classic `createItem` wired end-to-end.** Since a WebDAV `PUT`/`MKCOL` returns no metadata body, `WebDAVRequestBuilder.properties(path:)` (Depth:0 PROPFIND, same prop body as `enumerate`, 2 tests) and `BackendConnection.readBackRequest(path:)` + `readBackItem(fromPropfind:parentIdentifier:)` (parse the single item via `WebDAVMultiStatusParser`, `nil` on empty multistatus, 3 tests) give the create a metadata read-back. `FileProviderExtension.createItem` now routes per backend into `createItemOCIS` (reconciles from the returned driveItem) / `createItemClassic` (write → Depth:0 read-back → reconcile the server-assigned id + etag; `.serverUnreachable` if the read-back is empty). Signed `xcodebuild` BUILD SUCCEEDED.)* *(Done 2026-08-17: **`modifyItem` content edits wired for both backends.** The core sync operation — a content change — routes on `changedFields.contains(.contents)`: the base version's `contentVersion` token becomes the `If-Match` etag (optimistic concurrency), then `modifyContentsOCIS` reconciles from the returned driveItem and `modifyContentsClassic` PUTs then reuses the Depth:0 read-back for the new etag (`.serverUnreachable` if empty). Request shaping (`modifyContentsRequest(path:/itemID:)`) and the read-back were already tested; the handler is thin Mac-only adapter over them. Signed `xcodebuild` BUILD SUCCEEDED.)* *(Done 2026-08-17: **rename/move via `modifyItem` wired for both backends.** `GraphRequestBuilder.move(driveID:itemID:newName:newParentID:)` (PATCH with `name` + optional `parentReference.id`; `PATCH` added to `HTTPMethod`; 2 tests) gives oCIS the ID-addressed counterpart of Classic's WebDAV `MOVE`, exposed via `BackendConnection.moveRequest(itemID:newName:newParentID:)` (1 test). `modifyItem` now branches: content edits as before, else `.filename`/`.parentItemIdentifier` route to `moveItem` — Graph PATCH reconciling from the returned driveItem for oCIS, WebDAV MOVE + Depth:0 read-back for Classic, sending the reparent target only when the parent actually changed. Signed `xcodebuild` BUILD SUCCEEDED.)* *(Done 2026-08-17: **combined content-edit + rename in one `modifyItem` call.** Previously such a call applied only the content edit and silently dropped the rename; now the handler applies content-first-then-rename — the content PUT targets the item's current address (keeping the Classic path valid), then the move relocates it, and the move's reconciled item (the final server state) is returned. Neither backend offers a truly atomic combined op, so this is the correct sequential decomposition. Signed `xcodebuild` BUILD SUCCEEDED.)* **Remaining:** the conflict mechanism (a Phase 4 open question) and live exercise are Mac/Task 6.0-gated. Note: Classic operations address items by path (the identifier is treated as a server-relative path), while enumeration maps the identifier to `oc:id` — reconciling that is part of the Task 6.0 live spike.
* **Acceptance gate:** the content scenario group — hydration on read, upload of locally created files, rename/move, delete, the conflict scenario, and the large-file and many-files throughput scenarios. *(Gate stays open — requires the Phase 6 acceptance suite on a Mac against both backends.)*

## Phase 5: UI & Extension Lifecycle Integration

* [~] **Task 5.1:** Implement `NSFileProviderManager` domain setup, connection, and user sign-in flow initialization. **Prerequisite:** on macOS the extension is only discovered and launched when the containing app resides in `/Applications` (or `~/Applications`), or FileProvider testing mode is enabled. Launched straight from Xcode's DerivedData, `add(domain:)` reports success and Finder silently shows nothing. (Deployment behaviour rather than documented API — reconfirm on the Mac.) *(Done in core: `AccountSetupTests` drive `BackendDetector` (oCIS via OIDC discovery, Classic via a parseable installed `status.php`, OIDC wins ties), `AccountDescriptor` (stable `domainIdentifier`, `user@host` display name), and `DomainRemovalChoice` (default preserves downloads).)* **Blocked:** the `NSFileProviderManager.add(_:)` call, `NSFileProviderDomain` construction, and the `/Applications` discovery prerequisite are the Mac-only adapter. **Superseded in part by Phase 7:** the user-facing half of this task (who calls `add`/`remove`, and with what identity) is designed in Tasks 7.1–7.5 — the domain identifier changes from `AccountDescriptor.domainIdentifier` to `SyncRoot.domainIdentifier` there, so do Task 7.1 before extending this one.
* [~] **Task 5.2:** Build File Provider UI extension (`FPUIActionExtensionViewController`) for authentication credential inputs and domain removal actions. Scope note: from macOS 11 on, custom actions can be declared directly in the File Provider extension via `NSExtensionFileProviderActions` and run without presenting UI — so the UI extension is only needed for the flows that actually show something, such as sign-in. *(Done: `ActionViewController` scaffold with `prepare(forError:)`/`prepare(forAction:…)` stubs referenced by the UI extension Info.plist.)* **Blocked:** the actual credential-entry UI and its `FPUIActionExtensionViewController` behaviour need Xcode/AppKit on a Mac. **Scope narrowed by Phase 7:** Task 7.9 keeps this extension a *launcher* — `prepare(forError:)` opens the containing app at the right account rather than reimplementing sign-in (least of all OIDC) inside a sandboxed appex. The credential UI itself lives in Task 7.8.
* [ ] **Task 5.3:** Run end-to-end integration test suite validating Finder synchronization performance and error recovery states. This is the Phase 6 acceptance suite, not a second one. *(Deferred: this **is** the Phase 6 suite — see Tasks 6.0–6.6. It is Mac + Docker + signing gated and cannot run in the headless loop.)*
* **Acceptance gate:** the lifecycle scenario group — domain add and removal (including the `NSFileProviderManager.DomainRemovalMode` choice of what happens to local files), sign-in and re-authentication after credential expiry, and behaviour while the domain is disconnected (`NSFileProviderDomain.isDisconnected`). *(Gate stays open — requires the Phase 6 acceptance suite on a Mac against both backends.)*

---

## Acceptance Criteria

The unit tiers of Task 1.4 prove the code in isolation. These criteria define when the
extension is accepted as *working* — exercised as a real File Provider against real
servers. The scenarios themselves are authored during the loop-engineering process
(Phase 6), seeded from the desktop client's suites (see the
[appendix](#appendix-seed-scenarios-from-the-desktop-client-suites)).

* **AC-1 — Both backends, every scenario.** Each scenario runs against **ownCloud
  Classic v11** (`owncloud/server:11.0.0`, `amd64`/`arm64v8`, with MariaDB and Redis via
  Docker Compose as in the official Docker install docs) and **oCIS** (a pinned release,
  e.g. `owncloud/ocis:8.2.0`). Fixture data is provisioned through each backend's own
  admin API — the OCS provisioning API for Classic, the Graph API for oCIS — never by
  reaching into a container's storage. Where behaviour legitimately differs, the
  difference is expressed as a scenario tag (`@classicOnly` / `@ocisOnly`) with a reason,
  never as a silent skip.
* **AC-2 — The suite runs in GitHub Actions.** Three tiers, because GitHub-hosted macOS
  runners have **no container runtime** — no Docker, Colima, Lima or Podman in the
  `actions/runner-images` macOS images, and no nested virtualisation on Apple silicon:
  * *Unit* — `swift test` (core SPM package) and `xcodebuild test`; hosted macOS runner;
    every PR. Already defined in Task 1.4.
  * *Backend contract* — the core package's WebDAV and Graph clients driven against
    **both** backends in Docker on `ubuntu-latest`, brought up with Docker Compose in a
    step (not `services:`, so Classic gets `depends_on` and health checks); every PR.
    This is what keeps Classic v11 exercised in CI. It constrains the core package: the
    backend layer stays Linux-buildable — Foundation plus `FoundationNetworking`, no
    Apple-only API below the File Provider boundary.
  * *File Provider end-to-end* — the full domain/Finder behaviour on a hosted macOS
    runner, with oCIS started from its official `darwin-arm64` release binary at the same
    version as the pinned image; nightly `schedule:` plus a `full-ci` PR label.
  * **Known gap:** Classic v11 has no end-to-end tier in CI, because it ships only as a
    container and hosted macOS runners cannot run one. Classic end-to-end runs locally on
    a developer Mac (AC-4) until a Docker-capable macOS runner is available; at that
    point this tier covers both backends and the gap closes.
* **AC-3 — Deterministic, no sleeps.** Two mechanisms, selected by a harness capability
  flag (Task 6.1):
  * *Preferred* — the documented sync controls: set `NSFileProviderDomain.testingModes`
    to `.alwaysEnabled` before `add(_:)` (it cannot be changed afterwards), then drive
    and observe with `listAvailableTestingOperations()`, `run(_:)`,
    `waitForStabilization(completionHandler:)` and `waitForChanges(below:completionHandler:)`.
    This needs the `com.apple.developer.fileprovider.testing-mode` entitlement from
    Task 1.3, which in turn needs a provisioning profile from a paid Apple Developer
    team — so it is unavailable to contributors without one.
  * *Fallback* — bounded polling with documented per-assertion timeouts, modelled on the
    client suite's `MAX_SYNC_TIMEOUT` / `MIN_SYNC_TIMEOUT` configuration.
  A scenario is only accepted once it has run green ten consecutive times.
* **AC-4 — Reproducible locally, identically.** A single entry point —
  `make backend-contract BACKEND=classic|ocis` — brings up the Docker fixtures, waits for
  health, runs exactly the tests CI runs (`swift test --filter BackendContract` with the
  same `OWNCLOUD_TEST_BACKEND`), and tears down. No CI-only wiring. *(Done for the
  backend-contract tier via [`Makefile`](Makefile); the `make acceptance` end-to-end target
  is added with the Task 6.0 spike.)*
* **AC-5 — Traceable.** Every scenario has a stable ID and maps to the phase gate it
  satisfies (Phase 3 enumeration, Phase 4 content, Phase 5 lifecycle). A phase's
  checkbox is not ticked while any of its scenarios fails on either backend.
* **AC-6 — Diagnosable on failure.** Failing jobs upload: backend server logs, a system
  log excerpt scoped to the provider (`log collect`), the domain's file tree annotated
  with each item's materialisation state, and the failing scenario's step trace.
* **AC-7 — Pinned.** Backend images are pinned to explicit versions, and the oCIS binary
  used on macOS is pinned to the same version as the oCIS image, so a backend upgrade is
  a reviewable commit rather than a silent change under the suite.

## Phase 6: Acceptance Test Suite & CI

* [ ] **Task 6.0 (spike, do first):** prove on a GitHub-hosted macOS runner that a
  trivial File Provider domain can be added and enumerated at all — the containing app
  copied to `/Applications` (Task 5.1's prerequisite), a signing identity the runner
  accepts, and the extension actually loading in the runner's session. None of this is
  documented by Apple; it is make-or-break for AC-2's end-to-end tier. If it fails, that
  tier moves to a self-hosted Mac and AC-2 is rewritten accordingly.
  * **Loop status — fully blocked (no headless artifact):** this is by definition an
    experiment on a live GitHub-hosted macOS runner (domain add + enumerate, app in
    `/Applications`, a signing identity the runner accepts). It cannot be reduced to a unit
    test. The end-to-end job in `.github/workflows/ci.yml` carries a placeholder step that
    is replaced with the spike's real body once it is run on a Mac.
  * **Local spike scaffolding done (2026-08-17):** the repeatable local path is now in
    place. A DEBUG-only dev harness (`App/Sources/DevHarness.swift`, wired into
    `ContentView`) stands in for the not-yet-built sign-in (5.2) and live domain add (5.1):
    **Sign in** performs the initial shared-Keychain write via `KeychainCredentialStore`,
    **Add domain** calls `NSFileProviderManager.add`, **Remove domain**/**Sign out** reset
    it — defaulting to the Classic fixture (`admin`/`admin` at `http://localhost:8080`,
    path-addressed so no drive-id resolution). A `make install` target builds+signs Debug and
    installs to `~/Applications` (an FP discovery location needing no elevation).
    **Verified scriptable parts:** `make install` → `codesign --verify --deep --strict`
    exits 0, both `.appex` embedded under `Contents/PlugIns`, testing-mode entitlement
    survives signing; Classic fixture up; the WebDAV path the enumerator drives is live
    (PROPFIND → 207, a seeded `harness-test.txt` is listed); 204 unit tests green. **Still
    manual (GUI, unscriptable):** the Sign in → Add domain click-through and confirming
    `admin@localhost` mounts + enumerates in Finder — the app is installed and launched for
    that. CI hosted-runner secrets remain the separate open item.
* [x] **Task 6.1:** settle the AC-3 mechanism: determine whether Apple Developer signing
  credentials (certificate, provisioning profile carrying
  `com.apple.developer.fileprovider.testing-mode`, team ID) can be provided as CI
  secrets. Record the decision here; implement the other mechanism as the documented
  fallback either way.
  * **Decision (2026-08-16): no Apple signing for now — SUPERSEDED 2026-08-17.** The
    interim decision was to skip signing and use the bounded-polling fallback. That is now
    reversed.
  * **Decision (2026-08-17): Apple development signing is set up.** Automatic (Xcode-managed)
    signing works against team `4AP2STM4H5` (ownCloud GmbH) with an `Apple Development`
    identity; the extension's `com.apple.developer.fileprovider.testing-mode` entitlement
    validates against the generated Mac App Development profile (Task 1.3). This unblocks the
    **deterministic AC-3 path** (`testingModes = .alwaysEnabled`, `run(_:)`,
    `waitForStabilization`) locally on a signed, `/Applications`-installed app; the
    bounded-polling fallback stays specified for contributors/CI without team credentials.
    The live-integration steps (byte-streaming glue in Tasks 4.1/4.2/4.4, live `add` in 5.1,
    end-to-end 5.3, runner spike 6.0) are now unblocked **on this developer Mac** (AC-4); CI
    secrets for hosted runners remain a separate open item. `xcodebuild build`/`test` no
    longer need `CODE_SIGNING_ALLOWED=NO`.
* [~] **Task 6.2:** backend fixtures — `test/fixtures/classic/docker-compose.yml`
  (`owncloud/server:11.0.0` + MariaDB + Redis) and `test/fixtures/ocis/docker-compose.yml`,
  plus the CI script that starts the same oCIS version from the `darwin-arm64` release
  binary with equivalent configuration. Includes trusting the fixture's self-signed
  certificate on the test machine (`security add-trusted-cert`, or an explicit pin in the
  test client) — a sandboxed extension will not accept it otherwise.
  * **Loop status:** all fixtures authored and now **brought up live** (Docker on the Mac).
    `test/fixtures/classic/docker-compose.yml` (owncloud/server:11.0.0 + mariadb:10.11 +
    redis:7, health checks + `depends_on`) reaches 207 on PROPFIND; `test/fixtures/ocis/docker-compose.yml`
    (owncloud/ocis:8.2.0, demo users off, `PROXY_ENABLE_BASIC_AUTH` added so the contract
    tier authenticates uniformly) serves real Graph drive JSON. `versions.env` is the single
    pinned-version source (AC-7); `start-ocis-macos.sh` downloads the same version as a
    `darwin-arm64` binary for the runner. The self-signed cert is handled in-client
    (a test-only `URLSessionDelegate` trusting the fixture trust) rather than
    `security add-trusted-cert`. **Remaining for `[x]`:** the end-to-end tier's cert trust
    for the *sandboxed extension* (a real domain talking to the fixture) still needs the
    Task 6.0 spike; the contract tier is proven.
* [~] **Task 6.3:** the `AcceptanceSupport` harness: a `BackendAdmin` protocol with OCS
  and Graph implementations (create user, upload content, assert remote state), a domain
  lifecycle helper (`add(_:)`, `removeAllDomains(completionHandler:)`,
  `getUserVisibleURL(for:completionHandler:)`, `signalEnumerator(for:completionHandler:)`,
  `reimportItems(below:completionHandler:)`), and a materialisation-state observer. This
  plays the role the client suite's `test/gui/shared/steps` does. **Open question for
  this task:** how a test process outside the extension reads whether an item is
  materialised — determine this on the Mac rather than assuming a resource key.
  * **Loop status:** the `BackendAdmin` provisioning half is done test-first (6 tests
    green): `OCSProvisioningRequestBuilder` (Classic OCS API — `POST /ocs/v1.php/cloud/users`
    form-encoded, `OCS-APIRequest: true`, user delete) and `GraphProvisioningRequestBuilder`
    (oCIS Graph — `POST /graph/v1.0/users` JSON, user delete). This provisions fixtures
    through each backend's own admin API (AC-1), reusing the Phase 4 `RemoteRequest` value
    type. **Blocked:** the domain lifecycle helper wraps `NSFileProviderManager` (Mac-only),
    and the materialisation-state observer is the task's open question — both need a Mac.
    Content upload for fixtures reuses the Phase 4 WebDAV/Graph builders already in place.
* [~] **Task 6.4:** the Gherkin layer — `.feature` files kept close to the client's
  wording so they stay diff-comparable, a small Gherkin parser/runner in the test target,
  and the step library mapping steps onto Task 6.3's harness. Port the first scenarios
  from the appendix.
  * **Loop status:** the parser is done and fully tested headlessly — `GherkinParser`
    (feature/background/scenario/scenario-outline, tags, `And`/`But` continuation, examples
    table + `expanded()`), 8 tests green. First scenarios ported to
    `test/features/enumeration.feature` (4 enumeration scenarios seeded from `tst_syncing`),
    verified to parse. **Blocked:** the *runner* and *step library* map steps onto the
    Task 6.3 `AcceptanceSupport` harness, which is Mac + Docker + signing gated; only the
    pure text-processing half is exercisable here.
* [~] **Task 6.5:** the GitHub workflows for AC-2's three tiers, with the AC-6 artifact
  upload, third-party actions pinned to full commit SHAs, and the nightly schedule.
  * **Loop status:** `.github/workflows/ci.yml` written with all three tiers — *unit*
    (`swift test` on `macos-15`, every PR), *backend contract* (both backends via Docker
    Compose `--wait` on `ubuntu-latest`, matrix, every PR, uploads server logs on failure
    per AC-6), and *end-to-end* (oCIS from the `darwin-arm64` binary on `macos-15`, nightly
    `schedule:` + `full-ci` label). Third-party actions pinned to full commit SHAs (AC-2).
    **Blocked:** the `xcodebuild test` step (needs the `.xcodeproj`, Task 1.1), the
    `--filter BackendContract` suite (needs the live-backend contract tests, Task 6.3), and
    the end-to-end harness body (Task 6.0 spike) are stubbed/commented pending the Mac.
* [~] **Task 6.6:** flake policy — a `@quarantine` tag, the ten-green rule of AC-3, and a
  nightly re-run of quarantined scenarios so they cannot be forgotten.
  * **Loop status:** the tag-selection logic is done test-first (`ScenarioSelection` — 4
    tests green): `mainSuite(_:)` excludes `@quarantine`, `quarantined(_:)` takes only them
    (the nightly re-run), and `forBackend(_:_:)` applies the AC-1 `@classicOnly`/`@ocisOnly`
    tags. **Blocked:** wiring the quarantine re-run into the nightly workflow and enforcing
    the ten-green rule both need the scenarios actually running (Mac + Docker), so they land
    with Task 6.3's harness.

---

## Phase 7: User-Facing Configuration

The integration works but cannot be configured. Design spec (not committed —
`docs/superpowers/` is git-ignored per repo hygiene rules):
`docs/superpowers/specs/2026-08-17-fileprovider-configuration-design.md`. Read it
before starting; the decisions below are load-bearing and are argued there.

**Scope:** accounts plus sync selection — add/remove account, sign in, sign out with
the `DomainRemovalChoice`, re-authenticate, and choose which oCIS spaces appear in
Finder. Deliberately **out**: known-folder (Desktop/Documents) claim, MDM/managed
preferences, menu bar item, custom per-item Finder actions, Classic folder selection,
bandwidth/ignore-list/log-level settings. Each is a decision with a reason in the spec,
not an omission.

**Two framing decisions that shape every task below:**

1. **There is no System Settings pane to build.** macOS 13+ has no public API for a
   third party to add one; iCloud's entry is first-party UI. What macOS does give is a
   per-domain on/off toggle — `NSFileProviderDomain.userEnabled` documents it as *"if
   the user disables the domain in the System Preferences"* — which we **observe and
   surface**, never fight. Configuration lives in the containing app, which macOS
   already forces into `/Applications` for the extension to be discovered at all
   (Task 5.1). A legacy `/Library/PreferencePanes` bundle is rejected in the spec with
   reasons; do not reopen it without reading them.
2. **One `NSFileProviderDomain` per oCIS space** (a Classic account is one domain over
   its files root). Selecting a space adds its domain; deselecting removes it. This is
   what `BackendConnection.swift:19` already assumes — *"the oCIS drive the domain maps
   to, resolved at sign-in"* — and it makes the selection a lifecycle operation over an
   API the system already persists, not a setting we store and must keep in sync.

* [ ] **Task 7.0 (verify first, cheap, do before writing code):** resolve the five
  unverified assumptions in the spec's §9, because each one silently changes an
  implementation detail. (a) Do extension instances for multiple domains share a
  process? — determines whether Task 7.6's lock is required or merely harmless (build it
  either way). (b) Does Finder show `NSExtensionFileProviderActions` when
  right-clicking a *domain row in the sidebar*? — the optional "Settings…" affordance;
  note Apple's key page lists iOS/iPadOS/visionOS only, yet Nextcloud ships these on
  macOS. (c) The System Settings deep-link URL/anchor for the File Providers list.
  (d) The real behaviour of `NSExtensionFileProviderAllowsUserControlledEviction` (an
  undocumented key, read from Nextcloud's shipping `FileProviderExt/Info.plist`).
  (e) How the Finder sidebar copes with ~12 domains, and the per-domain resource cost.
  Record each answer here as a finding, the way Task 1.2's identifier check was recorded.
* [ ] **Task 7.1:** the identity split — headless, and it fixes a live bug.
  `AccountDescriptor.domainIdentifier` currently doubles as the domain identifier
  (`DomainAdapter.swift:12`) *and* the Keychain item key
  (`KeychainCredentialStore.swift:47`); with N domains per account those must diverge, or
  every space gets its own credential item and its own refresh token. Rename the property
  to `accountIdentifier` (same `backend|serverURL|username` encoding, same `maxSplits: 2`
  round-trip, no Keychain migration) and add `SyncRoot` (account + optional `driveID`)
  owning `domainIdentifier` as `"<driveID>|<accountIdentifier>"` — drive first so the
  username stays the verbatim tail and the existing parser handles it. Replace
  `NSFileProviderDomain(account:)` with `NSFileProviderDomain(syncRoot:displayName:)`, and
  add `DomainDisplayNamer` for the two-accounts-both-with-a-"Personal"-space collision.
  * *Test first:* `SyncRoot` round-trip for oCIS and Classic (empty head), rejection of a
    `driveID` containing `|`, rejection of an unparseable tail; a regression test that a
    username containing `|` still survives the rename; `DomainDisplayNamer` with no
    collision, a cross-account collision, and a within-account collision.
  * **Then fix the bug:** `FileProviderExtension.swift:34` hardcodes `driveID: nil`, so
    every oCIS Graph request currently builds `drives//…`. Parse a `SyncRoot` in
    `init(domain:)` and pass its `driveID` into `BackendConnection`. This is a
    prerequisite for oCIS enumeration working at all, so the Phase 3 gate depends on it
    too — not just Phase 7.
* [ ] **Task 7.2:** the space catalog. Add `GraphRequestBuilder.listDrives()` for
  `GET /graph/v1.0/me/drives` — the endpoint `BackendContractTests.swift:54` currently
  hits with a hand-built URL, so there is no builder for it yet — and a `SpaceCatalog` /
  `Space` value type (drive id, name, `driveType`, quota) mapped from the existing
  `GraphJSONDecoder.decodeDriveList`. Classic's catalog is the single files root.
  * *Test first (unit):* decode a real drive-list fixture covering personal, project and
    shared types plus quota. *Then (backend-contract tier, both backends):* fetch the
    catalog from live oCIS with spaces provisioned through the Graph API per AC-1, and
    assert a space the token cannot see never appears.
* [ ] **Task 7.3:** persistence — headless, over an injectable store seam like
  `KeychainBackend`. An `AccountRegistry`: one `UserDefaults` key in
  `group.com.owncloud.macos.fileprovider` holding JSON-encoded `[AccountRecord]`
  (accountIdentifier, backend, serverURL, username). Credentials stay in the Keychain
  untouched. Plus a display-only space-catalog cache (JSON in the app group container) so
  the settings window renders instantly and offline. The registry exists for exactly one
  reason: an account with **zero** spaces selected has no domains and would otherwise
  vanish. The cache is never authoritative.
  * *Test first:* Codable round-trip, corrupt-blob tolerance (the posture
    `KeychainCredentialStoreTests` already sets), and empty/absent-key defaults.
* [ ] **Task 7.4:** `DomainReconciler.plan(registry:existing:intent:)` →
  `(add, remove, orphans)` — a pure function, the pattern `BackendDetector` and
  `Paginator` already establish. **The system's domain list is the source of truth for
  the selection**; `getDomainsWithCompletionHandler` already persists across launches and
  propagates to the extension, so there is no parallel "selected spaces" list to keep in
  sync. (Nextcloud ships `resetVfsForAccount` precisely because their state can drift.)
  Orphans are domains whose account is absent from the registry — a leftover install, or
  an account removed while the app was closed.
  * *Test first:* add, remove, no-op, orphan, zero-space account, account-removed-while-closed.
* [ ] **Task 7.5:** the Mac-only `DomainService` adapter over `NSFileProviderManager`:
  `getDomainsWithCompletionHandler` → `[SyncRoot]`, `add(_:)`, `remove(_:mode:)` driven by
  `DomainRemovalChoice.removalMode`, and orphan removal **only on confirmation, never
  silently**. Enforce single-instance for the app so two copies cannot reconcile
  concurrently (Nextcloud ships `singleinstancemanager_mac` for the same reason). Ordering
  matters and is specified so any crash leaves recoverable state — the registry brackets
  the domain lifetime: on add, write the account record *before* adding domains (a
  zero-space account is legal); on removal, remove domains → delete credentials → delete
  the record *last* (an orphan domain is detectable; a missing credential just reads as
  "signed out").
* [ ] **Task 7.6:** credential-refresh arbitration — **this is a real bug created by the
  per-space domain model, not a theoretical one.** N extension instances each hold a
  `SessionManager` over the same Keychain item; oCIS/Keycloak rotate refresh tokens by
  default, so the first instance to refresh invalidates the token the other N−1 hold and
  every space but one is signed out. Fix with cross-process double-checked locking: take
  an exclusive `flock` on a file in the app group container, re-read the Keychain item,
  refresh only if it is *still* expired, and let losers pick up the winner's token. Plus a
  retry: on any refresh failure, re-read the Keychain once before surfacing
  `.notAuthenticated`. Basic-auth Classic is unaffected.
  * *Test first:* the re-read-then-decide path over a fake lock, using `SessionManager`'s
    existing injected clock. The lock itself is a thin Mac-only adapter behind a seam.
  * *Depends on* the oCIS OIDC token-endpoint `RefreshHandler` still outstanding in Task 2.5.
* [ ] **Task 7.7:** a space that disappears server-side. The extension maps a
  root-enumeration 404 onto `NSFileProviderManager.disconnect(reason:options:)` with a
  human string Finder surfaces, instead of failing every operation. It must **not** remove
  the domain — that would discard or orphan materialised files without consent. The app's
  catalog refresh flags the row; removal stays a user action. `reconnect` when the space
  returns.
* [ ] **Task 7.8:** the settings window — the app's *main* window, not a separate
  `Settings` scene, since configuration is the app's only job. One `NavigationSplitView`:
  an accounts sidebar plus Account / Spaces / Advanced tabs (layout sketched in the spec's
  §7). The Spaces tab is the checklist; for Classic it shows one non-editable "All files"
  row **plus a line saying selection is an oCIS capability** — the difference is stated,
  not hidden, matching AC-1's `@ocisOnly`-with-a-reason convention. Deselect prompts with
  the `DomainRemovalChoice` worded concretely ("Keep the 840 MB already downloaded" /
  "Remove them"). Advanced carries reset-domain (remove + re-add clean), diagnostics via
  `requestDiagnosticCollection(for:errorReason:)`, and version info. **Surface
  `userEnabled`:** if someone flips the System Settings toggle, say so and link to the
  pane — otherwise it reads as our bug. Sign-in lives here: Classic via `BackendDetector`
  + username/password or app password, oCIS via OIDC through `ASWebAuthenticationSession`.
  * **Mac-gated** (AppKit/SwiftUI). Keep every decision it renders in the core types from
    Tasks 7.1–7.4 so the view layer stays thin and the logic stays headlessly tested.
* [ ] **Task 7.9:** the UI extension stays a **launcher**, not a settings host.
  `prepare(forError:)` shows a minimal "Reconnect" sheet that opens the app at that
  account's sign-in — no second OIDC implementation inside a sandboxed appex. Separately,
  set `NSExtensionFileProviderAllowsUserControlledEviction` in the File Provider
  extension's `Info.plist`: one key buys Finder-native "Remove Download" with no code
  (pending Task 7.0(d)).
* [ ] **Task 7.10:** the acceptance scenarios for this phase, joining the Phase 5
  lifecycle group per AC-5 under AC-3's ten-consecutive-green rule: select a space →
  domain appears and enumerates; deselect preserving downloads → files remain on disk,
  domain gone; deselect with `removeAll` → files gone; sign out with two spaces selected →
  both domains removed and the credential deleted; orphan detection after a registry wipe;
  and **the refresh race** — two spaces selected, token forced to expire, both stay
  authenticated. Task 7.6 does not count as done until that last scenario exists and runs.
* **Acceptance gate:** the configuration scenario group above, green on both backends
  (Classic exercising the account/sign-out half, oCIS the space-selection half per AC-1's
  tagging), plus the Phase 5 lifecycle gate it extends.

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
* Configuration surfaces (Phase 7): [userEnabled](https://developer.apple.com/documentation/fileprovider/nsfileproviderdomain/userenabled) — documents the System Settings toggle we observe rather than build · [isHidden](https://developer.apple.com/documentation/fileprovider/nsfileproviderdomain/ishidden) · [getDomainsWithCompletionHandler](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/getdomains(completionhandler:)) · [add(\_:completionHandler:)](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/add(_:completionhandler:)) · [remove(\_:mode:completionHandler:)](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/remove(_:mode:completionhandler:)) · [disconnect(reason:options:completionHandler:)](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/disconnect(reason:options:completionhandler:)) · [reconnect(completionHandler:)](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/reconnect(completionhandler:)) · [evictItem(identifier:completionHandler:)](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/evictitem(identifier:completionhandler:)) · [requestDiagnosticCollection(for:errorReason:completionHandler:)](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/requestdiagnosticcollection(for:errorreason:completionhandler:)) · [claimKnownFolders(\_:localizedReason:completionHandler:)](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/claimknownfolders(_:localizedreason:completionhandler:)) (per-domain — the reason known folders are out of v1) · [FPUIActionExtensionViewController](https://developer.apple.com/documentation/fileproviderui/fpuiactionextensionviewcontroller) · [NSFileProviderError.notAuthenticated](https://developer.apple.com/documentation/fileprovider/nsfileprovidererror-swift.struct/code/notauthenticated) · [NSExtensionFileProviderActions](https://developer.apple.com/documentation/bundleresources/information-property-list/nsextension/nsextensionfileprovideractions) (documented for iOS/iPadOS/visionOS only — Task 7.0(b)) · [ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession) (oCIS sign-in) · [PreferencePanes](https://developer.apple.com/documentation/preferencepanes) (the rejected alternative — evaluated, not overlooked)
* Prior art for Phase 7, read verbatim rather than recalled: [nextcloud/desktop `fileprovidersettingscontroller.h`](https://github.com/nextcloud/desktop/blob/master/src/gui/macOS/fileprovidersettingscontroller.h) (app-level settings, `vfsEnabledForAccount`, `resetVfsForAccount`, `performStartupReconciliation` — the drift their design has to repair and ours avoids by treating the domain list as the source of truth) · [their `FileProviderExt/Info.plist`](https://github.com/nextcloud/desktop/blob/master/shell_integration/MacOSX/NextcloudIntegration/FileProviderExt/Info.plist) (seven `NSExtensionFileProviderActions` with SUBQUERY activation rules on macOS, `NSFileProviderDecorations`, and the undocumented `NSExtensionFileProviderAllowsUserControlledEviction` / `NSExtensionFileProviderAllowsContextualMenuDownloadEntry` keys)
* Sync controls used by the acceptance suite: [testingModes](https://developer.apple.com/documentation/fileprovider/nsfileproviderdomain/testingmodes-swift.property) · [NSFileProviderDomain.TestingModes](https://developer.apple.com/documentation/fileprovider/nsfileproviderdomain/testingmodes-swift.struct) (`.alwaysEnabled`, `.interactive`) · [listAvailableTestingOperations()](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/listavailabletestingoperations()) · [run(\_:)](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/run(_:)) · [NSFileProviderTestingOperation](https://developer.apple.com/documentation/fileprovider/nsfileprovidertestingoperation) · [waitForStabilization(completionHandler:)](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/waitforstabilization(completionhandler:)) · [waitForChanges(below:completionHandler:)](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/waitforchanges(below:completionhandler:)) · [reimportItems(below:completionHandler:)](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/reimportitems(below:completionhandler:)) · [getUserVisibleURL(for:completionHandler:)](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/getuservisibleurl(for:completionhandler:)) · [removeAllDomains(completionHandler:)](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/removealldomains(completionhandler:)) · [DomainRemovalMode](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/domainremovalmode) · [isDisconnected](https://developer.apple.com/documentation/fileprovider/nsfileproviderdomain/isdisconnected)

Backend fixtures and prior art for the acceptance suite:

* Backends: [owncloud-docker/server](https://github.com/owncloud-docker/server) (`owncloud/server:11.0.0`, `amd64`/`arm64v8`) · [owncloud/core releases](https://github.com/owncloud/core/releases) (v11.0.0, 2026-07-30) · [owncloud/ocis releases](https://github.com/owncloud/ocis/releases) (ships `ocis-<version>-darwin-arm64` binaries alongside the Linux ones)
* Desktop client suites used as the seed: [tst_syncing](https://github.com/owncloud/client/tree/master/test/gui/tst_syncing) · [tst_vfs](https://github.com/owncloud/client/tree/master/test/gui/tst_vfs) · [step library](https://github.com/owncloud/client/tree/master/test/gui/shared) · [gui-tests.yml](https://github.com/owncloud/client/blob/master/.github/workflows/gui-tests.yml) (runs on `ubuntu-latest` with oCIS as a service container)
* Runner capabilities: [actions/runner-images macOS readmes](https://github.com/actions/runner-images/tree/main/images/macos) — the evidence for AC-2: the `macos-15`, `macos-15-arm64` and `macos-26-arm64` software lists contain no Docker, Colima, Lima or Podman.

Still **not** settled by these docs, and flagged inline above: the two
`NSExtensionPointIdentifier` values, the SPM-cannot-emit-`.appex` constraint, the
`/Applications` discovery prerequisite, whether a domain can be added and enumerated on a
GitHub-hosted macOS runner at all (Task 6.0), how a test process observes an item's
materialisation state (Task 6.3), the on-disk location of a replicated domain
(`~/Library/CloudStorage/…` in practice, not documented), the conflict mechanism a
replicated provider is expected to produce (Phase 4), and Phase 7's five open questions
(Task 7.0: process-per-domain, Finder actions on a sidebar domain row, the System Settings
deep-link anchor, `NSExtensionFileProviderAllowsUserControlledEviction`, and sidebar
behaviour with ~12 domains). All need a Mac to confirm.

Also searched for and **not found**: any public API for a third-party app to add a pane or
row to System Settings on macOS 13+. The iCloud entry is first-party UI. Treat any future
design that assumes otherwise as blocked on evidence, not on effort.

---

## Appendix: seed scenarios from the desktop client suites

The starting point for Phase 6, one row per scenario in the client's
[tst_syncing](https://github.com/owncloud/client/tree/master/test/gui/tst_syncing) and
[tst_vfs](https://github.com/owncloud/client/tree/master/test/gui/tst_vfs) suites.
*port* = same behaviour, rewritten against the domain; *adapt* = the intent survives but
the mechanism differs; *n/a* = tests desktop-client UI that has no counterpart here.
Anything marked *n/a* is dropped deliberately, not overlooked.

### `tst_syncing`

| Client scenario | Disposition | Note |
|---|---|---|
| Syncing a file to the server | port | Assert via the backend API instead of the activity tab. |
| Syncing all files and folders from the server | port | Items must appear **unmaterialised** — no download on enumeration. |
| Syncing a file from the server and creating a conflict | adapt | Word it behaviourally: no edit is lost, the losing edit stays reachable. The client's conflict-file naming is its own; the replicated-provider mechanism is a Phase 4 question. |
| Syncing a folder to the server (long name, special chars) | port | |
| Many subfolders can be synced | port | |
| Both original and copied folders can be synced | port | |
| Verify that you can create a subfolder with long name | port | |
| Sync long nested folder | port | |
| Verify pre existing folders in local are copied over to the server | adapt | Local content that predates the domain — exercises `reimportItems(below:completionHandler:)`. |
| Filenames that are rejected by the server are reported | adapt | Rejection surfaces as an `NSFileProviderError` on the item, not an errors tab; resolution via `signalErrorResolved(_:completionHandler:)`. |
| Invalid system names are synced (`CON`, `PRN`, `test%`, `foo%`) | adapt | All legal on APFS; keep as a round-trip check. |
| Syncing a folder having space at the end | adapt | Legal on macOS; assert the trailing space survives the round trip. |
| various types of files can be synced from server to client | port | |
| various types of files can be synced from client to server | port | |
| File with long name can be synced | port | |
| File with spaces in the name can sync | port | |
| sync resources having European characters | port | Extend with the NFD/NFC case below. |
| Syncing file of 1 GB size | port | Throughput; end-to-end tier only. |
| Syncing folders each having 500 files | port | Throughput and enumeration pagination; end-to-end tier only. |
| extract a zip file in the sync folder | port | Many creations in a short window. |
| remove folder sync connection | adapt | Becomes domain removal and the `DomainRemovalMode` choice for local files. |
| Sync all is selected by default | n/a | Sync-connection wizard. |
| Sync only one folder from the server | n/a | Selective sync; a replicated domain has no folder subset. Server-side deletion propagation is kept as an enumeration scenario. |
| sort folders list by name and size | n/a | Client UI. |
| Skip sync folder configuration | n/a | Wizard. |
| sync remote folder to a local sync folder having special characters | n/a | The local location is system-owned, not user-chosen. |
| Try to sync files having space at the end (Windows only) | n/a | Windows path rules. |
| Sync invalid system names (Windows only) | n/a | Windows path rules. |

### `tst_vfs`

Every scenario here is *adapt* rather than *port*: a replicated provider is always
virtual, so there is no VFS switch to toggle.

| Client scenario | Becomes |
|---|---|
| Disable/Enable VFS | Split into: items are browsable while unmaterialised · reading materialises · eviction returns an item to unmaterialised while it stays browsable. |
| Copy and paste virtual file | Copying an unmaterialised item — inside the domain, and out to a local folder. |
| Move virtual file | Moving an unmaterialised item within the domain must not materialise it; moving it out of the domain must. |
| Disable/Enable VFS quickly | Repeated evict/materialise churn on a large file, asserting no stuck or duplicated state. |

### macOS-specific additions

Not present in the client suites, and specific to this platform:

* APFS NFD vs. server NFC filename normalisation.
* `:` / `/` translation in filenames between Finder and the server.
* Packages and bundles (`.app`, `.key`, `.rtfd`) treated as single items.
* `.DS_Store`, extended attributes and resource forks — synced, ignored, or dropped.
* Finder's *Remove Download* as the eviction trigger.
* Quota exhaustion on upload, and the error the user sees.
* Domain disconnected (`NSFileProviderDomain.isDisconnected`): browsing works,
  materialisation fails cleanly, and the queue drains on reconnect.
* Trash semantics (`NSFileProviderDomain.supportsSyncingTrash`).

---

## Log & Execution History

* *2026-08-16*: Initialized `progress.md` tracking layout for macOS File Provider extension TDD loop engineering.
* *2026-08-16*: Corrected Apple API names, extension point identifiers, `Info.plist` keys and sandbox entitlements after review of PR #1.
* *2026-08-16*: Re-verified every Apple claim against `developer.apple.com` (see References). All protocol, selector and entitlement names hold exactly as written. Two claims from the previous pass were wrong and are fixed: `NSFileProviderDomainUsageDescription` does exist (it is a consuming app's key, not ours), and `NSExtensionFileProviderSupportsPickingFolders` is absent from Apple's key index. The two extension point identifiers could not be confirmed from the documentation and are now labelled as Xcode-template values pending a check on the Mac.
* *2026-08-16*: Phase 1 skeleton landed as headless-verifiable artifacts on branch `phase-1-skeleton`. Created the local SPM core package `Core/` (`OwnCloudCore`, macOS 14, Foundation-only so it stays Linux-buildable for AC-2's backend-contract tier) with a green `swift test`. Wrote the three targets' source trees, `Info.plist`s (correct extension-point identifiers) and `.entitlements` (Task 1.2/1.3), plus [`PROJECT.md`](PROJECT.md) documenting the target/dependency wiring that must be assembled in Xcode on a Mac. Tasks 1.1–1.4 marked `[~]` (partial): the `.xcodeproj`/`.appex` targets, the `xcodebuild test` half, signing-team-gated `testing-mode`, and the `.xctemplate` identifier reconfirmation all require a Mac and remain blocked. Discovered `swift test` must run with the command sandbox disabled here (Xcode module cache is outside the sandbox); recorded in `PROJECT.md`.
* *2026-08-16*: Phase 2 core landed test-first (24 tests green under `swift test`). Task 2.1/2.2: `WebDAVItem` + namespace-aware `WebDAVMultiStatusParser` (Foundation `XMLParser`) parsing SabreDAV Depth:1 PROPFIND multistatus. Task 2.3/2.4: `GraphDrive`/`GraphItem`/`GraphItemCollection` + `GraphJSONDecoder` for oCIS Graph (drives, children, delta `$token`, `deleted` facet). Task 2.5 (`[~]`): `Credentials` + injectable `CredentialStore` + `SessionManager` covering Basic/Bearer header building and leeway-based token refresh with injected clock; Keychain-backed store and live OIDC refresh remain Mac/entitlement-gated. Each step followed red→green: watched the test fail for a missing-type reason before implementing. All backend logic kept Foundation-only for AC-2's Linux backend-contract tier.
* *2026-08-16*: Phase 3 enumeration core landed test-first (40 tests green). Task 3.1: `FileProviderItemDescription` value type + `ItemIdentifier`/`ItemCapabilities` and WebDAV/Graph mappers, keeping the FileProvider framework out of the Linux core. Task 3.2 (`[~]`): `SyncAnchor`/`PageCursor`/`EnumerationPage`/`Paginator` for paged accumulation + anchor capture. Task 3.3 (`[~]`): `ChangeSet` diffing (listing-vs-listing for WebDAV, delta-page split for oCIS). The `NSFileProviderEnumerator`/`ChangeObserver` conformances remain Mac-only adapters over this logic; the enumeration acceptance gate stays open pending Phase 6.
* *2026-08-16*: Phase 4 content core landed test-first (57 tests green). `RemoteRequest`/`HTTPMethod` + `PathEncoding`, `WebDAVRequestBuilder` (GET fetch, PUT create, MKCOL, PUT modify w/ `If-Match`, DELETE, MOVE w/ `Destination`+`Overwrite: F`) and `GraphRequestBuilder` (GET/PUT `/content`, DELETE item, POST `/children` folder w/ `conflictBehavior: fail`) cover the routed request each replicated handler issues (Tasks 4.1/4.2/4.4). `UploadQueue` (Task 4.3, `[x]`) does change detection by version + dedup + FIFO. The `NSFileProviderReplicatedExtension` handler conformances, temp-URL streaming hand-off, and conflict mechanism remain Mac-only adapters; the content acceptance gate stays open pending Phase 6.
* *2026-08-16*: Phase 5 sign-in core landed test-first (65 tests green). Task 5.1 (`[~]`): `BackendDetector` (oCIS via OIDC discovery, Classic via installed `status.php`, OIDC wins ties, `nil` when neither), `AccountDescriptor` (stable `domainIdentifier`, `user@host` display name), `DomainRemovalChoice` (default preserves downloaded data). Task 5.2 (`[~]`): UI extension `ActionViewController` scaffold. Task 5.3 deferred — it is the Phase 6 acceptance suite (Mac + Docker + signing gated). The `NSFileProviderManager`/domain and AppKit UI conformances remain Mac-only; the lifecycle acceptance gate stays open pending Phase 6.
* *2026-08-16 (on a Mac, Docker running)*: AC-2 **backend-contract tier proven against both live backends.** Added `URLRequestFactory` (test-first, 6 tests) — the Foundation-only seam mapping a `RemoteRequest` onto a `URLRequest` with the `Authorization` header — closing the gap between the pure Phase 4 builders and real HTTP. Added `BackendContractTests`, gated on `OWNCLOUD_TEST_BACKEND` so the unit run skips them: it drives request-shaping → `URLRequestFactory` → `URLSession` → parser against the Docker fixtures. Both pass — Classic `owncloud/server:11.0.0` PROPFIND → 207 → `WebDAVMultiStatusParser` yields items; oCIS `owncloud/ocis:8.2.0` `me/drives` → 200 → `GraphJSONDecoder` yields the personal drive. Enabled `PROXY_ENABLE_BASIC_AUTH` on the oCIS fixture (test-only) for a uniform credential path, and trusted the self-signed cert with a test-only `URLSessionDelegate`. Added a [`Makefile`](Makefile) `make backend-contract BACKEND=…` entry point (up → wait-for-health → run → teardown), satisfying AC-4 for this tier; verified green + clean teardown for both backends. Unit suite now 90 tests (88 + 2 contract, skipped without the env var).
* *2026-08-16 (on a Mac — Xcode 16.4, macOS 26, Swift 6.1.2)*: Phase 1 Mac-gated tasks completed. Adopted **XcodeGen** (the generator PROJECT.md had earmarked) and committed a reviewable [`project.yml`](project.yml) wiring all three targets (App + two `.appex`) to the existing committed sources/Info.plists/entitlements and the local `OwnCloudCore` package, with the real ownCloud GmbH team id `4AP2STM4H5`. `xcodebuild -scheme App build` → **BUILD SUCCEEDED**: the app bundle embeds both extensions in `Contents/PlugIns` and passes `embeddedBinaryValidationUtility`, which **confirms the two `NSExtensionPointIdentifier` values** that were flagged pending-a-Mac (Task 1.2). Task 1.1 and 1.2 → `[x]`. Task 1.4 → `[x]`: both `swift test` and `xcodebuild test -scheme App` run the 82-test `OwnCloudCore` suite green (test wired via the scheme's `test:` block). Updated the CI unit tier to `xcodegen generate` + `xcodebuild test`, git-ignored the generated `.xcodeproj`, and refreshed PROJECT.md. Task 1.3 stays `[~]`: the bundle signs with the Developer ID identity, but `fileprovider.testing-mode` still needs a provisioning profile carrying that entitlement (Task 6.1).
* *2026-08-16*: Phase 6 completed to its headless boundary (82 tests green). Task 6.6 (`[~]`): `ScenarioSelection` test-first (4 tests) — `mainSuite`/`quarantined` partition on `@quarantine` and `forBackend` applies AC-1's `@classicOnly`/`@ocisOnly`. Task 6.3 (`[~]`): the `BackendAdmin` provisioning half test-first (6 tests) — `OCSProvisioningRequestBuilder` (Classic OCS API, form-encoded, `OCS-APIRequest` header) and `GraphProvisioningRequestBuilder` (oCIS Graph users JSON), provisioning fixtures via each backend's own admin API (AC-1) and reusing the Phase 4 `RemoteRequest`. Tasks 6.0 and 6.1 marked fully blocked with notes: 6.0 is by definition a live-runner spike (no unit test possible), and 6.1 is an org/human decision on committing signing credentials — the AC-3 bounded-polling fallback covers the interim. Every Phase 6 task is now either `[~]` (headless artifact done, Mac/Docker/signing remainder documented) or blocked with an explicit reason; no task is silently unaddressed.
* *2026-08-16*: Phase 6 headless-verifiable artifacts landed (72 tests green). Task 6.2 (`[~]`): Docker fixtures for both backends (`owncloud/server:11.0.0` + MariaDB + Redis with health checks; `owncloud/ocis:8.2.0`), a single pinned-version source `versions.env` (AC-7), and `start-ocis-macos.sh` that downloads the same oCIS version as a `darwin-arm64` binary for the runner. Task 6.4 (`[~]`): `GherkinParser` (feature/background/scenario/outline, tags, `And`/`But`, examples + `expanded()`) test-first with 8 tests green, plus `test/features/enumeration.feature` (4 `tst_syncing`-seeded scenarios, verified to parse). Task 6.5 (`[~]`): `.github/workflows/ci.yml` wiring AC-2's three tiers — unit (`swift test`), backend contract (both backends in Docker on `ubuntu-latest`, matrix, AC-6 log upload on failure), and end-to-end (oCIS `darwin-arm64` binary on `macos-15`, nightly + `full-ci` label) — third-party actions pinned to full commit SHAs. Blocked remainder is Mac/Docker/signing: the `xcodebuild test` step, the live backend-contract suite (Task 6.3), the end-to-end harness (Task 6.0 spike), and the Gherkin step library/runner.
* *2026-08-16*: Added the Acceptance Criteria section, per-phase acceptance gates for Phases 3–5, Phase 6 for the acceptance suite and CI, and an appendix seeding the scenarios from the desktop client's `tst_syncing` and `tst_vfs` suites. Nothing is complete until it passes against both ownCloud Classic v11 (`owncloud/server:11.0.0`) and oCIS, run from Docker fixtures. GitHub-hosted macOS runners turn out to have no container runtime at all, so the end-to-end tier runs oCIS from its `darwin-arm64` release binary and Classic v11 keeps no end-to-end tier in CI — it runs locally against Docker until a Docker-capable macOS runner exists. That gap is recorded in AC-2 rather than papered over. Whether the deterministic sync controls (`testingModes`, `run(_:)`, `waitForStabilization`) or bounded polling is used depends on Apple signing credentials being available to CI; both paths are specified and the choice is Task 6.1.
* *2026-08-16 (on a Mac)*: Phase 3 Mac-only adapters landed test-first in the new `FileProviderSupport` SPM target (13 target tests green; 103 total, 2 contract skipped). `FileProviderItem` conforms `NSFileProviderItem` over the core `FileProviderItemDescription` (identifier/root mapping, filename/size, content-type via UTType, etag → both version components, capability translation) — 8 tests. `ItemEnumerator` conforms `NSFileProviderEnumerator` over the core `Paginator`/`ChangeSet`: `enumerateItems` walks all pages and vends `FileProviderItem`s, `enumerateChanges` maps a `ChangeSet` onto `didUpdate`/`didDeleteItems` and finishes with the new anchor (change provider injected), `currentSyncAnchor` surfaces the latest — 5 tests with fake observers covering multi-page, fetch/diff error surfacing, and anchor plumbing. All FileProvider-importing code is behind `#if canImport(FileProvider)` so the package stays Linux-buildable for AC-2. Tasks 3.2/3.3 → `[x]`; the enumeration acceptance gate stays open pending Phase 6.
* *2026-08-16 (on a Mac)*: Phase 4 error-classification layer landed test-first (118 tests green). Added `OwnCloudCore.RemoteError` — the backend-agnostic mapping from an HTTP status (shared by WebDAV and Graph) to a semantic failure: 401 → authenticationRequired, 403 → insufficientPermissions, 404 → noSuchItem, 409/412 → versionConflict, 507 → insufficientQuota, 5xx/unclassified → serverError, 2xx → nil (9 tests). Added the Mac-only `RemoteError.asFileProviderError` adapter in `FileProviderSupport` mapping those onto the system errors the replicated-extension handlers must return — `NSFileProviderError` codes (notAuthenticated/noSuchItem/insufficientQuota/serverUnreachable) plus Cocoa `fileWriteNoPermission`/`fileWriteFileExists` for the two cases FileProvider has no code for (6 tests). This closes the "what does a failure mean to the system" half of Tasks 4.1/4.2/4.4; the remaining Mac-only glue is the `URLSession` byte streaming (download-to-temp-URL hand-off for `fetchContents`, upload for the push handlers) wired into the extension target.
* *2026-08-16 (on a Mac)*: Phase 5 domain adapter landed test-first (122 tests green). Added the Mac-only `FileProviderSupport` translation of the core account model onto the FileProvider domain types (Task 5.1): `NSFileProviderDomain(account:)` builds a replicated domain from `AccountDescriptor`'s stable identifier + display name, and `DomainRemovalChoice.removalMode` maps onto `NSFileProviderManager.DomainRemovalMode` (preserveDownloadedUserData / removeAll), with the default preserving downloads — 4 tests. This is the pure translation half of Task 5.1; the remaining Mac-only work is the live `NSFileProviderManager.add(_:)`/`remove(_:mode:)` calls and the `/Applications` discovery prerequisite, which need a signed, installed app to exercise (Phase 6).
* *2026-08-16 (on a Mac)*: Wired `FileProviderSupport` into the Xcode project. [`project.yml`](project.yml) now links the `FileProviderSupport` product into the App target (domain add/remove) and the File Provider `.appex` (item/enumerator/error adapters); `xcodebuild -scheme App build` with signing disabled still **BUILD SUCCEEDED** with both extensions embedded and validated, confirming the second SPM product links into the `.appex`. Added `FileProviderSupportTests` to the App scheme's `test:` block so `xcodebuild test` runs it through the generated project alongside `OwnCloudCoreTests` — `xcodebuild test` → **TEST SUCCEEDED**, 122 tests (2 contract skipped). (Local `xcodebuild` build/test uses `CODE_SIGNING_ALLOWED=NO`; a real signed build needs the paid-team provisioning profiles per Task 1.3/6.1.)
* *2026-08-16 (decision)*: **Task 6.1 settled — no Apple signing for now** (project owner). AC-3 uses the documented **bounded-polling fallback**, not the deterministic `fileprovider.testing-mode` path. All live-integration steps (Tasks 4.1/4.2/4.4 byte-streaming glue, 5.1 live `add`, 5.3 end-to-end, 6.0 runner spike) remain blocked on a signed app installed in `/Applications`; `xcodebuild` runs locally with `CODE_SIGNING_ALLOWED=NO`. Headless-testable core + `#if canImport(FileProvider)` adapters continue test-first. Task 6.1 → `[x]`.
* *2026-08-16 (on a Mac)*: Added the Phase 3 enumeration **request** builders test-first (131 tests green) — the piece that feeds `Paginator`'s injected `FetchPage`. `WebDAVRequestBuilder.enumerate(path:)` issues PROPFIND `Depth: 1` with an XML body requesting exactly the props `WebDAVMultiStatusParser` reads (DAV core + `oc:id`/`oc:size`/`oc:permissions`/`oc:favorite`); `GraphRequestBuilder.enumerate(driveID:cursor:)` GETs `/root/children` for the first page and follows the opaque `$token` against `/root/delta` for subsequent pages (the same endpoint that drives change tracking). 4 tests. This closes the request-shaping gap between the builders and the enumeration engine; wiring a builder+parser into a live `Paginator.FetchPage` via `RemoteClient` is the remaining Mac/signed step.
* *2026-08-16 (on a Mac)*: Added the pure response→`EnumerationPage` mapping test-first (136 tests green) — the other half of `Paginator.FetchPage`. `EnumerationPage(webDAVItems:containerHref:parentIdentifier:)` drops the Depth:1 self-entry (the response whose normalized href matches the requested container) and maps the remaining children to `FileProviderItemDescription`s under the given parent, with no cursor (Classic lists all children at once). `EnumerationPage(graphCollection:)` maps a `GraphItemCollection`: `nextToken` → next `PageCursor`, `deltaToken` (final page only) → `SyncAnchor`. 5 tests. Together with the enumerate request builders, both backends now have a fully unit-tested request-shape → parse → page path; only the live fetch closure (`RemoteClient` + builder + parser wired into `Paginator.FetchPage`) remains, and that needs the signed/installed app.
* *2026-08-17 (on a Mac)*: **Live-fetch enumeration + hydration wired now signing is available (171 → wired extension, 171 core tests green).** With signing done, worked the byte-streaming glue that the "no signing" decision had blocked, all test-first: `RemoteEnumerationSource` (WebDAV PROPFIND→parse→drop self-entry→synthesized listing anchor; Graph children→delta cursor/anchor) + `enumerateAll(from:)` closes the "builder+parser into a live `Paginator.FetchPage`" gap; `ItemEnumerator` gains a source-backed init so the `NSFileProviderEnumerator` drives the real async network path. `ContentDownloader` (Task 4.1/4.2 — download to a fresh temp URL, failure writes nothing) and `ContentUploader` (Task 4.4 — stream a file body, map 412/409→versionConflict) implement the content halves. `AccountDescriptor(domainIdentifier:)` round-trips the account the extension is handed. `BackendConnection` is the per-domain composition root encoding the path-addressed (Classic) vs ID-addressed (oCIS) split. The `FileProviderExtension` principal class now vends a real enumerator and a real `fetchContents`; the only remaining seam is the Keychain-backed `CredentialStore` (`authorization(for:)` returns `nil` → handlers fail cleanly with `.notAuthenticated`). `xcodebuild -scheme App -allowProvisioningUpdates build` → **BUILD SUCCEEDED**, both `.appex` signed (`codesign --verify --deep --strict` OK). Live exercise of the domain is the Task 6.0 spike (signed app in `/Applications` + credentials).
* *2026-08-17 (on a Mac)*: **Apple development code signing set up — Task 1.3 → `[x]`, Task 6.1 decision reversed.** Configured automatic (Xcode-managed) signing under team `4AP2STM4H5` (ownCloud GmbH). `xcodebuild -scheme App -allowProvisioningUpdates build` → **BUILD SUCCEEDED**: app + both `.appex` signed with `Apple Development: Thomas Mueller`, Mac App Development profiles minted/embedded, `codesign --verify --deep --strict` passes, and the managed `com.apple.developer.fileprovider.testing-mode` entitlement validated against the generated profile with no separate portal capability toggle. Setup snag worth recording: automatic signing needs this Mac registered in the account's Devices list, and on Apple Silicon the Provisioning UDID to register is the short `system_profiler SPHardwareDataType | grep "Provisioning UDID"` value (`00006030-…`), **not** the `IOPlatformUUID` from `ioreg`. This reverses the 2026-08-16 "no signing" decision: the deterministic AC-3 path (`testingModes`/`run(_:)`/`waitForStabilization`) is now available locally, and the live-integration steps (Tasks 4.1/4.2/4.4 byte-streaming glue, 5.1 live `add`, 5.3 end-to-end, 6.0 runner spike) are unblocked on this developer Mac. CI-secret signing for hosted runners stays a separate open item.
* *2026-08-16 (on a Mac)*: Added the WebDAV sync-anchor synthesis test-first (143 tests green). Classic has no delta API, so `SyncAnchor(listing:)` digests the current listing (each item's identifier + `versionIdentifier`) into a deterministic, order-independent token via a small FNV-1a hash — Swift's `Hasher` is per-run seeded and can't back a persisted anchor. The digest is stable for unchanged contents and changes on any add/remove/version-change, so the enumerator can cheaply decide whether to re-list and diff (`ChangeSet(from:to:)`) for `enumerateChanges`. 7 tests (stability, order-independence, version/add/remove sensitivity, empty listing, Data round-trip). This closes the last enumeration-core gap named in the `SyncAnchor` note; Classic and oCIS now both have complete headless enumeration/change-tracking logic. Re-verified the Mac project: `xcodebuild -scheme App build` (signing disabled) still BUILD SUCCEEDED with both `.appex` embedded.
* *2026-08-17 (on a Mac)*: **Keychain-backed `CredentialStore` landed and wired — Task 2.5's last blocked seam closed (183 core tests green, 2 skipped).** TDD, split by testability: `CredentialCoder` in the Linux-buildable core serializes `Credentials`↔a tagged-JSON payload (scheme + fields, bearer expiry as a Unix timestamp), pinning the byte format the shared access group persists without needing `SecItem` — 5 tests (basic/bearer round-trip, expiry-to-the-second, colon-in-password, garbage→throws). `KeychainCredentialStore` in `FileProviderSupport` conforms to `CredentialStore` over an injectable `KeychainBackend` seam so the store logic is fully headless: one generic-password item per account keyed by the account's stable `domainIdentifier` under the shared access group, upsert-on-resave, corrupt-blob→`nil`; the real `SecItem` implementation (`SecItemKeychainBackend`, `SecItemUpdate`→`SecItemAdd` fallback) is the default and never runs in the unit suite — 7 tests via an in-memory fake backend. Then replaced `FileProviderExtension.authorization(for:)`'s `nil` stub: it builds a `KeychainCredentialStore` over `com.owncloud.macos.fileprovider.shared` + a `SessionManager`, calls `refreshTokenIfNeeded()`, and returns a real `Authorization` header. `xcodegen generate` + `xcodebuild -scheme App -allowProvisioningUpdates build` → **BUILD SUCCEEDED**, both `.appex` signed. Remaining on Task 2.5: the live `SecItem` round-trip needs a signed/installed host (Task 6.0), and the oCIS OIDC token-endpoint `RefreshHandler` is still to be wired.
* *2026-08-17 (on a Mac)*: **oCIS new-file upload request + body-returning upload (198 core tests green, 2 skipped).** Completed the request-shaping surface the create/modify handlers will route: `GraphRequestBuilder.uploadNewFile(driveID:parentID:name:)` PUTs a new file's bytes under its parent via the `items/{parent}:/{name}:/content` path syntax (name percent-encoded), exposed on `BackendConnection` as `uploadNewFileRequest(parentID:name:)`; and `ContentUploader.uploadReturningBody` returns the response body so oCIS create/modify can reconcile the returned driveItem via `decodeItem`. With these, every core primitive the two remaining handlers need on the oCIS side exists; what's left for `createItem`/`modifyItem` is the live-server reconciliation glue (Classic reads the new ETag from the PUT response *header*, `FileProviderItemDescription`→`NSFileProviderItem`, template-field mapping), best exercised in the Task 6.0 spike.
* *2026-08-17 (on a Mac)*: **oCIS `createItem` wired end-to-end (204 core tests green, 2 skipped).** Test-first, added the root-relative Graph request variants (`uploadNewFileUnderRoot`, `createFolderUnderRoot`) and `BackendConnection.createItemRequest(parentID:name:isDirectory:)`, which centralises the two routing decisions the handler needs — drive root (`root` segment) vs. a specific parent (`items/{id}`), and folder (POST `/children`) vs. file (PUT `:/name:/content`) — 6 `BackendConnection` + 2 builder tests. `FileProviderExtension.createItem` now handles the oCIS path: shape the request, stream the system-provided file bytes (or send the folder JSON / a zero-byte file), decode the returned driveItem (`GraphJSONDecoder.decodeItem`), reconcile it into a `FileProviderItem`, and hand it back; `RemoteError`→`NSFileProviderError`. Classic `createItem` (PUT/MKCOL return no metadata body, so a follow-up PROPFIND is needed) and both backends' `modifyItem` remain `NSFeatureUnsupportedError` pending the live Task 6.0 spike. `xcodegen generate` + signed `xcodebuild -scheme App -allowProvisioningUpdates build` → **BUILD SUCCEEDED**.
* *2026-08-17 (CI, PR #2)*: **Backend-contract tier turned green on `ubuntu-latest` — three independent root causes fixed via systematic debugging, each verified before the next.** (1) *Compile error, not a test failure:* `BackendContractTests`' `InsecureTrustDelegate` used `challenge.protectionSpace.serverTrust` + `URLCredential(trust:)`, both Darwin-only, so the whole `OwnCloudCoreTests` target failed to compile on swift-corelibs-foundation and `--filter BackendContract` never ran (reproduced in `swift:6.0-jammy`). Guarded the trust override behind `#if canImport(Security)`, falling through to `.performDefaultHandling` on Linux — Linux `swift build --build-tests` → green. (2) *Bogus healthcheck:* the oCIS fixture's `["CMD","ocis","health"]` exits 3 (`No help topic for 'health'` — no such subcommand in 8.2.0), so `docker compose up --wait` timed out though the server was fully up. Replaced it with a Basic-authed `curl` of `graph/v1.0/me/drives` (proves proxy + IDP + Graph are serving), `retries: 20`, `start_period: 60s`; `up --wait` → `Healthy`. (3) *Self-signed TLS on Linux:* with (1)/(2) fixed the test still couldn't reach oCIS — foundation-on-Linux has no runtime API to trust the fixture cert, and plain http is impossible (oCIS IDP refuses a non-https issuer). Added an oCIS-only CI step that extracts the cert via `openssl s_client` and installs it with `update-ca-certificates`; the cert's SAN already covers `localhost`/`127.0.0.1` (the CI URL). Verified both suites green against the live fixtures from a Linux container: Classic PROPFIND and oCIS `me/drives` pass; macOS unit suite still 204 green (2 contract skipped). Earlier fix from this cycle: the `Load pinned versions` step now greps `KEY=value` lines into `$GITHUB_ENV` (the file's leading `#` comments were rejected as "Invalid format").
* *2026-08-17 (on a Mac)*: **oCIS drive-id resolution wired into the extension — Task 5.1 async connection path (220 core tests green, 2 skipped).** oCIS is ID-addressed, so `BackendConnection` needs a concrete personal `driveID`, which is only known after an async `GET /me/drives` lookup — but the extension had been building the connection eagerly in `init` with `driveID: nil` (so oCIS enumeration would have hit `drives//root/children`). Test-first core pieces: `GraphRequestBuilder.listDrives()` (`/graph/v1.0/me/drives`) + `GraphRequestBuilder.move(driveID:itemID:newName:newParentID:)` (PATCH, adds `HTTPMethod.patch`); `GraphDrive.personalDrive(in:)` picks the `driveType == "personal"` drive; `DriveResolver` composes list+decode+pick over an injected `RemoteClient` (2 tests: resolves personal id + hits the right URL/auth header; throws `.noPersonalDrive` when absent); `LazyRemoteEnumerationSource` defers building the real source to the first page fetch and memoizes it via an actor, running the factory at most once and *not* caching a failed build (3 tests). Also added `BackendConnection.readBackRequest(path:)`/`readBackItem(fromPropfind:parentIdentifier:)` (Depth:0 PROPFIND read-back) and `moveRequest(itemID:newName:newParentID:)`. Then refactored `FileProviderExtension`: removed the eager `connection` stored property; every handler now obtains its connection via an async `makeConnection()` that resolves (and caches, via a `DriveIDCache` actor) the oCIS personal drive id — Classic still resolves to `driveID = nil`. `enumerator(for:)` (sync) wraps the source in `LazyRemoteEnumerationSource { try await self.makeConnection().enumerationSource(for:) }`; `createItem`/`modifyItem`/`deleteItem` await `makeConnection()` inside their Task, with the create/modify/move helpers rewritten as `async throws -> FileProviderItem` so error mapping is centralised in the public handler. `xcodegen generate` + signed `xcodebuild -scheme App -allowProvisioningUpdates build` → **BUILD SUCCEEDED**, both `.appex` signed. Live oCIS enumeration/CRUD against the fixture remains the Task 6.0 spike (needs a bearer/OIDC credential path).
* *2026-08-17 (on a Mac)*: **`item(for:)` single-item lookup wired for both backends (228 core tests green, 2 skipped).** The `NSFeatureUnsupportedError` stub is replaced: the root container is answered synthetically (no round-trip, `FileProviderItemDescription.rootContainer`), and any other identifier is fetched from the backend. Test-first core: `GraphRequestBuilder.metadata(driveID:itemID:)` (GET `/items/{id}`, no `/content` suffix) + `BackendConnection.itemMetadataRequest(itemID:)` — 2 tests. The extension's `fetchItem` routes per backend: oCIS decodes the returned driveItem (which carries its own `parentReference.id`); Classic reuses the Depth:0 PROPFIND read-back, deriving the parent by dropping the identifier-path's last segment (`.rootContainer` for a child of root) since WebDAV hrefs carry no parent id, and maps an empty multistatus to `.noSuchItem`. Signed `xcodebuild -scheme App -allowProvisioningUpdates build` → **BUILD SUCCEEDED**, both `.appex` signed. (The Classic path-vs-`oc:id` identifier tension noted under Task 4.4 applies here too and is part of the Task 6.0 live reconciliation.)
* *2026-08-17 (design)*: **Phase 7 (user-facing configuration) designed and added; nothing implemented yet.** Spec at `docs/superpowers/specs/2026-08-17-fileprovider-configuration-design.md` (git-ignored per repo hygiene — read it before starting Phase 7; it carries the arguments, the wireframe, and the alternatives that were rejected). Six decisions worth recording because they are hard to re-derive: (1) **The premise that started this — "iCloud puts an entry in System Settings, so we do too" — is not achievable.** macOS 13+ exposes no public API for a third party to add to System Settings; iCloud's entry is first-party UI. Configuration lives in the containing app, which macOS already forces into `/Applications` (Task 5.1). A `/Library/PreferencePanes` bundle was evaluated and rejected. (2) **One `NSFileProviderDomain` per oCIS space** (Classic = one domain over its files root), because `BackendConnection.swift:19` already resolves exactly one drive per domain — so per-space domains cost almost nothing, while a single domain with a synthetic space level would mean inventing a virtual hierarchy the enumerator does not have. (3) **Splitting identity:** `AccountDescriptor.domainIdentifier` currently keys both the domain (`DomainAdapter.swift:12`) and the Keychain item (`KeychainCredentialStore.swift:47`); under per-space domains that would give every space its own refresh token, so the property becomes `accountIdentifier` (credential identity, no Keychain migration) and a new `SyncRoot` owns `"<driveID>|<accountIdentifier>"` (domain identity), drive-first so the username stays the verbatim tail. (4) **Found a live bug while designing:** `FileProviderExtension.swift:34` hardcodes `driveID: nil`, so every oCIS Graph request builds `drives//…`. Task 7.1 fixes it; the Phase 3 gate depends on that too. (5) **No persisted "selected spaces" setting** — `getDomainsWithCompletionHandler` is the source of truth, so selection is a lifecycle operation, not state to keep in sync (Nextcloud ships `resetVfsForAccount`/`performStartupReconciliation` precisely to repair the drift a parallel list creates). What is stored is an account registry (so a zero-space account does not vanish) plus a display-only catalog cache. (6) **Per-space domains create a real refresh-token race** — N extension instances over one rotating oCIS token — fixed by cross-process `flock` double-checked locking (Task 7.6), which does not count as done without the end-to-end scenario in Task 7.10. Argued **out** of v1 with reasons: known-folder claim (`claimKnownFolders` is per-domain, so "which space owns your Desktop?" has no answer, and the failure mode is irreversible movement of user data), MDM/managed prefs, menu bar item, custom per-item Finder actions, Classic folder selection, bandwidth/ignore-list/log-level settings. Five assumptions remain unverified and are Task 7.0, deliberately placed first so they cannot silently become facts.

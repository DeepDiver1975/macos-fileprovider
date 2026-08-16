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
* [~] **Task 1.3:** Setup code signing entitlements. The extension is sandboxed, so it needs:
  * `com.apple.security.app-sandbox`
  * `com.apple.security.network.client` — **required**; without it every request in Phase 2 fails immediately
  * `keychain-access-groups` (or `com.apple.security.application-groups`) so the containing app's sign-in flow and the extension can share credentials (needed by Tasks 2.5, 5.1, 5.2) — must be provisioned up front, not retrofitted
  * `com.apple.developer.fileprovider.testing-mode` for the Task 5.3 integration suite and the deterministic path of AC-3 — subject to Task 6.1, since it needs a provisioning profile from a paid Apple Developer team
  * Do **not** add `com.apple.security.files.downloads.read-write` / `files.user-selected.read-write` to the extension — those are host-app file-picker entitlements; a replicated provider writes into the system-provided domain directory.
  * **Loop status:** three `.entitlements` files written — app, extension, UI extension — each with app-sandbox, network.client, the shared app group and keychain group, the extension carrying `fileprovider.testing-mode`, and none carrying the file-picker entitlements. All three build and embed cleanly with the real team id `4AP2STM4H5` (ownCloud GmbH) set in [`project.yml`](project.yml) as `DEVELOPMENT_TEAM`. **Still blocked:** `fileprovider.testing-mode` requires a *provisioning profile that carries that specific entitlement* from the paid team — the Developer ID identity present here signs the bundle but a testing-mode profile must still be issued (Task 6.1); until then AC-3 uses the bounded-polling fallback.
* [x] **Task 1.4:** Establish the test harness: `swift test` covers the local SPM core package; the extension targets are covered by XCTest targets inside the Xcode project (`xcodebuild test`).
  * **Done (Mac):** both halves are green — `swift test` over `Core/` (82 tests) and `xcodebuild test -scheme App -destination 'platform=macOS'`, which runs the `OwnCloudCore` suite through the generated project (82 tests, wired via the App scheme's `test:` block in [`project.yml`](project.yml)). Extension-specific XCTest targets are added as the Mac-only adapters (Phases 3–5) gain testable logic. **Sandbox caveat recorded in [`PROJECT.md`](PROJECT.md):** the Xcode module cache lives outside the default command sandbox, so `swift test` runs with the sandbox disabled in this environment.

## Phase 2: Core Protocols & Networking Layer (TDD)

* [x] **Task 2.1:** Write failing unit test for parsing ownCloud Classic WebDAV `PROPFIND` multi-status XML responses into native domain models. *(Done: `WebDAVMultiStatusParserTests` — 7 tests over a Depth:1 SabreDAV multistatus fixture covering collection/file resourcetype, `oc:id`/`oc:size`/`oc:permissions`/`oc:favorite`, RFC-1123 dates, percent-decoded names, malformed-XML error.)*
* [x] **Task 2.2:** Implement robust XML parser (`XMLParser` delegate or lightweight parser) to pass Task 2.1. *(Done: `WebDAVItem` domain model + namespace-aware `WebDAVMultiStatusParser` on Foundation `XMLParser`/`FoundationXML` so it stays Linux-buildable. All green under `swift test`.)*
* [x] **Task 2.3:** Write failing unit test for oCIS Graph API JSON deserialization (drives, item lists, delta sync tokens). *(Done: `GraphModelsTests` — drive list with quota/root, children list with folder/file facets + `parentReference`, ISO-8601 dates, `$token` from `@odata.deltaLink`/`nextLink`, `deleted` facet, malformed-JSON error.)*
* [x] **Task 2.4:** Implement oCIS Graph API client structures to pass Task 2.3. *(Done: `GraphDrive`/`GraphQuota`/`GraphItem`/`GraphItemCollection` domain models + `GraphJSONDecoder` mapping `Codable` wire types to them. Foundation-only.)*
* [~] **Task 2.5:** Implement unified credential and session manager handling basic auth (Classic) and OAuth2/OIDC token refresh (oCIS). *(Done: `Credentials` (basic/bearer), injectable `CredentialStore` protocol, and `SessionManager` — `Authorization` header building, expiry/leeway-based `needsTokenRefresh()`, and persisted `refreshTokenIfNeeded()`. 10 tests green with injected clock + refresh handler.)* **Blocked:** the concrete Keychain-backed `CredentialStore` (shared access group) and the live OIDC token-endpoint `RefreshHandler` need entitlements / a signed host on the Mac (Task 1.3); the pure logic is fully covered headlessly.

## Phase 3: File Provider Domain & Enumeration (`NSFileProviderEnumerating`)

* [x] **Task 3.1:** Write failing unit test for `NSFileProviderEnumerator` container initialization mapping remote container roots to `NSFileProviderItem`. *(Done: `FileProviderItemDescriptionTests` — backend-agnostic `FileProviderItemDescription` value type (identifier, parent, filename, size, version/etag, content type, capabilities) with `ItemIdentifier`/`ItemCapabilities`, plus `WebDAVItem` and `GraphItem` mappers and a `rootContainer` synthesizer. The `NSFileProviderItem` adapter stays a Mac-only wrapper over this type.)*
* [~] **Task 3.2:** Implement root and child item enumeration logic in `enumerateItems(for:startingAt:)`, supporting pagination and sync anchors (`NSFileProviderSyncAnchor`, surfaced through `currentSyncAnchor(completionHandler:)`). *(Done in core: `SyncAnchor` (Data round-trip), `PageCursor`, `EnumerationPage`, and `Paginator` that walks pages until no cursor and captures the final anchor — backend fetch injected. Tested with multi-page and single-page sources.)* **Blocked:** the `NSFileProviderEnumerator` conformance and `currentSyncAnchor` plumbing are the Mac-only adapter.
* [~] **Task 3.3:** Implement change tracking enumeration (`enumerateChanges(for:from:)`, taking an `NSFileProviderChangeObserver` and a `from:` sync anchor) handling server-side additions, modifications, and deletions. *(Done in core: `ChangeSet` — `init(from:to:)` diffs two listings by identifier + `versionIdentifier` (WebDAV, no delta API), `init(graphDelta:)` splits an oCIS delta page's live vs. `deleted`-facet items. Additions/modifications/deletions covered.)* **Blocked:** the `NSFileProviderChangeObserver` conformance is the Mac-only adapter.
* **Acceptance gate:** the enumeration scenario group — items appear in the domain without being downloaded, server-side additions/modifications/deletions are reflected, and a folder large enough to force pagination enumerates completely. *(Gate stays open — requires the Phase 6 acceptance suite on a Mac against both backends.)*

## Phase 4: File Operations & Synchronization (`NSFileProviderReplicatedExtension`)

* [~] **Task 4.1:** Write failing unit test for file hydration via `fetchContents(for:version:request:completionHandler:)`. Note the replicated contract: the extension downloads to a location **it** chooses and hands that URL back, after which the system takes ownership of the file and moves it into its own replicated store. *(Done in core: `RemoteRequestBuilderTests` drive `WebDAVRequestBuilder.fetchContents` (GET at percent-encoded item path) and `GraphRequestBuilder.fetchContents` (GET on `/items/{id}/content`).)* **Blocked:** the `fetchContents` completion-handler contract (download to a chosen temp URL, hand it back for the system to take ownership) is the Mac-only adapter.
* [~] **Task 4.2:** Implement remote item fetch and content streaming to a temporary URL returned to the system. Do **not** maintain a separate long-lived disk cache — the system already stores hydrated content, so a self-managed cache double-stores every file. *(Done in core: the fetch `RemoteRequest`s above; the "no self-managed cache" rule is documented and there is deliberately no cache type.)* **Blocked:** the streaming-to-temp-URL glue is the Mac-only adapter (needs `URLSession` download + the FileProvider hand-off).
* [x] **Task 4.3:** Write failing unit test for local file modification detection and upload queuing. *(Done: `UploadQueueTests` — enqueue new/modified (version differs), skip unchanged, dedupe already-pending, FIFO dequeue, re-enqueue after a post-dequeue change.)*
* [~] **Task 4.4:** Implement the push synchronization handlers of `NSFileProviderReplicatedExtension` — `createItem(basedOn:fields:contents:options:request:completionHandler:)`, `modifyItem(_:baseVersion:changedFields:contents:options:request:completionHandler:)` and `deleteItem(identifier:baseVersion:options:request:completionHandler:)` — routing requests to either WebDAV or oCIS backends. *(Done in core: `RemoteRequest` + `WebDAVRequestBuilder` (PUT/MKCOL/DELETE/MOVE, `If-Match` for optimistic concurrency, `Destination`/`Overwrite: F` on move) and `GraphRequestBuilder` (PUT `/content`, DELETE item, POST `/children` folder with `conflictBehavior: fail`), plus `UploadQueue`. These are the routed requests each handler issues.)* **Blocked:** the `NSFileProviderReplicatedExtension` handler conformances and the conflict mechanism (a Phase 4 open question) are the Mac-only adapter.
* **Acceptance gate:** the content scenario group — hydration on read, upload of locally created files, rename/move, delete, the conflict scenario, and the large-file and many-files throughput scenarios. *(Gate stays open — requires the Phase 6 acceptance suite on a Mac against both backends.)*

## Phase 5: UI & Extension Lifecycle Integration

* [~] **Task 5.1:** Implement `NSFileProviderManager` domain setup, connection, and user sign-in flow initialization. **Prerequisite:** on macOS the extension is only discovered and launched when the containing app resides in `/Applications` (or `~/Applications`), or FileProvider testing mode is enabled. Launched straight from Xcode's DerivedData, `add(domain:)` reports success and Finder silently shows nothing. (Deployment behaviour rather than documented API — reconfirm on the Mac.) *(Done in core: `AccountSetupTests` drive `BackendDetector` (oCIS via OIDC discovery, Classic via a parseable installed `status.php`, OIDC wins ties), `AccountDescriptor` (stable `domainIdentifier`, `user@host` display name), and `DomainRemovalChoice` (default preserves downloads).)* **Blocked:** the `NSFileProviderManager.add(_:)` call, `NSFileProviderDomain` construction, and the `/Applications` discovery prerequisite are the Mac-only adapter.
* [~] **Task 5.2:** Build File Provider UI extension (`FPUIActionExtensionViewController`) for authentication credential inputs and domain removal actions. Scope note: from macOS 11 on, custom actions can be declared directly in the File Provider extension via `NSExtensionFileProviderActions` and run without presenting UI — so the UI extension is only needed for the flows that actually show something, such as sign-in. *(Done: `ActionViewController` scaffold with `prepare(forError:)`/`prepare(forAction:…)` stubs referenced by the UI extension Info.plist.)* **Blocked:** the actual credential-entry UI and its `FPUIActionExtensionViewController` behaviour need Xcode/AppKit on a Mac.
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
* [ ] **Task 6.1:** settle the AC-3 mechanism: determine whether Apple Developer signing
  credentials (certificate, provisioning profile carrying
  `com.apple.developer.fileprovider.testing-mode`, team ID) can be provided as CI
  secrets. Record the decision here; implement the other mechanism as the documented
  fallback either way.
  * **Loop status — fully blocked (an org/human decision, no headless artifact):** whether
    a paid Apple Developer team's signing credentials can be committed as CI secrets is not
    something the loop can settle — it needs the team and a policy call. The AC-3 *fallback*
    (bounded polling with documented per-assertion timeouts) is the path specified for
    contributors without those credentials, and is what the harness will use until this is
    recorded.
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
(`~/Library/CloudStorage/…` in practice, not documented), and the conflict mechanism a
replicated provider is expected to produce (Phase 4). All need a Mac to confirm.

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

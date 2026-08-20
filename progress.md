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
* [~] **Task 2.5:** Implement unified credential and session manager handling basic auth (Classic) and OAuth2/OIDC token refresh (oCIS). *(Done: `Credentials` (basic/bearer), injectable `CredentialStore` protocol, and `SessionManager` — `Authorization` header building, expiry/leeway-based `needsTokenRefresh()`, and persisted `refreshTokenIfNeeded()`. 10 tests green with injected clock + refresh handler.)* *(Done 2026-08-17: the concrete **Keychain-backed `CredentialStore`** — `CredentialCoder` (pure `Credentials`↔JSON payload, 5 tests) in the Linux-buildable core, and `KeychainCredentialStore` in `FileProviderSupport` over an injectable `KeychainBackend` seam with a real `SecItem` implementation (`SecItemKeychainBackend`) and an in-memory fake for tests — 7 tests covering round-trip, addressing by the account's stable id + shared access group, upsert-on-resave, clear, corrupt-blob tolerance. Wired into `FileProviderExtension.authorization(for:)`: it now builds a `KeychainCredentialStore` over the shared access group + a `SessionManager` and returns a real header instead of `nil`.)* *(Done 2026-08-17: the pure OIDC token-refresh pieces — `OIDCTokenRequestBuilder.refresh(refreshToken:clientID:scope:)` shapes the OAuth2 `grant_type=refresh_token` form-encoded POST (values percent-escaped to the unreserved set; `scope` omitted when nil), and `OIDCTokenResponse.credentials(from:now:previousRefreshToken:)` decodes the token JSON into `Credentials.bearer`, turning the relative `expires_in` into an absolute expiry against an injected clock, retaining the previous refresh token when the response omits one, and throwing `OIDCTokenError.malformedResponse` on garbage / a missing `access_token` — 6 tests.)* *(Done 2026-08-18 — **the live oCIS refresh path, wired and proven** (Task 7.13 / issue #17): `SynchronousTokenSender` bridges `URLSession` onto the deliberately-synchronous `OIDCRefreshHandler.Send` (refresh runs under the cross-process `RefreshLock`, so it must block; `400` maps to `.authenticationRequired` ahead of the general status classification so a revoked grant reads as re-authenticate). The app hands the extension the refresh *parameters* — token endpoint, client id/secret, scope — through `OIDCSessionStore` in the shared app group, since the extension never runs discovery, and `FileProviderExtension.authorization(for:)` now builds `SessionManager(store:refresh:refreshLock:)` with a per-account `FileLock` whenever a record exists. Proven live: `OCISSignInContractTests` assembles that exact stack over a pre-expired token and Konnect renews it, persists a future expiry, and the renewed header authorizes `listDrives`.)* *(Done 2026-08-19 — **the in-situ leg, which was the last open item here**: proven in the real extension on a clean replica, ~7 hours after sign-in with `expires_in=300`, by `200 POST /konnect/v1/token` followed by `200 /konnect/v1/userinfo` + `200 /graph/v1.0/me/drives` on the renewed bearer and **zero** `token is expired` from the extension. Note this leg had for a while been *silently disabled in the product* rather than merely untested — the extension could not read the app group at all, so `makeSession` always took its refresh-less fallback; see the app-group prefix defect under Task 7.13 and `docs/live-evidence/2026-08-18-app-group-prefix.md`.)* **Remaining:** only the live `SecItem` round-trip, which runs on a signed/entitled host (Task 6.0). The refresh path itself — builder, response decoding, async reconciliation, cross-process arbitration, and now in-situ behaviour behind a real Finder mount — is complete and live-verified.

## Phase 3: File Provider Domain & Enumeration (`NSFileProviderEnumerating`)

* [x] **Task 3.1:** Write failing unit test for `NSFileProviderEnumerator` container initialization mapping remote container roots to `NSFileProviderItem`. *(Done: `FileProviderItemDescriptionTests` — backend-agnostic `FileProviderItemDescription` value type (identifier, parent, filename, size, version/etag, content type, capabilities) with `ItemIdentifier`/`ItemCapabilities`, plus `WebDAVItem` and `GraphItem` mappers and a `rootContainer` synthesizer. The `NSFileProviderItem` adapter stays a Mac-only wrapper over this type.)*
* [x] **Task 3.2:** Implement root and child item enumeration logic in `enumerateItems(for:startingAt:)`, supporting pagination and sync anchors (`NSFileProviderSyncAnchor`, surfaced through `currentSyncAnchor(completionHandler:)`). *(Done in core: `SyncAnchor` (Data round-trip), `PageCursor`, `EnumerationPage`, and `Paginator` that walks pages until no cursor and captures the final anchor — backend fetch injected. Tested with multi-page and single-page sources.)* *(Mac adapter: `FileProviderSupport.ItemEnumerator` conforms `NSFileProviderEnumerator` over the `Paginator`, vends `FileProviderItem`s, and surfaces the final anchor via `currentSyncAnchor`; `EnumeratorAdapterTests` drive multi-page enumeration, fetch-error surfacing, and anchor plumbing with fake observers.)*
* [x] **Task 3.3:** Implement change tracking enumeration (`enumerateChanges(for:from:)`, taking an `NSFileProviderChangeObserver` and a `from:` sync anchor) handling server-side additions, modifications, and deletions. *(Done in core: `ChangeSet` — `init(from:to:)` diffs two listings by identifier + `versionIdentifier` (WebDAV, no delta API), `init(graphDelta:)` splits an oCIS delta page's live vs. `deleted`-facet items. Additions/modifications/deletions covered.)* *(Mac adapter: `ItemEnumerator.enumerateChanges` maps a `ChangeSet` onto `didUpdate`/`didDeleteItems` and finishes with the new anchor via an injected change provider; covered by `EnumeratorAdapterTests` including error surfacing.)*
* **Acceptance gate:** the enumeration scenario group — items appear in the domain without being downloaded, server-side additions/modifications/deletions are reflected, and a folder large enough to force pagination enumerates completely. *(Gate stays open — requires the Phase 6 acceptance suite on a Mac against both backends.)*

## Phase 4: File Operations & Synchronization (`NSFileProviderReplicatedExtension`)

* [x] **Task 4.1:** Write failing unit test for file hydration via `fetchContents(for:version:request:completionHandler:)`. Note the replicated contract: the extension downloads to a location **it** chooses and hands that URL back, after which the system takes ownership of the file and moves it into its own replicated store. *(Done in core: `RemoteRequestBuilderTests` drive the fetch requests; `ContentDownloaderTests` drive `ContentDownloader` — send the fetch request over a `RemoteClient`, write the body to a fresh unique temp file, return that URL; failure writes nothing.)* *(Mac adapter: `FileProviderExtension.fetchContents` builds the backend fetch request via `BackendConnection`, runs `ContentDownloader.download`, and hands the temp URL back / maps `RemoteError` to an `NSFileProviderError`.)* **Verified live 2026-08-18** (`docs/live-evidence/2026-08-18-classic-roundtrip.md`): on the signed/installed build against the Classic fixture, `Documents/Example.odt` hydrated through the extension and was **byte-exact** (SHA-256 `d617ccd9…cb326f`) against a direct WebDAV GET. → `[x]`.
* [x] **Task 4.2:** Implement remote item fetch and content streaming to a temporary URL returned to the system. Do **not** maintain a separate long-lived disk cache — the system already stores hydrated content, so a self-managed cache double-stores every file. *(Done: `ContentDownloader` streams to a chosen temp URL with no self-managed cache; wired into `fetchContents` above. `BackendConnection` shapes the per-backend fetch request — Classic path-addressed, oCIS `/items/{id}/content`.)* **Verified live 2026-08-18** (same round-trip as 4.1): the download + FileProvider hand-off ran on the signed/installed app with a real Keychain credential, producing byte-exact content. → `[x]`. (oCIS's `/items/{id}/content` path stays covered by unit tests only — no OIDC fixture.)
* [x] **Task 4.3:** Write failing unit test for local file modification detection and upload queuing. *(Done: `UploadQueueTests` — enqueue new/modified (version differs), skip unchanged, dedupe already-pending, FIFO dequeue, re-enqueue after a post-dequeue change.)*
* [~] **Task 4.4:** Implement the push synchronization handlers of `NSFileProviderReplicatedExtension` — `createItem(basedOn:fields:contents:options:request:completionHandler:)`, `modifyItem(_:baseVersion:changedFields:contents:options:request:completionHandler:)` and `deleteItem(identifier:baseVersion:options:request:completionHandler:)` — routing requests to either WebDAV or oCIS backends. *(Done in core: `RemoteRequest` + `WebDAVRequestBuilder` (PUT/MKCOL/DELETE/MOVE, `If-Match` for optimistic concurrency, `Destination`/`Overwrite: F` on move) and `GraphRequestBuilder` (PUT `/content`, DELETE item, POST `/children` folder with `conflictBehavior: fail`), plus `UploadQueue`. These are the routed requests each handler issues.)* *(Done 2026-08-17: `BackendConnection` now exposes the push request shaping per backend — `createFileRequest`/`createDirectoryRequest`/`modifyContentsRequest(path:…)`/`deleteRequest(path:)`/`moveRequest` for Classic (path-addressed) and `modifyContentsRequest(itemID:…)`/`deleteRequest(itemID:)`/`createFolderRequest` for oCIS (ID-addressed), 10 tests. `FileProviderExtension.deleteItem` is wired end-to-end: it issues the backend DELETE over the `RemoteClient` and reports success / a mapped `NSFileProviderError` — no metadata read-back needed for delete. Signed `xcodebuild` BUILD SUCCEEDED.)* *(Done 2026-08-17: **oCIS `createItem` wired end-to-end.** `GraphRequestBuilder` gained root-relative variants (`uploadNewFileUnderRoot`, `createFolderUnderRoot`) and `BackendConnection.createItemRequest(parentID:name:isDirectory:)` makes the two routing decisions in one tested place — root (`root` segment) vs. a specific parent, and folder (POST `/children`) vs. file (PUT `:/name:/content`), 6 tests. `FileProviderExtension.createItem` routes on backend: for oCIS it shapes the request, streams the file body (or the folder JSON), decodes the returned driveItem via `GraphJSONDecoder.decodeItem`, and hands back a reconciled `FileProviderItem`; `RemoteError` → `NSFileProviderError`. Signed `xcodebuild` BUILD SUCCEEDED.)* *(Done 2026-08-17: **Classic `createItem` wired end-to-end.** Since a WebDAV `PUT`/`MKCOL` returns no metadata body, `WebDAVRequestBuilder.properties(path:)` (Depth:0 PROPFIND, same prop body as `enumerate`, 2 tests) and `BackendConnection.readBackRequest(path:)` + `readBackItem(fromPropfind:parentIdentifier:)` (parse the single item via `WebDAVMultiStatusParser`, `nil` on empty multistatus, 3 tests) give the create a metadata read-back. `FileProviderExtension.createItem` now routes per backend into `createItemOCIS` (reconciles from the returned driveItem) / `createItemClassic` (write → Depth:0 read-back → reconcile the server-assigned id + etag; `.serverUnreachable` if the read-back is empty). Signed `xcodebuild` BUILD SUCCEEDED.)* *(Done 2026-08-17: **`modifyItem` content edits wired for both backends.** The core sync operation — a content change — routes on `changedFields.contains(.contents)`: the base version's `contentVersion` token becomes the `If-Match` etag (optimistic concurrency), then `modifyContentsOCIS` reconciles from the returned driveItem and `modifyContentsClassic` PUTs then reuses the Depth:0 read-back for the new etag (`.serverUnreachable` if empty). Request shaping (`modifyContentsRequest(path:/itemID:)`) and the read-back were already tested; the handler is thin Mac-only adapter over them. Signed `xcodebuild` BUILD SUCCEEDED.)* *(Done 2026-08-17: **rename/move via `modifyItem` wired for both backends.** `GraphRequestBuilder.move(driveID:itemID:newName:newParentID:)` (PATCH with `name` + optional `parentReference.id`; `PATCH` added to `HTTPMethod`; 2 tests) gives oCIS the ID-addressed counterpart of Classic's WebDAV `MOVE`, exposed via `BackendConnection.moveRequest(itemID:newName:newParentID:)` (1 test). `modifyItem` now branches: content edits as before, else `.filename`/`.parentItemIdentifier` route to `moveItem` — Graph PATCH reconciling from the returned driveItem for oCIS, WebDAV MOVE + Depth:0 read-back for Classic, sending the reparent target only when the parent actually changed. Signed `xcodebuild` BUILD SUCCEEDED.)* *(Done 2026-08-17: **combined content-edit + rename in one `modifyItem` call.** Previously such a call applied only the content edit and silently dropped the rename; now the handler applies content-first-then-rename — the content PUT targets the item's current address (keeping the Classic path valid), then the move relocates it, and the move's reconciled item (the final server state) is returned. Neither backend offers a truly atomic combined op, so this is the correct sequential decomposition. Signed `xcodebuild` BUILD SUCCEEDED.)* **Live exercise done for Classic (2026-08-18, `docs/live-evidence/2026-08-18-classic-roundtrip.md`):** on the signed/installed build against the fixture, `createItem` (local create → server HTTP 201, byte-exact), `modifyItem` content edit (server reflected new bytes), `deleteItem` (server GET → 404), and `modifyItem` rename/move (`rename-src.txt` → 404, `rename-dst.txt` → 200) all round-tripped through the real extension. **Stays `[~]`** because the genuinely untested remainder is real: the **conflict mechanism** (the Phase 4 open question — not exercised), the **oCIS** path (ID-addressed; needs an OIDC fixture), and server→client change enumeration (lagged the observation window in this run). Note: Classic operations address items by path (the identifier is treated as a server-relative path), while enumeration maps the identifier to `oc:id` — the path-vs-`oc:id` reconciliation held under the live create/modify/delete above. **oCIS push leg exercised live 2026-08-19 (Task 7.13's mount) and it FAILS — two concrete bugs, both here rather than in the sign-in layer.** Once the fixture's access log was turned on (`OCIS_LOG_LEVEL=info`; it defaults to `error`, so successful requests log nothing and these were invisible), a write into a real oCIS mount showed: **(1)** `PUT /graph/v1.0/drives/{drive}/root:/{name}:/content` → **404**, as does the item-addressed `…/items/{rootID}:/{name}:/content`, while `PUT /dav/spaces/{drive}/{name}` → **201** and the file then appears in the Graph children listing — i.e. oCIS 8.2.0 does not serve the Graph content-upload path `GraphRequestBuilder.uploadNewFileUnderRoot`/`.uploadNewFile` emit, and the **WebDAV spaces route is the working one** (the same class of defect as the `/root/children` enumerate 404 already fixed in #15); **(2)** `GET /graph/v1.0/drives/{drive}/items/NSFileProviderWorkingSetContainerItemIdentifier/children` → **404** — `NSFileProviderItemIdentifier.workingSet` is passed straight through as an item id instead of being mapped, the way `.rootContainer` already is mapped to the drive id. Net effect: **no file written into an oCIS mount currently reaches the server**, even though the account, mount, enumeration and token refresh are all proven working (Task 7.13). **Both bugs are fixed under Task 4.5**, which replaced the whole Graph file-operation layer with per-space WebDAV; the oCIS push leg is now proven live end-to-end there. What keeps *this* task `[~]` is the remainder that was never oCIS-specific: the **conflict mechanism**, and server→client change enumeration.
* [x] **Task 4.5:** Route all oCIS file/folder sync over each space's own WebDAV endpoint, leaving Graph for space discovery only. **Why:** Task 4.4's live oCIS failure was not a wrong endpoint to be corrected one URL at a time — oCIS 8.2.0 does not serve the Graph content endpoints this code targeted at all (`PUT …/root:/{name}:/content` **404**, item-addressed variant **404**, `GET …/root/children` **404**, already worked around once in #15). `owncloud/client` shows the intended shape: its entire Graph layer is one drives job, and `Space::webDavUrl()` feeds the *same* PROPFIND/PUT/MKCOL/MOVE/DELETE jobs Classic uses — there is no oCIS conditional in its sync path. *(Done: `SpaceWebDAVEndpoint` derives the addressing base and normalises the space root, with a server-reported `root.webDavUrl` preferred over the derivation. `WebDAVItem`/`WebDAVMultiStatusParser` gained `oc:file-parent` + `oc:name` (both optional, so Classic is untouched), and a second mapper `FileProviderItemDescription(ocisWebDAVItem:driveID:)` sits beside the path-based one. `BackendConnection`'s oCIS branch now emits WebDAV for every operation, so create/modify/move reconcile through a Depth:0 read-back exactly as Classic does — the point of the change. The dead Graph layer is **deleted**, not left behind: `GraphRequestBuilder` keeps only `listDrives()`, and `GraphEnumerationSource`, `EnumerationPage.init(graphCollection:)` and `init(graphItem:)` are gone.)* **Two divergences from `owncloud/client`, both forced by live evidence:** (1) **addressing is by id, not path** — oCIS accepts any `oc:fileid` as `/dav/spaces/{fileID}` and the id survives rename *and* reparent, so oCIS identifiers are stable ids and never go stale the way Classic's paths do; only *create* is name-based, under its id-addressed parent. (2) the base is the **`/dav/spaces` collection**, not `/dav/spaces/{driveID}`: a fileid already begins with the drive id and is its *sibling*, verified as `PROPFIND /dav/spaces/{fileID}` → **207** vs `…/{driveID}/{fileID}` → **404**. *(Also fixed here: the framework's three **reserved** identifiers were being sent as addresses. `ItemIdentifier.resolvedContainer` maps `.workingSet` onto the root, answers `.rootContainer` synthetically, and returns `nil` for `.trashContainer` — which is refused rather than mapped to the root, because mapping it would present every live file as trashed and let "Put Back"/"Empty Trash" act on real data. Both `enumerator(for:)` **and** `item(for:)` resolve; `item(for:)` was the one actually producing the repeating `PROPFIND /dav/spaces/NSFileProviderTrashContainerItemIdentifier` → 404.)* **Verified live 2026-08-19** on the signed/installed build against the oCIS fixture with `OCIS_LOG_LEVEL=info`: create folder → `MKCOL` **201**; write file → `PUT` **201**; rename and reparent → `MOVE` **201** (id unchanged); read → `GET` **200**; edit → `PUT` **204**; delete → `DELETE` **204**. Each step confirmed **server-side by an independent `curl`**, not just in Finder — the edited file returned its exact bytes over `GET` (**200**) and **404**ed after the delete. The access log for that window contains **zero** 4xx/5xx, **zero** Graph file-operation requests, and **zero** reserved-identifier requests; Graph's only appearance is `me/drives` **200**. Headless: 441 unit tests / 0 failures, and 4 new live legs in `BackendContractTests` (`root.webDavUrl` reported and agreeing with the derivation; Depth:1 children all carrying `oc:id`; a top-level child parenting to `.rootContainer`; and a full MKCOL→PUT→PROPFIND→MOVE→GET→DELETE round trip asserting the **fileid is unchanged across a combined rename+reparent**). → `[x]`. **Trap worth recording:** the first two "verification" runs were invalid — `make install` had deployed a **stale** bundle (`rm -rf` + `cp -R` left an older copy whose dylib still contained the deleted Graph paths), and macOS additionally caches the registered appex. Comparing built-vs-installed **sha256** exposed it; `pluginkit -r`/`-a` forces re-registration. Byte-identical binaries are now the precondition for trusting any live evidence here.
* **Acceptance gate:** the content scenario group — hydration on read, upload of locally created files, rename/move, delete, the conflict scenario, and the large-file and many-files throughput scenarios. *(Gate stays open — requires the Phase 6 acceptance suite on a Mac against both backends.)*

## Phase 5: UI & Extension Lifecycle Integration

* [~] **Task 5.1:** Implement `NSFileProviderManager` domain setup, connection, and user sign-in flow initialization. **Prerequisite:** on macOS the extension is only discovered and launched when the containing app resides in `/Applications` (or `~/Applications`), or FileProvider testing mode is enabled. Launched straight from Xcode's DerivedData, `add(domain:)` reports success and Finder silently shows nothing. (Deployment behaviour rather than documented API — reconfirm on the Mac.) *(Done in core: `AccountSetupTests` drive `BackendDetector` (oCIS via OIDC discovery, Classic via a parseable installed `status.php`, OIDC wins ties), `AccountDescriptor` (stable `domainIdentifier`, `user@host` display name), and `DomainRemovalChoice` (default preserves downloads).)* **Verified live 2026-08-18** (`docs/live-evidence/2026-08-18-classic-roundtrip.md`): the `NSFileProviderManager.add(_:)` call, `NSFileProviderDomain` construction, and the `~/Applications` discovery prerequisite all worked on the signed/installed build — the `admin@localhost` domain mounted and enumerated in the CloudStorage location. (Also driven through the settings Add Account flow under Task 7.11, already `[x]`.) The Mac-only adapter is proven for Classic; oCIS domain add awaits an OIDC fixture. **Superseded in part by Phase 7:** the user-facing half of this task (who calls `add`/`remove`, and with what identity) is designed in Tasks 7.1–7.5 — the domain identifier changes from `AccountDescriptor.domainIdentifier` to `SyncRoot.domainIdentifier` there, so do Task 7.1 before extending this one.
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

* [~] **Task 6.0 (spike, do first):** prove on a GitHub-hosted macOS runner that a
  trivial File Provider domain can be added and enumerated at all — the containing app
  copied to `/Applications` (Task 5.1's prerequisite), a signing identity the runner
  accepts, and the extension actually loading in the runner's session. None of this is
  documented by Apple; it is make-or-break for AC-2's end-to-end tier. If it fails, that
  tier moves to a self-hosted Mac and AC-2 is rewritten accordingly.
  * **The make-or-break question is answered YES (locally, 2026-08-18):** on a signed,
    installed build (`~/Applications`, `codesign --verify --deep --strict` OK, both `.appex`
    registered per `pluginkit`), a File Provider domain **was added and enumerated** against
    the Classic fixture, and the full data path round-tripped byte-exact — hydration, create,
    modify, delete, rename (`docs/live-evidence/2026-08-18-classic-roundtrip.md`). So the
    extension loads, mounts, and drives real I/O on a signed macOS build. **Stays `[~]`** for
    the one thing this did *not* prove: the same on a **GitHub-hosted** runner (signing
    identity the runner accepts + the extension loading in a headless CI session). That
    hosted-runner leg is the remaining open question; feasibility on a Mac is no longer in
    doubt, so if the hosted runner can't do it, the fallback (self-hosted Mac) is viable.
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
    type. **Fixture-state action bodies done + proven live (2026-08-18, Classic):**
    `ClassicBackendAdmin` performs the server-side operations the acceptance Given/When steps
    drive — `createFile(path:contents:)` (WebDAV PUT), `createFolder(path:fileCount:)`
    (MKCOL + N distinctly-named PUTs, the "folder containing N files" fixture), and
    `deleteFile(path:)` (DELETE) — pure orchestration over an injected `RemoteClient`
    (4 headless `ClassicBackendAdminTests`, a non-2xx propagates as `RemoteError` so a failed
    provisioning step never no-ops silently). `ClassicBackendAdminContractTests` runs it
    against the **live** Docker fixture (gated on `OWNCLOUD_TEST_BACKEND=classic`, wired into
    the classic CI leg's `--filter`): create → server 200 byte-exact, delete → 404, folder →
    exactly N children by PROPFIND. So the *automatable* half of the harness — provisioning
    the fixture through the backend — is proven end to end. **Blocked (still `[~]`):** the
    domain lifecycle helper wraps `NSFileProviderManager` (Mac-only) and the
    materialisation-state observer is the task's open question — both need a Mac; and the
    oCIS `BackendAdmin` fixture-state bodies await an OIDC-capable fixture.
    Content upload for fixtures reuses the Phase 4 WebDAV/Graph builders already in place.
* [~] **Task 6.4:** the Gherkin layer — `.feature` files kept close to the client's
  wording so they stay diff-comparable, a small Gherkin parser/runner in the test target,
  and the step library mapping steps onto Task 6.3's harness. Port the first scenarios
  from the appendix.
  * **Loop status:** the parser is done and fully tested headlessly — `GherkinParser`
    (feature/background/scenario/scenario-outline, tags, `And`/`But` continuation, examples
    table + `expanded()`), 8 tests green. First scenarios ported to
    `test/features/enumeration.feature` (4 enumeration scenarios seeded from `tst_syncing`),
    verified to parse. **Step-matching engine + catalog done test-first (2026-08-18, 11 tests):**
    `StepPattern` compiles a Cucumber-expression pattern (`{string}` → quoted-run capture,
    `{int}` → integer capture; literal spans regex-escaped so wording metacharacters match
    themselves) to an anchored `NSRegularExpression`; `StepRegistry` dispatches a `GherkinStep`
    to exactly one pattern, raising `StepMatchError.undefined`/`.ambiguous` so an unimplemented
    or overlapping step fails loudly. `AcceptanceStepCatalog` holds every step pattern the
    committed feature files use, and `AcceptanceStepCatalogTests` parses the real
    `test/features/*.feature` (outlines expanded) and asserts **every step matches exactly one
    catalog pattern** — so a scenario referencing undefined/ambiguous wording is caught in the
    headless loop, not on the Mac. **Scenario-runner orchestration done test-first (2026-08-18,
    5 tests):** `ScenarioRunner` walks a parsed scenario's steps in order, matches each through
    the `StepRegistry`, and invokes the action bound to the matched pattern via an injected
    `ActionLookup` closure — stopping at the first failure and surfacing all three failure modes
    (undefined step, matched-but-unbound pattern, action throw) rather than swallowing them; it
    reports a `Result` (outcome + the step texts that executed). The action closures are injected,
    so sequencing / argument-passing / fail-fast are proven with a stub action. **Classic
    server-side bindings done test-first (2026-08-18, 7 tests):** `ClassicStepBindings` is the
    join between the three previously-disconnected pieces — it maps the catalog's four
    fixture-state patterns (`the server has a file {string}`, `… a folder {string} containing
    {int} files`, `a file {string} is created on the server`, `the file {string} is deleted on
    the server`) onto the Task 6.3 `ClassicBackendAdmin` calls, exposed as the exact
    `ScenarioRunner.ActionLookup` the runner consumes. Driving a real `ScenarioRunner` over the
    catalog registry + these bindings against a stub transport proves a scenario's Given/When
    server steps issue the right WebDAV requests in order (PUT/MKCOL+PUTs/DELETE), a server error
    fails the run, and Mac-only steps (`the domain is enumerated`) stay unbound so the runner
    reports `no action bound` rather than the binding layer silently swallowing them. So for
    Classic, the whole chain feature-text → parse → match → dispatch → WebDAV request is now pure
    and proven headlessly. **Blocked:** the remaining *action bodies* — the Mac-only
    domain-lifecycle + materialisation-assertion steps (drive `NSFileProviderManager`) and the
    oCIS server-side bindings (need an OIDC fixture) — stay Mac + Docker + signing gated.
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

* [~] **Task 7.0 (verify first, cheap, do before writing code):** resolve the five
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
  * **Loop status — findings recorded from documentation + prior art; live
    confirmation on a Mac remains.** Each of the five is a runtime behaviour that
    cannot be reduced to a unit test, so the derivable answer is recorded here and
    the code is written to be *correct either way* (the posture the task itself
    prescribes for (a)). What is left is observing each on a signed, `/Applications`-
    installed app — the Task 6.0 spike environment.
    * **(a) Process sharing — assume NOT shared; lock is required, not merely
      harmless.** Apple documents no guarantee that multiple domains of one provider
      share a process, and `fileproviderd` is free to spawn per-domain instances. So
      the N-instances-over-one-rotating-token race (Task 7.6) is treated as real: the
      cross-process `flock` in `FileLock`/`FileLockInstanceLock` arbitrates regardless
      of whether the instances turn out to share an address space. Building it either
      way is exactly what the task asked; the live check only decides whether it was
      strictly necessary, not whether it is safe. **Confirm on Mac:** log the pid in
      `beginRequest(with:)` across two mounted spaces.
    * **(b) `NSExtensionFileProviderActions` on a sidebar domain row — treat as
      unavailable on macOS; do not depend on it.** Apple's key page enumerates
      iOS/iPadOS/visionOS only. Nextcloud ships these actions on macOS, but for
      *item* context menus, not the *domain sidebar row* — no documented evidence the
      row itself shows them. Decision: the "Settings…" affordance is **not** relied
      on; configuration is reached by opening the app directly (which is also the
      Task 7.9 launcher path). If the live check shows the row honours them, it
      becomes a pure enhancement. **Confirm on Mac:** right-click a domain row.
    * **(c) System Settings deep-link — `x-apple.systempreferences:` URL, pane
      confirmed derivable.** The Login Items & Extensions pane (which hosts the
      per-provider File Provider toggles on macOS 13+) opens via
      `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`. This is
      what `DomainEnablementStatus.settingsPaneURL` returns (Task 7.8) and what the
      settings window's "Open System Settings" link uses. **Confirm on Mac:** the
      exact anchor that scrolls to the *File Provider* subsection (the pane opens; the
      subsection anchor is the only unverified part).
    * **(d) `NSExtensionFileProviderAllowsUserControlledEviction` — set to `true`,
      behaviour to confirm.** Undocumented by Apple; read from Nextcloud's shipping
      `FileProviderExt/Info.plist` and corroborated by the `tst_vfs` eviction seed
      scenarios (appendix). Added to `FileProviderExtension/Info.plist` inside the
      `NSExtension` dict (Task 7.9). A wrong assumption here only affects whether the
      Finder "Remove Download" menu item appears — never sync correctness — so it is
      safe to ship and confirm live. **Confirm on Mac:** materialise a file, then
      check for "Remove Download" in its Finder context menu.
    * **(e) ~12 domains in the Finder sidebar — no code impact found; watch resource
      cost.** Each space is one `NSFileProviderDomain`, and the design already treats
      the system domain list as the source of truth (Task 7.4), so nothing in the code
      caps or specially-cases the count. The open risk is purely operational (sidebar
      clutter, per-domain memory/daemon cost), not correctness. **Confirm on Mac:**
      mount ~12 spaces and observe sidebar behaviour + `fileproviderd` footprint.
* [x] **Task 7.1:** the identity split — headless, and it fixes a live bug.
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
  * **Done:** `AccountDescriptor.domainIdentifier` renamed to `accountIdentifier`
    (same encoding, no Keychain migration); `SyncRoot` (account + optional `driveID`)
    owns `domainIdentifier` as `"<driveID>|<accountIdentifier>"`; `DomainDisplayNamer`
    disambiguates collisions (unique name verbatim → account-qualified → drive-id-
    qualified). All tests written first: SyncRoot round-trip (oCIS/Classic empty head),
    `driveID`-with-`|` rejection, unparseable-tail rejection, `|`-in-username regression,
    and the three `DomainDisplayNamer` collision cases. **Live bug fixed:** the
    extension now parses a `SyncRoot` and passes its real `driveID` into
    `BackendConnection` instead of hardcoding `nil`. Fully headless (`swift test` green).
* [x] **Task 7.2:** the space catalog. Add `GraphRequestBuilder.listDrives()` for
  `GET /graph/v1.0/me/drives` — the endpoint `BackendContractTests.swift:54` currently
  hits with a hand-built URL, so there is no builder for it yet — and a `SpaceCatalog` /
  `Space` value type (drive id, name, `driveType`, quota) mapped from the existing
  `GraphJSONDecoder.decodeDriveList`. Classic's catalog is the single files root.
  * *Test first (unit):* decode a real drive-list fixture covering personal, project and
    shared types plus quota. *Then (backend-contract tier, both backends):* fetch the
    catalog from live oCIS with spaces provisioned through the Graph API per AC-1, and
    assert a space the token cannot see never appears.
  * **Done (unit):** `GraphRequestBuilder.listDrives()` + `Space`/`SpaceCatalog`
    (Codable) mapped from `GraphJSONDecoder`, with `SpaceCatalog.classic` as the single
    "All files" root. Drive-list decode tested. **Remaining for the live half:** the
    backend-contract-tier fetch against live oCIS (token-visibility assertion) rides the
    Mac + Docker tier (Task 6.3), so the *unit* half is `[x]`-equivalent and the live
    assertion is tracked with the contract suite.
* [x] **Task 7.3:** persistence — headless, over an injectable store seam like
  `KeychainBackend`. An `AccountRegistry`: one `UserDefaults` key in
  `group.com.owncloud.macos.fileprovider` holding JSON-encoded `[AccountRecord]`
  (accountIdentifier, backend, serverURL, username). Credentials stay in the Keychain
  untouched. Plus a display-only space-catalog cache (JSON in the app group container) so
  the settings window renders instantly and offline. The registry exists for exactly one
  reason: an account with **zero** spaces selected has no domains and would otherwise
  vanish. The cache is never authoritative.
  * *Test first:* Codable round-trip, corrupt-blob tolerance (the posture
    `KeychainCredentialStoreTests` already sets), and empty/absent-key defaults.
  * **Done:** `KeyValueStore` seam (`UserDefaultsKeyValueStore` production adapter),
    `AccountRegistry` (one JSON blob under `com.owncloud.macos.fileprovider.accounts`,
    corrupt/absent → `[]`, upsert-in-place), and a display-only `SpaceCatalogCache`
    (per-account key, miss/corrupt → `nil`). All test-first over an in-memory fake
    store: round-trip, corrupt-blob tolerance, empty/absent defaults. Fully headless.
* [x] **Task 7.4:** `DomainReconciler.plan(registry:existing:intent:)` →
  `(add, remove, orphans)` — a pure function, the pattern `BackendDetector` and
  `Paginator` already establish. **The system's domain list is the source of truth for
  the selection**; `getDomainsWithCompletionHandler` already persists across launches and
  propagates to the extension, so there is no parallel "selected spaces" list to keep in
  sync. (Nextcloud ships `resetVfsForAccount` precisely because their state can drift.)
  Orphans are domains whose account is absent from the registry — a leftover install, or
  an account removed while the app was closed.
  * *Test first:* add, remove, no-op, orphan, zero-space account, account-removed-while-closed.
  * **Done:** `DomainReconciler.plan(registry:existing:intent:)` → `DomainPlan`
    (`add`/`remove`/`orphans`), a pure function. `add` = intent not in existing;
    existing whose account is unknown to the registry → `orphans`; existing known but
    not in intent → `remove`. All six cases tested (add, remove, no-op, orphan,
    zero-space account, account-removed-while-closed). Fully headless.
* [x] **Task 7.5:** the Mac-only `DomainService` adapter over `NSFileProviderManager`:
  `getDomainsWithCompletionHandler` → `[SyncRoot]`, `add(_:)`, `remove(_:mode:)` driven by
  `DomainRemovalChoice.removalMode`, and orphan removal **only on confirmation, never
  silently**. Enforce single-instance for the app so two copies cannot reconcile
  concurrently (Nextcloud ships `singleinstancemanager_mac` for the same reason). Ordering
  matters and is specified so any crash leaves recoverable state — the registry brackets
  the domain lifetime: on add, write the account record *before* adding domains (a
  zero-space account is legal); on removal, remove domains → delete credentials → delete
  the record *last* (an orphan domain is detectable; a missing credential just reads as
  "signed out").
  * **Done (headless core):** `DomainService` (in `OwnCloudCore`) orchestrates the ordering
    over three injected seams — a `DomainManager` (get/add/remove), a `CredentialDeleter`,
    and an `InstanceLock` — so the add-writes-record-first / remove-deletes-record-last
    ordering, the orphan-only-on-confirmation rule, and single-instance guarding are all
    unit-tested (`DomainServiceTests`) without a live `NSFileProviderManager`. The Mac
    adapters (`SystemDomainManager`, `KeychainCredentialDeleter`, `FileLockInstanceLock`)
    live in `FileProviderSupport`/`DomainServiceAdapters.swift`.
  * **Verified live (2026-08-18):** the Task 7.11 round-trip exercised these adapters end to
    end on the signed, installed host — Add Account drove `addSpace` → `SystemDomainManager.add`
    → `NSFileProviderManager.add` (domain mounted in Finder), the sidebar populated via
    `existingSyncRoots` → `getDomains`, and Sign Out drove `signOut` → remove domain + delete
    credential + delete record → `NSFileProviderManager.remove` (domain + account gone). The
    record-first-on-add / record-last-on-remove ordering and the `SystemDomainManager`/
    `KeychainCredentialDeleter`/`FileLockInstanceLock` adapters all ran against the live
    system. (Orphan-only-on-confirmation and multi-instance contention remain unit-tested
    only; the concurrent-reconcile case is naturally part of the Task 6.3 fixture tier.)
* [~] **Task 7.6:** credential-refresh arbitration — **this is a real bug created by the
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
  * **Done:** `SessionManager.refreshTokenIfNeeded()` now arbitrates through an injected
    `RefreshLock` seam: with a lock configured it double-checks under the lock (a winner
    that refreshed while we waited short-circuits) and, on a refresh *failure*, re-reads
    once — a concurrent winner's fresh token counts as success rather than surfacing
    `.notAuthenticated`. No lock → direct refresh (single-instance app / Basic auth).
    `FileLock` (a `flock`-backed `RefreshLock` over the app-group container) is the
    production conformer; `RefreshArbitrationTests` drive the winner/loser and
    failure-then-recover paths over a fake lock and the injected clock. Headless.
  * **Remaining:** the end-to-end refresh-race acceptance scenario (Task 7.10) is Mac +
    Docker gated, as is threading the live OIDC `RefreshHandler` (Task 2.5) through the lock.
* [~] **Task 7.7:** a space that disappears server-side. The extension maps a
  root-enumeration 404 onto `NSFileProviderManager.disconnect(reason:options:)` with a
  human string Finder surfaces, instead of failing every operation. It must **not** remove
  the domain — that would discard or orphan materialised files without consent. The app's
  catalog refresh flags the row; removal stays a user action. `reconnect` when the space
  returns.
  * **Done:** `SpaceAvailability.decide(forEnumeration:isRootContainer:)` is the pure
    decision — a `.noSuchItem` (404) on the *root* container → `.disconnect(reason:)` with
    a user-facing string that names no status codes and promises reconnection; a 404
    deeper in the tree, or any other error, → `.surfaceError`. Never removes the domain.
    `SpaceAvailabilityTests` cover root-404, non-root-404, and other-error. `ItemEnumerator`
    consults it and calls `disconnect`/`reconnect` on the Mac adapter.
  * **Remaining:** the live `disconnect`/`reconnect` round-trip against a deleted drive is
    Mac + Docker gated (Task 6.3 fixtures).
* [~] **Task 7.8:** the settings window — the app's *main* window, not a separate
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
  * **Done:** every rendered decision lives in tested core presenters — `SpacesTab.make`
    (checklist rows, `selectionDisabled` + the Classic "selection is an oCIS feature" note),
    `SpaceRemovalPrompt.make` (the concrete "Keep the 840 MB already downloaded" / "Remove
    them" wording via `humanizedBytes`), and `DomainEnablementStatus.make` (the `userEnabled`
    warning + `x-apple.systempreferences:` deep link) — all in
    `SettingsPresentation.swift` with `SettingsPresentationTests`. The SwiftUI shell
    (`App/Sources/SettingsWindow.swift` + `SettingsModel.swift`) is a thin `@MainActor`
    layer over those presenters and `DomainService`; it builds + `xcodebuild test` passes.
  * **Done (2026-08-19, issue #26 / PR #27): account removal is a first-class action here.**
    The window previously offered only a `Sign Out…` button that confirmed nothing, hid the
    keep-or-delete choice, and was absent from the sidebar; `AccountRemovalPrompt.make` now
    supplies every rendered string and drives **three** affordances through one confirmed
    path — the Account-tab button, a `−` button beside `Add Account…`, and a `Remove
    Account…` context menu on the sidebar row (acting on the right-clicked row, not the
    selection). `DomainService.signOut` → `removeAccount`, its crash-safe ordering unchanged.
    Live-proven on the signed build against the Classic fixture, including the on-disk
    consequence of both choices: `.preserveDownloadedUserData` leaves the sync root **renamed
    in place with a timestamp suffix** (same inode, materialized file byte-identical), while
    `.removeAll` deletes the replica outright. See the dated log entry below for the full
    evidence and for the 401 misdiagnosis it corrects.
  * **Remaining:** the **Classic** username/password sign-in is built and verified live
    (Task 7.11 — `AddAccountSheet` + `SettingsModel.addAccount`, round-trip confirmed
    2026-08-18). The **oCIS OIDC** flow's *headless core and adapters* are now built and
    tested (Task 7.12): the PKCE Authorization-Code machinery, the discovery fetch (live
    CI-proven against the oCIS fixture), and the `ASWebAuthenticationSession` presenter. What
    keeps this task `[~]` is the last mile — wiring that core into `SettingsModel`'s oCIS
    branch (redirect-scheme `Info.plist` entry, per-space drive resolution) and exercising it,
    which needs an OIDC-capable fixture (the current Docker oCIS fixture is Basic-auth only).
    Diagnostics/reset are wired but exercised only on a signed host.
    **Superseded by Task 7.13 (issue #17):** that last mile is now built — the sheet is a
    two-step `AddAccountFlow`, `SettingsModel` runs the OIDC branch, the `oc` redirect
    scheme is declared, and the shipping client registration is live-proven. What still
    keeps *this* task `[~]` is the last of the GUI leg. The **web sheet and a live oCIS
    domain mounting are now proven** (2026-08-18: a real browser sign-in from this sheet
    mounted `admin@localhost` / Infinite Scale); the cert gate is cleared and was never the
    real blocker — see the app-group prefix defect under Task 7.13. Only the server-side
    round trip through that mount is unproven.
* [~] **Task 7.9:** the UI extension stays a **launcher**, not a settings host.
  `prepare(forError:)` shows a minimal "Reconnect" sheet that opens the app at that
  account's sign-in — no second OIDC implementation inside a sandboxed appex. Separately,
  set `NSExtensionFileProviderAllowsUserControlledEviction` in the File Provider
  extension's `Info.plist`: one key buys Finder-native "Remove Download" with no code
  (pending Task 7.0(d)).
  * **Done:** the reconnect deep link is a tested core type — `AppLaunchURL`
    (`owncloud-fileprovider://reconnect?account=…`, round-trip `reconnectURL`/`parse`,
    reserved-char and rejection cases in `AppLaunchURLTests`). `ActionViewController`
    (`prepare(forError:)`) extracts the account from the error's domain identifier, shows a
    minimal Reconnect sheet, and opens the app via `NSWorkspace` — no OIDC inside the appex.
    `NSExtensionFileProviderAllowsUserControlledEviction` = true is set inside the File
    Provider extension's `NSExtension` dict, and the app declares the URL scheme in its
    `Info.plist`; `SettingsModel.handleLaunch` parses it on `onOpenURL`.
  * **Remaining:** the live sheet → app hand-off runs only on a signed, installed host.
* [~] **Task 7.10:** the acceptance scenarios for this phase, joining the Phase 5
  lifecycle group per AC-5 under AC-3's ten-consecutive-green rule: select a space →
  domain appears and enumerates; deselect preserving downloads → files remain on disk,
  domain gone; deselect with `removeAll` → files gone; sign out with two spaces selected →
  both domains removed and the credential deleted; orphan detection after a registry wipe;
  and **the refresh race** — two spaces selected, token forced to expire, both stay
  authenticated. Task 7.6 does not count as done until that last scenario exists and runs.
  * **Done:** `test/features/configuration.feature` (`@configuration`, joining the Phase 5
    lifecycle group) carries all six scenarios — the space-selection ones tagged `@ocisOnly`
    with the AC-1 difference stated, sign-out and orphan detection untagged (both backends),
    and the refresh-race scenario present. `ConfigurationFeatureTests` parse it with the
    tested `GherkinParser` and assert the tag, all six flows, the `@ocisOnly` tagging, and
    the refresh-race step shape — so the artifact can't silently degrade.
  * **Remaining:** the runner + step library that drive these against live Docker fixtures
    are Mac + Docker gated (Task 6.3).
* [x] **Task 7.11:** the Classic sign-in flow that closes the Task 7.8 gap. Before this the
  only path that ever seeded a credential and mounted a domain was `DevHarness` (DEBUG-only),
  which writes the Keychain and calls `NSFileProviderManager.add` directly — never touching
  `AccountRegistry` — so on a real `make install` launch the settings sidebar was empty and
  "Add Account…" was a stub. Now the settings window's "Add Account…" probes the server,
  resolves the backend, writes the Basic credential to the shared Keychain, and adds the
  domain through `DomainService` (which records the account in the registry *first*, so it
  appears in the sidebar and its space/sign-out actions work). oCIS OIDC sign-in stays out of
  scope here, rejected with a typed error the sheet renders rather than a silent failure.
  * **Done (headless):** `SignInResolver` turns raw fields + a `BackendProbeResult` into a
    resolved account/credential/sync-root or a typed `SignInError` — every decision
    (trim/normalize, `http://` prepend for schemeless hosts, `BackendDetector` choice,
    `.basic` credential, nil-drive `SyncRoot`, oCIS rejection). Seven `SignInResolverTests`
    pin it (RED → GREEN), part of the 311-test Linux-buildable suite.
  * **Probe proven live (CI on every PR):** `HTTPServerProbe` (GET
    `/.well-known/openid-configuration` → OIDC signal; GET `/status.php` → Classic signal;
    any non-2xx/error is the negative signal) is now covered by `ServerProbeContractTests` —
    a live contract tier that probes the real Docker Classic fixture and feeds the result
    through `SignInResolver`, asserting it resolves a Classic Basic account. It joins the
    existing backend-contract job (`swift test --filter 'BackendContract|ServerProbeContract'`,
    gated on `OWNCLOUD_TEST_BACKEND=classic`, self-skips on the oCIS leg). The probe carries no
    FileProvider dependency, so it builds and runs on the Linux CI runner too.
  * **Mac-gated UI (built + verified live):** the `SettingsModel.addAccount` wiring and the
    `AddAccountSheet` view. The Finder round-trip was run on 2026-08-18 against the local
    Classic fixture (`make install`, launch, Add Account `http://localhost:8080` admin/admin):
    the account appeared in the sidebar, the domain mounted in Finder and enumerated, and Sign
    Out removed both the domain and the account — the full lifecycle round-tripped. This is the
    live check that promotes the task to `[x]`.
* [~] **Task 7.12:** the **oCIS OIDC sign-in** headless core + adapters — the counterpart of
  Task 7.11 for the Infinite Scale backend, closing the OIDC half of the Task 7.8 gap. The
  whole Authorization-Code + PKCE flow is built as pure, Linux-buildable core with the two
  outside-world touchpoints (discovery fetch, browser presentation) injected as closures, so
  the decision logic is fully headlessly tested.
  * **Done (headless, TDD RED→GREEN):**
    * `SHA256` — a dependency-free FIPS-180-4 implementation (the package stays
      Foundation-only; no swift-crypto), pinned to the published FIPS/RFC vectors incl. the
      one-million-'a' case (`SHA256Tests`).
    * `PKCE` — RFC 7636 verifier generation + `S256` challenge (base64url-no-pad of
      SHA-256(verifier)), pinned to the RFC 7636 Appendix B worked example (`PKCETests`).
    * `OIDCConfiguration` — parses the `/.well-known/openid-configuration` discovery document
      into issuer + authorization/token endpoints, rejecting non-JSON / missing endpoints
      (`OIDCDiscoveryTests`).
    * `OIDCAuthorizationRequest` — builds the authorize URL (`response_type=code`, PKCE
      `S256`, state) and parses the redirect callback, validating `state` *before* the code,
      surfacing server `error`, and rejecting a code-less callback (`OIDCAuthorizationTests`).
    * `OIDCTokenRequestBuilder.exchange` — the `grant_type=authorization_code` POST redeeming
      the code with the PKCE `code_verifier` (`OIDCCodeExchangeTests`), sharing the form
      encoder with the already-built `refresh` grant.
    * `OIDCSignInCoordinator` — composes all of the above into one async `signIn(serverURL:)`
      returning `.bearer` credentials + the discovered configuration (so refresh — Task 7.6 /
      2.5 — wires to the same token endpoint). State/verifier/`now`/`fetchDiscovery`/
      `authorize`/`sendToken` are all injected, so the happy path and the state-mismatch abort
      are deterministic (`OIDCSignInCoordinatorTests`). Now also surfaces the raw `id_token`
      from the token response (`OIDCTokenResponse.idToken(from:)`) so the account can be named.
    * `OIDCIDToken` — reads the account-identity claims out of the `id_token` JWT
      (`preferred_username` → `email` → the mandatory `sub`), base64url-decoding the payload
      *without* verifying the signature (the token arrives over TLS inside the code exchange
      and is used only to name the account for display — never for authorization; the
      `access_token` is the bearer credential). Pinned to the jwt.io external vector + malformed
      cases (`OIDCIDTokenTests`).
    * `OCISSignInResolver` — the oCIS counterpart of `SignInResolver`: turns a completed sign-in
      (server + bearer credential + `id_token` + `me/drives` listing) into an
      `AccountDescriptor(.ocis)` named from the claims, the bearer `Credentials` to store, one
      `SyncRoot` per space, and the `SpaceCatalog` for the Spaces tab — rejecting non-bearer
      credentials and an empty drive list with typed errors (`OCISSignInResolverTests`). This is
      the pure "per-space drive resolution / account identity" step the Mac wiring below plugs into.
  * **Discovery proven live (CI on every PR):** `HTTPOIDCDiscovery` (the oCIS sibling of
    `HTTPServerProbe`) GETs the live IDP's discovery document and parses it. `OIDCDiscoveryContractTests`
    runs it against the Docker oCIS fixture — asserting the endpoints come back on the fixture
    host — and joins the backend-contract job (`swift test --filter
    'BackendContract|ServerProbeContract|OIDCDiscoveryContract'`, gated on
    `OWNCLOUD_TEST_BACKEND=ocis`, self-skips on the Classic leg). Verified green locally on
    2026-08-18 against `https://localhost:9200`.
  * **Whole sign-in chain proven live against the real IDP (2026-08-18, `docs/live-evidence/2026-08-18-ocis-oidc-signin.md`):**
    the earlier assumption that this needed a separate "OIDC-capable fixture" was only partly
    right — the Docker fixture's IDP (Konnect) *is* a full OIDC provider, and its interactive
    login sits in front of a scripted JSON logon API (the standard browser-automation seam). So
    `OCISSignInContractTests` drives the **production** `OIDCSignInCoordinator.signIn` end to end
    against `https://localhost:9200`: live discovery → authorize URL + PKCE `S256` → (browser
    step scripted via Konnect logon) → state validation + code extraction → `exchange` code→token
    (real `access_token` + `refresh_token` + `id_token`, `Bearer`, `expires_in=300`) → the real
    bearer token authorizes `GET /me/drives` (2 drives) via `DriveResolver`'s client path →
    `OCISSignInResolver` yields a `.ocis` account named from the claims (`preferred_username=admin`),
    one sync root per space, a 2-space catalog → the `refresh_token` grant renews the credential.
    1 test passed live; wired into the oCIS backend-contract CI leg's `--filter`
    (`…|OCISSignInContract|…`, gated on `OWNCLOUD_TEST_BACKEND=ocis`, self-skips elsewhere). This
    is genuine live proof of the sign-in *protocol + decision* layer — not just discovery.
  * **Mac-gated adapter (built, GUI-gated):** `WebAuthorizationPresenter` drives the
    authorization URL through `ASWebAuthenticationSession` (`#if canImport(AuthenticationServices)`),
    supplying the coordinator's `authorize` closure. Its only untested part is the system
    browser sheet itself — the same GUI gate as the Classic Finder round-trip (the contract test
    above scripts the logon in its place).
  * **Remaining (keeps `[~]`):** what is genuinely *not* yet exercised is the Mac-host + GUI
    remainder — the AppKit web sheet (`WebAuthorizationPresenter`), the `SettingsModel` oCIS
    branch that calls the coordinator → `OCISSignInResolver` → persists the credential → adds one
    domain per sync root via `DomainService`, the redirect-scheme `Info.plist` entry, and a live
    oCIS domain mount in Finder. Those need the Mac FileProvider host (Task 6.0 tier), not the
    IDP — which is now proven. So the OIDC protocol/decision layer is done and live-verified; the
    SwiftUI glue + Finder mount stay `[~]`.
    **Closed by Task 7.13 (issue #17), except the server-side round trip:** the
    `SettingsModel` oCIS branch, the `Info.plist` redirect scheme and the personal-space
    domain-add are built, and the *shipping* client registration (id + secret + `oc://`
    redirect) is now what the live contract tier drives. The **AppKit web sheet is also
    live-proven** — a real browser sign-in mounted `admin@localhost` / Infinite Scale from
    the shipping sheet (2026-08-18). The System-keychain cert gate is cleared, and the note
    that it blocked this leg is withdrawn: what actually blocked it was the app-group prefix
    defect recorded under Task 7.13. Only the server-side round trip (upload visible in the
    server's listing, and a re-enumeration >5 min later) remains unproven.
* [~] **Task 7.13:** **oCIS OIDC sign-in reachable from the settings UI** (GitHub issue
  #17 — *"settings ui has no option to connect to ocis — ocis requires OIDC — username and
  password is only usable in test automation"*). Task 7.12 built and live-proved the whole
  OIDC protocol layer, but nothing in the product reached it: typing an oCIS URL into "Add
  Account" hit `SignInResolver`'s `.ocisNotSupportedYet` and rendered *"OpenID sign-in
  isn't supported here yet."* This task is the glue plus the three real gaps behind it —
  no `client_secret` support, no redirect scheme declared, and a refresh-less
  `SessionManager` in the extension that would kill an oCIS mount after
  `expires_in=300`.
  * **Client registration (decided, then proven live):** oCIS's shipped ownCloud iOS
    client (`services/idp/pkg/config/defaults/defaultconfig.go` in v8.2.0) — client id
    `mxd5OQ…OxkY1`, redirect `oc://ios.owncloud.com`, scope
    `openid profile email offline_access` — captured by
    `ASWebAuthenticationSession(callbackURLScheme: "oc")`. Its secret is a **published
    default present in every oCIS install, not a confidential credential**; RFC 8252 §8.5
    is explicit that PKCE, not the secret, protects a native client. That is said in a doc
    comment on `OCISClientRegistration` so nobody mistakes it for a secret to guard.
  * **Done (headless, TDD RED→GREEN):**
    * `client_secret` support through the token layer — `OIDCTokenRequestBuilder.exchange`
      / `.refresh` append it only when non-nil (lico takes it as a plain form field), and
      `OIDCSignInCoordinator` / `OIDCRefreshHandler.make` forward it.
      `OCISClientRegistration.ownCloudMobile` keeps the literals out of the SwiftUI layer.
    * `OCISSignInResolver.resolve(…, spaces:)` — `.personalOnly` mounts one domain (the
      `driveType == "personal"` drive, `OCISSignInError.noPersonalSpace` when absent)
      while the returned catalog still lists **every** space, so the Spaces tab can opt
      into the rest later. `.all` stays the default, preserving existing callers.
    * `SignInResolver` split in two, because the sheet cannot know whether a username is
      even wanted before it knows the backend: `route(serverURL:probe:)` →
      `.classic(serverURL:)` / `.oidc(serverURL:)`, then `resolveClassic(serverURL:
      username:password:)`. `.ocisNotSupportedYet` is deleted. (Caught while wiring the
      sheet: validating the username inside `route` would have dead-ended the Classic path
      at its own first step.)
    * `AddAccountFlow` (`.server` → `.classicCredentials` / `.authorizing`) owns the
      two-step sheet's wording, busy state and `canSubmit` rules, so the view keeps making
      no decisions.
    * `OIDCSessionStore` / `OIDCSessionRecord` — the app→extension handover of the
      *refresh parameters* (token endpoint, client id/secret, scope) over the existing
      `KeyValueStore` seam in the shared app group. The extension never runs discovery, so
      it cannot otherwise know the token endpoint. Tokens stay in the Keychain; a miss and
      a corrupt blob both read `nil` because a Classic account legitimately has no record.
    * `SynchronousTokenSender` (`FileProviderSupport`) — the blocking `URLSession` bridge
      supplying `OIDCRefreshHandler.Send`, which is synchronous by design because refresh
      runs under the cross-process `RefreshLock`. Maps `400` → `.authenticationRequired`
      *before* the general status classification, so a revoked grant reads as
      re-authenticate rather than a transient server fault.
  * **Mac glue (built, signed build green):** `SettingsModel.submitAddAccount` routes the
    probe, advances the flow, and on `.oidc` runs `signInWithOIDC` — the production
    `OIDCSignInCoordinator` over `HTTPOIDCDiscovery`, `WebAuthorizationPresenter` and
    `RemoteClient` → `listDrives` → `OCISSignInResolver(spaces: .personalOnly)` →
    Keychain credential → catalog cache → `OIDCSessionStore` → one `DomainService.addSpace`
    per sync root → `reload()`. `handleLaunch` now re-runs it for an `.ocis` account, so
    the Task 7.9 reconnect deep link actually reconnects; sign-out drops the session
    record. `AddAccountSheet` renders `AddAccountFlow`; the app declares the `oc` scheme in
    `Info.plist` (kept in sync with the registration by a comment on both sides).
  * **Extension refresh wired (the `expires_in=300` fix):**
    `FileProviderExtension.authorization(for:)` builds `SessionManager` with
    `OIDCRefreshHandler` + `SynchronousTokenSender` + a per-account `FileLock` in the app
    group whenever `OIDCSessionStore` has a record; Classic keeps the refresh-less path.
    The lock is per account because several extension instances share one Keychain item.
  * **Proven live against the real Konnect IDP (2026-08-18):** `OCISSignInContractTests`
    now drives the **shipping registration** — client id + secret + custom-scheme redirect
    — end to end, so a wrong value fails a test instead of only failing in the GUI. It also
    asserts the personal-only selection (1 sync root == the personal drive; catalog still
    2 spaces) and, in a second test, assembles the extension's *exact* refresh stack
    (`SessionManager` + `OIDCRefreshHandler` + `SynchronousTokenSender` + `FileLock`) over a
    pre-expired token: the manager renews it against Konnect, persists a future expiry,
    retains a refresh token, and the renewed header authorizes `listDrives`. Both green.
    **Finding worth keeping:** the mobile client is `trusted: false` in oCIS's shipped
    registration, so lico *always* forces a consent step (`identity/managers/identifier.go`
    — "If not trusted, always force consent") that the `web` client skipped. In the product
    that is one extra tap in the browser sheet; in the harness the scripted stand-in now
    grants consent (`POST /signin/v1/identifier/_/consent`, then `konnect=<state>` on the
    authorize GET, replaying the `__Secure-KKTC-…` cookie whose *name* is a hash over the
    request parameters). Without it, authorize redirects back to the sign-in form with
    `flow=consent` and the code never arrives.
  * **The app-group prefix defect — found live, and the reason the refresh wiring above was
    inert in the product** (2026-08-18; full write-up in
    `docs/live-evidence/2026-08-18-app-group-prefix.md`). `makeSession` attaches
    `OIDCRefreshHandler` *only* when it can read an `OIDCSessionRecord` out of the shared
    app group, and otherwise falls back to a refresh-less `SessionManager` — deliberate,
    because a Classic account has no record, and therefore **silent**.
    `com.apple.security.application-groups` was declared as the bare `group.…` id in all
    three entitlements files (and in `NSExtensionFileProviderDocumentGroup`), with no
    `$(AppIdentifierPrefix)`. On macOS an application group id *is* `<TEAMID>.group.…`; the
    bare form compiles, codesigns and provisions cleanly, then splits the processes at
    runtime — the **app** creates `~/Library/Group Containers/group.…` and, as its creator,
    keeps working, while the **extension** is denied a container it isn't entitled to, so
    `containerURL(forSecurityApplicationGroupIdentifier:)` yields an unopenable path and
    `UserDefaults(suiteName:)` yields a suite with **zero** of the app's keys — *with no
    error on either side*. `keychain-access-groups` already had the prefix, so credentials
    crossed and only the app-group reads failed, which is what hid it. Net effect: no
    record → refresh-less fallback → every oCIS mount died 300 s after sign-in.
    * **Evidence:** the fixture's proxy named it —
      `"failed to verify access token: token has invalid claims: token is expired"` with
      `"user_agent":"FileProviderExtension/1"` — and lldb localised it: same identifier,
      same moment, the app saw **6** `com.owncloud` keys + a 270-byte session record and
      wrote to the container fine; the extension saw **0** keys and was **denied** the
      write.
    * **Retraction:** this was previously attributed to the System-keychain self-signed-cert
      gate. That was **wrong**. Trust was verified in place (`security dump-trust-settings
      -d` → `Number of trusted certs = 1, Cert 0: OCIS`) and the proxy log proves the
      extension reaches the server over TLS and is rejected on the token. A second earlier
      claim — that a 21-minute-old domain still enumerating proved refresh worked — is also
      withdrawn: it was served from the local replica, and the Keychain `expiresAt` had
      never moved.
    * **Fix:** new `AppGroup` (`teamID` / `bareIdentifier` / `identifier`) as the single
      place the runtime id is written, carrying the failure mode in its doc comment;
      `$(AppIdentifierPrefix)` added to all three entitlements files and the document group;
      `SettingsModel` / `FileProviderExtension` / `DevHarnessOCIS` switched to
      `AppGroup.identifier`. New `AppGroupIdentifierTests` (4 tests) reads those seven files
      off disk and fails if any drops the prefix or reintroduces the bare id — a convention
      was not enough precisely because the wrong value raises no error at any stage.
    * **Proven:** 421 core tests / 10 skipped / 0 failures; `make install` BUILD SUCCEEDED
      with `codesign --verify --deep --strict` passing and both signed declarations reading
      `4AP2STM4H5.group.com.owncloud.macos.fileprovider`; the extension's container write
      flipped **"UNPREFIXED WRITE DENIED" → "EXT CONTAINER WRITE OK"**; and a fresh sign-in
      through the *shipping* sheet and the **real browser sheet** produced sidebar row
      **`admin@localhost` / Infinite Scale** with `accounts`, `oidc-session` (`tokenEndpoint:
      https://localhost:9200/konnect/v1/token`) and the 2-space catalog written into the
      **prefixed** container.
  * **Method note (kept because it cost real time):** the oCIS proxy logs **only failures**
    — a successful request emits no line at all, so "zero log lines" is *not* evidence of
    success. Assert on a positive signal (the resource, the response, the persisted
    expiry), never on silence.
  * **In-situ refresh proven (2026-08-19) — the last of issue #17's own scope:** redone on a
    *clean* replica after the first attempt was discarded as inconclusive (it had run against
    a **stale `~/Library/CloudStorage/` directory reused by display name**, still holding
    `probe.txt`/`enum-trigger.txt` from the pre-fix domain). All domains removed with
    `.removeAll` (verified: the directory disappeared), then the domain re-created through the
    **production Task 7.9 reconnect deep link** — `owncloud-fileprovider://reconnect?account=…`
    → `signInWithOIDC` → the real browser sheet at
    `signin/v1/identifier?client_id=mxd5OQ…&redirect_uri=oc%3A%2F%2Fios.owncloud.com&code_challenge_method=S256`
    → `admin`/`admin` → the forced-consent step → empty fresh replica. **That also proves the
    oCIS reconnect deep link live**, not just the Add Account sheet. A write into the domain
    **~7 hours after sign-in** (`expires_in=300`) produced `200 POST /konnect/v1/token`, then
    `200 GET /konnect/v1/userinfo` and `200 GET /graph/v1.0/me/drives` on the renewed bearer,
    with **zero** `token is expired` from the extension. So the real extension's refresh stack
    — `SessionManager` + `OIDCRefreshHandler` + `SynchronousTokenSender` + the per-account
    `FileLock`, reading its parameters from the now-reachable app group — works in situ, which
    is the one thing the contract test could only simulate.
    * **What made this readable at all:** the fixture runs `OCIS_LOG_LEVEL: error`, so
      successful requests emit nothing. Restarting it with `OCIS_LOG_LEVEL=info` (an env
      override only — `docker-compose.yml` is unchanged) turns on the proxy **access log with
      status codes**, converting the whole exercise from arguing about silence to reading
      positive signals. **Do this first in any future live oCIS debugging.**
  * **Two unrelated pre-existing bugs this surfaced — NOT issue #17, deliberately not fixed
    here** (they are in the Graph request layer and were invisible while every request was
    silent; recorded rather than fixed, because #17's scope is sign-in reachability and
    neither bug is caused by it):
    1. **Graph content upload always 404s.** `PUT /graph/v1.0/drives/{drive}/root:/{name}:/content`
       → **404**, and so does the item-addressed `…/items/{rootID}:/{name}:/content`. But
       `PUT /dav/spaces/{drive}/{name}` → **201** and the file then appears in the Graph
       children listing. oCIS 8.2.0 does not serve the Graph upload path
       `GraphRequestBuilder.uploadNewFileUnderRoot` / `.uploadNewFile` emit; the WebDAV spaces
       route is the working one. Same *class* of defect as the `/root/children` enumerate 404
       already fixed.
    2. **Working-set identifier sent literally.** `GET /graph/v1.0/drives/{drive}/items/`
       `NSFileProviderWorkingSetContainerItemIdentifier/children` → **404**: the extension
       passes `NSFileProviderItemIdentifier.workingSet` straight through as an item id instead
       of mapping it, as it already maps `.rootContainer` to the drive id.

    Consequence to be honest about: **no file written into an oCIS mount reaches the server
    yet.** The account, the mount, the enumeration and the token lifecycle are all proven; the
    write verb is wrong. That is follow-up work of its own. **Both fixed 2026-08-19 under
    Task 4.5**, which replaced the Graph file-operation layer with per-space WebDAV: the write
    round trip is now live-proven server-side, and the reserved identifiers (working set *and*
    trash) are resolved before any address is built.
  * **Remaining (keeps `[~]`):** issue #17's own scope — sign-in reachable from the settings
    UI, the personal space mounting, and the mount surviving past `expires_in=300` — is
    **complete and live-proven**, and the upload round trip that used to block this marker is
    now closed by Task 4.5 (create/write/rename/reparent/edit/delete all confirmed server-side
    by independent `curl`). Two housekeeping defects remain unfixed and are now tracked as
    issues rather than only here: a stale `spaces.…` app-group key survives Sign Out
    (**#23** — `SpaceCatalogCache` has no `remove` at all, so nothing can drop the key), and
    old `ownCloudFileProvider-*` replica directories accumulate (**#24**; being reused by
    display name, they can silently confound a live check — see the discarded first attempt
    above). A third, learned the hard way in 4.5:
    `make install` can leave a **stale** bundle in place, so live evidence is only
    trustworthy once built-vs-installed **sha256** match and the appex has been re-registered.
* **Acceptance gate:** the configuration scenario group above, green on both backends
  (Classic exercising the account/sign-out half, oCIS the space-selection half per AC-1's
  tagging), plus the Phase 5 lifecycle gate it extends.

---

## Branding & About (issue #18)

Not a phase — a self-contained gap the phases never covered. The repo shipped **no
asset catalog at all**, so macOS used its generic placeholder icon everywhere, and
About was AppKit's default panel: name, version, nothing a bug report can use.

* `[x]` **Task 8.1 — the ownCloud icon in all three bundles.** Upstream
  `oc-logo-1c-blue-RGB.svg` committed unmodified under `Resources/Icon/` (provenance +
  SHA-256 in its README); `make icons` runs `Resources/Icon/make-icon.swift`, which
  takes **path index 8** (the cloud mark alone — the wordmark is illegible at the
  Finder sidebar's 16 px), composes it on a white squircle on Apple's macOS grid, and
  writes the ten deterministic PNGs of `Resources/Assets.xcassets/AppIcon.appiconset/`.
  Generation is manual and the PNGs are committed, so it stays out of `install` and CI.
  Two things to not rediscover:
  * **`qlmanage -t` cannot rasterize this.** It forces square output *and* composites
    onto opaque white, so the squircle's transparent corners come back as
    `(255,255,255,255)`. The AppKit path (`NSImage` → `_NSSVGImageRep` →
    `NSBitmapImageRep`, `imageInterpolation = .high`) keeps alpha and needs no
    Homebrew tooling — `magick`/`rsvg-convert`/`inkscape` are not installed here.
  * **An `.appex` target needs `ASSETCATALOG_COMPILER_APPICON_NAME` set explicitly.**
    An app target gets it for free. Without it on the two extension targets, `actool`
    runs and the `.appex` still ships an empty `Contents/Resources` — no icon, no
    warning. All three `Info.plist`s also spell out `CFBundleIconName`/
    `CFBundleIconFile`, because `GENERATE_INFOPLIST_FILE: NO` means actool's partial
    plist is never merged.
  * Which bundle macOS reads for a sync root's Finder icon is undocumented, so the one
    catalog is wired into all three targets rather than guessing.
* `[x]` **Task 8.2 — an About window that supports a bug report.** Same split as
  Phase 7's settings window: `AboutInfo` (`OwnCloudCore`) owns every rendered string
  and is covered by nine `AboutInfoTests`, with the year and OS version injected
  rather than read from the clock so the output is deterministic; `AboutWindow.swift`
  is a thin SwiftUI renderer and `AboutInfoReader` the bundle-reading adapter.
  ⌘-About reaches it via `CommandGroup(replacing: .appInfo)`. It reports the app,
  **both extensions separately** (read from `Contents/PlugIns/*.appex` — they load
  out-of-process and can be stale relative to the app), the core version and the host
  macOS version, every value selectable for pasting. An unreadable bundle degrades to
  a legible `Unavailable` row: this window is what a user opens *because* something is
  wrong, so it must render when an extension is missing.
* `[~]` **Verified on the installed signed build** (`make install`, `codesign --verify
  --deep --strict` clean): the committed PNGs are pixel-exact `041E42FF` in sRGB with
  transparent corners at 16/128/1024 px; `make icons` re-run leaves a clean `git diff`;
  `AppIcon.icns` + `Assets.car` and `CFBundleIconName = AppIcon` are present in the app
  **and both `.appex`** bundles; 340 core tests green; `xcodebuild` BUILD SUCCEEDED. The
  About window was captured for real from the running app (not a harness) with both
  extension versions populated. **Note for the reviewer:** macOS 26 applies its own icon
  treatment to a flat legacy `.appiconset` — the rendered icon shows extra corner
  rounding, a gradient sheen and a lightened blue. Our artwork is exact; if the treated
  look is unwanted, that is an Icon Composer / `.icon` migration, a separate change.
* `[x]` **Finder sync-root icon confirmed working — and the mechanism, because it is not
  obvious.** Finder resolves a live sync root's icon from the **File Provider extension
  bundle**, not the containing app: with an icon-less `.appex` the row shows the generic
  white "plugin brick" (macOS's fallback extension icon), and with `AppIcon` present in
  the `.appex` the row shows the cloud. This is exactly why the icon has to be wired into
  the extension targets (see the `ASSETCATALOG_COMPILER_APPICON_NAME` note above) —
  putting it only in the app would leave the sidebar generic. Verified by capturing the
  real Finder window before and after installing the icon-carrying build.
  Two measurement traps found while confirming this, both of which produced false
  negatives and cost a debugging cycle:
  * **`NSWorkspace.icon(forFile:)` is not a valid oracle for a sync root.** It returns
    the generic folder/provider-root icon even for iCloud Drive, whose sidebar row is
    definitely branded. Only a screenshot of Finder itself tells the truth. (An earlier
    note here claimed the sidebar icon "cannot be asserted programmatically" and cited a
    comparison against "the Nextcloud client installed on this Mac" — that was wrong on
    both counts: Nextcloud is **not** installed, only an orphaned
    `~/Library/CloudStorage` folder with no provider behind it, so the comparison
    measured nothing.)
  * **Finder caches the root icon from when the domain was mounted.** A root created by
    an icon-less build keeps the brick until Finder is restarted (`killall Finder`), even
    after the icon-carrying build is installed. Restart Finder before judging.
  * **Watch out for the sibling checkout.** `~/Development/DeepDiver1975/macos-fileprovider`
    (no `-2`) builds the same bundle id and installs to the same
    `~/Applications` path, so a `make install` from there silently replaces this
    checkout's app — which is what put an icon-less build in place mid-verification.
    Check `plutil -extract CFBundleIconName raw "<installed app>/Contents/Info.plist"`
    before concluding the icon is broken.

---

## Release & Distribution

Not a phase — the gap between "the app builds" and "a user can install it". Every
build ever made called itself `0.0.1 (1)`, because `project.yml` hardcoded
`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` and nothing overrode them; the About
window built for issue #18, whose whole purpose is telling a bug reporter which
build they are on, reported that constant forever. There were no tags, no GitHub
releases and no distributable artifact.

Tag convention, required secrets and the full local recipe are in
[PROJECT.md → Releasing](PROJECT.md#releasing).

* `[x]` **Task 9.1 — derive the version from the tag.** `scripts/release-version.sh`
  splits a tag into the numeric core that stamps the bundles and the full tag that
  names the release, because Apple accepts only one to three dot-separated integers
  in `CFBundleShortVersionString` — `v1.2.0-rc.1` cannot reach a bundle as-is. It is a
  tested script rather than a `${GITHUB_REF#refs/tags/}` expression inlined in YAML
  because it is the one piece of release logic with real edge cases: `make
  release-version-test` asserts 6 accepted and 8 rejected tags. A malformed tag exits
  non-zero rather than emitting a partial result — a half-parsed tag would ship a
  bundle claiming version `""`.
* `[x]` **Task 9.2 — make the project releasable.** Two blockers, either of which
  would have failed every release:
  * **`ENABLE_HARDENED_RUNTIME` was set nowhere** (0 hits in the generated
    `.pbxproj`). The notary service rejects a submission whose executables were not
    built against it. Now in `settings.base`, so all three targets get it.
  * **`com.apple.developer.fileprovider.testing-mode` is a *restricted*
    entitlement**, granted only through a development provisioning profile. A
    Developer ID profile does not carry it and signing fails outright, so Release
    builds use a `configs:` override pointing at
    `FileProviderExtension-Release.entitlements` — the same file minus that key. It
    should not ship regardless: it exists so the acceptance suite can drive
    `NSFileProviderDomain.testingModes` deterministically (AC-3), a developer
    capability, not a user one. **The two entitlements files must be kept in step.**
* `[x]` **Task 9.3 — the artifact.** `scripts/make-dmg.sh` archives, exports,
  packages and signs; `scripts/notarize.sh` submits, staples and verifies. Both live
  in scripts rather than in the workflow so a release is reproducible on a developer
  Mac with the same commands CI runs (**AC-4**, no CI-only wiring), reachable as
  `make dmg` / `make notarize`. `hdiutil` rather than `create-dmg` — the same finding
  as issue #18, Homebrew image tooling is absent here and `hdiutil` ships with every
  runner. A `.pkg` was rejected: it needs a `Developer ID Installer` certificate the
  team does not have, whereas the `Developer ID Application` certificate that does
  exist can sign a `.dmg`. The app is stapled **before** the image is rebuilt around
  it, so a user who drags the app out of the image onto another Mac still has a valid
  ticket offline.
* `[x]` **Task 9.4 — the version is asserted, not assumed.** `make-dmg.sh` fails the
  build unless all three `Info.plist`s report the expected version *and* the shipped
  extension's entitlements carry the app sandbox and app group but not testing-mode.
  The extensions are separate targets, so a settings mistake could stamp the app and
  miss them — and the About window would then report versions that disagree. The two
  required entitlements are a **positive control**: `codesign -d --entitlements`
  produces no output at all for an ad-hoc-signed or unreadable bundle, so a bare
  "grep finds no testing-mode" would pass on a failed dump. (Also: `plutil -extract`
  cannot be used here — it treats the dots in a reverse-DNS entitlement key as
  keypath separators and reports every such key as missing. `PlistBuddy` does not.)
* `[x]` **Task 9.5 — the stale version rows.** `AboutInfo`'s "Core" row showed
  `OwnCloudCore.version`, a compiled-in package constant; a release stamps the three
  `Info.plist`s and never rewrites Swift source, so that row would have read `0.0.1`
  in a `1.2.0` build and contradicted every other number in the window. Row removed,
  and the app's own `1.2.0 (147)` exposed as `AboutInfo.appVersionDisplay`. The same
  bug in `SettingsWindow.swift`'s "Version" field was found while tracing it and
  fixed the same way. A test now asserts no row's value equals `OwnCloudCore.version`,
  so the row cannot come back by accident.
* `[~]` **Task 9.6 — the workflow.** `.github/workflows/release.yml` on `push:
  tags: ['v*']`: parser self-test → derive version → `swift test` (a release must not
  ship untested code) → import the `.p12` into a temporary keychain → `make dmg` →
  notarize + staple → `gh release create` with `--prerelease` for a suffixed tag,
  attaching the `.dmg` and a `.sha256`. Actions pinned to full commit SHAs and
  diagnostics uploaded on failure, matching `ci.yml` (**AC-2**, **AC-6**). **Blocked
  on the six repository secrets, none of which exist yet** — and, as 9.8 records, on
  a key permission the secret list does not reveal (issue #32) — so no release has
  ever run; this stays `[~]` until a throwaway tag has been pushed end to end. Tasks 9.7
  and 9.8 exist because that is the wrong way to find out: they exercise the two
  halves of this pipeline continuously so a tag is not its first execution.
* `[x]` **Task 9.7 — the unsigned half, on every PR.** `ci.yml` tier 4, `installer`:
  parser self-test → `xcodegen` → `make dmg SIGNING=none VERSION=0.0.0
  BUILD=<run number>` → the `.dmg` uploaded as a workflow artifact (14 days), with
  a `dist` listing on failure (**AC-6**). No secrets at all, so it runs on fork PRs
  too — and on a developer Mac with no Xcode account, which is exactly where the
  signed path cannot run. `SIGNING=none` lives in `make-dmg.sh` rather than a second
  script (**AC-4**): it skips `-exportArchive` (copying the app out of the archive
  instead, so every later stage is identical between modes), the entitlements check
  and signing the image, printing the reason for each. Two rails so a flag that
  skips a safety check cannot produce something mistakable for a release: the
  `-unsigned` suffix is appended *inside* the script, and `dist/signing-mode.txt`
  makes `notarize.sh` refuse the build — the same handoff pattern as
  `artifact-path.txt`, and checked here rather than at Apple, where the rejection
  arrives twenty minutes later reading like a notarization failure.
  `ReleaseEntitlementsTests` (5 cases) covers the declarations the artifact check
  cannot: **`codesign -d --entitlements` exits 0 and writes no file** on an
  ad-hoc/linker-signed bundle, so unsigned the check cannot pass and must not appear
  to. The tests parse both plists with `PropertyListSerialization`, **not**
  `contains`: both files carry a comment block naming
  `com.apple.developer.fileprovider.testing-mode`, so the literal string appears
  once in the Debug file and **twice** in the Release file that omits it — a string
  search would be exactly inverted. Same family as the two traps in 9.4.
  **The bug this tier caught on its own first run, which is the whole argument for
  building it:** macOS ships `/bin/bash` **3.2**, where expanding an *empty* array
  under `set -u` fails outright — `auth_flags[@]: unbound variable`. `#!/usr/bin/env
  bash` finds Homebrew's bash 5 on a developer Mac, which tolerates it, so no amount
  of local testing could have surfaced this. `release.yml` had the identical bug in
  `prerelease_flag`, sitting on the **non**-prerelease path: every `v1.2.0` would
  have failed at `gh release create` while every `v1.2.0-rc.1` worked. Both fixed by
  making the arrays never empty — lead with a flag that is always wanted — rather
  than by guarding each expansion with `${a[@]+"${a[@]}"}`. Scripts are now checked
  against `/bin/bash` explicitly.
* `[~]` **Task 9.8 — the signed half, on every push to `main`.** `release.yml` gains
  `push: branches: [main]` and publishes a rolling `main-latest` prerelease,
  deleted and recreated each time (`gh release delete --cleanup-tag`), so Developer
  ID signing, both notary submissions, stapling and `gh release create` — the last
  unproven publish step — run continuously instead of first on a tag. `main-latest`
  cannot re-trigger the workflow: the tag filter is `v*`. Version `0.0.0` with
  `main-<sha7>` as the artifact name, because a rolling build is not a release and
  About should say so. Gated on the `RELEASE_SIGNING_ENABLED` repository **variable**
  — a variable, not a secret, because `vars` can be read in a job-level `if` and
  `secrets` cannot — since until the six secrets exist an unconditional signed job
  would paint `main` red on every push. `[~]`: written and unexercised for exactly
  the same reason as 9.6, and setting the variable is the user's call.
  **Second blocker, found 2026-08-20 and not visible from the secret list:** an
  unattended signed build needs a *team* App Store Connect key holding
  *Access to Cloud Managed Developer ID Certificate*. The key that exists has Admin
  and notarizes fine, but Apple 403s it on cloud-managed certificates, and cloud
  signing is the only way `-exportArchive` gets a Developer ID profile without a
  signed-in Xcode account — which no runner has. So the six secrets are necessary
  and **not sufficient**; see the 2026-08-20 log entry, and issue #32 for the
  remaining steps and how to verify the grant before spending a build on it.

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
* Competing products, checked against each vendor's own documentation rather than recalled — all three configure in their own app plus a plist/MDM domain, and **none ships a System Settings pane**, which is the evidence for Phase 7's first framing decision: [OneDrive: Deploy and configure the sync app for Mac](https://learn.microsoft.com/en-us/sharepoint/deploy-and-configure-on-macos) (`com.microsoft.OneDrive` / `com.microsoft.OneDrive-mac` plist + configuration profiles) · [Google: Advanced Drive for desktop configuration](https://knowledge.workspace.google.com/admin/drive/advanced-drive-for-desktop-configuration) (`com.google.drivefs.settings`, incl. `/Library/Managed Preferences/`) · [Dropbox: Expected changes with Dropbox for macOS on File Provider](https://help.dropbox.com/installs/macos-support-for-expected-changes). Three findings that bear on tasks above, not just background:
  * OneDrive's `AddedFolderUnmountOnPermissionsLoss` **defaults to** "mark the folder in error and prompt the user to remove it" (hard-delete is opt-in) — independent corroboration of **Task 7.7**: disconnect and flag, never remove the domain.
  * OneDrive's `KFMSilentOptIn`/`KFMOptInWithWizard` take a **tenant ID**, i.e. the known-folder claim is keyed to one unambiguous owner. We have no equivalent across N per-space domains, which is why known folders are out of Phase 7 rather than guessed at.
  * Google's page states that from macOS 12.1 *"Drive for desktop uses File Provider and macOS controls the location of cached data"* — adopting File Provider removed their cache-location setting, and Dropbox's article confirms the `~/Library/CloudStorage` relocation. Both corroborate the "on-disk location of a replicated domain" note below, and mean **Task 7.8 must not offer a configurable local folder location**.
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
* *2026-08-17 (correction to the entry above)*: the competing-product comparison was originally recorded as "from knowledge, not verified — only `developer.apple.com` and GitHub were reachable". **That reachability claim was false and self-inflicted:** `WebFetch` had failed twice with an unrelated error (its summarizer model returns HTTP 403 on this host's Bedrock role), and rather than testing another route I explained the gap using the sandbox's `allowedHosts` list without ever trying it. Plain `curl` reaches those vendor hosts fine. Re-checked against each vendor's own documentation and cited in References: **no third-party product ships a System Settings pane** — OneDrive and Google Drive both configure via a preference-domain plist plus MDM, Dropbox's own article only ever points at *Apple's* Privacy pane. Two Phase 7 decisions gained independent support (Task 7.7's disconnect-and-flag matches OneDrive's `AddedFolderUnmountOnPermissionsLoss` default; known folders being out matches OneDrive keying `KFMSilentOptIn` to a single tenant ID) and one task gained a constraint (Task 7.8 must not offer a configurable local folder location — Google's docs say File Provider took that control away). Method note for the loop: when a fetch tool fails, verify the *next* route before describing the limit — `curl` plus a docset's `toc.json`, `sitemap.xml` or search API reached every source needed here.
* *2026-08-18*: **Phase 7 (user-facing configuration) implemented to its headless boundary, test-first (304 core tests green + 3 skipped; `xcodebuild test` TEST SUCCEEDED; signed `xcodebuild build` BUILD SUCCEEDED).** Every task carries either a `[~]` (headless artifact done, Mac/Docker remainder documented) or, for the pure-logic ones, `[x]`. Highlights, in the order the phase was built: **7.1** the identity split — a new `SyncRoot` owns the domain identity `"<driveID>|<accountIdentifier>"` while `accountIdentifier` keys the Keychain, `DomainDisplayNamer` names the row, and the live `driveID: nil` bug (`drives//…`) is fixed. **7.2** the space catalog — `GraphRequestBuilder.listDrives()` + `Space`/`SpaceCatalog`. **7.3** persistence over an injectable `KeyValueStore` seam — `AccountRegistry` (so a zero-space account doesn't vanish) + a display-only `SpaceCatalogCache`. **7.4** `DomainReconciler.plan(registry:existing:intent:)`, a pure add/remove/orphans function (six cases tested). **7.5** `DomainService` orchestrates the crash-safe ordering (record-first on add, record-last on remove, orphan-only-on-confirmation, single-instance) over three injected seams; Mac adapters in `DomainServiceAdapters.swift`. **7.6** `SessionManager.refreshTokenIfNeeded()` arbitrates the N-instances-over-one-rotating-token race via an injected `RefreshLock` — double-checked under the lock, re-read-once on failure; `FileLock` is the `flock` conformer. **7.7** `SpaceAvailability` maps a root-container 404 onto disconnect-not-remove with a user-facing reason. **7.8** the settings window — all rendered decisions live in tested presenters (`SpacesTab`, `SpaceRemovalPrompt` with the concrete "Keep the 840 MB already downloaded" wording via `humanizedBytes`, `DomainEnablementStatus` surfacing `userEnabled` + the System Settings deep link); the SwiftUI shell (`SettingsWindow`/`SettingsModel`) is a thin `@MainActor` layer. **7.9** the UI extension stays a launcher — `AppLaunchURL` (`owncloud-fileprovider://reconnect`) round-trips, `ActionViewController.prepare(forError:)` opens the app, and `NSExtensionFileProviderAllowsUserControlledEviction` = true buys Finder-native "Remove Download". **7.10** `test/features/configuration.feature` carries all six acceptance scenarios (space-selection tagged `@ocisOnly` per AC-1, the refresh race among them), asserted for shape by `ConfigurationFeatureTests`. **7.0** the five deferred assumptions were resolved and recorded as findings (process-per-domain → the lock is required, not merely harmless; sidebar Finder actions unavailable → don't depend on them; the `x-apple.systempreferences:` LoginItems deep link; the eviction key placement inside `NSExtension`; ~12-domain scale has no code impact). **Remaining across the phase is uniformly Mac/Docker-gated:** the live `NSFileProviderManager` add/remove/disconnect/reconnect calls, the sign-in flows (Classic password, oCIS OIDC via `ASWebAuthenticationSession`), the live OIDC `RefreshHandler` through the lock, and the acceptance runner/step library that drives the feature file against Docker fixtures (Task 6.0/6.3).
* *2026-08-18*: **Task 7.11 — the real Classic "Add Account" sign-in flow, closing the Task 7.8 gap (311 core tests green + 3 skipped; signed `xcodebuild build` BUILD SUCCEEDED).** The problem: the settings sidebar is populated from `AccountRegistry`, but the only code that ever seeded a credential and mounted a domain was `DevHarness` (DEBUG-only), which writes the Keychain and calls `NSFileProviderManager.add` directly — never touching the registry — so on a real `make install` launch the sidebar was empty and `beginAddAccount()` was a stub. Built test-first, thin-view-layer as the rest of Phase 7: **headless** `SignInResolver` (`Core/Sources/OwnCloudCore`) turns raw fields + a `BackendProbeResult` into a `ResolvedSignIn` (account + `.basic` credential + nil-drive `SyncRoot`) or a typed `SignInError`, owning every decision — whitespace trim, `http://` prepend for a schemeless host (fixture ergonomics, pinned by a test), `BackendDetector` choice, and an explicit `.ocisNotSupportedYet` rejection since OIDC is out of scope here; seven `SignInResolverTests` drive it RED→GREEN. **Mac-gated adapters:** `HTTPServerProbe` (`FileProviderSupport`, behind a `ServerProbing` protocol) GETs `/.well-known/openid-configuration` (success → OIDC signal) and `/status.php` (body → Classic signal) over `RemoteClient`, catching any non-2xx/error as the negative signal (Classic 404s the OIDC document); `SettingsModel.addAccount(serverURL:username:password:)` probes → resolves → writes the Basic credential via `KeychainCredentialStore` → `DomainService.addSpace` (records the account in the registry *first*, so it appears in the sidebar) → `reload()` → selects it, publishing `addAccountError` on any failure; and `AddAccountSheet` in `SettingsWindow.swift`, a thin field-collector presented from the "Add Account…" button. **Remaining (Mac, live):** the end-to-end fixture exercise — `make up BACKEND=classic`, `make install`, Add Account `http://localhost:8080` admin/admin, confirm the domain mounts in Finder and Sign Out round-trips. oCIS OIDC sign-in stays out of scope (rejected with the typed error).
* *2026-08-18 (follow-up)*: **Task 7.11's probe promoted from "compiles" to "proven live", and the automatable slice of its remainder closed (313 core tests + 5 skipped in the unit run; 2 new live tests green against the Docker Classic fixture; signed `xcodebuild build` BUILD SUCCEEDED).** `HTTPServerProbe` was the one sign-in adapter with no test — its whole job is turning a live server's two endpoint responses into a `BackendProbeResult`, so a headless unit test can't cover it. Added `ServerProbeContractTests` (in `FileProviderSupportTests`), a live contract tier mirroring `BackendContractTests`: it probes the real fixture and runs the result through `SignInResolver`, asserting `hasOpenIDConfiguration == false`, a non-nil `status.php` body, `BackendDetector.detect == .classic`, and a resolved Classic `.basic` account with a nil-drive `SyncRoot`. Ran it locally against `make up BACKEND=classic` — both tests pass. Dropped the unnecessary `#if canImport(FileProvider)` guard from `ServerProbe.swift` (it uses only `RemoteClient` + Foundation, so it's Linux-buildable like the rest of the contract path), and wired the tier into the existing classic backend-contract CI job (`swift test --filter 'BackendContract|ServerProbeContract'`) so it runs on **every PR**, self-skipping on the oCIS matrix leg. What genuinely remains is GUI-only and cannot be automated headlessly: the Finder mount + System Settings extension approval + Sign-Out round-trip on an installed build — a human-at-the-machine step, documented under Task 7.11 like Phase 7's other live remainders.
* *2026-08-18 (Task 7.11 verified live → `[x]`)*: ran the manual Finder round-trip on the installed signed build against the local Classic fixture (`make up BACKEND=classic`, `make install`, both `.appex` registered per `pluginkit -mAv`). Add Account `http://localhost:8080` admin/admin → the `admin@localhost` (Classic) account appeared in the sidebar (proving probe → resolve → Keychain write → `DomainService.addSpace` → registry → reload), the domain mounted in Finder and enumerated, and **Sign Out** removed both the domain and the account — the full lifecycle round-tripped. With the headless core CI-proven (`SignInResolver` unit tests + the live `ServerProbeContractTests`) and the live UI now confirmed, Task 7.11 is marked `[x]`.
* *2026-08-18 (Task 7.5 promoted to `[x]` on the same evidence)*: re-examining the `[~]` tasks against what the 7.11 round-trip actually exercised, **Task 7.5's** documented remainder — the live `NSFileProviderManager.add`/`remove`/`getDomains` calls on a signed host — was in fact driven end to end by that round-trip: Add Account went `addSpace` → `SystemDomainManager.add` → `NSFileProviderManager.add` (domain mounted in Finder), the sidebar populated through `existingSyncRoots` → `getDomains`, and Sign Out went `signOut` → remove domain + delete credential + delete record → `NSFileProviderManager.remove` (domain + account both gone). The record-first-on-add / record-last-on-remove ordering ran against the live system. Marked `[x]`; the orphan-only-on-confirmation and concurrent-multi-instance reconcile paths stay unit-tested and belong to the Task 6.3 fixture tier. **Task 7.8** had its Classic sign-in half closed by 7.11 too, but stays `[~]` because its oCIS OIDC (`ASWebAuthenticationSession`) half is genuinely unbuilt. The rest (7.6, 7.7, 7.9, 7.10) keep `[~]`: each has a real remainder that needs the Mac/Docker end-to-end tier (Task 6.0/6.3) — a live refresh-race, a live `disconnect`/`reconnect` against a deleted drive, the appex→app hand-off, and the acceptance runner — none of which the Classic sign-in round-trip touched, so promoting them would be false reporting.
* *2026-08-18 (Task 7.12 — the oCIS OIDC sign-in headless core + adapters)*: built the Infinite Scale counterpart of 7.11's Classic flow, all test-first (331 core tests green + 6 skipped; `swift build` + signed `xcodebuild build` both succeed). The whole OAuth2 Authorization-Code + PKCE flow is pure, Linux-buildable core with the outside-world touchpoints injected as closures, so the decision logic is fully headlessly tested — the pattern established by `OIDCRefreshHandler`. Pieces, in build order (each RED→GREEN, watched to fail for a missing-type reason first): (1) **`SHA256`** — a dependency-free FIPS-180-4 hash, because the package is deliberately Foundation-only (no swift-crypto); pinned to the published FIPS/RFC vectors incl. the one-million-'a' case. (2) **`PKCE`** — RFC 7636 verifier + `S256` challenge (base64url-no-pad of SHA-256(verifier)), pinned to the RFC 7636 Appendix B worked example so the base64url + hash wiring is verified against the standard, not itself. (3) **`OIDCConfiguration`** — parses `/.well-known/openid-configuration` into issuer/authorization/token endpoints, rejecting non-JSON or a missing endpoint. (4) **`OIDCAuthorizationRequest`** — builds the authorize URL (`response_type=code`, PKCE `S256`, state) and parses the redirect callback, validating `state` *before* the code (CSRF), surfacing a server `error`, rejecting a code-less callback. (5) **`OIDCTokenRequestBuilder.exchange`** — the `grant_type=authorization_code` POST redeeming the code with the `code_verifier`, sharing the form encoder with the already-built `refresh` grant. (6) **`OIDCSignInCoordinator`** — composes all of the above into one async `signIn(serverURL:)` returning `.bearer` credentials (via the existing `OIDCTokenResponse.credentials`) + the discovered configuration so refresh (Task 7.6/2.5) wires to the same token endpoint; state/verifier/`now` and all three network/UI closures are injected, so the happy path and the state-mismatch abort are deterministic. **Discovery proven live (CI, every PR):** `HTTPOIDCDiscovery` (`FileProviderSupport`, the oCIS sibling of `HTTPServerProbe`) GETs the live IDP's discovery document and parses it; `OIDCDiscoveryContractTests` runs it against the Docker oCIS fixture (trusting the self-signed cert with the same test-only `InsecureTrustDelegate` as `BackendContractTests`) and joins the backend-contract job (`--filter 'BackendContract|ServerProbeContract|OIDCDiscoveryContract'`, gated on `OWNCLOUD_TEST_BACKEND=ocis`, self-skips on the Classic leg). Ran it locally against `make up BACKEND=ocis` (`https://localhost:9200`) — green. **Mac-gated adapter (built, GUI-gated):** `WebAuthorizationPresenter` drives the authorize URL through `ASWebAuthenticationSession` (`#if canImport(AuthenticationServices)`, `prefersEphemeralWebBrowserSession`), supplying the coordinator's `authorize` closure; only the system browser sheet is untested — the same GUI gate as the Classic Finder round-trip. **What keeps 7.8/7.12 `[~]`:** wiring the coordinator into `SettingsModel`'s oCIS branch (a redirect-scheme `Info.plist` entry + per-space drive resolution) and a live end-to-end exercise both need an **OIDC-capable oCIS fixture** — the current Docker fixture is Basic-auth only (`PROXY_ENABLE_BASIC_AUTH`, fixtures-only). That is the Task 6.0/6.3 tier.
* *2026-08-18 (Task 7.12 follow-up — the oCIS account-identity + per-space resolution, headless)*: closed the pure "who is this account and what does it sync" half of 7.12's remainder, all test-first (343 core tests green + 6 skipped; signed `xcodebuild build` BUILD SUCCEEDED). The gap: unlike Classic, an OIDC sign-in has **no typed username** — the identity is in the `id_token` — and nothing extracted it (`DevHarness` hardcodes `"admin"`, `OIDCTokenResponse` discarded the token). Pieces, each RED→GREEN watched to fail first: (1) **`OIDCIDToken`** reads the account-identity claims out of the `id_token` JWT (`preferred_username` → `email` → the mandatory `sub`), base64url-decoding the payload but *deliberately not* verifying the signature — it arrives over TLS inside the code exchange and names the account for display only; the `access_token` remains the sole bearer credential, so a forged claim renames a string but grants no access (documented in the type + pinned by the jwt.io external vector and malformed/missing-`sub` cases, `OIDCIDTokenTests`). (2) **`OIDCTokenResponse.idToken(from:)`** surfaces the raw `id_token` (nil when omitted, e.g. the refresh grant), and **`OIDCSignInCoordinator.Success`** now carries it. (3) **`OCISSignInResolver`** — the oCIS counterpart of `SignInResolver`: turns (server + bearer credential + `id_token` + `me/drives` listing) into an `AccountDescriptor(.ocis)` named from the claims, the bearer `Credentials`, one `SyncRoot` per space, and the `SpaceCatalog`; rejects non-bearer credentials and an empty drive list with typed errors (`OCISSignInResolverTests`). **Still `[~]`:** the thin Mac glue that calls the coordinator (`WebAuthorizationPresenter` + `HTTPOIDCDiscovery`), feeds its result + a `DriveResolver` `me/drives` fetch through `OCISSignInResolver`, persists the credential and adds one domain per sync root via `DomainService`, plus the redirect-scheme `Info.plist` entry and a live run — all needing an **OIDC-capable oCIS fixture** (the Docker fixture is Basic-auth only). Task 6.0/6.3 tier.
* *2026-08-18 (Task 6.4 — the acceptance step-matching engine + catalog, headless)*: built the pure half of the step library that Task 6.4 named, all test-first (356 core tests green + 6 skipped; signed `xcodebuild build` BUILD SUCCEEDED). The step library has two halves: mapping a Gherkin step's *text* to a definition (pure text-processing) and *executing* that definition against the live `BackendAdmin` + `NSFileProviderManager` harness (Mac/Docker-gated). Built the first: (1) **`StepPattern`** compiles a Cucumber-expression pattern to an anchored `NSRegularExpression` — `{string}` captures a double-quoted run, `{int}` an optionally-signed integer, and literal spans are `NSRegularExpression.escapedPattern`-escaped so wording metacharacters (`.`, `(`, `)`) match themselves not as regex; `match(_:)` returns the ordered `StepArgument`s. (2) **`StepRegistry`** dispatches a `GherkinStep` to exactly one pattern, raising `StepMatchError.undefined` (zero matches — an unimplemented step must fail loudly) or `.ambiguous` (>1 — the library can't silently pick). 9 `StepMatcherTests` incl. the metacharacter-escaping and ambiguity cases. (3) **`AcceptanceStepCatalog`** enumerates every step pattern the committed feature files use; **`AcceptanceStepCatalogTests`** parses the real `test/features/*.feature` (outlines `expanded()`) and asserts every step matches exactly one catalog pattern — so an undefined or ambiguous step is caught in the headless loop, not at runtime on the Mac. Anchoring keeps near-duplicate wording disjoint (e.g. "deselected" vs "deselected keeping downloaded files"). All Foundation-only / Linux-buildable. **Still `[~]`:** the runner and the action bodies (which drive Task 6.3's Mac/Docker harness) remain gated; only the step-text → definition mapping is now pure and proven.
* *2026-08-18 (Task 6.4 follow-up — the acceptance scenario-runner orchestration, headless)*: built the second pure layer of the acceptance runner, all test-first (361 core tests green + 6 skipped; signed `xcodebuild build` BUILD SUCCEEDED). Where step-matching made step *selection* pure, this makes step *sequencing* pure: **`ScenarioRunner`** walks a parsed `GherkinScenario`'s steps in order, matches each through the `StepRegistry`, resolves the matched pattern's action through an injected `ActionLookup` closure, and invokes it with the captured `StepMatch` — stopping at the first failure and returning a `Result` (`.passed` / `.failed(step:reason:)` + the step texts that executed). All three failure modes are surfaced, never swallowed: an undefined step (no pattern matched), a matched-but-unbound pattern (the catalog listed wording the harness never wired), and an action that throws. Because the action bodies are injected `@Sendable (StepMatch) async throws -> Void` closures, the sequencing / argument-passing / fail-fast contract is proven with a stub action (5 `ScenarioRunnerTests`, each RED→GREEN watched to fail for a missing-type reason first). All Foundation-only / Linux-buildable. **Still `[~]`:** only the *action bodies* (Task 6.3's `BackendAdmin` + `NSFileProviderManager` harness — Mac + Docker + signing) remain gated; the step-text → definition mapping **and** the scenario-run orchestration are now both pure and CI-proven.
* *2026-08-18 (LIVE Classic round-trip on the signed/installed build — Tasks 4.1/4.2 → `[x]`, 6.0 → `[~]`, 4.4/5.1 evidence recorded)*: ran the end-to-end Mac tier the "no headless test possible" tasks had been waiting on, at the project owner's direction. Setup, all scripted: `make up BACKEND=classic` (ownCloud 11.0.0 at `http://localhost:8080`, admin/admin, seeded `report.txt` + the skeleton `Documents`/`Photos`); `make install` → signed Debug build in `~/Applications`, `codesign --verify --deep --strict` exit 0, both `.appex` embedded and registered `+` per `pluginkit -mAv`. The Debug build's `DevHarness` mounted the `admin@localhost` domain (path-addressed Classic, real Keychain credential via `KeychainCredentialStore`), so the checks drove the **real `FileProviderExtension`**, each corroborated against the server over WebDAV: **enumerate** root + subfolders (`Documents`/`Photos`/`Example.odt`); **hydrate** `Example.odt` (36227 B) **byte-exact** — SHA-256 `d617ccd9…cb326f` == direct WebDAV GET; **create** `live-acc-check.txt` → server HTTP 201, byte-exact; **modify** → server showed new bytes; **delete** → server GET 404; **rename/move** → `rename-src.txt` 404, `rename-dst.txt` 200. Evidence table saved to `docs/live-evidence/2026-08-18-classic-roundtrip.md` (tracked). **Promotions the evidence genuinely supports, and only those:** Task 4.1 and 4.2 → `[x]` (the download/hydration hand-off, whose sole remainder was "exercise live with a signed app + credentials", is now byte-exact-proven); Task 6.0 → `[~]` (its make-or-break question — *can a domain be added and enumerated at all on a signed build* — is answered **yes**; only the *GitHub-hosted-runner* leg of its headline remains). **Deliberately left `[~]` because their remainder is genuinely untested:** Task 4.4 (the **conflict mechanism** — a Phase 4 open question — and the oCIS ID-addressed path were not exercised; create/modify/delete/rename were, and are recorded), Task 5.1 (oCIS domain add needs an OIDC fixture; Classic add is proven and partly superseded by Phase 7). **Honest gaps in this run:** server→client *change* enumeration lagged the observation window (not claimed); oCIS anything (Basic-auth-only fixture); the automated Gherkin acceptance suite (Task 6.3/6.4 action bodies) — verification here was manual, not the runner. No `[~]`→`[x]` flip was made without the stated live evidence.
* *2026-08-18 (Task 6.3 — the Classic fixture-state action bodies, headless + proven live)*: built and proved the automatable half of the acceptance harness that Task 6.3 named — the server-side operations the scenarios' Given/When steps drive to put a fixture into a known state, all test-first (367 core tests green + 8 skipped in the unit run; 2 new live contract tests green against the Docker Classic fixture; signed `xcodebuild build` BUILD SUCCEEDED). `ClassicBackendAdmin` composes `WebDAVRequestBuilder` + the injected `RemoteClient` into `createFile(path:contents:)` (PUT), `createFolder(path:fileCount:)` (MKCOL then N distinctly-named PUTs — the "folder containing N files" fixture the large-enumeration scenario needs), and `deleteFile(path:)` (DELETE); a non-2xx propagates as `RemoteError` so a failed provisioning step surfaces rather than silently no-op'ing. Four headless `ClassicBackendAdminTests` capture the exact `URLRequest`s a stub transport receives (method/URL/body/ordering), each RED→GREEN watched to fail for a missing-type reason first; one GREEN fix along the way — the folder loop's `1...max(fileCount,0)` would trap on `fileCount == 0`, replaced with a `guard fileCount > 0`. Then `ClassicBackendAdminContractTests` runs the same type against the **live** fixture (`make up BACKEND=classic`, gated on `OWNCLOUD_TEST_BACKEND=classic` like `BackendContractTests`, wired into the classic CI leg's `--filter`): create → server GET 200 with byte-exact contents, delete → 404, a 5-file folder → exactly 5 children by Depth:1 PROPFIND — both pass locally. This closes the *fixture-provisioning* half of the Task 6.3 harness end to end; what keeps 6.3 `[~]` is the genuinely Mac-only remainder — the `NSFileProviderManager` domain-lifecycle helper and the materialisation-state observer (the task's open question) — plus the oCIS fixture-state bodies, which await an OIDC-capable fixture. This slots directly beneath the pure `StepRegistry` (PR #9) + `ScenarioRunner` (PR #10): the runner now has real Classic action bodies to bind its "the server has a file"/"a file is created on the server"/"the file is deleted on the server"/"folder containing N files" steps onto.
* *2026-08-18 (Task 6.4 follow-up — the Classic server-side step bindings, headless)*: connected the three previously-disconnected acceptance pieces for the Classic backend, test-first (374 core tests green + 8 skipped; signed `xcodebuild build` BUILD SUCCEEDED). Until now the catalog (which step patterns exist), the `ScenarioRunner` (walks a scenario's steps and dispatches through an injected `ActionLookup`), and `ClassicBackendAdmin` (performs the WebDAV operations) were three separate types with no wiring between them — a scenario's `Given the server has a file …` / `When a file … is created on the server` steps had nowhere to dispatch. **`ClassicStepBindings`** is that join: it maps the catalog's four fixture-state patterns (`the server has a file {string}`, `… a folder {string} containing {int} files`, `a file {string} is created on the server`, `the file {string} is deleted on the server`) onto the `ClassicBackendAdmin` calls and exposes exactly the `ScenarioRunner.ActionLookup` the runner consumes. 7 `ClassicStepBindingsTests`, each RED→GREEN watched to fail for the missing-type reason first: driving a real `ScenarioRunner` over the catalog registry + these bindings against a stub transport proves a scenario's Given/When server steps issue the right WebDAV requests in order (PUT / MKCOL+PUTs / DELETE), that a server 500 fails the run at the offending step (never a silent pass), and that a Mac-only step (`the domain is enumerated`) stays **unbound** so the runner reports `no action bound` rather than the binding layer swallowing it — and such a step never touches the wire. So for Classic the whole chain feature-text → parse → match → dispatch → WebDAV request is now pure and proven headlessly. All Foundation-only / Linux-buildable. **Still `[~]` (Task 6.4/6.3):** the remaining action bodies — the Mac-only domain-lifecycle + materialisation-assertion steps (`NSFileProviderManager`) and the oCIS server-side bindings (need an OIDC-capable fixture) — stay Mac + Docker + signing gated. This slots directly beneath the `ClassicBackendAdmin` slice (PR #12): the runner now actually executes the Classic fixture-state steps end to end against a backend.
* *2026-08-18 (LIVE oCIS OIDC sign-in against the real Konnect IDP — Tasks 7.8/7.12/2.5 evidence, still `[~]`)*: retired the assumption that the oCIS OIDC flow "needs an OIDC-capable fixture we don't have". The Docker fixture (`owncloud/ocis:8.2.0`) *does* run a full OIDC IDP (Konnect); the interactive login page sits in front of a scripted JSON logon API (`/signin/v1/identifier/_/logon`) — the same seam browser-automation OIDC e2e suites use — so the whole sign-in *protocol + decision* path is drivable headlessly against the real IDP, with only the AppKit web sheet out of frame (its own GUI gate). Built `OCISSignInContractTests` (in `FileProviderSupportTests`, gated on `OWNCLOUD_TEST_BACKEND=ocis`, wired into the oCIS CI leg's `--filter`): it drives the **production** chain, no reimplementation — `OIDCSignInCoordinator.signIn` (live `/.well-known/openid-configuration` discovery via `OIDCConfiguration`; authorize URL + `PKCE.challengeS256`; the injected `authorize` closure scripts Konnect logon+authorize and returns the real `?code=` callback; `OIDCAuthorizationRequest.authorizationCode` validates state + extracts the code; `OIDCTokenRequestBuilder.exchange` + `OIDCTokenResponse.credentials` redeem it) → real `access_token` (len 1267) + `refresh_token` + `id_token`, `Bearer`, `expires_in=300` → the bearer token authorizes `GET /me/drives` through `GraphRequestBuilder.listDrives` + `GraphJSONDecoder.decodeDriveList` (2 drives: personal `Admin`, virtual `Shares`; a 401 would fail the run) → `OCISSignInResolver.resolve` yields a `.ocis` account named from the `id_token` claims (`preferred_username=admin`, `email=admin@example.org`), one `SyncRoot` per drive, a 2-space `SpaceCatalog` → `OIDCTokenRequestBuilder.refresh` runs a real `refresh_token` grant that returns a fresh bearer token (the Task 2.5 refresh path, oCIS side). Ran green live against `https://localhost:9200` (fixture up via `docker compose … up -d --wait`); full unit run 375 tests + 9 skipped (contract tiers self-skip without the env var); signed `xcodebuild build` BUILD SUCCEEDED. Evidence table in `docs/live-evidence/2026-08-18-ocis-oidc-signin.md`. **Two implementation fixes found while wiring the live harness (test-only, not production):** the `__Secure-KKT` Konnect session cookie is dropped by `URLSession`'s ephemeral storage, so the harness captures it from the logon `Set-Cookie` and replays it by hand on the authorize GET; and the trust delegate must refuse the authorize redirect (`willPerformHTTPRedirection` → nil) so the `?code=` callback is read from the `Location` header rather than chased. **Deliberately still `[~]` (no `[~]`→`[x]` flip):** the AppKit web sheet (`WebAuthorizationPresenter`), the `SettingsModel` oCIS branch (coordinator → resolver → credential persist → one domain per sync root via `DomainService`) + its redirect-scheme `Info.plist` entry, a live oCIS domain mount in Finder (5.1 oCIS leg), oCIS push/enumerate + the conflict mechanism (4.4 oCIS leg), and the refresh-token *concurrency arbitration* of 7.6 (the grant is proven; the single-flight arbitration is separate). Those need the Mac FileProvider host, not the IDP — which is now proven. The gate this closes is "can the OIDC protocol be driven headlessly at all?" — **yes**, and the pure sign-in chain is now live-verified against the real IDP.
* *2026-08-18 (LIVE-DISCOVERED production bug: oCIS enumerate endpoint — fixed via TDD; Task 3.2 oCIS leg)*: driving the signed extension against the live oCIS fixture surfaced a real defect that headless mocks could not — `GraphRequestBuilder.enumerate` addressed the drive root with the MS-Graph shortcut `GET /graph/v1.0/drives/{driveID}/root/children`, which **oCIS 8.2.0 returns HTTP 404 for even with valid auth**, so a live oCIS domain enumerated to nothing. Confirmed with real bearer auth against `https://localhost:9200`: `/root/children` → 404, while `/items/{rootID}/children` → 200 returning the listing (incl. the seeded `ocis-probe.txt`); the personal drive's `root.id` equals the driveID string. A latent second defect sat beside it — `BackendConnection.enumerationSource(for:)` ignored the `container` item id for oCIS and always built the source from the `driveID`, so every subfolder silently re-listed the root. **Fix (test-first, RED watched first):** `enumerate(driveID:itemID:cursor:)` is now item-addressed — `/items/{itemID}/children` (first page) / `/items/{itemID}/delta?$token=…` (cursor); the root container's item id is the drive root id (== driveID) and `enumerationSource(for:)` now passes a subfolder's own item id, so descending into folders enumerates the folder. Updated `RemoteRequestBuilderTests`/`BackendConnectionTests`/`RemoteEnumerationSourceTests` to assert the item-addressed URLs (the old `/root/children` assertions became the RED anchor); full `swift test` green on macOS **and** Linux parity (`docker run swift:6.0-jammy`, the enumeration subset 57 tests / 0 failures, `swift build --build-tests` clean); signed `xcodebuild build` BUILD SUCCEEDED. Also fixed the DEBUG-only `DevHarnessOCIS` to remove domains with `.removeAll` (not the sign-out default `.preserveDownloadedUserData`) so a repeat live run starts from a clean FileProvider cache rather than replaying a stale root enumeration. Delta change-tracking stays a documented remainder: every `/delta` variant 404s on oCIS 8.2.0 and `/children` emits no `@odata.nextLink`, so the cursor branch is kept item-addressed for consistency but not claimed working. Evidence: `docs/live-evidence/2026-08-18-ocis-enumerate-endpoint.md`. **What this does NOT yet prove:** the live Finder-mount enumeration through the signed extension — the sandboxed extension validates the fixture's self-signed cert against the **System** trust store, and the oCIS container logged `TLS handshake error … EOF` during the extension's enumeration window; trusting `CN=OCIS` in `/Library/Keychains/System.keychain` needs an interactive `sudo` password (curl succeeds via the login keychain, which the sandboxed extension does not consult). That is the same cert/GUI environmental gate documented elsewhere — the fix is proven independently by unit tests (macOS+Linux) and live curl (404→200). No `[~]`→`[x]` flip made.
* *2026-08-18 (Task 7.13 / GitHub issue #17 — oCIS OIDC sign-in reachable from the settings UI)*: the product could not connect to oCIS at all — the Add Account sheet collected Server/User Name/Password, and an oCIS URL hit `SignInResolver`'s `.ocisNotSupportedYet` ("OpenID sign-in isn't supported here yet"), even though Task 7.12 had already live-proven the whole OIDC chain. Closed the gap plus the three real defects behind it, test-first throughout (**409 core tests green + 10 skipped**; 2 live oCIS contract tests green; signed `xcodebuild -scheme App build` **BUILD SUCCEEDED**). **Registration (owner's choice, then proven rather than assumed):** oCIS's shipped ownCloud iOS client (`mxd5OQ…OxkY1`, redirect `oc://ios.owncloud.com`, scope `openid profile email offline_access`) driven by `ASWebAuthenticationSession(callbackURLScheme: "oc")`; its secret is a **published default present in every oCIS install, not a confidential credential** (RFC 8252 §8.5 — PKCE, not the secret, protects a native client), stated in a doc comment on `OCISClientRegistration` so it can't be mistaken for one. **Headless pieces, each RED→GREEN:** `client_secret` threaded through `OIDCTokenRequestBuilder.exchange`/`.refresh` (appended only when non-nil; lico takes it as a plain form field) and forwarded by `OIDCSignInCoordinator` / `OIDCRefreshHandler.make`; `OCISSignInResolver.resolve(…, spaces: .personalOnly)` mounts exactly the personal drive (`noPersonalSpace` when absent) while still returning the full catalog for the Spaces tab; `AddAccountFlow` owns the two-step sheet's wording/busy/`canSubmit`; `OIDCSessionStore`/`OIDCSessionRecord` hand the *refresh parameters* to the extension through the shared app group (tokens stay in the Keychain — the extension never runs discovery, so it cannot otherwise know the token endpoint); `SynchronousTokenSender` bridges `URLSession` onto the deliberately-synchronous `OIDCRefreshHandler.Send`, mapping `400` → `.authenticationRequired` ahead of the general status classification so a revoked grant reads as re-authenticate. **A design flaw caught while wiring the sheet, fixed test-first:** `SignInResolver.route` validated the username *inside* its `.classic` branch, so the new server-first step — which has no username yet — would have failed `.emptyUsername` and dead-ended the Classic path at its own first step. Split into `route(serverURL:probe:)` → `.classic(serverURL:)`/`.oidc(serverURL:)` and `resolveClassic(serverURL:username:password:)`, with `SignInRoute` no longer carrying a resolved account. **Mac glue:** `SettingsModel` routes the probe (cached per server string so submitting a password doesn't re-probe) and on `.oidc` runs the production coordinator → `listDrives` → resolver → Keychain → catalog cache → session record → one `DomainService.addSpace` per sync root, in that documented load-bearing order; `handleLaunch` re-runs it for an `.ocis` account so the Task 7.9 reconnect deep link actually reconnects; sign-out drops the session record; `AddAccountSheet` just renders the flow; the app declares the `oc` scheme in `Info.plist`. **The `expires_in=300` fix:** `FileProviderExtension.authorization(for:)` now builds `SessionManager` with `OIDCRefreshHandler` + `SynchronousTokenSender` + a per-account app-group `FileLock` whenever a session record exists (per account because several extension instances share one Keychain item); Classic keeps the refresh-less path. Without this an oCIS mount stopped working five minutes after sign-in. **Live proof (the one thing unreadable from source):** `OCISSignInContractTests` now drives the *shipping* registration against real Konnect, so a wrong client id/secret/redirect fails a test rather than only failing in the GUI; it also pins the personal-only selection (1 sync root == the personal drive, catalog still 2 spaces) and, in a second test, assembles the extension's exact refresh stack over a **pre-expired** token — Konnect renews it, a future expiry is persisted, a refresh token is retained, and the renewed header authorizes `listDrives`. That proves the refresh wiring immediately instead of after a five-minute wait. **Live finding worth keeping:** the mobile client is `trusted: false` in oCIS's shipped registration, so lico *always* forces consent (`identity/managers/identifier.go` — "If not trusted, always force consent") where the `web` client skipped it; the scripted stand-in therefore grants consent (`POST /signin/v1/identifier/_/consent`, then `konnect=<state>` on the authorize GET, replaying the `__Secure-KKTC-…` cookie whose *name* is a blake2b hash over the request parameters). Diagnosed from the real 302: without consent, authorize redirects back to the sign-in form with `flow=consent` and the code never arrives — which is exactly the `missingCode` failure the first live run produced, so the harness surfaced the extra step rather than hiding it. **Not flipped to `[x]`:** the live Finder leg (web sheet → personal-space domain mounting/enumerating, then a re-enumeration >5 min later) is blocked by the same **System-keychain** self-signed-cert gate as the oCIS enumerate fix — the sandboxed extension and `ASWebAuthenticationSession` consult the System trust store, which no test delegate can influence, and trusting `CN=OCIS` there needs an interactive `sudo`. Task 7.13 stays `[~]`; Tasks 7.8/7.12 keep `[~]` with their remainder narrowed to that GUI leg, and Task 2.5's "reconcile the sync `RefreshHandler` with async networking" remainder is now done.
* *2026-08-18 (Task 7.13 continued — the live leg ran, and found a defect that had silently disabled oCIS token refresh)*: **this entry supersedes the closing claim of the entry above.** That claim — that the live Finder leg was blocked by the System-keychain self-signed-cert gate — is **withdrawn**. Once the fixture's `CN=OCIS` cert was trusted, the live leg ran, and the oCIS mount still stopped working; the sandboxed extension turned out to be reaching the server over TLS perfectly well. The fixture's own proxy named the real failure — `"failed to verify access token: token has invalid claims: token is expired"`, `"user_agent":"FileProviderExtension/1"` — i.e. `expires_in=300` had elapsed and **refresh was never running**, in spite of the wiring recorded above being correct and green under contract test. **Root cause, one line of XML:** `com.apple.security.application-groups` was declared as the bare `group.com.owncloud.macos.fileprovider` in all three entitlements files, and likewise in the extension's `NSExtensionFileProviderDocumentGroup`, with no `$(AppIdentifierPrefix)`. On macOS an application group id **is** `<TEAMID>.group.…`; the bare form is accepted everywhere it is *declared* — compiler, `codesign`, provisioning — and then splits the two processes at runtime. The **app** creates `~/Library/Group Containers/group.…` on first write and, as its creator, keeps working, so the app half of every feature looks right; the **extension** asks the sandbox for a container it is not entitled to and is denied, so `containerURL(forSecurityApplicationGroupIdentifier:)` returns an unopenable path and `UserDefaults(suiteName:)` returns a suite containing **none** of the app's keys — **with no error raised on either side**. `keychain-access-groups` in the same files already carried the prefix, so credentials crossed the boundary and *only* the app-group reads failed, which is exactly what hid it. Because `FileProviderExtension.makeSession` attaches `OIDCRefreshHandler` only when an `OIDCSessionRecord` is readable and otherwise falls back to a refresh-less `SessionManager` — deliberately, since a Classic account has no record — the failure was **silent**: no record, refresh-less fallback, every oCIS mount dead 300 seconds after sign-in, presenting on the Mac as an empty Finder folder. **Localised with lldb** (both `log show` and `~/Library/Application Support/FileProvider` are TCC-blocked here even with the sandbox off, so `docker logs` + lldb were the only channels; `expr -l swift` needs `as NSString`/`as NSNumber`, since a bare Swift `String` gives "summary string parsing error"): same identifier, same moment, the app saw **6** `com.owncloud` keys plus a 270-byte session record and wrote to the container fine, while the extension saw **0** keys and was **denied** the write. **A second earlier claim is also withdrawn:** that a 21-minute-old hosted domain still enumerating proved refresh worked — it was served from the local replica, and the Keychain's `expiresAt` had never moved. **Fix:** new `Core/Sources/OwnCloudCore/AppGroup.swift` (`teamID` / `bareIdentifier` / `identifier`) as the single place the runtime id is written, with the whole failure mode in its doc comment — a *runtime* string cannot reference `$(AppIdentifierPrefix)`, so the team id is declared there and the two must agree; `$(AppIdentifierPrefix)` added to all three entitlements files and to `NSExtensionFileProviderDocumentGroup`, each with a comment on why the bare id must not return; `SettingsModel`, `FileProviderExtension` and `DevHarnessOCIS` switched from local literals to `AppGroup.identifier`. New `AppGroupIdentifierTests` — 4 tests that read the four declaration files and three Swift sources off disk and fail if any drops the prefix or reintroduces the bare id. A convention would not have caught this; the wrong value raises no error at any stage, which is precisely why it needed pinning by test. **Verified at three levels:** unit — **421 tests, 10 skipped, 0 failures** including the new guards; mechanism — the extension's container write flipped **"UNPREFIXED WRITE DENIED" → "EXT CONTAINER WRITE OK"**, and both signed declarations now read `4AP2STM4H5.group.com.owncloud.macos.fileprovider` (`make install` BUILD SUCCEEDED, `codesign --verify --deep --strict` passed, both `.appex` embedded); end to end — a fresh sign-in through the **shipping Add Account sheet and the real browser sheet** produced sidebar row **`admin@localhost` / Infinite Scale**, with the `accounts` entry, the `oidc-session` record (`tokenEndpoint: https://localhost:9200/konnect/v1/token`) and the 2-space `spaces` catalog all written into the **prefixed** container. So the browser sheet, sign-in and domain-add — previously the `[~]` remainder — are now live-proven. **Method note kept deliberately:** the oCIS proxy logs **only failures**, so a successful request emits no line at all and "zero log lines" is *not* evidence of success; it was read that way earlier in this investigation and cost time. Assert on a positive signal, never on silence. **Task 7.13 still `[~]`, honestly:** the server-side round trip is unproven — a file written into the domain appearing in the server's own children listing, plus a re-enumeration >5 min later to watch refresh in situ. The first attempt was **inconclusive rather than negative** and is not counted: it ran against `~/Library/CloudStorage/ownCloudFileProvider-Admin`, a stale replica directory reused by display name still holding `probe.txt`/`enum-trigger.txt` from the pre-fix domain, with six other stale `ownCloudFileProvider-*` domains still registered — that reading proves nothing either way, and a clean run needs them removed first. Two housekeeping defects noticed and not fixed: a stale `spaces.…` app-group key survives Sign Out, and old domain directories accumulate. Full write-up: `docs/live-evidence/2026-08-18-app-group-prefix.md`. **Transferable lesson:** a silent fallback needs a loud diagnostic — `makeSession`'s refresh-less path is correct for Classic and catastrophic for oCIS and could not tell the two apart; the missing log line cost the entire investigation.
* *2026-08-19 (Task 7.13 / issue #17 — the in-situ refresh leg closed, and two unrelated oCIS push bugs found)*: finished the one item issue #17 still owed and, in doing so, found the real reason nothing written into an oCIS mount reaches the server — which turns out **not** to be #17's fault. **The methodological fix that unlocked all of it:** the fixture runs `OCIS_LOG_LEVEL: error`, so a *successful* request emits no log line whatsoever; every earlier "zero log lines" reading was therefore uninformative rather than reassuring. Restarting the fixture with `OCIS_LOG_LEVEL=info` (an **env override only** — `test/fixtures/ocis/docker-compose.yml` is unchanged, and the original container was restored afterwards) turns on the proxy **access log with status codes**, which converted the whole exercise from arguing about silence into reading positive signals. Recorded prominently in the evidence file: *turn the access log on first* in any future live oCIS debugging. **Clean re-run of the mount, because the previous attempt was confounded rather than merely unlucky:** `~/Library/CloudStorage/` directories are **reused by display name and survive domain removal**, so the earlier check had read a stale replica still holding `probe.txt`/`enum-trigger.txt` from the pre-fix domain — a stale replica will happily serve a "successful" listing that never touched the server. So: every domain removed with `.removeAll` and the disappearance of the `…-Admin` directory verified, then the domain re-created through the **production Task 7.9 reconnect deep link** (`owncloud-fileprovider://reconnect?account=ocis|…` → `handleLaunch` → `signInWithOIDC`), which opened the real browser sheet at `signin/v1/identifier?client_id=mxd5OQ…&redirect_uri=oc%3A%2F%2Fios.owncloud.com&code_challenge_method=S256`, took `admin`/`admin`, went through the **forced-consent** step (the untrusted-mobile-client behaviour already recorded), and produced an **empty, freshly created** replica. That incidentally makes the **oCIS reconnect deep link live-proven**, not just the Add Account sheet. **The in-situ refresh proof (Task 7.13's last open item, and Task 2.5's):** a write into that domain **~7 hours after sign-in**, against `expires_in=300`, produced `200 POST /konnect/v1/token` followed by `200 GET /konnect/v1/userinfo` and `200 GET /graph/v1.0/me/drives` on the renewed bearer, with **zero** `token is expired` from the extension. (One such line does appear in the log from `user_agent: …Chrome/151…` — a browser tab of mine hitting a probe file, not the extension; worth noting because attributing it to the extension would have been an easy fourth misdiagnosis.) So the real extension's refresh stack — `SessionManager` + `OIDCRefreshHandler` + `SynchronousTokenSender` + the per-account app-group `FileLock`, reading its parameters from the now-reachable app group — **works in situ**, which is the one thing the contract test could only simulate. The extension was also re-probed in a fresh process and sees `container=true`, `write=OK`, all **3** app-group keys including the 270-byte `oidc-session` record, so the app-group fix holds across extension restarts. **Two pre-existing bugs the access log exposed, deliberately NOT fixed here** (they belong to Task 4.4's oCIS push leg, are unrelated to the app group or OIDC, and #17's scope is sign-in reachability): **(1)** `PUT /graph/v1.0/drives/{drive}/root:/{name}:/content` → **404**, as does the item-addressed `…/items/{rootID}:/{name}:/content`, while `PUT /dav/spaces/{drive}/{name}` → **201** and the file then shows up in the Graph children listing — oCIS 8.2.0 does not serve the Graph content-upload path `GraphRequestBuilder.uploadNewFileUnderRoot`/`.uploadNewFile` emit, and the **WebDAV spaces route is the working one**; this is the same class of defect as the `/root/children` enumerate 404 fixed in #15, which suggests the Graph builder needs a systematic audit against 8.2.0 rather than another one-off fix. **(2)** `GET /graph/v1.0/drives/{drive}/items/NSFileProviderWorkingSetContainerItemIdentifier/children` → **404** — `NSFileProviderItemIdentifier.workingSet` is passed through as a literal item id instead of being mapped, the way `.rootContainer` already is mapped to the drive id. Both recorded under Task 4.4 with the failing verbs and the working alternative. **Honest status:** issue #17's own scope — oCIS reachable from the settings UI, personal space mounting, and the mount surviving past `expires_in=300` — is **complete and live-proven**; Task 7.13 nonetheless stays `[~]` because **no file written into an oCIS mount reaches the server yet**, blocked by those two Graph-layer bugs rather than by anything in this task. Task 2.5's in-situ remainder is now genuinely done, leaving only the signed-host `SecItem` round trip. Unit suite re-verified green at **421 tests / 10 skipped / 0 failures**, and all four app-group declarations re-checked as `4AP2STM4H5.group.com.owncloud.macos.fileprovider` in the signed app and `.appex`. Evidence: `docs/live-evidence/2026-08-18-app-group-prefix.md`.
* *2026-08-19 (issue #18 — app icon in all three bundles + a real About window)*: the repo had **no asset catalog at all**, so macOS fell back to its generic placeholder — visible in the issue screenshot both in the Finder sidebar next to every sync root and in the About panel, which was AppKit's unmodified default (name, `0.0.1 (1)`, nothing else: no copyright, no links, and no way for a bug reporter to say which extension build they were running). **Artwork:** the official `oc-logo-1c-blue-RGB.svg` is committed unmodified under `Resources/Icon/` with its provenance (source URL, path inside the zip, SHA-256) in a README; only **path index 8** — the cloud mark — is used, because the "ownCloud" wordmark in paths 0–7 is illegible at the 16 px the Finder sidebar renders. `Resources/Icon/make-icon.swift` (run via `make icons`) composes the mark at 78 % of canvas width on a white squircle following Apple's macOS grid (art box `824/1024`, corner radius `185/824`) and rasterizes the ten 16/32/128/256/512 @1x/@2x PNGs into `Resources/Assets.xcassets/AppIcon.appiconset/`; it **measures the cloud's bbox from the path data** rather than hardcoding it, and fails loudly if path 8 stops being wider than tall, so refreshing the upstream SVG cannot silently mis-centre the mark. Output is deterministic (byte-identical across runs), so the PNGs are committed and generation stays manual — out of `install` and out of CI. **Two findings worth recording, both cost real time:** (1) `qlmanage -t` is a **dead end** for this — it forces square output *and* composites onto opaque white, so the squircle's corners came back `(255,255,255,255)` instead of transparent; the AppKit route (`NSImage` → `_NSSVGImageRep` → `NSBitmapImageRep` with `imageInterpolation = .high`) preserves alpha and needs no Homebrew tooling, which matters because `magick`, `convert`, `rsvg-convert` and `inkscape` are all absent here. (2) **An extension target needs `ASSETCATALOG_COMPILER_APPICON_NAME` set explicitly** — the App target gets it for free, but without it on the two `.appex` targets `actool` runs and the `.appex` still ships an empty `Contents/Resources`: no icon, no warning, no error. That was the one step that would otherwise have silently no-opped. All three targets share the one catalog via `sources:`, and all three `Info.plist`s carry `CFBundleIconName`/`CFBundleIconFile` explicitly because `GENERATE_INFOPLIST_FILE: NO` means actool's partial plist is never merged; the app also gained `NSHumanReadableCopyright`. **About window:** built test-first in the Phase 7 shape — `AboutInfo` in `OwnCloudCore` owns every rendered string (name, version summary, the four detail rows, copyright, the three link URLs) with the year and OS version *injected* rather than read from the clock so the output is deterministic, covered by nine `AboutInfoTests`; `App/Sources/AboutWindow.swift` is a thin SwiftUI renderer and `AboutInfoReader` the bundle-reading adapter. It reports the app, **both extensions** (read from `Contents/PlugIns/*.appex` — they load out-of-process and can be stale relative to the app, which is the whole reason to list them separately), the core version and the host macOS version, each row `.textSelection(.enabled)` so it can be pasted into a bug report; an unreadable bundle degrades to a legible `Unavailable` row rather than vanishing, since the About window is what a user opens *because* something is wrong. `CommandGroup(replacing: .appInfo)` points ⌘-About at it. **Verified live** on the installed signed build (`codesign --verify --deep --strict` clean, 340 core tests green, BUILD SUCCEEDED): `make icons` re-run leaves a clean `git diff`; the committed PNGs are pixel-exact `041E42FF` in sRGB with transparent corners at 16/128/1024 px; `AppIcon.icns` + `Assets.car` and `CFBundleIconName` are present in the app and **both** `.appex`; the About window was captured from the running app with both extension versions populated. Two method notes for the next person: **(a)** macOS 26 applies its own treatment to a flat legacy `.appiconset` — extra corner rounding, a gradient sheen, a lightened blue — so the *rendered* icon does not match the source bytes; migrating to Icon Composer / a `.icon` bundle would be a separate change. **(b)** The Finder sync-root row is driven by the **`.appex`** icon, not the app's — an icon-less extension yields the generic white "plugin brick", which is precisely why `ASSETCATALOG_COMPILER_APPICON_NAME` on the extension targets is load-bearing rather than belt-and-braces. Confirmed by screenshotting Finder before/after. Three traps: `NSWorkspace.icon(forFile:)` is not a valid oracle (it reports generic even for iCloud Drive); Finder caches the root icon from mount time, so `killall Finder` is required before judging; and the sibling checkout `macos-fileprovider` (no `-2`) installs to the same `~/Applications` path with the same bundle id, so it can silently replace this checkout's build mid-verification.

* *2026-08-19 (Task 4.5 — oCIS sync moved off Graph onto per-space WebDAV)*: closed the gap Task 4.4 recorded as *"no file written into an oCIS mount reaches the server"*. The premise of the fix is that this was **not** a wrong endpoint to correct one URL at a time: oCIS 8.2.0 serves none of the Graph content endpoints this code targeted (`PUT …/root:/{name}:/content` 404, item-addressed variant 404, `/root/children` 404 — the last already patched once in #15), while the same operations over `/dav/spaces` all succeed. `owncloud/client`, the reference the user pointed at, is built exactly that way: its whole Graph layer is one drives job, and `Space::webDavUrl()` feeds the *same* PROPFIND/PUT/MKCOL/MOVE/DELETE jobs Classic uses, with no oCIS conditional in the sync path. So Graph is now used **only** for `me/drives`, the dead file-operation layer is **deleted** rather than left to mislead (`GraphRequestBuilder` keeps `listDrives()` alone; `GraphEnumerationSource`, `EnumerationPage.init(graphCollection:)` and `init(graphItem:)` are gone), and `BackendConnection`'s oCIS branch emits WebDAV throughout — which incidentally makes create/modify/move reconcile through a Depth:0 read-back exactly as Classic does. **Two deliberate divergences from `owncloud/client`, each forced by live probing:** oCIS identifiers are **stable `oc:fileid`s, not paths** (an id survives rename *and* reparent, so oCIS identifiers cannot go stale the way Classic's must — only *create* is name-based, under its id-addressed parent); and the addressing base is the **`/dav/spaces` collection**, not `/dav/spaces/{driveID}`, because a fileid already begins with the drive id and is its **sibling** — `PROPFIND /dav/spaces/{fileID}` → **207** vs `…/{driveID}/{fileID}` → **404**. `owncloud/client` can use the per-space URL as a base only because it addresses items by *path*. **A real bug found by reading the log rather than trusting the plan:** the plan listed only `workingSet` among the framework's reserved identifiers, but the access log showed `PROPFIND /dav/spaces/NSFileProviderTrashContainerItemIdentifier` → **404** repeating for as long as the domain stayed mounted. Trash was deliberately **not** mapped onto the root — that would have zeroed the 404s while presenting every live file as trashed, with "Put Back"/"Empty Trash" then acting on real data — so `resolvedContainer` returns `nil` for it and the provider refuses, which is the framework's own answer for a provider without trash. It also turned out the first fix was in the wrong place: mapping in `enumerator(for:)` alone left the 404s coming from **`item(for:)`**, which only short-circuited `.rootContainer`; both call sites resolve now. **The methodological trap, worth more than the fix:** two consecutive "verification" runs were **invalid**, and both looked like success at first. `make install` had deployed a **stale** bundle — its dylib still contained the deleted Graph path strings and no `dav/spaces` at all — and macOS separately caches the registered appex, so the *running* extension was pre-refactor code even after a clean build. Finder showed the file; the server did not have it. What exposed it was comparing built-vs-installed **sha256** (not mtimes, which matched) and grepping the installed binary for strings that should no longer exist; `pluginkit -r`/`-a` then forced re-registration. Byte-identical binaries plus a fresh registration are now the precondition for any live claim in this repo. **Live proof, on the third and valid run:** `MKCOL` 201, `PUT` 201, `MOVE` 201 (fileid unchanged across a combined rename+reparent), `GET` 200, edit `PUT` 204, `DELETE` 204 — each step confirmed **server-side by an independent `curl`**, with the edited file returning its exact bytes and 404ing after the delete. The access log for that window holds **zero** 4xx/5xx, **zero** Graph file-operation requests and **zero** reserved-identifier requests; Graph appears only as `me/drives` 200. Headless: **441 unit tests / 14 skipped / 0 failures**, plus 4 new live legs in `BackendContractTests` (`root.webDavUrl` reported and agreeing with the derivation; Depth:1 children all carrying `oc:id`; a top-level child parenting to `.rootContainer`, which is the alarm for the root-id derivation; and the full round trip asserting the stable fileid). Task 4.5 → `[x]`; Task 4.4 and Task 7.13 amended to point here, both still `[~]` for reasons that were never oCIS-specific (the conflict mechanism, server→client change enumeration). Fixture note: the `OCIS_LOG_LEVEL=info` override is a temporary compose-override file, not a change to `test/fixtures/ocis/docker-compose.yml`; probe artifacts were cleaned up server-side, leaving only the pre-existing `xxx/`.
* *2026-08-19 (post-merge cleanup — the two housekeeping defects promoted to issues)*: issue #17 and Task 4.5 landed on `main` as **#20** (`e24fa7b`) and **#21** (`fd933d0`), split so each PR reads truthfully on its own rather than as one sweep. The two defects that had been recorded only inside this file are now tracked where they can be scheduled: **#23** — `SpaceCatalogCache` (`AccountRegistry.swift:126`) has **no `remove` method at all**, so the per-account `com.owncloud.macos.fileprovider.spaces.<id>` blob survives Sign Out even though the same path already drops the credential, the registry record *and* the OIDC session record; the fix is the mirror of `OIDCSessionStore.remove(forAccount:)` called beside it in `confirmSignOut`. **#24** — replica directories accumulate under `~/Library/CloudStorage/` and are **reused by display name**, which is the mechanism behind the one discarded live reading in this project, so it is filed as a verification hazard and not merely disk hygiene. **Environment restored:** both fixtures down with volumes removed, the temporary `OCIS_LOG_LEVEL=info` compose override deleted (the committed fixture still reads `error`), and the two merged local branches deleted after confirming `feat/ocis-space-webdav-sync` diffed **empty** against `main` and `feat/ocis-oidc-settings-signin` was its ancestor. **Two traps found while cleaning, both now in #24:** un-materialised placeholders make `tar`/`cp` **hang** when the backing server is gone, so a replica whose domain is still registered must not be archived; and replica subdirectories can carry a cleared write bit (`dr-x------`), so `rm -rf` fails until `chmod u+w`. Only the two Classic replicas were removed (archived first): `fileproviderctl dump` showed **two oCIS domains still registered with running sync engines**, and domain removal is only exposed through the app's dev harness, so those directories were left in place rather than pulled out from under a live domain.
* *2026-08-19 (issue #26 — account removal made discoverable and confirmed; #23 fixed alongside)*: the capability the issue reports as missing was in fact **present but unfindable and unsafe**, which is a more interesting defect than a missing feature. The only affordance was a `Sign Out…` button inside the Account tab, and it was wrong in four separate ways at once: the name **understated** it (it deleted the domains, the Keychain item *and* the registry record — the account was gone, not signed out), `SettingsModel.confirmSignOut` **confirmed nothing** despite its name (removal happened on the first click), it hard-coded `.preserveDownloadedUserData` so the keep-or-delete choice space deselect already offered was never presented, and it was **absent from the accounts sidebar**, which had `Add Account…` and no counterpart. All four are addressed: `DomainService.signOut` → **`removeAccount`** (body and its crash-safe ordering — domains → credential → registry record last — deliberately unchanged, so `DomainServiceTests`' ordering assertions stayed green as-is and the rename is provably behaviour-free); a new **`AccountRemovalPrompt`** presenter in `OwnCloudCore` following the Phase 7 shape, so every rendered string is headlessly tested and the SwiftUI layer only arranges it; and **two** sidebar affordances — a `Remove Account…` context-menu item on the row (acting on the right-clicked row, not the selection) and a `−` button beside `Add Account…`, both routed through the same prompt as the Account-tab button, so there is one confirmed path rather than two behaviours. `AccountRemovalPrompt` is a **distinct type from `SpaceRemovalPrompt`** rather than a reuse: account removal is strictly wider (it drops the credential and every space at once), and sharing the type would blur two dialogs whose consequences differ. The shared part — the keep-label size rule — was factored into one `keepLabel(downloadedBytes:)` helper both prompts now call, so "name the concrete amount, or drop the clause rather than say *0 bytes*" lives in a single place. A zero-space account drops the space clause entirely instead of claiming "0 spaces", because a zero-space account is legal and is the entire reason `AccountRegistry` exists. **One addition beyond the issue's scope, flagged rather than smuggled:** `removeAccount` was called as `try? await`, so a failed domain removal left the row in place with no explanation — presenting as exactly the complaint in #26. The error is now published into `accountRemovalError` and rendered; `selectedAccountID` is also cleared when it pointed at the removed account, so `reload()` re-selects a survivor instead of leaving a dead selection. **#23 fixed alongside**, as its cause is this same path: `SpaceCatalogCache.remove(forAccount:)` (the mirror of `OIDCSessionStore.remove(forAccount:)`) is called beside its sibling, so the `spaces.<id>` blob no longer outlives the account — account identifiers derive from server + username, so a later sign-in to the same account would otherwise inherit a stale space list. **Live-verified** on the installed signed build against the Classic fixture, asserting positive signals: the confirmation dialog was captured naming the account (`Remove the account "admin@localhost"?`) with correct **singular** "This stops syncing 1 space" and both choices; after **Remove them**, all four stores agreed — sidebar row gone, registry `accounts` entry gone, `fileproviderctl dump` no longer listing the domain, the `~/Library/CloudStorage/ownCloudFileProvider-admin@localhost` replica gone, and the Keychain item for that exact identifier gone; the run was then repeated end-to-end with **Keep the downloaded files**. **The `spaces.<id>` assertion is deliberately *not* claimed from this leg, because on a Classic account it is vacuous:** `catalogCache.store` is called only from `persistAndMount`, the oCIS path, and `spacesTab(for:)` feeds Classic the static `.classic` catalog — so a Classic account never writes a `spaces.<id>` key in the first place and its absence afterwards proves nothing. #23 rests on its three unit tests (round-trip then remove reads `nil`; removing one account leaves another's blob intact), and the live leg corroborates only that the removal path runs `catalogCache.remove` without error. An earlier version of this entry cited that key as live evidence; that was wrong. The `deepdiver` account's own three keys were re-checked as untouched throughout. **Three method notes.** (a) A `SecureField` is **invisible to accessibility** — `value` reads `[]` no matter what it contains — so `val=[]` is not evidence the field is empty; the sign-in step must be judged by its *outcome* (a new sidebar row), not by reading the field back. AppleScript `set value` also does not work on it; a real `keystroke` into a **clicked** field does. (b) SwiftUI `.contextMenu` does not respond to `AXShowMenu`, and a synthetic `CGEvent` right-click only opens it when `mouseEventClickState` is set to 1; the menu then lives outside the process's `windows`/`menus` AX tree, so a **screenshot** is the only reliable oracle. Activation, click and capture must run in **one** shell invocation, or the terminal steals focus between steps and the capture shows the terminal. (c) `UserDefaults` in the app group flushes **lazily** — the plist twice still showed a just-removed account, and re-reading a few seconds later showed it gone. A single plist read immediately after a UI action is not a valid assertion. (d) **Never advance a form with a synthetic tab** (`key code 48`): it appeared to work, the subsequent `keystroke` went nowhere, and because Classic sign-in validates nothing the empty password was accepted silently — the entire 401 misdiagnosis above traces to this. Click each field directly and confirm the field's *rendered* state in a screenshot (a `SecureField` showing the right number of bullets) before submitting. **The keep-vs-remove on-disk distinction is now proven, and the earlier claim about why it wasn't is retracted.** An earlier version of this entry reported the assertion as unachievable, blaming a **401** from the Classic fixture on the pre-existing signed-host `SecItem` gap (Task 2.5's last item). **That attribution was wrong**, and a systematic-debugging pass disproved it three ways: the access log line was `- admin`, and `%u` is populated with the *attempted* user on a bad password but shows `-` when no `Authorization` header is sent at all — so the extension had read the credential and the Keychain was reachable; both bundles carry the team-prefixed entitlement under TeamIdentifier `4AP2STM4H5`; and filling the Password field by **direct click** (instead of the `key code 48` tab that silently never delivered it) produced `PROPFIND … 207` from the same extension immediately. The real cause was **my own input error compounded by a genuine product defect**: `SignInResolver.resolveClassic` rejects only an empty *username* and **never contacts the server**, so an empty or wrong password is accepted, stored, and a domain added, with the failure surfacing much later as a 401 in the extension rather than as a sign-in error. That defect is real, pre-existing and outside #26's scope — filed as **issue #29** rather than fixed here. The same pass also found that `SecItemKeychainBackend` never sets `kSecUseDataProtectionKeychain`, so items land in the legacy ACL-based keychain where `kSecAttrAccessGroup` is **silently accepted and ignored** (probed: `status 0` for the bare group, the team-prefixed group *and* `nil`; the stored item carries no `agrp` attribute), and that the access group is passed **bare** rather than team-prefixed — the same defect class as the app-group bug already recorded here. App↔extension credential sharing therefore works by same-team ACL accident, not the documented mechanism: **issue #30**. **What the completed leg actually shows.** With a correct password, `keeptest.txt` was created *in* the mount (`PUT` 204 + `PROPFIND` 207, sha256 byte-identical to an independent `curl` GET) — note that creating in the mount, not uploading server-side, is the only way to materialize a file today, because `changeProvider` is `nil` at the sole production `ItemEnumerator` call site, so `enumerateChanges` returns `NSFeatureUnsupportedError` and a server-side upload never propagates (the server→client gap already recorded under Task 4.4, not a regression). Then: **Keep the downloaded files** → the domain is gone and the registry record is gone, but the sync root **survives, renamed in place with a timestamp suffix** — `ownCloudFileProvider-admin@localhost (19.08.26 15:22)`, **same inode 49291528**, `keeptest.txt` intact at the same sha256. That is `NSFileProviderManager.remove(_:mode:)` handing back a `preservedLocation`, which `SystemDomainManager.remove` currently discards as `_` — worth knowing, since it means the app cannot tell the user where the kept files went. **Remove them** → on a freshly re-added account with the file hydrated from dataless (`blocks=0` → `GET` 200 → `blocks=8`), the replica directory is **gone entirely**, alongside domain, record and Keychain item, while the earlier preserved directory remained untouched. So the two choices are now distinguished by observed on-disk consequence, not merely by the `DomainRemovalChoice` reaching the service. Headless: **459 tests / 14 skipped / 0 failures**; `xcodebuild -scheme App build` BUILD SUCCEEDED with both `.appex` signed. Fixture brought back up for the keep-files leg above and torn down again afterwards (`make down BACKEND=classic`); note that `make down`/`make up` recreates the volumes, so any file uploaded in a previous run is gone. Two **stale** Classic keychain items from 2026-08-17/18 under older identifier formats were deleted as test debris — worth noting because their presence briefly looked like the credential deletion having failed, until the *exact* identifier this session created was confirmed absent. No `[~]` marker is promoted: Task 7.8's remainder is unrelated to account removal.
* *2026-08-19 (release automation — tag-triggered version stamping + a notarized `.dmg`)*: closed the gap between "the app builds" and "a user can install it". Pushing `v1.2.0` now stamps `1.2.0` into the app **and both extensions**, builds a signed, notarized, stapled `.dmg` and publishes it as a GitHub release; `v1.2.0-rc.1` publishes a prerelease. **What was already in our favour, and worth knowing:** all three `Info.plist`s reference `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)` rather than literals, and command-line build settings outrank project settings — so one `xcodebuild MARKETING_VERSION=… CURRENT_PROJECT_VERSION=…` reaches all three bundles with no new plumbing, and because `AboutInfoReader` already reads exactly those keys from the app and from `Contents/PlugIns/*.appex`, the About window picks the tag up for free. **Two blockers found while planning, either of which would have failed every release:** (1) `ENABLE_HARDENED_RUNTIME` was set **nowhere** (0 hits in the generated `.pbxproj`) and the notary service rejects a submission without it — now in `settings.base`, verified as `flags=0x10000(runtime)` in a real Release archive; (2) `com.apple.developer.fileprovider.testing-mode` is a **restricted** entitlement Apple grants only through a *development* profile, so a Developer ID profile does not carry it and signing fails outright — Release builds now use a `configs:` override pointing at `FileProviderExtension-Release.entitlements` (the same file minus that key), which is correct regardless of signing since the entitlement exists for AC-3's deterministic harness, not for users. Confirmed from the two builds' own `.xcent` files: Release has app-sandbox + app group and **no** testing-mode; Debug still has it. **The stale-version bug the release exposed:** `AboutInfo`'s "Core" row rendered `OwnCloudCore.version`, a compiled-in package constant — a release stamps plists and never rewrites Swift, so that row would have read `0.0.1` inside a `1.2.0` build and contradicted every other number in the window. Row dropped, the app's own `1.2.0 (147)` exposed as `AboutInfo.appVersionDisplay`, the identical bug in `SettingsWindow`'s "Version" field fixed the same way, and a test added asserting **no** row's value equals `OwnCloudCore.version` so it cannot silently come back. **Shape:** the build lives in `scripts/make-dmg.sh` + `scripts/notarize.sh` (reachable as `make dmg` / `make notarize`), not in the workflow, so a release is reproducible on a developer Mac with the same commands CI runs (**AC-4**); `.github/workflows/release.yml` only supplies credentials and publishes, with actions pinned to full SHAs and diagnostics uploaded on failure (**AC-2/AC-6**). `hdiutil` not `create-dmg` (Homebrew image tooling is absent here — the same finding as issue #18); `.dmg` not `.pkg` (a `.pkg` needs a `Developer ID Installer` certificate the team does not have, while the `Developer ID Application` certificate that exists can sign a `.dmg`); the app is stapled **before** the image is rebuilt around it, so dragging the app out of the image onto another Mac still leaves a valid ticket offline. **Three traps found while writing the checks, each of which produced a false pass:** (a) `codesign -d --entitlements` emits *nothing* for an ad-hoc-signed or unreadable bundle, so `… | grep -q testing-mode` "passes" on a failed dump — the guard now requires app-sandbox and the app group to be present as a **positive control** before the absence of testing-mode is allowed to mean anything, and was exercised against four inputs (real Release → pass, real Debug → trips, empty plist → trips, missing file → trips); (b) `plutil -extract` treats the dots in `com.apple.security.app-sandbox` as keypath separators and reports every reverse-DNS entitlement key as missing — `PlistBuddy` is the right tool; (c) verifying the per-configuration entitlements mapping by reading a line range out of the `.pbxproj` is backwards, because `name = <Config>;` sits at the **end** of each `XCBuildConfiguration` block, which made Debug appear to use the Release file. Also: `make-dmg.sh` writes `dist/artifact-path.txt` and `notarize.sh` plus the workflow read it, rather than each re-deriving the filename from `VERSION`/`DMG_NAME` — three independent guesses would diverge the first time the naming changed, leaving an un-notarized image next to a stapled one nobody publishes. **A bug the rebase onto `main` exposed, and the reason a fourth `AppGroupIdentifierTests` path now exists:** the new Release entitlements file was copied from the Debug file *before* #20 added `$(AppIdentifierPrefix)` to the app group, so it carried the **bare** `group.com.owncloud.macos.fileprovider` — precisely the id whose failure mode that whole test class was written to catch, reintroduced in the one file that *ships* while every Debug build kept working. `testEveryEntitlementsFileRequestsTheTeamPrefixedAppGroup` reads all four declaration files now, not three. Worth generalising: a new per-configuration copy of any pinned declaration is invisible to a test that enumerates paths by hand, so adding the file and adding it to the list have to be one step. Fixed and re-verified from the signed Release `.appex`'s own `.xcent`: `4AP2STM4H5.group.com.owncloud.macos.fileprovider`, no testing-mode, `flags=0x10000(runtime)`. **Proven locally:** `make dmg VERSION=9.9.9 BUILD=147` → `** ARCHIVE SUCCEEDED **` with all three bundles reporting `9.9.9 (147)`, hardened runtime on, testing-mode absent; unit suite green at **453 tests / 14 skipped / 0 failures** on top of `098c41f`. **NOT proven, and the reason:** `xcodebuild -exportArchive` fails on this machine with `error: exportArchive No Accounts` / `No profiles for 'com.owncloud.macos.fileprovider' were found` — no Xcode account is signed in and no Developer ID provisioning profiles exist locally. Everything downstream of export (the image, its signature, both notarization submissions, stapling, `spctl`) is therefore **written but unexercised**, and the six repository secrets do not exist yet, so no release has ever run. Task 9.6 stays `[~]` until a throwaway `v0.0.2-rc.1` has gone end to end.
* *2026-08-19 (Tasks 9.7/9.8 — build the installer on every push, not only on a tag)*: acting on the entry above's own conclusion, which was that most of the release path had never run: a first release would have been the first execution of `make-dmg.sh`, `notarize.sh` and `release.yml` simultaneously. The pipeline is now exercised continuously, split along the only line that actually matters — **whether a step needs credentials**. `gh secret list` is empty and the repo is public, so `-exportArchive` and notarization cannot run on a PR *at all*, and never on a fork PR; that constraint, not taste, is what produced two tiers rather than one. **Unsigned, on every PR** (`ci.yml` tier 4 `installer`): `make dmg SIGNING=none VERSION=0.0.0 BUILD=<run number>`, the `.dmg` uploaded for 14 days. `VERSION=0.0.0` deliberately — a smoke build is not a release and an About window reading `0.0.0 (1234)` says so unambiguously while still naming its run. **Signed, on every push to `main`** (`release.yml`): a rolling `main-latest` prerelease, deleted and recreated each time, so Developer ID signing, both notary submissions, stapling and `gh release create` — the last unproven publish step — stop waiting for a tag. `--cleanup-tag` matters: without it the tag survives, `gh release create` refuses to move it, and every later push publishes the *first* commit's image under the new commit's release. **The design constraint that shaped the split, and is worth remembering on its own:** `codesign -d --entitlements <file> --xml` on an **ad-hoc/linker-signed** bundle **exits 0 and writes no file** — proven by probe, not assumed. So the artifact entitlements guard cannot pass unsigned, and letting it try would report "the entitlements did not survive export" about a build that was never signed. It is therefore skipped *loudly*, and `ReleaseEntitlementsTests` (5 cases) covers the declarations instead. Those tests **parse** both plists rather than string-searching them, and that is not stylistic: both files carry a comment block naming `com.apple.developer.fileprovider.testing-mode`, so the literal string occurs once in the Debug file and **twice** in the Release file that deliberately omits it — `contains` would be exactly inverted. Third member of the same family as 9.4's two traps. **Two rails, because a flag that skips a safety check must not be able to produce something mistakable for a release:** the `-unsigned` suffix is appended *inside* `make-dmg.sh` (a caller-supplied `DMG_NAME` gets it too), and `dist/signing-mode.txt` makes `notarize.sh` refuse — recorded as state rather than inferred from the filename, and checked locally rather than at Apple, where the rejection arrives twenty minutes later looking like a notarization failure. **The unsigned archive incantation, verified before anything was built on it:** `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS="" CODE_SIGN_STYLE=Manual`, **and dropping `-allowProvisioningUpdates`** — with automatic signing xcodebuild goes hunting for the very Developer ID profiles whose absence is the reason for building unsigned. **`vars`, not `secrets`, gates the main build:** `secrets.*` is unusable in a job-level `if`, so `RELEASE_SIGNING_ENABLED` is a repository *variable*; without a gate every push to `main` would fail on the certificate import from now until the secrets exist. Setting it is deliberately the user's call and the documented last step of enabling releases. **Proven locally, in full — which is the reason the unsigned tier was built first:** unit suite **458 tests / 14 skipped / 0 failures**; all four mutations of the new tests killed by the right test with an actionable message (`testing-mode` re-added to the Release file, removed from Debug, the app group unprefixed, the `project.yml` mapping deleted); `make dmg SIGNING=none VERSION=0.0.0 BUILD=1` end to end → `dist/ownCloud-File-Provider-0.0.0-unsigned.dmg` with all three skip messages printed and their reasons; `hdiutil attach` showing the app, the `/Applications` symlink, `0.0.0 (1)` in all three `Info.plist`s and `flags=0x20002(adhoc,linker-signed)` on the `.appex`; the About content composed from those shipped bundles reading `Version 0.0.0 (1)` with both extension rows matching, three detail rows and no "Core" row; `make notarize` immediately after **refusing** with exit 1, citing `signing-mode.txt`; `SIGNING=bogus` rejected; and the signed-mode regression check — `make dmg VERSION=9.9.9 BUILD=147` still reaches `** ARCHIVE SUCCEEDED **` and still fails only at `-exportArchive` with `No Accounts`, so the refactor did not change the release path. Both workflow files parse, and the version-derive step was run on both legs (`v1.2.0-rc.1` → `1.2.0`/`1.2.0-rc.1`/prerelease; `main` → `0.0.0`/`main-deadbee`/rolling). **NOT proven, and for exactly the same reason as 9.6:** everything behind `RELEASE_SIGNING_ENABLED`. Task 9.7 is `[x]`; 9.8 opens as `[~]`; 9.6 stays `[~]`. **Two environment notes:** SwiftPM's own `sandbox-exec` cannot nest inside the tool sandbox (`sandbox_apply: Operation not permitted`), so `swift test` runs with it disabled here — already recorded under the test-harness section; and BSD `sed -i ''` misparsed a script argument twice on this machine, the second time silently making a mutation run **vacuous**, which is how a meaningless "0 failures" nearly passed for a killed mutation. `perl -pi -e` for in-place edits from now on. **And the finding that justified the whole exercise on the first run:** the `installer` job failed in 17s with `./scripts/make-dmg.sh: line 136: auth_flags[@]: unbound variable`. macOS ships `/bin/bash` **3.2**, in which expanding an **empty** array under `set -u` is an error; `#!/usr/bin/env bash` picks up Homebrew's bash 5 on a developer Mac, which tolerates it, so this was **unreachable locally by construction** — no local discipline would have found it, only a runner. Worse, `release.yml`'s `prerelease_flag=()` had the same bug on the **non**-prerelease branch, so every `v1.2.0` would have died at `gh release create` while every `v1.2.0-rc.1` succeeded — the exact asymmetry that makes a bug survive a test release. Fixed by making both arrays never empty (lead with a flag that is always wanted: `-allowProvisioningUpdates` for export, `--generate-notes` for publish) rather than sprinkling `${a[@]+"${a[@]}"}`, which is unreadable and easy to omit at the next call site. Re-verified **against `/bin/bash` specifically**: `-n` on all three scripts, the flag assembly across all four `SIGNING`×`ASC_KEY_PATH` combinations (and the unsigned archive still never receives `-allowProvisioningUpdates`), and the publish step on both `IS_PRERELEASE` legs. Generalisable, and the reason this is written down: **the runner's shell is bash 3.2 and a developer Mac's is not**, so any `bash`-array or `set -u` behaviour has to be checked with `/bin/bash` explicitly, not with whatever `env bash` resolves to. The AC-6 diagnostics upload earned its keep here too — `dist/` holding only the two handoff files immediately located the failure before the archive.
* *2026-08-20 (the first notarized build — and why CI still cannot make one)*: `make-dmg.sh` and `notarize.sh` ran end to end for the first time, producing `dist/ownCloud-File-Provider-main-76394f0-local.dmg` (2.6 MB, `0.0.0 (20260820)`, commit `76394f0`, sha256 `f6b2905c…a7a11a`) — a hand-out build for external testers, not a release. All three bundles are signed `Developer ID Application: ownCloud GmbH (4AP2STM4H5)` with `flags=0x10000(runtime)`, both notary submissions came back **Accepted**, app and image are stapled, and `spctl -a -t install` reports `accepted / source=Notarized Developer ID` — re-checked on a copy carrying a `com.apple.quarantine` attribute, because this machine trusts what it builds and would not otherwise reproduce a tester's first run. **The single thing that unblocked it, after a day spent on the wrong hypothesis:** `-exportArchive` with `signingStyle=automatic` needs a Developer ID *provisioning profile*, and the only ways to get one are cloud signing or a manual profile. Cloud signing is gated on *Access to Cloud Managed Developer ID Certificate*, a permission that exists **per user and per team key, separately from the role**. The team key created for this work has Admin — `GET /v1/users` returns 200, and it notarizes — yet Apple answers `403 FORBIDDEN_ERROR` (`resultCode 7495`) on `xcbuild/v1/certificates?filter[certificateType]=DEVELOPER_ID_APPLICATION_MANAGED`. The account holds that permission where the key does not, so **signing in to Xcode and passing no `ASC_*` variables at all** made the export succeed on the first attempt; the key is still used for notarization, where it works. `make-dmg.sh` was already written for exactly this split ("*absent locally, where Xcode's own signed-in account already has them*"), so no script changed. **Three dead ends worth not repeating.** (1) *Individual* API keys cannot drive `xcodebuild`: they authenticate with `sub: "user"` and **no** `iss` — `notarytool history --key … --key-id …` with `--issuer` omitted succeeds — but `xcodebuild` refuses `-authenticationKeyPath` without `-authenticationKeyIssuerID`, and supplying any issuer invalidates the token, giving `401` on `listTeams.action` and then `No profiles for '<bundle id>' were found` ×3. (2) Cloud-managed certificates are **absent from the public App Store Connect API** — `filter[certificateType]` accepts `DEVELOPER_ID_APPLICATION` and `…_G2` and no `*_MANAGED` value at all — so no amount of API work substitutes for the permission; they exist only behind Xcode's internal `xcbuild` endpoint. (3) Re-signing the archived app by hand with the local Developer ID identity does not work either: with `embedded.provisionprofile` deleted, `codesign --entitlements` fails with the entirely opaque **`errSecInternalComponent`** — *not* a keychain problem, which is the usual diagnosis and cost real time here; restricted entitlements (app-sandbox, app groups, keychain groups) need a profile to validate against, and with the profile restored the same command succeeds. Keeping the archive's own profile is no fix: it is `Mac Team Provisioning Profile: *`, a **development** profile scoped to 7 registered devices, so the result would launch nowhere else. The profile the successful export embedded is `Mac Team Direct Provisioning Profile: com.owncloud.macos.fileprovider`, `ProvisionsAllDevices=true`, valid to 2044. **Also confirmed by measurement, correcting Task 9.6's stated blocker:** only one of the three App IDs was registered (`…fileprovider.FileProvider`); the Debug build never needed the others because it uses the wildcard development profile. `-allowProvisioningUpdates` created `com.owncloud.macos.fileprovider` and `…FileProviderUI` during the export, so this was self-healing once authentication worked — but it is the reason an export can fail three times over with one root cause. **The generalisable lesson:** an ASC key's *role* and its *cloud-signing permission* are independent, and a key that notarizes perfectly proves nothing about whether it can sign. Verify with the endpoint Xcode actually calls; `~/.appstoreconnect/check-cloud-signing.sh` does it in about a second, which beats discovering it five minutes into an archive. **Environment note:** `security find-identity` and every `curl` to Apple need the tool sandbox disabled — sandboxed, `find-identity` reports `0 valid identities found`, indistinguishable from a missing certificate, and TLS fails with `x509: OSStatus -26276`. Tasks 9.6 and 9.8 both stay `[~]`: nothing was published, no tag was pushed, `RELEASE_SIGNING_ENABLED` is unset, and CI now has a second blocker beyond the secrets — the state and the remaining steps are tracked as issue #32 so they survive this session.


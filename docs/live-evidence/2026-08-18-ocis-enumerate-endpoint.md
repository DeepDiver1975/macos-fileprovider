# Live evidence — oCIS enumerate endpoint bug (2026-08-18)

A genuine production bug, found by live-testing the signed extension against the
Docker oCIS fixture (`owncloud/ocis:8.2.0`) rather than only headless mocks.

## The bug

`GraphRequestBuilder.enumerate` addressed the drive root with the MS-Graph
shortcut path `GET /graph/v1.0/drives/{driveID}/root/children`. **oCIS 8.2.0 does
not implement that shortcut — it returns HTTP 404 even with valid auth.** So a live
oCIS domain enumerated to nothing (only the system-synthesized `.Trash`).

A second, latent defect sat next to it: `BackendConnection.enumerationSource(for:)`
ignored the `container` item id for oCIS and always built the source from the
`driveID` alone. Classic honours the container path; oCIS silently re-listed the
root for every subfolder.

## Live probe (real bearer auth, fixture up via `make up BACKEND=ocis`)

Personal drive `aabf948a-fa17-44f2-aa5e-d9d0f1a5c006$98f9d537-5b57-4442-b189-8aa3395425d1`;
its `root.id` (from `GET /graph/v1.0/drives/{driveID}`) equals the driveID string.

| Endpoint | HTTP |
|----------|------|
| `GET /graph/v1.0/drives/{driveID}/root/children` (old code) | **404** |
| `GET /graph/v1.0/drives/{driveID}/items/{rootID}/children` (new code) | **200** — returns the listing incl. seeded `ocis-probe.txt` |
| `GET /graph/v1.0/drives/{driveID}/root/delta` (old cursor path) | **404** |
| `GET /graph/v1.0/drives/{driveID}/items/{rootID}/delta` (all delta variants) | **404** |

Delta change-tracking is simply not served by oCIS 8.2.0 (every variant 404s, and
`/children` emits no `@odata.nextLink`), so it stays a documented remainder — the
cursor branch is kept item-addressed for consistency but is not claimed working.

## The fix

`enumerate(driveID:itemID:cursor:)` is now item-addressed:
`/items/{itemID}/children` (first page) / `/items/{itemID}/delta?$token=…` (cursor).
The root container's item id is the drive's root id (== driveID);
`BackendConnection.enumerationSource(for:)` now passes the container's own item id
for subfolders, so descending into folders enumerates the folder — not the root.

## Verification

- **TDD, RED first:** `RemoteRequestBuilderTests` / `BackendConnectionTests` /
  `RemoteEnumerationSourceTests` were updated to assert the item-addressed URL and
  watched to fail (the old `/root/children` assertions + the missing `itemID:`
  parameter), then made green.
- **macOS:** full `swift test` — all passing.
- **Linux parity** (`docker run swift:6.0-jammy`): the enumeration test subset →
  57 tests, 0 failures; `swift build --build-tests` clean.
- **Live curl** (table above): old path 404, new path 200 with the file listing.

## What this does NOT yet prove (and why)

The live **Finder-mount** enumeration through the signed extension could not be
captured on this machine: the sandboxed FileProvider extension validates the
fixture's self-signed cert against the **System** trust store, and the oCIS
container logged `TLS handshake error … EOF` bursts during the extension's
enumeration window. Trusting `CN=OCIS` in `/Library/Keychains/System.keychain`
needs an interactive `sudo` password (curl succeeds because the cert is trusted in
the login keychain, which the sandboxed extension does not consult). That is the
same cert/GUI environmental gate documented elsewhere — not a defect in the fix,
which is proven independently above.

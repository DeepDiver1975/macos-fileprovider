# Live Classic round-trip evidence — 2026-08-18

Signed, installed build (`make install` → `~/Applications/ownCloud File Provider.app`,
`codesign --verify --deep --strict` OK, both `.appex` registered per `pluginkit -mAv` with `+`).
Domain `admin@localhost` mounted (Debug build via `DevHarness`) against the local Classic
fixture (`make up BACKEND=classic`, `http://localhost:8080`, admin/admin). Domain dir:
`~/Library/CloudStorage/ownCloudFileProvider-admin@localhost`.

All checks below drove the **real File Provider extension** (not curl-only) and were
corroborated against the server over WebDAV.

| Capability | Task | Result |
|---|---|---|
| Domain add + enumerate root/subfolders | 6.0, 5.1 | `Documents`, `Photos`, `Documents/Example.odt` enumerated |
| Download / hydration byte-exact | 4.1, 4.2 | `Example.odt` 36227 B; SHA-256 `d617ccd9…cb326f` == direct WebDAV GET |
| Create (createItem) | 4.4 | `live-acc-check.txt` → server HTTP 201, content byte-exact |
| Modify content (modifyItem .contents) | 4.4 | server reflected new bytes |
| Delete (deleteItem) | 4.4 | server GET → HTTP 404 after local delete |
| Rename/move (modifyItem .filename) | 4.4 | `rename-src.txt` → 404, `rename-dst.txt` → 200 |

**Not proven in this run (honest gaps):**
- Server→client *change* enumeration (a server-side add did not reflect within the wait window).
- oCIS anything (Classic-only; oCIS needs an OIDC-capable fixture).
- The settings-window Add Account flow (this run used `DevHarness`; the settings flow is Task 7.11).
- Conflict mechanism (Phase 4 open question), and the automated Gherkin acceptance suite
  (Task 6.3/6.4 action bodies) — verification here was manual, not the runner.

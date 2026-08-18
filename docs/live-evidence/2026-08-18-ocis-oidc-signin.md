# Live evidence — oCIS OIDC sign-in against the real Konnect IDP (2026-08-18)

The oCIS sign-in tasks (7.8, 7.12, and the oCIS legs of 2.5 / 4.4 / 5.1) had been
recorded as blocked on "an OIDC-capable oCIS fixture", on the assumption that an
OIDC Authorization-Code flow cannot be exercised without an interactive browser.

That assumption was only *partly* right. The Docker oCIS fixture
(`owncloud/ocis:8.2.0`, `test/fixtures/ocis/docker-compose.yml`) ships a full OIDC
IDP (Konnect). Its interactive login page sits in front of a **scripted JSON logon
API** (`/signin/v1/identifier/_/logon`) — the same seam browser-automation OIDC e2e
suites use. That lets the whole sign-in *protocol + decision* path run headlessly
against the real IDP; only the AppKit `ASWebAuthenticationSession` web sheet stays
out of frame (its own GUI gate, exactly like the Finder round-trip in
`2026-08-18-classic-roundtrip.md`).

## What ran, against `https://localhost:9200` (fixture up via `docker compose … up -d --wait`)

The test `OCISSignInContractTests.testFullOIDCSignInResolvesAccountAndSpacesLive`
drives the **production** types (no reimplementation) end to end:

| Step | Production code exercised | Result |
|------|---------------------------|--------|
| Discovery | `OIDCConfiguration(discoveryJSON:)` via the coordinator's `fetchDiscovery` | issuer/authorization/token endpoints parsed from the live `/.well-known/openid-configuration` |
| Authorize URL + PKCE | `OIDCAuthorizationRequest.authorizationURL`, `PKCE.challengeS256` | real IDP accepted the `S256` challenge |
| Browser step (scripted stand-in) | injected `authorize` closure → Konnect `logon` + `authorize` | real authorization `code` returned on the redirect `Location` |
| State validation + code extract | `OIDCAuthorizationRequest.authorizationCode(fromCallback:expectedState:)` | state matched, code extracted |
| Code→token exchange | `OIDCTokenRequestBuilder.exchange`, `OIDCTokenResponse.credentials` | real `access_token` (len 1267) + `refresh_token` + `id_token`, `token_type=Bearer`, `expires_in=300` |
| Bearer authorizes Graph | `GraphRequestBuilder.listDrives`, `RemoteClient.urlSession`, `GraphJSONDecoder.decodeDriveList` | `GET /me/drives` returned 2 drives (personal `Admin`, virtual `Shares`) — a 401 would have failed the run |
| Account + spaces resolution | `OCISSignInResolver.resolve` (+ `OIDCIDToken.claims`, `SyncRoot`, `SpaceCatalog`) | `.ocis` account named from claims (`preferred_username=admin`, `email=admin@example.org`), one sync root per drive, catalog with 2 spaces |
| Token refresh | `OIDCTokenRequestBuilder.refresh`, `OIDCTokenResponse.credentials` | real `refresh_token` grant returned a fresh bearer access token |

`OWNCLOUD_TEST_BACKEND=ocis swift test --filter OCISSignInContract` → **1 test passed**.
Wired into the oCIS backend-contract CI leg's `--filter` (self-skips on the Classic
leg and the pure-unit run). Full unit run: 375 tests, 9 skipped (the contract tiers).
Signed `xcodebuild build` BUILD SUCCEEDED.

## What this promotes — and what it deliberately does not

**Genuinely proven now (the protocol + decision layer against the real IDP):** the
whole `OIDCSignInCoordinator.signIn` chain, `DriveResolver`'s `me/drives` fetch with a
real bearer token, `OCISSignInResolver`, and the `refresh_token` grant (`SessionManager`
/ Task 2.5 refresh path, oCIS side).

**Still NOT exercised (kept `[~]` — do not mark `[x]`):**
- The **AppKit web sheet** (`WebAuthorizationPresenter` / `ASWebAuthenticationSession`)
  — the scripted logon stands in for it; the real browser presentation is GUI-gated.
- The Mac **glue in `SettingsModel`**: the oCIS branch that calls the coordinator,
  feeds its result through `OCISSignInResolver`, persists the credential, and adds one
  domain per sync root via `DomainService` — plus the redirect-scheme `Info.plist`
  entry. Not driven here (this test stops at the resolved value object).
- A live **oCIS domain mount in Finder** (Task 5.1 oCIS leg) and **oCIS push/enumerate
  + the conflict mechanism** (Task 4.4 oCIS leg) — those need the Mac FileProvider
  host, not just the IDP.
- The **refresh-token concurrency arbitration** of Task 7.6 (two domains, one shared
  refresh token, single-flight) — the *grant* is proven live; the *arbitration* is a
  separate concern tested headlessly, not exercised end to end here.

So this evidence closes the "can the OIDC protocol even be driven headlessly?" question
(**yes**) and proves the pure sign-in chain against the real IDP, but the Mac-host and
GUI remainders of 7.8/7.12/5.1/4.4/7.6 stay honestly `[~]`.

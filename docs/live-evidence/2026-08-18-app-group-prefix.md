# Live evidence — the app group id was missing its team prefix, silently disabling oCIS token refresh (2026-08-18)

This file records a defect that was **misattributed twice** before it was found, because
its symptom on the Mac looks nothing like its cause. It is written up in full so the
misattribution is on the record and the mistake cannot quietly return.

## Symptom

After Task 7.13 wired OIDC refresh into the extension, an oCIS domain mounted from the
shipping UI stopped serving content. Enumerating it in Finder produced an empty folder.
The first two explanations were both wrong:

1. *"The refresh works — a 21-minute-old domain still enumerates."* It did, but from the
   **local replica**; the extension was never asked. The Keychain item's `expiresAt` had
   never moved, which is what a working refresh would have updated.
2. *"It is the System-keychain self-signed-cert gate"* — the same gate recorded in
   `2026-08-18-ocis-enumerate-endpoint.md` for the enumerate fix. **Retracted.** Trust was
   verified actually in place (`security dump-trust-settings -d` → `Number of trusted
   certs = 1, Cert 0: OCIS`), and the fixture's own log proves the extension completes a
   TLS handshake and is answered at the HTTP layer.

## What the server actually said

The oCIS proxy names the real failure — and names the client:

```
"failed to verify access token: token has invalid claims: token is expired"
"user_agent":"FileProviderExtension/1"
```

So: the extension reaches the server fine, over TLS, and is rejected on an **expired
access token**. `expires_in=300`. Refresh was not running.

> **Method note worth keeping:** the oCIS proxy logs **only failures**. A successful
> request produces no log line at all, so "zero log lines" is *not* evidence of success —
> it was read that way earlier in this investigation and cost time. Assert on a positive
> signal (the resource, the response, the persisted expiry), never on silence.

## Root cause — an entitlement that is wrong only at runtime

`FileProviderExtension.makeSession` attaches `OIDCRefreshHandler` **only** when it can
read an `OIDCSessionRecord` out of the shared app group, and otherwise falls back to a
refresh-less `SessionManager`. That fallback is deliberate (a Classic account has no
record) — which is exactly why it made this defect silent.

`com.apple.security.application-groups` was declared as the bare `group.…` id, with no
`$(AppIdentifierPrefix)`, in all three entitlements files, and likewise in the extension's
`NSExtensionFileProviderDocumentGroup`. On macOS an application group id **is**
`<TEAMID>.group.…`. The bare form is accepted everywhere it is *declared* — it compiles,
codesigns and provisions cleanly — and then splits the two processes apart at runtime:

- the **app** creates `~/Library/Group Containers/group.…` on first write and, as its
  creator, keeps working, so the app half of every feature looks correct;
- the **extension** asks the sandbox for a container it is not entitled to and is denied.
  `containerURL(forSecurityApplicationGroupIdentifier:)` returns a path it cannot open and
  `UserDefaults(suiteName:)` returns a suite holding **none** of the app's keys — with **no
  error raised on either side**.

Note the near miss that hid it: `keychain-access-groups` in the same files *did* already
carry the prefix, so credentials crossed the boundary and only the app-group reads failed.

## The asymmetry, measured under lldb

Same machine, same moment, same identifier, two processes:

| Probe | Containing app | `FileProviderExtension` |
|-------|----------------|-------------------------|
| `com.owncloud…` keys visible in the suite | **6** | **0** |
| `OIDCSessionRecord` blob | present, 270 bytes | absent |
| Write into the group container | OK | **denied** |

Zero keys, so no record; no record, so `makeSession` took its refresh-less fallback; so
every oCIS mount died 300 seconds after sign-in. (`log show` and
`~/Library/Application Support/FileProvider` are both TCC-blocked here even with the
sandbox off, so `docker logs` plus lldb were the only channels available. `expr -l swift`
needs `as NSString` / `as NSNumber` — a bare Swift `String` gives "summary string parsing
error" and `print(...)` yields `() = {}`.)

## Fix

- New `Core/Sources/OwnCloudCore/AppGroup.swift` — `AppGroup.teamID` /
  `.bareIdentifier` / `.identifier`, the single place the runtime id is written, carrying
  the failure mode above in its doc comment. A runtime string cannot reference
  `$(AppIdentifierPrefix)`, so the team id is declared here and the two must agree.
- `$(AppIdentifierPrefix)` added to `application-groups` in **all three** entitlements
  files and to the extension's `NSExtensionFileProviderDocumentGroup`, each with a comment
  saying why the bare form must never come back.
- `SettingsModel`, `FileProviderExtension` and `DevHarnessOCIS` now use
  `AppGroup.identifier` instead of a local literal.
- New `Core/Tests/OwnCloudCoreTests/AppGroupIdentifierTests.swift` — 4 tests that read the
  four declaration files and the three Swift sources off disk and fail if any of them
  drops the prefix or reintroduces the bare id. A convention was not enough here precisely
  because the wrong value raises no error at any stage.

## Verification

| Level | Check | Result |
|-------|-------|--------|
| Unit | `swift test` | **421 tests, 10 skipped, 0 failures** (incl. the 4 new guards) |
| Build | `make install`, `codesign --verify --deep --strict` | BUILD SUCCEEDED, verify passed, both `.appex` embedded |
| Signed declarations | `codesign -d --entitlements` on app + `.appex` | both `4AP2STM4H5.group.com.owncloud.macos.fileprovider` |
| Mechanism | extension writes into the group container | **"UNPREFIXED WRITE DENIED" → "EXT CONTAINER WRITE OK"** |
| End to end | fresh sign-in through the *shipping* Add Account sheet + the real browser sheet | sidebar row **`admin@localhost` / Infinite Scale**; `accounts`, `oidc-session` (`tokenEndpoint: https://localhost:9200/konnect/v1/token`) and the 2-space `spaces` catalog all written into the **prefixed** container |

## In-situ refresh, now proven (2026-08-19)

The first attempt at this was inconclusive and was discarded rather than counted: it ran
against `~/Library/CloudStorage/ownCloudFileProvider-Admin`, a **stale replica directory
reused by display name** still holding `probe.txt`/`enum-trigger.txt` from the pre-fix
domain, with six other stale `ownCloudFileProvider-*` domains registered. Redone cleanly:

1. Every domain removed with `.removeAll` (verified: the `…-Admin` directory disappeared).
2. The domain re-created through the **production reconnect path** — the Task 7.9 deep link
   `owncloud-fileprovider://reconnect?account=ocis|…` — which drove `signInWithOIDC` and
   opened the real browser sheet at
   `…/signin/v1/identifier?client_id=mxd5OQ…&redirect_uri=oc%3A%2F%2Fios.owncloud.com&code_challenge_method=S256`.
   That incidentally proves the oCIS reconnect deep link live, not just the Add Account sheet.
   `admin`/`admin`, then the **forced consent** step (the untrusted-mobile-client behaviour
   already recorded), and the replica was recreated empty.
3. **The decisive change of method: the fixture logs only failures because it runs
   `OCIS_LOG_LEVEL: error`.** Restarting it with `OCIS_LOG_LEVEL=info` (an env override
   only — `docker-compose.yml` is unchanged) turns on the proxy access log, which reports
   **status codes for successful requests**. That converted this whole investigation from
   arguing about silence to reading positive signals.

With that channel, a write into the domain **~7 hours after sign-in** produced:

```
200 POST /konnect/v1/token          <- the extension refreshed its own token, in situ
200 GET  /konnect/v1/userinfo
200 GET  /graph/v1.0/me/drives      <- the renewed bearer authorizes Graph
```

Zero `token is expired` from the extension. (One such line does appear in the log, from
`user_agent: …Chrome/151…` — a browser tab of mine hitting a probe file, not the extension.)
`expires_in=300` versus ~7 hours elapsed: the refresh path — `SessionManager` +
`OIDCRefreshHandler` + `SynchronousTokenSender` + the per-account `FileLock`, reading its
parameters from the now-reachable app group — **works in the real extension**, which is the
one thing the contract test could only simulate.

## Two unrelated pre-existing bugs this surfaced (NOT issue #17)

The same access log exposed two defects that have nothing to do with the app group or OIDC,
and that were invisible while every request was silent. Both are in the Graph request layer:

| # | Symptom | Detail |
|---|---------|--------|
| 1 | **Upload always 404s** | `PUT /graph/v1.0/drives/{drive}/root:/{name}:/content` → **404**. So does the item-addressed variant `…/items/{rootID}:/{name}:/content`. `PUT /dav/spaces/{drive}/{name}` → **201**, and the file then appears in the Graph children listing. So oCIS 8.2.0 does not serve the Graph content-upload path this builder emits (`GraphRequestBuilder.uploadNewFileUnderRoot` / `.uploadNewFile`); the WebDAV spaces route is the working one. This is the same *class* of bug as the enumerate `/root/children` 404 already fixed. |
| 2 | **Working-set identifier sent literally** | `GET /graph/v1.0/drives/{drive}/items/NSFileProviderWorkingSetContainerItemIdentifier/children` → **404**. The extension passes `NSFileProviderItemIdentifier.workingSet` straight through as an item id instead of mapping it (as it already maps `.rootContainer` to the drive id). |

Consequence: no file written into an oCIS mount reaches the server yet. That is a real gap,
but it is **not** issue #17 and not the app-group defect — the account, the mount, the
enumeration and the token lifecycle are all now proven working; the write verb is wrong.
Fixing these is separate follow-up work, recorded in `progress.md` rather than fixed here,
because #17's scope is sign-in reachability and neither bug is caused by it.

## Transferable lessons

1. **A silent fallback needs a loud diagnostic.** `makeSession`'s refresh-less path is
   correct for Classic and catastrophic for oCIS, and it could not tell the difference. The
   cost of the missing log line was the whole investigation.
2. **"No error" is not "no problem."** The sandbox denied a container and `UserDefaults`
   returned an empty suite; neither raised anything.
3. **Ask the server.** The only channel that named the actual failure was the *other side*
   of the connection. Client-side evidence was consistent with three different stories.
4. **Silence is not success** when the log records only failures — and the fix for that is
   cheap: raise the fixture to `OCIS_LOG_LEVEL=info` and read the access log's status codes.
   Doing this earlier would have found the app-group defect *and* both upload bugs in one
   pass. **For any future live oCIS debugging, turn the access log on first.**
5. **Verify a mount on a freshly created replica.** `~/Library/CloudStorage/` directories are
   reused by display name and survive a domain removal, so a stale replica will happily serve
   a "successful" listing that never touched the server. Remove with `.removeAll` and confirm
   the directory actually disappeared before trusting anything read out of it.

---
name: no-signing-ac3-polling
description: Project decision — no Apple signing for now; AC-3 uses the bounded-polling fallback
metadata:
  type: project
---

The user decided (2026-08-16) **not** to set up Apple Developer signing for this
project for now. This resolves progress.md **Task 6.1**: use the **AC-3
bounded-polling fallback** rather than the deterministic `fileprovider.testing-mode`
path (which needs a provisioning profile from a paid team).

**Why:** signing credentials aren't being provisioned to CI or the dev machine.

**How to apply:**
- Don't tick tasks that require a signed/installed app: the extension is only
  discovered when the containing app is signed and in `/Applications`, so live
  `NSFileProviderManager.add`, byte-streaming hand-off, and the end-to-end
  acceptance tier (Tasks 4.1/4.2/4.4 glue, 5.1 live call, 5.3, 6.0) stay blocked.
- Keep building the Linux-buildable core + `#if canImport(FileProvider)` adapters
  test-first — that's the work that can still progress headlessly.
- Local `xcodebuild build`/`test` must pass `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`.

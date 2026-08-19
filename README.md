# macos-fileprovider

A macOS File Provider extension for ownCloud, built on the modern `FileProvider`
and `FileProviderUI` frameworks.

## Scope

* **Target OS:** macOS 14+ (Sonoma and newer)
* **Backends:**
  * ownCloud Classic — WebDAV / SabreDAV XML
  * ownCloud Infinite Scale (oCIS) — Graph API / OIDC

## Status

Early stage — no implementation yet. The development plan, phase breakdown and
task tracking live in [`progress.md`](progress.md).

## Install

Signed, notarized `.dmg` builds are published on the
[releases page](../../releases) — drag the app to Applications. Each release also
carries a `.sha256` file, so a download can be checked with
`shasum -c ownCloud-File-Provider-*.dmg.sha256`.

Releases are cut by pushing a `v*` tag; see
[PROJECT.md → Releasing](PROJECT.md#releasing).

## Development

Work follows a test-driven loop: each task starts with a failing unit test, then
the implementation that makes it pass. See `progress.md` for the ordered task
list.

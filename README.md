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
task tracking live in [`process.md`](process.md).

## Development

Work follows a test-driven loop: each task starts with a failing unit test, then
the implementation that makes it pass. See `process.md` for the ordered task
list.

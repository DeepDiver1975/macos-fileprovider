// OwnCloudCore
//
// Backend-agnostic core for the macOS ownCloud File Provider extension.
// Implementation is built up test-first across Phase 2 of progress.md:
//   - Task 2.1/2.2: WebDAV PROPFIND multi-status XML parsing (ownCloud Classic)
//   - Task 2.3/2.4: oCIS Graph API JSON models
//   - Task 2.5:     unified credential / session manager

/// Marker giving the module a stable, importable symbol before the Phase 2
/// types land. Lets the package build and its test target link from Task 1.1.
public enum OwnCloudCore {
    /// Semantic version of the core package.
    public static let version = "0.0.1"
}

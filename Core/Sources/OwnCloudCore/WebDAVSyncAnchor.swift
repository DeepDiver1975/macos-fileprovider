import Foundation

/// Synthesizes a ``SyncAnchor`` for ownCloud Classic (WebDAV), which has no
/// delta API. The anchor is a deterministic digest of the current listing: the
/// system stores it and, on the next `enumerateChanges`, the enumerator re-lists
/// and compares — a different digest means the folder changed and a
/// `ChangeSet(from:to:)` diff is produced (progress.md Task 3.3, `SyncAnchor` note).
public extension SyncAnchor {

    /// Digest the listing by each item's identity and version. Order-independent
    /// (entries are sorted first) so the same folder contents always yield the
    /// same anchor, and any added/removed item or changed `versionIdentifier`
    /// changes it.
    init(listing: [FileProviderItemDescription]) {
        let entries = listing
            .map { "\($0.identifier.rawValue)\u{0}\($0.versionIdentifier ?? "")" }
            .sorted()
        // A stable, process-independent digest — Swift's Hasher is seeded per
        // run, so it can't be used for a persisted anchor.
        let digest = FNV1a.hash(entries.joined(separator: "\u{1}"))
        self.init(token: "webdav:\(String(digest, radix: 16))")
    }
}

/// 64-bit FNV-1a — a small, dependency-free, deterministic string hash. Used
/// only for the WebDAV sync anchor digest, not for anything security-sensitive.
enum FNV1a {
    static func hash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

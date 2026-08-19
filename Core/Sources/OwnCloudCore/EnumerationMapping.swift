import Foundation

/// Maps a parsed backend enumeration response onto an ``EnumerationPage`` — the
/// pure half of a `Paginator.FetchPage` (progress.md Phase 3). No networking:
/// the WebDAV/Graph client fetches and parses; these initializers turn the
/// parsed models into the engine's page type.
public extension EnumerationPage {

    /// Build a page from a WebDAV `PROPFIND Depth:1` listing. Depth:1 returns the
    /// container itself as the first entry alongside its children; that self
    /// entry (the response whose href matches the requested container) is dropped
    /// so only children are enumerated. Classic returns every child at once, so
    /// there is no next cursor and the anchor is synthesized elsewhere.
    init(webDAVItems: [WebDAVItem], containerHref: String, parentIdentifier: ItemIdentifier) {
        let containerPath = Self.normalizedPath(containerHref)
        let children = webDAVItems.filter { Self.normalizedPath($0.href) != containerPath }
        self.init(
            items: children.map { FileProviderItemDescription(webDAVItem: $0, parentIdentifier: parentIdentifier) },
            nextCursor: nil,
            anchor: nil
        )
    }

    /// Build a page from an oCIS space-WebDAV `PROPFIND Depth:1` listing
    /// (Task 4.5). Like Classic, Depth:1 returns the container itself first — but
    /// that entry is dropped by **`oc:id`**, not by href.
    ///
    /// Href comparison is not reliable here: oCIS echoes the request's own
    /// percent-encoding back in the response href, so a container addressed as
    /// `…/drive%21folder` comes back spelled that way while the same item listed
    /// under its parent is spelled with a literal `!`. Matching on `oc:id` — which
    /// every oCIS entry carries — is exact, and the container's id is already known
    /// because it is what was requested.
    ///
    /// `containerFileID` is `nil` when enumerating the space root, whose `oc:id`
    /// is not the bare driveID; ``SpaceWebDAVEndpoint/isRoot(fileID:driveID:)``
    /// recognises it instead.
    init(ocisWebDAVItems items: [WebDAVItem], containerFileID: String?, driveID: String) {
        let children = items.filter { item in
            guard let fileID = item.fileID else { return true }
            if let containerFileID { return fileID != containerFileID }
            return !SpaceWebDAVEndpoint.isRoot(fileID: fileID, driveID: driveID)
        }
        self.init(
            items: children.map { FileProviderItemDescription(ocisWebDAVItem: $0, driveID: driveID) },
            nextCursor: nil,
            anchor: nil
        )
    }

    /// Normalise an href for self-entry comparison: strip a trailing slash so
    /// `/a/b/` and `/a/b` compare equal. Percent-encoding is left intact — both
    /// the container path and the server hrefs are encoded the same way.
    private static func normalizedPath(_ href: String) -> String {
        href.hasSuffix("/") ? String(href.dropLast()) : href
    }
}

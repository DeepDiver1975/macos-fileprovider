import Foundation

/// An opaque sync anchor. In the extension this maps to
/// `NSFileProviderSyncAnchor`, which wraps arbitrary `Data`; we carry a token
/// string (the oCIS delta `$token`, or a synthesized digest for WebDAV).
public struct SyncAnchor: Equatable, Sendable {
    public let token: String

    public init(token: String) { self.token = token }

    /// Serialised form for `NSFileProviderSyncAnchor(_:)`.
    public var data: Data { Data(token.utf8) }

    /// Reconstruct from an anchor's raw data. `nil` for empty data (no prior
    /// anchor — the enumerator should do a full pass).
    public init?(data: Data) {
        guard !data.isEmpty, let token = String(data: data, encoding: .utf8) else { return nil }
        self.token = token
    }
}

/// A cursor into a paginated enumeration (oCIS `@odata.nextLink` `$token`, or a
/// WebDAV page offset). `nil` means "start from the beginning" as an input and
/// "no more pages" as an output.
public struct PageCursor: Equatable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// One page of an enumeration.
public struct EnumerationPage: Equatable, Sendable {
    public let items: [FileProviderItemDescription]
    /// The cursor for the next page, or `nil` when this is the last page.
    public let nextCursor: PageCursor?
    /// The sync anchor to hand back once enumeration completes. Typically only
    /// the final page carries it.
    public let anchor: SyncAnchor?

    public init(items: [FileProviderItemDescription], nextCursor: PageCursor?, anchor: SyncAnchor?) {
        self.items = items
        self.nextCursor = nextCursor
        self.anchor = anchor
    }
}

/// The fully accumulated result of walking every page.
public struct EnumerationResult: Equatable, Sendable {
    public let items: [FileProviderItemDescription]
    public let anchor: SyncAnchor?
}

/// Walks a paginated backend source page by page until there is no next cursor,
/// accumulating items in order and capturing the final sync anchor. The page
/// fetch is injected, so the WebDAV and Graph clients plug in without the engine
/// knowing either protocol.
public struct Paginator {
    /// Fetches the page beginning at `cursor` (`nil` = first page).
    public typealias FetchPage = (_ cursor: PageCursor?) throws -> EnumerationPage

    private let fetchPage: FetchPage

    public init(fetchPage: @escaping FetchPage) {
        self.fetchPage = fetchPage
    }

    public func enumerateAll() throws -> EnumerationResult {
        var items: [FileProviderItemDescription] = []
        var cursor: PageCursor? = nil
        var latestAnchor: SyncAnchor? = nil

        repeat {
            let page = try fetchPage(cursor)
            items.append(contentsOf: page.items)
            if let anchor = page.anchor { latestAnchor = anchor }
            cursor = page.nextCursor
        } while cursor != nil

        return EnumerationResult(items: items, anchor: latestAnchor)
    }
}

/// The result of diffing two enumerations: what the change observer must report
/// as updated (added or modified) and what it must report as deleted.
public struct ChangeSet: Equatable, Sendable {
    public let updatedItems: [FileProviderItemDescription]
    public let deletedIdentifiers: [ItemIdentifier]

    public init(updatedItems: [FileProviderItemDescription], deletedIdentifiers: [ItemIdentifier]) {
        self.updatedItems = updatedItems
        self.deletedIdentifiers = deletedIdentifiers
    }

    /// Diff a previous listing against a current one (WebDAV Classic, which has
    /// no delta API — the enumerator re-lists and compares).
    ///
    /// - An item present in `new` but absent from `old`, or whose
    ///   `versionIdentifier` changed, is *updated*.
    /// - An item present in `old` but absent from `new` is *deleted*.
    ///
    /// Ordering of `updatedItems` follows `new`; of `deletedIdentifiers`, `old`.
    public init(from old: [FileProviderItemDescription], to new: [FileProviderItemDescription]) {
        let oldByID = Dictionary(old.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        let newIDs = Set(new.map(\.identifier))

        updatedItems = new.filter { item in
            guard let previous = oldByID[item.identifier] else { return true } // added
            return previous.versionIdentifier != item.versionIdentifier        // modified
        }
        deletedIdentifiers = old.map(\.identifier).filter { !newIDs.contains($0) }
    }

}

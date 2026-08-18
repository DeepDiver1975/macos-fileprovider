import Foundation

/// The *domain* identity: one `NSFileProviderDomain` per oCIS space (Task 7.1). A
/// Classic account is a single sync root over its files root (`driveID == nil`);
/// an oCIS account has one sync root per selected space.
///
/// The domain identifier is `"<driveID>|<accountIdentifier>"` — drive first, so
/// the ``AccountDescriptor/accountIdentifier`` stays the verbatim tail and its own
/// parser handles it unchanged. This is the identifier the extension is handed and
/// must reconstruct both the account and (for oCIS) the drive from.
public struct SyncRoot: Sendable, Equatable, Hashable {
    public let account: AccountDescriptor
    /// The oCIS drive (space) this domain maps to, or `nil` for Classic.
    public let driveID: String?

    /// Build a sync root. Returns `nil` if `driveID` contains the `|` head
    /// separator, which would make the domain identifier ambiguous (oCIS drive ids
    /// use `$` and `!`, never `|`).
    public init?(account: AccountDescriptor, driveID: String?) {
        if let driveID, driveID.contains("|") { return nil }
        self.account = account
        self.driveID = driveID
    }

    /// Reconstruct a sync root from a ``domainIdentifier``. Splits on the first
    /// `|` into the (possibly empty) drive head and the account tail, then parses
    /// the tail as an ``AccountDescriptor/accountIdentifier``. Returns `nil` if
    /// there is no separator or the tail is not a valid account identifier.
    public init?(domainIdentifier: String) {
        guard let separator = domainIdentifier.firstIndex(of: "|") else { return nil }
        let head = String(domainIdentifier[..<separator])
        let tail = String(domainIdentifier[domainIdentifier.index(after: separator)...])
        guard let account = AccountDescriptor(accountIdentifier: tail) else { return nil }
        self.account = account
        self.driveID = head.isEmpty ? nil : head
    }

    /// Stable domain identifier `"<driveID>|<accountIdentifier>"`. For Classic the
    /// drive head is empty, so it begins with `|`.
    public var domainIdentifier: String {
        "\(driveID ?? "")|\(account.accountIdentifier)"
    }
}

/// One row's input to ``DomainDisplayNamer``: the sync root plus the space's
/// server-side display name.
public struct DomainNameInput: Sendable, Equatable {
    public let syncRoot: SyncRoot
    public let spaceName: String

    public init(syncRoot: SyncRoot, spaceName: String) {
        self.syncRoot = syncRoot
        self.spaceName = spaceName
    }
}

/// Resolves user-facing domain display names, disambiguating collisions (Task 7.1).
///
/// The common case is that a space's own name is unique, so that name is used
/// verbatim. When two spaces share a name the namer qualifies them: across
/// accounts by the account's display name (`Personal (einstein@ocis.test)`), and —
/// if even that collides (the same account, two spaces named alike) — additionally
/// by the drive id.
public enum DomainDisplayNamer {

    /// Map each input's ``SyncRoot/domainIdentifier`` to its resolved display name.
    public static func displayNames(for inputs: [DomainNameInput]) -> [String: String] {
        var result: [String: String] = [:]
        // Group by space name; only names shared by more than one row need
        // qualifying.
        let byName = Dictionary(grouping: inputs, by: { $0.spaceName })
        for (name, group) in byName {
            if group.count == 1 {
                result[group[0].syncRoot.domainIdentifier] = name
                continue
            }
            // Collision. Qualify by account; if that still collides (same account,
            // same space name), add the drive id.
            let accountQualified = Dictionary(
                grouping: group, by: { $0.syncRoot.account.displayName })
            for (accountName, accountGroup) in accountQualified {
                if accountGroup.count == 1 {
                    result[accountGroup[0].syncRoot.domainIdentifier] = "\(name) (\(accountName))"
                } else {
                    for input in accountGroup {
                        let drive = input.syncRoot.driveID ?? ""
                        result[input.syncRoot.domainIdentifier] = "\(name) (\(accountName) — \(drive))"
                    }
                }
            }
        }
        return result
    }
}

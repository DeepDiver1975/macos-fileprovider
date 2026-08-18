import XCTest
@testable import OwnCloudCore

/// Task 7.1 (the identity split). One `NSFileProviderDomain` maps to one oCIS
/// space, so the domain identity (`SyncRoot`) must diverge from the credential
/// identity (`AccountDescriptor.accountIdentifier`): N spaces of one account share
/// one credential item but get N domains.
final class SyncRootTests: XCTestCase {

    private let ocisAccount = AccountDescriptor(
        backend: .ocis,
        serverURL: URL(string: "https://ocis.test")!,
        username: "einstein"
    )
    private let classicAccount = AccountDescriptor(
        backend: .classic,
        serverURL: URL(string: "http://localhost:8080")!,
        username: "admin"
    )

    // MARK: - Domain identifier round trip

    func testOCISSyncRootRoundTripsThroughDomainIdentifier() {
        // oCIS: the domain identifier is "<driveID>|<accountIdentifier>". Drive
        // first, so the accountIdentifier (which the existing parser handles) is
        // the verbatim tail.
        let root = SyncRoot(account: ocisAccount, driveID: "1284d238-aa92$4242!68 f")!
        let restored = SyncRoot(domainIdentifier: root.domainIdentifier)
        XCTAssertEqual(restored, root)
        XCTAssertEqual(restored?.driveID, "1284d238-aa92$4242!68 f")
        XCTAssertEqual(restored?.account, ocisAccount)
    }

    func testClassicSyncRootHasEmptyDriveHead() {
        // A Classic account is one domain over its files root — no drive id, so the
        // head is empty and driveID is nil.
        let root = SyncRoot(account: classicAccount, driveID: nil)!
        XCTAssertTrue(root.domainIdentifier.hasPrefix("|"),
                      "Classic domain identifier should start with an empty drive head: \(root.domainIdentifier)")
        let restored = SyncRoot(domainIdentifier: root.domainIdentifier)
        XCTAssertEqual(restored, root)
        XCTAssertNil(restored?.driveID)
    }

    func testSyncRootRejectsDriveIDContainingPipe() {
        // The drive head is delimited by '|', so a drive id carrying one would be
        // misparsed. oCIS drive ids never contain '|' (they use '$' and '!'), so
        // this is rejected at construction.
        XCTAssertNil(SyncRoot(account: ocisAccount, driveID: "bad|drive"))
    }

    func testSyncRootRejectsUnparseableTail() {
        // A well-formed head but a tail that is not a valid accountIdentifier.
        XCTAssertNil(SyncRoot(domainIdentifier: "somedrive|not-an-account"))
        XCTAssertNil(SyncRoot(domainIdentifier: "somedrive|bogusbackend|https%3A%2F%2Fx.test|u"))
    }

    func testSyncRootRejectsIdentifierWithoutSeparator() {
        // No '|' at all — cannot split head from tail.
        XCTAssertNil(SyncRoot(domainIdentifier: "nodelimiter"))
    }

    func testDomainIdentifierRoundTripSurvivesPipeInUsername() {
        // Regression for the rename: only the first '|' separates the drive head;
        // the accountIdentifier's own separators are percent-encoded, so a username
        // containing '|' still survives.
        let account = AccountDescriptor(
            backend: .classic,
            serverURL: URL(string: "https://cloud.example.org/owncloud")!,
            username: "od|d"
        )
        let root = SyncRoot(account: account, driveID: nil)!
        XCTAssertEqual(SyncRoot(domainIdentifier: root.domainIdentifier), root)
    }

    // MARK: - DomainDisplayNamer

    func testDisplayNamesNoCollisionUsesPlainSpaceName() {
        // Distinct space names → the space name is the domain's display name.
        let inputs = [
            DomainNameInput(syncRoot: SyncRoot(account: ocisAccount, driveID: "d1")!, spaceName: "Personal"),
            DomainNameInput(syncRoot: SyncRoot(account: ocisAccount, driveID: "d2")!, spaceName: "Project X"),
        ]
        let names = DomainDisplayNamer.displayNames(for: inputs)
        XCTAssertEqual(names[inputs[0].syncRoot.domainIdentifier], "Personal")
        XCTAssertEqual(names[inputs[1].syncRoot.domainIdentifier], "Project X")
    }

    func testDisplayNamesCrossAccountCollisionQualifiesByAccount() {
        // Two accounts each with a "Personal" space collide; qualify with the
        // account's display name so the sidebar rows are distinguishable.
        let other = AccountDescriptor(
            backend: .ocis, serverURL: URL(string: "https://other.test")!, username: "curie")
        let inputs = [
            DomainNameInput(syncRoot: SyncRoot(account: ocisAccount, driveID: "d1")!, spaceName: "Personal"),
            DomainNameInput(syncRoot: SyncRoot(account: other, driveID: "d2")!, spaceName: "Personal"),
        ]
        let names = DomainDisplayNamer.displayNames(for: inputs)
        XCTAssertEqual(names[inputs[0].syncRoot.domainIdentifier], "Personal (einstein@ocis.test)")
        XCTAssertEqual(names[inputs[1].syncRoot.domainIdentifier], "Personal (curie@other.test)")
    }

    func testDisplayNamesWithinAccountCollisionQualifiesByDrive() {
        // The same account with two spaces sharing a name: the account qualifier is
        // not enough, so the drive id disambiguates.
        let inputs = [
            DomainNameInput(syncRoot: SyncRoot(account: ocisAccount, driveID: "d1")!, spaceName: "Shared"),
            DomainNameInput(syncRoot: SyncRoot(account: ocisAccount, driveID: "d2")!, spaceName: "Shared"),
        ]
        let names = DomainDisplayNamer.displayNames(for: inputs)
        XCTAssertEqual(names[inputs[0].syncRoot.domainIdentifier], "Shared (einstein@ocis.test — d1)")
        XCTAssertEqual(names[inputs[1].syncRoot.domainIdentifier], "Shared (einstein@ocis.test — d2)")
    }
}

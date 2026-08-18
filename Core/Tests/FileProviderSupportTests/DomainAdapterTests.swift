#if canImport(FileProvider)
import XCTest
import FileProvider
@testable import FileProviderSupport
import OwnCloudCore

/// The Mac-only translation of the backend-agnostic account model (progress.md
/// Task 5.1) onto the FileProvider domain types. `AccountDescriptor` decides the
/// stable identifier and display name (tested in the core); here we verify the
/// `NSFileProviderDomain` construction and the removal-mode mapping — a wrong
/// identifier would duplicate the domain, a wrong removal mode would delete the
/// user's local files against their choice.
final class DomainAdapterTests: XCTestCase {

    private let account = AccountDescriptor(
        backend: .ocis,
        serverURL: URL(string: "https://ocis.test")!,
        username: "einstein"
    )

    func testDomainUsesSyncRootIdentifierAndGivenDisplayName() {
        let syncRoot = SyncRoot(account: account, driveID: "personal-drive")!
        let domain = NSFileProviderDomain(syncRoot: syncRoot, displayName: "Personal")
        XCTAssertEqual(domain.identifier.rawValue, syncRoot.domainIdentifier)
        XCTAssertEqual(domain.displayName, "Personal")
    }

    func testPreserveDownloadedMapsToPreserveDownloadedUserData() {
        XCTAssertEqual(
            DomainRemovalChoice.preserveDownloadedUserData.removalMode,
            .preserveDownloadedUserData
        )
    }

    func testRemoveAllMapsToRemoveAll() {
        XCTAssertEqual(DomainRemovalChoice.removeAll.removalMode, .removeAll)
    }

    func testDefaultChoicePreservesDownloadedData() {
        XCTAssertEqual(DomainRemovalChoice.default.removalMode, .preserveDownloadedUserData)
    }
}
#endif

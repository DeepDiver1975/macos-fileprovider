import XCTest
@testable import OwnCloudCore

/// Task 5.1 (core-testable part): the sign-in flow's backend detection and
/// domain-descriptor construction.
///
/// The `NSFileProviderManager.add(_:)` call, the `NSFileProviderDomain` object
/// and the `/Applications` discovery prerequisite are Mac-only; what the core
/// owns is deciding whether a URL is an ownCloud Classic or an oCIS server, and
/// producing the account descriptor the domain is built from.
final class AccountSetupTests: XCTestCase {

    // MARK: - Backend detection

    func testDetectsOCISFromOpenIDConfiguration() {
        // oCIS advertises an OIDC issuer at /.well-known/openid-configuration.
        let probe = BackendProbeResult(hasOpenIDConfiguration: true, classicStatusJSON: nil)
        XCTAssertEqual(BackendDetector.detect(from: probe), .ocis)
    }

    func testDetectsClassicFromStatusJSON() {
        // ownCloud Classic exposes /status.php with a version and product name.
        let status = """
        {"installed":true,"maintenance":false,"version":"10.15.0.0","productname":"ownCloud"}
        """
        let probe = BackendProbeResult(hasOpenIDConfiguration: false, classicStatusJSON: Data(status.utf8))
        XCTAssertEqual(BackendDetector.detect(from: probe), .classic)
    }

    func testPrefersOCISWhenBothPresent() {
        // A modern oCIS also serves a status.php shim; OIDC presence wins.
        let status = #"{"installed":true,"productname":"Infinite Scale"}"#
        let probe = BackendProbeResult(hasOpenIDConfiguration: true, classicStatusJSON: Data(status.utf8))
        XCTAssertEqual(BackendDetector.detect(from: probe), .ocis)
    }

    func testUnknownWhenNeitherSignalPresent() {
        let probe = BackendProbeResult(hasOpenIDConfiguration: false, classicStatusJSON: nil)
        XCTAssertNil(BackendDetector.detect(from: probe))
    }

    func testClassicStatusMustParseAsInstalled() {
        // A 200 with junk body is not a valid Classic server.
        let probe = BackendProbeResult(hasOpenIDConfiguration: false, classicStatusJSON: Data("not json".utf8))
        XCTAssertNil(BackendDetector.detect(from: probe))
    }

    // MARK: - Account descriptor / domain identifier

    func testAccountDescriptorBuildsStableDomainIdentifier() {
        let account = AccountDescriptor(
            backend: .ocis,
            serverURL: URL(string: "https://ocis.test")!,
            username: "einstein"
        )
        // Domain identifier is stable across launches for the same account.
        XCTAssertEqual(account.domainIdentifier, "ocis|https://ocis.test|einstein")
        XCTAssertEqual(account.displayName, "einstein@ocis.test")
    }

    func testAccountDescriptorDisplayNameUsesHost() {
        let account = AccountDescriptor(
            backend: .classic,
            serverURL: URL(string: "https://cloud.example.org/owncloud")!,
            username: "admin"
        )
        XCTAssertEqual(account.displayName, "admin@cloud.example.org")
    }

    func testAccountDescriptorRoundTripsThroughItsDomainIdentifier() {
        // The extension is handed only an NSFileProviderDomain (carrying the
        // identifier); it must reconstruct the account to build a backend source.
        let account = AccountDescriptor(
            backend: .ocis,
            serverURL: URL(string: "https://ocis.test")!,
            username: "einstein"
        )
        let restored = AccountDescriptor(domainIdentifier: account.domainIdentifier)
        XCTAssertEqual(restored, account)
    }

    func testDomainIdentifierRoundTripSurvivesPipeInUsername() {
        // Only the first two separators are structural — a '|' inside the username
        // must not corrupt the round trip.
        let account = AccountDescriptor(
            backend: .classic,
            serverURL: URL(string: "https://cloud.example.org/owncloud")!,
            username: "od|d"
        )
        XCTAssertEqual(AccountDescriptor(domainIdentifier: account.domainIdentifier), account)
    }

    func testMalformedDomainIdentifierReturnsNil() {
        XCTAssertNil(AccountDescriptor(domainIdentifier: "not-a-valid-identifier"))
        XCTAssertNil(AccountDescriptor(domainIdentifier: "bogusbackend|https://x.test|u"))
    }

    // MARK: - Removal mode mapping

    func testRemovalModeDefaultsToPreservingDownloads() {
        // Removing a domain should, by default, keep already-downloaded files on
        // disk (progress.md Phase 5 acceptance gate: DomainRemovalMode choice).
        XCTAssertEqual(DomainRemovalChoice.default, .preserveDownloadedUserData)
    }
}

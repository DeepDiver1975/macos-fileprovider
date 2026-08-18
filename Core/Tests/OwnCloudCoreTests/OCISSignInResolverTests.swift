import XCTest
@testable import OwnCloudCore

/// The headless decision layer of the oCIS OIDC sign-in flow (Task 7.12) — the
/// counterpart of ``SignInResolver`` for Infinite Scale.
///
/// After ``OIDCSignInCoordinator`` returns bearer credentials and the `me/drives`
/// listing has been fetched, this resolver turns them into the account identity and
/// one sync root per space. Unlike Classic there is no typed username: the account
/// is named from the `id_token` claims. Every decision (identity, credential, which
/// spaces become sync roots) lives here so the SwiftUI/networking layers stay thin.
final class OCISSignInResolverTests: XCTestCase {

    private let serverURL = URL(string: "https://ocis.test")!

    private func makeIDToken(payload: [String: Any]) -> String {
        func b64url(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
        let body = b64url(try! JSONSerialization.data(withJSONObject: payload))
        return "\(header).\(body).sig"
    }

    private func bearer() -> Credentials {
        .bearer(accessToken: "at", refreshToken: "rt", expiresAt: Date(timeIntervalSince1970: 3600))
    }

    private func drive(id: String, name: String, type: String) -> GraphDrive {
        GraphDrive(id: id, name: name, driveType: type, driveAlias: nil, quota: nil, root: nil)
    }

    /// The happy path: id_token claims name the oCIS account, the bearer credential
    /// is carried through, and every drive becomes a sync root under that account.
    func testResolvesOCISAccountAndPerSpaceSyncRoots() throws {
        let idToken = makeIDToken(payload: ["sub": "u-1", "preferred_username": "einstein"])
        let drives = [
            drive(id: "1$personal", name: "Personal", type: "personal"),
            drive(id: "2$project", name: "Project X", type: "project"),
        ]

        let resolved = try OCISSignInResolver.resolve(
            serverURL: serverURL,
            credentials: bearer(),
            idToken: idToken,
            drives: drives)

        XCTAssertEqual(resolved.account.backend, .ocis)
        XCTAssertEqual(resolved.account.username, "einstein")
        XCTAssertEqual(resolved.account.serverURL, serverURL)
        XCTAssertEqual(resolved.account.displayName, "einstein@ocis.test")
        XCTAssertEqual(resolved.credentials, bearer())

        // One sync root per drive, in listing order, each carrying that drive id.
        XCTAssertEqual(resolved.syncRoots.map(\.driveID), ["1$personal", "2$project"])
        XCTAssertTrue(resolved.syncRoots.allSatisfy { $0.account == resolved.account })

        // The catalog mirrors the drives so the Spaces tab can show them.
        XCTAssertEqual(resolved.catalog.spaces.map(\.name), ["Personal", "Project X"])
    }

    /// A malformed id_token surfaces as a typed error rather than a bad account name.
    func testRejectsMalformedIDToken() {
        XCTAssertThrowsError(try OCISSignInResolver.resolve(
            serverURL: serverURL,
            credentials: bearer(),
            idToken: "not-a-jwt",
            drives: [drive(id: "1$personal", name: "Personal", type: "personal")]))
    }

    /// A sign-in that returns no drives is rejected — there is nothing to sync and
    /// no domain could be created.
    func testRejectsEmptyDriveList() {
        XCTAssertThrowsError(try OCISSignInResolver.resolve(
            serverURL: serverURL,
            credentials: bearer(),
            idToken: makeIDToken(payload: ["sub": "u-1"]),
            drives: [])) { error in
            XCTAssertEqual(error as? OCISSignInError, .noSpaces)
        }
    }

    /// Basic credentials are not a valid product of an OIDC sign-in — the resolver
    /// rejects them so a mis-wired caller can't persist the wrong credential kind.
    func testRejectsNonBearerCredentials() {
        XCTAssertThrowsError(try OCISSignInResolver.resolve(
            serverURL: serverURL,
            credentials: .basic(username: "x", password: "y"),
            idToken: makeIDToken(payload: ["sub": "u-1"]),
            drives: [drive(id: "1$personal", name: "Personal", type: "personal")])) { error in
            XCTAssertEqual(error as? OCISSignInError, .notBearerCredentials)
        }
    }
}

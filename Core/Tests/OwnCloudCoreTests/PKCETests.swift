import XCTest
@testable import OwnCloudCore

/// PKCE (RFC 7636) for the oCIS OIDC sign-in flow (Task 7.8).
///
/// The verifier is a high-entropy random string; the S256 challenge is the
/// base64url-without-padding encoding of its SHA-256 hash. The transform is pinned
/// to the RFC 7636 Appendix B worked example, which fixes both the exact verifier
/// bytes and the expected challenge — so the base64url + SHA-256 wiring is verified
/// against the standard.
final class PKCETests: XCTestCase {

    /// RFC 7636 Appendix B: this exact verifier must produce this exact challenge.
    func testS256ChallengeMatchesRFCExample() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            PKCE.challengeS256(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    /// A freshly generated verifier is URL-safe and long enough to satisfy RFC 7636
    /// (43–128 chars from the unreserved set), and each generation differs.
    func testGeneratedVerifierIsHighEntropyAndURLSafe() {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let a = PKCE.generateVerifier()
        let b = PKCE.generateVerifier()

        XCTAssertGreaterThanOrEqual(a.count, 43)
        XCTAssertLessThanOrEqual(a.count, 128)
        XCTAssertTrue(a.unicodeScalars.allSatisfy { unreserved.contains($0) },
                      "verifier must be from the unreserved set")
        XCTAssertNotEqual(a, b, "each verifier must be random")
    }
}

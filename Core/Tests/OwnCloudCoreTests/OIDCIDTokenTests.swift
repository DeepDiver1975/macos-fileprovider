import XCTest
@testable import OwnCloudCore

/// Extracting the account identity from an OIDC `id_token` (Task 7.12).
///
/// Unlike the Classic flow, an oCIS OIDC sign-in never asks the user for a
/// username — the signed-in identity is carried in the `id_token`'s claims. This
/// parser reads that JWT's payload for the human-facing account name
/// (`preferred_username`, falling back to `email`, then the mandatory `sub`).
///
/// Security note pinned by these tests: the token arrives from the token endpoint
/// over TLS *inside the same code exchange*, so it is trusted as a claims container
/// for naming only — the parser deliberately does **not** verify the JWT signature,
/// and the account it names is never used as an authorization decision (the
/// `access_token` is the bearer credential). See ``OIDCIDToken``.
final class OIDCIDTokenTests: XCTestCase {

    /// A token carrying `preferred_username` names the account by that claim.
    func testExtractsPreferredUsername() throws {
        let token = Self.makeIDToken(payload: [
            "sub": "u-0815",
            "preferred_username": "einstein",
            "email": "einstein@ocis.test",
        ])

        let claims = try OIDCIDToken.claims(from: token)

        XCTAssertEqual(claims.subject, "u-0815")
        XCTAssertEqual(claims.preferredUsername, "einstein")
        XCTAssertEqual(claims.email, "einstein@ocis.test")
        XCTAssertEqual(claims.accountName, "einstein")
    }

    /// With no `preferred_username`, the account name falls back to `email`.
    func testFallsBackToEmailWhenNoPreferredUsername() throws {
        let token = Self.makeIDToken(payload: [
            "sub": "u-0815",
            "email": "einstein@ocis.test",
        ])

        let claims = try OIDCIDToken.claims(from: token)

        XCTAssertNil(claims.preferredUsername)
        XCTAssertEqual(claims.accountName, "einstein@ocis.test")
    }

    /// The classic jwt.io example (an external vector): `sub` present, no username
    /// or email, so the account name is the subject itself.
    func testFallsBackToSubjectUsingExternalVector() throws {
        // Header {"alg":"HS256","typ":"JWT"}, payload
        // {"sub":"1234567890","name":"John Doe","iat":1516239022}.
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
            + ".eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ"
            + ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

        let claims = try OIDCIDToken.claims(from: token)

        XCTAssertEqual(claims.subject, "1234567890")
        XCTAssertNil(claims.preferredUsername)
        XCTAssertNil(claims.email)
        XCTAssertEqual(claims.accountName, "1234567890")
    }

    /// An empty `preferred_username` (or `email`) is treated as absent, so the
    /// account name falls back rather than resolving to the empty string — the
    /// "never empty" invariant must hold for empty claims too, not just missing ones.
    func testEmptyStringClaimsFallThroughToSubject() throws {
        let token = Self.makeIDToken(payload: [
            "sub": "u-0815",
            "preferred_username": "",
            "email": "",
        ])

        let claims = try OIDCIDToken.claims(from: token)

        XCTAssertNil(claims.preferredUsername)
        XCTAssertNil(claims.email)
        XCTAssertEqual(claims.accountName, "u-0815")
    }

    /// A payload whose base64url encoding actually uses the URL-safe alphabet
    /// (`-`/`_` in place of `+`/`/`) decodes correctly — locks in the substitution.
    func testDecodesPayloadUsingURLSafeAlphabet() throws {
        // The bytes 0xFB 0xFF base64-encode to "+/8=" (contains + and /); base64url
        // encodes them as "-_8". Embed such bytes in the `sub` string via UTF-8 so
        // the payload's base64url genuinely carries `-` and `_`.
        let payload: [String: Any] = ["sub": "\u{00FB}\u{00FF}"]
        let token = Self.makeIDToken(payload: payload)
        // Precondition: the payload segment must contain a URL-safe-only character.
        let payloadSegment = token.split(separator: ".")[1]
        XCTAssertTrue(payloadSegment.contains("-") || payloadSegment.contains("_"),
                      "test vector must exercise the -/_ substitution; got \(payloadSegment)")

        let claims = try OIDCIDToken.claims(from: token)

        XCTAssertEqual(claims.subject, "\u{00FB}\u{00FF}")
    }

    /// A string that is not `header.payload.signature` is rejected.
    func testRejectsTokenWithoutThreeSegments() {
        XCTAssertThrowsError(try OIDCIDToken.claims(from: "not.a.jwt.token")) { error in
            XCTAssertEqual(error as? OIDCIDTokenError, .malformed)
        }
        XCTAssertThrowsError(try OIDCIDToken.claims(from: "onlyonesegment")) { error in
            XCTAssertEqual(error as? OIDCIDTokenError, .malformed)
        }
    }

    /// A payload that is not base64url-encoded JSON is rejected.
    func testRejectsNonJSONPayload() {
        let token = "aGVhZGVy.@@@notbase64@@@.sig"
        XCTAssertThrowsError(try OIDCIDToken.claims(from: token)) { error in
            XCTAssertEqual(error as? OIDCIDTokenError, .malformed)
        }
    }

    /// A payload missing the mandatory `sub` claim is rejected — without a subject
    /// there is no stable identity to key the account on.
    func testRejectsPayloadWithoutSubject() {
        let token = Self.makeIDToken(payload: ["preferred_username": "einstein"])
        XCTAssertThrowsError(try OIDCIDToken.claims(from: token)) { error in
            XCTAssertEqual(error as? OIDCIDTokenError, .malformed)
        }
    }

    // MARK: - Helper

    /// Build a `header.payload.signature` JWT whose payload is `payload` as
    /// base64url-no-pad JSON. The signature is a placeholder — the parser does not
    /// verify it. This encoder is the inverse of the parser under test, written
    /// independently here so the round-trip is a genuine check.
    private static func makeIDToken(payload: [String: Any]) -> String {
        func b64url(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
        let body = b64url(try! JSONSerialization.data(withJSONObject: payload))
        return "\(header).\(body).placeholder-signature"
    }
}

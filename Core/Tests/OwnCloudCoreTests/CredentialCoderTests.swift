import XCTest
@testable import OwnCloudCore

/// The pure serialization seam between `Credentials` and the raw bytes a Keychain
/// item stores (progress.md Task 1.3 / 2.5). The Keychain-backed store is
/// Mac-runtime, but the encode/decode of the credential payload is fully testable
/// here — so the byte format the shared access group persists is pinned down
/// headlessly, independent of `SecItem`.
final class CredentialCoderTests: XCTestCase {

    func testBasicCredentialsRoundTrip() throws {
        let creds = Credentials.basic(username: "admin", password: "s3cret")

        let data = try CredentialCoder.encode(creds)
        let decoded = try CredentialCoder.decode(data)

        XCTAssertEqual(decoded, creds)
    }

    func testBearerCredentialsRoundTrip() throws {
        let creds = Credentials.bearer(
            accessToken: "at-123",
            refreshToken: "rt-456",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try CredentialCoder.encode(creds)
        let decoded = try CredentialCoder.decode(data)

        XCTAssertEqual(decoded, creds)
    }

    func testBearerExpiryPreservedToTheSecond() throws {
        // The refresh scheduling in SessionManager compares against `expiresAt`,
        // so the persisted expiry must survive a round-trip without drift.
        let expiry = Date(timeIntervalSince1970: 1_699_999_999)
        let creds = Credentials.bearer(accessToken: "a", refreshToken: "r", expiresAt: expiry)

        let decoded = try CredentialCoder.decode(CredentialCoder.encode(creds))

        guard case let .bearer(_, _, decodedExpiry) = decoded else {
            return XCTFail("expected bearer credentials")
        }
        XCTAssertEqual(decodedExpiry.timeIntervalSince1970, expiry.timeIntervalSince1970, accuracy: 0.0001)
    }

    func testPasswordWithColonSurvives() throws {
        // Basic-auth header building splits username:password, but the stored
        // payload must not lose a colon that legitimately appears in a password.
        let creds = Credentials.basic(username: "user", password: "a:b:c")

        let decoded = try CredentialCoder.decode(try CredentialCoder.encode(creds))

        XCTAssertEqual(decoded, creds)
    }

    func testDecodingGarbageThrows() {
        XCTAssertThrowsError(try CredentialCoder.decode(Data("not json".utf8)))
    }
}

import XCTest
@testable import OwnCloudCore

/// A pure-Swift SHA-256 (Task 7.8 oCIS sign-in: PKCE S256 needs a hash, and the
/// package is deliberately Foundation-only / Linux-buildable — no swift-crypto).
/// Pinned to the published FIPS-180 / RFC 6234 vectors so the implementation is
/// verified against the standard, not against itself.
final class SHA256Tests: XCTestCase {

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    func testEmptyString() {
        XCTAssertEqual(
            hex(SHA256.hash(Array("".utf8))),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testABC() {
        XCTAssertEqual(
            hex(SHA256.hash(Array("abc".utf8))),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// 448-bit message — crosses a block boundary, exercising the length padding.
    func testTwoBlockMessage() {
        let message = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        XCTAssertEqual(
            hex(SHA256.hash(Array(message.utf8))),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    /// One million 'a's — the classic long-message vector, many blocks.
    func testMillionAs() {
        let message = [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(
            hex(SHA256.hash(message)),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
}

import Foundation

/// Proof Key for Code Exchange (RFC 7636) for the oCIS OIDC sign-in flow (Task 7.8).
///
/// A public client (this app has no server-side secret) protects the authorization
/// code by sending a `code_challenge` up front and revealing the matching
/// `code_verifier` only when it redeems the code. We always use the `S256` method:
/// the challenge is the base64url-without-padding encoding of the SHA-256 hash of
/// the verifier. Both pieces are pure; the SHA-256 comes from ``SHA256`` so the
/// package keeps no crypto dependency.
public enum PKCE {

    /// A random code verifier: 43–128 characters from the unreserved set
    /// (RFC 7636 §4.1). We generate 32 random bytes and base64url-encode them,
    /// yielding a 43-character verifier.
    public static func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return base64URLEncode(bytes)
    }

    /// The `S256` code challenge for `verifier`: base64url(SHA-256(verifier)).
    public static func challengeS256(for verifier: String) -> String {
        base64URLEncode(SHA256.hash(Array(verifier.utf8)))
    }

    /// Base64url without padding (RFC 4648 §5): `+`→`-`, `/`→`_`, and no trailing `=`.
    private static func base64URLEncode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

import Foundation

/// Why an OIDC `id_token` could not be turned into account claims (Task 7.12).
public enum OIDCIDTokenError: Error, Equatable {
    /// The token was not a `header.payload.signature` JWT, its payload was not
    /// base64url-encoded JSON, or the mandatory `sub` claim was absent.
    case malformed
}

/// The subset of `id_token` claims used to name an oCIS account at sign-in.
///
/// A Classic sign-in takes a typed username; an OIDC sign-in has none, so the
/// account identity comes from here. ``accountName`` is what the settings sidebar
/// shows and what seeds ``AccountDescriptor/username`` — `preferred_username` when
/// present, otherwise `email`, otherwise the always-present `subject`.
public struct OIDCIDTokenClaims: Equatable, Sendable {
    /// The mandatory `sub` claim — the stable, unique subject identifier.
    public let subject: String
    /// The `preferred_username` claim, if the IDP issued one.
    public let preferredUsername: String?
    /// The `email` claim, if present.
    public let email: String?

    public init(subject: String, preferredUsername: String?, email: String?) {
        self.subject = subject
        self.preferredUsername = preferredUsername
        self.email = email
    }

    /// The human-facing account name: `preferred_username`, else `email`, else the
    /// subject. Never empty because `subject` is required.
    public var accountName: String {
        preferredUsername ?? email ?? subject
    }
}

/// Reads the claims out of an OIDC `id_token`.
///
/// SECURITY: this deliberately does **not** verify the JWT signature. The
/// `id_token` is consumed only as it arrives from the token endpoint over TLS
/// during the code exchange we initiated (RFC 6749 §4.1.3), and its claims are used
/// solely to *name* the account for display. The bearer credential that authorizes
/// every request is the `access_token`, which the server validates on its side — so
/// a forged claim here can rename a display string but grants no access. Do not
/// reuse this parser to make authorization decisions.
public enum OIDCIDToken {

    /// Parse the `id_token`'s payload segment into ``OIDCIDTokenClaims``. Throws
    /// ``OIDCIDTokenError/malformed`` on a non-JWT string, an undecodable payload,
    /// or a missing `sub`.
    public static func claims(from idToken: String) throws -> OIDCIDTokenClaims {
        let segments = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let payloadData = base64URLDecode(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let subject = object["sub"] as? String, !subject.isEmpty
        else {
            throw OIDCIDTokenError.malformed
        }
        return OIDCIDTokenClaims(
            subject: subject,
            preferredUsername: nonEmptyString(object["preferred_username"]),
            email: nonEmptyString(object["email"]))
    }

    /// A claim value as a non-empty `String`, or `nil` — so an IDP that issues an
    /// empty `preferred_username`/`email` falls through to the next fallback rather
    /// than naming the account with the empty string (``OIDCIDTokenClaims/accountName``
    /// must never be empty).
    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    /// Decode a base64url segment (no padding, `-`/`_` alphabet) into bytes.
    private static func base64URLDecode(_ segment: String) -> Data? {
        var base64 = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Restore the padding base64url strips so Foundation's decoder accepts it.
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}

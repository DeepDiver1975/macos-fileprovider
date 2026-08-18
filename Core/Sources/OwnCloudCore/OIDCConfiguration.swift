import Foundation

/// Why an OIDC discovery document could not be turned into an ``OIDCConfiguration``.
public enum OIDCConfigurationError: Error, Equatable {
    /// The `/.well-known/openid-configuration` body was not JSON, or lacked a
    /// mandatory endpoint (`authorization_endpoint` / `token_endpoint`).
    case malformedDiscoveryDocument
}

/// The subset of the OIDC discovery document (`/.well-known/openid-configuration`,
/// RFC 8414) the oCIS sign-in flow needs (Task 7.8).
///
/// oCIS advertises its IDP endpoints here rather than at fixed paths, so both
/// sign-in (authorization + token exchange) and refresh (token) resolve the real
/// URLs from this document. Parsing is pure; the Mac networking layer fetches the
/// bytes and hands them here.
public struct OIDCConfiguration: Equatable, Sendable {
    public let issuer: URL
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL

    public init(issuer: URL, authorizationEndpoint: URL, tokenEndpoint: URL) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
    }

    /// Parse a discovery-document body. Throws
    /// ``OIDCConfigurationError/malformedDiscoveryDocument`` on non-JSON or a
    /// missing/unparseable `issuer`, `authorization_endpoint`, or `token_endpoint`.
    public init(discoveryJSON data: Data) throws {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let issuer = Self.url(object["issuer"]),
            let authorization = Self.url(object["authorization_endpoint"]),
            let token = Self.url(object["token_endpoint"])
        else {
            throw OIDCConfigurationError.malformedDiscoveryDocument
        }
        self.init(issuer: issuer, authorizationEndpoint: authorization, tokenEndpoint: token)
    }

    private static func url(_ value: Any?) -> URL? {
        guard let string = value as? String else { return nil }
        return URL(string: string)
    }
}

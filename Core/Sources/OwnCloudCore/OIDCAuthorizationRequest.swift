import Foundation

/// Why an OIDC authorization callback could not be turned into an authorization code.
public enum OIDCAuthorizationError: Error, Equatable {
    /// The callback's `state` did not match the one we sent — a possible CSRF /
    /// injected-response attempt (RFC 6749 §10.12). The code is rejected.
    case stateMismatch
    /// The IDP redirected back with an `error` parameter (e.g. `access_denied`).
    case server(String)
    /// The callback carried neither an `error` nor a `code`.
    case missingCode
}

/// The authorization-request half of the OIDC Authorization Code + PKCE flow
/// (Task 7.8): shape the URL the user's browser is sent to, and parse the redirect
/// the IDP returns to our custom scheme.
///
/// Both steps are pure so the whole decision is testable; the Mac adapter's only
/// jobs are to present ``authorizationURL`` in an `ASWebAuthenticationSession` and
/// to hand the returned callback URL to ``authorizationCode(fromCallback:expectedState:)``.
public struct OIDCAuthorizationRequest {

    public let configuration: OIDCConfiguration
    public let clientID: String
    public let redirectURI: String
    public let scope: String
    public let state: String
    public let codeChallenge: String

    public init(
        configuration: OIDCConfiguration,
        clientID: String,
        redirectURI: String,
        scope: String,
        state: String,
        codeChallenge: String
    ) {
        self.configuration = configuration
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scope = scope
        self.state = state
        self.codeChallenge = codeChallenge
    }

    /// The URL to load in the web-auth session: the IDP's authorization endpoint
    /// with the Authorization Code + PKCE (`S256`) query parameters.
    public var authorizationURL: URL {
        var components = URLComponents(
            url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    /// Extract the authorization `code` from the IDP's redirect, first validating
    /// `state` against the value we sent.
    ///
    /// Order matters: `state` is checked before anything else, so a response with a
    /// forged/mismatched state is rejected even if it carries a plausible code. A
    /// server-reported `error` is surfaced verbatim; a callback with neither error
    /// nor code is ``OIDCAuthorizationError/missingCode``.
    public static func authorizationCode(
        fromCallback callback: URL,
        expectedState: String
    ) throws -> String {
        let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        guard value("state") == expectedState else {
            throw OIDCAuthorizationError.stateMismatch
        }
        if let error = value("error") {
            throw OIDCAuthorizationError.server(error)
        }
        guard let code = value("code") else {
            throw OIDCAuthorizationError.missingCode
        }
        return code
    }
}

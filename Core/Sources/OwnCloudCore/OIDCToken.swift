import Foundation

/// Why an OIDC token refresh could not be turned into `Credentials` (Task 2.5).
public enum OIDCTokenError: Error, Equatable {
    /// The token endpoint's response was not parseable JSON, or lacked the
    /// mandatory `access_token`.
    case malformedResponse
}

/// Shapes the OAuth2 `refresh_token` grant sent to an OIDC token endpoint — the
/// pure counterpart of `SessionManager.RefreshHandler` for oCIS. The token
/// endpoint URL comes from `/.well-known/openid-configuration` discovery (done by
/// the Mac networking layer); shaping the form-encoded POST is pure and tested
/// here.
public struct OIDCTokenRequestBuilder {

    public let tokenEndpoint: URL

    public init(tokenEndpoint: URL) {
        self.tokenEndpoint = tokenEndpoint
    }

    /// A `grant_type=refresh_token` POST with an `application/x-www-form-urlencoded`
    /// body. `scope` is included only when non-nil (RFC 6749 §6 makes it optional),
    /// and `clientSecret` only for a client registered with one — a secret-less
    /// public client must not send an empty field.
    public func refresh(refreshToken: String,
                        clientID: String,
                        clientSecret: String? = nil,
                        scope: String?) -> RemoteRequest {
        var fields = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ]
        if let clientSecret {
            fields.append(("client_secret", clientSecret))
        }
        if let scope {
            fields.append(("scope", scope))
        }
        return post(fields)
    }

    /// A `grant_type=authorization_code` POST that redeems the code the browser
    /// handed back for tokens (RFC 6749 §4.1.3 + RFC 7636 §4.5). `code_verifier` is
    /// the PKCE secret proving this client began the flow; `redirect_uri` must match
    /// the one sent to the authorization endpoint. `clientSecret` is sent only for a
    /// client registered with one (oCIS's native clients are — see
    /// ``OCISClientRegistration``); a public client must not send an empty field.
    public func exchange(code: String,
                         redirectURI: String,
                         clientID: String,
                         clientSecret: String? = nil,
                         codeVerifier: String) -> RemoteRequest {
        var fields = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
        ]
        if let clientSecret {
            fields.append(("client_secret", clientSecret))
        }
        fields.append(("code_verifier", codeVerifier))
        return post(fields)
    }

    /// Shape a form-encoded POST to the token endpoint from ordered fields.
    private func post(_ fields: [(String, String)]) -> RemoteRequest {
        let body = fields
            .map { "\($0.0)=\(Self.formEncode($0.1))" }
            .joined(separator: "&")
        return RemoteRequest(
            method: .post,
            url: tokenEndpoint,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            hasBody: true,
            jsonBody: Data(body.utf8)
        )
    }

    /// Percent-encode a form value: only the unreserved set survives, so `+`, `/`,
    /// `=`, and spaces (as `%20`) are all escaped rather than misread by the server.
    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Decodes an OIDC token-endpoint response into `Credentials.bearer`.
public enum OIDCTokenResponse {

    /// Parse the token JSON, resolving the relative `expires_in` (seconds) into an
    /// absolute expiry against `now`. Per OAuth2 the response `refresh_token` is
    /// optional; when absent the caller's `previousRefreshToken` is retained.
    /// Throws ``OIDCTokenError/malformedResponse`` on non-JSON or a missing
    /// `access_token`.
    public static func credentials(
        from data: Data,
        now: Date,
        previousRefreshToken: String
    ) throws -> Credentials {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = object["access_token"] as? String
        else {
            throw OIDCTokenError.malformedResponse
        }
        let refreshToken = (object["refresh_token"] as? String) ?? previousRefreshToken
        // `expires_in` is seconds-from-now; default to 0 (immediately stale) if the
        // server omits it, so the next request triggers another refresh.
        let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue ?? 0
        return .bearer(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(expiresIn)
        )
    }

    /// The `id_token` field of a token response, if present — the JWT the account is
    /// named from (``OIDCIDToken``). Returns `nil` for non-JSON or a response that
    /// omits it (the refresh grant, for one, need not re-issue it).
    public static func idToken(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["id_token"] as? String
    }
}

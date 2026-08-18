import Foundation

/// Composes the OIDC token endpoint into a ``SessionManager/RefreshHandler``
/// (Task 7.6 / the Task 2.5 remainder).
///
/// The three pieces are each already tested: ``OIDCTokenRequestBuilder/refresh``
/// shapes the `grant_type=refresh_token` POST, a transport sends it, and
/// ``OIDCTokenResponse/credentials(from:now:previousRefreshToken:)`` parses the
/// reply (retaining the old refresh token when the server omits a new one). This
/// factory is the wiring that turns them into the synchronous handler
/// `SessionManager` calls.
///
/// The `send` closure is synchronous because `RefreshHandler` is: refresh happens
/// under the exclusive ``RefreshLock`` (Task 7.6), where a synchronous, blocking
/// round-trip is exactly what serializes the N instances. The Mac wiring passes a
/// closure that drives the token request over `URLSession` synchronously.
public enum OIDCRefreshHandler {

    /// A synchronous transport for the token request: shape → bytes.
    public typealias Send = (_ request: RemoteRequest) throws -> Data

    /// Build a ``SessionManager/RefreshHandler`` bound to a token endpoint.
    public static func make(
        tokenEndpoint: URL,
        clientID: String,
        scope: String?,
        now: @escaping () -> Date = Date.init,
        send: @escaping Send
    ) -> SessionManager.RefreshHandler {
        let builder = OIDCTokenRequestBuilder(tokenEndpoint: tokenEndpoint)
        return { refreshToken in
            let request = builder.refresh(refreshToken: refreshToken, clientID: clientID, scope: scope)
            let data = try send(request)
            return try OIDCTokenResponse.credentials(
                from: data, now: now(), previousRefreshToken: refreshToken)
        }
    }
}

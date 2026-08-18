#if canImport(AuthenticationServices)
import Foundation
import AuthenticationServices
import OwnCloudCore

/// Presents the OIDC authorization URL in an `ASWebAuthenticationSession` and
/// returns the redirect callback — the one genuinely GUI-gated step of the oCIS
/// sign-in flow (Task 7.8). Every decision around it (building the URL, validating
/// the callback's `state`, redeeming the code) lives in the pure
/// ``OIDCSignInCoordinator``; this adapter only drives the system browser sheet.
///
/// It exists to supply the coordinator's `authorize` closure; the other two
/// closures are plain `RemoteClient` GET/POSTs:
///
///     let coordinator = OIDCSignInCoordinator(
///         clientID: clientID, redirectURI: callbackScheme + "://oidc", scope: scope,
///         fetchDiscovery: { serverURL in
///             try await client.send(RemoteRequest(method: .get,
///                 url: serverURL.appendingPathComponent(".well-known/openid-configuration")),
///                 authorization: nil)
///         },
///         authorize: presenter.authorize,
///         sendToken: { try await client.send($0, authorization: nil) })
///
/// `ASWebAuthenticationSession` is Darwin-only, so the whole file is gated and the
/// package still builds on Linux.
@MainActor
public final class WebAuthorizationPresenter: NSObject {

    /// The custom URL scheme the IDP redirects back to (e.g. `oc`), which the
    /// session watches for to capture the callback and dismiss the sheet.
    private let callbackScheme: String
    private let anchorProvider: (() -> ASPresentationAnchor)?

    /// - Parameters:
    ///   - callbackScheme: the scheme of the app's `redirect_uri`, without `://`.
    ///   - anchor: the window the auth sheet is presented from. When `nil` a new
    ///     anchor is created on the main actor, which AppKit attaches to the key
    ///     window.
    public init(
        callbackScheme: String,
        anchor: (() -> ASPresentationAnchor)? = nil
    ) {
        self.callbackScheme = callbackScheme
        self.anchorProvider = anchor
        super.init()
    }

    /// Present `authorizationURL` and resume with the redirect callback URL, or
    /// throw if the user cancels or the session fails. Suitable as the
    /// ``OIDCSignInCoordinator`` `authorize` closure.
    public func authorize(_ authorizationURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: callbackScheme
            ) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: error ?? ASWebAuthenticationSessionError(.canceledLogin))
                }
            }
            session.presentationContextProvider = self
            // A fresh sign-in should not silently reuse a stale IDP cookie.
            session.prefersEphemeralWebBrowserSession = true
            // `start()` returns false when the session can't be presented (no key
            // window / presentation context). In that case the completion handler
            // never fires, so resume here or the whole `signIn` await hangs forever.
            if !session.start() {
                continuation.resume(throwing: ASWebAuthenticationSessionError(.presentationContextNotProvided))
            }
        }
    }
}

extension WebAuthorizationPresenter: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchorProvider?() ?? ASPresentationAnchor()
    }
}
#endif

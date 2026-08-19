import Foundation

/// The OAuth2 client the app identifies itself as when signing in to oCIS
/// (GitHub issue #17).
///
/// oCIS's IDP (Konnect/libregraph-lico) does **not** allow dynamic client
/// registration — `AllowDynamicClientRegistration` is `false` in its shipped
/// defaults — so a client cannot invent its own id. It must present one of the
/// registrations every oCIS install already carries.
///
/// Bundling the id, its secret, the redirect URI and the scope in one value keeps
/// them consistent: lico compares a custom-scheme `redirect_uri` by **string
/// equality** against the registration, and the token endpoint then requires the
/// same string again in the code exchange. Two hand-written copies of it would be
/// two chances to drift.
public struct OCISClientRegistration: Sendable, Equatable {
    public let clientID: String
    /// The registered secret, or `nil` for a secret-less public client (oCIS's
    /// `web` client has none). lico's token endpoint accepts it as a plain
    /// `client_secret` form field.
    public let clientSecret: String?
    public let redirectURI: String
    public let scope: String

    public init(clientID: String, clientSecret: String?, redirectURI: String, scope: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.scope = scope
    }

    /// The scheme of ``redirectURI`` — what `ASWebAuthenticationSession` watches for
    /// to capture the callback. Derived rather than stored so it cannot disagree
    /// with the redirect URI the IDP was given.
    public var callbackScheme: String {
        redirectURI.components(separatedBy: "://").first ?? redirectURI
    }

    /// The ownCloud mobile client registration, present in **every** oCIS install:
    /// see `services/idp/pkg/config/defaults/defaultconfig.go` in `owncloud/ocis`
    /// (verified against v8.2.0). It is registered `application_type: native` with
    /// the custom-scheme redirect below — the shape `ASWebAuthenticationSession`
    /// can capture, unlike the `web` client's `https://<server>/` redirects.
    ///
    /// The secret is **not** a confidential credential: it is a published constant
    /// shipped identically to every oCIS deployment and readable in the oCIS source.
    /// A native app cannot keep a secret anyway (RFC 8252 §8.5), which is why PKCE —
    /// not this string — is what actually protects the code exchange.
    ///
    /// `offline_access` is what makes the IDP issue a refresh token; without it the
    /// domain stops working when the first access token expires (5 minutes).
    public static let ownCloudMobile = OCISClientRegistration(
        clientID: "mxd5OQDk6es5LzOzRvidJNfXLUZS2oN3oUFeXPP8LpPrhx3UroJFduGEYIBOxkY1",
        clientSecret: "KFeFWWEZO9TkisIQzR3fo7hfiMXlOpaqP8CFuTbSHzV1TUuGECglPxpiVKJfOXIx",
        redirectURI: "oc://ios.owncloud.com",
        scope: "openid profile email offline_access")
}

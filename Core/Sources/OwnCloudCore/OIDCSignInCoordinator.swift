import Foundation

/// Orchestrates the oCIS OIDC Authorization Code + PKCE sign-in (Task 7.8),
/// composing the pure pieces — ``OIDCConfiguration`` discovery, ``PKCE``,
/// ``OIDCAuthorizationRequest``, and ``OIDCTokenRequestBuilder/exchange`` — into a
/// single async result.
///
/// Everything that touches the outside world is an injected closure, mirroring how
/// ``OIDCRefreshHandler`` injects its `send`: `fetchDiscovery` performs the
/// `/.well-known/openid-configuration` GET, `authorize` presents the authorization
/// URL (the Mac adapter drives `ASWebAuthenticationSession` and returns the
/// redirect callback), and `sendToken` performs the token-endpoint POST. The random
/// `state` and PKCE verifier are injected too, so the whole flow is deterministic in
/// tests. The coordinator itself is Foundation-only and Linux-buildable.
public struct OIDCSignInCoordinator {

    /// Fetch the raw `/.well-known/openid-configuration` body for a server.
    public typealias FetchDiscovery = (_ serverURL: URL) async throws -> Data
    /// Present the authorization URL and return the redirect callback URL.
    public typealias Authorize = (_ authorizationURL: URL) async throws -> URL
    /// Perform the token-endpoint POST and return its body.
    public typealias SendToken = (_ request: RemoteRequest) async throws -> Data

    /// The outcome of a successful sign-in: the tokens to store, and the discovered
    /// configuration so the caller can wire refresh to the same token endpoint.
    public struct Success: Equatable {
        public let credentials: Credentials
        public let configuration: OIDCConfiguration
        /// The raw `id_token` JWT from the token response, if the server issued one.
        /// An OIDC sign-in has no typed username, so the account is named from this
        /// token's claims (``OIDCIDToken``). `nil` when the response omits it.
        public let idToken: String?

        public init(credentials: Credentials, configuration: OIDCConfiguration, idToken: String?) {
            self.credentials = credentials
            self.configuration = configuration
            self.idToken = idToken
        }
    }

    private let clientID: String
    private let clientSecret: String?
    private let redirectURI: String
    private let scope: String
    private let now: () -> Date
    private let generateState: () -> String
    private let generateVerifier: () -> String
    private let fetchDiscovery: FetchDiscovery
    private let authorize: Authorize
    private let sendToken: SendToken

    /// - Parameter clientSecret: the registered client's secret, or `nil` for a
    ///   public client. oCIS's native registrations carry one (see
    ///   ``OCISClientRegistration``); PKCE, not the secret, is what protects the
    ///   exchange for an app that cannot keep secrets.
    public init(
        clientID: String,
        clientSecret: String? = nil,
        redirectURI: String,
        scope: String,
        now: @escaping () -> Date = Date.init,
        generateState: @escaping () -> String = { PKCE.generateVerifier() },
        generateVerifier: @escaping () -> String = PKCE.generateVerifier,
        fetchDiscovery: @escaping FetchDiscovery,
        authorize: @escaping Authorize,
        sendToken: @escaping SendToken
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.scope = scope
        self.now = now
        self.generateState = generateState
        self.generateVerifier = generateVerifier
        self.fetchDiscovery = fetchDiscovery
        self.authorize = authorize
        self.sendToken = sendToken
    }

    /// Run the full sign-in against `serverURL`, returning bearer credentials and
    /// the discovered configuration. Throws on discovery failure, a state mismatch
    /// or server error in the callback, or a malformed token response.
    public func signIn(serverURL: URL) async throws -> Success {
        let configuration = try OIDCConfiguration(discoveryJSON: await fetchDiscovery(serverURL))

        let state = generateState()
        let verifier = generateVerifier()
        let authorizationRequest = OIDCAuthorizationRequest(
            configuration: configuration,
            clientID: clientID,
            redirectURI: redirectURI,
            scope: scope,
            state: state,
            codeChallenge: PKCE.challengeS256(for: verifier))

        let callback = try await authorize(authorizationRequest.authorizationURL)
        let code = try OIDCAuthorizationRequest.authorizationCode(
            fromCallback: callback, expectedState: state)

        let builder = OIDCTokenRequestBuilder(tokenEndpoint: configuration.tokenEndpoint)
        let exchange = builder.exchange(
            code: code, redirectURI: redirectURI, clientID: clientID,
            clientSecret: clientSecret, codeVerifier: verifier)
        let tokenData = try await sendToken(exchange)

        // A brand-new sign-in has no prior refresh token to retain.
        let credentials = try OIDCTokenResponse.credentials(
            from: tokenData, now: now(), previousRefreshToken: "")
        return Success(
            credentials: credentials,
            configuration: configuration,
            idToken: OIDCTokenResponse.idToken(from: tokenData))
    }
}

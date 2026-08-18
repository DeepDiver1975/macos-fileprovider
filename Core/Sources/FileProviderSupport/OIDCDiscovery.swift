import Foundation
import OwnCloudCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches and parses the oCIS OIDC discovery document (Task 7.8) — the thin
/// networking adapter feeding the pure ``OIDCConfiguration`` parser, and the oCIS
/// sibling of ``HTTPServerProbe`` in the Classic flow.
///
/// Behind a protocol so ``OIDCSignInCoordinator``'s `fetchDiscovery` closure can be
/// faked in tests; the live conformer GETs `/.well-known/openid-configuration`
/// through ``RemoteClient`` and is exercised by `OIDCDiscoveryContractTests` against
/// the Docker fixture.
public protocol OIDCDiscovering: Sendable {
    /// Fetch and parse the discovery document advertised by `serverURL`.
    func configuration(serverURL: URL) async throws -> OIDCConfiguration
}

/// An ``OIDCDiscovering`` backed by live HTTP through ``RemoteClient``.
public struct HTTPOIDCDiscovery: OIDCDiscovering {

    private let client: RemoteClient

    public init(client: RemoteClient = .urlSession()) {
        self.client = client
    }

    public func configuration(serverURL: URL) async throws -> OIDCConfiguration {
        let url = serverURL.appendingPathComponent(".well-known/openid-configuration")
        let data = try await client.send(RemoteRequest(method: .get, url: url), authorization: nil)
        return try OIDCConfiguration(discoveryJSON: data)
    }
}

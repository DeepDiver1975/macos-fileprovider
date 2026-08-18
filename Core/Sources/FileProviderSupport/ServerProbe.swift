import Foundation
import OwnCloudCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Mac-only networking half of the Classic sign-in flow (Task 7.11).
///
/// ``SignInResolver`` is the pure decision layer; it consumes a
/// ``BackendProbeResult`` and never touches the network. This adapter produces
/// that probe result by asking the server two questions the way
/// ``BackendDetector`` expects them answered:
///
/// - Does the server serve `/.well-known/openid-configuration`? A success is the
///   OIDC signal (`hasOpenIDConfiguration = true`).
/// - What does `/status.php` return? Its body is the Classic signal
///   (`classicStatusJSON`), which the detector parses for `installed == true`.
///
/// Because a Classic server does **not** serve the OIDC document (it answers 404,
/// which ``RemoteClient.send`` turns into a thrown ``RemoteError``), every probe
/// request is wrapped so that any error — non-2xx, offline, TLS — becomes the
/// *negative* signal rather than propagating. A server that answers neither
/// question is simply reported as "not detected" by the resolver.
public protocol ServerProbing: Sendable {
    /// Probe `serverURL` and report which backend signals it exhibits.
    func probe(serverURL: URL) async -> BackendProbeResult
}

/// A ``ServerProbing`` backed by live HTTP through ``RemoteClient``.
public struct HTTPServerProbe: ServerProbing {

    private let client: RemoteClient

    public init(client: RemoteClient = .urlSession()) {
        self.client = client
    }

    public func probe(serverURL: URL) async -> BackendProbeResult {
        let hasOIDC = await succeeds(path: ".well-known/openid-configuration", on: serverURL)
        let statusJSON = await body(path: "status.php", on: serverURL)
        return BackendProbeResult(hasOpenIDConfiguration: hasOIDC, classicStatusJSON: statusJSON)
    }

    /// `true` when a GET of `path` returns 2xx; any error is a negative signal.
    private func succeeds(path: String, on serverURL: URL) async -> Bool {
        await body(path: path, on: serverURL) != nil
    }

    /// The 2xx body of a GET of `path`, or `nil` on any failure (non-2xx, offline).
    private func body(path: String, on serverURL: URL) async -> Data? {
        let url = serverURL.appendingPathComponent(path)
        let request = RemoteRequest(method: .get, url: url)
        return try? await client.send(request, authorization: nil)
    }
}

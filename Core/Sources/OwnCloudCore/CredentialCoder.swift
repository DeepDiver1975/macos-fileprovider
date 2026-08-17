import Foundation

/// Serializes ``Credentials`` to and from the raw bytes a Keychain item holds
/// (progress.md Task 1.3 / 2.5). Kept separate from the Mac-only Keychain store
/// so the persisted byte format — the contract shared between the app's sign-in
/// flow and the extension — is testable without `SecItem` or a signed host.
///
/// The wire format is a small tagged JSON object; a scheme tag plus the fields
/// for that scheme, with the bearer expiry stored as a Unix timestamp so it
/// survives a round-trip without date-format ambiguity.
public enum CredentialCoder {

    public enum CodingError: Error, Equatable {
        /// The bytes are not a credential payload this version understands.
        case malformed
    }

    private struct Payload: Codable {
        var scheme: String
        var username: String?
        var password: String?
        var accessToken: String?
        var refreshToken: String?
        var expiresAt: Double?
    }

    private static let basicScheme = "basic"
    private static let bearerScheme = "bearer"

    public static func encode(_ credentials: Credentials) throws -> Data {
        let payload: Payload
        switch credentials {
        case let .basic(username, password):
            payload = Payload(scheme: basicScheme, username: username, password: password,
                              accessToken: nil, refreshToken: nil, expiresAt: nil)
        case let .bearer(accessToken, refreshToken, expiresAt):
            payload = Payload(scheme: bearerScheme, username: nil, password: nil,
                              accessToken: accessToken, refreshToken: refreshToken,
                              expiresAt: expiresAt.timeIntervalSince1970)
        }
        return try JSONEncoder().encode(payload)
    }

    public static func decode(_ data: Data) throws -> Credentials {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw CodingError.malformed
        }
        switch payload.scheme {
        case basicScheme:
            guard let username = payload.username, let password = payload.password else {
                throw CodingError.malformed
            }
            return .basic(username: username, password: password)
        case bearerScheme:
            guard let accessToken = payload.accessToken,
                  let refreshToken = payload.refreshToken,
                  let expiresAt = payload.expiresAt
            else {
                throw CodingError.malformed
            }
            return .bearer(accessToken: accessToken, refreshToken: refreshToken,
                           expiresAt: Date(timeIntervalSince1970: expiresAt))
        default:
            throw CodingError.malformed
        }
    }
}

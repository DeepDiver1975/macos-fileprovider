import Foundation

/// Builds ownCloud Classic **OCS provisioning API** requests used by the
/// acceptance harness (progress.md Task 6.3) to create and remove fixture users
/// through the backend's own admin API rather than its storage (AC-1).
///
/// Pure request shaping, no networking — the Mac-only harness attaches admin
/// credentials and issues these against the live container.
public struct OCSProvisioningRequestBuilder {

    /// The server root, e.g. `https://cloud.test`.
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    private static let usersPath = "/ocs/v1.php/cloud/users"

    /// The OCS API rejects calls without this header (HTTP 403).
    private var ocsHeaders: [String: String] { ["OCS-APIRequest": "true"] }

    private func url(_ path: String) -> URL {
        URL(string: baseURL.absoluteString + path) ?? baseURL
    }

    public func createUser(username: String, password: String) -> RemoteRequest {
        let body = "userid=\(FormEncoding.encode(username))&password=\(FormEncoding.encode(password))"
        return RemoteRequest(
            method: .post,
            url: url(Self.usersPath),
            headers: ocsHeaders,
            hasBody: true,
            jsonBody: Data(body.utf8)
        )
    }

    public func deleteUser(username: String) -> RemoteRequest {
        RemoteRequest(
            method: .delete,
            url: url(Self.usersPath + "/" + username),
            headers: ocsHeaders
        )
    }
}

/// Builds oCIS **Graph users** requests for the same fixture provisioning
/// (progress.md Task 6.3).
public struct GraphProvisioningRequestBuilder {

    /// The oCIS root, e.g. `https://ocis.test`.
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    private static let usersPath = "/graph/v1.0/users"

    private func url(_ path: String) -> URL {
        URL(string: baseURL.absoluteString + path) ?? baseURL
    }

    public func createUser(username: String, displayName: String, password: String) -> RemoteRequest {
        let payload: [String: Any] = [
            "onPremisesSamAccountName": username,
            "displayName": displayName,
            "passwordProfile": ["password": password],
        ]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return RemoteRequest(
            method: .post,
            url: url(Self.usersPath),
            headers: ["Content-Type": "application/json"],
            hasBody: true,
            jsonBody: body
        )
    }

    public func deleteUser(id: String) -> RemoteRequest {
        RemoteRequest(method: .delete, url: url(Self.usersPath + "/" + id))
    }
}

/// `application/x-www-form-urlencoded` value encoding for the OCS body. Spaces
/// become `%20` (not `+`), matching what the OCS endpoint accepts.
enum FormEncoding {
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

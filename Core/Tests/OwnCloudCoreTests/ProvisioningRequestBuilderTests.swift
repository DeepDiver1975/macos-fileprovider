import XCTest
@testable import OwnCloudCore

/// Task 6.3: the `BackendAdmin` provisioning requests — create a fixture user
/// through each backend's own admin API (never by reaching into a container's
/// storage, per AC-1). Classic uses the OCS provisioning API; oCIS uses the
/// Graph users endpoint.
///
/// This is pure request shaping, like the Phase 4 `RemoteRequestBuilder`s, so it
/// is fully unit-testable here. Actually issuing the requests against a live
/// backend is the Mac + Docker half of Task 6.3.
final class ProvisioningRequestBuilderTests: XCTestCase {

    // MARK: Classic — OCS provisioning API

    private let ocs = OCSProvisioningRequestBuilder(
        baseURL: URL(string: "https://cloud.test")!
    )

    func testCreateUserPostsToOCSUsersEndpoint() {
        let request = ocs.createUser(username: "alice", password: "s3cret")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.absoluteString, "https://cloud.test/ocs/v1.php/cloud/users")
    }

    func testCreateUserSendsOCSAPIRequestHeader() {
        // Without OCS-APIRequest: true the server rejects the call with 403.
        let request = ocs.createUser(username: "alice", password: "s3cret")
        XCTAssertEqual(request.headers["OCS-APIRequest"], "true")
    }

    func testCreateUserFormEncodesCredentials() {
        let request = ocs.createUser(username: "alice", password: "p@ss word")
        XCTAssertTrue(request.hasBody)
        let body = String(data: request.jsonBody ?? Data(), encoding: .utf8)
        XCTAssertEqual(body, "userid=alice&password=p%40ss%20word")
    }

    func testDeleteUserTargetsTheUser() {
        let request = ocs.deleteUser(username: "alice")
        XCTAssertEqual(request.method, .delete)
        XCTAssertEqual(request.url.absoluteString, "https://cloud.test/ocs/v1.php/cloud/users/alice")
        XCTAssertEqual(request.headers["OCS-APIRequest"], "true")
    }

    // MARK: oCIS — Graph users endpoint

    private let graph = GraphProvisioningRequestBuilder(
        baseURL: URL(string: "https://ocis.test")!
    )

    func testGraphCreateUserPostsJSONToUsersEndpoint() {
        let request = graph.createUser(username: "bob", displayName: "Bob", password: "s3cret")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.absoluteString, "https://ocis.test/graph/v1.0/users")
        XCTAssertTrue(request.hasBody)

        let json = try? JSONSerialization.jsonObject(with: request.jsonBody ?? Data()) as? [String: Any]
        XCTAssertEqual(json?["onPremisesSamAccountName"] as? String, "bob")
        XCTAssertEqual(json?["displayName"] as? String, "Bob")
        XCTAssertEqual(json?["passwordProfile"] as? [String: String], ["password": "s3cret"])
    }

    func testGraphDeleteUserTargetsTheUserID() {
        let request = graph.deleteUser(id: "user-123")
        XCTAssertEqual(request.method, .delete)
        XCTAssertEqual(request.url.absoluteString, "https://ocis.test/graph/v1.0/users/user-123")
    }
}

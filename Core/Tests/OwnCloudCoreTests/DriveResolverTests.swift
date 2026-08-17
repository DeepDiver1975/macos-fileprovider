import XCTest
@testable import OwnCloudCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Task 5.1 (oCIS drive-id resolution): at sign-in the provider must learn which
/// Graph drive the domain maps to. `DriveResolver` lists the user's drives
/// (`GET /me/drives`) over an injected `RemoteClient` and picks the personal one,
/// so the `BackendConnection` can be built with a real `driveID` instead of nil.
final class DriveResolverTests: XCTestCase {

    private func client(status: Int, body: Data, capture: ((URLRequest) -> Void)? = nil) -> RemoteClient {
        RemoteClient { urlRequest in
            capture?(urlRequest)
            return (body, HTTPURLResponse(url: urlRequest.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private let serverURL = URL(string: "https://ocis.test")!

    func testResolvesThePersonalDriveIDFromMeDrives() async throws {
        var seen: URLRequest?
        let body = Data("""
        { "value": [
          { "id": "shares$id", "name": "Shares", "driveType": "virtual" },
          { "id": "personal$id", "name": "Admin", "driveType": "personal" }
        ] }
        """.utf8)
        let resolver = DriveResolver(serverURL: serverURL, client: client(status: 200, body: body, capture: { seen = $0 }))

        let driveID = try await resolver.resolvePersonalDriveID(authorization: "Bearer t")

        XCTAssertEqual(seen?.url?.absoluteString, "https://ocis.test/graph/v1.0/me/drives")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertEqual(driveID, "personal$id")
    }

    func testThrowsWhenNoPersonalDrivePresent() async {
        let body = Data("""
        { "value": [ { "id": "shares$id", "name": "Shares", "driveType": "virtual" } ] }
        """.utf8)
        let resolver = DriveResolver(serverURL: serverURL, client: client(status: 200, body: body))

        do {
            _ = try await resolver.resolvePersonalDriveID(authorization: "Bearer t")
            XCTFail("expected a no-personal-drive error")
        } catch let error as DriveResolutionError {
            XCTAssertEqual(error, .noPersonalDrive)
        } catch {
            XCTFail("expected DriveResolutionError, got \(error)")
        }
    }
}

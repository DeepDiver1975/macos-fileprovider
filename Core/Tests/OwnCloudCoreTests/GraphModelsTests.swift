import XCTest
@testable import OwnCloudCore

/// Task 2.3: oCIS Graph API JSON deserialization — the `me/drives` listing.
///
/// Graph's only role is space discovery: it names the spaces and, per space,
/// reports the `root.webDavUrl` that all file and folder I/O then runs over. The
/// `driveItem` children/delta fixtures that used to live here went with the Graph
/// file-operation layer (Task 4.5) — those endpoints 404 on oCIS 8.2.0, and items
/// now arrive as WebDAV multi-status (see `WebDAVMultiStatusParserTests`).
///
/// Fixtures mirror the body oCIS returns for `GET /graph/v1.0/me/drives`.
final class GraphModelsTests: XCTestCase {

    private let decoder = GraphJSONDecoder()

    // MARK: - Drives

    func testDecodesDriveList() throws {
        let json = """
        {
          "value": [
            {
              "id": "1284d238-aa92-42ce-bdc4-0b0000009157$4c510ada",
              "name": "Admin",
              "driveType": "personal",
              "driveAlias": "personal/admin",
              "quota": { "total": 10737418240, "used": 2048, "remaining": 10737416192, "state": "normal" },
              "root": {
                "id": "1284d238-aa92-42ce-bdc4-0b0000009157$4c510ada",
                "webDavUrl": "https://ocis.test/dav/spaces/1284d238-aa92-42ce-bdc4-0b0000009157$4c510ada"
              }
            },
            {
              "id": "a0ca6a90-a365-4782-871e-d44447bbc668$another",
              "name": "Shares",
              "driveType": "virtual",
              "quota": { "total": 0, "used": 0, "remaining": 0 },
              "root": { "id": "a0ca6a90-a365-4782-871e-d44447bbc668$another", "webDavUrl": "https://ocis.test/dav/spaces/shares" }
            }
          ]
        }
        """
        let drives = try decoder.decodeDriveList(Data(json.utf8))

        XCTAssertEqual(drives.count, 2)
        XCTAssertEqual(drives[0].id, "1284d238-aa92-42ce-bdc4-0b0000009157$4c510ada")
        XCTAssertEqual(drives[0].name, "Admin")
        XCTAssertEqual(drives[0].driveType, "personal")
        XCTAssertEqual(drives[0].quota?.total, 10737418240)
        XCTAssertEqual(drives[0].quota?.used, 2048)
        XCTAssertEqual(drives[0].quota?.remaining, 10737416192)
        XCTAssertEqual(drives[0].root?.webDavUrl, "https://ocis.test/dav/spaces/1284d238-aa92-42ce-bdc4-0b0000009157$4c510ada")
        XCTAssertEqual(drives[1].driveType, "virtual")
    }

    func testPersonalDriveSelectsThePersonalTypeFromAList() throws {
        // Drive-id resolution: the domain maps to the user's personal drive.
        let drives = [
            GraphDrive(id: "shares-id", name: "Shares", driveType: "virtual", driveAlias: nil, quota: nil, root: nil),
            GraphDrive(id: "personal-id", name: "Admin", driveType: "personal", driveAlias: nil, quota: nil, root: nil),
        ]
        XCTAssertEqual(GraphDrive.personalDrive(in: drives)?.id, "personal-id")
    }

    func testPersonalDriveIsNilWhenNoPersonalDrivePresent() throws {
        let drives = [
            GraphDrive(id: "shares-id", name: "Shares", driveType: "virtual", driveAlias: nil, quota: nil, root: nil),
        ]
        XCTAssertNil(GraphDrive.personalDrive(in: drives))
    }
}

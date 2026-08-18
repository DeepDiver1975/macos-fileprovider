import XCTest
@testable import OwnCloudCore

/// Task 7.2: the space catalog. The settings window's Spaces tab is a checklist
/// of the oCIS drives the token can see; Classic has a single implicit "All
/// files" space. `Space`/`SpaceCatalog` are the display-facing value types mapped
/// from the Graph drive list.
final class SpaceCatalogTests: XCTestCase {

    // A me/drives response covering the three drive types the UI must render, one
    // with quota so the catalog surfaces it.
    private let driveListJSON = """
    {
      "value": [
        {
          "id": "personal-id",
          "name": "Admin",
          "driveType": "personal",
          "quota": { "total": 10737418240, "used": 2147483648, "remaining": 8589934592, "state": "normal" }
        },
        {
          "id": "project-id",
          "name": "Project Falcon",
          "driveType": "project"
        },
        {
          "id": "shares-id",
          "name": "Shares",
          "driveType": "virtual"
        }
      ]
    }
    """

    func testCatalogFromDriveListMapsEverySpace() throws {
        let drives = try GraphJSONDecoder().decodeDriveList(Data(driveListJSON.utf8))
        let catalog = SpaceCatalog(drives: drives)

        XCTAssertEqual(catalog.spaces.count, 3)
        let personal = catalog.spaces.first { $0.driveID == "personal-id" }
        XCTAssertEqual(personal?.name, "Admin")
        XCTAssertEqual(personal?.driveType, "personal")
        XCTAssertEqual(personal?.quotaTotal, 10737418240)
        XCTAssertEqual(personal?.quotaUsed, 2147483648)

        let project = catalog.spaces.first { $0.driveID == "project-id" }
        XCTAssertEqual(project?.name, "Project Falcon")
        XCTAssertEqual(project?.driveType, "project")
        // A drive with no quota block has nil quota fields, not zero.
        XCTAssertNil(project?.quotaTotal)
    }

    func testClassicCatalogIsTheSingleFilesRoot() {
        // Classic has no spaces API; its catalog is one non-editable "All files"
        // space with a nil drive id (Classic domains are path-addressed).
        let catalog = SpaceCatalog.classic
        XCTAssertEqual(catalog.spaces.count, 1)
        XCTAssertNil(catalog.spaces[0].driveID)
        XCTAssertEqual(catalog.spaces[0].name, "All files")
    }

    func testSpaceSyncRootUsesTheDriveID() {
        // A selected space becomes a SyncRoot whose driveID is the space's — the
        // bridge from the catalog to the domain lifecycle (Task 7.4/7.5).
        let account = AccountDescriptor(
            backend: .ocis, serverURL: URL(string: "https://ocis.test")!, username: "einstein")
        let space = Space(driveID: "personal-id", name: "Admin", driveType: "personal",
                          quotaTotal: nil, quotaUsed: nil)
        XCTAssertEqual(space.syncRoot(for: account)?.driveID, "personal-id")
    }
}

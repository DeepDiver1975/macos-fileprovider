import XCTest
@testable import OwnCloudCore

/// Task 2.3: oCIS Graph API JSON deserialization — drives, item (children)
/// lists, and delta responses carrying a sync token.
///
/// oCIS implements the Microsoft Graph `driveItem` shape. Fixtures below mirror
/// the bodies oCIS returns for:
///   - GET /graph/v1.0/me/drives
///   - GET /graph/v1.0/drives/{id}/root/children
///   - GET /graph/v1.0/drives/{id}/root/delta
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

    // MARK: - Children list

    func testDecodesChildrenList() throws {
        let json = """
        {
          "value": [
            {
              "id": "1284d238$4c510ada!folderid",
              "name": "Documents",
              "size": 4096,
              "eTag": "\\"d1a2b3c4\\"",
              "lastModifiedDateTime": "2026-08-12T08:30:15Z",
              "folder": { "childCount": 3 },
              "parentReference": { "driveId": "1284d238$4c510ada", "id": "1284d238$4c510ada!root" }
            },
            {
              "id": "1284d238$4c510ada!fileid",
              "name": "notes.txt",
              "size": 1024,
              "eTag": "\\"a1b2c3d4\\"",
              "lastModifiedDateTime": "2026-08-13T09:00:00Z",
              "file": { "mimeType": "text/plain" },
              "parentReference": { "driveId": "1284d238$4c510ada", "id": "1284d238$4c510ada!root" }
            }
          ]
        }
        """
        let list = try decoder.decodeItemCollection(Data(json.utf8))

        XCTAssertEqual(list.items.count, 2)
        XCTAssertNil(list.deltaToken)

        let folder = list.items[0]
        XCTAssertEqual(folder.name, "Documents")
        XCTAssertTrue(folder.isFolder)
        XCTAssertEqual(folder.size, 4096)
        XCTAssertEqual(folder.eTag, "\"d1a2b3c4\"")
        XCTAssertNil(folder.mimeType)
        XCTAssertEqual(folder.parentDriveID, "1284d238$4c510ada")
        XCTAssertFalse(folder.isDeleted)

        let file = list.items[1]
        XCTAssertFalse(file.isFolder)
        XCTAssertEqual(file.size, 1024)
        XCTAssertEqual(file.mimeType, "text/plain")
    }

    func testDecodesLastModifiedDateTime() throws {
        let json = """
        { "value": [ { "id": "x", "name": "n", "lastModifiedDateTime": "2026-08-12T08:30:15Z", "file": {} } ] }
        """
        let list = try decoder.decodeItemCollection(Data(json.utf8))

        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 12
        c.hour = 8; c.minute = 30; c.second = 15
        c.timeZone = TimeZone(identifier: "GMT")
        let expected = Calendar(identifier: .gregorian).date(from: c)
        XCTAssertEqual(list.items[0].lastModified, expected)
    }

    // MARK: - Delta with sync token

    func testDecodesDeltaTokenFromDeltaLink() throws {
        let json = """
        {
          "value": [ { "id": "a", "name": "kept.txt", "file": {} } ],
          "@odata.deltaLink": "https://ocis.test/graph/v1.0/drives/1284d238/root/delta?$token=abc123token"
        }
        """
        let list = try decoder.decodeItemCollection(Data(json.utf8))
        XCTAssertEqual(list.deltaToken, "abc123token")
        XCTAssertNil(list.nextToken)
    }

    func testDecodesNextTokenFromNextLink() throws {
        let json = """
        {
          "value": [ { "id": "a", "name": "page1.txt", "file": {} } ],
          "@odata.nextLink": "https://ocis.test/graph/v1.0/drives/1284d238/root/delta?$token=page2token"
        }
        """
        let list = try decoder.decodeItemCollection(Data(json.utf8))
        XCTAssertEqual(list.nextToken, "page2token")
        XCTAssertNil(list.deltaToken)
    }

    func testDecodesDeletedItemInDelta() throws {
        // In a delta response a removed item carries a `deleted` facet.
        let json = """
        {
          "value": [
            { "id": "gone", "name": "removed.txt", "deleted": { "state": "deleted" } }
          ]
        }
        """
        let list = try decoder.decodeItemCollection(Data(json.utf8))
        XCTAssertTrue(list.items[0].isDeleted)
    }

    func testThrowsOnMalformedJSON() {
        let garbage = Data("{ not json ".utf8)
        XCTAssertThrowsError(try decoder.decodeItemCollection(garbage))
    }
}

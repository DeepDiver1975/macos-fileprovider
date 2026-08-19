import XCTest
@testable import OwnCloudCore

/// Task 2.1: parsing ownCloud Classic WebDAV `PROPFIND` multi-status XML
/// (`207 Multi-Status`, SabreDAV flavour) into native domain models.
///
/// The fixture mirrors what `owncloud/server:11.0.0` returns for a `PROPFIND`
/// with `Depth: 1` on a collection: the collection itself first, then its
/// children. It exercises the `DAV:`, `http://owncloud.org/ns` (`oc:`) and
/// SabreDAV namespaces, collection vs. file `resourcetype`, and the ownCloud
/// extension properties (`oc:id`, `oc:permissions`, `oc:size`, `oc:favorite`).
final class WebDAVMultiStatusParserTests: XCTestCase {

    /// A representative Depth:1 PROPFIND multistatus body: one collection root
    /// followed by a file child and a subfolder child.
    private let multiStatusXML = """
    <?xml version="1.0"?>
    <d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns">
      <d:response>
        <d:href>/remote.php/dav/files/admin/</d:href>
        <d:propstat>
          <d:prop>
            <oc:id>00000015ocobzus5kn6s</oc:id>
            <oc:fileid>15</oc:fileid>
            <d:getlastmodified>Mon, 11 Aug 2026 10:00:00 GMT</d:getlastmodified>
            <d:resourcetype>
              <d:collection/>
            </d:resourcetype>
            <oc:size>4096</oc:size>
            <oc:permissions>RDNVCK</oc:permissions>
            <d:getetag>"5f3a1b2c3d4e5"</d:getetag>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/remote.php/dav/files/admin/report.pdf</d:href>
        <d:propstat>
          <d:prop>
            <oc:id>00000016ocobzus5kn6s</oc:id>
            <d:getlastmodified>Tue, 12 Aug 2026 08:30:15 GMT</d:getlastmodified>
            <d:getcontentlength>2048</d:getcontentlength>
            <d:getcontenttype>application/pdf</d:getcontenttype>
            <d:getetag>"abc123def456"</d:getetag>
            <d:resourcetype/>
            <oc:permissions>RDNVW</oc:permissions>
            <oc:favorite>1</oc:favorite>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/remote.php/dav/files/admin/Photos/</d:href>
        <d:propstat>
          <d:prop>
            <oc:id>00000017ocobzus5kn6s</oc:id>
            <d:getlastmodified>Wed, 13 Aug 2026 12:00:00 GMT</d:getlastmodified>
            <d:resourcetype>
              <d:collection/>
            </d:resourcetype>
            <oc:size>8192</oc:size>
            <oc:permissions>RDNVCK</oc:permissions>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    func testParsesAllResponsesIntoItems() throws {
        let items = try WebDAVMultiStatusParser().parse(Data(multiStatusXML.utf8))
        XCTAssertEqual(items.count, 3)
    }

    func testParsesCollectionRoot() throws {
        let items = try WebDAVMultiStatusParser().parse(Data(multiStatusXML.utf8))
        let root = items[0]

        XCTAssertEqual(root.href, "/remote.php/dav/files/admin/")
        XCTAssertTrue(root.isDirectory)
        XCTAssertEqual(root.fileID, "00000015ocobzus5kn6s")
        XCTAssertEqual(root.etag, "\"5f3a1b2c3d4e5\"")
        XCTAssertEqual(root.permissions, "RDNVCK")
        XCTAssertEqual(root.ocSize, 4096)
        XCTAssertNil(root.contentLength)     // collections have no getcontentlength
        XCTAssertNil(root.contentType)
        XCTAssertFalse(root.isFavorite)
    }

    func testParsesFileChildWithContentMetadata() throws {
        let items = try WebDAVMultiStatusParser().parse(Data(multiStatusXML.utf8))
        let file = items[1]

        XCTAssertEqual(file.href, "/remote.php/dav/files/admin/report.pdf")
        XCTAssertFalse(file.isDirectory)
        XCTAssertEqual(file.fileID, "00000016ocobzus5kn6s")
        XCTAssertEqual(file.contentLength, 2048)
        XCTAssertEqual(file.contentType, "application/pdf")
        XCTAssertEqual(file.etag, "\"abc123def456\"")
        XCTAssertEqual(file.permissions, "RDNVW")
        XCTAssertTrue(file.isFavorite)
    }

    func testParsesLastModifiedAsDate() throws {
        let items = try WebDAVMultiStatusParser().parse(Data(multiStatusXML.utf8))

        // Tue, 12 Aug 2026 08:30:15 GMT
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 12
        components.hour = 8
        components.minute = 30
        components.second = 15
        components.timeZone = TimeZone(identifier: "GMT")
        let expected = Calendar(identifier: .gregorian).date(from: components)

        XCTAssertEqual(items[1].lastModified, expected)
    }

    func testSubfolderChildIsDirectory() throws {
        let items = try WebDAVMultiStatusParser().parse(Data(multiStatusXML.utf8))
        let folder = items[2]

        XCTAssertEqual(folder.href, "/remote.php/dav/files/admin/Photos/")
        XCTAssertTrue(folder.isDirectory)
        XCTAssertEqual(folder.ocSize, 8192)
    }

    func testDecodedNameStripsTrailingSlashAndPercentDecodes() throws {
        // href components arrive percent-encoded; the decoded last path segment
        // is the user-visible name, with any trailing slash (collections) gone.
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:response>
            <d:href>/remote.php/dav/files/admin/My%20Report%20%232.txt</d:href>
            <d:propstat>
              <d:prop><d:resourcetype/></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """
        let items = try WebDAVMultiStatusParser().parse(Data(xml.utf8))
        XCTAssertEqual(items[0].name, "My Report #2.txt")
    }

    func testThrowsOnMalformedXML() {
        let garbage = Data("<d:multistatus><unterminated".utf8)
        XCTAssertThrowsError(try WebDAVMultiStatusParser().parse(garbage))
    }

    // MARK: - oCIS space WebDAV (Task 4.5)

    /// Verbatim `Depth: 1` response from oCIS 8.2.0 on
    /// `/dav/spaces/{driveID}/mapper-probe`, for the production prop set plus
    /// `oc:file-parent` and `oc:name`. Captured live rather than hand-written, so
    /// the shape below (including the split propstats) is what the server sends.
    ///
    /// Two things differ from Classic and both matter:
    /// - `oc:file-parent` gives the parent's `oc:id` directly, so an id-addressed
    ///   PROPFIND needs no href parsing to find its parent;
    /// - the folder's absent `d:getcontentlength`/`d:getcontenttype` come back in a
    ///   **second propstat with status 404**, not omitted entirely.
    private let ocisMultiStatusXML = """
    <?xml version="1.0" ?>
    <d:multistatus xmlns:s="http://sabredav.org/ns" xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response>
        <d:href>/dav/spaces/e876c6de-dc43-4a0f-a58e-b77a1e8db031$9c566819-f305-49d1-8015-e1c8d9ad3624/mapper-probe/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype>
              <d:collection/>
            </d:resourcetype>
            <d:getetag>"702e134c342841683014bc68331f2ef6"</d:getetag>
            <d:getlastmodified>Wed, 19 Aug 2026 07:48:51 GMT</d:getlastmodified>
            <oc:id>e876c6de-dc43-4a0f-a58e-b77a1e8db031$9c566819-f305-49d1-8015-e1c8d9ad3624!691a271d-006e-4066-a9cd-abeb79bc521e</oc:id>
            <oc:size>12</oc:size>
            <oc:permissions>RDNVCKZP</oc:permissions>
            <oc:favorite>0</oc:favorite>
            <oc:file-parent>e876c6de-dc43-4a0f-a58e-b77a1e8db031$9c566819-f305-49d1-8015-e1c8d9ad3624!9c566819-f305-49d1-8015-e1c8d9ad3624</oc:file-parent>
            <oc:name>mapper-probe</oc:name>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
        <d:propstat>
          <d:prop>
            <d:getcontentlength/>
            <d:getcontenttype/>
          </d:prop>
          <d:status>HTTP/1.1 404 Not Found</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/spaces/e876c6de-dc43-4a0f-a58e-b77a1e8db031$9c566819-f305-49d1-8015-e1c8d9ad3624/mapper-probe/note.txt</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype/>
            <d:getetag>"1553aa55df9a8c37b8a844f0a9cbb6a3"</d:getetag>
            <d:getcontentlength>12</d:getcontentlength>
            <d:getcontenttype>text/plain</d:getcontenttype>
            <d:getlastmodified>Wed, 19 Aug 2026 07:48:51 GMT</d:getlastmodified>
            <oc:id>e876c6de-dc43-4a0f-a58e-b77a1e8db031$9c566819-f305-49d1-8015-e1c8d9ad3624!76445d14-462e-4a62-bf8b-d69c15146396</oc:id>
            <oc:size>12</oc:size>
            <oc:permissions>RDNVWZP</oc:permissions>
            <oc:favorite>0</oc:favorite>
            <oc:file-parent>e876c6de-dc43-4a0f-a58e-b77a1e8db031$9c566819-f305-49d1-8015-e1c8d9ad3624!691a271d-006e-4066-a9cd-abeb79bc521e</oc:file-parent>
            <oc:name>note.txt</oc:name>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    func testParsesOCISParentFileIDAndServerName() throws {
        let items = try WebDAVMultiStatusParser().parse(Data(ocisMultiStatusXML.utf8))
        XCTAssertEqual(items.count, 2)

        let folder = items[0]
        XCTAssertEqual(
            folder.parentFileID,
            "e876c6de-dc43-4a0f-a58e-b77a1e8db031$9c566819-f305-49d1-8015-e1c8d9ad3624!9c566819-f305-49d1-8015-e1c8d9ad3624")
        XCTAssertEqual(folder.serverName, "mapper-probe")

        let file = items[1]
        // The child's parent is the folder's own oc:id — the link an id-addressed
        // enumeration relies on.
        XCTAssertEqual(file.parentFileID, folder.fileID)
        XCTAssertEqual(file.serverName, "note.txt")
    }

    func testAFolderWith404PropstatHasNoContentMetadata() throws {
        // oCIS reports a collection's absent getcontentlength/getcontenttype in a
        // 404 propstat rather than omitting them; they must not become values.
        let folder = try WebDAVMultiStatusParser().parse(Data(ocisMultiStatusXML.utf8))[0]

        XCTAssertTrue(folder.isDirectory)
        XCTAssertNil(folder.contentLength)
        XCTAssertNil(folder.contentType)
        XCTAssertEqual(folder.ocSize, 12)
        XCTAssertEqual(folder.permissions, "RDNVCKZP")
        XCTAssertFalse(folder.isFavorite)
    }

    func testClassicResponsesLeaveTheOCISPropertiesNil() throws {
        // Classic does not send oc:file-parent/oc:name, so both stay nil and the
        // Classic mapping is unaffected.
        let items = try WebDAVMultiStatusParser().parse(Data(multiStatusXML.utf8))
        XCTAssertNil(items[0].parentFileID)
        XCTAssertNil(items[0].serverName)
    }

    func testOCISPropertiesResetBetweenResponses() throws {
        // A response that omits the props must not inherit the previous one's.
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:response>
            <d:href>/dav/spaces/d1/a.txt</d:href>
            <d:propstat>
              <d:prop><d:resourcetype/><oc:file-parent>d1!p</oc:file-parent><oc:name>a.txt</oc:name></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/dav/spaces/d1/b.txt</d:href>
            <d:propstat>
              <d:prop><d:resourcetype/></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """
        let items = try WebDAVMultiStatusParser().parse(Data(xml.utf8))
        XCTAssertEqual(items[0].parentFileID, "d1!p")
        XCTAssertNil(items[1].parentFileID)
        XCTAssertNil(items[1].serverName)
    }
}

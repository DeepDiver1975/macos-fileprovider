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
}

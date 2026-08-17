import XCTest
@testable import OwnCloudCore

/// Task 3.1: mapping remote container roots and their children into the fields
/// an `NSFileProviderItem` exposes.
///
/// `NSFileProviderItem` is a FileProvider-framework protocol that cannot be
/// built in the Linux core, so the core owns a backend-agnostic value type,
/// `FileProviderItemDescription`, carrying exactly the fields the extension's
/// thin `NSFileProviderItem` adapter reads: identifier, parent identifier,
/// filename, directory flag, size, dates, version (etag), content type and
/// capabilities. This test drives the WebDAV and Graph mappers into it.
final class FileProviderItemDescriptionTests: XCTestCase {

    // MARK: - Root container

    func testRootContainerMapsToRootContainerIdentifier() {
        let root = FileProviderItemDescription.rootContainer(filename: "Admin")
        XCTAssertEqual(root.identifier, .rootContainer)
        XCTAssertEqual(root.parentIdentifier, .rootContainer)
        XCTAssertEqual(root.filename, "Admin")
        XCTAssertTrue(root.isDirectory)
    }

    // MARK: - WebDAV → description

    func testWebDAVFileMapsToDescription() throws {
        let item = WebDAVItem(
            href: "/remote.php/dav/files/admin/report.pdf",
            isDirectory: false,
            fileID: "00000016ocobzus5kn6s",
            etag: "\"abc123\"",
            contentLength: 2048,
            contentType: "application/pdf",
            lastModified: Date(timeIntervalSince1970: 1_000_000),
            permissions: "RDNVW"
        )
        let parent = ItemIdentifier(rawValue: "00000015ocobzus5kn6s")
        let desc = FileProviderItemDescription(webDAVItem: item, parentIdentifier: parent)

        XCTAssertEqual(desc.identifier, ItemIdentifier(rawValue: "00000016ocobzus5kn6s"))
        XCTAssertEqual(desc.parentIdentifier, parent)
        XCTAssertEqual(desc.filename, "report.pdf")
        XCTAssertFalse(desc.isDirectory)
        XCTAssertEqual(desc.size, 2048)
        XCTAssertEqual(desc.contentType, "application/pdf")
        XCTAssertEqual(desc.versionIdentifier, "\"abc123\"")
        XCTAssertEqual(desc.contentModificationDate, Date(timeIntervalSince1970: 1_000_000))
    }

    func testWebDAVFolderIsDirectoryAndHasNoContentType() {
        let item = WebDAVItem(href: "/remote.php/dav/files/admin/Photos/", isDirectory: true, fileID: "17", ocSize: 8192)
        let desc = FileProviderItemDescription(webDAVItem: item, parentIdentifier: .rootContainer)

        XCTAssertTrue(desc.isDirectory)
        XCTAssertEqual(desc.filename, "Photos")
        XCTAssertNil(desc.contentType)
        XCTAssertEqual(desc.size, 8192)  // falls back to oc:size for collections
    }

    func testWebDAVWritePermissionMapsToWritableCapabilities() {
        let writable = WebDAVItem(href: "/x/a.txt", isDirectory: false, permissions: "RDNVW")
        XCTAssertTrue(FileProviderItemDescription(webDAVItem: writable, parentIdentifier: .rootContainer)
            .capabilities.contains(.allowsWriting))

        let readOnly = WebDAVItem(href: "/x/b.txt", isDirectory: false, permissions: "R")
        XCTAssertFalse(FileProviderItemDescription(webDAVItem: readOnly, parentIdentifier: .rootContainer)
            .capabilities.contains(.allowsWriting))
    }

    // MARK: - Graph → description

    func testGraphFolderMapsToDescription() {
        let item = GraphItem(
            id: "drive$space!folder",
            name: "Documents",
            size: 4096,
            eTag: "\"d1a2\"",
            lastModified: Date(timeIntervalSince1970: 2_000_000),
            isFolder: true,
            childCount: 3,
            mimeType: nil,
            parentDriveID: "drive$space",
            parentID: "drive$space!root",
            isDeleted: false
        )
        let desc = FileProviderItemDescription(graphItem: item)

        XCTAssertEqual(desc.identifier, ItemIdentifier(rawValue: "drive$space!folder"))
        XCTAssertEqual(desc.parentIdentifier, ItemIdentifier(rawValue: "drive$space!root"))
        XCTAssertEqual(desc.filename, "Documents")
        XCTAssertTrue(desc.isDirectory)
        XCTAssertEqual(desc.size, 4096)
        XCTAssertEqual(desc.versionIdentifier, "\"d1a2\"")
        XCTAssertEqual(desc.contentModificationDate, Date(timeIntervalSince1970: 2_000_000))
    }

    func testGraphFileMapsMimeType() {
        let item = GraphItem(
            id: "drive$space!file", name: "notes.txt", size: 1024, eTag: "\"a1\"",
            lastModified: nil, isFolder: false, childCount: nil, mimeType: "text/plain",
            parentDriveID: "drive$space", parentID: "drive$space!root", isDeleted: false
        )
        let desc = FileProviderItemDescription(graphItem: item)
        XCTAssertFalse(desc.isDirectory)
        XCTAssertEqual(desc.contentType, "text/plain")
    }

    func testGraphItemWithoutParentUsesRootContainer() {
        let item = GraphItem(
            id: "drive$space!root", name: "Admin", size: 0, eTag: nil, lastModified: nil,
            isFolder: true, childCount: 0, mimeType: nil,
            parentDriveID: nil, parentID: nil, isDeleted: false
        )
        let desc = FileProviderItemDescription(graphItem: item)
        XCTAssertEqual(desc.parentIdentifier, .rootContainer)
    }
}

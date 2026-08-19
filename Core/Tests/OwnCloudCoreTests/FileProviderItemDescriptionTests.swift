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
/// capabilities. This test drives the two WebDAV mappers into it — Classic's
/// path-addressed one and oCIS's id-addressed one.
final class FileProviderItemDescriptionTests: XCTestCase {

    // MARK: - Root container

    func testRootContainerMapsToRootContainerIdentifier() {
        let root = FileProviderItemDescription.rootContainer(filename: "Admin")
        XCTAssertEqual(root.identifier, .rootContainer)
        XCTAssertEqual(root.parentIdentifier, .rootContainer)
        XCTAssertEqual(root.filename, "Admin")
        XCTAssertTrue(root.isDirectory)
    }

    // MARK: - Reserved identifiers (Task 4.5)

    func testWorkingSetResolvesToTheRootContainer() {
        // The framework asks for an enumerator for the working set (its "recents and
        // favourites" feed) using a reserved identifier, not a server id. Passed
        // through it addresses `/dav/spaces/NSFileProviderWorkingSetContainerItemIdentifier`
        // — a 404 (the Graph form of this URL was observed 404ing live). The working
        // set is a view over the whole tree, so it resolves onto the space root.
        XCTAssertEqual(ItemIdentifier.workingSet.resolvedContainer, ItemIdentifier.rootContainer)
    }

    func testRootContainerResolvesToItself() {
        XCTAssertEqual(ItemIdentifier.rootContainer.resolvedContainer, ItemIdentifier.rootContainer)
    }

    func testAnOrdinaryContainerResolvesToItself() {
        // Only the reserved identifiers are remapped; a real container keeps its own
        // id so descending into folders — and fetching its metadata — still works.
        let folder = ItemIdentifier(rawValue: "drive-1$space-1!folder")
        XCTAssertEqual(folder.resolvedContainer, folder)
    }

    func testTrashCannotBeServed() {
        // Trash is the third reserved identifier, and the only one that must NOT be
        // remapped: neither backend exposes a trash collection here, and pointing it
        // at the root would present every file as trashed (and "restore"/"empty"
        // would act on live files). Both `enumerator(for:)` and `item(for:)` refuse
        // it instead — observed live as `PROPFIND /dav/spaces/NSFileProviderTrash… →
        // 404`, from *both* call sites.
        XCTAssertNil(ItemIdentifier.trashContainer.resolvedContainer)
    }

    func testEveryReservedIdentifierIsResolvedRatherThanAddressed() {
        // The guarantee both call sites depend on: no reserved raw value is ever
        // handed to a request builder. Whatever `resolvedContainer` returns is either
        // nil, or an identifier that is no longer reserved.
        for reserved in [ItemIdentifier.rootContainer, .workingSet, .trashContainer] {
            guard let resolved = reserved.resolvedContainer else { continue }
            XCTAssertFalse(
                resolved.isReserved && resolved != .rootContainer,
                "\(reserved.rawValue) resolved to another reserved identifier")
        }
        XCTAssertTrue(ItemIdentifier.workingSet.isReserved)
        XCTAssertFalse(ItemIdentifier(rawValue: "drive-1$space-1!item").isReserved)
    }

    func testTheReservedIdentifiersMatchTheFrameworkConstants() {
        // Documented raw values of the `NSFileProviderItemIdentifier` constants. The
        // core cannot import FileProvider, so the strings are duplicated here; if
        // Apple ever changed one, this assertion is the reminder of where to look.
        XCTAssertEqual(ItemIdentifier.workingSet.rawValue, "NSFileProviderWorkingSetContainerItemIdentifier")
        XCTAssertEqual(ItemIdentifier.trashContainer.rawValue, "NSFileProviderTrashContainerItemIdentifier")
        XCTAssertEqual(ItemIdentifier.rootContainer.rawValue, "NSFileProviderRootContainerItemIdentifier")
    }

    // MARK: - WebDAV → description

    func testWebDAVFileMapsToDescription() throws {
        let item = WebDAVItem(
            href: "/remote.php/dav/files/admin/folder/report.pdf",
            isDirectory: false,
            fileID: "00000016ocobzus5kn6s",
            etag: "\"abc123\"",
            contentLength: 2048,
            contentType: "application/pdf",
            lastModified: Date(timeIntervalSince1970: 1_000_000),
            permissions: "RDNVW"
        )
        // Classic is path-addressed: the parent identifier is the parent's
        // server-relative path, and the item's identifier is that path joined with
        // its name — not its oc:id (see FileProviderItemDescription for why).
        let parent = ItemIdentifier(rawValue: "/folder")
        let desc = FileProviderItemDescription(webDAVItem: item, parentIdentifier: parent)

        XCTAssertEqual(desc.identifier, ItemIdentifier(rawValue: "/folder/report.pdf"))
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

    // MARK: - oCIS space WebDAV → description (Task 4.5)

    /// The personal space of the live fixture; ids below are verbatim server values.
    private static let ocisDrive = "e876c6de-dc43-4a0f-a58e-b77a1e8db031$9c566819-f305-49d1-8015-e1c8d9ad3624"
    private static let ocisRootFileID = "\(ocisDrive)!9c566819-f305-49d1-8015-e1c8d9ad3624"

    func testOCISFileIsIdentifiedByItsFileIDNotItsPath() {
        // Unlike Classic, oCIS addresses items by oc:id — /dav/spaces/{oc:id} is a
        // valid target for every verb, and the id survives rename and reparent, so
        // the identifier never goes stale.
        let item = WebDAVItem(
            href: "/dav/spaces/\(Self.ocisDrive)/mapper-probe/note.txt",
            isDirectory: false,
            fileID: "\(Self.ocisDrive)!76445d14-462e-4a62-bf8b-d69c15146396",
            etag: "\"1553aa55df9a8c37b8a844f0a9cbb6a3\"",
            contentLength: 12,
            contentType: "text/plain",
            lastModified: Date(timeIntervalSince1970: 1_000_000),
            permissions: "RDNVWZP",
            parentFileID: "\(Self.ocisDrive)!691a271d-006e-4066-a9cd-abeb79bc521e",
            serverName: "note.txt"
        )
        let parent = ItemIdentifier(rawValue: "\(Self.ocisDrive)!691a271d-006e-4066-a9cd-abeb79bc521e")
        let desc = FileProviderItemDescription(ocisWebDAVItem: item, driveID: Self.ocisDrive)

        XCTAssertEqual(desc.identifier, ItemIdentifier(rawValue: item.fileID!))
        XCTAssertEqual(desc.parentIdentifier, parent)
        XCTAssertEqual(desc.filename, "note.txt")
        XCTAssertFalse(desc.isDirectory)
        XCTAssertEqual(desc.size, 12)
        XCTAssertEqual(desc.contentType, "text/plain")
        XCTAssertEqual(desc.versionIdentifier, "\"1553aa55df9a8c37b8a844f0a9cbb6a3\"")
        XCTAssertEqual(desc.contentModificationDate, Date(timeIntervalSince1970: 1_000_000))
    }

    func testOCISTopLevelItemIsParentedToTheRootContainer() {
        // A top-level child's oc:file-parent is the space root's oc:id. Reported
        // verbatim it would name a container the system does not know, so it must
        // normalise to .rootContainer.
        let item = WebDAVItem(
            href: "/dav/spaces/\(Self.ocisDrive)/mapper-probe/",
            isDirectory: true,
            fileID: "\(Self.ocisDrive)!691a271d-006e-4066-a9cd-abeb79bc521e",
            ocSize: 12,
            permissions: "RDNVCKZP",
            parentFileID: Self.ocisRootFileID,
            serverName: "mapper-probe"
        )
        let desc = FileProviderItemDescription(ocisWebDAVItem: item, driveID: Self.ocisDrive)

        XCTAssertEqual(desc.parentIdentifier, .rootContainer)
        XCTAssertTrue(desc.isDirectory)
        XCTAssertEqual(desc.filename, "mapper-probe")
        XCTAssertNil(desc.contentType)
        XCTAssertEqual(desc.size, 12)  // collections fall back to oc:size
    }

    func testOCISNameFallsBackToTheHrefWhenTheServerOmitsIt() {
        // oc:name is preferred because it needs no percent-decoding, but a server
        // that omits it must still yield the right filename.
        let item = WebDAVItem(
            href: "/dav/spaces/\(Self.ocisDrive)/My%20Report%20%232.txt",
            isDirectory: false,
            fileID: "\(Self.ocisDrive)!abc",
            parentFileID: Self.ocisRootFileID
        )
        XCTAssertEqual(
            FileProviderItemDescription(ocisWebDAVItem: item, driveID: Self.ocisDrive).filename,
            "My Report #2.txt")
    }

    func testOCISMissingParentFallsBackToTheRootContainer() {
        // The space root itself reports the bare driveID as its oc:file-parent, and
        // a server omitting the prop must not produce an unrooted item.
        let noParent = WebDAVItem(
            href: "/dav/spaces/\(Self.ocisDrive)/a.txt",
            isDirectory: false,
            fileID: "\(Self.ocisDrive)!abc",
            serverName: "a.txt")
        XCTAssertEqual(
            FileProviderItemDescription(ocisWebDAVItem: noParent, driveID: Self.ocisDrive).parentIdentifier,
            .rootContainer)

        let bareDriveParent = WebDAVItem(
            href: "/dav/spaces/\(Self.ocisDrive)/",
            isDirectory: true,
            fileID: Self.ocisRootFileID,
            parentFileID: Self.ocisDrive,
            serverName: "Admin")
        XCTAssertEqual(
            FileProviderItemDescription(ocisWebDAVItem: bareDriveParent, driveID: Self.ocisDrive).parentIdentifier,
            .rootContainer)
    }

    func testOCISSpaceRootMapsToTheRootContainerIdentifier() {
        // The Depth:1 self entry: its own oc:id is the root's, so it must report
        // .rootContainer rather than a second identifier for the same container.
        let root = WebDAVItem(
            href: "/dav/spaces/\(Self.ocisDrive)/",
            isDirectory: true,
            fileID: Self.ocisRootFileID,
            ocSize: 12,
            permissions: "RDNVCKZP",
            parentFileID: Self.ocisDrive,
            serverName: "Admin")
        let desc = FileProviderItemDescription(ocisWebDAVItem: root, driveID: Self.ocisDrive)

        XCTAssertEqual(desc.identifier, .rootContainer)
        XCTAssertEqual(desc.parentIdentifier, .rootContainer)
    }

    func testOCISPermissionsMapToCapabilitiesLikeClassic() {
        // oCIS returns the same permission letters (RDNVCKZP observed live), so the
        // Classic mapping is reused unchanged.
        let writable = WebDAVItem(
            href: "/dav/spaces/d1/a.txt", isDirectory: false, fileID: "d1!a",
            permissions: "RDNVWZP", parentFileID: "d1!p")
        let caps = FileProviderItemDescription(ocisWebDAVItem: writable, driveID: "d1").capabilities
        XCTAssertTrue(caps.contains(.allowsWriting))
        XCTAssertTrue(caps.contains(.allowsRenaming))
        XCTAssertTrue(caps.contains(.allowsDeleting))

        let readOnly = WebDAVItem(
            href: "/dav/spaces/d1/b.txt", isDirectory: false, fileID: "d1!b",
            permissions: "R", parentFileID: "d1!p")
        XCTAssertFalse(FileProviderItemDescription(ocisWebDAVItem: readOnly, driveID: "d1")
            .capabilities.contains(.allowsWriting))
    }

    func testOCISItemWithoutAFileIDFallsBackToThePathIdentifier() {
        // Defensive: a server that omits oc:id would otherwise yield an empty
        // identifier. Falling back to the path keeps the item addressable.
        let item = WebDAVItem(
            href: "/dav/spaces/\(Self.ocisDrive)/orphan.txt",
            isDirectory: false,
            serverName: "orphan.txt")
        let desc = FileProviderItemDescription(ocisWebDAVItem: item, driveID: Self.ocisDrive)

        XCTAssertEqual(desc.identifier, ItemIdentifier(rawValue: "/orphan.txt"))
        XCTAssertEqual(desc.filename, "orphan.txt")
    }
}

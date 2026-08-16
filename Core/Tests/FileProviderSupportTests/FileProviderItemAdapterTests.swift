#if canImport(FileProvider)
import XCTest
import FileProvider
@testable import FileProviderSupport
import OwnCloudCore

/// The `NSFileProviderItem` adapter (progress.md Task 3.1) wraps a backend-agnostic
/// `FileProviderItemDescription` and exposes exactly the framework properties the
/// system reads. The mapping decisions live in the Linux-buildable core and are
/// tested there; this verifies the thin framework translation.
final class FileProviderItemAdapterTests: XCTestCase {

    private func makeItem(
        id: String = "id-1",
        parent: ItemIdentifier = .rootContainer,
        filename: String = "report.pdf",
        isDirectory: Bool = false,
        size: Int? = 1234,
        version: String? = "etag-abc",
        caps: ItemCapabilities = .readWrite
    ) -> FileProviderItem {
        let description = FileProviderItemDescription(
            identifier: ItemIdentifier(rawValue: id),
            parentIdentifier: parent,
            filename: filename,
            isDirectory: isDirectory,
            size: size,
            versionIdentifier: version,
            contentType: isDirectory ? nil : "application/pdf",
            capabilities: caps
        )
        return FileProviderItem(itemDescription: description)
    }

    func testMapsIdentifierAndParent() {
        let item = makeItem(id: "id-1", parent: ItemIdentifier(rawValue: "parent-9"))
        XCTAssertEqual(item.itemIdentifier, NSFileProviderItemIdentifier("id-1"))
        XCTAssertEqual(item.parentItemIdentifier, NSFileProviderItemIdentifier("parent-9"))
    }

    func testRootParentMapsToRootContainerConstant() {
        let item = makeItem(parent: .rootContainer)
        XCTAssertEqual(item.parentItemIdentifier, .rootContainer)
    }

    func testMapsFilenameAndSize() {
        let item = makeItem(filename: "report.pdf", size: 1234)
        XCTAssertEqual(item.filename, "report.pdf")
        XCTAssertEqual(item.documentSize, 1234)
    }

    func testFileContentType() {
        let item = makeItem(isDirectory: false)
        XCTAssertEqual(item.contentType, .pdf)
    }

    func testDirectoryContentTypeIsFolder() {
        let item = makeItem(filename: "Docs", isDirectory: true, size: nil)
        XCTAssertEqual(item.contentType, .folder)
    }

    func testVersionUsesEtagForContentAndMetadata() {
        let item = makeItem(version: "etag-abc")
        let expected = Data("etag-abc".utf8)
        XCTAssertEqual(item.itemVersion.contentVersion, expected)
        XCTAssertEqual(item.itemVersion.metadataVersion, expected)
    }

    func testReadOnlyCapabilitiesMap() {
        let item = makeItem(caps: .readOnly)
        XCTAssertTrue(item.capabilities.contains(.allowsReading))
        XCTAssertFalse(item.capabilities.contains(.allowsWriting))
        XCTAssertFalse(item.capabilities.contains(.allowsDeleting))
    }

    func testReadWriteCapabilitiesMap() {
        let item = makeItem(caps: .readWrite)
        XCTAssertTrue(item.capabilities.contains(.allowsReading))
        XCTAssertTrue(item.capabilities.contains(.allowsWriting))
        XCTAssertTrue(item.capabilities.contains(.allowsDeleting))
    }
}
#endif

import XCTest
@testable import OwnCloudCore

/// Task 4.5: the per-space WebDAV endpoint oCIS sync runs over.
///
/// oCIS serves file I/O under `/dav/spaces`, not through Graph — the Graph
/// content endpoints this project used to target 404 on oCIS 8.2.0 (see the task
/// notes in progress.md). `me/drives` reports a per-drive `root.webDavUrl` of
/// `{server}/dav/spaces/{driveID}`, so the server's value is preferred and the
/// derivation is the fallback, mirroring `Space::webDavUrl()` in
/// `owncloud/client`.
///
/// The base is the **`/dav/spaces` collection**, not the per-space
/// `/dav/spaces/{driveID}`, because addressing is by id and an id is always the
/// first segment: `PROPFIND /dav/spaces/{fileID}` answers **207** while
/// `PROPFIND /dav/spaces/{driveID}/{fileID}` answers **404** (verified live —
/// a fileid already begins with the drive id, so it is its sibling, not its
/// child).
final class SpaceWebDAVEndpointTests: XCTestCase {

    private let driveID = "e876c6de-dc43-4a0f-a58e-b77a1e8db031$9c566819-f305-49d1-8015-e1c8d9ad3624"

    // MARK: - Base URL

    func testDerivesBaseURLAsTheSpacesCollection() {
        // The drive id is *not* part of the base: it is supplied per request by
        // `path(for:driveID:)`, as one segment like any other id.
        let url = SpaceWebDAVEndpoint.baseURL(
            serverURL: URL(string: "https://localhost:9200")!,
            driveID: driveID)

        XCTAssertEqual(url.absoluteString, "https://localhost:9200/dav/spaces")
    }

    func testDerivedBaseURLDoesNotDoubleTheSlashOnATrailingSlashServerURL() {
        let url = SpaceWebDAVEndpoint.baseURL(
            serverURL: URL(string: "https://localhost:9200/")!,
            driveID: driveID)

        XCTAssertEqual(url.absoluteString, "https://localhost:9200/dav/spaces")
    }

    func testDerivedBaseURLPreservesAServerSubPath() {
        // A server hosted under a sub-path keeps it; the dav route is appended.
        let url = SpaceWebDAVEndpoint.baseURL(
            serverURL: URL(string: "https://example.test/ocis")!,
            driveID: "d1")

        XCTAssertEqual(url.absoluteString, "https://example.test/ocis/dav/spaces")
    }

    // MARK: - Preferring the server-reported endpoint

    func testUsesTheParentCollectionOfTheServerReportedWebDavURL() {
        // `me/drives` reports `{host}/dav/spaces/{driveID}` per drive. Its host and
        // prefix win over the derivation — but the drive-id segment is stripped,
        // since ids are appended per request.
        let url = SpaceWebDAVEndpoint.baseURL(
            serverURL: URL(string: "https://localhost:9200")!,
            driveID: driveID,
            reportedWebDavURL: "https://dav.example.test/dav/spaces/\(driveID)")

        XCTAssertEqual(url.absoluteString, "https://dav.example.test/dav/spaces")
    }

    func testKeepsAReportedURLThatDoesNotEndInTheDriveID() {
        // An unexpected shape is used as-is rather than having a real path
        // component chopped off it.
        let reported = "https://dav.example.test/custom/dav/root"
        let url = SpaceWebDAVEndpoint.baseURL(
            serverURL: URL(string: "https://localhost:9200")!,
            driveID: driveID,
            reportedWebDavURL: reported)

        XCTAssertEqual(url.absoluteString, reported)
    }

    func testFallsBackToTheDerivationWhenTheReportedURLIsAbsentOrUnusable() {
        let server = URL(string: "https://localhost:9200")!
        let expected = "https://localhost:9200/dav/spaces"

        XCTAssertEqual(
            SpaceWebDAVEndpoint.baseURL(serverURL: server, driveID: driveID, reportedWebDavURL: nil)
                .absoluteString,
            expected)
        XCTAssertEqual(
            SpaceWebDAVEndpoint.baseURL(serverURL: server, driveID: driveID, reportedWebDavURL: "")
                .absoluteString,
            expected)
        XCTAssertEqual(
            SpaceWebDAVEndpoint.baseURL(serverURL: server, driveID: driveID, reportedWebDavURL: "not a url")
                .absoluteString,
            expected)
    }

    // MARK: - Root container identity

    func testTheDriveIDItselfIsTheRootContainer() {
        // Graph reports `root.id` as the bare driveID, and live oCIS returns the
        // bare driveID as the *space root's own* `oc:file-parent`, so this form
        // reaches the mapper and must resolve to the root.
        XCTAssertTrue(SpaceWebDAVEndpoint.isRoot(fileID: driveID, driveID: driveID))
    }

    func testTheSuffixedRootFileIDIsTheRootContainer() {
        // A driveID is `{storageID}${spaceID}`, and live oCIS reports the space
        // root's `oc:id` as `{driveID}!{spaceID}` — the `!` suffix repeats the
        // post-`$` segment. Verified on two spaces of different types:
        //   personal  e876…$9c566819-…  ->  e876…$9c566819-…!9c566819-…
        //   virtual   a0ca…$a0ca6a90-…  ->  a0ca…$a0ca6a90-…!a0ca6a90-…
        // A top-level child's `oc:file-parent` is that value, not the bare
        // driveID, so this is the form the mapper actually sees in enumeration.
        let rootFileID = "\(driveID)!9c566819-f305-49d1-8015-e1c8d9ad3624"
        XCTAssertTrue(SpaceWebDAVEndpoint.isRoot(fileID: rootFileID, driveID: driveID))
    }

    func testTheRootRuleHoldsForASpaceWhoseStorageAndSpaceIDsMatch() {
        // The virtual/share-jail space has storageID == spaceID, so its root id
        // repeats one UUID three times. Guards against a rule that only works
        // when the two halves of the driveID differ.
        let virtualDrive = "a0ca6a90-a365-4782-871e-d44447bbc668$a0ca6a90-a365-4782-871e-d44447bbc668"
        XCTAssertTrue(SpaceWebDAVEndpoint.isRoot(
            fileID: "\(virtualDrive)!a0ca6a90-a365-4782-871e-d44447bbc668",
            driveID: virtualDrive))
    }

    func testAnUnrecognisedSuffixIsNotTheRootContainer() {
        // Only the documented-by-observation suffix counts. Accepting any
        // `{driveID}!…` would make every item in the space its own root.
        XCTAssertFalse(SpaceWebDAVEndpoint.isRoot(fileID: "\(driveID)!whatever", driveID: driveID))
    }

    func testAChildItemIDIsNotTheRootContainer() {
        // A real child id shares the drive prefix but has its own item segment; it
        // must not be mistaken for the root, or every item would report itself as a
        // child of the root.
        XCTAssertFalse(SpaceWebDAVEndpoint.isRoot(
            fileID: "\(driveID)!5b509bbe-8409-4f9c-8d4b-82b96028e0ff",
            driveID: driveID))
    }

    func testAFileIDFromAnotherDriveIsNotThisRoot() {
        XCTAssertFalse(SpaceWebDAVEndpoint.isRoot(fileID: "other-drive$x!y", driveID: driveID))
    }

    func testNormalisesTheRootFileIDToTheRootContainerIdentifier() {
        XCTAssertEqual(
            SpaceWebDAVEndpoint.identifier(forFileID: driveID, driveID: driveID),
            .rootContainer)
        XCTAssertEqual(
            SpaceWebDAVEndpoint.identifier(
                forFileID: "\(driveID)!9c566819-f305-49d1-8015-e1c8d9ad3624",
                driveID: driveID),
            .rootContainer)
    }

    func testKeepsANonRootFileIDAsItsOwnIdentifier() {
        let childID = "\(driveID)!5b509bbe-8409-4f9c-8d4b-82b96028e0ff"
        XCTAssertEqual(
            SpaceWebDAVEndpoint.identifier(forFileID: childID, driveID: driveID),
            ItemIdentifier(rawValue: childID))
    }

    // MARK: - Addressing a container for enumeration

    func testTheRootContainerAddressesTheDriveID() {
        // `/dav/spaces/{driveID}` is the space root (verified live: PROPFIND 207).
        XCTAssertEqual(
            SpaceWebDAVEndpoint.path(for: .rootContainer, driveID: driveID),
            "/\(driveID)")
    }

    func testASubfolderAddressesItsOwnFileIDAsASiblingOfTheDriveID() {
        // Not `/{driveID}/{fileID}` — that 404s live. A fileid already contains the
        // drive id, so it is a sibling segment under `/dav/spaces`.
        let childID = "\(driveID)!5b509bbe-8409-4f9c-8d4b-82b96028e0ff"
        XCTAssertEqual(
            SpaceWebDAVEndpoint.path(for: ItemIdentifier(rawValue: childID), driveID: driveID),
            "/\(childID)")
    }

    func testIDsAreLeftVerbatimSoTheBuilderCanEncodeThem() {
        // `$` and `!` are not escaped here: `WebDAVRequestBuilder` percent-encodes
        // each path segment when it appends the address, and oCIS accepts the
        // escaped form (verified live: `%24`/`%21` → 207).
        XCTAssertEqual(SpaceWebDAVEndpoint.path(for: .rootContainer, driveID: "a$b!c"), "/a$b!c")
    }
}

// swift-tools-version:5.9
import PackageDescription

// OwnCloudCore holds all backend-agnostic logic shared by the containing app,
// the File Provider extension and the FileProviderUI extension:
// WebDAV (ownCloud Classic) XML parsing, oCIS Graph API models, and unified
// credential / session management.
//
// Deliberate constraint (see progress.md, AC-2 "Backend contract" tier): this
// package must stay Linux-buildable — Foundation plus FoundationNetworking only,
// no Apple-only API below the File Provider boundary — so its clients can be
// driven against both backends in Docker on ubuntu-latest in CI.
let package = Package(
    name: "OwnCloudCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OwnCloudCore", targets: ["OwnCloudCore"])
    ],
    targets: [
        .target(
            name: "OwnCloudCore"
        ),
        .testTarget(
            name: "OwnCloudCoreTests",
            dependencies: ["OwnCloudCore"]
        )
    ]
)

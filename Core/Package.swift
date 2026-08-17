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
        .library(name: "OwnCloudCore", targets: ["OwnCloudCore"]),
        // The Mac-only FileProvider adapter layer over OwnCloudCore. Its
        // FileProvider-framework code is behind `#if canImport(FileProvider)`,
        // so the package still builds on Linux (the framework simply isn't there
        // and the file compiles to nothing) — AC-2's backend-contract tier.
        .library(name: "FileProviderSupport", targets: ["FileProviderSupport"])
    ],
    targets: [
        .target(
            name: "OwnCloudCore"
        ),
        .target(
            name: "FileProviderSupport",
            dependencies: ["OwnCloudCore"]
        ),
        .testTarget(
            name: "OwnCloudCoreTests",
            dependencies: ["OwnCloudCore"]
        ),
        .testTarget(
            name: "FileProviderSupportTests",
            dependencies: ["FileProviderSupport"]
        )
    ]
)

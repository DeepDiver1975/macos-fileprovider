import Foundation

/// The content of the About window (issue #18).
///
/// Follows the same split as ``SettingsPresentation``: every string the window
/// renders is decided here, so the SwiftUI layer is a renderer and the wording is
/// covered by the Linux-buildable suite. Bundle reading and the current date stay
/// on the app side and arrive as plain values, which also keeps the output
/// deterministic in tests.

/// A bundle's marketing version and build number, rendered the way Apple's About
/// panels do: `1.2.3 (45)`.
public struct BundleVersion: Sendable, Equatable {
    public let version: String
    public let build: String?

    public init(version: String, build: String?) {
        self.version = version
        self.build = build
    }

    /// `"1.2.3 (45)"`, or just `"1.2.3"` when the build number is absent or would
    /// merely repeat the version.
    public var displayString: String {
        guard let build, !build.isEmpty, build != version else { return version }
        return "\(version) (\(build))"
    }
}

/// One `label: value` line in the About window's detail block.
public struct AboutDetailRow: Sendable, Equatable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// A titled external link.
public struct AboutLink: Sendable, Equatable {
    public let title: String
    public let url: URL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }
}

public struct AboutInfo: Sendable, Equatable {
    public let applicationName: String
    public let versionSummary: String
    public let detailRows: [AboutDetailRow]
    public let copyright: String
    public let links: [AboutLink]

    public init(applicationName: String,
                versionSummary: String,
                detailRows: [AboutDetailRow],
                copyright: String,
                links: [AboutLink]) {
        self.applicationName = applicationName
        self.versionSummary = versionSummary
        self.detailRows = detailRows
        self.copyright = copyright
        self.links = links
    }

    /// Shown in place of a version that could not be read. The About window is
    /// what a user opens *because* something is wrong, so a missing extension
    /// bundle must degrade to a legible row rather than an empty one or a crash.
    public static let unavailableValue = "Unavailable"

    public static let applicationDisplayName = "ownCloud File Provider"

    /// What the app managed to read out of its own and its extensions' bundles.
    /// Every field is optional because the About window has to render even when a
    /// bundle is missing or unloadable.
    public struct BundleVersions: Sendable, Equatable {
        public let appVersion: String?
        public let appBuild: String?
        public let fileProviderExtension: BundleVersion?
        public let fileProviderUIExtension: BundleVersion?

        public init(appVersion: String?,
                    appBuild: String?,
                    fileProviderExtension: BundleVersion?,
                    fileProviderUIExtension: BundleVersion?) {
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.fileProviderExtension = fileProviderExtension
            self.fileProviderUIExtension = fileProviderUIExtension
        }
    }

    /// The three links a user in the About window plausibly wants: the product
    /// page, the docs, and somewhere to report what went wrong.
    public static let websiteURL = URL(string: "https://owncloud.com")!
    public static let documentationURL = URL(string: "https://doc.owncloud.com")!
    public static let issueTrackerURL =
        URL(string: "https://github.com/DeepDiver1975/macos-fileprovider/issues")!

    /// - Parameters:
    ///   - versions: what the app read from the bundles.
    ///   - osVersion: the host macOS version, for the support row.
    ///   - year: the copyright year, injected rather than read from the clock so
    ///     the string is identical on every machine and in every test run.
    public static func make(versions: BundleVersions,
                            osVersion: String,
                            year: Int) -> AboutInfo {
        let appSummary: String
        if let version = versions.appVersion, !version.isEmpty {
            appSummary = BundleVersion(version: version, build: versions.appBuild).displayString
        } else {
            appSummary = unavailableValue
        }

        // The two extensions load out-of-process and can be stale relative to the
        // app, so a bug report needs all three separately.
        let rows = [
            AboutDetailRow(label: "Core", value: OwnCloudCore.version),
            AboutDetailRow(label: "File Provider Extension",
                           value: versions.fileProviderExtension?.displayString ?? unavailableValue),
            AboutDetailRow(label: "File Provider UI Extension",
                           value: versions.fileProviderUIExtension?.displayString ?? unavailableValue),
            AboutDetailRow(label: "macOS", value: osVersion),
        ]

        return AboutInfo(
            applicationName: applicationDisplayName,
            versionSummary: "Version \(appSummary)",
            detailRows: rows,
            copyright: "© \(year) ownCloud GmbH",
            links: [
                AboutLink(title: "Website", url: websiteURL),
                AboutLink(title: "Documentation", url: documentationURL),
                AboutLink(title: "Report an Issue", url: issueTrackerURL),
            ]
        )
    }
}

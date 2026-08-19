import AppKit
import SwiftUI
import OwnCloudCore

/// The About window (issue #18), replacing AppKit's default panel.
///
/// The stock panel shows only the name and version. This one adds what a bug
/// report actually needs — the two extensions load out-of-process and can be stale
/// relative to the app, so their versions are listed separately — plus the
/// copyright and the links a user in this window plausibly wants.
///
/// As with ``SettingsWindow``, the view is deliberately thin: every string comes
/// from ``AboutInfo`` in `OwnCloudCore`, which is headlessly tested.
struct AboutWindow: View {
    let info: AboutInfo

    var body: some View {
        VStack(spacing: 16) {
            // The icon the system resolved for this bundle, so this window shows
            // whatever the Dock and Finder show rather than a second copy that
            // could drift from it.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(info.applicationName)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(info.versionSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // A grid rather than a Form: this is a read-only fact table, and the
            // labels should align without the inset-grouped chrome.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(info.detailRows, id: \.label) { row in
                    GridRow {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(row.value)
                            .textSelection(.enabled)   // so it can be pasted into a bug report
                    }
                }
            }
            .font(.callout)

            Divider()

            HStack(spacing: 12) {
                ForEach(info.links, id: \.title) { link in
                    Link(link.title, destination: link.url)
                }
            }
            .font(.callout)

            Text(info.copyright)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 360)
    }
}

/// Reads the versions the About window reports out of the running bundles.
///
/// The two extensions are embedded in `Contents/PlugIns`, so their versions come
/// from their own `Info.plist`s rather than the app's — that is the whole point of
/// listing them separately. A bundle that cannot be read yields `nil` and
/// ``AboutInfo`` renders it as unavailable.
enum AboutInfoReader {
    /// Bundle names as embedded by the App target (see `project.yml`).
    private static let fileProviderExtensionName = "FileProviderExtension.appex"
    private static let fileProviderUIExtensionName = "FileProviderUIExtension.appex"

    static func current(now: Date = Date()) -> AboutInfo {
        let app = Bundle.main
        let calendar = Calendar(identifier: .gregorian)

        return AboutInfo.make(
            versions: AboutInfo.BundleVersions(
                appVersion: app.shortVersionString,
                appBuild: app.buildString,
                fileProviderExtension: embeddedVersion(named: fileProviderExtensionName),
                fileProviderUIExtension: embeddedVersion(named: fileProviderUIExtensionName)
            ),
            osVersion: osVersion,
            year: calendar.component(.year, from: now)
        )
    }

    /// `"26.0"` / `"26.0.1"`. `operatingSystemVersionString` would read
    /// "Version 26.0 (Build 25F74)", which duplicates the row's own label.
    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let patch = version.patchVersion == 0 ? "" : ".\(version.patchVersion)"
        return "\(version.majorVersion).\(version.minorVersion)\(patch)"
    }

    private static func embeddedVersion(named name: String) -> BundleVersion? {
        guard let plugIns = Bundle.main.builtInPlugInsURL,
              let bundle = Bundle(url: plugIns.appendingPathComponent(name)),
              let version = bundle.shortVersionString
        else { return nil }
        return BundleVersion(version: version, build: bundle.buildString)
    }
}

private extension Bundle {
    var shortVersionString: String? {
        infoDictionary?["CFBundleShortVersionString"] as? String
    }

    var buildString: String? {
        infoDictionary?["CFBundleVersion"] as? String
    }
}

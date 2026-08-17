import SwiftUI
import OwnCloudCore

// Containing app entry point (scaffold for Task 1.1).
//
// The app's real job (Task 5.1) is to host the sign-in flow and register the
// File Provider domain via NSFileProviderManager. On macOS the extension is
// only discovered when this app lives in /Applications (or ~/Applications), or
// when FileProvider testing mode is enabled — see progress.md Task 5.1.
@main
struct OwnCloudFileProviderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("ownCloud File Provider")
                .font(.title2)
            Text("Core \(OwnCloudCore.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            #if DEBUG
            Divider()
                .padding(.vertical, 8)
            // Local end-to-end testing stand-in for the not-yet-built sign-in and
            // domain registration (Task 6.0 spike); compiled only in DEBUG.
            DevHarnessView()
            #endif
        }
        .padding(40)
    }
}

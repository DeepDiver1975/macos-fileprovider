import SwiftUI
import OwnCloudCore

// Containing app entry point (Task 1.1 scaffold; Task 7.8 makes it the settings app).
//
// Configuration is the app's only job (progress.md Phase 7), so its main window is
// the settings window itself — not a separate `Settings` scene. On macOS the
// extension is only discovered when this app lives in /Applications (or
// ~/Applications), or when FileProvider testing mode is enabled — see Task 5.1.
@main
struct OwnCloudFileProviderApp: App {
    @StateObject private var model = SettingsModel()

    var body: some Scene {
        WindowGroup {
            SettingsWindow(model: model)
                // Task 7.9: the UI extension opens the app here on a re-auth error.
                .onOpenURL { model.handleLaunch($0) }
        }
        .windowResizability(.contentSize)

        #if DEBUG
        // Local end-to-end testing stand-in for the sign-in and domain registration
        // (Task 6.0 spike); compiled only in DEBUG, kept out of the shipping window.
        Window("Dev Harness", id: "dev-harness") {
            DevHarnessView()
        }
        #endif
    }
}

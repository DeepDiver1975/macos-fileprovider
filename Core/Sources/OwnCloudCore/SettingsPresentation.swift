import Foundation

/// The headlessly-tested presentation logic behind the settings window (Task 7.8).
/// The SwiftUI layer is Mac-gated and thin: it renders these values and forwards
/// the chosen ``DomainRemovalChoice`` back to the ``DomainService``. Keeping the
/// decisions here means the wording, the Classic/oCIS split, and the enablement
/// warning are all covered by the Linux-buildable test suite.

/// One row in the Spaces-tab checklist.
public struct SpaceRow: Sendable, Equatable {
    public let driveID: String?
    public let name: String
    public let isSelected: Bool

    public init(driveID: String?, name: String, isSelected: Bool) {
        self.driveID = driveID
        self.name = name
        self.isSelected = isSelected
    }
}

/// The rendered Spaces tab for one account.
///
/// oCIS accounts get a selectable checklist, each row marked according to whether
/// a domain for that space already exists. Classic accounts get a single
/// non-editable "All files" row plus a note stating that per-space selection is an
/// oCIS capability — the difference is surfaced, not hidden.
public struct SpacesTab: Sendable, Equatable {
    public let rows: [SpaceRow]
    public let selectionDisabled: Bool
    public let classicNote: String?

    public init(rows: [SpaceRow], selectionDisabled: Bool, classicNote: String?) {
        self.rows = rows
        self.selectionDisabled = selectionDisabled
        self.classicNote = classicNote
    }

    /// Shown under the Classic single-row list.
    public static let classicSelectionNote =
        "This server syncs all files as one folder. Selecting individual spaces is an ownCloud Infinite Scale feature."

    public static func make(account: AccountDescriptor,
                            catalog: SpaceCatalog,
                            existing: [SyncRoot]) -> SpacesTab {
        let selectedDriveIDs = Set(existing.map { $0.driveID })
        let rows = catalog.spaces.map { space in
            SpaceRow(
                driveID: space.driveID,
                name: space.name,
                isSelected: selectedDriveIDs.contains(space.driveID)
            )
        }
        let isClassic = account.backend == .classic
        return SpacesTab(
            rows: rows,
            selectionDisabled: isClassic,
            classicNote: isClassic ? classicSelectionNote : nil
        )
    }
}

/// A single button in the deselect confirmation, pairing user-facing wording with
/// the machine choice it maps to.
public struct SpaceRemovalOption: Sendable, Equatable {
    public let label: String
    public let choice: DomainRemovalChoice

    public init(label: String, choice: DomainRemovalChoice) {
        self.label = label
        self.choice = choice
    }
}

/// The confirmation shown when a user deselects (removes) a space. The wording is
/// concrete — it names the space and, when there is anything on disk, the amount —
/// so "Keep the 840 MB already downloaded" reads unambiguously against "Remove them".
public struct SpaceRemovalPrompt: Sendable, Equatable {
    public let message: String
    public let keepChoice: SpaceRemovalOption
    public let removeChoice: SpaceRemovalOption

    public init(message: String, keepChoice: SpaceRemovalOption, removeChoice: SpaceRemovalOption) {
        self.message = message
        self.keepChoice = keepChoice
        self.removeChoice = removeChoice
    }

    public static func make(spaceName: String, downloadedBytes: Int) -> SpaceRemovalPrompt {
        let keepLabel: String
        if downloadedBytes > 0 {
            keepLabel = "Keep the \(humanizedBytes(downloadedBytes)) already downloaded"
        } else {
            keepLabel = "Keep the downloaded files"
        }
        return SpaceRemovalPrompt(
            message: "Stop syncing “\(spaceName)”?",
            keepChoice: SpaceRemovalOption(label: keepLabel, choice: .preserveDownloadedUserData),
            removeChoice: SpaceRemovalOption(label: "Remove them", choice: .removeAll)
        )
    }
}

/// Whether the domain is blocked by the System Settings > General > Login Items &
/// Extensions toggle (`userEnabled`). When off, nothing syncs; say so and link to
/// the pane, otherwise it reads as our bug rather than a switch the user flipped.
public struct DomainEnablementStatus: Sendable, Equatable {
    public let isBlocked: Bool
    public let message: String?
    public let settingsPaneURL: URL?

    public init(isBlocked: Bool, message: String?, settingsPaneURL: URL?) {
        self.isBlocked = isBlocked
        self.message = message
        self.settingsPaneURL = settingsPaneURL
    }

    public static func make(userEnabled: Bool) -> DomainEnablementStatus {
        guard !userEnabled else {
            return DomainEnablementStatus(isBlocked: false, message: nil, settingsPaneURL: nil)
        }
        return DomainEnablementStatus(
            isBlocked: true,
            message: "Syncing is turned off in System Settings. Turn it on under "
                + "Login Items & Extensions to resume.",
            settingsPaneURL: URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        )
    }
}

/// The step the Add Account sheet is on (issue #17).
///
/// The sheet cannot ask for a username and password up front any more, because
/// whether they are even wanted depends on what the server turns out to be: Classic
/// wants Basic credentials, oCIS requires OIDC and has no typed username at all
/// (the identity arrives in the `id_token`). So the sheet collects the server first,
/// probes it, and this type says what to show next — including the wording, so the
/// SwiftUI layer keeps making no decisions.
public enum AddAccountFlow: Sendable, Equatable {
    /// Collecting the server URL; nothing is known about the backend yet.
    case server
    /// The server is ownCloud Classic: collect username and password.
    case classicCredentials(serverURL: URL)
    /// The server is oCIS: the browser sheet is up and we are waiting for the
    /// authorization callback.
    case authorizing(serverURL: URL)

    /// The step a resolved ``SignInRoute`` leads to.
    public static func next(for route: SignInRoute) -> AddAccountFlow {
        switch route {
        case .classic(let serverURL):
            return .classicCredentials(serverURL: serverURL)
        case .oidc(let serverURL):
            return .authorizing(serverURL: serverURL)
        }
    }

    /// Whether the username/password fields are shown (Classic only).
    public var showsCredentialFields: Bool {
        if case .classicCredentials = self { return true }
        return false
    }

    /// Whether a sign-in is in flight, so the sheet shows progress and accepts no
    /// further submission — a second tap must not start a second authorization.
    public var isBusy: Bool {
        if case .authorizing = self { return true }
        return false
    }

    /// The primary button's title for this step: "Continue" leads to another step,
    /// "Sign In" completes one.
    public var primaryButtonTitle: String {
        switch self {
        case .server: return "Continue"
        case .classicCredentials: return "Sign In"
        case .authorizing: return "Signing In…"
        }
    }

    /// Explanatory text under the fields, if this step needs any. The oCIS step names
    /// the server the browser is being sent to, so a window appearing is expected
    /// rather than alarming.
    public var message: String? {
        switch self {
        case .server:
            return nil
        case .classicCredentials:
            return nil
        case .authorizing(let serverURL):
            let host = serverURL.host ?? serverURL.absoluteString
            return "Complete the sign-in for \(host) in the browser window."
        }
    }

    /// Whether the primary button is enabled for the currently typed fields. The
    /// password is deliberately not required: an empty one is for the server to
    /// reject, not for the button to pre-judge.
    public func canSubmit(server: String, username: String) -> Bool {
        func isPresent(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        switch self {
        case .server:
            return isPresent(server)
        case .classicCredentials:
            return isPresent(server) && isPresent(username)
        case .authorizing:
            return false
        }
    }
}

/// A compact binary-unit byte size ("840 MB", "1.5 GB") computed deterministically
/// so the deselect prompt reads the same on every platform the tests run on.
func humanizedBytes(_ bytes: Int) -> String {
    guard bytes > 0 else { return "0 bytes" }
    let units = ["bytes", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024 && unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    if unit == 0 { return "\(bytes) bytes" }
    // Whole numbers render without a decimal ("840 MB"); otherwise one place.
    if value.rounded() == value {
        return "\(Int(value)) \(units[unit])"
    }
    return String(format: "%.1f %@", value, units[unit])
}

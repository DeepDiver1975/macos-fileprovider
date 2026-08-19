import XCTest
@testable import OwnCloudCore

/// Task 7.8: the settings window keeps every decision it renders in headlessly
/// tested core types, so the SwiftUI layer stays thin. This covers the Spaces-tab
/// checklist model, the concretely-worded deselect prompt, and the `userEnabled`
/// surfacing.
final class SettingsPresentationTests: XCTestCase {

    private let einstein = AccountDescriptor(
        backend: .ocis, serverURL: URL(string: "https://ocis.test")!, username: "einstein")
    private let admin = AccountDescriptor(
        backend: .classic, serverURL: URL(string: "http://localhost:8080")!, username: "admin")

    // MARK: - Spaces tab: the checklist

    func testOCISSpacesTabMarksSelectedRowsFromExistingDomains() {
        let catalog = SpaceCatalog(spaces: [
            Space(driveID: "personal", name: "Personal", driveType: "personal", quotaTotal: nil, quotaUsed: nil),
            Space(driveID: "project", name: "Project Falcon", driveType: "project", quotaTotal: nil, quotaUsed: nil),
        ])
        // Only the personal space currently has a domain.
        let existing = [SyncRoot(account: einstein, driveID: "personal")!]

        let tab = SpacesTab.make(account: einstein, catalog: catalog, existing: existing)

        XCTAssertFalse(tab.selectionDisabled, "oCIS spaces are selectable")
        XCTAssertNil(tab.classicNote)
        XCTAssertEqual(tab.rows.map(\.name), ["Personal", "Project Falcon"])
        XCTAssertEqual(tab.rows.first { $0.name == "Personal" }?.isSelected, true)
        XCTAssertEqual(tab.rows.first { $0.name == "Project Falcon" }?.isSelected, false)
    }

    func testClassicSpacesTabIsSingleNonEditableRowWithReason() {
        let tab = SpacesTab.make(account: admin, catalog: .classic, existing: [SyncRoot(account: admin, driveID: nil)!])

        XCTAssertTrue(tab.selectionDisabled, "Classic has no space selection")
        // The difference is stated, not hidden (AC-1's @ocisOnly-with-a-reason convention).
        XCTAssertEqual(tab.classicNote, SpacesTab.classicSelectionNote)
        XCTAssertEqual(tab.rows.count, 1)
        XCTAssertEqual(tab.rows[0].name, "All files")
        XCTAssertTrue(tab.rows[0].isSelected)
    }

    // MARK: - Deselect prompt: concrete wording

    func testDeselectPromptStatesTheDownloadedSizeConcretely() {
        // 840 MB downloaded — the prompt names the amount and the two choices, per
        // the spec: "Keep the 840 MB already downloaded" / "Remove them".
        let prompt = SpaceRemovalPrompt.make(spaceName: "Project Falcon", downloadedBytes: 880_803_840)

        XCTAssertTrue(prompt.message.contains("Project Falcon"))
        XCTAssertEqual(prompt.keepChoice.choice, .preserveDownloadedUserData)
        XCTAssertEqual(prompt.removeChoice.choice, .removeAll)
        XCTAssertTrue(prompt.keepChoice.label.contains("840 MB"),
                      "keep label names the concrete size: \(prompt.keepChoice.label)")
        XCTAssertTrue(prompt.removeChoice.label.localizedCaseInsensitiveContains("remove"))
    }

    func testDeselectPromptWithNothingDownloadedStillOffersBothChoices() {
        let prompt = SpaceRemovalPrompt.make(spaceName: "Personal", downloadedBytes: 0)
        XCTAssertEqual(prompt.keepChoice.choice, .preserveDownloadedUserData)
        XCTAssertEqual(prompt.removeChoice.choice, .removeAll)
        // With nothing downloaded the size clause is dropped rather than "0 bytes".
        XCTAssertFalse(prompt.keepChoice.label.contains("0 "))
    }

    // MARK: - Account removal prompt (issue #26)

    /// Removing an account is not a per-space deselect: it drops the credential and
    /// every one of the account's spaces at once. The prompt therefore names the
    /// account and states that consequence, so the two dialogs cannot be confused.
    func testAccountRemovalPromptNamesTheAccountAndBothChoices() {
        let prompt = AccountRemovalPrompt.make(
            accountName: "admin@localhost", spaceCount: 2, downloadedBytes: 0)

        XCTAssertTrue(prompt.message.contains("admin@localhost"),
                      "message names the account: \(prompt.message)")
        XCTAssertEqual(prompt.keepChoice.choice, .preserveDownloadedUserData)
        XCTAssertEqual(prompt.removeChoice.choice, .removeAll)
        XCTAssertTrue(prompt.removeChoice.label.localizedCaseInsensitiveContains("remove"))
    }

    /// The consequence is spelled out, not implied: how many spaces stop syncing and
    /// that the stored credential goes. "2 spaces" — plural.
    func testAccountRemovalPromptStatesTheConsequenceInPlural() {
        let prompt = AccountRemovalPrompt.make(
            accountName: "einstein", spaceCount: 3, downloadedBytes: 0)

        XCTAssertTrue(prompt.detail.contains("3 spaces"),
                      "detail counts the spaces: \(prompt.detail)")
        XCTAssertTrue(prompt.detail.localizedCaseInsensitiveContains("sign in again"),
                      "detail says the credential goes: \(prompt.detail)")
    }

    /// One space reads "1 space", not "1 spaces".
    func testAccountRemovalPromptStatesTheConsequenceInSingular() {
        let prompt = AccountRemovalPrompt.make(
            accountName: "admin@localhost", spaceCount: 1, downloadedBytes: 0)

        XCTAssertTrue(prompt.detail.contains("1 space"), prompt.detail)
        XCTAssertFalse(prompt.detail.contains("1 spaces"), prompt.detail)
    }

    /// A zero-space account is legal (the registry's whole reason to exist), so the
    /// detail must not claim a space count it doesn't have.
    func testAccountRemovalPromptWithNoSpacesDropsTheSpaceClause() {
        let prompt = AccountRemovalPrompt.make(
            accountName: "admin@localhost", spaceCount: 0, downloadedBytes: 0)

        XCTAssertFalse(prompt.detail.contains("0 space"), prompt.detail)
        XCTAssertTrue(prompt.detail.localizedCaseInsensitiveContains("sign in again"),
                      "the credential clause still applies: \(prompt.detail)")
    }

    /// Same rule as the deselect prompt: name the concrete amount when it is known.
    func testAccountRemovalPromptNamesTheDownloadedSizeWhenKnown() {
        let prompt = AccountRemovalPrompt.make(
            accountName: "einstein", spaceCount: 2, downloadedBytes: 880_803_840)

        XCTAssertTrue(prompt.keepChoice.label.contains("840 MB"),
                      "keep label names the concrete size: \(prompt.keepChoice.label)")
    }

    func testAccountRemovalPromptWithNothingDownloadedDropsTheSizeClause() {
        let prompt = AccountRemovalPrompt.make(
            accountName: "einstein", spaceCount: 2, downloadedBytes: 0)

        XCTAssertFalse(prompt.keepChoice.label.contains("0 "), prompt.keepChoice.label)
        XCTAssertTrue(prompt.keepChoice.label.localizedCaseInsensitiveContains("keep"),
                      prompt.keepChoice.label)
    }

    // MARK: - userEnabled surfacing

    func testDomainDisabledInSystemSettingsIsSurfacedWithAPaneLink() {
        // If someone flips the System Settings toggle off, say so and link to the
        // pane — otherwise it reads as our bug.
        let status = DomainEnablementStatus.make(userEnabled: false)
        XCTAssertTrue(status.isBlocked)
        XCTAssertNotNil(status.message)
        XCTAssertNotNil(status.settingsPaneURL)
    }

    func testDomainEnabledHasNoWarning() {
        let status = DomainEnablementStatus.make(userEnabled: true)
        XCTAssertFalse(status.isBlocked)
        XCTAssertNil(status.message)
    }

    // MARK: - Add Account flow (issue #17)

    /// The sheet cannot ask for a username up front any more: whether credentials are
    /// even wanted depends on what the server turns out to be. So it starts at the
    /// server step, where only the server field gates Continue.
    func testFlowStartsAtTheServerStepAndOnlyNeedsAServer() {
        let flow = AddAccountFlow.server
        XCTAssertFalse(flow.showsCredentialFields)
        XCTAssertFalse(flow.isBusy)
        XCTAssertFalse(flow.canSubmit(server: "  ", username: ""))
        XCTAssertTrue(flow.canSubmit(server: "localhost:8080", username: ""))
    }

    /// A Classic server advances to the credentials step, which does require a
    /// username (the Basic-auth identity) but not a password — an empty password is a
    /// server-side rejection, not something to block the button on.
    func testClassicCredentialsStepRequiresAUsername() {
        let flow = AddAccountFlow.classicCredentials(serverURL: URL(string: "http://localhost:8080")!)
        XCTAssertTrue(flow.showsCredentialFields)
        XCTAssertFalse(flow.isBusy)
        XCTAssertFalse(flow.canSubmit(server: "http://localhost:8080", username: " "))
        XCTAssertTrue(flow.canSubmit(server: "http://localhost:8080", username: "admin"))
    }

    /// While the browser sheet is up nothing is submittable — a second tap must not
    /// start a second authorization.
    func testAuthorizingStepIsBusyAndBlocksSubmission() {
        let flow = AddAccountFlow.authorizing(serverURL: URL(string: "https://ocis.test")!)
        XCTAssertTrue(flow.isBusy)
        XCTAssertFalse(flow.showsCredentialFields)
        XCTAssertFalse(flow.canSubmit(server: "https://ocis.test", username: "einstein"))
    }

    /// Each step names its own primary button, so the view has no wording decisions
    /// left to make: "Continue" leads to a second step, "Sign In" completes.
    func testEachStepLabelsItsPrimaryButton() {
        XCTAssertEqual(AddAccountFlow.server.primaryButtonTitle, "Continue")
        XCTAssertEqual(
            AddAccountFlow.classicCredentials(serverURL: URL(string: "http://x.test")!).primaryButtonTitle,
            "Sign In")
        XCTAssertEqual(
            AddAccountFlow.authorizing(serverURL: URL(string: "https://x.test")!).primaryButtonTitle,
            "Signing In…")
    }

    /// The oCIS step explains where the user is being sent, and names the server, so
    /// a browser window appearing is expected rather than alarming.
    func testAuthorizingStepExplainsTheBrowserHandoff() {
        let flow = AddAccountFlow.authorizing(serverURL: URL(string: "https://ocis.test")!)
        let message = try? XCTUnwrap(flow.message)
        XCTAssertTrue(message?.contains("ocis.test") == true, String(describing: message))
    }

    /// The route the resolver returns picks the next step — that mapping is a
    /// decision, so it lives here rather than in the SwiftUI sheet.
    func testFlowAdvancesAccordingToTheResolvedRoute() {
        let ocis = URL(string: "https://ocis.test")!
        XCTAssertEqual(AddAccountFlow.next(for: .oidc(serverURL: ocis)), .authorizing(serverURL: ocis))

        let classicURL = URL(string: "http://localhost:8080")!
        XCTAssertEqual(AddAccountFlow.next(for: .classic(serverURL: classicURL)),
                       .classicCredentials(serverURL: classicURL))
    }
}

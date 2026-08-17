import Cocoa
import FileProviderUI

// Principal class for the FileProviderUI extension, referenced from
// SupportingFiles/Info.plist as $(PRODUCT_MODULE_NAME).ActionViewController.
//
// Scaffold for Task 1.1; the sign-in / re-authentication UI is built in Task 5.2.
final class ActionViewController: FPUIActionExtensionViewController {

    override func prepare(forError error: Error) {
        // Re-authentication flow (Task 5.2): show credential entry for the
        // domain whose session expired.
    }

    override func prepare(forAction actionIdentifier: String, itemIdentifiers: [NSFileProviderItemIdentifier]) {
        // Custom action UI (Task 5.2). Non-UI actions live in the File Provider
        // extension via NSExtensionFileProviderActions.
    }
}

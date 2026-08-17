import FileProvider
import OwnCloudCore
import FileProviderSupport

// Principal class for the File Provider (non-UI) extension, referenced from
// SupportingFiles/Info.plist as $(PRODUCT_MODULE_NAME).FileProviderExtension.
//
// It reconstructs the account from the domain identifier (progress.md Task 5.1)
// and builds a BackendConnection (Phase 3–5) that the enumerator and content
// handlers drive. The pagination, request shaping, parsing and error
// classification all live in the Linux-buildable core and are unit-tested there;
// this class is the thin FileProvider-framework wiring.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    let domain: NSFileProviderDomain
    private let account: AccountDescriptor?
    private let connection: BackendConnection?
    private let downloader: ContentDownloader
    private let client: RemoteClient

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let client = RemoteClient.urlSession()
        self.client = client
        // The domain identifier round-trips the account (backend, server, user).
        let account = AccountDescriptor(domainIdentifier: domain.identifier.rawValue)
        self.account = account
        // Credentials come from the shared Keychain access group (Task 1.3); the
        // authorization header and the resolved oCIS drive id are looked up per
        // domain. Until the Keychain-backed CredentialStore is wired (Mac runtime),
        // there is no authorization and calls surface .notAuthenticated.
        let authorization = FileProviderExtension.authorization(for: account)
        self.connection = account.map {
            BackendConnection(account: $0, client: client, authorization: authorization, driveID: nil)
        }
        self.downloader = ContentDownloader(client: client)
        super.init()
    }

    func invalidate() {
        // No long-lived resources held per domain.
    }

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        // Single-item lookup is added with the metadata cache; enumeration is the
        // Task 6.0 make-or-break path and is wired below.
        completionHandler(nil, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        guard let connection else {
            completionHandler(nil, nil, NSFileProviderError(.notAuthenticated))
            return Progress()
        }
        let fetchRequest: RemoteRequest
        switch connection.account.backend {
        case .classic:
            // The Classic item identifier is the server-relative path.
            fetchRequest = connection.fetchContentsRequest(path: itemIdentifier.rawValue)
        case .ocis:
            fetchRequest = connection.fetchContentsRequest(itemID: itemIdentifier.rawValue)
        }
        let downloader = self.downloader
        let auth = FileProviderExtension.authorization(for: account)
        Task {
            do {
                let url = try await downloader.download(fetchRequest, authorization: auth)
                // Hand the temp URL back; the system takes ownership. The item is
                // supplied on the next enumeration/lookup pass.
                completionHandler(url, nil, nil)
            } catch let error as RemoteError {
                completionHandler(nil, nil, error.asFileProviderError)
            } catch {
                completionHandler(nil, nil, error)
            }
        }
        return Progress()
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        // Phase 4, Task 4.4. oCIS reconciles the created item from the driveItem
        // the server returns (its assigned id + eTag). Classic returns no metadata
        // body on a PUT/MKCOL (it needs a follow-up PROPFIND), so that path stays
        // pending the Task 6.0 live spike.
        guard let connection else {
            completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
            return Progress()
        }
        guard connection.account.backend == .ocis else {
            completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
            return Progress()
        }

        let parent: ItemIdentifier = itemTemplate.parentItemIdentifier == .rootContainer
            ? .rootContainer
            : ItemIdentifier(rawValue: itemTemplate.parentItemIdentifier.rawValue)
        let isDirectory = itemTemplate.contentType == .folder
        let createRequest = connection.createItemRequest(
            parentID: parent, name: itemTemplate.filename, isDirectory: isDirectory
        )

        let client = self.client
        let uploader = ContentUploader(client: client)
        let auth = FileProviderExtension.authorization(for: account)
        Task {
            do {
                // A folder POST carries its JSON body in the request; a file PUT
                // streams the contents the system handed us.
                let responseBody: Data
                if isDirectory {
                    responseBody = try await client.send(createRequest, authorization: auth)
                } else if let url {
                    responseBody = try await uploader.uploadReturningBody(createRequest, fromFile: url, authorization: auth)
                } else {
                    // A non-directory create with no contents is a zero-byte file.
                    responseBody = try await client.send(createRequest, body: Data(), authorization: auth)
                }
                let created = try GraphJSONDecoder().decodeItem(responseBody)
                let item = FileProviderItem(itemDescription: FileProviderItemDescription(graphItem: created))
                completionHandler(item, [], false, nil)
            } catch let error as RemoteError {
                completionHandler(nil, [], false, error.asFileProviderError)
            } catch {
                completionHandler(nil, [], false, error)
            }
        }
        return Progress()
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        // Phase 4, Task 4.4.
        completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        // Phase 4, Task 4.4. Delete needs no metadata read-back: issue the DELETE
        // at the item's backend address and report success or a mapped error.
        guard let connection else {
            completionHandler(NSFileProviderError(.notAuthenticated))
            return Progress()
        }
        let deleteRequest: RemoteRequest
        switch connection.account.backend {
        case .classic:
            deleteRequest = connection.deleteRequest(path: identifier.rawValue)
        case .ocis:
            deleteRequest = connection.deleteRequest(itemID: identifier.rawValue)
        }
        let client = self.client
        let auth = FileProviderExtension.authorization(for: account)
        Task {
            do {
                try await client.send(deleteRequest, authorization: auth)
                completionHandler(nil)
            } catch let error as RemoteError {
                completionHandler(error.asFileProviderError)
            } catch {
                completionHandler(error)
            }
        }
        return Progress()
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        guard let connection else {
            throw NSFileProviderError(.notAuthenticated)
        }
        let container: ItemIdentifier = containerItemIdentifier == .rootContainer
            ? .rootContainer
            : ItemIdentifier(rawValue: containerItemIdentifier.rawValue)
        return ItemEnumerator(source: connection.enumerationSource(for: container))
    }

    // MARK: Credentials

    /// The shared Keychain access group both the app's sign-in flow and this
    /// extension read credentials from. Matches the `keychain-access-groups`
    /// entitlement; the leading team prefix (`$(AppIdentifierPrefix)`) is applied
    /// automatically by the keychain for the app-group form used here.
    private static let keychainAccessGroup = "com.owncloud.macos.fileprovider.shared"

    /// The `Authorization` header for this domain's account, read from the shared
    /// Keychain access group (Task 1.3 / 2.5). Returns `nil` when the account is
    /// unknown or no credentials are stored, so handlers fail cleanly with
    /// `.notAuthenticated` rather than sending unauthenticated requests.
    private static func authorization(for account: AccountDescriptor?) -> String? {
        guard let account else { return nil }
        let store = KeychainCredentialStore(account: account, accessGroup: keychainAccessGroup)
        let session = SessionManager(store: store)
        // Refresh a bearer token that is at/near expiry before building the
        // header; a no-op for Basic auth and when no refresh handler is wired.
        try? session.refreshTokenIfNeeded()
        return try? session.authorizationHeader()
    }
}

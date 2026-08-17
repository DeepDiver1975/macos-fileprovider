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
    private let downloader: ContentDownloader
    private let client: RemoteClient
    /// Caches the oCIS drive-id resolution so `me/drives` is looked up once per
    /// extension instance, not per operation.
    private let driveIDCache = DriveIDCache()

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let client = RemoteClient.urlSession()
        self.client = client
        // The domain identifier round-trips the account (backend, server, user).
        self.account = AccountDescriptor(domainIdentifier: domain.identifier.rawValue)
        self.downloader = ContentDownloader(client: client)
        super.init()
    }

    /// Build the backend connection for this operation. Classic needs no drive id;
    /// oCIS resolves its personal drive id once (cached) before the connection can
    /// address items. Credentials come from the shared Keychain access group (Task
    /// 1.3); with none stored there is no authorization and callers surface
    /// `.notAuthenticated`.
    private func makeConnection() async throws -> BackendConnection {
        guard let account else { throw NSFileProviderError(.notAuthenticated) }
        let authorization = FileProviderExtension.authorization(for: account)
        let driveID: String?
        switch account.backend {
        case .classic:
            driveID = nil
        case .ocis:
            driveID = try await driveIDCache.driveID {
                let resolver = DriveResolver(serverURL: account.serverURL, client: self.client)
                return try await resolver.resolvePersonalDriveID(authorization: authorization)
            }
        }
        return BackendConnection(account: account, client: client, authorization: authorization, driveID: driveID)
    }

    /// Memoizes the resolved oCIS drive id across concurrent operations; the
    /// resolver runs at most once and a failed resolution is not cached.
    private actor DriveIDCache {
        private var resolved: Task<String, Error>?

        func driveID(_ resolve: @escaping @Sendable () async throws -> String) async throws -> String {
            if let resolved { return try await resolved.value }
            let task = Task { try await resolve() }
            resolved = task
            do {
                return try await task.value
            } catch {
                resolved = nil
                throw error
            }
        }
    }

    func invalidate() {
        // No long-lived resources held per domain.
    }

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        // The system asks for a single item's current metadata. The root container
        // is synthetic (no backend round-trip). Otherwise fetch it: oCIS GETs the
        // driveItem (which carries its own parent); Classic reuses the Depth:0
        // PROPFIND read-back, deriving the parent by dropping the last path segment
        // (WebDAV hrefs don't carry a parent id).
        if identifier == .rootContainer {
            let root = FileProviderItemDescription.rootContainer(filename: domain.displayName)
            completionHandler(FileProviderItem(itemDescription: root), nil)
            return Progress()
        }
        Task {
            do {
                let connection = try await makeConnection()
                let item = try await fetchItem(connection: connection, identifier: identifier)
                completionHandler(item, nil)
            } catch let error as RemoteError {
                completionHandler(nil, error.asFileProviderError)
            } catch {
                completionHandler(nil, error)
            }
        }
        return Progress()
    }

    /// Fetch a single item's current metadata from the backend and reconcile it
    /// into an `NSFileProviderItem`.
    private func fetchItem(
        connection: BackendConnection,
        identifier: NSFileProviderItemIdentifier
    ) async throws -> FileProviderItem {
        let auth = FileProviderExtension.authorization(for: account)
        switch connection.account.backend {
        case .ocis:
            let body = try await client.send(connection.itemMetadataRequest(itemID: identifier.rawValue), authorization: auth)
            let item = try GraphJSONDecoder().decodeItem(body)
            return FileProviderItem(itemDescription: FileProviderItemDescription(graphItem: item))
        case .classic:
            // The Classic identifier is the server-relative path; its parent is the
            // path with the last segment removed ("/" for a child of the root).
            let path = identifier.rawValue
            let parentPath = (path as NSString).deletingLastPathComponent
            let parent: ItemIdentifier = (parentPath.isEmpty || parentPath == "/")
                ? .rootContainer
                : ItemIdentifier(rawValue: parentPath)
            let body = try await client.send(connection.readBackRequest(path: path), authorization: auth)
            guard let description = try connection.readBackItem(fromPropfind: body, parentIdentifier: parent) else {
                throw NSFileProviderError(.noSuchItem)
            }
            return FileProviderItem(itemDescription: description)
        }
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let downloader = self.downloader
        let auth = FileProviderExtension.authorization(for: account)
        Task {
            do {
                let connection = try await makeConnection()
                let fetchRequest: RemoteRequest
                switch connection.account.backend {
                case .classic:
                    // The Classic item identifier is the server-relative path.
                    fetchRequest = connection.fetchContentsRequest(path: itemIdentifier.rawValue)
                case .ocis:
                    fetchRequest = connection.fetchContentsRequest(itemID: itemIdentifier.rawValue)
                }
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
        // Phase 4, Task 4.4. The two backends reconcile the created item
        // differently: oCIS returns the driveItem (its assigned id + eTag) in the
        // response body, while Classic's PUT/MKCOL returns no body and needs a
        // Depth:0 PROPFIND read-back to learn the server-assigned id and etag.
        let isDirectory = itemTemplate.contentType == .folder
        let parentIdentifier = itemTemplate.parentItemIdentifier
        let parent: ItemIdentifier = parentIdentifier == .rootContainer
            ? .rootContainer
            : ItemIdentifier(rawValue: parentIdentifier.rawValue)
        let name = itemTemplate.filename
        Task {
            do {
                let connection = try await makeConnection()
                let item: FileProviderItem
                switch connection.account.backend {
                case .ocis:
                    item = try await createItemOCIS(
                        connection: connection, parent: parent, name: name,
                        isDirectory: isDirectory, contents: url
                    )
                case .classic:
                    item = try await createItemClassic(
                        connection: connection, parentIdentifier: parentIdentifier,
                        parent: parent, name: name, isDirectory: isDirectory, contents: url
                    )
                }
                completionHandler(item, [], false, nil)
            } catch let error as RemoteError {
                completionHandler(nil, [], false, error.asFileProviderError)
            } catch {
                completionHandler(nil, [], false, error)
            }
        }
        return Progress()
    }

    /// oCIS create: the response body is the created driveItem, so it reconciles
    /// directly with no read-back.
    private func createItemOCIS(
        connection: BackendConnection,
        parent: ItemIdentifier,
        name: String,
        isDirectory: Bool,
        contents url: URL?
    ) async throws -> FileProviderItem {
        let createRequest = connection.createItemRequest(parentID: parent, name: name, isDirectory: isDirectory)
        let uploader = ContentUploader(client: client)
        let auth = FileProviderExtension.authorization(for: account)
        // A folder POST carries its JSON body in the request; a file PUT streams
        // the contents the system handed us.
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
        return FileProviderItem(itemDescription: FileProviderItemDescription(graphItem: created))
    }

    /// Classic create: PUT/MKCOL return no metadata body, so after the write we
    /// PROPFIND (Depth:0) the new item's path to learn its server-assigned id and
    /// etag, then reconcile. The Classic item identifier is the server-relative
    /// path, so the new item's path is the parent path joined with the filename.
    private func createItemClassic(
        connection: BackendConnection,
        parentIdentifier: NSFileProviderItemIdentifier,
        parent: ItemIdentifier,
        name: String,
        isDirectory: Bool,
        contents url: URL?
    ) async throws -> FileProviderItem {
        // The root container is served at "/", so a child of root is "/name";
        // otherwise it is "<parent path>/name".
        let parentPath = parentIdentifier == .rootContainer ? "" : parentIdentifier.rawValue
        let newPath = parentPath + "/" + name
        let writeRequest = isDirectory
            ? connection.createDirectoryRequest(path: newPath)
            : connection.createFileRequest(path: newPath)
        let readBackRequest = connection.readBackRequest(path: newPath)
        let uploader = ContentUploader(client: client)
        let auth = FileProviderExtension.authorization(for: account)

        // Write first (create the collection, or stream the file bytes),
        // discarding the empty response.
        if isDirectory {
            _ = try await client.send(writeRequest, authorization: auth)
        } else if let url {
            _ = try await uploader.uploadReturningBody(writeRequest, fromFile: url, authorization: auth)
        } else {
            _ = try await client.send(writeRequest, body: Data(), authorization: auth)
        }
        // Then read the new item back for its server-assigned metadata.
        let body = try await client.send(readBackRequest, authorization: auth)
        guard let description = try connection.readBackItem(fromPropfind: body, parentIdentifier: parent) else {
            // The write succeeded but the read-back found nothing — treat as a
            // server-side error rather than reporting a bogus item.
            throw NSFileProviderError(.serverUnreachable)
        }
        return FileProviderItem(itemDescription: description)
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
        // Phase 4, Task 4.4. Two change kinds are wired: a content edit (PUT the
        // new bytes with an `If-Match` on the base version's etag, then reconcile)
        // and a rename/move (`.filename`/`.parentItemIdentifier` — WebDAV MOVE /
        // Graph PATCH). A single call carrying both is applied content-first then
        // rename (neither backend offers a truly atomic combined op): the content
        // PUT targets the item's current address, then the move relocates it, and
        // the move's reconciled item — the final server state — is returned. This
        // ordering keeps the Classic path-address valid, since the content write
        // happens before the path changes.
        let etag = String(data: version.contentVersion, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
        let identifier = item.itemIdentifier
        let parent: ItemIdentifier = item.parentItemIdentifier == .rootContainer
            ? .rootContainer
            : ItemIdentifier(rawValue: item.parentItemIdentifier.rawValue)

        let contentsChanged = changedFields.contains(.contents)
        let renamed = changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier)

        // A change we don't handle (e.g. a pure metadata edit) needs no connection.
        guard contentsChanged || renamed else {
            completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
            return Progress()
        }

        Task {
            do {
                let connection = try await makeConnection()
                var result: FileProviderItem?
                if contentsChanged {
                    // The base version's content token is the etag the system last
                    // saw; send it as `If-Match` so a server-side change since then
                    // fails the write rather than silently clobbering it.
                    switch connection.account.backend {
                    case .ocis:
                        result = try await modifyContentsOCIS(
                            connection: connection, itemID: identifier.rawValue,
                            etag: etag, contents: newContents
                        )
                    case .classic:
                        result = try await modifyContentsClassic(
                            connection: connection, path: identifier.rawValue,
                            parent: parent, etag: etag, contents: newContents
                        )
                    }
                }
                if renamed {
                    result = try await moveItem(
                        connection: connection, item: item,
                        changedFields: changedFields, parent: parent
                    )
                }
                // Both flags were false is handled by the guard above, so `result`
                // is always set here.
                completionHandler(result, [], false, nil)
            } catch let error as RemoteError {
                completionHandler(nil, [], false, error.asFileProviderError)
            } catch {
                completionHandler(nil, [], false, error)
            }
        }
        return Progress()
    }

    /// Rename and/or move an item: WebDAV `MOVE` (path-addressed) for Classic and
    /// Graph `PATCH` (id-addressed) for oCIS. The reparent target is only sent
    /// when `.parentItemIdentifier` actually changed, so a pure rename stays in
    /// place.
    private func moveItem(
        connection: BackendConnection,
        item: NSFileProviderItem,
        changedFields: NSFileProviderItemFields,
        parent: ItemIdentifier
    ) async throws -> FileProviderItem {
        let newName = item.filename
        let parentChanged = changedFields.contains(.parentItemIdentifier)
        let auth = FileProviderExtension.authorization(for: account)

        switch connection.account.backend {
        case .ocis:
            let moveRequest = connection.moveRequest(
                itemID: item.itemIdentifier.rawValue,
                newName: newName,
                newParentID: parentChanged ? parent.rawValue : nil
            )
            let body = try await client.send(moveRequest, authorization: auth)
            let updated = try GraphJSONDecoder().decodeItem(body)
            return FileProviderItem(itemDescription: FileProviderItemDescription(graphItem: updated))
        case .classic:
            // WebDAV is path-addressed: the destination path is the new parent's
            // path joined with the new filename. Root is served at "/".
            let parentPath = item.parentItemIdentifier == .rootContainer ? "" : parent.rawValue
            let toPath = parentPath + "/" + newName
            let moveRequest = connection.moveRequest(fromPath: item.itemIdentifier.rawValue, toPath: toPath)
            let readBackRequest = connection.readBackRequest(path: toPath)
            _ = try await client.send(moveRequest, authorization: auth)
            let body = try await client.send(readBackRequest, authorization: auth)
            guard let description = try connection.readBackItem(fromPropfind: body, parentIdentifier: parent) else {
                throw NSFileProviderError(.serverUnreachable)
            }
            return FileProviderItem(itemDescription: description)
        }
    }

    /// oCIS content modify: PUT on `/items/{id}/content` returns the updated
    /// driveItem, so it reconciles directly.
    private func modifyContentsOCIS(
        connection: BackendConnection,
        itemID: String,
        etag: String?,
        contents newContents: URL?
    ) async throws -> FileProviderItem {
        let modifyRequest = connection.modifyContentsRequest(itemID: itemID, ifMatchETag: etag)
        let uploader = ContentUploader(client: client)
        let auth = FileProviderExtension.authorization(for: account)
        let responseBody: Data
        if let newContents {
            responseBody = try await uploader.uploadReturningBody(modifyRequest, fromFile: newContents, authorization: auth)
        } else {
            responseBody = try await client.send(modifyRequest, body: Data(), authorization: auth)
        }
        let updated = try GraphJSONDecoder().decodeItem(responseBody)
        return FileProviderItem(itemDescription: FileProviderItemDescription(graphItem: updated))
    }

    /// Classic content modify: a WebDAV PUT returns no metadata body, so after the
    /// write we read the item back (Depth:0 PROPFIND) for its new etag, mirroring
    /// `createItemClassic`.
    private func modifyContentsClassic(
        connection: BackendConnection,
        path: String,
        parent: ItemIdentifier,
        etag: String?,
        contents newContents: URL?
    ) async throws -> FileProviderItem {
        let modifyRequest = connection.modifyContentsRequest(path: path, ifMatchETag: etag)
        let readBackRequest = connection.readBackRequest(path: path)
        let uploader = ContentUploader(client: client)
        let auth = FileProviderExtension.authorization(for: account)
        if let newContents {
            _ = try await uploader.uploadReturningBody(modifyRequest, fromFile: newContents, authorization: auth)
        } else {
            _ = try await client.send(modifyRequest, body: Data(), authorization: auth)
        }
        let body = try await client.send(readBackRequest, authorization: auth)
        guard let description = try connection.readBackItem(fromPropfind: body, parentIdentifier: parent) else {
            throw NSFileProviderError(.serverUnreachable)
        }
        return FileProviderItem(itemDescription: description)
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
        let auth = FileProviderExtension.authorization(for: account)
        Task {
            do {
                let connection = try await makeConnection()
                let deleteRequest: RemoteRequest
                switch connection.account.backend {
                case .classic:
                    deleteRequest = connection.deleteRequest(path: identifier.rawValue)
                case .ocis:
                    deleteRequest = connection.deleteRequest(itemID: identifier.rawValue)
                }
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
        // `enumerator(for:)` is synchronous, but oCIS drive-id resolution is async.
        // Defer building the real source (which needs a resolved `BackendConnection`)
        // to the first page fetch via `LazyRemoteEnumerationSource`.
        let container: ItemIdentifier = containerItemIdentifier == .rootContainer
            ? .rootContainer
            : ItemIdentifier(rawValue: containerItemIdentifier.rawValue)
        let source = LazyRemoteEnumerationSource {
            let connection = try await self.makeConnection()
            return connection.enumerationSource(for: container)
        }
        return ItemEnumerator(source: source)
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

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
    /// The sync root this domain maps to (account + optional oCIS drive id),
    /// reconstructed from the domain identifier (Task 7.1).
    private let syncRoot: SyncRoot?
    private var account: AccountDescriptor? { syncRoot?.account }
    private let client: RemoteClient
    /// Caches the oCIS drive-id resolution so `me/drives` is looked up once per
    /// extension instance, not per operation — only used when the domain
    /// identifier carries no drive id (a legacy domain / defensive fallback).
    private let driveIDCache = DriveIDCache()

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let client = RemoteClient.urlSession()
        self.client = client
        // The domain identifier round-trips the sync root: "<driveID>|<account>".
        self.syncRoot = SyncRoot(domainIdentifier: domain.identifier.rawValue)
        super.init()
    }

    /// Build the backend connection for this operation. Classic needs no drive id.
    /// For oCIS the drive id comes from the ``SyncRoot`` (one domain per space, so
    /// it is baked into the identifier, Task 7.1); only a legacy identifier lacking
    /// a drive head falls back to resolving the personal drive once (cached).
    /// Credentials come from the shared Keychain access group (Task 1.3); with none
    /// stored there is no authorization and callers surface `.notAuthenticated`.
    private func makeConnection() async throws -> BackendConnection {
        guard let syncRoot else { throw NSFileProviderError(.notAuthenticated) }
        let account = syncRoot.account
        let authorization = FileProviderExtension.authorization(for: account)
        let driveID: String?
        switch account.backend {
        case .classic:
            driveID = nil
        case .ocis:
            if let resolved = syncRoot.driveID {
                driveID = resolved
            } else {
                driveID = try await driveIDCache.driveID {
                    let resolver = DriveResolver(serverURL: account.serverURL, client: self.client)
                    return try await resolver.resolvePersonalDriveID(authorization: authorization)
                }
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
        // The system asks for a single item's current metadata. Like
        // `enumerator(for:)` this receives the framework's *reserved* identifiers as
        // well as server ids, so it resolves them the same way — otherwise the
        // reserved raw value is sent as an address, which was observed live as
        // `PROPFIND /dav/spaces/NSFileProviderTrashContainerItemIdentifier → 404`
        // repeating for as long as the domain stayed mounted. Trash resolves to nil
        // and is refused; the root and working set are answered synthetically, since
        // no server serves a "root" name either.
        //
        // Otherwise both backends do the same Depth:0 PROPFIND read-back (Task 4.5);
        // they differ only in where the parent comes from — oCIS serves it as
        // `oc:file-parent`, while Classic needs it derived by dropping the last path
        // segment (WebDAV hrefs don't carry a parent id).
        guard let resolved = ItemIdentifier(rawValue: identifier.rawValue).resolvedContainer else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        if resolved == .rootContainer {
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
            // Space WebDAV: one Depth:0 PROPFIND at the item's `oc:id` yields
            // identifier, parent and name together, so nothing is derived here.
            let body = try await client.send(connection.itemMetadataRequest(itemID: identifier.rawValue), authorization: auth)
            guard let description = try connection.readBackItem(fromOCISPropfind: body) else {
                throw NSFileProviderError(.noSuchItem)
            }
            return FileProviderItem(itemDescription: description)
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
        let auth = FileProviderExtension.authorization(for: account)
        let domain = self.domain
        let client = self.client
        Task {
            do {
                let connection = try await makeConnection()
                // The system requires BOTH the file URL and the item's current
                // metadata on success — a nil item aborts the extension via the
                // NSAssertionHandler in FPXExtensionContext.fetchContents. So fetch
                // the item's metadata alongside its bytes.
                let item = try await fetchItem(connection: connection, identifier: itemIdentifier)
                let fetchRequest: RemoteRequest
                switch connection.account.backend {
                case .classic:
                    // The Classic item identifier is the server-relative path.
                    fetchRequest = connection.fetchContentsRequest(path: itemIdentifier.rawValue)
                case .ocis:
                    fetchRequest = connection.fetchContentsRequest(itemID: itemIdentifier.rawValue)
                }
                // The downloaded file must be a regular file on the same volume as
                // the user-visible URL (FileProvider header contract), so download
                // into the provider's own temporary directory.
                let downloader = FileProviderExtension.downloader(for: domain, client: client)
                let url = try await downloader.download(fetchRequest, authorization: auth)
                // Hand back the temp URL and the item; the system takes ownership
                // of the file.
                completionHandler(url, item, nil)
            } catch let error as RemoteError {
                completionHandler(nil, nil, error.asFileProviderError)
            } catch {
                completionHandler(nil, nil, error)
            }
        }
        return Progress()
    }

    /// A `ContentDownloader` that writes into the domain's provider temporary
    /// directory, so the hydrated file lands on the same volume as the
    /// user-visible URL (required by `fetchContents`). Falls back to the default
    /// temp directory if the manager is unavailable.
    private static func downloader(for domain: NSFileProviderDomain, client: RemoteClient) -> ContentDownloader {
        if let manager = NSFileProviderManager(for: domain),
           let tempDir = try? manager.temporaryDirectoryURL() {
            return ContentDownloader(client: client, destinationDirectory: tempDir)
        }
        return ContentDownloader(client: client)
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        // Phase 4, Task 4.4. Both backends now write then read back: a WebDAV
        // PUT/MKCOL returns no metadata body either way, so a Depth:0 PROPFIND
        // learns the server-assigned id and etag. They differ only in how the new
        // item is addressed — a path for Classic, `{parent oc:id}/{name}` for oCIS
        // (Task 4.5; the Graph create endpoints this used to call 404 on 8.2.0).
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

    /// oCIS create: `MKCOL`/`PUT` at `{parent oc:id}/{name}` returns no metadata
    /// body, so the new item is read back with a Depth:0 PROPFIND — the same shape
    /// as ``createItemClassic``. The read-back is addressed by *path* rather than by
    /// id because the server assigns the `oc:id`, which is not known until it is
    /// read; it is the one place oCIS addressing is name-based (Task 4.5).
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
        // Write first (create the collection, or stream the file bytes), discarding
        // the empty response.
        if isDirectory {
            _ = try await client.send(createRequest, authorization: auth)
        } else if let url {
            _ = try await uploader.uploadReturningBody(createRequest, fromFile: url, authorization: auth)
        } else {
            // A non-directory create with no contents is a zero-byte file.
            _ = try await client.send(createRequest, body: Data(), authorization: auth)
        }
        let body = try await client.send(
            connection.readBackNewItemRequest(parentID: parent, name: name), authorization: auth)
        guard let description = try connection.readBackItem(fromOCISPropfind: body) else {
            // The write succeeded but the read-back found nothing — a server-side
            // error, rather than reporting a bogus item.
            throw NSFileProviderError(.serverUnreachable)
        }
        return FileProviderItem(itemDescription: description)
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

    /// Rename and/or move an item: a WebDAV `MOVE` on both backends, differing only
    /// in the address — a path for Classic, the item's `oc:id` for oCIS (Task 4.5).
    /// The reparent target is only sent when `.parentItemIdentifier` actually
    /// changed, so a pure rename stays in place.
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
            _ = try await client.send(moveRequest, authorization: auth)
            // MOVE returns no body. The fileid survives a rename *and* a reparent
            // (verified live), so the item is read back at its unchanged `oc:id`.
            let body = try await client.send(
                connection.itemMetadataRequest(itemID: item.itemIdentifier.rawValue), authorization: auth)
            guard let description = try connection.readBackItem(fromOCISPropfind: body) else {
                throw NSFileProviderError(.serverUnreachable)
            }
            return FileProviderItem(itemDescription: description)
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

    /// oCIS content modify: a PUT at the item's `oc:id` returns no metadata body, so
    /// the item is read back for its new etag — mirroring ``modifyContentsClassic``,
    /// but addressed by id, and with no parent to supply (Task 4.5).
    private func modifyContentsOCIS(
        connection: BackendConnection,
        itemID: String,
        etag: String?,
        contents newContents: URL?
    ) async throws -> FileProviderItem {
        let modifyRequest = connection.modifyContentsRequest(itemID: itemID, ifMatchETag: etag)
        let uploader = ContentUploader(client: client)
        let auth = FileProviderExtension.authorization(for: account)
        if let newContents {
            _ = try await uploader.uploadReturningBody(modifyRequest, fromFile: newContents, authorization: auth)
        } else {
            _ = try await client.send(modifyRequest, body: Data(), authorization: auth)
        }
        let body = try await client.send(
            connection.itemMetadataRequest(itemID: itemID), authorization: auth)
        guard let description = try connection.readBackItem(fromOCISPropfind: body) else {
            throw NSFileProviderError(.serverUnreachable)
        }
        return FileProviderItem(itemDescription: description)
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
        //
        // The identifier may be one the framework reserves rather than a server id:
        // `.rootContainer`, `.workingSet` (its recents/favourites feed) or
        // `.trashContainer`. None of them addresses anything on either backend, so
        // `resolvedContainer` resolves them — the first two onto the space root, and
        // trash to `nil`, which this provider does not serve (its 404s were observed
        // live). See `ItemIdentifier.resolvedContainer` (Task 4.5).
        guard let container = ItemIdentifier(rawValue: containerItemIdentifier.rawValue).resolvedContainer else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        }
        let isRoot = container == .rootContainer
        let source = LazyRemoteEnumerationSource {
            let connection = try await self.makeConnection()
            return connection.enumerationSource(for: container)
        }
        // Task 7.7: a root-404 means the space vanished — disconnect the domain
        // (keeping downloaded files) rather than failing every operation forever.
        return ItemEnumerator(
            source: source,
            isRootContainer: isRoot,
            availabilityReactor: isRoot ? DomainDisconnector(domain: domain) : nil)
    }

    // MARK: Credentials

    /// The shared Keychain access group both the app's sign-in flow and this
    /// extension read credentials from. Matches the `keychain-access-groups`
    /// entitlement; the leading team prefix (`$(AppIdentifierPrefix)`) is applied
    /// automatically by the keychain for the app-group form used here.
    private static let keychainAccessGroup = "com.owncloud.macos.fileprovider.shared"

    /// The app group both the app and this extension are entitled to, holding the
    /// OIDC refresh parameters and the refresh lock file. Team-prefixed — see
    /// ``AppGroup`` for why the bare id silently denies *this* process the
    /// container while leaving the app working.
    private static let appGroup = AppGroup.identifier

    /// The `Authorization` header for this domain's account, read from the shared
    /// Keychain access group (Task 1.3 / 2.5). Returns `nil` when the account is
    /// unknown or no credentials are stored, so handlers fail cleanly with
    /// `.notAuthenticated` rather than sending unauthenticated requests.
    ///
    /// For an oCIS account the session is built **with** a refresh handler: oCIS
    /// access tokens carry `expires_in=300`, so without one the domain would stop
    /// working five minutes after sign-in (issue #17). The refresh parameters come
    /// from the app-group ``OIDCSessionStore`` the app wrote at sign-in — this
    /// process never ran OIDC discovery and so cannot know the token endpoint
    /// otherwise. The ``FileLock`` is per account: several extension instances may
    /// share one Keychain item, and without arbitration each would rotate the same
    /// refresh token and sign the others out (Task 7.6).
    ///
    /// A Classic account has no record, keeps the refresh-less path, and never
    /// touches the lock.
    private static func authorization(for account: AccountDescriptor?) -> String? {
        guard let account else { return nil }
        let store = KeychainCredentialStore(account: account, accessGroup: keychainAccessGroup)
        let session = makeSession(store: store, accountIdentifier: account.accountIdentifier)
        // Refresh a bearer token that is at/near expiry before building the
        // header; a no-op for Basic auth and when no refresh handler is wired.
        try? session.refreshTokenIfNeeded()
        return try? session.authorizationHeader()
    }

    private static func makeSession(store: CredentialStore, accountIdentifier: String) -> SessionManager {
        guard let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroup),
              let record = OIDCSessionStore(
                store: UserDefaultsKeyValueStore(defaults: UserDefaults(suiteName: appGroup) ?? .standard)
              ).record(forAccount: accountIdentifier)
        else {
            return SessionManager(store: store)
        }
        // The sender blocks; it runs under the lock, off the main thread.
        let sender = SynchronousTokenSender()
        return SessionManager(
            store: store,
            refresh: OIDCRefreshHandler.make(
                tokenEndpoint: record.tokenEndpoint,
                clientID: record.clientID,
                clientSecret: record.clientSecret,
                scope: record.scope,
                send: sender.send),
            refreshLock: FileLock(
                path: container.appendingPathComponent("refresh-\(accountIdentifier).lock").path))
    }
}

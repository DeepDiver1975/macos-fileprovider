import Foundation

/// Why drive resolution failed (Task 5.1, oCIS).
public enum DriveResolutionError: Error, Equatable {
    /// The `me/drives` listing carried no `driveType == "personal"` drive.
    case noPersonalDrive
}

/// Resolves which oCIS Graph drive a domain maps to. oCIS is ID-addressed, so the
/// `BackendConnection` needs a concrete `driveID`; at sign-in this lists the
/// user's drives (`GET /me/drives`) and picks the personal one. Pure aside from
/// the injected ``RemoteClient``, so it is unit-tested with a stub performer.
public struct DriveResolver {

    private let builder: GraphRequestBuilder
    private let client: RemoteClient
    private let decoder = GraphJSONDecoder()

    public init(serverURL: URL, client: RemoteClient) {
        self.builder = GraphRequestBuilder(baseURL: serverURL)
        self.client = client
    }

    /// The id of the user's personal drive, or throws ``DriveResolutionError/noPersonalDrive``.
    public func resolvePersonalDriveID(authorization: String?) async throws -> String {
        let data = try await client.send(builder.listDrives(), authorization: authorization)
        let drives = try decoder.decodeDriveList(data)
        guard let personal = GraphDrive.personalDrive(in: drives) else {
            throw DriveResolutionError.noPersonalDrive
        }
        return personal.id
    }
}

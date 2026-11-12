import Foundation
import OSLog

/// Immich client guide
///
/// The one place Otos speaks Immich's HTTP API (ADR 0046, `docs/research/2026-11-07-immich-api.md`).
/// It is a value over a server address and a `URLSession`, holds no state, and never
/// writes to the server: login and logout manage Otos's own session, and acks move
/// Otos's own sync cursor. Everything else is a read.
///
/// Errors are classified by their domain and code (ADR 0032 rule 4): a transport failure
/// is `unreachable`, an HTTP 401 is `unauthorized`, any other refusal its status.
nonisolated struct ImmichClient: Sendable {
    /// Immich's API changes break only across a major version (its upgrade policy), and
    /// the sync stream exists from 3.0 on. Otos speaks major 3 and refuses another by name.
    static let supportedMajorVersion = 3

    let server: URL
    let session: URLSession

    init(server: URL, session: URLSession = .shared) {
        self.server = server
        self.session = session
    }

    // MARK: - Session

    /// The server's version. Needs no login.
    func serverVersion() async throws -> ImmichServerVersion {
        let data = try await send(request("server/version", method: "GET"))
        return try decode(ImmichServerVersion.self, from: data)
    }

    /// Logs in with an email and password and returns the session it opened. The sync
    /// stream refuses API keys, so an account is added this way (research 2026-11-07).
    func login(email: String, password: String) async throws -> ImmichLogin {
        let body = try JSONEncoder().encode(["email": email, "password": password])
        let data = try await send(request("auth/login", method: "POST", body: body))
        let response = try decode(LoginResponse.self, from: data)
        return ImmichLogin(
            accessToken: response.accessToken,
            userID: response.userId,
            name: response.name,
            email: response.userEmail
        )
    }

    /// Ends `token`'s session on the server.
    func logout(token: String) async throws {
        _ = try await send(request("auth/logout", method: "POST", token: token))
    }

    // MARK: - Sync

    /// The types Otos syncs: owned assets and their EXIF (ADR 0046 §5: owned assets only).
    static let syncTypes = ["AssetsV2", "AssetExifsV1"]

    /// One pass of the session's sync stream, received whole into a temporary file at the
    /// network's pace, then parsed from it one JSON Line at a time, so a first sync of a
    /// large library never holds the whole stream in memory. The transfer never waits on
    /// the Store: a stream read straight from the connection as fast as the Store applies
    /// it stops being read whenever applying is slower than the server sends, and
    /// URLSession then times the request out (-1001) though the server is still sending
    /// (`docs/research/2026-11-13-immich-stream-slow-reader.md`). The file is deleted when
    /// the sequence is released.
    func syncEvents(token: String) async throws -> some AsyncSequence<ImmichSyncEvent, any Error> {
        var request = try request(
            "sync/stream", method: "POST", token: token,
            body: JSONEncoder().encode(["types": Self.syncTypes])
        )
        request.setValue("application/jsonlines+json", forHTTPHeaderField: "Accept")
        let file: URL
        let response: URLResponse
        do {
            (file, response) = try await session.download(for: request)
        } catch {
            throw ImmichClientError(transport: error)
        }
        let received = ReceivedDownload(file: file, op: "immich.sync")
        try Self.check(response)
        return received.file.lines.map { line in
            try withExtendedLifetime(received) {
                try ImmichSyncEvent(line: Data(line.utf8))
            }
        }
    }

    /// Moves the session's sync cursor past `acks` (each the `ack` of a line), so the next
    /// stream starts after them. Called only once the Store has applied those lines.
    func acknowledge(_ acks: [String], token: String) async throws {
        guard !acks.isEmpty else {
            return
        }
        let body = try JSONEncoder().encode(["acks": acks])
        _ = try await send(request("sync/ack", method: "POST", token: token, body: body))
    }

    // MARK: - Images

    /// Immich's own preview of an asset (`size=preview`): a JPEG at the server's
    /// configured size, orientation applied (`docs/research/2026-11-07-immich-derived-assets.md`).
    /// A read; the size and colour profile are whatever the file says.
    func preview(assetID: String, token: String) async throws -> Data {
        let endpoint = server.appending(path: "api").appending(path: "assets")
            .appending(path: assetID).appending(path: "thumbnail")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "size", value: "preview")]
        guard let url = components?.url else {
            throw ImmichClientError.malformedResponse
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    /// One asset's own facts (`GET /api/assets/{id}`): what a Live Photo's motion part is
    /// listed with when its own sync line was acknowledged in an earlier pass (ADR 0046
    /// §2). A read.
    func asset(id: String, token: String) async throws -> ImmichAssetDetail {
        let data = try await send(request("assets/\(id)", method: "GET", token: token))
        let body: AssetBody
        do {
            body = try JSONDecoder().decode(AssetBody.self, from: data)
        } catch {
            throw ImmichClientError.malformedResponse
        }
        guard let type = ImmichAsset.AssetType(rawValue: body.type) else {
            throw ImmichClientError.malformedResponse
        }
        return try ImmichAssetDetail(
            id: body.id,
            originalFileName: body.originalFileName,
            type: type,
            fileCreatedAt: Self.date(body.fileCreatedAt),
            fileModifiedAt: Self.date(body.fileModifiedAt),
            fileSize: body.exifInfo?.fileSizeInByte
        )
    }

    /// An ISO 8601 timestamp as Immich writes it, with fractional seconds.
    static func date(_ text: String) throws -> Date {
        do {
            return try Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        } catch {
            throw ImmichClientError.malformedResponse
        }
    }

    private struct AssetBody: Decodable {
        struct Exif: Decodable {
            let fileSizeInByte: Int64?
        }

        let id: String
        let originalFileName: String
        let type: String
        let fileCreatedAt: String
        let fileModifiedAt: String
        let exifInfo: Exif?
    }

    /// Downloads an asset's original to a temporary file the caller moves into place
    /// (ADR 0046 §4). A read.
    func downloadOriginal(assetID: String, token: String) async throws -> URL {
        var request = URLRequest(
            url: server.appending(path: "api").appending(path: "assets").appending(path: assetID)
                .appending(path: "original")
        )
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let file: URL
        let response: URLResponse
        do {
            (file, response) = try await session.download(for: request)
        } catch {
            throw ImmichClientError(transport: error)
        }
        do {
            try Self.check(response)
        } catch {
            // The body was an error page, not the original: it is not kept.
            Self.discardDownload(file, op: "immich.original")
            throw error
        }
        return file
    }

    /// Deletes one of URLSession's own temporary downloads, never anything of the user's:
    /// a file outside the temporary directory is left alone.
    static func discardDownload(_ file: URL, op: String) {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path(percentEncoded: false)
        guard file.standardizedFileURL.path(percentEncoded: false).hasPrefix(temporary) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: file)
        } catch where ErrorDiagnostics.isMissingFile(error) {
            // Already gone.
        } catch {
            OtosLog.mediaIO.errorOperation(op, phase: "cleanupFailed", fields: [
                "path": file.path(percentEncoded: false), "error": String(describing: error),
            ])
        }
    }

    /// A temporary download that lives as long as the sequence reading it: the last
    /// reference deletes the file, whether the read finished, failed or was abandoned.
    private final class ReceivedDownload: Sendable {
        let file: URL
        let op: String

        init(file: URL, op: String) {
            self.file = file
            self.op = op
        }

        deinit {
            ImmichClient.discardDownload(file, op: op)
        }
    }

    /// One byte range of an asset's original (`/original` honours `Range`, answering 206),
    /// completion-based for a byte source that blocks its own thread while it waits. A
    /// range past the end comes back clipped; the caller treats that as a short read.
    func originalRange(
        assetID: String,
        token: String,
        offset: UInt64,
        length: Int,
        completion: @escaping @Sendable (Result<Data, any Error>) -> Void
    ) {
        var request = URLRequest(
            url: server.appending(path: "api").appending(path: "assets").appending(path: assetID)
                .appending(path: "original")
        )
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("bytes=\(offset)-\(offset + UInt64(length) - 1)", forHTTPHeaderField: "Range")
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(ImmichClientError(transport: error)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(ImmichClientError.malformedResponse))
                return
            }
            switch http.statusCode {
            case 206:
                completion(.success(data ?? Data()))
            case 401:
                completion(.failure(ImmichClientError.unauthorized))
            default:
                // A 200 is the whole file, not the range asked for; anything else a refusal.
                completion(.failure(ImmichClientError.refused(status: http.statusCode)))
            }
        }.resume()
    }

    // MARK: - Transport

    private func request(_ path: String, method: String, token: String? = nil, body: Data? = nil) throws -> URLRequest {
        var request = URLRequest(url: server.appending(path: "api").appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ImmichClientError(transport: error)
        }
        try Self.check(response)
        return data
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ImmichClientError.malformedResponse
        }
        switch http.statusCode {
        case 200 ..< 300:
            return
        case 401:
            throw ImmichClientError.unauthorized
        default:
            throw ImmichClientError.refused(status: http.statusCode)
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ImmichClientError.malformedResponse
        }
    }

    private struct LoginResponse: Decodable {
        let accessToken: String
        let userId: String
        let userEmail: String
        let name: String
    }
}

/// Why a request to an Immich server did not succeed.
nonisolated enum ImmichClientError: Error, Equatable, Sendable {
    /// The request never reached a server that answered: no network, no route, a refused
    /// connection, a timeout. The server is unreachable now, which says nothing about the
    /// account.
    case unreachable(URLError.Code)
    /// The server refused the session: logged out, revoked, or a wrong password.
    case unauthorized
    /// The server answered with another failure status.
    case refused(status: Int)
    /// The server answered with something that is not Immich's API.
    case malformedResponse
    /// The server is an Immich whose major version Otos does not speak.
    case unsupportedVersion(major: Int)

    init(transport error: any Error) {
        if let error = error as? URLError {
            self = .unreachable(error.code)
        } else if let error = error as? ImmichClientError {
            self = error
        } else {
            self = .malformedResponse
        }
    }
}

nonisolated struct ImmichServerVersion: Decodable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
}

/// A session the server opened for one user.
nonisolated struct ImmichLogin: Equatable, Sendable {
    let accessToken: String
    let userID: String
    let name: String
    let email: String
}

/// An owned asset as `AssetV2` reports it, reduced to what Otos uses.
nonisolated struct ImmichAsset: Equatable, Sendable {
    enum AssetType: String, Sendable {
        case image = "IMAGE"
        case video = "VIDEO"
        case audio = "AUDIO"
        case other = "OTHER"
    }

    enum Visibility: String, Sendable {
        case timeline
        case archive
        /// A Live Photo's motion part, shown only through its still.
        case hidden
        /// The user's locked folder: never synced (ADR 0046 §5).
        case locked
    }

    let id: String
    let originalFileName: String
    let type: AssetType
    let visibility: Visibility
    /// In Immich's trash since then; nil when not trashed.
    let deletedAt: Date?
    let fileCreatedAt: Date?
    let fileModifiedAt: Date?
    /// A Live Photo still's motion part, an asset of its own (`visibility: hidden`).
    var livePhotoVideoID: String?
}

/// One asset's own facts, read on their own rather than from the sync stream.
nonisolated struct ImmichAssetDetail: Equatable, Sendable {
    let id: String
    let originalFileName: String
    let type: ImmichAsset.AssetType
    let fileCreatedAt: Date
    let fileModifiedAt: Date
    /// Nil until the server has read the file's size.
    let fileSize: Int64?
}

/// One line of the sync stream. Every line carries the `ack` that moves the cursor past it.
nonisolated enum ImmichSyncEvent: Equatable, Sendable {
    case asset(ImmichAsset, ack: String)
    /// The asset was deleted permanently: proof of deletion (ADR 0046 §1).
    case assetDeleted(assetID: String, ack: String)
    case exif(assetID: String, fileSize: Int64?, ack: String)
    /// The server has no history for this session's cursor: discard what was synced and
    /// sync everything again.
    case reset(ack: String)
    /// The pass is complete.
    case complete(ack: String)
    /// A line of a type Otos did not ask for; acknowledged and otherwise ignored.
    case unrequested(type: String, ack: String)

    var ack: String {
        switch self {
        case let .asset(_, ack), let .assetDeleted(_, ack), let .exif(_, _, ack), let .reset(ack),
             let .complete(ack), let .unrequested(_, ack):
            ack
        }
    }

    init(line: Data) throws {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: line)
        } catch {
            throw ImmichClientError.malformedResponse
        }
        let ack = envelope.ack
        switch envelope.type {
        case "AssetV2":
            let data = try Self.decode(AssetLine.self, line)
            guard let type = ImmichAsset.AssetType(rawValue: data.type),
                  let visibility = ImmichAsset.Visibility(rawValue: data.visibility)
            else {
                throw ImmichClientError.malformedResponse
            }
            self = try .asset(ImmichAsset(
                id: data.id,
                originalFileName: data.originalFileName,
                type: type,
                visibility: visibility,
                deletedAt: data.deletedAt.map(Self.date),
                fileCreatedAt: data.fileCreatedAt.map(Self.date),
                fileModifiedAt: data.fileModifiedAt.map(Self.date),
                livePhotoVideoID: data.livePhotoVideoId
            ), ack: ack)
        case "AssetDeleteV1":
            self = try .assetDeleted(assetID: Self.decode(DeleteLine.self, line).assetId, ack: ack)
        case "AssetExifV1":
            let data = try Self.decode(ExifLine.self, line)
            self = .exif(assetID: data.assetId, fileSize: data.fileSizeInByte, ack: ack)
        case "SyncResetV1":
            self = .reset(ack: ack)
        case "SyncCompleteV1":
            self = .complete(ack: ack)
        default:
            self = .unrequested(type: envelope.type, ack: ack)
        }
    }

    /// A line read for its type and ack; its `data` is decoded again by that type.
    private struct Envelope: Decodable {
        let type: String
        let ack: String
    }

    private struct Line<Payload: Decodable>: Decodable {
        let data: Payload
    }

    private struct AssetLine: Decodable {
        let id: String
        let originalFileName: String
        let type: String
        let visibility: String
        let deletedAt: String?
        let fileCreatedAt: String?
        let fileModifiedAt: String?
        let livePhotoVideoId: String?
    }

    private struct DeleteLine: Decodable {
        let assetId: String
    }

    private struct ExifLine: Decodable {
        let assetId: String
        let fileSizeInByte: Int64?
    }

    private static func decode<Payload: Decodable>(_ type: Payload.Type, _ line: Data) throws -> Payload {
        do {
            return try JSONDecoder().decode(Line<Payload>.self, from: line).data
        } catch {
            throw ImmichClientError.malformedResponse
        }
    }

    private static func date(_ text: String) throws -> Date {
        try ImmichClient.date(text)
    }
}

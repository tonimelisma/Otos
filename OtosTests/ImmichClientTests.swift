import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// Answers requests for one test's host, so tests running together never share a
/// handler.
final class ImmichStubProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest, Data?) throws -> (Int, Data)

    private static let handlers = Mutex<[String: Handler]>([:])

    static func session(host: String, _ handler: @escaping Handler) -> URLSession {
        handlers.withLock { $0[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImmichStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let host = request.url?.host ?? ""
        guard let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        do {
            let (status, body) = try handler(request, Self.body(of: request))
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// URLSession moves a body into a stream before the protocol sees it.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// The Immich HTTP client against a stubbed transport. Lines are shaped as Immich 3.3.6
/// sent them (`docs/research/2026-11-07-immich-api.md`).
struct ImmichClientTests {
    /// One line of the sync stream, as the server writes it.
    private static func line(_ type: String, _ data: [String: Any], ack: String) throws -> String {
        let object: [String: Any] = ["type": type, "data": data, "ack": ack]
        let data = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        return try #require(String(bytes: data, encoding: .utf8))
    }

    @Test func loginPostsTheCredentialsAndReturnsTheSession() async throws {
        let session = ImmichStubProtocol.session(host: "login.test") { request, body in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/auth/login")
            let sent = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: String]
            #expect(sent == ["email": "a@example.com", "password": "pw"])
            let reply = #"{"accessToken":"tok","userId":"u1","userEmail":"a@example.com","name":"A","isAdmin":false}"#
            return (201, Data(reply.utf8))
        }
        let client = try ImmichClient(server: #require(URL(string: "http://login.test")), session: session)
        let login = try await client.login(email: "a@example.com", password: "pw")
        #expect(login == ImmichLogin(accessToken: "tok", userID: "u1", name: "A", email: "a@example.com"))
    }

    @Test func failuresAreClassifiedByStatusAndTransportCode() async throws {
        let session = ImmichStubProtocol.session(host: "fail.test") { request, _ in
            switch request.url?.path {
            case "/api/auth/login": return (401, Data(#"{"message":"Incorrect email or password"}"#.utf8))
            case "/api/server/version": return (502, Data())
            default: throw URLError(.cannotConnectToHost)
            }
        }
        let client = try ImmichClient(server: #require(URL(string: "http://fail.test")), session: session)
        await #expect(throws: ImmichClientError.unauthorized) {
            try await client.login(email: "a", password: "b")
        }
        await #expect(throws: ImmichClientError.refused(status: 502)) {
            try await client.serverVersion()
        }
        await #expect(throws: ImmichClientError.unreachable(.cannotConnectToHost)) {
            try await client.acknowledge(["x"], token: "t")
        }
    }

    /// `GET /api/assets/{id}` decodes as Immich 3.3.6 writes an asset: a Live Photo's
    /// motion part, read on its own (ADR 0046 §2), which has no thumbhash: Immich makes no
    /// previews of a hidden asset.
    @Test func anAssetsOwnFactsDecode() async throws {
        let body: [String: Any] = [
            "id": "m1", "originalFileName": "IMG_1.MOV", "type": "VIDEO", "visibility": "hidden",
            "fileCreatedAt": "2025-06-13T00:48:36.603Z", "fileModifiedAt": "2026-01-01T00:00:00.000Z",
            "isTrashed": false, "livePhotoVideoId": NSNull(), "exifInfo": ["fileSizeInByte": 2_414_759, "make": NSNull()],
            "thumbhash": NSNull(),
        ]
        let reply = try JSONSerialization.data(withJSONObject: body)
        let session = ImmichStubProtocol.session(host: "asset.test") { request, _ in
            #expect(request.url?.path == "/api/assets/m1")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            return (200, reply)
        }
        let client = try ImmichClient(server: #require(URL(string: "http://asset.test")), session: session)
        let detail = try await client.asset(id: "m1", token: "tok")
        #expect(detail.id == "m1")
        #expect(detail.originalFileName == "IMG_1.MOV")
        #expect(detail.type == .video)
        #expect(detail.fileSize == 2_414_759)
        #expect(detail.fileModifiedAt == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(!detail.hasPreview)
    }

    @Test func theSyncStreamIsReadAsLines() async throws {
        let asset: [String: Any] = [
            "id": "24d2", "ownerId": "o", "originalFileName": "jpeg.jpg",
            "fileCreatedAt": "2025-06-13T00:48:36.603Z", "fileModifiedAt": "2026-01-01T00:00:00.000Z",
            "createdAt": "2026-11-08T03:41:01.872Z", "localDateTime": "2025-06-12T16:48:36.603Z",
            "type": "IMAGE", "deletedAt": NSNull(), "isFavorite": false, "visibility": "timeline",
            "duration": NSNull(), "livePhotoVideoId": NSNull(), "stackId": NSNull(), "libraryId": NSNull(),
            "width": 6192, "height": 4128, "isEdited": false, "checksum": "MDO/p/AKSxrbhRCQnjVUzGGH/i0=",
            "thumbhash": "HgkG",
        ]
        let lines = try [
            Self.line("AssetV2", asset, ack: "AssetV2|01"),
            Self.line(
                "AssetExifV1", ["assetId": "24d2", "fileSizeInByte": 5_099_275, "make": "SONY"], ack: "AssetExifV1|02"
            ),
            Self.line("AssetDeleteV1", ["assetId": "gone"], ack: "AssetDeleteV1|03"),
            Self.line("SyncCompleteV1", [:], ack: "SyncCompleteV1|04"),
        ]
        let session = ImmichStubProtocol.session(host: "sync.test") { request, body in
            #expect(request.url?.path == "/api/sync/stream")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/jsonlines+json")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            let sent = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: [String]]
            #expect(sent == ["types": ImmichClient.syncTypes])
            return (200, Data(lines.joined(separator: "\n").utf8))
        }
        let client = try ImmichClient(server: #require(URL(string: "http://sync.test")), session: session)
        var events: [ImmichSyncEvent] = []
        for try await event in try await client.syncEvents(token: "tok") {
            events.append(event)
        }
        #expect(events.count == 4)
        guard case let .asset(asset, ack) = events.first else {
            Issue.record("Expected an asset line first, got \(events)")
            return
        }
        #expect(ack == "AssetV2|01")
        #expect(asset.id == "24d2")
        #expect(asset.originalFileName == "jpeg.jpg")
        #expect(asset.type == .image)
        #expect(asset.visibility == .timeline)
        #expect(asset.deletedAt == nil)
        // Milliseconds parse to the nearest representable instant, not exactly.
        let created = try #require(asset.fileCreatedAt).timeIntervalSince1970
        #expect(abs(created - 1_749_775_716.603) < 0.001)
        #expect(asset.fileModifiedAt == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(asset.livePhotoVideoID == nil)
        #expect(asset.hasPreview)
        #expect(Array(events.dropFirst()) == [
            .exif(assetID: "24d2", fileSize: 5_099_275, ack: "AssetExifV1|02"),
            .assetDeleted(assetID: "gone", ack: "AssetDeleteV1|03"),
            .complete(ack: "SyncCompleteV1|04"),
        ])
    }

    /// The stream is received whole before a line of it is read, so reading it needs no
    /// connection: a Store slower than the server never leaves the transfer waiting until
    /// URLSession times it out. A refused stream is an error, never an empty one.
    @Test func theSyncStreamIsReceivedBeforeItIsRead() async throws {
        let lines = try (0 ..< 3).map { index in
            try Self.line("AssetDeleteV1", ["assetId": "gone\(index)"], ack: "AssetDeleteV1|\(index)")
        }
        let session = ImmichStubProtocol.session(host: "received.test") { request, _ in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer tok"
                ? (200, Data(lines.joined(separator: "\n").utf8))
                : (401, Data(#"{"message":"Invalid user token"}"#.utf8))
        }
        let client = try ImmichClient(server: #require(URL(string: "http://received.test")), session: session)
        let events = try await client.syncEvents(token: "tok")
        await #expect(throws: ImmichClientError.unauthorized) {
            _ = try await client.syncEvents(token: "revoked")
        }
        session.invalidateAndCancel()

        var deleted: [String] = []
        for try await case let .assetDeleted(assetID, _) in events {
            deleted.append(assetID)
        }
        #expect(deleted == ["gone0", "gone1", "gone2"])
    }

    @Test func acknowledgingPostsTheAcksAndNothingWhenThereAreNone() async throws {
        let posts = Mutex<[[String]]>([])
        let session = ImmichStubProtocol.session(host: "ack.test") { request, body in
            #expect(request.url?.path == "/api/sync/ack")
            let sent = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: [String]]
            posts.withLock { $0.append(sent?["acks"] ?? []) }
            return (204, Data())
        }
        let client = try ImmichClient(server: #require(URL(string: "http://ack.test")), session: session)
        try await client.acknowledge([], token: "tok")
        try await client.acknowledge(["AssetV2|01", "SyncCompleteV1|04"], token: "tok")
        #expect(posts.withLock { $0 } == [["AssetV2|01", "SyncCompleteV1|04"]])
    }

    @Test func aLineThatIsNotImmichsIsRefused() throws {
        #expect(throws: ImmichClientError.malformedResponse) {
            try ImmichSyncEvent(line: Data("not json".utf8))
        }
        let badDate = try Self.line("AssetV2", [
            "id": "a", "originalFileName": "a.jpg", "type": "IMAGE", "visibility": "timeline",
            "deletedAt": "yesterday",
        ], ack: "AssetV2|1")
        #expect(throws: ImmichClientError.malformedResponse) {
            try ImmichSyncEvent(line: Data(badDate.utf8))
        }
        let other = #"{"type":"PartnerV1","data":{},"ack":"PartnerV1|1"}"#
        #expect(try ImmichSyncEvent(line: Data(other.utf8)) == .unrequested(type: "PartnerV1", ack: "PartnerV1|1"))
    }

    /// The token round-trips through the Keychain under a service only this test uses,
    /// and the test removes its item.
    @Test func aSessionTokenRoundTripsThroughTheKeychain() throws {
        let store = ImmichKeychainSessionStore(service: "net.melisma.Otos.tests.immich-session.\(UUID().uuidString)")
        let account = DeviceIdentity(rawValue: "immich:https://photos.example.com#user-1")
        defer { try? store.deleteToken(for: account) }
        #expect(try store.token(for: account) == nil)
        try store.saveToken("first", for: account)
        try store.saveToken("second", for: account)
        #expect(try store.token(for: account) == "second")
        try store.deleteToken(for: account)
        #expect(try store.token(for: account) == nil)
    }
}

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

/// A transfer that answers its headers with one status and the first part of its body, then
/// holds the rest, as a large original does while it is still arriving: whatever settles the
/// read settles it at the headers or by cancelling. It records the `Range` asked for, and when the transfer was
/// started and stopped.
final class HeldTransfer: Sendable {
    private struct Facts {
        var range: String?
        var started = false
        var stopped = false
    }

    private static let transfers = Mutex<[String: HeldTransfer]>([:])
    private let status: Int
    private let facts = Mutex(Facts())

    init(status: Int) {
        self.status = status
    }

    var range: String? {
        facts.withLock(\.range)
    }

    var started: Bool {
        facts.withLock(\.started)
    }

    var stopped: Bool {
        facts.withLock(\.stopped)
    }

    /// A session whose every request to `host` is this transfer; each test names its own.
    func session(host: String) -> URLSession {
        Self.transfers.withLock { $0[host] = self }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldTransferProtocol.self]
        // The transfer is held on purpose until its test ends it. URLSession's idle timeout
        // (60 s) would otherwise race the test's own step under a loaded machine and end the
        // read as a server that did not answer: it did, 71 s into a parallel suite.
        configuration.timeoutIntervalForRequest = .greatestFiniteMagnitude
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        return URLSession(configuration: configuration)
    }

    fileprivate static func transfer(for request: URLRequest) -> HeldTransfer? {
        request.url?.host.flatMap { host in
            transfers.withLock { $0[host] }
        }
    }

    fileprivate func start(_ request: URLRequest) -> Int {
        facts.withLock {
            $0.range = request.value(forHTTPHeaderField: "Range")
            $0.started = true
        }
        return status
    }

    fileprivate func stop() {
        facts.withLock { $0.stopped = true }
    }
}

final class HeldTransferProtocol: URLProtocol {
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let transfer = HeldTransfer.transfer(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let status = transfer.start(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // The body's first part, then nothing more: URLSession hands a task its response
        // only once some body has arrived to sniff.
        client?.urlProtocol(self, didLoad: Data(repeating: 7, count: 4096))
    }

    override func stopLoading() {
        HeldTransfer.transfer(for: request)?.stop()
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

    // Validates: APP-063
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

    // Validates: APP-063, APP-065
    /// `GET /api/assets/{id}` decodes as Immich 3.3.6 writes an asset: a Live Photo's
    /// motion part, read on its own (ADR 0046 §2), which has no thumbhash: Immich makes no
    /// previews of a hidden asset.
    @Test func anAssetsOwnFactsDecode() async throws {
        let body: [String: Any] = [
            "id": "m1", "originalFileName": "IMG_1.MOV", "type": "VIDEO", "visibility": "hidden",
            "fileCreatedAt": "2025-06-13T00:48:36.603Z", "fileModifiedAt": "2026-01-01T00:00:00.000Z",
            "isTrashed": false, "livePhotoVideoId": NSNull(), "exifInfo": ["fileSizeInByte": 2_414_759, "make": NSNull()],
            "thumbhash": NSNull(), "originalPath": "/mnt/onedrive/Pictures/Camera Roll/2024/IMG_1.MOV",
            "libraryId": "lib-1", "checksum": "YSh/w9kgVtWGbzD5f2uUP5/HYag=",
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
        // An external library's asset: its checksum is of its server path, which it names.
        #expect(detail.originalPath == "/mnt/onedrive/Pictures/Camera Roll/2024/IMG_1.MOV")
        #expect(detail.contentDigest == nil)
        #expect(detail.pathChecksum == ImmichAsset.pathChecksum(checksum: "YSh/w9kgVtWGbzD5f2uUP5/HYag=", libraryID: "lib-1"))
    }

    // Validates: APP-063, APP-065
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
        let resets = Mutex<[Bool]>([])
        let session = ImmichStubProtocol.session(host: "sync.test") { request, body in
            #expect(request.url?.path == "/api/sync/stream")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/jsonlines+json")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            let sent = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
            #expect(sent?["types"] as? [String] == ImmichClient.syncTypes)
            resets.withLock { $0.append(sent?["reset"] as? Bool ?? false) }
            return (200, Data(lines.joined(separator: "\n").utf8))
        }
        let client = try ImmichClient(server: #require(URL(string: "http://sync.test")), session: session)
        var events: [ImmichSyncEvent] = []
        for try await event in try await client.syncEvents(token: "tok", fromZero: false) {
            events.append(event)
        }
        // A stream from zero asks the server to discard the cursor first.
        for try await _ in try await client.syncEvents(token: "tok", fromZero: true) {}
        #expect(resets.withLock { $0 } == [false, true])
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

    // Validates: APP-063
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
        let events = try await client.syncEvents(token: "tok", fromZero: false)
        await #expect(throws: ImmichClientError.unauthorized) {
            _ = try await client.syncEvents(token: "revoked", fromZero: false)
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
        #expect(try ImmichSyncEvent(line: Data(other.utf8)) == .ignored(type: "PartnerV1", ack: "PartnerV1|1"))
    }

    // Validates: APP-063
    /// An asset of a type or visibility this version does not know is one line ignored and
    /// acknowledged, never a stream that cannot be read: a newer server never stops a pass.
    @Test func anAssetOfAnUnknownKindIsIgnored() throws {
        for (type, visibility) in [("MODEL3D", "timeline"), ("IMAGE", "shared")] {
            let line = try Self.line("AssetV2", [
                "id": "a", "originalFileName": "a.jpg", "type": type, "visibility": visibility,
            ], ack: "AssetV2|9")
            #expect(try ImmichSyncEvent(line: Data(line.utf8)) == .ignored(type: "AssetV2", ack: "AssetV2|9"))
        }
    }

    /// The lines a full resync reads, as Immich 3.3 writes them (`server/src/utils/sync.ts`,
    /// `sync.service.ts` at v3.3.0, `docs/research/2026-11-14-immich-resync-against-3-3.md`):
    /// a stream the server resets is one `SyncResetV1` line acked `SyncResetV1|reset`, with
    /// no completion line after it; within `AssetsV2` the deletions come before the
    /// upserts; a trashed asset is still an `AssetV2` with its `deletedAt`; an audio asset
    /// is a line Otos reads and leaves out; an EXIF line without a size says so with null.
    @Test func aFullResyncsLinesDecodeAsImmich33WritesThem() async throws {
        let reset = #"{"type":"SyncResetV1","data":{},"ack":"SyncResetV1|reset"}"#
        let trashed: [String: Any] = [
            "id": "6f1c", "ownerId": "o", "originalFileName": "IMG_4821.HEIC", "thumbhash": "3OcRJYB4",
            "checksum": "q3xQ0C6Yh0m1Z8vK2bJw9sT4uE8=", "fileCreatedAt": "2024-06-01T14:03:22.000Z",
            "fileModifiedAt": "2024-06-01T14:03:22.000Z", "createdAt": "2024-06-02T08:11:45.123Z",
            "localDateTime": "2024-06-01T17:03:22.000Z", "type": "IMAGE", "deletedAt": "2026-11-01T09:00:00.000Z",
            "isFavorite": true, "visibility": "archive", "duration": NSNull(), "livePhotoVideoId": NSNull(),
            "stackId": NSNull(), "libraryId": NSNull(), "width": 4032, "height": 3024, "isEdited": false,
        ]
        var audio = trashed
        audio["id"] = "a0d1"
        audio["type"] = "AUDIO"
        audio["deletedAt"] = NSNull()
        let exif: [String: Any] = [
            "assetId": "6f1c", "description": "", "exifImageWidth": NSNull(), "exifImageHeight": NSNull(),
            "fileSizeInByte": NSNull(), "orientation": "6", "dateTimeOriginal": NSNull(), "modifyDate": NSNull(),
            "timeZone": NSNull(), "latitude": NSNull(), "longitude": NSNull(), "projectionType": NSNull(),
            "city": NSNull(), "state": NSNull(), "country": NSNull(), "make": NSNull(), "model": NSNull(),
            "lensModel": NSNull(), "fNumber": NSNull(), "focalLength": NSNull(), "iso": NSNull(),
            "exposureTime": NSNull(), "profileDescription": NSNull(), "rating": NSNull(), "fps": NSNull(),
        ]
        let fromZero = try [
            Self.line("AssetDeleteV1", ["assetId": "a2b3"], ack: "AssetDeleteV1|0190d3a3-0a1b"),
            Self.line("AssetV2", trashed, ack: "AssetV2|0190d3a2-7c41"),
            Self.line("AssetV2", audio, ack: "AssetV2|0190d3a2-7c42"),
            Self.line("AssetExifV1", exif, ack: "AssetExifV1|0190d3a2-7d02"),
            Self.line("SyncCompleteV1", [:], ack: "SyncCompleteV1|0190d3a4-1b2c"),
        ]
        let session = ImmichStubProtocol.session(host: "resync.test") { _, body in
            let sent = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
            let lines = sent?["reset"] as? Bool == true ? fromZero : [reset]
            return (200, Data(lines.joined(separator: "\n").utf8))
        }
        let client = try ImmichClient(server: #require(URL(string: "http://resync.test")), session: session)

        var resetStream: [ImmichSyncEvent] = []
        for try await event in try await client.syncEvents(token: "tok", fromZero: false) {
            resetStream.append(event)
        }
        #expect(resetStream == [.reset(ack: "SyncResetV1|reset")])

        var events: [ImmichSyncEvent] = []
        for try await event in try await client.syncEvents(token: "tok", fromZero: true) {
            events.append(event)
        }
        #expect(events.count == 5)
        #expect(events.first == .assetDeleted(assetID: "a2b3", ack: "AssetDeleteV1|0190d3a3-0a1b"))
        guard events.count == 5, case let .asset(asset, _) = events[1] else {
            Issue.record("Expected a trashed asset second, got \(events)")
            return
        }
        #expect(asset.visibility == .archive)
        #expect(asset.deletedAt == Date(timeIntervalSince1970: 1_793_523_600))
        #expect(asset.hasPreview)
        guard case let .asset(audioAsset, _) = events[2] else {
            Issue.record("Expected the audio asset third, got \(events)")
            return
        }
        #expect(audioAsset.type == .audio)
        #expect(Array(events.suffix(2)) == [
            .exif(assetID: "6f1c", fileSize: nil, ack: "AssetExifV1|0190d3a2-7d02"),
            .complete(ack: "SyncCompleteV1|0190d3a4-1b2c"),
        ])
    }

    // Validates: APP-066
    /// A ranged read's status is judged when its headers arrive: a server that ignores
    /// `Range` and starts sending the whole file (a 200) is refused at once, and its
    /// transfer cancelled before the body is received.
    @Test func aRangedReadAnsweredInFullIsRefusedAtItsHeaders() async throws {
        let transfer = HeldTransfer(status: 200)
        let client = try ImmichClient(
            server: #require(URL(string: "http://range-full.test")), session: transfer.session(host: "range-full.test")
        )
        let result = await withCheckedContinuation { (settled: CheckedContinuation<Result<Data, any Error>, Never>) in
            _ = client.originalRange(assetID: "a", token: "tok", offset: 0, length: 100) { settled.resume(returning: $0) }
        }
        #expect(throws: ImmichClientError.refused(status: 200)) { try result.get() }
        try await waitUntil { transfer.stopped }
        #expect(transfer.range == "bytes=0-99")
    }

    // Validates: APP-066
    /// A 206 is the range asked for: its body is the read.
    @Test func aRangedReadAnsweredPartiallyIsItsBody() async throws {
        let body = Data((0 ..< 100).map { UInt8($0) })
        let session = ImmichStubProtocol.session(host: "range-partial.test") { request, _ in
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=10-109")
            return (206, body)
        }
        let client = try ImmichClient(server: #require(URL(string: "http://range-partial.test")), session: session)
        let result = await withCheckedContinuation { (settled: CheckedContinuation<Result<Data, any Error>, Never>) in
            _ = client.originalRange(assetID: "a", token: "tok", offset: 10, length: 100) { settled.resume(returning: $0) }
        }
        #expect(try result.get() == body)
    }

    // Validates: APP-066
    /// A ranged read its caller stops waiting for is cancelled: its transfer ends, and it
    /// settles as cancellation, never as a server that did not answer.
    @Test func aRangedReadCanBeCancelled() async throws {
        let transfer = HeldTransfer(status: 206)
        let client = try ImmichClient(
            server: #require(URL(string: "http://range-cancel.test")), session: transfer.session(host: "range-cancel.test")
        )
        let result = await withCheckedContinuation { (settled: CheckedContinuation<Result<Data, any Error>, Never>) in
            let read = client.originalRange(assetID: "a", token: "tok", offset: 0, length: 100) {
                settled.resume(returning: $0)
            }
            Task {
                try await waitUntil { transfer.started }
                read.cancel()
            }
        }
        #expect(throws: CancellationError.self) { try result.get() }
        try await waitUntil { transfer.stopped }
    }

    // Validates: APP-063
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

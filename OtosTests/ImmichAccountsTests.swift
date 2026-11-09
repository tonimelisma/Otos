import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// ADR 0046 §5, §6: adding an account logs in and starts its sync; each account's
/// status is what its server last answered; forgetting one ends its session. The server
/// is a stubbed transport per test host; sessions live in memory.
@Suite(.testDirectory)
struct ImmichAccountsTests {
    private final class MemorySessions: ImmichSessionStoring, Sendable {
        private let tokens = Mutex<[DeviceIdentity: String]>([:])

        func saveToken(_ token: String, for account: DeviceIdentity) throws {
            tokens.withLock { $0[account] = token }
        }

        func token(for account: DeviceIdentity) throws -> String? {
            tokens.withLock { $0[account] }
        }

        func deleteToken(for account: DeviceIdentity) throws {
            _ = tokens.withLock { $0.removeValue(forKey: account) }
        }

        var all: [DeviceIdentity: String] {
            tokens.withLock { $0 }
        }
    }

    /// A server that answers like Immich 3.3.6, with one asset in its stream. `streams`
    /// scripts each sync request's status in turn; past the script it answers 200.
    private final class FakeServer: Sendable {
        let host: String
        private let streams: Mutex<[Int]>
        private let requests = Mutex<[String]>([])
        let major: Int

        init(host: String, streams: [Int] = [], major: Int = 3) {
            self.host = host
            self.streams = Mutex(streams)
            self.major = major
        }

        var paths: [String] {
            requests.withLock { $0 }
        }

        func session() -> URLSession {
            ImmichStubProtocol.session(host: host) { [self] request, body in
                let path = request.url?.path ?? ""
                requests.withLock { $0.append(path) }
                switch path {
                case "/api/server/version":
                    return (200, Data(#"{"major":\#(major),"minor":3,"patch":6}"#.utf8))
                case "/api/auth/login":
                    let sent = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: String]
                    guard sent?["password"] == "right" else {
                        return (401, Data(#"{"message":"Incorrect email or password"}"#.utf8))
                    }
                    let reply = #"{"accessToken":"tok","userId":"u1","userEmail":"a@example.com","name":"Family"}"#
                    return (201, Data(reply.utf8))
                case "/api/sync/stream":
                    let status = streams.withLock { $0.isEmpty ? 200 : $0.removeFirst() }
                    guard status == 200 else {
                        return (status, Data())
                    }
                    return (200, Data(Self.stream.utf8))
                case "/api/sync/ack", "/api/auth/logout":
                    return (204, Data())
                case "/api/assets/a1/original":
                    return (200, Self.original)
                case "/api/assets/silent/original":
                    throw URLError(.timedOut)
                default:
                    return (404, Data())
                }
            }
        }

        static let original = Data((0 ..< 4096).map { UInt8($0 % 251) })

        private static let stream: String = {
            let asset: [String: Any] = [
                "id": "a1", "originalFileName": "IMG_1.JPG", "type": "IMAGE", "visibility": "timeline",
                "deletedAt": NSNull(), "fileCreatedAt": "2026-01-01T00:00:00.000Z",
                "fileModifiedAt": "2026-01-01T00:00:00.000Z",
            ]
            let lines: [[String: Any]] = [
                ["type": "AssetV2", "data": asset, "ack": "AssetV2|1"],
                ["type": "AssetExifV1", "data": ["assetId": "a1", "fileSizeInByte": 42], "ack": "AssetExifV1|1"],
                ["type": "SyncCompleteV1", "data": [String: Any](), "ack": "SyncCompleteV1|1"],
            ]
            return lines.compactMap { line in
                (try? JSONSerialization.data(withJSONObject: line)).flatMap { String(bytes: $0, encoding: .utf8) }
            }.joined(separator: "\n")
        }()
    }

    private static let quick = ImmichAccounts.Schedule(poll: .seconds(3600), backoff: [.zero])

    private func makeStore() async throws -> CatalogStore {
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        return store
    }

    /// Reads statuses until `path`'s matches `expected`. The stream keeps only the newest
    /// dictionary and never repeats one, so each wait names a change still to come, or
    /// one condition over every account (`waitForStatuses`).
    private func waitForStatus(
        _ expected: ImmichAccountStatus,
        of path: LibraryRootPath,
        in accounts: ImmichAccounts
    ) async {
        await waitForStatuses(in: accounts) { $0[path] == expected }
    }

    private func waitForStatuses(
        in accounts: ImmichAccounts,
        until condition: ([LibraryRootPath: ImmichAccountStatus]) -> Bool
    ) async {
        for await statuses in accounts.statuses where condition(statuses) {
            return
        }
    }

    private func assetPaths(_ store: CatalogStore, _ rootPath: LibraryRootPath) async throws -> [String] {
        try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .library(rootPath)), availableLibraryPaths: [rootPath]
        ).ids.map(\.relativePath.rawValue)
    }

    @Test func addingAnAccountSavesItsSessionAndSyncsIt() async throws {
        let server = FakeServer(host: "add.test")
        let store = try await makeStore()
        let sessions = MemorySessions()
        let accounts = try ImmichAccounts(
            store: store, sessions: sessions, urlSession: server.session(), schedule: Self.quick,
            stagingContainer: makeTestDirectory()
        )

        let outcome = try await accounts.add(
            server: #require(URL(string: "http://add.test/")), email: "a@example.com", password: "right"
        )
        guard case let .added(rootPath) = outcome else {
            Issue.record("Expected the account added, got \(outcome)")
            return
        }
        await waitForStatus(.online, of: rootPath, in: accounts)
        #expect(try await assetPaths(store, rootPath) == ["a1/IMG_1.JPG"])
        #expect(Array(sessions.all.values) == ["tok"])
        let account = try #require(await store.currentLibraries().first { $0.path == rootPath })
        #expect(account.displayName == "Family")
        #expect(account.root.remoteBaseURL == URL(string: "http://add.test"))
        await accounts.shutdown()
        await store.shutdown()
    }

    @Test func aRefusedAddLeavesNoAccount() async throws {
        let store = try await makeStore()
        let sessions = MemorySessions()
        let wrong = FakeServer(host: "wrong.test")
        let old = FakeServer(host: "old.test", major: 2)
        let wrongAccounts = try ImmichAccounts(
            store: store, sessions: sessions, urlSession: wrong.session(), stagingContainer: makeTestDirectory()
        )
        let oldAccounts = try ImmichAccounts(
            store: store, sessions: sessions, urlSession: old.session(), stagingContainer: makeTestDirectory()
        )

        #expect(try await wrongAccounts.add(server: #require(URL(string: "http://wrong.test")), email: "a", password: "bad")
            == .wrongCredentials)
        #expect(try await oldAccounts.add(server: #require(URL(string: "http://old.test")), email: "a", password: "right")
            == .unsupportedVersion(major: 2))
        #expect(try await wrongAccounts.add(server: #require(URL(string: "http://nobody.test")), email: "a", password: "right")
            == .unreachable)
        #expect(try await wrongAccounts.add(server: #require(URL(string: "ftp://wrong.test")), email: "a", password: "right")
            == .invalidServer)
        #expect(await store.currentLibraries().isEmpty)
        #expect(sessions.all.isEmpty)
        await store.shutdown()
    }

    /// Offline is learned from a failed request and left on the next one that answers;
    /// a refused session is signed out.
    @Test func statusFollowsWhatTheServerLastAnswered() async throws {
        let server = FakeServer(host: "flaky.test", streams: [200, 503, 200, 401])
        let store = try await makeStore()
        // Nothing rings on its own: each pass here is asked for, so each status is read
        // before the next pass can replace it.
        let asked = ImmichAccounts.Schedule(poll: .seconds(3600), backoff: [.seconds(3600)])
        let accounts = try ImmichAccounts(
            store: store, sessions: MemorySessions(), urlSession: server.session(), schedule: asked,
            stagingContainer: makeTestDirectory()
        )
        guard case let .added(rootPath) = try await accounts.add(
            server: #require(URL(string: "http://flaky.test")), email: "a", password: "right"
        ) else {
            Issue.record("Expected the account added")
            return
        }
        await waitForStatus(.online, of: rootPath, in: accounts)
        await accounts.syncAll()
        await waitForStatus(.offline, of: rootPath, in: accounts)
        await accounts.syncAll()
        await waitForStatus(.online, of: rootPath, in: accounts)
        await accounts.syncAll()
        await waitForStatus(.signedOut, of: rootPath, in: accounts)
        #expect(try await assetPaths(store, rootPath) == ["a1/IMG_1.JPG"])
        await accounts.shutdown()
        await store.shutdown()
    }

    /// At launch, an account with a saved session syncs, and one without is signed out.
    @Test func startResumesSavedSessionsAndSignsOutTheRest() async throws {
        let server = FakeServer(host: "resume.test")
        let store = try await makeStore()
        let sessions = MemorySessions()
        let saved = try await store.addImmichAccount(
            server: #require(URL(string: "http://resume.test")), userID: "u1", displayName: "Saved",
            stagingContainer: makeTestDirectory()
        )
        let unsaved = try await store.addImmichAccount(
            server: #require(URL(string: "http://resume.test")), userID: "u2", displayName: "Unsaved",
            stagingContainer: makeTestDirectory()
        )
        let identity = try #require(await store.currentLibraries().first { $0.path == saved }?.root.deviceIdentity)
        try sessions.saveToken("tok", for: identity)
        let accounts = try ImmichAccounts(
            store: store, sessions: sessions, urlSession: server.session(), schedule: Self.quick,
            stagingContainer: makeTestDirectory()
        )

        await accounts.start()
        await waitForStatuses(in: accounts) { $0[saved] == .online && $0[unsaved] == .signedOut }
        #expect(try await assetPaths(store, saved) == ["a1/IMG_1.JPG"])
        await accounts.shutdown()
        await store.shutdown()
    }

    /// Forgetting an account logs its session out and deletes its Keychain item.
    @Test func forgettingAnAccountEndsItsSession() async throws {
        let server = FakeServer(host: "forget.test")
        let store = try await makeStore()
        let sessions = MemorySessions()
        let accounts = try ImmichAccounts(
            store: store, sessions: sessions, urlSession: server.session(), schedule: Self.quick,
            stagingContainer: makeTestDirectory()
        )
        guard case let .added(rootPath) = try await accounts.add(
            server: #require(URL(string: "http://forget.test")), email: "a", password: "right"
        ) else {
            Issue.record("Expected the account added")
            return
        }
        await waitForStatus(.online, of: rootPath, in: accounts)
        let root = try #require(await store.currentLibraries().first { $0.path == rootPath }?.root)

        await accounts.forget(root)
        #expect(sessions.all.isEmpty)
        #expect(server.paths.contains("/api/auth/logout"))
        #expect(try await store.removeLibrary(path: rootPath) == .removed)
        await accounts.shutdown()
        await store.shutdown()
    }

    /// The sheet's one footnote line says why an attempt failed, and only then.
    @Test func theSheetNamesEachFailure() {
        var sheet = ImmichAccountSheetState()
        #expect(sheet.failure == nil)
        let outcomes: [ImmichAddAccountOutcome] = [
            .invalidServer, .unreachable, .notImmich, .unsupportedVersion(major: 2), .wrongCredentials, .notSaved,
        ]
        var lines: Set<String> = []
        for outcome in outcomes {
            sheet.phase = .failed(outcome)
            lines.insert(sheet.failure ?? "")
        }
        #expect(lines.count == outcomes.count)
        #expect(!lines.contains(""))
        sheet.phase = .failed(.unsupportedVersion(major: 2))
        #expect(sheet.failure == "This server runs Immich 2. Otos works with Immich 3.")
        sheet.phase = .adding
        #expect(sheet.failure == nil)
        #expect(sheet.isAdding)
        #expect(sheet.title == "Add Immich Account")
        #expect(ImmichAccountSheetState(server: "http://nas.local", isSigningIn: true).actionTitle == "Sign In")
    }

    // MARK: - Originals (ADR 0046 §4, §7)

    /// The user's work downloads an original into the account's staging folder and offers
    /// it to enrichment for every product; background demand is refused, and a server that
    /// does not answer is reported as unavailable.
    @Test func anOriginalIsDownloadedOnlyForTheUsersWork() async throws {
        let server = FakeServer(host: "original.test")
        let store = try await makeStore()
        let accounts = try ImmichAccounts(
            store: store, sessions: MemorySessions(), urlSession: server.session(), schedule: Self.quick,
            stagingContainer: makeTestDirectory()
        )
        guard case let .added(rootPath) = try await accounts.add(
            server: #require(URL(string: "http://original.test")), email: "a", password: "right"
        ) else {
            Issue.record("Expected the account added")
            return
        }
        await waitForStatus(.online, of: rootPath, in: accounts)
        let id = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "a1/IMG_1.JPG"))
        func request(_ priority: MaterializationCoordinator.Priority) -> MaterializationCoordinator.Request {
            MaterializationCoordinator.Request(id: id, sourceSize: 42, isVideo: false, priority: priority)
        }

        #expect(await accounts.downloadOriginal(request(.background)).outcome == .requestFailed)
        #expect(!FileManager.default.fileExists(atPath: id.fileURL.path(percentEncoded: false)))

        #expect(await accounts.downloadOriginal(request(.interactive)).outcome == .materialized)
        #expect(FileManager.default.contents(atPath: id.fileURL.path(percentEncoded: false)) == FakeServer.original)
        // Offered ahead of other work, for every product it owes: a rendering, not just metadata.
        let offered = try await store.enrichmentCandidates(limit: 4)
        #expect(offered.map(\.asset.id) == [id])
        #expect(offered.first?.scope.contains(.rendering) == true)

        let missing = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "zz/NONE.JPG"))
        let refused = await accounts.downloadOriginal(
            MaterializationCoordinator.Request(id: missing, sourceSize: 1, isVideo: false, priority: .interactive)
        )
        #expect(refused.outcome == .requestFailed)

        // ADR 0046 §6: a server that does not answer is a state of the source, not a
        // provider failure, and is reported as one.
        let silent = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "silent/IMG_2.JPG"))
        let unanswered = await accounts.downloadOriginal(
            MaterializationCoordinator.Request(id: silent, sourceSize: 1, isVideo: false, priority: .interactive)
        )
        #expect(unanswered.outcome == .serverUnreachable)
        await accounts.shutdown()
        await store.shutdown()
    }

    @Test func onlyMetadataIsReadInRanges() {
        #expect(EnrichmentScope.metadata.isReadableInRanges)
        #expect(EnrichmentScope([.metadata, .provisionalThumbnail]).isReadableInRanges)
        #expect(!EnrichmentScope([.metadata, .rendering]).isReadableInRanges)
        #expect(!EnrichmentScope.hash.isReadableInRanges)
    }
}

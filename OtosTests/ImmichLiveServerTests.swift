import CoreGraphics
import Foundation
import ImageIO
import MediaMetadata
@testable import OtosKit
import Testing

/// Against a real, disposable Immich server: the release's own `docker-compose.yml` with no
/// machine-learning container, its test user's credentials made per run, and the stack
/// removed with its volumes afterwards (`docker compose down -v`). Runs only when
/// asked: `OTOS_IMMICH_LIVE` names a file of `IMMICH_URL=`, `IMMICH_EMAIL=` and
/// `IMMICH_PASSWORD=` lines, passed as a build setting the scheme substitutes:
///
///     xcodebuild test-without-building … -only-testing:OtosTests/ImmichLiveServerTests \
///         OTOS_IMMICH_LIVE=/path/to/test-credentials.env
///
/// The listing test writes nothing to the server's library. Its one server-side state is
/// the session it logs in with, and it logs that session out however the test ends. The
/// Live Photo test uploads a pair of its own, made unique so it can never be an asset the
/// server already had, and force-deletes exactly those two however it ends, confirming
/// the server no longer has them.
/// The live server's credentials, when a run asks for one.
enum ImmichLiveServer {
    struct Credentials {
        let server: URL
        let email: String
        let password: String
    }

    static let credentials: Credentials? = {
        guard let path = ProcessInfo.processInfo.environment["OTOS_IMMICH_LIVE"], !path.isEmpty,
              let bytes = FileManager.default.contents(atPath: path),
              let text = String(bytes: bytes, encoding: .utf8)
        else {
            return nil
        }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                values[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            }
        }
        guard let url = values["IMMICH_URL"].flatMap(URL.init(string:)), let email = values["IMMICH_EMAIL"],
              let password = values["IMMICH_PASSWORD"]
        else {
            return nil
        }
        return Credentials(server: url, email: email, password: password)
    }()
}

@Suite(.testDirectory, .enabled(if: ImmichLiveServer.credentials != nil))
struct ImmichLiveServerTests {
    /// A login and one pass bring every owned asset into an account's root, each with
    /// its EXIF size and a thumbnail from the server's preview; the session is logged out
    /// afterwards.
    @Test func aPassOverTheLiveServerListsItsAssets() async throws {
        let credentials = try #require(ImmichLiveServer.credentials)
        let client = ImmichClient(server: credentials.server)
        let version = try await client.serverVersion()
        #expect(version.major == ImmichClient.supportedMajorVersion)
        let login = try await client.login(email: credentials.email, password: credentials.password)
        let outcome: ImmichSyncPassOutcome
        let listed: [MediaAsset]
        do {
            let store = try CatalogStore(
                location: .databaseFile(makeTestDirectory().appending(path: "Catalog.sqlite")),
                scanCadence: .milliseconds(10)
            )
            try await store.start(scansSavedLibraries: false)
            let rootPath = try await store.addImmichAccount(
                server: credentials.server, userID: login.userID, displayName: login.name,
                stagingContainer: makeTestDirectory().appending(path: "RemoteStaging")
            )
            let sync = ImmichCatalogSync(
                rootPath: rootPath,
                source: ImmichSessionSyncSource(client: client, token: login.accessToken),
                store: store,
                volumeCapacity: ampleVolumeCapacity
            )
            outcome = await sync.pass()
            try await expectRangedMetadataRead(
                store: store, rootPath: rootPath, client: client, token: login.accessToken
            )
            let ids = try await store.orderedAssetIDs(
                for: CatalogQueryDescriptor(scope: .library(rootPath)), availableLibraryPaths: [rootPath]
            ).ids
            listed = try await Array(store.mediaAssets(for: ids).values)
            await store.shutdown()
        } catch {
            try await client.logout(token: login.accessToken)
            throw error
        }
        try await client.logout(token: login.accessToken)

        guard case let .synced(count, _, _) = outcome else {
            Issue.record("Expected a synced pass, got \(outcome)")
            return
        }
        #expect(count == listed.count)
        #expect(!listed.isEmpty)
        #expect(listed.allSatisfy { ($0.byteSize ?? 0) > 0 })
        // Each asset's grid thumbnail came from the server's own preview (ADR 0046 §7).
        #expect(listed.allSatisfy { $0.thumbnailPath != nil })
        await #expect(throws: ImmichClientError.unauthorized) {
            for try await _ in try await client.syncEvents(token: login.accessToken) {}
        }
    }

    /// The server answers ranged reads of an original, enough for MediaMetadata to read
    /// its format from a few chunks (ADR 0046 §5).
    private func expectRangedMetadataRead(
        store: CatalogStore,
        rootPath: LibraryRootPath,
        client: ImmichClient,
        token: String
    ) async throws {
        let first = try #require(try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .library(rootPath)), availableLibraryPaths: [rootPath]
        ).ids.first)
        let size = try #require(try await store.mediaAssets(for: [first])[first]?.byteSize)
        let assetID = try #require(try await store.sourceItemID(for: first))
        // The server's own facts for one asset decode as the sync reported them.
        let detail = try await client.asset(id: assetID, token: token)
        #expect(detail.id == assetID)
        #expect(detail.originalFileName == first.relativePath.fileName)
        #expect(detail.fileSize == size)
        let reader = RemoteRangeReader(size: UInt64(size)) { offset, length, completion in
            client.originalRange(
                assetID: assetID, token: token, offset: offset, length: length, completion: completion
            )
        }
        let parsed = await RemoteMetadataReader.read(reader, filenameHint: first.relativePath.rawValue)
        #expect(!parsed.outcome.shouldRetry)
        // The whole original downloads, at the size the sync reported (ADR 0046 §4).
        let downloaded = try await client.downloadOriginal(assetID: assetID, token: token)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let path = downloaded.path(percentEncoded: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.size] as? NSNumber)?.int64Value == size)
    }

    /// ADR 0046 §2: a Live Photo uploaded as Immich's mobile app uploads one — the motion
    /// part hidden, then the still naming it — is two rows in the still's folder, the motion
    /// named by its own asset ID.
    @Test func aLivePhotoOnTheLiveServerIsListedInItsStillsFolder() async throws {
        let credentials = try #require(ImmichLiveServer.credentials)
        let client = ImmichClient(server: credentials.server)
        let login = try await client.login(email: credentials.email, password: credentials.password)
        let token = login.accessToken
        let directory = try makeTestDirectory()
        var uploaded: [String] = []
        var failure: (any Error)?
        do {
            let movie = directory.appending(path: "LIVE_\(UUID().uuidString.prefix(8)).MOV")
            try Self.writeUniqueMovie(to: movie)
            let still = directory.appending(path: movie.deletingPathExtension().lastPathComponent + ".JPG")
            try Self.writeUniqueJPEG(to: still)
            let motionID = try await Self.upload(movie, hidden: true, linking: nil, server: credentials.server, token: token)
            uploaded.append(motionID)
            let stillID = try await Self.upload(still, hidden: false, linking: motionID, server: credentials.server, token: token)
            uploaded.append(stillID)

            let store = try CatalogStore(
                location: .databaseFile(directory.appending(path: "Catalog.sqlite")), scanCadence: .milliseconds(10)
            )
            try await store.start(scansSavedLibraries: false)
            let rootPath = try await store.addImmichAccount(
                server: credentials.server, userID: login.userID, displayName: login.name,
                stagingContainer: directory.appending(path: "RemoteStaging")
            )
            let sync = ImmichCatalogSync(
                rootPath: rootPath, source: ImmichSessionSyncSource(client: client, token: token), store: store,
                volumeCapacity: ampleVolumeCapacity
            )
            _ = await sync.pass()
            let paths = try await store.paths(ofSourceItems: [stillID, motionID], in: rootPath)
            #expect(paths[stillID]?.rawValue == "\(stillID)/\(still.lastPathComponent)")
            #expect(paths[motionID]?.rawValue == "\(stillID)/\(movie.lastPathComponent)")
            await store.shutdown()
        } catch {
            failure = error
        }
        try await Self.forceDelete(uploaded, server: credentials.server, token: token)
        // The server deletes in a job of its own and reports nothing when done, so the
        // removal is confirmed by asking until it refuses each asset (time: poll). Only its
        // refusal counts: a transport error is no proof of removal and fails the test.
        for id in uploaded {
            try await waitUntil(every: .milliseconds(250)) {
                do {
                    _ = try await client.asset(id: id, token: token)
                    return false
                } catch ImmichClientError.refused {
                    return true
                }
            }
        }
        try await client.logout(token: token)
        if let failure {
            throw failure
        }
    }

    /// A JPEG of random pixels, so its checksum is new to the server.
    private static func writeUniqueJPEG(to url: URL) throws {
        let width = 64, height = 48
        let pixels = (0 ..< width * height * 4).map { _ in UInt8.random(in: 0 ... 255) }
        let image = try #require(pixels.withUnsafeBytes { bytes -> CGImage? in
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        })
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
    }

    /// The fixture movie with a `free` box of random bytes after it: a valid movie whose
    /// checksum is new to the server.
    private static func writeUniqueMovie(to url: URL) throws {
        var data = try Data(contentsOf: SourceTree.mediaFixtures.appending(path: "mov-no-embedded-capture-date.mov"))
        let payload = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
        let size = UInt32(8 + payload.count)
        data.append(contentsOf: withUnsafeBytes(of: size.bigEndian, Array.init))
        data.append(contentsOf: Array("free".utf8))
        data.append(contentsOf: payload)
        try data.write(to: url)
    }

    /// Uploads a file as Immich's mobile app does (`POST /api/assets`), and returns its
    /// new ID. An upload the server reports as a duplicate is refused: deleting it would
    /// delete an asset the test did not make.
    private static func upload(
        _ file: URL,
        hidden: Bool,
        linking motionID: String?,
        server: URL,
        token: String
    ) async throws -> String {
        let boundary = "otos-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        let now = Date().formatted(.iso8601)
        field("fileCreatedAt", now)
        field("fileModifiedAt", now)
        field("filename", file.lastPathComponent)
        if hidden {
            field("visibility", "hidden")
        }
        if let motionID {
            field("livePhotoVideoId", motionID)
        }
        body.append(Data(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8
        ))
        try body.append(Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: server.appending(path: "api").appending(path: "assets"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        struct Created: Decodable {
            let id: String
            let status: String
        }
        let created = try JSONDecoder().decode(Created.self, from: data)
        try #require((response as? HTTPURLResponse)?.statusCode == 201 && created.status == "created")
        return created.id
    }

    /// Deletes the test's own uploads for good (`DELETE /api/assets`, `force`).
    private static func forceDelete(_ ids: [String], server: URL, token: String) async throws {
        guard !ids.isEmpty else {
            return
        }
        var request = URLRequest(url: server.appending(path: "api").appending(path: "assets"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ids": ids, "force": true])
        let (_, response) = try await URLSession.shared.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == 204)
    }
}

import Foundation
@testable import OtosKit
import Testing

/// Against a real, disposable Immich server (plan 0112, "Test server"). Runs only when
/// asked: `OTOS_IMMICH_LIVE` names a file of `IMMICH_URL=`, `IMMICH_EMAIL=` and
/// `IMMICH_PASSWORD=` lines, passed as a build setting the scheme substitutes:
///
///     xcodebuild test-without-building … -only-testing:OtosTests/ImmichLiveServerTests \
///         OTOS_IMMICH_LIVE=/path/to/test-credentials.env
///
/// The test writes nothing to the server's library. Its one server-side state is the
/// session it logs in with, and it logs that session out however the test ends.
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
    /// its EXIF size; the session is logged out afterwards.
    @Test func aPassOverTheLiveServerListsItsAssets() async throws {
        let credentials = try #require(ImmichLiveServer.credentials)
        let client = ImmichClient(server: credentials.server)
        let version = try await client.serverVersion()
        #expect(version.major == ImmichClient.supportedMajorVersion)
        let login = try await client.login(email: credentials.email, password: credentials.password)
        let outcome: ImmichSyncPassOutcome
        let listed: [MediaAsset]
        do {
            let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
            try await store.start(scansSavedLibraries: false)
            let rootPath = try await store.addImmichAccount(
                server: credentials.server, userID: login.userID, displayName: login.name,
                stagingContainer: makeTestDirectory().appending(path: "RemoteStaging")
            )
            let sync = ImmichCatalogSync(
                rootPath: rootPath,
                source: ImmichSessionSyncSource(client: client, token: login.accessToken),
                store: store
            )
            outcome = await sync.pass()
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
        await #expect(throws: ImmichClientError.unauthorized) {
            for try await _ in try await client.syncEvents(token: login.accessToken) {}
        }
    }
}

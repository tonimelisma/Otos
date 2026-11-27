import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// APP-097: the installed app updates itself, and an update never replaces the running app
/// while an import or a reorganization is in flight (ADR 0059, ADR 0030).
@Suite(.testScope)
@MainActor
struct AppUpdatesTests {
    /// Only the installed identity carrying the update key, outside a test host, updates.
    @Test func onlyTheInstalledBuildWithTheKeyUpdatesItself() {
        let key = "q1Wd5xZ2b3cV9mN0pL7kJ8hG6fD4sA2eR5tY1uI3oP0="
        #expect(AppUpdater.updatesItself(bundleIdentifier: "net.melisma.Otos", publicKey: key, environment: [:]))
        #expect(!AppUpdater.updatesItself(bundleIdentifier: "net.melisma.Otos.dev", publicKey: key, environment: [:]))
        #expect(!AppUpdater.updatesItself(bundleIdentifier: "net.melisma.Otos", publicKey: "", environment: [:]))
        #expect(!AppUpdater.updatesItself(bundleIdentifier: "net.melisma.Otos", publicKey: nil, environment: [:]))
        #expect(!AppUpdater.updatesItself(
            bundleIdentifier: "net.melisma.Otos",
            publicKey: key,
            environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]
        ))
    }

    /// A downloaded update waits while work is in flight and installs once, when none is.
    @Test func anInstallWaitsForTheWorkInFlightAndRunsOnce() async throws {
        let (answers, report) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let gate = UpdateInstallGate { answers }
        let installs = Counter()

        report.yield(true)
        gate.hold({ installs.add() }, version: "100")
        gate.hold({ installs.add() }, version: "101")
        #expect(gate.isHolding)
        #expect(installs.value == 0, "held while an import or a reorganization is in flight")

        #expect(gate.heldVersion == "101", "the version held is the newest handed over")

        report.yield(false)
        try await waitUntil { !gate.isHolding }
        #expect(installs.value == 1, "the newest held install, once")
        #expect(gate.heldVersion == nil, "an install that ran holds nothing")
    }

    /// App ▸ Check for Updates… always answers: Sparkle answers a check with nothing while its
    /// session is open, which it is for as long as Otos holds an update, so a held update is
    /// said first; with none held, the check is Sparkle's while it can check and the item is
    /// disabled while it cannot.
    @Test func checkForUpdatesAlwaysAnswers() {
        #expect(AppUpdater.checkAnswer(sparkleCanCheck: false, heldVersion: "1.0.9") == .showHeld(version: "1.0.9"))
        #expect(AppUpdater.checkAnswer(sparkleCanCheck: true, heldVersion: "1.0.9") == .showHeld(version: "1.0.9"))
        #expect(AppUpdater.checkAnswer(sparkleCanCheck: true, heldVersion: nil) == .check)
        #expect(AppUpdater.checkAnswer(sparkleCanCheck: false, heldVersion: nil) == .unavailable)
        #expect(AppUpdater.heldTitle(version: "1.0.9") == "Otos 1.0.9 Is Ready to Install")
    }

    /// The Store says when an import starts and when its journal is gone, from the journal
    /// write itself.
    @Test func theStoreReportsAnImportInFlightFromItsJournal() async throws {
        let temp = try makeTestDirectory()
        let sourceRoot = temp.appending(path: "Source", directoryHint: .isDirectory)
        let destinationRoot = temp.appending(path: "Destination", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let store = makeTestStore(location: .databaseFile(temp.appending(path: "db/catalog.sqlite")))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: sourceRoot)
        try await store.addLibrary(url: destinationRoot)

        var answers = await store.operationalWorkChanges().makeAsyncIterator()
        #expect(await answers.next() == false, "the open's answer: nothing in flight")

        let operation = try ActiveFileOperation(
            operationKey: .make(),
            sourceKind: .library,
            sourceDeviceIdentity: nil,
            sourceRootPath: CatalogPath.normalizedDirectoryPath(for: sourceRoot),
            sourceRelativePath: MediaRelativePath(rawValue: "source.jpg"),
            destinationRootPath: CatalogPath.normalizedDirectoryPath(for: destinationRoot),
            destinationRelativePath: MediaRelativePath(rawValue: "imported.jpg"),
            stagingURL: nil,
            companionStagingURLs: [],
            contentHash: nil,
            importBatch: ImportBatchID(unixMilliseconds: 1),
            sourceByteSize: 4,
            sourceModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            destinationModifiedAt: nil,
            phase: .copying,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        try await store.beginImportOperation(operation)
        #expect(await answers.next() == true)

        try await store.abandonImportOperation(key: operation.operationKey)
        #expect(await answers.next() == false)
    }
}

private final class Counter: Sendable {
    private let count = Mutex(0)

    var value: Int {
        count.withLock { $0 }
    }

    func add() {
        count.withLock { $0 += 1 }
    }
}

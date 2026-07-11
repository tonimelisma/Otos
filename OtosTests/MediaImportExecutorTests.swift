import Foundation
@testable import Otos
import Testing

struct ExclusivePublicationTests {
    @Test func publishesStagingToAbsentFinalOnAPFS() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let staging = temp.appending(path: ".stage.otos-import-staging")
        let final = temp.appending(path: "final.jpg")
        try Data([0x01, 0x02, 0x03]).write(to: staging)

        let outcome = ExclusivePublication.publish(staging: staging, final: final)
        #expect(outcome == .published)
        #expect(FileManager.default.fileExists(atPath: final.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func refusesOverwriteWhenFinalExists() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let staging = temp.appending(path: ".stage.otos-import-staging")
        let final = temp.appending(path: "final.jpg")
        try Data([0x01]).write(to: staging)
        try Data([0x02]).write(to: final)

        let outcome = ExclusivePublication.publish(staging: staging, final: final)
        #expect(outcome == .destinationExists)
        #expect(try Data(contentsOf: final) == Data([0x02]))
    }
}

struct CopyfileTransferTests {
    @Test func copiesBytesAndReportsCompletion() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let source = temp.appending(path: "source.bin")
        let destination = temp.appending(path: "dest.bin")
        let payload = Data(repeating: 0xAB, count: 64 * 1024)
        try payload.write(to: source)

        let outcome = CopyfileTransfer.copy(
            from: source,
            to: destination,
            onProgress: { _ in },
            shouldContinue: { true }
        )
        #expect(outcome == .completed)
        #expect(try Data(contentsOf: destination) == payload)
    }

    @Test func cancelRemovesPartialDestination() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let source = temp.appending(path: "source.bin")
        let destination = temp.appending(path: "dest.bin")
        try Data(repeating: 0xCD, count: 2 * 1024 * 1024).write(to: source)

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() -> Int {
                lock.lock()
                defer { lock.unlock() }
                value += 1
                return value
            }
        }
        let counter = Counter()
        let outcome = CopyfileTransfer.copy(
            from: source,
            to: destination,
            onProgress: { _ in },
            shouldContinue: {
                counter.increment() < 2
            }
        )
        #expect(outcome == .cancelled || outcome == .completed)
        if outcome == .cancelled {
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }
}

struct ActiveFileOperationJournalTests {
    @Test func journalRoundTripsThroughStore() async throws {
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)

        let operation = ActiveFileOperation(
            operationKey: .make(),
            mode: "import",
            sourceKind: .removableVolume,
            sourceDeviceIdentity: "volume:test",
            sourceRootPath: LibraryRootPath(rawValue: "/Volumes/CARD"),
            sourceRelativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
            destinationRootPath: LibraryRootPath(rawValue: "/Users/example/Pictures"),
            destinationRelativePath: MediaRelativePath(rawValue: "2026/07/IMG_1.JPG"),
            stagingPath: "/Users/example/Pictures/.tmp.otos-import-staging",
            importBatchUnixMs: 1_704_067_200_000,
            sourceByteSize: 100,
            sourceModifiedAt: Date(timeIntervalSince1970: 1000),
            destinationModifiedAt: Date(timeIntervalSince1970: 1000),
            phase: .copying,
            deleteSourceRequested: false,
            updatedAt: Date()
        )
        try await store.insertActiveFileOperation(operation)
        let loaded = try await store.fetchActiveFileOperations()
        #expect(loaded.count == 1)
        #expect(loaded.first?.operationKey == operation.operationKey)
        #expect(loaded.first?.phase == .copying)

        var updated = operation
        updated.phase = .readyToPublish
        updated.updatedAt = Date()
        try await store.updateActiveFileOperation(updated)
        let reloaded = try await store.fetchActiveFileOperations()
        #expect(reloaded.first?.phase == .readyToPublish)

        try await store.deleteActiveFileOperation(key: operation.operationKey)
        #expect(try await store.fetchActiveFileOperations().isEmpty)
    }
}

struct CameraImportAccessTests {
    @Test func mockGatewayRevalidatesAndReportsDeleteCapability() async throws {
        let access = CameraImportAccess(
            revalidate: { identity, path, size, _ in
                identity == "cam-1" && path.rawValue == "IMG_1.JPG" && size == 10
            },
            ensureBytes: { _, _, enrichment, staging in
                do {
                    let data = try Data(contentsOf: enrichment)
                    try data.write(to: staging)
                    return .completed
                } catch {
                    return .failed(String(describing: error))
                }
            },
            deleteItem: { _, _ in true },
            canDelete: { $0 == "cam-1" },
            eject: { _ in .ejected }
        )
        #expect(
            await access.revalidateItem(
                identity: "cam-1",
                relativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
                byteSize: 10,
                modifiedAt: nil
            )
        )
        #expect(await access.canDelete(identity: "cam-1"))
        #expect(await access.eject(identity: "cam-1") == .ejected)

        let temp = try makeCatalogStoreTemporaryDirectory()
        let enrichment = temp.appending(path: "enrich.bin")
        let staging = temp.appending(path: "stage.bin")
        try Data([0x01, 0x02]).write(to: enrichment)
        let result = await access.ensureImportBytes(
            identity: "cam-1",
            relativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
            enrichmentURL: enrichment,
            importStagingURL: staging
        )
        #expect(result == .completed)
        #expect(try Data(contentsOf: staging) == Data([0x01, 0x02]))
    }
}

struct VolumeRenameCapabilityTests {
    @Test func temporaryDirectoryReportsAKnownCapability() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let capability = VolumeRenameCapability.probe(url: temp)
        #expect(
            capability == .renameExcl
                || capability == .hardLink
                || capability == .checkThenAct
        )
    }
}

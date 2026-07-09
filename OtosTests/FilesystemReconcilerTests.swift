import CoreServices
import Foundation
@testable import Otos
import Testing

struct FilesystemReconcilerTests {
    private let root = LibraryRootPath(rawValue: "/tmp/otos-test-root")

    @Test func dropsWhenRootMissing() {
        let decision = FilesystemReconciler.decide(
            events: [fileEvent("a.jpg")],
            rootExists: false,
            isArmed: true,
            isAvailable: true,
            hasActiveScanForRoot: false
        )
        #expect(decision == .drop(reason: "removed"))
    }

    @Test func dropsWhenUnarmed() {
        let decision = FilesystemReconciler.decide(
            events: [fileEvent("a.jpg")],
            rootExists: true,
            isArmed: false,
            isAvailable: true,
            hasActiveScanForRoot: false
        )
        #expect(decision == .drop(reason: "unarmed"))
    }

    @Test func dropsWhenUnavailable() {
        let decision = FilesystemReconciler.decide(
            events: [fileEvent("a.jpg")],
            rootExists: true,
            isArmed: true,
            isAvailable: false,
            hasActiveScanForRoot: false
        )
        #expect(decision == .drop(reason: "unavailable"))
    }

    @Test func defersWhileRootScanActive() {
        let events = [fileEvent("a.jpg"), fileEvent("b.jpg")]
        let decision = FilesystemReconciler.decide(
            events: events,
            rootExists: true,
            isArmed: true,
            isAvailable: true,
            hasActiveScanForRoot: true
        )
        #expect(decision == .deferUntilScanCompletes(eventCount: 2))
    }

    @Test func noopForEmptyBatch() {
        let decision = FilesystemReconciler.decide(
            events: [],
            rootExists: true,
            isArmed: true,
            isAvailable: true,
            hasActiveScanForRoot: false
        )
        #expect(decision == .noop)
    }

    @Test func fullRootWhenAnyEventRequiresScan() {
        let events = [
            fileEvent("a.jpg", flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            FilesystemEvent(path: "\(root.rawValue)/subdir", flags: 0),
        ]
        let decision = FilesystemReconciler.decide(
            events: events,
            rootExists: true,
            isArmed: true,
            isAvailable: true,
            hasActiveScanForRoot: false
        )
        #expect(decision == .rescanRoot(eventCount: 2))
    }

    @Test func targetedWhenAllEventsAreSingleFile() {
        let events = [
            fileEvent(
                "a.jpg",
                flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
            ),
            fileEvent(
                "b.jpg",
                flags: UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)
            ),
        ]
        let decision = FilesystemReconciler.decide(
            events: events,
            rootExists: true,
            isArmed: true,
            isAvailable: true,
            hasActiveScanForRoot: false
        )
        #expect(decision == .targeted(events: events))
    }

    private func fileEvent(_ name: String, flags: UInt32 = 0) -> FilesystemEvent {
        FilesystemEvent(path: "\(root.rawValue)/\(name)", flags: flags)
    }
}

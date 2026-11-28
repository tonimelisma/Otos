import Foundation
@testable import OtosKit
import Testing

struct ScanLeaseControllerTests {
    private let pathA = LibraryRootPath(rawValue: "/tmp/scan-lease-a")
    private let pathB = LibraryRootPath(rawValue: "/tmp/scan-lease-b")

    private func knownRoots(_ paths: Set<LibraryRootPath>) -> (LibraryRootPath) -> Bool {
        { paths.contains($0) }
    }

    // Validates: ARC-003
    @Test func enqueueSkipsActiveAndDuplicatePendingPaths() {
        var controller = ScanLeaseController()
        let active = controller.makeActiveScan(rootPath: pathA, rootRowID: 1)
        controller.beginFilesystemScan(active, lane: .fixedLibraries)

        controller.enqueue([pathA, pathB], knownRoots: knownRoots([pathA, pathB]))
        #expect(controller.pendingScanPaths == [pathB])

        let clearedWhileActive = controller.clearFilesystemScan(active)
        #expect(clearedWhileActive?.needsRescan == false)
        controller.enqueue([pathA], knownRoots: knownRoots([pathA, pathB]))
        controller.enqueue([pathA], knownRoots: knownRoots([pathA, pathB]))
        #expect(controller.pendingScanPaths == [pathB, pathA])
    }

    @Test func enqueueFrontPriorityInsertsAtHead() {
        var controller = ScanLeaseController()
        controller.enqueue([pathA], knownRoots: knownRoots([pathA, pathB]))
        controller.enqueue([pathB], priority: .front, knownRoots: knownRoots([pathA, pathB]))
        #expect(controller.pendingScanPaths == [pathB, pathA])
    }

    @Test func ownsMatchesFilesystemAndDeviceLeases() {
        var controller = ScanLeaseController()
        let filesystemScan = controller.makeActiveScan(rootPath: pathA, rootRowID: 1)
        controller.beginFilesystemScan(filesystemScan, lane: .fixedLibraries)

        #expect(controller.owns(filesystemScan) { $0 == pathA && $1 == 1 })
        #expect(!controller.owns(filesystemScan) { $0 == pathA && $1 == 2 })

        let listingScan = controller.makeActiveScan(rootPath: pathB, rootRowID: 2)
        controller.beginListingScan(listingScan)
        #expect(controller.owns(listingScan) { $0 == pathB && $1 == 2 })
        #expect(!controller.owns(listingScan) { $0 == pathB && $1 == 3 })
    }

    @Test func cancelWorkClearsLeaseQueueAndDeferral() {
        var controller = ScanLeaseController()
        let active = controller.makeActiveScan(rootPath: pathA, rootRowID: 1)
        controller.beginFilesystemScan(active, lane: .fixedLibraries)
        controller.enqueue([pathA, pathB], knownRoots: knownRoots([pathA, pathB]))
        controller.markRescanAfterCurrentScan(pathA)

        let cancelled = controller.cancelWork(for: pathA)
        #expect(cancelled == .fixedLibraries)
        #expect(controller.activeScans.isEmpty)
        #expect(!controller.pendingScanPaths.contains(pathA))
        #expect(controller.pendingScanPaths == [pathB])
    }

    @Test func clearFilesystemScanReturnsDeferredRescanFlag() {
        var controller = ScanLeaseController()
        let scan = controller.makeActiveScan(rootPath: pathA, rootRowID: 1)
        controller.beginFilesystemScan(scan, lane: .fixedLibraries)
        controller.markRescanAfterCurrentScan(pathA)

        let cleared = controller.clearFilesystemScan(scan)
        #expect(cleared?.lane == .fixedLibraries)
        #expect(cleared?.needsRescan == true)
        #expect(controller.activeScans.isEmpty)
        let clearedAgain = controller.clearFilesystemScan(scan)
        #expect(clearedAgain == nil)
    }

    // Validates: APP-017
    /// A card is its own device: its scan starts while a library walk holds the fixed
    /// lane, and a second library waits behind the first.
    @Test func takeFirstPendingSkipsBusyLanesAndKeepsQueueOrder() {
        let card = LibraryRootPath(rawValue: "/tmp/scan-lease-card")
        var controller = ScanLeaseController()
        let library = controller.makeActiveScan(rootPath: pathA, rootRowID: 1)
        controller.beginFilesystemScan(library, lane: .fixedLibraries)
        controller.enqueue([pathB, card], knownRoots: knownRoots([pathA, pathB, card]))
        let lane: (LibraryRootPath) -> ScanLeaseController.ScanLane = {
            $0 == card ? .removableSource(card) : .fixedLibraries
        }

        let busyBeforeCard = Set(controller.activeScans.keys)
        let started = controller.takeFirstPending { !busyBeforeCard.contains(lane($0)) }

        #expect(started == card)
        #expect(controller.pendingScanPaths == [pathB])
        controller.beginFilesystemScan(controller.makeActiveScan(rootPath: card, rootRowID: 3), lane: .removableSource(card))
        #expect(controller.hasActiveFilesystemScan(for: card))
        #expect(controller.hasActiveFilesystemScan(for: pathA))
        let busyAfterCard = Set(controller.activeScans.keys)
        #expect(controller.takeFirstPending { !busyAfterCard.contains(lane($0)) } == nil)
    }
}

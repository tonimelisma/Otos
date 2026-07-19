import Foundation
@testable import Otos
import Testing

struct ScanLeaseControllerTests {
    private let pathA = LibraryRootPath(rawValue: "/tmp/scan-lease-a")
    private let pathB = LibraryRootPath(rawValue: "/tmp/scan-lease-b")

    private func knownRoots(_ paths: Set<LibraryRootPath>) -> (LibraryRootPath) -> Bool {
        { paths.contains($0) }
    }

    @Test func enqueueSkipsActiveAndDuplicatePendingPaths() {
        var controller = ScanLeaseController()
        let active = controller.makeActiveScan(rootPath: pathA, rootRowID: 1)
        controller.beginFilesystemScan(active)

        controller.enqueue([pathA, pathB], knownRoots: knownRoots([pathA, pathB]))
        #expect(controller.pendingScanPaths == [pathB])

        let clearedWhileActive = controller.clearFilesystemScan(active)
        #expect(clearedWhileActive == false)
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

    @Test func makeActiveScanIncrementsLeaseGeneration() {
        var controller = ScanLeaseController()
        let first = controller.makeActiveScan(rootPath: pathA, rootRowID: 1)
        let second = controller.makeActiveScan(rootPath: pathA, rootRowID: 1)
        #expect(first.leaseGeneration < second.leaseGeneration)
    }

    @Test func activeScanCapturesNamespaceMutationEpoch() {
        var controller = ScanLeaseController()
        let scan = controller.makeActiveScan(
            rootPath: pathA,
            rootRowID: 1,
            startNamespaceMutationEpoch: 7
        )
        #expect(scan.startNamespaceMutationEpoch == 7)
    }

    @Test func ownsMatchesFilesystemAndDeviceLeases() {
        var controller = ScanLeaseController()
        let filesystemScan = controller.makeActiveScan(rootPath: pathA, rootRowID: 1)
        controller.beginFilesystemScan(filesystemScan)

        #expect(controller.owns(filesystemScan) { $0 == pathA && $1 == 1 })
        #expect(!controller.owns(filesystemScan) { $0 == pathA && $1 == 2 })

        let deviceScan = controller.makeActiveScan(rootPath: pathB, rootRowID: 2)
        controller.beginDeviceScan(deviceScan)
        #expect(controller.owns(deviceScan) { $0 == pathB && $1 == 2 })
        #expect(!controller.owns(deviceScan) { $0 == pathB && $1 == 3 })
    }

    @Test func cancelWorkClearsLeaseQueueAndDeferral() {
        var controller = ScanLeaseController()
        let active = controller.makeActiveScan(rootPath: pathA, rootRowID: 1)
        controller.beginFilesystemScan(active)
        controller.enqueue([pathA, pathB], knownRoots: knownRoots([pathA, pathB]))
        controller.markRescanAfterCurrentScan(pathA)

        let cancelled = controller.cancelWork(for: pathA)
        #expect(cancelled)
        #expect(controller.activeScan == nil)
        #expect(!controller.pendingScanPaths.contains(pathA))
        #expect(controller.pendingScanPaths == [pathB])
    }

    @Test func clearFilesystemScanReturnsDeferredRescanFlag() {
        var controller = ScanLeaseController()
        let scan = controller.makeActiveScan(rootPath: pathA, rootRowID: 1)
        controller.beginFilesystemScan(scan)
        controller.markRescanAfterCurrentScan(pathA)

        let cleared = controller.clearFilesystemScan(scan)
        #expect(cleared)
        #expect(controller.activeScan == nil)
        let clearedAgain = controller.clearFilesystemScan(scan)
        #expect(!clearedAgain)
    }
}

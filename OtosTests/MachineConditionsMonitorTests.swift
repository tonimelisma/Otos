import Foundation
@testable import OtosKit
import Testing

/// The machine conditions monitor's reports arrive off the main thread (ADR 0057).
///
/// The memory-pressure source delivers its handler on a global queue. While the monitor was
/// a main-actor type, the handler it formed inherited the main actor, and Swift's check at the
/// closure's entry killed the process in `_dispatch_assert_queue_fail` on the first report the
/// source delivered: a session that launched under memory pressure, or met it later, crashed
/// when the level changed. These tests make the monitor and deliver each report from a
/// non-main thread, as the platform does; a monitor or report that claims the main actor again
/// either no longer compiles here or traps the test.
struct MachineConditionsMonitorTests {
    // Validates: ENR-033
    @Test func aMemoryPressureReportDeliveredOffTheMainThreadReachesTheRoom() async {
        let room = BackgroundRoom(conditions: .roomy)
        let monitor = MachineConditionsMonitor(room: room, storeUse: nil)

        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                #expect(!Thread.isMainThread)
                MachineConditionsMonitor.memoryPressureReported(.warning, room: room, storeUse: nil)
                continuation.resume()
            }
        }

        #expect(room.conditions.memory == .warning)
        withExtendedLifetime(monitor) {}
    }

    // Validates: ENR-033
    @Test func aPowerStateReportDeliveredOffTheMainThreadReachesTheRoom() async {
        var start = MachineConditions.roomy
        start.lowPower = !ProcessInfo.processInfo.isLowPowerModeEnabled
        let room = BackgroundRoom(conditions: start)
        let monitor = MachineConditionsMonitor(room: room, storeUse: nil)
        room.deliver(start)

        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                #expect(!Thread.isMainThread)
                // An observer registered with no queue runs on the posting thread.
                NotificationCenter.default.post(name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)
                continuation.resume()
            }
        }

        #expect(room.conditions.lowPower == ProcessInfo.processInfo.isLowPowerModeEnabled)
        withExtendedLifetime(monitor) {}
    }
}

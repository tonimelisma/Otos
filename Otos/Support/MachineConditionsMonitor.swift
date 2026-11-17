import AppKit
import Foundation

/// Machine conditions monitor guide (ADR 0057, ADR 0015)
///
/// The app's one listener to the platform's reports about room for background work, and
/// the one place they reach the `BackgroundRoom`: the system's memory-pressure source
/// (`DispatchSource.makeMemoryPressureSource`), the thermal state's and Low Power Mode's
/// notifications, and the app becoming and ceasing to be the active app. Each report updates
/// one field of the room's conditions in the step it arrives, on the thread it arrives on;
/// nothing samples, and nothing hops to another actor.
///
/// A memory-pressure report is also the session's checkpoint (`event=memoryPressure`) and
/// its `op=system.pressure phase=changed` line; `phase=launch` is the level at start, read
/// from the kernel (`kern.memorystatus_vm_pressure_level`), since the source reports only
/// changes. The room's conditions start from the same reading.
@MainActor
final class MachineConditionsMonitor {
    private let source: any DispatchSourceMemoryPressure
    private var observers: [NSObjectProtocol] = []

    init(room: BackgroundRoom, storeUse: (@Sendable () -> CatalogStoreUse)?) {
        let info = ProcessInfo.processInfo
        var launch = SystemPressure.kernelFields()
        let level = SystemPressure.kernelLevelName(launch["systemLevel"])
        launch["level"] = level
        launch["thermal"] = SystemPressure.thermalName(info.thermalState)
        launch["lowPower"] = "\(info.isLowPowerModeEnabled)"
        OtosLog.performance.noticeOperation("system.pressure", phase: "launch", fields: launch)
        room.update { conditions in
            conditions.memory = MachineConditions.Memory(rawValue: level) ?? .normal
            conditions.thermal = info.thermalState
            conditions.lowPower = info.isLowPowerModeEnabled
            conditions.userInApp = NSApp?.isActive ?? false
        }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .global(qos: .utility)
        )
        self.source = source
        source.setEventHandler { [weak source] in
            guard let event = source?.data else {
                return
            }
            let memory = Self.memory(event)
            var changed = SystemPressure.kernelFields()
            changed["level"] = memory.rawValue
            OtosLog.performance.noticeOperation("system.pressure", phase: "changed", fields: changed)
            ResourceCheckpoint.record("memoryPressure", fields: ["level": memory.rawValue], storeUse: storeUse)
            room.update { $0.memory = memory }
        }
        source.activate()

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { _ in
            let thermal = ProcessInfo.processInfo.thermalState
            room.update { $0.thermal = thermal }
        })
        observers.append(center.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: nil
        ) { _ in
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            room.update { $0.lowPower = lowPower }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { _ in
            room.update { $0.userInApp = true }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: nil
        ) { _ in
            room.update { $0.userInApp = false }
        })
    }

    isolated deinit {
        source.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    nonisolated static func memory(_ event: DispatchSource.MemoryPressureEvent) -> MachineConditions.Memory {
        if event.contains(.critical) {
            return .critical
        }
        if event.contains(.warning) {
            return .warning
        }
        return .normal
    }
}

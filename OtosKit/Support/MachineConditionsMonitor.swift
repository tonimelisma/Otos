import Foundation

/// Machine conditions monitor guide (ADR 0057, ADR 0015)
///
/// The app's one listener to the platform's reports about room for background work, and
/// the one place they reach the `BackgroundRoom`: the system's memory-pressure source
/// (`DispatchSource.makeMemoryPressureSource`) and the thermal state's and Low Power Mode's
/// notifications. Each report updates
/// one field of the room's conditions in the step it arrives, on the thread it arrives on;
/// nothing hops to another actor.
///
/// The type is `nonisolated`, and that is what makes each handler safe where the platform
/// runs it. The memory-pressure source delivers on a global queue, and its handler parameter
/// is a plain block: a closure formed in an actor-isolated context inherits that isolation,
/// and Swift checks it at the closure's entry, so a main-actor monitor trapped in
/// `_dispatch_assert_queue_fail` on the first report the source ever delivered. Here no
/// handler can claim an actor, and each is written `@Sendable` besides (SwiftLint
/// `dispatch_handler_claims_isolation`).
///
/// The memory-pressure source is a doorbell, not the level: on each report the room reads
/// the kernel's level (`kern.memorystatus_vm_pressure_level`) and holds that, since the
/// kernel tells the source of a change late, or not at all (ADR 0057). The room's first read
/// is the session's `op=system.pressure phase=launch` line, with the thermal state and Low
/// Power Mode beside it. A source report is also the session's checkpoint
/// (`event=memoryPressure`).
final nonisolated class MachineConditionsMonitor {
    private let source: any DispatchSourceMemoryPressure
    private var observers: [NSObjectProtocol] = []

    init(room: BackgroundRoom, storeUse: (@Sendable () -> CatalogStoreUse)?) {
        let info = ProcessInfo.processInfo
        room.update { conditions in
            conditions.thermal = info.thermalState
            conditions.lowPower = info.isLowPowerModeEnabled
        }
        room.readMemory(.launch, fields: [
            "thermal": SystemPressure.thermalName(info.thermalState),
            "lowPower": "\(info.isLowPowerModeEnabled)",
        ])

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .global(qos: .utility)
        )
        self.source = source
        source.setEventHandler { @Sendable [weak source] in
            guard let event = source?.data else {
                return
            }
            Self.memoryPressureReported(event, room: room, storeUse: storeUse)
        }
        source.activate()

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { @Sendable _ in
            let thermal = ProcessInfo.processInfo.thermalState
            room.update { $0.thermal = thermal }
        })
        observers.append(center.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: nil
        ) { @Sendable _ in
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            room.update { $0.lowPower = lowPower }
        })
    }

    deinit {
        source.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// One memory-pressure report, applied on whatever thread the source delivered it:
    /// checkpointed for the session, then rung at the room.
    static func memoryPressureReported(
        _ event: DispatchSource.MemoryPressureEvent,
        room: BackgroundRoom,
        storeUse: (@Sendable () -> CatalogStoreUse)?
    ) {
        let memory = memory(event)
        ResourceCheckpoint.record("memoryPressure", fields: ["level": memory.rawValue], storeUse: storeUse)
        room.sourceReported(memory)
    }

    static func memory(_ event: DispatchSource.MemoryPressureEvent) -> MachineConditions.Memory {
        if event.contains(.critical) {
            return .critical
        }
        if event.contains(.warning) {
            return .warning
        }
        return .normal
    }
}

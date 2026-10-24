import DiskArbitration
import Foundation
import OSLog

nonisolated struct RemovableVolumeAttachment: Equatable {
    let mountURL: URL
    let identity: String
    let displayName: String
    let isEjectable: Bool
    let capabilities: VolumeNamespaceCapabilities
    let deviceModel: String?
    let volumeFormat: String?

    init(
        mountURL: URL,
        identity: String,
        displayName: String,
        isEjectable: Bool,
        capabilities: VolumeNamespaceCapabilities = .unknown,
        deviceModel: String? = nil,
        volumeFormat: String? = nil
    ) {
        self.mountURL = mountURL
        self.identity = identity
        self.displayName = displayName
        self.isEjectable = isEjectable
        self.capabilities = capabilities
        self.deviceModel = deviceModel
        self.volumeFormat = volumeFormat
    }
}

/// What DiskArbitration says about one disk in a callback: the facts that match it to an
/// attached source.
nonisolated struct RemovableVolumeDisk: Equatable {
    let volumePath: String?
    let volumeUUID: String?
}

/// Removable volume monitor guide
///
/// Watches removable filesystems and reports source-level events. It stops at detection:
/// `CatalogStore` owns catalog roots, scan ordering, availability, and persistence; this
/// type translates platform reports into stable `volume:<uuid>` attachments, quiesce,
/// resume and detach.
///
/// DiskArbitration is the single source. Its appeared, description-changed (volume path),
/// unmount-approval and disappeared callbacks all arrive on one serial queue, and each
/// becomes one `Event` in one ordered stream, so a detach can never be handled before the
/// quiesce that preceded it. One loop consumes the stream: it enumerates mounted volumes
/// off the main actor when the set may have changed, then applies the event to
/// `RemovableVolumeTracker` synchronously and performs the tracker's effects. The loop
/// holds the monitor weakly and ends when the monitor is gone.
@MainActor
final class RemovableVolumeMonitor {
    nonisolated enum Event: Equatable {
        /// A disk appeared or a volume path changed: the mounted set may be different.
        case volumesChanged
        /// Someone asked to unmount this disk. DiskArbitration asks for approval of every
        /// unmount, Otos's own included, before it happens.
        case unmountRequested(RemovableVolumeDisk)
        case disappeared(RemovableVolumeDisk)
        case refusalLimitElapsed(identity: String, request: UInt64)
    }

    private let onAttach: @MainActor @Sendable (RemovableVolumeAttachment) -> Void
    private let onQuiesce: @MainActor @Sendable (String) -> Void
    private let onResume: @MainActor @Sendable (String) -> Void
    private let onDetach: @MainActor @Sendable (String, RemovableSourceDetachReason) -> Void

    private var tracker = RemovableVolumeTracker()
    private var events: AsyncStream<Event>.Continuation?
    private var diskArbitration: DiskArbitrationEvents?
    private var loop: Task<Void, Never>?
    private var refusalLimits: [String: Task<Void, Never>] = [:]

    init(
        onAttach: @escaping @MainActor @Sendable (RemovableVolumeAttachment) -> Void,
        onQuiesce: @escaping @MainActor @Sendable (String) -> Void,
        onResume: @escaping @MainActor @Sendable (String) -> Void,
        onDetach: @escaping @MainActor @Sendable (String, RemovableSourceDetachReason) -> Void
    ) {
        self.onAttach = onAttach
        self.onQuiesce = onQuiesce
        self.onResume = onResume
        self.onDetach = onDetach
    }

    func start() {
        guard loop == nil else {
            return
        }
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        events = continuation
        // The first enumeration does not wait for a disk to appear: a Mac with no
        // removable disk still has a current set, and it is empty.
        continuation.yield(.volumesChanged)
        diskArbitration = DiskArbitrationEvents(events: continuation)
        loop = Task { [weak self] in
            for await event in stream {
                // Off the main actor, and before the owner is upgraded: the enumeration
                // touches each volume. `nil` is a failed read, which changes nothing.
                let mounted: [RemovableVolumeAttachment]? = if event == .volumesChanged {
                    await Self.currentAttachments()
                } else {
                    nil
                }
                guard let self else {
                    return
                }
                apply(event, mounted: mounted)
            }
        }
    }

    func stop() {
        diskArbitration?.stop()
        diskArbitration = nil
        events?.finish()
        events = nil
        loop?.cancel()
        loop = nil
        for limit in refusalLimits.values {
            limit.cancel()
        }
        refusalLimits.removeAll()
        tracker = RemovableVolumeTracker()
    }

    private func apply(_ event: Event, mounted: [RemovableVolumeAttachment]?) {
        let effects: [RemovableVolumeTracker.Effect] = switch event {
        case .volumesChanged:
            mounted.map { tracker.reconcile($0) } ?? []
        case let .unmountRequested(disk):
            tracker.unmountRequested(disk)
        case let .disappeared(disk):
            tracker.disappeared(disk)
        case let .refusalLimitElapsed(identity, request):
            tracker.refusalLimitElapsed(identity: identity, request: request)
        }
        if case .volumesChanged = event, let mounted {
            OtosLog.fileAccess.noticeOperation("removableVolume.refresh", phase: "finish", fields: [
                "count": "\(mounted.count)",
            ])
        }
        for effect in effects {
            perform(effect)
        }
    }

    private func perform(_ effect: RemovableVolumeTracker.Effect) {
        switch effect {
        case let .attach(attachment):
            onAttach(attachment)
        case let .quiesce(identity):
            onQuiesce(identity)
        case let .resume(identity):
            refusalLimits.removeValue(forKey: identity)
            onResume(identity)
        case let .detach(identity, reason):
            refusalLimits.removeValue(forKey: identity)?.cancel()
            onDetach(identity, reason)
        case let .awaitRefusalLimit(identity, request):
            refusalLimits[identity]?.cancel()
            refusalLimits[identity] = Task { [events] in
                do {
                    // time: deadline — `unreportedUnmountRefusalLimit`: a refused unmount is reported to its caller alone
                    try await Task.sleep(for: Self.unreportedUnmountRefusalLimit)
                } catch {
                    return
                }
                events?.yield(.refusalLimitElapsed(identity: identity, request: request))
            }
        }
    }

    /// How long a source an unmount request quiesced waits for that unmount to finish
    /// before it resumes. This is a product decision, not a guess at a fact: an unmount
    /// another process asks for and the system then refuses as busy reports its refusal to
    /// that process alone. Measured on 2026-10-23 against a held file on a scratch volume,
    /// the refusal came 226 ms after the approval request, and nothing was delivered after
    /// it (`docs/research/2026-10-23-removable-and-camera-state-reports.md`). A success is
    /// a fact and detaches the source at once; only the refusal is waited out. Otos's own
    /// Eject knows its outcome and resumes without this limit.
    nonisolated static let unreportedUnmountRefusalLimit = Duration.seconds(2)

    nonisolated static func disambiguatedAttachments(
        _ attachments: [RemovableVolumeAttachment]
    ) -> [RemovableVolumeAttachment] {
        let grouped = Dictionary(grouping: attachments, by: \.identity)
        return attachments.map { attachment in
            guard let duplicates = grouped[attachment.identity],
                  duplicates.count > 1,
                  duplicates.first != attachment
            else {
                return attachment
            }
            let mountPath = normalizedMountPath(for: attachment.mountURL)
            return RemovableVolumeAttachment(
                mountURL: attachment.mountURL,
                identity: "\(attachment.identity)#path:\(mountPath)",
                displayName: attachment.displayName,
                isEjectable: attachment.isEjectable,
                capabilities: attachment.capabilities,
                deviceModel: attachment.deviceModel,
                volumeFormat: attachment.volumeFormat
            )
        }
    }

    private nonisolated static func normalizedMountPath(for url: URL) -> String {
        if let path = try? CatalogPath.normalizedDirectoryPath(for: url).rawValue {
            return path
        }
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// The removable physical volumes mounted now, or `nil` when the system does not
    /// answer — which is not an empty set, and must not detach anything.
    @concurrent
    private nonisolated static func currentAttachments() async -> [RemovableVolumeAttachment]? {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeUUIDStringKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeSupportsCaseSensitiveNamesKey,
            .volumeSupportsCasePreservedNamesKey,
            .volumeLocalizedFormatDescriptionKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            OtosLog.fileAccess.errorOperation("removableVolume.refresh", phase: "failed", fields: [
                "reason": "mountedVolumeURLsUnavailable",
            ])
            return nil
        }
        // One session for this whole refresh, not one per candidate volume —
        // there are typically 0-2 candidates per call.
        let session = DASessionCreate(kCFAllocatorDefault)
        let attachments = urls.compactMap { url -> RemovableVolumeAttachment? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRemovable == true,
                  isPhysicalRemovableDevice(deviceModel: deviceModel(forVolumeAt: url, session: session))
            else {
                return nil
            }
            let path = url.path(percentEncoded: false)
            let identity = values.volumeUUIDString.map { "volume:\($0)" } ?? "volume:path:\(path)"
            return RemovableVolumeAttachment(
                mountURL: url,
                identity: identity,
                displayName: values.volumeName ?? url.lastPathComponent,
                isEjectable: values.volumeIsEjectable == true,
                capabilities: FilesystemNamespaceSemantics.probeVolumeCapabilities(rootURL: url),
                deviceModel: deviceModel(forVolumeAt: url, session: session),
                volumeFormat: values.volumeLocalizedFormatDescription
            )
        }
        return disambiguatedAttachments(attachments)
            .sorted { left, right in
                left.identity.localizedStandardCompare(right.identity) == .orderedAscending
            }
    }

    /// Whether a `DiskArbitration` device-model fact proves a mounted volume
    /// is real removable hardware rather than a disk image.
    /// `URLResourceValues.volumeIsRemovable` alone cannot tell them apart —
    /// measured (`docs/research/2026-08-19-removable-volume-qualification.md`):
    /// both a read-write and a read-only mounted DMG report it `true` (plan
    /// 0095 D10; production evidence held `/Volumes/Raycast` and
    /// `/Volumes/BoltAI 2`, both app-installer DMGs, as permanent removable
    /// sources). `kDADiskDescriptionDeviceModelKey` — not
    /// `kDADiskDescriptionDeviceProtocolKey`, which reports the generic
    /// `"Virtual Interface"` for a disk image at every level of its disk
    /// object hierarchy and so cannot distinguish it from other virtual
    /// transports — is the fact that actually distinguishes them:
    /// `"Disk Image"` for any `hdiutil`-attached volume, the real hardware
    /// model (or vendor string) for physical media. Fails closed — no model
    /// at all is not proof of physical media, so it is rejected too, not
    /// accepted by default.
    nonisolated static func isPhysicalRemovableDevice(deviceModel: String?) -> Bool {
        guard let deviceModel, !deviceModel.isEmpty else {
            return false
        }
        return deviceModel != "Disk Image"
    }

    /// `kDADiskDescriptionDeviceModelKey` for the volume mounted at `url`, or
    /// `nil` if `url` is not currently a mounted volume root or
    /// `DiskArbitration` has no answer. The migration in
    /// `CatalogStorePersistence.swift` that removes already-persisted
    /// disk-image roots reuses this rather than re-deriving it.
    nonisolated static func deviceModel(forVolumeAt url: URL, session: DASession?) -> String? {
        guard let session,
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else {
            return nil
        }
        return description[kDADiskDescriptionDeviceModelKey as String] as? String
    }
}

/// The monitor's state and decisions, with no platform in it: each report in, the
/// effects out. The monitor's loop is its only caller, one event at a time.
nonisolated struct RemovableVolumeTracker {
    enum Effect: Equatable {
        case attach(RemovableVolumeAttachment)
        case quiesce(String)
        case resume(String)
        case detach(String, RemovableSourceDetachReason)
        /// Start the refusal limit for this unmount request; when it elapses the monitor
        /// reports `refusalLimitElapsed` with the same request number.
        case awaitRefusalLimit(identity: String, request: UInt64)
    }

    private(set) var attachmentsByIdentity: [String: RemovableVolumeAttachment] = [:]
    /// The latest unmount request per quiesced source. A request is a revision: a limit
    /// started for an older request never resumes a source a newer request quiesced.
    private var pendingUnmount: [String: UInt64] = [:]
    private var requests: UInt64 = 0

    mutating func reconcile(_ mounted: [RemovableVolumeAttachment]) -> [Effect] {
        let next = Dictionary(mounted.map { ($0.identity, $0) }) { first, _ in first }
        var effects: [Effect] = []
        for identity in attachmentsByIdentity.keys.sorted() where next[identity] == nil {
            pendingUnmount.removeValue(forKey: identity)
            effects.append(.detach(identity, .unmounted))
        }
        for attachment in mounted where attachmentsByIdentity[attachment.identity] != attachment {
            effects.append(.attach(attachment))
        }
        attachmentsByIdentity = next
        return effects
    }

    mutating func unmountRequested(_ disk: RemovableVolumeDisk) -> [Effect] {
        guard let identity = identity(matching: disk) else {
            return []
        }
        requests &+= 1
        pendingUnmount[identity] = requests
        return [.quiesce(identity), .awaitRefusalLimit(identity: identity, request: requests)]
    }

    mutating func disappeared(_ disk: RemovableVolumeDisk) -> [Effect] {
        guard let identity = identity(matching: disk) else {
            return []
        }
        attachmentsByIdentity.removeValue(forKey: identity)
        pendingUnmount.removeValue(forKey: identity)
        return [.detach(identity, .disconnected)]
    }

    /// The source is still mounted when the limit elapses, so the unmount was refused:
    /// resume it — unless it detached meanwhile, or a newer request quiesced it again.
    mutating func refusalLimitElapsed(identity: String, request: UInt64) -> [Effect] {
        guard pendingUnmount[identity] == request, attachmentsByIdentity[identity] != nil else {
            return []
        }
        pendingUnmount.removeValue(forKey: identity)
        return [.resume(identity)]
    }

    private func identity(matching disk: RemovableVolumeDisk) -> String? {
        if let volumeUUID = disk.volumeUUID {
            let identity = "volume:\(volumeUUID)"
            if attachmentsByIdentity[identity] != nil {
                return identity
            }
        }
        if let volumePath = disk.volumePath.map(Self.mountPathKey) {
            return attachmentsByIdentity.first { _, attachment in
                Self.mountPathKey(attachment.mountURL.path(percentEncoded: false)) == volumePath
            }?.key
        }
        return nil
    }

    /// A mount path compared without its trailing slash: DiskArbitration and
    /// `mountedVolumeURLs` both hand out directory URLs, whose path keeps one, and a
    /// path given as text may not.
    private static func mountPathKey(_ path: String) -> String {
        var key = path
        while key.count > 1, key.hasSuffix("/") {
            key.removeLast()
        }
        return key
    }
}

/// The DiskArbitration session. Every callback runs on `queue`, one serial queue, and
/// only yields into the monitor's stream: the order DiskArbitration reports in is the
/// order the monitor applies.
private final nonisolated class DiskArbitrationEvents {
    private let session: DASession
    private let queue = DispatchQueue(label: "net.melisma.Otos.removable-disk-arbitration")
    private let context: UnsafeMutableRawPointer
    private var isStopped = false

    init?(events: AsyncStream<RemovableVolumeMonitor.Event>.Continuation) {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            OtosLog.fileAccess.errorOperation("removableVolume.diskArbitration", phase: "failed", fields: [
                "reason": "sessionUnavailable",
            ])
            return nil
        }
        self.session = session
        context = Unmanaged.passRetained(DiskArbitrationContext(events: events)).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, diskAppeared, context)
        DARegisterDiskDescriptionChangedCallback(
            session,
            nil,
            [kDADiskDescriptionVolumePathKey] as CFArray,
            diskDescriptionChanged,
            context
        )
        DARegisterDiskUnmountApprovalCallback(session, nil, diskUnmountApproval, context)
        DARegisterDiskDisappearedCallback(session, nil, diskDisappeared, context)
        DASessionSetDispatchQueue(session, queue)
    }

    deinit {
        stop()
    }

    func stop() {
        guard !isStopped else {
            return
        }
        isStopped = true
        queue.sync {
            for callback in [
                unsafeBitCast(diskAppeared as DADiskAppearedCallback, to: UnsafeMutableRawPointer.self),
                unsafeBitCast(diskDescriptionChanged as DADiskDescriptionChangedCallback, to: UnsafeMutableRawPointer.self),
                unsafeBitCast(diskUnmountApproval as DADiskUnmountApprovalCallback, to: UnsafeMutableRawPointer.self),
                unsafeBitCast(diskDisappeared as DADiskDisappearedCallback, to: UnsafeMutableRawPointer.self),
            ] {
                DAUnregisterCallback(session, callback, context)
            }
            DASessionSetDispatchQueue(session, nil)
        }
        Unmanaged<DiskArbitrationContext>.fromOpaque(context).release()
    }
}

private final nonisolated class DiskArbitrationContext {
    let events: AsyncStream<RemovableVolumeMonitor.Event>.Continuation

    init(events: AsyncStream<RemovableVolumeMonitor.Event>.Continuation) {
        self.events = events
    }

    static func from(_ pointer: UnsafeMutableRawPointer?) -> DiskArbitrationContext? {
        pointer.map { Unmanaged<DiskArbitrationContext>.fromOpaque($0).takeUnretainedValue() }
    }

    /// The disk's volume path and UUID from its description. The UUID is a `CFUUID`,
    /// not a Foundation `UUID`, and is rendered the way `volumeUUIDString` renders it.
    static func disk(_ disk: DADisk) -> RemovableVolumeDisk {
        let description = DADiskCopyDescription(disk) as? [String: Any]
        let path = (description?[kDADiskDescriptionVolumePathKey as String] as? URL)?.path(percentEncoded: false)
        var uuid: String?
        if let value = description?[kDADiskDescriptionVolumeUUIDKey as String] {
            let reference = value as CFTypeRef
            if CFGetTypeID(reference) == CFUUIDGetTypeID() {
                uuid = CFUUIDCreateString(kCFAllocatorDefault, unsafeBitCast(reference, to: CFUUID.self)) as String
            }
        }
        return RemovableVolumeDisk(volumePath: path, volumeUUID: uuid)
    }
}

private nonisolated func diskAppeared(_: DADisk, _ context: UnsafeMutableRawPointer?) {
    DiskArbitrationContext.from(context)?.events.yield(.volumesChanged)
}

private nonisolated func diskDescriptionChanged(_: DADisk, _: CFArray, _ context: UnsafeMutableRawPointer?) {
    DiskArbitrationContext.from(context)?.events.yield(.volumesChanged)
}

private nonisolated func diskUnmountApproval(
    _ disk: DADisk,
    _ context: UnsafeMutableRawPointer?
) -> Unmanaged<DADissenter>? {
    DiskArbitrationContext.from(context)?.events.yield(.unmountRequested(DiskArbitrationContext.disk(disk)))
    // Otos never dissents: the request is reported so the source can quiesce.
    return nil
}

private nonisolated func diskDisappeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    DiskArbitrationContext.from(context)?.events.yield(.disappeared(DiskArbitrationContext.disk(disk)))
}

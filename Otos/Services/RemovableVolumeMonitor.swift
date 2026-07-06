import AppKit
import DiskArbitration
import Foundation
import OSLog

nonisolated struct RemovableVolumeAttachment: Equatable {
    let mountURL: URL
    let identity: String
    let displayName: String
    let isEjectable: Bool
}

nonisolated struct RemovableVolumeDetachedDisk {
    let volumePath: String?
    let volumeUUID: String?
}

/// Watches foreground removable filesystems and reports source-level events.
///
/// The monitor deliberately stops at detection. `CatalogStore` owns catalog roots,
/// scan ordering, availability, and persistence; this service only translates
/// platform signals into stable `volume:<uuid>` attachments and detach notices.
@MainActor
final class RemovableVolumeMonitor {
    private let notificationCenter: NotificationCenter
    private let onAttach: @MainActor @Sendable (RemovableVolumeAttachment) -> Void
    private let onDetach: @MainActor @Sendable (String, RemovableSourceDetachReason) -> Void

    private var observers: [NSObjectProtocol] = []
    private var attachmentsByIdentity: [String: RemovableVolumeAttachment] = [:]
    private var diskMonitor: RemovableDiskDisappearanceMonitor?
    private var isStarted = false

    init(
        workspace: NSWorkspace = .shared,
        onAttach: @escaping @MainActor @Sendable (RemovableVolumeAttachment) -> Void,
        onDetach: @escaping @MainActor @Sendable (String, RemovableSourceDetachReason) -> Void
    ) {
        notificationCenter = workspace.notificationCenter
        self.onAttach = onAttach
        self.onDetach = onDetach
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        installObservers()
        diskMonitor = RemovableDiskDisappearanceMonitor { [weak self] disk in
            self?.detach(matching: disk, reason: .disconnected)
        }
        refresh(reason: "initial")
    }

    func stop() {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        diskMonitor = nil
        attachmentsByIdentity.removeAll()
        isStarted = false
    }

    private func installObservers() {
        let didMount = notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(reason: "didMount")
            }
        }
        let willUnmount = notificationCenter.addObserver(
            forName: NSWorkspace.willUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let volumePath = notification.userInfo?["NSDevicePath"] as? String
            Task { @MainActor in
                self?.detach(
                    matching: RemovableVolumeDetachedDisk(
                        volumePath: volumePath,
                        volumeUUID: nil
                    ),
                    reason: .unmounted
                )
            }
        }
        let didUnmount = notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let volumePath = notification.userInfo?["NSDevicePath"] as? String
            Task { @MainActor in
                self?.detach(
                    matching: RemovableVolumeDetachedDisk(
                        volumePath: volumePath,
                        volumeUUID: nil
                    ),
                    reason: .unmounted
                )
            }
        }
        observers = [didMount, willUnmount, didUnmount]
    }

    private func refresh(reason: String) {
        let attachments = Self.currentAttachments()
        let nextByIdentity = Dictionary(uniqueKeysWithValues: attachments.map { ($0.identity, $0) })
        let currentIdentities = Set(attachmentsByIdentity.keys)
        let nextIdentities = Set(nextByIdentity.keys)

        for identity in currentIdentities.subtracting(nextIdentities) {
            onDetach(identity, .unmounted)
        }
        for attachment in attachments where attachmentsByIdentity[attachment.identity] != attachment {
            onAttach(attachment)
        }
        attachmentsByIdentity = nextByIdentity
        OtosLog.fileAccess.info(
            "Removable volume refresh reason=\(reason, privacy: .public) count=\(attachments.count, privacy: .public)"
        )
    }

    private func detach(matching disk: RemovableVolumeDetachedDisk, reason: RemovableSourceDetachReason) {
        guard let identity = identity(matching: disk) else {
            return
        }
        attachmentsByIdentity.removeValue(forKey: identity)
        onDetach(identity, reason)
    }

    private func identity(matching disk: RemovableVolumeDetachedDisk) -> String? {
        if let volumeUUID = disk.volumeUUID {
            let identity = "volume:\(volumeUUID)"
            if attachmentsByIdentity[identity] != nil {
                return identity
            }
        }
        if let volumePath = disk.volumePath {
            return attachmentsByIdentity.first { _, attachment in
                attachment.mountURL.path(percentEncoded: false) == volumePath
            }?.key
        }
        return nil
    }

    private nonisolated static func currentAttachments() -> [RemovableVolumeAttachment] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeUUIDStringKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRemovable == true
            else {
                return nil
            }
            let path = url.path(percentEncoded: false)
            let identity = values.volumeUUIDString.map { "volume:\($0)" } ?? "volume:path:\(path)"
            return RemovableVolumeAttachment(
                mountURL: url,
                identity: identity,
                displayName: values.volumeName ?? url.lastPathComponent,
                isEjectable: values.volumeIsEjectable == true
            )
        }
        .sorted { left, right in
            left.identity.localizedStandardCompare(right.identity) == .orderedAscending
        }
    }
}

private final nonisolated class RemovableDiskDisappearanceMonitor {
    private let session: DASession
    private let queue = DispatchQueue(label: "net.melisma.Otos.removable-disk-arbitration")
    private let onDiskDisappeared: @MainActor @Sendable (RemovableVolumeDetachedDisk) -> Void

    init?(onDiskDisappeared: @escaping @MainActor @Sendable (RemovableVolumeDetachedDisk) -> Void) {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return nil
        }
        self.session = session
        self.onDiskDisappeared = onDiskDisappeared

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        DARegisterDiskDisappearedCallback(session, nil, removableDiskDisappearedCallback, context)
        DASessionSetDispatchQueue(session, queue)
    }

    deinit {
        DASessionSetDispatchQueue(session, nil)
    }

    fileprivate func handleDiskDisappeared(_ disk: DADisk) {
        guard let description = DADiskCopyDescription(disk) as? [String: Any],
              description[kDADiskDescriptionMediaRemovableKey as String] as? Bool == true
        else {
            return
        }
        let detachedDisk = RemovableVolumeDetachedDisk(
            volumePath: (description[kDADiskDescriptionVolumePathKey as String] as? URL)?.path(percentEncoded: false),
            volumeUUID: (description[kDADiskDescriptionVolumeUUIDKey as String] as? UUID)?.uuidString
        )
        Task { @MainActor [onDiskDisappeared, detachedDisk] in
            onDiskDisappeared(detachedDisk)
        }
    }
}

private nonisolated func removableDiskDisappearedCallback(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    guard let context else {
        return
    }
    let monitor = Unmanaged<RemovableDiskDisappearanceMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.handleDiskDisappeared(disk)
}

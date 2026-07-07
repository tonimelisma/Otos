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
    private let onQuiesce: @MainActor @Sendable (String) -> Void
    private let onResume: @MainActor @Sendable (String) -> Void
    private let onDetach: @MainActor @Sendable (String, RemovableSourceDetachReason) -> Void

    private var observers: [NSObjectProtocol] = []
    private var attachmentsByIdentity: [String: RemovableVolumeAttachment] = [:]
    private var diskMonitor: RemovableDiskDisappearanceMonitor?
    private var isStarted = false

    init(
        workspace: NSWorkspace = .shared,
        onAttach: @escaping @MainActor @Sendable (RemovableVolumeAttachment) -> Void,
        onQuiesce: @escaping @MainActor @Sendable (String) -> Void,
        onResume: @escaping @MainActor @Sendable (String) -> Void,
        onDetach: @escaping @MainActor @Sendable (String, RemovableSourceDetachReason) -> Void
    ) {
        notificationCenter = workspace.notificationCenter
        self.onAttach = onAttach
        self.onQuiesce = onQuiesce
        self.onResume = onResume
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
        diskMonitor?.stop()
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
                self?.quiesce(
                    matching: RemovableVolumeDetachedDisk(
                        volumePath: volumePath,
                        volumeUUID: nil
                    )
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
        let nextByIdentity = Dictionary(attachments.map { ($0.identity, $0) }) { first, _ in first }
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

    private func quiesce(matching disk: RemovableVolumeDetachedDisk) {
        guard let identity = identity(matching: disk) else {
            return
        }
        onQuiesce(identity)
        Task { @MainActor [weak self, identity] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard let self,
                  Self.currentAttachments().contains(where: { $0.identity == identity })
            else {
                return
            }
            onResume(identity)
        }
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
                isEjectable: attachment.isEjectable
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
        let attachments = urls.compactMap { url -> RemovableVolumeAttachment? in
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
        return disambiguatedAttachments(attachments)
            .sorted { left, right in
                left.identity.localizedStandardCompare(right.identity) == .orderedAscending
            }
    }
}

private final nonisolated class RemovableDiskDisappearanceMonitor {
    private let session: DASession
    private let queue = DispatchQueue(label: "net.melisma.Otos.removable-disk-arbitration")
    private let callbackContext: UnsafeMutableRawPointer
    private var isStopped = false

    init?(onDiskDisappeared: @escaping @MainActor @Sendable (RemovableVolumeDetachedDisk) -> Void) {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return nil
        }
        self.session = session
        callbackContext = Unmanaged.passRetained(
            RemovableDiskDisappearanceContext(onDiskDisappeared: onDiskDisappeared)
        ).toOpaque()

        DARegisterDiskDisappearedCallback(
            session,
            nil,
            removableDiskDisappearedCallback as DADiskDisappearedCallback,
            callbackContext
        )
        DASessionSetDispatchQueue(session, queue)
    }

    deinit {
        stop()
    }

    func stop() {
        guard !isStopped else {
            return
        }
        let callback = removableDiskDisappearedCallback as DADiskDisappearedCallback
        let callbackPointer = unsafeBitCast(callback, to: UnsafeMutableRawPointer.self)
        queue.sync {
            DAUnregisterCallback(
                session,
                callbackPointer,
                callbackContext
            )
            DASessionSetDispatchQueue(session, nil)
        }
        Unmanaged<RemovableDiskDisappearanceContext>.fromOpaque(callbackContext).release()
        isStopped = true
    }
}

private final nonisolated class RemovableDiskDisappearanceContext {
    private let onDiskDisappeared: @MainActor @Sendable (RemovableVolumeDetachedDisk) -> Void

    init(onDiskDisappeared: @escaping @MainActor @Sendable (RemovableVolumeDetachedDisk) -> Void) {
        self.onDiskDisappeared = onDiskDisappeared
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
    let callbackContext = Unmanaged<RemovableDiskDisappearanceContext>.fromOpaque(context).takeUnretainedValue()
    callbackContext.handleDiskDisappeared(disk)
}

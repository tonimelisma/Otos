import AppKit
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
            let volumePath = Self.volumePath(from: notification)
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
            let volumePath = Self.volumePath(from: notification)
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

    nonisolated static func volumePath(from notification: Notification) -> String? {
        if let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
            return url.path(percentEncoded: false)
        }
        return notification.userInfo?["NSDevicePath"] as? String
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

    private nonisolated static func currentAttachments() -> [RemovableVolumeAttachment] {
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
            return []
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

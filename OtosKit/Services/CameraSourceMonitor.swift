import CoreGraphics
import Foundation
@preconcurrency import ImageCaptureCore
import OSLog
import UniformTypeIdentifiers

nonisolated struct DeviceCameraCatalogItem: Hashable {
    let relativePath: MediaRelativePath
    let name: String
    let contentTypeIdentifier: String?
    let byteSize: Int64?
    let captureDate: Date?
    let modificationDate: Date?
}

/// How a camera item is named in the catalog, where its path is its identity (ADR 0008).
/// The name is the one the device lists, unique within its folder and stable across
/// sessions: an iPhone's `IMG_E0571.HEIC`, a Sony's `DSC06715.ARW`. Never
/// `originalFilename`, which an iPhone gives every edited photo alike (`FullSizeRender.heic`,
/// measured 2026-11-12: 31 of 1,054 items), and which a Sony does not report at all. A path
/// two items claim belongs to neither: Otos invents no suffix, so neither is cataloged.
nonisolated enum CameraItemNaming {
    /// The listed name, else the name the item was created with on the device.
    static func name(listed: String?, created: String?) -> String? {
        [listed, created].lazy.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first
    }

    /// The paths more than one item claims.
    static func contested(_ paths: [String]) -> Set<String> {
        var seen = Set<String>()
        var contested = Set<String>()
        for path in paths where !seen.insert(path).inserted {
            contested.insert(path)
        }
        return contested
    }
}

nonisolated struct DeviceCameraCompanionItem: Hashable {
    let relativePath: MediaRelativePath
    let primaryRelativePath: MediaRelativePath
    let kind: MediaCompanionKind
    let byteSize: Int64?
    let contentModifiedAt: Date?
}

nonisolated struct DeviceCameraCatalogSnapshot: Hashable {
    let items: [DeviceCameraCatalogItem]
    let companions: [DeviceCameraCompanionItem]
    let isStable: Bool
}

nonisolated enum ImageCaptureCameraRejectionReason: String {
    case mountedVolume
    case massStorageTransport
    case massStorageLocation
}

nonisolated enum ImageCaptureCameraSourcePolicy {
    static func rejectionReason(
        mountPoint: String?,
        transportType: String?,
        locationDescription: String?
    ) -> ImageCaptureCameraRejectionReason? {
        if let mountPoint, !mountPoint.isEmpty {
            return .mountedVolume
        }
        if isMassStorageValue(transportType) {
            return .massStorageTransport
        }
        if isMassStorageValue(locationDescription) {
            return .massStorageLocation
        }
        return nil
    }

    private static func isMassStorageValue(_ value: String?) -> Bool {
        guard let value else {
            return false
        }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        return normalized.contains("massstorage")
    }
}

/// The single owner of "what date does this `ICCameraFile` have".
/// Camera firmware populates the six date properties ImageCapture exposes
/// inconsistently — some write only EXIF fields, some only filesystem fields —
/// so each function tries all six in a fixed precedence and returns the first one
/// that passes the epoch-zero guard. Every call site in this file (catalog
/// listing, revalidation, companion inventory) goes through one of these two
/// functions; none derives a date by any other chain.
///
/// The precedence logic takes the six raw dates rather than `ICCameraFile`
/// directly: `ICCameraFile`'s properties are read-only and framework-populated
/// (no public initializer), so a version over the raw values is what
/// `CameraFileDateTests` can actually construct fixtures for. The
/// `ICCameraFile` overloads below are the one-line adapters every real call
/// site uses.
nonisolated enum CameraFileDate {
    /// When the file was captured: creation-first.
    static func captureDate(
        creationDate: Date?,
        exifCreationDate: Date?,
        fileCreationDate: Date?,
        modificationDate: Date?,
        fileModificationDate: Date?,
        exifModificationDate: Date?
    ) -> Date? {
        validCameraDate(creationDate)
            ?? validCameraDate(exifCreationDate)
            ?? validCameraDate(fileCreationDate)
            ?? validCameraDate(modificationDate)
            ?? validCameraDate(fileModificationDate)
            ?? validCameraDate(exifModificationDate)
    }

    /// When the file was last modified: modification-first.
    static func modificationDate(
        creationDate: Date?,
        exifCreationDate: Date?,
        fileCreationDate: Date?,
        modificationDate: Date?,
        fileModificationDate: Date?,
        exifModificationDate: Date?
    ) -> Date? {
        validCameraDate(modificationDate)
            ?? validCameraDate(fileModificationDate)
            ?? validCameraDate(exifModificationDate)
            ?? validCameraDate(creationDate)
            ?? validCameraDate(exifCreationDate)
            ?? validCameraDate(fileCreationDate)
    }

    static func captureDate(_ file: ICCameraFile) -> Date? {
        captureDate(
            creationDate: file.creationDate,
            exifCreationDate: file.exifCreationDate,
            fileCreationDate: file.fileCreationDate,
            modificationDate: file.modificationDate,
            fileModificationDate: file.fileModificationDate,
            exifModificationDate: file.exifModificationDate
        )
    }

    static func modificationDate(_ file: ICCameraFile) -> Date? {
        modificationDate(
            creationDate: file.creationDate,
            exifCreationDate: file.exifCreationDate,
            fileCreationDate: file.fileCreationDate,
            modificationDate: file.modificationDate,
            fileModificationDate: file.fileModificationDate,
            exifModificationDate: file.exifModificationDate
        )
    }

    private static func validCameraDate(_ date: Date?) -> Date? {
        guard let date, abs(date.timeIntervalSince1970) >= 0.001 else {
            return nil
        }
        return date
    }
}

@MainActor
final class CameraSourceMonitor: NSObject {
    private let browser = ICDeviceBrowser()
    private let onAttach: @MainActor @Sendable (DeviceCameraSession) -> Void
    private let onDetach: @MainActor @Sendable (DeviceIdentity) -> Void
    private var sessionsByIdentity: [DeviceIdentity: DeviceCameraSession] = [:]
    private var identitiesByDevice: [ObjectIdentifier: DeviceIdentity] = [:]
    private var isStarted = false
    /// The catalog's staging containers (`CatalogStore.stagingContainers`): where each
    /// camera's session stages its files, so the camera's root and the Store's are one path.
    let stagingContainers: StagingContainers
    /// Browser reports in the order the browser made them; `browserLoop` is the one consumer.
    private let browserEvents: AsyncStream<BrowserEvent>.Continuation
    private var browserLoop: Task<Void, Never>?

    fileprivate nonisolated enum BrowserEvent: Sendable {
        case added(ICCameraDevice)
        case removed(ICCameraDevice)
    }

    init(
        stagingContainers: StagingContainers,
        onAttach: @escaping @MainActor @Sendable (DeviceCameraSession) -> Void,
        onDetach: @escaping @MainActor @Sendable (DeviceIdentity) -> Void
    ) {
        self.stagingContainers = stagingContainers
        self.onAttach = onAttach
        self.onDetach = onDetach
        let (stream, continuation) = AsyncStream.makeStream(of: BrowserEvent.self, bufferingPolicy: .unbounded)
        browserEvents = continuation
        super.init()
        browserLoop = Task { [weak self] in
            for await event in stream {
                guard let self else {
                    return
                }
                switch event {
                case let .added(camera):
                    attach(camera)
                case let .removed(camera):
                    detach(camera)
                }
            }
        }
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        )!
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        browser.start()
    }

    func stop() {
        guard isStarted else {
            return
        }
        browser.stop()
        for session in sessionsByIdentity.values {
            session.close()
        }
        sessionsByIdentity.removeAll()
        identitiesByDevice.removeAll()
        isStarted = false
    }

    private func attach(_ device: ICCameraDevice) {
        if let reason = ImageCaptureCameraSourcePolicy.rejectionReason(
            mountPoint: device.mountPoint,
            transportType: device.transportType,
            locationDescription: device.locationDescription
        ) {
            OtosLog.fileAccess.debug(
                "ImageCapture camera rejected reason=\(reason.rawValue, privacy: .public)"
            )
            return
        }
        let identity = Self.identity(for: device)
        if sessionsByIdentity[identity] != nil {
            return
        }
        let session = DeviceCameraSession(
            identity: identity,
            displayName: device.name ?? "Connected Camera",
            device: device,
            stagingRootURL: stagingRoot(for: identity)
        )
        sessionsByIdentity[identity] = session
        identitiesByDevice[ObjectIdentifier(device)] = identity
        onAttach(session)
    }

    /// Where the camera named `identity` stages its files: its tree in the catalog's device
    /// container.
    func stagingRoot(for identity: DeviceIdentity) -> URL {
        stagingContainers.sessionRoot(in: .device, identity: identity)
    }

    private func detach(_ device: ICCameraDevice) {
        let identity = identitiesByDevice.removeValue(forKey: ObjectIdentifier(device))
            ?? Self.identity(for: device)
        sessionsByIdentity.removeValue(forKey: identity)?.close()
        onDetach(identity)
    }

    private nonisolated static func identity(for device: ICCameraDevice) -> DeviceIdentity {
        let rawIdentity = firstNonEmpty(
            device.persistentIDString,
            device.serialNumberString,
            device.uuidString
        )
        if let rawIdentity {
            return .camera(id: rawIdentity)
        }
        let display = firstNonEmpty(device.name, device.locationDescription) ?? "connected-camera"
        return .camera(name: sanitize(display))
    }

    private nonisolated static func firstNonEmpty(_ values: String?...) -> String? {
        values.lazy.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first
    }

    nonisolated static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "source" : sanitized
    }
}

/// ImageCaptureCore delegate boundary
///
/// ImageCaptureCore calls delegate methods on queues it chooses. Its headers promise
/// that "unless otherwise noted, all delegate callbacks will occur on the main thread"
/// (`ICDevice.h`), but `cameraDevice(_:didReceivePTPEvent:)` is delivered on the
/// framework's own `ICDeviceOperationQueue` — which killed the app in
/// `_dispatch_assert_queue_fail` when a camera attached.
///
/// A `@preconcurrency` conformance on a `@MainActor` type asserts isolation this app
/// does not control: it does not move a callback to the main actor, it inserts a runtime
/// executor check that traps at method entry when the framework disagrees — so even an
/// empty method crashes. Both delegate conformances here are therefore plain, and every
/// delegate method is `nonisolated`. That is a type-level fix rather than a per-method
/// patch: the compiler now rejects any delegate method that claims main-actor isolation,
/// so a callback added later cannot re-open this defect class, and each one must state
/// its hop to the owner.
///
/// The framework's Objective-C objects cross that hop under the file's
/// `@preconcurrency import ImageCaptureCore`, which is what that import is for — no
/// unchecked `Sendable` conformance is introduced (ARC-042).
///
/// Each delegate method only yields into its owner's ordered stream: the browser's for
/// add/remove, the session's for session and catalog reports. One loop per owner applies
/// them on the main actor in the order the framework delivered them, so a camera removed
/// right after it was added is never left attached.
extension CameraSourceMonitor: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else {
            return
        }
        browserEvents.yield(.added(camera))
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard let camera = device as? ICCameraDevice else {
            return
        }
        browserEvents.yield(.removed(camera))
    }

    nonisolated func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        OtosLog.fileAccess.debug("ImageCapture camera browser finished local enumeration")
    }
}

@MainActor
final class DeviceCameraSession: NSObject {
    let identity: DeviceIdentity
    let displayName: String
    let stagingRootURL: URL

    private let device: ICCameraDevice
    private enum WaitCondition {
        case open
        case catalogReady
    }

    private struct Waiter {
        let condition: WaitCondition
        let continuation: CheckedContinuation<Void, Error>
    }

    private var sessionOpenResult: Result<Void, Error>?
    private var isCatalogReady = false
    private var terminalFailure: Error?
    private var waiters: [UUID: Waiter] = [:]
    private var didAddItemCount = 0
    private var filesByRelativePath: [MediaRelativePath: ICCameraFile] = [:]
    private var isClosed = false
    /// FIFO gate over every byte-moving request to this device.
    ///
    /// ImageCaptureCore serialises on one `ICDeviceCommandQueue` regardless of how many
    /// requests are outstanding — a process sample during the 2026-08-30 session found the
    /// app inside `requestDownloadWithOptions` for 1,465 of 1,481 samples. Extra
    /// concurrent requests therefore buy no parallelism; they queue somewhere Otos cannot
    /// see, time, or cancel, and they measurably cost throughput (0.9-8.5 MB/s observed
    /// under a 16-way window against 37-40 MB/s single-stream).
    ///
    /// The gate lives on the session rather than in `MaterializationAdmissionPolicy`
    /// because the policy only sees enrichment traffic. `MediaImportExecutor` runs eight
    /// copy workers that call `download` directly, so import bypasses the policy entirely
    /// — and once planning stops staging the card up front, import becomes the *only*
    /// path that moves bytes. A cap that lives anywhere else would not cover it.
    private var transferInFlight = false
    private var transferWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    /// Session and catalog reports in the order ImageCaptureCore made them, whichever
    /// queue it made them on; `eventLoop` is the one consumer.
    private let events: AsyncStream<SessionEvent>.Continuation
    private var eventLoop: Task<Void, Never>?
    /// The doorbell `CameraCatalogSync` waits on. Newest-wins: any number of reports
    /// while a pass runs become one more pass.
    let catalogChanges: AsyncStream<Void>
    private let catalogChangeBell: AsyncStream<Void>.Continuation

    fileprivate nonisolated enum SessionEvent: Sendable {
        /// The framework error, reduced to its description at the boundary.
        case opened(frameworkErrorDescription: String?)
        case closed
        case itemsAdded(Int)
        /// Items removed or renamed: the list changed without growing.
        case itemsChanged
        case catalogComplete
    }

    /// `stagingRootURL` is the tree its monitor names for it (`CameraSourceMonitor.stagingRoot`).
    init(identity: DeviceIdentity, displayName: String, device: ICCameraDevice, stagingRootURL: URL) {
        self.identity = identity
        self.displayName = displayName
        self.device = device
        self.stagingRootURL = stagingRootURL
        // Claims this camera's tree for as long as this process is attached, so a peer's
        // launch sweep leaves it alone. Best-effort: a failed claim means another instance
        // does the cleaning, not that staging is unusable.
        StagingLocation.claimOwnership(of: stagingRootURL)
        let (stream, continuation) = AsyncStream.makeStream(of: SessionEvent.self, bufferingPolicy: .unbounded)
        events = continuation
        (catalogChanges, catalogChangeBell) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        super.init()
        eventLoop = Task { [weak self] in
            for await event in stream {
                guard let self else {
                    return
                }
                apply(event)
            }
        }
        device.delegate = self
    }

    private func apply(_ event: SessionEvent) {
        switch event {
        case let .opened(frameworkErrorDescription):
            applySessionOpenOutcome(frameworkErrorDescription: frameworkErrorDescription)
        case .closed:
            applySessionClosed()
        case let .itemsAdded(count):
            didAddItemCount += count
            ringCatalogChange()
        case .itemsChanged:
            ringCatalogChange()
        case .catalogComplete:
            markCatalogReady()
        }
    }

    func catalogSnapshot() async throws -> DeviceCameraCatalogSnapshot {
        let started = ContinuousClock().now
        OtosLog.fileAccess.noticeOperation("camera.enumerate", phase: "start", fields: [
            "identity": identity.rawValue,
        ])
        try await openAndWaitForCatalogReady()
        let isStable = await waitForCatalogStability(timeout: Self.catalogSettleLimit)
        let items = currentCatalogItems()
        let elapsedMs = DiagnosticsTiming.milliseconds(from: started, to: .now)
        OtosLog.fileAccess.noticeOperation("camera.enumerate", phase: "finish", fields: [
            "identity": identity.rawValue,
            "count": "\(items.count)",
            "elapsedMs": "\(elapsedMs)",
            "isStable": "\(isStable)",
        ])
        return DeviceCameraCatalogSnapshot(
            items: items,
            companions: currentCompanionItems(),
            isStable: isStable
        )
    }

    private func currentCatalogItems() -> [DeviceCameraCatalogItem] {
        let named = (device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }.compactMap { file in
            catalogItem(for: file).map { (file, $0) }
        }
        let contested = CameraItemNaming.contested(named.map(\.1.relativePath.rawValue))
        if !contested.isEmpty {
            OtosLog.fileAccess.noticeOperation("camera.inventory", phase: "contestedPathsSkipped", fields: [
                "identity": identity.rawValue,
                "paths": "\(contested.count)",
            ])
        }
        var items: [DeviceCameraCatalogItem] = []
        filesByRelativePath.removeAll(keepingCapacity: true)
        for (file, item) in named where !contested.contains(item.relativePath.rawValue) {
            filesByRelativePath[item.relativePath] = file
            items.append(item)
        }
        return items.sorted {
            $0.relativePath.rawValue.localizedStandardCompare($1.relativePath.rawValue) == .orderedAscending
        }
    }

    /// Maps `ICCameraFile.sidecarFiles` property values onto recognized companions.
    /// Hardware may also surface some companions inside `mediaFiles`; those are
    /// inventoried only when they match `.xmp`/`.srt` and are not already paired
    /// here. Findings without attached hardware are recorded in
    /// `docs/research/2026-07-10-camera-sidecar-surfacing.md`.
    private func currentCompanionItems() -> [DeviceCameraCompanionItem] {
        var companions: [DeviceCameraCompanionItem] = []
        var seen = Set<MediaRelativePath>()
        for (primaryPath, file) in filesByRelativePath {
            let sidecars = file.sidecarFiles ?? []
            for sidecar in sidecars {
                guard let cameraFile = sidecar as? ICCameraFile else {
                    continue
                }
                guard let name = CameraItemNaming.name(listed: cameraFile.name, created: cameraFile.createdFilename) else {
                    continue
                }
                guard let kind = MediaCompanionKind.recognize(
                    fileExtension: MediaRelativePath(rawValue: name).fileExtension
                ) else {
                    continue
                }
                let relativePath = MediaRelativePath(
                    rawValue: cameraRelativePath(for: cameraFile, name: name)
                )
                guard seen.insert(relativePath).inserted else {
                    continue
                }
                let size = cameraFile.fileSize >= 0 ? Int64(cameraFile.fileSize) : nil
                let modified = CameraFileDate.modificationDate(cameraFile)
                companions.append(
                    DeviceCameraCompanionItem(
                        relativePath: relativePath,
                        primaryRelativePath: primaryPath,
                        kind: kind,
                        byteSize: size,
                        contentModifiedAt: modified
                    )
                )
            }
        }
        return companions.sorted {
            $0.relativePath.rawValue.localizedStandardCompare($1.relativePath.rawValue) == .orderedAscending
        }
    }

    func thumbnailData(for relativePath: MediaRelativePath, maxPixelSize: Int) async throws -> Data? {
        guard let file = filesByRelativePath[relativePath] else {
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            // Same boundary as the download completion and the delegate methods: the
            // framework chooses the queue, so the closure must claim no isolation.
            // This one has not trapped only because thumbnails happen to arrive on the
            // main thread today — which is the assumption APP-018 exists to forbid.
            file.requestThumbnailData(options: [
                ICCameraItemThumbnailOption.imageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]) { @Sendable data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    /// Completes one ImageCaptureCore download from whatever queue the framework
    /// chose. Deliberately `nonisolated`: claiming this type's actor here inserts an
    /// executor assertion that traps instead of hopping (see the delegate boundary
    /// note above — same defect class, reached through the completion block rather
    /// than a delegate method).
    nonisolated static func settleDownload(
        savedFilename: String?,
        error: Error?,
        destinationURL: URL,
        continuation: CheckedContinuation<Void, Error>
    ) {
        if let error {
            continuation.resume(throwing: error)
            return
        }
        // The camera may save under a name of its own; the bytes are where the caller
        // asked only once they are moved there, so a failed move fails the download.
        if let savedFilename, savedFilename != destinationURL.lastPathComponent {
            let savedURL = destinationURL.deletingLastPathComponent().appending(path: savedFilename)
            do {
                do {
                    try FileManager.default.removeItem(at: destinationURL)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {}
                try FileManager.default.moveItem(at: savedURL, to: destinationURL)
            } catch {
                continuation.resume(throwing: error)
                return
            }
        }
        continuation.resume(returning: ())
    }

    /// Takes the device's single transfer slot, waiting in FIFO order for it.
    ///
    /// Throwing rather than plain suspension so `close()` can release queued callers with
    /// `.disconnected` instead of stranding them: a detached camera must fail its waiters,
    /// not hang the import that is waiting on them.
    private func acquireTransferSlot() async throws {
        if isClosed {
            throw DeviceCameraSessionError.disconnected
        }
        guard transferInFlight else {
            transferInFlight = true
            return
        }
        let id = UUID()
        try await withCheckedThrowingContinuation { continuation in
            transferWaiters.append((id: id, continuation: continuation))
        }
    }

    /// Hands the slot to the next waiter, or marks the device idle.
    ///
    /// Never clears `transferInFlight` while a waiter exists: the slot passes directly
    /// from one holder to the next, so no third caller can slip in between and make two
    /// transfers concurrent.
    private func releaseTransferSlot() {
        guard !transferWaiters.isEmpty else {
            transferInFlight = false
            return
        }
        let next = transferWaiters.removeFirst()
        next.continuation.resume()
    }

    func download(relativePath: MediaRelativePath, to destinationURL: URL) async throws {
        guard let file = filesByRelativePath[relativePath] else {
            throw DeviceCameraSessionError.itemUnavailable(relativePath.rawValue)
        }
        try await acquireTransferSlot()
        defer { releaseTransferSlot() }
        let started = ContinuousClock().now
        OtosLog.fileAccess.noticeOperation("camera.download", phase: "start", fields: [
            "relativePath": relativePath.rawValue,
        ])
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        let downloadOptions: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: destinationURL.deletingLastPathComponent(),
            .saveAsFilename: destinationURL.lastPathComponent,
            .overwrite: true,
            .sidecarFiles: false,
        ]
        do {
            // The completion block is the same boundary as the delegate methods above:
            // ImageCaptureCore invokes it on a queue of its own choosing, so a closure
            // that inherits this type's `@MainActor` isolation does not get hopped to
            // the main actor — it gets a runtime executor check that traps. That is
            // exactly how it died: `_dispatch_assert_queue_fail` under
            // `swift_task_checkIsolatedSwift`, from inside this closure.
            //
            // `Self.settleDownload` is `nonisolated` and takes only Sendable values, so
            // the closure claims no isolation it does not have. The work it does — one
            // rename — is pure filesystem and needs none.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let destination = destinationURL
                file.requestDownload(options: downloadOptions) { @Sendable savedFilename, error in
                    Self.settleDownload(
                        savedFilename: savedFilename,
                        error: error,
                        destinationURL: destination,
                        continuation: continuation
                    )
                }
            }
        } catch {
            // Report the destination alongside the error: ICDownloadOption's
            // `downloadsDirectoryURL` must be a *writable* directory, so a refusal
            // here is about where the file is being put at least as often as it is
            // about the camera, and the two are indistinguishable without both paths.
            var fields = ErrorDiagnostics.fields(for: error)
            fields["relativePath"] = relativePath.rawValue
            fields["downloadsDirectory"] = destinationURL.deletingLastPathComponent().path(percentEncoded: false)
            fields["saveAsFilename"] = destinationURL.lastPathComponent
            fields["destinationWritable"] = FileManager.default.isWritableFile(
                atPath: destinationURL.deletingLastPathComponent().path(percentEncoded: false)
            ) ? "true" : "false"
            OtosLog.fileAccess.errorOperation("camera.download", phase: "failed", fields: fields)
            throw error
        }
        let elapsedMs = DiagnosticsTiming.milliseconds(from: started, to: .now)
        let bytes = try? destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        OtosLog.fileAccess.noticeOperation("camera.download", phase: "finish", fields: [
            "relativePath": relativePath.rawValue,
            "bytes": bytes.flatMap(\.self).map { "\($0)" } ?? "unknown",
            "elapsedMs": "\(elapsedMs)",
        ])
    }

    /// Issues one ranged read and returns immediately; `completion` carries the answer.
    ///
    /// The whole point of this shape is that `ICCameraFile` never leaves the main actor.
    /// It is not `Sendable`, and Otos forbids the escape hatches that would let it cross
    /// (ARC-042), so the file is looked up and used here, and only Sendable values — a
    /// relative path, an offset, a length, and the result — travel in either direction.
    ///
    /// This method does no waiting. `requestReadData` returns as soon as the request is
    /// queued, so the main actor's share of a ranged read is microseconds; the caller does
    /// the waiting on its own thread. That asymmetry is what makes a synchronous byte
    /// source safe to build on top of this without ever blocking the main actor.
    ///
    /// The completion claims no isolation, per APP-018: ImageCaptureCore invokes it on a
    /// queue of its own choosing, and a closure that inherited this type's `@MainActor`
    /// would get a runtime executor check that traps rather than a hop.
    nonisolated func beginRangedRead(
        relativePath: MediaRelativePath,
        offset: UInt64,
        length: Int,
        completion: @escaping @Sendable (Result<Data, DeviceCameraSessionError>) -> Void
    ) {
        // A request, not a report: each read carries its own completion and its caller
        // waits for that answer alone, so no order between reads is owed.
        // swiftlint:disable:next unordered_main_actor_hop
        Task { @MainActor in
            guard !isClosed, let file = filesByRelativePath[relativePath] else {
                completion(.failure(.itemUnavailable(relativePath.rawValue)))
                return
            }
            file.requestReadData(atOffset: off_t(offset), length: off_t(length)) { @Sendable data, error in
                if let error {
                    completion(.failure(.rangedReadFailed(String(describing: error))))
                    return
                }
                guard let data else {
                    completion(.failure(.rangedReadFailed("no data and no error")))
                    return
                }
                completion(.success(data))
            }
        }
    }

    func file(for relativePath: MediaRelativePath) -> ICCameraFile? {
        filesByRelativePath[relativePath]
    }

    /// Revalidates planned size/date against live `ICCameraFile` facts (ARC-049).
    /// Distinguishes "the session itself isn't ready" from "this specific file
    /// is gone", which a `Bool` would collapse.
    func revalidate(
        relativePath: MediaRelativePath,
        byteSize: Int64?,
        modifiedAt: Date?
    ) -> SourceValidation {
        guard !isClosed, device.hasOpenSession else {
            logRevalidateMiss(relativePath: relativePath, validation: .sourceNotReady)
            return .sourceNotReady
        }
        guard let file = filesByRelativePath[relativePath] else {
            logRevalidateMiss(relativePath: relativePath, validation: .absent)
            return .absent
        }
        if let byteSize {
            guard file.fileSize >= 0, Int64(file.fileSize) == byteSize else {
                logRevalidateMiss(relativePath: relativePath, validation: .changed(.size))
                return .changed(.size)
            }
        }
        if let modifiedAt {
            let live = CameraFileDate.modificationDate(file)
            guard let live, abs(live.timeIntervalSince(modifiedAt)) < 1.0 else {
                logRevalidateMiss(relativePath: relativePath, validation: .changed(.date))
                return .changed(.date)
            }
        }
        return .matches
    }

    private func logRevalidateMiss(relativePath: MediaRelativePath, validation: SourceValidation) {
        OtosLog.fileAccess.noticeOperation("camera.revalidate", phase: "miss", fields: [
            "identity": identity.rawValue,
            "relativePath": relativePath.rawValue,
            "reason": String(describing: validation),
        ])
    }

    var canDeleteOneFile: Bool {
        let token = ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue
        return device.capabilities.contains(token)
    }

    func deleteItem(relativePath: MediaRelativePath) async -> Bool {
        guard canDeleteOneFile, let file = filesByRelativePath[relativePath] else {
            return false
        }
        return await withCheckedContinuation { continuation in
            // Same boundary again. Semantics unchanged — this path still deletes only
            // what an explicit, user-requested erase asked for; only the isolation
            // claim is removed.
            _ = device.requestDeleteFiles(
                [file],
                deleteFailed: { @Sendable _ in },
                completion: { @Sendable _, error in
                    continuation.resume(returning: error == nil)
                }
            )
        }
    }

    func eject() async -> RemovableEjectOutcome {
        let token = ICDeviceCapability.canEjectOrDisconnect.rawValue
        guard device.capabilities.contains(token) else {
            return .failed(description: "cameraCannotEject")
        }
        return await withCheckedContinuation { continuation in
            device.requestEject { error in
                if let error {
                    continuation.resume(returning: .failed(description: error.localizedDescription))
                } else {
                    continuation.resume(returning: .ejected)
                }
            }
        }
    }

    func close() {
        failAllWaiters(DeviceCameraSessionError.disconnected)
        if device.hasOpenSession {
            // `didCloseSessionWithError` (below) logs the confirmed close once
            // ImageCapture completes it; logging here too would claim the session
            // closed before it actually did.
            device.requestCloseSession()
        }
    }

    private func openAndWaitForCatalogReady() async throws {
        if isClosed {
            throw DeviceCameraSessionError.disconnected
        }
        if !device.hasOpenSession {
            try await requestOpenSession(timeout: Self.sessionOpenLimit)
        }
        try await waitForCatalogReady(timeout: Self.catalogReadyLimit)
    }

    /// When a camera that has not opened its session, or not finished its catalog, is
    /// reported as failed. The PTP link may never answer, so these are product decisions
    /// about when the user is told, not stand-ins for a fact the device reports.
    nonisolated static let sessionOpenLimit = Duration.seconds(10)
    nonisolated static let catalogReadyLimit = Duration.seconds(240)

    private func requestOpenSession(timeout: Duration) async throws {
        let timeoutTask = Task { [weak self] in
            do {
                // time: deadline — `sessionOpenLimit`: the camera may never open its session
                try await Task.sleep(for: timeout)
                self?.resolveWaiters(condition: .open, result: .failure(DeviceCameraSessionError.openTimedOut))
            } catch is CancellationError {
                return
            }
        }
        defer { timeoutTask.cancel() }
        try await wait(for: .open) {
            self.device.requestOpenSession()
        }
    }

    private func waitForCatalogReady(timeout: Duration) async throws {
        let timeoutTask = Task { [weak self] in
            do {
                // time: deadline — `catalogReadyLimit`: the camera may never finish its catalog
                try await Task.sleep(for: timeout)
                self?.resolveWaiters(
                    condition: .catalogReady,
                    result: .failure(DeviceCameraSessionError.catalogTimedOut)
                )
            } catch is CancellationError {
                return
            }
        }
        defer { timeoutTask.cancel() }
        try await wait(for: .catalogReady)
    }

    private func wait(for condition: WaitCondition, start: (() -> Void)? = nil) async throws {
        if let terminalFailure {
            throw terminalFailure
        }
        if conditionIsSatisfied(condition) {
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let terminalFailure {
                continuation.resume(throwing: terminalFailure)
                return
            }
            if conditionIsSatisfied(condition) {
                continuation.resume()
                return
            }
            waiters[UUID()] = Waiter(condition: condition, continuation: continuation)
            start?()
        }
    }

    private func conditionIsSatisfied(_ condition: WaitCondition) -> Bool {
        switch condition {
        case .open:
            if case .success = sessionOpenResult {
                return true
            }
            return device.hasOpenSession
        case .catalogReady:
            return isCatalogReady
        }
    }

    private func resolveWaiters(condition: WaitCondition, result: Result<Void, Error>) {
        var remaining: [UUID: Waiter] = [:]
        for (id, waiter) in waiters {
            if waiter.condition == condition {
                waiter.continuation.resume(with: result)
            } else {
                remaining[id] = waiter
            }
        }
        waiters = remaining
    }

    private func failAllWaiters(_ error: Error) {
        terminalFailure = error
        isClosed = true
        catalogChangeBell.finish()
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters.values {
            waiter.continuation.resume(throwing: error)
        }
        // Transfer waiters are failed on the same path. A queued caller is parked on a
        // slot that will never be handed over once the device is gone, so leaving them
        // suspended would hang whatever is awaiting them — an import, most likely.
        let currentTransferWaiters = transferWaiters
        transferWaiters.removeAll()
        transferInFlight = false
        for waiter in currentTransferWaiters {
            waiter.continuation.resume(throwing: error)
        }
    }

    /// Main-actor side of `device(_:didOpenSessionWithError:)`. `terminalFailure` (set by a
    /// close) still wins in `wait(for:)`.
    private func applySessionOpenOutcome(frameworkErrorDescription: String?) {
        if let frameworkErrorDescription {
            sessionOpenResult = .failure(DeviceCameraSessionError.disconnected)
            resolveWaiters(condition: .open, result: .failure(DeviceCameraSessionError.disconnected))
            OtosLog.fileAccess.errorOperation("camera.session", phase: "openFailed", fields: [
                "identity": identity.rawValue,
                "error": frameworkErrorDescription,
            ])
        } else {
            sessionOpenResult = .success(())
            resolveWaiters(condition: .open, result: .success(()))
            OtosLog.fileAccess.noticeOperation("camera.session", phase: "open", fields: [
                "identity": identity.rawValue,
            ])
        }
    }

    /// Main-actor side of `device(_:didCloseSessionWithError:)` and `didRemove(_:)`.
    /// Both mean the same thing to every caller — the session is gone — so they share
    /// one owner intent instead of two paths that must stay in step.
    private func applySessionClosed() {
        failAllWaiters(DeviceCameraSessionError.disconnected)
        OtosLog.fileAccess.noticeOperation("camera.session", phase: "close", fields: [
            "identity": identity.rawValue,
        ])
    }

    /// Items reported before the catalog is complete are the initial enumeration, which
    /// the first pass reads; only a change after it is news.
    private func ringCatalogChange() {
        guard isCatalogReady, !isClosed else {
            return
        }
        catalogChangeBell.yield()
    }

    private func markCatalogReady() {
        isCatalogReady = true
        resolveWaiters(condition: .catalogReady, result: .success(()))
    }

    /// How long a camera's item list may keep changing before the enumeration gives up
    /// proving deletions. A product decision, because ImageCaptureCore reports no fact
    /// that the list is whole: `deviceDidBecomeReadyWithCompleteContentCatalog` has been
    /// observed with one item of a full card listed, and `deviceDidBecomeReady` with none
    /// (`docs/research/removable-volume-and-camera-sources.md`), and
    /// `wasAddedAfterContentCatalogCompleted` marks only items captured later. Two equal
    /// samples of the `didAdd` count and `mediaFiles` are the evidence available, and
    /// they gate one thing: whether this pass may delete rows. A list still changing at
    /// the limit records what it saw and deletes nothing (ADR 0008: a missing item is
    /// not a deleted one).
    nonisolated static let catalogSettleLimit = Duration.seconds(30)

    /// The gap between the two samples that must agree.
    nonisolated static let catalogSettleSampleInterval = Duration.milliseconds(500)

    private func waitForCatalogStability(timeout: Duration) async -> Bool {
        let startedAt = ContinuousClock.now
        var previous: (didAdd: Int, media: Int)?
        while !Task.isCancelled {
            let sample = (didAddItemCount, (device.mediaFiles ?? []).count)
            if let previous, previous == sample {
                return true
            }
            if previous != nil {
                OtosLog.fileAccess.noticeOperation("camera.enumerate", phase: "batch", fields: [
                    "identity": identity.rawValue,
                    "count": "\(sample.1)",
                ])
            }
            previous = sample
            if DiagnosticsTiming.milliseconds(since: startedAt) >= DiagnosticsTiming.milliseconds(timeout) {
                return false
            }
            do {
                // time: deadline — ImageCaptureCore reports no fact that the list is whole (`catalogSettleLimit`)
                try await Task.sleep(for: Self.catalogSettleSampleInterval)
            } catch {
                return false
            }
        }
        return false
    }

    private func catalogItem(for file: ICCameraFile) -> DeviceCameraCatalogItem? {
        guard file.fileSize >= 0 else {
            return nil
        }
        // An item's path is its identity (ADR 0008), so an item the camera gives no name
        // has none that would survive the next enumeration; it is not cataloged.
        guard let name = CameraItemNaming.name(listed: file.name, created: file.createdFilename) else {
            OtosLog.fileAccess.noticeOperation("camera.inventory", phase: "unnamedItemSkipped", fields: [
                "identity": identity.rawValue,
                "fileSize": "\(file.fileSize)",
            ])
            return nil
        }
        let relativePath = cameraRelativePath(for: file, name: name)
        let fileExtension = MediaRelativePath(rawValue: name).fileExtension
        let contentType = fileExtension.isEmpty ? nil : UTType(filenameExtension: fileExtension)
        guard MediaEligibility.isCatalogMedia(contentType: contentType) else {
            return nil
        }
        return DeviceCameraCatalogItem(
            relativePath: MediaRelativePath(rawValue: relativePath),
            name: name,
            contentTypeIdentifier: contentType?.identifier,
            byteSize: Int64(file.fileSize),
            captureDate: CameraFileDate.captureDate(file),
            modificationDate: CameraFileDate.modificationDate(file)
        )
    }

    private func cameraRelativePath(for file: ICCameraFile, name: String) -> String {
        let folderComponents = parentFolderComponents(for: file)
        guard !folderComponents.isEmpty else {
            return name
        }
        return (folderComponents + [name]).joined(separator: "/")
    }

    private func parentFolderComponents(for file: ICCameraFile) -> [String] {
        var components: [String] = []
        var folder = file.parentFolder
        while let current = folder {
            if let name = firstNonEmpty(current.name), name != "/" {
                components.insert(name, at: 0)
            }
            folder = current.parentFolder
        }
        return components
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values.lazy.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first
    }
}

extension DeviceCameraSession: CameraCatalogSource {
    func answersRangedReads(relativePath: MediaRelativePath, size: UInt64) async -> Bool {
        await CameraMetadataReader.isRangeCapable(session: self, relativePath: relativePath, size: size)
    }
}

extension DeviceCameraSession: ICCameraDeviceDelegate {
    /// Readiness Otos waits for is the complete catalog, reported below.
    nonisolated func deviceDidBecomeReady(_ device: ICDevice) {}

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        // The framework error is reduced to a Sendable value at the boundary rather
        // than carried inward: callers of this session only ever see its own typed
        // failures, and the framework's description survives in the log line below.
        events.yield(.opened(frameworkErrorDescription: error.map { String(describing: $0) }))
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        events.yield(.closed)
    }

    /// Otos shows no device status; open and close arrive through their own reports.
    nonisolated func device(_ device: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus: Any]) {}

    /// Every request Otos makes reports its own failure through its completion; this
    /// unsolicited report answers nothing Otos asked.
    nonisolated func device(_ device: ICDevice, didEncounterError error: (any Error)?) {}

    nonisolated func didRemove(_ device: ICDevice) {
        events.yield(.closed)
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd item: ICCameraItem) {
        events.yield(.itemsAdded(1))
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        events.yield(.itemsAdded(items.count))
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        events.yield(.itemsChanged)
    }

    /// A renamed item has a new relative path, which only a pass can record.
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        events.yield(.itemsChanged)
    }

    /// Thumbnails and metadata are read by request (`requestThumbnailData`, ranged
    /// reads), each with its own completion; these unsolicited deliveries are not used.
    nonisolated func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveThumbnail thumbnail: CGImage?,
        for item: ICCameraItem,
        error: (any Error)?
    ) {}

    nonisolated func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveMetadata metadata: [AnyHashable: Any]?,
        for item: ICCameraItem,
        error: (any Error)?
    ) {}

    /// Capabilities are read when they are used (delete, eject), so a change needs no report.
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}

    /// Delivered on the framework's own `ICDeviceOperationQueue`, not the main thread —
    /// the callback whose main-actor assertion trapped the process. Otos consumes no PTP
    /// events, so it stays empty; it must stay `nonisolated`.
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    /// A lifted restriction is followed by the items' own add reports and the catalog's
    /// completion; a new one surfaces as the requests that then fail.
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}

    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        events.yield(.catalogComplete)
    }
}

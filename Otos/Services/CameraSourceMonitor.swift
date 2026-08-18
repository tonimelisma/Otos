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

@MainActor
final class CameraSourceMonitor: NSObject {
    private let browser = ICDeviceBrowser()
    private let onAttach: @MainActor @Sendable (DeviceCameraSession) -> Void
    private let onDetach: @MainActor @Sendable (String) -> Void
    private var sessionsByIdentity: [String: DeviceCameraSession] = [:]
    private var identitiesByDevice: [ObjectIdentifier: String] = [:]
    private var isStarted = false

    init(
        onAttach: @escaping @MainActor @Sendable (DeviceCameraSession) -> Void,
        onDetach: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.onAttach = onAttach
        self.onDetach = onDetach
        super.init()
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
            device: device
        )
        sessionsByIdentity[identity] = session
        identitiesByDevice[ObjectIdentifier(device)] = identity
        onAttach(session)
    }

    private func detach(_ device: ICCameraDevice) {
        let identity = identitiesByDevice.removeValue(forKey: ObjectIdentifier(device))
            ?? Self.identity(for: device)
        sessionsByIdentity.removeValue(forKey: identity)?.close()
        onDetach(identity)
    }

    private nonisolated static func identity(for device: ICCameraDevice) -> String {
        let rawIdentity = firstNonEmpty(
            device.persistentIDString,
            device.serialNumberString,
            device.uuidString
        )
        if let rawIdentity {
            return "camera:\(rawIdentity)"
        }
        let display = firstNonEmpty(device.name, device.locationDescription) ?? "connected-camera"
        return "camera:transient:\(sanitize(display))"
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

extension CameraSourceMonitor: @preconcurrency ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else {
            return
        }
        attach(camera)
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard let camera = device as? ICCameraDevice else {
            return
        }
        detach(camera)
    }

    func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        OtosLog.fileAccess.debug("ImageCapture camera browser finished local enumeration")
    }
}

@MainActor
final class DeviceCameraSession: NSObject {
    let identity: String
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

    init(identity: String, displayName: String, device: ICCameraDevice) {
        self.identity = identity
        self.displayName = displayName
        self.device = device
        stagingRootURL = Self.stagingRootURL(identity: identity)
        super.init()
        device.delegate = self
    }

    func catalogSnapshot() async throws -> DeviceCameraCatalogSnapshot {
        let started = ContinuousClock().now
        OtosLog.fileAccess.noticeOperation("camera.enumerate", phase: "start", fields: [
            "identity": identity,
        ])
        try await openAndWaitForCatalogReady()
        let isStable = await waitForCatalogStability(timeout: .seconds(30))
        let items = currentCatalogItems()
        let elapsedMs = DiagnosticsTiming.milliseconds(from: started, to: .now)
        OtosLog.fileAccess.noticeOperation("camera.enumerate", phase: "finish", fields: [
            "identity": identity,
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
        let files = (device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        var collisionCounts: [String: Int] = [:]
        var items: [DeviceCameraCatalogItem] = []
        filesByRelativePath.removeAll(keepingCapacity: true)
        for file in files {
            guard let item = catalogItem(for: file, collisionCounts: &collisionCounts) else {
                continue
            }
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
                guard let name = firstNonEmpty(
                    cameraFile.originalFilename,
                    cameraFile.name,
                    cameraFile.createdFilename
                ) else {
                    continue
                }
                guard let kind = MediaCompanionKind.recognize(
                    fileExtension: URL(fileURLWithPath: name).pathExtension
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
                let modified = validCameraDate(cameraFile.modificationDate)
                    ?? validCameraDate(cameraFile.fileModificationDate)
                    ?? validCameraDate(cameraFile.exifModificationDate)
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
            file.requestThumbnailData(options: [
                ICCameraItemThumbnailOption.imageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    func download(relativePath: MediaRelativePath, to destinationURL: URL) async throws {
        guard let file = filesByRelativePath[relativePath] else {
            throw DeviceCameraSessionError.itemUnavailable(relativePath.rawValue)
        }
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
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                file.requestDownload(options: downloadOptions) { savedFilename, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let savedFilename,
                       savedFilename != destinationURL.lastPathComponent
                    { // swiftlint:disable:this opening_brace
                        let savedURL = destinationURL.deletingLastPathComponent().appending(path: savedFilename)
                        try? FileManager.default.removeItem(at: destinationURL)
                        try? FileManager.default.moveItem(at: savedURL, to: destinationURL)
                    }
                    continuation.resume(returning: ())
                }
            }
        } catch {
            OtosLog.fileAccess.errorOperation("camera.download", phase: "failed", fields: [
                "relativePath": relativePath.rawValue,
                "error": String(describing: error),
            ])
            throw error
        }
        let elapsedMs = DiagnosticsTiming.milliseconds(from: started, to: .now)
        let bytes = (try? destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        OtosLog.fileAccess.noticeOperation("camera.download", phase: "finish", fields: [
            "relativePath": relativePath.rawValue,
            "bytes": "\(bytes)",
            "elapsedMs": "\(elapsedMs)",
        ])
    }

    func file(for relativePath: MediaRelativePath) -> ICCameraFile? {
        filesByRelativePath[relativePath]
    }

    /// Revalidates planned size/date against live `ICCameraFile` facts (ARC-049).
    func revalidate(
        relativePath: MediaRelativePath,
        byteSize: Int64?,
        modifiedAt: Date?
    ) -> Bool {
        guard !isClosed, device.hasOpenSession, let file = filesByRelativePath[relativePath] else {
            logRevalidateMiss(relativePath: relativePath, reason: "sourceNotReady")
            return false
        }
        if let byteSize {
            guard file.fileSize >= 0, Int64(file.fileSize) == byteSize else {
                logRevalidateMiss(relativePath: relativePath, reason: "sizeMismatch")
                return false
            }
        }
        if let modifiedAt {
            let live = validCameraDate(file.modificationDate)
                ?? validCameraDate(file.fileModificationDate)
                ?? validCameraDate(file.exifModificationDate)
                ?? validCameraDate(file.creationDate)
                ?? validCameraDate(file.exifCreationDate)
                ?? validCameraDate(file.fileCreationDate)
            guard let live, abs(live.timeIntervalSince(modifiedAt)) < 1.0 else {
                logRevalidateMiss(relativePath: relativePath, reason: "dateMismatch")
                return false
            }
        }
        return true
    }

    private func logRevalidateMiss(relativePath: MediaRelativePath, reason: String) {
        OtosLog.fileAccess.noticeOperation("camera.revalidate", phase: "miss", fields: [
            "identity": identity,
            "relativePath": relativePath.rawValue,
            "reason": reason,
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
            _ = device.requestDeleteFiles(
                [file],
                deleteFailed: { _ in },
                completion: { _, error in
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
            try await requestOpenSession(timeout: .seconds(10))
        }
        try await waitForCatalogReady(timeout: .seconds(240))
    }

    private func requestOpenSession(timeout: Duration) async throws {
        let timeoutTask = Task { [weak self] in
            do {
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
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters.values {
            waiter.continuation.resume(throwing: error)
        }
    }

    private func markCatalogReady() {
        isCatalogReady = true
        resolveWaiters(condition: .catalogReady, result: .success(()))
    }

    private func waitForCatalogStability(timeout: Duration) async -> Bool {
        let startedAt = Date()
        var previous: (didAdd: Int, media: Int)?
        while !Task.isCancelled {
            let sample = (didAddItemCount, (device.mediaFiles ?? []).count)
            if let previous, previous == sample {
                return true
            }
            if previous != nil {
                OtosLog.fileAccess.noticeOperation("camera.enumerate", phase: "batch", fields: [
                    "identity": identity,
                    "count": "\(sample.1)",
                ])
            }
            previous = sample
            if DiagnosticsTiming.milliseconds(since: startedAt) >= DiagnosticsTiming.milliseconds(timeout) {
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return false
            }
        }
        return false
    }

    private func catalogItem(
        for file: ICCameraFile,
        collisionCounts: inout [String: Int]
    ) -> DeviceCameraCatalogItem? {
        guard file.fileSize >= 0 else {
            return nil
        }
        let name = firstNonEmpty(file.originalFilename, file.name, file.createdFilename)
            ?? "camera-item-\(itemsHashSeed(file))"
        let baseRelativePath = cameraRelativePath(for: file, name: name)
        let collisionIndex = collisionCounts[baseRelativePath, default: 0]
        collisionCounts[baseRelativePath] = collisionIndex + 1
        let relativePath = collisionIndex == 0
            ? baseRelativePath
            : baseRelativePath + "#\(collisionIndex + 1)"
        let captureDate = validCameraDate(file.creationDate)
            ?? validCameraDate(file.exifCreationDate)
            ?? validCameraDate(file.fileCreationDate)
            ?? validCameraDate(file.modificationDate)
            ?? validCameraDate(file.fileModificationDate)
            ?? validCameraDate(file.exifModificationDate)
        let contentType = URL(fileURLWithPath: name).pathExtension.isEmpty
            ? nil
            : UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension)
        guard MediaEligibility.isCatalogMedia(contentType: contentType) else {
            return nil
        }
        return DeviceCameraCatalogItem(
            relativePath: MediaRelativePath(rawValue: relativePath),
            name: name,
            contentTypeIdentifier: contentType?.identifier,
            byteSize: Int64(file.fileSize),
            captureDate: captureDate
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

    private func validCameraDate(_ date: Date?) -> Date? {
        guard let date, abs(date.timeIntervalSince1970) >= 0.001 else {
            return nil
        }
        return date
    }

    private func itemsHashSeed(_ file: ICCameraFile) -> String {
        String(UInt(bitPattern: Unmanaged.passUnretained(file).toOpaque()))
    }

    private static func stagingRootURL(identity: String) -> URL {
        let caches = (try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let root = caches
            .appending(path: "net.melisma.Otos", directoryHint: .isDirectory)
            .appending(path: "DeviceStaging", directoryHint: .isDirectory)
            .appending(path: CameraSourceMonitor.sanitize(identity), directoryHint: .isDirectory)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(values)
        return root
    }
}

extension DeviceCameraSession: @preconcurrency ICCameraDeviceDelegate {
    func deviceDidBecomeReady(_ device: ICDevice) {}

    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        if let error {
            sessionOpenResult = .failure(error)
            resolveWaiters(condition: .open, result: .failure(error))
            OtosLog.fileAccess.errorOperation("camera.session", phase: "openFailed", fields: [
                "identity": identity,
                "error": String(describing: error),
            ])
        } else {
            sessionOpenResult = .success(())
            resolveWaiters(condition: .open, result: .success(()))
            OtosLog.fileAccess.noticeOperation("camera.session", phase: "open", fields: [
                "identity": identity,
            ])
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        failAllWaiters(error ?? DeviceCameraSessionError.disconnected)
        OtosLog.fileAccess.noticeOperation("camera.session", phase: "close", fields: [
            "identity": identity,
        ])
    }

    func device(_ device: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus: Any]) {}

    func device(_ device: ICDevice, didEncounterError error: (any Error)?) {}

    func didRemove(_ device: ICDevice) {
        failAllWaiters(DeviceCameraSessionError.disconnected)
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd item: ICCameraItem) {
        didAddItemCount += 1
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        didAddItemCount += items.count
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}

    func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveThumbnail thumbnail: CGImage?,
        for item: ICCameraItem,
        error: (any Error)?
    ) {}

    func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveMetadata metadata: [AnyHashable: Any]?,
        for item: ICCameraItem,
        error: (any Error)?
    ) {}

    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        markCatalogReady()
    }
}

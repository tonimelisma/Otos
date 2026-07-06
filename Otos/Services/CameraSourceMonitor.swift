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
        onAttach(session)
    }

    private func detach(_ device: ICCameraDevice) {
        let identity = Self.identity(for: device)
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
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
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

    func catalogItems() async throws -> [DeviceCameraCatalogItem] {
        try await openAndWaitForCatalog()
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
    }

    func close() {
        isClosed = true
        if device.hasOpenSession {
            device.requestCloseSession()
        }
    }

    private func openAndWaitForCatalog() async throws {
        if isClosed {
            throw DeviceCameraSessionError.disconnected
        }
        if !device.hasOpenSession {
            try await requestOpenSession(timeout: .seconds(10))
        }
        try await waitForCatalogReady(timeout: .seconds(240))
        try await Task.sleep(for: .milliseconds(250))
    }

    private func requestOpenSession(timeout: Duration) async throws {
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                self?.resumeOpenContinuation(.failure(DeviceCameraSessionError.openTimedOut))
            } catch is CancellationError {
                return
            }
        }
        defer { timeoutTask.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            openContinuation = continuation
            device.requestOpenSession()
        }
    }

    private func waitForCatalogReady(timeout: Duration) async throws {
        if !(device.mediaFiles ?? []).isEmpty {
            return
        }
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                self?.resumeReadyContinuation(.failure(DeviceCameraSessionError.catalogTimedOut))
            } catch is CancellationError {
                return
            }
        }
        defer { timeoutTask.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyContinuation = continuation
        }
    }

    private func resumeOpenContinuation(_ result: Result<Void, Error>) {
        guard let continuation = openContinuation else {
            return
        }
        openContinuation = nil
        continuation.resume(with: result)
    }

    private func resumeReadyContinuation(_ result: Result<Void, Error>) {
        guard let continuation = readyContinuation else {
            return
        }
        readyContinuation = nil
        continuation.resume(with: result)
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
            resumeOpenContinuation(.failure(error))
        } else {
            resumeOpenContinuation(.success(()))
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        isClosed = true
    }

    func device(_ device: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus: Any]) {}

    func device(_ device: ICDevice, didEncounterError error: (any Error)?) {}

    func didRemove(_ device: ICDevice) {
        isClosed = true
        resumeOpenContinuation(.failure(DeviceCameraSessionError.disconnected))
        resumeReadyContinuation(.failure(DeviceCameraSessionError.disconnected))
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd item: ICCameraItem) {}

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}

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
        resumeReadyContinuation(.success(()))
    }
}

import Foundation
import ImageCaptureCore
import OSLog

/// Routes byte materialization for MTP-backed virtual roots.
///
/// A camera row's `MediaAssetID.fileURL` points into the local staging directory.
/// Before a file is staged that URL is simply absent, matching the existing
/// not-materialized enrichment path. This registry is the narrow bridge that turns
/// a missing staging URL into one ImageCapture download while every non-device URL
/// keeps using `FileMaterialization`.
@MainActor
final class DeviceStagingRegistry {
    private let freeSpaceFloorBytes: Int64 = 10 * 1024 * 1024 * 1024
    private var sessionsByIdentity: [String: DeviceCameraSession] = [:]

    init() {}

    func register(_ session: DeviceCameraSession) {
        sessionsByIdentity[session.identity] = session
    }

    func unregister(identity: String) {
        sessionsByIdentity.removeValue(forKey: identity)
        deleteStaging(identity: identity)
    }

    func materialize(_ url: URL) async -> MaterializationResult? {
        guard let route = route(for: url) else {
            return nil
        }
        let start = Date()
        let path = url.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: path) {
            return MaterializationResult(outcome: .alreadyMaterialized, rerequestCount: 0, elapsedMs: 0)
        }
        guard hasEnoughFreeSpace(for: route.session.stagingRootURL) else {
            OtosLog.fileAccess.error(
                "Device staging paused for low free space identity=\(route.session.identity, privacy: .public)"
            )
            return MaterializationResult(
                outcome: .insufficientLocalSpace,
                rerequestCount: 0,
                elapsedMs: DiagnosticsTiming.milliseconds(since: start)
            )
        }
        do {
            try await download(route: route, destinationURL: url)
            return MaterializationResult(
                outcome: .materialized,
                rerequestCount: 0,
                elapsedMs: DiagnosticsTiming.milliseconds(since: start)
            )
        } catch {
            OtosLog.fileAccess.error(
                """
                Device staging download failed identity=\(route.session.identity, privacy: .public) \
                relativePath=\(route.relativePath.rawValue, privacy: .public) \
                error=\(String(describing: error), privacy: .public)
                """
            )
            return MaterializationResult(
                outcome: .requestFailed,
                rerequestCount: 0,
                elapsedMs: DiagnosticsTiming.milliseconds(since: start)
            )
        }
    }

    private struct Route {
        let session: DeviceCameraSession
        let relativePath: MediaRelativePath
    }

    private func route(for url: URL) -> Route? {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let matches = sessionsByIdentity.values.compactMap { session -> (DeviceCameraSession, String)? in
            let root = session.stagingRootURL.standardizedFileURL.path(percentEncoded: false)
            guard path.hasPrefix(root + "/") else {
                return nil
            }
            return (session, String(path.dropFirst(root.count + 1)))
        }
        guard let match = matches.max(by: { left, right in
            left.0.stagingRootURL.path(percentEncoded: false).count
                < right.0.stagingRootURL.path(percentEncoded: false).count
        }) else {
            return nil
        }
        return Route(session: match.0, relativePath: MediaRelativePath(rawValue: match.1))
    }

    private func download(route: Route, destinationURL: URL) async throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tempURL = destinationURL.deletingLastPathComponent()
            .appending(path: ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        try? FileManager.default.removeItem(at: tempURL)
        try await route.session.download(relativePath: route.relativePath, to: tempURL)
        if FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        }
    }

    private func hasEnoughFreeSpace(for url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else {
            return true
        }
        return available >= freeSpaceFloorBytes
    }

    static func sweepAbsentDeviceStaging(exceptIdentities: Set<String> = []) async {
        await Task.detached(priority: .utility) {
            sweepAbsentDeviceStagingSynchronously(exceptIdentities: exceptIdentities)
        }.value
    }

    private nonisolated static func sweepAbsentDeviceStagingSynchronously(exceptIdentities: Set<String>) {
        let root = Self.deviceStagingRootURL()
        let skippedNames = Set(exceptIdentities.map(CameraSourceMonitor.sanitize))
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return
        }
        for url in contents {
            let identity = url.lastPathComponent
            guard !skippedNames.contains(identity) else {
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func deleteStaging(identity: String) {
        let url = Self.deviceStagingRootURL()
            .appending(path: CameraSourceMonitor.sanitize(identity), directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: url)
    }

    private nonisolated static func deviceStagingRootURL() -> URL {
        let caches = (try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return caches
            .appending(path: "net.melisma.Otos", directoryHint: .isDirectory)
            .appending(path: "DeviceStaging", directoryHint: .isDirectory)
    }

    // MARK: - Import gateway (ARC-049)

    /// Builds a Sendable import gateway over the live session map.
    func makeCameraImportAccess() -> CameraImportAccess {
        CameraImportAccess(
            revalidate: { [weak self] identity, relativePath, byteSize, modifiedAt in
                await MainActor.run {
                    self?.sessionsByIdentity[identity]?.revalidate(
                        relativePath: relativePath,
                        byteSize: byteSize,
                        modifiedAt: modifiedAt
                    ) ?? false
                }
            },
            ensureBytes: { [weak self] identity, relativePath, enrichmentURL, importStagingURL in
                await self?.ensureImportBytes(
                    identity: identity,
                    relativePath: relativePath,
                    enrichmentURL: enrichmentURL,
                    importStagingURL: importStagingURL
                ) ?? .failed("cameraRegistryGone")
            },
            deleteItem: { [weak self] identity, relativePath in
                guard let registry = self else { return false }
                return await registry.sessionsByIdentity[identity]?.deleteItem(relativePath: relativePath) ?? false
            },
            canDelete: { [weak self] identity in
                await MainActor.run {
                    self?.sessionsByIdentity[identity]?.canDeleteOneFile ?? false
                }
            },
            eject: { [weak self] identity in
                guard let registry = self else { return .failed(description: "cameraGone") }
                return await registry.sessionsByIdentity[identity]?.eject()
                    ?? .failed(description: "cameraGone")
            }
        )
    }

    private func ensureImportBytes(
        identity: String,
        relativePath: MediaRelativePath,
        enrichmentURL: URL,
        importStagingURL: URL
    ) async -> CameraByteOutcome {
        guard let session = sessionsByIdentity[identity] else {
            return .failed("cameraSessionMissing")
        }
        try? FileManager.default.createDirectory(
            at: importStagingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: enrichmentURL.path),
           let size = try? enrichmentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           let file = session.file(for: relativePath),
           file.fileSize >= 0,
           Int64(size) == Int64(file.fileSize) {
            let source = enrichmentURL
            let destination = importStagingURL
            let outcome = await withCheckedContinuation {
                (continuation: CheckedContinuation<CopyfileTransfer.Outcome, Never>) in
                Task.detached {
                    let copyOutcome = CopyfileTransfer.copy(
                        from: source,
                        to: destination,
                        onProgress: { _ in },
                        shouldContinue: { true }
                    )
                    continuation.resume(returning: copyOutcome)
                }
            }
            switch outcome {
            case .completed:
                OtosLog.fileAccess.notice(
                    // swiftlint:disable:next line_length
                    "op=mediaOperation.camera phase=reuseEnrichmentStaging path=\(relativePath.rawValue, privacy: .public)"
                )
                return .completed
            case .cancelled:
                return .cancelled
            case let .failed(message):
                return .failed(message)
            }
        }
        do {
            try await session.download(relativePath: relativePath, to: importStagingURL)
            return .completed
        } catch {
            return .failed(String(describing: error))
        }
    }
}

/// Outcome of placing camera bytes into import staging.
nonisolated enum CameraByteOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case failed(String)
}

/// Camera-side import hooks used by `MediaImportExecutor` (ARC-049).
nonisolated struct CameraImportAccess: Sendable {
    private let revalidate: @Sendable (String, MediaRelativePath, Int64?, Date?) async -> Bool
    private let ensureBytes: @Sendable (String, MediaRelativePath, URL, URL) async -> CameraByteOutcome
    private let deleteItemHook: @Sendable (String, MediaRelativePath) async -> Bool
    private let canDeleteHook: @Sendable (String) async -> Bool
    private let ejectHook: @Sendable (String) async -> RemovableEjectOutcome

    init(
        revalidate: @escaping @Sendable (String, MediaRelativePath, Int64?, Date?) async -> Bool,
        ensureBytes: @escaping @Sendable (String, MediaRelativePath, URL, URL) async -> CameraByteOutcome,
        deleteItem: @escaping @Sendable (String, MediaRelativePath) async -> Bool,
        canDelete: @escaping @Sendable (String) async -> Bool,
        eject: @escaping @Sendable (String) async -> RemovableEjectOutcome
    ) {
        self.revalidate = revalidate
        self.ensureBytes = ensureBytes
        deleteItemHook = deleteItem
        canDeleteHook = canDelete
        ejectHook = eject
    }

    func revalidateItem(
        identity: String,
        relativePath: MediaRelativePath,
        byteSize: Int64?,
        modifiedAt: Date?
    ) async -> Bool {
        await revalidate(identity, relativePath, byteSize, modifiedAt)
    }

    func ensureImportBytes(
        identity: String,
        relativePath: MediaRelativePath,
        enrichmentURL: URL,
        importStagingURL: URL
    ) async -> CameraByteOutcome {
        await ensureBytes(identity, relativePath, enrichmentURL, importStagingURL)
    }

    func deleteItem(identity: String, relativePath: MediaRelativePath) async -> Bool {
        await deleteItemHook(identity, relativePath)
    }

    func canDelete(identity: String) async -> Bool {
        await canDeleteHook(identity)
    }

    func eject(identity: String) async -> RemovableEjectOutcome {
        await ejectHook(identity)
    }
}

import Foundation
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

    init() {
        sweepAbsentDeviceStaging()
    }

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
                outcome: .timedOut,
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

    private func sweepAbsentDeviceStaging() {
        let root = Self.deviceStagingRootURL()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return
        }
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func deleteStaging(identity: String) {
        let url = Self.deviceStagingRootURL()
            .appending(path: CameraSourceMonitor.sanitize(identity), directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: url)
    }

    private static func deviceStagingRootURL() -> URL {
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
}

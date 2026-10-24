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
    private var sessionsByIdentity: [String: DeviceCameraSession] = [:]

    init() {}

    func register(_ session: DeviceCameraSession) {
        sessionsByIdentity[session.identity] = session
    }

    /// Drops the live session but **keeps** the staged bytes. They were already
    /// transferred off the camera, so discarding them on eject would re-download the
    /// whole device on the next attach — tens of gigabytes for a full card. Staging
    /// lives for the session and is cleared at app close, with a startup sweep as the
    /// crash-safe backstop (APP-018, owner decision 2026-08-30).
    func unregister(identity: String) {
        sessionsByIdentity.removeValue(forKey: identity)
    }

    func materialize(_ url: URL) async -> MaterializationResult? {
        guard let route = route(for: url) else {
            return nil
        }
        let start = ContinuousClock.now
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
            var fields = ErrorDiagnostics.fields(for: error)
            fields["identity"] = route.session.identity
            fields["relativePath"] = route.relativePath.rawValue
            fields["stagingRoot"] = route.session.stagingRootURL.path(percentEncoded: false)
            OtosLog.fileAccess.errorOperation("camera.staging", phase: "failed", fields: fields)
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

    /// The path of `url` relative to `root`, or nil when it does not live under it.
    /// Pure and static so the prefix rule can be tested without a camera session —
    /// the rule that silently broke all MTP staging was never covered by one.
    nonisolated static func stagingRelativePath(of url: URL, under root: URL) -> String? {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        var rootPath = root.standardizedFileURL.path(percentEncoded: false)
        while rootPath.hasSuffix("/") {
            rootPath.removeLast()
        }
        guard path.hasPrefix(rootPath + "/") else {
            return nil
        }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func route(for url: URL) -> Route? {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let matches = sessionsByIdentity.values.compactMap { session -> (DeviceCameraSession, String)? in
            // `stagingRootURL` is a directory URL, so its path already ends in "/".
            // Appending another produced a "…/root//" prefix that no requested path
            // could ever match, so every camera file fell through to the *cloud*
            // materialization path and failed there as a permission error on a path
            // that does not exist — which is what MTP staging silently did.
            guard let relative = Self.stagingRelativePath(of: url, under: session.stagingRootURL) else {
                return nil
            }
            return (session, relative)
        }
        guard let match = matches.max(by: { left, right in
            left.0.stagingRootURL.path(percentEncoded: false).count
                < right.0.stagingRootURL.path(percentEncoded: false).count
        }) else {
            // No registered session owns this path, so the caller falls through to the
            // *cloud* materialization path and asks the File Provider to download a
            // camera file — which fails as a permission error on a path that does not
            // exist, saying nothing about the real cause. Report the mismatch itself:
            // the path asked for, and every root actually registered.
            OtosLog.fileAccess.errorOperation("camera.staging", phase: "noRoute", fields: [
                "requestedPath": path,
                "registeredRoots": sessionsByIdentity.values
                    .map { $0.stagingRootURL.standardizedFileURL.path(percentEncoded: false) }
                    .sorted()
                    .joined(separator: ","),
                "registeredCount": "\(sessionsByIdentity.count)",
            ])
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
        // The same promise the import executor keeps (ADR 0027), from the
        // same constant. The file's own size is not known at this seam, so
        // a stage may finish just below the floor; it never starts below it.
        return available >= FreeSpaceFloor.bytes
    }

    /// A Sendable resolver from a device root to its live session.
    ///
    /// Enrichment needs a session to read ranges from, and the coordinator is an actor that
    /// cannot reach this `@MainActor` registry directly. The same shape as
    /// `CameraImportAccess`: a value that closes over the registry weakly, so a detached
    /// camera resolves to nil rather than keeping a dead session alive.
    func makeCameraRangeAccess() -> CameraRangeAccess {
        CameraRangeAccess { [weak self] rootPath in
            await MainActor.run {
                self?.sessionsByIdentity.values.first {
                    (try? CatalogPath.normalizedDirectoryPath(for: $0.stagingRootURL)) == rootPath
                }
            }
        }
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
                    ) ?? .sourceNotReady
                }
            },
            ensureBytes: { [weak self] identity, relativePath, enrichmentURL, destinationTempURL in
                await self?.ensureImportBytes(
                    identity: identity,
                    relativePath: relativePath,
                    enrichmentURL: enrichmentURL,
                    destinationTempURL: destinationTempURL
                ) ?? .failed(.other("cameraRegistryGone"))
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
        destinationTempURL: URL
    ) async -> CameraByteOutcome {
        guard let session = sessionsByIdentity[identity] else {
            return .failed(.other("cameraSessionMissing"))
        }
        try? FileManager.default.createDirectory(
            at: destinationTempURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: enrichmentURL.path),
           let size = try? enrichmentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           let file = session.file(for: relativePath),
           file.fileSize >= 0,
           Int64(size) == Int64(file.fileSize)
        {
            let source = enrichmentURL
            let destination = destinationTempURL
            let outcome: CopyfileTransfer.Outcome = await withCheckedContinuation { continuation in
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
                    "op=mediaOperation.camera phase=reuseEnrichmentStaging path=\(relativePath.rawValue, privacy: .public)"
                )
                return .completed
            case .cancelled:
                return .cancelled
            case let .failed(code):
                return .failed(code == ENOSPC ? .outOfSpace : .other("copyfile errno=\(code)"))
            }
        }
        do {
            try await session.download(relativePath: relativePath, to: destinationTempURL)
            return .completed
        } catch {
            return .failed(CameraByteFailure(error))
        }
    }
}

/// Outcome of placing camera bytes into import staging.
nonisolated enum CameraByteOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case failed(CameraByteFailure)
}

/// Why camera bytes could not be staged. `outOfSpace` is the one cause the
/// executor acts on: the staging volume is the destination volume, so a write
/// refused for space is the disk floor reached the hard way (ADR 0027) and stops
/// the run rather than counting the entry as failed — the same as a refused
/// `copyfile` on a card. Everything else stays a per-entry failure whose detail
/// is for the log.
nonisolated enum CameraByteFailure: Equatable, Sendable {
    case outOfSpace
    case other(String)

    /// Classifies a download error by its typed chain, never by its wording:
    /// Foundation's `NSFileWriteOutOfSpaceError` or a POSIX `ENOSPC` anywhere in
    /// the underlying-error chain is out of space. An error that carries neither
    /// is `other`, whatever it says — the shape ImageCaptureCore uses for a full
    /// disk has not been observed, and this does not guess at it.
    init(_ error: Error) {
        self = Self.isOutOfSpace(error as NSError) ? .outOfSpace : .other(String(describing: error))
    }

    private static func isOutOfSpace(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isOutOfSpace(underlying)
        }
        return false
    }
}

/// Camera-side import hooks used by `MediaImportExecutor` (ARC-049).
nonisolated struct CameraImportAccess: Sendable {
    private let revalidate: @Sendable (String, MediaRelativePath, Int64?, Date?) async -> SourceValidation
    private let ensureBytes: @Sendable (String, MediaRelativePath, URL, URL) async -> CameraByteOutcome
    private let deleteItemHook: @Sendable (String, MediaRelativePath) async -> Bool
    private let canDeleteHook: @Sendable (String) async -> Bool
    private let ejectHook: @Sendable (String) async -> RemovableEjectOutcome

    init(
        revalidate: @escaping @Sendable (String, MediaRelativePath, Int64?, Date?) async -> SourceValidation,
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
    ) async -> SourceValidation {
        await revalidate(identity, relativePath, byteSize, modifiedAt)
    }

    func ensureImportBytes(
        identity: String,
        relativePath: MediaRelativePath,
        enrichmentURL: URL,
        destinationTempURL: URL
    ) async -> CameraByteOutcome {
        await ensureBytes(identity, relativePath, enrichmentURL, destinationTempURL)
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

/// Resolves a device root to its live camera session, for enrichment's ranged reads.
///
/// `DeviceCameraSession` is `@MainActor` and therefore `Sendable`, so it can cross to the
/// enrichment actor freely; the non-`Sendable` `ICCameraFile` never does, because every
/// read goes back through the session.
nonisolated struct CameraRangeAccess: Sendable {
    private let resolve: @Sendable (LibraryRootPath) async -> DeviceCameraSession?

    init(resolve: @escaping @Sendable (LibraryRootPath) async -> DeviceCameraSession?) {
        self.resolve = resolve
    }

    func session(for rootPath: LibraryRootPath) async -> DeviceCameraSession? {
        await resolve(rootPath)
    }
}

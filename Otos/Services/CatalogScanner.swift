import Foundation
import OSLog
import UniformTypeIdentifiers

/// Catalog scanner guide
///
/// The scanner performs one read-only, idempotent filesystem observation. It
/// enumerates regular files, collects only the approved URL resource values, and
/// flushes observed facts on a time cadence through the Store-owned batch
/// callback. It never decides persistence, deletion, UI state, or media
/// eligibility.
///
/// Why metadata only and never file bytes: most media lives in cloud-synced folders
/// as dataless placeholders. Reading a file's resource values (name, size, dates,
/// type) is free, but reading its bytes would force the provider to download it,
/// potentially gigabytes. The scanner reads facts, never content.
///
/// A returned path set proves the completed observation used for reconciliation.
/// Cancellation or any filesystem issue prevents that success return, so Store
/// preserves earlier rows. Package descendants and symlinks are skipped before
/// they can expand traversal beyond the regular-file catalog contract.
nonisolated struct CatalogScanner {
    var scanRoot: @Sendable (
        _ rootPath: LibraryRootPath,
        _ cadence: Duration,
        _ diagnostics: CatalogDiagnostics?,
        _ batchHandler: @Sendable ([ScannedMediaFile]) async throws -> Void
    ) async throws -> Set<MediaRelativePath>

    static let live = CatalogScanner { rootPath, cadence, diagnostics, batchHandler in
        try await LiveCatalogScanner.scan(
            rootPath: rootPath,
            cadence: cadence,
            diagnostics: diagnostics,
            batchHandler: batchHandler
        )
    }
}

nonisolated enum CatalogScanError: Error {
    case filesystemErrorsEncountered(Int)
}

private nonisolated enum LiveCatalogScanner {
    private struct ScanIssue {
        let kind: String
        let path: String
        let errorDescription: String
    }

    private struct SkippedPackage {
        let path: String
        let contentTypeIdentifier: String?
    }

    private struct ScanState {
        var pending: [ScannedMediaFile] = []
        var observedPaths = Set<MediaRelativePath>()
        var filesystemIssues: [ScanIssue] = []
        var skippedPackages: [SkippedPackage] = []
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .nameKey,
        .creationDateKey,
        .contentModificationDateKey,
        .fileSizeKey,
        .contentTypeKey,
    ]

    static func scan(
        rootPath: LibraryRootPath,
        cadence: Duration,
        diagnostics: CatalogDiagnostics?,
        batchHandler: @Sendable ([ScannedMediaFile]) async throws -> Void
    ) async throws -> Set<MediaRelativePath> {
        let rootURL = rootPath.url
        var scanState = ScanState()
        let clock = ContinuousClock()
        var lastFlush = clock.now

        let state = OtosSignpost.fileAccess.beginInterval("CatalogScanEnumerate")
        defer {
            OtosSignpost.fileAccess.endInterval("CatalogScanEnumerate", state)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            // Packages are directories that Finder presents as files. The
            // current catalog discovers regular files only, so descending into
            // package internals would overreach the model and can trip protected
            // app-owned stores such as Photos libraries. Camera package support
            // belongs in an explicit, tested media-container path rather than
            // in the regular-file scanner.
            options: [.skipsPackageDescendants],
            errorHandler: { url, error in
                scanState.filesystemIssues.append(
                    ScanIssue(
                        kind: "enumeration",
                        path: url.path(percentEncoded: false),
                        errorDescription: String(describing: error)
                    )
                )
                return true
            }
        ) else {
            throw CatalogStoreError.notDirectory
        }

        while let fileURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            scanFileURL(
                fileURL,
                rootPath: rootPath,
                enumerator: enumerator,
                scanState: &scanState
            )
            if lastFlush.duration(to: clock.now) >= cadence {
                try await flush(&scanState.pending, batchHandler: batchHandler)
                lastFlush = clock.now
            }
        }

        try await flush(&scanState.pending, batchHandler: batchHandler)
        await recordSkippedPackages(scanState.skippedPackages, rootPath: rootPath, diagnostics: diagnostics)
        await recordIssues(scanState.filesystemIssues, rootPath: rootPath, diagnostics: diagnostics)

        if !scanState.filesystemIssues.isEmpty {
            throw CatalogScanError.filesystemErrorsEncountered(scanState.filesystemIssues.count)
        }
        return scanState.observedPaths
    }

    private static func scanFileURL(
        _ fileURL: URL,
        rootPath: LibraryRootPath,
        enumerator: FileManager.DirectoryEnumerator,
        scanState: inout ScanState
    ) {
        do {
            guard let file = try scannedFile(
                fileURL: fileURL,
                rootPath: rootPath,
                enumerator: enumerator,
                scanState: &scanState
            ) else {
                return
            }
            scanState.pending.append(file)
            scanState.observedPaths.insert(file.relativePath)
        } catch {
            scanState.filesystemIssues.append(
                ScanIssue(
                    kind: "resource",
                    path: fileURL.path(percentEncoded: false),
                    errorDescription: String(describing: error)
                )
            )
        }
    }

    private static func scannedFile(
        fileURL: URL,
        rootPath: LibraryRootPath,
        enumerator: FileManager.DirectoryEnumerator,
        scanState: inout ScanState
    ) throws -> ScannedMediaFile? {
        let values = try fileURL.resourceValues(forKeys: resourceKeys)
        if values.isSymbolicLink == true {
            if values.isDirectory == true {
                enumerator.skipDescendants()
            }
            return nil
        }
        if values.isPackage == true {
            // The enumerator option already prevents package descendants from
            // being visited. Keep this branch so diagnostics show that the
            // package root was intentionally skipped, not silently lost.
            scanState.skippedPackages.append(
                SkippedPackage(
                    path: fileURL.path(percentEncoded: false),
                    contentTypeIdentifier: values.contentType?.identifier
                )
            )
            if values.isDirectory == true {
                enumerator.skipDescendants()
            }
            return nil
        }
        guard values.isRegularFile == true else {
            return nil
        }
        guard let relativePath = CatalogPath.relativePath(rootPath: rootPath, fileURL: fileURL) else {
            throw CatalogScannerIssue.relativePathUnavailable
        }
        return ScannedMediaFile(
            relativePath: relativePath,
            name: values.name,
            contentTypeIdentifier: values.contentType?.identifier,
            byteSize: values.fileSize.map(Int64.init),
            createdAt: values.creationDate,
            contentModifiedAt: values.contentModificationDate
        )
    }

    private static func flush(
        _ pending: inout [ScannedMediaFile],
        batchHandler: @Sendable ([ScannedMediaFile]) async throws -> Void
    ) async throws {
        guard !pending.isEmpty else {
            return
        }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        let state = OtosSignpost.fileAccess.beginInterval("CatalogScanFlush")
        defer {
            OtosSignpost.fileAccess.endInterval("CatalogScanFlush", state)
        }
        try await batchHandler(batch)
        await Task.yield()
    }

    private static func recordSkippedPackages(
        _ skippedPackages: [SkippedPackage],
        rootPath: LibraryRootPath,
        diagnostics: CatalogDiagnostics?
    ) async {
        for package in skippedPackages {
            var fields = [
                "rootPath": rootPath.rawValue,
                "path": package.path,
            ]
            if let contentTypeIdentifier = package.contentTypeIdentifier {
                fields["contentTypeIdentifier"] = contentTypeIdentifier
            }
            OtosLog.fileAccess.debug(
                """
                Catalog scan skipped package path=\(package.path, privacy: .public) \
                contentType=\(package.contentTypeIdentifier ?? "unknown", privacy: .public)
                """
            )
            await diagnostics?.record(
                operation: "catalog.scan.skippedPackage",
                phase: "skip",
                fields: fields
            )
        }
    }

    private static func recordIssues(
        _ issues: [ScanIssue],
        rootPath: LibraryRootPath,
        diagnostics: CatalogDiagnostics?
    ) async {
        for issue in issues {
            await diagnostics?.record(
                operation: "catalog.scan.issue",
                phase: "issue",
                fields: [
                    "rootPath": rootPath.rawValue,
                    "path": issue.path,
                    "kind": issue.kind,
                    "error": issue.errorDescription,
                ]
            )
        }
    }
}

private nonisolated enum CatalogScannerIssue: Error {
    case relativePathUnavailable
}

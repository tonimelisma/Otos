import Foundation
import OSLog
import UniformTypeIdentifiers

/// Catalog scanner guide
///
/// The scanner performs one read-only, idempotent filesystem observation. It
/// enumerates regular files, applies structural and media-eligibility filters,
/// collects only the approved URL resource values, and flushes observed facts on a
/// time cadence through the Store-owned batch callback. It never decides
/// persistence, deletion, or UI state.
///
/// Media eligibility: after structural guards, only regular files whose
/// `contentTypeKey` conforms to `UTType.image` or `UTType.movie` become observed
/// scan results. Nil or other types are skipped without failing the scan. See ADR
/// 0002 and `MediaEligibility`.
///
/// Why metadata only and never file bytes: most media lives in cloud-synced folders
/// as dataless placeholders. Reading a file's resource values (name, size, dates,
/// type) is free, but reading its bytes would force the provider to download it,
/// potentially gigabytes. The scanner reads facts, never content.
///
/// A returned path set proves the completed observation used for reconciliation.
/// Cancellation or any filesystem issue prevents that success return, so Store
/// preserves earlier rows. Package descendants and symlinks are skipped before
/// they can expand traversal beyond the regular-file catalog contract. Full scans
/// and targeted filesystem-event reconciliation share `CatalogScannedFileReader`
/// so a one-path upsert observes the same facts and media eligibility as a scan.
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

nonisolated struct CatalogScanIssueSummary: Equatable {
    let kind: String
    let errorDescription: String
    let count: Int
    let examplePaths: [String]
}

nonisolated enum CatalogScanError: Error {
    case filesystemErrorsEncountered(count: Int, summaries: [CatalogScanIssueSummary])
}

private nonisolated enum LiveCatalogScanner {
    private static let issueExampleLimitPerKey = 10

    private struct ScanIssueKey: Hashable {
        let kind: String
        let errorDescription: String
    }

    private struct ScanIssueBucket {
        var count = 0
        var examplePaths: [String] = []

        mutating func record(path: String) {
            count += 1
            if examplePaths.count < issueExampleLimitPerKey {
                examplePaths.append(path)
            }
        }
    }

    private struct SkippedPackage {
        let path: String
        let contentTypeIdentifier: String?
    }

    private struct ScanState {
        var pending: [ScannedMediaFile] = []
        var observedPaths = Set<MediaRelativePath>()
        var filesystemIssueCount = 0
        var filesystemIssueBuckets: [ScanIssueKey: ScanIssueBucket] = [:]
        var skippedPackages: [SkippedPackage] = []
        var skippedNonMediaCount = 0

        mutating func recordIssue(kind: String, path: String, errorDescription: String) {
            filesystemIssueCount += 1
            let key = ScanIssueKey(kind: kind, errorDescription: errorDescription)
            filesystemIssueBuckets[key, default: ScanIssueBucket()].record(path: path)
        }

        func issueSummaries() -> [CatalogScanIssueSummary] {
            filesystemIssueBuckets
                .map { key, bucket in
                    CatalogScanIssueSummary(
                        kind: key.kind,
                        errorDescription: key.errorDescription,
                        count: bucket.count,
                        examplePaths: bucket.examplePaths
                    )
                }
                .sorted {
                    if $0.count != $1.count {
                        return $0.count > $1.count
                    }
                    if $0.kind != $1.kind {
                        return $0.kind < $1.kind
                    }
                    return $0.errorDescription < $1.errorDescription
                }
        }
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
                scanState.recordIssue(
                    kind: "enumeration",
                    path: url.path(percentEncoded: false),
                    errorDescription: String(describing: error)
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

        return try await finish(
            scanState: &scanState,
            rootPath: rootPath,
            diagnostics: diagnostics,
            batchHandler: batchHandler
        )
    }

    private static func finish(
        scanState: inout ScanState,
        rootPath: LibraryRootPath,
        diagnostics: CatalogDiagnostics?,
        batchHandler: @Sendable ([ScannedMediaFile]) async throws -> Void
    ) async throws -> Set<MediaRelativePath> {
        try await flush(&scanState.pending, batchHandler: batchHandler)
        await recordSkippedPackages(scanState.skippedPackages, rootPath: rootPath, diagnostics: diagnostics)
        await recordSkippedNonMedia(
            count: scanState.skippedNonMediaCount,
            rootPath: rootPath,
            diagnostics: diagnostics
        )
        let summaries = scanState.issueSummaries()
        recordIssues(summaries, rootPath: rootPath)

        if scanState.filesystemIssueCount > 0 {
            throw CatalogScanError.filesystemErrorsEncountered(
                count: scanState.filesystemIssueCount,
                summaries: summaries
            )
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
            scanState.recordIssue(
                kind: "resource",
                path: fileURL.path(percentEncoded: false),
                errorDescription: String(describing: error)
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
        if values.isRegularFile == true,
           !MediaEligibility.isCatalogMedia(contentType: values.contentType)
        { // swiftlint:disable:this opening_brace
            scanState.skippedNonMediaCount += 1
            return nil
        }
        return try CatalogScannedFileReader.scannedFile(fileURL: fileURL, rootPath: rootPath)
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

    private static func recordSkippedNonMedia(
        count: Int,
        rootPath: LibraryRootPath,
        diagnostics: CatalogDiagnostics?
    ) async {
        guard count > 0 else {
            return
        }
        OtosLog.fileAccess.debug(
            """
            Catalog scan skipped non-media root=\(rootPath.rawValue, privacy: .public) \
            count=\(count, privacy: .public)
            """
        )
        await diagnostics?.record(
            operation: "catalog.scan.skippedNonMedia",
            phase: "skip",
            fields: [
                "rootPath": rootPath.rawValue,
                "count": "\(count)",
            ]
        )
    }

    private static func recordIssues(
        _ summaries: [CatalogScanIssueSummary],
        rootPath: LibraryRootPath
    ) {
        for summary in summaries {
            OtosLog.fileAccess.error(
                """
                Catalog scan issue summary root=\(rootPath.rawValue, privacy: .public) \
                kind=\(summary.kind, privacy: .public) \
                error=\(summary.errorDescription, privacy: .public) \
                count=\(summary.count, privacy: .public) \
                firstExample=\(summary.examplePaths.first ?? "none", privacy: .public)
                """
            )
        }
    }
}

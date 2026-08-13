import Foundation
import OSLog
import UniformTypeIdentifiers

/// Catalog scanner guide
///
/// The scanner performs one read-only, idempotent filesystem observation. It
/// enumerates regular files, applies structural and media-eligibility filters,
/// collects only the approved URL resource values, and flushes observed media
/// facts on a time cadence through the Store-owned batch callback. Recognized
/// companions (`.xmp` / `.srt`) are collected during the same walk and returned
/// in the completed observation so Store can pair and reconcile them without a
/// second enumerator. It never decides persistence, deletion, or UI state.
///
/// Media eligibility: after structural guards, only regular files whose
/// `contentTypeKey` conforms to `UTType.image` or `UTType.movie` become observed
/// media. Recognized companions are inventoried separately and never enter media
/// queries or enrichment. Nil or other types are skipped without failing the
/// scan. Hidden files, AppleDouble files, package descendants, symlinks,
/// Spotlight/trash folders, and common camera helper paths are structural
/// exclusions before media eligibility is considered. See ADR 0002 and
/// `MediaEligibility`.
///
/// Why metadata only and never file bytes: most media lives in cloud-synced folders
/// as dataless placeholders. Reading a file's resource values (name, size, dates,
/// type) is free, but reading its bytes would force the provider to download it,
/// potentially gigabytes. The scanner reads facts, never content.
///
/// A returned observation proves the completed walk used for reconciliation.
/// Cancellation or any filesystem issue prevents that success return, so Store
/// preserves earlier rows. Package descendants and symlinks are skipped before
/// they can expand traversal beyond the regular-file catalog contract. Full-root
/// and subtree scans share the same fact/eligibility/companion/package path;
/// targeted filesystem-event reconciliation shares `CatalogScannedFileReader`
/// so a one-path upsert observes the same facts and media eligibility as a scan.
nonisolated struct CatalogScanner {
    var scanRoot: @Sendable (
        _ rootPath: LibraryRootPath,
        _ cadence: Duration,
        _ batchHandler: @Sendable ([ScannedMediaFile]) async throws -> Void
    ) async throws -> CatalogScanObservation

    var scanSubtree: @Sendable (
        _ rootPath: LibraryRootPath,
        _ subtreeRelativePath: MediaRelativePath,
        _ cadence: Duration,
        _ batchHandler: @Sendable ([ScannedMediaFile]) async throws -> Void
    ) async throws -> CatalogScanObservation

    init(
        scanRoot: @escaping @Sendable (
            _ rootPath: LibraryRootPath,
            _ cadence: Duration,
            _ batchHandler: @Sendable ([ScannedMediaFile]) async throws -> Void
        ) async throws -> CatalogScanObservation,
        scanSubtree: @escaping @Sendable (
            _ rootPath: LibraryRootPath,
            _ subtreeRelativePath: MediaRelativePath,
            _ cadence: Duration,
            _ batchHandler: @Sendable ([ScannedMediaFile]) async throws -> Void
        ) async throws -> CatalogScanObservation = { rootPath, subtree, cadence, batchHandler in
            try await LiveCatalogScanner.scan(
                rootPath: rootPath,
                subtreeRelativePath: subtree,
                cadence: cadence,
                batchHandler: batchHandler
            )
        }
    ) {
        self.scanRoot = scanRoot
        self.scanSubtree = scanSubtree
    }

    static let live = CatalogScanner(
        scanRoot: { rootPath, cadence, batchHandler in
            try await LiveCatalogScanner.scan(
                rootPath: rootPath,
                subtreeRelativePath: nil,
                cadence: cadence,
                batchHandler: batchHandler
            )
        },
        scanSubtree: { rootPath, subtree, cadence, batchHandler in
            try await LiveCatalogScanner.scan(
                rootPath: rootPath,
                subtreeRelativePath: subtree,
                cadence: cadence,
                batchHandler: batchHandler
            )
        }
    )
}

nonisolated struct CatalogScanIssueSummary: Equatable {
    let kind: String
    let errorDescription: String
    let count: Int
    let examplePaths: [String]
}

nonisolated enum CatalogScanError: Error {
    case filesystemErrorsEncountered(count: Int, summaries: [CatalogScanIssueSummary])
    case subtreeNotDirectory
}

private nonisolated enum LiveCatalogScanner {
    private static let issueExampleLimitPerKey = 10
    private static let issueSummaryLimit = 20

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
        var companions: [ScannedCompanionFile] = []
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
            Array(filesystemIssueBuckets
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
                .prefix(issueSummaryLimit))
        }
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .isHiddenKey,
        .nameKey,
        .creationDateKey,
        .contentModificationDateKey,
        .fileSizeKey,
        .contentTypeKey,
    ]

    static func scan(
        rootPath: LibraryRootPath,
        subtreeRelativePath: MediaRelativePath?,
        cadence: Duration,
        batchHandler: @Sendable ([ScannedMediaFile]) async throws -> Void
    ) async throws -> CatalogScanObservation {
        let rootURL = rootPath.url
        let startURL: URL
        if let subtreeRelativePath {
            startURL = rootURL.appendingPathComponent(subtreeRelativePath.rawValue, isDirectory: true)
            let subtreeIsDirectory = (try? startURL.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
            if !subtreeIsDirectory {
                // Proven absence under a still-reachable root is an empty successful
                // observation: Store deletes only rows inside this subtree boundary.
                // If the root itself is gone, fail so Store preserves rows.
                let rootIsDirectory = (try? rootURL.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true
                guard rootIsDirectory else {
                    throw CatalogScanError.subtreeNotDirectory
                }
                OtosLog.fileAccess.info(
                    // swiftlint:disable:next line_length
                    "Catalog subtree absent under reachable root root=\(rootPath.rawValue, privacy: .public) subtree=\(subtreeRelativePath.rawValue, privacy: .public)"
                )
                return .empty
            }
        } else {
            startURL = rootURL
        }

        var scanState = ScanState()
        let clock = ContinuousClock()
        var lastFlush = clock.now

        let state = OtosSignpost.fileAccess.beginInterval("CatalogScanEnumerate")
        defer {
            OtosSignpost.fileAccess.endInterval("CatalogScanEnumerate", state)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: startURL,
            includingPropertiesForKeys: Array(resourceKeys),
            // Packages are directories that Finder presents as files. The
            // current catalog discovers regular files only, so descending into
            // package internals would overreach the model and can trip protected
            // app-owned stores such as Photos libraries. Camera package support
            // belongs in an explicit, tested media-container path rather than
            // in the regular-file scanner.
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                scanState.recordIssue(
                    kind: "enumeration",
                    path: url.path(percentEncoded: false),
                    errorDescription: stableIssueDescription(error)
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
            batchHandler: batchHandler
        )
    }

    private static func finish(
        scanState: inout ScanState,
        rootPath: LibraryRootPath,
        batchHandler: @Sendable ([ScannedMediaFile]) async throws -> Void
    ) async throws -> CatalogScanObservation {
        try await flush(&scanState.pending, batchHandler: batchHandler)
        await recordSkippedPackages(scanState.skippedPackages, rootPath: rootPath)
        await recordSkippedNonMedia(
            count: scanState.skippedNonMediaCount,
            rootPath: rootPath
        )
        let summaries = scanState.issueSummaries()
        recordIssues(summaries, rootPath: rootPath)

        if scanState.filesystemIssueCount > 0 {
            throw CatalogScanError.filesystemErrorsEncountered(
                count: scanState.filesystemIssueCount,
                summaries: summaries
            )
        }
        return CatalogScanObservation(
            mediaPaths: scanState.observedPaths,
            companions: scanState.companions,
            skippedPackageCount: scanState.skippedPackages.count
        )
    }

    private static func scanFileURL(
        _ fileURL: URL,
        rootPath: LibraryRootPath,
        enumerator: FileManager.DirectoryEnumerator,
        scanState: inout ScanState
    ) {
        do {
            guard let item = try observedItem(
                fileURL: fileURL,
                rootPath: rootPath,
                enumerator: enumerator,
                scanState: &scanState
            ) else {
                return
            }
            switch item {
            case let .media(file):
                scanState.pending.append(file)
                scanState.observedPaths.insert(file.relativePath)
            case let .companion(companion):
                scanState.companions.append(companion)
            }
        } catch {
            scanState.recordIssue(
                kind: "resource",
                path: fileURL.path(percentEncoded: false),
                errorDescription: stableIssueDescription(error)
            )
        }
    }

    private static func stableIssueDescription(_ error: Error) -> String {
        if let issue = error as? CatalogScannedFileReaderIssue {
            switch issue {
            case .relativePathUnavailable:
                return "Otos.CatalogScannedFileReaderIssue.relativePathUnavailable"
            }
        }
        let typeName = String(reflecting: type(of: error))
        let nsError = error as NSError
        return "\(typeName)(domain:\(nsError.domain),code:\(nsError.code))"
    }

    private static func observedItem(
        fileURL: URL,
        rootPath: LibraryRootPath,
        enumerator: FileManager.DirectoryEnumerator,
        scanState: inout ScanState
    ) throws -> CatalogScannedFileReader.ObservedItem? {
        let values = try fileURL.resourceValues(forKeys: resourceKeys)
        if values.isHidden == true {
            if values.isDirectory == true {
                enumerator.skipDescendants()
            }
            return nil
        }
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
        if values.isDirectory == true {
            let relativePath = CatalogPath.relativePath(rootPath: rootPath, fileURL: fileURL)
            if MediaEligibility.shouldSkipDirectory(name: values.name)
                || relativePath.map(MediaEligibility.shouldSkipRelativePath) == true
            { // swiftlint:disable:this opening_brace
                enumerator.skipDescendants()
            }
            return nil
        }
        if let relativePath = CatalogPath.relativePath(rootPath: rootPath, fileURL: fileURL),
           MediaEligibility.shouldSkipRelativePath(relativePath)
        { // swiftlint:disable:this opening_brace
            return nil
        }
        if values.isRegularFile == true {
            if let relativePath = CatalogPath.relativePath(rootPath: rootPath, fileURL: fileURL),
               let kind = MediaCompanionKind.recognize(
                   fileExtension: URL(fileURLWithPath: relativePath.rawValue).pathExtension
               )
            {
                return .companion(
                    ScannedCompanionFile(
                        relativePath: relativePath,
                        kind: kind,
                        byteSize: values.fileSize.map(Int64.init),
                        contentModifiedAt: values.contentModificationDate
                    )
                )
            }
            if !MediaEligibility.isCatalogMedia(contentType: values.contentType) {
                scanState.skippedNonMediaCount += 1
                return nil
            }
        }
        guard let file = try CatalogScannedFileReader.scannedFile(fileURL: fileURL, rootPath: rootPath) else {
            return nil
        }
        return .media(file)
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
}

private extension LiveCatalogScanner {
    private nonisolated static func recordSkippedPackages(
        _ skippedPackages: [SkippedPackage],
        rootPath: LibraryRootPath
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
            OtosLog.catalog.notice(
                "op=catalog.scan.skippedPackage phase=skip \(otosLogFields(fields), privacy: .public)"
            )
        }
        if !skippedPackages.isEmpty {
            OtosLog.catalog.notice(
                // swiftlint:disable:next line_length
                "op=catalog.scan.skippedPackageCount phase=summary rootPath=\(rootPath.rawValue, privacy: .public) count=\(skippedPackages.count, privacy: .public)"
            )
        }
    }

    private nonisolated static func recordSkippedNonMedia(
        count: Int,
        rootPath: LibraryRootPath
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
        OtosLog.catalog.notice(
            "op=catalog.scan.skippedNonMedia phase=skip rootPath=\(rootPath.rawValue, privacy: .public) count=\(count, privacy: .public)"
        )
    }

    private nonisolated static func recordIssues(
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

import Foundation
import OSLog
import UniformTypeIdentifiers

nonisolated struct CatalogScanner {
    var scanRoot: @Sendable (
        _ rootPath: String,
        _ cadence: Duration,
        _ batchHandler: @Sendable ([ScannedMediaFile]) async throws -> Void
    ) async throws -> Set<String>

    static let live = CatalogScanner { rootPath, cadence, batchHandler in
        try await LiveCatalogScanner.scan(rootPath: rootPath, cadence: cadence, batchHandler: batchHandler)
    }
}

nonisolated enum CatalogScanError: Error {
    case filesystemErrorsEncountered(Int)
}

private nonisolated enum LiveCatalogScanner {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .contentModificationDateKey,
        .fileSizeKey,
        .contentTypeKey,
    ]

    static func scan(
        rootPath: String,
        cadence: Duration,
        batchHandler: @Sendable ([ScannedMediaFile]) async throws -> Void
    ) async throws -> Set<String> {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        var pending: [ScannedMediaFile] = []
        var observedPaths = Set<String>()
        var filesystemErrorCount = 0
        let clock = ContinuousClock()
        var lastFlush = clock.now

        let state = OtosSignpost.fileAccess.beginInterval("CatalogScanEnumerate")
        defer {
            OtosSignpost.fileAccess.endInterval("CatalogScanEnumerate", state)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, _ in
                filesystemErrorCount += 1
                return true
            }
        ) else {
            throw CatalogStoreError.notDirectory
        }

        while let fileURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()

            guard let file = try scannedFile(
                fileURL: fileURL,
                rootPath: rootPath,
                enumerator: enumerator,
                filesystemErrorCount: &filesystemErrorCount
            ) else {
                continue
            }
            pending.append(file)
            observedPaths.insert(file.relativePath)

            if lastFlush.duration(to: clock.now) >= cadence {
                try await flush(&pending, batchHandler: batchHandler)
                lastFlush = clock.now
            }
        }

        try await flush(&pending, batchHandler: batchHandler)

        if filesystemErrorCount > 0 {
            throw CatalogScanError.filesystemErrorsEncountered(filesystemErrorCount)
        }
        return observedPaths
    }

    private static func scannedFile(
        fileURL: URL,
        rootPath: String,
        enumerator: FileManager.DirectoryEnumerator,
        filesystemErrorCount: inout Int
    ) throws -> ScannedMediaFile? {
        let values = try fileURL.resourceValues(forKeys: resourceKeys)
        if values.isSymbolicLink == true {
            if values.isDirectory == true {
                enumerator.skipDescendants()
            }
            return nil
        }
        guard values.isRegularFile == true else {
            return nil
        }
        guard let relativePath = CatalogPath.relativePath(rootPath: rootPath, fileURL: fileURL) else {
            filesystemErrorCount += 1
            return nil
        }
        return ScannedMediaFile(
            relativePath: relativePath,
            contentTypeIdentifier: values.contentType?.identifier,
            byteSize: values.fileSize.map(Int64.init),
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
        try await batchHandler(batch)
        await Task.yield()
    }
}

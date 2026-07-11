import Foundation
import UniformTypeIdentifiers

/// Shared read-only file-fact reader for full scans and targeted FSEvents reconciliation.
/// One resource-key set and eligibility path keeps scan and single-file upserts aligned.
nonisolated enum CatalogScannedFileReader {
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

    /// Observed inventory classification for one absolute path. Companions are
    /// never catalog media; unrecognized non-media is neither.
    nonisolated enum ObservedItem: Equatable, Sendable {
        case media(ScannedMediaFile)
        case companion(ScannedCompanionFile)
    }

    static func scannedFile(
        fileURL: URL,
        rootPath: LibraryRootPath
    ) throws -> ScannedMediaFile? {
        switch try observedItem(fileURL: fileURL, rootPath: rootPath) {
        case let .media(file):
            file
        case .companion, .none:
            nil
        }
    }

    static func observedItem(
        fileURL: URL,
        rootPath: LibraryRootPath
    ) throws -> ObservedItem? {
        let values = try fileURL.resourceValues(forKeys: resourceKeys)
        guard values.isHidden != true else {
            return nil
        }
        if values.isSymbolicLink == true {
            return nil
        }
        if values.isPackage == true {
            return nil
        }
        guard values.isRegularFile == true else {
            return nil
        }
        guard let relativePath = CatalogPath.relativePath(rootPath: rootPath, fileURL: fileURL) else {
            throw CatalogScannedFileReaderIssue.relativePathUnavailable
        }
        guard !MediaEligibility.shouldSkipRelativePath(relativePath) else {
            return nil
        }
        if let kind = MediaCompanionKind.recognize(
            fileExtension: URL(fileURLWithPath: relativePath.rawValue).pathExtension
        ) {
            return .companion(
                ScannedCompanionFile(
                    relativePath: relativePath,
                    kind: kind,
                    byteSize: values.fileSize.map(Int64.init),
                    contentModifiedAt: values.contentModificationDate
                )
            )
        }
        guard MediaEligibility.isCatalogMedia(contentType: values.contentType) else {
            return nil
        }
        return .media(
            ScannedMediaFile(
                relativePath: relativePath,
                name: values.name,
                contentTypeIdentifier: values.contentType?.identifier,
                byteSize: values.fileSize.map(Int64.init),
                createdAt: values.creationDate,
                contentModifiedAt: values.contentModificationDate
            )
        )
    }
}

nonisolated enum CatalogScannedFileReaderIssue: Error {
    case relativePathUnavailable
}

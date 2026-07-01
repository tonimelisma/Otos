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
        .nameKey,
        .creationDateKey,
        .contentModificationDateKey,
        .fileSizeKey,
        .contentTypeKey,
    ]

    static func scannedFile(
        fileURL: URL,
        rootPath: LibraryRootPath
    ) throws -> ScannedMediaFile? {
        let values = try fileURL.resourceValues(forKeys: resourceKeys)
        if values.isSymbolicLink == true {
            return nil
        }
        if values.isPackage == true {
            return nil
        }
        guard values.isRegularFile == true else {
            return nil
        }
        guard MediaEligibility.isCatalogMedia(contentType: values.contentType) else {
            return nil
        }
        guard let relativePath = CatalogPath.relativePath(rootPath: rootPath, fileURL: fileURL) else {
            throw CatalogScannedFileReaderIssue.relativePathUnavailable
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
}

private nonisolated enum CatalogScannedFileReaderIssue: Error {
    case relativePathUnavailable
}

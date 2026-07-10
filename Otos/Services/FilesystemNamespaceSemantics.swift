import Foundation

/// Filesystem namespace semantics guide
///
/// Off-main, volume-aware occupancy and name observations for import planning
/// and (later) reorganization. One `lstat`-scale observation per candidate —
/// never trusts the catalog alone for destination freeness (symlinks, packages,
/// and foreign files are invisible to media queries).
///
/// Pure observation only: no mutation, no materialization, no catalog writes.
nonisolated enum FilesystemNamespaceSemantics {
    static func occupancy(
        rootPath: LibraryRootPath,
        relativePath: MediaRelativePath
    ) -> NamespaceOccupancyResult {
        let url = rootPath.url.appending(path: relativePath.rawValue, directoryHint: .notDirectory)
        var info = stat()
        let path = url.path(percentEncoded: false)
        guard lstat(path, &info) == 0 else {
            return .absent
        }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            return .foreign(kind: .symlink)
        }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            return .foreign(kind: .directory)
        }
        if (info.st_mode & S_IFMT) != S_IFREG {
            return .foreign(kind: .other)
        }
        do {
            let values = try url.resourceValues(forKeys: [
                .isPackageKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ])
            if values.isPackage == true {
                return .foreign(kind: .package)
            }
            return .regularFile(
                byteSize: values.fileSize.map(Int64.init),
                contentModifiedAt: values.contentModificationDate
            )
        } catch {
            return .regularFile(byteSize: Int64(info.st_size), contentModifiedAt: nil)
        }
    }

    static func resolve(
        _ requests: [NamespaceOccupancyRequest],
        knownForeignOccupants: Set<MediaRelativePath> = []
    ) -> [NamespaceOccupancyRequest: NamespaceOccupancyResult] {
        var results: [NamespaceOccupancyRequest: NamespaceOccupancyResult] = [:]
        for request in requests {
            if knownForeignOccupants.contains(request.relativePath) {
                results[request] = .foreign(kind: .knownForeignFact)
                continue
            }
            results[request] = occupancy(
                rootPath: request.rootPath,
                relativePath: request.relativePath
            )
        }
        return results
    }
}

import Foundation

/// Filesystem namespace semantics guide
///
/// Off-main, volume-aware occupancy and name observations for import planning and
/// reorganization. Never trusts the catalog alone for destination freeness —
/// symlinks, packages, and foreign files are invisible to media queries.
///
/// Two observation shapes, both `lstat`-scale per name:
/// - `occupancy(rootPath:relativePath:)` answers one candidate. Reorganization
///   resolves its candidates this way because its destinations are scattered.
/// - `enumerateNamespace(root:folders:)` reads whole folders. Import planning uses
///   this because its candidates cluster into a small, pre-computable folder set,
///   so one enumeration answers every candidate — including suffixed retries —
///   and reveals foreign occupants no per-candidate probe would have asked about.
///
/// Pure observation only: no mutation, no materialization, no catalog writes.
/// Byte-reading is never triggered: directory and `lstat` facts read without
/// materializing cloud placeholders.
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

    /// Reads every entry of `folders` under `root` into one immutable namespace.
    ///
    /// A folder that does not exist is still enumerated: it contributes no entries,
    /// which correctly makes every candidate inside it absent (the first import into
    /// a fresh `YYYY/MM` folder). An unreadable folder is omitted from
    /// `enumeratedFolders`, so its candidates answer `nil` rather than a false
    /// `.absent`, and the planner blocks them instead of planning an overwrite.
    static func enumerateNamespace(
        root: LibraryRootPath,
        folders: Set<String>,
        capabilities: VolumeNamespaceCapabilities = .caseInsensitiveAPFS
    ) -> DestinationNamespace {
        var entries: [MediaRelativePath: NamespaceOccupancyResult] = [:]
        var enumerated: Set<String> = []
        let fileManager = FileManager.default

        for folder in folders {
            let folderURL = folder.isEmpty
                ? root.url
                : root.url.appending(path: folder, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: folderURL.path(percentEncoded: false), isDirectory: &isDirectory)
            if !exists {
                // Absent folder: nothing occupies it, and every candidate is free.
                enumerated.insert(folder)
                continue
            }
            guard isDirectory.boolValue,
                  let names = try? fileManager.contentsOfDirectory(atPath: folderURL.path(percentEncoded: false))
            else {
                // A file where a folder belongs, or an unreadable folder: leave it
                // unenumerated so candidates surface as unobservable, not as free.
                continue
            }
            for name in names {
                let relative = MediaRelativePath(rawValue: folder.isEmpty ? name : "\(folder)/\(name)")
                entries[relative] = occupancy(rootPath: root, relativePath: relative)
            }
            enumerated.insert(folder)
        }

        return DestinationNamespace(
            entries: entries,
            enumeratedFolders: enumerated,
            capabilities: capabilities
        )
    }
}

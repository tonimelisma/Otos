import Foundation
import OSLog

/// Filesystem namespace semantics guide
///
/// Volume-aware occupancy and name observations for import planning and
/// reorganization. Never trusts the catalog alone for destination freeness —
/// symlinks, packages, and foreign files are invisible to media queries.
///
/// `enumerateNamespace(root:folders:)` reads whole folders, `lstat`-scale per name.
/// Import planning and Reorganize both use it: a plan's candidates cluster into a
/// small folder set known before any name is chosen, so one enumeration answers every
/// candidate — including suffixed retries — and reveals foreign occupants no
/// per-candidate probe would have asked about.
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
        capabilities: VolumeNamespaceCapabilities = .unknown
    ) -> DestinationNamespace {
        var entries: [MediaRelativePath: NamespaceOccupancyResult] = [:]
        var enumerated: Set<String> = []
        var unreadable: [String: String] = [:]
        var occupiedFolders: [String: String] = [:]
        let fileManager = FileManager.default

        for folder in folders {
            // `.notDirectory`: a directory hint adds a trailing slash, and a regular file
            // at a trailing-slash path reports as absent, hiding a file where a folder
            // belongs. Whether it is a directory is read from `isDirectory` below.
            let folderURL = folder.isEmpty
                ? root.url
                : root.url.appending(path: folder, directoryHint: .notDirectory)
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(
                atPath: folderURL.path(percentEncoded: false),
                isDirectory: &isDirectory
            )
            if !exists {
                // Absent folder: nothing occupies it and every candidate is free — unless
                // a file holds one of its ancestors' names, which makes the folder
                // impossible to create. That is a fact about the library, not a read
                // that failed, so it is recorded as an occupied folder, not retried.
                if let occupant = MediaRelativePath(rawValue: folder + "/_").ancestorFolders.first(where: {
                    var ancestorIsDirectory: ObjCBool = false
                    let ancestorURL = root.url.appending(path: $0, directoryHint: .notDirectory)
                    return fileManager.fileExists(
                        atPath: ancestorURL.path(percentEncoded: false),
                        isDirectory: &ancestorIsDirectory
                    ) && !ancestorIsDirectory.boolValue
                }) {
                    occupiedFolders[folder] = occupant
                    logOccupiedFolder(folder: folder, occupant: occupant)
                    continue
                }
                enumerated.insert(folder)
                continue
            }
            guard isDirectory.boolValue else {
                // A file where the folder belongs.
                occupiedFolders[folder] = folder
                logOccupiedFolder(folder: folder, occupant: folder)
                continue
            }
            let names: [String]
            do {
                names = try fileManager.contentsOfDirectory(atPath: folderURL.path(percentEncoded: false))
            } catch {
                // An unreadable folder — a cloud provider mid-sync answers this way
                // for a moment (observed 2026-09-13 on a OneDrive folder that had
                // just received 368 imports). Record the error rather than
                // swallowing it: the coordinator retries on it, and the log must
                // say why.
                let nsError = error as NSError
                let detail = "\(nsError.domain)#\(nsError.code)"
                unreadable[folder] = detail
                logUnreadable(folder: folder, error: detail)
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
            unreadableFolders: unreadable,
            occupiedFolders: occupiedFolders,
            capabilities: capabilities
        )
    }

    private static func logOccupiedFolder(folder: String, occupant: String) {
        OtosLog.fileAccess.noticeOperation("namespace.enumerate", phase: "folderOccupied", fields: [
            "folder": folder,
            "occupant": occupant,
        ])
    }

    private static func logUnreadable(folder: String, error: String) {
        OtosLog.catalog.error(
            "op=plan.namespace.enumerate phase=unreadable folder=\(folder, privacy: .public) error=\(error, privacy: .public)"
        )
    }
}

import Foundation
import GRDB

/// Derived file reconciliation guide
///
/// Every derived image Otos keeps (a thumbnail, a preview, a video's face frames) is a
/// file in the derived folder that one catalog row names (`thumbnail_path`,
/// `preview_path`, `face_frames_path`). That is the overlay's one lifecycle (ADR 0008): a
/// file lives exactly as long as a row names it. Each writer keeps it — a promotion and the
/// row that names it are one write transaction, a replaced name's file is deleted after
/// the write commits, a purge deletes what the rows it removed named — and the
/// reconciliation is the owner-side check that the folder holds nothing more: a file a
/// crash left between its promotion and its row, a write that rolled back after its
/// promotion, or a defect of an older build.
///
/// It runs once a launch, after the first grid (`CatalogStore.reconcileDerivedFiles`):
/// 1. a listing of the folder's top level (never `.staging`, whose files are a running
///    write's and are cleared at startup), then a read of the protected names: every name a
///    row holds and every name a present row's identity derives (`protectedNames`);
/// 2. what is listed and not protected is re-checked against the protected names read again
///    inside a write transaction, and deleted there. A promotion happens only inside a write
///    transaction, so while that one holds the writer no file can become named, and the
///    re-check decides. A file promoted after the listing is not in it.
///
/// A file is removed only when no present row holds its name and none would write it: the
/// names are a hash of the asset's identity, so every name a row can come to hold is known.
///
/// It logs counts and bytes only (`op=derived.reconcile`), then the folder's census by
/// kind (`op=derived.folder phase=census`), which the scorecard reads as the session's
/// disk growth. It also removes the files of a retired sink: the July
/// `Diagnostics/catalog-diagnostics-*.jsonl` that ADR 0015's removed JSONL writer left.
nonisolated enum DerivedFileReconciliation {
    /// What kind of derived file a name is, by the extension `ThumbnailStore` gives it.
    enum Kind: String, CaseIterable, Sendable {
        case thumbnail
        case preview
        case faceFrames
        case other

        init(name: String) {
            if name.hasSuffix(".faces.heic") {
                self = .faceFrames
            } else if name.hasSuffix(".heic") {
                self = .preview
            } else if name.hasSuffix(".jpg") {
                self = .thumbnail
            } else {
                self = .other
            }
        }
    }

    /// One listed file.
    struct Entry: Equatable, Sendable {
        let name: String
        let bytes: Int64
    }

    /// Files and allocated bytes, by kind.
    struct Census: Equatable, Sendable {
        var files: [Kind: Int] = [:]
        var bytes: [Kind: Int64] = [:]

        init(_ entries: [Entry] = []) {
            for entry in entries {
                add(entry)
            }
        }

        mutating func add(_ entry: Entry) {
            let kind = Kind(name: entry.name)
            files[kind, default: 0] += 1
            bytes[kind, default: 0] += entry.bytes
        }

        var totalFiles: Int {
            files.values.reduce(0, +)
        }

        var totalBytes: Int64 {
            bytes.values.reduce(0, +)
        }

        /// `thumbnails=… thumbnailBytes=… previews=… …` for an `op=` line.
        var fields: [String: String] {
            var fields: [String: String] = ["files": "\(totalFiles)", "bytes": "\(totalBytes)"]
            for kind in Kind.allCases {
                fields["\(kind.rawValue)Files"] = "\(files[kind, default: 0])"
                fields["\(kind.rawValue)Bytes"] = "\(bytes[kind, default: 0])"
            }
            return fields
        }
    }

    /// The derived folder's top-level files with their allocated sizes. A missing folder
    /// is empty.
    static func list(_ directory: URL) throws -> [Entry] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey],
                options: []
            )
        } catch where ErrorDiagnostics.isMissingFile(error) {
            return []
        }
        return try urls.compactMap { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey])
            guard values.isRegularFile == true else {
                return nil
            }
            return Entry(name: url.lastPathComponent, bytes: Int64(values.totalFileAllocatedSize ?? 0))
        }
    }

    /// Every name a file may hold while it belongs to a present row: each derived name a row
    /// holds, and each name a present row's identity derives (`ThumbnailStore`'s thumbnail,
    /// preview and face-frames names), whether or not its column holds it now. A row that does
    /// not name its image yet, or for a moment no longer does, writes that same name when it
    /// next renders, so a file of a present row's identity is never taken for an orphan.
    static func protectedNames(db: Database) throws -> Set<String> {
        var names = Set<String>()
        let rows = try Row.fetchCursor(db, sql: """
        SELECT r.path, a.relative_path, a.thumbnail_path, a.preview_path, a.face_frames_path
        FROM media_asset a JOIN library_root r ON r.id = a.library_root_id
        """)
        while let row = try rows.next() {
            let id = MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: row[0]),
                relativePath: MediaRelativePath(rawValue: row[1])
            )
            names.insert(ThumbnailStore.relativeName(for: id))
            names.insert(ThumbnailStore.previewRelativeName(for: id))
            names.insert(ThumbnailStore.faceFramesRelativeName(for: id))
            for column in 2 ..< 5 {
                if let name: String = row[column] {
                    names.insert(name)
                }
            }
        }
        return names
    }

    /// Deletes `entries` from `directory`; returns what went.
    static func delete(_ entries: [Entry], in directory: URL) -> [Entry] {
        entries.filter { entry in
            do {
                try FileManager.default.removeItem(at: ThumbnailStore.url(for: entry.name, in: directory))
                return true
            } catch where ErrorDiagnostics.isMissingFile(error) {
                return false
            } catch {
                OtosLog.thumbnails.errorOperation("derived.reconcile", phase: "removeFailed", fields: [
                    "kind": Kind(name: entry.name).rawValue,
                    "error": String(describing: error),
                ])
                return false
            }
        }
    }

    /// The retired JSONL sink's folder beside the derived folder (`Diagnostics`), and its
    /// files' names: only those it wrote are removed, then the folder if that left it empty.
    static func removeRetiredDiagnostics(besides derivedDirectory: URL) -> (files: Int, bytes: Int64) {
        let folder = derivedDirectory.deletingLastPathComponent().appending(path: "Diagnostics", directoryHint: .isDirectory)
        let entries: [Entry]
        do {
            entries = try list(folder).filter { $0.name.hasPrefix("catalog-diagnostics-") && $0.name.hasSuffix(".jsonl") }
        } catch {
            OtosLog.thumbnails.errorOperation("derived.retiredDiagnostics", phase: "listFailed", fields: [
                "error": String(describing: error),
            ])
            return (0, 0)
        }
        let removed = delete(entries, in: folder)
        do {
            if !removed.isEmpty, try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).isEmpty {
                try FileManager.default.removeItem(at: folder)
            }
        } catch {
            OtosLog.thumbnails.errorOperation("derived.retiredDiagnostics", phase: "folderRemoveFailed", fields: [
                "error": String(describing: error),
            ])
        }
        return (removed.count, removed.reduce(0) { $0 + $1.bytes })
    }
}

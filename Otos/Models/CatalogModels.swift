import Foundation

nonisolated struct LibraryRootPath: Hashable, Codable, RawRepresentable, CustomStringConvertible {
    let rawValue: String

    var description: String {
        rawValue
    }

    var url: URL {
        URL(fileURLWithPath: rawValue, isDirectory: true)
    }

    var displayName: String {
        let name = url.lastPathComponent
        return name.isEmpty ? rawValue : name
    }
}

nonisolated struct MediaRelativePath: Hashable, Codable, RawRepresentable, CustomStringConvertible {
    let rawValue: String

    var description: String {
        rawValue
    }
}

nonisolated struct MediaAssetID: Hashable {
    let libraryRootPath: LibraryRootPath
    let relativePath: MediaRelativePath
}

nonisolated struct LibraryRoot: Identifiable, Hashable {
    let path: LibraryRootPath

    var id: LibraryRootPath {
        path
    }

    var displayName: String {
        path.displayName
    }
}

nonisolated struct MediaAsset: Identifiable, Hashable {
    let libraryRootPath: LibraryRootPath
    let libraryDisplayName: String
    let relativePath: MediaRelativePath
    let name: String?
    let contentTypeIdentifier: String?
    let byteSize: Int64?
    let createdAt: Date?
    let contentModifiedAt: Date?

    var id: MediaAssetID {
        MediaAssetID(libraryRootPath: libraryRootPath, relativePath: relativePath)
    }
}

nonisolated struct CatalogSnapshot: Equatable {
    var roots: [LibraryRoot]
    var assets: [MediaAsset]
    var scanningRootPaths: Set<LibraryRootPath>

    static let empty = CatalogSnapshot(roots: [], assets: [], scanningRootPaths: [])

    var isScanning: Bool {
        !scanningRootPaths.isEmpty
    }
}

nonisolated struct CatalogBrowserProjection: Equatable {
    var title: String
    var assetsForSelection: [MediaAsset]

    static let empty = CatalogBrowserProjection(title: "All Media", assetsForSelection: [])
}

nonisolated enum CatalogSelection: Hashable {
    case allMedia
    case library(LibraryRootPath)
}

nonisolated struct ScannedMediaFile: Hashable {
    let relativePath: MediaRelativePath
    let name: String?
    let contentTypeIdentifier: String?
    let byteSize: Int64?
    let createdAt: Date?
    let contentModifiedAt: Date?
}

nonisolated enum CatalogPath {
    static func normalizedDirectoryPath(for url: URL) throws -> LibraryRootPath {
        let standardizedURL = url.standardizedFileURL
        var path = standardizedURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return LibraryRootPath(rawValue: path)
    }

    static func normalizedExistingDirectoryPath(for url: URL) throws -> LibraryRootPath {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw CatalogStoreError.notDirectory
        }
        return try normalizedDirectoryPath(for: url)
    }

    static func relationship(candidate: LibraryRootPath, existing: LibraryRootPath) -> LibraryRootRelationship? {
        if candidate == existing {
            return .duplicate
        }
        if candidate.rawValue.hasPrefix(existing.rawValue + "/") {
            return .descendant
        }
        if existing.rawValue.hasPrefix(candidate.rawValue + "/") {
            return .ancestor
        }
        return nil
    }

    static func relativePath(rootPath: LibraryRootPath, fileURL: URL) -> MediaRelativePath? {
        let filePath = fileURL.standardizedFileURL.path(percentEncoded: false)
        let prefix = rootPath.rawValue + "/"
        guard filePath.hasPrefix(prefix) else {
            return nil
        }
        return MediaRelativePath(rawValue: String(filePath.dropFirst(prefix.count)))
    }
}

nonisolated enum LibraryRootRelationship: Equatable {
    case duplicate
    case ancestor
    case descendant
}

nonisolated enum CatalogStoreError: LocalizedError, Equatable {
    case notDirectory
    case overlappingRoot(existingPath: LibraryRootPath, relationship: LibraryRootRelationship)
    case catalogUnavailable

    var errorDescription: String? {
        switch self {
        case .notDirectory:
            "Choose a folder."
        case let .overlappingRoot(existingPath, relationship):
            switch relationship {
            case .duplicate:
                "That library is already saved."
            case .ancestor:
                "That folder contains an existing library at \(existingPath.rawValue)."
            case .descendant:
                "That folder is already inside an existing library at \(existingPath.rawValue)."
            }
        case .catalogUnavailable:
            "The catalog is unavailable."
        }
    }
}

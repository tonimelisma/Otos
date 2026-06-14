import Foundation

nonisolated struct LibraryRoot: Identifiable, Hashable {
    let storageID: Int64
    let path: String

    var id: String {
        path
    }

    var displayName: String {
        let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        return name.isEmpty ? path : name
    }
}

nonisolated struct MediaAsset: Identifiable, Hashable {
    let libraryPath: String
    let libraryDisplayName: String
    let relativePath: String
    let contentTypeIdentifier: String?
    let byteSize: Int64?
    let contentModifiedAt: Date?

    var id: String {
        "\(libraryPath)|\(relativePath)"
    }
}

nonisolated struct CatalogSnapshot: Equatable {
    var roots: [LibraryRoot]
    var assets: [MediaAsset]
    var scanningRootPaths: Set<String>

    static let empty = CatalogSnapshot(roots: [], assets: [], scanningRootPaths: [])

    var isScanning: Bool {
        !scanningRootPaths.isEmpty
    }

    func assets(for selection: CatalogSelection) -> [MediaAsset] {
        switch selection {
        case .allMedia:
            assets
        case let .library(path):
            assets.filter { $0.libraryPath == path }
        }
    }

    func title(for selection: CatalogSelection) -> String {
        switch selection {
        case .allMedia:
            "All Media"
        case let .library(path):
            roots.first { $0.path == path }?.displayName ?? "Library"
        }
    }
}

nonisolated enum CatalogSelection: Hashable {
    case allMedia
    case library(String)
}

nonisolated struct ScannedMediaFile: Hashable {
    let relativePath: String
    let contentTypeIdentifier: String?
    let byteSize: Int64?
    let contentModifiedAt: Date?
}

nonisolated enum CatalogPath {
    static func normalizedDirectoryPath(for url: URL) throws -> String {
        let standardizedURL = url.standardizedFileURL
        var path = standardizedURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    static func normalizedExistingDirectoryPath(for url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw CatalogStoreError.notDirectory
        }
        return try normalizedDirectoryPath(for: url)
    }

    static func relationship(candidate: String, existing: String) -> LibraryRootRelationship? {
        if candidate == existing {
            return .duplicate
        }
        if candidate.hasPrefix(existing + "/") {
            return .descendant
        }
        if existing.hasPrefix(candidate + "/") {
            return .ancestor
        }
        return nil
    }

    static func relativePath(rootPath: String, fileURL: URL) -> String? {
        let filePath = fileURL.standardizedFileURL.path(percentEncoded: false)
        let prefix = rootPath + "/"
        guard filePath.hasPrefix(prefix) else {
            return nil
        }
        return String(filePath.dropFirst(prefix.count))
    }
}

nonisolated enum LibraryRootRelationship: Equatable {
    case duplicate
    case ancestor
    case descendant
}

nonisolated enum CatalogStoreError: LocalizedError, Equatable {
    case notDirectory
    case overlappingRoot(existingPath: String, relationship: LibraryRootRelationship)
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
                "That folder contains an existing library at \(existingPath)."
            case .descendant:
                "That folder is already inside an existing library at \(existingPath)."
            }
        case .catalogUnavailable:
            "The catalog is unavailable."
        }
    }
}

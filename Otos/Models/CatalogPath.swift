import Foundation

/// Path helper guide
///
/// These helpers keep filesystem identity rules explicit at call sites. Root paths
/// are normalized before persistence, media paths are expressed relative to a root,
/// and overlap checks use typed `LibraryRootPath` values instead of raw strings.
nonisolated enum CatalogPath {
    /// Existing roots resolve symlink components before persistence so scanner
    /// enumeration, root-relative paths, and filesystem events all use one path
    /// spelling for the same directory.
    static func normalizedDirectoryPath(for url: URL) throws -> LibraryRootPath {
        let standardizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
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
        // The root path was resolved once at registration. Resolving every file
        // again can rewrite `/private` to `/` and break this prefix comparison;
        // standardization is sufficient for scanner-relative identity.
        let filePath = fileURL.standardizedFileURL.path(percentEncoded: false)
        var normalizedRoot = rootPath.rawValue
        while normalizedRoot.count > 1, normalizedRoot.hasSuffix("/") {
            normalizedRoot.removeLast()
        }
        let prefix = normalizedRoot + "/"
        guard filePath.hasPrefix(prefix) else {
            return nil
        }
        return MediaRelativePath(rawValue: String(filePath.dropFirst(prefix.count)))
    }

    /// Maps an absolute filesystem event path to the saved root that owns it.
    static func owningRoot(for eventPath: String, among roots: some Sequence<LibraryRootPath>) -> LibraryRootPath? {
        var match: LibraryRootPath?
        var matchLength = 0
        for root in roots {
            let raw = root.rawValue
            if eventPath == raw || eventPath.hasPrefix(raw + "/"), raw.count > matchLength {
                match = root
                matchLength = raw.count
            }
        }
        return match
    }
}

nonisolated enum LibraryRootRelationship: Equatable {
    case duplicate
    case ancestor
    case descendant
}

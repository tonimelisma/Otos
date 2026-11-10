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

    /// A path FSEvents reported, spelled as the catalog spells paths. Foundation, which
    /// spells every root and scanned file here, drops a leading `/private` where the
    /// shorter path names the same place: `/var`, `/tmp` and `/etc` are links into
    /// `/private`. FSEvents reports the real `/private` path, so without this an event
    /// inside a library under `/var` or `/tmp` would never match its root.
    static func catalogSpelling(ofEventPath path: String) -> String {
        for linked in ["/var", "/tmp", "/etc"] {
            let real = "/private" + linked
            if path == real || path.hasPrefix(real + "/") {
                return String(path.dropFirst("/private".count))
            }
        }
        return path
    }

    static func relativePath(rootPath: LibraryRootPath, fileURL: URL) -> MediaRelativePath? {
        // The root path was resolved once at registration. Resolving every file
        // again can rewrite `/private` to `/` and break this prefix comparison;
        // standardization is sufficient for scanner-relative identity.
        relativePath(rootPath: rootPath, absolutePath: fileURL.standardizedFileURL.path(percentEncoded: false))
    }

    /// Maps an absolute path inside `rootPath` to its root-relative path by text alone.
    /// A directory URL's trailing slash is not part of the name, so a path that is a
    /// directory now maps exactly as it did when it was a file. `nil` for the root
    /// itself and for a path outside it.
    static func relativePath(rootPath: LibraryRootPath, absolutePath: String) -> MediaRelativePath? {
        var normalizedRoot = rootPath.rawValue
        while normalizedRoot.count > 1, normalizedRoot.hasSuffix("/") {
            normalizedRoot.removeLast()
        }
        var path = absolutePath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        let prefix = normalizedRoot == "/" ? "/" : normalizedRoot + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else {
            return nil
        }
        return MediaRelativePath(rawValue: String(path.dropFirst(prefix.count)))
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

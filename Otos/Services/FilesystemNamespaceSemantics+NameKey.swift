import Foundation

/// Volume-aware filesystem name key for occupancy and equality (ARC-046).
///
/// Not an unconditional lowercased string — case folding and Unicode form follow
/// the probed volume capabilities. Ambiguous comparisons block before mutation.
nonisolated struct FilesystemNameKey: Hashable, Sendable {
    let rawValue: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
    }

    func hash(into hasher: inout Hasher) {
        for byte in rawValue.utf8 {
            hasher.combine(byte)
        }
    }
}

nonisolated struct VolumeNamespaceCapabilities: Equatable, Sendable {
    let isCaseSensitive: Bool
    let prefersDecomposedUnicode: Bool
    let isKnown: Bool

    init(isCaseSensitive: Bool, prefersDecomposedUnicode: Bool, isKnown: Bool = true) {
        self.isCaseSensitive = isCaseSensitive
        self.prefersDecomposedUnicode = prefersDecomposedUnicode
        self.isKnown = isKnown
    }

    static let unknown = VolumeNamespaceCapabilities(
        isCaseSensitive: false,
        prefersDecomposedUnicode: true,
        isKnown: false
    )

    static let caseInsensitiveAPFS = VolumeNamespaceCapabilities(
        isCaseSensitive: false,
        prefersDecomposedUnicode: true
    )
    static let caseSensitiveAPFS = VolumeNamespaceCapabilities(
        isCaseSensitive: true,
        prefersDecomposedUnicode: true
    )
}

nonisolated struct PlannedNamespacePath: Equatable, Sendable {
    let relativePath: MediaRelativePath
    let lookupKey: FilesystemNameKey
    let volumeIdentifier: String
}

/// The one owner of a root's filesystem namespace rules. Callers must carry this
/// value from root registration or probing; comparison capabilities are never
/// guessed at the operation call site.
nonisolated struct RootNamespace: Equatable, Sendable {
    let root: LibraryRootPath
    private let capabilities: VolumeNamespaceCapabilities

    init(root: LibraryRootPath, capabilities: VolumeNamespaceCapabilities) {
        self.root = root
        self.capabilities = capabilities
    }

    func key(_ relativePath: MediaRelativePath) -> FilesystemNameKey {
        FilesystemNamespaceSemantics.nameKey(relativePath: relativePath, capabilities: capabilities)
    }

    var isKnown: Bool {
        capabilities.isKnown
    }

    var permitsDestructiveReconciliation: Bool {
        capabilities.isKnown
    }

    func contains(_ url: URL) -> MediaRelativePath? {
        CatalogPath.relativePathIfContained(rootPath: root, fileURL: url)
    }
}

extension FilesystemNamespaceSemantics {
    /// Builds a lookup key for the given relative path under known volume capabilities.
    nonisolated static func nameKey(
        relativePath: MediaRelativePath,
        capabilities: VolumeNamespaceCapabilities
    ) -> FilesystemNameKey {
        var normalized = relativePath.rawValue
        if capabilities.prefersDecomposedUnicode {
            normalized = normalized.decomposedStringWithCanonicalMapping
        } else {
            normalized = normalized.precomposedStringWithCanonicalMapping
        }
        if !capabilities.isCaseSensitive {
            normalized = normalized.lowercased()
        }
        return FilesystemNameKey(rawValue: normalized)
    }

    /// Probes case-sensitivity and Unicode preference for a root URL.
    /// Falls back to case-insensitive APFS defaults when the probe is inconclusive.
    nonisolated static func probeVolumeCapabilities(rootURL: URL) -> VolumeNamespaceCapabilities {
        let values = try? rootURL.resourceValues(forKeys: [
            .volumeSupportsCaseSensitiveNamesKey,
            .volumeSupportsCasePreservedNamesKey,
        ])
        let caseSensitive = values?.volumeSupportsCaseSensitiveNames ?? false
        return VolumeNamespaceCapabilities(
            isCaseSensitive: caseSensitive,
            prefersDecomposedUnicode: true
        )
    }

    nonisolated static func plannedPath(
        relativePath: MediaRelativePath,
        volumeIdentifier: String,
        capabilities: VolumeNamespaceCapabilities
    ) -> PlannedNamespacePath {
        PlannedNamespacePath(
            relativePath: relativePath,
            lookupKey: nameKey(relativePath: relativePath, capabilities: capabilities),
            volumeIdentifier: volumeIdentifier
        )
    }
}

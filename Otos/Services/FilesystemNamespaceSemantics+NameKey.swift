import Foundation

/// Volume-aware filesystem name key for occupancy and equality (ARC-046).
///
/// Not an unconditional lowercased string — case folding and Unicode form follow
/// the probed volume capabilities. Ambiguous comparisons block before mutation.
nonisolated struct FilesystemNameKey: Hashable, Sendable {
    let rawValue: String
}

nonisolated struct VolumeNamespaceCapabilities: Equatable, Sendable {
    var isCaseSensitive: Bool
    var prefersDecomposedUnicode: Bool

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

extension FilesystemNamespaceSemantics {
    /// Builds a lookup key for the given relative path under volume capabilities.
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

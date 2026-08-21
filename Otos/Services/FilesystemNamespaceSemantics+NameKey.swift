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

/// The one namespace fact Otos probes per volume.
///
/// Unicode normalization is deliberately *not* here. A comparison key only has to
/// satisfy one property — both sides normalize the same way — so the form is
/// arbitrary and consistency is everything. Modelling it per volume created the
/// possibility of two keys for one path, and that possibility shipped: two
/// disagreeing "unknown" values produced different keys for the same accented
/// filename. Measurements in
/// `docs/research/2026-08-21-volume-normalization-is-not-a-capability.md` also
/// found no observable per-volume variation to probe. `nameKey` always decomposes.
nonisolated struct VolumeNamespaceCapabilities: Equatable, Sendable {
    let isCaseSensitive: Bool
    /// Whether `isCaseSensitive` was actually probed. The memberwise initializer
    /// gives it no default on purpose: recording a guess as a fact is what made
    /// this flag unreachable from a live volume before.
    let isKnown: Bool

    /// The probe did not answer. Compares case-insensitively, which is the
    /// conservative choice: it can only ever merge two names, never split one.
    static let unknown = VolumeNamespaceCapabilities(isCaseSensitive: false, isKnown: false)

    static let caseInsensitiveAPFS = VolumeNamespaceCapabilities(isCaseSensitive: false, isKnown: true)
    static let caseSensitiveAPFS = VolumeNamespaceCapabilities(isCaseSensitive: true, isKnown: true)

    /// `NULL` when unprobed, so the column and `isKnown` stay one fact across a
    /// round trip. Writing `0` for an unprobed root made it read back as a
    /// confidently case-insensitive one.
    var storedCaseSensitiveColumn: Int? {
        isKnown ? (isCaseSensitive ? 1 : 0) : nil
    }
}

nonisolated struct PlannedNamespacePath: Equatable, Sendable {
    let relativePath: MediaRelativePath
    let lookupKey: FilesystemNameKey
    let volumeIdentifier: String
}

extension FilesystemNamespaceSemantics {
    /// Builds a lookup key for the given relative path under known volume capabilities.
    nonisolated static func nameKey(
        relativePath: MediaRelativePath,
        capabilities: VolumeNamespaceCapabilities
    ) -> FilesystemNameKey {
        // Always decomposed. See `VolumeNamespaceCapabilities`: the form is
        // arbitrary, but it must be the same on both sides of every comparison,
        // and it must match what the v17 `relative_path_key` backfill wrote.
        var normalized = relativePath.rawValue.decomposedStringWithCanonicalMapping
        if !capabilities.isCaseSensitive {
            normalized = normalized.lowercased()
        }
        return FilesystemNameKey(rawValue: normalized)
    }

    /// Probes case-sensitivity for a root URL, or reports `.unknown`.
    ///
    /// An inconclusive probe is *not* silently recorded as case-insensitive. That
    /// is a guess, and recording it as a fact made `isKnown == false` unreachable
    /// from a live volume — which in turn made every consumer of that flag inert.
    nonisolated static func probeVolumeCapabilities(rootURL: URL) -> VolumeNamespaceCapabilities {
        guard let values = try? rootURL.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]),
              let caseSensitive = values.volumeSupportsCaseSensitiveNames
        else {
            return .unknown
        }
        return VolumeNamespaceCapabilities(isCaseSensitive: caseSensitive, isKnown: true)
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

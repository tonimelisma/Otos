import Foundation

/// Volume-aware filesystem name key for occupancy and equality (ARC-046).
///
/// Not an unconditional lowercased string — case folding and Unicode form follow
/// the probed volume capabilities. Ambiguous comparisons block before mutation.
nonisolated struct FilesystemNameKey: Hashable, Sendable {
    let rawValue: String

    /// Byte-exact, deliberately. Swift's `String ==` is Unicode
    /// *canonical-equivalence* based, so a precomposed and a decomposed spelling
    /// of the same name compare equal for free — which would silently do the
    /// normalization work this key exists to do explicitly, and hide it from
    /// `nameKey`. Comparing UTF-8 bytes forces every caller through `nameKey`'s
    /// normalization, so two keys are equal only when the same rules produced
    /// them. Do not "simplify" these back to the synthesized conformance.
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
nonisolated enum VolumeNamespaceCapabilities: Equatable, Sendable {
    case caseSensitive
    case caseInsensitive
    /// The probe did not answer. A guess is never recorded as a fact: an unknown volume
    /// stays unknown, so a consumer that must not act on a guess can tell.
    case unknown

    /// Whether two names that differ only by case are different names here. An unknown
    /// volume compares case-insensitively, the conservative choice: it can only ever
    /// merge two names, never split one.
    var distinguishesCase: Bool {
        self == .caseSensitive
    }

    var isKnown: Bool {
        self != .unknown
    }

    /// `NULL` when unprobed, so an unprobed root never reads back as a confidently
    /// case-insensitive one.
    var storedCaseSensitiveColumn: Int? {
        switch self {
        case .caseSensitive: 1
        case .caseInsensitive: 0
        case .unknown: nil
        }
    }

    init(storedCaseSensitiveColumn column: Int?) {
        switch column {
        case nil: self = .unknown
        case 1?: self = .caseSensitive
        case _?: self = .caseInsensitive
        }
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
        if !capabilities.distinguishesCase {
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
        return caseSensitive ? .caseSensitive : .caseInsensitive
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

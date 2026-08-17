import Foundation
import UniformTypeIdentifiers

/// Recognized useful companion files that may travel with a primary during import
/// or reorganization. Otos never generates these; it only inventories and
/// optionally transfers user-owned companions.
nonisolated enum MediaCompanionKind: String, Equatable, Sendable {
    case xmp
    case srt

    static func recognize(fileExtension: String) -> MediaCompanionKind? {
        switch fileExtension.lowercased() {
        case "xmp":
            .xmp
        case "srt":
            .srt
        default:
            nil
        }
    }
}

/// One inventoried companion under a library root. Identity is
/// `(library_root_id, relative_path)`. `primaryRelativePath` is nil when unpaired.
nonisolated struct MediaCompanion: Equatable, Sendable {
    let relativePath: MediaRelativePath
    let primaryRelativePath: MediaRelativePath?
    let kind: MediaCompanionKind
    let byteSize: Int64?
    let contentModifiedAt: Date?
}

/// Filesystem facts for one companion observed during scan or targeted reconcile.
nonisolated struct ScannedCompanionFile: Equatable, Sendable {
    let relativePath: MediaRelativePath
    let kind: MediaCompanionKind
    let byteSize: Int64?
    let contentModifiedAt: Date?
}

/// Completed scan observation used for reconciliation. Media still stream through
/// the batch handler; companions are collected during enumeration and applied
/// once at scan completion so pairing sees the full primary set for the root.
nonisolated struct CatalogScanObservation: Equatable, Sendable {
    let mediaPaths: Set<MediaRelativePath>
    let companions: [ScannedCompanionFile]
    let skippedPackageCount: Int

    var companionPaths: Set<MediaRelativePath> {
        Set(companions.map(\.relativePath))
    }

    static let empty = CatalogScanObservation(
        mediaPaths: [],
        companions: [],
        skippedPackageCount: 0
    )

    static func mediaOnly(_ paths: Set<MediaRelativePath>) -> CatalogScanObservation {
        CatalogScanObservation(mediaPaths: paths, companions: [], skippedPackageCount: 0)
    }
}

/// Pure companion pairing for one directory. RAW+JPEG prefer-raw; otherwise the
/// deterministically first primary by natural name.
nonisolated enum MediaCompanionPairing {
    static func pair(
        companions: [ScannedCompanionFile],
        primaries: [ScannedMediaFile]
    ) -> [MediaCompanion] {
        let primariesByStem = Dictionary(grouping: primaries) { stem(of: $0.relativePath) }
        return companions.map { companion in
            let stem = stem(of: companion.relativePath)
            let matches = primariesByStem[stem] ?? []
            let primary = preferredPrimary(among: matches)
            return MediaCompanion(
                relativePath: companion.relativePath,
                primaryRelativePath: primary?.relativePath,
                kind: companion.kind,
                byteSize: companion.byteSize,
                contentModifiedAt: companion.contentModifiedAt
            )
        }
    }

    /// Re-derives pairings for companions that share a directory with the given
    /// relative paths (targeted FSEvents / single-file reconcile).
    static func directoryKey(of relativePath: MediaRelativePath) -> String {
        let raw = relativePath.rawValue
        guard let slash = raw.lastIndex(of: "/") else {
            return ""
        }
        return String(raw[..<slash])
    }

    static func stem(of relativePath: MediaRelativePath) -> String {
        let name = URL(fileURLWithPath: relativePath.rawValue).deletingPathExtension().lastPathComponent
        return name.lowercased()
    }

    static func preferredPrimary(among matches: [ScannedMediaFile]) -> ScannedMediaFile? {
        guard !matches.isEmpty else {
            return nil
        }
        if let raw = matches.first(where: { $0.kind == .raw }) {
            return raw
        }
        return matches.sorted { left, right in
            let leftKey = MediaSortKey.naturalKey(left.name ?? left.relativePath.rawValue)
            let rightKey = MediaSortKey.naturalKey(right.name ?? right.relativePath.rawValue)
            if leftKey != rightKey {
                return leftKey < rightKey
            }
            return left.relativePath.rawValue < right.relativePath.rawValue
        }.first
    }
}

/// User preferences for import behavior. Persisted via `@AppStorage` keys owned by
/// Settings; this type is the typed owner (ARC-047).
nonisolated struct ImportPreferences: Equatable, Sendable {
    static let sidecarImportKey = "import.sidecarFiles"
    static let deleteSourceAfterImportKey = "import.deleteSourceAfterImport"
    static let autoEjectAfterImportKey = "import.autoEjectAfterImport"
    static let destinationFolderPolicyKey = "import.destinationFolderPolicy"
    static let destinationNamePolicyKey = "import.destinationNamePolicy"

    var importSidecarFiles: Bool
    var deleteSourceAfterImport: Bool
    var autoEjectAfterImport: Bool
    var destinationFolderPolicy: DestinationFolderPolicy
    var destinationNamePolicy: DestinationNamePolicy

    static let `default` = ImportPreferences(
        importSidecarFiles: true,
        deleteSourceAfterImport: false,
        autoEjectAfterImport: false,
        destinationFolderPolicy: .yearMonth,
        destinationNamePolicy: .captureDateTime
    )
}

nonisolated enum DestinationFolderPolicy: String, Equatable, Sendable, CaseIterable {
    case none
    case yearMonth
}

nonisolated enum DestinationNamePolicy: String, Equatable, Sendable, CaseIterable {
    case original
    case captureDateTime
}

// `UserDefaults` is documented thread-safe. Callers that need it across an
// isolation boundary must not rely on a retroactive `Sendable` conformance
// (ARC-042); instead they either read a `Sendable` value before the hop or
// hold the `UserDefaults` on the single owning actor
// with a scoped comment.

/// Typed read/write owner for import preferences. Keys are stable for the
/// Settings Import tab.
nonisolated enum ImportPreferencesStore {
    static func load(defaults: any PreferenceStore) -> ImportPreferences {
        ImportPreferences(
            importSidecarFiles: defaults.object(forKey: ImportPreferences.sidecarImportKey) as? Bool
                ?? ImportPreferences.default.importSidecarFiles,
            deleteSourceAfterImport: defaults.object(forKey: ImportPreferences.deleteSourceAfterImportKey) as? Bool
                ?? ImportPreferences.default.deleteSourceAfterImport,
            autoEjectAfterImport: defaults.object(forKey: ImportPreferences.autoEjectAfterImportKey) as? Bool
                ?? ImportPreferences.default.autoEjectAfterImport,
            destinationFolderPolicy: DestinationFolderPolicy(
                rawValue: defaults.string(forKey: ImportPreferences.destinationFolderPolicyKey)
                    ?? ImportPreferences.default.destinationFolderPolicy.rawValue
            ) ?? ImportPreferences.default.destinationFolderPolicy,
            destinationNamePolicy: DestinationNamePolicy(
                rawValue: defaults.string(forKey: ImportPreferences.destinationNamePolicyKey)
                    ?? ImportPreferences.default.destinationNamePolicy.rawValue
            ) ?? ImportPreferences.default.destinationNamePolicy
        )
    }

    static func save(_ preferences: ImportPreferences, defaults: any PreferenceStore) {
        defaults.set(preferences.importSidecarFiles, forKey: ImportPreferences.sidecarImportKey)
        defaults.set(preferences.deleteSourceAfterImport, forKey: ImportPreferences.deleteSourceAfterImportKey)
        defaults.set(preferences.autoEjectAfterImport, forKey: ImportPreferences.autoEjectAfterImportKey)
        defaults.set(preferences.destinationFolderPolicy.rawValue, forKey: ImportPreferences.destinationFolderPolicyKey)
        defaults.set(preferences.destinationNamePolicy.rawValue, forKey: ImportPreferences.destinationNamePolicyKey)
    }
}

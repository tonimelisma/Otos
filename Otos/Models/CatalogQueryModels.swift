import Foundation
import UniformTypeIdentifiers

// Query model guide
//
// These values describe how the single media browser asks Store for visible
// identities. The ViewModel saves the current descriptor at quit and restores it at
// launch as part of `BrowserPlace` (APP-043); nothing else persists it. Keeping
// scope, filter, and sort in one descriptor gives toolbar buttons, menu commands,
// Projection, Store SQL, and the AppKit scroll-reset gate one shared contract.

nonisolated enum MediaKind: String, CaseIterable, Hashable {
    case image
    case raw
    case video

    static let displayOrder: [MediaKind] = [.image, .raw, .video]

    static func classify(_ contentType: UTType?) -> MediaKind? {
        guard let contentType else { return nil }
        if contentType.conforms(to: .rawImage) {
            return .raw
        }
        if contentType.conforms(to: .image) {
            return .image
        }
        if contentType.conforms(to: .movie) {
            return .video
        }
        return nil
    }

    var label: String {
        switch self {
        case .image:
            "Images"
        case .raw:
            "RAW"
        case .video:
            "Videos"
        }
    }
}

nonisolated struct MediaFormatToken: Hashable, Codable, RawRepresentable, Comparable, CustomStringConvertible {
    let rawValue: String

    var description: String {
        rawValue
    }

    static func < (left: MediaFormatToken, right: MediaFormatToken) -> Bool {
        left.rawValue.localizedStandardCompare(right.rawValue) == .orderedAscending
    }

    static func normalize(contentType: UTType?) -> MediaFormatToken? {
        guard let contentType else { return nil }
        return normalize(extension: contentType.preferredFilenameExtension)
            ?? normalize(extension: contentType.tags[.filenameExtension]?.first)
    }

    static func normalize(extension rawExtension: String?) -> MediaFormatToken? {
        guard let rawExtension else { return nil }
        let trimmed = rawExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let uppercased = trimmed.uppercased()
        switch uppercased {
        case "JPG", "JPE":
            return MediaFormatToken(rawValue: "JPEG")
        case "TIF":
            return MediaFormatToken(rawValue: "TIFF")
        default:
            return MediaFormatToken(rawValue: uppercased)
        }
    }
}

/// A user-facing file-type choice can cover multiple exact catalog format facts.
/// HEIC is a specific HEIF-family type, but separating HEIC and HEIF in the filter
/// does not serve a useful browser task. The catalog keeps both exact tokens; this
/// value groups only the query/control surface so future metadata consumers lose
/// no information.
nonisolated struct MediaFileTypeOption: Hashable, Comparable {
    let label: String
    let formats: [MediaFormatToken]

    private static let heifFormats = [
        MediaFormatToken(rawValue: "HEIC"),
        MediaFormatToken(rawValue: "HEIF"),
        MediaFormatToken(rawValue: "HIF"),
    ]

    private static let jpegFormats = [
        MediaFormatToken(rawValue: "JPEG"),
        MediaFormatToken(rawValue: "JPG"),
        MediaFormatToken(rawValue: "JPE"),
    ]

    private static let tiffFormats = [
        MediaFormatToken(rawValue: "TIFF"),
        MediaFormatToken(rawValue: "TIF"),
    ]

    init(format: MediaFormatToken) {
        if Self.heifFormats.contains(format) {
            label = "HEIF"
            formats = Self.heifFormats
        } else if Self.jpegFormats.contains(format) {
            label = "JPEG"
            formats = Self.jpegFormats
        } else if Self.tiffFormats.contains(format) {
            label = "TIFF"
            formats = Self.tiffFormats
        } else {
            label = format.rawValue
            formats = [format]
        }
    }

    static func grouped(_ formats: [MediaFormatToken]) -> [MediaFileTypeOption] {
        Set(formats.map(MediaFileTypeOption.init(format:))).sorted()
    }

    static func < (left: MediaFileTypeOption, right: MediaFileTypeOption) -> Bool {
        left.label.localizedStandardCompare(right.label) == .orderedAscending
    }
}

nonisolated struct MediaFilter: Hashable {
    var kinds: Set<MediaKind> = []
    var formats: Set<MediaFormatToken> = []
    var choices: Set<MediaChoice> = []

    static let all = MediaFilter()

    var isActive: Bool {
        !kinds.isEmpty || !formats.isEmpty || !choices.isEmpty
    }

    func includes(kind: MediaKind?, format: MediaFormatToken?) -> Bool {
        (kinds.isEmpty && formats.isEmpty)
            || (kind.map(kinds.contains) ?? false)
            || (format.map(formats.contains) ?? false)
    }

    func includes(kind: MediaKind?, format: MediaFormatToken?, choice: MediaChoice) -> Bool {
        let includesMedia = (kinds.isEmpty && formats.isEmpty)
            || (kind.map(kinds.contains) ?? false)
            || (format.map(formats.contains) ?? false)
        let includesChoice = choices.isEmpty || choices.contains(choice)
        return includesMedia && includesChoice
    }

    func settingChoice(_ choice: MediaChoice, included: Bool) -> MediaFilter {
        var updated = self
        if included {
            updated.choices.insert(choice)
        } else {
            updated.choices.remove(choice)
        }
        if updated.choices == Set(MediaChoice.allCases) {
            updated.choices = []
        }
        return updated
    }

    func settingKind(
        _ kind: MediaKind,
        included: Bool,
        options: CatalogFilterOptions
    ) -> MediaFilter {
        var updated = self
        let formatsInKind = options.availableFormatTokens(for: kind)
        updated.kinds.remove(kind)
        updated.formats.subtract(formatsInKind)
        if included {
            updated.kinds.insert(kind)
        }
        return updated.canonicalized(options: options)
    }

    func settingFileType(
        _ fileType: MediaFileTypeOption,
        kind: MediaKind,
        included: Bool,
        options: CatalogFilterOptions
    ) -> MediaFilter {
        var updated = self
        let formatsInKind = options.availableFormatTokens(for: kind)
        var selectedFormats = updated.kinds.contains(kind)
            ? formatsInKind
            : updated.formats.intersection(formatsInKind)

        if included {
            selectedFormats.formUnion(fileType.formats)
        } else {
            selectedFormats.subtract(fileType.formats)
        }

        updated.kinds.remove(kind)
        updated.formats.subtract(formatsInKind)
        if !formatsInKind.isEmpty, selectedFormats == formatsInKind {
            updated.kinds.insert(kind)
        } else {
            updated.formats.formUnion(selectedFormats)
        }
        return updated.canonicalized(options: options)
    }

    private func canonicalized(options: CatalogFilterOptions) -> MediaFilter {
        let availableKinds = Set(options.availableKinds)
        let selectsEveryAvailableKind = !availableKinds.isEmpty
            && kinds == availableKinds
            && formats.isEmpty
        if selectsEveryAvailableKind {
            var result = self
            result.kinds = []
            result.formats = []
            return result.choices.isEmpty ? .all : result
        }
        return self
    }
}

nonisolated enum MediaSortField: String, Hashable {
    case bestDate
    case name
    case size
}

nonisolated enum MediaSortDirection: String, Hashable {
    case ascending
    case descending
}

nonisolated struct MediaSortOrder: Hashable, CaseIterable {
    var field: MediaSortField
    var direction: MediaSortDirection

    static let dateNewest = MediaSortOrder(field: .bestDate, direction: .descending)
    static let dateOldest = MediaSortOrder(field: .bestDate, direction: .ascending)
    static let filenameAscending = MediaSortOrder(field: .name, direction: .ascending)
    static let filenameDescending = MediaSortOrder(field: .name, direction: .descending)
    static let sizeLargest = MediaSortOrder(field: .size, direction: .descending)
    static let sizeSmallest = MediaSortOrder(field: .size, direction: .ascending)

    static let allCases: [MediaSortOrder] = [
        .dateNewest,
        .dateOldest,
        .filenameAscending,
        .filenameDescending,
        .sizeLargest,
        .sizeSmallest,
    ]

    static let defaultOrder = dateNewest

    var label: String {
        switch (field, direction) {
        case (.bestDate, .descending):
            "Date — Newest First"
        case (.bestDate, .ascending):
            "Date — Oldest First"
        case (.name, .ascending):
            "Filename — A to Z"
        case (.name, .descending):
            "Filename — Z to A"
        case (.size, .descending):
            "Size — Largest First"
        case (.size, .ascending):
            "Size — Smallest First"
        }
    }
}

nonisolated struct CatalogQueryDescriptor: Hashable {
    var scope: SidebarSelection
    var filter: MediaFilter
    var sort: MediaSortOrder

    static let `default` = CatalogQueryDescriptor(scope: .allMedia)

    init(
        scope: SidebarSelection,
        filter: MediaFilter = .all,
        sort: MediaSortOrder = .defaultOrder
    ) {
        self.scope = scope
        self.filter = filter
        self.sort = sort
    }

    var diagnosticDescription: String {
        let kindList = filter.kinds.map(\.rawValue).sorted().joined(separator: ",")
        let formatList = filter.formats.map(\.rawValue).sorted().joined(separator: ",")
        let choiceList = filter.choices.map(\.rawValue).sorted().joined(separator: ",")
        return """
        scope=\(scope.diagnosticDescription) \
        sort=\(sort.field.rawValue):\(sort.direction.rawValue) \
        kinds=\(kindList.isEmpty ? "all" : kindList) \
        formats=\(formatList.isEmpty ? "all" : formatList) \
        choices=\(choiceList.isEmpty ? "all" : choiceList)
        """
    }
}

nonisolated struct CatalogQueryRequest: Hashable {
    var descriptor: CatalogQueryDescriptor
    var generation: UInt64

    static let initial = CatalogQueryRequest(descriptor: .default, generation: 0)
}

nonisolated struct CatalogFilterOptions: Equatable {
    var formatsByKind: [MediaKind: [MediaFormatToken]] = [:]

    static let empty = CatalogFilterOptions()

    var isEmpty: Bool {
        formatsByKind.isEmpty
    }

    var availableKinds: [MediaKind] {
        MediaKind.displayOrder.filter { formatsByKind.keys.contains($0) }
    }

    func formats(for kind: MediaKind) -> [MediaFormatToken] {
        formatsByKind[kind] ?? []
    }

    func fileTypes(for kind: MediaKind) -> [MediaFileTypeOption] {
        MediaFileTypeOption.grouped(formats(for: kind))
    }

    func availableFormatTokens(for kind: MediaKind) -> Set<MediaFormatToken> {
        Set(fileTypes(for: kind).flatMap(\.formats))
    }
}

/// Where a library moves in the user's order (APP-003), stated against libraries rather
/// than positions so the Store can apply it to the order it holds when the move arrives.
nonisolated enum LibraryOrderMove: Equatable, Sendable {
    /// One place earlier.
    case up
    /// One place later.
    case down
    /// Directly before this library, or last when nil.
    case before(LibraryRootPath?)

    /// The order after this move, or nil when `moving` (or the library it is placed
    /// before) is not in `order`.
    func reordering(_ order: [LibraryRootPath], moving: LibraryRootPath) -> [LibraryRootPath]? {
        guard let index = order.firstIndex(of: moving) else { return nil }
        var result = order
        switch self {
        case .up:
            guard index > 0 else { return order }
            result.swapAt(index, index - 1)
        case .down:
            guard index < order.count - 1 else { return order }
            result.swapAt(index, index + 1)
        case let .before(anchor):
            result.remove(at: index)
            if let anchor {
                guard anchor != moving else { return order }
                guard let anchorIndex = result.firstIndex(of: anchor) else { return nil }
                result.insert(moving, at: anchorIndex)
            } else {
                result.append(moving)
            }
        }
        return result
    }
}

/// One ordered-ID read of the catalog: the identities in display order, their day
/// buckets when sorted by date, and the identity remaps not yet acknowledged by the
/// window — all from one read transaction (ARC-052).
nonisolated struct CatalogOrderedAssets: Equatable, Sendable {
    let ids: [MediaAssetID]
    let dayBuckets: [Date?]
    let pendingIdentityRemaps: [CatalogIdentityRemapBatch]
}

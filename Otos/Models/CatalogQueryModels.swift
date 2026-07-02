import Foundation
import UniformTypeIdentifiers

// Query model guide
//
// These values describe how the single media browser asks Store for visible
// identities. They are session state, not persisted user preferences. Keeping
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

nonisolated struct MediaFilter: Hashable {
    var kinds: Set<MediaKind> = []
    var formats: Set<MediaFormatToken> = []

    static let all = MediaFilter()

    var isActive: Bool {
        !kinds.isEmpty || !formats.isEmpty
    }

    func includes(kind: MediaKind?, format: MediaFormatToken?) -> Bool {
        guard isActive else { return true }
        if let kind, kinds.contains(kind) {
            return true
        }
        if let format, formats.contains(format) {
            return true
        }
        return false
    }
}

nonisolated enum MediaSortField: String, CaseIterable, Hashable {
    case bestDate
    case name
    case size

    var label: String {
        switch self {
        case .bestDate:
            "Best Date"
        case .name:
            "File Name"
        case .size:
            "File Size"
        }
    }

    var defaultDirection: MediaSortDirection {
        switch self {
        case .bestDate, .size:
            .descending
        case .name:
            .ascending
        }
    }
}

nonisolated enum MediaSortDirection: String, CaseIterable, Hashable {
    case ascending
    case descending

    var label: String {
        switch self {
        case .ascending:
            "Ascending"
        case .descending:
            "Descending"
        }
    }
}

nonisolated struct MediaSortOrder: Hashable {
    var field: MediaSortField
    var direction: MediaSortDirection

    static let defaultOrder = MediaSortOrder(field: .bestDate, direction: .descending)

    static func defaultForField(_ field: MediaSortField) -> MediaSortOrder {
        MediaSortOrder(field: field, direction: field.defaultDirection)
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
        return """
        scope=\(scope.diagnosticDescription) \
        sort=\(sort.field.rawValue):\(sort.direction.rawValue) \
        kinds=\(kindList.isEmpty ? "all" : kindList) \
        formats=\(formatList.isEmpty ? "all" : formatList)
        """
    }
}

nonisolated struct CatalogFilterOptions: Equatable {
    var formatsByKind: [MediaKind: [MediaFormatToken]] = [:]

    static let empty = CatalogFilterOptions()

    var isEmpty: Bool {
        formatsByKind.isEmpty
    }

    func formats(for kind: MediaKind) -> [MediaFormatToken] {
        formatsByKind[kind] ?? []
    }
}

import Foundation
import OSLog

nonisolated enum OtosLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "net.melisma.Otos"

    static let app = Logger(subsystem: subsystem, category: Category.app.rawValue)
    static let ui = Logger(subsystem: subsystem, category: Category.ui.rawValue)
    static let fileAccess = Logger(subsystem: subsystem, category: Category.fileAccess.rawValue)
    static let catalog = Logger(subsystem: subsystem, category: Category.catalog.rawValue)
    static let metadata = Logger(subsystem: subsystem, category: Category.metadata.rawValue)
    static let mediaIO = Logger(subsystem: subsystem, category: Category.mediaIO.rawValue)
    static let thumbnails = Logger(subsystem: subsystem, category: Category.thumbnails.rawValue)
    static let persistence = Logger(subsystem: subsystem, category: Category.persistence.rawValue)
    static let rendering = Logger(subsystem: subsystem, category: Category.rendering.rawValue)
    static let performance = Logger(subsystem: subsystem, category: Category.performance.rawValue)

    enum Category: String {
        case app = "App"
        case ui = "UI"
        case fileAccess = "FileAccess"
        case catalog = "Catalog"
        case metadata = "Metadata"
        case mediaIO = "MediaIO"
        case thumbnails = "Thumbnails"
        case persistence = "Persistence"
        case rendering = "Rendering"
        case performance = "Performance"
    }
}

nonisolated enum OtosSignpost {
    static let app = OSSignposter(logger: OtosLog.app)
    static let ui = OSSignposter(logger: OtosLog.ui)
    static let fileAccess = OSSignposter(logger: OtosLog.fileAccess)
    static let catalog = OSSignposter(logger: OtosLog.catalog)
    static let metadata = OSSignposter(logger: OtosLog.metadata)
    static let mediaIO = OSSignposter(logger: OtosLog.mediaIO)
    static let thumbnails = OSSignposter(logger: OtosLog.thumbnails)
    static let persistence = OSSignposter(logger: OtosLog.persistence)
    static let rendering = OSSignposter(logger: OtosLog.rendering)
    static let performance = OSSignposter(logger: OtosLog.performance)
}

extension Logger {
    /// Boundary log with stable `op=` / `phase=` / `key=value` shape for agent grepping.
    nonisolated func noticeOperation(_ operation: String, phase: String, fields: [String: String] = [:]) {
        if fields.isEmpty {
            notice("op=\(operation, privacy: .public) phase=\(phase, privacy: .public)")
            return
        }
        let pairs = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        notice(
            "op=\(operation, privacy: .public) phase=\(phase, privacy: .public) \(pairs, privacy: .public)"
        )
    }

    nonisolated func errorOperation(_ operation: String, phase: String, fields: [String: String] = [:]) {
        if fields.isEmpty {
            error("op=\(operation, privacy: .public) phase=\(phase, privacy: .public)")
            return
        }
        let pairs = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        error(
            "op=\(operation, privacy: .public) phase=\(phase, privacy: .public) \(pairs, privacy: .public)"
        )
    }
}

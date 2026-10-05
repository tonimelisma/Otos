import Foundation
import OSLog

nonisolated enum OtosLog {
    /// A constant, never `Bundle.main.bundleIdentifier`. OtosKit is loaded by the
    /// app *and* by the unhosted test bundle (ADR 0023), whose `Bundle.main` is
    /// the `xctest` tool — deriving the subsystem from the host process filed
    /// every test-run log line under `com.apple.dt.xctest.tool`, where
    /// `script/logs.sh`'s subsystem predicate could never find it. The subsystem
    /// identifies this code, not whatever process loaded it.
    static let subsystem = "net.melisma.Otos"

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

/// Renders `["a":"1","b":"2"]` as `"a=1 b=2"` (sorted, stable) for greppable logs.
nonisolated func otosLogFields(_ fields: [String: String]) -> String {
    fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
}

/// Scroll-path per-flush debug chatter and signpost intervals. Summary
/// `noticeOperation` lines stay always-on. Set `OTOS_UI_VERBOSE=1` to enable.
nonisolated enum OtosUIVerbose {
    static let enabled = ProcessInfo.processInfo.environment["OTOS_UI_VERBOSE"] == "1"
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
        let pairs = otosLogFields(fields)
        notice(
            "op=\(operation, privacy: .public) phase=\(phase, privacy: .public) \(pairs, privacy: .public)"
        )
    }

    nonisolated func errorOperation(_ operation: String, phase: String, fields: [String: String] = [:]) {
        if fields.isEmpty {
            error("op=\(operation, privacy: .public) phase=\(phase, privacy: .public)")
            return
        }
        let pairs = otosLogFields(fields)
        error(
            "op=\(operation, privacy: .public) phase=\(phase, privacy: .public) \(pairs, privacy: .public)"
        )
    }

    /// Debug-level twin of `noticeOperation` for signals we accept losing (per-frame or
    /// per-asset chatter). Never use for a signal named in docs/requirements.md as a
    /// diagnostic contract — macOS does not persist `.debug` for a subsystem without an
    /// explicit logging configuration profile, so such a signal would be unreadable. See
    /// ADR 0015.
    nonisolated func debugOperation(_ operation: String, phase: String, fields: [String: String] = [:]) {
        if fields.isEmpty {
            debug("op=\(operation, privacy: .public) phase=\(phase, privacy: .public)")
            return
        }
        let pairs = otosLogFields(fields)
        debug("op=\(operation, privacy: .public) phase=\(phase, privacy: .public) \(pairs, privacy: .public)")
    }
}

/// Decomposes an error into greppable fields for the log.
///
/// `String(describing:)` renders an `NSError` as prose and drops its `userInfo`,
/// so a `NSCocoaErrorDomain` 257 arrives as "you don't have permission to view it"
/// with no indication of *which* path was refused. `NSFilePath` and
/// `NSUnderlyingError` are exactly the fields needed to tell a denied destination
/// from a denied source, and their absence turned one real failure into an
/// afternoon of inference.
nonisolated enum ErrorDiagnostics {
    static func fields(for error: Error, prefix: String = "error") -> [String: String] {
        let nsError = error as NSError
        var out: [String: String] = [
            prefix: nsError.domain,
            "\(prefix)Code": "\(nsError.code)",
            "\(prefix)Description": nsError.localizedDescription,
            // Which keys the error carried at all: an empty list says the in-process
            // error holds nothing more and the cause is outside it (e.g. a TCC refusal
            // that only the kernel's sandbox log names).
            "\(prefix)UserInfoKeys": nsError.userInfo.keys.sorted().joined(separator: ","),
        ]
        if let path = nsError.userInfo[NSFilePathErrorKey] as? String {
            out["\(prefix)Path"] = path
        }
        if let url = nsError.userInfo[NSURLErrorKey] as? URL {
            out["\(prefix)URL"] = url.path(percentEncoded: false)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            out["\(prefix)UnderlyingDomain"] = underlying.domain
            out["\(prefix)UnderlyingCode"] = "\(underlying.code)"
            out["\(prefix)UnderlyingDescription"] = underlying.localizedDescription
            if let path = underlying.userInfo[NSFilePathErrorKey] as? String {
                out["\(prefix)UnderlyingPath"] = path
            }
        }
        if let reason = nsError.localizedFailureReason {
            out["\(prefix)Reason"] = reason
        }
        return out
    }
}

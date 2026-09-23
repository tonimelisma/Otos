import Foundation

/// Process run guide
///
/// Diagnostics and script artifacts need a stable process-local identity so a
/// large smoke run can be analyzed without mixing evidence from older launches.
/// This helper is intentionally tiny and value-only: it reads immutable process
/// facts once and never owns files or logging. Tests never launch the app
/// (OtosTests is unhosted), so runKind is always "prod".
nonisolated enum RunContext {
    static let runKind: String = "prod"

    static let sessionID: String = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: Date())
        return "\(timestamp)-p\(ProcessInfo.processInfo.processIdentifier)"
    }()
}

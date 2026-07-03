import Foundation

/// Process run guide
///
/// Diagnostics and script artifacts need a stable process-local identity so a
/// large smoke run can be analyzed without mixing evidence from older launches.
/// This helper is intentionally tiny and value-only: it reads immutable process
/// facts once, labels the run as app or test, and never owns files or logging.
nonisolated enum RunContext {
    static let isTestRun: Bool = {
        let environment = ProcessInfo.processInfo.environment
        let hasXCTestEnvironment = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundlePath"] != nil
        if hasXCTestEnvironment {
            return true
        }
        if NSClassFromString("XCTestCase") != nil {
            return true
        }
        return ProcessInfo.processInfo.processName == "xctest"
    }()

    static let runKind: String = isTestRun ? "test" : "prod"

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

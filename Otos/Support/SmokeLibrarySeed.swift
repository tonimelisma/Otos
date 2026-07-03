import Foundation
import OSLog

/// Developer smoke-launch seed guide
///
/// This helper is deliberately not product onboarding. Agent smoke scripts can
/// pass one trusted local root through `OTOS_SMOKE_LIBRARY_ROOT`; the app then
/// submits that root through the same ViewModel/Store intent path as a user add.
/// Store remains the only catalog writer and decides whether the root is new,
/// already saved, or invalid.
nonisolated enum SmokeLibrarySeed {
    static let environmentVariable = "OTOS_SMOKE_LIBRARY_ROOT"

    static func configuredRootURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let rawValue = environment[environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: NSString(string: rawValue).expandingTildeInPath, isDirectory: true)
    }

    @MainActor
    static func applyIfPresent(
        to viewModel: CatalogWindowViewModel,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard let rootURL = configuredRootURL(environment: environment) else {
            return
        }
        OtosLog.app.info("Smoke library seed requested path=\(rootURL.path(percentEncoded: false), privacy: .public)")
        viewModel.ensureLibrary(url: rootURL)
    }
}

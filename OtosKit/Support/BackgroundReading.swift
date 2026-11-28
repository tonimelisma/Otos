import Foundation
import OSLog

/// Background reading guide
///
/// Otos keeps reading the library while its window is hidden — enrichment, faces, duplicates
/// and search indexing (ADR 0048) — and that runs all the time.
/// macOS App Naps a hidden app: with the user away, every Otos thread ran at priority 4 and
/// indexing all but stopped (`docs/research/2026-11-09-keyword-search.md` §8). One process
/// activity, held for the session, exempts it. It allows idle system sleep, so Otos never keeps
/// the Mac awake; an idle Otos does no work, so holding it costs nothing when there is nothing
/// to read.
nonisolated enum BackgroundReading {
    /// User-initiated work, minus keeping the Mac awake: what exempts a process from App Nap.
    static let options: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep

    static func begin() -> NSObjectProtocol {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: options,
            reason: "Otos reads the library for search, faces and duplicates"
        )
        OtosLog.app.noticeOperation("backgroundReading", phase: "held")
        return activity
    }
}

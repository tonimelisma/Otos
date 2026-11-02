import Foundation

/// The checkout these tests were built from.
///
/// The Otos scheme passes it to the test process as `OTOS_SOURCE_ROOT = $(SRCROOT)`.
/// `#filePath` cannot stand in for it: the verification build maps every source path to
/// `/^worktree` so that compile results are shared between worktrees (ADR 0044), and a
/// mapped path names no directory on disk.
enum SourceTree {
    static let root: URL = {
        guard let path = ProcessInfo.processInfo.environment["OTOS_SOURCE_ROOT"], !path.isEmpty else {
            fatalError("OTOS_SOURCE_ROOT is unset: run the tests through the Otos scheme, which sets it to $(SRCROOT)")
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }()

    /// `OtosTests/Fixtures/Media`: the media files the tests read and copy.
    static let mediaFixtures = root.appending(path: "OtosTests/Fixtures/Media", directoryHint: .isDirectory)
}

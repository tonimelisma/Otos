import Foundation
@testable import OtosKit
import Testing

/// `OriginalPathWatch` against the real FSEvents: a watch armed on a path that does not
/// exist yet, under a folder that does not exist yet, reports the original put back there,
/// as a folder a sync client restores or a volume mounted again does.
@Suite(.testScope)
struct OriginalPathWatchTests {
    @Test func aWatchOnAMissingPathReportsTheOriginalPutBack() async throws {
        // The path as the catalog spells it, symlinks resolved (`/var` is `/private/var`).
        let directory = try CatalogPath.normalizedDirectoryPath(for: makeTestDirectory())
        let original = URL(filePath: directory.rawValue, directoryHint: .isDirectory)
            .appending(path: "Restored/photo.jpg")
        let changes = OriginalPathWatch.changes(of: original)

        try FileManager.default.createDirectory(
            at: original.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data([0xFF, 0xD8, 0xFF]).write(to: original)

        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }
}

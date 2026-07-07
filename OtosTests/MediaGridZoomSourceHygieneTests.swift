import Foundation
import Testing

/// Split out of `SourceHygieneTests.swift` (spec 0048) to keep that suite under its
/// type-body-length budget; this guards the grid-zoom architecture specifically.
struct MediaGridZoomSourceHygieneTests {
    @Test func mediaBrowserUsesReusableVariableColumnAppKitGrid() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let content = try String(
            contentsOf: repoRoot.appending(path: "Otos/Views/MediaAssetCollectionView.swift"),
            encoding: .utf8
        )
            + String(
                contentsOf: repoRoot.appending(path: "Otos/Views/MediaAssetCollectionLayout.swift"),
                encoding: .utf8
            )
            + String(
                contentsOf: repoRoot.appending(path: "Otos/Views/MediaGridAnimatedLayout.swift"),
                encoding: .utf8
            )
            + String(
                contentsOf: repoRoot.appending(path: "Otos/Models/GridColumnCount.swift"),
                encoding: .utf8
            )

        #expect(content.contains("NSViewControllerRepresentable"))
        #expect(content.contains("NSCollectionView"))
        #expect(content.contains("NSCollectionViewCompositionalLayout"))
        // Grid density is a user-adjustable 3–9 (spec 0048), not a hardcoded column count.
        #expect(content.contains("static let minimum = 3"))
        #expect(content.contains("static let maximum = 9"))
        #expect(!content.contains("NSTableView"))
        #expect(!content.contains("NSHostingView"))
        #expect(!FileManager.default.fileExists(
            atPath: repoRoot.appending(path: "Otos/Views/MediaTableView.swift").path(percentEncoded: false)
        ))
    }
}

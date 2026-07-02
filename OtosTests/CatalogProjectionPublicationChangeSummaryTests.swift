@testable import Otos
import Testing

struct ProjectionChangeSummaryTests {
    @Test func stateChangedIsDerivedFromEveryWindowStateField() {
        let base = CatalogWindowState.empty
        #expect(!summary(previous: base, current: base).stateChanged)
        #expect(summary(previous: nil, current: base).stateChanged)

        let root = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let id = MediaAssetID(
            libraryRootPath: root.path,
            relativePath: MediaRelativePath(rawValue: "one.jpg")
        )

        var titleChanged = base
        titleChanged.title = "Pictures"
        #expect(summary(previous: base, current: titleChanged).stateChanged)
        #expect(summary(previous: base, current: titleChanged).titleChanged)

        var librariesChanged = base
        librariesChanged.libraries = [CatalogLibraryState(
            root: root,
            availability: .available,
            activity: .idle
        )]
        #expect(summary(previous: base, current: librariesChanged).stateChanged)

        var mediaScopeChanged = base
        mediaScopeChanged.mediaGrid.descriptor = CatalogQueryDescriptor(scope: .library(root.path))
        #expect(summary(previous: base, current: mediaScopeChanged).stateChanged)

        var filterOptionsChanged = base
        filterOptionsChanged.filterOptions = CatalogFilterOptions(
            formatsByKind: [.image: [MediaFormatToken(rawValue: "JPEG")]]
        )
        #expect(summary(previous: base, current: filterOptionsChanged).stateChanged)

        var mediaOrderChanged = base
        mediaOrderChanged.mediaGrid.orderedAssetIDs = [id]
        #expect(summary(previous: base, current: mediaOrderChanged).stateChanged)

        var detailRefreshChanged = base
        detailRefreshChanged.mediaGrid.detailRefreshGeneration = 1
        #expect(summary(previous: base, current: detailRefreshChanged).stateChanged)

        var resolvedSelectionChanged = base
        resolvedSelectionChanged.resolvedSidebarSelection = .library(root.path)
        #expect(summary(previous: base, current: resolvedSelectionChanged).stateChanged)

        var emptyStateChanged = base
        emptyStateChanged.mediaEmptyState = .checkingLibraries
        #expect(summary(previous: base, current: emptyStateChanged).stateChanged)
    }
}

private func summary(
    previous: CatalogWindowState?,
    current: CatalogWindowState
) -> CatalogProjection.PublicationChangeSummary {
    CatalogProjection.PublicationChangeSummary.compare(previous: previous, current: current)
}

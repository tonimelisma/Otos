import Foundation
@testable import Otos
import Testing

struct SidebarSelectionPolicyTests {
    private let pictures = CatalogLibraryState(
        root: LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures")),
        availability: .available,
        activity: .idle
    )
    private let archive = CatalogLibraryState(
        root: LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive")),
        availability: .available,
        activity: .idle
    )

    @Test func showsAllMediaRequiresTwoFixedLibraries() {
        #expect(!SidebarSelectionPolicy.showsAllMedia(libraries: []))
        #expect(!SidebarSelectionPolicy.showsAllMedia(libraries: [pictures]))
        #expect(SidebarSelectionPolicy.showsAllMedia(libraries: [pictures, archive]))
    }

    @Test func defaultSelectionPrefersConnectedRemovable() {
        let older = removableSource(
            path: "/Volumes/OLD",
            identity: "volume:old",
            lastSeenAt: Date(timeIntervalSince1970: 1)
        )
        let newer = removableSource(
            path: "/Volumes/NEW",
            identity: "volume:new",
            lastSeenAt: Date(timeIntervalSince1970: 2)
        )
        let selection = SidebarSelectionPolicy.defaultSelection(
            libraries: [pictures, archive],
            removableSources: [older, newer]
        )
        #expect(selection == .library(newer.path))
    }

    @Test func defaultSelectionUsesSingleLibraryWhenNoRemovable() {
        let selection = SidebarSelectionPolicy.defaultSelection(
            libraries: [pictures],
            removableSources: []
        )
        #expect(selection == .library(pictures.path))
    }

    @Test func defaultSelectionUsesAllMediaWithMultipleLibrariesAndNoRemovable() {
        let selection = SidebarSelectionPolicy.defaultSelection(
            libraries: [pictures, archive],
            removableSources: []
        )
        #expect(selection == .allMedia)
    }

    @Test func selectionOnAttachReturnsLibraryForRemovable() {
        let card = removableSource(path: "/Volumes/CARD", identity: "volume:card")
        #expect(SidebarSelectionPolicy.selectionOnAttach(attached: card) == .library(card.path))
        #expect(SidebarSelectionPolicy.selectionOnAttach(attached: pictures) == nil)
    }

    @Test func selectionOnSelectedSourceRemovedMatchesDefault() {
        let card = removableSource(path: "/Volumes/CARD", identity: "volume:card")
        let removed = SidebarSelectionPolicy.selectionOnSelectedSourceRemoved(
            libraries: [pictures],
            removableSources: [card]
        )
        let defaultSelection = SidebarSelectionPolicy.defaultSelection(
            libraries: [pictures],
            removableSources: [card]
        )
        #expect(removed == defaultSelection)
    }

    @Test func sidebarVisibleRemovableSourcesFiltersUnavailable() {
        let available = removableSource(path: "/Volumes/CARD", identity: "volume:card")
        var unavailable = removableSource(path: "/Volumes/GONE", identity: "volume:gone")
        unavailable = CatalogLibraryState(
            root: unavailable.root,
            availability: .unavailable,
            activity: .idle,
            isEjectable: unavailable.isEjectable
        )
        let visible = SidebarSelectionPolicy.sidebarVisibleRemovableSources([available, unavailable])
        #expect(visible == [available])
    }

    private func removableSource(
        path: String,
        identity: String,
        lastSeenAt: Date = Date()
    ) -> CatalogLibraryState {
        CatalogLibraryState(
            root: LibraryRoot(
                path: LibraryRootPath(rawValue: path),
                kind: .removableVolume,
                deviceIdentity: identity,
                displayName: URL(fileURLWithPath: path).lastPathComponent,
                lastSeenAt: lastSeenAt
            ),
            availability: .available,
            activity: .idle,
            isEjectable: true
        )
    }
}

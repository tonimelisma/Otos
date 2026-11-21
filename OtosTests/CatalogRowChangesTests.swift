@testable import OtosKit
import Testing

/// What one write's rows announce (`CatalogRowChanges`).
struct CatalogRowChangesTests {
    private let root = LibraryRootPath(rawValue: "/Account")

    private func id(_ path: String) -> MediaAssetID {
        MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: path))
    }

    /// A source's own facts of a listed item that moved are announced as their kinds, naming
    /// the row; a statement that changed nothing announces nothing.
    @Test func anExistingRowsKnownFactsAreAnnouncedAsTheirKinds() {
        var rows = CatalogRowChanges()
        rows.recordChanged(0, of: id("a/IMG.JPG"), facts: [.images])
        #expect(rows.isEmpty)
        #expect(rows.notifications.isEmpty)

        rows.recordChanged(1, of: id("a/IMG.JPG"), facts: [.membership, .copies, .images, .detail])
        #expect(rows.notifications == [.changed([.membership, .copies, .images, .detail], rows: .rows([id("a/IMG.JPG")]))])
    }

    /// Beside new rows they follow the insert; beside another change to an existing row the
    /// whole change names them too.
    @Test func knownFactsJoinTheWritesOtherChanges() {
        var inserted = CatalogRowChanges()
        inserted.record(.inserted, of: id("b/IMG.JPG"))
        inserted.recordChanged(1, of: id("a/IMG.JPG"), facts: [.images])
        #expect(inserted.notifications == [.assetsAdded, .changed([.images], rows: .rows([id("a/IMG.JPG")]))])

        var updated = CatalogRowChanges()
        updated.record(.updated, of: id("b/IMG.JPG"))
        updated.recordChanged(1, of: id("a/IMG.JPG"), facts: [.images])
        #expect(updated.notifications == [.changed(.all, rows: .rows([id("a/IMG.JPG"), id("b/IMG.JPG")]))])
    }
}

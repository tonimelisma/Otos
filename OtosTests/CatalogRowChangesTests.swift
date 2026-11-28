@testable import OtosKit
import Testing

/// What one write's rows announce (`CatalogRowChanges`).
struct CatalogRowChangesTests {
    private let root = LibraryRootPath(rawValue: "/Account")

    private func id(_ path: String) -> MediaAssetID {
        MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: path))
    }

    // Validates: ARC-018
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

    // Validates: ARC-018
    /// Beside new rows they follow the insert; beside another change to an existing row the
    /// change names both writes' kinds and both rows.
    @Test func knownFactsJoinTheWritesOtherChanges() {
        var inserted = CatalogRowChanges()
        inserted.record(.inserted, of: id("b/IMG.JPG"))
        inserted.recordChanged(1, of: id("a/IMG.JPG"), facts: [.images])
        #expect(inserted.notifications == [.assetsAdded, .changed([.images], rows: .rows([id("a/IMG.JPG")]))])

        var updated = CatalogRowChanges()
        updated.record(.updated, of: id("b/IMG.JPG"))
        updated.recordChanged(1, of: id("a/IMG.JPG"), facts: [.images])
        #expect(updated.notifications == [.changed(CatalogChangedFacts.fileFacts.union(.images), rows: .rows([id("a/IMG.JPG"), id("b/IMG.JPG")]))])
    }

    // Validates: ARC-018
    /// A write names the kinds of what it did to each existing row, never every kind: a file's
    /// facts, a row's presence (a deletion names the Live Photo partner it leaves), a size by
    /// source item with no row named. A row that took another path names every kind keyed by a
    /// row and no row, since the path it left is not named.
    @Test func eachWriteToAnExistingRowNamesItsKinds() {
        var deleted = CatalogRowChanges()
        deleted.recordDeleted(
            AssetRowDeletion(deleted: true, partners: [MediaRelativePath(rawValue: "a/IMG.MOV")]),
            of: MediaRelativePath(rawValue: "a/IMG.HEIC"),
            in: root
        )
        deleted.recordDeleted(.nothing, of: MediaRelativePath(rawValue: "b/IMG.HEIC"), in: root)
        #expect(deleted.notifications == [.changed(.presence, rows: .rows([id("a/IMG.HEIC"), id("a/IMG.MOV")]))])

        var sized = CatalogRowChanges()
        sized.recordUnnamedUpdates(0, facts: .presence)
        #expect(sized.notifications.isEmpty)
        sized.recordUnnamedUpdates(2, facts: [.membership, .detail])
        sized.recordChanged(1, of: id("a/IMG.JPG"), facts: .presence)
        #expect(sized.notifications == [.changed(.presence, rows: .unnamed)])

        var moved = CatalogRowChanges()
        moved.record(.moved, of: id("a/IMG.JPG"))
        #expect(moved.notifications == [.changed(.movedRow, rows: .unnamed)])
        #expect(!CatalogChangedFacts.movedRow.contains(.placeNames))
        #expect(CatalogChangedFacts.fileFacts.isDisjoint(with: [.faces, .location, .placeNames, .mediaRecord, .searchContent, .images]))
    }
}

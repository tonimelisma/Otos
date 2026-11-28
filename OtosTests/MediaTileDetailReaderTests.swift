import Foundation
@testable import OtosKit
import Testing

/// A failed tile-detail read is an error to its reader, never an empty result (ADR 0032,
/// rule 4): an asset without a row reads as nil, a read that failed throws, and the next
/// read after the failure returns the row.
@Suite(.testScope)
@MainActor
struct MediaTileDetailReaderTests {
    // Validates: ARC-059
    @Test func aFailedReadThrowsAndTheNextReadReturnsTheRow() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let reader = MediaTileDetailReader(store: library.store)
            let hidden = try await HiddenCatalogTable("asset_metadata", in: library.databaseURL)

            await #expect(throws: (any Error).self) {
                try await reader.details(for: [id])
            }
            await #expect(throws: (any Error).self) {
                try await reader.detail(for: id)
            }

            try await hidden.restore()
            #expect(try await Set(reader.details(for: [id]).keys) == [id])
            #expect(try await reader.detail(for: id)?.bestKind == .image)
        }
    }

    // Validates: ARC-059
    @Test func anAssetWithoutARowReadsAsNil() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let reader = MediaTileDetailReader(store: library.store)
            let absent = MediaAssetID(
                libraryRootPath: library.ids[0].libraryRootPath,
                relativePath: MediaRelativePath(rawValue: "absent.jpg")
            )

            let detail = try await reader.detail(for: absent)
            let details = try await reader.details(for: [absent])
            #expect(detail == nil)
            #expect(details.isEmpty)
        }
    }
}

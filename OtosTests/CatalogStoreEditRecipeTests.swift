import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

/// ADR 0036: a photo's edit is a recipe saved under an increasing revision, and the
/// thumbnail and preview rendered from it are promoted only while that revision is still
/// current and the original is the file it was rendered from.
@Suite(.testDirectory)
struct CatalogStoreEditRecipeTests {
    @Test func savingARecipeIncrementsItsRevisionAndReportsTheOneItReplaced() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            #expect(try await library.store.editRecipe(for: id) == nil)

            let first = try await library.store.setEditRecipe(EditRecipe(exposure: 1), for: id)
            #expect(first.exists)
            #expect(first.previous == nil)
            #expect(first.saved == StoredEditRecipe(recipe: EditRecipe(exposure: 1), revision: 1))
            #expect(try first.sourceSize == Int64(Data(contentsOf: id.fileURL).count))
            #expect(first.sourceMTimeSeconds != nil)

            let second = try await library.store.setEditRecipe(EditRecipe(exposure: 1, contrast: 20), for: id)
            #expect(second.previous == StoredEditRecipe(recipe: EditRecipe(exposure: 1), revision: 1))
            #expect(second.saved?.revision == 2)

            let unchanged = try await library.store.setEditRecipe(EditRecipe(exposure: 1, contrast: 20), for: id)
            #expect(unchanged.exists)
            #expect(unchanged.saved == nil)
            #expect(
                try await library.store.editRecipe(for: id)
                    == StoredEditRecipe(recipe: EditRecipe(exposure: 1, contrast: 20), revision: 2)
            )
        }
    }

    @Test func savingNeutralOnAnUneditedPhotoChangesNothing() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let result = try await library.store.setEditRecipe(.neutral, for: library.ids[0])
            #expect(result.exists)
            #expect(result.saved == nil)
            #expect(try await library.store.editRecipe(for: library.ids[0]) == nil)
        }
    }

    @Test func aPhotoTheCatalogDoesNotHoldReportsNoRow() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let missing = MediaAssetID(
                libraryRootPath: library.ids[0].libraryRootPath,
                relativePath: MediaRelativePath(rawValue: "gone.jpg")
            )
            let result = try await library.store.setEditRecipe(EditRecipe(exposure: 1), for: missing)
            #expect(!result.exists)
            #expect(result.saved == nil)
        }
    }

    @Test func productsOfTheCurrentRevisionArePromotedAndShownByTheTile() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let result = try await library.store.setEditRecipe(EditRecipe(exposure: 1), for: id)
            let saved = try #require(result.saved)

            let applied = try await library.store.applyRenderedEditProducts(
                stagedProducts(for: id, revision: saved.revision, result: result, in: library.thumbnailDirectory)
            )

            #expect(applied)
            let detail = try #require(try await library.store.mediaTileDetails(for: [id])[id])
            #expect(detail.renderedRevision == 1)
            #expect(detail.editRecipe == EditRecipe(exposure: 1))
            let thumbnail = try #require(detail.thumbnailPath)
            let preview = try #require(detail.previewPath)
            #expect(FileManager.default.fileExists(atPath: library.thumbnailDirectory.appending(path: thumbnail).path))
            #expect(FileManager.default.fileExists(atPath: library.thumbnailDirectory.appending(path: preview).path))
        }
    }

    @Test func productsOfASupersededRevisionAreRefusedAndDiscarded() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let first = try await library.store.setEditRecipe(EditRecipe(exposure: 1), for: id)
            _ = try await library.store.setEditRecipe(EditRecipe(exposure: 2), for: id)
            let stale = try stagedProducts(for: id, revision: 1, result: first, in: library.thumbnailDirectory)

            let applied = await library.store.applyRenderedEditProducts(stale)

            #expect(!applied)
            for staged in [stale.thumbnail, stale.preview] {
                #expect(!FileManager.default.fileExists(
                    atPath: library.thumbnailDirectory.appending(path: staged.stagedRelativePath).path
                ))
            }
            let detail = try #require(try await library.store.mediaTileDetails(for: [id])[id])
            #expect(detail.renderedRevision == 0)
        }
    }

    @Test func productsRenderedFromAFileThatHasSinceChangedAreRefused() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            var result = try await library.store.setEditRecipe(EditRecipe(exposure: 1), for: id)
            let saved = try #require(result.saved)
            result.sourceSize = (result.sourceSize ?? 0) + 1

            let applied = try await library.store.applyRenderedEditProducts(
                stagedProducts(for: id, revision: saved.revision, result: result, in: library.thumbnailDirectory)
            )

            #expect(!applied)
        }
    }

    /// Enrichment renders with the recipe it read; a result rendered before a newer save
    /// is refused, and one rendered from the current save records it as rendered.
    @Test func anEnrichmentResultRenderedFromAnOlderEditIsRefused() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let result = try await library.store.setEditRecipe(EditRecipe(exposure: 1), for: id)
            func enriched(editRevision: Int64) -> EnrichmentResult {
                EnrichmentResult(
                    id: id,
                    metadata: .localCapture(instant: Date(timeIntervalSince1970: 1_767_279_600)),
                    thumbnailPath: nil,
                    sourceSize: result.sourceSize,
                    sourceMTimeSeconds: result.sourceMTimeSeconds,
                    contentHash: nil,
                    editRevision: editRevision
                )
            }

            #expect(await library.store.applyEnrichmentBatch([enriched(editRevision: 0)]) == .applied(count: 0))
            #expect(await library.store.applyEnrichmentBatch([enriched(editRevision: 1)]) == .applied(count: 1))
            #expect(try await library.store.mediaTileDetails(for: [id])[id]?.renderedRevision == 1)
        }
    }

    /// Move to Trash's undo puts the edit back with the photo, and its products are
    /// rendered again rather than trusted.
    @Test func trashUndoPutsTheEditBack() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            _ = try await library.store.setEditRecipe(EditRecipe(shadows: 40), for: id)
            let overlay = try #require(try await library.store.trashedOverlay(for: [id])[id])
            #expect(overlay.editRecipe == StoredEditRecipe(recipe: EditRecipe(shadows: 40), revision: 1))
            _ = try await library.store.setEditRecipe(EditRecipe(shadows: -10), for: id)
            let item = try #require(try await library.store.mediaTrashItems(for: [id]).first)

            let restored = await library.store.restoreTrashedItem(TrashedItem(
                item: item,
                members: item.members.map { TrashedMember(member: $0, trashURL: nil) },
                overlay: overlay
            ))

            #expect(restored)
            #expect(
                try await library.store.editRecipe(for: id)
                    == StoredEditRecipe(recipe: EditRecipe(shadows: 40), revision: 1)
            )
            #expect(try await library.store.mediaTileDetails(for: [id])[id]?.renderedRevision == 0)
        }
    }

    /// A recipe written before a control existed decodes that control as neutral.
    @Test func aRecipeMissingAControlDecodesItAsNeutral() throws {
        let stored = try CatalogStore.storedEditRecipe(json: #"{"exposure":0.5}"#, revision: 3)
        #expect(stored == StoredEditRecipe(recipe: EditRecipe(exposure: 0.5), revision: 3))
        #expect(try CatalogStore.storedEditRecipe(json: nil, revision: 0) == nil)
    }

    @Test func controlsClampToTheirRangeAndSnapToTheirStep() {
        #expect(LightControl.exposure.applying(9, to: .neutral).exposure == 4)
        #expect(LightControl.highlights.applying(30, to: .neutral).highlights == 0)
        #expect(LightControl.contrast.applying(12.4, to: .neutral).contrast == 12)
        #expect(abs(LightControl.exposure.applying(0.33, to: .neutral).exposure - 0.35) < 0.0001)
        #expect(LightControl.exposure.formatted(0) == "0.00")
        #expect(LightControl.exposure.formatted(0.5) == "+0.50")
        #expect(LightControl.shadows.formatted(-20) == "-20")
    }
}

private func stagedProducts(
    for id: MediaAssetID,
    revision: Int64,
    result: EditRecipeMutationResult,
    in directory: URL
) throws -> RenderedEditProducts {
    let image = try #require(gradientImage(width: 48, height: 32))
    return try RenderedEditProducts(
        id: id,
        revision: revision,
        sourceSize: result.sourceSize,
        sourceMTimeSeconds: result.sourceMTimeSeconds,
        thumbnail: ThumbnailStore.stage(image, finalRelativeName: ThumbnailStore.relativeName(for: id), in: directory),
        preview: ThumbnailStore.stagePreview(
            image, finalRelativeName: ThumbnailStore.previewRelativeName(for: id), in: directory
        )
    )
}

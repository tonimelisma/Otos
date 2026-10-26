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
        let still = EditPhotoFacts.still
        #expect(EditControl.exposure.applying(9, to: .neutral, facts: still).exposure == 4)
        #expect(EditControl.highlights.applying(30, to: .neutral, facts: still).highlights == 30)
        #expect(EditControl.highlights.applying(130, to: .neutral, facts: still).highlights == 100)
        #expect(EditControl.contrast.applying(12.4, to: .neutral, facts: still).contrast == 12)
        #expect(abs(EditControl.exposure.applying(0.33, to: .neutral, facts: still).exposure - 0.35) < 0.0001)
        #expect(EditControl.exposure.formatted(.neutral, facts: still) == "0.00")
        #expect(EditControl.exposure.formatted(EditRecipe(exposure: 0.5), facts: still) == "+0.50")
        #expect(EditControl.shadows.formatted(EditRecipe(shadows: -20), facts: still) == "-20")
    }

    /// A still's white balance is relative and zero is as shot; a RAW's is kelvin, its
    /// slider even in mireds, and as shot until moved.
    @Test func whiteBalanceIsRelativeForAStillAndKelvinForARAW() {
        let still = EditPhotoFacts.still
        #expect(EditControl.temperature.applying(0, to: EditRecipe(temperature: 30), facts: still).temperature == nil)
        #expect(EditControl.tint.applying(-12, to: .neutral, facts: still).tint == -12)
        #expect(EditControl.temperature.formatted(.neutral, facts: still) == "0")

        let raw = EditPhotoFacts(isRAW: true, asShotTemperature: 5600, asShotTint: 4)
        #expect(EditControl.temperature.formatted(.neutral, facts: raw) == "5600 K")
        #expect(EditControl.tint.sliderValue(in: .neutral, facts: raw) == 4)
        let middle = EditControl.temperature.applying(0.5, to: .neutral, facts: raw)
        #expect(middle.temperature == 3850)
        #expect(middle.tint == nil)
        #expect(abs(EditControl.position(ofKelvin: 2000)) < 0.0001)
        #expect(abs(EditControl.position(ofKelvin: 50000) - 1) < 0.0001)
        #expect(abs(EditControl.kelvin(atPosition: EditControl.position(ofKelvin: 6500)) - 6500) < 0.01)
    }

    /// `hig-validation.md` F-15: a typed value is read as the panel shows it — signs, a
    /// degree mark, a kelvin unit — and a RAW's temperature in kelvin.
    @Test func typedValuesAreReadAsThePanelShowsThem() {
        let still = EditPhotoFacts.still
        let raw = EditPhotoFacts(isRAW: true, asShotTemperature: 5600, asShotTint: 4)
        #expect(EditControl.exposure.position(fromEntered: "+0.50", facts: still) == 0.5)
        #expect(EditControl.straighten.position(fromEntered: " -3.5° ", facts: still) == -3.5)
        #expect(EditControl.shadows.position(fromEntered: "\u{2212}20", facts: still) == -20)
        #expect(EditControl.exposure.position(fromEntered: "bright", facts: still) == nil)
        let kelvin = EditControl.temperature.position(fromEntered: "6500 K", facts: raw)
        #expect(kelvin.map { abs(EditControl.kelvin(atPosition: $0) - 6500) < 0.01 } == true)
        #expect(EditControl.temperature.position(fromEntered: "30", facts: still) == 30)
    }

    /// ADR 0036: a photo is offered the Detail and Optics controls its decoder supports.
    @Test func sectionsAndControlsFollowWhatThePhotoOffers() {
        let still = EditPhotoFacts.still
        #expect(EditSection.detail.isAvailable(still))
        #expect(!EditSection.optics.isAvailable(still))
        #expect(EditControl.sharpening.isAvailable(still))
        #expect(!EditControl.moireReduction.isAvailable(still))

        let raw9 = EditPhotoFacts(
            isRAW: true, asShotTemperature: 5000, asShotTint: 0,
            rawDetail: [.sharpening: 100, .noiseReduction: 33], lensCorrectionDefault: true
        )
        #expect(EditSection.optics.isAvailable(raw9))
        #expect(!EditControl.colorNoiseReduction.isAvailable(raw9))
        #expect(EditControl.noiseReduction.sliderValue(in: .neutral, facts: raw9) == 33)
        #expect(EditControl.noiseReduction.formatted(.neutral, facts: raw9) == "33")
        #expect(EditControl.noiseReduction.applying(50, to: .neutral, facts: raw9).noiseReduction == 50)

        let raw8 = EditPhotoFacts(
            isRAW: true, asShotTemperature: 5000, asShotTint: 0,
            rawDetail: [.sharpening: 100, .colorNoiseReduction: 50, .detail: 17, .moireReduction: 55]
        )
        #expect(EditControl.moireReduction.isAvailable(raw8))
        #expect(!EditControl.noiseReduction.isAvailable(raw8))
        #expect(!EditSection.optics.isAvailable(raw8))
        #expect(EditControl.vignette.formatted(EditRecipe(vignette: -30), facts: still) == "-30")
        #expect(EditSection.effects.reset(EditRecipe(vignette: -30, vignetteMidpoint: 10)) == .neutral)
    }

    @Test func eachSectionResetsOnlyItsOwnControls() {
        let edited = EditRecipe(exposure: 1, contrast: 10, temperature: 5000, tint: 3, vibrance: 20, saturation: -5)
        #expect(EditSection.color.reset(edited) == EditRecipe(exposure: 1, contrast: 10))
        #expect(EditSection.light.reset(edited) == EditRecipe(temperature: 5000, tint: 3, vibrance: 20, saturation: -5))
        #expect(EditSection.light.isNeutral(in: EditRecipe(vibrance: 20)))
        #expect(!EditSection.color.isNeutral(in: EditRecipe(vibrance: 20)))
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

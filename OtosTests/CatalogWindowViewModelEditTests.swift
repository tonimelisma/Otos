import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

/// The edit panel (ADR 0036) against a real catalog and real JPEGs: dragging renders
/// live without saving, letting go saves once and renders the photo's thumbnail and
/// preview, and Edit ▸ Undo and Redo step through saves.
///
/// Every save travels the view model's one edit lane, so `hasSettledEdits` is the fact
/// that it has been saved, rendered and applied (or refused); each step waits for that.
@Suite(.testDirectory)
@MainActor
struct CatalogWindowViewModelEditTests {
    @Test func draggingRendersLiveAndLettingGoSavesAndRendersTheProducts() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.toggleInspector(.edit)
            model.selectAll()
            model.setViewMode(.loupe)
            try await waitUntil { model.editTarget?.id == id && model.canEdit }

            model.setEditDragging(true, control: .exposure)
            model.setEditValue(1, for: .exposure)
            try await waitUntil { model.editLivePreview?.recipe == EditRecipe(exposure: 1) }
            #expect(model.submittedEditCommandCount == 0)
            #expect(model.displayedPanePreview(.loupe)?.image === model.editLivePreview?.image)

            model.setEditDragging(false, control: .exposure)
            #expect(model.submittedEditCommandCount == 1)
            try await waitUntil { model.hasSettledEdits }

            #expect(
                try await library.store.editRecipe(for: id)
                    == StoredEditRecipe(recipe: EditRecipe(exposure: 1), revision: 1)
            )
            #expect(try await library.store.mediaTileDetails(for: [id])[id]?.renderedRevision == 1)
            #expect(model.undoMenuState.undoTitle == "Undo Exposure")
            try await waitUntil { model.panePreviews[.loupe]?.renderedRevision == 1 }
            #expect(model.displayedPanePreview(.loupe)?.image === model.panePreviews[.loupe]?.image)
        }
    }

    /// The pane's progress indicator marks a pane waiting for its photo (DES-086): loading
    /// raises it, and refreshing the photo the pane already shows — an edit's new preview —
    /// does not.
    @Test func refreshingThePhotoTheLoupeShowsRaisesNoIndicator() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.selectAll()
            model.setViewMode(.loupe)
            #expect(model.downloadingSlots.contains(.loupe))
            try await waitUntil { model.panePreviews[.loupe]?.id == id }
            #expect(!model.downloadingSlots.contains(.loupe))

            model.requestPanePreview(id, slot: .loupe)

            #expect(!model.downloadingSlots.contains(.loupe))
            #expect(model.displayedPanePreview(.loupe)?.id == id)
        }
    }

    /// An undo shows what it changes (F-18): undoing an edit to a photo the user has moved
    /// away from selects that photo again, and the panel follows it.
    @Test func undoingAnEditToAnotherPhotoRevealsIt() async throws {
        try await withEditableLibrary(fileCount: 2) { library in
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.toggleInspector(.edit)
            model.selectAssets([library.ids[0]])
            try await waitUntil { model.editTarget?.id == library.ids[0] && model.canEdit }
            model.setEditValue(0.5, for: .exposure)
            try await waitUntil { model.hasSettledEdits }

            model.selectAssets([library.ids[1]])
            try await waitUntil { model.editTarget?.id == library.ids[1] }
            model.undoLastChange()

            #expect(model.targetIDs(.current) == [library.ids[0]])
            try await waitUntil { model.hasSettledEdits && model.editTarget?.id == library.ids[0] }
            #expect(try await library.store.editRecipe(for: library.ids[0])?.recipe == .neutral)
        }
    }

    @Test func undoAndRedoStepThroughSavesAndBringThePanelAlong() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.editTarget?.id == id && model.canEdit }

            model.setEditDragging(true, control: .contrast)
            model.setEditValue(40, for: .contrast)
            model.setEditDragging(false, control: .contrast)
            try await waitUntil { model.hasSettledEdits }

            model.undoLastChange()
            #expect(model.editDraft == .neutral)
            try await waitUntil { model.hasSettledEdits }
            #expect(try await library.store.editRecipe(for: id)?.recipe == .neutral)
            #expect(model.undoMenuState.redoTitle == "Redo Contrast")
            #expect(!model.undoMenuState.canUndo)

            model.redoLastChange()
            #expect(model.editDraft == EditRecipe(contrast: 40))
            try await waitUntil { model.hasSettledEdits }
            let redone = try await library.store.editRecipe(for: id)
            #expect(redone?.recipe == EditRecipe(contrast: 40))
            #expect(try await library.store.mediaTileDetails(for: [id])[id]?.renderedRevision == redone?.revision)
        }
    }

    /// A change that is not a drag — a keyboard step on the focused slider — is saved at once.
    @Test func aChangeOutsideADragIsSavedAtOnce() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.editTarget?.id == id && model.canEdit }

            model.setEditValue(-30, for: .highlights)

            #expect(model.submittedEditCommandCount == 1)
            try await waitUntil { model.hasSettledEdits }
            #expect(try await library.store.editRecipe(for: id)?.recipe == EditRecipe(highlights: -30))
        }
    }

    @Test func resetReturnsEveryLightControlToNeutralAsOneUndoStep() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.editTarget?.id == id && model.canEdit }
            model.setEditValue(0.5, for: .exposure)
            model.setEditValue(25, for: .shadows)
            try await waitUntil { model.hasSettledEdits }

            model.resetEditSection(.light)
            try await waitUntil { model.hasSettledEdits }
            #expect(try await library.store.editRecipe(for: id)?.recipe == .neutral)
            #expect(model.undoMenuState.undoTitle == "Undo Reset Light")

            model.undoLastChange()
            try await waitUntil { model.hasSettledEdits }
            #expect(try await library.store.editRecipe(for: id)?.recipe == EditRecipe(exposure: 0.5, shadows: 25))
        }
    }

    /// The picker, armed in the loupe, saves the clicked point's white balance as one step.
    @Test func theWhiteBalancePickerSavesTheClickedPointAsOneStep() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            try writeSolidJPEG(to: id.fileURL)
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.toggleInspector(.edit)
            model.selectAll()
            #expect(!model.canPickNeutral)
            model.setViewMode(.loupe)
            try await waitUntil { model.editTarget?.id == id && model.canEdit }
            #expect(model.canPickNeutral)

            model.toggleNeutralPicker()
            #expect(model.isPickingNeutral)
            model.pickNeutral(at: CGPoint(x: 0.5, y: 0.5))
            #expect(!model.isPickingNeutral)
            try await waitUntil { model.hasSettledEdits && model.submittedEditCommandCount == 2 }

            let saved = try await library.store.editRecipe(for: id)?.recipe
            #expect((saved?.temperature ?? 0) < 0)
            #expect(model.editDraft == saved)
            #expect(model.undoMenuState.undoTitle == "Undo White Balance")
        }
    }

    @Test func escapeDisarmsThePickerBeforeLeavingTheLoupe() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.toggleInspector(.edit)
            model.selectAll()
            model.setViewMode(.loupe)
            try await waitUntil { model.canEdit }
            model.toggleNeutralPicker()

            model.loupeEscape()

            #expect(!model.isPickingNeutral)
            #expect(model.viewMode == .loupe)
        }
    }

    /// C from the grid opens the panel and the loupe with the crop tool on; a drag saves
    /// one step when let go, and Escape ends the tool keeping the crop.
    @Test func theCropToolSavesADragAsOneStepAndEscapeEndsIt() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.selectAll()

            model.toggleCropTool()
            #expect(model.isEditPanelPresented)
            #expect(model.viewMode == .loupe)
            #expect(model.isCropping)
            try await waitUntil { model.canEdit && model.editCropBase?.id == id }

            let crop = EditCrop(left: 0.1, top: 0.1, width: 0.5, height: 0.5)
            model.setCrop(crop, dragging: true)
            #expect(model.submittedEditCommandCount == 0)
            model.setCrop(crop, dragging: false)
            try await waitUntil { model.hasSettledEdits }
            #expect(try await library.store.editRecipe(for: id)?.recipe.crop == crop)
            #expect(model.undoMenuState.undoTitle == "Undo Crop")

            model.loupeEscape()
            #expect(!model.isCropping)
            #expect(model.editCropBase == nil)
            #expect(model.viewMode == .loupe)
        }
    }

    /// A line drawn on the crop canvas straightens the photo along it as one step; the
    /// ruler that armed it disarms.
    @Test func aLineDrawnOnTheCanvasStraightensAlongIt() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.selectAll()
            model.toggleCropTool()
            try await waitUntil { model.canEdit && model.editCropBase?.id == id }

            model.toggleStraightenLine()
            #expect(model.isDrawingStraightenLine)
            model.straighten(along: .zero, to: CGPoint(x: 100, y: -100 * tan(4 * Double.pi / 180)))
            #expect(!model.isDrawingStraightenLine)
            try await waitUntil { model.hasSettledEdits }
            let straighten = try #require(try await library.store.editRecipe(for: id)?.recipe.straighten)
            #expect(abs(straighten - 4) < 0.051)
            #expect(model.undoMenuState.undoTitle == "Undo Straighten")
        }
    }

    /// A suggested crop is placed by the subject Vision finds in the frame the tool shows,
    /// as one step.
    @Test func aSuggestedCropHoldsTheSubject() async throws {
        let center = CGPoint(x: 0.3, y: 0.35)
        try await withEditableLibrary(fileCount: 1, write: { try writeSubjectJPEG(to: $0, center: center) }) { library in
            let id = library.ids[0]
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.selectAll()
            model.toggleCropTool()
            try await waitUntil { model.canSuggestCrop && model.editCropBase?.id == id }

            model.suggestCrop(.fitSubject)
            try await waitUntil { model.hasSettledEdits }
            let crop = try #require(try await library.store.editRecipe(for: id)?.recipe.crop)
            #expect(crop.left < center.x && crop.right > center.x)
            #expect(crop.top < center.y && crop.bottom > center.y)
            #expect(crop.width < 0.6)
            #expect(model.undoMenuState.undoTitle == "Undo Suggested Crop")
        }
    }

    /// Crop geometry takes the photo's upright size from the decode it is edited from,
    /// never from the catalog row: a HEIF turned by its `irot` property can be cataloged
    /// with its stored landscape size while it shows upright.
    @Test func cropGeometryUsesTheOpenedPhotosUprightSize() async throws {
        try await withEditableLibrary(fileCount: 1, fileExtension: "heic", write: writeRotatedHEIC) { library in
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.toggleInspector(.edit)
            model.selectAll()
            model.setViewMode(.loupe)
            try await waitUntil { model.editTarget?.id == library.ids[0] && model.canEdit }

            #expect(model.editOriginalPixelSize == CGSize(width: 64, height: 96))
            #expect(model.cropFrameSize == CGSize(width: 64, height: 96))
            model.turnPhoto(clockwise: true)
            #expect(model.cropFrameSize == CGSize(width: 96, height: 64))
        }
    }

    /// C pressed before the photo has opened (the panel opens with it) must not decide the
    /// aspect's orientation from an unknown frame: a portrait photo's Original aspect stays
    /// portrait once its size is known, instead of snapping a drag to a landscape crop.
    @Test func cropBeforeThePhotoOpensKeepsAPortraitPhotosAspectPortrait() async throws {
        try await withEditableLibrary(fileCount: 1, fileExtension: "heic", write: writeRotatedHEIC) { library in
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.selectAll()

            model.toggleCropTool()
            #expect(model.isCropping)
            try await waitUntil { model.canEdit }

            let ratio = try #require(model.cropPixelRatio)
            #expect(abs(ratio - 64.0 / 96.0) < 0.001)
            #expect(!model.cropAspectIsLandscape)
            model.rotateCropAspect()
            #expect(model.cropAspectIsLandscape)
        }
    }

    @Test func rotateRightAndUndoTurnTheSavedPhoto() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.canEdit }

            model.turnPhoto(clockwise: true)
            try await waitUntil { model.hasSettledEdits }
            #expect(try await library.store.editRecipe(for: id)?.recipe.quarterTurns == 1)
            #expect(model.undoMenuState.undoTitle == "Undo Rotate Right")

            model.undoLastChange()
            try await waitUntil { model.hasSettledEdits }
            #expect(try await library.store.editRecipe(for: id)?.recipe.quarterTurns == 0)
        }
    }

    /// The Crop section's Auto levels the horizon as one undo step, and Undo puts it back.
    @Test func autoStraightenLevelsTheHorizonAsOneUndoStep() async throws {
        try await withEditableLibrary(fileCount: 1, write: { try writeHorizonJPEG(to: $0, risingBy: 6) }) { library in
            let id = library.ids[0]
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.canEdit }

            model.autoStraighten()
            try await waitUntil { model.hasSettledEdits }
            let straighten = try #require(try await library.store.editRecipe(for: id)?.recipe.straighten)
            #expect(abs(straighten - 6) < 1)
            #expect(model.undoMenuState.undoTitle == "Undo Auto Straighten")

            model.undoLastChange()
            try await waitUntil { model.hasSettledEdits }
            #expect(try await library.store.editRecipe(for: id)?.recipe.straighten == 0)
        }
    }

    /// An iPhone back camera's gravity reading levels the photo ahead of the horizon in its
    /// pixels, and is mirrored on a photo shown flipped.
    @Test func autoStraightenTakesTheCamerasLevelBeforeTheHorizon() async throws {
        // Gravity 3° counterclockwise of straight down the screen: a −3° turn levels it.
        let tilt = 3 * Double.pi / 180
        let write: (URL) throws -> Void = {
            try writeLeveledJPEG(
                to: $0, risingBy: 6, gravity: (x: -sin(tilt), y: -cos(tilt), z: 0),
                lensModel: "iPhone 18 Pro back triple camera 6.93mm f/1.48"
            )
        }
        try await withEditableLibrary(fileCount: 1, write: write) { library in
            let id = library.ids[0]
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.canEdit }

            model.autoStraighten()
            try await waitUntil { model.hasSettledEdits }
            let plain = try #require(try await library.store.editRecipe(for: id)?.recipe.straighten)
            #expect(abs(plain + 3) < 0.05)

            model.undoLastChange()
            try await waitUntil { model.hasSettledEdits }
            model.flipPhoto(horizontally: true)
            model.autoStraighten()
            try await waitUntil { model.hasSettledEdits }
            let flipped = try #require(try await library.store.editRecipe(for: id)?.recipe)
            #expect(flipped.flipHorizontal)
            #expect(abs(flipped.straighten - 3) < 0.05)
        }
    }

    /// A front-camera photo's gravity reading says nothing about how it is shown, since iOS
    /// may have mirrored it: Auto levels its horizon instead.
    @Test func aFrontCameraPhotoIsLeveledByItsHorizon() async throws {
        let tilt = 3 * Double.pi / 180
        let write: (URL) throws -> Void = {
            try writeLeveledJPEG(
                to: $0, risingBy: 6, gravity: (x: -sin(tilt), y: -cos(tilt), z: 0),
                lensModel: "iPhone 18 Pro front camera 2.715mm f/1.9"
            )
        }
        try await withEditableLibrary(fileCount: 1, write: write) { library in
            let id = library.ids[0]
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.canEdit }

            model.autoStraighten()
            try await waitUntil { model.hasSettledEdits }
            let straighten = try #require(try await library.store.editRecipe(for: id)?.recipe.straighten)
            #expect(abs(straighten - 6) < 1)
        }
    }

    /// A reading taken before the photo was turned is measured in another frame, and one
    /// that found no level has nothing to apply: either leaves the photo as it is.
    @Test func aStaleOrEmptyLevelReadingChangesNothing() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.canEdit }

            model.applyAutoStraighten(id: id, shown: EditRecipe(quarterTurns: 1), .level(5, .gravity))
            model.applyAutoStraighten(id: id, shown: model.editDraft, .none)

            #expect(model.editDraft.straighten == 0)
            #expect(model.undoMenuState.undoTitle != "Undo Auto Straighten")
        }
    }

    @Test func leavingTheLoupeEndsTheCropTool() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.selectAll()
            model.toggleCropTool()
            try await waitUntil { model.canEdit }
            #expect(model.isCropping)

            model.setViewMode(.grid)

            #expect(!model.isCropping)
        }
    }

    /// The panel edits one photo; with two selected its controls have nothing to act on.
    @Test func aMultipleSelectionHasNoEditTarget() async throws {
        try await withEditableLibrary(fileCount: 2) { library in
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.toggleInspector(.edit)
            _ = model.applyGridClick(hit: library.ids[0], modifiers: [], orderedIDs: library.ids)
            try await waitUntil { model.editTarget?.id == library.ids[0] }

            model.selectAll()

            #expect(model.editTarget == nil)
            model.setEditValue(1, for: .exposure)
            #expect(model.submittedEditCommandCount == 0)
        }
    }

    @Test func hidingThePanelLetsGoOfTheTarget() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.editTarget != nil }

            model.toggleInspector(.edit)

            #expect(!model.isEditPanelPresented)
            #expect(model.editTarget == nil)
            #expect(model.editLivePreview == nil)
        }
    }
}

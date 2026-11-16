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
@Suite(.testScope)
@MainActor
struct CatalogWindowViewModelEditTests {
    @Test func draggingRendersLiveAndLettingGoSavesAndRendersTheProducts() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = library.makeEditModel()
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
            let model = library.makeEditModel()
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
            let model = library.makeEditModel()
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
            let model = library.makeEditModel()
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

    @Test func resetReturnsEveryLightControlToNeutralAsOneUndoStep() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = library.makeEditModel()
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
            let model = library.makeEditModel()
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
            let model = library.makeEditModel()
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
            let model = library.makeEditModel()
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
            let model = library.makeEditModel()
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

    /// Crop geometry takes the photo's upright size from the decode it is edited from,
    /// never from the catalog row: a HEIF turned by its `irot` property can be cataloged
    /// with its stored landscape size while it shows upright.
    @Test func cropGeometryUsesTheOpenedPhotosUprightSize() async throws {
        try await withEditableLibrary(fileCount: 1, fileExtension: "heic", write: writeRotatedHEIC) { library in
            let model = library.makeEditModel()
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

    /// The crop tool starts with Custom, even when C is pressed before the photo has opened;
    /// Original chosen once it opens stands as the photo does, portrait here, never a
    /// landscape guess from an unknown frame.
    @Test func cropStartsCustomAndOriginalStandsAsThePhotoDoes() async throws {
        try await withEditableLibrary(fileCount: 1, fileExtension: "heic", write: writeRotatedHEIC) { library in
            let model = library.makeEditModel()
            model.selectAll()

            model.toggleCropTool()
            #expect(model.isCropping)
            #expect(model.cropAspect == .free)
            try await waitUntil { model.canEdit }
            model.setCropAspect(.original)

            let ratio = try #require(model.cropPixelRatio)
            #expect(abs(ratio - 64.0 / 96.0) < 0.001)
            #expect(!model.cropAspectIsLandscape)
            model.rotateCropAspect()
            #expect(model.cropAspectIsLandscape)
        }
    }

    /// Level ▸ Auto straightens by an iPhone back camera's gravity reading, as one undo step,
    /// mirrored on a photo shown flipped; the reading is known as the photo opens.
    @Test func autoStraightenUsesTheCamerasReadingAndMirrorsItWhenFlipped() async throws {
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
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.canEdit }
            #expect(model.autoStraightenState == .available(.gravity))

            model.autoStraighten()
            try await waitUntil { model.hasSettledEdits }
            let plain = try #require(try await library.store.editRecipe(for: id)?.recipe.straighten)
            #expect(abs(plain + 3) < 0.05)
            #expect(model.undoMenuState.undoTitle == "Undo Auto Straighten")

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
    /// may have mirrored it: Auto straighten never uses it, and reads the pixels instead.
    @Test func aFrontCameraReadingIsNeverTheLevel() async throws {
        let tilt = 3 * Double.pi / 180
        let write: (URL) throws -> Void = {
            try writeLeveledJPEG(
                to: $0, risingBy: 6, gravity: (x: -sin(tilt), y: -cos(tilt), z: 0),
                lensModel: "iPhone 18 Pro front camera 2.715mm f/1.9"
            )
        }
        try await withEditableLibrary(fileCount: 1, write: write) { library in
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.canEdit && model.autoStraightenState != .reading }

            #expect(model.autoStraightenState != .available(.gravity))
        }
    }

    /// Suggested ▸ Crop applies the crop read for the frame the draft shows, as one undo
    /// step; once the frame turns, that reading no longer applies until the new frame is read.
    @Test func autoCropAppliesTheReadingForTheFrameAsShown() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.canEdit && model.autoCropState != .reading }

            // Whatever FocalNet read for this frame, the button applies the reading it holds.
            let suggested = EditCrop(left: 0.1, top: 0.05, width: 0.7, height: 0.8)
            model.editAutoCrop = AutoCropReading(id: id, frame: model.editDraft.uncropped, crop: suggested)
            #expect(model.autoCropState == .available(nil))
            model.autoCrop()
            try await waitUntil { model.hasSettledEdits }
            #expect(try await library.store.editRecipe(for: id)?.recipe.crop == suggested)
            #expect(model.undoMenuState.undoTitle == "Undo Auto Crop")

            model.editAutoCrop = AutoCropReading(id: id, frame: model.editDraft.uncropped, crop: suggested)
            model.turnPhoto(clockwise: true)
            #expect(model.autoCropState == .reading)
            try await waitUntil { model.autoCropState != .reading }
            #expect(model.editAutoCrop?.frame.quarterTurns == 1)
        }
    }

    /// The ruler draws on the crop canvas, so arming it with the tool off turns the tool on.
    @Test func theRulerTurnsTheCropToolOn() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.canEdit }

            model.toggleStraightenLine()

            #expect(model.isCropping)
            #expect(model.isDrawingStraightenLine)
        }
    }

    @Test func leavingTheLoupeEndsTheCropTool() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let model = library.makeEditModel()
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
            let model = library.makeEditModel()
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
            let model = library.makeEditModel()
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

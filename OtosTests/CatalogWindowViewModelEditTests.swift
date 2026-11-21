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
            try await waitUntil { model.editSession.editTarget?.id == id && model.editSession.canEdit }

            model.editSession.setEditDragging(true, control: .exposure)
            model.editSession.setEditValue(1, for: .exposure)
            try await waitUntil { model.editSession.editLivePreview?.recipe == EditRecipe(exposure: 1) }
            #expect(model.editSession.submittedEditCommandCount == 0)
            #expect(model.editSession.displayedPanePreview(.loupe)?.image === model.editSession.editLivePreview?.image)

            model.editSession.setEditDragging(false, control: .exposure)
            #expect(model.editSession.submittedEditCommandCount == 1)
            try await waitUntil { model.editSession.hasSettledEdits }

            #expect(
                try await library.store.windowReads.editRecipe(for: id)
                    == StoredEditRecipe(recipe: EditRecipe(exposure: 1), revision: 1)
            )
            #expect(try await library.store.windowReads.mediaTileDetails(for: [id])[id]?.renderedRevision == 1)
            #expect(model.undoMenuState.undoTitle == "Undo Exposure")
            try await waitUntil { model.panePreviews[.loupe]?.renderedRevision == 1 }
            #expect(model.editSession.displayedPanePreview(.loupe)?.image === model.panePreviews[.loupe]?.image)
        }
    }

    /// A section with changes has a checkmark that turns its changes off in the loupe, saving
    /// nothing, until the edit changes or another photo is opened (DES-122).
    @Test func aSectionsCheckmarkTurnsItsChangesOffInTheLoupeUntilTheEditChanges() async throws {
        try await withEditableLibrary(fileCount: 2) { library in
            let edited = library.ids[0]
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.setViewMode(.loupe)
            model.selectAssets([edited])
            try await waitUntil { model.editSession.editTarget?.id == edited && model.editSession.canEdit }
            model.editSession.setEditValue(1, for: .exposure)
            try await waitUntil { model.editSession.hasSettledEdits }

            model.editSession.toggleEditSection(.color)
            #expect(model.editSession.sectionsTurnedOff.isEmpty, "a section without changes has no checkmark to turn off")
            model.editSession.toggleEditSection(.light)
            #expect(model.editSession.sectionsTurnedOff == [.light])
            #expect(model.editSession.shownRecipe == .neutral)
            try await waitUntil { model.editSession.editLivePreview?.recipe == .neutral }
            #expect(try await library.store.windowReads.editRecipe(for: edited)?.recipe == EditRecipe(exposure: 1))

            model.editSession.toggleEditSection(.light)
            #expect(model.editSession.sectionsTurnedOff.isEmpty)
            try await waitUntil { model.editSession.editLivePreview?.recipe == EditRecipe(exposure: 1) }

            model.editSession.toggleEditSection(.light)
            model.editSession.setEditValue(0.5, for: .exposure)
            #expect(model.editSession.sectionsTurnedOff.isEmpty, "a change to the edit turns every section back on")

            model.editSession.toggleEditSection(.light)
            model.selectAssets([library.ids[1]])
            try await waitUntil { model.editSession.editTarget?.id == library.ids[1] }
            #expect(model.editSession.sectionsTurnedOff.isEmpty)
        }
    }

    /// Returning to an edited photo shows its edit from the first image the loupe paints, with
    /// the edit panel open and closed (owner, 2026-11-19: "it shows in the loupe the unedited
    /// version for a subsecond before switching to the edited one").
    @Test(arguments: [true, false])
    func anEditedPhotoIsNeverShownUnedited(panelOpen: Bool) async throws {
        try await withEditableLibrary(fileCount: 2) { library in
            let edited = library.ids[0], other = library.ids[1]
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.setViewMode(.loupe)
            model.selectAssets([edited])
            try await waitUntil { model.editSession.editTarget?.id == edited && model.editSession.canEdit }
            model.editSession.setEditValue(1, for: .exposure)
            try await waitUntil { model.editSession.hasSettledEdits && model.panePreviews[.loupe]?.renderedRevision == 1 }
            if !panelOpen {
                model.toggleInspector(.edit)
            }

            model.selectAssets([other])
            try await waitUntil { model.editSession.displayedPanePreview(.loupe)?.id == other }
            let shown = Observations { @MainActor in
                model.editSession.displayedPanePreview(.loupe).map { ($0.id, $0.renderedRevision, $0.editRecipe) }
            }
            model.selectAssets([edited])
            var seen: [(MediaAssetID, Int64, EditRecipe?)] = []
            for await preview in shown {
                guard let preview, preview.0 == edited else { continue }
                seen.append(preview)
                if preview.1 >= 1 {
                    break
                }
            }
            #expect(seen.allSatisfy { $0.1 >= 1 }, "the loupe showed \(seen.map { "revision \($0.1)" })")
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
            #expect(model.editSession.displayedPanePreview(.loupe)?.id == id)
        }
    }

    /// An undo shows what it changes (F-18): undoing an edit to a photo the user has moved
    /// away from selects that photo again, and the panel follows it.
    @Test func undoingAnEditToAnotherPhotoRevealsIt() async throws {
        try await withEditableLibrary(fileCount: 2) { library in
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAssets([library.ids[0]])
            try await waitUntil { model.editSession.editTarget?.id == library.ids[0] && model.editSession.canEdit }
            model.editSession.setEditValue(0.5, for: .exposure)
            try await waitUntil { model.editSession.hasSettledEdits }

            model.selectAssets([library.ids[1]])
            try await waitUntil { model.editSession.editTarget?.id == library.ids[1] }
            model.undoLastChange()

            #expect(model.targetIDs(.current) == [library.ids[0]])
            try await waitUntil { model.editSession.hasSettledEdits && model.editSession.editTarget?.id == library.ids[0] }
            #expect(try await library.store.windowReads.editRecipe(for: library.ids[0])?.recipe == .neutral)
        }
    }

    @Test func undoAndRedoStepThroughSavesAndBringThePanelAlong() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.editSession.editTarget?.id == id && model.editSession.canEdit }

            model.editSession.setEditDragging(true, control: .contrast)
            model.editSession.setEditValue(40, for: .contrast)
            model.editSession.setEditDragging(false, control: .contrast)
            try await waitUntil { model.editSession.hasSettledEdits }

            model.undoLastChange()
            #expect(model.editSession.editDraft == .neutral)
            try await waitUntil { model.editSession.hasSettledEdits }
            #expect(try await library.store.windowReads.editRecipe(for: id)?.recipe == .neutral)
            #expect(model.undoMenuState.redoTitle == "Redo Contrast")
            #expect(!model.undoMenuState.canUndo)

            model.redoLastChange()
            #expect(model.editSession.editDraft == EditRecipe(contrast: 40))
            try await waitUntil { model.editSession.hasSettledEdits }
            let redone = try await library.store.windowReads.editRecipe(for: id)
            #expect(redone?.recipe == EditRecipe(contrast: 40))
            #expect(try await library.store.windowReads.mediaTileDetails(for: [id])[id]?.renderedRevision == redone?.revision)
        }
    }

    @Test func resetReturnsEveryLightControlToNeutralAsOneUndoStep() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.editSession.editTarget?.id == id && model.editSession.canEdit }
            model.editSession.setEditValue(0.5, for: .exposure)
            model.editSession.setEditValue(25, for: .shadows)
            try await waitUntil { model.editSession.hasSettledEdits }

            model.editSession.resetEditSection(.light)
            try await waitUntil { model.editSession.hasSettledEdits }
            #expect(try await library.store.windowReads.editRecipe(for: id)?.recipe == .neutral)
            #expect(model.undoMenuState.undoTitle == "Undo Reset Light")

            model.undoLastChange()
            try await waitUntil { model.editSession.hasSettledEdits }
            #expect(try await library.store.windowReads.editRecipe(for: id)?.recipe == EditRecipe(exposure: 0.5, shadows: 25))
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
            #expect(!model.editSession.canPickNeutral)
            model.setViewMode(.loupe)
            try await waitUntil { model.editSession.editTarget?.id == id && model.editSession.canEdit }
            #expect(model.editSession.canPickNeutral)

            model.editSession.toggleNeutralPicker()
            #expect(model.editSession.isPickingNeutral)
            model.editSession.pickNeutral(at: CGPoint(x: 0.5, y: 0.5))
            #expect(!model.editSession.isPickingNeutral)
            try await waitUntil { model.editSession.hasSettledEdits && model.editSession.submittedEditCommandCount == 2 }

            let saved = try await library.store.windowReads.editRecipe(for: id)?.recipe
            #expect((saved?.temperature ?? 0) < 0)
            #expect(model.editSession.editDraft == saved)
            #expect(model.undoMenuState.undoTitle == "Undo White Balance")
        }
    }

    @Test func escapeDisarmsThePickerBeforeLeavingTheLoupe() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAll()
            model.setViewMode(.loupe)
            try await waitUntil { model.editSession.canEdit }
            model.editSession.toggleNeutralPicker()

            model.loupeEscape()

            #expect(!model.editSession.isPickingNeutral)
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

            model.editSession.toggleCropTool()
            #expect(model.isEditPanelPresented)
            #expect(model.viewMode == .loupe)
            #expect(model.editSession.isCropping)
            try await waitUntil { model.editSession.canEdit && model.editSession.editCropBase?.id == id }

            let crop = EditCrop(left: 0.1, top: 0.1, width: 0.5, height: 0.5)
            model.editSession.setCrop(crop, dragging: true)
            #expect(model.editSession.submittedEditCommandCount == 0)
            model.editSession.setCrop(crop, dragging: false)
            try await waitUntil { model.editSession.hasSettledEdits }
            #expect(try await library.store.windowReads.editRecipe(for: id)?.recipe.crop == crop)
            #expect(model.undoMenuState.undoTitle == "Undo Crop")

            model.loupeEscape()
            #expect(!model.editSession.isCropping)
            #expect(model.editSession.editCropBase == nil)
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
            model.editSession.toggleCropTool()
            try await waitUntil { model.editSession.canEdit && model.editSession.editCropBase?.id == id }

            model.editSession.toggleStraightenLine()
            #expect(model.editSession.isDrawingStraightenLine)
            model.editSession.straighten(along: .zero, to: CGPoint(x: 100, y: -100 * tan(4 * Double.pi / 180)))
            #expect(!model.editSession.isDrawingStraightenLine)
            try await waitUntil { model.editSession.hasSettledEdits }
            let straighten = try #require(try await library.store.windowReads.editRecipe(for: id)?.recipe.straighten)
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
            try await waitUntil { model.editSession.editTarget?.id == library.ids[0] && model.editSession.canEdit }

            #expect(model.editSession.editOriginalPixelSize == CGSize(width: 64, height: 96))
            #expect(model.editSession.cropFrameSize == CGSize(width: 64, height: 96))
            model.editSession.turnPhoto(clockwise: true)
            #expect(model.editSession.cropFrameSize == CGSize(width: 96, height: 64))
        }
    }

    /// The crop tool starts with Custom, even when C is pressed before the photo has opened;
    /// Original chosen once it opens stands as the photo does, portrait here, never a
    /// landscape guess from an unknown frame.
    @Test func cropStartsCustomAndOriginalStandsAsThePhotoDoes() async throws {
        try await withEditableLibrary(fileCount: 1, fileExtension: "heic", write: writeRotatedHEIC) { library in
            let model = library.makeEditModel()
            model.selectAll()

            model.editSession.toggleCropTool()
            #expect(model.editSession.isCropping)
            #expect(model.editSession.cropAspect == .free)
            try await waitUntil { model.editSession.canEdit }
            model.editSession.setCropAspect(.original)

            let ratio = try #require(model.editSession.cropPixelRatio)
            #expect(abs(ratio - 64.0 / 96.0) < 0.001)
            #expect(!model.editSession.cropAspectIsLandscape)
            model.editSession.rotateCropAspect()
            #expect(model.editSession.cropAspectIsLandscape)
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
            try await waitUntil { model.editSession.canEdit }
            #expect(model.editSession.autoStraightenState == .available(.gravity))

            model.editSession.autoStraighten()
            try await waitUntil { model.editSession.hasSettledEdits }
            let plain = try #require(try await library.store.windowReads.editRecipe(for: id)?.recipe.straighten)
            #expect(abs(plain + 3) < 0.05)
            #expect(model.undoMenuState.undoTitle == "Undo Auto Straighten")

            model.undoLastChange()
            try await waitUntil { model.editSession.hasSettledEdits }
            model.editSession.flipPhoto(horizontally: true)
            model.editSession.autoStraighten()
            try await waitUntil { model.editSession.hasSettledEdits }
            let flipped = try #require(try await library.store.windowReads.editRecipe(for: id)?.recipe)
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
            try await waitUntil { model.editSession.canEdit && model.editSession.autoStraightenState != .reading }

            #expect(model.editSession.autoStraightenState != .available(.gravity))
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
            try await waitUntil { model.editSession.canEdit && model.editSession.autoCropState != .reading }

            // Whatever FocalNet read for this frame, the button applies the reading it holds.
            let suggested = EditCrop(left: 0.1, top: 0.05, width: 0.7, height: 0.8)
            model.editSession.editAutoCrop = AutoCropReading(id: id, frame: model.editSession.editDraft.uncropped, crop: suggested)
            #expect(model.editSession.autoCropState == .available(nil))
            model.editSession.autoCrop()
            try await waitUntil { model.editSession.hasSettledEdits }
            #expect(try await library.store.windowReads.editRecipe(for: id)?.recipe.crop == suggested)
            #expect(model.undoMenuState.undoTitle == "Undo Auto Crop")

            model.editSession.editAutoCrop = AutoCropReading(id: id, frame: model.editSession.editDraft.uncropped, crop: suggested)
            model.editSession.turnPhoto(clockwise: true)
            #expect(model.editSession.autoCropState == .reading)
            try await waitUntil { model.editSession.autoCropState != .reading }
            #expect(model.editSession.editAutoCrop?.frame.quarterTurns == 1)
        }
    }

    /// The ruler draws on the crop canvas, so arming it with the tool off turns the tool on.
    @Test func theRulerTurnsTheCropToolOn() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.editSession.canEdit }

            model.editSession.toggleStraightenLine()

            #expect(model.editSession.isCropping)
            #expect(model.editSession.isDrawingStraightenLine)
        }
    }

    @Test func leavingTheLoupeEndsTheCropTool() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let model = library.makeEditModel()
            model.selectAll()
            model.editSession.toggleCropTool()
            try await waitUntil { model.editSession.canEdit }
            #expect(model.editSession.isCropping)

            model.setViewMode(.grid)

            #expect(!model.editSession.isCropping)
        }
    }

    /// The panel edits one photo; with two selected its controls have nothing to act on.
    @Test func aMultipleSelectionHasNoEditTarget() async throws {
        try await withEditableLibrary(fileCount: 2) { library in
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            _ = model.applyGridClick(hit: library.ids[0], modifiers: [], orderedIDs: library.ids)
            try await waitUntil { model.editSession.editTarget?.id == library.ids[0] }

            model.selectAll()

            #expect(model.editSession.editTarget == nil)
            model.editSession.setEditValue(1, for: .exposure)
            #expect(model.editSession.submittedEditCommandCount == 0)
        }
    }

    @Test func hidingThePanelLetsGoOfTheTarget() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.editSession.editTarget != nil }

            model.toggleInspector(.edit)

            #expect(!model.isEditPanelPresented)
            #expect(model.editSession.editTarget == nil)
            #expect(model.editSession.editLivePreview == nil)
        }
    }
}

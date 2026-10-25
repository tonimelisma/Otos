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
            model.toggleEditPanel()
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

    @Test func undoAndRedoStepThroughSavesAndBringThePanelAlong() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.toggleEditPanel()
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
            model.toggleEditPanel()
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
            model.toggleEditPanel()
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
            model.toggleEditPanel()
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
            model.toggleEditPanel()
            model.selectAll()
            model.setViewMode(.loupe)
            try await waitUntil { model.canEdit }
            model.toggleNeutralPicker()

            model.loupeEscape()

            #expect(!model.isPickingNeutral)
            #expect(model.viewMode == .loupe)
        }
    }

    /// The panel edits one photo; with two selected its controls have nothing to act on.
    @Test func aMultipleSelectionHasNoEditTarget() async throws {
        try await withEditableLibrary(fileCount: 2) { library in
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.toggleEditPanel()
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
            model.toggleEditPanel()
            model.selectAll()
            try await waitUntil { model.editTarget != nil }

            model.toggleEditPanel()

            #expect(!model.isEditPanelPresented)
            #expect(model.editTarget == nil)
            #expect(model.editLivePreview == nil)
        }
    }
}

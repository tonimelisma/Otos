import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

/// The edit panel's commands beyond its controls (ADR 0036): Show Original, Revert to
/// Original, the keyboard's selected adjustment, resetting one control, and the histogram,
/// against a real catalog and real photos.
@Suite(.testScope)
@MainActor
struct CatalogWindowViewModelEditCommandsTests {
    // Validates: APP-053
    @Test func showOriginalRendersTheUneditedPhotoUntilTheEditChanges() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAll()
            model.setViewMode(.loupe)
            try await waitUntil { model.editSession.editTarget?.id == id && model.editSession.canEdit }
            #expect(!model.editSession.canShowOriginal)
            // The opened photo's histogram, so the edit's can be told from it: the edited
            // preview can arrive through the saved edit, which counts no histogram.
            try await waitUntil { model.editSession.editHistogram != nil }
            let openedHistogram = model.editSession.editHistogram

            model.editSession.setEditValue(1, for: .exposure)
            try await waitUntil { model.editSession.hasSettledEdits && model.editSession.editLivePreview?.recipe == EditRecipe(exposure: 1) }
            let edited = try #require(model.editSession.displayedPanePreview(.loupe)?.image)

            try await waitUntil { model.editSession.editHistogram != openedHistogram }
            let editedHistogram = model.editSession.editHistogram
            model.editSession.toggleShowOriginal()
            #expect(model.editSession.isShowingOriginal)
            try await waitUntil { model.editSession.loupeShowsOriginal }
            // The histogram keeps describing the edit.
            #expect(model.editSession.editHistogram == editedHistogram)
            let original = try #require(model.editSession.displayedPanePreview(.loupe)?.image)
            #expect(original !== edited)
            #expect(meanBrightness(original.cgImage) < meanBrightness(edited.cgImage))

            model.editSession.setEditValue(0.5, for: .exposure)
            #expect(!model.editSession.isShowingOriginal)
            #expect(!model.editSession.loupeShowsOriginal)
            #expect(model.editSession.displayedPanePreview(.loupe)?.image !== original)

            // Leaving the loupe ends it, as it ends the crop tool.
            model.editSession.toggleShowOriginal()
            #expect(model.editSession.isShowingOriginal)
            model.setViewMode(.grid)
            #expect(!model.editSession.isShowingOriginal)
            #expect(!model.editSession.canShowOriginal)
        }
    }

    // Validates: APP-053
    @Test func revertToOriginalRemovesTheWholeEditAsOneUndoStep() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.editSession.editTarget?.id == id && model.editSession.canEdit }
            #expect(!model.editSession.canRevertToOriginal)
            model.editSession.setEditValue(0.5, for: .exposure)
            model.editSession.turnPhoto(clockwise: true)
            try await waitUntil { model.editSession.hasSettledEdits }
            #expect(model.editSession.canRevertToOriginal)

            model.editSession.revertToOriginal()
            #expect(model.editSession.editDraft == .neutral)
            try await waitUntil { model.editSession.hasSettledEdits }
            #expect(try await library.store.windowReads.editRecipe(for: id)?.recipe == .neutral)
            #expect(model.undoMenuState.undoTitle == "Undo Revert to Original")
            #expect(!model.editSession.canRevertToOriginal)

            model.undoLastChange()
            try await waitUntil { model.editSession.hasSettledEdits }
            #expect(
                try await library.store.windowReads.editRecipe(for: id)?.recipe == EditRecipe(exposure: 0.5, quarterTurns: 1)
            )
        }
    }

    // Validates: APP-053
    @Test func revertToOriginalUntrimsTheVideoInTheLoupe() async throws {
        let fixture = SourceTree.mediaFixtures.appending(path: "mov-no-embedded-capture-date.mov")
        try await withEditableLibrary(fileCount: 1, fileExtension: "mov", write: { url in
            try FileManager.default.copyItem(at: fixture, to: url)
        }) { library in
            let id = library.ids[0]
            _ = try await library.store.setEditRecipe(EditRecipe(trimStart: 0.5), for: id)
            let model = library.makeEditModel()
            model.selectAll()
            model.setViewMode(.loupe)
            try await waitUntil { model.loupeVideoState?.id == id && model.loupeVideoState?.recipe.trimStart == 0.5 }
            #expect(model.editSession.canRevertToOriginal)

            model.editSession.revertToOriginal()
            try await waitUntil { model.editSession.hasSettledEdits }
            #expect(try await library.store.windowReads.editRecipe(for: id)?.recipe == .neutral)
            #expect(model.loupeVideoState?.recipe == .neutral)
            #expect(model.undoMenuState.undoTitle == "Undo Revert to Original")
        }
    }

    // Validates: APP-054
    @Test func theKeyboardSelectsAnAdjustmentAndMovesItByItsStep() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.editSession.editTarget?.id == id && model.editSession.canEdit }
            #expect(!model.editSession.canNudgeEditControl)
            let controls = model.editSession.navigableEditControls

            model.editSession.selectAdjacentEditControl(forward: true)
            #expect(model.editSession.selectedEditControl == controls.first)
            model.editSession.selectAdjacentEditControl(forward: false)
            #expect(model.editSession.selectedEditControl == controls.last)
            model.editSession.selectAdjacentEditControl(forward: true)
            #expect(model.editSession.selectedEditControl == controls.first)

            model.editSession.setEditDragging(true, control: .exposure)
            model.editSession.setEditDragging(false, control: .exposure)
            #expect(model.editSession.selectedEditControl == .exposure)
            model.editSession.nudgeSelectedEditControl(up: true)
            model.editSession.nudgeSelectedEditControl(up: true)
            model.editSession.nudgeSelectedEditControl(up: false)
            try await waitUntil { model.editSession.hasSettledEdits }
            let nudged = try #require(try await library.store.windowReads.editRecipe(for: id)?.recipe)
            #expect(abs(nudged.exposure - 0.05) < 1e-9)
            #expect(nudged.contrast == 0)
            #expect(model.undoMenuState.undoTitle == "Undo Exposure")
        }
    }

    // Validates: APP-054
    @Test func resettingOneControlLeavesTheOthers() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.editSession.editTarget?.id == id && model.editSession.canEdit }
            model.editSession.setEditValue(0.5, for: .exposure)
            model.editSession.setEditValue(25, for: .shadows)
            try await waitUntil { model.editSession.hasSettledEdits }

            model.editSession.resetEditControl(.shadows)
            try await waitUntil { model.editSession.hasSettledEdits }
            #expect(try await library.store.windowReads.editRecipe(for: id)?.recipe == EditRecipe(exposure: 0.5))
            #expect(model.undoMenuState.undoTitle == "Undo Reset Shadows")
        }
    }

    // Validates: APP-055
    /// The histogram follows the render: the saved edit's when the photo opens, then each
    /// live render's.
    @Test func theHistogramFollowsTheRenderedPhoto() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.editSession.editTarget?.id == id && model.editSession.editHistogram != nil }
            let opened = try #require(model.editSession.editHistogram)

            model.editSession.setEditValue(-3, for: .exposure)
            try await waitUntil { model.editSession.editHistogram != opened }
            let darkened = try #require(model.editSession.editHistogram)
            #expect(meanBrightness(darkened) < meanBrightness(opened) / 2)

            model.toggleInspector(.edit)
            #expect(model.editSession.editHistogram == nil)
        }
    }
}

/// The mean of an image's red, green and blue, 0–255.
@MainActor
private func meanBrightness(_ image: CGImage) -> Double {
    EditHistogram.counting(image).map(meanBrightness) ?? 0
}

/// The mean of a histogram's red, green and blue, 0–255.
@MainActor
private func meanBrightness(_ histogram: EditHistogram) -> Double {
    func mean(_ bins: [Double]) -> Double {
        let total = bins.reduce(0, +)
        return zip(bins.indices, bins).reduce(0) { $0 + Double($1.0) * $1.1 } / max(total, 1) * 256 / Double(bins.count)
    }
    return (mean(histogram.red) + mean(histogram.green) + mean(histogram.blue)) / 3
}

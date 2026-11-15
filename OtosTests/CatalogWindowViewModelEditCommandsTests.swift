import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

/// The edit panel's commands beyond its controls (ADR 0036): Show Original, Revert to
/// Original, the keyboard's selected adjustment, resetting one control, and the histogram,
/// against a real catalog and real photos.
@Suite(.testDirectory)
@MainActor
struct CatalogWindowViewModelEditCommandsTests {
    @Test func showOriginalRendersTheUneditedPhotoUntilTheEditChanges() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAll()
            model.setViewMode(.loupe)
            try await waitUntil { model.editTarget?.id == id && model.canEdit }
            #expect(!model.canShowOriginal)
            // The opened photo's histogram, so the edit's can be told from it: the edited
            // preview can arrive through the saved edit, which counts no histogram.
            try await waitUntil { model.editHistogram != nil }
            let openedHistogram = model.editHistogram

            model.setEditValue(1, for: .exposure)
            try await waitUntil { model.hasSettledEdits && model.editLivePreview?.recipe == EditRecipe(exposure: 1) }
            let edited = try #require(model.displayedPanePreview(.loupe)?.image)

            try await waitUntil { model.editHistogram != openedHistogram }
            let editedHistogram = model.editHistogram
            model.toggleShowOriginal()
            #expect(model.isShowingOriginal)
            try await waitUntil { model.loupeShowsOriginal }
            // The histogram keeps describing the edit.
            #expect(model.editHistogram == editedHistogram)
            let original = try #require(model.displayedPanePreview(.loupe)?.image)
            #expect(original !== edited)
            #expect(meanBrightness(original) < meanBrightness(edited))

            model.setEditValue(0.5, for: .exposure)
            #expect(!model.isShowingOriginal)
            #expect(!model.loupeShowsOriginal)
            #expect(model.displayedPanePreview(.loupe)?.image !== original)

            // Leaving the loupe ends it, as it ends the crop tool.
            model.toggleShowOriginal()
            #expect(model.isShowingOriginal)
            model.setViewMode(.grid)
            #expect(!model.isShowingOriginal)
            #expect(!model.canShowOriginal)
        }
    }

    @Test func revertToOriginalRemovesTheWholeEditAsOneUndoStep() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.editTarget?.id == id && model.canEdit }
            #expect(!model.canRevertToOriginal)
            model.setEditValue(0.5, for: .exposure)
            model.turnPhoto(clockwise: true)
            try await waitUntil { model.hasSettledEdits }
            #expect(model.canRevertToOriginal)

            model.revertToOriginal()
            #expect(model.editDraft == .neutral)
            try await waitUntil { model.hasSettledEdits }
            #expect(try await library.store.editRecipe(for: id)?.recipe == .neutral)
            #expect(model.undoMenuState.undoTitle == "Undo Revert to Original")
            #expect(!model.canRevertToOriginal)

            model.undoLastChange()
            try await waitUntil { model.hasSettledEdits }
            #expect(
                try await library.store.editRecipe(for: id)?.recipe == EditRecipe(exposure: 0.5, quarterTurns: 1)
            )
        }
    }

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
            #expect(model.canRevertToOriginal)

            model.revertToOriginal()
            try await waitUntil { model.hasSettledEdits }
            #expect(try await library.store.editRecipe(for: id)?.recipe == .neutral)
            #expect(model.loupeVideoState?.recipe == .neutral)
            #expect(model.undoMenuState.undoTitle == "Undo Revert to Original")
        }
    }

    @Test func theKeyboardSelectsAnAdjustmentAndMovesItByItsStep() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.editTarget?.id == id && model.canEdit }
            #expect(!model.canNudgeEditControl)
            let controls = model.navigableEditControls

            model.selectAdjacentEditControl(forward: true)
            #expect(model.selectedEditControl == controls.first)
            model.selectAdjacentEditControl(forward: false)
            #expect(model.selectedEditControl == controls.last)
            model.selectAdjacentEditControl(forward: true)
            #expect(model.selectedEditControl == controls.first)

            model.setEditDragging(true, control: .exposure)
            model.setEditDragging(false, control: .exposure)
            #expect(model.selectedEditControl == .exposure)
            model.nudgeSelectedEditControl(up: true)
            model.nudgeSelectedEditControl(up: true)
            model.nudgeSelectedEditControl(up: false)
            try await waitUntil { model.hasSettledEdits }
            let nudged = try #require(try await library.store.editRecipe(for: id)?.recipe)
            #expect(abs(nudged.exposure - 0.05) < 1e-9)
            #expect(nudged.contrast == 0)
            #expect(model.undoMenuState.undoTitle == "Undo Exposure")
        }
    }

    @Test func resettingOneControlLeavesTheOthers() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.editTarget?.id == id && model.canEdit }
            model.setEditValue(0.5, for: .exposure)
            model.setEditValue(25, for: .shadows)
            try await waitUntil { model.hasSettledEdits }

            model.resetEditControl(.shadows)
            try await waitUntil { model.hasSettledEdits }
            #expect(try await library.store.editRecipe(for: id)?.recipe == EditRecipe(exposure: 0.5))
            #expect(model.undoMenuState.undoTitle == "Undo Reset Shadows")
        }
    }

    /// The histogram follows the render: the saved edit's when the photo opens, then each
    /// live render's.
    @Test func theHistogramFollowsTheRenderedPhoto() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.editTarget?.id == id && model.editHistogram != nil }
            let opened = try #require(model.editHistogram)

            model.setEditValue(-3, for: .exposure)
            try await waitUntil { model.editHistogram != opened }
            let darkened = try #require(model.editHistogram)
            #expect(meanBrightness(darkened) < meanBrightness(opened) / 2)

            model.toggleInspector(.edit)
            #expect(model.editHistogram == nil)
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

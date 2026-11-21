import Foundation
import OSLog

/// Edit commands guide
///
/// The edit panel's commands beyond its controls, each one intent behind its menu item,
/// its key and its panel button (ADR 0036; Lightroom's keys, DES-093):
/// - **Show Original (\\):** the loupe shows the open photo without its edit, rendered
///   through the live lane, until it is turned off, the photo changes, or the edit
///   changes. The loupe marks it, so it is never mistaken for the edit (DES-098).
/// - **Revert to Original (⌘⇧R):** the whole edit — adjustments, crop and orientation,
///   a video's trim — removed as one undo step, as Photos does.
/// - **Pick White Balance (W):** the Color section's picker.
/// - **The selected adjustment:** Select Previous and Next Adjustment (, and .) choose a
///   control in panel order and Increase and Decrease Adjustment (= and −) move it by its
///   keyboard step, each press one undo step, as Lightroom Classic's keys do.
///   Double-clicking a control's name resets it.
extension EditSession {
    // MARK: - Show Original

    /// View ▸ Show Original / Show Edited (\).
    func toggleShowOriginal() {
        if isShowingOriginal {
            endShowingOriginal()
            OtosLog.ui.noticeOperation("edit.showOriginal", phase: "off")
            return
        }
        guard canShowOriginal else { return }
        isShowingOriginal = true
        editOriginalPreview = nil
        requestOriginalRender()
        OtosLog.ui.noticeOperation("edit.showOriginal", phase: "on")
    }

    /// The loupe holds the photo being edited, and it has an edit to compare against.
    var canShowOriginal: Bool {
        canEdit && window.viewMode() == .loupe && !isCropping && !editDraft.isNeutral
    }

    /// The loupe is showing the original's render, which it marks (DES-098). Until that
    /// render arrives it still shows the edit, unmarked.
    var loupeShowsOriginal: Bool {
        isShowingOriginal && editOriginalPreview.map { $0.id == window.expectedAsset(.loupe) } == true
    }

    func endShowingOriginal() {
        guard isShowingOriginal || editOriginalPreview != nil else { return }
        isShowingOriginal = false
        editOriginalPreview = nil
    }

    // MARK: - Revert to Original

    /// Photo ▸ Revert to Original (⌘⇧R) and the panel's button.
    func revertToOriginal() {
        if editTarget != nil {
            guard canEdit, !editDraft.isNeutral else { return }
            endCropping()
            editDraft = .neutral
            requestLiveEditRender()
            commitEdit(actionName: "Revert to Original")
        } else if let video = revertibleVideo {
            enqueueEdit(EditCommand(id: video.id, recipe: .neutral, actionName: "Revert to Original", origin: .user))
        } else {
            return
        }
        OtosLog.ui.noticeOperation("edit.revert", phase: "submitted")
    }

    var canRevertToOriginal: Bool {
        (canEdit && !editDraft.isNeutral) || revertibleVideo != nil
    }

    /// A trimmed video in the loupe, which Revert to Original untrims.
    private var revertibleVideo: LoupeVideoState? {
        guard window.viewMode() == .loupe, let video = window.loupeVideoState(), video.id == window.focusedAssetID(),
              !video.recipe.isNeutral
        else { return nil }
        return video
    }

    // MARK: - Selected adjustment

    /// The controls the keyboard moves through, in panel order: those the open photo offers.
    var navigableEditControls: [EditControl] {
        guard let facts = editPhotoFacts else { return [] }
        return EditSection.allCases
            .filter { $0.isAvailable(facts) }
            .flatMap(\.controls)
            .filter { $0.isAvailable(facts) }
    }

    /// Photo ▸ Select Next Adjustment (.) and Select Previous Adjustment (,).
    func selectAdjacentEditControl(forward: Bool) {
        let controls = navigableEditControls
        guard canEdit, !controls.isEmpty else { return }
        guard let current = selectedEditControl, let index = controls.firstIndex(of: current) else {
            selectedEditControl = forward ? controls.first : controls.last
            return
        }
        let next = (index + (forward ? 1 : controls.count - 1)) % controls.count
        selectedEditControl = controls[next]
    }

    /// Photo ▸ Increase Adjustment (=) and Decrease Adjustment (−).
    func nudgeSelectedEditControl(up: Bool) {
        guard canEdit, let control = selectedEditControl, let facts = editPhotoFacts else { return }
        let step = control.keyboardStep(facts) * (up ? 1 : -1)
        setEditValue(control.sliderValue(in: editDraft, facts: facts) + step, for: control)
    }

    var canNudgeEditControl: Bool {
        canEdit && selectedEditControl != nil
    }

    /// Double-clicking a control's name: that control back to neutral, as one undo step.
    func resetEditControl(_ control: EditControl) {
        guard canEdit else { return }
        let reset = control.reset(editDraft)
        guard reset != editDraft else { return }
        editDraft = reset
        requestLiveEditRender()
        commitEdit(actionName: "Reset \(control.title)")
    }
}

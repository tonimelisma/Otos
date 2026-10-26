import CoreGraphics
import Foundation
import OSLog

/// Crop tool intents guide
///
/// The crop tool is a mode of the loupe (ADR 0036). While it is on, the loupe shows the
/// whole frame — the photo edited with everything but its crop (`editCropBase`, rendered
/// through the live lane) — with the crop drawn over it, and the edit panel's Crop
/// section acts on it. Photo ▸ Crop, C and the panel's Crop button call
/// `toggleCropTool()`; Return (the panel's Done), Escape, leaving the loupe, another
/// target or hiding the panel end it.
///
/// Dragging the crop changes only the draft and the drawn frame: nothing is rendered
/// while it moves, because the frame under it does not change. Letting go saves it as
/// one undo step, exactly as a slider's release does, and the save's render produces the
/// cropped preview the loupe shows once the tool ends. Quarter turns, flips and
/// straighten are ordinary edits that work with the tool on or off.
///
/// The aspect choice is the tool's state, not the photo's: it constrains how the crop
/// resizes and is fitted to the photo when chosen, but it is not saved with the edit.
extension CatalogWindowViewModel {
    /// Photo ▸ Crop (C), and the panel's Crop / Done button.
    func toggleCropTool() {
        if isCropping {
            endCropping()
            return
        }
        if !isEditPanelPresented {
            toggleEditPanel()
        }
        if viewMode != .loupe {
            setViewMode(.loupe)
        }
        guard viewMode == .loupe, targetIDs(.current).count == 1 else { return }
        isPickingNeutral = false
        isCropping = true
        cropAspect = .original
        // The photo may still be opening, so its frame is unknown here; the aspect follows
        // the crop's shape once it is known rather than guessing one now.
        cropAspectLandscapeChoice = nil
        requestLiveEditRender()
        OtosLog.ui.noticeOperation("edit.crop", phase: "started")
    }

    /// Ends the crop tool, keeping what was saved; a drag still in progress is saved first.
    func endCropping() {
        guard isCropping else { return }
        commitPendingCrop()
        isCropping = false
        editCropBase = nil
        // The pane shows the edited photo again: the cropped live render, until the saved
        // preview carries the crop.
        requestLiveEditRender()
        OtosLog.ui.noticeOperation("edit.crop", phase: "ended")
    }

    var canCrop: Bool {
        canEdit && viewMode == .loupe
    }

    /// The crop moved: `dragging` while the pointer is down, false when it is let go, which
    /// saves it.
    func setCrop(_ crop: EditCrop, dragging: Bool) {
        guard isCropping, canEdit else { return }
        let clamped = crop.clamped
        editDraft.crop = clamped.isWhole ? nil : clamped
        isDraggingCrop = dragging
        if !dragging {
            commitEdit(actionName: "Crop")
        }
    }

    /// The aspect menu: the crop becomes the largest of that ratio around its center.
    func setCropAspect(_ aspect: CropAspect) {
        guard isCropping, canEdit else { return }
        cropAspect = aspect
        refitCropToAspect(actionName: "Crop Aspect")
    }

    /// Rotate Aspect: the constrained ratio turns between landscape and portrait.
    func rotateCropAspect() {
        guard isCropping, canEdit, cropAspect != .free else { return }
        cropAspectLandscapeChoice = !cropAspectIsLandscape
        refitCropToAspect(actionName: "Crop Aspect")
    }

    /// Whether the constrained aspect stands landscape: Rotate Aspect's choice, else the
    /// shape of the crop as it is (the whole frame when uncropped).
    var cropAspectIsLandscape: Bool {
        cropAspectLandscapeChoice ?? currentCropIsLandscape
    }

    /// The pixel ratio (width over height) the crop keeps while resized, or nil when free.
    var cropPixelRatio: Double? {
        guard let frame = cropFrameSize, let longOverShort = cropAspect.longOverShort(frame: frame) else {
            return nil
        }
        return cropAspectIsLandscape ? longOverShort : 1 / longOverShort
    }

    /// `cropPixelRatio` as width over height in fractions of the frame, which is what the
    /// crop canvas resizes with.
    var cropFractionRatio: Double? {
        guard let ratio = cropPixelRatio, let frame = cropFrameSize else { return nil }
        return EditCrop.fractionRatio(pixelRatio: ratio, frame: frame)
    }

    /// The frame's size in pixels — the original turned by the draft — when known.
    var cropFrameSize: CGSize? {
        editOriginalPixelSize.map { editDraft.frameSize(ofOriginal: $0) }
    }

    /// Photo ▸ Rotate Left (⌘[) and Rotate Right (⌘]), and the panel's buttons.
    func turnPhoto(clockwise: Bool) {
        guard canEdit else { return }
        editDraft = editDraft.turned(clockwise: clockwise)
        if isCropping, let choice = cropAspectLandscapeChoice {
            // The frame turned; a chosen constraint turns with it so it still fits. One that
            // follows the crop follows the turned crop by itself.
            cropAspectLandscapeChoice = !choice
        }
        requestLiveEditRender()
        commitEdit(actionName: clockwise ? "Rotate Right" : "Rotate Left")
    }

    /// Photo ▸ Flip Horizontal and Flip Vertical, and the panel's buttons.
    func flipPhoto(horizontally: Bool) {
        guard canEdit else { return }
        editDraft = editDraft.flipped(horizontally: horizontally)
        requestLiveEditRender()
        commitEdit(actionName: horizontally ? "Flip Horizontal" : "Flip Vertical")
    }

    /// A crop render landed: shown while it is for the photo being cropped and newer than
    /// any render shown.
    func publishCropBase(id: MediaAssetID, recipe: EditRecipe, image: CGImage, sequence: UInt64) {
        guard isCropping, editTarget?.id == id, sequence > editRenderPublished else { return }
        editRenderPublished = sequence
        editCropBase = EditLivePreview(id: id, image: image, recipe: recipe, revision: nil)
    }

    private var currentCropIsLandscape: Bool {
        guard let frame = cropFrameSize else { return true }
        let crop = editDraft.crop ?? .whole
        return crop.width * frame.width >= crop.height * frame.height
    }

    private func refitCropToAspect(actionName: String) {
        guard let frame = cropFrameSize else { return }
        let current = editDraft.crop ?? .whole
        if let ratio = cropPixelRatio {
            let fitted = EditCrop.largest(pixelRatio: ratio, frame: frame, around: current.center)
            editDraft.crop = fitted.isWhole ? nil : fitted
        }
        commitEdit(actionName: actionName)
        OtosLog.ui.noticeOperation("edit.crop", phase: "aspect", fields: [
            "aspect": cropAspect.rawValue, "landscape": "\(cropAspectIsLandscape)",
        ])
    }

    private func commitPendingCrop() {
        guard isDraggingCrop else { return }
        isDraggingCrop = false
        commitEdit(actionName: "Crop")
    }
}

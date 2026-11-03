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
        setInspectorPane(.edit)
        if viewMode != .loupe {
            setViewMode(.loupe)
        }
        guard viewMode == .loupe, targetIDs(.current).count == 1 else { return }
        isPickingNeutral = false
        isCropping = true
        // Custom: a crop is free to take whatever shape suits the photo, and a suggested
        // crop with it. A fixed shape is the person's choice from the Aspect menu.
        cropAspect = .free
        // The photo may still be opening, so its frame is unknown here; a constrained
        // aspect follows the crop's shape once it is known rather than guessing one now.
        cropAspectLandscapeChoice = nil
        requestLiveEditRender()
        OtosLog.ui.noticeOperation("edit.crop", phase: "started")
    }

    /// Ends the crop tool, keeping what was saved; a drag still in progress is saved first.
    func endCropping() {
        guard isCropping else { return }
        commitPendingCrop()
        isCropping = false
        isDrawingStraightenLine = false
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

    /// Level ▸ Auto: straightens the photo by its level reading, as one `Auto Straighten`
    /// step — the camera's gravity reading when the file has one, else GeoCalib's (ADR 0045).
    /// The reading levels the upright, unflipped photo; a quarter turn keeps a level level and
    /// each flip mirrors it.
    func autoStraighten() {
        guard canEdit, let target = editTarget, let facts = editPhotoFacts,
              let reading = editAutoLevel, reading.id == target.id,
              case let .degrees(degrees, source) = reading.level
        else { return }
        commitPendingEdit()
        let shown = editDraft.flipHorizontal == editDraft.flipVertical ? degrees : -degrees
        let next = EditControl.straighten.applying(shown, to: editDraft, facts: facts)
        OtosLog.ui.noticeOperation("edit.autoLevel", phase: "applied", fields: [
            "id": target.id.relativePath.rawValue,
            "source": source.rawValue,
            "degrees": String(format: "%.1f", next.straighten),
            "changed": "\(next != editDraft)",
        ])
        guard next != editDraft else { return }
        editDraft = next
        requestLiveEditRender()
        commitEdit(actionName: "Auto Straighten")
    }

    /// Level ▸ Auto as the panel shows it.
    var autoStraightenState: EditAutoState {
        guard canEdit, let target = editTarget else { return .reading }
        guard let reading = editAutoLevel, reading.id == target.id else { return .reading }
        switch reading.level {
        case let .degrees(_, source): return .available(source)
        case .none: return .none
        }
    }

    /// Suggested ▸ Crop: the crop FocalNet suggests for the frame as saved, as one `Auto Crop`
    /// step (ADR 0045). A crop the person is dragging is saved first, so the suggestion
    /// replaces a saved crop, never an unsaved one.
    func autoCrop() {
        guard canEdit, let target = editTarget, let reading = editAutoCrop, reading.id == target.id,
              let crop = reading.crop, Self.sameFrame(reading.frame, editDraft)
        else { return }
        commitPendingCrop()
        guard editDraft.crop != crop else { return }
        editDraft.crop = crop
        OtosLog.ui.noticeOperation("edit.autoCrop", phase: "applied", fields: [
            "id": target.id.relativePath.rawValue,
            "crop": String(format: "%.3f,%.3f,%.3f,%.3f", crop.left, crop.top, crop.width, crop.height),
        ])
        requestLiveEditRender()
        commitEdit(actionName: "Auto Crop")
    }

    /// Suggested ▸ Crop as the panel shows it: available only for the frame the draft shows,
    /// once the saved frame has been read and FocalNet suggested a crop for it.
    var autoCropState: EditAutoState {
        guard canEdit, let target = editTarget,
              let reading = editAutoCrop, reading.id == target.id,
              Self.sameFrame(reading.frame, editDraft)
        else { return .reading }
        return reading.crop == nil ? .none : .available(nil)
    }

    /// The crop tool's straighten line (Lightroom Classic's Angle tool): armed by the
    /// panel's ruler button, or held with ⌘ during a drag on the canvas. A line is drawn on
    /// the crop canvas, so arming it with the tool off turns the tool on first.
    func toggleStraightenLine() {
        guard canEdit else { return }
        guard isCropping else {
            toggleCropTool()
            isDrawingStraightenLine = isCropping
            return
        }
        isDrawingStraightenLine.toggle()
    }

    /// A line was drawn on the crop canvas, in its y-down space: the photo turns so that
    /// line is level, or plumb when it was drawn nearer vertical, as one `Straighten` step.
    func straighten(along start: CGPoint, to end: CGPoint) {
        isDrawingStraightenLine = false
        guard isCropping, canEdit, let facts = editPhotoFacts,
              let turn = StraightenLine.levelingTurn(from: start, to: end)
        else { return }
        // The line was drawn on the frame the canvas shows, which can be a render behind the
        // draft while a straighten is still rendering: the turn is from that frame's angle.
        let shown = editCropBase.flatMap { $0.id == editTarget?.id ? $0.recipe.straighten : nil } ?? editDraft.straighten
        let next = EditControl.straighten.applying(shown + turn, to: editDraft, facts: facts)
        OtosLog.ui.noticeOperation("edit.straightenLine", phase: "drawn", fields: [
            "turn": String(format: "%.2f", turn),
            "straighten": String(format: "%.1f", next.straighten),
            "changed": "\(next != editDraft)",
        ])
        guard next != editDraft else { return }
        editDraft = next
        requestLiveEditRender()
        commitEdit(actionName: "Straighten")
    }

    /// Whether two recipes frame the photo alike: the crop is a rectangle of that frame.
    static func sameFrame(_ lhs: EditRecipe, _ rhs: EditRecipe) -> Bool {
        lhs.quarterTurns == rhs.quarterTurns && lhs.flipHorizontal == rhs.flipHorizontal
            && lhs.flipVertical == rhs.flipVertical && lhs.straighten == rhs.straighten
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

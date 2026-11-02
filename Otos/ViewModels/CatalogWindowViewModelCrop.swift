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

    /// Level ▸ Camera: straightens the photo by the camera's own gravity reading at
    /// capture, as one `Level to Camera` step. The reading levels the upright original; a
    /// quarter turn keeps a level level and each flip mirrors it.
    func levelToCamera() {
        guard canLevelToCamera, let target = editTarget, let facts = editPhotoFacts,
              let reading = facts.cameraLevel
        else { return }
        commitPendingEdit()
        let degrees = editDraft.flipHorizontal == editDraft.flipVertical ? reading : -reading
        let next = EditControl.straighten.applying(degrees, to: editDraft, facts: facts)
        OtosLog.ui.noticeOperation("edit.level", phase: "applied", fields: [
            "id": target.id.relativePath.rawValue,
            "source": "camera",
            "degrees": String(format: "%.1f", next.straighten),
            "changed": "\(next != editDraft)",
        ])
        guard next != editDraft else { return }
        editDraft = next
        requestLiveEditRender()
        commitEdit(actionName: "Level to Camera")
    }

    /// The opened photo carries a gravity reading Level ▸ Camera can use.
    var canLevelToCamera: Bool {
        canEdit && editPhotoFacts?.cameraLevel != nil
    }

    /// Level ▸ Horizon: straightens the photo so the horizon Vision finds in it is level, as
    /// one `Level to Horizon` step. Where Vision finds none, the photo is left as it is.
    /// Vision states no confidence and reads tilts into photos with no horizon, so this is
    /// the person's choice, never a default (ADR 0036).
    func levelToHorizon() {
        guard canEdit, let target = editTarget else { return }
        commitPendingEdit()
        submittedEditCommandCount += 1
        editCommandContinuation.yield(.levelToHorizon(id: target.id, shown: editDraft, sourceSize: target.sourceSize))
        OtosLog.ui.noticeOperation("edit.level", phase: "requested", fields: [
            "id": target.id.relativePath.rawValue, "source": "horizon",
        ])
    }

    /// A horizon reading landed. It is applied only to the photo it was read from, still
    /// turned and flipped as it was read, since the angle is measured in that frame.
    func applyHorizonLevel(id: MediaAssetID, shown: EditRecipe, _ reading: HorizonReading) {
        guard editTarget?.id == id, let facts = editPhotoFacts,
              editDraft.quarterTurns == shown.quarterTurns,
              editDraft.flipHorizontal == shown.flipHorizontal,
              editDraft.flipVertical == shown.flipVertical
        else {
            OtosLog.ui.noticeOperation("edit.level", phase: "stale", fields: [
                "id": id.relativePath.rawValue, "source": "horizon",
            ])
            return
        }
        guard case let .level(degrees) = reading else {
            OtosLog.ui.noticeOperation("edit.level", phase: "noHorizon", fields: ["id": id.relativePath.rawValue])
            return
        }
        let next = EditControl.straighten.applying(degrees, to: editDraft, facts: facts)
        OtosLog.ui.noticeOperation("edit.level", phase: "applied", fields: [
            "id": id.relativePath.rawValue,
            "source": "horizon",
            "degrees": String(format: "%.1f", next.straighten),
            "changed": "\(next != editDraft)",
        ])
        guard next != editDraft else { return }
        editDraft = next
        requestLiveEditRender()
        commitEdit(actionName: "Level to Horizon")
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

    /// The crop tool's Suggested menu: places `suggestion` by the subject Vision finds in the
    /// frame the tool shows, keeping the chosen aspect.
    func suggestCrop(_ suggestion: CropSuggestion) {
        guard canSuggestCrop, let target = editTarget, let base = editCropBase else {
            return
        }
        commitPendingCrop()
        submittedEditCommandCount += 1
        editCommandContinuation.yield(.suggestCrop(
            id: target.id, frame: base.image, shown: base.recipe, suggestion: suggestion, pixelRatio: cropPixelRatio
        ))
        OtosLog.ui.noticeOperation("edit.suggestCrop", phase: "requested", fields: [
            "id": target.id.relativePath.rawValue, "suggestion": suggestion.rawValue,
        ])
    }

    /// The tool shows the frame the draft crops: a suggestion is read from that picture, so
    /// it waits while a turn, flip or straighten is still rendering.
    var canSuggestCrop: Bool {
        guard isCropping, canEdit, let base = editCropBase, base.id == editTarget?.id else { return false }
        return Self.sameFrame(base.recipe, editDraft)
    }

    /// Whether two recipes frame the photo alike: the crop is a rectangle of that frame.
    static func sameFrame(_ lhs: EditRecipe, _ rhs: EditRecipe) -> Bool {
        lhs.quarterTurns == rhs.quarterTurns && lhs.flipHorizontal == rhs.flipHorizontal
            && lhs.flipVertical == rhs.flipVertical && lhs.straighten == rhs.straighten
    }

    /// A subject reading landed. It is applied only while the tool still shows the same
    /// frame — the same photo, turned, flipped and straightened as it was read — since the
    /// subject is placed in that frame.
    func applySuggestedCrop(
        id: MediaAssetID,
        shown: EditRecipe,
        suggestion: CropSuggestion,
        pixelRatio: Double?,
        subject reading: SubjectReading
    ) {
        guard isCropping, editTarget?.id == id, let frame = cropFrameSize, Self.sameFrame(shown, editDraft) else {
            OtosLog.ui.noticeOperation("edit.suggestCrop", phase: "stale", fields: ["id": id.relativePath.rawValue])
            return
        }
        guard case let .found(subject) = reading else {
            OtosLog.ui.noticeOperation("edit.suggestCrop", phase: "noSubject", fields: ["id": id.relativePath.rawValue])
            return
        }
        let crop = suggestion.crop(subject: subject, frame: frame, pixelRatio: pixelRatio)
        let next = crop.isWhole ? nil : crop
        OtosLog.ui.noticeOperation("edit.suggestCrop", phase: "applied", fields: [
            "id": id.relativePath.rawValue, "suggestion": suggestion.rawValue,
            "crop": String(format: "%.3f,%.3f,%.3f,%.3f", crop.left, crop.top, crop.width, crop.height),
        ])
        guard next != editDraft.crop else { return }
        editDraft.crop = next
        commitEdit(actionName: "Suggested Crop")
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

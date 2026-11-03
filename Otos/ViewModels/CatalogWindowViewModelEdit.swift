import CoreGraphics
import Foundation
import OSLog

/// Edit panel intents guide
///
/// The edit panel edits one still photo — the current target when it is exactly one
/// image or RAW (ADR 0036). Its values are `editDraft`; moving a control changes the draft
/// and asks for a live render, and letting go saves it.
///
/// When the target resolves the photo is opened — downloaded first if it is cloud-only,
/// as editing needs its bytes — and its facts (`EditPhotoFacts`: RAW or not, a RAW's
/// as-shot white balance) are published. The controls act only once they are known.
///
/// Three lanes, each one consumer:
/// - **Live render** (`editRenderStream`, newest-wins): opens the photo and renders the
///   draft on `LiveEditRenderer`, which keeps the photo open between renders. A render is
///   shown only while its photo is still the target and no newer render has been shown,
///   and a newer request never cancels one in flight (ADR 0032 rule 3). Every open or
///   render that succeeds publishes the photo's facts, so a request that replaced the
///   open still delivers them. Every render of the edit, and the saved edit's render an
///   open makes, also counts the histogram the panel shows (`editHistogram`, DES-100), under its own
///   sequence so an open's count never replaces a newer render's.
/// - **Commands** (`editCommandStream`, ordered, lossless): a save stores the recipe,
///   registers the inverse on `windowUndoManager`, then renders the saved recipe's
///   thumbnail and preview and hands them to the store, which promotes them only while
///   that revision is still current. A render that fails hands the photo to enrichment
///   instead, which renders with the saved recipe too, so the grid never keeps an edit's
///   old thumbnail. A neutral pick asks the open photo for the white balance that makes
///   the clicked point gray and saves it as one step.
/// - **Analysis** (`editAnalysisStream`, newest-wins): reads the photo for Auto straighten and
///   Auto crop (ADR 0045) when it opens and whenever the saved edit moves the frame. Auto
///   straighten is the camera's gravity reading when the file has one (known as the photo
///   opens), else GeoCalib's roll when it is confident; Auto crop is FocalNet's crop of the
///   frame as saved. A reading is published only for the photo and frame it was read from;
///   a failed read publishes nothing and the buttons stay unavailable.
///
/// Undo and redo enqueue the same command through the same lane, so they order after any
/// save still in flight, and file their own inverse synchronously at fire time
/// (APP-039's pattern).
///
/// The pane keeps showing the live render until its own preview carries the save
/// (`PanePreview.renderedRevision`), so the image never steps back to the unedited photo
/// between letting go of a slider and the stored preview arriving.
nonisolated struct EditTarget: Equatable, Sendable {
    let id: MediaAssetID
    let sourceSize: Int64?
}

/// A live render of `recipe` for `id`. `revision` is the save that recipe became, once it
/// has; nil while it is still only a draft.
nonisolated struct EditLivePreview: Equatable {
    let id: MediaAssetID
    let image: CGImage
    let recipe: EditRecipe
    var revision: Int64?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.image === rhs.image && lhs.recipe == rhs.recipe && lhs.revision == rhs.revision
    }
}

nonisolated enum EditRenderRequest: Sendable {
    /// The panel has a new target: open it, report its facts, and count the histogram of
    /// `recipe` — its saved edit — rendered.
    case open(id: MediaAssetID, sourceSize: Int64?, recipe: EditRecipe, sequence: UInt64)
    case render(
        id: MediaAssetID,
        recipe: EditRecipe,
        sourceSize: Int64?,
        sequence: UInt64,
        purpose: EditRenderPurpose,
        requestedAt: ContinuousClock.Instant
    )
    /// Editing moved to another photo or the panel closed: let go of the open photo.
    case close
}

/// What a live render is for: the edited photo the pane shows, the uncropped photo the crop
/// tool draws its frame over, or the photo without its edit for Show Original.
nonisolated enum EditRenderPurpose: Sendable {
    case edited
    case cropBase
    case original
}

/// A request for the loupe's player to begin trimming `id`, applied once per generation.
nonisolated struct VideoTrimCommand: Equatable, Sendable {
    let id: MediaAssetID
    let generation: UInt64
}

nonisolated enum EditCommandOrigin: String, Sendable {
    case user
    case undo
    case redo
}

nonisolated struct EditCommand: Sendable {
    let id: MediaAssetID
    let recipe: EditRecipe
    /// Undo menu title: the control that changed, `White Balance`, or `Reset Light`.
    let actionName: String
    let origin: EditCommandOrigin
}

nonisolated enum EditLaneCommand: Sendable {
    case save(EditCommand)
    /// The white balance picker was clicked at `point`, a fraction of the photo as shown
    /// (edited with `shown`) from its top-left corner.
    case pickNeutral(id: MediaAssetID, point: CGPoint, shown: EditRecipe, sourceSize: Int64?)
}

/// What Auto straighten can do for the photo the panel edits.
nonisolated struct AutoLevelReading: Equatable, Sendable {
    enum Level: Equatable, Sendable {
        /// The straighten, degrees clockwise, that levels the upright, unflipped photo.
        case degrees(Double, source: AutoLevelSource)
        /// No reading Otos trusts: the button is unavailable.
        case none
    }

    let id: MediaAssetID
    let level: Level
}

nonisolated extension AutoLevelReading.Level {
    /// The degrees as logs write them, or `none`.
    var logValue: String {
        if case let .degrees(degrees, _) = self {
            return String(format: "%.2f", degrees)
        }
        return "none"
    }
}

/// What a level was read from: the camera's own gravity reading, or GeoCalib's reading of the
/// pixels.
nonisolated enum AutoLevelSource: String, Equatable, Sendable {
    case gravity
    case scene
}

/// The suggested crop of the photo as `frame` turns, flips and straightens it; nil when
/// FocalNet would keep that frame whole.
nonisolated struct AutoCropReading: Equatable, Sendable {
    let id: MediaAssetID
    let frame: EditRecipe
    let crop: EditCrop?
}

/// A request to read the photo: the crop of `frame`, and its level when that is not known.
nonisolated struct EditAnalysisRequest: Equatable, Sendable {
    let id: MediaAssetID
    let frame: EditRecipe
    let sourceSize: Int64?
    let needsLevel: Bool
}

/// What one analysis read. A nil part failed or was not asked for, and publishes nothing.
nonisolated struct EditAnalysis: Sendable {
    let crop: EditCrop??
    let level: AutoLevelReading.Level?
}

extension CatalogWindowViewModel {
    // MARK: - Panel

    /// The Edit pane left the inspector: its tools end, a pending change is saved, and the
    /// photo is let go.
    func endEditing() {
        endCropping()
        commitPendingEdit()
        editTargetTask?.cancel()
        editTargetTask = nil
        clearEditTarget()
    }

    /// Photo ▸ Trim Video… (⌘T): asks the loupe's player to show `AVPlayerView`'s trim UI.
    func trimVideo() {
        guard canTrimVideo, let id = loupeVideoState?.id else { return }
        videoTrimGeneration &+= 1
        videoTrimCommand = VideoTrimCommand(id: id, generation: videoTrimGeneration)
        OtosLog.ui.noticeOperation("edit.trim", phase: "requested", fields: ["id": id.relativePath.rawValue])
    }

    /// A video the loupe shows — not a Live Photo's motion, which plays under its still.
    var canTrimVideo: Bool {
        viewMode == .loupe && focusedAssetKind == .video && loupeVideoState != nil
            && loupeVideoState?.id == focusedAssetID
    }

    /// The trim UI closed with Trim: the range it left on the player is saved as one step.
    /// Cancel restores nothing to save, so it never reaches here.
    func finishTrim(id: MediaAssetID) {
        guard let state = loupeVideoState, state.id == id else { return }
        let trim = state.currentTrim
        var recipe = state.recipe
        recipe.trimStart = trim.start
        recipe.trimEnd = trim.end
        guard recipe != state.recipe else { return }
        enqueueEdit(EditCommand(id: id, recipe: recipe, actionName: "Trim", origin: .user))
        OtosLog.ui.noticeOperation("edit.trim", phase: "submitted", fields: [
            "id": id.relativePath.rawValue,
            "start": trim.start.map { String(format: "%.2f", $0) } ?? "none",
            "end": trim.end.map { String(format: "%.2f", $0) } ?? "none",
        ])
    }

    /// The Optics section's Lens Correction checkbox.
    func setLensCorrection(_ enabled: Bool) {
        guard canEdit, editDraft.lensCorrection != enabled else { return }
        editDraft.lensCorrection = enabled
        requestLiveEditRender()
        commitEdit(actionName: "Lens Correction")
    }

    /// A value field in the panel gained or lost the keyboard.
    func setEnteringEditValue(_ entering: Bool) {
        if isEnteringEditValue != entering {
            isEnteringEditValue = entering
        }
    }

    /// Text owns the keyboard: an edit value is being typed, or a sheet with fields is up.
    /// Edit ▸ Cut, Copy, Paste and Select All then act on text through the responder
    /// chain, never on photos behind the sheet.
    var textHoldsKeyboard: Bool {
        isEnteringEditValue || exportSheet != nil
    }

    /// The Color section's white balance picker: armed, the next click on the loupe image
    /// sets white balance from that point. Loupe only; Escape or any other move disarms it.
    func toggleNeutralPicker() {
        guard canPickNeutral || isPickingNeutral else { return }
        isPickingNeutral.toggle()
        OtosLog.ui.noticeOperation("edit.neutralPicker", phase: isPickingNeutral ? "armed" : "disarmed")
    }

    var canPickNeutral: Bool {
        editPhotoFacts != nil && viewMode == .loupe && !isCropping
    }

    /// The loupe was clicked while the picker was armed.
    func pickNeutral(at point: CGPoint) {
        guard isPickingNeutral, let target = editTarget, editPhotoFacts != nil else { return }
        isPickingNeutral = false
        commitPendingEdit()
        submittedEditCommandCount += 1
        editCommandContinuation.yield(.pickNeutral(
            id: target.id,
            point: point,
            shown: shownRecipe,
            sourceSize: target.sourceSize
        ))
        OtosLog.ui.noticeOperation("edit.neutralPicker", phase: "picked", fields: [
            "id": target.id.relativePath.rawValue,
            "x": String(format: "%.3f", point.x), "y": String(format: "%.3f", point.y),
        ])
    }

    /// Resolves the photo the panel edits whenever the current target changes (the same
    /// writers that refresh Open With). Reads the target's saved recipe once.
    func refreshEditTarget() {
        guard isEditPanelPresented else { return }
        if viewMode != .loupe {
            isPickingNeutral = false
            endCropping()
            endShowingOriginal()
        }
        let ids = targetIDs(.current)
        guard ids.count == 1, let id = ids.first else {
            commitPendingEdit()
            editTargetTask?.cancel()
            editTargetTask = nil
            clearEditTarget()
            return
        }
        // Already the target, or already being read: every target writer calls this, and
        // one gesture fires several, so a read in flight for the same photo is kept.
        guard editTarget?.id != id, !(editTargetTask != nil && editTargetRequestedID == id) else { return }
        // Only moving off a resolved photo ends its tools; the crop tool started for a
        // target still resolving stays on for it.
        if editTarget != nil {
            endCropping()
        }
        commitPendingEdit()
        editTargetTask?.cancel()
        let reader = tileDetailReader
        editTargetRequestedID = id
        editTargetTask = Task { [weak self] in
            let detail: MediaTileDetail?
            do {
                detail = try await reader.detail(for: id)
            } catch {
                guard !Task.isCancelled, let self, targetIDs(.current) == [id] else { return }
                // Without the saved recipe the panel cannot edit this photo, and the photo
                // it showed is no longer the target, so the panel closes its target rather
                // than edit either. `editTarget` is not `id`, so the next refresh reads again.
                editTargetTask = nil
                clearEditTarget()
                return
            }
            guard !Task.isCancelled, let self, targetIDs(.current) == [id] else { return }
            editTargetTask = nil
            guard let detail, detail.bestKind == .image || detail.bestKind == .raw else {
                clearEditTarget()
                return
            }
            let saved = detail.editRecipe ?? .neutral
            editTarget = EditTarget(id: id, sourceSize: detail.byteSize)
            editPhotoFacts = nil
            editAutoLevel = nil
            editAutoCrop = nil
            editAnalysisRequested = nil
            editOriginalPixelSize = nil
            isPickingNeutral = false
            endShowingOriginal()
            editSavedRecipe = saved
            editDraft = saved
            editLivePreview = nil
            editHistogram = nil
            editRenderRequested &+= 1
            editRenderContinuation.yield(.open(
                id: id, sourceSize: detail.byteSize, recipe: saved, sequence: editRenderRequested
            ))
            if isCropping {
                requestLiveEditRender()
            }
            OtosLog.ui.debugOperation("edit.target", phase: "resolved", fields: [
                "id": id.relativePath.rawValue, "edited": "\(!saved.isNeutral)",
            ])
        }
    }

    private func clearEditTarget() {
        guard editTarget != nil || editLivePreview != nil else { return }
        endCropping()
        editTarget = nil
        editPhotoFacts = nil
        editAutoLevel = nil
        editAutoCrop = nil
        editAnalysisRequested = nil
        editOriginalPixelSize = nil
        isPickingNeutral = false
        endShowingOriginal()
        selectedEditControl = nil
        editSavedRecipe = .neutral
        editDraft = .neutral
        editDraggingControl = nil
        editLivePreview = nil
        editHistogram = nil
        editRenderContinuation.yield(.close)
    }

    // MARK: - Controls

    /// A control moved. While it is being dragged only the live render follows; a change
    /// that is not a drag (a keyboard step, an accessibility increment) is saved at once.
    func setEditValue(_ value: Double, for control: EditControl) {
        guard editTarget != nil, let facts = editPhotoFacts else { return }
        let next = control.applying(value, to: editDraft, facts: facts)
        guard next != editDraft else { return }
        editDraft = next
        requestLiveEditRender()
        if editDraggingControl != control {
            commitEdit(actionName: control.title)
        }
    }

    /// Slider drag start and end; the end saves the dragged value.
    func setEditDragging(_ dragging: Bool, control: EditControl) {
        if dragging {
            editDraggingControl = control
            // The control last touched is the one = and - move.
            selectedEditControl = control
        } else if editDraggingControl == control {
            editDraggingControl = nil
            commitEdit(actionName: control.title)
        }
    }

    /// A section's Reset: every control in it back to neutral, as one undo step.
    func resetEditSection(_ section: EditSection) {
        guard editTarget != nil, editPhotoFacts != nil, !section.isNeutral(in: editDraft) else { return }
        editDraft = section.reset(editDraft)
        requestLiveEditRender()
        commitEdit(actionName: section.resetActionName)
    }

    /// The controls act: there is one photo to edit and it is open.
    var canEdit: Bool {
        editTarget != nil && editPhotoFacts != nil
    }

    /// True once every submitted edit command has been saved and rendered, or refused.
    var hasSettledEdits: Bool {
        handledEditCommandCount == submittedEditCommandCount
    }

    /// The pane image for `slot`: the live render while the pane's own preview does not
    /// yet carry the edit being made, otherwise the pane preview.
    func displayedPanePreview(_ slot: PaneSlot) -> PanePreview? {
        let pane = panePreviews[slot]
        if slot == .loupe, isShowingOriginal, let original = editOriginalPreview, expectedAsset(for: slot) == original.id {
            return PanePreview(
                id: original.id,
                image: original.image,
                mediaChoice: pane?.id == original.id ? pane?.mediaChoice : nil,
                nativePixelSize: editOriginalPixelSize,
                renderedRevision: 0
            )
        }
        guard let live = editLivePreview, expectedAsset(for: slot) == live.id else {
            return pane
        }
        let matching = pane?.id == live.id ? pane : nil
        if let revision = live.revision, let matching, matching.renderedRevision >= revision {
            return matching
        }
        return PanePreview(
            id: live.id,
            image: live.image,
            mediaChoice: matching?.mediaChoice,
            nativePixelSize: editOriginalPixelSize.map { live.recipe.outputSize(ofOriginal: $0) }
                ?? matching?.nativePixelSize,
            renderedRevision: live.revision ?? matching?.renderedRevision ?? 0
        )
    }

    func commitPendingEdit() {
        guard editTarget != nil, editDraft != editSavedRecipe else { return }
        commitEdit(actionName: editDraggingControl?.title ?? "Edit")
        editDraggingControl = nil
    }

    func commitEdit(actionName: String) {
        guard let target = editTarget, editDraft != editSavedRecipe else { return }
        editSavedRecipe = editDraft
        enqueueEdit(EditCommand(id: target.id, recipe: editDraft, actionName: actionName, origin: .user))
        OtosLog.ui.noticeOperation("edit.submit", phase: "submitted", fields: [
            "id": target.id.relativePath.rawValue, "action": actionName,
        ])
    }

    func enqueueEdit(_ command: EditCommand) {
        submittedEditCommandCount += 1
        editCommandContinuation.yield(.save(command))
    }

    /// The recipe the pane shows the photo with: the draft, uncropped while the crop tool
    /// shows the whole frame.
    var shownRecipe: EditRecipe {
        isCropping ? editDraft.uncropped : editDraft
    }

    /// Renders the draft for the pane. Any change to the edit shows the edited photo, so it
    /// also ends Show Original.
    func requestLiveEditRender() {
        guard let target = editTarget else { return }
        endShowingOriginal()
        editRenderRequested &+= 1
        editRenderContinuation.yield(.render(
            id: target.id,
            recipe: shownRecipe,
            sourceSize: target.sourceSize,
            sequence: editRenderRequested,
            purpose: isCropping ? .cropBase : .edited,
            requestedAt: .now
        ))
    }

    /// Renders the open photo without its edit, for Show Original.
    func requestOriginalRender() {
        guard let target = editTarget else { return }
        editRenderRequested &+= 1
        editRenderContinuation.yield(.render(
            id: target.id,
            recipe: .neutral,
            sourceSize: target.sourceSize,
            sequence: editRenderRequested,
            purpose: .original,
            requestedAt: .now
        ))
    }

    // MARK: - Lanes

    func startEditing(store: CatalogStore) {
        let pipeline = EditPipeline(
            store: store,
            renderer: liveEditRenderer,
            materialization: materializationCoordinator,
            directory: store.thumbnailDirectory,
            analyzer: EditAnalyzer()
        )
        startLiveEditRendering(pipeline)
        startEditSaving(pipeline)
        startEditAnalysis(pipeline)
    }

    private func startEditAnalysis(_ pipeline: EditPipeline) {
        editAnalysisTask = Task { [weak self, editAnalysisStream, pipeline] in
            for await request in editAnalysisStream {
                guard !Task.isCancelled else { break }
                let analysis = await pipeline.analyze(request)
                self?.publishEditAnalysis(request, analysis)
            }
        }
    }

    /// Asks for a reading of the photo as saved, unless the same one was already asked for.
    /// The crop is read for the saved frame; the level once per photo.
    func requestEditAnalysis() {
        guard let target = editTarget, editPhotoFacts != nil else { return }
        let request = EditAnalysisRequest(
            id: target.id,
            frame: editSavedRecipe.uncropped,
            sourceSize: target.sourceSize,
            needsLevel: editAutoLevel?.id != target.id
        )
        guard request != editAnalysisRequested else { return }
        editAnalysisRequested = request
        editAnalysisContinuation.yield(request)
        OtosLog.ui.debugOperation("edit.analysis", phase: "requested", fields: [
            "id": target.id.relativePath.rawValue, "needsLevel": "\(request.needsLevel)",
        ])
    }

    /// A reading landed. Each part is kept only for the photo it was read from; the crop only
    /// while the saved frame is still the one it was read for.
    private func publishEditAnalysis(_ request: EditAnalysisRequest, _ analysis: EditAnalysis) {
        guard editTarget?.id == request.id else { return }
        if let level = analysis.level, editAutoLevel?.id != request.id {
            editAutoLevel = AutoLevelReading(id: request.id, level: level)
        }
        if let crop = analysis.crop, Self.sameFrame(request.frame, editSavedRecipe) {
            editAutoCrop = AutoCropReading(id: request.id, frame: request.frame, crop: crop)
        }
        if analysis.level == nil && request.needsLevel || analysis.crop == nil {
            // A failed part asks again on the next change, not in a loop.
            editAnalysisRequested = nil
        }
    }

    private func startLiveEditRendering(_ pipeline: EditPipeline) {
        editRenderTask = Task { [weak self, editRenderStream, pipeline] in
            for await request in editRenderStream {
                guard !Task.isCancelled else { break }
                switch request {
                case .close:
                    await pipeline.renderer.close()
                case let .open(id, sourceSize, recipe, sequence):
                    guard let opened = await pipeline.open(id, sourceSize: sourceSize) else { continue }
                    self?.publishOpenedPhoto(id: id, opened)
                    guard let live = await pipeline.liveImage(id, recipe: recipe, sourceSize: sourceSize) else {
                        continue
                    }
                    let histogram = await EditHistogram.count(live.image)
                    self?.publishHistogram(id: id, histogram, sequence: sequence)
                case let .render(id, recipe, sourceSize, sequence, purpose, requestedAt):
                    let startedAt = ContinuousClock.now
                    guard let live = await pipeline.liveImage(id, recipe: recipe, sourceSize: sourceSize) else {
                        continue
                    }
                    // How long the pane waited for this render: queued behind the lane,
                    // then rendering (including making the original local).
                    OtosLog.rendering.debugOperation("edit.liveRender", phase: "rendered", fields: [
                        "sequence": "\(sequence)",
                        "purpose": "\(purpose)",
                        "waitMs": "\(DiagnosticsTiming.milliseconds(startedAt - requestedAt))",
                        "renderMs": "\(DiagnosticsTiming.milliseconds(since: startedAt))",
                    ])
                    self?.publishOpenedPhoto(id: id, live.opened)
                    // The histogram describes the edit; Show Original's render is a glance
                    // at what the edit replaced.
                    if purpose != .original {
                        let histogram = await EditHistogram.count(live.image)
                        self?.publishHistogram(id: id, histogram, sequence: sequence)
                    }
                    switch purpose {
                    case .edited:
                        self?.publishLiveEdit(id: id, recipe: recipe, image: live.image, sequence: sequence)
                    case .cropBase:
                        self?.publishCropBase(id: id, recipe: recipe, image: live.image, sequence: sequence)
                    case .original:
                        self?.publishOriginal(id: id, image: live.image, sequence: sequence)
                    }
                }
            }
        }
    }

    private func startEditSaving(_ pipeline: EditPipeline) {
        editCommandTask = Task { [weak self, editCommandStream, pipeline] in
            for await laneCommand in editCommandStream {
                defer { self?.handledEditCommandCount += 1 }
                guard !Task.isCancelled else { break }
                let command: EditCommand
                switch laneCommand {
                case let .pickNeutral(id, point, shown, sourceSize):
                    if let whiteBalance = await pipeline.neutralWhiteBalance(
                        id, at: point, shown: shown, sourceSize: sourceSize
                    ) {
                        self?.applyPickedWhiteBalance(id: id, whiteBalance)
                    }
                    continue
                case let .save(save):
                    command = save
                }
                guard let result = await pipeline.save(command), let saved = result.saved else {
                    continue
                }
                self?.applySavedEdit(command, saved: saved, previous: result.previous?.recipe ?? .neutral)
                // A video's trim changes nothing the catalog renders (the store marked its
                // products current).
                guard !result.isVideo else { continue }
                guard let products = await pipeline.products(command.id, saved: saved, result: result) else {
                    continue
                }
                self?.showRenderedEdit(id: command.id, saved: saved, image: products.image)
                if await pipeline.store.applyRenderedEditProducts(products.staged) {
                    self?.refreshEditedPanes(command.id)
                }
            }
        }
    }

    private func publishOpenedPhoto(id: MediaAssetID, _ opened: OpenedEditPhoto) {
        guard editTarget?.id == id,
              editPhotoFacts != opened.facts || editOriginalPixelSize != opened.pixelSize
        else { return }
        editPhotoFacts = opened.facts
        editOriginalPixelSize = opened.pixelSize
        if let degrees = opened.facts.cameraLevel, editAutoLevel?.id != id {
            editAutoLevel = AutoLevelReading(id: id, level: .degrees(degrees, source: .gravity))
        }
        requestEditAnalysis()
        OtosLog.ui.debugOperation("edit.target", phase: "opened", fields: [
            "id": id.relativePath.rawValue, "raw": "\(opened.facts.isRAW)",
            "width": "\(Int(opened.pixelSize.width))", "height": "\(Int(opened.pixelSize.height))",
            "asShotTemperature": opened.facts.asShotTemperature.map { "\(Int($0.rounded()))" } ?? "none",
        ])
    }

    /// The picked white balance becomes the draft's and is saved as one step, unless the
    /// panel has moved on to another photo meanwhile.
    private func applyPickedWhiteBalance(id: MediaAssetID, _ whiteBalance: (temperature: Double, tint: Double)) {
        guard editTarget?.id == id, let facts = editPhotoFacts else { return }
        var next = editDraft
        if facts.isRAW {
            next.temperature = (whiteBalance.temperature / 50).rounded() * 50
            next.tint = whiteBalance.tint.rounded()
        } else {
            next.temperature = whiteBalance.temperature == 0 ? nil : whiteBalance.temperature
            next.tint = whiteBalance.tint == 0 ? nil : whiteBalance.tint
        }
        guard next != editDraft else { return }
        editDraft = next
        requestLiveEditRender()
        commitEdit(actionName: "White Balance")
    }

    /// The histogram of the newest render of the edit for the photo the panel edits. A count that
    /// failed publishes nothing and the previous one stays.
    private func publishHistogram(id: MediaAssetID, _ histogram: EditHistogram?, sequence: UInt64) {
        guard let histogram, editTarget?.id == id, sequence > editHistogramPublished else { return }
        editHistogramPublished = sequence
        editHistogram = histogram
    }

    private func publishOriginal(id: MediaAssetID, image: CGImage, sequence: UInt64) {
        guard isShowingOriginal, editTarget?.id == id, sequence > editRenderPublished else { return }
        editRenderPublished = sequence
        editOriginalPreview = EditLivePreview(id: id, image: image, recipe: .neutral, revision: nil)
    }

    private func publishLiveEdit(id: MediaAssetID, recipe: EditRecipe, image: CGImage, sequence: UInt64) {
        guard editTarget?.id == id, sequence > editRenderPublished else { return }
        editRenderPublished = sequence
        editLivePreview = EditLivePreview(id: id, image: image, recipe: recipe, revision: nil)
    }

    /// A save landed: register its inverse for a user's own change, and bring the panel
    /// to the saved values when an undo or redo restored a recipe for the photo it edits.
    private func applySavedEdit(_ command: EditCommand, saved: StoredEditRecipe, previous: EditRecipe) {
        switch command.origin {
        case .user:
            registerEditUndo(id: command.id, restoring: previous, inverse: saved.recipe, actionName: command.actionName)
        case .undo, .redo:
            if editTarget?.id == command.id {
                editSavedRecipe = saved.recipe
                editDraft = saved.recipe
            }
        }
        if loupeVideoState?.id == command.id {
            loupeVideoState?.applyTrim(saved.recipe)
        }
        if var live = editLivePreview, live.id == command.id, live.recipe == saved.recipe {
            live.revision = saved.revision
            editLivePreview = live
        }
    }

    /// The saved recipe's render becomes the live image while the panel still shows that
    /// recipe — the render an undo produces, or a save of the draft on screen.
    private func showRenderedEdit(id: MediaAssetID, saved: StoredEditRecipe, image: CGImage) {
        guard editTarget?.id == id, editDraft == saved.recipe else { return }
        editRenderPublished = editRenderRequested
        editLivePreview = EditLivePreview(id: id, image: image, recipe: saved.recipe, revision: saved.revision)
    }

    /// The store now holds the edited preview: reload it into every pane showing the
    /// photo, without clearing what they show meanwhile, and redo a zoomed loupe's
    /// full-resolution decode with the edit.
    private func refreshEditedPanes(_ id: MediaAssetID) {
        for slot in PaneSlot.allCases where expectedAsset(for: slot) == id {
            if slot == .loupe {
                fullResolutionRequestedIDs.remove(id)
            }
            requestPanePreview(id, slot: slot)
        }
    }

    // MARK: - Undo

    private func registerEditUndo(id: MediaAssetID, restoring: EditRecipe, inverse: EditRecipe, actionName: String) {
        windowUndoManager.beginUndoGrouping()
        windowUndoManager.registerUndo(withTarget: self) { model in
            model.restoreEdit(id: id, recipe: restoring, inverse: inverse, actionName: actionName)
        }
        windowUndoManager.setActionName(actionName)
        windowUndoManager.endUndoGrouping()
        publishUndoState()
    }

    /// Runs inside `UndoManager.undo()` / `redo()`: files the opposite entry first, so it
    /// lands on the other stack, then enqueues the restore through the save lane.
    private func restoreEdit(id: MediaAssetID, recipe: EditRecipe, inverse: EditRecipe, actionName: String) {
        let origin: EditCommandOrigin = windowUndoManager.isUndoing ? .undo : .redo
        windowUndoManager.registerUndo(withTarget: self) { model in
            model.restoreEdit(id: id, recipe: inverse, inverse: recipe, actionName: actionName)
        }
        windowUndoManager.setActionName(actionName)
        revealUndoneChange([id])
        if editTarget?.id == id {
            editSavedRecipe = recipe
            editDraft = recipe
            requestLiveEditRender()
        }
        enqueueEdit(EditCommand(id: id, recipe: recipe, actionName: actionName, origin: origin))
        OtosLog.ui.noticeOperation("edit.restore", phase: "submitted", fields: [
            "id": id.relativePath.rawValue, "origin": origin.rawValue,
        ])
    }
}

/// The off-MainActor steps of the edit lanes: saving a recipe, making the original local,
/// rendering live, and rendering a save's products. Every step leaves the caller's actor
/// (`@concurrent`), and none touches view-model state; the lanes apply what they return.
nonisolated struct EditPipeline: Sendable {
    let store: CatalogStore
    let renderer: LiveEditRenderer
    let materialization: MaterializationCoordinator?
    let directory: URL?
    let analyzer: EditAnalyzer

    /// Saves the command's recipe. A failed save is logged and returns nil; the panel's
    /// values stay as the user left them.
    @concurrent
    func save(_ command: EditCommand) async -> EditRecipeMutationResult? {
        let result: EditRecipeMutationResult
        do {
            result = try await store.setEditRecipe(command.recipe, for: command.id)
        } catch {
            OtosLog.persistence.errorOperation("edit.persist", phase: "failed", fields: [
                "id": command.id.relativePath.rawValue, "error": String(describing: error),
            ])
            return nil
        }
        if result.saved == nil {
            OtosLog.ui.noticeOperation("edit.persist", phase: result.exists ? "unchanged" : "noRow", fields: [
                "id": command.id.relativePath.rawValue,
            ])
        }
        return result
    }

    /// Opens the photo — downloading it first when it is cloud-only — and reports its
    /// facts and upright size, or nil when it cannot be read.
    @concurrent
    func open(_ id: MediaAssetID, sourceSize: Int64?) async -> OpenedEditPhoto? {
        guard await MaterializationCoordinator.makeLocal(id, sourceSize: sourceSize, via: materialization) else {
            return nil
        }
        do {
            return try await renderer.open(id.fileURL)
        } catch {
            OtosLog.rendering.errorOperation("render.liveEdit", phase: "openFailed", fields: [
                "id": id.relativePath.rawValue, "error": String(describing: error),
            ])
            return nil
        }
    }

    /// The draft rendered at preview size with what opening the photo reported, or nil
    /// when the original cannot be read.
    @concurrent
    func liveImage(
        _ id: MediaAssetID,
        recipe: EditRecipe,
        sourceSize: Int64?
    ) async -> (image: CGImage, opened: OpenedEditPhoto)? {
        guard await MaterializationCoordinator.makeLocal(id, sourceSize: sourceSize, via: materialization) else {
            return nil
        }
        do {
            let image = try await renderer.render(id.fileURL, recipe: recipe)
            return try await (image, renderer.open(id.fileURL))
        } catch {
            OtosLog.rendering.errorOperation("render.liveEdit", phase: "failed", fields: [
                "id": id.relativePath.rawValue, "error": String(describing: error),
            ])
            return nil
        }
    }

    /// Renders the saved recipe's products, unless a newer save has already replaced it.
    /// A render that cannot happen hands the photo to enrichment.
    @concurrent
    func products(
        _ id: MediaAssetID,
        saved: StoredEditRecipe,
        result: EditRecipeMutationResult
    ) async -> (image: CGImage, staged: RenderedEditProducts)? {
        guard let directory else {
            return nil
        }
        do {
            guard try await store.editRecipe(for: id)?.revision == saved.revision else {
                OtosLog.rendering.debugOperation("render.editProducts", phase: "superseded", fields: [
                    "id": id.relativePath.rawValue, "revision": "\(saved.revision)",
                ])
                return nil
            }
            guard await MaterializationCoordinator.makeLocal(id, sourceSize: result.sourceSize, via: materialization) else {
                await handToEnrichment(id)
                return nil
            }
            let image = try await renderer.render(id.fileURL, recipe: saved.recipe)
            let rendered = try RenderedEditImages.staging(image, id: id, directory: directory)
            return (rendered.image, RenderedEditProducts(
                id: id,
                revision: saved.revision,
                sourceSize: result.sourceSize,
                sourceMTimeSeconds: result.sourceMTimeSeconds,
                thumbnail: rendered.thumbnail,
                preview: rendered.preview
            ))
        } catch {
            OtosLog.rendering.errorOperation("render.editProducts", phase: "failed", fields: [
                "id": id.relativePath.rawValue, "error": String(describing: error),
            ])
            await handToEnrichment(id)
            return nil
        }
    }

    /// The white balance that makes the photo gray at `point`, or nil when it cannot be
    /// read.
    @concurrent
    func neutralWhiteBalance(
        _ id: MediaAssetID,
        at point: CGPoint,
        shown: EditRecipe,
        sourceSize: Int64?
    ) async -> (temperature: Double, tint: Double)? {
        guard await MaterializationCoordinator.makeLocal(id, sourceSize: sourceSize, via: materialization) else {
            return nil
        }
        do {
            return try await renderer.neutralWhiteBalance(id.fileURL, at: point, shown: shown)
        } catch {
            OtosLog.rendering.errorOperation("render.neutralPick", phase: "failed", fields: [
                "id": id.relativePath.rawValue, "error": String(describing: error),
            ])
            return nil
        }
    }

    /// Reads the photo for Auto crop and, when asked, Auto straighten: FocalNet on the frame as
    /// saved, GeoCalib on the upright, unedited photo, trusted only when confident.
    @concurrent
    func analyze(_ request: EditAnalysisRequest) async -> EditAnalysis {
        guard await MaterializationCoordinator.makeLocal(request.id, sourceSize: request.sourceSize, via: materialization)
        else { return EditAnalysis(crop: nil, level: nil) }
        let url = request.id.fileURL
        let path = request.id.relativePath.rawValue
        var crop: EditCrop??
        let cropStart = ContinuousClock.now
        do {
            let frame = try await renderer.analysisImage(url, recipe: request.frame)
            let suggested = try await analyzer.crop(of: frame)
            crop = .some(suggested)
            OtosLog.rendering.noticeOperation("edit.autoCrop", phase: "read", fields: [
                "id": path,
                "crop": suggested.map { String(format: "%.3f,%.3f,%.3f,%.3f", $0.left, $0.top, $0.width, $0.height) } ?? "none",
                "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: cropStart))",
            ])
        } catch {
            OtosLog.rendering.errorOperation("edit.autoCrop", phase: "failed", fields: [
                "id": path, "error": String(describing: error),
            ])
        }
        guard request.needsLevel else { return EditAnalysis(crop: crop, level: nil) }
        var level: AutoLevelReading.Level?
        let levelStart = ContinuousClock.now
        do {
            let photo = try await renderer.analysisImage(url, recipe: .neutral)
            if let reading = try await analyzer.roll(of: photo),
               reading.uncertainty <= AutoLevelModel.maximumUncertainty
            {
                level = .degrees(reading.roll * 180 / .pi, source: .scene)
            } else {
                level = AutoLevelReading.Level.none
            }
            OtosLog.rendering.noticeOperation("edit.autoLevel", phase: "read", fields: [
                "id": path,
                "level": level?.logValue ?? "none",
                "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: levelStart))",
            ])
        } catch {
            OtosLog.rendering.errorOperation("edit.autoLevel", phase: "failed", fields: [
                "id": path, "error": String(describing: error),
            ])
        }
        return EditAnalysis(crop: crop, level: level)
    }

    private func handToEnrichment(_ id: MediaAssetID) async {
        do {
            try await store.handUnrenderedEditToEnrichment(id)
        } catch {
            OtosLog.persistence.errorOperation("edit.handToEnrichment", phase: "failed", fields: [
                "id": id.relativePath.rawValue, "error": String(describing: error),
            ])
        }
    }
}

/// The two models Auto crop and Auto straighten read with (ADR 0045), loaded on first use and
/// owned here, one per window. Loading reads 79 MB of weights and every prediction blocks, so the
/// actor runs on its own serial queue rather than the shared pool (ADR 0032 rule 6), and the
/// models never leave it.
actor EditAnalyzer {
    private let queue = DispatchSerialQueue(label: "net.melisma.Otos.edit.analysis", qos: .userInitiated)
    private var crop: AutoCropModel?
    private var level: AutoLevelModel?

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// FocalNet's suggested crop of `image`, or nil when it would keep it whole.
    func crop(of image: CGImage) throws -> EditCrop? {
        try cropModel().crop(of: image)
    }

    /// GeoCalib's roll of `image` and its uncertainty, radians.
    func roll(of image: CGImage) throws -> (roll: Double, uncertainty: Double)? {
        try levelModel().roll(of: image)
    }

    private func cropModel() throws -> AutoCropModel {
        if let crop {
            return crop
        }
        let start = ContinuousClock.now
        let model = try AutoCropModel(bundle: Bundle(for: CatalogWindowViewModel.self))
        crop = model
        OtosLog.rendering.noticeOperation("edit.analysisModel", phase: "loaded", fields: [
            "model": "FocalNet", "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        return model
    }

    private func levelModel() throws -> AutoLevelModel {
        if let level {
            return level
        }
        // Its shape functions load as photos need them, and log their own load times.
        let model = try AutoLevelModel(bundle: Bundle(for: CatalogWindowViewModel.self))
        level = model
        return model
    }
}

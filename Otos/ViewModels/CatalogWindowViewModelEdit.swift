import CoreGraphics
import Foundation
import OSLog

/// Edit panel intents guide
///
/// The edit panel edits one still photo — the current target when it is exactly one
/// image or RAW (ADR 0036). Its values are `editDraft`; moving a control changes the draft
/// and asks for a live render, and letting go saves it.
///
/// Two lanes, each one consumer:
/// - **Live render** (`editRenderStream`, newest-wins): renders the draft on
///   `LiveEditRenderer`, which keeps the photo open between renders. A render is shown
///   only while its photo is still the target and no newer render has been shown, and a
///   newer request never cancels one in flight (ADR 0032 rule 3).
/// - **Save** (`editCommandStream`, ordered, lossless): saves the recipe, registers the
///   inverse on `windowUndoManager`, then renders the saved recipe's thumbnail and
///   preview and hands them to the store, which promotes them only while that revision is
///   still current. A render that fails hands the photo to enrichment instead, which
///   renders with the saved recipe too, so the grid never keeps an edit's old thumbnail.
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
    case render(id: MediaAssetID, recipe: EditRecipe, sourceSize: Int64?, sequence: UInt64)
    /// Editing moved to another photo or the panel closed: let go of the open photo.
    case close
}

nonisolated enum EditCommandOrigin: String, Sendable {
    case user
    case undo
    case redo
}

nonisolated struct EditCommand: Sendable {
    let id: MediaAssetID
    let recipe: EditRecipe
    /// Undo menu title: the control that changed, or `Reset Light`.
    let actionName: String
    let origin: EditCommandOrigin
}

extension CatalogWindowViewModel {
    // MARK: - Panel

    /// View ▸ Show / Hide Edit Panel (E) and the toolbar button.
    func toggleEditPanel() {
        isEditPanelPresented.toggle()
        OtosLog.ui.noticeOperation("edit.panel", phase: isEditPanelPresented ? "shown" : "hidden")
        if isEditPanelPresented {
            refreshEditTarget()
        } else {
            commitPendingEdit()
            editTargetTask?.cancel()
            editTargetTask = nil
            clearEditTarget()
        }
    }

    /// Resolves the photo the panel edits whenever the current target changes (the same
    /// writers that refresh Open With). Reads the target's saved recipe once.
    func refreshEditTarget() {
        guard isEditPanelPresented else { return }
        let ids = targetIDs(.current)
        guard ids.count == 1, let id = ids.first else {
            commitPendingEdit()
            editTargetTask?.cancel()
            editTargetTask = nil
            clearEditTarget()
            return
        }
        guard editTarget?.id != id else { return }
        commitPendingEdit()
        editTargetTask?.cancel()
        let reader = tileDetailReader
        editTargetTask = Task { [weak self] in
            let detail = await reader.details(for: [id])[id]
            guard !Task.isCancelled, let self, targetIDs(.current) == [id] else { return }
            editTargetTask = nil
            guard let detail, detail.bestKind == .image || detail.bestKind == .raw else {
                clearEditTarget()
                return
            }
            let saved = detail.editRecipe ?? .neutral
            if editTarget != nil {
                editRenderContinuation.yield(.close)
            }
            editTarget = EditTarget(id: id, sourceSize: detail.byteSize)
            editSavedRecipe = saved
            editDraft = saved
            editLivePreview = nil
            OtosLog.ui.debugOperation("edit.target", phase: "resolved", fields: [
                "id": id.relativePath.rawValue, "edited": "\(!saved.isNeutral)",
            ])
        }
    }

    private func clearEditTarget() {
        guard editTarget != nil || editLivePreview != nil else { return }
        editTarget = nil
        editSavedRecipe = .neutral
        editDraft = .neutral
        editDraggingControl = nil
        editLivePreview = nil
        editRenderContinuation.yield(.close)
    }

    // MARK: - Controls

    /// A control moved. While it is being dragged only the live render follows; a change
    /// that is not a drag (a keyboard step, an accessibility increment) is saved at once.
    func setEditValue(_ value: Double, for control: LightControl) {
        guard editTarget != nil else { return }
        let next = control.applying(value, to: editDraft)
        guard next != editDraft else { return }
        editDraft = next
        requestLiveEditRender()
        if editDraggingControl != control {
            commitEdit(actionName: control.title)
        }
    }

    /// Slider drag start and end; the end saves the dragged value.
    func setEditDragging(_ dragging: Bool, control: LightControl) {
        if dragging {
            editDraggingControl = control
        } else if editDraggingControl == control {
            editDraggingControl = nil
            commitEdit(actionName: control.title)
        }
    }

    /// The Light section's Reset: every Light control back to neutral, as one undo step.
    func resetLight() {
        guard editTarget != nil, !editDraft.isNeutral else { return }
        editDraft = .neutral
        requestLiveEditRender()
        commitEdit(actionName: "Reset Light")
    }

    var hasEditTarget: Bool {
        editTarget != nil
    }

    /// True once every submitted edit command has been saved and rendered, or refused.
    var hasSettledEdits: Bool {
        handledEditCommandCount == submittedEditCommandCount
    }

    /// The pane image for `slot`: the live render while the pane's own preview does not
    /// yet carry the edit being made, otherwise the pane preview.
    func displayedPanePreview(_ slot: PaneSlot) -> PanePreview? {
        let pane = panePreviews[slot]
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
            nativePixelSize: matching?.nativePixelSize,
            renderedRevision: live.revision ?? matching?.renderedRevision ?? 0
        )
    }

    private func commitPendingEdit() {
        guard editTarget != nil, editDraft != editSavedRecipe else { return }
        commitEdit(actionName: editDraggingControl?.title ?? "Edit")
        editDraggingControl = nil
    }

    private func commitEdit(actionName: String) {
        guard let target = editTarget, editDraft != editSavedRecipe else { return }
        editSavedRecipe = editDraft
        enqueueEdit(EditCommand(id: target.id, recipe: editDraft, actionName: actionName, origin: .user))
        OtosLog.ui.noticeOperation("edit.submit", phase: "submitted", fields: [
            "id": target.id.relativePath.rawValue, "action": actionName,
        ])
    }

    private func enqueueEdit(_ command: EditCommand) {
        submittedEditCommandCount += 1
        editCommandContinuation.yield(command)
    }

    private func requestLiveEditRender() {
        guard let target = editTarget else { return }
        editRenderRequested &+= 1
        editRenderContinuation.yield(.render(
            id: target.id,
            recipe: editDraft,
            sourceSize: target.sourceSize,
            sequence: editRenderRequested
        ))
    }

    // MARK: - Lanes

    func startEditing(store: CatalogStore) {
        let pipeline = EditPipeline(
            store: store,
            renderer: liveEditRenderer,
            materialization: materializationCoordinator,
            directory: store.thumbnailDirectory
        )
        startLiveEditRendering(pipeline)
        startEditSaving(pipeline)
    }

    private func startLiveEditRendering(_ pipeline: EditPipeline) {
        editRenderTask = Task { [weak self, editRenderStream, pipeline] in
            for await request in editRenderStream {
                guard !Task.isCancelled else { break }
                switch request {
                case .close:
                    await pipeline.renderer.close()
                case let .render(id, recipe, sourceSize, sequence):
                    guard let image = await pipeline.liveImage(id, recipe: recipe, sourceSize: sourceSize) else {
                        continue
                    }
                    self?.publishLiveEdit(id: id, recipe: recipe, image: image, sequence: sequence)
                }
            }
        }
    }

    private func startEditSaving(_ pipeline: EditPipeline) {
        editCommandTask = Task { [weak self, editCommandStream, pipeline] in
            for await command in editCommandStream {
                defer { self?.handledEditCommandCount += 1 }
                guard !Task.isCancelled else { break }
                guard let result = await pipeline.save(command), let saved = result.saved else {
                    continue
                }
                self?.applySavedEdit(command, saved: saved, previous: result.previous?.recipe ?? .neutral)
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

    /// The draft rendered at preview size, or nil when the original cannot be read.
    @concurrent
    func liveImage(_ id: MediaAssetID, recipe: EditRecipe, sourceSize: Int64?) async -> CGImage? {
        guard await makeLocal(id, sourceSize: sourceSize) else {
            return nil
        }
        do {
            return try await renderer.render(id.fileURL, recipe: recipe)
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
            guard await makeLocal(id, sourceSize: result.sourceSize) else {
                await handToEnrichment(id)
                return nil
            }
            let rendered = try await renderer.renderProducts(
                id.fileURL, recipe: saved.recipe, id: id, directory: directory
            )
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

    private func handToEnrichment(_ id: MediaAssetID) async {
        do {
            try await store.handUnrenderedEditToEnrichment(id)
        } catch {
            OtosLog.persistence.errorOperation("edit.handToEnrichment", phase: "failed", fields: [
                "id": id.relativePath.rawValue, "error": String(describing: error),
            ])
        }
    }

    /// Makes the original's bytes local before a render reads them (ADR 0008): an
    /// interactive download when it is dataless, then the check again right before the read.
    private func makeLocal(_ id: MediaAssetID, sourceSize: Int64?) async -> Bool {
        let url = id.fileURL
        if FileMaterialization.status(of: url) == .dataless, let materialization {
            let result = await materialization.materialize(MaterializationCoordinator.Request(
                id: id, sourceSize: sourceSize, isVideo: false, priority: .interactive
            ))
            guard result.isMaterialized else {
                OtosLog.mediaIO.noticeOperation("edit.materialize", phase: "notMaterialized", fields: [
                    "id": id.relativePath.rawValue, "outcome": String(describing: result.outcome),
                ])
                return false
            }
        }
        guard FileMaterialization.status(of: url) == .materialized else {
            OtosLog.mediaIO.noticeOperation("edit.materialize", phase: "unavailable", fields: [
                "id": id.relativePath.rawValue,
            ])
            return false
        }
        return true
    }
}

import CoreGraphics
import Foundation
import OSLog

/// Edit session guide
///
/// `EditSession` is the window's edit feature (ADR 0036, ADR 0004): it owns every value the
/// edit panel, the crop tool and the edit commands hold, the three edit lanes and their
/// tasks. The window owns one for its life and is the only thing that holds it strongly. The
/// session reads the window, and asks it to act, only through `EditSession.Window`: the
/// window stays the one owner of its own state (targets, view mode, panes, the loupe's
/// player, the undo menu), and no edit state lives on the window.
///
/// The edit panel edits one still photo — the current target when it is exactly one
/// image or RAW (ADR 0036). Its values are `editDraft`; moving a control changes the draft
/// and asks for a live render, and letting go saves it.
///
/// When the target resolves the photo is opened — downloaded first if it is cloud-only,
/// as editing needs its bytes — and its facts (`EditPhotoFacts`: RAW or not, a RAW's
/// as-shot white balance) are published. The controls act only once they are known.
///
/// How that open went is the target's own state (`EditTarget.open`): opening, opened, or
/// failed. A failed open is not the end of the photo: the pane says its original can't be
/// read, and the target is resolved and opened again by whichever comes first:
/// - the next refresh of the target;
/// - the next catalog change (`catalogDidChange`): a row written, a root that came back;
/// - a change at the original's own path (`OriginalPathWatch`): the file written or put
///   back, a folder above it restored, its volume mounted again. This is what reopens an
///   original that returns exactly as it was, which changes no row. Right after the watch is
///   armed the original is looked at once more, so a return between the failed read and the
///   watch is not missed.
///
/// Nothing retries on a timer (ADR 0033); a refresh of a target that is open or opening
/// leaves it alone.
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
///   registers the inverse on `undoManager`, then renders the saved recipe's
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
///   a failed read publishes nothing and the buttons stay unavailable. Ending the lane
///   (the window closes) cancels its reading: one still waiting for the analyzer never runs
///   its model, and nothing it returns is published.
///
/// Undo and redo enqueue the same command through the same lane, so they order after any
/// save still in flight, and file their own inverse synchronously at fire time
/// (APP-039's pattern), on the window's one undo manager.
///
/// The pane keeps showing the live render until its own preview carries the save
/// (`PanePreview.renderedRevision`), so the image never steps back to the unedited photo
/// between letting go of a slider and the stored preview arriving.
nonisolated struct EditTarget: Equatable, Sendable {
    let id: MediaAssetID
    let sourceSize: Int64?
    /// How opening the original has gone so far.
    var open: EditTargetOpen
}

/// Where opening an edit target's original stands.
nonisolated enum EditTargetOpen: Equatable, Sendable {
    /// Asked for under `sequence` on the live lane, and not yet answered: by that request or
    /// any later one for the photo, since a newer render can replace a queued open.
    case opening(sequence: UInt64)
    /// Its facts are published; the controls act.
    case opened
    /// The original could not be made local or read. The next target refresh, catalog
    /// change or change at its path resolves and opens it again.
    case failed(EditOpenFailure)

    var hasFailed: Bool {
        if case .failed = self {
            true
        } else {
            false
        }
    }
}

/// Why opening an edit target's original failed.
nonisolated enum EditOpenFailure: Error, Equatable, Sendable {
    /// The original is not on this Mac and could not be made local: missing, its volume
    /// gone, a download that failed.
    case notLocal
    /// The original is local, but could not be decoded.
    case undecodable
}

/// A live render of `recipe` for `id`. `revision` is the save that recipe became, once it
/// has; nil while it is still only a draft.
nonisolated struct EditLivePreview: Equatable {
    let id: MediaAssetID
    let image: DisplayImage
    let recipe: EditRecipe
    var revision: Int64?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.image.isSame(as: rhs.image) && lhs.recipe == rhs.recipe && lhs.revision == rhs.revision
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

@MainActor
@Observable
final class EditSession {
    /// What the session reads from the window it edits in, and the window intents it calls.
    /// Each is the window's own answer or its own intent, read or called at the moment the
    /// session needs it, so the window stays the one owner of that state. A value read here
    /// during a view's body is observed like any read of the window.
    struct Window {
        /// The current targets (`targetIDs(.current)`).
        let currentTargets: @MainActor () -> [MediaAssetID]
        let viewMode: @MainActor () -> BrowserViewMode
        /// A story plays over On This Day: its pane draws no edit tools (ADR 0049).
        let isPlayingStory: @MainActor () -> Bool
        let focusedAssetID: @MainActor () -> MediaAssetID?
        let focusedAssetKind: @MainActor () -> MediaKind?
        /// The loupe's player, when its video is ready.
        let loupeVideoState: @MainActor () -> LoupeVideoState?
        /// The selected scope's state has been applied (`showsSelectedScope`).
        let showsSelectedScope: @MainActor () -> Bool
        /// The inspector shows the Edit pane.
        let isEditPanelPresented: @MainActor () -> Bool
        /// The pane's own decode for a slot, and the asset the slot is meant to show.
        let panePreview: @MainActor (PaneSlot) -> PanePreview?
        let expectedAsset: @MainActor (PaneSlot) -> MediaAssetID?
        /// The crop tool shows the Edit pane and the loupe.
        let setInspectorPane: @MainActor (InspectorPane?) -> Void
        let setViewMode: @MainActor (BrowserViewMode) -> Void
        /// Applies a saved trim to the loupe's ready player.
        let updateLoupeVideoState: @MainActor ((inout LoupeVideoState) -> Void) -> Void
        /// Reloads a pane's preview once the store holds an edit's new one.
        let requestPanePreview: @MainActor (MediaAssetID, PaneSlot) -> Void
        /// The loupe asks again for its full-resolution decode, so a zoomed photo is redone
        /// with the edit.
        let forgetFullResolutionRequest: @MainActor (MediaAssetID) -> Void
        let publishUndoState: @MainActor () -> Void
        let revealUndoneChange: @MainActor ([MediaAssetID]) -> Void
    }

    /// The one still photo the panel edits; nil disables its controls.
    var editTarget: EditTarget?
    /// The panel's values for `editTarget`: the saved recipe plus any change still being
    /// dragged. Any change to it turns every section the person turned off back on.
    var editDraft = EditRecipe.neutral {
        didSet {
            if editDraft != oldValue {
                editSectionsOff = nil
            }
        }
    }

    /// The edited sections the person turned off with their heading's checkmark, for the photo
    /// they were turned off on: the loupe shows the photo without those sections' changes,
    /// and nothing is saved (Photos' adjustment checkmarks). Back on with any change to the
    /// edit, and moot on another photo.
    var editSectionsOff: EditSectionsOff?
    /// The newest live render of the draft, shown in place of the pane's stored preview
    /// until that preview carries the saved edit.
    var editLivePreview: EditLivePreview?
    /// The open target's facts; nil until it has been opened (the controls wait for them).
    var editPhotoFacts: EditPhotoFacts?
    /// The open target's upright full-resolution size, from the decode its edits render
    /// from; nil until it has been opened. Crop geometry and the edited photo's size come
    /// from this, never from the catalog row.
    var editOriginalPixelSize: CGSize?
    /// The latest request for the loupe's player to show its trim UI.
    var videoTrimCommand: VideoTrimCommand?
    @ObservationIgnored var videoTrimGeneration: UInt64 = 0
    /// The white balance picker is armed: the next loupe click picks a neutral point.
    var isPickingNeutral = false
    /// View ▸ Show Original (\\): the loupe shows the photo without its edit until it is
    /// turned off, the photo changes, or an edit is made.
    var isShowingOriginal = false
    /// The open photo rendered without its edit, for Show Original.
    var editOriginalPreview: EditLivePreview?
    /// The adjustment the keyboard acts on: chosen with , and . (Select Previous and Next
    /// Adjustment) and moved with = and − (Increase and Decrease Adjustment).
    var selectedEditControl: EditControl?
    /// The histogram of the photo the panel edits, as last rendered (DES-100).
    var editHistogram: EditHistogram?
    /// The crop tool is on: the loupe shows the whole frame with the crop over it.
    var isCropping = false
    /// The crop tool's straighten line is armed: the next drag on the canvas draws it.
    var isDrawingStraightenLine = false
    /// The photo edited with everything but its crop, which the crop tool draws over.
    var editCropBase: EditLivePreview?
    /// The crop tool's aspect choice and which way it stands; tool state, not saved.
    var cropAspect = CropAspect.free
    /// Which way the constrained aspect stands, once Rotate Aspect has said so; nil follows
    /// the crop's own shape (`cropAspectIsLandscape`), decided only once the frame is known.
    var cropAspectLandscapeChoice: Bool?
    /// What Auto straighten would do for the photo the panel edits; nil until it is known.
    var editAutoLevel: AutoLevelReading?
    /// The suggested crop of the frame last read; nil until one is known.
    var editAutoCrop: AutoCropReading?
    @ObservationIgnored var isDraggingCrop = false
    /// The saved edit. Every change to it can move the frame the suggested crop was read
    /// from, so it asks for a new reading (`requestEditAnalysis`).
    @ObservationIgnored var editSavedRecipe = EditRecipe.neutral {
        didSet { requestEditAnalysis() }
    }

    @ObservationIgnored var editDraggingControl: EditControl?
    @ObservationIgnored var editTargetTask: Task<Void, Never>?
    /// The photo `editTargetTask` is reading, while it runs.
    @ObservationIgnored var editTargetRequestedID: MediaAssetID?
    /// Waits for the original of a target whose open failed (`watchOriginal`).
    @ObservationIgnored var editOriginalWatchTask: Task<Void, Never>?
    @ObservationIgnored let liveEditRenderer = LiveEditRenderer()
    // A live render is newest-wins; a save is a command that must survive in order.
    @ObservationIgnored let editRenderStream: AsyncStream<EditRenderRequest>
    @ObservationIgnored let editRenderContinuation: AsyncStream<EditRenderRequest>.Continuation
    @ObservationIgnored var editRenderTask: Task<Void, Never>?
    @ObservationIgnored var editRenderRequested: UInt64 = 0
    @ObservationIgnored var editRenderPublished: UInt64 = 0
    @ObservationIgnored var editHistogramPublished: UInt64 = 0
    @ObservationIgnored let editCommandStream: AsyncStream<EditLaneCommand>
    @ObservationIgnored let editCommandContinuation: AsyncStream<EditLaneCommand>.Continuation
    @ObservationIgnored var editCommandTask: Task<Void, Never>?
    /// Readings of the photo for Auto straighten and Auto crop: newest-wins, since only the
    /// current frame's matters.
    @ObservationIgnored let editAnalysisStream: AsyncStream<EditAnalysisRequest>
    @ObservationIgnored let editAnalysisContinuation: AsyncStream<EditAnalysisRequest>.Continuation
    @ObservationIgnored var editAnalysisTask: Task<Void, Never>?
    /// The reading last asked for, so an unchanged frame is not read again.
    @ObservationIgnored var editAnalysisRequested: EditAnalysisRequest?
    /// Submitted and fully handled edit commands — saved, rendered and applied, or
    /// refused — so a caller can wait for an edit to settle without guessing a duration.
    @ObservationIgnored var submittedEditCommandCount = 0
    @ObservationIgnored var handledEditCommandCount = 0

    @ObservationIgnored let window: Window
    /// Reads a target's saved recipe and kind, as the panes do.
    @ObservationIgnored private let tileDetailReader: MediaTileDetailReader
    /// The one way to an original's bytes; editing a cloud-only photo downloads it.
    @ObservationIgnored private let materialization: any MaterializationRequesting
    /// The window's one undo stack (ADR 0036): edits are undone among likes and trash.
    @ObservationIgnored private let undoManager: UndoManager
    /// Changes at an original's path (`OriginalPathWatch.changes(of:)`).
    @ObservationIgnored private let originalChanges: @Sendable (URL) -> AsyncStream<Void>

    init(
        window: Window,
        tileDetailReader: MediaTileDetailReader,
        materialization: any MaterializationRequesting,
        undoManager: UndoManager,
        originalChanges: @escaping @Sendable (URL) -> AsyncStream<Void> = OriginalPathWatch.changes(of:)
    ) {
        self.originalChanges = originalChanges
        self.window = window
        self.tileDetailReader = tileDetailReader
        self.materialization = materialization
        self.undoManager = undoManager
        let render = AsyncStream<EditRenderRequest>.makeStream(bufferingPolicy: .bufferingNewest(1))
        editRenderStream = render.stream
        editRenderContinuation = render.continuation
        let command = AsyncStream<EditLaneCommand>.makeStream(bufferingPolicy: .unbounded)
        editCommandStream = command.stream
        editCommandContinuation = command.continuation
        let analysis = AsyncStream<EditAnalysisRequest>.makeStream(bufferingPolicy: .bufferingNewest(1))
        editAnalysisStream = analysis.stream
        editAnalysisContinuation = analysis.continuation
    }

    isolated deinit {
        // Consumers before producers: finishing a stream drains what it buffered, and a
        // cancelled lane starts none of it.
        editTargetTask?.cancel()
        editOriginalWatchTask?.cancel()
        editRenderTask?.cancel()
        editCommandTask?.cancel()
        editAnalysisTask?.cancel()
        editRenderContinuation.finish()
        editCommandContinuation.finish()
        editAnalysisContinuation.finish()
    }

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
        guard canTrimVideo, let id = window.loupeVideoState()?.id else { return }
        videoTrimGeneration &+= 1
        videoTrimCommand = VideoTrimCommand(id: id, generation: videoTrimGeneration)
        OtosLog.ui.noticeOperation("edit.trim", phase: "requested", fields: ["id": id.relativePath.rawValue])
    }

    /// A video the loupe shows — not a Live Photo's motion, which plays under its still, and
    /// not one a story plays, whose pane draws no player controls to trim with (ADR 0049).
    var canTrimVideo: Bool {
        guard window.viewMode() == .loupe, !window.isPlayingStory(), window.focusedAssetKind() == .video,
              let video = window.loupeVideoState()
        else { return false }
        return video.id == window.focusedAssetID()
    }

    /// The trim UI closed with Trim: the range it left on the player is saved as one step.
    /// Cancel restores nothing to save, so it never reaches here.
    func finishTrim(id: MediaAssetID) {
        guard let state = window.loupeVideoState(), state.id == id else { return }
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

    /// The Color section's white balance picker: armed, the next click on the loupe image
    /// sets white balance from that point. Loupe only; Escape or any other move disarms it.
    func toggleNeutralPicker() {
        guard canPickNeutral || isPickingNeutral else { return }
        isPickingNeutral.toggle()
        OtosLog.ui.noticeOperation("edit.neutralPicker", phase: isPickingNeutral ? "armed" : "disarmed")
    }

    var canPickNeutral: Bool {
        editPhotoFacts != nil && window.viewMode() == .loupe && !window.isPlayingStory() && !isCropping
    }

    /// The loupe was clicked while the picker was armed.
    func pickNeutral(at point: CGPoint) {
        guard isPickingNeutral, canEdit, let target = editTarget else { return }
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
        guard window.isEditPanelPresented() else { return }
        if window.viewMode() != .loupe {
            isPickingNeutral = false
            endCropping()
            endShowingOriginal()
        }
        let ids = window.currentTargets()
        guard ids.count == 1, let id = ids.first else {
            commitPendingEdit()
            editTargetTask?.cancel()
            editTargetTask = nil
            clearEditTarget()
            return
        }
        // Already the target and open or opening, or already being read: every target writer
        // calls this, and one gesture fires several, so a read in flight for the same photo
        // is kept. A target whose open failed is resolved and opened again.
        if let target = editTarget, target.id == id, !target.open.hasFailed {
            return
        }
        guard !(editTargetTask != nil && editTargetRequestedID == id) else { return }
        // Only moving off a resolved photo ends its tools; the crop tool started for a
        // target still resolving, or opening again, stays on for it.
        if let target = editTarget, target.id != id {
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
                guard !Task.isCancelled, let self, window.currentTargets() == [id] else { return }
                // Without the saved recipe the panel cannot edit this photo, and the photo
                // it showed is no longer the target, so the panel closes its target rather
                // than edit either. `editTarget` is not `id`, so the next refresh reads again.
                editTargetTask = nil
                clearEditTarget()
                return
            }
            guard !Task.isCancelled, let self, window.currentTargets() == [id] else { return }
            editTargetTask = nil
            guard let detail, detail.bestKind == .image || detail.bestKind == .raw else {
                clearEditTarget()
                return
            }
            openTarget(id, detail: detail)
        }
    }

    /// The target's detail was read: it becomes the target, opening, and the live lane is
    /// asked to open it.
    private func openTarget(_ id: MediaAssetID, detail: MediaTileDetail) {
        let saved = detail.editRecipe ?? .neutral
        let reopening = editTarget?.id == id
        editOriginalWatchTask?.cancel()
        editOriginalWatchTask = nil
        editRenderRequested &+= 1
        editTarget = EditTarget(id: id, sourceSize: detail.byteSize, open: .opening(sequence: editRenderRequested))
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
        editRenderContinuation.yield(.open(
            id: id, sourceSize: detail.byteSize, recipe: saved, sequence: editRenderRequested
        ))
        if isCropping {
            requestLiveEditRender()
        }
        OtosLog.ui.debugOperation("edit.target", phase: reopening ? "reopening" : "resolved", fields: [
            "id": id.relativePath.rawValue, "edited": "\(!saved.isNeutral)",
        ])
    }

    /// The window applied a publication whose rows or roots changed. A target whose open
    /// failed may be readable now — its file written again, its volume back — so it is
    /// resolved and opened again; any other target is left as it is.
    func catalogDidChange() {
        guard editTarget?.open.hasFailed == true else { return }
        refreshEditTarget()
    }

    /// Something changed at the failed target's original, or it was found local right after
    /// the watch was armed: it is resolved and opened again.
    private func originalChanged(_ id: MediaAssetID, reason: String) {
        guard let target = editTarget, target.id == id, target.open.hasFailed else { return }
        editOriginalWatchTask = nil
        OtosLog.ui.noticeOperation("edit.target", phase: "originalChanged", fields: [
            "id": id.relativePath.rawValue, "reason": reason,
        ])
        refreshEditTarget()
    }

    /// While the target's open has failed, waits for its original: one look once the path's
    /// watch is armed (only for an original that was not local, so a local file that cannot
    /// be decoded is not opened again and again), then the first change at its path.
    private func watchOriginal(_ id: MediaAssetID, after failure: EditOpenFailure) {
        editOriginalWatchTask?.cancel()
        let changes = originalChanges(id.fileURL)
        let materialization = materialization
        editOriginalWatchTask = Task { [weak self] in
            if failure == .notLocal, await materialization.locality(of: id) == .local {
                guard !Task.isCancelled else { return }
                self?.originalChanged(id, reason: "localOnceWatched")
                return
            }
            for await _ in changes {
                guard !Task.isCancelled else { return }
                self?.originalChanged(id, reason: "pathChanged")
                return
            }
        }
    }

    /// The target is resolved and its original could not be read: the pane says so.
    var isOriginalUnreadable: Bool {
        editTarget?.open.hasFailed == true
    }

    private func clearEditTarget() {
        guard editTarget != nil || editLivePreview != nil else { return }
        endCropping()
        editOriginalWatchTask?.cancel()
        editOriginalWatchTask = nil
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
        guard canEdit, let facts = editPhotoFacts else { return }
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
        guard canEdit, !section.isNeutral(in: editDraft) else { return }
        editDraft = section.reset(editDraft)
        requestLiveEditRender()
        commitEdit(actionName: section.resetActionName)
    }

    /// The controls act: there is one photo to edit, it is open, and it belongs to the scope
    /// the user has selected. Until a newly selected scope publishes, the panel keeps showing
    /// the photo of the scope left (APP-080), but nothing acts on it.
    var canEdit: Bool {
        editTarget != nil && editPhotoFacts != nil && window.showsSelectedScope()
    }

    /// True once every submitted edit command has been saved and rendered, or refused.
    var hasSettledEdits: Bool {
        handledEditCommandCount == submittedEditCommandCount
    }

    /// The pane image for `slot`: the live render while the pane's own preview does not
    /// yet carry the edit being made, otherwise the pane preview.
    func displayedPanePreview(_ slot: PaneSlot) -> PanePreview? {
        let pane = window.panePreview(slot)
        if slot == .loupe, isShowingOriginal, let original = editOriginalPreview, window.expectedAsset(slot) == original.id {
            return PanePreview(
                id: original.id,
                image: original.image,
                mediaChoice: pane?.id == original.id ? pane?.mediaChoice : nil,
                uprightPixelSize: editOriginalPixelSize,
                renderedRevision: 0
            )
        }
        guard let live = editLivePreview, window.expectedAsset(slot) == live.id else {
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
            uprightPixelSize: editOriginalPixelSize ?? matching?.uprightPixelSize,
            editRecipe: live.recipe,
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

    /// The recipe the pane shows the photo with: the draft without the sections turned off,
    /// uncropped while the crop tool shows the whole frame.
    var shownRecipe: EditRecipe {
        let shown = sectionsTurnedOff.reduce(editDraft) { recipe, section in section.reset(recipe) }
        return isCropping ? shown.uncropped : shown
    }

    /// The sections of the open photo the person turned off.
    var sectionsTurnedOff: Set<EditSection> {
        guard let off = editSectionsOff, off.id == editTarget?.id else { return [] }
        return off.sections
    }

    /// A section heading's checkmark: turns the section's changes off in the loupe, or back
    /// on. Only a section with changes has one; nothing is saved.
    func toggleEditSection(_ section: EditSection) {
        guard let target = editTarget, !section.isNeutral(in: editDraft) else { return }
        var sections = sectionsTurnedOff
        if sections.contains(section) {
            sections.remove(section)
        } else {
            sections.insert(section)
        }
        editSectionsOff = sections.isEmpty ? nil : EditSectionsOff(id: target.id, sections: sections)
        requestLiveEditRender()
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

    /// Starts the edit lanes over `store`, as the window starts. The session owns its
    /// `analyzer`; a test making many windows in one process shares one, so the models load
    /// once there as they do in the app.
    func startEditing(store: CatalogStore, analyzer: EditAnalyzer = EditAnalyzer()) {
        let pipeline = EditPipeline(
            store: store,
            renderer: liveEditRenderer,
            materialization: materialization,
            directory: store.thumbnailDirectory,
            analyzer: analyzer
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
                // A lane ended mid-reading publishes nothing: its reading may be cut short.
                guard !Task.isCancelled else { break }
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
                    let opened: OpenedEditPhoto
                    switch await pipeline.open(id, sourceSize: sourceSize) {
                    case let .success(photo):
                        opened = photo
                    case let .failure(failure):
                        self?.publishOpenFailed(id: id, sequence: sequence, failure)
                        continue
                    }
                    self?.publishOpenedPhoto(id: id, opened)
                    let rendered = await pipeline.liveImage(id, recipe: recipe, sourceSize: sourceSize)
                    guard case let .success(live) = rendered else { continue }
                    let histogram = await EditHistogram.count(live.image.cgImage)
                    self?.publishHistogram(id: id, histogram, sequence: sequence)
                case let .render(id, recipe, sourceSize, sequence, purpose, requestedAt):
                    let startedAt = ContinuousClock.now
                    let live: (image: DisplayImage, opened: OpenedEditPhoto)
                    switch await pipeline.liveImage(id, recipe: recipe, sourceSize: sourceSize) {
                    case let .success(rendered):
                        live = rendered
                    case let .failure(failure):
                        // A render that replaced a queued open answers for it.
                        self?.publishOpenFailed(id: id, sequence: sequence, failure)
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
                        let histogram = await EditHistogram.count(live.image.cgImage)
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
        guard var target = editTarget, target.id == id else { return }
        if target.open != .opened {
            target.open = .opened
            editTarget = target
        }
        guard editPhotoFacts != opened.facts || editOriginalPixelSize != opened.pixelSize else { return }
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

    /// A request for the target could not read its original. It fails the open only while
    /// that open is still unanswered and the request is the open or a later one; a render
    /// failing once the photo is open leaves it open.
    private func publishOpenFailed(id: MediaAssetID, sequence: UInt64, _ failure: EditOpenFailure) {
        guard var target = editTarget, target.id == id,
              case let .opening(opening) = target.open, sequence >= opening
        else { return }
        target.open = .failed(failure)
        editTarget = target
        OtosLog.ui.noticeOperation("edit.target", phase: "openFailed", fields: [
            "id": id.relativePath.rawValue, "sequence": "\(sequence)", "failure": "\(failure)",
        ])
        watchOriginal(id, after: failure)
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

    private func publishOriginal(id: MediaAssetID, image: DisplayImage, sequence: UInt64) {
        guard isShowingOriginal, editTarget?.id == id, sequence > editRenderPublished else { return }
        editRenderPublished = sequence
        editOriginalPreview = EditLivePreview(id: id, image: image, recipe: .neutral, revision: nil)
    }

    private func publishLiveEdit(id: MediaAssetID, recipe: EditRecipe, image: DisplayImage, sequence: UInt64) {
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
        if window.loupeVideoState()?.id == command.id {
            window.updateLoupeVideoState { $0.applyTrim(saved.recipe) }
        }
        if var live = editLivePreview, live.id == command.id, live.recipe == saved.recipe {
            live.revision = saved.revision
            editLivePreview = live
        }
    }

    /// The saved recipe's render becomes the live image while the panel still shows that
    /// recipe — the render an undo produces, or a save of the draft on screen.
    private func showRenderedEdit(id: MediaAssetID, saved: StoredEditRecipe, image: DisplayImage) {
        guard editTarget?.id == id, editDraft == saved.recipe else { return }
        editRenderPublished = editRenderRequested
        editLivePreview = EditLivePreview(id: id, image: image, recipe: saved.recipe, revision: saved.revision)
    }

    /// The store now holds the edited preview: reload it into every pane showing the
    /// photo, without clearing what they show meanwhile, and redo a zoomed loupe's
    /// full-resolution decode with the edit.
    private func refreshEditedPanes(_ id: MediaAssetID) {
        for slot in PaneSlot.allCases where window.expectedAsset(slot) == id {
            if slot == .loupe {
                window.forgetFullResolutionRequest(id)
            }
            window.requestPanePreview(id, slot)
        }
    }

    // MARK: - Undo

    private func registerEditUndo(id: MediaAssetID, restoring: EditRecipe, inverse: EditRecipe, actionName: String) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { session in
            session.restoreEdit(id: id, recipe: restoring, inverse: inverse, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
        window.publishUndoState()
    }

    /// Runs inside `UndoManager.undo()` / `redo()`: files the opposite entry first, so it
    /// lands on the other stack, then enqueues the restore through the save lane.
    private func restoreEdit(id: MediaAssetID, recipe: EditRecipe, inverse: EditRecipe, actionName: String) {
        let origin: EditCommandOrigin = undoManager.isUndoing ? .undo : .redo
        undoManager.registerUndo(withTarget: self) { session in
            session.restoreEdit(id: id, recipe: inverse, inverse: recipe, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        window.revealUndoneChange([id])
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
/// (`@concurrent`), and none touches session state; the lanes apply what they return.
nonisolated struct EditPipeline: Sendable {
    let store: CatalogStore
    let renderer: LiveEditRenderer
    let materialization: any MaterializationRequesting
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
    /// facts and upright size, or why it cannot be read.
    @concurrent
    func open(_ id: MediaAssetID, sourceSize: Int64?) async -> Result<OpenedEditPhoto, EditOpenFailure> {
        guard await materialization.ensureLocal(.init(
            id: id, sourceSize: sourceSize, isVideo: false, priority: .interactive
        )).isLocal else {
            return .failure(.notLocal)
        }
        do {
            return try await .success(renderer.open(id.fileURL))
        } catch {
            OtosLog.rendering.errorOperation("render.liveEdit", phase: "openFailed", fields: [
                "id": id.relativePath.rawValue, "error": String(describing: error),
            ])
            return .failure(.undecodable)
        }
    }

    /// The draft rendered at preview size with what opening the photo reported, or why the
    /// original cannot be read.
    @concurrent
    func liveImage(
        _ id: MediaAssetID,
        recipe: EditRecipe,
        sourceSize: Int64?
    ) async -> Result<(image: DisplayImage, opened: OpenedEditPhoto), EditOpenFailure> {
        guard await materialization.ensureLocal(.init(
            id: id, sourceSize: sourceSize, isVideo: false, priority: .interactive
        )).isLocal else {
            return .failure(.notLocal)
        }
        do {
            let image = try await renderer.render(id.fileURL, recipe: recipe)
            return try await .success((image, renderer.open(id.fileURL)))
        } catch {
            OtosLog.rendering.errorOperation("render.liveEdit", phase: "failed", fields: [
                "id": id.relativePath.rawValue, "error": String(describing: error),
            ])
            return .failure(.undecodable)
        }
    }

    /// Renders the saved recipe's products, unless a newer save has already replaced it.
    /// A render that cannot happen hands the photo to enrichment.
    @concurrent
    func products(
        _ id: MediaAssetID,
        saved: StoredEditRecipe,
        result: EditRecipeMutationResult
    ) async -> (image: DisplayImage, staged: RenderedEditProducts)? {
        guard let directory else {
            return nil
        }
        do {
            guard try await store.windowReads.editRecipe(for: id)?.revision == saved.revision else {
                OtosLog.rendering.debugOperation("render.editProducts", phase: "superseded", fields: [
                    "id": id.relativePath.rawValue, "revision": "\(saved.revision)",
                ])
                return nil
            }
            guard await materialization.ensureLocal(.init(
                id: id, sourceSize: result.sourceSize, isVideo: false, priority: .interactive
            )).isLocal else {
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
        guard await materialization.ensureLocal(.init(
            id: id, sourceSize: sourceSize, isVideo: false, priority: .interactive
        )).isLocal else {
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
        guard await materialization.ensureLocal(.init(
            id: request.id, sourceSize: request.sourceSize, isVideo: false, priority: .interactive
        )).isLocal
        else { return EditAnalysis(crop: nil, level: nil) }
        let url = request.id.fileURL
        let path = request.id.relativePath.rawValue
        var crop: EditCrop??
        let cropStart = ContinuousClock.now
        do {
            guard let frame = try await renderer.analysisImage(url, recipe: request.frame) else {
                Self.logAnalysisSkipped(path)
                return EditAnalysis(crop: nil, level: nil)
            }
            let modelStart = ContinuousClock.now
            let suggested = try await analyzer.crop(of: frame)
            crop = .some(suggested)
            OtosLog.rendering.noticeOperation("edit.autoCrop", phase: "read", fields: [
                "id": path,
                "crop": suggested.map { String(format: "%.3f,%.3f,%.3f,%.3f", $0.left, $0.top, $0.width, $0.height) } ?? "none",
                "image": "\(frame.width)x\(frame.height)",
                "renderMs": "\(DiagnosticsTiming.milliseconds(from: cropStart, to: modelStart))",
                "modelMs": "\(DiagnosticsTiming.milliseconds(since: modelStart))",
                "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: cropStart))",
            ])
        } catch is CancellationError {
            Self.logAnalysisCancelled(path, reading: "crop")
            return EditAnalysis(crop: nil, level: nil)
        } catch {
            OtosLog.rendering.errorOperation("edit.autoCrop", phase: "failed", fields: [
                "id": path, "error": String(describing: error),
            ])
        }
        guard request.needsLevel else { return EditAnalysis(crop: crop, level: nil) }
        // The lane was ended while the crop was read: the level would be read for no one.
        guard !Task.isCancelled else {
            Self.logAnalysisCancelled(path, reading: "level")
            return EditAnalysis(crop: crop, level: nil)
        }
        var level: AutoLevelReading.Level?
        let levelStart = ContinuousClock.now
        do {
            guard let photo = try await renderer.analysisImage(url, recipe: .neutral) else {
                Self.logAnalysisSkipped(path)
                return EditAnalysis(crop: crop, level: nil)
            }
            let modelStart = ContinuousClock.now
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
                "image": "\(photo.width)x\(photo.height)",
                "renderMs": "\(DiagnosticsTiming.milliseconds(from: levelStart, to: modelStart))",
                "modelMs": "\(DiagnosticsTiming.milliseconds(since: modelStart))",
                "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: levelStart))",
            ])
        } catch is CancellationError {
            Self.logAnalysisCancelled(path, reading: "level")
        } catch {
            OtosLog.rendering.errorOperation("edit.autoLevel", phase: "failed", fields: [
                "id": path, "error": String(describing: error),
            ])
        }
        return EditAnalysis(crop: crop, level: level)
    }

    /// The analysis lane was ended (its window closed) before this reading's turn on the
    /// analyzer came, so the model never ran for it.
    private static func logAnalysisCancelled(_ path: String, reading: String) {
        OtosLog.rendering.noticeOperation("edit.analysis", phase: "cancelled", fields: [
            "id": path, "reading": reading,
        ])
    }

    /// The photo was left before its read: nothing is developed, and the reading it would have
    /// given belongs to no photo on screen.
    private static func logAnalysisSkipped(_ path: String) {
        OtosLog.rendering.noticeOperation("edit.analysis", phase: "skipped", fields: [
            "id": path, "reason": "photoLeft",
        ])
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
///
/// Readings run one at a time, so a reading waits its turn behind the ones asked for before it.
/// A prediction cannot be interrupted once it starts, but a reading whose caller was cancelled
/// while it waited is never started: it throws `CancellationError` when its turn comes, and the
/// queue moves on to work someone still wants.
actor EditAnalyzer {
    private let queue: DispatchSerialQueue
    private var crop: AutoCropModel?
    private var level: AutoLevelModel?

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// `queue` is the one the models run on; a test passes its own to hold readings back.
    init(queue: DispatchSerialQueue = DispatchSerialQueue(label: "net.melisma.Otos.edit.analysis", qos: .userInitiated)) {
        self.queue = queue
    }

    /// FocalNet's suggested crop of `image`, or nil when it would keep it whole.
    func crop(of image: CGImage) throws -> EditCrop? {
        try Task.checkCancellation()
        return try cropModel().crop(of: image)
    }

    /// GeoCalib's roll of `image` and its uncertainty, radians.
    func roll(of image: CGImage) throws -> (roll: Double, uncertainty: Double)? {
        try Task.checkCancellation()
        return try levelModel().roll(of: image)
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

/// The sections turned off on one photo (`EditSession.editSectionsOff`).
nonisolated struct EditSectionsOff: Equatable, Sendable {
    let id: MediaAssetID
    let sections: Set<EditSection>
}

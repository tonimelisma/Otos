import AppKit
import Foundation
import OSLog

/// Hand-off intents guide
///
/// Copy (⌘C), Share and Open / Open With hand the current targets to another app as one
/// full-size file per photo, on this Mac (ADR 0012, ADR 0037; `HandOffPreparer`). Reveal in
/// Finder hands Finder the originals themselves, never a rendered file. An edited photo or a
/// RAW needs a file rendered first, a cloud-only original needs downloading, and an original
/// a source stages (an Immich account's, a camera's) needs fetching before it has a file, so
/// every hand-off travels one ordered lane with one consumer (`handOffStream`, lossless). For
/// each request the consumer starts one task (`handOffWork`) that:
/// 1. reads the targets' details;
/// 2. prepares each photo whose file is not ready, publishing `handOffProgress` (the status
///    bar's "Preparing 3 photos to copy", M of N, with Cancel);
/// 3. returns the files, or the first failure, or that it was cancelled;
///
/// and the consumer then performs the action with the files: writes the pasteboard, shows
/// the share picker, opens the files, or reveals them in Finder.
///
/// A hand-off whose files are all ready completes as soon as its details are read, with no
/// progress shown. Cancel cancels the task, which stops the download or render in flight
/// (`HandOffPreparer` and `MaterializationCoordinator` release work no one waits for), and
/// hands nothing over. A hand-off is all or nothing: a partial one would silently drop
/// photos the person chose, so the first photo that cannot be prepared ends it, and the
/// alert names that photo's cause (`HandOffFailure`).
///
/// The pasteboard is newest-wins state, so Copy is too: ⌘C claims the pasteboard at once
/// (`MediaGridClipboard.claim`), so a paste while the photos are prepared never pastes what
/// was there before, and a newer Copy cancels an older one still being prepared and skips one
/// still queued. The files are written only if nothing has written the pasteboard since the
/// claim, so a slow Copy never overwrites what the person copied after it.
///
/// Drag cannot wait for this lane: `dragWriters(for:)` answers synchronously from the
/// details the grid already holds, with a ready file's URL or a file promise that prepares on
/// demand (`HandOffPromise`).
nonisolated enum HandOffAction: Equatable, Sendable {
    case copy(NSPasteboard.Name)
    case share(ShareOrigin)
    case openDefault
    case openWith(URL)
    case revealInFinder

    /// The verb the status bar uses: "Preparing 3 photos to copy".
    var verb: String {
        switch self {
        case .copy: "copy"
        case .share: "share"
        case .openDefault, .openWith: "open"
        case .revealInFinder: "reveal"
        }
    }

    /// What the alert says did not happen, as a sentence of its own.
    var refusalSentence: String {
        self == .revealInFinder ? "Nothing was revealed." : "Nothing was handed over."
    }

    /// Which file the action takes for each photo: Reveal in Finder takes the original,
    /// because it shows where the photo lives, not what is handed over.
    var wanted: HandOffPreparer.Wanted {
        self == .revealInFinder ? .original : .handOffFile
    }

    var isCopy: Bool {
        if case .copy = self {
            true
        } else {
            false
        }
    }
}

nonisolated struct HandOffRequest: Sendable {
    let ids: [MediaAssetID]
    let action: HandOffAction
    let generation: UInt64
    /// For a Copy, the pasteboard's change count after ⌘C claimed it: the files are written
    /// only while it is still the pasteboard's.
    let clipboardClaim: Int?
}

/// The hand-off the lane is working on.
nonisolated struct HandOffWork: Sendable {
    let generation: UInt64
    let action: HandOffAction
    let task: Task<HandOffOutcome, Never>
}

/// How a hand-off's preparation ended.
nonisolated enum HandOffOutcome: Equatable, Sendable {
    /// Every photo's file, in order, and how many of them took work.
    case ready([URL], prepared: Int)
    case failed(HandOffFailure)
    case cancelled
}

/// The hand-off being prepared, as the status bar shows it.
nonisolated struct HandOffProgress: Equatable, Sendable {
    let verb: String
    let completed: Int
    let total: Int
    let generation: UInt64

    /// The status bar's line: "Preparing 3 photos to copy".
    var title: String {
        "Preparing \(total == 1 ? "1 photo" : "\(total) photos") to \(verb)"
    }
}

extension CatalogWindowViewModel {
    /// Edit ▸ Copy (⌘C) and the context menu's Copy.
    func copyCurrentTargets(to pasteboard: NSPasteboard = .general) {
        handOff(.copy(pasteboard.name))
    }

    /// Submits a hand-off of the current targets to the lane. A Copy claims the pasteboard
    /// here, at the command, and supersedes every older Copy.
    func handOff(_ action: HandOffAction) {
        // Reveal in Finder shows every file a collapsed stack is made of; every other
        // hand-off gives the picture, the stack's shown member (ADR 0052).
        let stacks = parts.gridStacks
        let ids: [MediaAssetID] = switch action {
        case .revealInFinder:
            targetIDs(.current).flatMap(stacks.files(reachedThrough:))
        case .copy, .share, .openDefault, .openWith:
            targetIDs(.current)
        }
        guard !ids.isEmpty else { return }
        handOffRequested &+= 1
        var claim: Int?
        if case let .copy(name) = action {
            claim = MediaGridClipboard.claim(NSPasteboard(name: name))
            latestCopyGeneration = handOffRequested
            if let work = handOffWork, work.action.isCopy {
                work.task.cancel()
            }
        }
        submittedHandOffCount += 1
        handOffContinuation.yield(HandOffRequest(
            ids: ids, action: action, generation: handOffRequested, clipboardClaim: claim
        ))
        OtosLog.ui.noticeOperation("handOff.submit", phase: "submitted", fields: [
            "count": "\(ids.count)", "action": action.verb, "generation": "\(handOffRequested)",
            "mode": viewMode.rawValue,
        ])
    }

    /// The status bar's Cancel: the hand-off being prepared stops — its download or render
    /// with it — and hands nothing over.
    func cancelHandOff() {
        guard let progress = handOffProgress else { return }
        handOffProgress = nil
        if let work = handOffWork, work.generation == progress.generation {
            work.task.cancel()
        }
        OtosLog.ui.noticeOperation("handOff.cancel", phase: "requested", fields: [
            "generation": "\(progress.generation)",
        ])
    }

    /// True once every submitted hand-off has been handed over, cancelled, superseded or
    /// failed.
    var hasSettledHandOffs: Bool {
        handledHandOffCount == submittedHandOffCount
    }

    func dismissHandOffAlert() {
        handOffAlertMessage = nil
    }

    /// The lane's one consumer. Each request's work is a task of its own, so Cancel can stop
    /// it, and it is cancelled with the lane at teardown.
    func startHandOff(store _: CatalogStore) {
        handOffTask = Task { [weak self, handOffStream] in
            for await request in handOffStream {
                guard !Task.isCancelled else { break }
                guard let work = self?.beginHandOff(request) else { continue }
                let outcome = await withTaskCancellationHandler {
                    await work.task.value
                } onCancel: {
                    work.task.cancel()
                }
                self?.finishHandOff(request, outcome: outcome, work: work)
            }
        }
    }

    /// Starts `request`'s work, or settles it at once: an older Copy than the newest is
    /// superseded, and nothing of it runs.
    private func beginHandOff(_ request: HandOffRequest) -> HandOffWork? {
        if request.action.isCopy, request.generation < latestCopyGeneration {
            handledHandOffCount += 1
            OtosLog.ui.noticeOperation("handOff.complete", phase: "superseded", fields: [
                "generation": "\(request.generation)", "newest": "\(latestCopyGeneration)",
            ])
            return nil
        }
        let preparer = handOffPreparer
        let reader = tileDetailReader
        let task = Task { [weak self, preparer, reader] () -> HandOffOutcome in
            let details: [MediaAssetID: MediaTileDetail]
            do {
                details = try await reader.details(for: request.ids)
            } catch {
                // The reader logged it; nothing is handed over for an unread target.
                return Task.isCancelled ? .cancelled : .failed(.detailsUnread)
            }
            let items = request.ids.map { EditedMediaItem(id: $0, detail: details[$0]) }
            let wanted = request.action.wanted
            // Asked once, before progress shows, so the status bar counts only photos that
            // take work: a file to download, render or export.
            let needed = await preparer.needsWork(items, as: wanted)
            let total = needed.count(where: \.self)
            guard !Task.isCancelled else { return .cancelled }
            self?.beginHandOffProgress(request, total: total)
            var urls: [URL] = []
            for (item, itemNeeded) in zip(items, needed) {
                do {
                    try await urls.append(preparer.prepare(item, as: wanted))
                } catch {
                    // A cancellation is no failure; every other error has its cause.
                    guard !Task.isCancelled, let failure = HandOffPreparer.failure(for: error) else {
                        return .cancelled
                    }
                    let root = item.id.libraryRootPath
                    return .failed(.photo(failure, source: self?.sourceName(for: root) ?? root.rawValue))
                }
                guard !Task.isCancelled else { return .cancelled }
                if itemNeeded {
                    self?.advanceHandOffProgress(request)
                }
            }
            return .ready(urls, prepared: total)
        }
        let work = HandOffWork(generation: request.generation, action: request.action, task: task)
        handOffWork = work
        return work
    }

    /// Applies a request's outcome, synchronously, on the identity it started for.
    private func finishHandOff(_ request: HandOffRequest, outcome: HandOffOutcome, work: HandOffWork) {
        handledHandOffCount += 1
        if handOffWork?.generation == work.generation {
            handOffWork = nil
        }
        endHandOffProgress(request)
        // A Cancel or a newer Copy that arrived after the work returned still wins.
        let result: HandOffOutcome = work.task.isCancelled ? .cancelled : outcome
        switch result {
        case .cancelled:
            let superseded = request.action.isCopy && request.generation < latestCopyGeneration
            OtosLog.ui.noticeOperation(
                superseded ? "handOff.complete" : "handOff.cancel",
                phase: superseded ? "superseded" : "applied",
                fields: ["generation": "\(request.generation)"]
            )
        case let .failed(failure):
            handOffAlertMessage = failure.alertMessage(for: request.action)
            OtosLog.ui.errorOperation("handOff.complete", phase: "failed", fields: [
                "cause": failure.diagnosticName,
                "count": "\(request.ids.count)",
                "action": request.action.verb,
                "generation": "\(request.generation)",
            ])
        case let .ready(urls, prepared):
            completeHandOff(request, urls: urls, prepared: prepared)
        }
    }

    private func beginHandOffProgress(_ request: HandOffRequest, total: Int) {
        guard total > 0 else { return }
        handOffProgress = HandOffProgress(
            verb: request.action.verb, completed: 0, total: total, generation: request.generation
        )
    }

    private func advanceHandOffProgress(_ request: HandOffRequest) {
        guard let progress = handOffProgress, progress.generation == request.generation else { return }
        handOffProgress = HandOffProgress(
            verb: progress.verb,
            completed: min(progress.completed + 1, progress.total),
            total: progress.total,
            generation: progress.generation
        )
    }

    private func endHandOffProgress(_ request: HandOffRequest) {
        if handOffProgress?.generation == request.generation {
            handOffProgress = nil
        }
    }

    private func completeHandOff(_ request: HandOffRequest, urls: [URL], prepared: Int) {
        switch request.action {
        case let .copy(name):
            guard let claim = request.clipboardClaim else { return }
            MediaGridClipboard.write(files: urls, to: NSPasteboard(name: name), claimed: claim)
        case let .share(origin):
            presentSharePicker(urls, origin: origin)
        case .openDefault:
            var groups: [(application: URL, targets: [URL])] = []
            for url in urls {
                guard let application = workspace.defaultApplicationURL(toOpen: url) else {
                    OtosLog.ui.notice("op=ui.open.noDefaultApplication count=1")
                    continue
                }
                if let index = groups.firstIndex(where: { $0.application == application }) {
                    groups[index].targets.append(url)
                } else {
                    groups.append((application, [url]))
                }
            }
            for group in groups {
                open(group.targets, with: group.application, origin: "default")
            }
        case let .openWith(application):
            open(urls, with: application, origin: "openWith")
        case .revealInFinder:
            workspace.revealInFinder(urls)
            OtosLog.ui.notice("op=ui.revealInFinder count=\(urls.count, privacy: .public)")
        }
        OtosLog.ui.noticeOperation("handOff.complete", phase: "handedOver", fields: [
            "count": "\(urls.count)", "prepared": "\(prepared)", "action": request.action.verb,
            "generation": "\(request.generation)",
        ])
    }

    /// The name the sidebar shows for a library or removable source.
    func sourceName(for rootPath: LibraryRootPath) -> String? {
        (parts.libraries + parts.removableSources).first { $0.path == rootPath }?.displayName
    }

    /// The drag pasteboard writers for the photos a drag carries, in order (ADR 0028,
    /// ADR 0037): the URL of a photo's file when it is ready — the original, a cloud
    /// placeholder included, or the file this launch prepared — and otherwise a file promise
    /// that prepares it when the receiver asks. Synchronous, from the details the grid holds;
    /// the photos it holds none for are promised as pending, and their details are read at
    /// once, off the main actor (`dragDetailsTask`), so a promise names and writes the file
    /// the hand-off gives, never a guess. Empty while the selected scope's state is not
    /// applied (`showsSelectedScope`): the photos held are no one's to hand over (APP-080).
    func dragWriters(for ids: [MediaAssetID]) -> [NSPasteboardWriting] {
        guard showsSelectedScope else { return [] }
        let preparer = handOffPreparer
        var pending: [PendingHandOffItem] = []
        let writers = ids.map { id -> NSPasteboardWriting in
            guard let detail = tileContentStore.content(for: id)?.detail else {
                let item = PendingHandOffItem(id: id)
                pending.append(item)
                return HandOffPromise(.pending(item), preparer: preparer)
            }
            let item = EditedMediaItem(id: id, detail: detail)
            if let ready = preparer.readyURL(for: item, as: .draggedFile) {
                return MediaGridClipboard.pasteboardItem(for: ready)
            }
            return HandOffPromise(.item(item), preparer: preparer)
        }
        if !pending.isEmpty {
            readDragDetails(pending)
        }
        return writers
    }

    /// Reads the details of a drag's pending photos and resolves each, with its item or
    /// with the read's error. Detached from the main actor: a receiver may wait for the
    /// answer on the main thread (`PendingHandOffItem.wait()`).
    private func readDragDetails(_ pending: [PendingHandOffItem]) {
        let reader = tileDetailReader
        dragDetailsTask = Task.detached(priority: .userInitiated) {
            do {
                let details = try await reader.details(for: pending.map(\.id))
                for item in pending {
                    item.resolve(.success(EditedMediaItem(id: item.id, detail: details[item.id])))
                }
            } catch {
                // The reader logged it; each promise fails with the read's error.
                for item in pending {
                    item.resolve(.failure(error))
                }
            }
        }
    }
}

/// Why a hand-off could not be done: the first photo that could not be prepared and why,
/// or the targets' details that could not be read. The alert says it in the cause's own
/// terms: a full disk as one, never as an unavailable original; a source that cannot send
/// an original, or a folder's provider that did not deliver one, by the name the sidebar
/// shows (ADR 0046 §6).
nonisolated enum HandOffFailure: Equatable, Sendable {
    case detailsUnread
    case photo(HandOffPreparer.PrepareError, source: String)

    /// The alert's message for `action`, which says what did not happen.
    func alertMessage(for action: HandOffAction) -> String {
        switch self {
        case .detailsUnread:
            "Otos couldn’t read these photos from its catalog. \(action.refusalSentence)"
        case let .photo(.outOfSpace, _):
            "There isn’t enough disk space to prepare one photo. \(action.refusalSentence) Free up space and try again."
        case let .photo(cause, source):
            "\(Self.sentence(for: cause, source: source)) \(action.refusalSentence)"
        }
    }

    private static func sentence(for cause: HandOffPreparer.PrepareError, source: String) -> String {
        switch cause {
        case .originalMissing:
            "One photo’s original isn’t where Otos last saw it."
        case .downloadFailed:
            "One photo couldn’t be downloaded from “\(source)”."
        case .sourceUnavailable(.serverNotAnswering):
            "“\(source)” isn’t answering, so one photo couldn’t be downloaded."
        case .sourceUnavailable(.cameraDisconnected):
            "“\(source)” isn’t connected, so one photo couldn’t be copied from it."
        case .rawSupportUnavailable:
            "macOS couldn’t download what it needs to develop one RAW photo."
        case .renderFailed:
            "One photo couldn’t be rendered from its original."
        case .outOfSpace:
            "There isn’t enough disk space to prepare one photo."
        }
    }

    /// The cause as the log names it.
    var diagnosticName: String {
        switch self {
        case .detailsUnread: "detailsUnread"
        case .photo(.originalMissing, _): "originalMissing"
        case .photo(.downloadFailed, _): "downloadFailed"
        case .photo(.sourceUnavailable(.serverNotAnswering), _): "serverNotAnswering"
        case .photo(.sourceUnavailable(.cameraDisconnected), _): "cameraDisconnected"
        case .photo(.rawSupportUnavailable, _): "rawSupportUnavailable"
        case .photo(.renderFailed, _): "renderFailed"
        case .photo(.outOfSpace, _): "outOfSpace"
        }
    }
}

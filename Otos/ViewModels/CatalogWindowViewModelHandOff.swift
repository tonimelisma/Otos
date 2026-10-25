import AppKit
import Foundation
import OSLog

/// Hand-off intents guide
///
/// Copy (⌘C), Share and Open / Open With hand the current targets to another app as one
/// full-size file per photo (plan 0108 increment 13; `HandOffPreparer`). An edited photo
/// or a RAW needs a file rendered first, so every hand-off travels one ordered lane with
/// one consumer (`handOffStream`, lossless). The consumer:
/// 1. reads the targets' details;
/// 2. prepares what needs preparing, publishing `handOffProgress` (the status bar's
///    "Preparing 3 photos to copy", M of N, with Cancel);
/// 3. performs the action with the files: writes the pasteboard, shows the share picker,
///    or opens the files.
///
/// A hand-off whose targets need nothing prepared completes as soon as its details are
/// read, with no progress shown. Cancel stops the preparation in flight between photos and
/// hands nothing over. A photo that cannot be prepared (its original cannot be downloaded
/// or read) fails the whole hand-off with an alert; a partial hand-off would silently drop
/// photos the person chose.
///
/// Drag cannot wait for this lane: `dragWriter(for:)` answers synchronously from the
/// details the grid already holds, with the original's URL, a file this launch already
/// prepared, or a file promise that prepares on demand (`HandOffPromise`).
nonisolated enum HandOffAction: Equatable, Sendable {
    case copy(NSPasteboard.Name)
    case share(ShareOrigin)
    case openDefault
    case openWith(URL)

    /// The verb the status bar uses: "Preparing 3 photos to copy".
    var verb: String {
        switch self {
        case .copy: "copy"
        case .share: "share"
        case .openDefault, .openWith: "open"
        }
    }
}

nonisolated struct HandOffRequest: Sendable {
    let ids: [MediaAssetID]
    let action: HandOffAction
    let generation: UInt64
}

/// The hand-off being prepared, as the status bar shows it.
nonisolated struct HandOffProgress: Equatable, Sendable {
    let verb: String
    let completed: Int
    let total: Int
    let generation: UInt64
}

extension CatalogWindowViewModel {
    /// Edit ▸ Copy (⌘C) and the context menu's Copy.
    func copyCurrentTargets(to pasteboard: NSPasteboard = .general) {
        handOff(.copy(pasteboard.name))
    }

    /// Submits a hand-off of the current targets to the lane.
    func handOff(_ action: HandOffAction) {
        let ids = targetIDs(.current)
        guard !ids.isEmpty else { return }
        handOffRequested &+= 1
        submittedHandOffCount += 1
        handOffContinuation.yield(HandOffRequest(ids: ids, action: action, generation: handOffRequested))
        OtosLog.ui.noticeOperation("handOff.submit", phase: "submitted", fields: [
            "count": "\(ids.count)", "action": action.verb, "generation": "\(handOffRequested)",
        ])
    }

    /// The status bar's Cancel: the hand-off being prepared stops and hands nothing over.
    func cancelHandOff() {
        guard let progress = handOffProgress else { return }
        handOffCancelledThrough = max(handOffCancelledThrough, progress.generation)
        handOffProgress = nil
        OtosLog.ui.noticeOperation("handOff.cancel", phase: "requested", fields: [
            "generation": "\(progress.generation)",
        ])
    }

    /// True once every submitted hand-off has been handed over, cancelled or failed.
    var hasSettledHandOffs: Bool {
        handledHandOffCount == submittedHandOffCount
    }

    func dismissHandOffAlert() {
        handOffAlertMessage = nil
    }

    func startHandOff(store: CatalogStore) {
        let preparer = handOffPreparer
        let reader = tileDetailReader
        handOffTask = Task { [weak self, handOffStream, preparer, reader] in
            for await request in handOffStream {
                defer { self?.handledHandOffCount += 1 }
                guard !Task.isCancelled else { break }
                let details: [MediaAssetID: MediaTileDetail]
                do {
                    details = try await reader.details(for: request.ids)
                } catch {
                    // The reader logged it; nothing is handed over for an unread target.
                    self?.failHandOff(request, failed: request.ids.count)
                    continue
                }
                let items = request.ids.map { Self.handOffItem($0, detail: details[$0]) }
                let pending = items.filter { $0.form != .original && preparer.readyURL(for: $0) == nil }.count
                self?.beginHandOffProgress(request, total: pending)
                var urls: [URL] = []
                var failed = 0
                var cancelled = false
                for item in items {
                    if let through = self?.handOffCancelledThrough, through >= request.generation {
                        cancelled = true
                        break
                    }
                    let needed = item.form != .original && preparer.readyURL(for: item) == nil
                    do {
                        try await urls.append(preparer.prepare(item))
                    } catch {
                        failed += 1
                    }
                    if needed {
                        self?.advanceHandOffProgress(request)
                    }
                }
                guard let self else { break }
                if cancelled || handOffCancelledThrough >= request.generation {
                    endHandOffProgress(request)
                    OtosLog.ui.noticeOperation("handOff.cancel", phase: "applied", fields: [
                        "generation": "\(request.generation)",
                    ])
                } else if failed > 0 {
                    failHandOff(request, failed: failed)
                } else {
                    completeHandOff(request, urls: urls)
                }
            }
        }
    }

    /// What a photo hands over follows from its catalog row; a target with no row (gone
    /// since it was chosen) hands over its path as it is, which is what Finder would.
    nonisolated static func handOffItem(_ id: MediaAssetID, detail: MediaTileDetail?) -> HandOffItem {
        HandOffItem(
            id: id,
            isVideo: detail?.bestKind == .video,
            recipe: detail?.editRecipe ?? .neutral,
            sourceSize: detail?.byteSize
        )
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

    private func failHandOff(_ request: HandOffRequest, failed: Int) {
        endHandOffProgress(request)
        handOffAlertMessage = failed == 1
            ? "One photo couldn’t be prepared, so nothing was handed over. Its original may be unavailable."
            : "\(failed) photos couldn’t be prepared, so nothing was handed over. Their originals may be unavailable."
        OtosLog.ui.errorOperation("handOff.complete", phase: "failed", fields: [
            "failed": "\(failed)", "count": "\(request.ids.count)", "action": request.action.verb,
        ])
    }

    private func completeHandOff(_ request: HandOffRequest, urls: [URL]) {
        endHandOffProgress(request)
        switch request.action {
        case let .copy(name):
            MediaGridClipboard.write(files: urls, to: NSPasteboard(name: name))
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
        }
        OtosLog.ui.noticeOperation("handOff.complete", phase: "handedOver", fields: [
            "count": "\(urls.count)", "action": request.action.verb, "generation": "\(request.generation)",
        ])
    }

    /// The drag pasteboard writer for one photo (ADR 0028, plan 0108 increment 13): the
    /// original's URL when it is handed over as itself, the file this launch already
    /// prepared when there is one, and otherwise a file promise that prepares it when the
    /// receiver asks. Synchronous, from the details the grid holds; a photo whose details it
    /// does not hold is promised, and the promise decides once it can read them.
    func dragWriter(for id: MediaAssetID) -> NSPasteboardWriting {
        let preparer = handOffPreparer
        if let detail = tileContentStore.content(for: id)?.detail {
            let item = Self.handOffItem(id, detail: detail)
            if let ready = preparer.readyURL(for: item) {
                return ready as NSURL
            }
            return HandOffPromise(item: item, preparer: preparer, reader: nil)
        }
        return HandOffPromise(item: nil, id: id, preparer: preparer, reader: tileDetailReader)
    }
}

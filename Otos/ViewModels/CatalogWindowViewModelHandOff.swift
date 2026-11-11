import AppKit
import Foundation
import OSLog

/// Hand-off intents guide
///
/// Copy (⌘C), Share and Open / Open With hand the current targets to another app as one
/// full-size file per photo (ADR 0037; `HandOffPreparer`). Reveal in Finder hands Finder
/// the originals themselves, never a rendered file. An edited photo or a RAW needs a file
/// rendered first, and an original a source stages (an Immich account's, a camera's) needs
/// fetching before it has a file, so every hand-off travels one ordered lane with one
/// consumer (`handOffStream`, lossless). The consumer:
/// 1. reads the targets' details;
/// 2. prepares what needs preparing, publishing `handOffProgress` (the status bar's
///    "Preparing 3 photos to copy", M of N, with Cancel);
/// 3. performs the action with the files: writes the pasteboard, shows the share picker,
///    opens the files, or reveals them in Finder.
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

    /// What the alert says did not happen, inside a sentence: "so nothing was handed over".
    var refusalClause: String {
        self == .revealInFinder ? "nothing was revealed" : "nothing was handed over"
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

    /// Submits a hand-off of the current targets to the lane.
    func handOff(_ action: HandOffAction) {
        let ids = targetIDs(.current)
        guard !ids.isEmpty else { return }
        handOffRequested &+= 1
        submittedHandOffCount += 1
        handOffContinuation.yield(HandOffRequest(ids: ids, action: action, generation: handOffRequested))
        OtosLog.ui.noticeOperation("handOff.submit", phase: "submitted", fields: [
            "count": "\(ids.count)", "action": action.verb, "generation": "\(handOffRequested)",
            "mode": viewMode.rawValue,
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
                    self?.failHandOff(request, failures: HandOffFailures(other: request.ids.count))
                    continue
                }
                let items = request.ids.map { EditedMediaItem(id: $0, detail: details[$0]) }
                let wanted = request.action.wanted
                // Asked once, before progress shows, so the status bar counts only photos
                // that take real work: a missing original no source can send takes none.
                var needed: [Bool] = []
                for item in items {
                    await needed.append(preparer.needsPreparation(item, as: wanted))
                }
                self?.beginHandOffProgress(request, total: needed.count(where: \.self))
                var urls: [URL] = []
                var failures = HandOffFailures()
                var cancelled = false
                for (item, itemNeeded) in zip(items, needed) {
                    if let through = self?.handOffCancelledThrough, through >= request.generation {
                        cancelled = true
                        break
                    }
                    do {
                        try await urls.append(preparer.prepare(item, as: wanted))
                    } catch HandOffPreparer.PrepareError.outOfSpace {
                        failures.outOfSpace += 1
                    } catch let HandOffPreparer.PrepareError.sourceUnavailable(reason) {
                        let root = item.id.libraryRootPath
                        failures.recordUnavailable(
                            rootPath: root, name: self?.sourceName(for: root) ?? root.rawValue, reason: reason
                        )
                    } catch {
                        failures.other += 1
                    }
                    if itemNeeded {
                        self?.advanceHandOffProgress(request)
                    }
                }
                guard let self else { break }
                if cancelled || handOffCancelledThrough >= request.generation {
                    endHandOffProgress(request)
                    OtosLog.ui.noticeOperation("handOff.cancel", phase: "applied", fields: [
                        "generation": "\(request.generation)",
                    ])
                } else if !failures.isEmpty {
                    failHandOff(request, failures: failures)
                } else {
                    completeHandOff(request, urls: urls)
                }
            }
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

    private func failHandOff(_ request: HandOffRequest, failures: HandOffFailures) {
        endHandOffProgress(request)
        handOffAlertMessage = failures.alertMessage(for: request.action)
        OtosLog.ui.errorOperation("handOff.complete", phase: "failed", fields: [
            "failed": "\(failures.count)",
            "outOfSpace": "\(failures.outOfSpace)",
            "sourceUnavailable": "\(failures.unavailable.reduce(0) { $0 + $1.count })",
            "count": "\(request.ids.count)",
            "action": request.action.verb,
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
        case .revealInFinder:
            workspace.revealInFinder(urls)
            OtosLog.ui.notice("op=ui.revealInFinder count=\(urls.count, privacy: .public)")
        }
        OtosLog.ui.noticeOperation("handOff.complete", phase: "handedOver", fields: [
            "count": "\(urls.count)", "action": request.action.verb, "generation": "\(request.generation)",
        ])
    }

    /// The name the sidebar shows for a library or removable source.
    func sourceName(for rootPath: LibraryRootPath) -> String? {
        (state.libraries + state.removableSources).first { $0.path == rootPath }?.displayName
    }

    /// The drag pasteboard writer for one photo (ADR 0028, ADR 0037): the
    /// original's URL when it is handed over as itself, the file this launch already
    /// prepared when there is one, and otherwise a file promise that prepares it when the
    /// receiver asks. Synchronous, from the details the grid holds; a photo whose details it
    /// does not hold is promised, and the promise decides once it can read them.
    func dragWriter(for id: MediaAssetID) -> NSPasteboardWriting {
        let preparer = handOffPreparer
        if let detail = tileContentStore.content(for: id)?.detail {
            let item = EditedMediaItem(id: id, detail: detail)
            if let ready = preparer.readyURL(for: item) {
                return ready as NSURL
            }
            return HandOffPromise(item: item, preparer: preparer, reader: nil)
        }
        return HandOffPromise(item: nil, id: id, preparer: preparer, reader: tileDetailReader)
    }
}

/// Why a hand-off's photos could not be prepared, counted by cause, and what the alert
/// says about them: a full disk is named as one, never as an unavailable original, and a
/// source that cannot send an original is named by the name the sidebar shows (ADR 0046 §6).
nonisolated struct HandOffFailures: Equatable, Sendable {
    var outOfSpace = 0
    var other = 0
    /// Photos whose originals their source could not send, by source, in the order met.
    private(set) var unavailable: [UnavailableSource] = []

    struct UnavailableSource: Equatable, Sendable {
        let rootPath: LibraryRootPath
        let name: String
        let reason: HandOffPreparer.SourceUnavailability
        var count: Int

        var sentence: String {
            let photos = count == 1 ? "one photo" : "\(count) photos"
            return switch reason {
            case .serverNotAnswering: "“\(name)” isn’t answering, so \(photos) couldn’t be downloaded."
            case .cameraDisconnected: "“\(name)” isn’t connected, so \(photos) couldn’t be copied from it."
            }
        }
    }

    mutating func recordUnavailable(
        rootPath: LibraryRootPath,
        name: String,
        reason: HandOffPreparer.SourceUnavailability
    ) {
        if let index = unavailable.firstIndex(where: { $0.rootPath == rootPath && $0.reason == reason }) {
            unavailable[index].count += 1
        } else {
            unavailable.append(UnavailableSource(rootPath: rootPath, name: name, reason: reason, count: 1))
        }
    }

    var count: Int {
        outOfSpace + other + unavailable.reduce(0) { $0 + $1.count }
    }

    var isEmpty: Bool {
        outOfSpace == 0 && other == 0 && unavailable.isEmpty
    }

    /// The alert's message for `action`, which says what did not happen.
    func alertMessage(for action: HandOffAction) -> String {
        let sources = unavailable.map(\.sentence).joined(separator: " ")
        guard outOfSpace + other > 0 else {
            return sources + " " + action.refusalSentence
        }
        let preparation = preparationMessage(for: action)
        return sources.isEmpty ? preparation : sources + " " + preparation
    }

    /// What the alert says about the photos that failed on this Mac.
    private func preparationMessage(for action: HandOffAction) -> String {
        let nothing = action.refusalClause
        let photos = { (count: Int) in count == 1 ? "one photo" : "\(count) photos" }
        switch (outOfSpace, other) {
        case (0, 1):
            return "One photo couldn’t be prepared, so \(nothing). Its original may be unavailable."
        case let (0, other):
            return "\(other) photos couldn’t be prepared, so \(nothing). Their originals may be unavailable."
        case let (outOfSpace, 0):
            return "There isn’t enough disk space to prepare \(photos(outOfSpace)), so \(nothing). "
                + "Free up space and try again."
        case let (outOfSpace, other):
            return "There isn’t enough disk space to prepare \(photos(outOfSpace)), and \(photos(other)) couldn’t be "
                + "prepared because \(other == 1 ? "its original" : "their originals") may be unavailable. "
                + "\(action.refusalSentence) Free up space and try again."
        }
    }
}

import AVFoundation
import Foundation
import OSLog

// On This Day and its story player (ADR 0049)
//
// Today. The ViewModel owns `today`, the day On This Day asks about. It is read at init
// and again whenever the platform reports the calendar day or the system time zone
// changed (`NSCalendarDayChanged`, `NSSystemTimeZoneDidChange`): no timer stands in for
// midnight, since the platform reports it (ADR 0033). Each report rings a newest-wins
// doorbell whose one consumer reads the day and applies it synchronously (ADR 0032); a day
// that moved re-selects On This Day for the new day through the ordinary selection intent,
// so the scope re-queries like any scope change.
//
// The story. A story plays the On This Day scope's items in the scope's own order with the
// loupe's own machinery: `viewMode` is `.loupe` while it plays and the story's item *is*
// `focusedAssetID` — one owner, so the story keeps no copy that a Move to Trash successor
// or a reorganization remap could leave behind. The picture, the video and their
// downloads come from the loupe's pane slot, `loupeVideoState` and the shared
// materialization coordinator at interactive priority; there is no second decoder or
// player owner. Photo commands and the inspector act on the item through the loupe's own
// target. What the story adds is its timing (`story`): a still holds 5 s from when its
// picture is on screen, a video advances when its player reports the end (or holds like a
// still when it reports a failure), and nothing advances while bytes are awaited.
// `StoryPlaybackPolicy` decides each move; this file applies it.
//
// Every focus change is a visit (`focusVisit`), and `setFocus` starts the story's state
// over for it (`beginStoryVisit`). Every report — the pane's, the kind read's, the
// player's, the hold's — carries the visit it was made for and is dropped for any other,
// so a late report from an earlier visit of the same item moves nothing. A read that fails
// leaves the story waiting and says so (`op=story.stalled`); it never stands in a value.

extension CatalogWindowViewModel {
    // MARK: - Scope

    /// Whether the detail pane is On This Day's anniversaries, or the story over them. Read from
    /// the published scope, as `showsPlacesMap` is.
    var showsOnThisDay: Bool {
        state.detailSurface == .onThisDay
    }

    /// Today, while the On This Day row exists: whenever the Places row does.
    var onThisDayRowDay: CalendarDay? {
        showsPlacesRow ? today : nil
    }

    /// Whether the sort control acts. A scope that fixes its own order — On This Day plays
    /// newest first — disables it in place (DES-053, DES-038).
    var canChangeSort: Bool {
        queryDescriptor.scope.fixedSort == nil
    }

    // MARK: - Today

    func startCalendarDayMonitoring() {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        calendarDayContinuation = continuation
        // The platform callbacks only ring the doorbell; the consumer reads the day.
        calendarDayObservers = [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange].map { name in
            calendarNotificationCenter.addObserver(forName: name, object: nil, queue: nil) { _ in
                continuation.yield()
            }
        }
        calendarDayTask = Task { [weak self] in
            for await _ in stream {
                guard let self else {
                    return
                }
                // A zone change leaves the cached system zone stale until it is reset.
                NSTimeZone.resetSystemTimeZone()
                applyCalendarDay(calendarDayReader())
            }
        }
    }

    /// The platform reported a calendar change and `day` is today now. A story closes,
    /// and On This Day, if selected, moves to the new day.
    func applyCalendarDay(_ day: CalendarDay) {
        guard day != today else {
            OtosLog.ui.noticeOperation("onThisDay.day", phase: "unchanged", fields: [
                "day": day.diagnosticDescription,
            ])
            return
        }
        let previous = today
        today = day
        OtosLog.ui.noticeOperation("onThisDay.day", phase: "changed", fields: [
            "from": previous.diagnosticDescription,
            "to": day.diagnosticDescription,
        ])
        guard case .onThisDay = queryDescriptor.scope else {
            return
        }
        closeStory(reason: "dayChanged")
        applyAutomaticSidebarSelection(.onThisDay(day))
    }

    // MARK: - Applying state

    /// A story ends when its scope does; the scope's anniversaries are its one presentation, so a
    /// loupe or compare left open in another scope closes on entering it.
    ///
    /// The anniversaries' covers are this pane's visible items, so they are pinned in the shared
    /// tile store exactly as the grid pins its visible tiles (`pinVisible`, ADR 0006): no
    /// budget pressure — a story's pictures warming the store included — can drop a cover
    /// already painted, and a card made again after the story closes paints it at once.
    /// Leaving the scope releases them; the next grid pass pins its own.
    func applyOnThisDayState(previous: CatalogWindowState, next: CatalogWindowState) {
        if let onThisDay = next.onThisDay {
            tileContentStore.pinVisible(Set(onThisDay.anniversaries.map(\.keyItem)))
        } else if previous.onThisDay != nil {
            tileContentStore.pinVisible([])
        }
        if next.onThisDay != previous.onThisDay || next.mediaGrid.orderedAssetIDs != previous.mediaGrid.orderedAssetIDs {
            anniversaryTitleRequests?.yield(Self.titledAnniversaries(next))
        }
        let scopeChanged = previous.mediaGrid.descriptor.scope != next.mediaGrid.descriptor.scope
        if story != nil, scopeChanged {
            closeStory(reason: "scopeChanged")
        }
        if story == nil, viewMode != .grid, case .onThisDay = next.resolvedSidebarSelection,
           case .onThisDay = queryDescriptor.scope
        {
            exitToGrid()
        }
        if scopeChanged, let onThisDay = next.onThisDay {
            OtosLog.ui.noticeOperation("onThisDay.scope", phase: "entered", fields: [
                "day": onThisDay.day.diagnosticDescription,
                "unit": onThisDay.isYears ? "years" : "months",
                "anniversaries": "\(onThisDay.anniversaries.count)",
                "items": "\(onThisDay.itemCount)",
            ])
        }
    }

    /// The anniversaries `state` shows, as On This Day's titles are written for them: none
    /// outside the scope.
    nonisolated static func titledAnniversaries(_ state: CatalogWindowState) -> [AnniversaryTitleWriter.Anniversary] {
        guard let onThisDay = state.onThisDay else { return [] }
        let ordered = state.mediaGrid.orderedAssetIDs
        return onThisDay.anniversaries.compactMap { anniversary in
            guard anniversary.indexes.upperBound <= ordered.count else { return nil }
            return AnniversaryTitleWriter.Anniversary(
                day: anniversary.day,
                ago: OnThisDayPresentation.ago(anniversary, today: onThisDay.day),
                items: Array(ordered[anniversary.indexes])
            )
        }
    }

    /// Hands the anniversaries shown to the title writer, newest wins, and assigns the titles
    /// it publishes (ADR 0053). One forwarding loop and one consumer, both children of one
    /// task the window owns; they hold the view model weakly and end with it.
    func startAnniversaryTitles() {
        guard let writer = anniversaryTitleWriter else { return }
        let (requests, continuation) = AsyncStream<[AnniversaryTitleWriter.Anniversary]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        anniversaryTitleRequests = continuation
        anniversaryTitleTask = Task { [weak self] in
            await withDiscardingTaskGroup { group in
                group.addTask {
                    for await anniversaries in requests {
                        await writer.show(anniversaries)
                    }
                }
                for await titles in await writer.titles() {
                    guard !Task.isCancelled, let self else { break }
                    if self.anniversaryTitles != titles {
                        self.anniversaryTitles = titles
                    }
                }
                group.cancelAll()
            }
        }
    }

    /// The scope's items changed under a playing story (a late import, a Move to Trash, a
    /// filter): focus stays on its item while it remains, else moves to the loupe's
    /// survivor, and the story closes when nothing remains.
    func reconcileStoryAfterGridChange(previousOrder: CatalogGridContent) {
        guard story != nil, let current = focusedAssetID else {
            closeStory(reason: "noItem")
            return
        }
        guard let survivor = StoryPlaybackPolicy.survivor(
            of: current,
            previousOrderedIDs: previousOrder,
            survivingOrderedIDs: state.mediaGrid.content
        ) else {
            closeStory(reason: "empty")
            return
        }
        guard survivor != current else {
            return
        }
        showStoryItem(survivor, reason: "removed")
    }

    // MARK: - Intents

    /// The item the story shows: the loupe's focus while a story plays.
    var storyItem: MediaAssetID? {
        story == nil ? nil : focusedAssetID
    }

    /// Whether View ▸ Play Story acts: On This Day shows at least one anniversary and no
    /// story plays.
    var canPlayStory: Bool {
        showsOnThisDay && showsSelectedScope && story == nil && state.onThisDay?.anniversaries.isEmpty == false
    }

    /// View ▸ Play Story (⌘Return): from the newest anniversary.
    func playStory() {
        playStory(anniversary: nil)
    }

    /// An anniversary in the collection was clicked, or Return / Space pressed on it: its
    /// story, from its first item, continuing into older ones.
    func playStory(anniversary: CalendarDay?) {
        guard canPlayStory, let onThisDay = state.onThisDay,
              let first = StoryPlaybackPolicy.start(
                  anniversary: anniversary,
                  anniversaries: onThisDay.anniversaries,
                  orderedIDs: state.mediaGrid.orderedAssetIDs
              )
        else {
            return
        }
        comparePair = .empty
        lastReplacedComparePane = nil
        viewMode = .loupe
        storySignpost = OtosSignpost.ui.beginInterval("StoryPlayback")
        // The visit is set by the focus change below.
        story = StoryPlayback(visit: focusVisit)
        OtosLog.ui.noticeOperation("story.start", phase: "applied", fields: [
            "anniversary": anniversary?.diagnosticDescription ?? "newest",
            "items": "\(state.mediaGrid.orderedAssetIDs.count)",
            "anniversaries": "\(onThisDay.anniversaries.count)",
        ])
        focusStoryItem(first)
    }

    /// → and the player's Next: the next item, across anniversaries.
    func storyNext() {
        guard let current = storyItem,
              let next = StoryPlaybackPolicy.next(after: current, in: state.mediaGrid.orderedAssetIDs)
        else {
            return
        }
        showStoryItem(next, reason: "next")
    }

    /// ← and the player's Previous: the item before, across anniversaries.
    func storyPrevious() {
        guard let current = storyItem,
              let previous = StoryPlaybackPolicy.previous(before: current, in: state.mediaGrid.orderedAssetIDs)
        else {
            return
        }
        showStoryItem(previous, reason: "previous")
    }

    var canStoryNext: Bool {
        storyItem.flatMap { StoryPlaybackPolicy.next(after: $0, in: state.mediaGrid.orderedAssetIDs) } != nil
    }

    var canStoryPrevious: Bool {
        storyItem.flatMap { StoryPlaybackPolicy.previous(before: $0, in: state.mediaGrid.orderedAssetIDs) } != nil
    }

    /// Whether Play / Pause acts: not after the last item has finished.
    var canToggleStoryPause: Bool {
        story.map { !$0.hasEnded } ?? false
    }

    /// Space and the player's Pause / Play. Pausing freezes the hold's remainder and the
    /// video; playing resumes both.
    func toggleStoryPause() {
        guard var story, !story.hasEnded else {
            return
        }
        let now = ContinuousClock.now
        story.isPaused.toggle()
        let playsVideo = loupeVideoState?.id == focusedAssetID && story.video == .playing
        if story.isPaused {
            story.hold = story.hold?.pausing(at: now)
            storyHoldTask?.cancel()
            storyHoldTask = nil
            if playsVideo {
                loupeVideoState?.player.pause()
                loupeVideoState?.isPlaying = false
            }
        } else {
            story.hold = story.hold?.resuming(at: now)
            if playsVideo {
                loupeVideoState?.player.play()
                loupeVideoState?.isPlaying = true
            }
        }
        self.story = story
        OtosLog.ui.noticeOperation("story.pause", phase: story.isPaused ? "paused" : "playing", fields: [
            "id": focusedAssetID?.relativePath.rawValue ?? "none",
        ])
        if !story.isPaused, let hold = story.hold {
            scheduleStoryHold(hold.remaining, visit: story.visit)
        }
    }

    /// Esc and the player's Close: back to the anniversaries, with keyboard focus on the one
    /// the story was on and its item selected.
    func closeStory() {
        closeStory(reason: "user")
    }

    func closeStory(reason: String) {
        guard story != nil else {
            return
        }
        let current = focusedAssetID
        let anniversary = current.flatMap { id in
            state.onThisDay.flatMap { onThisDay in
                StoryPlaybackPolicy.place(
                    of: id,
                    anniversaries: onThisDay.anniversaries,
                    orderedIDs: state.mediaGrid.orderedAssetIDs
                )?.anniversary.day
            }
        }
        cancelStoryWaits()
        story = nil
        exitToGrid()
        if let anniversary {
            onThisDayFocusRequest = OnThisDayFocusRequest(
                anniversary: anniversary,
                revision: (onThisDayFocusRequest?.revision ?? 0) &+ 1
            )
        }
        if let storySignpost {
            OtosSignpost.ui.endInterval("StoryPlayback", storySignpost)
            self.storySignpost = nil
        }
        OtosLog.ui.noticeOperation("story.close", phase: "applied", fields: [
            "reason": reason,
            "id": current?.relativePath.rawValue ?? "none",
            "anniversary": anniversary?.diagnosticDescription ?? "none",
        ])
    }

    // MARK: - Visits

    /// `setFocus` moved focus: a playing story starts this visit over, keeping only
    /// whether it is paused. A picture already decoded for the item (a step back to it) is
    /// on screen at once.
    func beginStoryVisit() {
        guard let story else {
            return
        }
        cancelStoryWaits()
        guard let current = focusedAssetID else {
            closeStory(reason: "noItem")
            return
        }
        self.story = StoryPlayback(visit: focusVisit, isPaused: story.isPaused)
        if panePreviews[.loupe]?.id == current {
            storyPaneSettled(visit: focusVisit, pane: .shown)
        }
    }

    // MARK: - Reports

    /// The story's state for `visit`, or nil when the report belongs to another visit.
    private func story(for visit: UInt64) -> StoryPlayback? {
        guard let story, story.visit == visit, focusedAssetID != nil else {
            return nil
        }
        return story
    }

    /// The loupe's pane request for this visit finished: its picture is on screen, or
    /// there is none to show.
    func storyPaneSettled(visit: UInt64, pane: StoryPane) {
        guard var story = story(for: visit), story.pane == .awaited else {
            return
        }
        story.pane = pane
        self.story = story
        startStoryHoldIfReady()
    }

    /// The focused item's kind is known.
    func storyKindResolved(visit: UInt64) {
        guard var story = story(for: visit) else {
            return
        }
        if focusedAssetKind == .video, story.video == .notVideo {
            story.video = .preparing
            self.story = story
        }
        startStoryHoldIfReady()
    }

    /// The loupe prepared the current video's player: it plays now unless the story is
    /// paused, and its end or failure is awaited. A hold started before the player was
    /// known (none should be) ends: a video plays to its own end.
    func storyVideoReady(_ prepared: LoupeVideoState, visit: UInt64) {
        guard var story = story(for: visit), prepared.id == focusedAssetID else {
            return
        }
        storyHoldTask?.cancel()
        storyHoldTask = nil
        story.hold = nil
        story.video = .playing
        self.story = story
        let player = prepared.player
        // Observed before it plays, so a short video cannot end unseen.
        let reports = StoryVideoReports(item: player.currentItem)
        if !story.isPaused {
            player.play()
            loupeVideoState?.isPlaying = true
        }
        storyVideoWatchTask?.cancel()
        storyVideoWatchTask = Task { [weak self] in
            let outcome = await reports.first()
            guard !Task.isCancelled, let self, let outcome else {
                return
            }
            switch outcome {
            case .ended: storyVideoEnded(visit: visit)
            case .failed: storyVideoFailed(visit: visit)
            }
        }
        OtosLog.ui.noticeOperation("story.video", phase: story.isPaused ? "readyPaused" : "playing", fields: [
            "id": prepared.id.relativePath.rawValue,
        ])
    }

    /// The current video can have no player: it holds like a still.
    func storyVideoUnavailable(visit: UInt64) {
        guard var story = story(for: visit) else {
            return
        }
        story.video = .unavailable
        self.story = story
        OtosLog.ui.noticeOperation("story.video", phase: "unavailable", fields: [
            "id": focusedAssetID?.relativePath.rawValue ?? "none",
        ])
        startStoryHoldIfReady()
    }

    /// The player reported it cannot play the current video to its end: the player goes,
    /// the poster stays, and the item holds like a still.
    func storyVideoFailed(visit: UInt64) {
        guard story(for: visit) != nil else {
            return
        }
        clearLoupeVideo()
        storyVideoUnavailable(visit: visit)
    }

    /// The player reported the current video reached its end.
    func storyVideoEnded(visit: UInt64) {
        guard story(for: visit) != nil else {
            return
        }
        advanceStory(reason: "videoEnd")
    }

    /// The current still's hold ran out.
    func storyHoldElapsed(visit: UInt64) {
        guard let story = story(for: visit), !story.isPaused, story.hold != nil else {
            return
        }
        advanceStory(reason: "hold")
    }

    /// A read the story waits on failed for this visit: the story waits on, and says so.
    /// Nothing stands in for the value; the next visit reads again.
    func storyStalled(visit: UInt64, reason: String, error: any Error) {
        guard story(for: visit) != nil else {
            return
        }
        OtosLog.ui.errorOperation("story.stalled", phase: "readFailed", fields: [
            "reason": reason,
            "id": focusedAssetID?.relativePath.rawValue ?? "none",
            "error": String(describing: error),
        ])
    }

    // MARK: - Moving

    private func advanceStory(reason: String) {
        guard var story, let current = focusedAssetID else {
            return
        }
        if let next = StoryPlaybackPolicy.next(after: current, in: state.mediaGrid.orderedAssetIDs) {
            showStoryItem(next, reason: reason)
            return
        }
        // The last item stays on screen, paused, its segment full.
        cancelStoryWaits()
        story.hasEnded = true
        story.isPaused = true
        story.hold = story.hold?.pausing(at: .now)
        self.story = story
        OtosLog.ui.noticeOperation("story.end", phase: "applied", fields: [
            "reason": reason,
            "id": current.relativePath.rawValue,
        ])
    }

    /// Moves the story to `id` by moving focus.
    private func showStoryItem(_ id: MediaAssetID, reason: String) {
        let position = state.onThisDay.flatMap { onThisDay in
            StoryPlaybackPolicy.place(of: id, anniversaries: onThisDay.anniversaries, orderedIDs: state.mediaGrid.orderedAssetIDs)
        }
        OtosLog.ui.noticeOperation("story.advance", phase: "applied", fields: [
            "reason": reason,
            "id": id.relativePath.rawValue,
            "anniversary": position.map(\.anniversary.day.diagnosticDescription) ?? "none",
            "position": position.map { "\($0.position)/\($0.anniversary.count)" } ?? "none",
        ])
        focusStoryItem(id)
    }

    private func focusStoryItem(_ id: MediaAssetID) {
        gridSelection = gridSelection.plainClick(id)
        setFocus(id)
    }

    private func startStoryHoldIfReady() {
        guard var story, story.hold == nil, !story.hasEnded,
              StoryPlaybackPolicy.holdCanStart(kind: focusedAssetKind, pane: story.pane, video: story.video)
        else {
            return
        }
        let hold = StoryHold(startingAt: story.isPaused ? nil : .now)
        story.hold = hold
        self.story = story
        OtosLog.ui.noticeOperation("story.hold", phase: "started", fields: [
            "id": focusedAssetID?.relativePath.rawValue ?? "none",
            "pane": story.pane == .shown ? "picture" : "none",
            "paused": "\(story.isPaused)",
        ])
        if !story.isPaused {
            scheduleStoryHold(hold.remaining, visit: story.visit)
        }
    }

    private func scheduleStoryHold(_ remaining: Duration, visit: UInt64) {
        storyHoldTask?.cancel()
        storyHoldTask = Task { [weak self] in
            do {
                // time: schedule — a still holds for a duration the product defines (ADR 0049).
                try await Task.sleep(for: remaining)
            } catch {
                // Cancelled: the item changed, or the story paused or closed.
                return
            }
            self?.storyHoldElapsed(visit: visit)
        }
    }

    private func cancelStoryWaits() {
        storyHoldTask?.cancel()
        storyHoldTask = nil
        storyVideoWatchTask?.cancel()
        storyVideoWatchTask = nil
    }
}

/// What a story waits to hear from a video's player: it played to its end, or it cannot.
/// The platform reports — `didPlayToEndTime`, `failedToPlayToEndTime` and a change of the
/// item's `status` — each ring one stream from their callbacks, which run on whatever
/// thread delivers them and touch nothing but the stream; the waiter, on the main actor,
/// reads the item's status itself when told it changed (KVO's own `newValue` arrives nil for
/// this property). Registered when this value is made, before the player plays, so a short
/// video cannot end unseen; every registration is removed when the answer is taken or the
/// wait is cancelled.
@MainActor
private final class StoryVideoReports {
    enum Outcome {
        case ended
        case failed
    }

    private enum Report {
        case ended
        case failed
        case statusChanged
    }

    private let item: AVPlayerItem?
    private let stream: AsyncStream<Report>
    private var observers: [any NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?

    init(item: AVPlayerItem?) {
        self.item = item
        let (stream, continuation) = AsyncStream<Report>.makeStream(bufferingPolicy: .unbounded)
        self.stream = stream
        guard let item else {
            return
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: nil) { _ in
                continuation.yield(.ended)
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: nil) { _ in
                continuation.yield(.failed)
            },
        ]
        statusObservation = item.observe(\.status, options: [.initial, .new]) { @Sendable _, _ in
            continuation.yield(.statusChanged)
        }
    }

    /// The first report that answers, or nil when the wait was cancelled. An item that is
    /// gone answers that it cannot play.
    func first() async -> Outcome? {
        defer { stopObserving() }
        guard let item else {
            return .failed
        }
        for await report in stream {
            switch report {
            case .ended:
                return .ended
            case .failed:
                return .failed
            case .statusChanged where item.status == .failed:
                return .failed
            case .statusChanged:
                continue
            }
        }
        return nil
    }

    private func stopObserving() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        statusObservation?.invalidate()
        statusObservation = nil
    }
}

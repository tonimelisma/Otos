import Foundation

/// One of the import bar's seven drawn states (`docs/design/import-bar.md` → State
/// inventory), fully resolved: every string, the middle zone's content, and the
/// primary action. The view switches on `middleZone`/`primaryAction` to render;
/// it does not compute copy or decide visibility itself.
nonisolated struct ImportBarDrawnState: Equatable, Sendable {
    enum StateKind: Equatable, Sendable {
        case preparing, noDestination, ready, needsAttention, working, done, failed
    }

    enum SecondaryLine: Equatable, Sendable {
        case none
        case plain(String)
        /// The orange-badge clause plus its "Show them" reveal (states D and
        /// F-incomplete). The badge carries a glyph, never colour alone
        /// (DES-029). `itemIDs` is what `revealLabel` selects and scrolls.
        case attention(clause: String, revealLabel: String, itemIDs: [MediaAssetID])
    }

    /// The glyph beside `primaryLine`, if any. `.attention` is the orange "!"
    /// circle the mockup uses for F's incomplete variant — the same visual
    /// language as D's badge, just on L1 instead of L3.
    enum PrimaryBadge: Equatable, Sendable {
        case none
        case checkmark
        case attention
    }

    enum ProgressTrack: Equatable, Sendable {
        case indeterminate
        case determinate(completed: Int64, total: Int64)
    }

    /// The bar's middle column. Exactly one of these per state — `.hidden` is the
    /// DES-053 exception for a control whose subject no longer exists (empty card,
    /// card gone), never an empty `.choices`.
    ///
    /// `.choices` carries the Preparing track above its two control rows while
    /// the card is being checked: the destination and the per-run checkboxes are
    /// usable from the first frame, because choosing costs nothing — the plan
    /// rebuilds against the choice — and a control that only appears at Ready
    /// would move between states (DES-053; `import-bar.md` state A, mockup 2b).
    /// `.progress` is Working's zone: a track with the destination caption and
    /// no choices, because the run has already consumed them.
    enum MiddleZone: Equatable, Sendable {
        case choices(track: ProgressTrack?, eraseEnabled: Bool, eraseDisabledReason: String?)
        case addLibraryButton
        case progress(track: ProgressTrack, caption: String?)
        case hidden
    }

    /// The bar's act. `.none` is the DES-053 exception applied to the act
    /// zone: a state that has no act left renders an empty zone rather than a
    /// button whose subject is gone or whose effect is already on screen. It is
    /// reached only by state F, and only where the user is by construction
    /// already looking at the items the bar is talking about.
    ///
    /// `.importNewItems` is one case whether or not it is enabled: its title is
    /// `Import` either way and `primaryEnabled` says which (DES-053, "a disabled
    /// primary action shall keep its position and its title"). The title carries
    /// no count — Otos imports everything new, so the number is L1's primary fact,
    /// not a scope the click chooses (DES-036). A click the coordinator is
    /// holding until the plan is ready (`presentation.importRequested`) is the
    /// same button disabled — the bar keeps saying what it knows.
    enum PrimaryAction: Equatable, Sendable {
        case none
        case importNewItems
        case ejectCard
        case eraseItems(count: Int)
        case cancel
        case tryAgain
    }

    let kind: StateKind
    let primaryLine: String
    let primaryBadge: PrimaryBadge
    let secondaryLine: SecondaryLine
    let middleZone: MiddleZone
    let primaryAction: PrimaryAction
    let primaryEnabled: Bool
    /// Whether an `.eraseItems` confirmation may state its second sentence
    /// ("All of them are already in X") — true only when the current plan
    /// proves every item is already in the destination: no blocked entries
    /// and, post-execution, no foreign skips or failures either
    /// (`import-bar.md` state F, "Erase-only run": "stated only when the plan
    /// proves it… otherwise it is omitted"). Meaningless where the primary
    /// action isn't `.eraseItems`; false everywhere that isn't provably clean.
    let eraseConfirmationProvenClean: Bool
}

/// Pure mapper from coordinator presentation to the import bar's drawn state
/// (`docs/design/import-bar.md`). No SwiftUI import: this is where the state
/// inventory table becomes code, and it holds every user-facing string. The view
/// (`ImportPlanFooter.swift`) renders this value and derives nothing.
///
/// Two facts the presentation cannot carry are supplied by the caller, because
/// they are owned elsewhere: `sourceDisplayName` (state B) comes from the
/// catalog's removable-source row, and `preferences` (erase/eject checkbox
/// state) is the ViewModel's per-run session override merged over Settings.
nonisolated enum ImportBarPresentation {
    static func map(
        presentation: MediaOperationSourcePresentation,
        preferences: ImportPreferences,
        sourceDisplayName: String,
        isCancelling: Bool = false
    ) -> ImportBarDrawnState {
        let drawn = mapState(
            presentation: presentation,
            preferences: preferences,
            sourceDisplayName: sourceDisplayName,
            isCancelling: isCancelling
        )
        // A held click is not a state (`import-bar.md` row 7): the bar says
        // exactly what it would otherwise say, and the Import button — the
        // control that took the click — is disabled until the coordinator
        // begins the run. Nothing else changes, so the determinate count and
        // the choices stay where they were.
        guard presentation.importRequested, drawn.primaryAction == .importNewItems, drawn.primaryEnabled else {
            return drawn
        }
        return ImportBarDrawnState(
            kind: drawn.kind,
            primaryLine: drawn.primaryLine,
            primaryBadge: drawn.primaryBadge,
            secondaryLine: drawn.secondaryLine,
            middleZone: drawn.middleZone,
            primaryAction: drawn.primaryAction,
            primaryEnabled: false,
            eraseConfirmationProvenClean: drawn.eraseConfirmationProvenClean
        )
    }

    private static func mapState(
        presentation: MediaOperationSourcePresentation,
        preferences: ImportPreferences,
        sourceDisplayName: String,
        isCancelling: Bool
    ) -> ImportBarDrawnState {
        guard presentation.destinationPath != nil else {
            return noDestination(presentation: presentation, sourceDisplayName: sourceDisplayName)
        }
        switch presentation.state {
        case let .failed(reason, publishedCount):
            return failed(reason: reason, publishedCount: publishedCount, presentation: presentation)
        case let .planningFailed(reason):
            return planningFailed(reason: reason, presentation: presentation)
        case let .executing(progress):
            return working(progress: progress, isCancelling: isCancelling, presentation: presentation, preferences: preferences)
        default:
            break
        }
        // A stopped run outranks everything below: the re-plan's Ready would
        // otherwise swallow the fact that a run just ended early (J8 as
        // written today falls through to plain Ready), and the detached
        // snapshot's `.completed` would report it as an ordinary Done. A new
        // run's `.executing`/`.failed` above still win — they are the newer
        // fact about this attachment.
        if let stopReason = presentation.stopReason,
           let copiedJustNow = presentation.copiedJustNow,
           let plannedCount = presentation.plannedCount
        {
            return stopped(
                reason: stopReason,
                copiedCount: copiedJustNow,
                plannedCount: plannedCount,
                remainder: readyTotals(presentation.state),
                presentation: presentation,
                preferences: preferences
            )
        }
        switch presentation.state {
        case let .completed(summary, skippedForeignCount, failedCount, incompleteItems):
            return doneFromCompleted(
                summary: summary,
                skippedForeignCount: skippedForeignCount,
                failedCount: failedCount,
                incompleteItems: incompleteItems,
                presentation: presentation,
                preferences: preferences,
                eraseOutcome: presentation.eraseOutcome
            )
        default:
            break
        }
        // `copiedJustNow` persists across the post-settlement re-plan, so a card
        // that already imported everything keeps reading as Done rather than
        // reverting to C's "nothing new" wording once `state` moves on from
        // `.completed` (`import-bar.md` "F is derived, not remembered").
        if let copiedJustNow = presentation.copiedJustNow,
           let isFullyClean = presentation.isFullyClean,
           let (summary, attentionItems) = readyTotals(presentation.state),
           summary.copyCount == 0, summary.companionCopyCount == 0, attentionItems.isEmpty
        {
            return doneFromRebuilt(
                copiedJustNow: copiedJustNow,
                isFullyClean: isFullyClean,
                summary: summary,
                presentation: presentation,
                preferences: preferences
            )
        }
        if let (summary, attentionItems) = readyTotals(presentation.state), !attentionItems.isEmpty {
            return needsAttention(summary: summary, attentionItems: attentionItems, presentation: presentation)
        }
        if let (summary, _) = readyTotals(presentation.state) {
            return ready(summary: summary, presentation: presentation, preferences: preferences)
        }
        return preparing(state: presentation.state, sourceKind: presentation.sourceKind)
    }

    private static func readyTotals(
        _ state: MediaOperationSourceState
    ) -> (MediaOperationPlanTotals, [MediaAttentionItem])? {
        switch state {
        case let .ready(summary, _, _, attentionItems):
            (summary, attentionItems)
        case let .executionUnavailable(summary, _, attentionItems):
            (summary, attentionItems)
        default:
            nil
        }
    }

    // MARK: - A · Preparing

    private static func preparing(
        state: MediaOperationSourceState,
        sourceKind: LibraryRootKind
    ) -> ImportBarDrawnState {
        let itemsLine: String?
        let track: ImportBarDrawnState.ProgressTrack
        switch state {
        case let .waitingForMetadata(done, total):
            itemsLine = "\(done) of \(total) items"
            track = .determinate(completed: Int64(done), total: Int64(total))
        default:
            itemsLine = nil
            track = .indeterminate
        }
        let primaryLine = sourceKind == .deviceMTP ? "Checking the camera…" : "Checking the card…"
        let primaryAction: ImportBarDrawnState.PrimaryAction = .importNewItems
        // The choices are live while Otos checks: nothing about the check
        // depends on the destination or the checkboxes, and a pick made now is
        // what the first plan is built against. Erase is enabled because no
        // plan has yet found anything to hold it back; state D disables it once
        // one does.
        return ImportBarDrawnState(
            kind: .preparing,
            primaryLine: primaryLine,
            primaryBadge: .none,
            secondaryLine: itemsLine.map { ImportBarDrawnState.SecondaryLine.plain($0) } ?? .none,
            middleZone: .choices(track: track, eraseEnabled: true, eraseDisabledReason: nil),
            primaryAction: primaryAction,
            primaryEnabled: false,
            eraseConfirmationProvenClean: false
        )
    }

    // MARK: - B · No destination

    private static func noDestination(
        presentation: MediaOperationSourcePresentation,
        sourceDisplayName: String
    ) -> ImportBarDrawnState {
        var secondary: ImportBarDrawnState.SecondaryLine = .none
        if case let .waitingForMetadata(_, total) = presentation.state, total > 0 {
            secondary = .plain("\(total) \(total == 1 ? "item" : "items") on \(sourceDisplayName)")
        }
        return ImportBarDrawnState(
            kind: .noDestination,
            primaryLine: "Otos needs a library to copy into",
            primaryBadge: .none,
            secondaryLine: secondary,
            middleZone: .addLibraryButton,
            primaryAction: .importNewItems,
            primaryEnabled: false,
            eraseConfirmationProvenClean: false
        )
    }

    // MARK: - C · Ready (+ nothing-new, empty)

    private static func ready(
        summary: MediaOperationPlanTotals,
        presentation: MediaOperationSourcePresentation,
        preferences: ImportPreferences
    ) -> ImportBarDrawnState {
        // A destination path with no resolved display name yet (e.g. a
        // `librariesByPath` snapshot that hasn't caught up) falls back to a
        // true generic term rather than an empty-string substitution that
        // would build a broken sentence ("already in ").
        let destinationName = presentation.destinationDisplayName ?? "the library"
        if summary.copyCount == 0, summary.companionCopyCount == 0 {
            if summary.skipCount == 0 {
                return ImportBarDrawnState(
                    kind: .ready,
                    primaryLine: "This card is empty",
                    primaryBadge: .none,
                    secondaryLine: .none,
                    middleZone: .hidden,
                    primaryAction: .ejectCard,
                    primaryEnabled: true,
                    eraseConfirmationProvenClean: false
                )
            }
            let eraseChecked = preferences.deleteSourceAfterImport
            let action: ImportBarDrawnState.PrimaryAction = eraseChecked
                ? .eraseItems(count: summary.skipCount)
                : .ejectCard
            return ImportBarDrawnState(
                kind: .ready,
                primaryLine: "Nothing new on this card",
                primaryBadge: .none,
                secondaryLine: .plain(
                    "All \(summary.skipCount) \(summary.skipCount == 1 ? "item is" : "items are") already in \(destinationName)"
                ),
                middleZone: .choices(track: nil, eraseEnabled: true, eraseDisabledReason: nil),
                primaryAction: action,
                primaryEnabled: true,
                eraseConfirmationProvenClean: true
            )
        }
        let secondary: ImportBarDrawnState.SecondaryLine = if let advisory = spaceAdvisory(summary: summary, presentation: presentation) {
            .plain(advisory)
        } else if let already = alreadyInLibraryLine(skipCount: summary.skipCount, destinationName: destinationName) {
            .plain(already)
        } else {
            .none
        }
        return ImportBarDrawnState(
            kind: .ready,
            primaryLine: newItemsHeadline(summary: summary),
            primaryBadge: .none,
            secondaryLine: secondary,
            middleZone: .choices(track: nil, eraseEnabled: true, eraseDisabledReason: nil),
            primaryAction: .importNewItems,
            primaryEnabled: true,
            eraseConfirmationProvenClean: false
        )
    }

    /// State C's one line about room: shown only when the plan's bytes plus
    /// the floor exceed what the destination volume reported available at
    /// publish — two measured values and Otos's own stopping rule, not an
    /// estimate (DES-032 permits one estimate and this is not it). It gates
    /// nothing: the act stays `Import`, the run copies what fits and
    /// stops at the floor, and the Stopped bar states what happened. "Yet"
    /// is the resumable design in one word. Outranks the already-in-library
    /// clause because it changes what the click will do (DES-034: one clause).
    private static func spaceAdvisory(
        summary: MediaOperationPlanTotals,
        presentation: MediaOperationSourcePresentation
    ) -> String? {
        guard let available = presentation.destinationAvailableBytes,
              summary.copyBytes + FreeSpaceFloor.bytes > available
        else {
            return nil
        }
        return "Not everything will fit yet · \(ImportBarByteFormat.string(bytes: available)) available"
    }

    // MARK: - D · Ready, needs attention

    private static func needsAttention(
        summary: MediaOperationPlanTotals,
        attentionItems: [MediaAttentionItem],
        presentation: MediaOperationSourcePresentation
    ) -> ImportBarDrawnState {
        let destinationName = presentation.destinationDisplayName ?? "the library"
        let clause = attentionClause(items: attentionItems, destinationName: destinationName)
        // D's act is Import, for the items that are not blocked. When every
        // item is blocked there is nothing to import, and a button reading
        // `Import 0 Items` — drawn on 2026-09-13 over 368 blocked items — is a
        // control whose subject does not exist (DES-053): the act zone is empty.
        let action: ImportBarDrawnState.PrimaryAction = summary.copyCount > 0
            ? .importNewItems
            : .none
        return ImportBarDrawnState(
            kind: .needsAttention,
            primaryLine: newItemsHeadline(summary: summary),
            primaryBadge: .none,
            secondaryLine: .attention(clause: clause, revealLabel: "Show them", itemIDs: attentionItems.map(\.id)),
            middleZone: .choices(
                track: nil,
                eraseEnabled: false,
                eraseDisabledReason: "Some items still need attention."
            ),
            primaryAction: action,
            primaryEnabled: true,
            eraseConfirmationProvenClean: false
        )
    }

    /// Groups by case, not full equality: the destination-carrying cases carry
    /// a per-item path, so two instances of the same *cause* are never `==`.
    /// The clause names the cause, not the payload (state D, "the real cause").
    private enum AttentionCauseKind: Equatable {
        case noUsableDate
        case filesystemObservationUnavailable
        case noFreeDestinationName
        case sourceUnreadable
    }

    private static func causeKind(_ reason: MediaOperationBlockReason) -> AttentionCauseKind {
        switch reason {
        case .noUsableDate: .noUsableDate
        case .filesystemObservationUnavailable: .filesystemObservationUnavailable
        case .noFreeDestinationName: .noFreeDestinationName
        case .sourceUnreadable: .sourceUnreadable
        }
    }

    private static func attentionClause(items: [MediaAttentionItem], destinationName: String) -> String {
        let kinds = Set(items.map { causeKind($0.reason) })
        let count = items.count
        guard kinds.count == 1, let reason = items.first?.reason else {
            return count == 1 ? "1 item needs attention" : "\(count) items need attention"
        }
        switch reason {
        case .noUsableDate:
            return count == 1 ? "1 item has no date" : "\(count) items have no date"
        case .filesystemObservationUnavailable:
            // The coordinator never presents a plan built on an unread folder
            // (it retries the build instead), so this clause is the model's
            // completeness, not a state the bar expects to draw.
            let noun = count == 1 ? "name" : "names"
            return "Otos couldn't check \(count) \(noun) in \(destinationName)"
        case .noFreeDestinationName:
            return count == 1
                ? "Otos couldn't find a free name for 1 item in \(destinationName)"
                : "Otos couldn't find a free name for \(count) items in \(destinationName)"
        case .sourceUnreadable:
            // Names what the user can act on — the file will not copy either — without
            // the internal vocabulary DES-035 forbids.
            return count == 1 ? "1 item couldn't be read" : "\(count) items couldn't be read"
        }
    }

    // MARK: - E · Working

    private static func working(
        progress: MediaOperationProgress,
        isCancelling: Bool,
        presentation: MediaOperationSourcePresentation,
        preferences: ImportPreferences
    ) -> ImportBarDrawnState {
        if isCancelling {
            return ImportBarDrawnState(
                kind: .working,
                primaryLine: "Stopping…",
                primaryBadge: .none,
                secondaryLine: .plain("Finishing the current item"),
                middleZone: .progress(
                    track: .determinate(completed: Int64(progress.completedBytes), total: max(progress.totalBytes, 1)),
                    caption: nil
                ),
                primaryAction: .cancel,
                primaryEnabled: false,
                eraseConfirmationProvenClean: false
            )
        }
        var secondary = "\(ImportBarByteFormat.string(bytes: progress.completedBytes)) of \(ImportBarByteFormat.string(bytes: progress.totalBytes))"
        if let remaining = remainingTimeClause(progress: progress) {
            secondary += " · \(remaining)"
        }
        let destinationName = presentation.destinationDisplayName ?? "the library"
        var caption = "Into \(destinationName)"
        if preferences.autoEjectAfterImport {
            caption += " · the card ejects when it's done"
        }
        return ImportBarDrawnState(
            kind: .working,
            primaryLine: "Importing \(progress.completedCount) of \(progress.totalCount)",
            primaryBadge: .none,
            secondaryLine: .plain(secondary),
            middleZone: .progress(
                track: .determinate(completed: progress.completedBytes, total: max(progress.totalBytes, 1)),
                caption: caption
            ),
            primaryAction: .cancel,
            primaryEnabled: true,
            eraseConfirmationProvenClean: false
        )
    }

    /// Omitted until the run has produced enough data for a rate estimate to be
    /// honest (DES-032) rather than guessed. 2s/nonzero-bytes is a judgment call,
    /// not a spec number — the spec only says "omitted until meaningful."
    private static func remainingTimeClause(progress: MediaOperationProgress) -> String? {
        guard progress.elapsedMs >= 2000,
              progress.completedBytes > 0,
              progress.totalBytes > progress.completedBytes
        else {
            return nil
        }
        let rate = Double(progress.completedBytes) / Double(progress.elapsedMs)
        guard rate > 0 else { return nil }
        let remainingBytes = Double(progress.totalBytes - progress.completedBytes)
        let remainingSeconds = Int((remainingBytes / rate / 1000).rounded())
        guard remainingSeconds > 0 else { return nil }
        return "about \(remainingClause(seconds: remainingSeconds)) left"
    }

    /// Precision degrades with magnitude, so the estimate never states more than it knows
    /// (DES-032): seconds below a minute, whole minutes below an hour, hours and minutes
    /// above. A 38 GB card opened at `about 221 seconds left` before this — a figure the
    /// reader has to convert, and one whose trailing digits re-render every second while
    /// carrying no information a rate estimate can support.
    static func remainingClause(seconds: Int) -> String {
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = if seconds < 60 {
            [.seconds]
        } else if seconds < 3600 {
            [.minutes]
        } else {
            [.hours, .minutes]
        }
        return Duration.seconds(seconds).formatted(
            .units(allowed: allowed, width: .wide, maximumUnitCount: 2)
        )
    }

    // MARK: - F · Done

    private static func doneFromCompleted(
        summary: MediaOperationPlanTotals,
        skippedForeignCount: Int,
        failedCount: Int,
        incompleteItems: [MediaAssetID],
        presentation: MediaOperationSourcePresentation,
        preferences: ImportPreferences,
        eraseOutcome: EraseOutcome?
    ) -> ImportBarDrawnState {
        if let eraseOutcome, summary.copyCount == 0, summary.companionCopyCount == 0 {
            let failed = eraseOutcome.failedCount + eraseOutcome.skippedCount
            let itemWord = eraseOutcome.deletedCount == 1 ? "item" : "items"
            let isComplete = failed == 0
            return ImportBarDrawnState(
                kind: .done,
                primaryLine: isComplete
                    ? "Card erased · \(eraseOutcome.deletedCount) \(itemWord) deleted"
                    : "Card erase incomplete · \(eraseOutcome.deletedCount) \(itemWord) deleted",
                primaryBadge: isComplete ? .checkmark : .attention,
                secondaryLine: failed == 0
                    ? .none
                    : .plain("\(failed) \(failed == 1 ? "item" : "items") could not be deleted"),
                middleZone: .hidden,
                primaryAction: .ejectCard,
                primaryEnabled: true,
                eraseConfirmationProvenClean: false
            )
        }
        let isFullyClean = skippedForeignCount == 0 && failedCount == 0 && summary.blockedCount == 0
        let copiedCount = presentation.copiedJustNow ?? summary.copyCount
        let itemsInLibrary = summary.copyCount + summary.skipCount + summary.companionCopyCount
        return done(
            copiedCount: copiedCount,
            totalAttempted: summary.copyCount,
            itemsInLibrary: itemsInLibrary,
            isFullyClean: isFullyClean,
            incompleteItems: incompleteItems,
            presentation: presentation,
            preferences: preferences
        )
    }

    private static func doneFromRebuilt(
        copiedJustNow: Int,
        isFullyClean: Bool,
        summary: MediaOperationPlanTotals,
        presentation: MediaOperationSourcePresentation,
        preferences: ImportPreferences
    ) -> ImportBarDrawnState {
        let itemsInLibrary = summary.skipCount + summary.companionCopyCount
        return done(
            copiedCount: copiedJustNow,
            totalAttempted: copiedJustNow + presentation.incompleteItems.count,
            itemsInLibrary: itemsInLibrary,
            isFullyClean: isFullyClean,
            incompleteItems: presentation.incompleteItems,
            presentation: presentation,
            preferences: preferences
        )
    }

    // MARK: - F · Stopped

    /// A run that ended before attempting every entry it planned — the user's
    /// Cancel, or the disk floor (ADR 0027). Still F: a partial batch is a real
    /// batch and nothing already copied is lost. What differs is that the bar
    /// says the run stopped, from the run's own facts (`copiedJustNow` of
    /// `plannedCount`), names the cause at L3, and offers what is left. The
    /// remainder is the *re-plan's* `copyCount`, so the act reads a disabled
    /// `Import` for the moment the re-plan takes and the real number once it
    /// lands — never the pre-run plan's count, which the coordinator drops on
    /// a stop because that run has just made it false. This is the one F
    /// variant with a prominent act: its subject exists, the items are still
    /// on an attached card (`import-bar.md` state F, Stopped; J8). Identical
    /// on the card row and the batch row.
    private static func stopped(
        reason: ImportStopReason,
        copiedCount: Int,
        plannedCount: Int,
        remainder: (MediaOperationPlanTotals, [MediaAttentionItem])?,
        presentation: MediaOperationSourcePresentation,
        preferences: ImportPreferences
    ) -> ImportBarDrawnState {
        let destinationName = presentation.destinationDisplayName ?? "the library"
        let primaryLine = "Stopped — \(copiedCount) of \(plannedCount) \(plannedCount == 1 ? "item" : "items") copied"
        // Card gone: the sentence is about the result, and both the choices
        // and the act are omitted — their subject no longer exists (DES-053
        // exception), exactly as F's own card-gone variant does.
        guard presentation.cardStillExists else {
            return ImportBarDrawnState(
                kind: .done,
                primaryLine: primaryLine,
                primaryBadge: .none,
                secondaryLine: .plain("In \(destinationName) · card ejected — safe to remove"),
                middleZone: .hidden,
                primaryAction: .none,
                primaryEnabled: true,
                eraseConfirmationProvenClean: false
            )
        }
        let clause: String? = switch reason {
        case .user:
            copiedCount > 0 ? "They're in \(destinationName)" : nil
        case let .diskFloor(bytesFree):
            "Not enough room on the disk · \(ImportBarByteFormat.string(bytes: bytesFree)) left"
        }
        guard let (summary, attentionItems) = remainder else {
            // The re-plan has not landed yet: the act is coming, its count is not.
            return ImportBarDrawnState(
                kind: .done,
                primaryLine: primaryLine,
                primaryBadge: .none,
                secondaryLine: clause.map { .plain($0) } ?? .none,
                middleZone: .choices(track: nil, eraseEnabled: true, eraseDisabledReason: nil),
                primaryAction: .importNewItems,
                primaryEnabled: false,
                eraseConfirmationProvenClean: false
            )
        }
        // Attention items keep erase disabled for the same reason state D
        // does (DES-038); the stop stays the primary fact.
        let middleZone: ImportBarDrawnState.MiddleZone = .choices(
            track: nil,
            eraseEnabled: attentionItems.isEmpty,
            eraseDisabledReason: attentionItems.isEmpty ? nil : "Some items still need attention."
        )
        let action: ImportBarDrawnState.PrimaryAction = if summary.copyCount > 0 {
            .importNewItems
        } else if preferences.deleteSourceAfterImport {
            .eraseItems(count: summary.skipCount + summary.companionCopyCount)
        } else {
            .ejectCard
        }
        return ImportBarDrawnState(
            kind: .done,
            primaryLine: primaryLine,
            primaryBadge: .none,
            secondaryLine: clause.map { .plain($0) } ?? .none,
            middleZone: middleZone,
            primaryAction: action,
            primaryEnabled: true,
            eraseConfirmationProvenClean: false
        )
    }

    private static func done(
        copiedCount: Int,
        totalAttempted: Int,
        itemsInLibrary: Int,
        isFullyClean: Bool,
        incompleteItems: [MediaAssetID],
        presentation: MediaOperationSourcePresentation,
        preferences: ImportPreferences
    ) -> ImportBarDrawnState {
        let destinationName = presentation.destinationDisplayName ?? "the library"
        // F, incomplete (some items couldn't be copied): its own copy and
        // badge regardless of whether the card is still attached — neither
        // eject nor erase decides anything further here, just go look
        // (`import-bar.md` state F, mockup "F incomplete"). The looking is the
        // L3 `Show them` reveal, which selects the failed items in place; the
        // act zone is empty because a second, whole-batch "show" would only
        // navigate to what is already on screen.
        if !isFullyClean, !incompleteItems.isEmpty {
            return ImportBarDrawnState(
                kind: .done,
                primaryLine: "\(copiedCount) of \(totalAttempted) \(totalAttempted == 1 ? "item" : "items") copied",
                primaryBadge: .attention,
                secondaryLine: .attention(
                    clause: incompleteItems.count == 1 ? "1 item couldn't be copied" : "\(incompleteItems.count) items couldn't be copied",
                    revealLabel: "Show them",
                    itemIDs: incompleteItems
                ),
                middleZone: .hidden,
                primaryAction: .none,
                primaryEnabled: true,
                eraseConfirmationProvenClean: false
            )
        }
        // F, card gone. Both variants below have an empty act zone: eject and
        // erase address a card that no longer exists (DES-053's "subject no
        // longer exists" exception, the same one that hides the choices zone
        // here), and the batch the bar is reporting on is what the user is
        // already standing on — the selection followed the work there at
        // execution start, and follows it there on eject if they had walked
        // back to the card's row (`import-bar.md` "Where the user is standing").
        guard presentation.cardStillExists else {
            if isFullyClean {
                return ImportBarDrawnState(
                    kind: .done,
                    primaryLine: "\(copiedCount) \(copiedCount == 1 ? "item" : "items") copied and verified",
                    primaryBadge: .checkmark,
                    secondaryLine: .plain("In \(destinationName) · card ejected — safe to remove"),
                    middleZone: .hidden,
                    primaryAction: .none,
                    primaryEnabled: true,
                    eraseConfirmationProvenClean: false
                )
            }
            // Not fully clean, but nothing failed to copy — items are still
            // blocked from an earlier plan (state D) rather than incomplete
            // from this run. The card is already gone, so just report what
            // landed; there is no reveal to offer without a copy failure, and
            // no act either — the card the act would have addressed is gone.
            return ImportBarDrawnState(
                kind: .done,
                primaryLine: "\(copiedCount) \(copiedCount == 1 ? "item" : "items") copied",
                primaryBadge: .none,
                secondaryLine: .plain("In \(destinationName) · card ejected — safe to remove"),
                middleZone: .hidden,
                primaryAction: .none,
                primaryEnabled: true,
                eraseConfirmationProvenClean: false
            )
        }
        if !isFullyClean {
            // Same "still blocked, nothing failed to copy" case as above,
            // card still attached: eject/erase remain meaningful acts.
            let eraseChecked = preferences.deleteSourceAfterImport
            let action: ImportBarDrawnState.PrimaryAction = eraseChecked
                ? .eraseItems(count: itemsInLibrary)
                : .ejectCard
            return ImportBarDrawnState(
                kind: .done,
                primaryLine: "\(copiedCount) \(copiedCount == 1 ? "item" : "items") copied",
                primaryBadge: .none,
                secondaryLine: .plain(
                    "\(copiedCount) copied just now · \(itemsInLibrary) \(itemsInLibrary == 1 ? "item" : "items") in \(destinationName)"
                ),
                middleZone: .choices(track: nil, eraseEnabled: true, eraseDisabledReason: nil),
                primaryAction: action,
                primaryEnabled: true,
                eraseConfirmationProvenClean: false
            )
        }
        let eraseChecked = preferences.deleteSourceAfterImport
        let action: ImportBarDrawnState.PrimaryAction = eraseChecked
            ? .eraseItems(count: itemsInLibrary)
            : .ejectCard
        return ImportBarDrawnState(
            kind: .done,
            primaryLine: "Everything on this card is imported",
            primaryBadge: .checkmark,
            secondaryLine: .plain(
                "\(copiedCount) copied just now · \(itemsInLibrary) \(itemsInLibrary == 1 ? "item" : "items") in \(destinationName)"
            ),
            middleZone: .choices(track: nil, eraseEnabled: true, eraseDisabledReason: nil),
            primaryAction: action,
            primaryEnabled: true,
            eraseConfirmationProvenClean: true
        )
    }

    // MARK: - G · Failed

    private static func failed(
        reason: MediaOperationFailureReason,
        publishedCount: Int,
        presentation: MediaOperationSourcePresentation
    ) -> ImportBarDrawnState {
        var clauseParts: [String] = []
        if let cause = failureClause(
            reason: reason,
            destinationName: presentation.destinationDisplayName,
            sourceKind: presentation.sourceKind
        ) {
            clauseParts.append(cause)
        }
        if publishedCount > 0 {
            clauseParts.append("\(publishedCount) \(publishedCount == 1 ? "item was" : "items were") copied before it stopped")
        }
        return failedState(primaryLine: "Couldn't finish the import", clauseParts: clauseParts)
    }

    /// G, planning variant: the same zones and act as a run failure, with the
    /// stage named honestly — nothing was started, so nothing "couldn't finish".
    private static func planningFailed(
        reason: MediaOperationFailureReason,
        presentation: MediaOperationSourcePresentation
    ) -> ImportBarDrawnState {
        let cause = failureClause(
            reason: reason,
            destinationName: presentation.destinationDisplayName,
            sourceKind: presentation.sourceKind
        )
        return failedState(primaryLine: "Couldn't prepare the import", clauseParts: cause.map { [$0] } ?? [])
    }

    private static func failedState(primaryLine: String, clauseParts: [String]) -> ImportBarDrawnState {
        let secondary: ImportBarDrawnState.SecondaryLine = clauseParts.isEmpty
            ? .none
            : .plain(clauseParts.joined(separator: " · "))
        return ImportBarDrawnState(
            kind: .failed,
            primaryLine: primaryLine,
            primaryBadge: .none,
            secondaryLine: secondary,
            middleZone: .choices(track: nil, eraseEnabled: true, eraseDisabledReason: nil),
            primaryAction: .tryAgain,
            primaryEnabled: true,
            eraseConfirmationProvenClean: false
        )
    }

    private static func failureClause(
        reason: MediaOperationFailureReason,
        destinationName: String?,
        sourceKind: LibraryRootKind
    ) -> String? {
        switch reason {
        case .sourceRemoved:
            "The card was removed"
        case .destinationUnavailable:
            if let destinationName, !destinationName.isEmpty {
                "\(destinationName) isn't available"
            } else {
                "The library isn't available"
            }
        case .sourceNotReady:
            sourceKind == .deviceMTP ? "The camera is still reading its card" : "The card is still being read"
        case .unexpected:
            nil
        }
    }

    // MARK: - Shared copy

    private static func newItemsHeadline(summary: MediaOperationPlanTotals) -> String {
        "\(summary.copyCount) \(summary.copyCount == 1 ? "new item" : "new items") · \(ImportBarByteFormat.string(bytes: summary.copyBytes))"
    }

    private static func alreadyInLibraryLine(skipCount: Int, destinationName: String) -> String? {
        guard skipCount > 0 else { return nil }
        return "\(skipCount) already in \(destinationName)"
    }
}

/// Byte formatting per `import-bar.md` → Number formatting. Deliberately not
/// `ByteCountFormatter`: the spec's thresholds (whole MB under 100, GB with one
/// decimal under 100 GB) are exact and must be independent of locale/OS formatter
/// behavior so the mapper stays a pure, deterministic function.
nonisolated enum ImportBarByteFormat {
    static func string(bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_000_000
        if megabytes < 1 {
            let kilobytes = Int((Double(bytes) / 1000).rounded())
            return "\(kilobytes) KB"
        }
        if megabytes < 100 {
            return "\(Int(megabytes.rounded())) MB"
        }
        let gigabytes = megabytes / 1000
        if gigabytes < 100 {
            return String(format: "%.1f GB", gigabytes)
        }
        return "\(Int(gigabytes.rounded())) GB"
    }
}

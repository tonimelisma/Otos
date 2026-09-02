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
    enum MiddleZone: Equatable, Sendable {
        case choices(eraseEnabled: Bool, eraseDisabledReason: String?)
        case addLibraryButton
        case progress(track: ProgressTrack, caption: String?)
        case hidden
    }

    enum PrimaryAction: Equatable, Sendable {
        case importPending
        case importQueued
        case importItems(count: Int)
        case ejectCard
        case eraseItems(count: Int)
        case showTheseItems
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
    /// F-attached only: `Show These Items` as a secondary text button beside the
    /// primary `Eject Card`. F-gone promotes the same action to primary instead.
    let showsSecondaryShowItemsButton: Bool
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
        guard presentation.destinationPath != nil else {
            return noDestination(presentation: presentation, sourceDisplayName: sourceDisplayName)
        }
        switch presentation.state {
        case let .failed(reason, publishedCount):
            return failed(reason: reason, publishedCount: publishedCount, presentation: presentation)
        case let .executing(progress):
            return working(progress: progress, isCancelling: isCancelling, presentation: presentation, preferences: preferences)
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
        case .queuedForReadiness:
            itemsLine = nil
            track = .indeterminate
        default:
            itemsLine = nil
            track = .indeterminate
        }
        let primaryLine = sourceKind == .deviceMTP ? "Checking the camera…" : "Checking the card…"
        let primaryAction: ImportBarDrawnState.PrimaryAction = state == .queuedForReadiness
            ? .importQueued
            : .importPending
        return ImportBarDrawnState(
            kind: .preparing,
            primaryLine: primaryLine,
            primaryBadge: .none,
            secondaryLine: itemsLine.map { ImportBarDrawnState.SecondaryLine.plain($0) } ?? .none,
            middleZone: .progress(track: track, caption: nil),
            primaryAction: primaryAction,
            primaryEnabled: false,
            showsSecondaryShowItemsButton: false,
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
            primaryAction: .importPending,
            primaryEnabled: false,
            showsSecondaryShowItemsButton: false,
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
                    showsSecondaryShowItemsButton: false,
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
                middleZone: .choices(eraseEnabled: true, eraseDisabledReason: nil),
                primaryAction: action,
                primaryEnabled: true,
                showsSecondaryShowItemsButton: false,
                eraseConfirmationProvenClean: true
            )
        }
        return ImportBarDrawnState(
            kind: .ready,
            primaryLine: newItemsHeadline(summary: summary),
            primaryBadge: .none,
            secondaryLine: alreadyInLibraryLine(skipCount: summary.skipCount, destinationName: destinationName)
                .map { ImportBarDrawnState.SecondaryLine.plain($0) } ?? .none,
            middleZone: .choices(eraseEnabled: true, eraseDisabledReason: nil),
            primaryAction: .importItems(count: summary.copyCount),
            primaryEnabled: true,
            showsSecondaryShowItemsButton: false,
            eraseConfirmationProvenClean: false
        )
    }

    // MARK: - D · Ready, needs attention

    private static func needsAttention(
        summary: MediaOperationPlanTotals,
        attentionItems: [MediaAttentionItem],
        presentation: MediaOperationSourcePresentation
    ) -> ImportBarDrawnState {
        let destinationName = presentation.destinationDisplayName ?? "the library"
        let clause = attentionClause(items: attentionItems, destinationName: destinationName)
        return ImportBarDrawnState(
            kind: .needsAttention,
            primaryLine: newItemsHeadline(summary: summary),
            primaryBadge: .none,
            secondaryLine: .attention(clause: clause, revealLabel: "Show them", itemIDs: attentionItems.map(\.id)),
            middleZone: .choices(
                eraseEnabled: false,
                eraseDisabledReason: "Some items still need attention."
            ),
            primaryAction: .importItems(count: summary.copyCount),
            primaryEnabled: true,
            showsSecondaryShowItemsButton: false,
            eraseConfirmationProvenClean: false
        )
    }

    /// Groups by case, not full equality: `filesystemObservationUnavailable` carries a
    /// per-item destination/detail, so two instances of the same *cause* are never
    /// `==`. The clause names the cause, not the payload (state D, "the real cause").
    private enum AttentionCauseKind: Equatable {
        case noUsableDate
        case filesystemObservationUnavailable
        case sourceUnreadable
    }

    private static func causeKind(_ reason: MediaOperationBlockReason) -> AttentionCauseKind {
        switch reason {
        case .noUsableDate: .noUsableDate
        case .filesystemObservationUnavailable: .filesystemObservationUnavailable
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
            let noun = count == 1 ? "name" : "names"
            return "Otos couldn't check \(count) \(noun) in \(destinationName)"
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
                showsSecondaryShowItemsButton: false,
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
            showsSecondaryShowItemsButton: false,
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
                showsSecondaryShowItemsButton: false,
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
        // (`import-bar.md` state F, mockup "F incomplete").
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
                primaryAction: .showTheseItems,
                primaryEnabled: true,
                showsSecondaryShowItemsButton: false,
                eraseConfirmationProvenClean: false
            )
        }
        guard presentation.cardStillExists else {
            if isFullyClean {
                return ImportBarDrawnState(
                    kind: .done,
                    primaryLine: "\(copiedCount) \(copiedCount == 1 ? "item" : "items") copied and verified",
                    primaryBadge: .checkmark,
                    secondaryLine: .plain("In \(destinationName) · card ejected — safe to remove"),
                    middleZone: .hidden,
                    primaryAction: .showTheseItems,
                    primaryEnabled: true,
                    showsSecondaryShowItemsButton: false,
                    eraseConfirmationProvenClean: false
                )
            }
            // Not fully clean, but nothing failed to copy — items are still
            // blocked from an earlier plan (state D) rather than incomplete
            // from this run. The card is already gone, so just report what
            // landed; there is no reveal to offer without a copy failure.
            return ImportBarDrawnState(
                kind: .done,
                primaryLine: "\(copiedCount) \(copiedCount == 1 ? "item" : "items") copied",
                primaryBadge: .none,
                secondaryLine: .plain("In \(destinationName) · card ejected — safe to remove"),
                middleZone: .hidden,
                primaryAction: .showTheseItems,
                primaryEnabled: true,
                showsSecondaryShowItemsButton: false,
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
                middleZone: .choices(eraseEnabled: true, eraseDisabledReason: nil),
                primaryAction: action,
                primaryEnabled: true,
                showsSecondaryShowItemsButton: true,
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
            middleZone: .choices(eraseEnabled: true, eraseDisabledReason: nil),
            primaryAction: action,
            primaryEnabled: true,
            showsSecondaryShowItemsButton: true,
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
        let secondary: ImportBarDrawnState.SecondaryLine = clauseParts.isEmpty
            ? .none
            : .plain(clauseParts.joined(separator: " · "))
        return ImportBarDrawnState(
            kind: .failed,
            primaryLine: "Couldn't finish the import",
            primaryBadge: .none,
            secondaryLine: secondary,
            middleZone: .choices(eraseEnabled: true, eraseDisabledReason: nil),
            primaryAction: .tryAgain,
            primaryEnabled: true,
            showsSecondaryShowItemsButton: false,
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
        case .outOfSpace:
            "The disk is full"
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

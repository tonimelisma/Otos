import Foundation
@testable import OtosKit
import Testing

/// The mapper is the oracle for `docs/design/import-bar.md`'s state inventory
/// table: one test per row (plus its variants), asserting the exact drawn
/// state and strings — not the view's layout (`AGENTS.md` forbids
/// source-as-text assertions; this asserts the pure function's output).
struct ImportBarPresentationTests {
    private static let source = LibraryRootPath(rawValue: "/Volumes/CAMERA")
    private static let destination = LibraryRootPath(rawValue: "/Users/example/Pictures/Summer Photos")

    private static func presentation(
        destinationPath: LibraryRootPath? = destination,
        destinationDisplayName: String? = "Summer Photos",
        state: MediaOperationSourceState,
        batchID: ImportBatchID? = nil,
        cardStillExists: Bool = true,
        copiedJustNow: Int? = nil,
        isFullyClean: Bool? = nil,
        settledAt: Date? = nil,
        incompleteItems: [MediaAssetID] = [],
        eraseOutcome: EraseOutcome? = nil,
        sourceKind: LibraryRootKind = .removableVolume,
        sessionPreferences: ImportPreferences = .default
    ) -> MediaOperationSourcePresentation {
        MediaOperationSourcePresentation(
            sourcePath: source,
            sourceKind: sourceKind,
            destinationPath: destinationPath,
            destinationDisplayName: destinationDisplayName,
            state: state,
            attachToReadyMs: nil,
            batchID: batchID,
            cardStillExists: cardStillExists,
            copiedJustNow: copiedJustNow,
            isFullyClean: isFullyClean,
            settledAt: settledAt,
            sessionPreferences: sessionPreferences,
            incompleteItems: incompleteItems,
            eraseOutcome: eraseOutcome
        )
    }

    private static func totals(
        copyCount: Int = 0,
        skipCount: Int = 0,
        blockedCount: Int = 0,
        companionCopyCount: Int = 0,
        copyBytes: Int64 = 0
    ) -> MediaOperationPlanTotals {
        MediaOperationPlanTotals(
            copyCount: copyCount,
            skipCount: skipCount,
            blockedCount: blockedCount,
            companionCopyCount: companionCopyCount,
            copyBytes: copyBytes
        )
    }

    private static let defaultPreferences = ImportPreferences.default

    private static func map(
        _ presentation: MediaOperationSourcePresentation,
        preferences: ImportPreferences = defaultPreferences,
        isCancelling: Bool = false
    ) -> ImportBarDrawnState {
        ImportBarPresentation.map(
            presentation: presentation,
            preferences: preferences,
            sourceDisplayName: "CAMERA",
            isCancelling: isCancelling
        )
    }

    // MARK: - A · Preparing (row 1, 7)

    @Test func preparingDuringEnumerationIsIndeterminateWithNoSecondaryLine() {
        let drawn = Self.map(Self.presentation(state: .inventory))
        #expect(drawn.kind == .preparing)
        #expect(drawn.primaryLine == "Checking the card…")
        #expect(drawn.secondaryLine == .none)
        #expect(drawn.middleZone == .progress(track: .indeterminate, caption: nil))
        #expect(drawn.primaryAction == .importPending)
        #expect(drawn.primaryEnabled == false)
    }

    @Test func preparingWithMetadataTotalIsDeterminateWithHonestCount() {
        let drawn = Self.map(Self.presentation(state: .waitingForMetadata(done: 112, total: 181)))
        #expect(drawn.kind == .preparing)
        #expect(drawn.secondaryLine == .plain("112 of 181 items"))
        #expect(drawn.middleZone == .progress(track: .determinate(completed: 112, total: 181), caption: nil))
    }

    @Test func preparingFoldsPlanningIntoA() {
        #expect(Self.map(Self.presentation(state: .planning)).kind == .preparing)
    }

    @Test func queuedForReadinessIsAWithQueuedButtonStillDisabled() {
        let drawn = Self.map(Self.presentation(state: .queuedForReadiness))
        #expect(drawn.kind == .preparing)
        #expect(drawn.primaryAction == .importQueued)
        #expect(drawn.primaryEnabled == false)
    }

    @Test func eraseOnlyCompletionReportsDeletedFilesAndDoesNotRevealBatchItems() {
        let drawn = Self.map(Self.presentation(
            state: .completed(summary: Self.totals(skipCount: 4)),
            eraseOutcome: EraseOutcome(
                deletedCount: 4,
                deletedBytes: 400,
                skippedCount: 0,
                failedCount: 0
            )
        ))
        #expect(drawn.primaryLine == "Card erased · 4 items deleted")
        #expect(drawn.primaryBadge == .checkmark)
        #expect(drawn.primaryAction == .ejectCard)
        #expect(drawn.showsSecondaryShowItemsButton == false)
    }

    @Test func preparingWordingIsCameraForDeviceMTPAndCardForRemovableVolume() {
        let camera = Self.map(Self.presentation(state: .inventory, sourceKind: .deviceMTP))
        #expect(camera.primaryLine == "Checking the camera…")
        let card = Self.map(Self.presentation(state: .inventory, sourceKind: .removableVolume))
        #expect(card.primaryLine == "Checking the card…")
    }

    // MARK: - B · No destination (row 2, 14)

    @Test func noDestinationWhenDestinationPathIsNilTakesPrecedenceOverState() {
        let drawn = Self.map(Self.presentation(
            destinationPath: nil,
            destinationDisplayName: nil,
            state: .ready(summary: Self.totals(copyCount: 5), generation: 1, skippedPackageCount: 0)
        ))
        #expect(drawn.kind == .noDestination)
        #expect(drawn.primaryLine == "Otos needs a library to copy into")
        #expect(drawn.middleZone == .addLibraryButton)
        #expect(drawn.primaryAction == .importPending)
        #expect(drawn.primaryEnabled == false)
    }

    @Test func noDestinationShowsHonestCardTotalWhenKnown() {
        let drawn = Self.map(Self.presentation(
            destinationPath: nil,
            destinationDisplayName: nil,
            state: .waitingForMetadata(done: 181, total: 181)
        ))
        #expect(drawn.secondaryLine == .plain("181 items on CAMERA"))
    }

    @Test func noDestinationOmitsSecondaryLineWhenTotalIsUnknown() {
        let drawn = Self.map(Self.presentation(destinationPath: nil, destinationDisplayName: nil, state: .inventory))
        #expect(drawn.secondaryLine == .none)
    }

    // MARK: - C · Ready (row 3, 4, 5)

    @Test func readyWithNewItemsNamesCountAndBytes() {
        let drawn = Self.map(Self.presentation(
            state: .ready(
                summary: Self.totals(copyCount: 42, skipCount: 139, copyBytes: 68_000_000),
                generation: 1,
                skippedPackageCount: 0
            )
        ))
        #expect(drawn.kind == .ready)
        #expect(drawn.primaryLine == "42 new items · 68 MB")
        #expect(drawn.secondaryLine == .plain("139 already in Summer Photos"))
        #expect(drawn.primaryAction == .importItems(count: 42))
        if case let .choices(eraseEnabled, reason) = drawn.middleZone {
            #expect(eraseEnabled)
            #expect(reason == nil)
        } else {
            Issue.record("Expected .choices middle zone")
        }
    }

    @Test func readyOmitsSecondaryLineWhenSkipCountIsZero() {
        let drawn = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(copyCount: 5, copyBytes: 1000), generation: 1, skippedPackageCount: 0)
        ))
        #expect(drawn.secondaryLine == .none)
    }

    @Test func readyNothingNewVariant() {
        let drawn = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(skipCount: 181), generation: 1, skippedPackageCount: 0)
        ))
        #expect(drawn.primaryLine == "Nothing new on this card")
        #expect(drawn.secondaryLine == .plain("All 181 items are already in Summer Photos"))
        #expect(drawn.primaryAction == .ejectCard)
        // The plan alone proves every item is a skip here (state D would have
        // taken precedence over C had anything been blocked), so the erase-only
        // confirmation may state its second sentence (`import-bar.md` state F,
        // "Erase-only run").
        #expect(drawn.eraseConfirmationProvenClean)
    }

    /// Plan 0095 D9: a destination path with no resolved display name yet
    /// (`destinationDisplayName == nil` while `destinationPath` is still set)
    /// used to substitute `""`, building a broken sentence ("already in ").
    /// A true generic term is substituted instead.
    @Test func readyNothingNewWithUnresolvedDestinationNameFallsBackHonestly() {
        let drawn = Self.map(Self.presentation(
            destinationDisplayName: nil,
            state: .ready(summary: Self.totals(skipCount: 181), generation: 1, skippedPackageCount: 0)
        ))
        #expect(drawn.secondaryLine == .plain("All 181 items are already in the library"))
    }

    @Test func readyNothingNewWithEraseCheckedArmsErase() {
        var prefs = ImportPreferences.default
        prefs.deleteSourceAfterImport = true
        let drawn = Self.map(
            Self.presentation(state: .ready(summary: Self.totals(skipCount: 181), generation: 1, skippedPackageCount: 0)),
            preferences: prefs
        )
        #expect(drawn.primaryAction == .eraseItems(count: 181))
    }

    @Test func readyEmptyCardVariantOmitsChoicesZone() {
        let drawn = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(), generation: 1, skippedPackageCount: 0)
        ))
        #expect(drawn.primaryLine == "This card is empty")
        #expect(drawn.secondaryLine == .none)
        #expect(drawn.middleZone == .hidden)
        #expect(drawn.primaryAction == .ejectCard)
    }

    @Test func executionUnavailableWithoutAttentionReadsAsReadyNotAsD() {
        let drawn = Self.map(Self.presentation(
            state: .executionUnavailable(summary: Self.totals(copyCount: 3, copyBytes: 1000), generation: 1)
        ))
        #expect(drawn.kind == .ready)
    }

    // MARK: - D · Ready, needs attention (row 6)

    @Test func needsAttentionNamesSingleCauseAndDisablesErase() {
        let itemID = MediaAssetID(libraryRootPath: Self.source, relativePath: MediaRelativePath(rawValue: "a.jpg"))
        let item = MediaAttentionItem(id: itemID, reason: .noUsableDate)
        let drawn = Self.map(Self.presentation(
            state: .ready(
                summary: Self.totals(copyCount: 39, copyBytes: 61_000_000),
                generation: 1,
                skippedPackageCount: 0,
                attentionItems: [item, item, item]
            )
        ))
        #expect(drawn.kind == .needsAttention)
        #expect(drawn.primaryLine == "39 new items · 61 MB")
        #expect(drawn.secondaryLine == .attention(
            clause: "3 items have no date",
            revealLabel: "Show them",
            itemIDs: [itemID, itemID, itemID]
        ))
        #expect(drawn.primaryAction == .importItems(count: 39))
        if case let .choices(eraseEnabled, reason) = drawn.middleZone {
            #expect(!eraseEnabled)
            #expect(reason == "Some items still need attention.")
        } else {
            Issue.record("Expected .choices middle zone")
        }
    }

    @Test func needsAttentionNamesFilesystemObservationCause() {
        let itemID = MediaAssetID(libraryRootPath: Self.source, relativePath: MediaRelativePath(rawValue: "a.jpg"))
        let item = MediaAttentionItem(
            id: itemID,
            reason: .filesystemObservationUnavailable(
                destination: MediaRelativePath(rawValue: "a.jpg"),
                detail: "enumerate failed"
            )
        )
        let drawn = Self.map(Self.presentation(
            state: .ready(
                summary: Self.totals(copyCount: 1, copyBytes: 1000),
                generation: 1,
                skippedPackageCount: 0,
                attentionItems: [item, item, item]
            )
        ))
        #expect(drawn.secondaryLine == .attention(
            clause: "Otos couldn't check 3 names in Summer Photos",
            revealLabel: "Show them",
            itemIDs: [itemID, itemID, itemID]
        ))
    }

    @Test func needsAttentionWithMixedCausesNamesNoSingleCause() {
        let aID = MediaAssetID(libraryRootPath: Self.source, relativePath: MediaRelativePath(rawValue: "a.jpg"))
        let bID = MediaAssetID(libraryRootPath: Self.source, relativePath: MediaRelativePath(rawValue: "b.jpg"))
        let a = MediaAttentionItem(id: aID, reason: .noUsableDate)
        let b = MediaAttentionItem(
            id: bID,
            reason: .filesystemObservationUnavailable(
                destination: MediaRelativePath(rawValue: "b.jpg"),
                detail: "x"
            )
        )
        let drawn = Self.map(Self.presentation(
            state: .ready(
                summary: Self.totals(copyCount: 1, copyBytes: 1000),
                generation: 1,
                skippedPackageCount: 0,
                attentionItems: [a, b]
            )
        ))
        #expect(drawn.secondaryLine == .attention(clause: "2 items need attention", revealLabel: "Show them", itemIDs: [aID, bID]))
    }

    // MARK: - E · Working (row 8)

    @Test func workingNamesCompletedOfTotalAndBytes() {
        let progress = MediaOperationProgress(
            completedCount: 12,
            totalCount: 42,
            completedBytes: 19_000_000,
            totalBytes: 68_000_000,
            elapsedMs: 0
        )
        let drawn = Self.map(Self.presentation(state: .executing(progress: progress)))
        #expect(drawn.kind == .working)
        #expect(drawn.primaryLine == "Importing 12 of 42")
        #expect(drawn.secondaryLine == .plain("19 MB of 68 MB"))
        #expect(drawn.primaryAction == .cancel)
    }

    @Test func workingOmitsRemainingTimeUntilMeaningful() {
        let tooEarly = MediaOperationProgress(
            completedCount: 1,
            totalCount: 42,
            completedBytes: 1_000_000,
            totalBytes: 68_000_000,
            elapsedMs: 500
        )
        let drawn = Self.map(Self.presentation(state: .executing(progress: tooEarly)))
        #expect(drawn.secondaryLine == .plain("1 MB of 68 MB"))
    }

    @Test func workingShowsRemainingTimeOnceMeaningful() {
        let progress = MediaOperationProgress(
            completedCount: 12,
            totalCount: 42,
            completedBytes: 19_000_000,
            totalBytes: 68_000_000,
            elapsedMs: 4000
        )
        let drawn = Self.map(Self.presentation(state: .executing(progress: progress)))
        guard case let .plain(text) = drawn.secondaryLine else {
            Issue.record("Expected plain secondary line")
            return
        }
        #expect(text.hasPrefix("19 MB of 68 MB · about "))
        #expect(text.hasSuffix("left"))
    }

    /// Plan 0095 D9: same honest fallback as `readyNothingNewWithUnresolvedDestinationNameFallsBackHonestly`,
    /// exercised at state E's own `destinationDisplayName ?? ""` site.
    @Test func workingCaptionWithUnresolvedDestinationNameFallsBackHonestly() {
        let progress = MediaOperationProgress(completedCount: 1, totalCount: 2, completedBytes: 1, totalBytes: 2, elapsedMs: 0)
        let drawn = Self.map(Self.presentation(destinationDisplayName: nil, state: .executing(progress: progress)))
        #expect(drawn.middleZone == .progress(
            track: .determinate(completed: 1, total: 2),
            caption: "Into the library"
        ))
    }

    @Test func workingCaptionNamesDestinationAndEjectPolicy() {
        var prefs = ImportPreferences.default
        prefs.autoEjectAfterImport = true
        let progress = MediaOperationProgress(completedCount: 1, totalCount: 2, completedBytes: 1, totalBytes: 2, elapsedMs: 0)
        let drawn = Self.map(Self.presentation(state: .executing(progress: progress)), preferences: prefs)
        #expect(drawn.middleZone == .progress(
            track: .determinate(completed: 1, total: 2),
            caption: "Into Summer Photos · the card ejects when it's done"
        ))
    }

    @Test func workingCaptionOmitsEjectClauseWhenEjectIsOff() {
        var prefs = ImportPreferences.default
        prefs.autoEjectAfterImport = false
        let progress = MediaOperationProgress(completedCount: 1, totalCount: 2, completedBytes: 1, totalBytes: 2, elapsedMs: 0)
        let drawn = Self.map(Self.presentation(state: .executing(progress: progress)), preferences: prefs)
        #expect(drawn.middleZone == .progress(track: .determinate(completed: 1, total: 2), caption: "Into Summer Photos"))
    }

    // MARK: - E · Cancelling (row 9)

    @Test func cancellingShowsStoppingWithDisabledButtonAndMovingIndicator() {
        let progress = MediaOperationProgress(
            completedCount: 12,
            totalCount: 42,
            completedBytes: 19_000_000,
            totalBytes: 68_000_000,
            elapsedMs: 4000
        )
        let drawn = Self.map(Self.presentation(state: .executing(progress: progress)), isCancelling: true)
        #expect(drawn.kind == .working)
        #expect(drawn.primaryLine == "Stopping…")
        #expect(drawn.secondaryLine == .plain("Finishing the current item"))
        #expect(drawn.middleZone == .progress(track: .determinate(completed: 19_000_000, total: 68_000_000), caption: nil))
        #expect(drawn.primaryAction == .cancel)
        #expect(drawn.primaryEnabled == false)
    }

    @Test func cancellingIsIgnoredOutsideExecuting() {
        // A stale/lingering flag must not leak into unrelated states.
        let drawn = Self.map(Self.presentation(state: .inventory), isCancelling: true)
        #expect(drawn.kind == .preparing)
        #expect(drawn.primaryLine == "Checking the card…")
    }

    // MARK: - F · Done (row 10, 11)

    @Test func doneAttachedCleanFromFreshCompletion() {
        let drawn = Self.map(Self.presentation(
            state: .completed(summary: Self.totals(copyCount: 42, skipCount: 139), skippedForeignCount: 0, failedCount: 0),
            copiedJustNow: 42
        ))
        #expect(drawn.kind == .done)
        #expect(drawn.primaryLine == "Everything on this card is imported")
        #expect(drawn.primaryBadge == .checkmark)
        #expect(drawn.secondaryLine == .plain("42 copied just now · 181 items in Summer Photos"))
        #expect(drawn.primaryAction == .ejectCard)
        #expect(drawn.showsSecondaryShowItemsButton)
        #expect(drawn.eraseConfirmationProvenClean)
    }

    /// Plan 0095 D9: same honest fallback as `readyNothingNewWithUnresolvedDestinationNameFallsBackHonestly`,
    /// exercised at state F's own `destinationDisplayName ?? ""` site.
    @Test func doneWithUnresolvedDestinationNameFallsBackHonestly() {
        let drawn = Self.map(Self.presentation(
            destinationDisplayName: nil,
            state: .completed(summary: Self.totals(copyCount: 42, skipCount: 139), skippedForeignCount: 0, failedCount: 0),
            copiedJustNow: 42
        ))
        #expect(drawn.secondaryLine == .plain("42 copied just now · 181 items in the library"))
    }

    // MARK: - F · Incomplete (row 11, mockup "F incomplete")

    @Test func doneAttachedIncompleteVariantNamesCouldNotBeCopiedWithReveal() {
        let failedID = MediaAssetID(libraryRootPath: Self.source, relativePath: MediaRelativePath(rawValue: "a.jpg"))
        let foreignID = MediaAssetID(libraryRootPath: Self.source, relativePath: MediaRelativePath(rawValue: "b.jpg"))
        let drawn = Self.map(Self.presentation(
            state: .completed(
                summary: Self.totals(copyCount: 42, skipCount: 0),
                skippedForeignCount: 1,
                failedCount: 1,
                incompleteItems: [failedID, foreignID]
            ),
            copiedJustNow: 40
        ))
        #expect(drawn.kind == .done)
        #expect(drawn.primaryLine == "40 of 42 items copied")
        #expect(drawn.primaryBadge == .attention)
        #expect(drawn.secondaryLine == .attention(
            clause: "2 items couldn't be copied",
            revealLabel: "Show them",
            itemIDs: [failedID, foreignID]
        ))
        #expect(drawn.middleZone == .hidden)
        #expect(drawn.primaryAction == .showTheseItems)
        #expect(drawn.showsSecondaryShowItemsButton == false)
        #expect(drawn.eraseConfirmationProvenClean == false)
    }

    @Test func doneIncompleteVariantSurvivesCardGoneToo() {
        let failedID = MediaAssetID(libraryRootPath: Self.source, relativePath: MediaRelativePath(rawValue: "a.jpg"))
        let drawn = Self.map(Self.presentation(
            state: .completed(
                summary: Self.totals(copyCount: 1, skipCount: 0),
                skippedForeignCount: 0,
                failedCount: 1,
                incompleteItems: [failedID]
            ),
            cardStillExists: false,
            copiedJustNow: 0
        ))
        #expect(drawn.primaryLine == "0 of 1 item copied")
        #expect(drawn.primaryBadge == .attention)
        #expect(drawn.primaryAction == .showTheseItems)
    }

    @Test func doneNotFullyCleanWithNoIncompleteItemsFallsBackWithoutReveal() {
        // Blocked items alone can leave a completion not-fully-clean with
        // nothing that actually failed to copy — no per-item identity exists
        // for that population here, so no reveal is offered.
        let drawn = Self.map(Self.presentation(
            state: .completed(summary: Self.totals(copyCount: 10, skipCount: 0, blockedCount: 2), skippedForeignCount: 0, failedCount: 0),
            copiedJustNow: 10
        ))
        #expect(drawn.primaryBadge == .none)
        if case .attention = drawn.secondaryLine {
            Issue.record("Expected no reveal without incomplete-item identities")
        }
        #expect(drawn.eraseConfirmationProvenClean == false)
    }

    @Test func doneCardGoneOmitsChoicesAndShowsResult() {
        let drawn = Self.map(Self.presentation(
            state: .completed(summary: Self.totals(copyCount: 42), skippedForeignCount: 0, failedCount: 0),
            cardStillExists: false
        ))
        #expect(drawn.primaryLine == "42 items copied and verified")
        #expect(drawn.primaryBadge == .checkmark)
        #expect(drawn.secondaryLine == .plain("In Summer Photos · card ejected — safe to remove"))
        #expect(drawn.middleZone == .hidden)
        #expect(drawn.primaryAction == .showTheseItems)
        #expect(drawn.showsSecondaryShowItemsButton == false)
    }

    @Test func doneKeepsShowingAfterRebuildViaCopiedJustNow() {
        // J2 step 8: re-plan lands, every item is now a skip, but the bar keeps
        // reporting what this attachment just copied instead of reverting to
        // C's "nothing new" wording.
        let drawn = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(skipCount: 181), generation: 2, skippedPackageCount: 0),
            copiedJustNow: 42,
            isFullyClean: true
        ))
        #expect(drawn.kind == .done)
        #expect(drawn.primaryLine == "Everything on this card is imported")
        #expect(drawn.secondaryLine == .plain("42 copied just now · 181 items in Summer Photos"))
    }

    @Test func doneYieldsToReadyWhenCardGainsNewItems() {
        // J4: a card that gains files while attached returns to C, even though
        // `copiedJustNow` is still set from the earlier import.
        let drawn = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(copyCount: 1, skipCount: 181, copyBytes: 4_000_000), generation: 3, skippedPackageCount: 0),
            copiedJustNow: 42,
            isFullyClean: true
        ))
        #expect(drawn.kind == .ready)
        #expect(drawn.primaryLine == "1 new item · 4 MB")
    }

    @Test func doneAttachedErasedArmedWhenEraseChecked() {
        var prefs = ImportPreferences.default
        prefs.deleteSourceAfterImport = true
        let drawn = Self.map(
            Self.presentation(
                state: .ready(summary: Self.totals(skipCount: 181), generation: 2, skippedPackageCount: 0),
                copiedJustNow: 42,
                isFullyClean: true
            ),
            preferences: prefs
        )
        #expect(drawn.primaryAction == .eraseItems(count: 181))
    }

    // MARK: - G · Failed (row 12, 15)

    @Test func failedSourceRemovedNamesCauseAndPartialCount() {
        let drawn = Self.map(Self.presentation(state: .failed(reason: .sourceRemoved, publishedCount: 12)))
        #expect(drawn.kind == .failed)
        #expect(drawn.primaryLine == "Couldn't finish the import")
        #expect(drawn.secondaryLine == .plain("The card was removed · 12 items were copied before it stopped"))
        #expect(drawn.primaryAction == .tryAgain)
    }

    @Test func failedDestinationUnavailableNamesDestination() {
        let drawn = Self.map(Self.presentation(state: .failed(reason: .destinationUnavailable, publishedCount: 0)))
        #expect(drawn.secondaryLine == .plain("Summer Photos isn't available"))
    }

    @Test func failedOutOfSpace() {
        let drawn = Self.map(Self.presentation(state: .failed(reason: .outOfSpace, publishedCount: 0)))
        #expect(drawn.secondaryLine == .plain("The disk is full"))
    }

    @Test func failedUnexpectedNamesNoCauseAndNeverLeaksDetail() {
        let drawn = Self.map(Self.presentation(state: .failed(reason: .unexpected(detail: "namespaceLeaseUnavailable"), publishedCount: 0)))
        #expect(drawn.secondaryLine == .none)
        if case let .plain(text) = drawn.secondaryLine {
            #expect(!text.contains("namespaceLeaseUnavailable"))
        }
    }

    /// The systemic classification from plan 0095 D8 must still land on a true,
    /// wording-appropriate state G rather than "Done" — camera vs. card wording
    /// follows `sourceKind`, matching the other `[deviation]`-free A-state wording.
    @Test func failedSourceNotReadyReachesFailedWithCameraOrCardWording() {
        let camera = Self.map(Self.presentation(
            state: .failed(reason: .sourceNotReady, publishedCount: 0),
            sourceKind: .deviceMTP
        ))
        #expect(camera.kind == .failed)
        #expect(camera.secondaryLine == .plain("The camera is still reading its card"))
        #expect(camera.primaryAction == .tryAgain)

        let card = Self.map(Self.presentation(
            state: .failed(reason: .sourceNotReady, publishedCount: 0),
            sourceKind: .removableVolume
        ))
        #expect(card.secondaryLine == .plain("The card is still being read"))
    }

    // MARK: - Byte formatting (Number formatting table)

    @Test func byteFormattingMatchesTheSpecTable() {
        #expect(ImportBarByteFormat.string(bytes: 840_000) == "840 KB")
        #expect(ImportBarByteFormat.string(bytes: 68_000_000) == "68 MB")
        #expect(ImportBarByteFormat.string(bytes: 500_000_000) == "0.5 GB")
        #expect(ImportBarByteFormat.string(bytes: 4_200_000_000) == "4.2 GB")
        #expect(ImportBarByteFormat.string(bytes: 128_000_000_000) == "128 GB")
    }

    /// Plan 0095 D9: `max(1, …)` used to force `0 bytes` to render as `1 KB` —
    /// a fabricated non-zero value for a genuinely-zero fact. `0` now renders
    /// as `0 KB`, and every threshold the formatter switches units at is
    /// pinned so a future edit can't reintroduce a silent off-by-one.
    @Test func byteFormattingAtEveryUnitBoundaryIsHonest() {
        #expect(ImportBarByteFormat.string(bytes: 0) == "0 KB")
        #expect(ImportBarByteFormat.string(bytes: 1) == "0 KB")
        #expect(ImportBarByteFormat.string(bytes: 999) == "1 KB")
        #expect(ImportBarByteFormat.string(bytes: 1000) == "1 KB")
        #expect(ImportBarByteFormat.string(bytes: 99_999_999) == "100 MB")
        #expect(ImportBarByteFormat.string(bytes: 100_000_000) == "0.1 GB")
        #expect(ImportBarByteFormat.string(bytes: 99_999_999_999) == "100.0 GB")
        #expect(ImportBarByteFormat.string(bytes: 100_000_000_000) == "100 GB")
    }
}

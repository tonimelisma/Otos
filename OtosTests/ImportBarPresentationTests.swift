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
        importRequested: Bool = false,
        batchID: ImportBatchID? = nil,
        cardStillExists: Bool = true,
        copiedJustNow: Int? = nil,
        isFullyClean: Bool? = nil,
        incompleteItems: [MediaAssetID] = [],
        eraseOutcome: EraseOutcome? = nil,
        sourceKind: LibraryRootKind = .removableVolume,
        sessionPreferences: ImportPreferences = .default,
        stopReason: ImportStopReason? = nil,
        plannedCount: Int? = nil,
        destinationAvailableBytes: Int64? = nil
    ) -> MediaOperationSourcePresentation {
        MediaOperationSourcePresentation(
            sourcePath: source,
            sourceKind: sourceKind,
            destinationPath: destinationPath,
            destinationDisplayName: destinationDisplayName,
            state: state,
            importRequested: importRequested,
            attachToReadyMs: nil,
            batchID: batchID,
            batchHasPublishedAssets: batchID != nil && (copiedJustNow ?? 1) > 0,
            cardStillExists: cardStillExists,
            copiedJustNow: copiedJustNow,
            isFullyClean: isFullyClean,
            stopReason: stopReason,
            plannedCount: plannedCount,
            destinationAvailableBytes: destinationAvailableBytes,
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
        #expect(drawn.middleZone == .choices(track: .indeterminate, eraseEnabled: true, eraseDisabledReason: nil))
        #expect(drawn.primaryAction == .importNewItems)
        #expect(drawn.primaryEnabled == false)
    }

    @Test func preparingWithMetadataTotalIsDeterminateWithHonestCount() {
        let drawn = Self.map(Self.presentation(state: .waitingForMetadata(done: 112, total: 181)))
        #expect(drawn.kind == .preparing)
        #expect(drawn.secondaryLine == .plain("112 of 181 items"))
        #expect(drawn.middleZone == .choices(
            track: .determinate(completed: 112, total: 181),
            eraseEnabled: true,
            eraseDisabledReason: nil
        ))
    }

    /// `import-bar.md` state A: "the destination and checkboxes stay visible and
    /// usable; choosing while we check costs nothing." The choices are the same
    /// zone Ready draws, with the track above them, so no control appears or
    /// moves when the plan lands (DES-053). The act is the same `Import` button
    /// Ready enables, disabled — never static text.
    @Test func preparingOffersTheChoicesAndTheDisabledImportButton() {
        for state in [MediaOperationSourceState.inventory, .planning, .waitingForMetadata(done: 1, total: 2)] {
            let drawn = Self.map(Self.presentation(state: state))
            guard case let .choices(track, eraseEnabled, reason) = drawn.middleZone else {
                Issue.record("Expected the choices zone while preparing from \(state)")
                continue
            }
            #expect(track != nil)
            #expect(eraseEnabled)
            #expect(reason == nil)
            let rendered = ImportPlanFooter.renderedPrimary(for: drawn)
            #expect(rendered.title == "Import")
            #expect(!rendered.isEnabled)
        }
        let ready = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(copyCount: 1, copyBytes: 10), generation: 1, skippedPackageCount: 0)
        ))
        #expect(ImportPlanFooter.renderedPrimary(for: ready).title == "Import")
        #expect(ImportPlanFooter.renderedPrimary(for: ready).isEnabled)
    }

    @Test func preparingFoldsPlanningIntoA() {
        #expect(Self.map(Self.presentation(state: .planning)).kind == .preparing)
    }

    /// `import-bar.md` row 7: a click the coordinator is holding until the plan
    /// is ready is not a state of its own. The bar keeps every string and zone
    /// it would otherwise draw — the determinate count included — and only the
    /// Import button changes, to disabled. No `Import queued` title (DES-035).
    @Test func aHeldClickDisablesImportAndChangesNothingElse() {
        let checking = Self.presentation(state: .waitingForMetadata(done: 112, total: 181))
        let held = Self.presentation(state: .waitingForMetadata(done: 112, total: 181), importRequested: true)
        let drawnChecking = Self.map(checking)
        let drawnHeld = Self.map(held)
        #expect(drawnHeld.primaryLine == drawnChecking.primaryLine)
        #expect(drawnHeld.secondaryLine == .plain("112 of 181 items"))
        #expect(drawnHeld.middleZone == drawnChecking.middleZone)
        #expect(drawnHeld.primaryAction == .importNewItems)
        #expect(!drawnHeld.primaryEnabled)
        #expect(ImportPlanFooter.renderedPrimary(for: drawnHeld).title == "Import")

        let ready = Self.presentation(
            state: .ready(summary: Self.totals(copyCount: 42, skipCount: 139, copyBytes: 68_000_000), generation: 1, skippedPackageCount: 0),
            importRequested: true
        )
        let drawnReady = Self.map(ready)
        #expect(drawnReady.primaryLine == "42 new items · 68 MB")
        #expect(drawnReady.primaryAction == .importNewItems)
        #expect(!drawnReady.primaryEnabled)
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
        #expect(drawn.primaryAction == .importNewItems)
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
        #expect(drawn.primaryAction == .importNewItems)
        if case let .choices(track, eraseEnabled, reason) = drawn.middleZone {
            #expect(track == nil)
            #expect(eraseEnabled)
            #expect(reason == nil)
        } else {
            Issue.record("Expected .choices middle zone")
        }
    }

    /// State C says before the click that not everything will fit: the plan's
    /// bytes plus the floor exceed what the volume reported available. The act
    /// stays the whole plan — the run copies what fits and stops (ADR 0027).
    @Test func readyAdvisesWhenNotEverythingWillFit() {
        let drawn = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(copyCount: 680, copyBytes: 54_757_512_996), generation: 1, skippedPackageCount: 0),
            destinationAvailableBytes: 37_673_455_616
        ))
        #expect(drawn.kind == .ready)
        #expect(drawn.primaryLine == "680 new items · 54.8 GB")
        #expect(drawn.secondaryLine == .plain("Not everything will fit yet · 37.7 GB available"))
        #expect(drawn.primaryAction == .importNewItems)
        #expect(drawn.primaryEnabled)
    }

    @Test func readyStaysQuietWhenEverythingFitsOrTheVolumeDidNotAnswer() {
        let fits = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(copyCount: 3, copyBytes: 3000), generation: 1, skippedPackageCount: 0),
            destinationAvailableBytes: FreeSpaceFloor.bytes + 4000
        ))
        #expect(fits.secondaryLine == .none)
        // Exactly the floor after the copy is still room enough.
        let exact = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(copyCount: 3, copyBytes: 3000), generation: 1, skippedPackageCount: 0),
            destinationAvailableBytes: FreeSpaceFloor.bytes + 3000
        ))
        #expect(exact.secondaryLine == .none)
        let unknown = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(copyCount: 3, copyBytes: 3000), generation: 1, skippedPackageCount: 0),
            destinationAvailableBytes: nil
        ))
        #expect(unknown.secondaryLine == .none)
    }

    /// One clause on L3 (DES-034): room outranks "already in the library"
    /// because it changes what the click will do.
    @Test func theSpaceAdvisoryOutranksTheAlreadyInLibraryClause() {
        let drawn = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(copyCount: 10, skipCount: 5, copyBytes: 10_000_000_000), generation: 1, skippedPackageCount: 0),
            destinationAvailableBytes: 2_000_000_000
        ))
        #expect(drawn.secondaryLine == .plain("Not everything will fit yet · 2.0 GB available"))
        let roomy = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(copyCount: 10, skipCount: 5, copyBytes: 10000), generation: 1, skippedPackageCount: 0),
            destinationAvailableBytes: FreeSpaceFloor.bytes + 1_000_000
        ))
        #expect(roomy.secondaryLine == .plain("5 already in Summer Photos"))
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

    /// APP-029: a destination path with no resolved display name yet
    /// (`destinationDisplayName == nil` while `destinationPath` is still set)
    /// takes a true generic term, never `""`, which would build a broken
    /// sentence ("already in ").
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
        #expect(drawn.primaryAction == .importNewItems)
        if case let .choices(track, eraseEnabled, reason) = drawn.middleZone {
            #expect(track == nil)
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
            reason: .filesystemObservationUnavailable(destination: MediaRelativePath(rawValue: "a.jpg"))
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

    @Test func needsAttentionNamesTheNoFreeNameCause() {
        let itemID = MediaAssetID(libraryRootPath: Self.source, relativePath: MediaRelativePath(rawValue: "a.jpg"))
        let item = MediaAttentionItem(id: itemID, reason: .noFreeDestinationName(destination: MediaRelativePath(rawValue: "a.jpg")))
        let drawn = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(copyCount: 1, copyBytes: 1000), generation: 1, skippedPackageCount: 0, attentionItems: [item, item])
        ))
        #expect(drawn.secondaryLine == .attention(
            clause: "Otos couldn't find a free name for 2 items in Summer Photos",
            revealLabel: "Show them",
            itemIDs: [itemID, itemID]
        ))
    }

    /// 2026-09-13: every item blocked, and the bar offered `Import 0 Items`,
    /// enabled. A control whose subject does not exist is omitted (DES-053).
    @Test func needsAttentionWithNothingImportableOffersNoAct() {
        let itemID = MediaAssetID(libraryRootPath: Self.source, relativePath: MediaRelativePath(rawValue: "a.jpg"))
        let item = MediaAttentionItem(id: itemID, reason: .noUsableDate)
        let drawn = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(copyCount: 0), generation: 1, skippedPackageCount: 0, attentionItems: [item])
        ))
        #expect(drawn.kind == .needsAttention)
        #expect(drawn.primaryAction == .none)
        let some = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(copyCount: 5, copyBytes: 5000), generation: 1, skippedPackageCount: 0, attentionItems: [item])
        ))
        #expect(some.primaryAction == .importNewItems)
    }

    @Test func needsAttentionWithMixedCausesNamesNoSingleCause() {
        let aID = MediaAssetID(libraryRootPath: Self.source, relativePath: MediaRelativePath(rawValue: "a.jpg"))
        let bID = MediaAssetID(libraryRootPath: Self.source, relativePath: MediaRelativePath(rawValue: "b.jpg"))
        let a = MediaAttentionItem(id: aID, reason: .noUsableDate)
        let b = MediaAttentionItem(
            id: bID,
            reason: .filesystemObservationUnavailable(destination: MediaRelativePath(rawValue: "b.jpg"))
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

    /// Same honest fallback as `readyNothingNewWithUnresolvedDestinationNameFallsBackHonestly`,
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
        #expect(drawn.eraseConfirmationProvenClean)
    }

    /// Same honest fallback as `readyNothingNewWithUnresolvedDestinationNameFallsBackHonestly`,
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
        #expect(drawn.primaryAction == .none)
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
        #expect(drawn.primaryAction == .none)
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
        #expect(drawn.primaryAction == .none)
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

    // MARK: - F · Stopped (APP-029, J8)

    @Test func stoppedAfterCancelOffersTheRemainderWhileTheCardIsAttached() {
        // J8 step 3–4: the run's own facts at L1, the cause at L3, and the
        // re-plan's remainder as the act — on either row.
        let drawn = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(copyCount: 30, skipCount: 12), generation: 2, skippedPackageCount: 0),
            copiedJustNow: 12,
            isFullyClean: false,
            stopReason: .user,
            plannedCount: 42
        ))
        #expect(drawn.kind == .done)
        #expect(drawn.primaryLine == "Stopped — 12 of 42 items copied")
        #expect(drawn.secondaryLine == .plain("They're in Summer Photos"))
        #expect(drawn.middleZone == .choices(track: nil, eraseEnabled: true, eraseDisabledReason: nil))
        #expect(drawn.primaryAction == .importNewItems)
        #expect(drawn.primaryEnabled)
    }

    @Test func stoppedBeforeTheRePlanLandsHoldsTheActAsPending() {
        // The coordinator drops the pre-run plan on a stop, so until the
        // rebuild lands there is no honest remainder to put in the title.
        let drawn = Self.map(Self.presentation(
            state: .waitingForMetadata(done: 42, total: 42),
            copiedJustNow: 12,
            isFullyClean: false,
            stopReason: .user,
            plannedCount: 42
        ))
        #expect(drawn.primaryLine == "Stopped — 12 of 42 items copied")
        #expect(drawn.primaryAction == .importNewItems)
        #expect(!drawn.primaryEnabled)
        let held = Self.map(Self.presentation(
            state: .waitingForMetadata(done: 42, total: 42),
            importRequested: true,
            copiedJustNow: 12,
            isFullyClean: false,
            stopReason: .user,
            plannedCount: 42
        ))
        #expect(held.primaryLine == "Stopped — 12 of 42 items copied")
        #expect(held.primaryAction == .importNewItems)
        #expect(!held.primaryEnabled)
    }

    @Test func stoppedWithTheCardGoneHasNoChoicesAndNoAct() {
        // The detached snapshot carries `.completed`; the stop still outranks
        // Done, and the card-gone rule applies (DES-053 exception).
        let drawn = Self.map(Self.presentation(
            state: .completed(summary: Self.totals(copyCount: 12)),
            cardStillExists: false,
            copiedJustNow: 12,
            isFullyClean: false,
            stopReason: .user,
            plannedCount: 42
        ))
        #expect(drawn.primaryLine == "Stopped — 12 of 42 items copied")
        #expect(drawn.secondaryLine == .plain("In Summer Photos · card ejected — safe to remove"))
        #expect(drawn.middleZone == .hidden)
        #expect(drawn.primaryAction == .none)
    }

    @Test func stoppedWithNothingCopiedStatesTheCountAndNoDestinationClause() {
        let drawn = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(copyCount: 42), generation: 2, skippedPackageCount: 0),
            copiedJustNow: 0,
            isFullyClean: false,
            stopReason: .user,
            plannedCount: 42
        ))
        #expect(drawn.primaryLine == "Stopped — 0 of 42 items copied")
        #expect(drawn.secondaryLine == .none)
        #expect(drawn.primaryAction == .importNewItems)
    }

    @Test func stoppedWithNothingLeftOffersEjectOrErase() {
        // Cancel landed after the last copy: the remainder is empty, so the act
        // is the card's, exactly as F-attached offers it.
        let base = Self.presentation(
            state: .ready(summary: Self.totals(skipCount: 42), generation: 2, skippedPackageCount: 0),
            copiedJustNow: 42,
            isFullyClean: false,
            stopReason: .user,
            plannedCount: 42
        )
        #expect(Self.map(base).primaryAction == .ejectCard)
        var erase = ImportPreferences.default
        erase.deleteSourceAfterImport = true
        #expect(Self.map(base, preferences: erase).primaryAction == .eraseItems(count: 42))
    }

    @Test func stoppedKeepsEraseDisabledWhileAttentionRemains() {
        let item = MediaAttentionItem(
            id: MediaAssetID(libraryRootPath: Self.source, relativePath: MediaRelativePath(rawValue: "IMG_0001.JPG")),
            reason: .noUsableDate
        )
        let drawn = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(copyCount: 30), generation: 2, skippedPackageCount: 0, attentionItems: [item]),
            copiedJustNow: 12,
            isFullyClean: false,
            stopReason: .user,
            plannedCount: 42
        ))
        #expect(drawn.primaryLine == "Stopped — 12 of 42 items copied")
        #expect(drawn.middleZone == .choices(track: nil, eraseEnabled: false, eraseDisabledReason: "Some items still need attention."))
        #expect(drawn.primaryAction == .importNewItems)
    }

    @Test func aNewRunOutranksTheStopItFollows() {
        // `lastCompletion` still carries the stop while the retry executes;
        // Working (and a retry's Failed) are the newer fact.
        let working = Self.map(Self.presentation(
            state: .executing(progress: MediaOperationProgress(completedCount: 1, totalCount: 30, completedBytes: 1, totalBytes: 30, elapsedMs: 10)),
            copiedJustNow: 12,
            isFullyClean: false,
            stopReason: .user,
            plannedCount: 42
        ))
        #expect(working.kind == .working)
        let failed = Self.map(Self.presentation(
            state: .failed(reason: .destinationUnavailable, publishedCount: 0),
            copiedJustNow: 12,
            isFullyClean: false,
            stopReason: .user,
            plannedCount: 42
        ))
        #expect(failed.kind == .failed)
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

    /// A failure before any run — the destination folder stayed unreadable, a
    /// root vanished, the builder threw — draws G with the stage named: nothing
    /// started, so the headline must not say "finish". Same zones, same act.
    @Test func planningFailureSaysPrepareNotFinish() {
        let drawn = Self.map(Self.presentation(state: .planningFailed(reason: .destinationUnavailable)))
        #expect(drawn.kind == .failed)
        #expect(drawn.primaryLine == "Couldn't prepare the import")
        #expect(drawn.secondaryLine == .plain("Summer Photos isn't available"))
        #expect(drawn.primaryAction == .tryAgain)
        #expect(drawn.middleZone == .choices(track: nil, eraseEnabled: true, eraseDisabledReason: nil))

        let unexpected = Self.map(Self.presentation(state: .planningFailed(reason: .unexpected(detail: "snapshotUnavailable"))))
        #expect(unexpected.primaryLine == "Couldn't prepare the import")
        #expect(unexpected.secondaryLine == .none)
    }

    /// ADR 0027: running out of room is a Stopped outcome, not a failure. The
    /// clause states the capacity read at the stop, in the spec's byte units.
    @Test func stoppedAtTheDiskFloorNamesTheRoomLeftAndOffersTheRemainder() {
        let drawn = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(copyCount: 268, skipCount: 412), generation: 2, skippedPackageCount: 0),
            copiedJustNow: 412,
            isFullyClean: false,
            stopReason: .diskFloor(bytesFree: 5_400_000_000),
            plannedCount: 680
        ))
        #expect(drawn.kind == .done)
        #expect(drawn.primaryLine == "Stopped — 412 of 680 items copied")
        #expect(drawn.secondaryLine == .plain("Not enough room on the disk · 5.4 GB left"))
        #expect(drawn.primaryAction == .importNewItems)
        let nothing = Self.map(Self.presentation(
            state: .ready(summary: Self.totals(copyCount: 680), generation: 2, skippedPackageCount: 0),
            copiedJustNow: 0,
            isFullyClean: false,
            stopReason: .diskFloor(bytesFree: 4_200_000_000),
            plannedCount: 680
        ))
        #expect(nothing.primaryLine == "Stopped — 0 of 680 items copied")
        #expect(nothing.secondaryLine == .plain("Not enough room on the disk · 4.2 GB left"))
    }

    @Test func failedUnexpectedNamesNoCauseAndNeverLeaksDetail() {
        let drawn = Self.map(Self.presentation(state: .failed(reason: .unexpected(detail: "namespaceLeaseUnavailable"), publishedCount: 0)))
        #expect(drawn.secondaryLine == .none)
        if case let .plain(text) = drawn.secondaryLine {
            #expect(!text.contains("namespaceLeaseUnavailable"))
        }
    }

    /// The systemic `.sourceNotReady` classification must still land on a true,
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

    /// `0` renders as `0 KB` — a `max(1, …)` clamp would fabricate `1 KB`, a
    /// non-zero value for a genuinely-zero fact — and every threshold the formatter switches units at is
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

    /// DES-032 permits exactly one estimate and requires it be hedged. It says nothing about
    /// units, and the code rendered raw seconds — a 38 GB card opened at `about 221 seconds
    /// left`. Precision degrades with magnitude so the estimate never states more than a
    /// bytes-over-elapsed rate can support.
    @Test func theRemainingEstimateIsStatedInUnitsAPersonReads() {
        #expect(ImportBarPresentation.remainingClause(seconds: 45) == "45 seconds")
        #expect(ImportBarPresentation.remainingClause(seconds: 1) == "1 second")
        // The measured case: 221 s is four minutes, not two hundred and twenty-one of
        // anything, and the trailing digits carry no information the rate can support.
        #expect(ImportBarPresentation.remainingClause(seconds: 221) == "4 minutes")
        #expect(ImportBarPresentation.remainingClause(seconds: 309) == "5 minutes")
    }

    /// Above an hour the estimate keeps the minutes, because "1 hour" alone would round away
    /// most of the wait on a long card.
    @Test func aLongRunKeepsItsMinutesAlongsideTheHours() {
        let clause = ImportBarPresentation.remainingClause(seconds: 4800)
        #expect(clause.contains("1 hour"))
        #expect(clause.contains("20 minutes"))
    }
}

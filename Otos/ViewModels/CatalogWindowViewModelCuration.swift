import Foundation
import OSLog

/// Curation intent guide
///
/// A curation command is captured on the MainActor, then delivered losslessly to the
/// Store's one-row-update owner. The command carries the display/query facts needed to
/// reject stale post-await navigation; it never carries a catalog row or a filesystem
/// fact. Grid, loupe, compare, menu, keyboard, accessibility, and inline controls all
/// call `submitMediaChoice(_:target:origin:)`.
nonisolated enum MediaChoiceTarget: Equatable {
    case current
    case item(MediaAssetID)
    case compare(PanePosition)
}

nonisolated enum MediaChoiceOrigin: String, Equatable {
    case menu
    case keyboard
    case inline
    case accessibility
}

struct MediaChoiceCommand: Equatable {
    let choice: MediaChoice
    let target: MediaChoiceTarget
    let ids: [MediaAssetID]
    let mode: BrowserViewMode
    let descriptor: CatalogQueryDescriptor
    let queryGeneration: UInt64
    let orderedIDs: [MediaAssetID]
    let selection: GridSelection
    let comparePair: ComparePair
    let comparePane: PanePosition
    let advanceFrom: MediaAssetID?
    let advanceTo: MediaAssetID?
    let origin: MediaChoiceOrigin
}

extension CatalogWindowViewModel {
    var hasMediaChoiceTarget: Bool {
        !mediaChoiceTargetIDs(.current).isEmpty
    }

    func setAdvanceAfterMediaChoice(_ enabled: Bool) {
        guard advanceAfterMediaChoice != enabled else {
            return
        }
        advanceAfterMediaChoice = enabled
        preferences.set(enabled, forKey: Self.advanceAfterMediaChoiceDefaultsKey)
    }

    func submitMediaChoice(
        _ choice: MediaChoice,
        target: MediaChoiceTarget = .current,
        origin: MediaChoiceOrigin = .menu
    ) {
        if case let .compare(position) = target {
            activeComparePane = position
        }
        let ids = mediaChoiceTargetIDs(target)
        guard !ids.isEmpty else {
            return
        }
        let orderedIDs = state.mediaGrid.orderedAssetIDs
        let advanceFrom = ids.last
        let advanceTo: MediaAssetID? = advanceFrom.flatMap { id in
            guard let index = orderedIDs.firstIndex(of: id) else {
                return nil
            }
            return orderedIDs.dropFirst(index + 1).first
        }
        let command = MediaChoiceCommand(
            choice: choice,
            target: target,
            ids: ids,
            mode: viewMode,
            descriptor: queryDescriptor,
            queryGeneration: queryGeneration,
            orderedIDs: orderedIDs,
            selection: gridSelection,
            comparePair: comparePair,
            comparePane: activeComparePane,
            advanceFrom: advanceFrom,
            advanceTo: advanceTo,
            origin: origin
        )
        mediaChoiceContinuation.yield(command)
        OtosLog.ui.notice(
            "op=mediaChoice.submit choice=\(choice.rawValue, privacy: .public) count=\(ids.count, privacy: .public) origin=\(origin.rawValue, privacy: .public)"
        )
    }

    func mediaChoiceTargetIDs(_ target: MediaChoiceTarget) -> [MediaAssetID] {
        let ordered = state.mediaGrid.orderedAssetIDs
        switch target {
        case .current:
            switch viewMode {
            case .grid:
                return orderedSelectedAssetIDs
            case .loupe:
                return focusedAssetID.map { [$0] } ?? []
            case .compare:
                return compareID(for: activeComparePane).map { [$0] } ?? []
            }
        case let .item(id):
            return ordered.contains(id) ? [id] : []
        case let .compare(position):
            return compareID(for: position).map { [$0] } ?? []
        }
    }

    private func compareID(for position: PanePosition) -> MediaAssetID? {
        switch position {
        case .left:
            comparePair.left
        case .right:
            comparePair.right
        }
    }

    func startMediaChoiceForwarding(store: CatalogStore) {
        mediaChoiceForwardingTask = Task { [weak self, mediaChoiceStream, store] in
            for await command in mediaChoiceStream {
                guard !Task.isCancelled else {
                    break
                }
                do {
                    let result = try await store.setMediaChoice(command.choice, for: command.ids)
                    guard result.accepted else {
                        continue
                    }
                    guard let self else {
                        break
                    }
                    updatePaneMediaChoices(ids: command.ids, choice: command.choice)
                    completeMediaChoice(command)
                } catch {
                    OtosLog.persistence.error(
                        "op=mediaChoice.persist failed=\(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
    }

    private func completeMediaChoice(_ command: MediaChoiceCommand) {
        guard advanceAfterMediaChoice,
              let advanceTo = command.advanceTo,
              viewMode == command.mode,
              queryDescriptor == command.descriptor,
              queryGeneration == command.queryGeneration,
              state.mediaGrid.orderedAssetIDs.contains(advanceTo)
        else {
            return
        }

        switch command.mode {
        case .grid:
            guard gridSelection == command.selection else { return }
            gridSelection = gridSelection.plainClick(advanceTo)
        case .loupe:
            guard focusedAssetID == command.ids.first else { return }
            gridSelection = gridSelection.plainClick(advanceTo)
            setFocus(advanceTo)
            refreshPanePreviews()
        case .compare:
            guard comparePair == command.comparePair,
                  activeComparePane == command.comparePane
            else { return }
            let next = ComparePairPolicy.click(
                advanceTo,
                replacing: command.comparePane,
                pair: comparePair,
                orderedIDs: state.mediaGrid.orderedAssetIDs
            )
            applyComparePair(next, orderedIDs: state.mediaGrid.orderedAssetIDs)
        }
        OtosLog.ui.notice(
            "op=mediaChoice.advance phase=completed moved=1"
        )
    }

    private func updatePaneMediaChoices(ids: [MediaAssetID], choice: MediaChoice) {
        let changedIDs = Set(ids)
        for slot in PaneSlot.allCases {
            guard let preview = panePreviews[slot], changedIDs.contains(preview.id) else {
                continue
            }
            panePreviews[slot] = PanePreview(
                id: preview.id,
                image: preview.image,
                mediaChoice: choice
            )
        }
    }
}

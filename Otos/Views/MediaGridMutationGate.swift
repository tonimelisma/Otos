import Foundation

/// Grid mutation gate guide
///
/// One small, testable state machine arbitrates every *exclusive* mutation of the AppKit
/// collection view — a diffable structural apply and an animated column-count (zoom)
/// swap — so those two never overlap in either direction. It keeps the imperative
/// update lifecycle out of SwiftUI and out of the controller, which becomes a pure
/// executor of the ordered action lists this gate returns.
///
/// Why one owner for both kinds: a single arbiter is what guarantees exclusivity in both
/// directions and keeps column-count truth in one place, so two states that are otherwise
/// easy to desync are made structurally safe here. A zoom request superseded back to the
/// currently installed count converges to "no swap" because the drain compares
/// requested-vs-installed at drain time and never keeps a stashed command; and a grid
/// state arriving mid-zoom parks as `pendingGrid` because `receive` checks `inFlight` for
/// *any* mutation kind, not just a structural apply.
///
/// Column state lives here as exactly two values — `installedColumnCount` (what the
/// layout currently shows) and `requestedColumnCount` (the newest requested value,
/// always overwritten). There is no separate "pending column" command to fall out of
/// sync with the ViewModel.
///
/// Each method returns an *ordered action list* (usually 0–1 elements). At most one
/// *exclusive* action — `.apply` or `.zoomSwap` — appears, and always last, because a
/// completion can legitimately need `[.refreshVisible(…), .zoomSwap(…)]`: a
/// `refreshVisible` is a cheap synchronous detail re-read/reset, not an exclusive
/// mutation, so it never occupies `inFlight` and may precede an exclusive action in the
/// same drain.
///
/// A query-descriptor change is a user context change, so it resets scroll and selection
/// even when the same identities survive. Lives beside `MediaGridBridgeView` (its
/// only owner) but in its own file so the collection bridge stays focused and the gate
/// can be unit-tested directly (`MediaGridBridgeTests`).
@MainActor
final class MediaGridMutationGate {
    /// Which exclusive mutation, if any, currently owns the collection view. A
    /// `refreshVisible` is deliberately *not* here: it is a cheap synchronous re-read, not
    /// an exclusive mutation, so it never blocks the other kind.
    enum InFlight: Equatable {
        case none
        case structuralApply
        case zoomSwap

        var diagnosticDescription: String {
            switch self {
            case .none: "none"
            case .structuralApply: "structuralApply"
            case .zoomSwap: "zoomSwap"
            }
        }
    }

    enum Action: Equatable {
        /// Diagnostics only: an update arrived while a mutation was in flight and was
        /// stashed as the newest pending grid. `replacedExisting` reports whether it
        /// displaced an earlier pending grid.
        case pending(replacedExisting: Bool)
        /// Same identities, so no structural apply: re-read visible details and apply the
        /// descriptor-change resets. Not exclusive — never occupies `inFlight`.
        case refreshVisible(CatalogMediaGridState, resetScroll: Bool, resetSelection: Bool)
        /// Exclusive: run one diffable structural apply for a new identity order.
        /// `descriptorChanged` is the single fact that drives scroll/selection reset
        /// and the apply-policy choice (same-descriptor reorders animate; descriptor
        /// flips keep the reloadData-class path).
        case apply(CatalogMediaGridState, descriptorChanged: Bool)
        /// Exclusive: install a new column-count layout (animated swap).
        case zoomSwap(columnCount: Int)

        var diagnosticDescription: String {
            switch self {
            case .pending:
                "pending"
            case .refreshVisible:
                "refreshVisible"
            case .apply:
                "apply"
            case .zoomSwap:
                "zoomSwap"
            }
        }
    }

    private(set) var displayedOrderedIDs: [MediaAssetID] = []
    /// Membership set for `displayedOrderedIDs`, retained beside the array so
    /// `MediaGridStructuralApplyPolicy.summarize` does not rebuild `Set(23k)` on
    /// every apply. Updated only in `completeStructuralApply(applied:)`.
    private(set) var displayedOrderedIDSet: Set<MediaAssetID> = []
    private(set) var displayedDescriptor: CatalogQueryDescriptor = .default
    /// What the installed layout currently shows.
    private(set) var installedColumnCount: Int
    /// The newest requested column count; always overwritten by `receiveColumnCount`, so
    /// there is never a stale separate request to drain.
    private(set) var requestedColumnCount: Int
    private(set) var inFlight: InFlight = .none
    private var pendingGrid: CatalogMediaGridState?

    /// Scalar gate facts for stall correlation — no grid payload retained.
    var stallDiagnosticFields: [String: String] {
        [
            "inFlightExclusive": inFlight.diagnosticDescription,
            "pendingGrid": pendingGrid == nil ? "false" : "true",
        ]
    }

    init(columnCount: Int = GridColumnCount.defaultValue) {
        installedColumnCount = columnCount
        requestedColumnCount = columnCount
    }

    /// A new background grid state. While any mutation is in flight the newest grid wins
    /// (only the latest survives as `pendingGrid`); otherwise it is evaluated immediately.
    func receive(_ grid: CatalogMediaGridState) -> [Action] {
        guard inFlight == .none else {
            let replacedExisting = pendingGrid != nil
            pendingGrid = grid
            return [.pending(replacedExisting: replacedExisting)]
        }
        return [idleGridAction(grid)]
    }

    /// A new requested column count from any zoom surface. The newest request is the only
    /// request: `requestedColumnCount` is always overwritten first, so a request that is
    /// later superseded (including back to the installed count) has nothing left to go
    /// stale. A swap starts only when idle and the count actually differs; otherwise the
    /// request converges at the next completion drain.
    func receiveColumnCount(_ requested: Int) -> [Action] {
        requestedColumnCount = requested
        guard inFlight == .none else {
            return []
        }
        guard requested != installedColumnCount else {
            return []
        }
        inFlight = .zoomSwap
        return [.zoomSwap(columnCount: requested)]
    }

    /// The diffable structural apply for `grid` finished. Adopts its identities/descriptor
    /// as displayed, clears the in-flight slot, then drains any parked work.
    /// Order array and membership set stay in lockstep — one write site only.
    func completeStructuralApply(applied grid: CatalogMediaGridState) -> [Action] {
        displayedOrderedIDs = grid.orderedAssetIDs
        displayedOrderedIDSet = Set(grid.orderedAssetIDs)
        displayedDescriptor = grid.descriptor
        inFlight = .none
        return drain()
    }

    /// The animated layout swap that installed `installed` columns finished. Adopts the
    /// installed count, clears the in-flight slot, then drains any parked work — this is
    /// what finally closes the apply-during-zoom window, because a grid state that arrived
    /// mid-animation parked as `pendingGrid` and applies here.
    func completeZoomSwap(installed: Int) -> [Action] {
        installedColumnCount = installed
        inFlight = .none
        return drain()
    }

    /// Evaluates a grid as if the gate were idle: updates descriptor bookkeeping and
    /// returns either a non-exclusive `.refreshVisible` (identical identities) or an
    /// exclusive `.apply` (new identity order), marking `inFlight = .structuralApply` in
    /// the apply case. Shared by `receive`'s idle path and `drain`.
    private func idleGridAction(_ grid: CatalogMediaGridState) -> Action {
        let descriptorChanged = grid.descriptor != displayedDescriptor
        if grid.orderedAssetIDs == displayedOrderedIDs {
            displayedDescriptor = grid.descriptor
            return .refreshVisible(
                grid,
                resetScroll: descriptorChanged,
                resetSelection: descriptorChanged
            )
        }
        inFlight = .structuralApply
        return .apply(grid, descriptorChanged: descriptorChanged)
    }

    /// Runs after every completion, in order: parked grid first (content correctness),
    /// then a still-needed zoom. A parked grid whose identities differ starts a new
    /// exclusive apply and returns immediately — the pending zoom converges after that
    /// apply's own completion drains again. A same-identity parked grid is a cheap
    /// `refreshVisible` that can precede a trailing zoom swap in the same drain.
    private func drain() -> [Action] {
        var actions: [Action] = []
        if let grid = pendingGrid {
            pendingGrid = nil
            let action = idleGridAction(grid)
            if case .apply = action {
                return [action]
            }
            actions.append(action)
        }
        if requestedColumnCount != installedColumnCount {
            inFlight = .zoomSwap
            actions.append(.zoomSwap(columnCount: requestedColumnCount))
        }
        return actions
    }
}

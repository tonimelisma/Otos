import AppKit

/// Owns work that must observe a resolved collection-view layout.
///
/// NSCollectionView can invalidate item layout without resolving it synchronously,
/// so visible-item queries and focus scrolling immediately after a reload-class
/// apply can observe an empty pass. The queue keeps one newest closure per closed
/// work kind, flushes layout when the host is ready, and owns the one-shot main-turn
/// hop used by `viewDidLayout`.
@MainActor
final class GridPostLayoutWorkQueue {
    enum Readiness { case ranNow, deferred }
    enum WorkKind: Hashable { case focusScroll, detailAndPreheat }

    private let isReady: () -> Bool
    private let flushLayout: () -> Void
    private var pending: [WorkKind: () -> Void] = [:]
    private var deferredTurnScheduled = false

    init(
        isReady: @escaping () -> Bool,
        flushLayout: @escaping () -> Void
    ) {
        self.isReady = isReady
        self.flushLayout = flushLayout
    }

    convenience init(collectionView: NSCollectionView) {
        self.init(
            isReady: { collectionView.frame.width > 0 && collectionView.window != nil },
            flushLayout: { collectionView.layoutSubtreeIfNeeded() }
        )
    }

    @discardableResult
    func submit(
        _ kind: WorkKind,
        reason _: String,
        work: @escaping () -> Void
    ) -> Readiness {
        guard isReady() else {
            pending[kind] = work
            return .deferred
        }
        flushLayout()
        work()
        return .ranNow
    }

    func runDeferredWork() {
        guard !pending.isEmpty, !deferredTurnScheduled else { return }
        deferredTurnScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            deferredTurnScheduled = false
            guard isReady() else { return }
            flushLayout()
            let work = pending.values
            pending.removeAll()
            work.forEach { $0() }
        }
    }
}

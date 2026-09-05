import AppKit

// Grid day bar guide
//
// DES-069 asks for a date on screen at all times under Date sort. The obvious
// mechanism — `pinToVisibleBounds` on the day header — is the one this grid does not
// use, and `MediaGridPresentation.swift` records why: pinning moves every header of a
// section into the scroll view's floating-subviews container, where AppKit recomputes
// its frame from the main thread on each bounds change while the tiles move on the
// compositor, and it installs an `NSScrollPocket` whose live blur of the passing tiles
// has no public opt-out on macOS 26+. Evidence, and the eight alternatives weighed
// against it, are in
// `docs/research/2026-09-04-grid-day-header-pinning-and-scroll-edge-effect.md`.
//
// So the bar is the app's own view, held at the top edge by constraints that never
// change. Its frame is constant; only its text and its alpha move. There is nothing
// for main-thread latency to desynchronise.
//
// Ownership split, matching the rest of this boundary: `MediaGridDayBarPolicy`
// (`MediaGridSupport.swift`) owns the *rule* — which day, and whether the bar shows at
// all — as a pure function; this file owns only reading the geometry the rule needs
// out of the layout. That is what makes DES-069's behavior testable without driving a
// live collection view, which the pinned-header design never was (APP-030 carried the
// gap as `unverified:`).

extension MediaGridViewController {
    /// Re-resolves what the day bar shows. Called from the coalesced scroll flush, the
    /// post-apply pass, and `viewDidLayout` — every path that can move a header
    /// relative to the viewport. Cheap and idempotent: one layout query plus a pure
    /// decision, and `render` no-ops when nothing changed.
    func updateDayBar() {
        guard !presentation.isStrip else {
            return
        }
        dayBar.render(
            MediaGridDayBarPolicy.barPresentation(
                topEdge: dayBarTopEdge(),
                viewportMinY: scrollView.documentVisibleRect.minY
            )
        )
    }

    /// The geometry `MediaGridDayBarPolicy` decides from: the day section holding the
    /// topmost visible item, where its own header sits, and the day before it.
    ///
    /// Geometry comes from the layout, not from `indexPathsForVisibleItems()`, for the
    /// reason `captureScrollAnchor` documents: realized cells are a rendering fact, and
    /// they answer "index 0" for a grid that has scrolled but not yet dequeued. The
    /// layout's attributes are a pure function of position. One
    /// `layoutAttributesForElements` call answers both the topmost item and its
    /// section's header; the preceding day comes from `appliedDaySections`, which is
    /// why neither reader needs `dataSource.snapshot()`.
    private func dayBarTopEdge() -> MediaGridDayBarPolicy.TopEdge? {
        guard let layout = collectionView.collectionViewLayout else {
            return nil
        }
        let viewport = scrollView.documentVisibleRect
        guard viewport.height > 0 else {
            return nil
        }
        // Settles the layout so the attributes read below are the current ones.
        _ = layout.collectionViewContentSize
        let attributes = layout.layoutAttributesForElements(in: viewport)
        let topmostItem = attributes
            .filter { $0.representedElementCategory == .item }
            .min { lhs, rhs in
                lhs.frame.minY == rhs.frame.minY
                    ? lhs.frame.minX < rhs.frame.minX
                    : lhs.frame.minY < rhs.frame.minY
            }
        guard let section = topmostItem?.indexPath?.section,
              let day = appliedDay(at: section)
        else {
            return nil
        }
        let headerMinY = attributes.first {
            $0.representedElementCategory == .supplementaryView
                && $0.representedElementKind == MediaGridDayHeaderView.elementKind
                && $0.indexPath?.section == section
        }?.frame.minY
        return MediaGridDayBarPolicy.TopEdge(
            day: day,
            headerMinY: headerMinY,
            precedingDay: section > 0 ? appliedDay(at: section - 1) : nil
        )
    }

    private func appliedDay(at section: Int) -> MediaGridDayBarPolicy.Day? {
        guard section >= 0, section < appliedDaySections.count,
              let applied = appliedDaySections[section]
        else {
            return nil
        }
        return MediaGridDayBarPolicy.Day(date: applied.date, itemCount: applied.itemCount)
    }
}

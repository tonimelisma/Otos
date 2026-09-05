import AppKit

// Grid day bar guide
//
// DES-069 asks for a date on screen at all times under Date sort. The obvious
// mechanism — `pinToVisibleBounds` on a day header — is the one this grid does not
// use, and `MediaGridPresentation.swift` records why: pinning moves every header of a
// section into the scroll view's floating-subviews container, where AppKit recomputes
// its frame from the main thread on each bounds change while the tiles move on the
// compositor, and it installs an `NSScrollPocket` whose live blur of the passing tiles
// has no public opt-out on macOS 26+. Evidence, and the alternatives weighed against
// this one, are in
// `docs/research/2026-09-04-grid-day-header-pinning-and-scroll-edge-effect.md`.
//
// So the bar is the app's own view, held at the top edge by constraints that never
// change. Its frame is constant; only its text and its alpha move. There is nothing
// for main-thread latency to desynchronise.
//
// It is also the *only* rendering of the day: there is no in-flow header under it.
// The grid reserves the bar's height as a top content inset, so nothing hides beneath
// it at rest and tiles pass under it once scrolling starts.
//
// Ownership split, matching the rest of this boundary: `MediaGridDayBarPolicy`
// (`MediaGridSupport.swift`) owns what the bar says as a pure function; this file
// owns only reading, out of the layout, which section sits at the top. That is what
// makes DES-069's behavior testable without driving a live collection view, which the
// pinned-header design never was (APP-030 carried the gap as `unverified:`).

extension MediaGridViewController {
    /// Re-resolves what the day bar shows. Called from the coalesced scroll flush, the
    /// post-apply pass, and `viewDidLayout` — every path that can change which section
    /// is at the top. Cheap and idempotent: one layout query plus a pure decision, and
    /// `render` no-ops when nothing changed.
    func updateDayBar() {
        guard !presentation.isStrip else {
            return
        }
        dayBar.render(
            MediaGridDayBarPolicy.barPresentation(
                days: appliedDaySections,
                topmostSection: topmostVisibleSection()
            )
        )
    }

    /// Reserves the bar's height at the top of the scrollable content, so the first
    /// row starts below the bar rather than under it. Read from the laid-out bar
    /// rather than a constant, because the bar sizes itself to its SwiftUI content and
    /// therefore to the user's text size. Guarded against a no-op write: assigning
    /// `contentInsets` invalidates layout, and this runs from `viewDidLayout`.
    func updateDayBarContentInset() {
        guard !presentation.isStrip else {
            return
        }
        let reserved = dayBar.frame.height
        guard abs(scrollView.contentInsets.top - reserved) > 0.5 else {
            return
        }
        scrollView.contentInsets.top = reserved
    }

    /// The section holding the topmost visible item.
    ///
    /// Geometry comes from the layout, not from `indexPathsForVisibleItems()`, for the
    /// reason `captureScrollAnchor` documents: realized cells are a rendering fact, and
    /// they answer "index 0" for a grid that has scrolled but not yet dequeued. The
    /// layout's attributes are a pure function of position.
    private func topmostVisibleSection() -> Int? {
        guard let layout = collectionView.collectionViewLayout else {
            return nil
        }
        let viewport = scrollView.documentVisibleRect
        guard viewport.height > 0 else {
            return nil
        }
        // Settles the layout so the attributes read below are the current ones.
        _ = layout.collectionViewContentSize
        return layout.layoutAttributesForElements(in: viewport)
            .filter { $0.representedElementCategory == .item }
            .min { lhs, rhs in
                lhs.frame.minY == rhs.frame.minY
                    ? lhs.frame.minX < rhs.frame.minX
                    : lhs.frame.minY < rhs.frame.minY
            }?
            .indexPath?
            .section
    }
}

import AppKit
import SwiftUI

/// DES-069 grid day header display, pure from `(date, itemCount)`. `date == nil`
/// pairs with `MediaGridViewController.Section.day(nil)` — assets whose capture
/// date is unknown are still grouped into their own header rather than dropped
/// from the day structure.
nonisolated struct MediaGridDayHeaderPresentation: Equatable, Sendable {
    let dateText: String
    let countText: String

    static func map(
        date: Date?,
        itemCount: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> MediaGridDayHeaderPresentation {
        let dateText = date.map {
            RelativeDateText.string(for: $0, now: now, calendar: calendar)
        } ?? "No Date"
        let countText = itemCount == 1 ? "1 item" : "\(itemCount) items"
        return MediaGridDayHeaderPresentation(dateText: dateText, countText: countText)
    }
}

/// Where one day line is being drawn. The two roles render the same strings and
/// differ only in surface: the in-flow header is a group header *inside* content
/// (DES-003) and paints no surface of its own, while the day bar floats above
/// scrolling tiles and is therefore chrome — DES-022's `bar` value with a DES-023
/// hairline under it, so tiles passing beneath are covered rather than blended.
nonisolated enum MediaGridDayLineSurface: Equatable, Sendable {
    case inFlowHeader
    case floatingBar
}

private struct MediaGridDayLineContent: View {
    let presentation: MediaGridDayHeaderPresentation
    let surface: MediaGridDayLineSurface
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(presentation.dateText)
                .font(.headline)
                .foregroundStyle(DesignPalette.label(for: colorScheme))
            Text(presentation.countText)
                .font(.subheadline)
                .foregroundStyle(DesignPalette.l3(for: colorScheme))
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(alignment: .bottom) {
            if surface == .floatingBar {
                DesignPalette.hairline(for: colorScheme)
                    .frame(height: 1)
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        switch surface {
        case .inFlowHeader:
            // Deliberately no surface. The grid paints no content background of its
            // own (`backgroundColors = [.clear]`, `drawsBackground = false`), so a
            // filled header would read as a slab floating on the window rather than
            // as a group header sitting among the tiles.
            Color.clear
        case .floatingBar:
            DesignPalette.bar(for: colorScheme)
        }
    }
}

/// The in-flow day header (DES-069): a low-cardinality view (one per day, not one
/// per tile) hosting SwiftUI so it can reuse `DesignPalette`'s dynamic-appearance
/// colors directly, unlike the tiles this grid otherwise renders in pure AppKit
/// for reuse-cost reasons that don't apply at this cardinality.
///
/// It scrolls with its own run and is **not** pinned. `pinToVisibleBounds` moves
/// every header of a section out of the collection view into the scroll view's
/// floating-subviews container, where AppKit repositions it from the main thread on
/// each bounds change while the tiles move on the compositor — two clocks driving
/// two things that must stay glued together — and installs an `NSScrollPocket`
/// whose live blur portal of the passing tiles cannot be declined through any
/// public API. `MediaGridDayBarView` keeps a date on screen instead; see
/// `docs/research/2026-09-04-grid-day-header-pinning-and-scroll-edge-effect.md`.
final class MediaGridDayHeaderView: NSView, NSCollectionViewElement {
    static let elementKind = "MediaGridDayHeader"

    private let hostingView = NSHostingView(
        rootView: MediaGridDayLineContent(
            presentation: MediaGridDayHeaderPresentation(dateText: "", countText: ""),
            surface: .inFlowHeader
        )
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ presentation: MediaGridDayHeaderPresentation) {
        hostingView.rootView = MediaGridDayLineContent(
            presentation: presentation,
            surface: .inFlowHeader
        )
    }
}

/// The day bar (DES-069): one instance per grid, owned by the controller, held at
/// the top edge of the grid by constraints that never change. Its frame is constant
/// by construction, so unlike a pinned supplementary it cannot fall behind the tiles
/// under main-thread load — only its text and its alpha change.
///
/// It names the day that owns the viewport's top edge, which is the rule a pinned
/// header implements implicitly. Where that day's own header is clipped or gone, the
/// bar sits exactly over it and covers rather than duplicates it; the bar hides only
/// at the very start of the grid, where the first header is fully visible and names
/// the day itself ("One fact, one owner"). `MediaGridDayBarPolicy` owns that rule.
final class MediaGridDayBarView: NSView {
    private let hostingView = NSHostingView(
        rootView: MediaGridDayLineContent(
            presentation: MediaGridDayHeaderPresentation(dateText: "", countText: ""),
            surface: .floatingBar
        )
    )
    private var presentation: MediaGridDayHeaderPresentation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        alphaValue = 0
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The bar is decoration over the grid's own content: it must never take a click
    /// meant for the tile beneath it, and it is not a keyboard stop.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    /// `nil` hides the bar. Both the text swap and the fade are idempotent, so this
    /// can be called on every coalesced scroll flush without churn.
    func render(_ next: MediaGridDayHeaderPresentation?) {
        if let next, next != presentation {
            presentation = next
            hostingView.rootView = MediaGridDayLineContent(
                presentation: next,
                surface: .floatingBar
            )
        }
        let target: CGFloat = next == nil ? 0 : 1
        guard abs(alphaValue - target) > 0.001 else {
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MediaGridAnimation.dayBarFadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = target
        }
    }
}

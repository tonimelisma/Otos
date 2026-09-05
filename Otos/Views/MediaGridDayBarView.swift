import AppKit
import SwiftUI

/// DES-069 day bar display, pure from `(date, itemCount)`. `date == nil` pairs with
/// `MediaGridViewController.Section.day(nil)` — assets whose capture date is unknown
/// are still grouped into their own section rather than dropped from the day
/// structure, and the bar names that section "No Date" like any other.
nonisolated struct MediaGridDayBarPresentation: Equatable, Sendable {
    let dateText: String
    let countText: String

    static func map(
        date: Date?,
        itemCount: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> MediaGridDayBarPresentation {
        let dateText = date.map {
            RelativeDateText.string(for: $0, now: now, calendar: calendar)
        } ?? "No Date"
        let countText = itemCount == 1 ? "1 item" : "\(itemCount) items"
        return MediaGridDayBarPresentation(dateText: dateText, countText: countText)
    }
}

private struct MediaGridDayBarContent: View {
    let presentation: MediaGridDayBarPresentation
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
        // DES-022 elevation order: the bar floats above the grid's content surface,
        // so it takes the `bar` value and is a step lighter than what scrolls beneath
        // it, closed off by a DES-023 hairline. Opaque, so tiles pass under it rather
        // than through it.
        .background(DesignPalette.bar(for: colorScheme))
        .overlay(alignment: .bottom) {
            DesignPalette.hairline(for: colorScheme)
                .frame(height: 1)
        }
    }
}

/// The day bar (DES-069): the grid's **only** rendering of the current day.
///
/// One instance per grid, owned by the controller, held at the top edge by
/// constraints that never change. Its frame is constant by construction, so unlike a
/// pinned supplementary it cannot fall behind the tiles under main-thread load —
/// only its text and its alpha change.
///
/// There is deliberately no in-flow day header beneath it. Two renderings of one
/// day is what "One fact, one owner" forbids, and it is what the previous design
/// could not keep straight: the two carried different surfaces, and at a day
/// boundary the bar and the incoming header stacked and disagreed. A pinned header
/// avoids that only because the pinned thing *is* the section's header — a trick
/// unavailable here, because `pinToVisibleBounds` is what caused the flicker and the
/// lag in the first place. Removing one of the two renderings resolves it by
/// construction rather than by rule. Day runs stay legible through the section inset
/// (DES-060). See
/// `docs/research/2026-09-04-grid-day-header-pinning-and-scroll-edge-effect.md`.
final class MediaGridDayBarView: NSView {
    private let hostingView = NSHostingView(
        rootView: MediaGridDayBarContent(
            presentation: MediaGridDayBarPresentation(dateText: "", countText: "")
        )
    )
    private var presentation: MediaGridDayBarPresentation?

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

    /// `nil` hides the bar — the grid has no day structure to name, which is every
    /// sort but Date. Both the text swap and the fade are idempotent, so this can be
    /// called on every coalesced scroll flush without churn.
    func render(_ next: MediaGridDayBarPresentation?) {
        if let next, next != presentation {
            presentation = next
            hostingView.rootView = MediaGridDayBarContent(presentation: next)
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

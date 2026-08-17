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

private struct MediaGridDayHeaderContent: View {
    let presentation: MediaGridDayHeaderPresentation
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
        .background(DesignPalette.content(for: colorScheme))
    }
}

/// Pinned section header (DES-069): a low-cardinality view (one per day, not one
/// per tile) hosting SwiftUI so it can reuse `DesignPalette`'s dynamic-appearance
/// colors directly, unlike the tiles this grid otherwise renders in pure AppKit
/// for reuse-cost reasons that don't apply at this cardinality.
final class MediaGridDayHeaderView: NSView, NSCollectionViewElement {
    static let elementKind = "MediaGridDayHeader"

    private let hostingView = NSHostingView(
        rootView: MediaGridDayHeaderContent(presentation: MediaGridDayHeaderPresentation(dateText: "", countText: ""))
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
        hostingView.rootView = MediaGridDayHeaderContent(presentation: presentation)
    }
}

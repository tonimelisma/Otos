import AppKit
import SwiftUI

/// DES-069 day label display, pure from `(date, itemCount)`. `date == nil` pairs with
/// `MediaGridStructure.SectionKey.day(nil)` — assets whose capture date is unknown
/// are still grouped into their own section rather than dropped from the day
/// structure, and the label names that section "No Date" like any other.
nonisolated struct MediaGridDayLabelPresentation: Equatable, Sendable {
    let dateText: String
    let countText: String

    static func map(
        date: Date?,
        itemCount: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> MediaGridDayLabelPresentation {
        let dateText = date.map {
            RelativeDateText.string(for: $0, now: now, calendar: calendar)
        } ?? "No Date"
        let countText = itemCount == 1 ? "1 item" : "\(itemCount) items"
        return MediaGridDayLabelPresentation(dateText: dateText, countText: countText)
    }
}

/// The one day label, drawn identically wherever it appears.
///
/// A day is named twice — once in flow at the head of its run, once by the bar held
/// at the top edge — and those are the same label at two moments, not two kinds of
/// object. So there is exactly one view of it, and neither host may restyle it. The
/// previous design gave the bar DES-022's `bar` value and left the header bare, and
/// the two immediately read as unrelated things that happened to be near each other.
///
/// The surface is `content`, opaque. Opaque because the bar must cover tiles passing
/// beneath rather than blend with them; `content` because this is not chrome — it is
/// the section's header, held in place.
///
/// `showsHairline` is the one thing that may differ between drawings, and it is not
/// part of the label: it is the DES-023 rule that closes the label off from what sits
/// below it. An in-flow header draws it as a day separator, so a run reads as a run.
/// The bar draws it as a scroll edge, and only once the grid has moved off its top —
/// the contextual behavior macOS gives the titlebar, where `NSTitlebarSeparatorStyle`
/// has defaulted to `.automatic` since macOS 11, showing a line beneath the titlebar
/// while content is scrolled under it and hiding it at the top. A blank header (the
/// first section's) draws neither label nor rule.
private struct MediaGridDayLabelContent: View {
    /// `nil` draws the label's space and nothing in it. The first section's header
    /// takes this: the bar already covers its rect, so its text would only ever be
    /// seen when rubber-band scrolling pushes it out from under the bar as a duplicate.
    let presentation: MediaGridDayLabelPresentation?
    var showsHairline = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let presentation {
                Text(presentation.dateText)
                    .font(.headline)
                    .foregroundStyle(DesignPalette.label(for: colorScheme))
                Text(presentation.countText)
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.content(for: colorScheme))
        .overlay(alignment: .bottom) {
            if showsHairline {
                DesignPalette.hairline(for: colorScheme)
                    .frame(height: 1)
            }
        }
    }
}

/// Hosts `MediaGridDayLabelContent` at a fixed size in an AppKit view. Both the
/// in-flow header and the top bar are this plus a host-specific role, so the two
/// cannot drift apart.
private final class MediaGridDayLabelHost: NSView {
    private let hostingView = NSHostingView(
        rootView: MediaGridDayLabelContent(presentation: nil)
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

    func render(_ presentation: MediaGridDayLabelPresentation?, showsHairline: Bool) {
        hostingView.rootView = MediaGridDayLabelContent(
            presentation: presentation,
            showsHairline: showsHairline
        )
    }
}

/// The in-flow day header (DES-069): one per day section, at the head of its run,
/// scrolling with it.
///
/// It is deliberately **not** pinned. `pinToVisibleBounds` does not stick the current
/// header; it moves every header of the section out of the collection view into the
/// scroll view's floating-subviews container, where AppKit repositions it from the
/// main thread on each bounds change while the tiles move on the compositor — so it
/// slides against its own run — and it installs an `NSScrollPocket` whose live blur
/// portal of the passing tiles has no public opt-out on macOS 26+.
/// `MediaGridDayBarView` holds the current day at the top instead. See
/// `docs/research/2026-09-04-grid-day-header-pinning-and-scroll-edge-effect.md`.
final class MediaGridDayHeaderView: NSView, NSCollectionViewElement {
    static let elementKind = "MediaGridDayHeader"

    private let label = MediaGridDayLabelHost()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The layout's frame, as given: every header is `height` tall and the grid's width,
    /// so AppKit need not fit its constraints each time it realizes one.
    func preferredLayoutAttributesFitting(
        _ layoutAttributes: NSCollectionViewLayoutAttributes
    ) -> NSCollectionViewLayoutAttributes {
        layoutAttributes
    }

    /// Every header's height, and the bar's (DES-069: one label drawn twice): the label's
    /// own fitting height with a date and a count in it, measured once.
    ///
    /// A fixed height rather than a self-sized one, for two measured reasons. The blank
    /// first header self-sized to its padding alone (12 pt against the label's 28 pt), so
    /// the bar resting on it covered the top of the first row instead of the space DES-069
    /// reserves. And fitting a header per section is half the layout's work on every
    /// reload: 5.96 G instructions for 5,097 day sections self-sized against 2.72 G fixed
    /// (`docs/research/2026-11-14-grid-structure-without-diffable-snapshot.md`).
    static let height: CGFloat = {
        let header = MediaGridDayHeaderView()
        header.configure(.map(date: Date(timeIntervalSince1970: 0), itemCount: 1))
        return header.fittingSize.height
    }()

    /// The label this header currently draws; `nil` is a blank header.
    private(set) var presentation: MediaGridDayLabelPresentation?

    /// A drawn header closes its run off with the DES-023 rule. `nil` leaves the
    /// header's space blank — no label and no rule.
    func configure(_ presentation: MediaGridDayLabelPresentation?) {
        self.presentation = presentation
        label.render(presentation, showsHairline: presentation != nil)
    }
}

/// The day bar (DES-069): the same label, held at the grid's top edge.
///
/// It is a copy of the header for whichever day owns the viewport's top edge, drawn
/// with the identical treatment at the identical horizontal position: as a run
/// scrolls, its header slides underneath and the bar keeps its place. That is a
/// pinned header, implemented here rather than by AppKit — and because this view is
/// held by constraints that never change, its frame cannot fall behind the tiles the
/// way a floating supplementary's does.
///
/// It reserves no space, and it withdraws rather than doubling up: while a day's own
/// header is still fully visible below the top edge, that header is the rendering and
/// the bar shows the day being left, or nothing at all at the very top of the grid.
final class MediaGridDayBarView: NSView {
    private let label = MediaGridDayLabelHost()
    private var presentation: MediaGridDayLabelPresentation?
    private var rendersHairline = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        alphaValue = 0
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The bar is a rendering of content, not a control: it must never take a click
    /// meant for the tile beneath it, and it is not a keyboard stop.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    /// `nil` hides the bar — the grid has no day structure to name, which is every
    /// sort but Date. Under Date sort the bar is on continuously, including at the top
    /// of the grid where it rests exactly on the first section's header and draws the
    /// same label in the same rect. Idempotent, so this can be called on every scroll
    /// tick without churn.
    ///
    /// Deliberately unanimated. The bar and the header behind it occupy the same rect
    /// and draw the same label, so there is no change of position or state for motion
    /// to explain (DES-070); a cross-fade only put the two at partial alpha over each
    /// other, which read as the label sliding.
    func render(_ next: MediaGridDayLabelPresentation?, showsHairline: Bool) {
        if let next, next != presentation || showsHairline != rendersHairline {
            presentation = next
            rendersHairline = showsHairline
            label.render(next, showsHairline: showsHairline)
        }
        alphaValue = next == nil ? 0 : 1
    }
}

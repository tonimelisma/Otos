import AppKit

// Grid scrub label guide
//
// While the user drags the grid's scroller knob, a label beside the knob names where the
// drag has reached (DES-123): the day owning the viewport's top edge, the same day the day
// bar names, told only as finely as the scroller can pick — a year, a month, or a day. A
// knob point that crosses months cannot pick a day, so the label does not pretend to.
//
// Ownership: `MediaGridScrubPolicy` is the pure rule (granularity and words);
// `MediaGridScroller` reports when its knob is being dragged; the view controller
// (`MediaGridDayBar.swift`) places and fills `MediaGridScrubLabelView` from the same top
// edge the day bar reads, so the label and the bar never name different days.

/// How finely the scrub label names a date, and its words.
nonisolated enum MediaGridScrubPolicy {
    enum Granularity: Equatable, Sendable {
        case year
        case month
        case day
    }

    /// One knob point covers `span / trackHeight` of the grid's dates. A point that covers
    /// a month or more can only pick a year; one that covers a day or more can pick a
    /// month; finer than that, a day.
    static func granularity(span: TimeInterval, trackHeight: CGFloat) -> Granularity {
        guard trackHeight > 0 else {
            return .day
        }
        let perPoint = span / Double(trackHeight)
        let day: TimeInterval = 86400
        if perPoint >= 30 * day {
            return .year
        }
        if perPoint >= day {
            return .month
        }
        return .day
    }

    /// The span of the grid's dated days, earliest to latest; zero with fewer than two.
    static func span(of dates: some Sequence<Date>) -> TimeInterval {
        var earliest: Date?
        var latest: Date?
        for date in dates {
            earliest = min(earliest ?? date, date)
            latest = max(latest ?? date, date)
        }
        guard let earliest, let latest else {
            return 0
        }
        return latest.timeIntervalSince(earliest)
    }

    /// `2020`, `May 2020` or `May 28, 2020`; an undated day reads as the day bar does.
    static func text(for date: Date?, granularity: Granularity, locale: Locale = .current) -> String {
        guard let date else {
            return "No Date"
        }
        let style = switch granularity {
        case .year: Date.FormatStyle(locale: locale).year()
        case .month: Date.FormatStyle(locale: locale).month(.wide).year()
        case .day: Date.FormatStyle(locale: locale).month(.wide).day().year()
        }
        return date.formatted(style)
    }
}

/// The grid's vertical scroller. It reports a knob drag's start and end, which AppKit's
/// live-scroll notifications cannot tell apart from a trackpad gesture.
final class MediaGridScroller: NSScroller {
    /// Called with `true` as a knob drag starts and `false` as it ends.
    var onKnobTracking: ((Bool) -> Void)?

    /// `trackKnob` runs the drag's own event loop and returns when the mouse goes up, so
    /// the scroll ticks of the drag all arrive between the two reports.
    override func trackKnob(with event: NSEvent) {
        onKnobTracking?(true)
        super.trackKnob(with: event)
        onKnobTracking?(false)
    }
}

/// The scrub label: a small plate beside the knob. A rendering, never a control.
final class MediaGridScrubLabelView: NSView {
    private let plate = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    static let gapToScroller: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        plate.material = .popover
        plate.blendingMode = .withinWindow
        plate.state = .active
        plate.wantsLayer = true
        plate.layer?.cornerRadius = 6
        plate.layer?.masksToBounds = true
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .labelColor
        label.alignment = .center
        addSubview(plate)
        plate.addSubview(label)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    /// Shows `text` with its trailing edge `gapToScroller` short of `trailingX`, centred
    /// on `centerY`, inside `bounds`. Unanimated: it follows the knob, which does not
    /// animate either.
    func show(_ text: String, trailingX: CGFloat, centerY: CGFloat, within bounds: CGRect) {
        if label.stringValue != text {
            label.stringValue = text
        }
        let textSize = label.fittingSize
        let size = CGSize(width: ceil(textSize.width) + 20, height: ceil(textSize.height) + 8)
        var origin = CGPoint(x: trailingX - Self.gapToScroller - size.width, y: centerY - size.height / 2)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        frame = CGRect(origin: origin, size: size)
        plate.frame = self.bounds
        label.frame = CGRect(x: 10, y: (size.height - ceil(textSize.height)) / 2, width: ceil(textSize.width), height: ceil(textSize.height))
        isHidden = false
    }

    func hide() {
        isHidden = true
    }
}

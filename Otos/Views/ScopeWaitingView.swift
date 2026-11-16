import AppKit
import SwiftUI

// Scope waiting pane guide (DES-118, APP-084)
//
// What the detail pane draws from a sidebar click until the selected scope's state is
// applied (`CatalogDetailPane.Content.waiting`): the selected surface's bar, at its height,
// with what is known without the scope's read, over an empty content area — nothing of the
// scope the user left. The view is passive: the view model says which surface waits and
// whether its indicator shows, and the view reports one fact back, that a frame showing it
// was presented (`FramePresentedReporter`), which is when the indicator appears. A scope
// whose state arrives within the frame of the click is never drawn with one.
//
// While the catalog opens (DES-121) every scope waits, and the indicator carries the open's
// status in words — `Opening catalog…`, or `Updating catalog…` with the step a migration is
// on — from the same presented frame, so a launch the first frame outlasts says what it is
// doing and one that finishes within it shows nothing.

/// The words under the waiting indicator while the catalog opens (DES-121): L1 the open's
/// present participle, L3 which update of how many runs. Updates are steps of unequal
/// cost, so they name where the open is and the indicator stays indeterminate.
struct CatalogOpeningPresentation: Equatable {
    let title: String
    /// Empty when there is nothing to qualify the title with; the line keeps its height.
    let detail: String
    let isFailed: Bool

    init(opening: CatalogOpening, failed: Bool) {
        if failed {
            title = "Couldn\u{2019}t open the catalog"
            detail = ""
            isFailed = true
            return
        }
        isFailed = false
        switch opening.phase {
        case .opening:
            title = "Opening catalog\u{2026}"
            detail = ""
        case let .updating(step, total):
            title = "Updating catalog\u{2026}"
            detail = total > 1 ? "Step \(step) of \(total)" : ""
        }
    }

    /// What VoiceOver reads for the status: both lines, as one element.
    var accessibilityLabel: String {
        detail.isEmpty ? title : "\(title), \(detail)"
    }
}

/// The selected surface's bar while its scope's state has not arrived.
enum ScopeWaitingBar {
    /// The media browser: its day bar names the day under the grid's top edge, and there is
    /// no grid yet, so there is nothing to name.
    case none
    /// The Places bar with no count: the count is the scope's read (DES-105).
    case places
    /// On This Day's bar: the day is today, which the window holds; what it holds is the
    /// scope's read (DES-112).
    case onThisDay(CalendarDay)
    /// The People bar from the People that is the same in every scope; nil before it is
    /// first built (DES-109).
    case people(CatalogPeopleState?)
    /// The duplicates bar from the groups that are the same in every scope, its act disabled
    /// (DES-107); nil before they are first built.
    case duplicates(DuplicatesBarPresentation?, DuplicatesActions)
}

struct ScopeWaitingView: View {
    let bar: ScopeWaitingBar
    /// The selected scope's name, the window's title: what VoiceOver says the indicator is
    /// waiting for (DES-082).
    let title: String
    let showsIndicator: Bool
    /// The catalog's open status, while it opens (DES-121).
    var opening: CatalogOpeningPresentation?
    let framePresented: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                DesignPalette.content(for: colorScheme)
                // DES-086's one indeterminate indicator, centered, moving while shown (DES-072).
                if showsIndicator {
                    if let opening {
                        CatalogOpeningStatusView(opening: opening)
                    } else {
                        ProgressView()
                            .controlSize(.regular)
                            .accessibilityLabel(title)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomBar
        }
        .background {
            if !showsIndicator {
                FramePresentedReporter(presented: framePresented)
            }
        }
    }

    @ViewBuilder
    private var topBar: some View {
        switch bar {
        case .none, .duplicates:
            EmptyView()
        case .places:
            PlacesMapBar(locatedCount: nil)
        case let .onThisDay(day):
            OnThisDayBar(day: day, summary: "")
        case let .people(people):
            PeopleBar(people: people)
            Rectangle()
                .fill(DesignPalette.hairline(for: colorScheme))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if case let .duplicates(presentation?, actions) = bar {
            Rectangle()
                .fill(DesignPalette.hairline(for: colorScheme))
                .frame(height: 1)
            DuplicatesStatusBar(presentation: presentation, actions: actions)
                .disabled(true)
        }
    }
}

/// The catalog's open status at the waiting pane's center: the indicator, then L1 and L3 at
/// one height in every state (DES-053), the indicator's place held when the open failed.
struct CatalogOpeningStatusView: View {
    let opening: CatalogOpeningPresentation

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                if !opening.isFailed {
                    ProgressView()
                        .controlSize(.regular)
                }
            }
            .frame(width: 32, height: 32)
            Text(opening.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(DesignPalette.label(for: colorScheme))
            Text(opening.detail.isEmpty ? " " : opening.detail)
                .font(.subheadline)
                .foregroundStyle(DesignPalette.l3(for: colorScheme))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(opening.accessibilityLabel)
    }
}

/// Reports, once, that a frame showing it has been presented: the first callback of its
/// display link after it joined a window, which comes at the display refresh after the
/// transaction that added it was committed. A platform report, not a timer: an occluded or
/// minimized window presents nothing, so nothing is reported, and nothing needs to be.
struct FramePresentedReporter: NSViewRepresentable {
    let presented: () -> Void

    func makeNSView(context _: Context) -> ReporterView {
        let view = ReporterView()
        view.presented = presented
        return view
    }

    func updateNSView(_ view: ReporterView, context _: Context) {
        view.presented = presented
    }

    static func dismantleNSView(_ view: ReporterView, coordinator _: ()) {
        view.stop()
    }

    final class ReporterView: NSView {
        var presented: () -> Void = {}
        private var link: CADisplayLink?
        private var reported = false

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil, !reported else {
                return
            }
            let link = displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        @objc private func step(_: CADisplayLink) {
            stop()
            guard !reported else {
                return
            }
            reported = true
            presented()
        }
    }
}

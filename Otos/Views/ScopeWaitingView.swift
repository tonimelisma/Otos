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
    let framePresented: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                DesignPalette.content(for: colorScheme)
                // DES-086's one indeterminate indicator, centered, moving while shown (DES-072).
                if showsIndicator {
                    ProgressView()
                        .controlSize(.regular)
                        .accessibilityLabel(title)
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

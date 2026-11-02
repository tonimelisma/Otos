import AppKit
@testable import OtosKit
import SwiftUI
import Testing

extension AppKitWindowTests {
    /// APP-058: on the Places map the view-mode picker selects no segment — the map is not
    /// one of the modes — and choosing one still delivers that mode. Read from the
    /// segmented control AppKit actually draws, not from the SwiftUI value.
    @MainActor
    struct ViewModePickerTests {
        @Test func theMapSelectsNoSegmentAndAModeSelectsItsOwn() throws {
            #expect(try selectedSegment(showing: nil) == -1)
            #expect(try selectedSegment(showing: .grid) == 0)
            #expect(try selectedSegment(showing: .loupe) == 1)
            #expect(try selectedSegment(showing: .compare) == 2)
        }

        @Test func choosingASegmentOnTheMapDeliversThatMode() throws {
            var chosen: [BrowserViewMode] = []
            let host = NSHostingView(rootView: ViewModePicker(viewMode: nil) { chosen.append($0) })
            let window = orderedInTestWindow(width: 300, height: 60, contentView: host)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            let control = try #require(segmentedControl(in: host))

            control.selectedSegment = 1
            _ = control.sendAction(control.action, to: control.target)

            #expect(chosen == [.loupe])
        }

        private func selectedSegment(showing mode: BrowserViewMode?) throws -> Int {
            let host = NSHostingView(rootView: ViewModePicker(viewMode: mode) { _ in })
            let window = orderedInTestWindow(width: 300, height: 60, contentView: host)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            let control = try #require(segmentedControl(in: host))
            #expect(control.segmentCount == BrowserViewMode.allCases.count)
            return control.selectedSegment
        }

        private func segmentedControl(in view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl {
                return control
            }
            for subview in view.subviews {
                if let control = segmentedControl(in: subview) {
                    return control
                }
            }
            return nil
        }
    }
}

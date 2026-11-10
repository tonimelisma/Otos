import AppKit
@testable import OtosKit
import SwiftUI
import Testing

extension AppKitWindowTests {
    /// APP-068 and DES-108: the main window's toolbar search field, read from the
    /// `NSSearchField` AppKit puts in the window's toolbar. Typing reaches the view model's
    /// search, and Edit ▸ Find's intent puts the keyboard in the field.
    @MainActor
    struct SearchFieldWindowTests {
        @Test func typingInTheToolbarFieldSearchesAndFindFocusesIt() async throws {
            let model = CatalogWindowViewModel(
                catalogStore: CatalogStore(location: .inMemory),
                startsStallMonitor: false,
                startsEnrichment: false,
                startsSourceMonitoring: false,
                preferencesDomain: .suite(UUID().uuidString),
                volumeCapacity: ampleVolumeCapacity,
                trashFiles: .refusing
            )
            let controller = NSHostingController(rootView: ContentView(viewModel: model))
            controller.sceneBridgingOptions = [.toolbars]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .resizable]
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.setFrame(NSRect(x: -4000, y: -4000, width: 1100, height: 700), display: true)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }

            let field = try await waitForValue { searchField(in: window) }
            #expect(field.placeholderString == "Search")

            // Typed as a user types: into the field editor, whose edits the search binding
            // listens to.
            #expect(window.makeFirstResponder(field))
            let editor = try #require(window.firstResponder as? NSTextView)
            editor.insertText("dog", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await waitUntil { model.searchText == "dog" }

            window.makeFirstResponder(nil)
            model.focusSearch()
            try await waitUntil { isEditing(field, in: window) }
        }

        private func searchField(in window: NSWindow) -> NSSearchField? {
            for item in window.toolbar?.items ?? [] {
                if let search = item as? NSSearchToolbarItem {
                    return search.searchField
                }
                if let field = item.view.flatMap(firstSearchField(in:)) {
                    return field
                }
            }
            return nil
        }

        private func firstSearchField(in view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField {
                return field
            }
            return view.subviews.lazy.compactMap(firstSearchField(in:)).first
        }

        private func isEditing(_ field: NSSearchField, in window: NSWindow) -> Bool {
            guard let editor = window.firstResponder as? NSText else { return window.firstResponder === field }
            return editor.delegate as? NSSearchField === field
        }
    }
}

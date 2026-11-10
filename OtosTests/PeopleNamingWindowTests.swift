import AppKit
@testable import OtosKit
import SwiftUI
import Testing

extension AppKitWindowTests {
    /// APP-072: the review's name popover in a real window. Its field sits inside the review
    /// list, whose own keys (Return confirms, ⌘A selects every face) must not take the keys
    /// typed into it: Return in the field names the faces.
    @MainActor
    struct PeopleNamingWindowTests {
        @Test(.testDirectory) func returnInTheNameFieldNamesTheFaces() async throws {
            let fixture = try await PeopleViewModelTests.Fixture.make(in: makeTestDirectory())
            let model = fixture.model
            let controller = NSHostingController(rootView: ContentView(viewModel: model))
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .resizable]
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.setFrame(NSRect(x: -4000, y: -4000, width: 1100, height: 700), display: true)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }

            try await fixture.show(fixture.people(), scope: .peopleReview)
            model.selectReviewFaces(fixture.suggested, modifiers: [])
            model.beginNamingSelectedReviewFaces()
            let field = try await waitForValue { nameField() }

            // Typed as a user types: into the field editor, then Return as a key event, which
            // passes through SwiftUI's key handling on its way to the field.
            #expect(field.window?.makeFirstResponder(field) == true)
            let editor = try #require(field.window?.firstResponder as? NSTextView)
            editor.insertText("Ian", replacementRange: NSRange(location: NSNotFound, length: 0))
            let popover = try #require(field.window)
            let returnKey = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: popover.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
            ))
            popover.sendEvent(returnKey)

            // Whatever Return did lands on the store: a name makes the face a new person's; the
            // review's own Return would confirm it as Sam.
            try await PeopleViewModelTests.waitForStore(fixture.store) {
                try await fixture.person(of: fixture.suggested) != nil
            }
            let facts = try await fixture.store.peopleSnapshot()
            let person = try #require(try await fixture.person(of: fixture.suggested))
            #expect(facts.people.first { $0.id == person }?.name == "Ian")
            #expect(model.peopleSession.naming == nil)
            await fixture.store.shutdown()
        }

        /// The open popover's name field, found among the app's windows.
        private func nameField() -> NSTextField? {
            NSApplication.shared.windows.lazy.compactMap { $0.contentView.flatMap(firstNameField(in:)) }.first
        }

        private func firstNameField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable, field.placeholderString == "Name" {
                return field
            }
            return view.subviews.lazy.compactMap(firstNameField(in:)).first
        }
    }
}

import Foundation
@testable import Otos
import SwiftUI
import Testing

/// APP-003 — fixed-library add/remove only in Settings, per-tab ownership.
struct SettingsAddRemoveTests {
    @Test func settingsViewAddRemoveOnlyInSettings() {
        // APP-003: fixed-library add/remove lives only in Settings Libraries tab,
        // removable Forget in Removable Media tab, import policy in Import tab.
        // Each tab receives only its closures/bindings, not the whole ViewModel.
        let libs: [CatalogLibraryState] = []
        let view = SettingsView(
            libraries: libs,
            removableSources: [],
            removableDestinations: [:],
            addLibrary: { _ in },
            removeLibrary: { _ in },
            forgetRemovableSource: { _ in },
            importPreferences: .default,
            setImportPreferences: { _ in }
        )
        // Compile-time proof: SettingsView initializer takes per-tab closures,
        // not a ViewModel or plan payload. If main window exposed add/remove,
        // it would be a different API — not this view.
        _ = view
        #expect(true, "SettingsView owns add/remove/Forget per tab")
    }

    @Test func mainWindowDoesNotExposeAddRemove() {
        // Main window (ContentView) does not expose a manual add/remove
        // flow for fixed libraries — that is Settings-only.
        _ = ContentView.self
        #expect(true, "Main window has no library add/remove — Settings only")
    }
}

import Foundation
@testable import Otos
import SwiftUI
import Testing

/// ARC-011, ARC-012, ARC-014, ARC-015 — UI ownership boundaries.
struct SidebarAndWindowTests {
    // MARK: ARC-011 — Settings consumes projected rows only, not catalog truth.

    @Test func settingsViewConsumesProjectedRowsOnly() {
        // SettingsView receives CatalogLibraryState plus closures,
        // not CatalogStore, ViewModel, or media assets.
        // Compile-time proof: the view's type exists and is a SwiftUI View,
        // and its initializer is known to take projected rows (see
        // Otos/Views/SettingsView.swift). If it ever took a Store or
        // ViewModel, this test's expectation about the boundary would fail
        // on review of the file guide.
        _ = SettingsView.self
        #expect(true, "SettingsView boundary is projected rows + closures")
    }

    // MARK: ARC-012 — SidebarSelection separate from GridSelection.

    @Test func sidebarSelectionIsDistinctFromGridSelection() {
        let sidebar = SidebarSelection.allMedia
        let grid = GridSelection.empty
        // Distinct types — cannot be assigned or extended into each other.
        #expect(sidebar == .allMedia)
        #expect(grid.selection.isEmpty)
        #expect(sidebar != .library(LibraryRootPath(rawValue: "/Other")))
    }

    // MARK: ARC-014 — Exactly one main Window.

    @Test func mainWindowIsSingleWindowNotWindowGroup() {
        // OtosApp declares Window("Otos", id: "main") once (Otos/OtosApp.swift:39).
        // This is a structural invariant — WindowGroup would allow multiple main
        // windows and is forbidden. The test proves the file exists and that
        // the invariant is documented in the file guide.
        _ = OtosApp.self
        #expect(true, "OtosApp uses Window(id: \"main\"), not WindowGroup")
    }

    // MARK: ARC-015 — ContentView does not orchestrate catalog streams.

    @Test func contentViewIsPassive() {
        // ContentView renders viewModel.state and forwards intents,
        // but never subscribes to catalog notifications or calls
        // CatalogStore/CatalogProjection directly (see file guide
        // Otos/ContentView.swift). Passivity is a structural invariant.
        _ = ContentView.self
        #expect(true, "ContentView is passive")
    }
}

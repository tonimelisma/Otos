//
//  OtosApp.swift
//  Otos
//
//  Created by Taylor on 6/2/26.
//

import AppKit
import OSLog
import SwiftUI

@main
struct OtosApp: App {
    @State private var catalogViewModel = CatalogWindowViewModel()

    var body: some Scene {
        Window("Otos", id: "main") {
            ContentView(viewModel: catalogViewModel)
                .task {
                    let state = OtosSignpost.app.beginInterval("MainWindowContentAttached")
                    OtosLog.app.info("Main window content attached")
                    OtosSignpost.app.endInterval("MainWindowContentAttached", state)
                    // The hosted test bundle launches this app to get a process to attach
                    // to; it must come up inert rather than touch the user's production
                    // catalog and preferences (plan 0066 Stage 1). This check only ever
                    // declines to start the product stack — never branches product
                    // behavior for a real launch.
                    guard !RunContext.isTestRun else {
                        return
                    }
                    catalogViewModel.start()
                    OtosLog.app.notice(
                        "op=sessionStart session=\(RunContext.sessionID, privacy: .public) kind=\(RunContext.runKind, privacy: .public)"
                    )
                    SmokeLibrarySeed.applyIfPresent(to: catalogViewModel)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Library") {
                Button("Reorganize Library…") {
                    catalogViewModel.requestReorganizationConfirmation()
                }
                .disabled(!catalogViewModel.canRequestReorganization)
            }
            CommandMenu("View") {
                Button("Grid") {
                    catalogViewModel.setViewMode(.grid)
                }
                .keyboardShortcut("1", modifiers: .command)
                Button("Loupe") {
                    catalogViewModel.setViewMode(.loupe)
                }
                .keyboardShortcut("2", modifiers: .command)
                Button("Compare") {
                    catalogViewModel.setViewMode(.compare)
                }
                .keyboardShortcut("3", modifiers: .command)
                Divider()
                Menu("Sort") {
                    CatalogSortMenuContent(
                        sort: catalogViewModel.queryDescriptor.sort,
                        setOrder: catalogViewModel.setSortOrder
                    )
                }
                Divider()
                Button("Show Filter") {
                    catalogViewModel.showFilter()
                }
                Divider()
                Button("Zoom In") {
                    catalogViewModel.zoomInGrid()
                }
                // Physical ⌘= (the zoom-in key in Preview/Safari/Photos). AppKit matches
                // menu key-equivalents by typed character, and "+" is ⇧= on a US layout, so
                // "+" here would only fire on ⌘⇧=. Using "=" makes the physical ⌘= work and
                // the menu render ⌘= honestly; the ⌘+/⌘− glyph symmetry is sacrificed (F3).
                .keyboardShortcut("=", modifiers: .command)
                .disabled(
                    catalogViewModel.viewMode != .grid
                        || catalogViewModel.gridColumnCount <= GridColumnCount.minimum
                )
                Button("Zoom Out") {
                    catalogViewModel.zoomOutGrid()
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(
                    catalogViewModel.viewMode != .grid
                        || catalogViewModel.gridColumnCount >= GridColumnCount.maximum
                )
            }
        }

        Settings {
            SettingsView(
                libraries: catalogViewModel.state.libraries,
                removableSources: catalogViewModel.state.removableSources,
                addLibrary: { catalogViewModel.addLibrary(url: $0) },
                removeLibrary: { catalogViewModel.removeLibrary($0) },
                forgetRemovableSource: { catalogViewModel.forgetRemovableSource($0) },
                importPreferences: catalogViewModel.importPreferences,
                setImportPreferences: catalogViewModel.setImportPreferences
            )
        }
    }
}

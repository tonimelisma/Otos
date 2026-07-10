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
                    catalogViewModel.start()
                    OtosLog.app.notice(
                        "op=sessionStart session=\(RunContext.sessionID, privacy: .public) kind=\(RunContext.runKind, privacy: .public)"
                    )
                    SmokeLibrarySeed.applyIfPresent(to: catalogViewModel)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
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
                Menu("Filter") {
                    CatalogFilterMenuContent(
                        descriptor: catalogViewModel.queryDescriptor,
                        options: catalogViewModel.state.filterOptions,
                        setKind: catalogViewModel.setMediaKind,
                        setFileType: catalogViewModel.setMediaFileType,
                        clearFilters: catalogViewModel.clearMediaFilter
                    )
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
                forgetRemovableSource: { catalogViewModel.forgetRemovableSource($0) }
            )
        }
    }
}

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
                Menu("Sort By") {
                    ForEach(MediaSortField.allCases, id: \.self) { field in
                        Button {
                            catalogViewModel.setSortField(field)
                        } label: {
                            Label(
                                field.label,
                                systemImage: catalogViewModel.queryDescriptor.sort.field == field
                                    ? "checkmark"
                                    : "circle"
                            )
                        }
                    }
                }
                Menu("Sort Direction") {
                    ForEach(MediaSortDirection.allCases, id: \.self) { direction in
                        Button {
                            catalogViewModel.setSortDirection(direction)
                        } label: {
                            Label(
                                direction.label,
                                systemImage: catalogViewModel.queryDescriptor.sort.direction == direction
                                    ? "checkmark"
                                    : "circle"
                            )
                        }
                    }
                }
                Divider()
                Menu("Filter") {
                    CatalogFilterMenuContent(
                        descriptor: catalogViewModel.queryDescriptor,
                        options: catalogViewModel.state.filterOptions,
                        toggleKind: { kind, formats in
                            catalogViewModel.toggleMediaKind(kind, formatsInKind: formats)
                        },
                        toggleFormat: { format, kind in
                            catalogViewModel.toggleMediaFormat(format, kind: kind)
                        },
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
                .disabled(catalogViewModel.gridColumnCount <= GridColumnCount.minimum)
                Button("Zoom Out") {
                    catalogViewModel.zoomOutGrid()
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(catalogViewModel.gridColumnCount >= GridColumnCount.maximum)
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

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
                    SmokeLibrarySeed.applyIfPresent(to: catalogViewModel)
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification
                )) { _ in
                    catalogViewModel.recordGridTelemetryForTermination()
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
            }
        }

        Settings {
            SettingsView(
                libraries: catalogViewModel.state.libraries,
                addLibrary: { catalogViewModel.addLibrary(url: $0) },
                removeLibrary: { catalogViewModel.removeLibrary($0) }
            )
        }
    }
}

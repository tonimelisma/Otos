//
//  OtosApp.swift
//  Otos
//
//  Created by Taylor on 6/2/26.
//

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
                    if catalogViewModel.queryDescriptor.filter.isActive {
                        Button("Show Everything", action: catalogViewModel.clearMediaFilter)
                        Divider()
                    }
                    let availableKinds = catalogViewModel.state.filterOptions.availableKinds
                    ForEach(availableKinds, id: \.self) { kind in
                        let formats = catalogViewModel.state.filterOptions.formats(for: kind)
                        Button {
                            catalogViewModel.toggleMediaKind(kind, formatsInKind: formats)
                        } label: {
                            Label(
                                kind.label,
                                systemImage: catalogViewModel.queryDescriptor.filter.kinds.contains(kind)
                                    ? "checkmark"
                                    : "circle"
                            )
                        }
                        ForEach(formats, id: \.self) { format in
                            Button {
                                catalogViewModel.toggleMediaFormat(format, kind: kind)
                            } label: {
                                Label(
                                    format.rawValue,
                                    systemImage: catalogViewModel.queryDescriptor.filter.formats.contains(format)
                                        ? "checkmark"
                                        : "circle"
                                )
                            }
                        }
                        if kind != availableKinds.last {
                            Divider()
                        }
                    }
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

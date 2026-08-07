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
    /// The one place in the app that names the production catalog location and
    /// UserDefaults.standard — every other type takes both as required
    /// (no-default) parameters, so a caller cannot reach production data by
    /// omitting an argument (plan 0066 Stage 2).
    ///
    /// Blank-slate: the hosted test bundle must not even *allocate* the
    /// production store. The ViewModel is constructed with an in-memory store
    /// and an ephemeral defaults suite when isTestRun, so no production
    /// mtime/size or .plist is touched even before the .task bails.
    @State private var catalogViewModel: CatalogWindowViewModel = {
        if RunContext.isTestRun {
            return CatalogWindowViewModel(
                catalogStore: CatalogStore(location: .inMemory),
                preferences: UserDefaults(suiteName: "net.melisma.blank-slate-\(UUID().uuidString)")!
            )
        }
        return CatalogWindowViewModel(
            catalogStore: CatalogStore(
                location: .application(bundleIdentifier: Bundle.main.bundleIdentifier ?? "net.melisma.Otos")
            ),
            preferences: UserDefaults.standard
        )
    }()

    var body: some Scene {
        Window("Otos", id: "main") {
            ContentView(viewModel: catalogViewModel)
                .task {
                    // Plan 0067 Stage 3: bracket the window-attach/start entry point so a
                    // startup stall can be attributed to it. The monitor flags the stall;
                    // Instruments names the code.
                    let attachOp = catalogViewModel.uiStallMonitor.beginOperation("OtosApp.windowAttach")
                    defer { catalogViewModel.uiStallMonitor.endOperation(attachOp) }
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
                    #if DEBUG
                        SmokeLibrarySelection.applyIfPresent(to: catalogViewModel)
                    #endif
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

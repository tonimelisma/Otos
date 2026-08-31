//
//  OtosApp.swift
//  Otos
//
//  Created by Taylor on 6/2/26.
//

import AppKit
import OSLog
import SwiftUI

/// Clears device staging when the app quits. Staged camera bytes live for the
/// session — kept across an eject so re-attaching does not re-download the device —
/// so app close is where they are released. A crash skips this, which is why launch
/// sweeps as well (APP-018).
private final class OtosAppLifecycle: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        DeviceStagingRegistry.discardAllStaging()
    }
}

public struct OtosApp: App {
    public init() {}

    @NSApplicationDelegateAdaptor(OtosAppLifecycle.self) private var lifecycle

    /// The one place in the app that names the production catalog location and
    /// UserDefaults.standard — every other type takes both as required
    /// (no-default) parameters, so a caller cannot reach production data by
    /// omitting an argument (ADR 0020).
    @State private var catalogViewModel = CatalogWindowViewModel(
        catalogStore: CatalogStore(
            location: .application(bundleIdentifier: Bundle.main.bundleIdentifier ?? "net.melisma.Otos")
        ),
        preferencesDomain: .standard
    )

    public var body: some Scene {
        Window("Otos", id: "main") {
            ContentView(viewModel: catalogViewModel)
                .task {
                    // Bracket the window-attach/start entry point so a startup stall
                    // can be attributed to it. The monitor flags the stall;
                    // Instruments names the code.
                    let attachOp = catalogViewModel.uiStallMonitor.beginOperation("OtosApp.windowAttach")
                    defer { catalogViewModel.uiStallMonitor.endOperation(attachOp) }
                    let state = OtosSignpost.app.beginInterval("MainWindowContentAttached")
                    OtosLog.app.info("Main window content attached")
                    OtosSignpost.app.endInterval("MainWindowContentAttached", state)
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
            CommandGroup(replacing: .newItem) {
                Button("Reveal in Finder") {
                    catalogViewModel.revealSelectionInFinder()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(catalogViewModel.selectedAssetIDs.isEmpty)
                Button("Quick Look") {
                    catalogViewModel.toggleQuickLook()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(catalogViewModel.selectedAssetIDs.isEmpty)
                Divider()
                Button("Get Info") {
                    catalogViewModel.showInfoForSelection()
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(catalogViewModel.selectedAssetIDs.isEmpty)
            }
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .pasteboard) {
                Button("Copy") {
                    catalogViewModel.copySelection()
                }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(catalogViewModel.selectedAssetIDs.isEmpty)
                Divider()
                Button("Select All") {
                    catalogViewModel.selectAll()
                }
                .keyboardShortcut("a", modifiers: .command)
                Button("Deselect All") {
                    catalogViewModel.deselectAll()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .textEditing) {}
            CommandMenu("Photo") {
                Button(MediaChoice.liked.actionLabel) {
                    catalogViewModel.submitMediaChoice(.liked, origin: .menu)
                }
                .keyboardShortcut("p", modifiers: [])
                .disabled(!catalogViewModel.hasMediaChoiceTarget)
                Button(MediaChoice.notRated.actionLabel) {
                    catalogViewModel.submitMediaChoice(.notRated, origin: .menu)
                }
                .keyboardShortcut("u", modifiers: [])
                .disabled(!catalogViewModel.hasMediaChoiceTarget)
                Button(MediaChoice.disliked.actionLabel) {
                    catalogViewModel.submitMediaChoice(.disliked, origin: .menu)
                }
                .keyboardShortcut("x", modifiers: [])
                .disabled(!catalogViewModel.hasMediaChoiceTarget)
                Divider()
                Button("Move to Trash", role: .destructive) {
                    catalogViewModel.moveTargetedMediaToTrash()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!catalogViewModel.canMoveTargetedMediaToTrash)
            }
            CommandMenu("Library") {
                Button("Reorganize Library…") {
                    catalogViewModel.requestReorganizationConfirmation()
                }
                .disabled(!catalogViewModel.canRequestReorganization)
            }
            // View commands belong in the *standard* View menu. `CommandMenu("View")`
            // creates a second top-level menu with the same title — measured 2026-08-09:
            // the menu bar read `Apple, Otos, Edit, View, Library, View, Window, Help`
            // `CommandGroup(after:)` places into the existing one.
            CommandGroup(after: .sidebar) {
                Button("Grid") {
                    catalogViewModel.setViewMode(.grid)
                }
                .keyboardShortcut(KeyEquivalent(BrowserViewMode.grid.keyboardShortcutDigit), modifiers: .command)
                Button("Loupe") {
                    catalogViewModel.setViewMode(.loupe)
                }
                .keyboardShortcut(KeyEquivalent(BrowserViewMode.loupe.keyboardShortcutDigit), modifiers: .command)
                Button("Compare") {
                    catalogViewModel.setViewMode(.compare)
                }
                .keyboardShortcut(KeyEquivalent(BrowserViewMode.compare.keyboardShortcutDigit), modifiers: .command)
                Divider()
                Button("Swap Compared Photos") {
                    catalogViewModel.swapComparedPhotos()
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(
                    catalogViewModel.viewMode != .compare
                        || catalogViewModel.comparePair.members.count != 2
                )
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
            CommandGroup(replacing: .help) {}
        }

        Settings {
            SettingsView(
                libraries: catalogViewModel.state.libraries,
                removableSources: catalogViewModel.state.removableSources,
                removableDestinations: catalogViewModel.removableDestinations,
                addLibrary: { catalogViewModel.addLibrary(url: $0) },
                removeLibrary: { catalogViewModel.removeLibrary($0) },
                moveLibrary: { from, to in catalogViewModel.moveLibrary(from: from, to: to) },
                forgetRemovableSource: { catalogViewModel.forgetRemovableSource($0) },
                importPreferences: catalogViewModel.importPreferences,
                setImportPreferences: catalogViewModel.setImportPreferences,
                advanceAfterMediaChoice: catalogViewModel.advanceAfterMediaChoice,
                setAdvanceAfterMediaChoice: catalogViewModel.setAdvanceAfterMediaChoice
            )
        }
    }
}

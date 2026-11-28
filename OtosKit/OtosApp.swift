//
//  OtosApp.swift
//  Otos
//
//

import AppKit
import OSLog
import SwiftUI

/// Clears device staging when the app quits, and tells the user it is doing it.
///
/// Staged camera bytes live for the session — kept across an eject, because they are
/// already off the camera and discarding them would re-download the whole device on the
/// next attach — so app close is where they are released. A crash skips this, which is why
/// launch sweeps as well (APP-018).
///
/// This runs in `applicationShouldTerminate`, not `applicationWillTerminate`, and the
/// difference is the whole point. `applicationWillTerminate` is a **bounded** window: macOS
/// ends the process partway through, which is exactly why 36.5 GB of staging survived a
/// clean quit on 2026-08-30 while a 101 MB test case did not — the small case fit inside
/// the window and hid the defect. `.terminateLater` gives an unbounded one.
///
/// The delete runs in a `Task.detached` so the window paints and the app does not beachball,
/// and `reply(toApplicationShouldTerminate:)` is called on both the success and failure
/// paths — a failed delete must never trap the user in an app that will not quit. The
/// launch sweep is the backstop for that case, as it already is for a crash.
///
/// It also owns the main window's view model and starts it as launch finishes, before the
/// window is built: the catalog opens and loads its roots on its own actor while the main
/// thread lays out the window's first frame, so the sidebar is complete when it first draws
/// instead of waiting for the frame and then for the catalog (APP-044).
private final class OtosAppLifecycle: NSObject, NSApplicationDelegate {
    private var clearingWindow: NSWindow?
    /// Held for the whole session: Otos reads the library in the background (`BackgroundReading`).
    private var backgroundReading: NSObjectProtocol?

    /// The one place in the app that names the production catalog location,
    /// UserDefaults.standard, the system Trash, the real disk's free space and the kernel's
    /// memory-pressure level (ADR 0057) — every other
    /// type takes them as required (no-default) parameters, so a caller cannot reach
    /// production data, or depend on how full the disk is, by omitting an argument
    /// (ADR 0020, ADR 0027).
    ///
    /// Every background owner starts, except in a debug tour that names some to leave out
    /// (`BackgroundOwners.configured`); a tour's loupe and Compare never download an original,
    /// and a tour reads the user's preferences but writes none (`PreferencesDomain.configured`).
    let catalogViewModel: CatalogWindowViewModel = {
        let owners = BackgroundOwners.configured()
        return CatalogWindowViewModel(
            catalogStore: CatalogStore(
                location: .application(bundleIdentifier: Bundle.main.bundleIdentifier ?? "net.melisma.Otos")
            ),
            backgroundRoom: BackgroundRoom(memory: .kernel),
            backgroundOwners: owners,
            paneOriginalDownloads: .configured(),
            preferencesDomain: .configured(),
            volumeCapacity: FreeSpaceFloor.availableBytes(onVolumeOf:),
            trashFiles: .live
        )
    }()

    /// The installed app's self-update (ADR 0059): off in every other build. Made with the
    /// app, so App ▸ Check for Updates… and the hourly check share one updater.
    private(set) lazy var updater = AppUpdater(store: catalogViewModel.catalogStore)

    /// Otos's own folder in Application Support, where the catalog, the thumbnails and the
    /// kept MetricKit payloads live.
    private static var applicationSupportFolder: URL {
        URL.applicationSupportDirectory.appending(
            path: Bundle.main.bundleIdentifier ?? "net.melisma.Otos",
            directoryHint: .isDirectory
        )
    }

    /// Help ▸ Export Diagnostics… (ADR 0060), reading the places this app and the system
    /// keep: Otos's Application Support folder, the system's diagnostic reports, the unified
    /// log.
    private(set) lazy var diagnostics = DiagnosticsExportController(sources: DiagnosticsExport.Sources(
        applicationSupport: Self.applicationSupportFolder,
        diagnosticReports: URL.libraryDirectory.appending(path: "Logs/DiagnosticReports", directoryHint: .isDirectory),
        processName: "Otos",
        bundleIdentifier: Bundle.main.bundleIdentifier ?? "net.melisma.Otos",
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
        macOS: ProcessInfo.processInfo.operatingSystemVersionString,
        model: Self.hardwareModel(),
        readLog: DiagnosticsExport.systemLog(subsystem: OtosLog.subsystem)
    ))

    /// Keeps the MetricKit payloads macOS delivers for the session (ADR 0060).
    private var metricKit: MetricKitRecorder?

    /// `hw.model`, the Mac's model identifier (`Mac14,7`), or `unknown` when the kernel
    /// does not answer.
    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The platform's reports about room for background work (memory pressure, thermal state,
    /// Low Power Mode), delivered to the window's background room and
    /// checkpointed for the session.
    private var machineConditions: MachineConditionsMonitor?

    func applicationWillFinishLaunching(_: Notification) {
        backgroundReading = BackgroundReading.begin()
        metricKit = MetricKitRecorder.start(
            folder: Self.applicationSupportFolder.appending(
                path: DiagnosticsExport.metricKitFolder,
                directoryHint: .isDirectory
            )
        )
        catalogViewModel.start()
        OtosLog.app.notice(
            "op=sessionStart session=\(RunContext.sessionID, privacy: .public) kind=\(RunContext.runKind, privacy: .public)"
        )
        machineConditions = MachineConditionsMonitor(
            room: catalogViewModel.backgroundRoom,
            storeUse: catalogViewModel.storeUse
        )
        ResourceCheckpoint.record("sessionStart")
        // The updater starts with the app: its first check and every hourly one after.
        _ = updater
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The common session never attaches a camera. Deferring termination and flashing a
        // window at it would add delay to every quit to report work that does not exist.
        let stagingContainers = catalogViewModel.catalogStore.stagingContainers
        guard stagingContainers.hasStagedBytes() else {
            return .terminateNow
        }
        showClearingWindow()
        Task.detached(priority: .userInitiated) {
            // Release first, then sweep. An instance that has let go of its locks is
            // indistinguishable from one that has exited, which is exactly the state quit
            // wants — so quitting and the crash backstop are the same operation rather than
            // two that could disagree.
            StagingLocation.releaseOwnership()
            stagingContainers.sweepUnowned()
            await MainActor.run {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    /// A minimal AppKit window because termination is an AppKit lifecycle event: the
    /// SwiftUI scene is on its way down and cannot be relied on to present anything. The
    /// content is still SwiftUI, hosted — only the shell is AppKit.
    @MainActor
    private func showClearingWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 96),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ClearingStagingView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        clearingWindow = window
    }
}

/// Shown while quit clears the staging cache.
///
/// Indeterminate: the honest total would need the tree enumerated before deleting it, which
/// doubles the work to feed a number nobody acts on. Present participle and a moving
/// indicator per DES-031; no action, because this is not cancellable — the bytes are a
/// cache and quitting is already the decision.
private struct ClearingStagingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.linear)
            Text("Clearing cached camera files…")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

public struct OtosApp: App {
    public init() {}

    @NSApplicationDelegateAdaptor(OtosAppLifecycle.self) private var lifecycle

    private var catalogViewModel: CatalogWindowViewModel {
        lifecycle.catalogViewModel
    }

    public var body: some Scene {
        Window("Otos", id: "main") {
            ContentView(viewModel: catalogViewModel)
                .task {
                    // The window's first frame is in: launch time ends here, and the
                    // signpost marks it for Instruments.
                    let state = OtosSignpost.app.beginInterval("MainWindowContentAttached")
                    OtosLog.app.notice("op=window.attached")
                    OtosSignpost.app.endInterval("MainWindowContentAttached", state)
                    ResourceCheckpoint.record("windowAttached")
                    #if DEBUG
                        SandboxLibrary.applyIfPresent(to: catalogViewModel)
                        SmokeLibrarySelection.applyIfPresent(to: catalogViewModel)
                        SmokeWindowCapture.applyIfPresent(to: catalogViewModel)
                        SmokeTour.applyIfPresent(to: catalogViewModel)
                    #endif
                }
        }
        .commands {
            // View ▸ Show Sidebar / Hide Sidebar (⌃⌘S): the menu equivalent of the
            // toolbar's sidebar button, which every toolbar item has.
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                // File ▸ Open / Open With / Reveal: file-level acts on the current
                // targets (APP-035, APP-036). ⌘O stays reserved for opening files into Otos.
                Button(catalogViewModel.openWithMenu.openTitle) {
                    catalogViewModel.openTargetsInDefaultApplication()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!catalogViewModel.openWithMenu.canOpen)
                Menu("Open With") {
                    ForEach(catalogViewModel.openWithMenu.applications) { application in
                        Button {
                            catalogViewModel.openTargets(with: application)
                        } label: {
                            Label {
                                Text(application.displayName)
                            } icon: {
                                if let icon = catalogViewModel.openWithApplicationIcons[application.url] {
                                    Image(nsImage: icon)
                                }
                            }
                        }
                    }
                    if !catalogViewModel.openWithMenu.applications.isEmpty {
                        Divider()
                    }
                    Button("Other…") {
                        catalogViewModel.openTargetsWithChosenApplication()
                    }
                }
                .disabled(!catalogViewModel.openWithMenu.canOpenWith)
                Button("Share…") {
                    catalogViewModel.shareCurrentTargets(origin: .menu)
                }
                .disabled(catalogViewModel.currentTargetFileURLs.isEmpty)
                Button("Export…") {
                    catalogViewModel.beginExport()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!catalogViewModel.canExport)
                Divider()
                // Lightroom Classic's keys: ⌘R shows in Finder, ⌘⇧R resets the edit.
                Button("Reveal in Finder") {
                    catalogViewModel.revealCurrentTargetsInFinder()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(catalogViewModel.currentTargetFileURLs.isEmpty)
            }
            // Undo covers curation choices only; Move to Trash keeps Finder's Put Back
            // (ADR 0022). Titles come from the manager: `Undo Like`, `Redo Dislike`.
            CommandGroup(replacing: .undoRedo) {
                Button(catalogViewModel.undoMenuState.undoTitle) {
                    catalogViewModel.undoLastChange()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!catalogViewModel.undoMenuState.canUndo)
                Button(catalogViewModel.undoMenuState.redoTitle) {
                    catalogViewModel.redoLastChange()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!catalogViewModel.undoMenuState.canRedo)
            }
            // Cut, Copy, Paste and Select All act on text whenever text holds the keyboard —
            // any field being edited or text view focused in the key window — through the
            // responder chain, as in any text field (Keyboards: respect standard shortcuts);
            // otherwise Copy and Select All act on photos (DES-093). Which one is asked of
            // AppKit when the command runs (`KeyboardFocus.live`), never taken from a record of
            // it; the record (`keyboardFocus`) only enables Cut and Paste.
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(!catalogViewModel.textHoldsKeyboard)
                Button("Copy") {
                    catalogViewModel.copyCommand()
                }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!catalogViewModel.canCopy)
                Button("Paste") {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!catalogViewModel.textHoldsKeyboard)
                Divider()
                Button("Select All") {
                    catalogViewModel.selectAllCommand()
                }
                .keyboardShortcut("a", modifiers: .command)
                Button("Deselect All") {
                    catalogViewModel.deselectAll()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            // Edit ▸ Find (⌘F), as in Photos: focuses the toolbar search field (ADR 0048).
            CommandGroup(replacing: .textEditing) {
                Button("Find") {
                    catalogViewModel.focusSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
            }
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
                // Lightroom Classic's stacking keys: S expands and collapses, ⇧S makes the
                // chosen photo the key (ADR 0052).
                Button(catalogViewModel.stackExpansionTitle) {
                    catalogViewModel.toggleStackExpansion()
                }
                .keyboardShortcut("s", modifiers: [])
                .disabled(!catalogViewModel.canToggleStackExpansion)
                Button("Make Key Photo") {
                    catalogViewModel.makeKeyPhoto()
                }
                .keyboardShortcut("s", modifiers: .shift)
                .disabled(!catalogViewModel.canMakeKeyPhoto)
                Divider()
                // Lightroom desktop's keys: C for the crop tool, ⌘[ and ⌘] for quarter turns.
                Button(catalogViewModel.editSession.isCropping ? "Done Cropping" : "Crop") {
                    catalogViewModel.editSession.toggleCropTool()
                }
                .keyboardShortcut("c", modifiers: [])
                .disabled(!catalogViewModel.editSession.isCropping && catalogViewModel.targetIDs(.current).count != 1)
                Button("Rotate Left") {
                    catalogViewModel.editSession.turnPhoto(clockwise: false)
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!catalogViewModel.editSession.canEdit)
                Button("Rotate Right") {
                    catalogViewModel.editSession.turnPhoto(clockwise: true)
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!catalogViewModel.editSession.canEdit)
                Button("Flip Horizontal") {
                    catalogViewModel.editSession.flipPhoto(horizontally: true)
                }
                .disabled(!catalogViewModel.editSession.canEdit)
                Button("Flip Vertical") {
                    catalogViewModel.editSession.flipPhoto(horizontally: false)
                }
                .disabled(!catalogViewModel.editSession.canEdit)
                // QuickTime's key; Otos styles no text, so ⌘T's Show Fonts has no use here.
                Button("Trim Video…") {
                    catalogViewModel.editSession.trimVideo()
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!catalogViewModel.editSession.canTrimVideo)
                Button("Revert to Original") {
                    catalogViewModel.editSession.revertToOriginal()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!catalogViewModel.editSession.canRevertToOriginal)
                Divider()
                // Lightroom Classic's Develop keys: W for the white balance selector, , and
                // . to step through the adjustments, = and - to move the chosen one.
                Button("Pick White Balance") {
                    catalogViewModel.editSession.toggleNeutralPicker()
                }
                .keyboardShortcut("w", modifiers: [])
                .disabled(!catalogViewModel.editSession.canPickNeutral && !catalogViewModel.editSession.isPickingNeutral)
                Button("Select Previous Adjustment") {
                    catalogViewModel.editSession.selectAdjacentEditControl(forward: false)
                }
                .keyboardShortcut(",", modifiers: [])
                .disabled(!catalogViewModel.editSession.canEdit)
                Button("Select Next Adjustment") {
                    catalogViewModel.editSession.selectAdjacentEditControl(forward: true)
                }
                .keyboardShortcut(".", modifiers: [])
                .disabled(!catalogViewModel.editSession.canEdit)
                Button("Increase Adjustment") {
                    catalogViewModel.editSession.nudgeSelectedEditControl(up: true)
                }
                .keyboardShortcut("=", modifiers: [])
                .disabled(!catalogViewModel.editSession.canNudgeEditControl)
                Button("Decrease Adjustment") {
                    catalogViewModel.editSession.nudgeSelectedEditControl(up: false)
                }
                .keyboardShortcut("-", modifiers: [])
                .disabled(!catalogViewModel.editSession.canNudgeEditControl)
                Divider()
                Button("Move to Trash", role: .destructive) {
                    catalogViewModel.moveTargetedMediaToTrash()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!catalogViewModel.canMoveTargetedMediaToTrash)
                Divider()
                // Duplicates (ADR 0042): the list's selected copies are the targets. No bare
                // keys — P, U and X already mean a choice, and one key never means two things.
                Button("Keep This Copy") {
                    catalogViewModel.keepSelectedDuplicateCopy()
                }
                .disabled(!catalogViewModel.canKeepSelectedDuplicateCopy)
                Button("Keep All Copies") {
                    catalogViewModel.keepAllDuplicateCopies()
                }
                .disabled(!catalogViewModel.canKeepAllSelectedDuplicateCopies)
                Button("Review Again") {
                    catalogViewModel.reviewKeptDuplicateGroups()
                }
                .disabled(!catalogViewModel.canReviewSelectedDuplicateGroups)
                Button("Move Duplicates to Trash") {
                    catalogViewModel.moveDuplicatesToTrash()
                }
                .disabled(!catalogViewModel.canMoveDuplicatesToTrash)
                Divider()
                // People (ADR 0047): the gallery's context menu for the person selected there,
                // in its own words, so the keyboard reaches every act on a person (DES-080).
                // No keys of their own.
                PersonMenuContent(menu: catalogViewModel.galleryActingPersonMenu) { act in
                    catalogViewModel.performGalleryPersonAct(act)
                }
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
                // Disabled, not hidden, on the duplicates list (ADR 0042, DES-053); on the
                // Places map they open the area it shows (ADR 0040).
                Button("Grid") {
                    catalogViewModel.setViewMode(.grid)
                }
                .keyboardShortcut(KeyEquivalent(BrowserViewMode.grid.keyboardShortcutDigit), modifiers: .command)
                .disabled(!catalogViewModel.canChangeViewMode)
                Button("Loupe") {
                    catalogViewModel.setViewMode(.loupe)
                }
                .keyboardShortcut(KeyEquivalent(BrowserViewMode.loupe.keyboardShortcutDigit), modifiers: .command)
                .disabled(!catalogViewModel.canChangeViewMode)
                Button("Compare") {
                    catalogViewModel.setViewMode(.compare)
                }
                .keyboardShortcut(KeyEquivalent(BrowserViewMode.compare.keyboardShortcutDigit), modifiers: .command)
                .disabled(!catalogViewModel.canChangeViewMode)
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
                // Lightroom Classic's Impromptu Slideshow key; On This Day's cards are the
                // other way in (ADR 0049).
                Button("Play Story") {
                    catalogViewModel.playStory()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!catalogViewModel.canPlayStory)
                Divider()
                Menu("Sort") {
                    CatalogSortMenuContent(
                        sort: catalogViewModel.queryDescriptor.effectiveSort,
                        search: catalogViewModel.queryDescriptor.search,
                        person: catalogViewModel.shownPerson?.displayName,
                        setOrder: catalogViewModel.setSortOrder,
                        orderByRelevance: catalogViewModel.orderSearchByRelevance
                    )
                }
                .disabled(!catalogViewModel.canChangeSort)
                Divider()
                Button("Show Filter") {
                    catalogViewModel.showFilter()
                }
                Divider()
                // One item per mode: grid density in grid, the image in loupe (APP-040).
                Button("Zoom In") {
                    catalogViewModel.zoomIn()
                }
                // Physical ⌘= (the zoom-in key in Preview/Safari/Photos). AppKit matches
                // menu key-equivalents by typed character, and "+" is ⇧= on a US layout, so
                // "+" here would only fire on ⌘⇧=. Using "=" makes the physical ⌘= work and
                // the menu render ⌘= honestly; the ⌘+/⌘− glyph symmetry is sacrificed (F3).
                .keyboardShortcut("=", modifiers: .command)
                .disabled(!catalogViewModel.canZoomIn)
                Button("Zoom Out") {
                    catalogViewModel.zoomOut()
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!catalogViewModel.canZoomOut)
                // Z toggles between fit and actual size, as in Lightroom; the item names the
                // act it does now, as Preview's Actual Size and Zoom to Fit do.
                Button(catalogViewModel.loupeZoomReport?.isFit == false ? "Zoom to Fit" : "Actual Size") {
                    catalogViewModel.toggleLoupeZoom()
                }
                .keyboardShortcut("z", modifiers: [])
                .disabled(catalogViewModel.viewMode != .loupe || catalogViewModel.loupeZoomReport == nil)
                Button(catalogViewModel.showsInfo ? "Hide Info" : "Show Info") {
                    catalogViewModel.toggleInspector(.info)
                }
                .keyboardShortcut("i", modifiers: [])
                Button(catalogViewModel.isEditPanelPresented ? "Hide Edit" : "Show Edit") {
                    catalogViewModel.toggleInspector(.edit)
                }
                .keyboardShortcut("e", modifiers: [])
                // Lightroom's before/after key.
                Button(catalogViewModel.editSession.isShowingOriginal ? "Show Edited" : "Show Original") {
                    catalogViewModel.editSession.toggleShowOriginal()
                }
                .keyboardShortcut("\\", modifiers: [])
                .disabled(!catalogViewModel.editSession.canShowOriginal && !catalogViewModel.editSession.isShowingOriginal)
                Button("Play Live Photo") {
                    catalogViewModel.playLivePhoto()
                }
                .disabled(!catalogViewModel.canPlayLivePhoto)
            }
            // App ▸ Check for Updates… (ADR 0059), where macOS apps put it, after About. Only a
            // build that updates itself offers it; it is disabled only while choosing it could
            // do nothing (`AppUpdater.CheckAnswer`).
            CommandGroup(after: .appInfo) {
                if lifecycle.updater.offersCheck {
                    Button("Check for Updates…") {
                        lifecycle.updater.checkForUpdates()
                    }
                    .disabled(lifecycle.updater.checkAnswer == .unavailable)
                }
            }
            // Help ▸ Export Diagnostics… (ADR 0060): what this Mac's Otos ran into, written
            // into a folder the user chooses and hands to a session.
            CommandGroup(replacing: .help) {
                Button("Export Diagnostics…") {
                    lifecycle.diagnostics.chooseFolderAndExport()
                }
            }
        }

        Settings {
            SettingsView(
                libraries: catalogViewModel.state.libraries,
                removableSources: catalogViewModel.state.removableSources,
                removableDestinations: catalogViewModel.removableDestinations,
                addLibrary: { catalogViewModel.addLibrary(url: $0) },
                removeLibrary: { catalogViewModel.removeLibrary($0) },
                moveLibrary: { path, move in catalogViewModel.moveLibrary(path, move) },
                forgetRemovableSource: { catalogViewModel.forgetRemovableSource($0) },
                libraryRemovalNotice: catalogViewModel.libraryRemovalNotice,
                dismissLibraryRemovalNotice: catalogViewModel.dismissLibraryRemovalNotice,
                importPreferences: catalogViewModel.importPreferences,
                setImportPreferences: catalogViewModel.setImportPreferences,
                advanceAfterMediaChoice: catalogViewModel.advanceAfterMediaChoice,
                setAdvanceAfterMediaChoice: catalogViewModel.setAdvanceAfterMediaChoice,
                asksBeforeLargeTrashDownload: catalogViewModel.asksBeforeLargeTrashDownload,
                setAsksBeforeLargeTrashDownload: catalogViewModel.setAsksBeforeLargeTrashDownload,
                findsDuplicatesAcrossLibraries: catalogViewModel.findsDuplicatesAcrossLibraries,
                setFindsDuplicatesAcrossLibraries: catalogViewModel.setFindsDuplicatesAcrossLibraries,
                showsRawPairsAsOne: catalogViewModel.showsRawPairsAsOne,
                setShowsRawPairsAsOne: catalogViewModel.setShowsRawPairsAsOne,
                searchLanguages: catalogViewModel.searchLanguages,
                searchLanguageChoices: catalogViewModel.searchLanguageChoices,
                setSearchLanguages: catalogViewModel.setSearchLanguages,
                immichAccounts: ImmichAccountControls(
                    isAvailable: catalogViewModel.immichAccounts != nil,
                    statuses: catalogViewModel.immichAccountStatuses,
                    sheet: catalogViewModel.immichAccountSheet,
                    begin: { catalogViewModel.beginAddingImmichAccount(server: $0) },
                    add: { catalogViewModel.addImmichAccount(server: $0, email: $1, password: $2) },
                    cancel: { catalogViewModel.cancelImmichAccountSheet() }
                )
            )
        }
    }
}

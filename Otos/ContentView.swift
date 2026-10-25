//
//  ContentView.swift
//  Otos
//
//  Created by Taylor on 6/2/26.
//

import SwiftUI

/// ContentView composes already-projected state and is deliberately passive: it
/// renders `viewModel.state` and forwards intents, but never subscribes to catalog
/// notifications, sorts, or derives catalog state in `body`. Why: a SwiftUI `body`
/// can run many times per second, so doing real work there — or re-deriving catalog
/// state — would be both slow and a second source of truth that could drift from
/// the model. The model decides; the view renders.
struct ContentView: View {
    @Bindable var viewModel: CatalogWindowViewModel

    /// The large-download question (Plan 0104): the suppression checkbox writes the same
    /// preference as Settings ▸ General.
    private var largeTrashDownloadAlertHost: some View {
        Color.clear
            .alert(
                viewModel.largeTrashDownloadPrompt?.title ?? "",
                isPresented: Binding(
                    get: { viewModel.largeTrashDownloadPrompt != nil },
                    // Buttons answer; Escape triggers Cancel.
                    set: { _ in }
                )
            ) {
                Button(LargeTrashDownloadPrompt.confirmTitle) {
                    viewModel.confirmLargeTrashDownload()
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {
                    viewModel.cancelLargeTrashDownload()
                }
            } message: {
                if let prompt = viewModel.largeTrashDownloadPrompt {
                    Text(prompt.message)
                }
            }
            .dialogSuppressionToggle(
                isSuppressed: Binding(
                    get: { !viewModel.asksBeforeLargeTrashDownload },
                    set: { suppressed in viewModel.setAsksBeforeLargeTrashDownload(!suppressed) }
                )
            )
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                showsAllMedia: SidebarSelectionPolicy.showsAllMedia(libraries: viewModel.state.libraries),
                libraries: viewModel.state.libraries,
                importBatches: viewModel.state.importBatches,
                removableSources: viewModel.state.removableSources,
                importPresentations: viewModel.importPresentations,
                sidebarSelection: viewModel.sidebarSelection,
                ejectingSourceIdentities: viewModel.ejectingSourceIdentities,
                selectSidebar: viewModel.selectSidebar,
                ejectSource: viewModel.ejectRemovableSource
            )
        } detail: {
            VStack(spacing: 0) {
                if viewModel.sidebarSelection == .allImports {
                    AllImportsListView(
                        batches: viewModel.state.importBatches,
                        selectBatch: { batchID in
                            viewModel.selectSidebar(.importBatch(batchID))
                        }
                    )
                } else {
                    detailContent
                }
                if let presentation = viewModel.selectedImportPresentation {
                    ImportPlanFooter(
                        presentation: presentation,
                        fixedLibraries: viewModel.state.libraries.filter { $0.availability == .available },
                        sourceDisplayName: viewModel.state.removableSources
                            .first { $0.path == presentation.sourcePath }?.displayName ?? "",
                        isCancelling: viewModel.cancellingImportSources.contains(presentation.sourcePath),
                        importPreferences: viewModel.importPreferences,
                        setDestination: { destination in
                            viewModel.setImportDestination(destination, for: presentation.sourcePath)
                        },
                        queueImport: {
                            viewModel.queueImport(for: presentation.sourcePath)
                        },
                        cancelImport: {
                            viewModel.cancelImport(for: presentation.sourcePath)
                        },
                        ejectCard: {
                            if let source = viewModel.state.removableSources
                                .first(where: { $0.path == presentation.sourcePath })
                            {
                                viewModel.ejectRemovableSource(source.root)
                            }
                        },
                        retryPlanning: {
                            viewModel.retryImportPlanning(for: presentation.sourcePath)
                        },
                        revealAttentionItems: { ids in
                            viewModel.selectAssets(ids)
                        },
                        sessionPreferences: viewModel.sessionPreferences(for: presentation.sourcePath),
                        setSessionPreferences: { prefs in
                            viewModel.setSessionPreferences(prefs, for: presentation.sourcePath)
                        }
                    )
                }
                if let trashStatus = TrashStatusPresentation.map(viewModel.trashQueueState) {
                    TrashStatusBar(presentation: trashStatus)
                }
                if let handOff = viewModel.handOffProgress {
                    HandOffStatusBar(progress: handOff, cancel: viewModel.cancelHandOff)
                }
            }
            // Hosted on its own view so `Do not ask again` applies to this alert only.
            .background { largeTrashDownloadAlertHost }
            // The trailing inspector column collapses and expands like the sidebar; the
            // toolbar button and View ▸ Show Edit drive the same intent.
            .inspector(isPresented: Binding(
                get: { viewModel.isEditPanelPresented },
                set: { presented in
                    if presented != viewModel.isEditPanelPresented {
                        viewModel.toggleEditPanel()
                    }
                }
            )) {
                EditPanelView(
                    photoName: viewModel.editTarget?.id.fileURL.lastPathComponent,
                    facts: viewModel.editPhotoFacts,
                    recipe: viewModel.editDraft,
                    isPickingNeutral: viewModel.isPickingNeutral,
                    canPickNeutral: viewModel.canPickNeutral,
                    crop: EditPanelCropState(
                        isCropping: viewModel.isCropping,
                        canCrop: viewModel.canCrop,
                        aspect: viewModel.cropAspect,
                        isLandscape: viewModel.cropAspectIsLandscape
                    ),
                    setValue: viewModel.setEditValue,
                    setDragging: viewModel.setEditDragging,
                    resetSection: viewModel.resetEditSection,
                    toggleNeutralPicker: viewModel.toggleNeutralPicker,
                    cropActions: EditPanelCropActions(
                        toggleTool: viewModel.toggleCropTool,
                        setAspect: viewModel.setCropAspect,
                        rotateAspect: viewModel.rotateCropAspect,
                        turn: viewModel.turnPhoto(clockwise:),
                        flip: viewModel.flipPhoto(horizontally:)
                    ),
                    setEntering: viewModel.setEnteringEditValue,
                    setLensCorrection: viewModel.setLensCorrection
                )
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ViewModePicker(
                    viewMode: viewModel.viewMode,
                    setViewMode: viewModel.setViewMode
                )
                CatalogFilterControl(
                    descriptor: viewModel.queryDescriptor,
                    options: viewModel.state.filterOptions,
                    isPresented: Binding(
                        get: { viewModel.isFilterPresented },
                        set: { viewModel.setFilterPresented($0) }
                    ),
                    setKind: viewModel.setMediaKind,
                    setFileType: viewModel.setMediaFileType,
                    setChoice: viewModel.setMediaChoice,
                    clearFilters: viewModel.clearMediaFilter
                )
                CatalogSortMenu(
                    sort: viewModel.queryDescriptor.sort,
                    setOrder: viewModel.setSortOrder
                )
            }
            ToolbarItem(placement: .primaryAction) {
                CatalogZoomControl(
                    columnCount: viewModel.gridColumnCount,
                    makeThumbnailsSmaller: viewModel.zoomOutGrid,
                    makeThumbnailsLarger: viewModel.zoomInGrid
                )
                .disabled(viewModel.viewMode != .grid)
            }
            // Trailing-edge Info and Share (APP-041, APP-036). File ▸ Share… and View ▸
            // Show Info are the menu-bar equivalents every toolbar item must have; the
            // Share button is also the anchor every Share path presents from.
            ToolbarItem(placement: .primaryAction) {
                CatalogCurationToolbarControl(
                    currentChoice: viewModel.currentTargetChoice,
                    isEnabled: viewModel.hasMediaChoiceTarget,
                    choose: { viewModel.submitMediaChoice($0, origin: .toolbar) }
                )
            }
            ToolbarItem(placement: .primaryAction) {
                CatalogInfoToolbarButton(
                    isEnabled: viewModel.viewMode == .loupe,
                    isShowing: viewModel.showsLoupeInfo,
                    toggle: viewModel.toggleLoupeInfo
                )
            }
            ToolbarItem(placement: .primaryAction) {
                CatalogShareToolbarButton(
                    isEnabled: !viewModel.currentTargetFileURLs.isEmpty,
                    onAnchor: viewModel.setShareAnchor,
                    share: { viewModel.shareCurrentTargets(origin: .toolbar) }
                )
            }
            ToolbarItem(placement: .primaryAction) {
                CatalogEditToolbarButton(
                    isShowing: viewModel.isEditPanelPresented,
                    toggle: viewModel.toggleEditPanel
                )
            }
            ToolbarItem(placement: .primaryAction) {
                CatalogActionToolbarMenu(
                    openWith: viewModel.openWithMenu,
                    icons: viewModel.openWithApplicationIcons,
                    canReveal: !viewModel.currentTargetFileURLs.isEmpty,
                    canTrash: viewModel.canMoveTargetedMediaToTrash,
                    open: viewModel.openTargetsInDefaultApplication,
                    openWithApplication: viewModel.openTargets(with:),
                    openWithOther: viewModel.openTargetsWithChosenApplication,
                    reveal: viewModel.revealCurrentTargetsInFinder,
                    moveToTrash: viewModel.moveTargetedMediaToTrash
                )
            }
        }
        .alert(
            "Could Not Eject Disk",
            isPresented: Binding(
                get: { viewModel.ejectAlertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissEjectAlert()
                    }
                }
            )
        ) {
            Button("OK") {
                viewModel.dismissEjectAlert()
            }
        } message: {
            if let message = viewModel.ejectAlertMessage {
                Text(message)
            }
        }
        .alert(
            "Couldn’t Prepare Photos",
            isPresented: Binding(
                get: { viewModel.handOffAlertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissHandOffAlert()
                    }
                }
            )
        ) {
            Button("OK") {
                viewModel.dismissHandOffAlert()
            }
        } message: {
            if let message = viewModel.handOffAlertMessage {
                Text(message)
            }
        }
        .alert(
            viewModel.trashAlertMessage ?? "Move to Trash",
            isPresented: Binding(
                get: { viewModel.trashAlertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissTrashAlert()
                    }
                }
            )
        ) {
            Button("Show in Finder") {
                viewModel.showFailedTrashItemsInFinder()
            }
            Button("Dismiss", role: .cancel) {
                viewModel.dismissTrashAlert()
            }
        } message: {
            Text(viewModel.trashAlertDetail)
        }
        .alert(
            viewModel.trashDecisions.first.map { TrashDecisionPrompt(decision: $0).title } ?? "",
            isPresented: Binding(
                get: { !viewModel.trashDecisions.isEmpty },
                // Every dismissal goes through a button (Escape triggers Cancel), and
                // each answers exactly the decision it was shown for; a setter that also
                // answered would consume the next queued decision.
                set: { _ in }
            )
        ) {
            Button(TrashDecisionPrompt.deleteTitle, role: .destructive) {
                viewModel.answerTrashDecisionDelete()
            }
            Button("Cancel", role: .cancel) {
                viewModel.answerTrashDecisionCancel()
            }
        } message: {
            if let decision = viewModel.trashDecisions.first {
                Text(TrashDecisionPrompt(decision: decision).message)
            }
        }
        .confirmationDialog(
            "Reorganize Library?",
            isPresented: Binding(
                get: { viewModel.reorganizationConfirmation != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.cancelReorganizationConfirmation()
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: viewModel.reorganizationConfirmation
        ) { _ in
            Button("Reorganize", role: .destructive) {
                viewModel.confirmReorganization()
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelReorganizationConfirmation()
            }
        } message: { confirmation in
            Text(confirmation.summaryText)
        }
        .alert(
            "Reorganization",
            isPresented: Binding(
                get: { viewModel.reorganizationAlertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.reorganizationAlertMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                viewModel.reorganizationAlertMessage = nil
            }
        } message: {
            if let message = viewModel.reorganizationAlertMessage {
                Text(message)
            }
        }
    }

    @ViewBuilder
    var detailContent: some View {
        switch viewModel.viewMode {
        case .grid:
            MediaGridView(
                title: viewModel.state.title,
                grid: viewModel.state.mediaGrid,
                tileContentStore: viewModel.tileContentStore,
                emptyState: viewModel.state.mediaEmptyState,
                deviceConnectionBanner: viewModel.state.deviceConnectionBanner,
                thumbnailDirectory: viewModel.thumbnailDirectory,
                detailReader: viewModel.tileDetailReader,
                stallMonitor: viewModel.uiStallMonitor,
                onViewportChanged: viewModel.viewportChanged,
                clearFilters: viewModel.clearMediaFilter,
                gridColumnCount: viewModel.gridColumnCount,
                onGridColumnCountChangeRequested: viewModel.setGridColumnCount,
                selectionHandlers: .from(viewModel),
                onItemDoubleClick: { viewModel.openLoupe(id: $0) },
                onReturnKey: { viewModel.openLoupe(id: nil) },
                onMediaChoiceKey: { viewModel.submitMediaChoice($0, origin: .keyboard) },
                onMediaChoice: { id, choice in
                    viewModel.submitMediaChoice(choice, target: .item(id), origin: .inline)
                },
                contextMenu: viewModel.makeMediaItemContextMenu,
                focusTargetID: viewModel.focusedAssetID,
                dismissedCameraBannerIdentities: viewModel.dismissedCameraBannerIdentities,
                onDismissCameraBanner: { viewModel.dismissCameraConnectionBanner($0.identity) }
            )
        case .loupe:
            LoupeView(
                grid: viewModel.state.mediaGrid,
                tileContentStore: viewModel.tileContentStore,
                focusedAssetID: viewModel.focusedAssetID,
                focusedAssetKind: viewModel.focusedAssetKind,
                panePreview: viewModel.displayedPanePreview(.loupe),
                loupeVideoState: viewModel.loupeVideoState,
                isDownloading: viewModel.downloadingSlots.contains(.loupe),
                stripTileEdge: viewModel.stripTileEdge,
                setStripTileEdge: viewModel.setStripTileEdge,
                thumbnailDirectory: viewModel.thumbnailDirectory,
                detailReader: viewModel.tileDetailReader,
                stallMonitor: viewModel.uiStallMonitor,
                selectionHandlers: .from(viewModel),
                onViewportChanged: viewModel.viewportChanged,
                onStripArrow: { delta in
                    if delta < 0 {
                        viewModel.focusPrevious()
                    } else {
                        viewModel.focusNext()
                    }
                },
                onEscape: viewModel.loupeEscape,
                onMediaChoiceKey: { viewModel.submitMediaChoice($0, origin: .keyboard) },
                onMediaChoice: { id, choice in
                    viewModel.submitMediaChoice(choice, target: .item(id), origin: .inline)
                },
                onPlayVideo: { id in viewModel.playLoupeVideo(id: id) },
                focusedMediaChoice: viewModel.panePreviews[.loupe]?.mediaChoice,
                onPreviewMediaChoice: { choice in
                    guard let id = viewModel.focusedAssetID else { return }
                    viewModel.submitMediaChoice(choice, target: .item(id), origin: .inline)
                },
                contextMenu: viewModel.makeMediaItemContextMenu,
                loupeZoomCommand: viewModel.loupeZoomCommand,
                onZoomReport: viewModel.reportLoupeZoom,
                onZoomDoubleClick: { viewModel.toggleLoupeZoom(at: $0) },
                isPickingNeutral: viewModel.isPickingNeutral,
                onPickNeutral: viewModel.pickNeutral(at:),
                cropEditor: viewModel.isCropping
                    ? viewModel.editCropBase.map { base in
                        CropEditorInput(
                            image: base.image,
                            crop: viewModel.editDraft.crop ?? .whole,
                            fractionRatio: viewModel.cropFractionRatio,
                            setCrop: viewModel.setCrop
                        )
                    }
                    : nil,
                videoTrimCommand: viewModel.videoTrimCommand,
                onVideoTrimmed: viewModel.finishTrim(id:),
                loupeInfo: viewModel.loupeInfo
            )
            .navigationTitle(viewModel.state.title)
        case .compare:
            CompareView(
                grid: viewModel.state.mediaGrid,
                tileContentStore: viewModel.tileContentStore,
                leftID: viewModel.comparePair.left,
                rightID: viewModel.comparePair.right,
                leftPreview: viewModel.displayedPanePreview(.compareLeft),
                rightPreview: viewModel.displayedPanePreview(.compareRight),
                leftIsDownloading: viewModel.downloadingSlots.contains(.compareLeft),
                rightIsDownloading: viewModel.downloadingSlots.contains(.compareRight),
                focusTargetID: viewModel.compareStripFocusTargetID,
                stripTileEdge: viewModel.stripTileEdge,
                setStripTileEdge: viewModel.setStripTileEdge,
                thumbnailDirectory: viewModel.thumbnailDirectory,
                detailReader: viewModel.tileDetailReader,
                stallMonitor: viewModel.uiStallMonitor,
                selectionHandlers: .from(viewModel),
                onViewportChanged: viewModel.viewportChanged,
                onStripArrow: { delta in
                    viewModel.slideCompare(delta)
                },
                onEscape: viewModel.exitToGrid,
                onMediaChoiceKey: { viewModel.submitMediaChoice($0, origin: .keyboard) },
                onMediaChoice: { id, choice in
                    viewModel.submitMediaChoice(choice, target: .item(id), origin: .inline)
                },
                leftMediaChoice: viewModel.panePreviews[.compareLeft]?.mediaChoice,
                rightMediaChoice: viewModel.panePreviews[.compareRight]?.mediaChoice,
                onPaneMediaChoice: { pane, choice in
                    viewModel.submitMediaChoice(choice, target: .compare(pane), origin: .inline)
                },
                onPaneActivated: viewModel.activateComparePane,
                contextMenu: viewModel.makeMediaItemContextMenu
            )
            .navigationTitle(viewModel.state.title)
        }
    }
}

private struct AllImportsListView: View {
    let batches: [ImportBatchSummary]
    let selectBatch: (ImportBatchID) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // A real `List(selection:)`, not `Button`s inside a plain `List`:
        // Tab reaches the list, Up/Down move a genuine selection, and
        // Return/click both fire `selectBatch` the same way (DES-080).
        // There is no persistent selection to hold here — picking
        // a row navigates away from `.allImports` entirely, replacing this
        // view — so the binding's getter always reads `nil`.
        List(selection: selectionBinding) {
            ForEach(batches, id: \.batchID) { batch in
                HStack {
                    Text(ImportBatchFormatting.sidebarTitle(for: batch.batchID, among: batches))
                        .foregroundStyle(DesignPalette.label(for: colorScheme))
                    Spacer()
                    Text("\(batch.assetCount) items")
                        .foregroundStyle(DesignPalette.l3(for: colorScheme))
                        .monospacedDigit()
                }
                .tag(batch.batchID)
            }
        }
        .navigationTitle("All Imports")
    }

    private var selectionBinding: Binding<ImportBatchID?> {
        Binding(
            get: { nil },
            set: { newValue in
                if let newValue {
                    selectBatch(newValue)
                }
            }
        )
    }
}

#Preview {
    ContentView(
        viewModel: CatalogWindowViewModel(
            catalogStore: CatalogStore(location: .inMemory),
            preferencesDomain: .suite("Otos.Preview.\(UUID().uuidString)"),
            trashFiles: .refusing
        )
    )
}

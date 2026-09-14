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
            // Trailing-edge Share over the current targets (APP-036). File ▸ Share…
            // is the menu-bar equivalent every toolbar item must have.
            ToolbarItem(placement: .primaryAction) {
                ShareLink(items: viewModel.currentTargetFileURLs) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(viewModel.currentTargetFileURLs.isEmpty)
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
            Text("The affected items remain selected.")
        }
        .confirmationDialog(
            "Reorganize Library?",
            isPresented: $viewModel.showsReorganizationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reorganize", role: .destructive) {
                viewModel.confirmReorganization()
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelReorganizationConfirmation()
            }
        } message: {
            if let summary = viewModel.reorganizationSummaryText {
                Text(summary)
            } else {
                Text("Apply the current import naming policy to this library.")
            }
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
                focusTargetID: viewModel.focusedAssetID,
                identityRemapEpoch: viewModel.identityRemapEpoch,
                identityRemapBatch: viewModel.identityRemapBatch,
                dismissedCameraBannerIdentities: viewModel.dismissedCameraBannerIdentities,
                onDismissCameraBanner: { viewModel.dismissCameraConnectionBanner($0.identity) }
            )
        case .loupe:
            LoupeView(
                grid: viewModel.state.mediaGrid,
                tileContentStore: viewModel.tileContentStore,
                focusedAssetID: viewModel.focusedAssetID,
                focusedAssetKind: viewModel.focusedAssetKind,
                panePreview: viewModel.panePreviews[.loupe],
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
                onEscape: viewModel.exitToGrid,
                onMediaChoiceKey: { viewModel.submitMediaChoice($0, origin: .keyboard) },
                onMediaChoice: { id, choice in
                    viewModel.submitMediaChoice(choice, target: .item(id), origin: .inline)
                },
                onDoubleClickPreview: viewModel.exitToGrid,
                onPlayVideo: { id in viewModel.playLoupeVideo(id: id) },
                focusedMediaChoice: viewModel.panePreviews[.loupe]?.mediaChoice,
                onPreviewMediaChoice: { choice in
                    guard let id = viewModel.focusedAssetID else { return }
                    viewModel.submitMediaChoice(choice, target: .item(id), origin: .inline)
                }
            )
            .navigationTitle(viewModel.state.title)
        case .compare:
            CompareView(
                grid: viewModel.state.mediaGrid,
                tileContentStore: viewModel.tileContentStore,
                leftID: viewModel.comparePair.left,
                rightID: viewModel.comparePair.right,
                leftPreview: viewModel.panePreviews[.compareLeft],
                rightPreview: viewModel.panePreviews[.compareRight],
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
                onPaneActivated: viewModel.activateComparePane
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
            preferencesDomain: .suite("Otos.Preview.\(UUID().uuidString)")
        )
    )
}

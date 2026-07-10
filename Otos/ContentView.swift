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
                removableSources: viewModel.state.removableSources,
                sidebarSelection: viewModel.sidebarSelection,
                ejectingSourceIdentities: viewModel.ejectingSourceIdentities,
                selectSidebar: viewModel.selectSidebar,
                ejectSource: viewModel.ejectRemovableSource
            )
        } detail: {
            detailContent
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ViewModePicker(
                    viewMode: viewModel.viewMode,
                    setViewMode: viewModel.setViewMode
                )
                CatalogFilterMenu(
                    descriptor: viewModel.queryDescriptor,
                    options: viewModel.state.filterOptions,
                    setKind: viewModel.setMediaKind,
                    setFileType: viewModel.setMediaFileType,
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
    }

    @ViewBuilder
    private var detailContent: some View {
        switch viewModel.viewMode {
        case .grid:
            MediaGridView(
                title: viewModel.state.title,
                grid: viewModel.state.mediaGrid,
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
                focusTargetID: viewModel.focusedAssetID
            )
        case .loupe:
            LoupeView(
                grid: viewModel.state.mediaGrid,
                focusedAssetID: viewModel.focusedAssetID,
                panePreview: viewModel.panePreviews[.loupe],
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
                onDoubleClickPreview: viewModel.exitToGrid
            )
            .navigationTitle(viewModel.state.title)
        case .compare:
            CompareView(
                grid: viewModel.state.mediaGrid,
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
                onEscape: viewModel.exitToGrid
            )
            .navigationTitle(viewModel.state.title)
        }
    }
}

#Preview {
    ContentView(viewModel: CatalogWindowViewModel())
}

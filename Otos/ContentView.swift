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
            MediaGridView(
                title: viewModel.state.title,
                grid: viewModel.state.mediaGrid,
                emptyState: viewModel.state.mediaEmptyState,
                deviceConnectionBanner: viewModel.state.deviceConnectionBanner,
                thumbnailDirectory: viewModel.thumbnailDirectory,
                detailReader: viewModel.tileDetailReader,
                imageCache: viewModel.tileImageCache,
                stallMonitor: viewModel.uiStallMonitor,
                diagnostics: viewModel.catalogDiagnostics,
                onViewportChanged: viewModel.viewportChanged,
                clearFilters: viewModel.clearMediaFilter,
                gridColumnCount: viewModel.gridColumnCount,
                onGridColumnCountChangeRequested: viewModel.setGridColumnCount
            )
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                CatalogFilterMenu(
                    descriptor: viewModel.queryDescriptor,
                    options: viewModel.state.filterOptions,
                    toggleKind: viewModel.toggleMediaKind,
                    toggleFormat: viewModel.toggleMediaFormat,
                    clearFilters: viewModel.clearMediaFilter
                )
                CatalogSortMenu(
                    sort: viewModel.queryDescriptor.sort,
                    setField: viewModel.setSortField,
                    setDirection: viewModel.setSortDirection
                )
                CatalogZoomSlider(
                    columnCount: viewModel.gridColumnCount,
                    requestColumnCount: viewModel.setGridColumnCount
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
    }
}

#Preview {
    ContentView(viewModel: CatalogWindowViewModel())
}

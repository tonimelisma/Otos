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
                libraries: viewModel.state.libraries,
                sidebarSelection: viewModel.sidebarSelection,
                selectSidebar: viewModel.selectSidebar
            )
        } detail: {
            MediaGridView(
                title: viewModel.state.title,
                grid: viewModel.state.mediaGrid,
                emptyState: viewModel.state.mediaEmptyState,
                thumbnailDirectory: viewModel.thumbnailDirectory,
                detailReader: viewModel.tileDetailReader,
                onViewportChanged: viewModel.viewportChanged
            )
        }
    }
}

#Preview {
    ContentView(viewModel: CatalogWindowViewModel())
}

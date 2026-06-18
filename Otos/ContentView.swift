//
//  ContentView.swift
//  Otos
//
//  Created by Taylor on 6/2/26.
//

import SwiftUI

/// ContentView composes already-projected state. Snapshot subscriptions,
/// projection cadence, and catalog mutations stay outside the view tree.
struct ContentView: View {
    @Bindable var viewModel: CatalogWindowViewModel

    var body: some View {
        NavigationSplitView {
            SidebarView(
                libraries: viewModel.state.libraries,
                sidebarSelection: $viewModel.sidebarSelection
            )
        } detail: {
            MediaTableView(
                title: viewModel.state.title,
                assets: viewModel.state.assetsInSelectedScope,
                emptyState: viewModel.state.mediaEmptyState
            )
        }
    }
}

#Preview {
    ContentView(viewModel: CatalogWindowViewModel())
}

//
//  ContentView.swift
//  Otos
//
//  Created by Taylor on 6/2/26.
//

import SwiftUI

struct ContentView: View {
    let session: CatalogSession
    @State private var browserState: CatalogBrowserState

    init(session: CatalogSession) {
        self.session = session
        _browserState = State(initialValue: CatalogBrowserState(catalogProjection: session.projection))
    }

    var body: some View {
        @Bindable var browser = browserState

        NavigationSplitView {
            SidebarView(snapshot: session.snapshot, selection: $browser.selection)
        } detail: {
            MediaTableView(title: browserState.title, assets: browserState.assetsForSelection)
        }
        .task {
            session.start()
            browserState.update(snapshot: session.snapshot)
        }
        .onChange(of: session.snapshot) { _, snapshot in
            browserState.update(snapshot: snapshot)
        }
        .onChange(of: browserState.selection) { _, _ in
            browserState.update(snapshot: session.snapshot)
        }
    }
}

#Preview {
    ContentView(session: CatalogSession())
}

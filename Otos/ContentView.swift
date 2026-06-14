//
//  ContentView.swift
//  Otos
//
//  Created by Taylor on 6/2/26.
//

import SwiftUI

struct ContentView: View {
    @Bindable var model: OtosAppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(snapshot: model.snapshot, selection: $model.selection)
        } detail: {
            MediaTableView(title: model.selectedTitle, assets: model.visibleAssets)
        }
        .task {
            model.start()
        }
        .alert("Catalog", isPresented: messageBinding) {
            Button("OK", role: .cancel) {
                model.dismissMessage()
            }
        } message: {
            Text(model.message ?? "")
        }
    }

    private var messageBinding: Binding<Bool> {
        Binding {
            model.message != nil
        } set: { isPresented in
            if !isPresented {
                model.dismissMessage()
            }
        }
    }
}

#Preview {
    ContentView(model: OtosAppModel())
}

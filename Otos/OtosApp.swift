//
//  OtosApp.swift
//  Otos
//
//  Created by Taylor on 6/2/26.
//

import OSLog
import SwiftUI

@main
struct OtosApp: App {
    @State private var model = OtosAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    let state = OtosSignpost.app.beginInterval("MainWindowContentAttached")
                    OtosLog.app.info("Main window content attached")
                    OtosSignpost.app.endInterval("MainWindowContentAttached", state)
                }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

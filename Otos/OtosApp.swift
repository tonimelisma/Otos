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
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    let state = OtosSignpost.app.beginInterval("MainWindowContentAttached")
                    OtosLog.app.info("Main window content attached")
                    OtosSignpost.app.endInterval("MainWindowContentAttached", state)
                }
        }
    }
}

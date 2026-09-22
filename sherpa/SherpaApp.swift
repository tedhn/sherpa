//
//  SherpaApp.swift
//  sherpa
//
//  Created by Ted on 21/09/2026.
//

import SwiftUI

@main
struct SherpaApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
        }
    }
}

//
//  SherpaApp.swift
//  sherpa
//
//  Created by Ted on 21/09/2026.
//

import SwiftUI

@main
struct SherpaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

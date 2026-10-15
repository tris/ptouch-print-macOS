//
//  PTouchBridgeApp.swift
//  PTouchBridge
//

import SwiftUI

@main
struct PTouchBridgeApp: App {
    @StateObject private var controller = PrintController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
                .onOpenURL { controller.handle(url: $0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL {
                        controller.handle(url: url)
                    }
                }
        }
    }
}

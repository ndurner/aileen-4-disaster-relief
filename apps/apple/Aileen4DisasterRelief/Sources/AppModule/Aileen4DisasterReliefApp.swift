import SwiftUI

@main
struct Aileen4DisasterReliefApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task {
                    await OverlayAutomationLab.runIfRequested()
                }
        }
    }
}

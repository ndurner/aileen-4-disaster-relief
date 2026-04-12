import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            BackgroundBriefingView()
                .tabItem {
                    Label("Background briefing", systemImage: "doc.text")
                }

            ContentProductionView()
                .tabItem {
                    Label("Content production", systemImage: "sparkles.rectangle.stack")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

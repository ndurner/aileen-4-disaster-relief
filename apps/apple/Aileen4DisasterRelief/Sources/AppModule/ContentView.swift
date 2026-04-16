import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: Tab = .backgroundBriefing
    @State private var appliedInitialTabSelection = false

    var body: some View {
        TabView(selection: $selectedTab) {
            BackgroundBriefingView()
                .tag(Tab.backgroundBriefing)
                .tabItem {
                    Label("Background briefing", systemImage: "doc.text")
                }

            ContentProductionView()
                .tag(Tab.contentProduction)
                .tabItem {
                    Label("Content production", systemImage: "sparkles.rectangle.stack")
                }

            SettingsView()
                .tag(Tab.settings)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .onAppear {
            guard !appliedInitialTabSelection else { return }
            appliedInitialTabSelection = true

            if appState.hasBackgroundBriefing {
                selectedTab = .contentProduction
            }
        }
    }

    private enum Tab {
        case backgroundBriefing
        case contentProduction
        case settings
    }
}

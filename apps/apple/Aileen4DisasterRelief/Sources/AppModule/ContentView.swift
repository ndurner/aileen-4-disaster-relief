import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            OceanBackdrop()

            ZStack {
                tabLayer(BackgroundBriefingView(), for: .backgroundBriefing)
                tabLayer(ContentProductionView(), for: .contentProduction)
                tabLayer(SettingsView(), for: .settings)
            }
            .animation(.snappy(duration: 0.35, extraBounce: 0.05), value: appState.selectedTab)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OceanTabBar(selection: $appState.selectedTab)
        }
        .tint(OceanPalette.deepWater)
    }

    private func tabLayer<Screen: View>(_ screen: Screen, for tab: AppTab) -> some View {
        screen
            .opacity(appState.selectedTab == tab ? 1 : 0)
            .allowsHitTesting(appState.selectedTab == tab)
            .accessibilityHidden(appState.selectedTab != tab)
            .zIndex(appState.selectedTab == tab ? 1 : 0)
    }
}

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showsLaunchSplash = true

    var body: some View {
        ZStack {
            OceanBackdrop()

            ZStack {
                tabLayer(BackgroundBriefingView(), for: .backgroundBriefing)
                tabLayer(ContentProductionView(), for: .contentProduction)
                tabLayer(SettingsView(), for: .settings)
            }
            .animation(.snappy(duration: 0.35, extraBounce: 0.05), value: appState.selectedTab)
            .opacity(showsLaunchSplash ? 0 : 1)
            .allowsHitTesting(!showsLaunchSplash)

            if showsLaunchSplash {
                AileenLaunchSplash()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OceanTabBar(selection: $appState.selectedTab)
                .opacity(showsLaunchSplash ? 0 : 1)
        }
        .tint(OceanPalette.deepWater)
        .task {
            guard showsLaunchSplash else { return }
            try? await Task.sleep(for: .milliseconds(1350))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.28)) {
                showsLaunchSplash = false
            }
        }
    }

    private func tabLayer<Screen: View>(_ screen: Screen, for tab: AppTab) -> some View {
        screen
            .opacity(appState.selectedTab == tab ? 1 : 0)
            .allowsHitTesting(appState.selectedTab == tab)
            .accessibilityHidden(appState.selectedTab != tab)
            .zIndex(appState.selectedTab == tab ? 1 : 0)
    }
}

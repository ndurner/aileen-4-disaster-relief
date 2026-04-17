import SwiftUI

struct BackgroundBriefingView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        OceanScreen {
            AileenWorkflowCard(
                    imageName: "AileenBriefingScene",
                    title: "Keep me briefed",
                    message: "Facts, priorities, and guardrails to keep steady between updates."
                ) {
                OceanTextEditor(
                    text: $appState.backgroundBriefing,
                    placeholder: """
                    What I should keep in mind:
                    - Confirmed situation details and access changes
                    - Key partners, spokespeople, and contact points
                    - Tone, wording, or claims to avoid
                    - Approved phrases that should stay consistent
                    """,
                    minHeight: 310
                )
                .accessibilityLabel("Background briefing")
            }
        }
    }
}

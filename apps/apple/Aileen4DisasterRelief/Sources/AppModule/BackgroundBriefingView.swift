import SwiftUI

struct BackgroundBriefingView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        OceanScreen(
            eyebrow: "Response Brief",
            title: "Background briefing",
            subtitle: "Keep the durable facts, partners, priorities, and wording guardrails that should shape every update."
        ) {
            OceanCard {
                OceanSectionHeader(title: "Persistent briefing", detail: "Always on hand")

                ViewThatFits {
                    HStack(spacing: 8) {
                        OceanPill(text: "Situation")
                        OceanPill(text: "Stakeholders")
                        OceanPill(text: "Guardrails")
                        OceanPill(text: "Approved wording")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            OceanPill(text: "Situation")
                            OceanPill(text: "Stakeholders")
                        }

                        HStack(spacing: 8) {
                            OceanPill(text: "Guardrails")
                            OceanPill(text: "Approved wording")
                        }
                    }
                }

                OceanTextEditor(
                    text: $appState.backgroundBriefing,
                    placeholder: """
                    Example:
                    - Main access routes are open, but some checkpoints remain monitored.
                    - Use calm, practical language for residents and volunteers.
                    - Keep helpline details and approved spokesperson names consistent.
                    """,
                    minHeight: 310
                )
            }

            OceanCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(OceanPalette.coral)
                        .frame(width: 38, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(OceanPalette.sand.opacity(0.95))
                        )

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Use this as the durable context layer")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(OceanPalette.ink)

                        Text("It should hold the details that stay true across updates, not the facts that belong only to one story.")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(OceanPalette.ink.opacity(0.70))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

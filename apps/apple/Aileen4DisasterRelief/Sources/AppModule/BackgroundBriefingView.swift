import SwiftUI

struct BackgroundBriefingView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            Form {
                Section("Persistent Briefing") {
                    Text("Keep durable context here: situation, stakeholders, priorities, approved wording, and guardrails.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $appState.backgroundBriefing)
                        .frame(minHeight: 320)
                        .font(.body.monospaced())
                }
            }
            .navigationTitle("Background briefing")
        }
    }
}

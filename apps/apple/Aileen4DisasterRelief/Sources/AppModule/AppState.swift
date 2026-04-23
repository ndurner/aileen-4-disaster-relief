import Foundation

enum AppTab: String, CaseIterable, Identifiable {
    case backgroundBriefing
    case contentProduction
    case settings

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .backgroundBriefing:
            return "Brief"
        case .contentProduction:
            return "Create"
        case .settings:
            return "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .backgroundBriefing:
            return "water.waves"
        case .contentProduction:
            return "sparkles"
        case .settings:
            return "slider.horizontal.3"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var backgroundBriefing: String {
        didSet { defaults.set(backgroundBriefing, forKey: Keys.backgroundBriefing) }
    }

    @Published var story: String {
        didSet { defaults.set(story, forKey: Keys.story) }
    }

    @Published var selectedProductionModel: ModelOption {
        didSet { defaults.set(selectedProductionModel.rawValue, forKey: Keys.selectedProductionModel) }
    }

    @Published var selectedTextModel: ModelOption {
        didSet { defaults.set(selectedTextModel.rawValue, forKey: Keys.selectedTextModel) }
    }

    @Published var selectedCloudProductionModel: CloudModelOption {
        didSet { defaults.set(selectedCloudProductionModel.rawValue, forKey: Keys.selectedCloudProductionModel) }
    }

    @Published var selectedCloudTextModel: CloudModelOption {
        didSet { defaults.set(selectedCloudTextModel.rawValue, forKey: Keys.selectedCloudTextModel) }
    }

    @Published var inferenceMode: InferenceMode {
        didSet { defaults.set(inferenceMode.rawValue, forKey: Keys.inferenceMode) }
    }

    @Published var googleAIStudioAPIKey: String {
        didSet { try? googleAIStudioAPIKeyStore.save(googleAIStudioAPIKey) }
    }

    @Published var selectedTab: AppTab {
        didSet { defaults.set(selectedTab.rawValue, forKey: Keys.selectedTab) }
    }

    private let defaults: UserDefaults
    private let googleAIStudioAPIKeyStore: GoogleAIStudioAPIKeyStore

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        googleAIStudioAPIKeyStore = GoogleAIStudioAPIKeyStore()
        let storedBackgroundBriefing = defaults.string(forKey: Keys.backgroundBriefing) ?? ""
        backgroundBriefing = storedBackgroundBriefing
        story = defaults.string(forKey: Keys.story) ?? ""
        selectedProductionModel = ModelOption(rawValue: defaults.string(forKey: Keys.selectedProductionModel) ?? "") ?? .e2bLiteRT
        selectedTextModel = ModelOption(rawValue: defaults.string(forKey: Keys.selectedTextModel) ?? "") ?? .e4bLiteRT
        selectedCloudProductionModel = CloudModelOption(rawValue: defaults.string(forKey: Keys.selectedCloudProductionModel) ?? "") ?? .gemma426bA4B
        selectedCloudTextModel = CloudModelOption(rawValue: defaults.string(forKey: Keys.selectedCloudTextModel) ?? "") ?? .gemma431B
        inferenceMode = InferenceMode(rawValue: defaults.string(forKey: Keys.inferenceMode) ?? "") ?? .onDevice
        googleAIStudioAPIKey = (try? googleAIStudioAPIKeyStore.load()) ?? ""
        selectedTab = AppState.initialSelectedTab(defaults: defaults, backgroundBriefing: storedBackgroundBriefing)
    }

    var hasBackgroundBriefing: Bool {
        !backgroundBriefing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasGoogleAIStudioAPIKey: Bool {
        !googleAIStudioAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var inferenceConfiguration: InferenceConfiguration {
        InferenceConfiguration(
            mode: inferenceMode,
            onDeviceVisualModel: selectedProductionModel,
            onDeviceTextModel: selectedTextModel,
            cloudVisualModel: selectedCloudProductionModel,
            cloudTextModel: selectedCloudTextModel,
            cloudAPIKey: googleAIStudioAPIKey
        )
    }

    private static func initialSelectedTab(defaults: UserDefaults, backgroundBriefing: String) -> AppTab {
        if let storedTab = AppTab(rawValue: defaults.string(forKey: Keys.selectedTab) ?? "") {
            return storedTab
        }

        let hasBackgroundBriefing = !backgroundBriefing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasBackgroundBriefing ? .contentProduction : .backgroundBriefing
    }

    private enum Keys {
        static let backgroundBriefing = "backgroundBriefing"
        static let story = "story"
        static let selectedProductionModel = "selectedProductionModel"
        static let selectedTextModel = "selectedTextModel"
        static let selectedCloudProductionModel = "selectedCloudProductionModel"
        static let selectedCloudTextModel = "selectedCloudTextModel"
        static let inferenceMode = "inferenceMode"
        static let selectedTab = "selectedTab"
    }
}

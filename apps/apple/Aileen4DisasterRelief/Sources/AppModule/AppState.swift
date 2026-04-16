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

    @Published var preferredModelSource: ModelSourcePreference {
        didSet { defaults.set(preferredModelSource.rawValue, forKey: Keys.preferredModelSource) }
    }

    @Published var selectedTab: AppTab {
        didSet { defaults.set(selectedTab.rawValue, forKey: Keys.selectedTab) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedBackgroundBriefing = defaults.string(forKey: Keys.backgroundBriefing) ?? ""
        backgroundBriefing = storedBackgroundBriefing
        story = defaults.string(forKey: Keys.story) ?? ""
        selectedProductionModel = ModelOption(rawValue: defaults.string(forKey: Keys.selectedProductionModel) ?? "") ?? .e2bLiteRT
        selectedTextModel = ModelOption(rawValue: defaults.string(forKey: Keys.selectedTextModel) ?? "") ?? .e4bLiteRT
        preferredModelSource = ModelSourcePreference(rawValue: defaults.string(forKey: Keys.preferredModelSource) ?? "") ?? .injected
        selectedTab = AppState.initialSelectedTab(defaults: defaults, backgroundBriefing: storedBackgroundBriefing)
    }

    var hasBackgroundBriefing: Bool {
        !backgroundBriefing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        static let preferredModelSource = "preferredModelSource"
        static let selectedTab = "selectedTab"
    }
}

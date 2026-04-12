import Foundation

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

    @Published var ffmpegExecutablePath: String {
        didSet { defaults.set(ffmpegExecutablePath, forKey: Keys.ffmpegExecutablePath) }
    }

    @Published var preferredModelSource: ModelSourcePreference {
        didSet { defaults.set(preferredModelSource.rawValue, forKey: Keys.preferredModelSource) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        backgroundBriefing = defaults.string(forKey: Keys.backgroundBriefing) ?? ""
        story = defaults.string(forKey: Keys.story) ?? ""
        selectedProductionModel = ModelOption(rawValue: defaults.string(forKey: Keys.selectedProductionModel) ?? "") ?? .e2bLiteRT
        selectedTextModel = ModelOption(rawValue: defaults.string(forKey: Keys.selectedTextModel) ?? "") ?? .e4bLiteRT
        ffmpegExecutablePath = defaults.string(forKey: Keys.ffmpegExecutablePath) ?? "/usr/local/bin/ffmpeg"
        preferredModelSource = ModelSourcePreference(rawValue: defaults.string(forKey: Keys.preferredModelSource) ?? "") ?? .injected
    }

    private enum Keys {
        static let backgroundBriefing = "backgroundBriefing"
        static let story = "story"
        static let selectedProductionModel = "selectedProductionModel"
        static let selectedTextModel = "selectedTextModel"
        static let ffmpegExecutablePath = "ffmpegExecutablePath"
        static let preferredModelSource = "preferredModelSource"
    }
}

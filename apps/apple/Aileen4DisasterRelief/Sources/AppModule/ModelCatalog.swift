import Foundation

enum ProductionExecutionMode: String, CaseIterable, Identifiable {
    case field = "field"
    case desk = "desk"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .field:
            return "Field"
        case .desk:
            return "Desk"
        }
    }

    var shortLabel: String {
        switch self {
        case .field:
            return "Create now"
        case .desk:
            return "Finish later"
        }
    }

    var detail: String {
        switch self {
        case .field:
            return "Create the finished post now, including media, text, and the share package."
        case .desk:
            return "Save the story and original media so a trusted teammate can finish it later."
        }
    }
}

enum InferenceMode: String, CaseIterable, Identifiable {
    case onDevice = "on_device"
    case cloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDevice:
            return "This Device"
        case .cloud:
            return "Cloud"
        }
    }
}

enum ModelOption: String, CaseIterable, Identifiable {
    case e2bLiteRT = "gemma-4-E2B-it.litertlm"
    case e4bLiteRT = "gemma-4-E4B-it.litertlm"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .e2bLiteRT:
            return "Fast device model"
        case .e4bLiteRT:
            return "Larger device model"
        }
    }

    var defaultUse: String {
        switch self {
        case .e2bLiteRT:
            return "Visual production"
        case .e4bLiteRT:
            return "Post body generation"
        }
    }
}

enum CloudModelOption: String, CaseIterable, Identifiable {
    case gemma426bA4B = "gemma-4-26b-a4b-it"
    case gemma431B = "gemma-4-31b-it"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemma426bA4B:
            return "Balanced cloud model"
        case .gemma431B:
            return "Larger cloud model"
        }
    }

    var detail: String {
        switch self {
        case .gemma426bA4B:
            return "Good default for faster cloud creation."
        case .gemma431B:
            return "More capacity for harder posts, with longer waits."
        }
    }

    var requestModelIdentifier: String {
        rawValue
    }
}

struct InferenceConfiguration {
    let mode: InferenceMode
    let onDeviceVisualModel: ModelOption
    let onDeviceTextModel: ModelOption
    let cloudVisualModel: CloudModelOption
    let cloudTextModel: CloudModelOption
    let cloudAPIKey: String

    var hasCloudAPIKey: Bool {
        !cloudAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum ModelAvailability {
    case available(URL, detail: String)
    case missing(detail: String)

    var url: URL? {
        switch self {
        case .available(let url, _):
            return url
        case .missing:
            return nil
        }
    }

    var detail: String {
        switch self {
        case .available(_, let detail):
            return detail
        case .missing(let detail):
            return detail
        }
    }
}

struct ModelLocator {
    private func applicationModelsDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("Models", isDirectory: true)
    }

    private func importedModelsDirectoryURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DownloadedModels", isDirectory: true)
    }

    func resolve(_ model: ModelOption) -> ModelAvailability {
        do {
            let injected = try applicationModelsDirectory()
                .appendingPathComponent(model.rawValue, isDirectory: false)
            let imported = importedModelsDirectoryURL()
                .appendingPathComponent(model.rawValue, isDirectory: false)

            let orderedCandidates: [(URL, String)] = [
                (injected, "Available on device from Application Support/Models."),
                (imported, "Available on device from imported Files storage.")
            ]

            for (url, detail) in orderedCandidates where FileManager.default.fileExists(atPath: url.path) {
                return .available(url, detail: detail)
            }

            return .missing(
                detail: "Expected \(model.rawValue) in Application Support/Models or the imported on-device model folder. Add it from Files in Settings or push it with the shared device script."
            )
        } catch {
            return .missing(detail: "Unable to resolve model storage: \(error.localizedDescription)")
        }
    }

    func importedModelsDirectory() -> URL {
        importedModelsDirectoryURL()
    }
}

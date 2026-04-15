import Foundation

enum ModelSourcePreference: String, CaseIterable, Identifiable {
    case injected
    case downloaded

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .injected:
            return "Injected"
        case .downloaded:
            return "Downloaded"
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
            return "Gemma 4 E2B"
        case .e4bLiteRT:
            return "Gemma 4 E4B"
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

    private func downloadedModelsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DownloadedModels", isDirectory: true)
    }

    func resolve(_ model: ModelOption, sourcePreference: ModelSourcePreference) -> ModelAvailability {
        do {
            let injected = try applicationModelsDirectory().appendingPathComponent(model.rawValue, isDirectory: false)
            let downloaded = downloadedModelsDirectory().appendingPathComponent(model.rawValue, isDirectory: false)

            let orderedCandidates: [(URL, String)] = switch sourcePreference {
            case .injected:
                [
                    (injected, "Using injected model from Application Support/Models."),
                    (downloaded, "Using downloaded model from Documents/DownloadedModels.")
                ]
            case .downloaded:
                [
                    (downloaded, "Using downloaded model from Documents/DownloadedModels."),
                    (injected, "Using injected model from Application Support/Models.")
                ]
            }

            for (url, detail) in orderedCandidates where FileManager.default.fileExists(atPath: url.path) {
                return .available(url, detail: detail)
            }

            return .missing(detail: "Expected \(model.rawValue) in Application Support/Models or Documents/DownloadedModels. Inject it with the shared device script or import it in Settings.")
        } catch {
            return .missing(detail: "Unable to resolve model storage: \(error.localizedDescription)")
        }
    }

    func importedModelsDirectory() -> URL {
        downloadedModelsDirectory()
    }
}

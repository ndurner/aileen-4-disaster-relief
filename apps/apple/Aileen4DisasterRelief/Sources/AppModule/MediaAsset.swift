import AVFoundation
import Foundation
import UniformTypeIdentifiers

struct MediaAsset: Identifiable, Hashable {
    enum Kind: String, Codable {
        case image
        case movie
    }

    let id: UUID
    let kind: Kind
    let originalURL: URL
    let localCopyURL: URL
    let displayName: String

    init(id: UUID = UUID(), kind: Kind, originalURL: URL, localCopyURL: URL, displayName: String) {
        self.id = id
        self.kind = kind
        self.originalURL = originalURL
        self.localCopyURL = localCopyURL
        self.displayName = displayName
    }

    var promptSummary: String {
        "\(kind == .image ? "image" : "movie"): \(displayName)"
    }

    static func kind(for url: URL) -> Kind {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie) {
            return .movie
        }
        return .image
    }
}

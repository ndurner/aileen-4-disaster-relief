import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ProductionWorkflowViewModel: ObservableObject {
    enum OutputKind: String, CaseIterable, Identifiable {
        case image
        case reel

        var id: String { rawValue }
    }

    @Published var selectedPhotoItems: [PhotosPickerItem] = []
    @Published var assets: [MediaAsset] = []
    @Published var outputKind: OutputKind = .image
    @Published var isRunning = false
    @Published var productionSummary = ""
    @Published var captionText = ""
    @Published var executedToolCalls: [LiteRTToolCall] = []
    @Published var producedURLs: [URL] = []
    @Published var shareItems: [Any] = []
    @Published var latestError: String?

    private let locator = ModelLocator()
    private let toolEngine = GemmaToolCallingEngine()
    private let captionRunner = GemmaTextRunner()

    func appendImportedFile(_ sourceURL: URL) throws {
        let targetDirectory = try assetStorageDirectory()
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let targetURL = targetDirectory.appendingPathComponent("\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: targetURL)

        assets.append(MediaAsset(
            kind: MediaAsset.kind(for: sourceURL),
            originalURL: sourceURL,
            localCopyURL: targetURL,
            displayName: sourceURL.lastPathComponent
        ))
    }

    func ingestPhotos() async {
        for item in selectedPhotoItems {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    let suggestedName = item.itemIdentifier ?? UUID().uuidString
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(suggestedName).\(ext)")
                    try data.write(to: tempURL, options: .atomic)
                    try appendImportedFile(tempURL)
                }
            } catch {
                latestError = error.localizedDescription
            }
        }
        selectedPhotoItems = []
    }

    func run(backgroundBriefing: String, story: String, visualModel: ModelOption, textModel: ModelOption, modelSource: ModelSourcePreference, ffmpegExecutablePath: String) async {
        isRunning = true
        latestError = nil
        productionSummary = ""
        captionText = ""
        executedToolCalls = []
        producedURLs = []
        shareItems = []

        defer { isRunning = false }

        do {
            let visualAvailability = locator.resolve(visualModel, sourcePreference: modelSource)
            guard let visualURL = visualAvailability.url else {
                throw GemmaTextRunnerError.runtime(visualAvailability.detail)
            }

            let contentPrompt = makeProductionPrompt(backgroundBriefing: backgroundBriefing, story: story)
            let toolResult = try await toolEngine.run(initialPrompt: contentPrompt, modelURL: visualURL, ffmpegExecutablePath: ffmpegExecutablePath)
            executedToolCalls = toolResult.toolCalls
            productionSummary = toolResult.finalText
            producedURLs = toolResult.producedURLs

            let textAvailability = locator.resolve(textModel, sourcePreference: modelSource)
            guard let textURL = textAvailability.url else {
                throw GemmaTextRunnerError.runtime(textAvailability.detail)
            }

            try await captionRunner.makeSession(modelURL: textURL)
            defer { Task { await captionRunner.destroySession() } }
            let captionPrompt = ProductionPrompts.captionPrompt(backgroundBriefing: backgroundBriefing, story: story, producedVisualSummary: productionSummary)
            let parsed = try await captionRunner.sendJSON(ProductionToolSchema.userMessageJSON(text: captionPrompt))
            captionText = parsed.text
            shareItems = producedURLs + [captionText].filter { !$0.isEmpty }
        } catch {
            latestError = error.localizedDescription
        }
    }

    private func makeProductionPrompt(backgroundBriefing: String, story: String) -> String {
        ProductionPrompts.productionPrompt(
            backgroundBriefing: backgroundBriefing,
            story: story,
            outputKind: outputKind,
            assets: assets
        )
    }

    private func assetStorageDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("ImportedAssets", isDirectory: true)
    }
}

enum ProductionPrompts {
    static func productionPrompt(backgroundBriefing: String, story: String, outputKind: ProductionWorkflowViewModel.OutputKind, assets: [MediaAsset]) -> String {
        let assetList = assets.map(\.promptSummary).joined(separator: "\n- ")
        return """
        You are preparing disaster-relief social media content.
        Background briefing:
        \(backgroundBriefing.isEmpty ? "(none provided)" : backgroundBriefing)

        Story:
        \(story.isEmpty ? "(none provided)" : story)

        Requested output:
        \(outputKind.rawValue)

        Available media assets:
        - \(assetList.isEmpty ? "(none selected)" : assetList)

        Use tool calls to plan and assemble the visuals. Prefer a concise, production-ready output.
        """
    }

    static func captionPrompt(backgroundBriefing: String, story: String, producedVisualSummary: String) -> String {
        """
        Write the social-media caption text for a disaster-relief post.
        Background briefing:
        \(backgroundBriefing.isEmpty ? "(none provided)" : backgroundBriefing)

        Story:
        \(story.isEmpty ? "(none provided)" : story)

        Visual output summary:
        \(producedVisualSummary.isEmpty ? "(none produced)" : producedVisualSummary)

        Keep it publication-ready and concise.
        """
    }
}

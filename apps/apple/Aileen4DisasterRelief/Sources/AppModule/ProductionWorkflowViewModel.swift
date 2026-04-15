import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
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
    @Published var exportDirectoryURL: URL?
    @Published var latestError: String?

    private let locator = ModelLocator()
    private let toolEngine = GemmaToolCallingEngine()
    private let captionRunner = GemmaTextRunner()
    private var nextCameraRollAssetNumber = 1
    private var nextImportedFileNumber = 1

    func appendImportedFile(_ sourceURL: URL, displayName overrideDisplayName: String? = nil) throws {
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
            displayName: overrideDisplayName ?? sourceURL.lastPathComponent
        ))
    }

    func ingestPhotos() async {
        for item in selectedPhotoItems {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    let suggestedName = item.itemIdentifier ?? UUID().uuidString
                    let ext = inferredFileExtension(for: data, supportedTypes: item.supportedContentTypes)
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(suggestedName).\(ext)")
                    try data.write(to: tempURL, options: .atomic)
                    let displayName = cameraRollDisplayName(for: tempURL)
                    try appendImportedFile(tempURL, displayName: displayName)
                }
            } catch {
                latestError = error.localizedDescription
            }
        }
        selectedPhotoItems = []
    }

    func run(backgroundBriefing: String, story: String, visualModel: ModelOption, textModel: ModelOption, modelSource: ModelSourcePreference) async {
        isRunning = true
        latestError = nil
        productionSummary = ""
        captionText = ""
        executedToolCalls = []
        producedURLs = []
        shareItems = []
        exportDirectoryURL = nil

        defer { isRunning = false }

        do {
            let visualAvailability = locator.resolve(visualModel, sourcePreference: modelSource)
            guard let visualURL = visualAvailability.url else {
                throw GemmaTextRunnerError.runtime(visualAvailability.detail)
            }

            let productionAssets = makeProductionAssets()
            let contentPrompt = makeProductionPrompt(backgroundBriefing: backgroundBriefing, story: story, productionAssets: productionAssets)
            let toolResult = try await toolEngine.run(
                initialPrompt: contentPrompt,
                modelURL: visualURL,
                sourceAssets: productionAssets,
                outputKind: outputKind
            )
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

    func prepareExportDirectory() throws -> URL {
        let root = try exportedResultsRootDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let directory = root.appendingPathComponent("Share-\(timestamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for sourceURL in producedURLs {
            let destinationURL = directory.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }

        if !captionText.isEmpty {
            let captionURL = directory.appendingPathComponent("caption.txt", isDirectory: false)
            try captionText.write(to: captionURL, atomically: true, encoding: .utf8)
        }

        exportDirectoryURL = directory
        return directory
    }

    func openExportDirectory() {
        do {
            let directory = try prepareExportDirectory()
            UIApplication.shared.open(directory, options: [:], completionHandler: nil)
        } catch {
            latestError = error.localizedDescription
        }
    }

    func copyCaptionToPasteboard() {
        guard !captionText.isEmpty else { return }
        UIPasteboard.general.string = captionText
    }

    private func makeProductionAssets() -> [ProductionAssetDescriptor] {
        assets.enumerated().map { offset, asset in
            ProductionAssetDescriptor(toolID: "asset_\(offset + 1)", mediaAsset: asset)
        }
    }

    private func makeProductionPrompt(backgroundBriefing: String, story: String, productionAssets: [ProductionAssetDescriptor]) -> String {
        ProductionPrompts.productionPrompt(
            backgroundBriefing: backgroundBriefing,
            story: story,
            outputKind: outputKind,
            assets: productionAssets,
            canvasSize: AppleMediaTooling.renderCanvasSize(for: outputKind)
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

    private func exportedResultsRootDirectory() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("ExportedResults", isDirectory: true)
    }

    private func inferredFileExtension(for data: Data, supportedTypes: [UTType]) -> String {
        if let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
           let typeIdentifier = CGImageSourceGetType(imageSource) as String?,
           let type = UTType(typeIdentifier),
           let ext = type.preferredFilenameExtension {
            return ext
        }

        if let ext = supportedTypes.first(where: { $0.conforms(to: .movie) || $0.conforms(to: .image) })?.preferredFilenameExtension {
            return ext
        }

        return "jpg"
    }

    private func cameraRollDisplayName(for sourceURL: URL) -> String {
        let name = "Camera Roll \(nextCameraRollAssetNumber)"
        nextCameraRollAssetNumber += 1
        return sourceURL.pathExtension.isEmpty ? name : "\(name).\(sourceURL.pathExtension.lowercased())"
    }

    func importedFileDisplayName(for sourceURL: URL) -> String {
        let name = "Imported File \(nextImportedFileNumber)"
        nextImportedFileNumber += 1
        return sourceURL.pathExtension.isEmpty ? name : "\(name).\(sourceURL.pathExtension.lowercased())"
    }
}

enum ProductionPrompts {
    static func productionPrompt(backgroundBriefing: String, story: String, outputKind: ProductionWorkflowViewModel.OutputKind, assets: [ProductionAssetDescriptor], canvasSize: CGSize) -> String {
        let assetList = assets.map(\.promptSummary).joined(separator: "\n- ")
        let validSourceIDs = assets.map(\.toolID).joined(separator: ", ")
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

        Output canvas:
        \(Int(canvasSize.width)) x \(Int(canvasSize.height)) pixels

        Valid source asset IDs:
        \(validSourceIDs.isEmpty ? "(none selected)" : validSourceIDs)

        Use only those exact asset IDs in tool calls. Never use file paths, filenames, display names, UUIDs, or guessed IDs.
        First call compose_visuals with one or more source asset IDs.
        Then, if needed, call add_text_overlay on the returned rendered asset ID.
        x, y, width, and height are pixel values in the output canvas.
        Keep tool responses concise and produce a publication-ready result.
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

import Foundation
import ImageIO
import OSLog
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ProductionWorkflowViewModel: ObservableObject {
    private struct ProductionOverlayPreparation {
        let promptAddendum: String?
        let protectedRegions: OverlayProtectedRegions
        let layoutGuide: OverlayLayoutGuide

        static let empty = ProductionOverlayPreparation(
            promptAddendum: nil,
            protectedRegions: .empty,
            layoutGuide: .empty
        )
    }

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
    @Published var postBodyText = ""
    @Published var producedURLs: [URL] = []
    @Published var shareItems: [Any] = []
    @Published var exportDirectoryURL: URL?
    @Published var latestError: String?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Aileen4DisasterRelief",
        category: "ProductionWorkflow"
    )
    private static let thinkingExtraContextJSON = ProductionToolSchema.stringify(["enable_thinking": true])
    private static let productionOverlayThinkingEnabled = true
    private static let productionGuideProvider: OverlayLayoutGuideProvider = .gemmaVision
    private static let productionGuidanceMode: OverlayLayoutGuidanceMode = .band

    private let locator = ModelLocator()
    private let postBodyRunner = GemmaTextRunner()
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
        postBodyText = ""
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
            let visualRunner = GemmaTextRunner()
            let overlayPreparation = await makeProductionOverlayPreparation(
                productionAssets: productionAssets,
                modelURL: visualURL,
                runner: visualRunner
            )
            let toolEngine = GemmaToolCallingEngine(runner: visualRunner)
            let contentPrompt = makeProductionPrompt(
                backgroundBriefing: backgroundBriefing,
                story: story,
                productionAssets: productionAssets,
                supplementalAddendum: overlayPreparation.promptAddendum
            )
            let toolResult: ToolExecutionResult
            do {
                toolResult = try await toolEngine.run(
                    initialPrompt: contentPrompt,
                    modelURL: visualURL,
                    sourceAssets: productionAssets,
                    outputKind: outputKind,
                    enableThinking: Self.productionOverlayThinkingEnabled,
                    protectedRegionProvider: .none,
                    protectedRegionsOverride: overlayPreparation.protectedRegions,
                    layoutGuideOverride: overlayPreparation.layoutGuide
                )
            } catch {
                await visualRunner.destroySession()
                throw error
            }
            logToolCalls(toolResult.toolCalls)
            productionSummary = productionSummary(for: toolResult)
            producedURLs = toolResult.producedURLs

            let textAvailability = locator.resolve(textModel, sourcePreference: modelSource)
            guard let textURL = textAvailability.url else {
                throw GemmaTextRunnerError.runtime(textAvailability.detail)
            }

            try await postBodyRunner.makeToolSession(
                modelURL: textURL,
                toolsJSON: PostBodyToolSchema.toolsJSON,
                extraContextJSON: Self.thinkingExtraContextJSON
            )
            do {
                let postBodyPrompt = ProductionPrompts.postBodyPrompt(backgroundBriefing: backgroundBriefing, story: story, producedVisualSummary: productionSummary)
                let parsed = try await postBodyRunner.sendJSON(ProductionToolSchema.userMessageJSON(text: postBodyPrompt, assets: productionAssets))
                await postBodyRunner.destroySession()
                postBodyText = PostBodyToolSchema.extractPostBody(from: parsed)
                shareItems = producedURLs + [postBodyText].filter { !$0.isEmpty }
            } catch {
                await postBodyRunner.destroySession()
                throw error
            }
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

        if !postBodyText.isEmpty {
            let postBodyURL = directory.appendingPathComponent("post-body.txt", isDirectory: false)
            try postBodyText.write(to: postBodyURL, atomically: true, encoding: .utf8)
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

    func copyPostBodyToPasteboard() {
        guard !postBodyText.isEmpty else { return }
        UIPasteboard.general.string = postBodyText
    }

    private func makeProductionAssets() -> [ProductionAssetDescriptor] {
        assets.enumerated().map { offset, asset in
            ProductionAssetDescriptor(toolID: "asset_\(offset + 1)", mediaAsset: asset)
        }
    }

    private func makeProductionPrompt(
        backgroundBriefing: String,
        story: String,
        productionAssets: [ProductionAssetDescriptor],
        supplementalAddendum: String? = nil
    ) -> String {
        let basePrompt = ProductionPrompts.productionPrompt(
            backgroundBriefing: backgroundBriefing,
            story: story,
            outputKind: outputKind,
            assets: productionAssets,
            canvasSize: AppleMediaTooling.renderCanvasSize(for: outputKind)
        )

        let trimmedAddendum = supplementalAddendum?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedAddendum, !trimmedAddendum.isEmpty else {
            return basePrompt
        }

        return """
        \(basePrompt)

        Additional production guidance:
        \(trimmedAddendum)
        """
    }

    private func makeProductionOverlayPreparation(
        productionAssets: [ProductionAssetDescriptor],
        modelURL: URL,
        runner: GemmaTextRunner
    ) async -> ProductionOverlayPreparation {
        guard Self.productionGuideProvider != .none else {
            return .empty
        }

        do {
            let tooling = AppleMediaTooling(
                sourceAssets: productionAssets,
                outputKind: outputKind,
                protectedRegionProvider: .none
            )
            let composeResult = try await tooling.execute(
                toolCall: LiteRTToolCall(
                    name: "compose_visuals",
                    arguments: [
                        "asset_ids": .array(productionAssets.map { .string($0.toolID) })
                    ]
                )
            )
            guard let renderedURL = composeResult.outputURL else {
                return .empty
            }

            let analysis = try await GemmaOverlayVision.analyzeDetailed(
                renderedURL: renderedURL,
                modelURL: modelURL,
                enableThinking: Self.productionOverlayThinkingEnabled,
                runner: runner
            )
            let canvasSize = AppleMediaTooling.renderCanvasSize(for: outputKind)
            let protectedRegions = OverlayLayoutGuidance.protectedRegions(
                from: analysis.guide,
                canvasSize: canvasSize
            )
            let layoutGuide: OverlayLayoutGuide
            if protectedRegions.isEmpty {
                layoutGuide = .empty
            } else {
                layoutGuide = OverlayLayoutGuidance.makeGuide(
                    provider: analysis.guide.provider == .none ? Self.productionGuideProvider : analysis.guide.provider,
                    protectedRegions: protectedRegions,
                    canvasSize: canvasSize
                )
            }

            return ProductionOverlayPreparation(
                promptAddendum: OverlayLayoutGuidance.promptAddendum(
                    for: analysis.guide,
                    canvasSize: canvasSize,
                    mode: Self.productionGuidanceMode
                ),
                protectedRegions: protectedRegions,
                layoutGuide: layoutGuide
            )
        } catch {
            Self.logger.error("Gemma overlay pre-analysis failed; continuing without guidance: \(error.localizedDescription, privacy: .public)")
            await runner.destroySession()
            return .empty
        }
    }

    private func productionSummary(for toolResult: ToolExecutionResult) -> String {
        let visibleText = toolResult.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !visibleText.isEmpty {
            return visibleText
        }

        let overlayActions = toolResult.toolCalls.filter {
            $0.name == "add_text_overlay" || $0.name == "move_text_overlay"
        }

        if overlayActions.isEmpty {
            return "Produced a publication-ready \(outputKind.rawValue) without a text overlay."
        }

        return "Produced a publication-ready \(outputKind.rawValue) with a single text overlay."
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

    private func logToolCalls(_ toolCalls: [LiteRTToolCall]) {
        guard !toolCalls.isEmpty else { return }
        Self.logger.notice("Executed \(toolCalls.count, privacy: .public) tool call(s)")
        for toolCall in toolCalls {
            Self.logger.notice("\(toolCall.logDescription, privacy: .public)")
        }
    }
}

enum ProductionPrompts {
    static func productionPrompt(backgroundBriefing: String, story: String, outputKind: ProductionWorkflowViewModel.OutputKind, assets: [ProductionAssetDescriptor], canvasSize: CGSize) -> String {
        let assetList = assets.map(\.promptSummary).joined(separator: "\n- ")
        let validSourceIDs = assets.map(\.toolID).joined(separator: ", ")
        return """
        You are preparing social-media content from the user's briefing, story text, and attached media.
        Background briefing:
        \(backgroundBriefing.isEmpty ? "(none provided)" : backgroundBriefing)

        Story:
        \(story.isEmpty ? "(none provided)" : story)

        Requested output:
        \(outputKind.rawValue)

        Available media assets:
        - \(assetList.isEmpty ? "(none selected)" : assetList)
        If images or video previews are attached, they appear in the same order as the asset list above.

        Output canvas:
        \(Int(canvasSize.width)) x \(Int(canvasSize.height)) pixels

        Valid source asset IDs:
        \(validSourceIDs.isEmpty ? "(none selected)" : validSourceIDs)

        Treat the background briefing as brand voice, audience, and editorial constraints, not as story facts.
        Ground every concrete claim in the story text or the attached media.
        Do not mention animals, people, events, needs, diagnoses, or calls to action unless they are supported by the story or visible media.
        If the story is sparse, obviously a test, or non-descriptive, keep the result correspondingly generic and testing-oriented instead of inventing subject matter.
        Match every overlay to what is visibly in frame. Do not write as if the media shows something it does not show.
        Use only those exact asset IDs in tool calls. Never use file paths, filenames, display names, UUIDs, or guessed IDs.
        First call compose_visuals with one or more source asset IDs.
        Then, only if the media clearly benefits from it, call add_text_overlay on the returned rendered asset ID.
        After you see a rendered overlay preview, you may either:
        - call move_text_overlay on that rendered asset ID to materially reposition or restyle the latest overlay without stacking another one, or
        - call accept_overlay_layout on that rendered asset ID when the current result is good as-is.
        Use as many overlays as needed when they clearly improve the result, but keep each overlay purposeful and compact.
        Keep overlay text short enough to read comfortably on mobile.
        If you call add_text_overlay more than once, always use the most recently returned rendered asset ID so overlays accumulate correctly.
        Prefer revising a weak first overlay with move_text_overlay instead of adding another overlay just to compensate.
        Use the style field simply:
        - sticker: the default Instagram-like rounded text card with a clear background; use this for almost all overlay text
        - tag: a smaller dark pill for short handles, labels, or secondary callouts
        - headline and caption are legacy aliases and render like sticker, so prefer sticker instead of those names
        - auto: only when you genuinely do not have a style preference
        Default to one overlay. Add a second overlay only when it is a genuine handle or location label and clearly improves the result.
        Prefer concrete wording grounded in what is visible, but do not anchor the overlay box itself to the main subject. Avoid filler text such as "nature", "wild beauty", "quiet moments", or "golden hour moment" unless the visible scene specifically supports it.
        Choose style from composition:
        - Prefer sticker for the main text almost always, including subject-dominant frames and open-scenery frames.
        - Use tag only for genuinely short labels such as a location, handle, or secondary marker.
        After compose_visuals, pay attention to the returned rendered preview. Base overlay placement on that rendered frame, not only on the original source asset, because the rendered canvas may crop or reframe the source media.
        Placement rule: the overlay should usually live in free space around the subject, not next to the subject's face, body, or main silhouette. Do not place the overlay near the subject just because the subject is the focus of the image.
        Prefer empty sky, water, pavement, wall area, or a clear frame edge over space that hugs the subject.
        If the subject is central or tall, prefer a lower band or an outer side band instead of a box that sits close to the subject.
        If the image is a close-up with a single central subject and limited negative space, strongly prefer one lower sticker band around 0.48 to 0.62 top_fraction instead of an upper sticker.
        Prefer the normalized overlay hints over raw pixel guesses:
        - Use top_fraction for vertical placement when you do not need an explicit slot. Good defaults are 0.18 to 0.35 for upper sticker placement and 0.45 to 0.60 for lower sticker placement.
        - Use max_width_fraction to express how wide the overlay may become after wrapping. Good defaults are roughly 0.38 to 0.68 depending on text length and style.
        - Use target_line_count so the renderer can measure width from the text itself. Good defaults are 1 or 2 for sticker, and 1 for tag.
        - Use horizontal_anchor to prefer left, center, or right placement without hard-coding a final box.
        - In normalized mode, do not also guess raw x, y, width, or height. Use one approach or the other.
        If you can see a clean free area in the rendered frame, you may instead describe a slot:
        - Provide x, y, width, and height as the available slot in the output canvas.
        - Then use horizontal_anchor and vertical_anchor to place the measured overlay inside that slot, often centered horizontally and bottom-aligned vertically.
        - In slot mode, do not assume the final overlay will fill the entire slot; the renderer will size it from the wrapped text.
        - Prefer slots that are clearly separated from the subject, not slots that merely touch or flank the subject tightly.
        Use x, y, width, and height only when you intentionally want to bound a slot. Otherwise prefer normalized hints.
        Overlay coordinates always resolve in the output canvas, not in the raw source image dimensions.
        Do not use full-canvas width for overlays.
        Keep overlays out of the top app-chrome band. Prefer the first sticker roughly 18% to 35% down from the top, or 45% to 60% down from the top when a lower placement is cleaner.
        If the rendered preview still looks too close to the subject, too boring, or too banner-like, revise it with move_text_overlay rather than defending a weak placement.
        Keep tool responses concise and produce a publication-ready result.
        """
    }

    static func postBodyPrompt(backgroundBriefing: String, story: String, producedVisualSummary: String) -> String {
        """
        Write the Instagram post body text grounded in the user's briefing, story text, attached media, and produced visual summary.
        Background briefing:
        \(backgroundBriefing.isEmpty ? "(none provided)" : backgroundBriefing)

        Story:
        \(story.isEmpty ? "(none provided)" : story)

        Visual output summary:
        \(producedVisualSummary.isEmpty ? "(none produced)" : producedVisualSummary)

        Treat the background briefing as style and constraints, not as factual post content.
        Use only facts supported by the story text, visible media, or visual output summary.
        If the story is sparse, obviously a test, or non-descriptive, keep the post body short and testing-oriented instead of inventing specific subject matter.
        Keep it publication-ready and concise.
        Prefer 1 to 3 short paragraphs or lines.
        Use at most 3 relevant hashtags, and only when they add value.
        Add a CTA only when the provided inputs clearly support one.
        """
    }
}

enum PostBodyToolSchema {
    static let toolName = "submit_post_body"
    static let fieldName = "post_body_text"

    static let toolsJSON = """
    [
      {
        "type": "function",
        "function": {
          "name": "\(toolName)",
          "description": "Submit the final publication-ready post body text for the social post.",
          "parameters": {
            "type": "object",
            "properties": {
              "\(fieldName)": {
                "type": "string",
                "description": "Only the final user-facing Instagram post body text that appears below the media. Do not include labels, explanations, markdown formatting, surrounding quotes, or code fences."
              }
            },
            "required": ["\(fieldName)"]
          }
        }
      }
    ]
    """

    static func extractPostBody(from parsed: LiteRTParsedMessage) -> String {
        if let toolCall = parsed.toolCalls.first(where: { $0.name == toolName }),
           let postBody = toolCall.arguments[fieldName]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !postBody.isEmpty {
            return postBody
        }
        return parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

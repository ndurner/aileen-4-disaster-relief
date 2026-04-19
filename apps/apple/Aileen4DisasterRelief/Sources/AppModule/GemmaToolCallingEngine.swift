import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

struct ToolExecutionResult {
    let toolCalls: [LiteRTToolCall]
    let toolResponsePayloads: [String]
    let finalText: String
    let producedURLs: [URL]
    let rawResponses: [String]
    let thoughtTraces: [String]
}

private struct OverlayReviewContext {
    let overlayText: String?
    let style: String?
    let x: Int?
    let y: Int?
    let width: Int?
    let height: Int?
}

enum OverlayPostReviewMode: String, Decodable {
    case none
    case resultOnly = "result_only"
    case resultOnlyWithSubjectBox = "result_only_with_subject_box"
    case resultOnlyForcedMove = "result_only_forced_move"
    case resultOnlyWithSubjectBoxForcedMove = "result_only_with_subject_box_forced_move"

    var includesSubjectBox: Bool {
        switch self {
        case .resultOnlyWithSubjectBox, .resultOnlyWithSubjectBoxForcedMove:
            return true
        default:
            return false
        }
    }

    var allowsAccept: Bool {
        switch self {
        case .resultOnlyForcedMove, .resultOnlyWithSubjectBoxForcedMove:
            return false
        default:
            return true
        }
    }
}

struct ProductionAssetDescriptor: Identifiable {
    let toolID: String
    let mediaAsset: MediaAsset

    var id: String { toolID }
    var promptSummary: String {
        "\(toolID): \(mediaAsset.kind.rawValue) source asset (\(mediaAsset.displayName), \(ProductionToolSchema.sourceDimensionsDescription(for: mediaAsset)))"
    }
}

actor GemmaToolCallingEngine {
    private let runner: GemmaTextRunner
    private static let thinkingExtraContextJSON = ProductionToolSchema.stringify(["enable_thinking": true])
    private static let maxToolRounds = 8

    init(runner: GemmaTextRunner = GemmaTextRunner()) {
        self.runner = runner
    }

    func run(
        initialPrompt: String,
        modelURL: URL,
        sourceAssets: [ProductionAssetDescriptor],
        outputKind: ProductionWorkflowViewModel.OutputKind,
        enableThinking: Bool = false,
        protectedRegionProvider: OverlayProtectedRegionProvider = .none,
        protectedRegionsOverride: OverlayProtectedRegions = .empty,
        layoutGuideOverride: OverlayLayoutGuide = .empty,
        postReviewMode: OverlayPostReviewMode = .none
    ) async throws -> ToolExecutionResult {
        let extraContextJSON = enableThinking ? Self.thinkingExtraContextJSON : nil
        try await runner.makeToolSession(
            modelURL: modelURL,
            toolsJSON: ProductionToolSchema.toolsJSON,
            systemMessageJSON: nil,
            extraContextJSON: extraContextJSON
        )
        do {
            let tooling = AppleMediaTooling(
                sourceAssets: sourceAssets,
                outputKind: outputKind,
                protectedRegionProvider: protectedRegionProvider,
                protectedRegionsOverride: protectedRegionsOverride,
                layoutGuideOverride: layoutGuideOverride
            )

            let initialMessage = try ProductionToolSchema.userMessageJSON(text: initialPrompt, assets: sourceAssets)
            var parsed = try await runner.sendJSON(initialMessage)
            var seenCalls: [LiteRTToolCall] = []
            var responsePayloads: [String] = []
            var latestProducedURL: URL?
            var toolRounds = 0
            var finalText = parsed.text
            var rawResponses: [String] = [parsed.rawJSON]
            var thoughtTraces: [String] = parsed.thoughtText.isEmpty ? [] : [parsed.thoughtText]

            while !parsed.toolCalls.isEmpty {
                toolRounds += 1
                if toolRounds > Self.maxToolRounds {
                    finalText = """
                    \(parsed.text.trimmingCharacters(in: .whitespacesAndNewlines))

                    Stopped after \(Self.maxToolRounds) tool rounds to avoid a non-progressing overlay loop.
                    """.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
                seenCalls.append(contentsOf: parsed.toolCalls)
                var responses: [MediaToolResult] = []
                for toolCall in parsed.toolCalls {
                    responses.append(try await tooling.execute(toolCall: toolCall))
                }
                responsePayloads.append(contentsOf: responses.map { ProductionToolSchema.stringify($0.payload) })
                latestProducedURL = responses.compactMap(\.outputURL).last ?? latestProducedURL
                let responseStatuses = responses.compactMap { $0.payload["status"] as? String }
                if !responseStatuses.isEmpty && responseStatuses.allSatisfy({ $0 == "skipped_duplicate" }) {
                    finalText = """
                    \(parsed.text.trimmingCharacters(in: .whitespacesAndNewlines))

                    Stopped after duplicate overlay calls produced no further visual changes.
                    """.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
                if let continuation = try await makeFreshContinuationMessage(
                    initialPrompt: initialPrompt,
                    responses: responses,
                    modelURL: modelURL,
                    extraContextJSON: extraContextJSON
                ) {
                    parsed = try await runner.sendJSON(continuation)
                } else {
                    let responseMessage = try ProductionToolSchema.toolResponseJSON(for: responses)
                    parsed = try await runner.sendJSON(responseMessage)
                }
                finalText = parsed.text
                rawResponses.append(parsed.rawJSON)
                if !parsed.thoughtText.isEmpty {
                    thoughtTraces.append(parsed.thoughtText)
                }
            }

            if postReviewMode != .none,
               let currentProducedURL = latestProducedURL,
               let currentAssetID = Self.latestRenderedAssetID(from: responsePayloads) {
                let reviewContext = Self.latestOverlayReviewContext(from: seenCalls, payloads: responsePayloads)
                let reviewResult = try await runFreshOverlayReview(
                    modelURL: modelURL,
                    renderedURL: currentProducedURL,
                    renderedAssetID: currentAssetID,
                    enableThinking: enableThinking,
                    tooling: tooling,
                    layoutGuideOverride: layoutGuideOverride,
                    reviewContext: reviewContext,
                    mode: postReviewMode
                )
                seenCalls.append(contentsOf: reviewResult.toolCalls)
                responsePayloads.append(contentsOf: reviewResult.toolResponsePayloads)
                latestProducedURL = reviewResult.latestProducedURL ?? latestProducedURL
                if !reviewResult.finalText.isEmpty {
                    finalText = reviewResult.finalText
                }
                rawResponses.append(contentsOf: reviewResult.rawResponses)
                thoughtTraces.append(contentsOf: reviewResult.thoughtTraces)
            }

            await runner.destroySession()
            return ToolExecutionResult(
                toolCalls: seenCalls,
                toolResponsePayloads: responsePayloads,
                finalText: finalText,
                producedURLs: latestProducedURL.map { [$0] } ?? [],
                rawResponses: rawResponses,
                thoughtTraces: thoughtTraces
            )
        } catch {
            await runner.destroySession()
            throw error
        }
    }

    private func runFreshOverlayReview(
        modelURL: URL,
        renderedURL: URL,
        renderedAssetID: String,
        enableThinking: Bool,
        tooling: AppleMediaTooling,
        layoutGuideOverride: OverlayLayoutGuide,
        reviewContext: OverlayReviewContext?,
        mode: OverlayPostReviewMode
    ) async throws -> (toolCalls: [LiteRTToolCall], toolResponsePayloads: [String], latestProducedURL: URL?, finalText: String, rawResponses: [String], thoughtTraces: [String]) {
        let extraContextJSON = enableThinking ? Self.thinkingExtraContextJSON : nil
        try await runner.makeToolSession(
            modelURL: modelURL,
            toolsJSON: ReviewToolSchema.toolsJSON(allowsAccept: mode.allowsAccept),
            systemMessageJSON: nil,
            extraContextJSON: extraContextJSON
        )
        let renderedAsset = ProductionAssetDescriptor(
            toolID: renderedAssetID,
            mediaAsset: MediaAsset(
                kind: .image,
                originalURL: renderedURL,
                localCopyURL: renderedURL,
                displayName: renderedURL.lastPathComponent
            )
        )
        let prompt = ReviewToolSchema.reviewPrompt(
            renderedAssetID: renderedAssetID,
            guide: layoutGuideOverride,
            reviewContext: reviewContext,
            mode: mode
        )
        var parsed = try await runner.sendJSON(
            ProductionToolSchema.userMessageJSON(text: prompt, assets: [renderedAsset])
        )
        var seenCalls: [LiteRTToolCall] = []
        var responsePayloads: [String] = []
        var latestProducedURL: URL?
        var finalText = parsed.text
        var toolRounds = 0
        let maxReviewToolRounds = mode.allowsAccept ? 2 : 1
        var rawResponses: [String] = [parsed.rawJSON]
        var thoughtTraces: [String] = parsed.thoughtText.isEmpty ? [] : [parsed.thoughtText]

        while !parsed.toolCalls.isEmpty {
            toolRounds += 1
            if toolRounds > maxReviewToolRounds {
                break
            }
            seenCalls.append(contentsOf: parsed.toolCalls)
            var responses: [MediaToolResult] = []
            for toolCall in parsed.toolCalls {
                responses.append(try await tooling.execute(toolCall: toolCall))
            }
            responsePayloads.append(contentsOf: responses.map { ProductionToolSchema.stringify($0.payload) })
            latestProducedURL = responses.compactMap(\.outputURL).last ?? latestProducedURL
            let responseMessage = try ProductionToolSchema.toolResponseJSON(for: responses)
            parsed = try await runner.sendJSON(responseMessage)
            finalText = parsed.text
            rawResponses.append(parsed.rawJSON)
            if !parsed.thoughtText.isEmpty {
                thoughtTraces.append(parsed.thoughtText)
            }
        }

        return (seenCalls, responsePayloads, latestProducedURL, finalText, rawResponses, thoughtTraces)
    }

    private func makeFreshContinuationMessage(
        initialPrompt: String,
        responses: [MediaToolResult],
        modelURL: URL,
        extraContextJSON: String?
    ) async throws -> String? {
        guard let latestRendered = responses.last(where: { $0.outputURL != nil }),
              let renderedURL = latestRendered.outputURL,
              let renderedAssetID = latestRendered.payload["asset_id"] as? String else {
            return nil
        }

        try await runner.makeToolSession(
            modelURL: modelURL,
            toolsJSON: ProductionToolSchema.toolsJSON,
            systemMessageJSON: nil,
            extraContextJSON: extraContextJSON
        )

        let renderedAsset = ProductionAssetDescriptor(
            toolID: renderedAssetID,
            mediaAsset: MediaAsset(
                kind: MediaAsset.kind(for: renderedURL),
                originalURL: renderedURL,
                localCopyURL: renderedURL,
                displayName: renderedURL.lastPathComponent
            )
        )

        let continuationPrompt = ProductionToolSchema.continuationPrompt(
            originalPrompt: initialPrompt,
            responses: responses,
            renderedAssetID: renderedAssetID
        )
        return try ProductionToolSchema.userMessageJSON(
            text: continuationPrompt,
            assets: [renderedAsset]
        )
    }

    private static func latestRenderedAssetID(from payloads: [String]) -> String? {
        payloads
            .compactMap { payload -> String? in
                guard let data = payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                return object["asset_id"] as? String
            }
            .last
    }

    private static func latestOverlayReviewContext(
        from toolCalls: [LiteRTToolCall],
        payloads: [String]
    ) -> OverlayReviewContext? {
        let latestToolCall = toolCalls.last { call in
            call.name == "add_text_overlay" || call.name == "move_text_overlay"
        }
        let latestPayload = payloads.reversed().compactMap { payload -> [String: Any]? in
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["overlay_width"] != nil || object["overlay_height"] != nil else {
                return nil
            }
            return object
        }.first
        guard latestToolCall != nil || latestPayload != nil else {
            return nil
        }
        return OverlayReviewContext(
            overlayText: latestToolCall?.arguments["overlay_text"]?.stringValue ?? latestToolCall?.arguments["overlay_text"]?.description,
            style: latestToolCall?.arguments["style"]?.stringValue ?? latestToolCall?.arguments["style"]?.description ?? (latestPayload?["style"] as? String),
            x: latestPayload?["x"] as? Int,
            y: latestPayload?["y"] as? Int,
            width: latestPayload?["overlay_width"] as? Int,
            height: latestPayload?["overlay_height"] as? Int
        )
    }
}

enum ProductionToolSchema {
    static let toolsJSON = """
    [
      {
        "type": "function",
        "function": {
          "name": "compose_visuals",
          "description": "Create the base visual from one or more exact source asset IDs such as asset_1. Use only the listed asset IDs, never file paths, filenames, or UUIDs. The app determines whether the result is a still image or a reel from its current output mode.",
          "parameters": {
            "type": "object",
            "properties": {
              "asset_ids": { "type": "array", "items": { "type": "string" } }
            },
            "required": ["asset_ids"]
          }
        }
      },
      {
        "type": "function",
        "function": {
          "name": "add_text_overlay",
          "description": "Draw a publication-ready text overlay on an existing rendered asset such as rendered_1. Prefer style sticker for almost all main overlay text and style tag only for short secondary labels. Legacy styles headline and caption are accepted but render like sticker. Place overlays in free space around the subject, not near the subject's face, body, or main silhouette. Prefer empty sky, water, pavement, wall area, or a clean frame edge over subject-hugging placement. For close-up central subjects with limited negative space, prefer one lower sticker band rather than an upper sticker. The renderer can size the overlay from normalized placement hints such as top_fraction, max_width_fraction, target_line_count, horizontal_anchor, and vertical_anchor. If you use normalized placement, do not also guess raw x, y, width, or height. If you provide x, y, width, and height together with anchors, the renderer treats that rectangle as an available slot in the rendered frame rather than as the exact final text box. The final size can vary because the renderer measures wrapped text. Use only exact returned asset IDs, and if you need another overlay, chain from the most recently returned rendered asset ID.",
          "parameters": {
            "type": "object",
            "properties": {
              "asset_id": { "type": "string" },
              "overlay_text": { "type": "string" },
              "style": {
                "type": "string",
                "enum": ["auto", "sticker", "headline", "caption", "tag"]
              },
              "top_fraction": { "type": "number" },
              "max_width_fraction": { "type": "number" },
              "target_line_count": { "type": "integer" },
              "horizontal_anchor": {
                "type": "string",
                "enum": ["left", "center", "right"]
              },
              "vertical_anchor": {
                "type": "string",
                "enum": ["top", "center", "bottom"]
              },
              "x": { "type": "integer" },
              "y": { "type": "integer" },
              "width": { "type": "integer" },
              "height": { "type": "integer" }
            },
            "required": ["asset_id", "overlay_text"]
          }
        }
      },
      {
        "type": "function",
        "function": {
          "name": "move_text_overlay",
          "description": "Replace the most recent overlay on an already rendered asset after inspecting the rendered preview. Use this when the current overlay is close but needs a material placement or style change. Prefer style sticker for almost all main overlay text and style tag only for short secondary labels. Legacy styles headline and caption are accepted but render like sticker. Move overlays away from the subject rather than closer to it. Prefer free space and frame edges over subject-hugging placement. For close-up central subjects with limited negative space, prefer one lower sticker band rather than an upper sticker. In normalized mode, do not also guess raw x, y, width, or height. This revises the latest overlay instead of stacking a second one. You may omit overlay_text or style to reuse the previous overlay content and style. Use normalized hints or a slot exactly as with add_text_overlay.",
          "parameters": {
            "type": "object",
            "properties": {
              "asset_id": { "type": "string" },
              "overlay_text": { "type": "string" },
              "style": {
                "type": "string",
                "enum": ["auto", "sticker", "headline", "caption", "tag"]
              },
              "top_fraction": { "type": "number" },
              "max_width_fraction": { "type": "number" },
              "target_line_count": { "type": "integer" },
              "horizontal_anchor": {
                "type": "string",
                "enum": ["left", "center", "right"]
              },
              "vertical_anchor": {
                "type": "string",
                "enum": ["top", "center", "bottom"]
              },
              "x": { "type": "integer" },
              "y": { "type": "integer" },
              "width": { "type": "integer" },
              "height": { "type": "integer" }
            },
            "required": ["asset_id"]
          }
        }
      },
      {
        "type": "function",
        "function": {
          "name": "accept_overlay_layout",
          "description": "Explicitly mark the current rendered asset as visually acceptable with no further overlay movement needed.",
          "parameters": {
            "type": "object",
            "properties": {
              "asset_id": { "type": "string" }
            },
            "required": ["asset_id"]
          }
        }
      }
    ]
    """

    static func userMessageJSON(text: String, assets: [ProductionAssetDescriptor] = []) throws -> String {
        var content = try mediaParts(for: assets)
        content.append(["type": "text", "text": text])

        let message: [String: Any] = [
            "role": "user",
            "content": content
        ]
        return stringify(message)
    }
    static func toolResponseJSON(for results: [MediaToolResult]) throws -> String {
        var content: [[String: Any]] = []
        for result in results {
            content.append([
                "type": "tool_response",
                "tool_name": result.name,
                "content": stringify(result.payload)
            ])
            content.append(contentsOf: try renderedMediaParts(for: result))
        }
        return stringify([
            "role": "user",
            "content": content
        ])
    }

    static func stringify(_ object: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func mediaParts(for assets: [ProductionAssetDescriptor]) throws -> [[String: Any]] {
        guard !assets.isEmpty else { return [] }

        var parts: [[String: Any]] = []
        for asset in assets {
            guard let promptBlob = try promptImageBlob(for: asset.mediaAsset) else { continue }
            parts.append([
                "type": "image",
                "blob": promptBlob
            ])
        }
        return parts
    }

    private static func promptImageBlob(for asset: MediaAsset) throws -> String? {
        switch asset.kind {
        case .image:
            guard let image = UIImage(contentsOfFile: asset.localCopyURL.path),
                  let normalizedData = image.pngData() else {
                return nil
            }
            return normalizedData.base64EncodedString()
        case .movie:
            guard let previewURL = try makeVideoPreviewImage(for: asset.localCopyURL),
                  let image = UIImage(contentsOfFile: previewURL.path),
                  let normalizedData = image.pngData() else {
                return nil
            }
            return normalizedData.base64EncodedString()
        }
    }

    private static func makeVideoPreviewImage(for sourceURL: URL) throws -> URL? {
        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AileenPromptMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")

        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, options)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return outputURL
    }

    static func sourceDimensionsDescription(for asset: MediaAsset) -> String {
        switch asset.kind {
        case .image:
            guard let imageSource = CGImageSourceCreateWithURL(asset.localCopyURL as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                return "source dimensions unavailable"
            }
            return "\(width)x\(height) px"
        case .movie:
            let videoAsset = AVURLAsset(url: asset.localCopyURL)
            guard let track = videoAsset.tracks(withMediaType: .video).first else {
                return "source dimensions unavailable"
            }
            let rect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
            return "\(Int(abs(rect.width).rounded()))x\(Int(abs(rect.height).rounded())) px"
        }
    }

    private static func renderedMediaParts(for result: MediaToolResult) throws -> [[String: Any]] {
        guard let outputURL = result.outputURL else { return [] }

        let renderedAsset = MediaAsset(
            kind: MediaAsset.kind(for: outputURL),
            originalURL: outputURL,
            localCopyURL: outputURL,
            displayName: outputURL.lastPathComponent
        )
        guard let promptBlob = try promptImageBlob(for: renderedAsset) else {
            return []
        }

        let assetID = result.payload["asset_id"] as? String ?? "rendered asset"
        let canvasWidth = result.payload["canvas_width"] as? Int
        let canvasHeight = result.payload["canvas_height"] as? Int
        let canvasDescription: String
        if let canvasWidth, let canvasHeight {
            canvasDescription = "\(canvasWidth)x\(canvasHeight) px canvas"
        } else {
            canvasDescription = sourceDimensionsDescription(for: renderedAsset)
        }

        return [
            [
                "type": "image",
                "blob": promptBlob
            ],
            [
                "type": "text",
                "text": "\nRendered result for \(assetID) (\(canvasDescription)). Base any follow-up overlay placement on this rendered frame, not only on the original source image."
            ]
        ]
    }

    static func continuationPrompt(
        originalPrompt: String,
        responses: [MediaToolResult],
        renderedAssetID: String
    ) -> String {
        let latestToolNames = responses.map(\.name)
        let responseSummary = responses.map { result in
            "- \(result.name): \(stringify(result.payload))"
        }.joined(separator: "\n")
        let nextStepInstruction: String
        if latestToolNames.contains("add_text_overlay") || latestToolNames.contains("move_text_overlay") {
            nextStepInstruction = """
            The attached frame already includes the latest overlay state.
            If the overlay still needs work, call move_text_overlay on asset_id \(renderedAssetID).
            Do not call add_text_overlay again unless you are intentionally starting a brand-new overlay from a clean frame.
            If the current rendered frame is already publishable, stop without another tool call or use accept_overlay_layout.
            """
        } else {
            nextStepInstruction = """
            The attached frame is a composed base render with no accepted overlay yet.
            If it would benefit from one overlay, call add_text_overlay on asset_id \(renderedAssetID) and include an explicit overlay_text string.
            Do not call add_text_overlay without overlay_text.
            Use move_text_overlay only after an overlay already exists on the current rendered frame.
            If the current rendered frame is already publishable without text, stop without another tool call.
            """
        }

        return """
        Continue the same content-production task from the latest rendered frame only.

        Original task:
        \(originalPrompt)

        Latest tool results:
        \(responseSummary)

        The attached image is the current rendered state for asset_id \(renderedAssetID).
        Base the next decision on this attached rendered frame.
        Do not repeat compose_visuals unless the composition itself is materially wrong.
        \(nextStepInstruction)
        """
    }
}

private enum ReviewToolSchema {
    private static let moveToolJSON = """
    [
      {
        "type": "function",
        "function": {
          "name": "move_text_overlay",
          "description": "Revise the current overlay on the rendered asset when the placement should materially change.",
          "parameters": {
            "type": "object",
            "properties": {
              "asset_id": { "type": "string" },
              "overlay_text": { "type": "string" },
              "style": {
                "type": "string",
                "enum": ["auto", "sticker", "headline", "caption", "tag"]
              },
              "top_fraction": { "type": "number" },
              "max_width_fraction": { "type": "number" },
              "target_line_count": { "type": "integer" },
              "horizontal_anchor": {
                "type": "string",
                "enum": ["left", "center", "right"]
              },
              "vertical_anchor": {
                "type": "string",
                "enum": ["top", "center", "bottom"]
              },
              "x": { "type": "integer" },
              "y": { "type": "integer" },
              "width": { "type": "integer" },
              "height": { "type": "integer" }
            },
            "required": ["asset_id"]
          }
        }
      }
    ]
    """

    private static let acceptToolJSON = """
    [
      {
        "type": "function",
        "function": {
          "name": "accept_overlay_layout",
          "description": "Accept the current rendered overlay layout with no further changes.",
          "parameters": {
            "type": "object",
            "properties": {
              "asset_id": { "type": "string" }
            },
            "required": ["asset_id"]
          }
        }
      }
    ]
    """

    static func toolsJSON(allowsAccept: Bool) -> String {
        guard allowsAccept else { return moveToolJSON }
        return """
        [
          {
            "type": "function",
            "function": {
              "name": "move_text_overlay",
              "description": "Revise the current overlay on the rendered asset when the placement should materially change.",
              "parameters": {
                "type": "object",
                "properties": {
                  "asset_id": { "type": "string" },
                  "overlay_text": { "type": "string" },
                  "style": {
                    "type": "string",
                    "enum": ["auto", "sticker", "headline", "caption", "tag"]
                  },
                  "top_fraction": { "type": "number" },
                  "max_width_fraction": { "type": "number" },
                  "target_line_count": { "type": "integer" },
                  "horizontal_anchor": {
                    "type": "string",
                    "enum": ["left", "center", "right"]
                  },
                  "vertical_anchor": {
                    "type": "string",
                    "enum": ["top", "center", "bottom"]
                  },
                  "x": { "type": "integer" },
                  "y": { "type": "integer" },
                  "width": { "type": "integer" },
                  "height": { "type": "integer" }
                },
                "required": ["asset_id"]
              }
            }
          },
          {
            "type": "function",
            "function": {
              "name": "accept_overlay_layout",
              "description": "Accept the current rendered overlay layout with no further changes.",
              "parameters": {
                "type": "object",
                "properties": {
                  "asset_id": { "type": "string" }
                },
                "required": ["asset_id"]
              }
            }
          }
        ]
        """
    }

    static func reviewPrompt(
        renderedAssetID: String,
        guide: OverlayLayoutGuide,
        reviewContext: OverlayReviewContext?,
        mode: OverlayPostReviewMode
    ) -> String {
        var lines = [
            "The attached image already has one text label drawn onto it.",
            "Your job is to judge that drawn label, not to imagine a new blank image.",
            "Look only at the single attached image and decide whether the current drawn label should stay where it is or be moved.",
            "Do not defend the earlier choice just because it already exists.",
            "Treat a label that sits on the subject's face, head, body, or upper silhouette as a strong reason to move it.",
            "If the text box overlaps the subject or competes with the main subject, move it.",
            "Move means replace the current text label with a better placement on the same image.",
            "Prefer a surprising but plausible modern placement over a boring banner, but do not rationalize obviously bad overlap.",
            "Use asset_id \(renderedAssetID)."
        ]
        if mode.allowsAccept {
            lines.insert("Use exactly one tool call before you stop:", at: 4)
            lines.insert("- call accept_overlay_layout only if the current drawn text label is already in a good place and should remain exactly where it is", at: 5)
            lines.insert("- call move_text_overlay if the current drawn text label should shift position, change size band, or change style", at: 6)
            lines.insert("Accept means leave the current text label exactly where it is with no change.", at: 9)
        } else {
            lines.insert("You have only one tool: move_text_overlay.", at: 4)
            lines.insert("Use move_text_overlay only if you can make a clear improvement.", at: 5)
            lines.insert("If the current label is already acceptable or you cannot improve it, do not call any tool.", at: 6)
            lines.insert("No tool call means keep the current text label exactly where it is.", at: 9)
        }
        if let reviewContext {
            var overlayLine = "Current drawn text label"
            if let overlayText = reviewContext.overlayText, !overlayText.isEmpty {
                overlayLine += ": \"\(overlayText)\""
            }
            if let style = reviewContext.style, !style.isEmpty {
                overlayLine += " with style \(style)"
            }
            overlayLine += "."
            lines.append(overlayLine)
            if let x = reviewContext.x,
               let y = reviewContext.y,
               let width = reviewContext.width,
               let height = reviewContext.height {
                lines.append("Current label box in the 1080x1350 image: left=\(x), top=\(y), width=\(width), height=\(height).")
            }
        }
        if mode.includesSubjectBox, let subjectRect = guide.subjectRect {
            lines.append("Keep-clear subject box: x=\(Int(subjectRect.minX.rounded())), y=\(Int(subjectRect.minY.rounded())), width=\(Int(subjectRect.width.rounded())), height=\(Int(subjectRect.height.rounded())).")
        }
        return lines.joined(separator: "\n")
    }
}

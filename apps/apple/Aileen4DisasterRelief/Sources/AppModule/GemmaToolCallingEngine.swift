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
        systemMessageJSON: String,
        enableThinking: Bool = false,
        samplerSeed: Int32? = nil,
        protectedRegionProvider: OverlayProtectedRegionProvider = .none,
        protectedRegionsOverride: OverlayProtectedRegions = .empty,
        layoutGuideOverride: OverlayLayoutGuide = .empty,
        postReviewMode: OverlayPostReviewMode = .none
    ) async throws -> ToolExecutionResult {
        let extraContextJSON = enableThinking ? Self.thinkingExtraContextJSON : nil
        try await runner.makeToolSession(
            modelURL: modelURL,
            toolsJSON: ProductionToolSchema.toolsJSON,
            systemMessageJSON: systemMessageJSON,
            extraContextJSON: extraContextJSON,
            samplerSeed: samplerSeed
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
                if responses.contains(where: { $0.name == "accept_overlay_layout" }) {
                    break
                }
                let responseMessage = try ProductionToolSchema.toolResponseJSON(for: responses)
                parsed = try await runner.sendJSON(responseMessage)
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
                    samplerSeed: samplerSeed,
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
        samplerSeed: Int32?,
        tooling: AppleMediaTooling,
        layoutGuideOverride: OverlayLayoutGuide,
        reviewContext: OverlayReviewContext?,
        mode: OverlayPostReviewMode
    ) async throws -> (toolCalls: [LiteRTToolCall], toolResponsePayloads: [String], latestProducedURL: URL?, finalText: String, rawResponses: [String], thoughtTraces: [String]) {
        let extraContextJSON = enableThinking ? Self.thinkingExtraContextJSON : nil
        try await runner.makeToolSession(
            modelURL: modelURL,
            toolsJSON: ReviewToolSchema.toolsJSON(allowsAccept: mode.allowsAccept),
            systemMessageJSON: ReviewToolSchema.systemMessageJSON(allowsAccept: mode.allowsAccept),
            extraContextJSON: extraContextJSON,
            samplerSeed: samplerSeed
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
            if let continuation = try makeReviewContinuationMessage(responses: responses) {
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

        return (seenCalls, responsePayloads, latestProducedURL, finalText, rawResponses, thoughtTraces)
    }

    private func makeReviewContinuationMessage(
        responses: [MediaToolResult]
    ) throws -> String? {
        guard let latestRendered = responses.last(where: { $0.outputURL != nil }),
              let renderedURL = latestRendered.outputURL,
              let renderedAssetID = latestRendered.payload["asset_id"] as? String else {
            return nil
        }

        let renderedAsset = ProductionAssetDescriptor(
            toolID: renderedAssetID,
            mediaAsset: MediaAsset(
                kind: MediaAsset.kind(for: renderedURL),
                originalURL: renderedURL,
                localCopyURL: renderedURL,
                displayName: renderedURL.lastPathComponent
            )
        )

        let prompt = """
        Continue the same rendered-overlay review from this updated frame.
        The attached image is the current rendered state for asset_id \(renderedAssetID).
        Judge the actual pixels in this attached image.
        If the current label is now publishable, stop without another tool call or use accept_overlay_layout if available.
        If the label still clearly needs a material placement or style improvement, call move_text_overlay on asset_id \(renderedAssetID).
        """

        return try ProductionToolSchema.toolResponseAndUserMessageJSON(
            for: responses,
            text: prompt,
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
          "description": "Create a base visual from multiple exact source asset IDs when assets must be combined before overlaying. Do not use this as a routine first step for a single source asset; add_text_overlay can render the source asset onto the output canvas itself. Use only listed asset IDs, never file paths, filenames, or UUIDs.",
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
          "description": "Draw a publication-ready text overlay on a source asset such as asset_1 or on an existing rendered asset such as rendered_1. asset_id must be exactly one listed ID, for example asset_1 or rendered_2; never include commas, overlay_text, or any other argument inside asset_id. For a single source asset, call this directly on that source asset; the app renders the source onto the output canvas before drawing text. Prefer style sticker for almost all main overlay text and style tag only for short secondary labels. Legacy styles headline and caption are accepted but render like sticker. Place overlays in free space around the subject, not directly across the subject's face, body, hands, animal body, tool interaction, or main silhouette. Actively look for empty space before choosing a default band: check top sky, side margins, corners, open ground, water, wall, and plain background. Prefer open space over subject-obscuring placement. Do not treat the bottom as automatically safe: if an animal, hands, tools, or the main action sits near the lower edge, choose upper, side, or corner space instead. Upper placements are allowed when they feel modern and do not visibly cover the face or central action, but compare them against lower, side, and corner options first. The renderer can size the overlay from normalized placement hints such as top_fraction, max_width_fraction, target_line_count, horizontal_anchor, and vertical_anchor. Prefer exact x, y, width, and height when choosing side or corner open space. If you provide x, y, width, and height, the renderer treats that rectangle as an available slot in the rendered frame. Do not mix exact coordinates with top_fraction or anchors. For sticker text longer than five words, prefer target_line_count 2 or 3 rather than 1. The final size can vary because the renderer measures wrapped text. Use exact source or returned asset IDs, and if you need another overlay, chain from the most recently returned rendered asset ID.",
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
          "description": "Replace the most recent overlay on an already rendered asset after inspecting the rendered preview. asset_id must be exactly one returned rendered asset ID, for example rendered_2; never include commas, overlay_text, or any other argument inside asset_id. Use this when the current overlay is close but needs a material placement or style change. Prefer style sticker for almost all main overlay text and style tag only for short secondary labels. Legacy styles headline and caption are accepted but render like sticker. Move overlays away from direct subject obstruction rather than closer to it. Prefer free space and frame edges over subject-obscuring placement. Bottom is not automatically safe; move away from the bottom when the lower area contains an animal, hands, tools, or the main action. Upper placements are allowed when they feel modern and do not visibly cover the face or central action. Prefer exact x, y, width, and height when moving into side or corner open space. Do not mix exact coordinates with top_fraction or anchors. For sticker text longer than five words, prefer target_line_count 2 or 3 rather than 1. This revises the latest overlay instead of stacking a second one. You may omit overlay_text or style to reuse the previous overlay content and style. Use normalized hints or a slot exactly as with add_text_overlay.",
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
          "description": "Explicitly mark the current rendered asset as visually acceptable with no further overlay movement needed. asset_id must be exactly one returned rendered asset ID, for example rendered_2; never include commas or other arguments inside asset_id.",
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
        stringify(try userMessageObject(text: text, assets: assets))
    }

    private static func userMessageObject(text: String, assets: [ProductionAssetDescriptor] = []) throws -> [String: Any] {
        var content = try mediaParts(for: assets)
        content.append(["type": "text", "text": text])

        return [
            "role": "user",
            "content": content
        ]
    }

    static func systemTextJSON(_ text: String) -> String {
        stringify([
            [
                "type": "text",
                "text": text
            ]
        ])
    }

    static func toolResponseJSON(for results: [MediaToolResult]) throws -> String {
        stringify(toolResponseMessageObject(for: results))
    }

    static func toolResponseAndUserMessageJSON(
        for results: [MediaToolResult],
        text: String,
        assets: [ProductionAssetDescriptor]
    ) throws -> String {
        stringify([
            toolResponseMessageObject(for: results),
            try userMessageObject(text: text, assets: assets)
        ])
    }

    private static func toolResponseMessageObject(for results: [MediaToolResult]) -> [String: Any] {
        var content: [[String: Any]] = []
        for result in results {
            content.append([
                "type": "tool_response",
                "name": result.name,
                "response": result.payload
            ])
        }
        return [
            "role": "tool",
            "content": content
        ]
    }

    static func stringify(_ object: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func mediaParts(for assets: [ProductionAssetDescriptor]) throws -> [[String: Any]] {
        guard !assets.isEmpty else { return [] }

        var parts: [[String: Any]] = []
        for asset in assets {
            guard let promptURL = try PromptMediaEncoder.promptImageFileURL(for: asset.mediaAsset) else { continue }
            parts.append([
                "type": "image",
                "path": promptURL.path
            ])
        }
        return parts
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

    static func systemMessageJSON(allowsAccept: Bool) -> String {
        let instruction = allowsAccept
            ? """
            You are reviewing a rendered social-media image that already has one drawn text label.
            Judge the actual pixels in the attached image, not the prior reasoning.
            Prior user text, prior model text, and prior tool choices are context only and must not justify a weak placement.
            Use move_text_overlay only when you can clearly improve placement or style.
            Use accept_overlay_layout only when the current drawn label is already publishable as-is.
            """
            : """
            You are reviewing a rendered social-media image that already has one drawn text label.
            Judge the actual pixels in the attached image, not the prior reasoning.
            Prior user text, prior model text, and prior tool choices are context only and must not justify a weak placement.
            Use move_text_overlay only when you can clearly improve placement or style.
            If you cannot clearly improve the current drawn label, do not call any tool.
            """
        return ProductionToolSchema.systemTextJSON(instruction)
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
            "Treat a label that sits directly across the subject's face, body, hands, animal body, tool interaction, or main silhouette as a strong reason to move it.",
            "Faces are blocked, including side-profile faces and faces partly cropped by the image edge.",
            "Moving away from one subject is not enough if the new label covers another subject.",
            "Upper placements can be acceptable only when they do not touch any face or central action.",
            "If a face or profile appears in the upper rows, do not use an upper-center band.",
            "For animal-care scenes with a person on one side and an animal low in frame, prefer compact open middle background between them.",
            "Bottom placements can be acceptable only when the lower area is open; do not cover an animal, hands, tools, or lower action.",
            "A large centered band can still be a bad choice if clear side or corner space is available.",
            "If the text box clearly obscures the subject or competes with the main story evidence, move it.",
            "Move means replace the current text label with a better placement on the same image.",
            "Prefer a surprising but plausible modern placement over a boring banner, but do not rationalize obvious face, body, hand, animal, tool, or evidence overlap.",
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

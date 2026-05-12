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

struct OverlayReviewContext {
    let overlayText: String?
    let style: String?
    let x: Int?
    let y: Int?
    let width: Int?
    let height: Int?
    let sourceAssetID: String?
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
               latestProducedURL != nil,
               let currentAssetID = Self.latestRenderedAssetID(from: responsePayloads) {
                let reviewContext = Self.latestOverlayReviewContext(from: seenCalls, payloads: responsePayloads)
                let reviewResult = try await runFreshOverlayReview(
                    modelURL: modelURL,
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
        let reviewAssets = try tooling.makeOverlayReviewAssets(
            renderedAssetID: renderedAssetID,
            reviewContext: reviewContext
        )
        let prompt = ReviewToolSchema.reviewPrompt(
            renderedAssetID: renderedAssetID,
            guide: layoutGuideOverride,
            reviewContext: reviewContext,
            mode: mode
        )
        var parsed = try await runner.sendJSON(
            ProductionToolSchema.userMessageJSON(text: prompt, assets: reviewAssets)
        )
        var seenCalls: [LiteRTToolCall] = []
        var responsePayloads: [String] = []
        var latestProducedURL: URL?
        var finalText = parsed.text
        var toolRounds = 0
        let maxReviewToolRounds = 2
        var rawResponses: [String] = [parsed.rawJSON]
        var thoughtTraces: [String] = parsed.thoughtText.isEmpty ? [] : [parsed.thoughtText]

        while !parsed.toolCalls.isEmpty {
            toolRounds += 1
            seenCalls.append(contentsOf: parsed.toolCalls)
            var responses: [MediaToolResult] = []
            for toolCall in parsed.toolCalls {
                responses.append(try await tooling.execute(toolCall: toolCall))
            }
            responsePayloads.append(contentsOf: responses.map { ProductionToolSchema.stringify($0.payload) })
            latestProducedURL = responses.compactMap(\.outputURL).last ?? latestProducedURL
            let shouldRetryRejectedMove = responses.contains { result in
                guard let status = result.payload["status"] as? String else { return false }
                return ["invalid_partial_rect", "invalid_rect_bounds", "invalid_upper_retry", "invalid_upper_move"].contains(status)
            }
            if !shouldRetryRejectedMove || toolRounds >= maxReviewToolRounds {
                break
            }
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
        let statuses = responses.compactMap { $0.payload["status"] as? String }
        if statuses.contains("invalid_partial_rect") {
            let renderedAssetID = responses.compactMap { $0.payload["asset_id"] as? String }.last ?? "the same rendered asset"
            let prompt = """
            Your previous move was rejected because it gave only some coordinates.
            Call move_text_overlay again on asset_id \(renderedAssetID) with all four integers: x, y, width, height.
            Do not use top_fraction or anchors in this retry.
            Do not move toward hands, tools, plants, guards, animals, paperwork, or the main action. Choose plain open background, side margin, sky, or open ground instead.
            """
            return try ProductionToolSchema.toolResponseAndUserMessageJSON(
                for: responses,
                text: prompt,
                assets: []
            )
        }
        if statuses.contains("invalid_rect_bounds") {
            let renderedAssetID = responses.compactMap { $0.payload["asset_id"] as? String }.last ?? "the same rendered asset"
            let canvasWidth = responses.compactMap { $0.payload["canvas_width"] as? Int }.last ?? 1080
            let canvasHeight = responses.compactMap { $0.payload["canvas_height"] as? Int }.last ?? 1350
            let prompt = """
            Your previous move was rejected because its rectangle was outside the image or too small for readable text.
            Call move_text_overlay again on asset_id \(renderedAssetID) with x, y, width, height fully inside the \(canvasWidth)x\(canvasHeight) canvas.
            width and height mean the sticker slot size, not the image size. Use a compact slot, usually width 240-560 and height 120-320.
            Leave at least 40 px of margin from every image edge; do not put the rectangle flush against the border.
            If the rejected location was otherwise clear, keep the same x and y and enlarge the slot just enough; do not jump to another part of the image.
            Do not move toward hands, tools, plants, guards, animals, paperwork, or the main action. Choose plain open background, side margin, sky, or open ground instead.
            """
            return try ProductionToolSchema.toolResponseAndUserMessageJSON(
                for: responses,
                text: prompt,
                assets: []
            )
        }
        if statuses.contains("invalid_upper_retry") || statuses.contains("invalid_upper_move") {
            let renderedAssetID = responses.compactMap { $0.payload["asset_id"] as? String }.last ?? "the same rendered asset"
            let prompt = """
            Your previous move was rejected because it used a wide upper banner.
            Call move_text_overlay again on asset_id \(renderedAssetID) with all four integers: x, y, width, height.
            Use a compact side/corner slot or open middle rows instead.
            Do not move toward hands, tools, plants, guards, animals, paperwork, or the main action. Choose plain open background, side margin, sky, or open ground instead.
            """
            return try ProductionToolSchema.toolResponseAndUserMessageJSON(
                for: responses,
                text: prompt,
                assets: []
            )
        }

        return nil
    }

    static func latestRenderedAssetID(from payloads: [String]) -> String? {
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

    static func latestOverlayReviewContext(
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
            height: latestPayload?["overlay_height"] as? Int,
            sourceAssetID: latestPayload?["source_asset_id"] as? String
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
          "description": "Draw a publication-ready text overlay on a source asset such as asset_1 or on an existing rendered asset such as rendered_1. asset_id must be exactly one listed ID, for example asset_1 or rendered_2; never include commas, overlay_text, or any other argument inside asset_id. For a single source asset, call this directly on that source asset; the app renders the source onto the output canvas before drawing text. Prefer style sticker for almost all main overlay text and style tag only for short secondary labels. Legacy styles headline and caption are accepted but render like sticker. Place overlays in free space around the subject, not directly across the subject's face, head, hair, shoulder, torso, body, hands, animal body, tool interaction, story evidence, or main silhouette. Story evidence includes plant guards, enclosures, water bowls, crates, shelters, signs, damaged structures, supply setups, sunset bands, horizons, skylines, smoke, floodwater, storm clouds, fire glow, and damage that explain the scene. Actively look for empty space before choosing a default band: check top sky, side margins, corners, open ground, water, wall, and plain background. Prefer open space over subject-obscuring placement. Do not treat a dark shirt, hair, shoulder, story evidence, or plain-looking body area as empty space. Do not treat the bottom as automatically safe: if an animal, hands, tools, story evidence, or the main action sits near the lower edge, choose upper, side, or corner space instead. For sunset, storm, smoke, or horizon scenes, use quiet sky around the dramatic band, not the red/orange/yellow/cloud band itself; if normalized hints drift into that band, use exact coordinates. Upper placements are allowed when they feel modern and do not visibly cover the face, head, hair, shoulder, torso, story evidence, or central action, but compare them against lower, side, and corner options first. The renderer can size the overlay from normalized placement hints such as top_fraction, max_width_fraction, target_line_count, horizontal_anchor, and vertical_anchor. Prefer exact x, y, width, and height when choosing side or corner open space. If you provide x, y, width, and height, the renderer treats that rectangle as an available slot in the rendered frame. Do not mix exact coordinates with top_fraction or anchors. If you include any one of x, y, width, or height, include all four; otherwise omit all four. For sticker text longer than five words, prefer target_line_count 2 or 3 rather than 1; if the clean slot would make four lines, shorten overlay_text. The final size can vary because the renderer measures wrapped text. Use exact source or returned asset IDs, and if you need another overlay, chain from the most recently returned rendered asset ID.",
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
              "x": { "type": "integer", "description": "Left edge of the open placement slot in pixels." },
              "y": { "type": "integer", "description": "Top edge of the open placement slot in pixels." },
              "width": { "type": "integer", "description": "Width of the sticker slot in pixels, not the full image width." },
              "height": { "type": "integer", "description": "Height of the sticker slot in pixels, not the full image height." }
            },
            "required": ["asset_id", "overlay_text"]
          }
        }
      },
      {
        "type": "function",
        "function": {
          "name": "move_text_overlay",
          "description": "Replace the most recent overlay on an already rendered asset after inspecting the rendered preview. asset_id must be exactly one returned rendered asset ID, for example rendered_2; never include commas, overlay_text, or any other argument inside asset_id. Use this when the current overlay is close but needs a material placement or style change. Prefer style sticker for almost all main overlay text and style tag only for short secondary labels. Legacy styles headline and caption are accepted but render like sticker. Move overlays away from direct subject obstruction rather than closer to it. Prefer free space and frame edges over subject-obscuring placement. The sticker background counts as overlay area. Do not place it across face, head, hair, shoulder, torso, body, hands, animal body, tool interaction, story evidence, or main silhouette. Story evidence includes plant guards, enclosures, water bowls, crates, shelters, signs, damaged structures, supply setups, sunset bands, horizons, skylines, smoke, floodwater, storm clouds, fire glow, and damage that explain the scene. Do not treat dark clothing, hair, shoulders, story evidence, or plain-looking body areas as empty space. Bottom is not automatically safe; move away from the bottom when the lower area contains an animal, hands, tools, story evidence, or the main action. For sunset, storm, smoke, or horizon scenes, use quiet sky around the dramatic band, not the red/orange/yellow/cloud band itself; if normalized hints drift into that band, use exact coordinates. Upper placements are allowed when they feel modern and do not visibly cover the face, head, hair, shoulder, torso, story evidence, or central action. In correction review, choose your own exact open rectangle. Prefer exact x, y, width, and height when moving into open space. Do not mix exact coordinates with top_fraction or anchors. If you include any one of x, y, width, or height, include all four; otherwise omit all four. For sticker text longer than five words, prefer target_line_count 2 or 3 rather than 1; if the clean slot would make four lines, shorten overlay_text. This revises the latest overlay instead of stacking a second one. You may omit overlay_text or style to reuse the previous overlay content and style. Use normalized hints or a slot exactly as with add_text_overlay.",
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
              "x": { "type": "integer", "description": "Left edge of the open placement slot in pixels." },
              "y": { "type": "integer", "description": "Top edge of the open placement slot in pixels." },
              "width": { "type": "integer", "description": "Width of the sticker slot in pixels, not the full image width." },
              "height": { "type": "integer", "description": "Height of the sticker slot in pixels, not the full image height." }
            },
            "required": ["asset_id"]
          }
        }
      },
      {
        "type": "function",
        "function": {
          "name": "accept_overlay_layout",
          "description": "Explicitly mark the current rendered asset as visually acceptable with no further overlay movement needed. Use this only when the rendered label is excellent as-is, not merely tolerable or familiar from the previous step. If this is a close call or a clearer open-space placement exists, use move_text_overlay instead. asset_id must be exactly one returned rendered asset ID, for example rendered_2; never include commas or other arguments inside asset_id.",
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

enum ReviewToolSchema {
    private static let moveToolJSON = """
    [
      {
        "type": "function",
        "function": {
          "name": "move_text_overlay",
          "description": "Revise the current overlay on the rendered asset when the placement should materially change. Choose one open sticker slot. x and y are the slot's top-left corner. width and height are the sticker slot size, not the image size.",
          "parameters": {
            "type": "object",
            "properties": {
              "asset_id": { "type": "string" },
              "overlay_text": { "type": "string" },
              "style": {
                "type": "string",
                "enum": ["auto", "sticker", "headline", "caption", "tag"]
              },
              "target_line_count": { "type": "integer" },
              "x": { "type": "integer", "description": "Left edge of the open slot in pixels. Use 0 to 1079." },
              "y": { "type": "integer", "description": "Top edge of the open slot in pixels. Use 0 to 1349." },
              "width": { "type": "integer", "description": "Open sticker slot width in pixels. Usually 240 to 560; never the full image width." },
              "height": { "type": "integer", "description": "Open sticker slot height in pixels. Usually 120 to 320; never the full image height." }
            },
            "required": ["asset_id", "x", "y", "width", "height"]
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
          "description": "Accept the current rendered overlay layout with no further changes. Use this only when the label is excellent as-is, not merely tolerable. If this is a close call or a clearer open-space placement exists, use move_text_overlay instead.",
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
              "description": "Revise the current overlay on the rendered asset when the placement should materially change. Choose one open sticker slot. x and y are the slot's top-left corner. width and height are the sticker slot size, not the image size.",
              "parameters": {
                "type": "object",
                "properties": {
                  "asset_id": { "type": "string" },
                  "overlay_text": { "type": "string" },
                  "style": {
                    "type": "string",
                    "enum": ["auto", "sticker", "headline", "caption", "tag"]
                  },
                  "target_line_count": { "type": "integer" },
                  "x": { "type": "integer", "description": "Left edge of the open slot in pixels. Use 0 to 1079." },
                  "y": { "type": "integer", "description": "Top edge of the open slot in pixels. Use 0 to 1349." },
                  "width": { "type": "integer", "description": "Open sticker slot width in pixels. Usually 240 to 560; never the full image width." },
                  "height": { "type": "integer", "description": "Open sticker slot height in pixels. Usually 120 to 320; never the full image height." }
                },
                "required": ["asset_id", "x", "y", "width", "height"]
              }
            }
          },
          {
            "type": "function",
            "function": {
              "name": "accept_overlay_layout",
              "description": "Accept the current rendered overlay layout with no further changes. Use this only when the label is excellent as-is, not merely tolerable. If this is a close call or a clearer open-space placement exists, use move_text_overlay instead.",
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
        ProductionToolSchema.systemTextJSON(systemInstruction(allowsAccept: allowsAccept))
    }

    static func systemInstruction(allowsAccept: Bool) -> String {
        allowsAccept
            ? """
            You are reviewing a social-media overlay using a clean image guide.
            Judge the red sticker box in the attached guide, not the prior reasoning.
            Prior user text, prior model text, and prior tool choices are context only and must not justify a weak placement.
            Determine whether the red box is production-ready.
            Use accept_overlay_layout only when it is excellent as-is.
            Use move_text_overlay for close calls, subject overlap, or obvious unused open space.
            """
            : """
            You are reviewing a social-media overlay using a clean image guide.
            Judge the red sticker box in the attached guide, not the prior reasoning.
            Prior user text, prior model text, and prior tool choices are context only and must not justify a weak placement.
            Determine whether the red box is production-ready.
            You must call move_text_overlay exactly once.
            If the current placement is excellent, call move_text_overlay with the same current rectangle.
            For close calls, subject overlap, or obvious unused open space, choose a better open rectangle.
            """
    }

    static func reviewPrompt(
        renderedAssetID: String,
        guide: OverlayLayoutGuide,
        reviewContext: OverlayReviewContext?,
        mode: OverlayPostReviewMode
    ) -> String {
        var lines = [
            "The attachment is a clean review guide for the current overlay.",
            "The red rounded rectangle is the current full sticker box. Judge that whole red box, not only the letters.",
            "Yellow grid lines and edge labels show pixel coordinates in the 1080x1350 canvas. x grows left to right; y grows top to bottom.",
            "Determine protected areas first: face/profile, head, hair, shoulder, torso, hands, animals, tools, plant guards, enclosures, paperwork, skyline, sunset band, smoke, floodwater, storm clouds, fire, damage, and main action.",
            "Determine whether the red box overlaps, touches, crowds, or competes with any protected area.",
            "Close call means move. Accept only if this is production-ready for handoff.",
            "A safe current side/corner sticker in real open background is excellent. Keep it; do not move it for aesthetics alone.",
            "Move only if the current red box is unsafe, crowded, or clearly weaker than unused open space.",
            "If moving, call move_text_overlay with all four integers: x, y, width, height.",
            "width and height mean sticker slot size, not image size. A compact sticker slot is usually 240-560 wide and 120-320 tall.",
            "Leave at least 40 px of margin from every image edge; never put the sticker flush against a border.",
            "To keep a good current red box that is slightly smaller than the slot guidance, reuse the same x and y and round width up to at least 240 and height up to at least 120.",
            "If the clean slot would make the old text a tall four-line block, shorten overlay_text to 2-4 plain words.",
            "Prefer compact modern side, corner, or middle placements in real open background. Avoid default top or bottom banners.",
            "For a top-row slot near a person, beside the head is safer than above the head.",
            "Do not let the rectangle share the head/hair x-range unless its bottom edge is clearly above all hair with visible empty space between.",
            "If you are unsure where the head/hair ends, use the opposite open side instead.",
            "If a person or animal occupies one side, use the opposite open side instead of that same side's corner.",
            "A corner is open only when the corner is visibly empty. If a person, hair, shoulder, plant guard, or story object fills that side, that corner is blocked.",
            "For animal-care scenes with a person on one side and an animal low in frame, avoid lower corners and lower-center. Prefer open upper/middle background, wall, mesh, or grass away from animal, paperwork, and hands.",
            "For planting, rescue, or care scenes, do not move toward the hands, tools, plants, guard, animal, paperwork, or action. Move away from them into plain open space.",
            "For scenic sunset or horizon scenes, keep the whole rectangle out of the red/orange/yellow band and skyline. Use quiet blue/gray dark sky near the top or side; red/orange/yellow cloud color under the rectangle means move higher. In most sunset frames, choose y around 70-180 and avoid y >= 250. y + height must stay above the bright band.",
            "Use asset_id \(renderedAssetID)."
        ]
        if mode.allowsAccept {
            lines.insert("Use exactly one tool call before you stop:", at: 4)
            lines.insert("- call accept_overlay_layout only if the current drawn text label is excellent and should remain exactly where it is", at: 5)
            lines.insert("- call move_text_overlay if the current drawn text label should shift position, change size band, or change style", at: 6)
            lines.insert("Accept means production-ready with no change; it does not mean merely acceptable.", at: 9)
        } else {
            lines.insert("You have only one tool: move_text_overlay.", at: 4)
            lines.insert("Call move_text_overlay exactly once.", at: 5)
            lines.insert("If the current red box is excellent, keep it by using the same current rectangle.", at: 6)
            lines.insert("If it is not excellent, choose a better open rectangle.", at: 7)
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
            lines.append("Protected keep-clear box: x=\(Int(subjectRect.minX.rounded())), y=\(Int(subjectRect.minY.rounded())), width=\(Int(subjectRect.width.rounded())), height=\(Int(subjectRect.height.rounded())).")
        }
        return lines.joined(separator: "\n")
    }
}

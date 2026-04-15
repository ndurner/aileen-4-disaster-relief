import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

struct ToolExecutionResult {
    let toolCalls: [LiteRTToolCall]
    let finalText: String
    let producedURLs: [URL]
}

struct ProductionAssetDescriptor: Identifiable {
    let toolID: String
    let mediaAsset: MediaAsset

    var id: String { toolID }
    var promptSummary: String { "\(toolID): \(mediaAsset.kind.rawValue) source asset (\(mediaAsset.displayName))" }
}

actor GemmaToolCallingEngine {
    private let runner = GemmaTextRunner()

    func run(initialPrompt: String, modelURL: URL, sourceAssets: [ProductionAssetDescriptor], outputKind: ProductionWorkflowViewModel.OutputKind) async throws -> ToolExecutionResult {
        try await runner.makeToolSession(modelURL: modelURL, toolsJSON: ProductionToolSchema.toolsJSON)
        defer { Task { await runner.destroySession() } }
        let tooling = AppleMediaTooling(sourceAssets: sourceAssets, outputKind: outputKind)

        let initialMessage = try ProductionToolSchema.userMessageJSON(text: initialPrompt, assets: sourceAssets)
        var parsed = try await runner.sendJSON(initialMessage)
        var seenCalls: [LiteRTToolCall] = []
        var latestProducedURL: URL?

        while !parsed.toolCalls.isEmpty {
            seenCalls.append(contentsOf: parsed.toolCalls)
            var responses: [MediaToolResult] = []
            for toolCall in parsed.toolCalls {
                responses.append(try await tooling.execute(toolCall: toolCall))
            }
            latestProducedURL = responses.compactMap(\.outputURL).last ?? latestProducedURL
            let responseMessage = try ProductionToolSchema.toolResponseJSON(for: responses)
            parsed = try await runner.sendJSON(responseMessage)
        }

        return ToolExecutionResult(
            toolCalls: seenCalls,
            finalText: parsed.text,
            producedURLs: latestProducedURL.map { [$0] } ?? []
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
          "description": "Draw a text box with background rectangle on an existing rendered asset such as rendered_1. Keep overlay text compact and publication-ready. Use only exact returned asset IDs, and if you need another overlay, chain from the most recently returned rendered asset ID.",
          "parameters": {
            "type": "object",
            "properties": {
              "asset_id": { "type": "string" },
              "overlay_text": { "type": "string" },
              "x": { "type": "integer" },
              "y": { "type": "integer" },
              "width": { "type": "integer" },
              "height": { "type": "integer" }
            },
            "required": ["asset_id", "overlay_text", "x", "y", "width", "height"]
          }
        }
      }
    ]
    """

    static func userMessageJSON(text: String, assets: [ProductionAssetDescriptor] = []) throws -> String {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        content.append(contentsOf: try mediaParts(for: assets))

        let message: [String: Any] = [
            "role": "user",
            "content": content
        ]
        return stringify(message)
    }

    static func toolResponseJSON(for results: [MediaToolResult]) throws -> String {
        let content: [[String: Any]] = results.map { result in
            [
                "type": "tool_response",
                "tool_name": result.name,
                "content": stringify(result.payload)
            ]
        }
        return stringify([
            "role": "user",
            "content": content
        ])
    }

    private static func stringify(_ object: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func mediaParts(for assets: [ProductionAssetDescriptor]) throws -> [[String: Any]] {
        guard !assets.isEmpty else { return [] }

        var parts: [[String: Any]] = []
        for asset in assets {
            guard let promptBlob = try promptImageBlob(for: asset.mediaAsset) else { continue }
            parts.append([
                "type": "text",
                "text": "\nAsset \(asset.toolID) is the following \(asset.mediaAsset.kind.rawValue):"
            ])
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
}

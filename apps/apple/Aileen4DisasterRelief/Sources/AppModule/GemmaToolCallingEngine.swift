import Foundation

struct ToolExecutionResult {
    let toolCalls: [LiteRTToolCall]
    let finalText: String
    let producedURLs: [URL]
}

struct ProductionAssetDescriptor: Identifiable {
    let toolID: String
    let mediaAsset: MediaAsset

    var id: String { toolID }
    var promptSummary: String { "\(toolID): \(mediaAsset.kind.rawValue) source asset" }
}

actor GemmaToolCallingEngine {
    private let runner = GemmaTextRunner()

    func run(initialPrompt: String, modelURL: URL, sourceAssets: [ProductionAssetDescriptor], outputKind: ProductionWorkflowViewModel.OutputKind) async throws -> ToolExecutionResult {
        try await runner.makeToolSession(modelURL: modelURL, toolsJSON: ProductionToolSchema.toolsJSON)
        defer { Task { await runner.destroySession() } }
        let tooling = AppleMediaTooling(sourceAssets: sourceAssets, outputKind: outputKind)

        let initialMessage = ProductionToolSchema.userMessageJSON(text: initialPrompt)
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
          "description": "Draw a text box with background rectangle on an existing rendered asset such as rendered_1. Use only exact returned asset IDs.",
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

    static func userMessageJSON(text: String) -> String {
        let message: [String: Any] = [
            "role": "user",
            "content": [["type": "text", "text": text]]
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
}

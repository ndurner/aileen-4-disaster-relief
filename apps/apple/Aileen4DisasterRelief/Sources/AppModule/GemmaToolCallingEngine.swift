import Foundation

struct ToolExecutionResult {
    let toolCalls: [LiteRTToolCall]
    let finalText: String
    let producedURLs: [URL]
}

actor GemmaToolCallingEngine {
    private let runner = GemmaTextRunner()

    func run(initialPrompt: String, modelURL: URL, ffmpegExecutablePath: String) async throws -> ToolExecutionResult {
        try await runner.makeToolSession(modelURL: modelURL, toolsJSON: ProductionToolSchema.toolsJSON)
        defer { Task { await runner.destroySession() } }

        let initialMessage = ProductionToolSchema.userMessageJSON(text: initialPrompt)
        var parsed = try await runner.sendJSON(initialMessage)
        var seenCalls: [LiteRTToolCall] = []
        var producedURLs: [URL] = []

        while !parsed.toolCalls.isEmpty {
            seenCalls.append(contentsOf: parsed.toolCalls)
            let responses = try parsed.toolCalls.map { try execute(toolCall: $0, ffmpegExecutablePath: ffmpegExecutablePath) }
            producedURLs.append(contentsOf: responses.compactMap(\.outputURL))
            let responseMessage = try ProductionToolSchema.toolResponseJSON(for: responses)
            parsed = try await runner.sendJSON(responseMessage)
        }

        return ToolExecutionResult(toolCalls: seenCalls, finalText: parsed.text, producedURLs: producedURLs)
    }

    private func execute(toolCall: LiteRTToolCall, ffmpegExecutablePath: String) throws -> FFmpegToolResult {
        try FFmpegTooling().execute(toolCall: toolCall, ffmpegExecutablePath: ffmpegExecutablePath)
    }
}

enum ProductionToolSchema {
    static let toolsJSON = """
    [
      {
        "type": "function",
        "function": {
          "name": "compose_visuals",
          "description": "Create a still image montage or a reel from local media assets.",
          "parameters": {
            "type": "object",
            "properties": {
              "mode": { "type": "string", "enum": ["image", "reel"] },
              "asset_paths": { "type": "array", "items": { "type": "string" } },
              "overlay_text": { "type": "string" }
            },
            "required": ["mode", "asset_paths"]
          }
        }
      },
      {
        "type": "function",
        "function": {
          "name": "add_overlay_rectangles",
          "description": "Draw text boxes or emphasis rectangles on an existing visual.",
          "parameters": {
            "type": "object",
            "properties": {
              "input_path": { "type": "string" },
              "overlay_text": { "type": "string" },
              "x": { "type": "integer" },
              "y": { "type": "integer" },
              "width": { "type": "integer" },
              "height": { "type": "integer" }
            },
            "required": ["input_path", "overlay_text"]
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

    static func toolResponseJSON(for results: [FFmpegToolResult]) throws -> String {
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

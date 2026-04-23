import Foundation

enum GoogleAIStudioResponseParser {
    static func parseContent(_ content: [String: Any], rawResponseJSON: String) -> LiteRTParsedMessage {
        LiteRTParsedMessage(
            text: visibleText(from: content),
            toolCalls: functionCalls(from: content),
            thoughtText: thoughtText(from: content),
            rawJSON: rawResponseJSON
        )
    }

    static func toolArguments(from rawArguments: Any?) -> [String: LiteRTToolValue] {
        if let dictionary = rawArguments as? [String: Any] {
            return dictionary.compactMapValues(LiteRTToolValue.init(jsonValue:))
        }

        if let jsonString = rawArguments as? String,
           let data = jsonString.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object.compactMapValues(LiteRTToolValue.init(jsonValue:))
        }

        return [:]
    }

    private static func visibleText(from content: [String: Any]) -> String {
        parts(from: content).compactMap { part in
            guard part["thought"] as? Bool != true,
                  let text = part["text"] as? String else {
                return nil
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.joined()
    }

    private static func thoughtText(from content: [String: Any]) -> String {
        parts(from: content).compactMap { part in
            guard part["thought"] as? Bool == true,
                  let text = part["text"] as? String else {
                return nil
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.joined(separator: "\n")
    }

    private static func functionCalls(from content: [String: Any]) -> [LiteRTToolCall] {
        parts(from: content).compactMap { part in
            guard let functionCall = part["functionCall"] as? [String: Any],
                  let name = functionCall["name"] as? String else {
                return nil
            }

            return LiteRTToolCall(
                name: name,
                arguments: toolArguments(from: functionCall["args"] ?? functionCall["arguments"]),
                toolCallID: functionCall["id"] as? String
            )
        }
    }

    private static func parts(from content: [String: Any]) -> [[String: Any]] {
        content["parts"] as? [[String: Any]] ?? []
    }
}

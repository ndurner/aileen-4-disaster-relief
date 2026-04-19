import Foundation

enum LiteRTToolValue: Hashable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([LiteRTToolValue])

    init?(jsonValue: Any) {
        switch jsonValue {
        case let string as String:
            self = .string(
                string.replacingOccurrences(of: "<|\"|>", with: "\"")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            )
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let array as [Any]:
            let values = array.compactMap(LiteRTToolValue.init(jsonValue:))
            self = .array(values)
        default:
            return nil
        }
    }

    var description: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        case .array(let values):
            return "[" + values.map(\.description).joined(separator: ", ") + "]"
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var stringArrayValue: [String]? {
        if case .array(let values) = self {
            return values.compactMap(\.stringValue)
        }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

struct LiteRTToolCall: Identifiable {
    let id = UUID()
    let name: String
    let arguments: [String: LiteRTToolValue]

    var logDescription: String {
        let formattedArguments = arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.description)" }
            .joined(separator: ", ")

        if formattedArguments.isEmpty {
            return "Tool call: \(name)"
        }

        return "Tool call: \(name) (\(formattedArguments))"
    }
}

struct LiteRTParsedMessage {
    let text: String
    let toolCalls: [LiteRTToolCall]
    let thoughtText: String
    let rawJSON: String
}

enum LiteRTResponseParser {
    static func parse(_ raw: String) -> LiteRTParsedMessage {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return LiteRTParsedMessage(text: raw, toolCalls: [], thoughtText: extractThoughtText(fromRaw: raw), rawJSON: raw)
        }

        return LiteRTParsedMessage(
            text: extractText(from: dictionary),
            toolCalls: extractToolCalls(from: dictionary),
            thoughtText: extractThoughtText(from: dictionary, raw: raw),
            rawJSON: raw
        )
    }

    static func sanitizeAssistantHistoryObject(_ object: Any) -> Any {
        guard var message = object as? [String: Any] else {
            return object
        }

        if let channels = message["channels"] as? [String: Any] {
            let sanitizedChannels = channels.filter { $0.key != "thought" }
            if sanitizedChannels.isEmpty {
                message.removeValue(forKey: "channels")
            } else {
                message["channels"] = sanitizedChannels
            }
        }

        if let content = message["content"] as? String {
            message["content"] = sanitizeVisibleText(content)
        } else if let content = message["content"] as? [[String: Any]] {
            message["content"] = content.compactMap(sanitizeAssistantHistoryContentItem)
        }

        if let text = message["text"] as? String {
            let sanitizedText = sanitizeVisibleText(text)
            if sanitizedText.isEmpty {
                message.removeValue(forKey: "text")
            } else {
                message["text"] = sanitizedText
            }
        }

        if let channel = message["channel"] as? String, channel == "thought" {
            message.removeValue(forKey: "channel")
        }

        return message
    }

    private static func extractText(from message: [String: Any]) -> String {
        guard let content = message["content"] else { return "" }
        if let text = content as? String {
            return sanitizeVisibleText(text)
        }
        guard let array = content as? [[String: Any]] else { return "" }
        return array.compactMap { item in
            guard item["type"] as? String == "text" else { return nil }
            if item["channel"] as? String == "thought" {
                return nil
            }
            guard let text = item["text"] as? String else { return nil }
            let sanitized = sanitizeVisibleText(text)
            return sanitized.isEmpty ? nil : sanitized
        }.joined()
    }

    private static func extractToolCalls(from message: [String: Any]) -> [LiteRTToolCall] {
        guard let toolCalls = message["tool_calls"] as? [[String: Any]] else {
            return []
        }

        return toolCalls.compactMap { entry in
            guard let function = entry["function"] as? [String: Any],
                  let name = function["name"] as? String else {
                return nil
            }
            let arguments = (function["arguments"] as? [String: Any] ?? [:]).compactMapValues(LiteRTToolValue.init(jsonValue:))
            return LiteRTToolCall(name: name, arguments: arguments)
        }
    }

    private static func extractThoughtText(from message: [String: Any], raw: String) -> String {
        if let channels = message["channels"] as? [String: Any],
           let thought = channels["thought"] as? String {
            let trimmed = thought.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let content = message["content"] as? [[String: Any]] {
            let thought = content.compactMap { item -> String? in
                if item["type"] as? String == "thought" {
                    return item["text"] as? String
                }
                if item["channel"] as? String == "thought" {
                    return item["text"] as? String
                }
                return nil
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !thought.isEmpty {
                return thought
            }
        }
        if let channel = message["channel"] as? String,
           channel == "thought",
           let text = message["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return extractThoughtText(fromRaw: raw)
    }

    private static func extractThoughtText(fromRaw raw: String) -> String {
        let pattern = #"<\|channel\>thought\s*(.*?)<channel\|>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return ""
        }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: raw) else {
            return ""
        }
        return raw[captureRange].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizeVisibleText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("<|channel>thought") else {
            return ""
        }
        return trimmed
    }

    private static func sanitizeAssistantHistoryContentItem(_ item: [String: Any]) -> [String: Any]? {
        if item["type"] as? String == "thought" || item["channel"] as? String == "thought" {
            return nil
        }

        var sanitizedItem = item
        if let text = item["text"] as? String {
            let sanitizedText = sanitizeVisibleText(text)
            guard !sanitizedText.isEmpty else {
                return nil
            }
            sanitizedItem["text"] = sanitizedText
        }
        return sanitizedItem
    }
}

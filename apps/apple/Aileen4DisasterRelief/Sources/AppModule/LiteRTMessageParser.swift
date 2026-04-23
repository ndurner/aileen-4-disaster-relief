import Foundation

enum LiteRTMessageParser {
    private static let textualQuotedTokens = ["<|\"|>", #"<|\"|>"#]

    static func parse(_ raw: String) -> LiteRTParsedMessage {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return LiteRTParsedMessage(text: raw, toolCalls: [], thoughtText: extractThoughtText(fromRaw: raw), rawJSON: raw)
        }

        return LiteRTParsedMessage(
            text: extractText(from: dictionary),
            toolCalls: extractToolCalls(from: dictionary, raw: raw),
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

    static func normalizedQuotedTokenString(_ raw: String) -> String {
        textualQuotedTokens
            .reduce(raw) { partialResult, token in
                partialResult.replacingOccurrences(of: token, with: "\"")
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func extractText(from message: [String: Any]) -> String {
        if let content = message["content"] as? String {
            return sanitizeVisibleText(content)
        }

        guard let items = message["content"] as? [[String: Any]] else {
            return ""
        }

        return items.compactMap { item in
            if item["channel"] as? String == "thought" {
                return nil
            }
            guard let text = item["text"] as? String else { return nil }
            let sanitized = sanitizeVisibleText(text)
            return sanitized.isEmpty ? nil : sanitized
        }.joined()
    }

    private static func extractToolCalls(from message: [String: Any], raw: String) -> [LiteRTToolCall] {
        if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
            return toolCalls.compactMap { entry in
                guard let function = entry["function"] as? [String: Any],
                      let name = function["name"] as? String else {
                    return nil
                }
                let arguments = toolArguments(from: function["arguments"])
                return LiteRTToolCall(name: name, arguments: arguments, toolCallID: entry["id"] as? String)
            }
        }

        let textualCandidates = textualToolCallCandidates(from: message) + [raw]
        for candidate in textualCandidates {
            let parsed = extractTextualToolCalls(from: candidate)
            if !parsed.isEmpty {
                return parsed
            }
        }

        return []
    }

    private static func textualToolCallCandidates(from message: [String: Any]) -> [String] {
        var candidates: [String] = []

        if let content = message["content"] as? String {
            candidates.append(content)
        }
        for item in assistantParts(from: message) {
            if let text = item["text"] as? String {
                candidates.append(text)
            }
        }
        if let text = message["text"] as? String {
            candidates.append(text)
        }

        return candidates
    }

    private static func extractTextualToolCalls(from text: String) -> [LiteRTToolCall] {
        let pattern = #"<\|tool_call\>call:([a-zA-Z_][a-zA-Z0-9_]*)\{(.*?)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else {
            return []
        }

        return matches.compactMap { match in
            guard match.numberOfRanges == 3,
                  let nameRange = Range(match.range(at: 1), in: text),
                  let argumentsRange = Range(match.range(at: 2), in: text) else {
                return nil
            }

            let name = String(text[nameRange])
            guard let arguments = parseTextualToolArguments(String(text[argumentsRange])) else {
                return nil
            }
            return LiteRTToolCall(name: name, arguments: arguments)
        }
    }

    private static func parseTextualToolArguments(_ raw: String) -> [String: LiteRTToolValue]? {
        var arguments: [String: LiteRTToolValue] = [:]
        for chunk in splitTopLevelArgumentPairs(raw) {
            guard let separatorIndex = topLevelColonIndex(in: chunk) else {
                return nil
            }
            let key = chunk[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = chunk[chunk.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty,
                  let parsedValue = parseTextualToolValue(String(value)) else {
                return nil
            }
            arguments[String(key)] = parsedValue
        }
        return arguments
    }

    private static func splitTopLevelArgumentPairs(_ raw: String) -> [String] {
        var result: [String] = []
        var current = ""
        var bracketDepth = 0
        var insideQuotedToken = false
        var index = raw.startIndex

        while index < raw.endIndex {
            if let token = matchingQuotedToken(in: raw, at: index) {
                insideQuotedToken.toggle()
                current += token
                index = raw.index(index, offsetBy: token.count)
                continue
            }

            let character = raw[index]
            if !insideQuotedToken {
                if character == "[" {
                    bracketDepth += 1
                } else if character == "]", bracketDepth > 0 {
                    bracketDepth -= 1
                } else if character == ",", bracketDepth == 0 {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        result.append(trimmed)
                    }
                    current = ""
                    index = raw.index(after: index)
                    continue
                }
            }

            current.append(character)
            index = raw.index(after: index)
        }

        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result.append(trimmed)
        }

        return result
    }

    private static func topLevelColonIndex(in raw: String) -> String.Index? {
        var bracketDepth = 0
        var insideQuotedToken = false
        var index = raw.startIndex

        while index < raw.endIndex {
            if let token = matchingQuotedToken(in: raw, at: index) {
                insideQuotedToken.toggle()
                index = raw.index(index, offsetBy: token.count)
                continue
            }

            let character = raw[index]
            if !insideQuotedToken {
                if character == "[" {
                    bracketDepth += 1
                } else if character == "]", bracketDepth > 0 {
                    bracketDepth -= 1
                } else if character == ":", bracketDepth == 0 {
                    return index
                }
            }

            index = raw.index(after: index)
        }

        return nil
    }

    private static func parseTextualToolValue(_ raw: String) -> LiteRTToolValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let token = textualQuotedTokens.first(where: { trimmed.hasPrefix($0) }) {
            guard trimmed.hasSuffix(token) else {
                return nil
            }
            let start = trimmed.index(trimmed.startIndex, offsetBy: token.count)
            let end = trimmed.index(trimmed.endIndex, offsetBy: -token.count)
            return .string(normalizedQuotedTokenString(String(trimmed[start..<end])))
        }

        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            let inner = String(trimmed.dropFirst().dropLast())
            let values = splitTopLevelArgumentPairs(inner).compactMap(parseTextualToolValue)
            return .array(values)
        }

        if trimmed == "true" {
            return .bool(true)
        }
        if trimmed == "false" {
            return .bool(false)
        }
        if let number = Double(trimmed) {
            return .number(number)
        }

        return .string(normalizedQuotedTokenString(trimmed))
    }

    private static func matchingQuotedToken(in raw: String, at index: String.Index) -> String? {
        textualQuotedTokens.first { raw[index...].hasPrefix($0) }
    }

    private static func stripTextualToolCallPrefix(_ text: String) -> String {
        guard let range = text.range(of: "<|tool_call>call:") else {
            return text
        }
        let remainder = text[range.lowerBound..<text.endIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.hasPrefix("<|tool_call>call:") {
            return ""
        }
        return text
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
        return stripTextualToolCallPrefix(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func assistantParts(from message: [String: Any]) -> [[String: Any]] {
        if let contentItems = message["content"] as? [[String: Any]] {
            return contentItems
        }
        return []
    }
}

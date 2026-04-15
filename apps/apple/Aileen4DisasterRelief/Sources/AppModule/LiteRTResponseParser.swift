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
}

struct LiteRTToolCall: Identifiable {
    let id = UUID()
    let name: String
    let arguments: [String: LiteRTToolValue]
}

struct LiteRTParsedMessage {
    let text: String
    let toolCalls: [LiteRTToolCall]
}

enum LiteRTResponseParser {
    static func parse(_ raw: String) -> LiteRTParsedMessage {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return LiteRTParsedMessage(text: raw, toolCalls: [])
        }

        return LiteRTParsedMessage(
            text: extractText(from: dictionary),
            toolCalls: extractToolCalls(from: dictionary)
        )
    }

    private static func extractText(from message: [String: Any]) -> String {
        guard let content = message["content"] else { return "" }
        if let text = content as? String {
            return text
        }
        guard let array = content as? [[String: Any]] else { return "" }
        return array.compactMap { item in
            guard item["type"] as? String == "text" else { return nil }
            return item["text"] as? String
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
}

import Foundation

enum LiteRTToolValue: Hashable, CustomStringConvertible, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([LiteRTToolValue])

    init?(jsonValue: Any) {
        switch jsonValue {
        case let string as String:
            self = .string(
                LiteRTMessageParser.normalizedQuotedTokenString(string)
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

struct LiteRTToolCall: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let arguments: [String: LiteRTToolValue]
    let toolCallID: String?

    init(name: String, arguments: [String: LiteRTToolValue], toolCallID: String? = nil) {
        self.name = name
        self.arguments = arguments
        self.toolCallID = toolCallID
    }

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

struct LiteRTParsedMessage: Sendable {
    let text: String
    let toolCalls: [LiteRTToolCall]
    let thoughtText: String
    let rawJSON: String
}

enum LiteRTResponseParser {
    static func parse(_ raw: String) -> LiteRTParsedMessage {
        LiteRTMessageParser.parse(raw)
    }

    static func sanitizeAssistantHistoryObject(_ object: Any) -> Any {
        LiteRTMessageParser.sanitizeAssistantHistoryObject(object)
    }

    static func toolArguments(from rawArguments: Any?) -> [String: LiteRTToolValue] {
        LiteRTMessageParser.toolArguments(from: rawArguments)
    }
}

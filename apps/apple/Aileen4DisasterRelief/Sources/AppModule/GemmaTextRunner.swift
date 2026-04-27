import Foundation

enum GemmaTextRunnerError: LocalizedError {
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .runtime(let message):
            return message
        }
    }
}

actor GemmaTextRunner {
    private var activeSession: OpaquePointer?
    private var activeModelPath: String?
    private var configuredToolsJSON: String?
    private var configuredSystemMessageJSON: String?
    private var configuredExtraContextJSON: String?
    private var conversationHistory: [Any] = []

    func makeSession(modelURL: URL) throws {
        try configureSession(
            modelURL: modelURL,
            toolsJSON: nil,
            systemMessageJSON: nil,
            extraContextJSON: nil
        )
    }

    func makeToolSession(
        modelURL: URL,
        toolsJSON: String,
        systemMessageJSON: String? = nil,
        extraContextJSON: String? = nil
    ) throws {
        try configureSession(
            modelURL: modelURL,
            toolsJSON: toolsJSON,
            systemMessageJSON: systemMessageJSON,
            extraContextJSON: extraContextJSON
        )
    }

    func sendJSON(_ messageJSON: String) throws -> LiteRTParsedMessage {
        return LiteRTResponseParser.parse(try sendRawJSON(messageJSON))
    }

    func sendRawJSON(_ messageJSON: String) throws -> String {
        try sendRawJSON(messageJSON, allowRecovery: true)
    }

    private func sendRawJSON(_ messageJSON: String, allowRecovery: Bool) throws -> String {
        let outgoingMessage = try parsedHistoryMessage(from: messageJSON)

        guard let activeSession else {
            throw GemmaTextRunnerError.runtime("LiteRT-LM session is not initialized.")
        }
        var responsePointer: UnsafePointer<CChar>?
        var errorPointer: UnsafePointer<CChar>?

        let result = messageJSON.withCString { messageCString in
            gemma_bridge_session_send_json(activeSession, messageCString, &responsePointer, &errorPointer)
        }

        if result != 0 {
            let message = errorPointer.map { String(cString: $0) } ?? "LiteRT-LM failed to send JSON."
            if allowRecovery,
               message.localizedCaseInsensitiveContains("failed to send message"),
               let activeModelPath {
                let modelURL = URL(fileURLWithPath: activeModelPath)
                let toolsJSON = configuredToolsJSON
                let systemMessageJSON = configuredSystemMessageJSON
                let extraContextJSON = configuredExtraContextJSON
                let historySnapshot = self.conversationHistory
                destroyBridgeSession()
                try configureSession(
                    modelURL: modelURL,
                    toolsJSON: toolsJSON,
                    systemMessageJSON: systemMessageJSON,
                    extraContextJSON: extraContextJSON,
                    seedHistory: historySnapshot
                )
                return try sendRawJSON(messageJSON, allowRecovery: false)
            }
            throw GemmaTextRunnerError.runtime(message)
        }

        let response = responsePointer.map { String(cString: $0) } ?? ""
        let incomingMessage = try sanitizedAssistantHistoryMessage(from: response)
        appendHistoryEntry(outgoingMessage)
        appendHistoryEntry(incomingMessage)
        return response
    }

    func destroySession() {
        destroyBridgeSession()
        activeModelPath = nil
        configuredToolsJSON = nil
        configuredSystemMessageJSON = nil
        configuredExtraContextJSON = nil
        conversationHistory = []
    }

    private func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
        guard let value else {
            return try body(nil)
        }
        return try value.withCString(body)
    }

    private func configureSession(
        modelURL: URL,
        toolsJSON: String?,
        systemMessageJSON: String?,
        extraContextJSON: String?,
        seedHistory: [Any] = []
    ) throws {
        let modelPath = modelURL.path

        if activeSession != nil, activeModelPath != modelPath {
            destroySession()
        }

        try modelPath.withCString { modelCString in
            try withOptionalCString(toolsJSON) { toolsCString in
                try withOptionalCString(systemMessageJSON) { systemCString in
                    if let activeSession {
                        try recreateConversation(
                            activeSession: activeSession,
                            systemCString: systemCString,
                            toolsCString: toolsCString,
                            history: seedHistory
                        )
                    } else {
                        var errorPointer: UnsafePointer<CChar>?
                        let session: OpaquePointer?
                        if systemCString == nil, toolsCString == nil {
                            session = gemma_bridge_session_create(modelCString, &errorPointer)
                        } else if systemCString == nil {
                            session = gemma_bridge_session_create_with_tools(modelCString, toolsCString, &errorPointer)
                        } else {
                            session = gemma_bridge_session_create_with_system_and_tools(modelCString, systemCString, toolsCString, &errorPointer)
                        }
                        guard let session else {
                            let message = errorPointer.map { String(cString: $0) } ?? "Failed to create LiteRT-LM session."
                            throw GemmaTextRunnerError.runtime(message)
                        }
                        activeSession = session
                        activeModelPath = modelPath
                        if !seedHistory.isEmpty {
                            try recreateConversation(
                                activeSession: session,
                                systemCString: systemCString,
                                toolsCString: toolsCString,
                                history: seedHistory
                            )
                        }
                    }

                    withOptionalCString(extraContextJSON) { extraContextCString in
                        gemma_bridge_session_set_extra_context(activeSession, extraContextCString)
                    }
                    activeModelPath = modelPath
                    configuredToolsJSON = toolsJSON
                    configuredSystemMessageJSON = systemMessageJSON
                    configuredExtraContextJSON = extraContextJSON
                    conversationHistory = seedHistory
                }
            }
        }
    }

    private func parsedHistoryMessage(from messageJSON: String) throws -> Any {
        guard let data = messageJSON.data(using: .utf8) else {
            throw GemmaTextRunnerError.runtime("Failed to encode LiteRT-LM message JSON.")
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw GemmaTextRunnerError.runtime("Failed to parse LiteRT-LM message JSON for history replay: \(error.localizedDescription)")
        }
    }

    private func sanitizedAssistantHistoryMessage(from messageJSON: String) throws -> Any {
        let object = try parsedHistoryMessage(from: messageJSON)
        return LiteRTResponseParser.sanitizeAssistantHistoryObject(object)
    }

    private func appendHistoryEntry(_ entry: Any) {
        if let messages = entry as? [Any] {
            conversationHistory.append(contentsOf: messages)
        } else {
            conversationHistory.append(entry)
        }
    }

    private func serializedHistoryJSON(_ history: [Any]) throws -> String? {
        guard !history.isEmpty else {
            return nil
        }
        guard JSONSerialization.isValidJSONObject(history) else {
            throw GemmaTextRunnerError.runtime("LiteRT-LM history replay could not serialize conversation history.")
        }
        let data = try JSONSerialization.data(withJSONObject: history)
        guard let json = String(data: data, encoding: .utf8) else {
            throw GemmaTextRunnerError.runtime("LiteRT-LM history replay produced invalid UTF-8.")
        }
        return json
    }

    private func recreateConversation(
        activeSession: OpaquePointer,
        systemCString: UnsafePointer<CChar>?,
        toolsCString: UnsafePointer<CChar>?,
        history: [Any]
    ) throws {
        let historyJSON = try serializedHistoryJSON(history)
        try withOptionalCString(historyJSON) { historyCString in
            try recreateConversation(
                activeSession: activeSession,
                systemCString: systemCString,
                toolsCString: toolsCString,
                historyCString: historyCString
            )
        }
    }

    private func recreateConversation(
        activeSession: OpaquePointer,
        systemCString: UnsafePointer<CChar>?,
        toolsCString: UnsafePointer<CChar>?,
        historyCString: UnsafePointer<CChar>?
    ) throws {
        var errorPointer: UnsafePointer<CChar>?
        let result = gemma_bridge_session_recreate_conversation_with_history(
            activeSession,
            systemCString,
            toolsCString,
            historyCString,
            &errorPointer
        )
        guard result == 0 else {
            let message = errorPointer.map { String(cString: $0) } ?? "Failed to recreate LiteRT-LM conversation."
            throw GemmaTextRunnerError.runtime(message)
        }
    }

    private func destroyBridgeSession() {
        if let activeSession {
            gemma_bridge_session_destroy(activeSession)
        }
        activeSession = nil
    }
}

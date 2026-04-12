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

    func makeSession(modelURL: URL) throws {
        guard activeSession == nil else { return }
        try modelURL.path.withCString { modelPath in
            var errorPointer: UnsafePointer<CChar>?
            guard let session = gemma_bridge_session_create(modelPath, &errorPointer) else {
                let message = errorPointer.map { String(cString: $0) } ?? "Failed to create LiteRT-LM session."
                throw GemmaTextRunnerError.runtime(message)
            }
            activeSession = session
        }
    }

    func makeToolSession(modelURL: URL, toolsJSON: String) throws {
        try modelURL.path.withCString { modelPath in
            try toolsJSON.withCString { toolsCString in
                var errorPointer: UnsafePointer<CChar>?
                guard let session = gemma_bridge_session_create_with_tools(modelPath, toolsCString, &errorPointer) else {
                    let message = errorPointer.map { String(cString: $0) } ?? "Failed to create LiteRT-LM tool session."
                    throw GemmaTextRunnerError.runtime(message)
                }
                activeSession = session
            }
        }
    }

    func sendJSON(_ messageJSON: String) throws -> LiteRTParsedMessage {
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
            throw GemmaTextRunnerError.runtime(message)
        }

        let response = responsePointer.map { String(cString: $0) } ?? ""
        return LiteRTResponseParser.parse(response)
    }

    func destroySession() {
        guard let activeSession else { return }
        gemma_bridge_session_destroy(activeSession)
        self.activeSession = nil
    }
}

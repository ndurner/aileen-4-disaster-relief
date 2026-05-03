import Foundation

enum GoogleAIStudioClientError: LocalizedError {
    case missingAPIKey
    case invalidResponse(String)
    case upstream(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Google AI Studio API key is missing. Add it in Settings before using cloud creation."
        case .invalidResponse(let message):
            return message
        case .upstream(let message):
            return message
        case .transport(let message):
            return message
        }
    }
}

struct GoogleAIStudioContent: @unchecked Sendable {
    let value: [String: Any]
}

struct GoogleAIStudioContents: @unchecked Sendable {
    let value: [[String: Any]]
}

struct GoogleAIStudioToolConfig: Sendable {
    let mode: String
    let allowedFunctionNames: [String]?

    static func constrainedToAllowedFunctions(_ names: [String]) -> GoogleAIStudioToolConfig {
        GoogleAIStudioToolConfig(mode: "ANY", allowedFunctionNames: names)
    }

    var value: [String: Any] {
        var config: [String: Any] = [
            "functionCallingConfig": [
                "mode": mode
            ]
        ]
        if let allowedFunctionNames, !allowedFunctionNames.isEmpty {
            config["functionCallingConfig"] = [
                "mode": mode,
                "allowedFunctionNames": allowedFunctionNames
            ]
        }
        return config
    }
}

struct GoogleAIStudioGenerateContentResponse: Sendable {
    let modelContentObject: GoogleAIStudioContent
    let parsedMessage: LiteRTParsedMessage
    let rawResponseJSON: String
    let finishReason: String?
    let finishMessage: String?
}

struct GoogleAIStudioFileReference: Sendable {
    let name: String
    let uri: String
    let mimeType: String
}

struct GoogleAIStudioClient {
    private static let endpointPrefix = "https://generativelanguage.googleapis.com/v1beta/models/"
    private static let fileEndpointPrefix = "https://generativelanguage.googleapis.com/v1beta/"
    private static let fileUploadEndpoint = "https://generativelanguage.googleapis.com/upload/v1beta/files"
    private static let maxGenerateContentAttempts = 2
    private static let generateContentTimeout: TimeInterval = 240
    private static let fileUploadTimeout: TimeInterval = 240

    let apiKey: String
    var session: URLSession = .shared

    func uploadFile(_ uploadFile: PromptMediaEncoder.UploadFile) async throws -> GoogleAIStudioFileReference {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw GoogleAIStudioClientError.missingAPIKey
        }

        let byteCount = try FileManager.default.attributesOfItem(atPath: uploadFile.url.path)[.size] as? NSNumber
        guard let byteCount else {
            throw GoogleAIStudioClientError.invalidResponse("The media file size could not be read before upload.")
        }

        guard let startURL = URL(string: Self.fileUploadEndpoint) else {
            throw GoogleAIStudioClientError.invalidResponse("The Google AI Studio file upload URL could not be constructed.")
        }

        var startRequest = URLRequest(url: startURL)
        startRequest.httpMethod = "POST"
        startRequest.timeoutInterval = Self.fileUploadTimeout
        startRequest.setValue(trimmedKey, forHTTPHeaderField: "x-goog-api-key")
        startRequest.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        startRequest.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        startRequest.setValue(byteCount.stringValue, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        startRequest.setValue(uploadFile.mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        startRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        startRequest.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "file": [
                    "displayName": uploadFile.displayName
                ]
            ],
            options: []
        )

        let (_, startResponse) = try await session.data(for: startRequest)
        guard let startHTTPResponse = startResponse as? HTTPURLResponse else {
            throw GoogleAIStudioClientError.invalidResponse("Google AI Studio did not return a valid file upload start response.")
        }
        guard (200...299).contains(startHTTPResponse.statusCode) else {
            throw GoogleAIStudioClientError.upstream("Google AI Studio file upload start failed with status \(startHTTPResponse.statusCode).")
        }
        guard let uploadURLString = Self.headerValue("x-goog-upload-url", from: startHTTPResponse),
              let uploadURL = URL(string: uploadURLString) else {
            throw GoogleAIStudioClientError.invalidResponse("Google AI Studio did not return a resumable upload URL.")
        }

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.timeoutInterval = Self.fileUploadTimeout
        uploadRequest.setValue(byteCount.stringValue, forHTTPHeaderField: "Content-Length")
        uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")

        let (data, uploadResponse) = try await session.upload(for: uploadRequest, fromFile: uploadFile.url)
        guard let uploadHTTPResponse = uploadResponse as? HTTPURLResponse else {
            throw GoogleAIStudioClientError.invalidResponse("Google AI Studio did not return a valid file upload response.")
        }
        guard (200...299).contains(uploadHTTPResponse.statusCode) else {
            throw GoogleAIStudioClientError.upstream(errorMessage(from: data, statusCode: uploadHTTPResponse.statusCode))
        }
        guard let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let file = object["file"] as? [String: Any],
              let name = file["name"] as? String,
              let uri = file["uri"] as? String else {
            throw GoogleAIStudioClientError.invalidResponse("Google AI Studio returned an unreadable file upload payload.")
        }

        return GoogleAIStudioFileReference(
            name: name,
            uri: uri,
            mimeType: (file["mimeType"] as? String) ?? uploadFile.mimeType
        )
    }

    func deleteFile(_ file: GoogleAIStudioFileReference) async {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty,
              let url = URL(string: Self.fileEndpointPrefix + file.name) else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.setValue(trimmedKey, forHTTPHeaderField: "x-goog-api-key")
        _ = try? await session.data(for: request)
    }

    func sendGenerateContent(
        model: CloudModelOption,
        contents: GoogleAIStudioContents,
        systemInstruction: String? = nil,
        toolsJSON: String? = nil,
        toolConfig: GoogleAIStudioToolConfig? = nil
    ) async throws -> GoogleAIStudioGenerateContentResponse {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw GoogleAIStudioClientError.missingAPIKey
        }

        guard let url = URL(string: Self.endpointPrefix + model.requestModelIdentifier + ":generateContent") else {
            throw GoogleAIStudioClientError.invalidResponse("The Google AI Studio endpoint URL could not be constructed.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.generateContentTimeout
        request.setValue(trimmedKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "contents": contents.value
        ]

        let trimmedInstruction = systemInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedInstruction.isEmpty {
            body["systemInstruction"] = [
                "parts": [
                    ["text": trimmedInstruction]
                ]
            ]
        }

        if let toolsJSON {
            let declarations = try parseFunctionDeclarations(from: toolsJSON)
            if !declarations.isEmpty {
                body["tools"] = [
                    ["functionDeclarations": declarations]
                ]
            }
        }

        if let toolConfig {
            body["toolConfig"] = toolConfig.value
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        var lastError: Error?
        for attempt in 1...Self.maxGenerateContentAttempts {
            try Task.checkCancellation()
            do {
                return try await performGenerateContentRequest(request)
            } catch {
                if Self.isCancellation(error) {
                    throw CancellationError()
                }
                lastError = error
                guard Self.shouldRetry(error, attempt: attempt) else {
                    throw Self.userFacingError(
                        from: error,
                        model: model,
                        attemptCount: attempt
                    )
                }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 750_000_000)
            }
        }

        throw Self.userFacingError(
            from: lastError ?? GoogleAIStudioClientError.invalidResponse("Google AI Studio request failed."),
            model: model,
            attemptCount: Self.maxGenerateContentAttempts
        )
    }

    private func performGenerateContentRequest(_ request: URLRequest) async throws -> GoogleAIStudioGenerateContentResponse {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleAIStudioClientError.invalidResponse("Google AI Studio did not return a valid HTTP response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw GoogleAIStudioClientError.upstream(errorMessage(from: data, statusCode: httpResponse.statusCode))
        }

        guard let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw GoogleAIStudioClientError.invalidResponse("Google AI Studio returned an unreadable generateContent payload.")
        }
        let rawResponseJSON = ProductionToolSchema.stringify(object)

        if let promptFeedback = object["promptFeedback"] as? [String: Any],
           let blockReason = promptFeedback["blockReason"] as? String,
           !blockReason.isEmpty,
           (object["candidates"] as? [[String: Any]])?.isEmpty != false {
            throw GoogleAIStudioClientError.upstream("Google AI Studio blocked the request: \(blockReason).")
        }

        guard let candidates = object["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first else {
            throw GoogleAIStudioClientError.invalidResponse("Google AI Studio returned no candidates.")
        }

        if let finishReason = firstCandidate["finishReason"] as? String,
           finishReason == "SAFETY" {
            throw GoogleAIStudioClientError.upstream("Google AI Studio stopped the response for safety reasons.")
        }

        guard let content = firstCandidate["content"] as? [String: Any] else {
            throw GoogleAIStudioClientError.invalidResponse("Google AI Studio returned a candidate without model content.")
        }

        return GoogleAIStudioGenerateContentResponse(
            modelContentObject: GoogleAIStudioContent(value: content),
            parsedMessage: GoogleAIStudioResponseParser.parseContent(
                content,
                rawResponseJSON: rawResponseJSON
            ),
            rawResponseJSON: rawResponseJSON,
            finishReason: firstCandidate["finishReason"] as? String,
            finishMessage: firstCandidate["finishMessage"] as? String
        )
    }

    private static func shouldRetry(_ error: Error, attempt: Int) -> Bool {
        guard attempt < maxGenerateContentAttempts else {
            return false
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return false
            case .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("internal error")
            || message.contains("temporarily unavailable")
            || message.contains("deadline exceeded")
            || message.contains("bad gateway")
            || message.contains("service unavailable")
            || message.contains("gateway timeout")
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        return (error as? URLError)?.code == .cancelled
    }

    private static func userFacingError(
        from error: Error,
        model: CloudModelOption,
        attemptCount: Int
    ) -> Error {
        if let clientError = error as? GoogleAIStudioClientError {
            return clientError
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return GoogleAIStudioClientError.transport("""
                Gemini API request to \(model.requestModelIdentifier) timed out after \(Int(generateContentTimeout)) seconds (attempts: \(attemptCount)). The hosted model did not return before the field-mode deadline. Try again, switch to the smaller cloud model, or use on-device inference when network latency is high.
                """)
            case .networkConnectionLost:
                return GoogleAIStudioClientError.transport("Gemini API request to \(model.requestModelIdentifier) lost the network connection. Check connectivity and try again.")
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return GoogleAIStudioClientError.transport("Gemini API endpoint could not be reached for \(model.requestModelIdentifier). Check connectivity, DNS, or API availability and try again.")
            default:
                return GoogleAIStudioClientError.transport("Gemini API request to \(model.requestModelIdentifier) failed: \(urlError.localizedDescription)")
            }
        }

        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else {
            return GoogleAIStudioClientError.transport("Gemini API request to \(model.requestModelIdentifier) failed.")
        }
        return GoogleAIStudioClientError.transport("Gemini API request to \(model.requestModelIdentifier) failed: \(detail)")
    }

    private func parseFunctionDeclarations(from json: String) throws -> [[String: Any]] {
        guard let data = json.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data, options: []) as? [Any] else {
            throw GoogleAIStudioClientError.invalidResponse("The Google AI Studio function declarations could not be encoded.")
        }

        return array.compactMap { entry in
            guard let object = entry as? [String: Any] else {
                return nil
            }
            if let function = object["function"] as? [String: Any] {
                return function
            }
            return object["name"] as? String == nil ? nil : object
        }
    }

    private func errorMessage(from data: Data, statusCode: Int) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return "Google AI Studio request failed with status \(statusCode)."
        }

        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return "Google AI Studio request failed with status \(statusCode): \(message)"
        }

        if let message = object["message"] as? String, !message.isEmpty {
            return "Google AI Studio request failed with status \(statusCode): \(message)"
        }

        return "Google AI Studio request failed with status \(statusCode)."
    }

    private static func headerValue(_ name: String, from response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String,
                  key.caseInsensitiveCompare(name) == .orderedSame else {
                continue
            }
            return value as? String
        }
        return nil
    }
}

enum GoogleAIStudioMessageFactory {
    static func userMessage(
        text: String,
        assets: [ProductionAssetDescriptor] = [],
        fileReferences: [String: GoogleAIStudioFileReference] = [:]
    ) throws -> [String: Any] {
        var parts: [[String: Any]] = [
            ["text": text]
        ]

        for asset in assets {
            if let fileReference = fileReferences[asset.toolID] {
                parts.append([
                    "fileData": [
                        "mimeType": fileReference.mimeType,
                        "fileUri": fileReference.uri
                    ]
                ])
                continue
            }
            guard let inlineData = try promptInlineData(for: asset.mediaAsset) else {
                continue
            }
            parts.append([
                "inlineData": inlineData
            ])
        }

        return [
            "role": "user",
            "parts": parts
        ]
    }

    static func functionResponseMessage(
        toolCalls: [LiteRTToolCall],
        responses: [MediaToolResult]
    ) -> [String: Any] {
        let pairs = zip(toolCalls, responses)
        let parts = pairs.map { toolCall, response -> [String: Any] in
            var functionResponse: [String: Any] = [
                "name": toolCall.name,
                "response": [
                    "result": response.payload
                ]
            ]
            if let toolCallID = toolCall.toolCallID, !toolCallID.isEmpty {
                functionResponse["id"] = toolCallID
            }
            return [
                "functionResponse": functionResponse
            ]
        }

        return [
            "role": "user",
            "parts": parts
        ]
    }

    private static func promptInlineData(for asset: MediaAsset) throws -> [String: Any]? {
        guard let inlineImage = try PromptMediaEncoder.promptInlineImageData(for: asset) else {
            return nil
        }

        return [
            "mimeType": inlineImage.mimeType,
            "data": inlineImage.data.base64EncodedString()
        ]
    }
}

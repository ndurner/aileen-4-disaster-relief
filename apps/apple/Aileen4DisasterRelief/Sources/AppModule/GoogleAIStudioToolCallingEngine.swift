import Foundation
import OSLog

actor GoogleAIStudioToolCallingEngine {
    private static let maxToolRounds = 8
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Aileen4DisasterRelief",
        category: "HostedGemmaConversation"
    )

    private let client: GoogleAIStudioClient
    private let fileReferences: [String: GoogleAIStudioFileReference]

    init(apiKey: String, fileReferences: [String: GoogleAIStudioFileReference] = [:]) {
        client = GoogleAIStudioClient(apiKey: apiKey)
        self.fileReferences = fileReferences
    }

    func run(
        initialPrompt: String,
        model: CloudModelOption,
        sourceAssets: [ProductionAssetDescriptor],
        outputKind: ProductionWorkflowViewModel.OutputKind,
        systemInstruction: String,
        protectedRegionProvider: OverlayProtectedRegionProvider = .none,
        protectedRegionsOverride: OverlayProtectedRegions = .empty,
        layoutGuideOverride: OverlayLayoutGuide = .empty
    ) async throws -> ToolExecutionResult {
        let tooling = AppleMediaTooling(
            sourceAssets: sourceAssets,
            outputKind: outputKind,
            protectedRegionProvider: protectedRegionProvider,
            protectedRegionsOverride: protectedRegionsOverride,
            layoutGuideOverride: layoutGuideOverride
        )

        var seenCalls: [LiteRTToolCall] = []
        var responsePayloads: [String] = []
        var latestProducedURL: URL?
        var finalText = ""
        var rawResponses: [String] = []
        var thoughtTraces: [String] = []
        var activeFileReferences = fileReferences
        if activeFileReferences.isEmpty {
            activeFileReferences = try await uploadCloudFiles(sourceAssets)
        }
        defer {
            if fileReferences.isEmpty {
                Task {
                    await self.deleteCloudFiles(activeFileReferences)
                }
            }
        }

        let needsComposition = sourceAssets.count > 1
        let firstPrompt = needsComposition ? composeTurnPrompt(from: initialPrompt) : initialPrompt
        let firstAssets = needsComposition ? [] : sourceAssets
        let firstAllowedFunctions = needsComposition ? ["compose_visuals"] : ["add_text_overlay"]
        Self.logOutgoingTurn(label: "visual user turn 1", text: firstPrompt, assets: firstAssets)
        var contents: [[String: Any]] = [
            try GoogleAIStudioMessageFactory.userMessage(
                text: firstPrompt,
                assets: firstAssets,
                fileReferences: activeFileReferences
            )
        ]

        var response = try await client.sendGenerateContent(
            model: model,
            contents: GoogleAIStudioContents(value: contents),
            systemInstruction: systemInstruction,
            toolsJSON: ProductionToolSchema.toolsJSON,
            toolConfig: .constrainedToAllowedFunctions(firstAllowedFunctions)
        )
        var parsed = response.parsedMessage
        Self.logIncomingTurn(label: "visual model turn 1", response: response)
        rawResponses.append(response.rawResponseJSON)
        if !parsed.thoughtText.isEmpty {
            thoughtTraces.append(parsed.thoughtText)
        }
        finalText = parsed.text

        var toolRounds = 0
        while !parsed.toolCalls.isEmpty {
            toolRounds += 1
            if toolRounds > Self.maxToolRounds {
                finalText = """
                \(parsed.text.trimmingCharacters(in: .whitespacesAndNewlines))

                Stopped after \(Self.maxToolRounds) tool rounds to avoid a non-progressing overlay loop.
                """.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }

            seenCalls.append(contentsOf: parsed.toolCalls)

            var responses: [MediaToolResult] = []
            for toolCall in parsed.toolCalls {
                responses.append(try await tooling.execute(toolCall: toolCall))
            }
            Self.logToolResponses(responses)

            responsePayloads.append(contentsOf: responses.map { ProductionToolSchema.stringify($0.payload) })
            latestProducedURL = responses.compactMap(\.outputURL).last ?? latestProducedURL
            if responses.contains(where: { $0.name == "accept_overlay_layout" }) {
                break
            }

            let responseStatuses = responses.compactMap { $0.payload["status"] as? String }
            if !responseStatuses.isEmpty && responseStatuses.allSatisfy({ $0 == "skipped_duplicate" }) {
                finalText = """
                \(parsed.text.trimmingCharacters(in: .whitespacesAndNewlines))

                Stopped after duplicate overlay calls produced no further visual changes.
                """.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }

            guard let allowedFunctionNames = allowedFunctionNames(after: responses) else {
                break
            }

            contents.append(response.modelContentObject.value)
            contents.append(GoogleAIStudioMessageFactory.functionResponseMessage(
                toolCalls: parsed.toolCalls,
                responses: responses
            ))

            response = try await client.sendGenerateContent(
                model: model,
                contents: GoogleAIStudioContents(value: contents),
                systemInstruction: systemInstruction,
                toolsJSON: ProductionToolSchema.toolsJSON,
                toolConfig: .constrainedToAllowedFunctions(allowedFunctionNames)
            )
            parsed = response.parsedMessage
            Self.logIncomingTurn(label: "visual model turn \(toolRounds + 1)", response: response)
            rawResponses.append(response.rawResponseJSON)
            if !parsed.thoughtText.isEmpty {
                thoughtTraces.append(parsed.thoughtText)
            }
            finalText = parsed.text
        }

        return ToolExecutionResult(
            toolCalls: seenCalls,
            toolResponsePayloads: responsePayloads,
            finalText: finalText,
            producedURLs: latestProducedURL.map { [$0] } ?? [],
            rawResponses: rawResponses,
            thoughtTraces: thoughtTraces
        )
    }

    private func composeTurnPrompt(from initialPrompt: String) -> String {
        """
        \(initialPrompt)

        This turn is only for choosing source assets for the base composition.
        Ignore any earlier instruction that says to return overlay copy directly.
        Call compose_visuals now using only the exact asset IDs listed in <valid_source_asset_ids>.
        Do not use filenames, uploaded file handles, or invented asset identifiers.
        """
    }

    private func allowedFunctionNames(after responses: [MediaToolResult]) -> [String]? {
        let names = responses.map(\.name)
        if names.contains("accept_overlay_layout") {
            return nil
        }
        if names.contains("compose_visuals") {
            return ["add_text_overlay"]
        }
        if names.contains("add_text_overlay") || names.contains("move_text_overlay") {
            return ["move_text_overlay", "accept_overlay_layout"]
        }
        return nil
    }

    private func uploadCloudFiles(_ assets: [ProductionAssetDescriptor]) async throws -> [String: GoogleAIStudioFileReference] {
        var uploadedFiles: [String: GoogleAIStudioFileReference] = [:]
        do {
            for asset in assets {
                try Task.checkCancellation()
                guard let uploadFile = try PromptMediaEncoder.promptUploadFile(for: asset.mediaAsset) else {
                    continue
                }
                uploadedFiles[asset.toolID] = try await client.uploadFile(uploadFile)
            }
            return uploadedFiles
        } catch {
            await deleteCloudFiles(uploadedFiles)
            throw error
        }
    }

    private func deleteCloudFiles(_ fileReferences: [String: GoogleAIStudioFileReference]) async {
        for fileReference in fileReferences.values {
            await client.deleteFile(fileReference)
        }
    }

    private static func logOutgoingTurn(
        label: String,
        text: String,
        assets: [ProductionAssetDescriptor]
    ) {
        logger.notice("[Hosted Gemma] \(label, privacy: .public)")
        logger.notice("[Hosted Gemma] outgoing text: \(text, privacy: .public)")
        if !assets.isEmpty {
            let assetSummary = assets.map(\.promptSummary).joined(separator: " | ")
            logger.notice("[Hosted Gemma] outgoing assets: \(assetSummary, privacy: .public)")
        }
    }

    private static func logIncomingTurn(
        label: String,
        response: GoogleAIStudioGenerateContentResponse
    ) {
        let parsed = response.parsedMessage
        logger.notice("[Hosted Gemma] \(label, privacy: .public)")
        if !parsed.thoughtText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.notice("[Hosted Gemma] thinking: \(parsed.thoughtText, privacy: .public)")
        }
        if !parsed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.notice("[Hosted Gemma] visible text: \(parsed.text, privacy: .public)")
        }
        if !parsed.toolCalls.isEmpty {
            for toolCall in parsed.toolCalls {
                logger.notice("[Hosted Gemma] tool call: \(toolCall.logDescription, privacy: .public)")
            }
        }
        if let finishReason = response.finishReason, !finishReason.isEmpty {
            logger.notice("[Hosted Gemma] finish reason: \(finishReason, privacy: .public)")
        }
        if let finishMessage = response.finishMessage, !finishMessage.isEmpty {
            logger.notice("[Hosted Gemma] finish message: \(finishMessage, privacy: .public)")
        }
        logger.notice("[Hosted Gemma] raw API response: \(response.rawResponseJSON, privacy: .public)")
    }

    private static func logToolResponses(_ responses: [MediaToolResult]) {
        for response in responses {
            logger.notice("[Hosted Gemma] tool result \(response.name, privacy: .public): \(ProductionToolSchema.stringify(response.payload), privacy: .public)")
        }
    }
}

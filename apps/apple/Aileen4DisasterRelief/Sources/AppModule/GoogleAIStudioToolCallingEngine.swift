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
        layoutGuideOverride: OverlayLayoutGuide = .empty,
        postReviewMode: OverlayPostReviewMode = .none
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

        if postReviewMode != .none,
           latestProducedURL != nil,
           let currentAssetID = GemmaToolCallingEngine.latestRenderedAssetID(from: responsePayloads) {
            let reviewContext = GemmaToolCallingEngine.latestOverlayReviewContext(from: seenCalls, payloads: responsePayloads)
            let reviewResult = try await runFreshOverlayReview(
                model: model,
                renderedAssetID: currentAssetID,
                tooling: tooling,
                layoutGuideOverride: layoutGuideOverride,
                reviewContext: reviewContext,
                mode: postReviewMode
            )
            seenCalls.append(contentsOf: reviewResult.toolCalls)
            responsePayloads.append(contentsOf: reviewResult.toolResponsePayloads)
            latestProducedURL = reviewResult.latestProducedURL ?? latestProducedURL
            if !reviewResult.finalText.isEmpty {
                finalText = reviewResult.finalText
            }
            rawResponses.append(contentsOf: reviewResult.rawResponses)
            thoughtTraces.append(contentsOf: reviewResult.thoughtTraces)
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

    private func runFreshOverlayReview(
        model: CloudModelOption,
        renderedAssetID: String,
        tooling: AppleMediaTooling,
        layoutGuideOverride: OverlayLayoutGuide,
        reviewContext: OverlayReviewContext?,
        mode: OverlayPostReviewMode
    ) async throws -> (toolCalls: [LiteRTToolCall], toolResponsePayloads: [String], latestProducedURL: URL?, finalText: String, rawResponses: [String], thoughtTraces: [String]) {
        let reviewAssets = try tooling.makeOverlayReviewAssets(
            renderedAssetID: renderedAssetID,
            reviewContext: reviewContext
        )
        let prompt = ReviewToolSchema.reviewPrompt(
            renderedAssetID: renderedAssetID,
            guide: layoutGuideOverride,
            reviewContext: reviewContext,
            mode: mode
        )

        Self.logOutgoingTurn(label: "visual review user turn 1", text: prompt, assets: reviewAssets)
        var contents: [[String: Any]] = [
            try GoogleAIStudioMessageFactory.userMessage(text: prompt, assets: reviewAssets)
        ]
        var response = try await client.sendGenerateContent(
            model: model,
            contents: GoogleAIStudioContents(value: contents),
            systemInstruction: ReviewToolSchema.systemInstruction(allowsAccept: mode.allowsAccept),
            toolsJSON: ReviewToolSchema.toolsJSON(allowsAccept: mode.allowsAccept),
            toolConfig: .constrainedToAllowedFunctions(mode.allowsAccept ? ["move_text_overlay", "accept_overlay_layout"] : ["move_text_overlay"])
        )
        var parsed = response.parsedMessage
        Self.logIncomingTurn(label: "visual review model turn 1", response: response)

        var seenCalls: [LiteRTToolCall] = []
        var responsePayloads: [String] = []
        var latestProducedURL: URL?
        var finalText = parsed.text
        var rawResponses: [String] = [response.rawResponseJSON]
        var thoughtTraces: [String] = parsed.thoughtText.isEmpty ? [] : [parsed.thoughtText]
        var toolRounds = 0
        let maxReviewToolRounds = 2

        while !parsed.toolCalls.isEmpty {
            toolRounds += 1
            seenCalls.append(contentsOf: parsed.toolCalls)
            var responses: [MediaToolResult] = []
            for toolCall in parsed.toolCalls {
                responses.append(try await tooling.execute(toolCall: toolCall))
            }
            Self.logToolResponses(responses)
            responsePayloads.append(contentsOf: responses.map { ProductionToolSchema.stringify($0.payload) })
            latestProducedURL = responses.compactMap(\.outputURL).last ?? latestProducedURL
            let shouldRetryRejectedMove = responses.contains { result in
                guard let status = result.payload["status"] as? String else { return false }
                return ["invalid_partial_rect", "invalid_rect_bounds", "invalid_upper_retry", "invalid_upper_move"].contains(status)
            }
            if !shouldRetryRejectedMove || toolRounds >= maxReviewToolRounds {
                break
            }

            contents.append(response.modelContentObject.value)
            contents.append(GoogleAIStudioMessageFactory.functionResponseMessage(
                toolCalls: parsed.toolCalls,
                responses: responses
            ))
            guard let continuation = try reviewContinuationMessage(responses: responses) else {
                break
            }
            contents.append(continuation)

            response = try await client.sendGenerateContent(
                model: model,
                contents: GoogleAIStudioContents(value: contents),
                systemInstruction: ReviewToolSchema.systemInstruction(allowsAccept: mode.allowsAccept),
                toolsJSON: ReviewToolSchema.toolsJSON(allowsAccept: mode.allowsAccept),
                toolConfig: .constrainedToAllowedFunctions(mode.allowsAccept ? ["move_text_overlay", "accept_overlay_layout"] : ["move_text_overlay"])
            )
            parsed = response.parsedMessage
            Self.logIncomingTurn(label: "visual review model turn \(toolRounds + 1)", response: response)
            finalText = parsed.text
            rawResponses.append(response.rawResponseJSON)
            if !parsed.thoughtText.isEmpty {
                thoughtTraces.append(parsed.thoughtText)
            }
        }

        return (seenCalls, responsePayloads, latestProducedURL, finalText, rawResponses, thoughtTraces)
    }

    private func reviewContinuationMessage(responses: [MediaToolResult]) throws -> [String: Any]? {
        let statuses = responses.compactMap { $0.payload["status"] as? String }
        if statuses.contains("invalid_partial_rect") {
            let renderedAssetID = responses.compactMap { $0.payload["asset_id"] as? String }.last ?? "the same rendered asset"
            let prompt = """
            Your previous move was rejected because it gave only some coordinates.
            Call move_text_overlay again on asset_id \(renderedAssetID) with all four integers: x, y, width, height.
            Do not use top_fraction or anchors in this retry.
            Do not move toward hands, tools, plants, guards, animals, paperwork, or the main action. Choose plain open background, side margin, sky, or open ground instead.
            """
            return try GoogleAIStudioMessageFactory.userMessage(text: prompt, assets: [])
        }
        if statuses.contains("invalid_rect_bounds") {
            let renderedAssetID = responses.compactMap { $0.payload["asset_id"] as? String }.last ?? "the same rendered asset"
            let canvasWidth = responses.compactMap { $0.payload["canvas_width"] as? Int }.last ?? 1080
            let canvasHeight = responses.compactMap { $0.payload["canvas_height"] as? Int }.last ?? 1350
            let prompt = """
            Your previous move was rejected because its rectangle was outside the image or too small for readable text.
            Call move_text_overlay again on asset_id \(renderedAssetID) with x, y, width, height fully inside the \(canvasWidth)x\(canvasHeight) canvas.
            width and height mean the sticker slot size, not the image size. Use a compact slot, usually width 240-560 and height 120-320.
            Leave at least 40 px of margin from every image edge; do not put the rectangle flush against the border.
            If the rejected location was otherwise clear, keep the same x and y and enlarge the slot just enough; do not jump to another part of the image.
            Do not move toward hands, tools, plants, guards, animals, paperwork, or the main action. Choose plain open background, side margin, sky, or open ground instead.
            """
            return try GoogleAIStudioMessageFactory.userMessage(text: prompt, assets: [])
        }
        if statuses.contains("invalid_upper_retry") || statuses.contains("invalid_upper_move") {
            let renderedAssetID = responses.compactMap { $0.payload["asset_id"] as? String }.last ?? "the same rendered asset"
            let prompt = """
            Your previous move was rejected because it used a wide upper banner.
            Call move_text_overlay again on asset_id \(renderedAssetID) with all four integers: x, y, width, height.
            Use a compact side/corner slot or open middle rows instead.
            Do not move toward hands, tools, plants, guards, animals, paperwork, or the main action. Choose plain open background, side margin, sky, or open ground instead.
            """
            return try GoogleAIStudioMessageFactory.userMessage(text: prompt, assets: [])
        }

        return nil
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

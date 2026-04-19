import Foundation

#if canImport(UIKit)
import UIKit
#endif

struct OverlayAutomationConfig: Decodable {
    struct Scenario: Decodable {
        struct ReviewPass: Decodable {
            let enabled: Bool
            let enableThinking: Bool?
            let reviewPromptAddendum: String?
            let rerunOnFailure: Bool?
        }

        let name: String
        let assetPaths: [String]
        let backgroundBriefing: String
        let story: String
        let promptAddendum: String?
        let outputKind: String
        let model: String
        let modelSource: String
        let enableThinking: Bool?
        let preOverlayAnalysisEnableThinking: Bool?
        let reuseGemmaEngine: Bool?
        let layoutGuideOverridePath: String?
        let disableEvaluationAnalysis: Bool?
        let protectedRegionProvider: String?
        let preOverlayAnalysisProvider: String?
        let preOverlayGuidanceMode: String?
        let useLayoutGuideProtectedRegions: Bool?
        let rerunOnEvaluationOverlap: Bool?
        let postReviewMode: String?
        let rawThinkingDiagnostic: Bool?
        let reviewPass: ReviewPass?
    }

    let outputDirectory: String
    let scenarios: [Scenario]
}

struct OverlayAutomationResult: Encodable {
    struct ScenarioResult: Encodable {
        struct AttemptResult: Encodable {
            struct ToolCallRecord: Encodable {
                let name: String
                let arguments: [String: String]
            }

            struct ReviewResult: Encodable {
                let approved: Bool
                let critique: String
                let rerunGuidance: String
                let subjectOverlapDetected: Bool
                let overallScore: Double
                let placementScore: Double
                let styleScore: Double
                let copyScore: Double
            }

            struct Goodness: Encodable {
                let overlayCount: Int
                let firstOverlayWidthFraction: Double?
                let firstOverlayHeightFraction: Double?
                let subjectOverlapFraction: Double?
                let avoidanceOverlapFraction: Double?
                let analysisProvider: String?
                let evaluationProvider: String?
                let usedNormalizedHints: Bool
                let usedSlotPlacement: Bool
                let enableThinking: Bool
                let heuristicScore: Double
                let reviewOverallScore: Double?
                let reviewSubjectOverlapDetected: Bool?
                let combinedScore: Double?
            }

            let attemptIndex: Int
            let prompt: String
            let toolCalls: [ToolCallRecord]
            let toolResponsePayloads: [String]
            let producedFiles: [String]
            let rawResponses: [String]
            let thoughtTraces: [String]
            let summary: String
            let firstOverlayStyle: String?
            let firstOverlayTopFraction: Double?
            let goodness: Goodness
            let review: ReviewResult?
            let durationSeconds: Double
        }

        let name: String
        let attempts: [AttemptResult]
        let error: String?
    }

    let startedAt: String
    let finishedAt: String
    let outputDirectory: String
    let scenarios: [ScenarioResult]
    let error: String?
}

private struct OverlayAutomationReview {
    let approved: Bool
    let critique: String
    let rerunGuidance: String
    let subjectOverlapDetected: Bool
    let overallScore: Double
    let placementScore: Double
    let styleScore: Double
    let copyScore: Double
}

private struct OverlayAutomationLayoutGuideRun {
    let guide: OverlayLayoutGuide
    let prompt: String?
    let rawResponses: [String]
    let thoughtTraces: [String]
}

private enum OverlayReviewToolSchema {
    static let toolName = "submit_overlay_review"

    static let toolsJSON = """
    [
      {
        "type": "function",
        "function": {
          "name": "\(toolName)",
          "description": "Review whether an overlay feels current and well-placed for Instagram-style social content, then provide concise rerun guidance when it should be improved.",
          "parameters": {
            "type": "object",
            "properties": {
              "approved": { "type": "boolean" },
              "critique": { "type": "string" },
              "rerun_guidance": { "type": "string" },
              "subject_overlap_detected": { "type": "boolean" },
              "overall_score": { "type": "number" },
              "placement_score": { "type": "number" },
              "style_score": { "type": "number" },
              "copy_score": { "type": "number" }
            },
            "required": ["approved", "critique", "rerun_guidance", "subject_overlap_detected", "overall_score", "placement_score", "style_score", "copy_score"]
          }
        }
      }
    ]
    """

    static func extract(from parsed: LiteRTParsedMessage) -> OverlayAutomationReview {
        guard let toolCall = parsed.toolCalls.first(where: { $0.name == toolName }) else {
            return OverlayAutomationReview(
                approved: true,
                critique: parsed.text.trimmingCharacters(in: .whitespacesAndNewlines),
                rerunGuidance: "",
                subjectOverlapDetected: false,
                overallScore: 80,
                placementScore: 80,
                styleScore: 80,
                copyScore: 80
            )
        }

        return OverlayAutomationReview(
            approved: toolCall.arguments["approved"]?.boolValue ?? true,
            critique: toolCall.arguments["critique"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            rerunGuidance: toolCall.arguments["rerun_guidance"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            subjectOverlapDetected: toolCall.arguments["subject_overlap_detected"]?.boolValue ?? false,
            overallScore: toolCall.arguments["overall_score"]?.numberValue ?? 80,
            placementScore: toolCall.arguments["placement_score"]?.numberValue ?? 80,
            styleScore: toolCall.arguments["style_score"]?.numberValue ?? 80,
            copyScore: toolCall.arguments["copy_score"]?.numberValue ?? 80
        )
    }
}

@MainActor
enum OverlayAutomationLab {
    private static var didStart = false

    static func runIfRequested() async {
        guard !didStart else { return }
        didStart = true

        guard let configPath = ProcessInfo.processInfo.environment["AILEEN_AUTOMATION_CONFIG_PATH"],
              !configPath.isEmpty else {
            return
        }

        do {
            let result = try await run(configPath: configPath)
            try write(result: result, outputDirectory: resolvedURL(for: result.outputDirectory))
            print("Overlay automation completed.")
            terminate(exitCode: 0)
        } catch {
            let fallbackDirectory = resolvedURL(for: "Documents/OverlayAutomation/results")
            let formatter = ISO8601DateFormatter()
            let result = OverlayAutomationResult(
                startedAt: formatter.string(from: Date()),
                finishedAt: formatter.string(from: Date()),
                outputDirectory: fallbackDirectory.path,
                scenarios: [],
                error: error.localizedDescription
            )
            try? write(result: result, outputDirectory: fallbackDirectory)
            print("Overlay automation failed: \(error.localizedDescription)")
            terminate(exitCode: 1)
        }
    }

    private static func run(configPath: String) async throws -> OverlayAutomationResult {
        let started = Date()
        let formatter = ISO8601DateFormatter()
        let configURL = resolvedURL(for: configPath)
        print("Overlay automation config path: \(configURL.path)")
        let configData = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(OverlayAutomationConfig.self, from: configData)
        let outputDirectory = resolvedURL(for: config.outputDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        appendProgressLog("Run started with \(config.scenarios.count) scenarios.", outputDirectory: outputDirectory)

        var scenarioResults: [OverlayAutomationResult.ScenarioResult] = []
        for scenario in config.scenarios {
            appendProgressLog("Starting scenario \(scenario.name)", outputDirectory: outputDirectory)
            let scenarioResult = await runScenario(scenario, outputDirectory: outputDirectory)
            scenarioResults.append(scenarioResult)
            if let error = scenarioResult.error {
                appendProgressLog("Scenario \(scenario.name) failed: \(error)", outputDirectory: outputDirectory)
            } else {
                appendProgressLog("Completed scenario \(scenario.name)", outputDirectory: outputDirectory)
            }
            let partialResult = OverlayAutomationResult(
                startedAt: formatter.string(from: started),
                finishedAt: formatter.string(from: Date()),
                outputDirectory: outputDirectory.path,
                scenarios: scenarioResults,
                error: nil
            )
            try? write(result: partialResult, outputDirectory: outputDirectory)
        }

        appendProgressLog("Run finished.", outputDirectory: outputDirectory)

        return OverlayAutomationResult(
            startedAt: formatter.string(from: started),
            finishedAt: formatter.string(from: Date()),
            outputDirectory: outputDirectory.path,
            scenarios: scenarioResults,
            error: nil
        )
    }

    private static func runScenario(
        _ scenario: OverlayAutomationConfig.Scenario,
        outputDirectory: URL
    ) async -> OverlayAutomationResult.ScenarioResult {
        let sharedRunner = (scenario.reuseGemmaEngine ?? false) ? GemmaTextRunner() : nil
        let result: OverlayAutomationResult.ScenarioResult
        do {
            let outputKind = ProductionWorkflowViewModel.OutputKind(rawValue: scenario.outputKind) ?? .image
            let model = ModelOption(rawValue: scenario.model) ?? .e2bLiteRT
            let modelSource = ModelSourcePreference(rawValue: scenario.modelSource) ?? .injected
            let locator = ModelLocator()
            let modelAvailability = locator.resolve(model, sourcePreference: modelSource)
            guard let modelURL = modelAvailability.url else {
                throw GemmaTextRunnerError.runtime(modelAvailability.detail)
            }

            let sourceAssets = try productionAssets(for: scenario.assetPaths)
            let scenarioDirectory = outputDirectory.appendingPathComponent(sanitizedComponent(scenario.name), isDirectory: true)
            try FileManager.default.createDirectory(at: scenarioDirectory, withIntermediateDirectories: true)
            let enableThinking = scenario.enableThinking ?? false
            let protectedRegionProvider = OverlayProtectedRegionProvider(rawValue: scenario.protectedRegionProvider ?? "") ?? .none
            let preOverlayAnalysisProvider = OverlayLayoutGuideProvider(rawValue: scenario.preOverlayAnalysisProvider ?? "") ?? .none
            let preOverlayAnalysisEnableThinking = scenario.preOverlayAnalysisEnableThinking ?? enableThinking
            let preOverlayGuidanceMode = OverlayLayoutGuidanceMode(rawValue: scenario.preOverlayGuidanceMode ?? "") ?? .slot
            let postReviewMode = OverlayPostReviewMode(rawValue: scenario.postReviewMode ?? "") ?? .none
            let layoutGuideRun: OverlayAutomationLayoutGuideRun
            if let layoutGuideOverridePath = scenario.layoutGuideOverridePath,
               !layoutGuideOverridePath.isEmpty {
                layoutGuideRun = try loadLayoutGuideOverride(from: layoutGuideOverridePath)
            } else {
                layoutGuideRun = try await makeLayoutGuide(
                    provider: preOverlayAnalysisProvider,
                    sourceAssets: sourceAssets,
                    outputKind: outputKind,
                    modelURL: modelURL,
                    enableThinking: preOverlayAnalysisEnableThinking,
                    runner: sharedRunner
                )
            }
            let layoutGuide = layoutGuideRun.guide
            try? writeLayoutGuideDiagnostics(layoutGuideRun, to: scenarioDirectory)
            let protectedRegions = layoutGuideProtectedRegions(
                from: layoutGuide,
                canvasSize: AppleMediaTooling.renderCanvasSize(for: outputKind),
                enabled: scenario.useLayoutGuideProtectedRegions ?? false
            )
            let effectiveLayoutGuide: OverlayLayoutGuide
            if scenario.useLayoutGuideProtectedRegions ?? false {
                effectiveLayoutGuide = OverlayLayoutGuidance.makeGuide(
                    provider: layoutGuide.provider == .none ? preOverlayAnalysisProvider : layoutGuide.provider,
                    protectedRegions: protectedRegions,
                    canvasSize: AppleMediaTooling.renderCanvasSize(for: outputKind)
                )
            } else {
                effectiveLayoutGuide = .empty
            }
            let basePrompt = makePrompt(
                for: scenario,
                outputKind: outputKind,
                assets: sourceAssets,
                supplementalAddendum: OverlayLayoutGuidance.promptAddendum(
                    for: layoutGuide,
                    canvasSize: AppleMediaTooling.renderCanvasSize(for: outputKind),
                    mode: preOverlayGuidanceMode
                )
            )
            if scenario.rawThinkingDiagnostic ?? false {
                let diagnosticAttempt = try await runRawThinkingDiagnosticAttempt(
                    prompt: basePrompt,
                    modelURL: modelURL,
                    sourceAssets: sourceAssets,
                    outputKind: outputKind,
                    enableThinking: enableThinking,
                    scenarioDirectory: scenarioDirectory
                )
                result = OverlayAutomationResult.ScenarioResult(
                    name: scenario.name,
                    attempts: [diagnosticAttempt],
                    error: nil
                )
                if let sharedRunner {
                    await sharedRunner.destroySession()
                }
                return result
            }
            var attempts: [OverlayAutomationResult.ScenarioResult.AttemptResult] = []

            let firstAttempt = try await runAttempt(
                index: 1,
                prompt: basePrompt,
                modelURL: modelURL,
                sourceAssets: sourceAssets,
                outputKind: outputKind,
                enableThinking: enableThinking,
                protectedRegionProvider: protectedRegionProvider,
                protectedRegions: protectedRegions,
                analysisGuide: layoutGuide,
                layoutGuideOverride: effectiveLayoutGuide,
                postReviewMode: postReviewMode,
                scenarioDirectory: scenarioDirectory,
                disableEvaluationAnalysis: scenario.disableEvaluationAnalysis ?? false,
                runner: sharedRunner
            )
            attempts.append(firstAttempt.attempt)

            if let reviewPass = scenario.reviewPass,
               reviewPass.enabled,
               let renderedURL = firstAttempt.finalURL {
                let review = try await reviewRenderedOutput(
                    renderedURL: renderedURL,
                    modelURL: modelURL,
                    enableThinking: reviewPass.enableThinking ?? true,
                    reviewPromptAddendum: reviewPass.reviewPromptAddendum
                )
                attempts[attempts.count - 1] = updated(attempts.last, with: review)

                if !review.approved,
                   (reviewPass.rerunOnFailure ?? false),
                   !review.rerunGuidance.isEmpty {
                    let revisedPrompt = """
                    \(basePrompt)

                    Second attempt after reviewing a previous output:
                    \(review.rerunGuidance)
                    """
                    let secondAttempt = try await runAttempt(
                        index: 2,
                        prompt: revisedPrompt,
                        modelURL: modelURL,
                        sourceAssets: sourceAssets,
                        outputKind: outputKind,
                        enableThinking: enableThinking,
                        protectedRegionProvider: protectedRegionProvider,
                        protectedRegions: protectedRegions,
                        analysisGuide: layoutGuide,
                        layoutGuideOverride: effectiveLayoutGuide,
                        postReviewMode: postReviewMode,
                        scenarioDirectory: scenarioDirectory,
                        disableEvaluationAnalysis: scenario.disableEvaluationAnalysis ?? false,
                        runner: sharedRunner
                    )
                    attempts.append(secondAttempt.attempt)
                }
            } else if scenario.rerunOnEvaluationOverlap ?? false,
                      needsEvaluationRerun(firstAttempt.attempt) {
                let revisedPrompt = """
                \(basePrompt)

                Second attempt after evaluating a previous render:
                The previous overlay touched or crowded the main subject. Keep the next overlay fully off the subject silhouette and its immediate margin.
                Avoid placing a sticker or headline across the subject's upper half.
                If no clean upper slot exists, switch to a lower caption or move the overlay to the cleaner side of the frame.
                Prefer measured placement over bold upper stickers when the subject is tall, central, or narrow.
                """
                let secondAttempt = try await runAttempt(
                    index: 2,
                    prompt: revisedPrompt,
                    modelURL: modelURL,
                    sourceAssets: sourceAssets,
                    outputKind: outputKind,
                    enableThinking: enableThinking,
                    protectedRegionProvider: protectedRegionProvider,
                    protectedRegions: protectedRegions,
                    analysisGuide: layoutGuide,
                    layoutGuideOverride: effectiveLayoutGuide,
                    postReviewMode: postReviewMode,
                    scenarioDirectory: scenarioDirectory,
                    disableEvaluationAnalysis: scenario.disableEvaluationAnalysis ?? false,
                    runner: sharedRunner
                )
                attempts.append(secondAttempt.attempt)
            }

            result = OverlayAutomationResult.ScenarioResult(
                name: scenario.name,
                attempts: attempts,
                error: nil
            )
        } catch {
            result = OverlayAutomationResult.ScenarioResult(
                name: scenario.name,
                attempts: [],
                error: error.localizedDescription
            )
        }
        if let sharedRunner {
            await sharedRunner.destroySession()
        }
        return result
    }

    private static func runAttempt(
        index: Int,
        prompt: String,
        modelURL: URL,
        sourceAssets: [ProductionAssetDescriptor],
        outputKind: ProductionWorkflowViewModel.OutputKind,
        enableThinking: Bool,
        protectedRegionProvider: OverlayProtectedRegionProvider,
        protectedRegions: OverlayProtectedRegions,
        analysisGuide: OverlayLayoutGuide,
        layoutGuideOverride: OverlayLayoutGuide,
        postReviewMode: OverlayPostReviewMode,
        scenarioDirectory: URL,
        disableEvaluationAnalysis: Bool,
        runner: GemmaTextRunner?
    ) async throws -> (attempt: OverlayAutomationResult.ScenarioResult.AttemptResult, finalURL: URL?) {
        let start = Date()
        let engine = GemmaToolCallingEngine(runner: runner ?? GemmaTextRunner())
        let toolResult = try await engine.run(
            initialPrompt: prompt,
            modelURL: modelURL,
            sourceAssets: sourceAssets,
            outputKind: outputKind,
            enableThinking: enableThinking,
            protectedRegionProvider: protectedRegionProvider,
            protectedRegionsOverride: protectedRegions,
            layoutGuideOverride: layoutGuideOverride,
            postReviewMode: postReviewMode
        )

        let attemptDirectory = scenarioDirectory.appendingPathComponent("attempt-\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: attemptDirectory, withIntermediateDirectories: true)
        let copiedFiles = try copyOutputs(toolResult.producedURLs, to: attemptDirectory)
        try prompt.write(to: attemptDirectory.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)
        try toolResult.finalText.write(
            to: attemptDirectory.appendingPathComponent("summary.txt"),
            atomically: true,
            encoding: .utf8
        )
        let rawResponsesData = try JSONSerialization.data(withJSONObject: toolResult.rawResponses, options: [.prettyPrinted])
        try rawResponsesData.write(to: attemptDirectory.appendingPathComponent("raw-responses.json"))
        if !toolResult.thoughtTraces.isEmpty {
            let thoughtText = toolResult.thoughtTraces.joined(separator: "\n\n---\n\n")
            try thoughtText.write(
                to: attemptDirectory.appendingPathComponent("thought-traces.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        let evaluationGuide: OverlayLayoutGuide
        if disableEvaluationAnalysis {
            evaluationGuide = .empty
        } else if let finalURL = copiedFiles.last {
            evaluationGuide = (try? await GemmaOverlayVision.analyze(
                renderedURL: finalURL,
                modelURL: modelURL,
                enableThinking: false,
                runner: runner
            )) ?? .empty
        } else {
            evaluationGuide = .empty
        }

        let attempt = OverlayAutomationResult.ScenarioResult.AttemptResult(
            attemptIndex: index,
            prompt: prompt,
            toolCalls: toolResult.toolCalls.map(toolCallRecord),
            toolResponsePayloads: toolResult.toolResponsePayloads,
            producedFiles: copiedFiles.map(\.path),
            rawResponses: toolResult.rawResponses,
            thoughtTraces: toolResult.thoughtTraces,
            summary: toolResult.finalText,
            firstOverlayStyle: firstOverlayStyle(from: toolResult.toolCalls, toolResponsePayloads: toolResult.toolResponsePayloads),
            firstOverlayTopFraction: firstOverlayTopFraction(
                from: toolResult.toolCalls,
                toolResponsePayloads: toolResult.toolResponsePayloads,
                outputKind: outputKind
            ),
            goodness: goodness(
                from: toolResult.toolCalls,
                toolResponsePayloads: toolResult.toolResponsePayloads,
                outputKind: outputKind,
                enableThinking: enableThinking,
                layoutGuide: analysisGuide,
                evaluationGuide: evaluationGuide,
                review: nil
            ),
            review: nil,
            durationSeconds: Date().timeIntervalSince(start)
        )
        return (attempt, copiedFiles.last)
    }

    private static func runRawThinkingDiagnosticAttempt(
        prompt: String,
        modelURL: URL,
        sourceAssets: [ProductionAssetDescriptor],
        outputKind: ProductionWorkflowViewModel.OutputKind,
        enableThinking: Bool,
        scenarioDirectory: URL
    ) async throws -> OverlayAutomationResult.ScenarioResult.AttemptResult {
        let start = Date()
        let runner = GemmaTextRunner()
        let tooling = AppleMediaTooling(
            sourceAssets: sourceAssets,
            outputKind: outputKind,
            protectedRegionProvider: .none
        )
        let extraContextJSON = enableThinking ? ProductionToolSchema.stringify(["enable_thinking": true]) : nil
        try await runner.makeToolSession(
            modelURL: modelURL,
            toolsJSON: ProductionToolSchema.toolsJSON,
            systemMessageJSON: nil,
            extraContextJSON: extraContextJSON
        )
        do {
            let initialMessage = try ProductionToolSchema.userMessageJSON(text: prompt, assets: sourceAssets)
            let rawResponse = try await runner.sendRawJSON(initialMessage)
            let parsed = LiteRTResponseParser.parse(rawResponse)
            var rawResponses = [rawResponse]
            var thoughtTraces = parsed.thoughtText.isEmpty ? [] : [parsed.thoughtText]
            var toolResponsePayloads: [String] = []
            var producedFiles: [String] = []
            var finalSummary = parsed.text

            if !parsed.toolCalls.isEmpty {
                var responses: [MediaToolResult] = []
                for toolCall in parsed.toolCalls {
                    responses.append(try await tooling.execute(toolCall: toolCall))
                }
                toolResponsePayloads = responses.map { ProductionToolSchema.stringify($0.payload) }
                let responseMessage = try ProductionToolSchema.toolResponseJSON(for: responses)
                let followupRawResponse = try await runner.sendRawJSON(responseMessage)
                let followupParsed = LiteRTResponseParser.parse(followupRawResponse)
                rawResponses.append(followupRawResponse)
                if !followupParsed.thoughtText.isEmpty {
                    thoughtTraces.append(followupParsed.thoughtText)
                }
                if !followupParsed.text.isEmpty {
                    finalSummary = followupParsed.text
                }

                let attemptDirectory = scenarioDirectory.appendingPathComponent("attempt-1", isDirectory: true)
                try FileManager.default.createDirectory(at: attemptDirectory, withIntermediateDirectories: true)
                let copiedOutputs = try copyOutputs(responses.compactMap(\.outputURL), to: attemptDirectory)
                producedFiles = copiedOutputs.map(\.path)
                try prompt.write(to: attemptDirectory.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)
                try finalSummary.write(to: attemptDirectory.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
                let rawResponsesData = try JSONSerialization.data(withJSONObject: rawResponses, options: [.prettyPrinted])
                try rawResponsesData.write(to: attemptDirectory.appendingPathComponent("raw-responses.json"))
                if !thoughtTraces.isEmpty {
                    let thoughtText = thoughtTraces.joined(separator: "\n\n---\n\n")
                    try thoughtText.write(
                        to: attemptDirectory.appendingPathComponent("thought-traces.txt"),
                        atomically: true,
                        encoding: .utf8
                    )
                }

                await runner.destroySession()
                return OverlayAutomationResult.ScenarioResult.AttemptResult(
                    attemptIndex: 1,
                    prompt: prompt,
                    toolCalls: parsed.toolCalls.map(toolCallRecord),
                    toolResponsePayloads: toolResponsePayloads,
                    producedFiles: producedFiles,
                    rawResponses: rawResponses,
                    thoughtTraces: thoughtTraces,
                    summary: finalSummary,
                    firstOverlayStyle: firstOverlayStyle(from: parsed.toolCalls, toolResponsePayloads: toolResponsePayloads),
                    firstOverlayTopFraction: firstOverlayTopFraction(
                        from: parsed.toolCalls,
                        toolResponsePayloads: toolResponsePayloads,
                        outputKind: outputKind
                    ),
                    goodness: .init(
                        overlayCount: parsed.toolCalls.contains(where: { isOverlayPlacementTool($0.name) }) ? 1 : 0,
                        firstOverlayWidthFraction: nil,
                        firstOverlayHeightFraction: nil,
                        subjectOverlapFraction: nil,
                        avoidanceOverlapFraction: nil,
                        analysisProvider: nil,
                        evaluationProvider: nil,
                        usedNormalizedHints: parsed.toolCalls.contains(where: { isOverlayPlacementTool($0.name) }),
                        usedSlotPlacement: parsed.toolCalls.contains(where: { isOverlayPlacementTool($0.name) }),
                        enableThinking: enableThinking,
                        heuristicScore: 0,
                        reviewOverallScore: nil,
                        reviewSubjectOverlapDetected: nil,
                        combinedScore: nil
                    ),
                    review: nil,
                    durationSeconds: Date().timeIntervalSince(start)
                )
            }

            let attemptDirectory = scenarioDirectory.appendingPathComponent("attempt-1", isDirectory: true)
            try FileManager.default.createDirectory(at: attemptDirectory, withIntermediateDirectories: true)
            try prompt.write(to: attemptDirectory.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)
            try finalSummary.write(to: attemptDirectory.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
            let rawResponsesData = try JSONSerialization.data(withJSONObject: rawResponses, options: [.prettyPrinted])
            try rawResponsesData.write(to: attemptDirectory.appendingPathComponent("raw-responses.json"))
            if !thoughtTraces.isEmpty {
                try thoughtTraces.joined(separator: "\n\n---\n\n").write(
                    to: attemptDirectory.appendingPathComponent("thought-traces.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }

            await runner.destroySession()
            return OverlayAutomationResult.ScenarioResult.AttemptResult(
                attemptIndex: 1,
                prompt: prompt,
                toolCalls: parsed.toolCalls.map(toolCallRecord),
                toolResponsePayloads: toolResponsePayloads,
                producedFiles: producedFiles,
                rawResponses: rawResponses,
                thoughtTraces: thoughtTraces,
                summary: finalSummary,
                firstOverlayStyle: nil,
                firstOverlayTopFraction: nil,
                goodness: .init(
                    overlayCount: parsed.toolCalls.contains(where: { isOverlayPlacementTool($0.name) }) ? 1 : 0,
                    firstOverlayWidthFraction: nil,
                    firstOverlayHeightFraction: nil,
                    subjectOverlapFraction: nil,
                    avoidanceOverlapFraction: nil,
                    analysisProvider: nil,
                    evaluationProvider: nil,
                    usedNormalizedHints: parsed.toolCalls.contains(where: { isOverlayPlacementTool($0.name) }),
                    usedSlotPlacement: parsed.toolCalls.contains(where: { isOverlayPlacementTool($0.name) }),
                    enableThinking: enableThinking,
                    heuristicScore: 0,
                    reviewOverallScore: nil,
                    reviewSubjectOverlapDetected: nil,
                    combinedScore: nil
                ),
                review: nil,
                durationSeconds: Date().timeIntervalSince(start)
            )
        } catch {
            await runner.destroySession()
            throw error
        }
    }

    private static func reviewRenderedOutput(
        renderedURL: URL,
        modelURL: URL,
        enableThinking: Bool,
        reviewPromptAddendum: String?
    ) async throws -> OverlayAutomationReview {
        let renderedAsset = ProductionAssetDescriptor(
            toolID: "rendered_review",
            mediaAsset: MediaAsset(
                kind: .image,
                originalURL: renderedURL,
                localCopyURL: renderedURL,
                displayName: renderedURL.lastPathComponent
            )
        )
        let reviewPrompt = """
        Review this rendered social-media visual for overlay placement and styling.
        Judge the single attached rendered output only.
        Prefer current Instagram-style placement, which usually means:
        - not in the top app-chrome band
        - upper-middle sticker/headline placement around 18% to 35% from the top when the overlay is punchy
        - lower-middle caption placement around 45% to 60% from the top when the image has more open scenery
        - varied overlay dimensions instead of a repeated uniform banner

        Be strict about rejecting overlays that feel like old top banners, oversized generic rectangles, or subject-obscuring placements.
        If any part of the overlay text or overlay background in the rendered image touches the main subject's visible silhouette or a very tight safety margin around it, treat that as a hard failure: approved=false, subject_overlap_detected=true, and placement_score=0.
        Treat even partial overlap on the subject's face, head, torso, or primary silhouette as a failure.
        Score the output from 0 to 100 for overall quality, placement, style/shape, and copy fitness.
        Return concise rerun guidance that tells the generator how to improve the next attempt while keeping the text grounded in what is visible.

        \(reviewPromptAddendum?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        """

        let runner = GemmaTextRunner()
        let extraContextJSON = enableThinking ? ProductionToolSchema.stringify(["enable_thinking": true]) : nil
        try await runner.makeToolSession(
            modelURL: modelURL,
            toolsJSON: OverlayReviewToolSchema.toolsJSON,
            systemMessageJSON: nil,
            extraContextJSON: extraContextJSON
        )
        do {
            let parsed = try await runner.sendJSON(
                ProductionToolSchema.userMessageJSON(text: reviewPrompt, assets: [renderedAsset])
            )
            await runner.destroySession()
            return OverlayReviewToolSchema.extract(from: parsed)
        } catch {
            await runner.destroySession()
            throw error
        }
    }

    private static func productionAssets(for assetPaths: [String]) throws -> [ProductionAssetDescriptor] {
        try assetPaths.enumerated().map { index, rawPath in
            let url = resolvedURL(for: rawPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw GemmaTextRunnerError.runtime("Missing automation asset at \(url.path).")
            }
            let asset = MediaAsset(
                kind: MediaAsset.kind(for: url),
                originalURL: url,
                localCopyURL: url,
                displayName: url.lastPathComponent
            )
            return ProductionAssetDescriptor(toolID: "asset_\(index + 1)", mediaAsset: asset)
        }
    }

    private static func makeLayoutGuide(
        provider: OverlayLayoutGuideProvider,
        sourceAssets: [ProductionAssetDescriptor],
        outputKind: ProductionWorkflowViewModel.OutputKind,
        modelURL: URL,
        enableThinking: Bool,
        runner: GemmaTextRunner?
    ) async throws -> OverlayAutomationLayoutGuideRun {
        guard provider != .none else {
            return OverlayAutomationLayoutGuideRun(
                guide: .empty,
                prompt: nil,
                rawResponses: [],
                thoughtTraces: []
            )
        }

        let tooling = AppleMediaTooling(
            sourceAssets: sourceAssets,
            outputKind: outputKind,
            protectedRegionProvider: .none
        )
        let composeResult = try await tooling.execute(
            toolCall: LiteRTToolCall(
                name: "compose_visuals",
                arguments: [
                    "asset_ids": .array(sourceAssets.map { .string($0.toolID) })
                ]
            )
        )
        guard let renderedURL = composeResult.outputURL else {
            throw GemmaTextRunnerError.runtime("Unable to prepare a base render for layout analysis.")
        }

        let canvasSize = AppleMediaTooling.renderCanvasSize(for: outputKind)
        switch provider {
        case .appleVision:
            #if canImport(UIKit)
            guard let image = UIImage(contentsOfFile: renderedURL.path) else {
                throw GemmaTextRunnerError.runtime("Unable to load rendered preview for Apple Vision analysis.")
            }
            let protectedRegions = OverlaySubjectAnalysis.protectedRegions(for: image, canvasSize: canvasSize)
            return OverlayAutomationLayoutGuideRun(
                guide: OverlayLayoutGuidance.makeGuide(
                    provider: .appleVision,
                    protectedRegions: protectedRegions,
                    canvasSize: canvasSize
                ),
                prompt: nil,
                rawResponses: [],
                thoughtTraces: []
            )
            #else
            return OverlayAutomationLayoutGuideRun(
                guide: .empty,
                prompt: nil,
                rawResponses: [],
                thoughtTraces: []
            )
            #endif
        case .gemmaVision:
            let analysis = try await GemmaOverlayVision.analyzeDetailed(
                renderedURL: renderedURL,
                modelURL: modelURL,
                enableThinking: enableThinking,
                runner: runner
            )
            return OverlayAutomationLayoutGuideRun(
                guide: analysis.guide,
                prompt: analysis.prompt,
                rawResponses: analysis.rawResponses,
                thoughtTraces: analysis.thoughtTraces
            )
        case .none:
            return OverlayAutomationLayoutGuideRun(
                guide: .empty,
                prompt: nil,
                rawResponses: [],
                thoughtTraces: []
            )
        }
    }

    private static func writeLayoutGuideDiagnostics(
        _ run: OverlayAutomationLayoutGuideRun,
        to scenarioDirectory: URL
    ) throws {
        let diagnosticsDirectory = scenarioDirectory.appendingPathComponent("pre-analysis", isDirectory: true)
        try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)

        if let prompt = run.prompt, !prompt.isEmpty {
            try prompt.write(
                to: diagnosticsDirectory.appendingPathComponent("prompt.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        if !run.rawResponses.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: run.rawResponses, options: [.prettyPrinted])
            try data.write(to: diagnosticsDirectory.appendingPathComponent("raw-responses.json"))
        }

        if !run.thoughtTraces.isEmpty {
            try run.thoughtTraces.joined(separator: "\n\n---\n\n").write(
                to: diagnosticsDirectory.appendingPathComponent("thought-traces.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let guideJSON: [String: Any] = [
            "provider": run.guide.provider.rawValue,
            "subject_rect": rectJSON(run.guide.subjectRect) ?? NSNull(),
            "subject_confidence": run.guide.subjectConfidence ?? NSNull(),
            "slot_rect": rectJSON(run.guide.slotRect) ?? NSNull(),
            "slot_confidence": run.guide.slotConfidence ?? NSNull(),
            "recommended_style": run.guide.recommendedStyle?.rawValue ?? NSNull(),
            "recommended_top_fraction": run.guide.recommendedTopFraction ?? NSNull(),
            "recommended_max_width_fraction": run.guide.recommendedMaxWidthFraction ?? NSNull(),
            "recommended_target_line_count": run.guide.recommendedTargetLineCount ?? NSNull(),
            "horizontal_anchor": run.guide.horizontalAnchor?.rawValue ?? NSNull(),
            "vertical_anchor": run.guide.verticalAnchor?.rawValue ?? NSNull(),
            "notes": run.guide.notes
        ]
        let guideData = try JSONSerialization.data(withJSONObject: guideJSON, options: [.prettyPrinted])
        try guideData.write(to: diagnosticsDirectory.appendingPathComponent("guide.json"))
    }

    private static func rectJSON(_ rect: CGRect?) -> [String: Double]? {
        guard let rect, !rect.isNull, !rect.isEmpty else {
            return nil
        }
        return [
            "x": Double(rect.minX),
            "y": Double(rect.minY),
            "width": Double(rect.width),
            "height": Double(rect.height)
        ]
    }

    private static func loadLayoutGuideOverride(from rawPath: String) throws -> OverlayAutomationLayoutGuideRun {
        let url = resolvedURL(for: rawPath)
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GemmaTextRunnerError.runtime("Invalid layout guide override at \(url.path).")
        }
        let provider = (object["provider"] as? String).flatMap(OverlayLayoutGuideProvider.init(rawValue:)) ?? .none
        let guide = OverlayLayoutGuide(
            provider: provider,
            subjectRect: rect(from: object["subject_rect"]),
            subjectConfidence: object["subject_confidence"] as? Double,
            slotRect: rect(from: object["slot_rect"]),
            slotConfidence: object["slot_confidence"] as? Double,
            recommendedStyle: (object["recommended_style"] as? String).flatMap(OverlayStyle.init(rawValue:)),
            recommendedTopFraction: object["recommended_top_fraction"] as? Double,
            recommendedMaxWidthFraction: object["recommended_max_width_fraction"] as? Double,
            recommendedTargetLineCount: object["recommended_target_line_count"] as? Int,
            horizontalAnchor: (object["horizontal_anchor"] as? String).flatMap(OverlayHorizontalAnchor.init(rawValue:)),
            verticalAnchor: (object["vertical_anchor"] as? String).flatMap(OverlayVerticalAnchor.init(rawValue:)),
            notes: object["notes"] as? String ?? ""
        )
        return OverlayAutomationLayoutGuideRun(
            guide: guide,
            prompt: nil,
            rawResponses: [],
            thoughtTraces: []
        )
    }

    private static func rect(from rawValue: Any?) -> CGRect? {
        guard let rawValue = rawValue as? [String: Any],
              let x = rawValue["x"] as? Double,
              let y = rawValue["y"] as? Double,
              let width = rawValue["width"] as? Double,
              let height = rawValue["height"] as? Double,
              width > 0,
              height > 0 else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height).integral
    }

    private static func makePrompt(
        for scenario: OverlayAutomationConfig.Scenario,
        outputKind: ProductionWorkflowViewModel.OutputKind,
        assets: [ProductionAssetDescriptor],
        supplementalAddendum: String?
    ) -> String {
        let basePrompt = ProductionPrompts.productionPrompt(
            backgroundBriefing: scenario.backgroundBriefing,
            story: scenario.story,
            outputKind: outputKind,
            assets: assets,
            canvasSize: AppleMediaTooling.renderCanvasSize(for: outputKind)
        )
        let addenda: [String] = [
            scenario.promptAddendum?.trimmingCharacters(in: .whitespacesAndNewlines),
            supplementalAddendum?.trimmingCharacters(in: .whitespacesAndNewlines)
        ].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }

        guard !addenda.isEmpty else { return basePrompt }
        return "\(basePrompt)\n\nAdditional experiment guidance:\n\(addenda.joined(separator: "\n\n"))"
    }

    private static func copyOutputs(_ urls: [URL], to directory: URL) throws -> [URL] {
        try urls.enumerated().map { index, sourceURL in
            let destinationURL = directory.appendingPathComponent("output-\(index + 1).\(sourceURL.pathExtension)")
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        }
    }

    private static func toolCallRecord(_ toolCall: LiteRTToolCall) -> OverlayAutomationResult.ScenarioResult.AttemptResult.ToolCallRecord {
        OverlayAutomationResult.ScenarioResult.AttemptResult.ToolCallRecord(
            name: toolCall.name,
            arguments: toolCall.arguments.mapValues(\.description)
        )
    }

    private static func firstOverlayStyle(from toolCalls: [LiteRTToolCall], toolResponsePayloads: [String]) -> String? {
        if let style = finalOverlayPayload(from: toolResponsePayloads)?["style"] as? String {
            return style
        }
        return toolCalls.last(where: { isOverlayPlacementTool($0.name) })?.arguments["style"]?.stringValue ?? "auto"
    }

    private static func firstOverlayTopFraction(
        from toolCalls: [LiteRTToolCall],
        toolResponsePayloads: [String],
        outputKind: ProductionWorkflowViewModel.OutputKind
    ) -> Double? {
        if let resolvedTopFraction = finalOverlayPayload(from: toolResponsePayloads)?["resolved_top_fraction"] as? Double {
            return resolvedTopFraction
        }

        guard let toolCall = toolCalls.last(where: { isOverlayPlacementTool($0.name) }) else {
            return nil
        }

        if let topFraction = toolCall.arguments["top_fraction"]?.numberValue {
            return topFraction
        }

        guard let y = toolCall.arguments["y"]?.numberValue else { return nil }
        let canvasHeight = AppleMediaTooling.renderCanvasSize(for: outputKind).height
        guard canvasHeight > 0 else { return nil }
        return y / canvasHeight
    }

    private static func goodness(
        from toolCalls: [LiteRTToolCall],
        toolResponsePayloads: [String],
        outputKind: ProductionWorkflowViewModel.OutputKind,
        enableThinking: Bool,
        layoutGuide: OverlayLayoutGuide,
        evaluationGuide: OverlayLayoutGuide,
        review: OverlayAutomationReview?
    ) -> OverlayAutomationResult.ScenarioResult.AttemptResult.Goodness {
        let overlayCalls = toolCalls.filter { $0.name == "add_text_overlay" }
        let overlayPlacementCalls = toolCalls.filter { isOverlayPlacementTool($0.name) }
        let firstPayload = finalOverlayPayload(from: toolResponsePayloads)
        let style = firstOverlayStyle(from: toolCalls, toolResponsePayloads: toolResponsePayloads)
        let topFraction = firstOverlayTopFraction(
            from: toolCalls,
            toolResponsePayloads: toolResponsePayloads,
            outputKind: outputKind
        )
        let overlayRect = firstOverlayRect(from: toolResponsePayloads)
        let widthFraction = firstPayload?["resolved_width_fraction"] as? Double
        let heightFraction = firstPayload?["resolved_height_fraction"] as? Double
        let canvasSize = AppleMediaTooling.renderCanvasSize(for: outputKind)
        let gradingGuide = evaluationGuide.subjectRect != nil ? evaluationGuide : layoutGuide
        let analysisSubjectOverlap = overlayRect.flatMap { OverlayLayoutGuidance.overlapFraction(overlayRect: $0, subjectRect: gradingGuide.subjectRect) }
        let avoidanceSubjectRect = gradingGuide.subjectRect.map {
            $0.insetBy(dx: -(canvasSize.width * 0.04), dy: -(canvasSize.height * 0.035))
        }
        let analysisAvoidanceOverlap = overlayRect.flatMap { OverlayLayoutGuidance.overlapFraction(overlayRect: $0, subjectRect: avoidanceSubjectRect) }
        let subjectOverlapFraction = analysisSubjectOverlap ?? firstPayload?["subject_overlap_fraction"] as? Double
        let avoidanceOverlapFraction = analysisAvoidanceOverlap ?? firstPayload?["avoidance_overlap_fraction"] as? Double
        let usedNormalizedHints = overlayPlacementCalls.contains { toolCall in
            toolCall.arguments["top_fraction"] != nil ||
            toolCall.arguments["max_width_fraction"] != nil ||
            toolCall.arguments["target_line_count"] != nil
        }
        let usedSlotPlacement = overlayPlacementCalls.contains { toolCall in
            toolCall.arguments["vertical_anchor"] != nil ||
            (toolCall.arguments["x"]?.numberValue ?? 0) > 0 &&
            (toolCall.arguments["y"]?.numberValue ?? 0) > 0 &&
            (toolCall.arguments["width"]?.numberValue ?? 0) > 0 &&
            (toolCall.arguments["height"]?.numberValue ?? 0) > 0 &&
            (toolCall.arguments["horizontal_anchor"] != nil || toolCall.arguments["vertical_anchor"] != nil)
        }
        let heuristicScore = heuristicScore(
            overlayCount: overlayCalls.count,
            style: style,
            topFraction: topFraction,
            widthFraction: widthFraction,
            heightFraction: heightFraction,
            overlayRect: overlayRect,
            subjectRect: gradingGuide.subjectRect,
            canvasSize: canvasSize,
            subjectOverlapFraction: subjectOverlapFraction,
            avoidanceOverlapFraction: avoidanceOverlapFraction,
            usedNormalizedHints: usedNormalizedHints,
            usedSlotPlacement: usedSlotPlacement
        )
        let reviewOverallScore = review?.overallScore
        let combinedScore: Double
        if (subjectOverlapFraction ?? 0) > 0.01 ||
            (avoidanceOverlapFraction ?? 0) > 0.18 ||
            review?.subjectOverlapDetected == true {
            combinedScore = 0
        } else {
            combinedScore = reviewOverallScore.map { round(((heuristicScore + $0) / 2) * 10) / 10 } ?? heuristicScore
        }

        return .init(
            overlayCount: overlayCalls.count,
            firstOverlayWidthFraction: widthFraction,
            firstOverlayHeightFraction: heightFraction,
            subjectOverlapFraction: subjectOverlapFraction,
            avoidanceOverlapFraction: avoidanceOverlapFraction,
            analysisProvider: layoutGuide.provider == .none ? nil : layoutGuide.provider.rawValue,
            evaluationProvider: gradingGuide.provider == .none ? nil : gradingGuide.provider.rawValue,
            usedNormalizedHints: usedNormalizedHints,
            usedSlotPlacement: usedSlotPlacement,
            enableThinking: enableThinking,
            heuristicScore: heuristicScore,
            reviewOverallScore: reviewOverallScore,
            reviewSubjectOverlapDetected: review?.subjectOverlapDetected,
            combinedScore: combinedScore
        )
    }

    private static func layoutGuideProtectedRegions(
        from guide: OverlayLayoutGuide,
        canvasSize: CGSize,
        enabled: Bool
    ) -> OverlayProtectedRegions {
        guard enabled else { return .empty }
        return OverlayLayoutGuidance.protectedRegions(from: guide, canvasSize: canvasSize)
    }

    private static func needsEvaluationRerun(_ attempt: OverlayAutomationResult.ScenarioResult.AttemptResult) -> Bool {
        (attempt.goodness.subjectOverlapFraction ?? 0) > 0.01 ||
        (attempt.goodness.avoidanceOverlapFraction ?? 0) > 0.18 ||
        (attempt.goodness.combinedScore ?? attempt.goodness.heuristicScore) <= 0
    }

    private static func heuristicScore(
        overlayCount: Int,
        style: String?,
        topFraction: Double?,
        widthFraction: Double?,
        heightFraction: Double?,
        overlayRect: CGRect?,
        subjectRect: CGRect?,
        canvasSize: CGSize,
        subjectOverlapFraction: Double?,
        avoidanceOverlapFraction: Double?,
        usedNormalizedHints: Bool,
        usedSlotPlacement: Bool
    ) -> Double {
        guard overlayCount > 0 else { return 25 }

        if let subjectOverlapFraction, subjectOverlapFraction > 0.01 {
            return 0
        }

        var score = 35.0
        if overlayCount == 1 {
            score += 20
        } else {
            score -= Double(overlayCount - 1) * 18
        }

        switch style {
        case "caption":
            score += bandScore(value: topFraction, ideal: 0.45...0.60, acceptable: 0.40...0.66, strongBonus: 25, softBonus: 12, missPenalty: 12)
            score += bandScore(value: widthFraction, ideal: 0.28...0.72, acceptable: 0.22...0.78, strongBonus: 18, softBonus: 8, missPenalty: 10)
            score += bandScore(value: heightFraction, ideal: 0.04...0.16, acceptable: 0.03...0.20, strongBonus: 8, softBonus: 4, missPenalty: 6)
        case "tag":
            score += bandScore(value: topFraction, ideal: 0.18...0.40, acceptable: 0.14...0.48, strongBonus: 20, softBonus: 10, missPenalty: 10)
            score += bandScore(value: widthFraction, ideal: 0.16...0.40, acceptable: 0.12...0.48, strongBonus: 18, softBonus: 8, missPenalty: 10)
            score += bandScore(value: heightFraction, ideal: 0.03...0.12, acceptable: 0.02...0.16, strongBonus: 8, softBonus: 4, missPenalty: 6)
        default:
            score += bandScore(value: topFraction, ideal: 0.18...0.35, acceptable: 0.14...0.42, strongBonus: 25, softBonus: 12, missPenalty: 12)
            score += bandScore(value: widthFraction, ideal: 0.30...0.70, acceptable: 0.24...0.78, strongBonus: 18, softBonus: 8, missPenalty: 10)
            score += bandScore(value: heightFraction, ideal: 0.06...0.22, acceptable: 0.04...0.26, strongBonus: 8, softBonus: 4, missPenalty: 6)
        }

        if let widthFraction, widthFraction > 0.82 {
            score -= 20
        }
        if let avoidanceOverlapFraction, avoidanceOverlapFraction > 0.01 {
            score -= min(45, avoidanceOverlapFraction * 180)
        }
        if let overlayRect,
           let subjectRect,
           canvasSize.width > 0,
           canvasSize.height > 0 {
            let subjectCenterXFraction = subjectRect.midX / canvasSize.width
            let subjectHeightFraction = subjectRect.height / canvasSize.height
            let horizontalGap = max(subjectRect.minX - overlayRect.maxX, overlayRect.minX - subjectRect.maxX, 0)
            let horizontalGapFraction = horizontalGap / canvasSize.width
            let verticalOverlap = max(0, min(subjectRect.maxY, overlayRect.maxY) - max(subjectRect.minY, overlayRect.minY))

            if (0.35...0.65).contains(subjectCenterXFraction),
               subjectHeightFraction > 0.35 {
                if let topFraction, topFraction < 0.45 {
                    score -= 25
                }
                if verticalOverlap > 0, horizontalGapFraction < 0.08 {
                    score -= 35
                }
            }
        }
        if usedNormalizedHints {
            score += 8
        }
        if usedSlotPlacement {
            score += 8
        }

        return min(max(round(score * 10) / 10, 0), 100)
    }

    private static func bandScore(
        value: Double?,
        ideal: ClosedRange<Double>,
        acceptable: ClosedRange<Double>,
        strongBonus: Double,
        softBonus: Double,
        missPenalty: Double
    ) -> Double {
        guard let value else { return 0 }
        if ideal.contains(value) {
            return strongBonus
        }
        if acceptable.contains(value) {
            return softBonus
        }
        return -missPenalty
    }

    private static func finalOverlayPayload(from toolResponsePayloads: [String]) -> [String: Any]? {
        toolResponsePayloads
            .compactMap(payloadDictionary)
            .last(where: { $0["style"] != nil && $0["resolved_top_fraction"] != nil })
    }

    private static func firstOverlayRect(from toolResponsePayloads: [String]) -> CGRect? {
        guard let payload = finalOverlayPayload(from: toolResponsePayloads),
              let x = payload["x"] as? Int,
              let y = payload["y"] as? Int,
              let width = payload["overlay_width"] as? Int,
              let height = payload["overlay_height"] as? Int,
              width > 0,
              height > 0 else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func payloadDictionary(from payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private static func isOverlayPlacementTool(_ name: String) -> Bool {
        name == "add_text_overlay" || name == "move_text_overlay"
    }

    private static func updated(
        _ attempt: OverlayAutomationResult.ScenarioResult.AttemptResult?,
        with review: OverlayAutomationReview
    ) -> OverlayAutomationResult.ScenarioResult.AttemptResult {
        guard let attempt else {
            return OverlayAutomationResult.ScenarioResult.AttemptResult(
                attemptIndex: 0,
                prompt: "",
                toolCalls: [],
                toolResponsePayloads: [],
                producedFiles: [],
                rawResponses: [],
                thoughtTraces: [],
                summary: "",
                firstOverlayStyle: nil,
                firstOverlayTopFraction: nil,
                goodness: .init(
                    overlayCount: 0,
                    firstOverlayWidthFraction: nil,
                    firstOverlayHeightFraction: nil,
                    subjectOverlapFraction: nil,
                    avoidanceOverlapFraction: nil,
                    analysisProvider: nil,
                    evaluationProvider: nil,
                    usedNormalizedHints: false,
                    usedSlotPlacement: false,
                    enableThinking: false,
                    heuristicScore: 0,
                    reviewOverallScore: review.overallScore,
                    reviewSubjectOverlapDetected: review.subjectOverlapDetected,
                    combinedScore: review.subjectOverlapDetected ? 0 : review.overallScore
                ),
                review: .init(
                    approved: review.approved,
                    critique: review.critique,
                    rerunGuidance: review.rerunGuidance,
                    subjectOverlapDetected: review.subjectOverlapDetected,
                    overallScore: review.overallScore,
                    placementScore: review.placementScore,
                    styleScore: review.styleScore,
                    copyScore: review.copyScore
                ),
                durationSeconds: 0
            )
        }

        return OverlayAutomationResult.ScenarioResult.AttemptResult(
            attemptIndex: attempt.attemptIndex,
            prompt: attempt.prompt,
            toolCalls: attempt.toolCalls,
            toolResponsePayloads: attempt.toolResponsePayloads,
            producedFiles: attempt.producedFiles,
            rawResponses: attempt.rawResponses,
            thoughtTraces: attempt.thoughtTraces,
            summary: attempt.summary,
            firstOverlayStyle: attempt.firstOverlayStyle,
            firstOverlayTopFraction: attempt.firstOverlayTopFraction,
            goodness: .init(
                overlayCount: attempt.goodness.overlayCount,
                firstOverlayWidthFraction: attempt.goodness.firstOverlayWidthFraction,
                firstOverlayHeightFraction: attempt.goodness.firstOverlayHeightFraction,
                subjectOverlapFraction: attempt.goodness.subjectOverlapFraction,
                avoidanceOverlapFraction: attempt.goodness.avoidanceOverlapFraction,
                analysisProvider: attempt.goodness.analysisProvider,
                evaluationProvider: attempt.goodness.evaluationProvider,
                usedNormalizedHints: attempt.goodness.usedNormalizedHints,
                usedSlotPlacement: attempt.goodness.usedSlotPlacement,
                enableThinking: attempt.goodness.enableThinking,
                heuristicScore: attempt.goodness.heuristicScore,
                reviewOverallScore: review.overallScore,
                reviewSubjectOverlapDetected: review.subjectOverlapDetected,
                combinedScore: review.subjectOverlapDetected ? 0 : round(((attempt.goodness.heuristicScore + review.overallScore) / 2) * 10) / 10
            ),
            review: .init(
                approved: review.approved,
                critique: review.critique,
                rerunGuidance: review.rerunGuidance,
                subjectOverlapDetected: review.subjectOverlapDetected,
                overallScore: review.overallScore,
                placementScore: review.placementScore,
                styleScore: review.styleScore,
                copyScore: review.copyScore
            ),
            durationSeconds: attempt.durationSeconds
        )
    }

    private static func write(result: OverlayAutomationResult, outputDirectory: URL) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let resultURL = outputDirectory.appendingPathComponent("results.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(result)
        try data.write(to: resultURL, options: .atomic)
        try writeScoreboard(result: result, outputDirectory: outputDirectory)
    }

    private static func appendProgressLog(_ message: String, outputDirectory: URL) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let logURL = outputDirectory.appendingPathComponent("progress.log")
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    private static func writeScoreboard(result: OverlayAutomationResult, outputDirectory: URL) throws {
        struct Row {
            let scenario: String
            let attempt: Int
            let combined: Double
            let heuristic: Double
            let review: Double?
            let approved: Bool?
            let overlays: Int
            let style: String?
            let top: Double?
            let width: Double?
            let height: Double?
            let subjectOverlap: Double?
            let avoidanceOverlap: Double?
            let analysisProvider: String?
            let evaluationProvider: String?
            let thinking: Bool
            let normalized: Bool
            let slot: Bool
            let reviewSubjectOverlapDetected: Bool?
        }

        let rows = result.scenarios.flatMap { scenario in
            scenario.attempts.map { attempt in
                Row(
                    scenario: scenario.name,
                    attempt: attempt.attemptIndex,
                    combined: attempt.goodness.combinedScore ?? attempt.goodness.heuristicScore,
                    heuristic: attempt.goodness.heuristicScore,
                    review: attempt.goodness.reviewOverallScore,
                    approved: attempt.review?.approved,
                    overlays: attempt.goodness.overlayCount,
                    style: attempt.firstOverlayStyle,
                    top: attempt.firstOverlayTopFraction,
                    width: attempt.goodness.firstOverlayWidthFraction,
                    height: attempt.goodness.firstOverlayHeightFraction,
                    subjectOverlap: attempt.goodness.subjectOverlapFraction,
                    avoidanceOverlap: attempt.goodness.avoidanceOverlapFraction,
                    analysisProvider: attempt.goodness.analysisProvider,
                    evaluationProvider: attempt.goodness.evaluationProvider,
                    thinking: attempt.goodness.enableThinking,
                    normalized: attempt.goodness.usedNormalizedHints,
                    slot: attempt.goodness.usedSlotPlacement,
                    reviewSubjectOverlapDetected: attempt.goodness.reviewSubjectOverlapDetected
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.combined == rhs.combined {
                return lhs.scenario < rhs.scenario
            }
            return lhs.combined > rhs.combined
        }

        let header = "scenario\tattempt\tcombined_score\theuristic_score\treview_score\tapproved\toverlays\tstyle\ttop_fraction\twidth_fraction\theight_fraction\tsubject_overlap_fraction\tavoidance_overlap_fraction\tanalysis_provider\tevaluation_provider\treview_subject_overlap_detected\tthinking\tnormalized_hints\tslot_placement"
        let lines = rows.map { row in
            [
                row.scenario,
                String(row.attempt),
                format(row.combined),
                format(row.heuristic),
                format(row.review),
                row.approved.map(String.init) ?? "",
                String(row.overlays),
                row.style ?? "",
                format(row.top),
                format(row.width),
                format(row.height),
                format(row.subjectOverlap),
                format(row.avoidanceOverlap),
                row.analysisProvider ?? "",
                row.evaluationProvider ?? "",
                row.reviewSubjectOverlapDetected.map { $0 ? "true" : "false" } ?? "",
                row.thinking ? "true" : "false",
                row.normalized ? "true" : "false",
                row.slot ? "true" : "false"
            ].joined(separator: "\t")
        }
        let scoreboard = ([header] + lines).joined(separator: "\n") + "\n"
        try scoreboard.write(
            to: outputDirectory.appendingPathComponent("scoreboard.tsv"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.1f", value)
    }

    private static func resolvedURL(for path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(path, isDirectory: false)
    }

    private static func sanitizedComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let string = String(mapped)
        return string.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func terminate(exitCode: Int32) {
        #if canImport(UIKit)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            exit(exitCode)
        }
        #else
        exit(exitCode)
        #endif
    }
}

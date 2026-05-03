import CoreGraphics
import Foundation

enum GoogleAIStudioOverlayVision {
    static func analyzeDetailed(
        renderedURL: URL,
        model: CloudModelOption,
        apiKey: String
    ) async throws -> GemmaOverlayVisionAnalysis {
        let renderedAsset = ProductionAssetDescriptor(
            toolID: "analysis_asset",
            mediaAsset: MediaAsset(
                kind: .image,
                originalURL: renderedURL,
                localCopyURL: renderedURL,
                displayName: renderedURL.lastPathComponent
            )
        )
        let canvasSize = OverlayLayoutGuidance.canvasSize(for: renderedURL) ?? AppleMediaTooling.imageCanvasSize
        let prompt = """
        Analyze this rendered social-media frame for overlay placement.
        The canvas is \(Int(canvasSize.width))x\(Int(canvasSize.height)) pixels. Return all coordinates as pixel values in this rendered canvas.
        Identify the main subject or subject cluster that should stay unobscured by overlay text or a sticker.
        Return one conservative subject keep-clear box that covers the full visible subject silhouette plus breathing room. If you are unsure, make the keep-clear box larger, not smaller.
        Prefer sticker for busy subject-dominant frames, caption for real negative space, headline only when a single line can stay legible without a box, and tag only for an actual handle or label.
        You may optionally return one coarse free-space patch if it is obvious, but subject protection matters more than patch precision.
        If there is no truly clean patch, omit the slot fields or return a very low slot_confidence and explain the compromise in notes.
        Call \(OverlayGuideToolSchema.toolName) with the overlay placement guide.
        """

        let client = GoogleAIStudioClient(apiKey: apiKey)
        let fileReferences = try await uploadCloudFiles([renderedAsset], using: client)
        defer {
            Task {
                await deleteCloudFiles(fileReferences, using: client)
            }
        }
        let response = try await client.sendGenerateContent(
            model: model,
            contents: GoogleAIStudioContents(value: [
                try GoogleAIStudioMessageFactory.userMessage(
                    text: prompt,
                    assets: [renderedAsset],
                    fileReferences: fileReferences
                )
            ]),
            toolsJSON: OverlayGuideToolSchema.toolsJSON,
            toolConfig: .constrainedToAllowedFunctions([OverlayGuideToolSchema.toolName])
        )
        let parsed = response.parsedMessage
        var guide = OverlayGuideToolSchema.extract(from: parsed, fallbackText: parsed.text)

        if shouldApplyFallback(to: guide, canvasSize: canvasSize) {
            let fallbackGuide = OverlayLayoutGuidance.makeGuide(
                provider: .gemmaVision,
                protectedRegions: OverlayProtectedRegions(
                    subjectRects: guide.subjectRect.map { [$0] } ?? [],
                    avoidanceRects: guide.subjectRect.map { [$0.insetBy(dx: -24, dy: -24)] } ?? []
                ),
                canvasSize: canvasSize
            )
            guide = OverlayLayoutGuide(
                provider: .gemmaVision,
                subjectRect: guide.subjectRect ?? fallbackGuide.subjectRect,
                subjectConfidence: guide.subjectConfidence ?? fallbackGuide.subjectConfidence,
                slotRect: guide.slotRect ?? fallbackGuide.slotRect,
                slotConfidence: guide.slotConfidence ?? fallbackGuide.slotConfidence,
                recommendedStyle: guide.recommendedStyle ?? fallbackGuide.recommendedStyle,
                recommendedTopFraction: guide.recommendedTopFraction ?? fallbackGuide.recommendedTopFraction,
                recommendedMaxWidthFraction: guide.recommendedMaxWidthFraction ?? fallbackGuide.recommendedMaxWidthFraction,
                recommendedTargetLineCount: guide.recommendedTargetLineCount ?? fallbackGuide.recommendedTargetLineCount,
                horizontalAnchor: guide.horizontalAnchor ?? fallbackGuide.horizontalAnchor,
                verticalAnchor: guide.verticalAnchor ?? fallbackGuide.verticalAnchor,
                notes: guide.notes.isEmpty ? fallbackGuide.notes : guide.notes
            )
        }

        return GemmaOverlayVisionAnalysis(
            prompt: prompt,
            guide: guide,
            rawResponses: [response.rawResponseJSON],
            thoughtTraces: parsed.thoughtText.isEmpty ? [] : [parsed.thoughtText]
        )
    }

    private static func shouldApplyFallback(to guide: OverlayLayoutGuide, canvasSize: CGSize) -> Bool {
        if guide.slotRect == nil || guide.recommendedStyle == nil {
            return true
        }
        guard let slotRect = guide.slotRect else {
            return true
        }
        if let subjectRect = guide.subjectRect,
           let overlap = OverlayLayoutGuidance.overlapFraction(overlayRect: slotRect, subjectRect: subjectRect),
           overlap > 0.08 {
            return true
        }
        if let slotConfidence = guide.slotConfidence, slotConfidence < 40 {
            return true
        }
        return slotRect.width <= 0 || slotRect.height <= 0 || canvasSize.width <= 0 || canvasSize.height <= 0
    }

    private static func uploadCloudFiles(
        _ assets: [ProductionAssetDescriptor],
        using client: GoogleAIStudioClient
    ) async throws -> [String: GoogleAIStudioFileReference] {
        var fileReferences: [String: GoogleAIStudioFileReference] = [:]
        do {
            for asset in assets {
                try Task.checkCancellation()
                guard let uploadFile = try PromptMediaEncoder.promptUploadFile(for: asset.mediaAsset) else {
                    continue
                }
                fileReferences[asset.toolID] = try await client.uploadFile(uploadFile)
            }
            return fileReferences
        } catch {
            await deleteCloudFiles(fileReferences, using: client)
            throw error
        }
    }

    private static func deleteCloudFiles(
        _ fileReferences: [String: GoogleAIStudioFileReference],
        using client: GoogleAIStudioClient
    ) async {
        for fileReference in fileReferences.values {
            await client.deleteFile(fileReference)
        }
    }
}

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
        Return only one JSON object with these keys when known: subject_x, subject_y, subject_width, subject_height, subject_confidence, slot_x, slot_y, slot_width, slot_height, slot_confidence, recommended_style, recommended_top_fraction, recommended_max_width_fraction, recommended_target_line_count, horizontal_anchor, vertical_anchor, notes.
        Do not include markdown fences, bullet points, or explanatory prose outside the JSON object.
        """

        let client = GoogleAIStudioClient(apiKey: apiKey)
        let response = try await client.sendGenerateContent(
            model: model,
            contents: GoogleAIStudioContents(value: [
                try GoogleAIStudioMessageFactory.userMessage(text: prompt, assets: [renderedAsset])
            ])
        )
        let rawResponse = response.parsedMessage.rawJSON
        let parsed = response.parsedMessage
        var guide = extractGuide(from: parsed.text)

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
            rawResponses: [rawResponse],
            thoughtTraces: []
        )
    }

    private static func extractGuide(from text: String) -> OverlayLayoutGuide {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let object = parseJSONObject(from: trimmed) else {
            return .empty
        }

        let arguments = GoogleAIStudioResponseParser.toolArguments(from: object)
        let subjectRect = rect(
            x: arguments["subject_x"]?.numberValue,
            y: arguments["subject_y"]?.numberValue,
            width: arguments["subject_width"]?.numberValue,
            height: arguments["subject_height"]?.numberValue
        )
        let slotRect = rect(
            x: arguments["slot_x"]?.numberValue,
            y: arguments["slot_y"]?.numberValue,
            width: arguments["slot_width"]?.numberValue,
            height: arguments["slot_height"]?.numberValue
        )

        return OverlayLayoutGuide(
            provider: .gemmaVision,
            subjectRect: subjectRect,
            subjectConfidence: arguments["subject_confidence"]?.numberValue,
            slotRect: slotRect,
            slotConfidence: arguments["slot_confidence"]?.numberValue,
            recommendedStyle: arguments["recommended_style"]?.stringValue.flatMap(OverlayStyle.init(rawValue:)),
            recommendedTopFraction: arguments["recommended_top_fraction"]?.numberValue,
            recommendedMaxWidthFraction: arguments["recommended_max_width_fraction"]?.numberValue,
            recommendedTargetLineCount: arguments["recommended_target_line_count"]?.numberValue.map { Int($0.rounded()) },
            horizontalAnchor: arguments["horizontal_anchor"]?.stringValue.flatMap(OverlayHorizontalAnchor.init(rawValue:)),
            verticalAnchor: arguments["vertical_anchor"]?.stringValue.flatMap(OverlayVerticalAnchor.init(rawValue:)),
            notes: arguments["notes"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
        )
    }

    private static func parseJSONObject(from text: String) -> [String: Any]? {
        let stripped = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = stripped.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }

        guard let start = stripped.firstIndex(of: "{"),
              let end = stripped.lastIndex(of: "}") else {
            return nil
        }

        let candidate = String(stripped[start...end])
        guard let data = candidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func rect(x: Double?, y: Double?, width: Double?, height: Double?) -> CGRect? {
        guard let x, let y, let width, let height, width > 0, height > 0 else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height).integral
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
}

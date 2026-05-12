import CoreGraphics
import Foundation
import ImageIO

#if canImport(UIKit)
import UIKit
#endif

enum OverlayProtectedRegionProvider: String, CaseIterable, Decodable {
    case none
    case appleVision = "apple_vision"
}

enum OverlayLayoutGuideProvider: String, Decodable {
    case none
    case appleVision = "apple_vision"
    case gemmaVision = "gemma_vision"
}

enum OverlayLayoutGuidanceMode: String, Decodable {
    case slot
    case band
}

struct OverlayProtectedRegions {
    let subjectRects: [CGRect]
    let avoidanceRects: [CGRect]

    static let empty = OverlayProtectedRegions(subjectRects: [], avoidanceRects: [])

    var isEmpty: Bool {
        subjectRects.isEmpty && avoidanceRects.isEmpty
    }

    func subjectOverlapFraction(with rect: CGRect) -> CGFloat {
        overlapFraction(of: rect, against: subjectRects)
    }

    func avoidanceOverlapFraction(with rect: CGRect) -> CGFloat {
        overlapFraction(of: rect, against: avoidanceRects)
    }

    private func overlapFraction(of rect: CGRect, against regions: [CGRect]) -> CGFloat {
        guard rect.width > 0, rect.height > 0, !regions.isEmpty else { return 0 }
        let rectArea = rect.width * rect.height
        guard rectArea > 0 else { return 0 }

        var intersectionArea: CGFloat = 0
        for region in regions {
            let intersection = rect.intersection(region)
            guard !intersection.isNull else { continue }
            intersectionArea += intersection.width * intersection.height
        }
        return min(max(intersectionArea / rectArea, 0), 1)
    }
}

struct OverlayLayoutGuide {
    let provider: OverlayLayoutGuideProvider
    let subjectRect: CGRect?
    let subjectConfidence: Double?
    let slotRect: CGRect?
    let slotConfidence: Double?
    let recommendedStyle: OverlayStyle?
    let recommendedTopFraction: Double?
    let recommendedMaxWidthFraction: Double?
    let recommendedTargetLineCount: Int?
    let horizontalAnchor: OverlayHorizontalAnchor?
    let verticalAnchor: OverlayVerticalAnchor?
    let notes: String

    static let empty = OverlayLayoutGuide(
        provider: .none,
        subjectRect: nil,
        subjectConfidence: nil,
        slotRect: nil,
        slotConfidence: nil,
        recommendedStyle: nil,
        recommendedTopFraction: nil,
        recommendedMaxWidthFraction: nil,
        recommendedTargetLineCount: nil,
        horizontalAnchor: nil,
        verticalAnchor: nil,
        notes: ""
    )

    var hasGuidance: Bool {
        subjectRect != nil || slotRect != nil || recommendedStyle != nil
    }
}

struct GemmaOverlayVisionAnalysis {
    let prompt: String
    let guide: OverlayLayoutGuide
    let rawResponses: [String]
    let thoughtTraces: [String]
}

enum OverlayLayoutGuidance {
    static func canvasSize(for url: URL) -> CGSize? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    static func makeGuide(
        provider: OverlayLayoutGuideProvider,
        protectedRegions: OverlayProtectedRegions,
        canvasSize: CGSize
    ) -> OverlayLayoutGuide {
        let subjectRect = union(of: protectedRegions.subjectRects)
        let avoidanceRect = union(of: protectedRegions.avoidanceRects)
        let chosenSubject = subjectRect ?? avoidanceRect
        let slotRect = bestSlot(canvasSize: canvasSize, blockedRect: avoidanceRect ?? subjectRect)
        let style = recommendedStyle(for: slotRect, canvasSize: canvasSize, subjectRect: chosenSubject)
        return OverlayLayoutGuide(
            provider: provider,
            subjectRect: chosenSubject,
            subjectConfidence: chosenSubject == nil ? nil : 70,
            slotRect: slotRect,
            slotConfidence: slotRect == nil ? nil : 68,
            recommendedStyle: style,
            recommendedTopFraction: slotRect.map { Double($0.minY / max(canvasSize.height, 1)) },
            recommendedMaxWidthFraction: slotRect.map { Double($0.width / max(canvasSize.width, 1)) },
            recommendedTargetLineCount: recommendedTargetLineCount(for: style),
            horizontalAnchor: .center,
            verticalAnchor: .bottom,
            notes: "Derived from protected regions and geometric slot search."
        )
    }

    static func overlapFraction(overlayRect: CGRect, subjectRect: CGRect?) -> Double? {
        guard let subjectRect,
              overlayRect.width > 0,
              overlayRect.height > 0 else {
            return nil
        }
        let intersection = overlayRect.intersection(subjectRect)
        guard !intersection.isNull else { return 0 }
        let overlayArea = overlayRect.width * overlayRect.height
        guard overlayArea > 0 else { return nil }
        let overlap = (intersection.width * intersection.height) / overlayArea
        return Double(min(max(overlap, 0), 1))
    }

    static func promptAddendum(
        for guide: OverlayLayoutGuide,
        canvasSize: CGSize,
        mode: OverlayLayoutGuidanceMode = .slot
    ) -> String? {
        guard guide.hasGuidance else { return nil }

        var lines: [String] = [
            "Pre-analysis of the rendered \(Int(canvasSize.width))x\(Int(canvasSize.height)) canvas:"
        ]

        let usableSubjectRect = guide.subjectRect.flatMap {
            isUsableSubjectRect($0, canvasSize: canvasSize) ? $0 : nil
        }
        let guideSubjectWasOverbroad = guide.subjectRect != nil && usableSubjectRect == nil
        let usableSlotRect = guideSubjectWasOverbroad ? nil : guide.slotRect.flatMap {
            isUsableSlotRect($0, subjectRect: usableSubjectRect, canvasSize: canvasSize) ? $0 : nil
        }

        if let subjectRect = usableSubjectRect {
            lines.append(
                "- Protected keep-clear box: x=\(Int(subjectRect.minX.rounded())), y=\(Int(subjectRect.minY.rounded())), width=\(Int(subjectRect.width.rounded())), height=\(Int(subjectRect.height.rounded())). Keep the overlay fully outside it."
            )
        }

        if let slotRect = usableSlotRect {
            switch mode {
            case .slot:
                lines.append(
                    "- Preferred slot: x=\(Int(slotRect.minX.rounded())), y=\(Int(slotRect.minY.rounded())), width=\(Int(slotRect.width.rounded())), height=\(Int(slotRect.height.rounded())). Place the measured overlay inside it, not across the whole slot."
                )
            case .band:
                lines.append(
                    "- Preferred free-space patch: x=\(Int(slotRect.minX.rounded())), y=\(Int(slotRect.minY.rounded())), width=\(Int(slotRect.width.rounded())), height=\(Int(slotRect.height.rounded())). Use it as coarse guidance, not as the final text box."
                )
                if let orientation = orientationLabel(slotRect: slotRect, subjectRect: usableSubjectRect) {
                    lines.append("- The free-space patch sits mostly \(orientation) the subject.")
                }
            }
        }

        if let style = guide.recommendedStyle {
            lines.append("- Recommended style for this frame: \(style.rawValue).")
        }
        if let targetLineCount = guide.recommendedTargetLineCount {
            lines.append("- Recommended target_line_count: \(targetLineCount).")
        }
        if let maxWidthFraction = guide.recommendedMaxWidthFraction {
            lines.append("- Recommended max_width_fraction ceiling: \(String(format: "%.2f", maxWidthFraction)).")
        }
        if let topFraction = guide.recommendedTopFraction {
            lines.append("- Recommended top_fraction target: \(String(format: "%.2f", topFraction)).")
        }
        if let horizontalAnchor = guide.horizontalAnchor, let verticalAnchor = guide.verticalAnchor {
            lines.append("- Recommended anchors: horizontal_anchor \(horizontalAnchor.rawValue), vertical_anchor \(verticalAnchor.rawValue).")
        }
        if mode == .band {
            lines.append("- Prefer normalized hints and anchors over raw x, y, width, and height. Only use raw slot coordinates if the free-space patch is exceptionally clean and obvious.")
        }

        return lines.joined(separator: "\n")
    }

    static func requestByApplyingGuide(
        _ request: OverlayRequest,
        guide: OverlayLayoutGuide,
        canvasSize: CGSize
    ) -> OverlayRequest {
        guard guide.hasGuidance else {
            return request
        }

        let guidedStyle = request.style == .auto ? (guide.recommendedStyle ?? request.style) : request.style
        let guidedLineCount = request.targetLineCount ?? guide.recommendedTargetLineCount ?? recommendedTargetLineCount(for: guidedStyle)
        let guidedMaxWidthFraction = request.maxWidthFraction ?? guide.recommendedMaxWidthFraction.map { CGFloat($0) }
        let guidedHorizontalAnchor = guide.horizontalAnchor ?? request.horizontalAnchor
        let guidedVerticalAnchor = guide.verticalAnchor ?? request.verticalAnchor
        let explicitRectRequested = request.rect.width > 0 && request.rect.height > 0

        guard !explicitRectRequested else {
            return OverlayRequest(
                text: request.text,
                rect: request.rect,
                style: guidedStyle,
                topFraction: request.topFraction,
                maxWidthFraction: guidedMaxWidthFraction,
                targetLineCount: guidedLineCount,
                horizontalAnchor: guidedHorizontalAnchor,
                verticalAnchor: guidedVerticalAnchor
            )
        }

        if let slotRect = preferredSlot(
            for: request.text,
            style: guidedStyle,
            guide: guide,
            canvasSize: canvasSize,
            maxWidthFraction: guidedMaxWidthFraction,
            targetLineCount: guidedLineCount,
            horizontalAnchor: guidedHorizontalAnchor,
            verticalAnchor: guidedVerticalAnchor
        ) {
            return OverlayRequest(
                text: request.text,
                rect: slotRect,
                style: guidedStyle,
                topFraction: nil,
                maxWidthFraction: guidedMaxWidthFraction,
                targetLineCount: guidedLineCount,
                horizontalAnchor: guidedHorizontalAnchor,
                verticalAnchor: guidedVerticalAnchor
            )
        }

        return OverlayRequest(
            text: request.text,
            rect: .zero,
            style: guidedStyle,
            topFraction: request.topFraction ?? guide.recommendedTopFraction.map { CGFloat($0) },
            maxWidthFraction: guidedMaxWidthFraction,
            targetLineCount: guidedLineCount,
            horizontalAnchor: guidedHorizontalAnchor,
            verticalAnchor: guidedVerticalAnchor
        )
    }

    static func protectedRegions(
        from guide: OverlayLayoutGuide,
        canvasSize: CGSize
    ) -> OverlayProtectedRegions {
        guard let subjectRect = guide.subjectRect,
              isUsableSubjectRect(subjectRect, canvasSize: canvasSize) else {
            return .empty
        }

        let aspectRatio = subjectRect.height / max(subjectRect.width, 1)
        let centrality = abs((subjectRect.midX / max(canvasSize.width, 1)) - 0.5)
        let horizontalPadding = canvasSize.width * (aspectRatio > 1.1 ? 0.09 : 0.07)
        let topPadding = canvasSize.height * (aspectRatio > 1.25 || centrality < 0.18 ? 0.11 : 0.08)
        let bottomPadding = canvasSize.height * 0.04
        let avoidanceRect = CGRect(
            x: subjectRect.minX - horizontalPadding,
            y: subjectRect.minY - topPadding,
            width: subjectRect.width + (horizontalPadding * 2),
            height: subjectRect.height + topPadding + bottomPadding
        ).integral

        return OverlayProtectedRegions(
            subjectRects: [subjectRect],
            avoidanceRects: [avoidanceRect]
        )
    }

    private static func union(of rects: [CGRect]) -> CGRect? {
        rects
            .filter { !$0.isNull && !$0.isEmpty }
            .reduce(nil) { partial, rect in
                partial?.union(rect) ?? rect
            }
    }

    static func isUsableSubjectRect(_ rect: CGRect, canvasSize: CGSize) -> Bool {
        guard rect.width > 0,
              rect.height > 0,
              canvasSize.width > 0,
              canvasSize.height > 0 else {
            return false
        }
        let canvasArea = canvasSize.width * canvasSize.height
        let areaFraction = (rect.width * rect.height) / max(canvasArea, 1)
        let widthFraction = rect.width / max(canvasSize.width, 1)
        let heightFraction = rect.height / max(canvasSize.height, 1)
        return areaFraction < 0.72 && !(widthFraction > 0.92 && heightFraction > 0.72)
    }

    static func isUsableSlotRect(_ rect: CGRect, subjectRect: CGRect?, canvasSize: CGSize) -> Bool {
        guard rect.width > 0,
              rect.height > 0,
              canvasSize.width > 0,
              canvasSize.height > 0 else {
            return false
        }
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let clipped = rect.intersection(canvas)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            return false
        }
        let areaFraction = (clipped.width * clipped.height) / max(canvas.width * canvas.height, 1)
        guard areaFraction >= 0.025, areaFraction <= 0.35 else {
            return false
        }
        if let subjectRect,
           isUsableSubjectRect(subjectRect, canvasSize: canvasSize),
           let overlap = overlapFraction(overlayRect: clipped, subjectRect: subjectRect),
           overlap > 0.08 {
            return false
        }
        return true
    }

    private static func bestSlot(canvasSize: CGSize, blockedRect: CGRect?) -> CGRect? {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        guard canvas.width > 0, canvas.height > 0 else { return nil }

        let candidates = candidateSlots(canvas: canvas, blockedRect: blockedRect)

        return candidates.max { lhs, rhs in
            slotScore(lhs, blockedRect: blockedRect, canvas: canvas) < slotScore(rhs, blockedRect: blockedRect, canvas: canvas)
        }
    }

    private static func preferredSlot(
        for text: String,
        style: OverlayStyle,
        guide: OverlayLayoutGuide,
        canvasSize: CGSize,
        maxWidthFraction: CGFloat?,
        targetLineCount: Int?,
        horizontalAnchor: OverlayHorizontalAnchor,
        verticalAnchor: OverlayVerticalAnchor
    ) -> CGRect? {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        guard canvas.width > 0, canvas.height > 0 else { return nil }

        let protectedRegions = protectedRegions(from: guide, canvasSize: canvasSize)
        let blockedRect = union(of: protectedRegions.avoidanceRects) ?? union(of: protectedRegions.subjectRects)
        var candidates = candidateSlots(canvas: canvas, blockedRect: blockedRect)
        let usableSubjectRect = guide.subjectRect.flatMap {
            isUsableSubjectRect($0, canvasSize: canvasSize) ? $0 : nil
        }
        let guideSubjectWasOverbroad = guide.subjectRect != nil && usableSubjectRect == nil
        if let coarseSlot = guide.slotRect,
           !guideSubjectWasOverbroad,
           isUsableSlotRect(coarseSlot, subjectRect: usableSubjectRect, canvasSize: canvasSize) {
            candidates.insert(coarseSlot.integral, at: 0)
        }
        candidates = deduplicatedRects(candidates)

        guard !candidates.isEmpty else { return nil }

        let resolved = candidates.compactMap { slotRect -> (CGRect, CGFloat)? in
            let overlay = OverlayRendering.resolve(
                OverlayRequest(
                    text: text,
                    rect: slotRect,
                    style: style,
                    topFraction: nil,
                    maxWidthFraction: maxWidthFraction,
                    targetLineCount: targetLineCount,
                    horizontalAnchor: horizontalAnchor,
                    verticalAnchor: verticalAnchor
                ),
                canvasSize: canvasSize,
                protectedRegions: .empty
            )
            let score = slotFitnessScore(
                slotRect: slotRect,
                overlayRect: overlay.frame,
                style: style,
                protectedRegions: protectedRegions,
                canvas: canvas
            )
            return (slotRect, score)
        }

        return resolved.max { lhs, rhs in
            lhs.1 < rhs.1
        }?.0
    }

    private static func candidateSlots(canvas: CGRect, blockedRect: CGRect?) -> [CGRect] {
        let marginX = canvas.width * 0.06
        let marginTop = canvas.height * 0.10
        let marginBottom = canvas.height * 0.08

        var candidates = fallbackSlots(canvas: canvas)

        guard let blockedRect, !blockedRect.isNull, !blockedRect.isEmpty else {
            return deduplicatedRects(candidates)
        }

        let safeBlocked = blockedRect.intersection(canvas)
        guard !safeBlocked.isNull, !safeBlocked.isEmpty else {
            return deduplicatedRects(candidates)
        }

        let leftWidth = safeBlocked.minX - marginX
        if leftWidth > canvas.width * 0.18 {
            candidates.append(
                CGRect(
                    x: marginX,
                    y: max(marginTop, safeBlocked.minY - (canvas.height * 0.02)),
                    width: leftWidth - (canvas.width * 0.02),
                    height: min(canvas.height * 0.32, max(canvas.height * 0.18, safeBlocked.height + (canvas.height * 0.06)))
                ).integral
            )
        }

        let rightX = safeBlocked.maxX + (canvas.width * 0.02)
        let rightWidth = canvas.maxX - marginX - rightX
        if rightWidth > canvas.width * 0.18 {
            candidates.append(
                CGRect(
                    x: rightX,
                    y: max(marginTop, safeBlocked.minY - (canvas.height * 0.02)),
                    width: rightWidth,
                    height: min(canvas.height * 0.32, max(canvas.height * 0.18, safeBlocked.height + (canvas.height * 0.06)))
                ).integral
            )
        }

        let aboveHeight = safeBlocked.minY - marginTop
        if aboveHeight > canvas.height * 0.12 {
            candidates.append(
                CGRect(
                    x: max(marginX, safeBlocked.minX - (canvas.width * 0.10)),
                    y: marginTop,
                    width: min(canvas.width - (marginX * 2), max(canvas.width * 0.30, safeBlocked.width + (canvas.width * 0.20))),
                    height: aboveHeight - (canvas.height * 0.02)
                ).integral
            )
        }

        let belowY = safeBlocked.maxY + (canvas.height * 0.03)
        let belowHeight = canvas.maxY - marginBottom - belowY
        if belowHeight > canvas.height * 0.10 {
            candidates.append(
                CGRect(
                    x: max(marginX, safeBlocked.minX - (canvas.width * 0.08)),
                    y: belowY,
                    width: min(canvas.width - (marginX * 2), max(canvas.width * 0.34, safeBlocked.width + (canvas.width * 0.16))),
                    height: belowHeight
                ).integral
            )
        }

        let topLeft = CGRect(
            x: marginX,
            y: marginTop,
            width: max(0, safeBlocked.minX - marginX - (canvas.width * 0.02)),
            height: max(0, safeBlocked.minY - marginTop - (canvas.height * 0.02))
        ).integral
        let topRight = CGRect(
            x: safeBlocked.maxX + (canvas.width * 0.02),
            y: marginTop,
            width: max(0, canvas.maxX - marginX - safeBlocked.maxX - (canvas.width * 0.02)),
            height: max(0, safeBlocked.minY - marginTop - (canvas.height * 0.02))
        ).integral
        candidates.append(contentsOf: [topLeft, topRight])

        return deduplicatedRects(candidates)
    }

    private static func fallbackSlots(canvas: CGRect) -> [CGRect] {
        let fractions: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.10, 0.18, 0.34, 0.22),
            (0.56, 0.18, 0.34, 0.22),
            (0.16, 0.18, 0.68, 0.18),
            (0.16, 0.48, 0.68, 0.18),
            (0.10, 0.58, 0.38, 0.16),
            (0.52, 0.58, 0.38, 0.16)
        ]
        return fractions.map { fractions in
            CGRect(
                x: canvas.width * fractions.0,
                y: canvas.height * fractions.1,
                width: canvas.width * fractions.2,
                height: canvas.height * fractions.3
            ).integral
        }
    }

    private static func deduplicatedRects(_ rects: [CGRect]) -> [CGRect] {
        rects.reduce(into: [CGRect]()) { unique, rect in
            guard rect.width > 0, rect.height > 0 else { return }
            let clipped = rect.integral
            let alreadySeen = unique.contains {
                abs($0.minX - clipped.minX) < 1 &&
                abs($0.minY - clipped.minY) < 1 &&
                abs($0.width - clipped.width) < 1 &&
                abs($0.height - clipped.height) < 1
            }
            if !alreadySeen {
                unique.append(clipped)
            }
        }
    }

    private static func slotScore(_ rect: CGRect, blockedRect: CGRect?, canvas: CGRect) -> CGFloat {
        guard rect.width > 0, rect.height > 0 else { return -.greatestFiniteMagnitude }

        let areaFraction = (rect.width * rect.height) / max(canvas.width * canvas.height, 1)
        let overlapPenalty: CGFloat
        if let blockedRect {
            let intersection = rect.intersection(blockedRect)
            if intersection.isNull {
                overlapPenalty = 0
            } else {
                overlapPenalty = (intersection.width * intersection.height) / max(rect.width * rect.height, 1)
            }
        } else {
            overlapPenalty = 0
        }

        let yCenter = rect.midY / max(canvas.height, 1)
        let bandBonus: CGFloat
        if (0.18...0.35).contains(yCenter) || (0.48...0.65).contains(yCenter) {
            bandBonus = 0.12
        } else {
            bandBonus = 0
        }

        let aspectRatio = rect.width / max(rect.height, 1)
        let shapeBonus: CGFloat
        if aspectRatio >= 1.3 && aspectRatio <= 3.8 {
            shapeBonus = 0.10
        } else {
            shapeBonus = -0.04
        }

        let edgePenalty = min(
            rect.minX / max(canvas.width, 1),
            rect.minY / max(canvas.height, 1),
            (canvas.maxX - rect.maxX) / max(canvas.width, 1),
            (canvas.maxY - rect.maxY) / max(canvas.height, 1)
        ) < 0.03 ? 0.08 : 0

        return areaFraction + bandBonus + shapeBonus - edgePenalty - (overlapPenalty * 4.5)
    }

    private static func slotFitnessScore(
        slotRect: CGRect,
        overlayRect: CGRect,
        style: OverlayStyle,
        protectedRegions: OverlayProtectedRegions,
        canvas: CGRect
    ) -> CGFloat {
        guard slotRect.width > 0, slotRect.height > 0, overlayRect.width > 0, overlayRect.height > 0 else {
            return -.greatestFiniteMagnitude
        }

        let subjectOverlap = protectedRegions.subjectOverlapFraction(with: overlayRect)
        let avoidanceOverlap = protectedRegions.avoidanceOverlapFraction(with: overlayRect)
        if subjectOverlap > 0.001 || avoidanceOverlap > 0.03 {
            return -10_000 - (subjectOverlap * 10_000) - (avoidanceOverlap * 3_000)
        }

        let subjectRect = union(of: protectedRegions.subjectRects)
        let silhouettePenalty = subjectRect.map {
            elevatedSilhouettePenalty(overlayRect: overlayRect, subjectRect: $0, canvas: canvas)
        } ?? 0

        let occupancy = (overlayRect.width * overlayRect.height) / max(slotRect.width * slotRect.height, 1)
        let occupancyScore: CGFloat
        if occupancy >= 0.18 && occupancy <= 0.72 {
            occupancyScore = 0.18
        } else if occupancy >= 0.10 && occupancy <= 0.84 {
            occupancyScore = 0.08
        } else {
            occupancyScore = -0.12
        }

        let insetLeft = overlayRect.minX - slotRect.minX
        let insetRight = slotRect.maxX - overlayRect.maxX
        let insetTop = overlayRect.minY - slotRect.minY
        let insetBottom = slotRect.maxY - overlayRect.maxY
        let minimumInset = min(insetLeft, insetRight, insetTop, insetBottom)
        let breathingRoom = min(max(minimumInset / max(canvas.width, canvas.height), 0), 0.12)

        let yCenter = overlayRect.midY / max(canvas.height, 1)
        let bandScore: CGFloat
        switch style {
        case .caption:
            bandScore = (0.44...0.64).contains(yCenter) ? 0.16 : ((0.38...0.70).contains(yCenter) ? 0.06 : -0.10)
        case .headline, .sticker, .tag, .auto:
            bandScore = (0.18...0.36).contains(yCenter) ? 0.16 : ((0.14...0.44).contains(yCenter) ? 0.06 : -0.08)
        }

        let edgeDistance = min(
            overlayRect.minX / max(canvas.width, 1),
            overlayRect.minY / max(canvas.height, 1),
            (canvas.maxX - overlayRect.maxX) / max(canvas.width, 1),
            (canvas.maxY - overlayRect.maxY) / max(canvas.height, 1)
        )
        let edgePenalty: CGFloat = edgeDistance < 0.035 ? 0.08 : 0

        return occupancyScore + breathingRoom + bandScore - edgePenalty - silhouettePenalty
    }

    private static func elevatedSilhouettePenalty(
        overlayRect: CGRect,
        subjectRect: CGRect,
        canvas: CGRect
    ) -> CGFloat {
        let horizontalIntersection = min(overlayRect.maxX, subjectRect.maxX) - max(overlayRect.minX, subjectRect.minX)
        guard horizontalIntersection > 0 else { return 0 }

        let horizontalOverlapFraction = horizontalIntersection / max(min(overlayRect.width, subjectRect.width), 1)
        guard horizontalOverlapFraction > 0.22 else { return 0 }
        let subjectAspect = subjectRect.height / max(subjectRect.width, 1)
        let subjectCentrality = abs((subjectRect.midX / max(canvas.width, 1)) - 0.5)

        if subjectAspect > 1.15 &&
            subjectCentrality < 0.20 &&
            overlayRect.midY < subjectRect.midY + (canvas.height * 0.02) {
            return 0.52
        }

        let verticalGap = subjectRect.minY - overlayRect.maxY
        if verticalGap >= 0 && verticalGap < canvas.height * 0.10 {
            return 0.18 + ((canvas.height * 0.10 - verticalGap) / max(canvas.height * 0.10, 1)) * 0.22
        }

        if overlayRect.minY < subjectRect.midY && overlayRect.maxY > subjectRect.minY {
            return 0.36
        }

        return 0
    }

    private static func recommendedStyle(
        for slotRect: CGRect?,
        canvasSize: CGSize,
        subjectRect: CGRect?
    ) -> OverlayStyle? {
        guard let slotRect else { return nil }

        let slotMidY = slotRect.midY / max(canvasSize.height, 1)
        if let subjectRect {
            let subjectAreaFraction = (subjectRect.width * subjectRect.height) / max(canvasSize.width * canvasSize.height, 1)
            if subjectAreaFraction > 0.22 && slotMidY < 0.42 {
                return .sticker
            }
        }

        if slotMidY >= 0.45 {
            return .caption
        }
        return .sticker
    }

    private static func recommendedTargetLineCount(for style: OverlayStyle?) -> Int? {
        switch style {
        case .caption:
            return 1
        case .headline, .tag:
            return 1
        case .sticker, .auto, .none:
            return 2
        }
    }

    private static func orientationLabel(slotRect: CGRect, subjectRect: CGRect?) -> String? {
        guard let subjectRect else { return nil }
        if slotRect.maxX <= subjectRect.minX {
            return "left of"
        }
        if slotRect.minX >= subjectRect.maxX {
            return "right of"
        }
        if slotRect.maxY <= subjectRect.minY {
            return "above"
        }
        if slotRect.minY >= subjectRect.maxY {
            return "below"
        }
        return nil
    }
}

enum OverlayGuideToolSchema {
    static let toolName = "determine_overlay_layout_guide"

    static let toolsJSON = """
    [
      {
        "type": "function",
        "function": {
          "name": "\(toolName)",
          "description": "Determine the protected keep-clear area and, only if safe, one open patch for a short Instagram overlay.",
          "parameters": {
            "type": "object",
            "properties": {
              "protected_x": { "type": "number" },
              "protected_y": { "type": "number" },
              "protected_width": { "type": "number" },
              "protected_height": { "type": "number" },
              "protected_confidence": { "type": "number" },
              "slot_x": { "type": "number" },
              "slot_y": { "type": "number" },
              "slot_width": { "type": "number" },
              "slot_height": { "type": "number" },
              "slot_confidence": { "type": "number" },
              "recommended_style": {
                "type": "string",
                "enum": ["auto", "sticker", "headline", "caption", "tag"]
              },
              "recommended_top_fraction": { "type": "number" },
              "recommended_max_width_fraction": { "type": "number" },
              "recommended_target_line_count": { "type": "integer" },
              "horizontal_anchor": {
                "type": "string",
                "enum": ["left", "center", "right"]
              },
              "vertical_anchor": {
                "type": "string",
                "enum": ["top", "center", "bottom"]
              },
              "notes": { "type": "string" }
            },
            "required": [
              "protected_x",
              "protected_y",
              "protected_width",
              "protected_height",
              "protected_confidence",
              "recommended_style",
              "notes"
            ]
          }
        }
      }
    ]
    """

    static func extract(fromRaw raw: String, fallbackText: String) -> OverlayLayoutGuide {
        let parsed = LiteRTResponseParser.parse(raw)
        return extract(from: parsed, fallbackText: fallbackText)
    }

    static func extract(from parsed: LiteRTParsedMessage, fallbackText: String) -> OverlayLayoutGuide {
        guard let toolCall = parsed.toolCalls.first(where: { $0.name == toolName }) else {
            return .empty
        }

        return extract(fromArguments: toolCall.arguments, fallbackText: fallbackText)
    }

    private static func extract(
        fromArguments arguments: [String: LiteRTToolValue],
        fallbackText: String
    ) -> OverlayLayoutGuide {
        let subjectRect = rect(
            x: arguments["protected_x"]?.numberValue ?? arguments["subject_x"]?.numberValue,
            y: arguments["protected_y"]?.numberValue ?? arguments["subject_y"]?.numberValue,
            width: arguments["protected_width"]?.numberValue ?? arguments["subject_width"]?.numberValue,
            height: arguments["protected_height"]?.numberValue ?? arguments["subject_height"]?.numberValue
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
            subjectConfidence: arguments["protected_confidence"]?.numberValue ?? arguments["subject_confidence"]?.numberValue,
            slotRect: slotRect,
            slotConfidence: arguments["slot_confidence"]?.numberValue,
            recommendedStyle: arguments["recommended_style"]?.stringValue.flatMap(OverlayStyle.init(rawValue:)),
            recommendedTopFraction: arguments["recommended_top_fraction"]?.numberValue,
            recommendedMaxWidthFraction: arguments["recommended_max_width_fraction"]?.numberValue,
            recommendedTargetLineCount: arguments["recommended_target_line_count"]?.numberValue.map { Int($0.rounded()) },
            horizontalAnchor: arguments["horizontal_anchor"]?.stringValue.flatMap(OverlayHorizontalAnchor.init(rawValue:)),
            verticalAnchor: arguments["vertical_anchor"]?.stringValue.flatMap(OverlayVerticalAnchor.init(rawValue:)),
            notes: arguments["notes"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func rect(x: Double?, y: Double?, width: Double?, height: Double?) -> CGRect? {
        guard let x, let y, let width, let height, width > 0, height > 0 else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height).integral
    }
}

enum GemmaOverlayVision {
    static func analyze(
        renderedURL: URL,
        modelURL: URL,
        enableThinking: Bool,
        samplerSeed: Int32? = nil,
        runner: GemmaTextRunner? = nil
    ) async throws -> OverlayLayoutGuide {
        try await analyzeDetailed(
            renderedURL: renderedURL,
            modelURL: modelURL,
            enableThinking: enableThinking,
            samplerSeed: samplerSeed,
            runner: runner
        ).guide
    }

    static func analyzeDetailed(
        renderedURL: URL,
        modelURL: URL,
        enableThinking: Bool,
        samplerSeed: Int32? = nil,
        runner: GemmaTextRunner? = nil
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
        Determine overlay placement guidance for this rendered social-media frame.
        The canvas is \(Int(canvasSize.width))x\(Int(canvasSize.height)) pixels. Return all coordinates as pixel values in this rendered canvas.
        Determine all protected visual areas first: people, faces, heads, hair, hands, animals, tools, enclosures, plant guards, paperwork, skyline, sunset band, smoke, fire, flood water, storm clouds, damage, and main action.
        Return one conservative protected keep-clear box that covers every protected area the sticker must avoid, with breathing room.
        If protected areas are separated, cover the full union or make the box larger. Do not protect only the animal and forget the person, face, head, hands, tools, or story objects.
        Keep the protected box tight enough to leave real open space when possible. Do not mark the whole canvas protected unless there is truly no safe sticker area.
        If you are unsure, make the keep-clear box larger, not smaller.
        Prefer sticker for busy subject-dominant frames, caption for real negative space, headline only when a single line can stay legible without a box, and tag only for an actual handle or label.
        You may optionally return one coarse free-space patch only if it is clearly outside all protected areas and has breathing room.
        Do not return an upper patch when a face, head, hair, skyline, sunset band, or story evidence sits in that upper area.
        If there is no truly clean patch, omit the slot fields or return very low slot_confidence and explain the compromise in notes.
        """

        let activeRunner = runner ?? GemmaTextRunner()
        let ownsRunner = runner == nil
        let extraContextJSON = enableThinking ? ProductionToolSchema.stringify(["enable_thinking": true]) : nil
        try await activeRunner.makeToolSession(
            modelURL: modelURL,
            toolsJSON: OverlayGuideToolSchema.toolsJSON,
            systemMessageJSON: nil,
            extraContextJSON: extraContextJSON,
            samplerSeed: samplerSeed
        )
        do {
            let rawResponse = try await activeRunner.sendRawJSON(
                ProductionToolSchema.userMessageJSON(text: prompt, assets: [renderedAsset])
            )
            let parsed = LiteRTResponseParser.parse(rawResponse)
            let rawResponses = [rawResponse]
            let thoughtTraces = parsed.thoughtText.isEmpty ? [] : [parsed.thoughtText]
            var guide = OverlayGuideToolSchema.extract(fromRaw: rawResponse, fallbackText: parsed.text)
            if shouldApplyFallback(to: guide) {
                let fallbackGuide = OverlayLayoutGuidance.makeGuide(
                    provider: .gemmaVision,
                    protectedRegions: OverlayProtectedRegions(
                        subjectRects: guide.subjectRect.map { [$0] } ?? [],
                        avoidanceRects: guide.subjectRect.map { [$0.insetBy(dx: -24, dy: -24)] } ?? []
                    ),
                    canvasSize: canvasSize
                )
                let replaceSlot = Self.shouldReplaceSlot(in: guide)
                guide = OverlayLayoutGuide(
                    provider: .gemmaVision,
                    subjectRect: guide.subjectRect ?? fallbackGuide.subjectRect,
                    subjectConfidence: guide.subjectConfidence ?? fallbackGuide.subjectConfidence,
                    slotRect: replaceSlot ? fallbackGuide.slotRect : (guide.slotRect ?? fallbackGuide.slotRect),
                    slotConfidence: replaceSlot ? fallbackGuide.slotConfidence : (guide.slotConfidence ?? fallbackGuide.slotConfidence),
                    recommendedStyle: guide.recommendedStyle ?? fallbackGuide.recommendedStyle,
                    recommendedTopFraction: replaceSlot ? fallbackGuide.recommendedTopFraction : (guide.recommendedTopFraction ?? fallbackGuide.recommendedTopFraction),
                    recommendedMaxWidthFraction: replaceSlot ? fallbackGuide.recommendedMaxWidthFraction : (guide.recommendedMaxWidthFraction ?? fallbackGuide.recommendedMaxWidthFraction),
                    recommendedTargetLineCount: guide.recommendedTargetLineCount ?? fallbackGuide.recommendedTargetLineCount,
                    horizontalAnchor: replaceSlot ? fallbackGuide.horizontalAnchor : (guide.horizontalAnchor ?? fallbackGuide.horizontalAnchor),
                    verticalAnchor: replaceSlot ? fallbackGuide.verticalAnchor : (guide.verticalAnchor ?? fallbackGuide.verticalAnchor),
                    notes: guide.notes.isEmpty ? fallbackGuide.notes : guide.notes
                )
            }
            if ownsRunner {
                await activeRunner.destroySession()
            }
            return GemmaOverlayVisionAnalysis(
                prompt: prompt,
                guide: guide,
                rawResponses: rawResponses,
                thoughtTraces: thoughtTraces
            )
        } catch {
            if ownsRunner {
                await activeRunner.destroySession()
            }
            throw error
        }
    }

    private static func shouldApplyFallback(to guide: OverlayLayoutGuide) -> Bool {
        if guide.slotRect == nil || guide.recommendedStyle == nil {
            return true
        }
        if shouldReplaceSlot(in: guide) {
            return true
        }
        return false
    }

    private static func shouldReplaceSlot(in guide: OverlayLayoutGuide) -> Bool {
        guard let slotRect = guide.slotRect else {
            return true
        }
        let canvasSize = AppleMediaTooling.imageCanvasSize
        if !OverlayLayoutGuidance.isUsableSlotRect(slotRect, subjectRect: guide.subjectRect, canvasSize: canvasSize) {
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
        return false
    }
}

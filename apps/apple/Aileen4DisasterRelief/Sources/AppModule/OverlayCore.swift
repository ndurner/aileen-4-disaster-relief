import CoreGraphics
import CoreText
import Foundation

#if canImport(UIKit)
import UIKit
typealias OverlayPlatformColor = UIColor
typealias OverlayPlatformFont = UIFont
#elseif canImport(AppKit)
import AppKit
typealias OverlayPlatformColor = NSColor
typealias OverlayPlatformFont = NSFont
#endif

enum OverlayStyle: String, CaseIterable {
    case auto
    case sticker
    case headline
    case caption
    case tag
}

enum OverlayHorizontalAnchor: String {
    case left
    case center
    case right
}

enum OverlayVerticalAnchor: String {
    case top
    case center
    case bottom
}

struct OverlayRequest {
    let text: String
    let rect: CGRect
    let style: OverlayStyle
    let topFraction: CGFloat?
    let maxWidthFraction: CGFloat?
    let targetLineCount: Int?
    let horizontalAnchor: OverlayHorizontalAnchor
    let verticalAnchor: OverlayVerticalAnchor

    init(
        text: String,
        rect: CGRect,
        style: OverlayStyle = .auto,
        topFraction: CGFloat? = nil,
        maxWidthFraction: CGFloat? = nil,
        targetLineCount: Int? = nil,
        horizontalAnchor: OverlayHorizontalAnchor = .center,
        verticalAnchor: OverlayVerticalAnchor = .top
    ) {
        self.text = text
        self.rect = rect
        self.style = style
        self.topFraction = topFraction
        self.maxWidthFraction = maxWidthFraction
        self.targetLineCount = targetLineCount
        self.horizontalAnchor = horizontalAnchor
        self.verticalAnchor = verticalAnchor
    }
}

struct ResolvedOverlay {
    let request: OverlayRequest
    let style: OverlayStyle
    let frame: CGRect
    let textRect: CGRect
    let backgroundRect: CGRect?
    let backgroundColor: OverlayPlatformColor?
    let cornerRadius: CGFloat
    let attributedText: NSAttributedString
    let subjectOverlapFraction: CGFloat
    let avoidanceOverlapFraction: CGFloat
}

enum OverlayRendering {
    private struct Insets {
        let top: CGFloat
        let left: CGFloat
        let bottom: CGFloat
        let right: CGFloat
    }

    private struct StyleMetrics {
        let preferredFontNames: [String]
        let defaultFontSize: CGFloat
        let minimumFontSize: CGFloat
        let maximumFontSize: CGFloat
        let minTopFraction: CGFloat
        let defaultTopFraction: CGFloat
        let minWidthFraction: CGFloat
        let defaultWidthFraction: CGFloat
        let maxWidthFraction: CGFloat
        let maxHeightFraction: CGFloat
        let defaultCenterXFraction: CGFloat
        let horizontalPaddingFactor: CGFloat
        let verticalPaddingFactor: CGFloat
        let minimumHorizontalPadding: CGFloat
        let minimumVerticalPadding: CGFloat
        let cornerRadiusFactor: CGFloat
        let alignment: NSTextAlignment
        let lineSpacing: CGFloat
        let backgroundColor: OverlayPlatformColor?
        let foregroundColor: OverlayPlatformColor
        let shadow: NSShadow?
    }

    private struct TextLayout {
        let size: CGSize
        let lineCount: Int
    }

    static func resolve(
        _ request: OverlayRequest,
        canvasSize: CGSize,
        protectedRegions: OverlayProtectedRegions = .empty
    ) -> ResolvedOverlay {
        let trimmedText = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveRequest = OverlayRequest(
            text: trimmedText.isEmpty ? request.text : trimmedText,
            rect: request.rect,
            style: request.style,
            topFraction: request.topFraction,
            maxWidthFraction: request.maxWidthFraction,
            targetLineCount: request.targetLineCount,
            horizontalAnchor: request.horizontalAnchor,
            verticalAnchor: request.verticalAnchor
        )

        let initial = annotate(
            resolveBase(effectiveRequest, canvasSize: canvasSize),
            protectedRegions: protectedRegions
        )
        guard !protectedRegions.isEmpty else {
            return initial
        }
        if initial.subjectOverlapFraction <= 0.001 && initial.avoidanceOverlapFraction <= 0.001 {
            return initial
        }

        let candidateOverlays: [ResolvedOverlay] = candidateRequests(
            for: effectiveRequest,
            canvasSize: canvasSize,
            style: initial.style
        ).map { request in
            annotate(resolveBase(request, canvasSize: canvasSize), protectedRegions: protectedRegions)
        }
        let candidates = ([initial] + candidateOverlays).reduce(into: [ResolvedOverlay]()) { unique, overlay in
            let duplicate = unique.contains { existing in
                isDuplicateFrame(existing.frame, overlay.frame)
            }
            if !duplicate {
                unique.append(overlay)
            }
        }

        return candidates.min {
            placementPenalty(
                for: $0,
                relativeTo: initial,
                originalRequest: effectiveRequest,
                canvasSize: canvasSize
            ) < placementPenalty(
                for: $1,
                relativeTo: initial,
                originalRequest: effectiveRequest,
                canvasSize: canvasSize
            )
        } ?? initial
    }

    private static func isDuplicateFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 1 &&
        abs(lhs.minY - rhs.minY) < 1 &&
        abs(lhs.width - rhs.width) < 1 &&
        abs(lhs.height - rhs.height) < 1
    }

    private static func resolveBase(_ effectiveRequest: OverlayRequest, canvasSize: CGSize) -> ResolvedOverlay {
        let style = effectiveStyle(for: effectiveRequest, canvasSize: canvasSize)
        let metrics = styleMetrics(for: style, canvasSize: canvasSize)
        let insets = safeInsets(for: canvasSize)

        let requestedWidth = effectiveRequest.rect.width > 0
            ? effectiveRequest.rect.width
            : canvasSize.width * (effectiveRequest.maxWidthFraction ?? metrics.defaultWidthFraction)
        var maxFrameWidth = clamp(
            requestedWidth,
            lower: canvasSize.width * metrics.minWidthFraction,
            upper: canvasSize.width * metrics.maxWidthFraction
        )
        let hasBackground = metrics.backgroundColor != nil
        let horizontalPadding = hasBackground
            ? max(metrics.minimumHorizontalPadding, maxFrameWidth * metrics.horizontalPaddingFactor)
            : 0
        let verticalPadding = hasBackground
            ? max(metrics.minimumVerticalPadding, canvasSize.height * metrics.verticalPaddingFactor)
            : 0
        var maxTextWidth = max(80, maxFrameWidth - (horizontalPadding * 2))
        let maxTextHeight = canvasSize.height * metrics.maxHeightFraction

        if let targetLineCount = effectiveRequest.targetLineCount,
           targetLineCount > 0 {
            maxTextWidth = resolvedTextWidth(
                targetLineCount: targetLineCount,
                text: effectiveRequest.text,
                metrics: metrics,
                minTextWidth: max(80, (canvasSize.width * metrics.minWidthFraction) - (horizontalPadding * 2)),
                maxTextWidth: maxTextWidth,
                maxTextHeight: maxTextHeight
            )
            maxFrameWidth = maxTextWidth + (horizontalPadding * 2)
        }

        var font = fittedFont(
            preferredNames: metrics.preferredFontNames,
            defaultSize: metrics.defaultFontSize,
            minimumSize: metrics.minimumFontSize,
            maximumSize: metrics.maximumFontSize,
            text: effectiveRequest.text,
            metrics: metrics,
            maxTextWidth: maxTextWidth,
            maxTextHeight: maxTextHeight
        )
        var attributedString = attributedText(
            text: effectiveRequest.text,
            font: font,
            metrics: metrics
        )
        var textLayout = measuredLayout(for: attributedString, maxWidth: maxTextWidth)
        var measuredTextSize = textLayout.size

        if style == .tag {
            let singleLineSize = measuredLayout(for: attributedString, maxWidth: canvasSize.width).size
            let expandedFrameWidth = min(
                canvasSize.width * metrics.maxWidthFraction,
                singleLineSize.width + (horizontalPadding * 2)
            )
            if expandedFrameWidth > maxFrameWidth {
                maxFrameWidth = expandedFrameWidth
                maxTextWidth = max(80, maxFrameWidth - (horizontalPadding * 2))
                font = fittedFont(
                    preferredNames: metrics.preferredFontNames,
                    defaultSize: metrics.defaultFontSize,
                    minimumSize: metrics.minimumFontSize,
                    maximumSize: metrics.maximumFontSize,
                    text: effectiveRequest.text,
                    metrics: metrics,
                    maxTextWidth: maxTextWidth,
                    maxTextHeight: maxTextHeight
                )
                attributedString = attributedText(
                    text: effectiveRequest.text,
                    font: font,
                    metrics: metrics
                )
                textLayout = measuredLayout(for: attributedString, maxWidth: maxTextWidth)
                measuredTextSize = textLayout.size
            }
        }

        let frameSize = CGSize(
            width: hasBackground ? measuredTextSize.width + (horizontalPadding * 2) : measuredTextSize.width,
            height: hasBackground ? measuredTextSize.height + (verticalPadding * 2) : measuredTextSize.height
        )

        let requestedCenterX = resolvedCenterX(
            request: effectiveRequest,
            frameWidth: frameSize.width,
            canvasSize: canvasSize,
            insets: insets,
            metrics: metrics
        )
        let resolvedTop = max(
            resolvedTop(
                request: effectiveRequest,
                frameHeight: frameSize.height,
                canvasSize: canvasSize,
                metrics: metrics
            ),
            canvasSize.height * metrics.minTopFraction
        )
        let origin = CGPoint(
            x: clamp(
                requestedCenterX - (frameSize.width / 2),
                lower: insets.left,
                upper: canvasSize.width - insets.right - frameSize.width
            ),
            y: clamp(
                resolvedTop,
                lower: insets.top,
                upper: canvasSize.height - insets.bottom - frameSize.height
            )
        )
        let frame = CGRect(origin: origin, size: frameSize).integral
        let textRect = (hasBackground
            ? frame.insetBy(dx: horizontalPadding, dy: verticalPadding)
            : frame
        ).integral
        let cornerRadius = hasBackground ? min(36, frame.height * metrics.cornerRadiusFactor) : 0

        return ResolvedOverlay(
            request: effectiveRequest,
            style: style,
            frame: frame,
            textRect: textRect,
            backgroundRect: hasBackground ? frame : nil,
            backgroundColor: metrics.backgroundColor,
            cornerRadius: cornerRadius,
            attributedText: attributedString,
            subjectOverlapFraction: 0,
            avoidanceOverlapFraction: 0
        )
    }

    private static func annotate(
        _ overlay: ResolvedOverlay,
        protectedRegions: OverlayProtectedRegions
    ) -> ResolvedOverlay {
        ResolvedOverlay(
            request: overlay.request,
            style: overlay.style,
            frame: overlay.frame,
            textRect: overlay.textRect,
            backgroundRect: overlay.backgroundRect,
            backgroundColor: overlay.backgroundColor,
            cornerRadius: overlay.cornerRadius,
            attributedText: overlay.attributedText,
            subjectOverlapFraction: protectedRegions.subjectOverlapFraction(with: overlay.frame),
            avoidanceOverlapFraction: protectedRegions.avoidanceOverlapFraction(with: overlay.frame)
        )
    }

    private static func candidateRequests(
        for request: OverlayRequest,
        canvasSize: CGSize,
        style: OverlayStyle
    ) -> [OverlayRequest] {
        let metrics = styleMetrics(for: style, canvasSize: canvasSize)
        let requestedTop = request.topFraction ?? metrics.defaultTopFraction
        let requestedWidth = request.maxWidthFraction ?? metrics.defaultWidthFraction
        let topFractions = uniqueFractions([
            metrics.minTopFraction,
            requestedTop,
            metrics.defaultTopFraction,
            style == .caption ? 0.58 : 0.18,
            style == .caption ? 0.50 : 0.24,
            style == .caption ? 0.42 : 0.32,
            style == .caption ? 0.66 : 0.40
        ])
        let widthFractions = uniqueFractions([
            requestedWidth,
            metrics.defaultWidthFraction,
            max(metrics.minWidthFraction, requestedWidth - 0.12),
            max(metrics.minWidthFraction, metrics.defaultWidthFraction - 0.18)
        ])
        let lineCounts = uniqueLineCounts([
            request.targetLineCount,
            style == .caption ? 1 : 2,
            style == .caption ? 2 : 3
        ])
        let anchors = uniqueAnchors([request.horizontalAnchor, .left, .center, .right])

        var candidates: [OverlayRequest] = []
        if request.rect.width > 0 && request.rect.height > 0 {
            for horizontalAnchor in anchors {
                for verticalAnchor in [OverlayVerticalAnchor.top, .center, .bottom] {
                    for targetLineCount in lineCounts {
                        candidates.append(
                            OverlayRequest(
                                text: request.text,
                                rect: request.rect,
                                style: style,
                                topFraction: nil,
                                maxWidthFraction: request.maxWidthFraction,
                                targetLineCount: targetLineCount,
                                horizontalAnchor: horizontalAnchor,
                                verticalAnchor: verticalAnchor
                            )
                        )
                    }
                }
            }
        }

        for topFraction in topFractions {
            for widthFraction in widthFractions {
                for targetLineCount in lineCounts {
                    for horizontalAnchor in anchors {
                        candidates.append(
                            OverlayRequest(
                                text: request.text,
                                rect: .zero,
                                style: style,
                                topFraction: topFraction,
                                maxWidthFraction: widthFraction,
                                targetLineCount: targetLineCount,
                                horizontalAnchor: horizontalAnchor,
                                verticalAnchor: .top
                            )
                        )
                    }
                }
            }
        }

        return candidates
    }

    private static func placementPenalty(
        for candidate: ResolvedOverlay,
        relativeTo baseline: ResolvedOverlay,
        originalRequest: OverlayRequest,
        canvasSize: CGSize
    ) -> CGFloat {
        let canvasWidth = max(canvasSize.width, 1)
        let canvasHeight = max(canvasSize.height, 1)
        let horizontalMovement = abs(candidate.frame.midX - baseline.frame.midX) / canvasWidth
        let verticalMovement = abs(candidate.frame.minY - baseline.frame.minY) / canvasHeight
        let escapedExplicitSlot = originalRequest.rect.width > 0 &&
            originalRequest.rect.height > 0 &&
            candidate.request.rect == .zero

        var penalty =
            candidate.subjectOverlapFraction * 10_000 +
            candidate.avoidanceOverlapFraction * 1_600 +
            horizontalMovement * 45 +
            verticalMovement * 70
        if escapedExplicitSlot {
            penalty += 12
        }
        return penalty
    }

    private static func uniqueFractions(_ values: [CGFloat?]) -> [CGFloat] {
        var unique: [CGFloat] = []
        for candidate in values {
            guard let candidate else { continue }
            let rounded = round(candidate * 1000) / 1000
            if !unique.contains(where: { abs($0 - rounded) < 0.001 }) {
                unique.append(rounded)
            }
        }
        return unique
    }

    private static func uniqueLineCounts(_ values: [Int?]) -> [Int] {
        values
            .compactMap { $0 }
            .filter { $0 > 0 }
            .reduce(into: [Int]()) { unique, value in
                if !unique.contains(value) {
                    unique.append(value)
                }
            }
    }

    private static func uniqueAnchors(_ values: [OverlayHorizontalAnchor]) -> [OverlayHorizontalAnchor] {
        values.reduce(into: [OverlayHorizontalAnchor]()) { unique, value in
            if !unique.contains(value) {
                unique.append(value)
            }
        }
    }

    static func draw(_ overlay: ResolvedOverlay, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        if let backgroundRect = overlay.backgroundRect,
           let backgroundColor = overlay.backgroundColor {
            let path = CGPath(
                roundedRect: backgroundRect,
                cornerWidth: overlay.cornerRadius,
                cornerHeight: overlay.cornerRadius,
                transform: nil
            )
            context.addPath(path)
            context.setFillColor(backgroundColor.cgColor)
            context.fillPath()
        }

        #if canImport(AppKit)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        overlay.attributedText.draw(
            with: overlay.textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        NSGraphicsContext.restoreGraphicsState()
        #else
        overlay.attributedText.draw(
            with: overlay.textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        #endif
    }

    static func makeOverlayCGImage(for request: OverlayRequest, canvasSize: CGSize) -> CGImage? {
        makeOverlayCGImage(for: resolve(request, canvasSize: canvasSize), canvasSize: canvasSize)
    }

    static func makeOverlayCGImage(for overlay: ResolvedOverlay, canvasSize: CGSize) -> CGImage? {
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let image = renderer.image { context in
            draw(overlay, in: context.cgContext)
        }
        return image.cgImage
        #else
        guard let context = CGContext(
            data: nil,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.translateBy(x: 0, y: canvasSize.height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(transparent.cgColor)
        context.fill(CGRect(origin: .zero, size: canvasSize))
        draw(overlay, in: context)
        return context.makeImage()
        #endif
    }

    private static func effectiveStyle(for request: OverlayRequest, canvasSize: CGSize) -> OverlayStyle {
        if request.style != .auto {
            switch request.style {
            case .headline, .caption, .sticker:
                return .sticker
            case .tag:
                return .tag
            case .auto:
                break
            }
        }

        let text = request.text.lowercased()

        if text.hasPrefix("@") || (text.hasPrefix("#") && request.text.count < 32) {
            return .tag
        }
        return .sticker
    }

    private static func safeInsets(for canvasSize: CGSize) -> Insets {
        Insets(
            top: canvasSize.height * 0.08,
            left: canvasSize.width * 0.06,
            bottom: canvasSize.height * 0.08,
            right: canvasSize.width * 0.06
        )
    }

    private static func styleMetrics(for style: OverlayStyle, canvasSize: CGSize) -> StyleMetrics {
        let canvasWidth = max(canvasSize.width, 1)

        switch style {
        case .sticker:
            return StyleMetrics(
                preferredFontNames: ["Georgia-Bold", "TimesNewRomanPS-BoldMT", "AvenirNext-DemiBold"],
                defaultFontSize: canvasWidth * 0.053,
                minimumFontSize: canvasWidth * 0.031,
                maximumFontSize: canvasWidth * 0.066,
                minTopFraction: 0.17,
                defaultTopFraction: 0.23,
                minWidthFraction: 0.34,
                defaultWidthFraction: 0.66,
                maxWidthFraction: 0.78,
                maxHeightFraction: 0.24,
                defaultCenterXFraction: 0.5,
                horizontalPaddingFactor: 0.06,
                verticalPaddingFactor: 0.015,
                minimumHorizontalPadding: 18,
                minimumVerticalPadding: 14,
                cornerRadiusFactor: 0.22,
                alignment: .center,
                lineSpacing: 0,
                backgroundColor: OverlayPlatformColor(white: 0.99, alpha: 0.98),
                foregroundColor: OverlayPlatformColor(white: 0.10, alpha: 1.0),
                shadow: nil
            )
        case .headline:
            return styleMetrics(for: .sticker, canvasSize: canvasSize)
        case .caption:
            return styleMetrics(for: .sticker, canvasSize: canvasSize)
        case .tag:
            let shadow = NSShadow()
            shadow.shadowBlurRadius = canvasWidth * 0.008
            shadow.shadowOffset = CGSize(width: 0, height: 2)
            shadow.shadowColor = OverlayPlatformColor(white: 0.0, alpha: 0.18)
            return StyleMetrics(
                preferredFontNames: ["AvenirNext-DemiBold", "HelveticaNeue-Bold", "Arial-BoldMT"],
                defaultFontSize: canvasWidth * 0.028,
                minimumFontSize: canvasWidth * 0.018,
                maximumFontSize: canvasWidth * 0.033,
                minTopFraction: 0.22,
                defaultTopFraction: 0.28,
                minWidthFraction: 0.22,
                defaultWidthFraction: 0.44,
                maxWidthFraction: 0.68,
                maxHeightFraction: 0.10,
                defaultCenterXFraction: 0.5,
                horizontalPaddingFactor: 0.08,
                verticalPaddingFactor: 0.010,
                minimumHorizontalPadding: 14,
                minimumVerticalPadding: 10,
                cornerRadiusFactor: 0.18,
                alignment: .center,
                lineSpacing: 0,
                backgroundColor: OverlayPlatformColor(white: 0.12, alpha: 0.68),
                foregroundColor: OverlayPlatformColor(white: 1.0, alpha: 1.0),
                shadow: shadow
            )
        case .auto:
            return styleMetrics(for: .sticker, canvasSize: canvasSize)
        }
    }

    private static func fittedFont(
        preferredNames: [String],
        defaultSize: CGFloat,
        minimumSize: CGFloat,
        maximumSize: CGFloat,
        text: String,
        metrics: StyleMetrics,
        maxTextWidth: CGFloat,
        maxTextHeight: CGFloat
    ) -> OverlayPlatformFont {
        var fontSize = clamp(defaultSize, lower: minimumSize, upper: maximumSize)
        while fontSize >= minimumSize {
            let font = platformFont(preferredNames: preferredNames, size: fontSize)
            let attributed = attributedText(text: text, font: font, metrics: metrics)
            let measured = measuredLayout(for: attributed, maxWidth: maxTextWidth)
            if measured.size.height <= maxTextHeight {
                return font
            }
            fontSize -= 2
        }
        return platformFont(preferredNames: preferredNames, size: minimumSize)
    }

    private static func attributedText(
        text: String,
        font: OverlayPlatformFont,
        metrics: StyleMetrics
    ) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = metrics.alignment
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = metrics.lineSpacing

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: metrics.foregroundColor,
            .paragraphStyle: paragraphStyle
        ]
        if let shadow = metrics.shadow {
            attributes[.shadow] = shadow
        }

        return NSAttributedString(string: text, attributes: attributes)
    }

    private static func measuredLayout(for attributedText: NSAttributedString, maxWidth: CGFloat) -> TextLayout {
        let constrainedWidth = max(maxWidth, 1)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText as CFAttributedString)
        let suggestedSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributedText.length),
            nil,
            CGSize(width: constrainedWidth, height: .greatestFiniteMagnitude),
            nil
        )
        let drawingRect = CGRect(
            x: 0,
            y: 0,
            width: constrainedWidth,
            height: max(ceil(suggestedSize.height) + 8, 8)
        )
        let path = CGMutablePath()
        path.addRect(drawingRect)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributedText.length),
            path,
            nil
        )
        let lineCount = CFArrayGetCount(CTFrameGetLines(frame))
        return TextLayout(
            size: CGSize(
                width: ceil(suggestedSize.width),
                height: ceil(suggestedSize.height)
            ),
            lineCount: max(lineCount, 1)
        )
    }

    private static func resolvedTextWidth(
        targetLineCount: Int,
        text: String,
        metrics: StyleMetrics,
        minTextWidth: CGFloat,
        maxTextWidth: CGFloat,
        maxTextHeight: CGFloat
    ) -> CGFloat {
        let minimumWidth = max(minTextWidth, 80)
        let maximumWidth = max(minimumWidth, maxTextWidth)
        guard targetLineCount > 0, maximumWidth > minimumWidth else {
            return maximumWidth
        }

        var lower = minimumWidth
        var upper = maximumWidth
        var bestWidth = maximumWidth
        var bestPenalty = Int.max

        for _ in 0..<12 {
            let candidateWidth = (lower + upper) / 2
            let font = fittedFont(
                preferredNames: metrics.preferredFontNames,
                defaultSize: metrics.defaultFontSize,
                minimumSize: metrics.minimumFontSize,
                maximumSize: metrics.maximumFontSize,
                text: text,
                metrics: metrics,
                maxTextWidth: candidateWidth,
                maxTextHeight: maxTextHeight
            )
            let attributed = attributedText(
                text: text,
                font: font,
                metrics: metrics
            )
            let layout = measuredLayout(for: attributed, maxWidth: candidateWidth)
            let penalty = abs(layout.lineCount - targetLineCount)
            if penalty < bestPenalty || (penalty == bestPenalty && candidateWidth < bestWidth) {
                bestPenalty = penalty
                bestWidth = candidateWidth
            }

            if layout.lineCount > targetLineCount {
                lower = candidateWidth + 6
            } else {
                upper = candidateWidth - 6
            }

            if lower >= upper {
                break
            }
        }

        return clamp(bestWidth, lower: minimumWidth, upper: maximumWidth)
    }

    private static func resolvedCenterX(
        request: OverlayRequest,
        frameWidth: CGFloat,
        canvasSize: CGSize,
        insets: Insets,
        metrics: StyleMetrics
    ) -> CGFloat {
        if request.rect.width > 0 {
            switch request.horizontalAnchor {
            case .left:
                return request.rect.minX + (frameWidth / 2)
            case .center:
                return request.rect.midX
            case .right:
                return request.rect.maxX - (frameWidth / 2)
            }
        }

        if request.rect.minX > 0 {
            return request.rect.minX + (frameWidth / 2)
        }

        switch request.horizontalAnchor {
        case .left:
            return insets.left + (frameWidth / 2)
        case .center:
            return canvasSize.width * metrics.defaultCenterXFraction
        case .right:
            return canvasSize.width - insets.right - (frameWidth / 2)
        }
    }

    private static func resolvedTop(
        request: OverlayRequest,
        frameHeight: CGFloat,
        canvasSize: CGSize,
        metrics: StyleMetrics
    ) -> CGFloat {
        if let topFraction = request.topFraction {
            return canvasSize.height * topFraction
        }

        if request.rect.height > 0 {
            let slotTop = request.rect.minY
            let slotBottom = request.rect.maxY
            let maxTopInSlot = max(slotTop, slotBottom - frameHeight)
            switch request.verticalAnchor {
            case .top:
                return slotTop
            case .center:
                return slotTop + max((request.rect.height - frameHeight) / 2, 0)
            case .bottom:
                return maxTopInSlot
            }
        }

        if request.rect.minY > 0 {
            return request.rect.minY
        }

        return canvasSize.height * metrics.defaultTopFraction
    }

    private static func platformFont(preferredNames: [String], size: CGFloat) -> OverlayPlatformFont {
        let resolvedSize = max(size, 12)
        for fontName in preferredNames {
            if let font = OverlayPlatformFont(name: fontName, size: resolvedSize) {
                return font
            }
        }

        #if canImport(UIKit)
        return .systemFont(ofSize: resolvedSize, weight: .bold)
        #else
        return .systemFont(ofSize: resolvedSize, weight: .bold)
        #endif
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }

    private static let transparent = OverlayPlatformColor(white: 0.0, alpha: 0.0)
}

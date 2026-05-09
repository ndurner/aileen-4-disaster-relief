import AVFoundation
import CoreImage
import CoreText
import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct MediaToolResult {
    let name: String
    let payload: [String: Any]
    let outputURL: URL?
}

enum SyntheticMediaDisclosureRenderer {
    private enum ImageFileType {
        case png
        case jpeg
        case heic

        var pathExtension: String {
            switch self {
            case .png:
                return "png"
            case .jpeg:
                return "jpg"
            case .heic:
                return "heic"
            }
        }

        var utType: UTType {
            switch self {
            case .png:
                return .png
            case .jpeg:
                return .jpeg
            case .heic:
                return .heic
            }
        }
    }

    static func renderBadge(on url: URL) async throws -> URL {
        switch MediaAsset.kind(for: url) {
        case .image:
            return try renderImageBadge(on: url)
        case .movie:
            return try await renderVideoBadge(on: url)
        }
    }

    private static func renderImageBadge(on url: URL) throws -> URL {
        guard let image = UIImage(contentsOfFile: url.path) else {
            throw MediaToolingError.imageLoadFailed("Unable to load rendered image for synthetic disclosure.")
        }

        let fileType = imageFileType(for: url) ?? .jpeg
        let canvasSize = image.size
        let outputURL = outputURL(for: fileType.pathExtension)
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: rendererFormat())
        let rendered = renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: canvasSize))
            drawBadge(in: context.cgContext, canvasSize: canvasSize)
        }

        try writeImage(rendered, to: outputURL, fileType: fileType)
        return outputURL
    }

    private static func renderVideoBadge(on url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw MediaToolingError.videoTrackMissing("No video track found for synthetic disclosure.")
        }

        let rect = CGRect(origin: .zero, size: videoTrack.naturalSize).applying(videoTrack.preferredTransform)
        let canvasSize = CGSize(width: abs(rect.width), height: abs(rect.height))
        guard let badgeCGImage = badgeImage(canvasSize: canvasSize) else {
            throw MediaToolingError.imageLoadFailed("Unable to render synthetic disclosure badge.")
        }
        let badgeImage = CIImage(cgImage: badgeCGImage)
        let videoComposition = AVVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
            let compositedImage = badgeImage
                .composited(over: request.sourceImage)
                .cropped(to: request.sourceImage.extent)
            request.finish(with: compositedImage, context: nil)
        })

        let outputURL = outputURL(for: "mp4")
        try await exportVideo(asset: asset, videoComposition: videoComposition, outputURL: outputURL)
        return outputURL
    }

    private static func badgeImage(canvasSize: CGSize) -> CGImage? {
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: rendererFormat())
        return renderer.image { context in
            drawBadge(in: context.cgContext, canvasSize: canvasSize)
        }.cgImage
    }

    private static func drawBadge(in context: CGContext, canvasSize: CGSize) {
        let fontSize = max(24, min(34, canvasSize.width * 0.028))
        let font = UIFont(name: "Georgia-BoldItalic", size: fontSize)
            ?? UIFont(name: "TimesNewRomanPS-BoldItalicMT", size: fontSize)
            ?? UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white.withAlphaComponent(0.96),
            .kern: 0.4,
            .paragraphStyle: paragraph
        ]
        let text = "AI" as NSString
        let textSize = text.size(withAttributes: attributes)
        let diameter = ceil(max(textSize.width, textSize.height) + fontSize * 0.58)
        let inset = max(22, canvasSize.width * 0.026)
        let rect = CGRect(x: inset, y: inset, width: diameter, height: diameter)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 5, color: UIColor.black.withAlphaComponent(0.26).cgColor)
        UIColor.black.withAlphaComponent(0.64).setFill()
        context.fillEllipse(in: rect)
        context.restoreGState()

        let textRect = CGRect(
            x: rect.minX,
            y: rect.midY - textSize.height / 2,
            width: rect.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attributes)
    }

    private static func writeImage(_ image: UIImage, to outputURL: URL, fileType: ImageFileType) throws {
        guard let cgImage = image.cgImage else {
            throw MediaToolingError.imageLoadFailed("Unable to encode synthetic disclosure image.")
        }
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, fileType.utType.identifier as CFString, 1, nil) else {
            throw MediaToolingError.imageLoadFailed("Unable to create synthetic disclosure image destination.")
        }

        let options: CFDictionary?
        switch fileType {
        case .png:
            options = nil
        case .jpeg, .heic:
            options = [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        }

        CGImageDestinationAddImage(destination, cgImage, options)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaToolingError.imageLoadFailed("Unable to encode synthetic disclosure image.")
        }
    }

    private static func exportVideo(asset: AVAsset, videoComposition: AVVideoComposition, outputURL: URL) async throws {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw MediaToolingError.exportFailed("Unable to create AVAssetExportSession for synthetic disclosure.")
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        exporter.videoComposition = videoComposition

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume(returning: ())
                case .failed, .cancelled:
                    let message = exporter.error?.localizedDescription ?? "Export failed."
                    continuation.resume(throwing: MediaToolingError.exportFailed(message))
                default:
                    continuation.resume(throwing: MediaToolingError.exportFailed("Export finished in unexpected state \(exporter.status.rawValue)."))
                }
            }
        }
    }

    private static func outputURL(for pathExtension: String) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AileenOutputs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(pathExtension)
    }

    private static func rendererFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return format
    }

    private static func imageFileType(for url: URL) -> ImageFileType? {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return nil
        }
        if type.conforms(to: .png) {
            return .png
        }
        if type.conforms(to: .heic) {
            return .heic
        }
        if type.conforms(to: .jpeg) {
            return .jpeg
        }
        return nil
    }
}

enum MediaToolingError: LocalizedError {
    case unsupportedTool(String)
    case invalidArguments(String)
    case missingAsset(String)
    case imageLoadFailed(String)
    case videoTrackMissing(String)
    case exportFailed(String)
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedTool(let name):
            return "Unsupported media tool call: \(name)"
        case .invalidArguments(let message),
             .missingAsset(let message),
             .imageLoadFailed(let message),
             .videoTrackMissing(let message),
             .exportFailed(let message),
             .writerFailed(let message):
            return message
        }
    }
}

final class AppleMediaTooling: @unchecked Sendable {
    static let imageCanvasSize = CGSize(width: 1080, height: 1350)
    static let reelCanvasSize = CGSize(width: 1080, height: 1920)

    private struct RenderedAsset {
        let toolID: String
        let url: URL
        let kind: MediaAsset.Kind
        let canvasSize: CGSize
        let preferredImageFileType: ImageFileType?
        let overlayFingerprint: String?
        let baseAssetID: String?
        let latestOverlayRequest: OverlayRequest?
    }

    private enum ImageFileType {
        case png
        case jpeg
        case heic

        var pathExtension: String {
            switch self {
            case .png:
                return "png"
            case .jpeg:
                return "jpg"
            case .heic:
                return "heic"
            }
        }

        var utType: UTType {
            switch self {
            case .png:
                return .png
            case .jpeg:
                return .jpeg
            case .heic:
                return .heic
            }
        }
    }

    private var assets: [String: RenderedAsset]
    private var nextRenderedAssetIndex = 1
    private var assetsWithRejectedPartialRect = Set<String>()
    private let outputKind: ProductionWorkflowViewModel.OutputKind
    private let renderCanvasSize: CGSize
    private let protectedRegionProvider: OverlayProtectedRegionProvider
    private let protectedRegionsOverride: OverlayProtectedRegions
    private let layoutGuideOverride: OverlayLayoutGuide

    init(
        sourceAssets: [ProductionAssetDescriptor],
        outputKind: ProductionWorkflowViewModel.OutputKind,
        protectedRegionProvider: OverlayProtectedRegionProvider = .none,
        protectedRegionsOverride: OverlayProtectedRegions = .empty,
        layoutGuideOverride: OverlayLayoutGuide = .empty
    ) {
        self.outputKind = outputKind
        self.renderCanvasSize = Self.renderCanvasSize(for: outputKind)
        self.protectedRegionProvider = protectedRegionProvider
        self.protectedRegionsOverride = protectedRegionsOverride
        self.layoutGuideOverride = layoutGuideOverride
        self.assets = Dictionary(uniqueKeysWithValues: sourceAssets.map { descriptor in
            let size = Self.sourceCanvasSize(for: descriptor.mediaAsset)
            return (
                descriptor.toolID,
                RenderedAsset(
                    toolID: descriptor.toolID,
                    url: descriptor.mediaAsset.localCopyURL,
                    kind: descriptor.mediaAsset.kind,
                    canvasSize: size,
                    preferredImageFileType: Self.imageFileType(for: descriptor.mediaAsset.localCopyURL),
                    overlayFingerprint: nil,
                    baseAssetID: nil,
                    latestOverlayRequest: nil
                )
            )
        })
    }

    func execute(toolCall: LiteRTToolCall) async throws -> MediaToolResult {
        switch toolCall.name {
        case "compose_visuals":
            return try await composeVisuals(arguments: toolCall.arguments)
        case "add_text_overlay":
            return try await addTextOverlay(arguments: toolCall.arguments)
        case "move_text_overlay":
            return try await moveTextOverlay(arguments: toolCall.arguments)
        case "accept_overlay_layout":
            return try acceptOverlayLayout(arguments: toolCall.arguments)
        default:
            throw MediaToolingError.unsupportedTool(toolCall.name)
        }
    }

    func makeOverlayReviewAssets(
        renderedAssetID: String,
        renderedURL: URL,
        reviewContext: OverlayReviewContext?
    ) throws -> [ProductionAssetDescriptor] {
        guard let reviewContext,
              let x = reviewContext.x,
              let y = reviewContext.y,
              let width = reviewContext.width,
              let height = reviewContext.height else {
            return []
        }

        let currentAsset = try resolveAsset(renderedAssetID)
        let sourceAssetID = reviewContext.sourceAssetID ?? currentAsset.baseAssetID
        guard let sourceAssetID,
              let sourceAsset = try? resolveAsset(sourceAssetID),
              sourceAsset.kind == .image else {
            return []
        }

        let rect = CGRect(
            x: CGFloat(x),
            y: CGFloat(y),
            width: CGFloat(max(width, 1)),
            height: CGFloat(max(height, 1))
        )
        let outlineURL = try renderOverlayReviewOutline(on: sourceAsset.url, overlayRect: rect)
        let gridURL = try renderOverlayReviewGrid(on: renderedURL)
        return [
            ProductionAssetDescriptor(
                toolID: "review_outline",
                mediaAsset: MediaAsset(
                    kind: .image,
                    originalURL: outlineURL,
                    localCopyURL: outlineURL,
                    displayName: outlineURL.lastPathComponent
                )
            ),
            ProductionAssetDescriptor(
                toolID: "review_grid",
                mediaAsset: MediaAsset(
                    kind: .image,
                    originalURL: gridURL,
                    localCopyURL: gridURL,
                    displayName: gridURL.lastPathComponent
                )
            )
        ]
    }

    private func composeVisuals(arguments: [String: LiteRTToolValue]) async throws -> MediaToolResult {
        guard let assetIDs = composeAssetIDs(from: arguments), !assetIDs.isEmpty else {
            throw MediaToolingError.invalidArguments("compose_visuals requires one or more asset_ids.")
        }

        let sourceAssets = try assetIDs.map(resolveAsset)
        let renderedAsset: RenderedAsset
        switch outputKind {
        case .image:
            let imageFileType = sourceAssets.compactMap(\.preferredImageFileType).first ?? .jpeg
            let outputURL = try renderImageMontage(from: sourceAssets, canvasSize: renderCanvasSize, fileType: imageFileType)
            renderedAsset = registerRenderedAsset(url: outputURL, kind: .image, canvasSize: renderCanvasSize, preferredImageFileType: imageFileType)
        case .reel:
            let outputURL = try await renderReel(from: sourceAssets, canvasSize: renderCanvasSize)
            renderedAsset = registerRenderedAsset(url: outputURL, kind: .movie, canvasSize: renderCanvasSize, preferredImageFileType: nil)
        }

        return MediaToolResult(
            name: "compose_visuals",
            payload: [
                "status": "success",
                "asset_id": renderedAsset.toolID,
                "width": Int(renderedAsset.canvasSize.width),
                "height": Int(renderedAsset.canvasSize.height)
            ],
            outputURL: renderedAsset.url
        )
    }

    private func addTextOverlay(arguments: [String: LiteRTToolValue]) async throws -> MediaToolResult {
        guard let assetID = toolAssetID(from: arguments) else {
            throw MediaToolingError.invalidArguments("add_text_overlay requires asset_id and overlay_text.")
        }

        var asset = try resolveAsset(assetID)
        if asset.baseAssetID == nil && asset.latestOverlayRequest == nil {
            asset = try await materializeSourceAssetForOverlay(asset)
        }
        if asset.latestOverlayRequest != nil {
            return try await moveTextOverlay(arguments: arguments)
        }
        let requestedOverlay = try overlayRequest(
            from: arguments,
            defaultingTo: nil,
            requireText: true
        )
        let overlay = resolvedOverlayRequest(
            from: requestedOverlay,
            using: layoutGuideOverride,
            canvasSize: asset.canvasSize
        )
        let protectedRegions = try protectedRegions(for: asset)
        let resolvedOverlay = OverlayRendering.resolve(
            overlay,
            canvasSize: asset.canvasSize,
            protectedRegions: protectedRegions
        )
        let overlayFingerprint = Self.overlayFingerprint(for: resolvedOverlay)
        if asset.overlayFingerprint == overlayFingerprint {
            return MediaToolResult(
                name: "add_text_overlay",
                payload: overlayPayload(
                    status: "skipped_duplicate",
                    renderedAsset: asset,
                    sourceAssetID: asset.toolID,
                    overlay: resolvedOverlay,
                    accepted: false
                ),
                outputURL: asset.url
            )
        }

        let outputURL: URL
        switch asset.kind {
        case .image:
            outputURL = try renderImageOverlay(on: asset, overlay: resolvedOverlay)
        case .movie:
            outputURL = try await renderVideoOverlay(on: asset, overlay: resolvedOverlay)
        }

        let renderedAsset = registerRenderedAsset(
            url: outputURL,
            kind: asset.kind,
            canvasSize: asset.canvasSize,
            preferredImageFileType: asset.preferredImageFileType,
            overlayFingerprint: overlayFingerprint,
            baseAssetID: asset.toolID,
            latestOverlayRequest: resolvedOverlay.request
        )
        return MediaToolResult(
            name: "add_text_overlay",
            payload: overlayPayload(
                status: "success",
                renderedAsset: renderedAsset,
                sourceAssetID: asset.toolID,
                overlay: resolvedOverlay,
                accepted: false
            ),
            outputURL: renderedAsset.url
        )
    }

    private func moveTextOverlay(arguments: [String: LiteRTToolValue]) async throws -> MediaToolResult {
        guard let assetID = toolAssetID(from: arguments) else {
            throw MediaToolingError.invalidArguments("move_text_overlay requires asset_id.")
        }

        let currentAsset = try resolveAsset(assetID)
        guard let previousOverlay = currentAsset.latestOverlayRequest else {
            throw MediaToolingError.invalidArguments("move_text_overlay requires an asset with an existing overlay.")
        }
        if let partialRectError = Self.partialExplicitRectError(arguments) {
            assetsWithRejectedPartialRect.insert(currentAsset.toolID)
            return MediaToolResult(
                name: "move_text_overlay",
                payload: [
                    "status": "invalid_partial_rect",
                    "asset_id": currentAsset.toolID,
                    "accepted": false,
                    "error": partialRectError,
                    "required_coordinates": ["x", "y", "width", "height"]
                ],
                outputURL: currentAsset.url
            )
        }
        let upperRetryError = Self.upperRowRetryError(
            arguments,
            afterRejectedPartialRect: assetsWithRejectedPartialRect.contains(currentAsset.toolID)
        )
        let upperMoveError = Self.upperRowMoveError(arguments)
        if let error = upperRetryError ?? upperMoveError {
            return MediaToolResult(
                name: "move_text_overlay",
                payload: [
                    "status": upperRetryError == nil ? "invalid_upper_move" : "invalid_upper_retry",
                    "asset_id": currentAsset.toolID,
                    "accepted": false,
                    "error": error,
                    "required_coordinates": ["x", "y", "width", "height"]
                ],
                outputURL: currentAsset.url
            )
        }
        let baseAssetID = currentAsset.baseAssetID ?? assetID
        let baseAsset = try resolveAsset(baseAssetID)
        let requestedOverlay = try overlayRequest(
            from: arguments,
            defaultingTo: previousOverlay,
            requireText: false
        )
        let overlay = resolvedOverlayRequest(
            from: requestedOverlay,
            using: layoutGuideOverride,
            canvasSize: baseAsset.canvasSize
        )
        let protectedRegions = try protectedRegions(for: baseAsset)
        let resolvedOverlay = OverlayRendering.resolve(
            overlay,
            canvasSize: baseAsset.canvasSize,
            protectedRegions: protectedRegions
        )
        let overlayFingerprint = Self.overlayFingerprint(for: resolvedOverlay)
        if currentAsset.overlayFingerprint == overlayFingerprint {
            return MediaToolResult(
                name: "move_text_overlay",
                payload: overlayPayload(
                    status: "skipped_duplicate",
                    renderedAsset: currentAsset,
                    sourceAssetID: baseAsset.toolID,
                    overlay: resolvedOverlay,
                    accepted: false
                ),
                outputURL: currentAsset.url
            )
        }

        let outputURL: URL
        switch baseAsset.kind {
        case .image:
            outputURL = try renderImageOverlay(on: baseAsset, overlay: resolvedOverlay)
        case .movie:
            outputURL = try await renderVideoOverlay(on: baseAsset, overlay: resolvedOverlay)
        }

        let renderedAsset = registerRenderedAsset(
            url: outputURL,
            kind: baseAsset.kind,
            canvasSize: baseAsset.canvasSize,
            preferredImageFileType: baseAsset.preferredImageFileType,
            overlayFingerprint: overlayFingerprint,
            baseAssetID: baseAsset.toolID,
            latestOverlayRequest: resolvedOverlay.request
        )
        return MediaToolResult(
            name: "move_text_overlay",
            payload: overlayPayload(
                status: "success",
                renderedAsset: renderedAsset,
                sourceAssetID: baseAsset.toolID,
                overlay: resolvedOverlay,
                accepted: false
            ),
            outputURL: renderedAsset.url
        )
    }

    private func acceptOverlayLayout(arguments: [String: LiteRTToolValue]) throws -> MediaToolResult {
        guard let assetID = toolAssetID(from: arguments) else {
            throw MediaToolingError.invalidArguments("accept_overlay_layout requires asset_id.")
        }
        let asset = try resolveAsset(assetID)
        return MediaToolResult(
            name: "accept_overlay_layout",
            payload: [
                "status": "accepted",
                "asset_id": asset.toolID,
                "accepted": true
            ],
            outputURL: nil
        )
    }

    private func materializeSourceAssetForOverlay(_ asset: RenderedAsset) async throws -> RenderedAsset {
        switch outputKind {
        case .image:
            let imageFileType = asset.preferredImageFileType ?? .jpeg
            let outputURL = try renderImageMontage(from: [asset], canvasSize: renderCanvasSize, fileType: imageFileType)
            return registerRenderedAsset(
                url: outputURL,
                kind: .image,
                canvasSize: renderCanvasSize,
                preferredImageFileType: imageFileType,
                baseAssetID: asset.toolID
            )
        case .reel:
            let outputURL = try await renderReel(from: [asset], canvasSize: renderCanvasSize)
            return registerRenderedAsset(
                url: outputURL,
                kind: .movie,
                canvasSize: renderCanvasSize,
                preferredImageFileType: nil,
                baseAssetID: asset.toolID
            )
        }
    }

    private func resolvedOverlayRequest(
        from request: OverlayRequest,
        using guide: OverlayLayoutGuide,
        canvasSize: CGSize
    ) -> OverlayRequest {
        OverlayLayoutGuidance.requestByApplyingGuide(
            request,
            guide: guide,
            canvasSize: canvasSize
        )
    }

    private func resolveAsset(_ toolID: String) throws -> RenderedAsset {
        guard let asset = assets[toolID] else {
            throw MediaToolingError.missingAsset("Unknown asset_id \(toolID).")
        }
        return asset
    }

    private func renderOverlayReviewOutline(on imageURL: URL, overlayRect: CGRect) throws -> URL {
        guard let image = UIImage(contentsOfFile: imageURL.path) else {
            throw MediaToolingError.imageLoadFailed("Unable to load review outline image.")
        }

        let canvasSize = image.size
        let outputURL = outputURL(for: "jpg")
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: Self.rendererFormat())
        let rendered = renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: canvasSize))
            let cgContext = context.cgContext
            let scaleX = canvasSize.width / max(renderCanvasSize.width, 1)
            let scaleY = canvasSize.height / max(renderCanvasSize.height, 1)
            let scaledRect = CGRect(
                x: overlayRect.minX * scaleX,
                y: overlayRect.minY * scaleY,
                width: overlayRect.width * scaleX,
                height: overlayRect.height * scaleY
            )
            let radius = max(16, min(32, min(scaledRect.width, scaledRect.height) * 0.16))
            let path = UIBezierPath(roundedRect: scaledRect, cornerRadius: radius)
            cgContext.saveGState()
            UIColor(red: 1.0, green: 0.15, blue: 0.15, alpha: 0.12).setFill()
            path.fill()
            UIColor(red: 1.0, green: 0.15, blue: 0.15, alpha: 0.96).setStroke()
            path.lineWidth = max(6, canvasSize.width / 150)
            path.stroke()
            cgContext.restoreGState()
        }

        try writeImage(rendered, to: outputURL, fileType: .jpeg)
        return outputURL
    }

    private func renderOverlayReviewGrid(on imageURL: URL) throws -> URL {
        guard let image = UIImage(contentsOfFile: imageURL.path) else {
            throw MediaToolingError.imageLoadFailed("Unable to load review grid image.")
        }

        let canvasSize = image.size
        let outputURL = outputURL(for: "jpg")
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: Self.rendererFormat())
        let rendered = renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: canvasSize))
            drawOverlayReviewGrid(in: context.cgContext, canvasSize: canvasSize)
        }

        try writeImage(rendered, to: outputURL, fileType: .jpeg)
        return outputURL
    }

    private func drawOverlayReviewGrid(in context: CGContext, canvasSize: CGSize) {
        let columns = 6
        let rows = 6
        let columnWidth = canvasSize.width / CGFloat(columns)
        let rowHeight = canvasSize.height / CGFloat(rows)
        let labelFont = UIFont.boldSystemFont(ofSize: max(22, canvasSize.width * 0.026))
        let axisFont = UIFont.boldSystemFont(ofSize: max(16, canvasSize.width * 0.018))
        let anchorFont = UIFont.boldSystemFont(ofSize: max(14, canvasSize.width * 0.015))
        let labelColor = UIColor(red: 0.06, green: 0.08, blue: 0.1, alpha: 0.94)

        context.saveGState()
        context.setLineWidth(3)
        context.setStrokeColor(UIColor(red: 1.0, green: 0.85, blue: 0.25, alpha: 0.58).cgColor)
        for index in 0...columns {
            let x = CGFloat(index) * columnWidth
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: canvasSize.height))
            context.strokePath()
            drawReviewLabel("x\(Int(round(x)))", at: CGPoint(x: min(max(x + 5, 4), canvasSize.width - 90), y: 4), font: axisFont, color: labelColor)
        }
        for index in 0...rows {
            let y = CGFloat(index) * rowHeight
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: canvasSize.width, y: y))
            context.strokePath()
            drawReviewLabel("y\(Int(round(y)))", at: CGPoint(x: 4, y: min(max(y + 5, 4), canvasSize.height - 32)), font: axisFont, color: labelColor)
        }

        for row in 0..<rows {
            for column in 0..<columns {
                let left = CGFloat(column) * columnWidth
                let top = CGFloat(row) * rowHeight
                let center = CGPoint(x: left + columnWidth / 2, y: top + rowHeight / 2)
                let cellLabel = "\(Character(UnicodeScalar(65 + column)!))\(row + 1)"
                drawReviewLabel(cellLabel, at: CGPoint(x: left + 8, y: top + 8), font: labelFont, color: labelColor)
                context.setFillColor(UIColor(red: 0.0, green: 0.58, blue: 1.0, alpha: 0.86).cgColor)
                context.fillEllipse(in: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
                drawReviewLabel(
                    "\(Int(round(center.x))),\(Int(round(center.y)))",
                    at: CGPoint(x: center.x - 42, y: center.y + 8),
                    font: anchorFont,
                    color: UIColor(red: 0.0, green: 0.28, blue: 0.58, alpha: 0.96)
                )
            }
        }
        context.restoreGState()
    }

    private func drawReviewLabel(_ text: String, at origin: CGPoint, font: UIFont, color: UIColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let size = text.size(withAttributes: attributes)
        let rect = CGRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 8)
        let background = UIBezierPath(roundedRect: rect, cornerRadius: 6)
        UIColor.white.withAlphaComponent(0.76).setFill()
        background.fill()
        text.draw(in: rect.insetBy(dx: 6, dy: 4), withAttributes: attributes)
    }

    private func toolAssetID(from arguments: [String: LiteRTToolValue], key: String = "asset_id") -> String? {
        guard let raw = arguments[key]?.stringValue else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return normalizedAssetID(from: trimmed) ?? trimmed
    }

    private func normalizedAssetID(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if assets[trimmed] != nil {
            return trimmed
        }

        let pattern = #"(?:asset|rendered)_\d+"#
        guard let range = trimmed.range(of: pattern, options: .regularExpression) else {
            return nil
        }

        let candidate = String(trimmed[range])
        if assets[candidate] != nil {
            return candidate
        }

        let loosePattern = #"\b(asset|rendered)_+(\d+)\b"#
        if let looseRange = trimmed.range(of: loosePattern, options: .regularExpression) {
            let looseCandidate = String(trimmed[looseRange])
                .replacingOccurrences(of: #"_+"#, with: "_", options: .regularExpression)
            if assets[looseCandidate] != nil {
                return looseCandidate
            }
        }

        if trimmed.contains("asset") {
            let sourceAssetIDs = assets.values
                .filter { $0.baseAssetID == nil && $0.toolID.hasPrefix("asset_") }
                .map(\.toolID)
                .sorted()
            if sourceAssetIDs.count == 1 {
                return sourceAssetIDs[0]
            }
        }

        if trimmed.contains("rendered") {
            let renderedAssetIDs = assets.keys
                .filter { $0.hasPrefix("rendered_") }
                .sorted()
            if renderedAssetIDs.count == 1 {
                return renderedAssetIDs[0]
            }
        }

        return nil
    }

    private func composeAssetIDs(from arguments: [String: LiteRTToolValue]) -> [String]? {
        if let assetIDs = arguments["asset_ids"]?.stringArrayValue?
            .map({ normalizedAssetID(from: $0) ?? $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty }),
           !assetIDs.isEmpty {
            return assetIDs
        }

        let sourceAssetIDs = assets.values
            .filter { $0.baseAssetID == nil }
            .map(\.toolID)
            .sorted()
        if sourceAssetIDs.count == 1 {
            return sourceAssetIDs
        }

        return nil
    }

    private func registerRenderedAsset(
        url: URL,
        kind: MediaAsset.Kind,
        canvasSize: CGSize,
        preferredImageFileType: ImageFileType?,
        overlayFingerprint: String? = nil,
        baseAssetID: String? = nil,
        latestOverlayRequest: OverlayRequest? = nil
    ) -> RenderedAsset {
        let toolID = "rendered_\(nextRenderedAssetIndex)"
        nextRenderedAssetIndex += 1
        let renderedAsset = RenderedAsset(
            toolID: toolID,
            url: url,
            kind: kind,
            canvasSize: canvasSize,
            preferredImageFileType: preferredImageFileType,
            overlayFingerprint: overlayFingerprint,
            baseAssetID: baseAssetID,
            latestOverlayRequest: latestOverlayRequest
        )
        assets[toolID] = renderedAsset
        return renderedAsset
    }

    private func overlayPayload(
        status: String,
        renderedAsset: RenderedAsset,
        sourceAssetID: String,
        overlay: ResolvedOverlay,
        accepted: Bool
    ) -> [String: Any] {
        let canvasWidth = max(renderedAsset.canvasSize.width, 1)
        let canvasHeight = max(renderedAsset.canvasSize.height, 1)
        return [
            "status": status,
            "asset_id": renderedAsset.toolID,
            "source_asset_id": sourceAssetID,
            "accepted": accepted,
            "style": overlay.style.rawValue,
            "x": Int(overlay.frame.minX.rounded()),
            "y": Int(overlay.frame.minY.rounded()),
            "overlay_width": Int(overlay.frame.width.rounded()),
            "overlay_height": Int(overlay.frame.height.rounded()),
            "resolved_left_fraction": Double(overlay.frame.minX / canvasWidth),
            "resolved_top_fraction": Double(overlay.frame.minY / canvasHeight),
            "resolved_width_fraction": Double(overlay.frame.width / canvasWidth),
            "resolved_height_fraction": Double(overlay.frame.height / canvasHeight),
            "resolved_center_x_fraction": Double(overlay.frame.midX / canvasWidth),
            "subject_overlap_fraction": Double(overlay.subjectOverlapFraction),
            "avoidance_overlap_fraction": Double(overlay.avoidanceOverlapFraction),
            "canvas_width": Int(renderedAsset.canvasSize.width),
            "canvas_height": Int(renderedAsset.canvasSize.height)
        ]
    }

    private func overlayRequest(
        from arguments: [String: LiteRTToolValue],
        defaultingTo previous: OverlayRequest?,
        requireText: Bool
    ) throws -> OverlayRequest {
        let overlayText = arguments["overlay_text"]?.stringValue ?? previous?.text
        guard let overlayText, !overlayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MediaToolingError.invalidArguments(requireText ? "Overlay text is required." : "move_text_overlay requires existing overlay text or a new overlay_text.")
        }

        let style = arguments["style"]?.stringValue.flatMap { OverlayStyle(rawValue: $0) } ?? previous?.style ?? .auto
        let horizontalAnchor = arguments["horizontal_anchor"]?.stringValue.flatMap { OverlayHorizontalAnchor(rawValue: $0) } ?? previous?.horizontalAnchor ?? .center
        let verticalAnchor = arguments["vertical_anchor"]?.stringValue.flatMap { OverlayVerticalAnchor(rawValue: $0) } ?? previous?.verticalAnchor ?? .top
        let explicitRectFields = ["x", "y", "width", "height"]
        let hasNormalizedOverride = arguments["top_fraction"] != nil || arguments["max_width_fraction"] != nil || arguments["target_line_count"] != nil
        let providedExplicitRectFields = Set(explicitRectFields.filter { arguments[$0] != nil })
        let hasCompleteExplicitRectOverride = providedExplicitRectFields.count == explicitRectFields.count
        let shouldUseExplicitRect = hasCompleteExplicitRectOverride

        let rect: CGRect
        if shouldUseExplicitRect {
            rect = CGRect(
                x: arguments["x"]?.numberValue ?? 0,
                y: arguments["y"]?.numberValue ?? 0,
                width: arguments["width"]?.numberValue ?? 0,
                height: arguments["height"]?.numberValue ?? 0
            )
        } else if hasNormalizedOverride {
            rect = .zero
        } else {
            rect = previous?.rect ?? .zero
        }

        let topFraction = shouldUseExplicitRect
            ? nil
            : arguments["top_fraction"]?.numberValue.map { CGFloat($0) } ?? previous?.topFraction
        let maxWidthFraction = shouldUseExplicitRect
            ? previous?.maxWidthFraction
            : arguments["max_width_fraction"]?.numberValue.map { CGFloat($0) } ?? previous?.maxWidthFraction
        let targetLineCount = arguments["target_line_count"]?.numberValue.map { Int($0.rounded()) } ?? previous?.targetLineCount

        return OverlayRequest(
            text: overlayText,
            rect: rect,
            style: style,
            topFraction: topFraction,
            maxWidthFraction: maxWidthFraction,
            targetLineCount: targetLineCount,
            horizontalAnchor: horizontalAnchor,
            verticalAnchor: verticalAnchor
        )
    }

    private static func partialExplicitRectError(_ arguments: [String: LiteRTToolValue]) -> String? {
        let explicitRectFields = ["x", "y", "width", "height"]
        let providedFields = explicitRectFields.filter { arguments[$0] != nil }
        guard !providedFields.isEmpty, providedFields.count != explicitRectFields.count else {
            return nil
        }
        let missingFields = explicitRectFields.filter { arguments[$0] == nil }
        return "Partial rectangle provided. Missing: \(missingFields.joined(separator: ", "))."
    }

    private static func upperRowRetryError(
        _ arguments: [String: LiteRTToolValue],
        afterRejectedPartialRect: Bool
    ) -> String? {
        guard afterRejectedPartialRect else {
            return nil
        }
        return upperRowMoveError(
            arguments,
            message: "Retry used a wide upper banner after a rejected partial move. Use a compact side/corner slot or open middle rows instead."
        )
    }

    private static func upperRowMoveError(
        _ arguments: [String: LiteRTToolValue],
        message: String? = nil
    ) -> String? {
        let explicitRectFields = ["x", "y", "width", "height"]
        guard explicitRectFields.allSatisfy({ arguments[$0] != nil }) else {
            return nil
        }
        let y = arguments["y"]?.numberValue
        let width = arguments["width"]?.numberValue
        if let y, y < 225 {
            if width == nil || (width ?? 0) > 560 {
                return message ?? "Correction move used a wide upper banner. Use a compact side/corner slot or open middle rows instead."
            }
        }
        return nil
    }

    private func protectedRegions(for asset: RenderedAsset) throws -> OverlayProtectedRegions {
        if !protectedRegionsOverride.isEmpty {
            return protectedRegionsOverride
        }
        switch protectedRegionProvider {
        case .none:
            return .empty
        case .appleVision:
            let previewImage = try previewImage(for: asset)
            return OverlaySubjectAnalysis.protectedRegions(
                for: previewImage,
                canvasSize: asset.canvasSize
            )
        }
    }

    private static func overlayFingerprint(for overlay: ResolvedOverlay) -> String {
        [
            overlay.style.rawValue,
            overlay.request.text,
            String(format: "%.3f", overlay.frame.minX),
            String(format: "%.3f", overlay.frame.minY),
            String(format: "%.3f", overlay.frame.width),
            String(format: "%.3f", overlay.frame.height)
        ].joined(separator: "|")
    }

    private func renderImageMontage(from sourceAssets: [RenderedAsset], canvasSize: CGSize, fileType: ImageFileType) throws -> URL {
        let outputURL = outputURL(for: fileType.pathExtension)
        let images = try normalizedMontageAssets(from: sourceAssets).map { try previewImage(for: $0) }
        let frames = Self.montageFrames(count: images.count, canvasSize: canvasSize)
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: Self.rendererFormat())
        let image = renderer.image { context in
            UIColor.black.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: canvasSize))
            for (image, frame) in zip(images, frames) {
                drawAspectFill(image: image, in: frame)
            }
        }

        try writeImage(image, to: outputURL, fileType: fileType)
        return outputURL
    }

    private func renderImageOverlay(on asset: RenderedAsset, overlay: ResolvedOverlay) throws -> URL {
        guard let image = UIImage(contentsOfFile: asset.url.path) else {
            throw MediaToolingError.imageLoadFailed("Unable to load image asset \(asset.toolID).")
        }
        let fileType = asset.preferredImageFileType ?? .jpeg
        let outputURL = outputURL(for: fileType.pathExtension)
        let renderer = UIGraphicsImageRenderer(size: asset.canvasSize, format: Self.rendererFormat())
        let rendered = renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: asset.canvasSize))
            OverlayRendering.draw(overlay, in: context.cgContext)
        }

        try writeImage(rendered, to: outputURL, fileType: fileType)
        return outputURL
    }

    private func renderReel(from sourceAssets: [RenderedAsset], canvasSize: CGSize) async throws -> URL {
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaToolingError.videoTrackMissing("Unable to create composition video track.")
        }

        var compositionAudioTrack: AVMutableCompositionTrack?
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        var cursorTime = CMTime.zero
        var temporaryURLs: [URL] = []
        defer { temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) } }

        for asset in sourceAssets {
            let clipURL: URL
            let clipDuration: CMTime

            if asset.kind == .image {
                clipDuration = CMTime(seconds: 3, preferredTimescale: 600)
                clipURL = try await makeStillVideoClip(from: try previewImage(for: asset), canvasSize: canvasSize, duration: clipDuration)
                temporaryURLs.append(clipURL)
            } else {
                clipURL = asset.url
                let movieAsset = AVURLAsset(url: clipURL)
                clipDuration = Self.minimumTime(movieAsset.duration, CMTime(seconds: 4, preferredTimescale: 600))
            }

            let clipAsset = AVURLAsset(url: clipURL)
            guard let sourceVideoTrack = clipAsset.tracks(withMediaType: .video).first else {
                throw MediaToolingError.videoTrackMissing("No video track found for \(asset.toolID).")
            }

            let timeRange = CMTimeRange(start: .zero, duration: clipDuration)
            try compositionVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: cursorTime)

            if let sourceAudioTrack = clipAsset.tracks(withMediaType: .audio).first {
                if compositionAudioTrack == nil {
                    compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                try compositionAudioTrack?.insertTimeRange(timeRange, of: sourceAudioTrack, at: cursorTime)
            }

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursorTime, duration: clipDuration)
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
            layerInstruction.setTransform(Self.transformToFit(track: sourceVideoTrack, renderSize: canvasSize), at: cursorTime)
            instruction.layerInstructions = [layerInstruction]
            instructions.append(instruction)
            cursorTime = CMTimeAdd(cursorTime, clipDuration)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = instructions
        videoComposition.renderSize = canvasSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let outputURL = outputURL(for: "mp4")
        try await exportVideo(
            asset: composition,
            videoComposition: videoComposition,
            outputURL: outputURL
        )
        return outputURL
    }

    private func renderVideoOverlay(on asset: RenderedAsset, overlay: ResolvedOverlay) async throws -> URL {
        let sourceAsset = AVURLAsset(url: asset.url)
        guard sourceAsset.tracks(withMediaType: .video).first != nil else {
            throw MediaToolingError.videoTrackMissing("No video track found for \(asset.toolID).")
        }

        guard let overlayCGImage = Self.overlayImage(for: overlay, canvasSize: asset.canvasSize) else {
            throw MediaToolingError.imageLoadFailed("Unable to render overlay image for \(asset.toolID).")
        }
        let overlayImage = CIImage(cgImage: overlayCGImage)
        let videoComposition = AVVideoComposition(asset: sourceAsset, applyingCIFiltersWithHandler: { request in
            let compositedImage = overlayImage
                .composited(over: request.sourceImage)
                .cropped(to: request.sourceImage.extent)
            request.finish(with: compositedImage, context: nil)
        })

        let outputURL = outputURL(for: "mp4")
        try await exportVideo(
            asset: sourceAsset,
            videoComposition: videoComposition,
            outputURL: outputURL
        )
        return outputURL
    }

    private func exportVideo(asset: AVAsset, videoComposition: AVVideoComposition, outputURL: URL) async throws {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw MediaToolingError.exportFailed("Unable to create AVAssetExportSession.")
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        exporter.videoComposition = videoComposition

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume(returning: ())
                case .failed, .cancelled:
                    let message = exporter.error?.localizedDescription ?? "Export failed."
                    continuation.resume(throwing: MediaToolingError.exportFailed(message))
                default:
                    continuation.resume(throwing: MediaToolingError.exportFailed("Export finished in unexpected state \(exporter.status.rawValue)."))
                }
            }
        }
    }

    private func makeStillVideoClip(from image: UIImage, canvasSize: CGSize, duration: CMTime) async throws -> URL {
        let outputURL = outputURL(for: "mp4")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(canvasSize.width),
            AVVideoHeightKey: Int(canvasSize.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(canvasSize.width),
            kCVPixelBufferHeightKey as String: Int(canvasSize.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)

        guard writer.canAdd(input) else {
            throw MediaToolingError.writerFailed("Unable to add video writer input.")
        }
        writer.add(input)

        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: Self.rendererFormat())
        let flattenedImage = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: canvasSize))
            drawAspectFill(image: image, in: CGRect(origin: .zero, size: canvasSize))
        }

        guard let pixelBuffer = Self.makePixelBuffer(from: flattenedImage, canvasSize: canvasSize) else {
            throw MediaToolingError.writerFailed("Unable to create pixel buffer for still clip.")
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameCount = max(1, Int(duration.seconds * 30))
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let time = CMTime(value: Int64(frame), timescale: 30)
            if !adaptor.append(pixelBuffer, withPresentationTime: time) {
                throw MediaToolingError.writerFailed(writer.error?.localizedDescription ?? "Failed to append still frame.")
            }
        }

        input.markAsFinished()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if let error = writer.error {
                    continuation.resume(throwing: MediaToolingError.writerFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
        return outputURL
    }

    private func previewImage(for asset: RenderedAsset) throws -> UIImage {
        switch asset.kind {
        case .image:
            guard let image = UIImage(contentsOfFile: asset.url.path) else {
                throw MediaToolingError.imageLoadFailed("Unable to load image asset \(asset.toolID).")
            }
            return image
        case .movie:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: asset.url))
            generator.appliesPreferredTrackTransform = true
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            return UIImage(cgImage: cgImage)
        }
    }

    private func writeImage(_ image: UIImage, to outputURL: URL, fileType: ImageFileType) throws {
        guard let cgImage = image.cgImage else {
            throw MediaToolingError.imageLoadFailed("Unable to encode rendered image.")
        }
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, fileType.utType.identifier as CFString, 1, nil) else {
            throw MediaToolingError.imageLoadFailed("Unable to create image destination.")
        }

        let options: CFDictionary?
        switch fileType {
        case .png:
            options = nil
        case .jpeg, .heic:
            options = [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        }

        CGImageDestinationAddImage(destination, cgImage, options)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaToolingError.imageLoadFailed("Unable to encode rendered image.")
        }
    }

    private func outputURL(for pathExtension: String) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AileenOutputs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(pathExtension)
    }

    private static func imageFileType(for url: URL) -> ImageFileType? {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return nil
        }
        if type.conforms(to: .png) {
            return .png
        }
        if type.conforms(to: .heic) {
            return .heic
        }
        if type.conforms(to: .jpeg) {
            return .jpeg
        }
        return nil
    }

    private func normalizedMontageAssets(from sourceAssets: [RenderedAsset]) -> [RenderedAsset] {
        let capped = Array(sourceAssets.prefix(4))
        guard capped.count == 3, let last = capped.last else {
            return capped
        }
        return capped + [last]
    }

    private func drawAspectFill(image: UIImage, in frame: CGRect) {
        UIColor.black.setFill()
        UIBezierPath(rect: frame).fill()
        image.draw(in: Self.aspectFillRect(for: image.size, in: frame))
    }

    private static func montageFrames(count: Int, canvasSize: CGSize) -> [CGRect] {
        switch count {
        case 1:
            return [CGRect(origin: .zero, size: canvasSize)]
        case 2:
            return [
                CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height / 2),
                CGRect(x: 0, y: canvasSize.height / 2, width: canvasSize.width, height: canvasSize.height / 2)
            ]
        default:
            let halfWidth = canvasSize.width / 2
            let halfHeight = canvasSize.height / 2
            return [
                CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight),
                CGRect(x: halfWidth, y: 0, width: halfWidth, height: halfHeight),
                CGRect(x: 0, y: halfHeight, width: halfWidth, height: halfHeight),
                CGRect(x: halfWidth, y: halfHeight, width: halfWidth, height: halfHeight)
            ]
        }
    }

    private static func transformToFit(track: AVAssetTrack, renderSize: CGSize) -> CGAffineTransform {
        let naturalSize = track.naturalSize
        let preferredTransform = track.preferredTransform
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let transformedSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
        let scale = max(renderSize.width / transformedSize.width, renderSize.height / transformedSize.height)

        var transform = preferredTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let scaledRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let tx = (renderSize.width - scaledRect.width) / 2 - scaledRect.minX
        let ty = (renderSize.height - scaledRect.height) / 2 - scaledRect.minY
        transform = transform.concatenating(CGAffineTransform(translationX: tx, y: ty))
        return transform
    }

    private static func minimumTime(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        CMTimeCompare(lhs, rhs) <= 0 ? lhs : rhs
    }

    static func renderCanvasSize(for outputKind: ProductionWorkflowViewModel.OutputKind) -> CGSize {
        switch outputKind {
        case .image:
            return imageCanvasSize
        case .reel:
            return reelCanvasSize
        }
    }

    private static func makeOverlayLayer(for overlay: ResolvedOverlay, canvasSize: CGSize) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: canvasSize)
        if let cgImage = overlayImage(for: overlay, canvasSize: canvasSize) {
            container.contents = cgImage
        }

        return container
    }

    private static func rendererFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return format
    }

    private static func transparentRendererFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return format
    }

    private static func aspectFillRect(for aspectSize: CGSize, in boundingRect: CGRect) -> CGRect {
        guard aspectSize.width > 0, aspectSize.height > 0 else {
            return boundingRect
        }

        let scale = max(boundingRect.width / aspectSize.width, boundingRect.height / aspectSize.height)
        let scaledSize = CGSize(width: aspectSize.width * scale, height: aspectSize.height * scale)
        let origin = CGPoint(
            x: boundingRect.midX - scaledSize.width / 2,
            y: boundingRect.midY - scaledSize.height / 2
        )
        return CGRect(origin: origin, size: scaledSize)
    }

    private static func overlayImage(for overlay: ResolvedOverlay, canvasSize: CGSize) -> CGImage? {
        OverlayRendering.makeOverlayCGImage(for: overlay, canvasSize: canvasSize)
    }

    private static func makePixelBuffer(from image: UIImage, canvasSize: CGSize) -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(canvasSize.width),
            Int(canvasSize.height),
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }

        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: canvasSize))
        guard let cgImage = image.cgImage else {
            return nil
        }
        context.draw(cgImage, in: CGRect(origin: .zero, size: canvasSize))
        return pixelBuffer
    }

    private static func sourceCanvasSize(for mediaAsset: MediaAsset) -> CGSize {
        switch mediaAsset.kind {
        case .image:
            guard let imageSource = CGImageSourceCreateWithURL(mediaAsset.localCopyURL as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
                  let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
                return Self.imageCanvasSize
            }
            return CGSize(width: width, height: height)
        case .movie:
            let asset = AVURLAsset(url: mediaAsset.localCopyURL)
            guard let track = asset.tracks(withMediaType: .video).first else {
                return Self.reelCanvasSize
            }
            let rect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
            return CGSize(width: abs(rect.width), height: abs(rect.height))
        }
    }

}

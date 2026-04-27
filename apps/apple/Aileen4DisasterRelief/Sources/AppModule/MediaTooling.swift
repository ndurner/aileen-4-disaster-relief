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
        return assets[candidate] == nil ? nil : candidate
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
        let hasExplicitRectOverride = !providedExplicitRectFields.isEmpty
        let hasCompleteExplicitRectOverride = providedExplicitRectFields.count == explicitRectFields.count
        let canReusePriorRect = previous?.rect.width ?? 0 > 0 && previous?.rect.height ?? 0 > 0
        let shouldUseExplicitRect = !hasNormalizedOverride && (hasCompleteExplicitRectOverride || (hasExplicitRectOverride && canReusePriorRect))

        let rect: CGRect
        if shouldUseExplicitRect {
            let priorRect = previous?.rect ?? .zero
            rect = CGRect(
                x: arguments["x"]?.numberValue ?? priorRect.minX,
                y: arguments["y"]?.numberValue ?? priorRect.minY,
                width: arguments["width"]?.numberValue ?? priorRect.width,
                height: arguments["height"]?.numberValue ?? priorRect.height
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

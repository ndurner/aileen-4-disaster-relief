import CoreGraphics
import Foundation
import Vision

#if canImport(UIKit)
import UIKit
#endif

enum OverlaySubjectAnalysis {
    static func protectedRegions(for image: UIImage, canvasSize: CGSize) -> OverlayProtectedRegions {
        guard let cgImage = normalizedCGImage(from: image) else {
            return .empty
        }

        let attentionRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        let objectnessRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)

        do {
            try handler.perform([attentionRequest, objectnessRequest, faceRequest])
        } catch {
            return .empty
        }

        let normalizedRects =
            salientRects(from: attentionRequest.results) +
            salientRects(from: objectnessRequest.results) +
            faceRects(from: faceRequest.results)
        let subjectRects = mergeNearbyRects(
            normalizedRects
                .map { denormalize($0, canvasSize: canvasSize) }
                .filter { isMeaningfulSubjectRect($0, canvasSize: canvasSize) }
        )
        guard !subjectRects.isEmpty else {
            return .empty
        }

        let avoidanceRects = mergeNearbyRects(
            subjectRects.map {
                padded(
                    $0,
                    dx: canvasSize.width * 0.05,
                    dy: canvasSize.height * 0.04,
                    canvasSize: canvasSize
                )
            }
        )
        return OverlayProtectedRegions(
            subjectRects: subjectRects,
            avoidanceRects: avoidanceRects
        )
    }

    private static func salientRects(from results: [VNSaliencyImageObservation]?) -> [CGRect] {
        guard let observations = results else { return [] }
        var rects: [CGRect] = []
        for observation in observations {
            guard let salientObjects = observation.salientObjects else { continue }
            for salientObject in salientObjects {
                rects.append(salientObject.boundingBox)
            }
        }
        return rects
    }

    private static func faceRects(from results: [VNFaceObservation]?) -> [CGRect] {
        guard let results else { return [] }
        return results.map(\.boundingBox)
    }

    private static func denormalize(_ rect: CGRect, canvasSize: CGSize) -> CGRect {
        CGRect(
            x: rect.minX * canvasSize.width,
            y: (1 - rect.maxY) * canvasSize.height,
            width: rect.width * canvasSize.width,
            height: rect.height * canvasSize.height
        ).integral
    }

    private static func isMeaningfulSubjectRect(_ rect: CGRect, canvasSize: CGSize) -> Bool {
        let widthFraction = rect.width / max(canvasSize.width, 1)
        let heightFraction = rect.height / max(canvasSize.height, 1)
        let areaFraction = (rect.width * rect.height) / max(canvasSize.width * canvasSize.height, 1)

        if widthFraction < 0.08 || heightFraction < 0.08 {
            return false
        }
        if areaFraction < 0.015 {
            return false
        }
        if widthFraction > 0.95 && heightFraction > 0.95 {
            return false
        }
        return true
    }

    private static func mergeNearbyRects(_ rects: [CGRect]) -> [CGRect] {
        var pending = rects.filter { !$0.isNull && !$0.isEmpty }
        var merged: [CGRect] = []

        while let current = pending.first {
            pending.removeFirst()
            var union = current
            var changed = true
            while changed {
                changed = false
                for (index, candidate) in pending.enumerated().reversed() {
                    if shouldMerge(union, candidate) {
                        union = union.union(candidate)
                        pending.remove(at: index)
                        changed = true
                    }
                }
            }
            merged.append(union.integral)
        }

        return merged
    }

    private static func shouldMerge(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        if lhs.intersects(rhs) {
            return true
        }

        let horizontalGap = max(0, max(lhs.minX, rhs.minX) - min(lhs.maxX, rhs.maxX))
        let verticalGap = max(0, max(lhs.minY, rhs.minY) - min(lhs.maxY, rhs.maxY))
        let widthThreshold = max(lhs.width, rhs.width) * 0.18
        let heightThreshold = max(lhs.height, rhs.height) * 0.18
        return horizontalGap <= widthThreshold && verticalGap <= heightThreshold
    }

    private static func padded(_ rect: CGRect, dx: CGFloat, dy: CGFloat, canvasSize: CGSize) -> CGRect {
        rect
            .insetBy(dx: -dx, dy: -dy)
            .intersection(CGRect(origin: .zero, size: canvasSize))
            .integral
    }

    private static func normalizedCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cgImage = image.cgImage {
            return cgImage
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let normalized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return normalized.cgImage
    }
}

import AVFoundation
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum PromptMediaEncoder {
    private static let directlySupportedImageExtensions: Set<String> = ["jpg", "jpeg", "png"]
    private static let inlineJPEGCompressionQuality: CGFloat = 0.82
    private static let maxInlineImageDimension: CGFloat = 1600

    struct InlineImageData {
        let mimeType: String
        let data: Data
    }

    struct UploadFile {
        let url: URL
        let mimeType: String
        let displayName: String
    }

    static func promptImageBlob(for asset: MediaAsset) throws -> String? {
        guard let inlineImage = try promptInlineImageData(for: asset) else {
            return nil
        }
        return inlineImage.data.base64EncodedString()
    }

    static func promptImageDataURL(for asset: MediaAsset) throws -> String? {
        guard let inlineImage = try promptInlineImageData(for: asset) else {
            return nil
        }
        return "data:\(inlineImage.mimeType);base64,\(inlineImage.data.base64EncodedString())"
    }

    static func promptInlineImageData(for asset: MediaAsset) throws -> InlineImageData? {
        switch asset.kind {
        case .image:
            let ext = asset.localCopyURL.pathExtension.lowercased()
            if ext == "jpg" || ext == "jpeg" {
                return InlineImageData(mimeType: "image/jpeg", data: try Data(contentsOf: asset.localCopyURL))
            }
            if ext == "png" {
                return InlineImageData(mimeType: "image/png", data: try Data(contentsOf: asset.localCopyURL))
            }
            return try makeNormalizedPromptJPEGData(for: asset.localCopyURL)
        case .movie:
            guard let previewURL = try makeVideoPreviewImage(for: asset.localCopyURL) else {
                return nil
            }
            return try makeNormalizedPromptJPEGData(for: previewURL)
        }
    }

    static func promptUploadFile(for asset: MediaAsset) throws -> UploadFile? {
        switch asset.kind {
        case .image:
            let ext = asset.localCopyURL.pathExtension.lowercased()
            if ext == "jpg" || ext == "jpeg" {
                return UploadFile(
                    url: asset.localCopyURL,
                    mimeType: "image/jpeg",
                    displayName: asset.displayName
                )
            }
            if ext == "png" {
                return UploadFile(
                    url: asset.localCopyURL,
                    mimeType: "image/png",
                    displayName: asset.displayName
                )
            }
            guard let normalizedURL = try makeNormalizedPromptJPEG(for: asset.localCopyURL) else {
                return nil
            }
            return UploadFile(
                url: normalizedURL,
                mimeType: "image/jpeg",
                displayName: normalizedURL.lastPathComponent
            )
        case .movie:
            guard let previewURL = try makeVideoPreviewImage(for: asset.localCopyURL) else {
                return nil
            }
            return UploadFile(
                url: previewURL,
                mimeType: "image/jpeg",
                displayName: previewURL.lastPathComponent
            )
        }
    }

    static func promptImageFileURL(for asset: MediaAsset) throws -> URL? {
        switch asset.kind {
        case .image:
            let ext = asset.localCopyURL.pathExtension.lowercased()
            if directlySupportedImageExtensions.contains(ext) {
                return asset.localCopyURL
            }
            return try makeNormalizedPromptPNG(for: asset.localCopyURL)
        case .movie:
            return try makeVideoPreviewImage(for: asset.localCopyURL)
        }
    }

    private static func makeVideoPreviewImage(for sourceURL: URL) throws -> URL? {
        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AileenPromptMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")

        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, options)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return outputURL
    }

    private static func makeNormalizedPromptJPEGData(for sourceURL: URL) throws -> InlineImageData? {
        guard let image = UIImage(contentsOfFile: sourceURL.path) else {
            return nil
        }
        let normalizedImage = image.preparingForInlinePrompt(maxDimension: maxInlineImageDimension)
        guard let data = normalizedImage.jpegData(compressionQuality: inlineJPEGCompressionQuality) else {
            return nil
        }
        return InlineImageData(mimeType: "image/jpeg", data: data)
    }

    private static func makeNormalizedPromptJPEG(for sourceURL: URL) throws -> URL? {
        guard let image = UIImage(contentsOfFile: sourceURL.path),
              let data = image.preparingForInlinePrompt(maxDimension: maxInlineImageDimension)
                .jpegData(compressionQuality: inlineJPEGCompressionQuality) else {
            return nil
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AileenPromptMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        try data.write(to: outputURL, options: .atomic)
        return outputURL
    }

    private static func makeNormalizedPromptPNG(for sourceURL: URL) throws -> URL? {
        guard let image = UIImage(contentsOfFile: sourceURL.path),
              let normalizedData = image.pngData() else {
            return nil
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AileenPromptMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        try normalizedData.write(to: outputURL, options: .atomic)
        return outputURL
    }
}

private extension UIImage {
    func preparingForInlinePrompt(maxDimension: CGFloat) -> UIImage {
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension, longestSide > 0 else {
            return normalizedForEncoding()
        }

        let scale = maxDimension / longestSide
        let targetSize = CGSize(
            width: max(1, floor(size.width * scale)),
            height: max(1, floor(size.height * scale))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            normalizedForEncoding().draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func normalizedForEncoding() -> UIImage {
        guard imageOrientation != .up else {
            return self
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

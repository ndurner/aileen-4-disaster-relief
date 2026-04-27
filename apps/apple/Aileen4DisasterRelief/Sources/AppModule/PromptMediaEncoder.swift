import AVFoundation
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum PromptMediaEncoder {
    private static let directlySupportedImageExtensions: Set<String> = ["jpg", "jpeg", "png"]

    static func promptImageBlob(for asset: MediaAsset) throws -> String? {
        guard let data = try promptImagePNGData(for: asset) else {
            return nil
        }
        return data.base64EncodedString()
    }

    static func promptImageDataURL(for asset: MediaAsset) throws -> String? {
        guard let blob = try promptImageBlob(for: asset) else {
            return nil
        }
        return "data:image/png;base64,\(blob)"
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

    private static func promptImagePNGData(for asset: MediaAsset) throws -> Data? {
        switch asset.kind {
        case .image:
            guard let image = UIImage(contentsOfFile: asset.localCopyURL.path),
                  let normalizedData = image.pngData() else {
                return nil
            }
            return normalizedData
        case .movie:
            guard let previewURL = try makeVideoPreviewImage(for: asset.localCopyURL),
                  let image = UIImage(contentsOfFile: previewURL.path),
                  let normalizedData = image.pngData() else {
                return nil
            }
            return normalizedData
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

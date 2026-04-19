import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

private struct LabTextObservation {
    let text: String
    let rect: CGRect
}

private struct LabTextCluster {
    var rect: CGRect
    var texts: [String]
}

private struct RenderConfiguration {
    var text = "Overlay text"
    var style: OverlayStyle = .auto
    var x: CGFloat = 160
    var y: CGFloat = 280
    var width: CGFloat = 720
    var height: CGFloat = 220
    var canvasSize = CGSize(width: 1080, height: 1350)
    var outputDirectory = URL(fileURLWithPath: "/tmp/aileen-overlay-lab", isDirectory: true)
    var inputPaths: [String] = []
}

@main
enum OverlayLabMain {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage()
            return
        }

        switch command {
        case "analyze":
            try analyze(paths: Array(arguments.dropFirst()))
        case "render":
            let configuration = try parseRenderConfiguration(arguments: Array(arguments.dropFirst()))
            try render(configuration: configuration)
        default:
            printUsage()
        }
    }

    private static func analyze(paths: [String]) throws {
        guard !paths.isEmpty else {
            throw NSError(domain: "OverlayLab", code: 1, userInfo: [NSLocalizedDescriptionKey: "Provide one or more image paths to analyze."])
        }

        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let image = loadImage(at: url) else {
                print("failed \(url.path)")
                continue
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])

            let observations = (request.results ?? []).compactMap { result -> LabTextObservation? in
                guard let candidate = result.topCandidates(1).first else {
                    return nil
                }
                let normalizedRect = CGRect(
                    x: result.boundingBox.minX,
                    y: 1 - result.boundingBox.maxY,
                    width: result.boundingBox.width,
                    height: result.boundingBox.height
                )
                return LabTextObservation(
                    text: candidate.string.replacingOccurrences(of: "\n", with: " "),
                    rect: normalizedRect
                )
            }

            let filtered = observations
                .filter { $0.rect.minY > 0.07 && $0.rect.minY < 0.72 }
                .filter { ($0.rect.width * $0.rect.height) > 0.004 || $0.rect.height > 0.02 }
                .sorted { $0.rect.minY < $1.rect.minY }
            let clusters = clustered(observations: filtered)

            print("FILE \(url.lastPathComponent)")
            if clusters.isEmpty {
                print("  no overlay-sized text clusters found")
            }
            for (index, cluster) in clusters.enumerated() {
                let summary = cluster.texts.joined(separator: " | ")
                print(
                    String(
                        format: "  cluster_%d top=%.3f left=%.3f width=%.3f height=%.3f text=%@",
                        index + 1,
                        cluster.rect.minY,
                        cluster.rect.minX,
                        cluster.rect.width,
                        cluster.rect.height,
                        summary
                    )
                )
            }
        }
    }

    private static func parseRenderConfiguration(arguments: [String]) throws -> RenderConfiguration {
        var configuration = RenderConfiguration()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--text":
                index += 1
                configuration.text = try requiredValue(after: index, in: arguments, flag: "--text")
            case "--style":
                index += 1
                let rawValue = try requiredValue(after: index, in: arguments, flag: "--style")
                guard let style = OverlayStyle(rawValue: rawValue) else {
                    throw NSError(domain: "OverlayLab", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown style \(rawValue)."])
                }
                configuration.style = style
            case "--x":
                index += 1
                configuration.x = try requiredNumber(after: index, in: arguments, flag: "--x")
            case "--y":
                index += 1
                configuration.y = try requiredNumber(after: index, in: arguments, flag: "--y")
            case "--width":
                index += 1
                configuration.width = try requiredNumber(after: index, in: arguments, flag: "--width")
            case "--height":
                index += 1
                configuration.height = try requiredNumber(after: index, in: arguments, flag: "--height")
            case "--canvas":
                index += 1
                configuration.canvasSize = try parseCanvasSize(try requiredValue(after: index, in: arguments, flag: "--canvas"))
            case "--output-dir":
                index += 1
                configuration.outputDirectory = URL(fileURLWithPath: try requiredValue(after: index, in: arguments, flag: "--output-dir"), isDirectory: true)
            default:
                configuration.inputPaths.append(argument)
            }
            index += 1
        }

        guard !configuration.inputPaths.isEmpty else {
            throw NSError(domain: "OverlayLab", code: 3, userInfo: [NSLocalizedDescriptionKey: "Provide one or more image paths to render."])
        }
        return configuration
    }

    private static func render(configuration: RenderConfiguration) throws {
        try FileManager.default.createDirectory(at: configuration.outputDirectory, withIntermediateDirectories: true)

        for path in configuration.inputPaths {
            let inputURL = URL(fileURLWithPath: path)
            guard let baseImage = NSImage(contentsOf: inputURL),
                  let cgImage = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                print("failed \(inputURL.path)")
                continue
            }
            guard let context = CGContext(
                data: nil,
                width: Int(configuration.canvasSize.width),
                height: Int(configuration.canvasSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw NSError(domain: "OverlayLab", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to create rendering context."])
            }

            context.translateBy(x: 0, y: configuration.canvasSize.height)
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(origin: .zero, size: configuration.canvasSize))
            let drawRect = aspectFillRect(
                for: CGSize(width: cgImage.width, height: cgImage.height),
                in: CGRect(origin: .zero, size: configuration.canvasSize)
            )
            let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext
            baseImage.draw(in: drawRect)
            NSGraphicsContext.restoreGraphicsState()

            let request = OverlayRequest(
                text: configuration.text,
                rect: CGRect(x: configuration.x, y: configuration.y, width: configuration.width, height: configuration.height),
                style: configuration.style
            )
            let resolved = OverlayRendering.resolve(request, canvasSize: configuration.canvasSize)
            OverlayRendering.draw(resolved, in: context)

            let outputURL = configuration.outputDirectory
                .appendingPathComponent("\(inputURL.deletingPathExtension().lastPathComponent)-\(resolved.style.rawValue).jpg")
            try writeJPEG(image: context.makeImage(), to: outputURL)

            print(
                "\(outputURL.path) style=\(resolved.style.rawValue) frame=\(Int(resolved.frame.minX)),\(Int(resolved.frame.minY)),\(Int(resolved.frame.width)),\(Int(resolved.frame.height))"
            )
        }
    }

    private static func clustered(observations: [LabTextObservation]) -> [LabTextCluster] {
        var clusters: [LabTextCluster] = []

        for observation in observations {
            if let lastIndex = clusters.indices.last,
               observation.rect.minY - clusters[lastIndex].rect.maxY <= 0.04 {
                clusters[lastIndex].rect = clusters[lastIndex].rect.union(observation.rect)
                clusters[lastIndex].texts.append(observation.text)
            } else {
                clusters.append(LabTextCluster(rect: observation.rect, texts: [observation.text]))
            }
        }

        return clusters
            .filter { $0.rect.width > 0.20 || $0.rect.height > 0.03 }
            .sorted { $0.rect.minY < $1.rect.minY }
    }

    private static func requiredValue(after index: Int, in arguments: [String], flag: String) throws -> String {
        guard index < arguments.count else {
            throw NSError(domain: "OverlayLab", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing value for \(flag)."])
        }
        return arguments[index]
    }

    private static func requiredNumber(after index: Int, in arguments: [String], flag: String) throws -> CGFloat {
        let value = try requiredValue(after: index, in: arguments, flag: flag)
        guard let number = Double(value) else {
            throw NSError(domain: "OverlayLab", code: 6, userInfo: [NSLocalizedDescriptionKey: "Expected numeric value for \(flag)."])
        }
        return number
    }

    private static func parseCanvasSize(_ rawValue: String) throws -> CGSize {
        let parts = rawValue.split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]) else {
            throw NSError(domain: "OverlayLab", code: 7, userInfo: [NSLocalizedDescriptionKey: "Canvas must be WIDTHxHEIGHT."])
        }
        return CGSize(width: width, height: height)
    }

    private static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func writeJPEG(image: CGImage?, to url: URL) throws {
        guard let image else {
            throw NSError(domain: "OverlayLab", code: 8, userInfo: [NSLocalizedDescriptionKey: "Unable to create output image."])
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "OverlayLab", code: 9, userInfo: [NSLocalizedDescriptionKey: "Unable to create JPEG destination."])
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "OverlayLab", code: 10, userInfo: [NSLocalizedDescriptionKey: "Unable to finalize JPEG output."])
        }
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

    private static func printUsage() {
        print("""
        overlay_lab.sh analyze /tmp/insta-samples/*
        overlay_lab.sh render --text \"Dry docked turtle rescue!\" --style headline --x 180 --y 280 --width 700 --height 140 /tmp/test-imgs/*
        """)
    }
}

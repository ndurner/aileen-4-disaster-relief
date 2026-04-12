import Foundation

struct FFmpegToolResult {
    let name: String
    let payload: [String: Any]
    let outputURL: URL?
}

enum FFmpegToolingError: LocalizedError {
    case unsupportedTool(String)
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedTool(let name):
            return "Unsupported FFmpeg tool call: \(name)"
        case .invalidArguments(let message):
            return message
        }
    }
}

struct FFmpegTooling {
    func execute(toolCall: LiteRTToolCall, ffmpegExecutablePath: String) throws -> FFmpegToolResult {
        switch toolCall.name {
        case "compose_visuals":
            return try composeVisuals(arguments: toolCall.arguments, ffmpegExecutablePath: ffmpegExecutablePath)
        case "add_overlay_rectangles":
            return try addOverlay(arguments: toolCall.arguments, ffmpegExecutablePath: ffmpegExecutablePath)
        default:
            throw FFmpegToolingError.unsupportedTool(toolCall.name)
        }
    }

    private func composeVisuals(arguments: [String: LiteRTToolValue], ffmpegExecutablePath: String) throws -> FFmpegToolResult {
        guard let mode = arguments["mode"]?.stringValue,
              let assetPaths = arguments["asset_paths"]?.stringArrayValue,
              !assetPaths.isEmpty else {
            throw FFmpegToolingError.invalidArguments("compose_visuals requires mode and asset_paths.")
        }

        let outputURL = outputURL(for: mode == "reel" ? "mp4" : "png")
        let command = [
            ffmpegExecutablePath,
            "-y",
            "-i", assetPaths.first ?? "",
            outputURL.path
        ]

        return FFmpegToolResult(
            name: "compose_visuals",
            payload: [
                "status": "planned",
                "mode": mode,
                "asset_paths": assetPaths,
                "output_path": outputURL.path,
                "ffmpeg_command": command.joined(separator: " ")
            ],
            outputURL: outputURL
        )
    }

    private func addOverlay(arguments: [String: LiteRTToolValue], ffmpegExecutablePath: String) throws -> FFmpegToolResult {
        guard let inputPath = arguments["input_path"]?.stringValue,
              let overlayText = arguments["overlay_text"]?.stringValue else {
            throw FFmpegToolingError.invalidArguments("add_overlay_rectangles requires input_path and overlay_text.")
        }

        let outputURL = outputURL(for: URL(fileURLWithPath: inputPath).pathExtension.isEmpty ? "mp4" : URL(fileURLWithPath: inputPath).pathExtension)
        let command = [
            ffmpegExecutablePath,
            "-y",
            "-i", inputPath,
            "-vf", "drawbox=x=20:y=20:w=400:h=120:color=black@0.55:t=fill,drawtext=text='\(overlayText)':x=40:y=60:fontsize=32:fontcolor=white",
            outputURL.path
        ]

        return FFmpegToolResult(
            name: "add_overlay_rectangles",
            payload: [
                "status": "planned",
                "input_path": inputPath,
                "output_path": outputURL.path,
                "overlay_text": overlayText,
                "ffmpeg_command": command.joined(separator: " ")
            ],
            outputURL: outputURL
        )
    }

    private func outputURL(for pathExtension: String) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AileenOutputs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(pathExtension)
    }
}

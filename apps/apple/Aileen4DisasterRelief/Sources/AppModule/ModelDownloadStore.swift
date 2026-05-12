import Foundation
import Combine

enum ModelDownloadState: Equatable {
    case idle
    case downloading(bytesWritten: Int64, bytesExpected: Int64?)
    case finishing
    case completed(Date)
    case failed(String)

    var isDownloading: Bool {
        switch self {
        case .downloading, .finishing:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }

    var progressFraction: Double? {
        guard case .downloading(let bytesWritten, let bytesExpected) = self,
              let bytesExpected,
              bytesExpected > 0 else {
            return nil
        }
        return min(max(Double(bytesWritten) / Double(bytesExpected), 0), 1)
    }

    var statusText: String {
        switch self {
        case .idle:
            return "Ready to download."
        case .downloading(let bytesWritten, let bytesExpected):
            if let bytesExpected, bytesExpected > 0 {
                return "\(Self.formattedBytes(bytesWritten)) of \(Self.formattedBytes(bytesExpected))"
            }
            return "\(Self.formattedBytes(bytesWritten)) downloaded"
        case .finishing:
            return "Finishing download..."
        case .completed:
            return "Download complete."
        case .failed(let message):
            return message
        }
    }

    private static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private enum ModelDownloadEvent: Sendable {
    case progress(ModelOption, bytesWritten: Int64, bytesExpected: Int64?)
    case finishing(ModelOption)
    case completed(ModelOption)
    case failed(ModelOption, String)
}

private enum ModelDownloadValidationError: LocalizedError {
    case httpStatus(Int)
    case tooSmall(Int64)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let statusCode):
            return "Model host returned HTTP \(statusCode)."
        case .tooSmall:
            return "Downloaded file is too small to be a LiteRT-LM model."
        }
    }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private static let minimumModelByteCount: Int64 = 50 * 1024 * 1024

    private struct DownloadRecord {
        let model: ModelOption
        let targetURL: URL
    }

    private let lock = NSLock()
    private var records: [Int: DownloadRecord] = [:]
    private var completedTaskIDs: Set<Int> = []
    private let eventHandler: @Sendable (ModelDownloadEvent) -> Void

    init(eventHandler: @escaping @Sendable (ModelDownloadEvent) -> Void) {
        self.eventHandler = eventHandler
    }

    func register(task: URLSessionTask, model: ModelOption, targetURL: URL) {
        lock.withLock {
            records[task.taskIdentifier] = DownloadRecord(model: model, targetURL: targetURL)
        }
    }

    func unregister(taskID: Int) {
        lock.withLock {
            records[taskID] = nil
            completedTaskIDs.remove(taskID)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let record = record(for: downloadTask.taskIdentifier) else { return }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        eventHandler(.progress(record.model, bytesWritten: totalBytesWritten, bytesExpected: expected))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let record = record(for: downloadTask.taskIdentifier) else { return }
        eventHandler(.finishing(record.model))

        do {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                throw ModelDownloadValidationError.httpStatus(response.statusCode)
            }

            let fileManager = FileManager.default
            let attributes = try fileManager.attributesOfItem(atPath: location.path)
            let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard byteCount >= Self.minimumModelByteCount else {
                throw ModelDownloadValidationError.tooSmall(byteCount)
            }

            try fileManager.createDirectory(
                at: record.targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: record.targetURL.path) {
                try fileManager.removeItem(at: record.targetURL)
            }
            try fileManager.moveItem(at: location, to: record.targetURL)
            markCompleted(taskID: downloadTask.taskIdentifier)
            eventHandler(.completed(record.model))
        } catch {
            eventHandler(.failed(record.model, "Could not save model: \(error.localizedDescription)"))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        defer { unregister(taskID: task.taskIdentifier) }
        guard let error,
              let record = record(for: task.taskIdentifier),
              !isCompleted(taskID: task.taskIdentifier) else {
            return
        }

        if (error as NSError).code == NSURLErrorCancelled {
            eventHandler(.failed(record.model, "Download canceled."))
        } else {
            eventHandler(.failed(record.model, "Download failed: \(error.localizedDescription)"))
        }
    }

    private func record(for taskID: Int) -> DownloadRecord? {
        lock.withLock { records[taskID] }
    }

    private func markCompleted(taskID: Int) {
        lock.withLock {
            completedTaskIDs.insert(taskID)
        }
    }

    private func isCompleted(taskID: Int) -> Bool {
        lock.withLock { completedTaskIDs.contains(taskID) }
    }
}

@MainActor
final class ModelDownloadStore: ObservableObject {
    @Published private var states: [ModelOption: ModelDownloadState]

    private let modelLocator: ModelLocator
    private var tasks: [ModelOption: URLSessionDownloadTask] = [:]
    private lazy var delegate = ModelDownloadDelegate { [weak self] event in
        Task { @MainActor in
            self?.handle(event)
        }
    }
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()

    init(modelLocator: ModelLocator = ModelLocator()) {
        self.modelLocator = modelLocator
        states = Dictionary(uniqueKeysWithValues: ModelOption.allCases.map { ($0, .idle) })
    }

    func state(for model: ModelOption) -> ModelDownloadState {
        states[model] ?? .idle
    }

    func startDownload(for model: ModelOption) {
        guard tasks[model] == nil else { return }

        let targetURL = modelLocator.importedModelsDirectory().appendingPathComponent(model.rawValue, isDirectory: false)
        var request = URLRequest(url: model.downloadURL)
        request.timeoutInterval = 60

        let task = session.downloadTask(with: request)
        tasks[model] = task
        states[model] = .downloading(bytesWritten: 0, bytesExpected: nil)
        delegate.register(task: task, model: model, targetURL: targetURL)
        task.resume()
    }

    func cancelDownload(for model: ModelOption) {
        tasks[model]?.cancel()
    }

    private func handle(_ event: ModelDownloadEvent) {
        switch event {
        case .progress(let model, let bytesWritten, let bytesExpected):
            states[model] = .downloading(bytesWritten: bytesWritten, bytesExpected: bytesExpected)
        case .finishing(let model):
            states[model] = .finishing
        case .completed(let model):
            tasks[model] = nil
            states[model] = .completed(Date())
        case .failed(let model, let message):
            tasks[model] = nil
            states[model] = .failed(message)
        }
    }
}

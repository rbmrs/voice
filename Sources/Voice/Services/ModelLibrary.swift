import AppKit
import Foundation

enum ManagedModelDownloadState: Equatable {
    case idle
    case downloading(progress: Double?)
    case failed(String)
}

struct InstalledManagedModel: Identifiable, Hashable {
    let descriptor: ManagedModelDescriptor
    let localURL: URL

    var id: String { descriptor.id }
}

@MainActor
final class ModelLibrary: ObservableObject {
    @Published private(set) var installedWhisperModels: [InstalledManagedModel] = []
    @Published private(set) var installedRefinementModels: [InstalledManagedModel] = []
    @Published private(set) var downloadStates: [String: ManagedModelDownloadState] = [:]

    private let fileManager: FileManager
    private var activeDownloads: [String: Task<Void, Never>] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        try? ensureInstallDirectories()
        refreshInstalledModels()
    }

    func models(for engine: ManagedModelEngine) -> [ManagedModelDescriptor] {
        ManagedModelCatalog.models(for: engine)
    }

    func installedModels(for engine: ManagedModelEngine) -> [InstalledManagedModel] {
        switch engine {
        case .whisper:
            installedWhisperModels
        case .llama:
            installedRefinementModels
        }
    }

    func installDirectory(for engine: ManagedModelEngine) -> URL {
        installRootDirectory().appendingPathComponent(engine.directoryName, isDirectory: true)
    }

    func destinationURL(for descriptor: ManagedModelDescriptor) -> URL {
        installDirectory(for: descriptor.engine).appendingPathComponent(descriptor.fileName, isDirectory: false)
    }

    func state(for descriptor: ManagedModelDescriptor) -> ManagedModelDownloadState {
        downloadStates[descriptor.id] ?? .idle
    }

    func isInstalled(_ descriptor: ManagedModelDescriptor) -> Bool {
        fileManager.fileExists(atPath: destinationURL(for: descriptor).path)
    }

    func activate(_ descriptor: ManagedModelDescriptor, in settings: AppSettings) {
        let destinationPath = destinationURL(for: descriptor).path

        switch descriptor.engine {
        case .whisper:
            settings.whisperModelPath = destinationPath

            if descriptor.isEnglishOnlyWhisperModel, !["auto", "en"].contains(settings.normalizedWhisperLanguage) {
                settings.whisperLanguage = "en"
            }
        case .llama:
            settings.llamaModelPath = destinationPath
        }
    }

    func revealInstallDirectory(for engine: ManagedModelEngine) {
        let directoryURL = installDirectory(for: engine)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        NSWorkspace.shared.open(directoryURL)
    }

    func refreshInstalledModels() {
        installedWhisperModels = ManagedModelCatalog.whisperModels.compactMap { descriptor in
            let localURL = destinationURL(for: descriptor)
            guard fileManager.fileExists(atPath: localURL.path) else { return nil }
            return InstalledManagedModel(descriptor: descriptor, localURL: localURL)
        }

        installedRefinementModels = ManagedModelCatalog.refinementModels.compactMap { descriptor in
            let localURL = destinationURL(for: descriptor)
            guard fileManager.fileExists(atPath: localURL.path) else { return nil }
            return InstalledManagedModel(descriptor: descriptor, localURL: localURL)
        }
    }

    func download(_ descriptor: ManagedModelDescriptor) {
        guard activeDownloads[descriptor.id] == nil else { return }

        let destinationURL = destinationURL(for: descriptor)
        downloadStates[descriptor.id] = .downloading(progress: 0)

        let task = Task { [weak self] in
            guard let self else { return }

            do {
                try await Self.performDownload(
                    from: descriptor.sourceURL,
                    to: destinationURL
                ) { [weak self] progress in
                    guard let self else { return }
                    await MainActor.run {
                        self.downloadStates[descriptor.id] = .downloading(progress: progress)
                    }
                }

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    self.downloadStates[descriptor.id] = .idle
                    self.activeDownloads[descriptor.id] = nil
                    self.refreshInstalledModels()
                }
            } catch {
                await MainActor.run {
                    self.downloadStates[descriptor.id] = .failed(error.localizedDescription)
                    self.activeDownloads[descriptor.id] = nil
                }
            }
        }

        activeDownloads[descriptor.id] = task
    }

    func delete(_ descriptor: ManagedModelDescriptor) {
        let modelURL = destinationURL(for: descriptor)

        guard fileManager.fileExists(atPath: modelURL.path) else {
            refreshInstalledModels()
            return
        }

        do {
            try fileManager.removeItem(at: modelURL)
            refreshInstalledModels()
            downloadStates[descriptor.id] = .idle
        } catch {
            downloadStates[descriptor.id] = .failed(error.localizedDescription)
        }
    }

    private static func performDownload(
        from remoteURL: URL,
        to destinationURL: URL,
        onProgress: @escaping @Sendable (Double?) async -> Void
    ) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)

        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).download", isDirectory: false)

        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }

        let downloader = DownloadRequest()
        _ = try await downloader.download(
            from: remoteURL,
            stagingURL: temporaryURL,
            onProgress: onProgress
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }

    private func ensureInstallDirectories() throws {
        try fileManager.createDirectory(at: installDirectory(for: .whisper), withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: installDirectory(for: .llama), withIntermediateDirectories: true, attributes: nil)
    }

    private func installRootDirectory() -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("Voice/Models", isDirectory: true)
    }
}

private final class DownloadRequest: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: (@Sendable (Double?) async -> Void)?
    private var downloadedURL: URL?
    private var downloadError: Error?
    private var stagingURL: URL?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 2
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func download(
        from remoteURL: URL,
        stagingURL: URL,
        onProgress: @escaping @Sendable (Double?) async -> Void
    ) async throws -> URL {
        progressHandler = onProgress
        self.stagingURL = stagingURL
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.downloadTask(with: remoteURL)
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let progressHandler else { return }

        let progress: Double?
        if totalBytesExpectedToWrite > 0 {
            progress = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        } else {
            progress = nil
        }

        Task {
            await progressHandler(progress)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let stagingURL else {
            downloadError = DictationServiceError.configuration("The downloader did not have a staging destination.")
            return
        }

        do {
            let fileManager = FileManager.default

            if fileManager.fileExists(atPath: stagingURL.path) {
                try fileManager.removeItem(at: stagingURL)
            }

            try fileManager.moveItem(at: location, to: stagingURL)
            downloadedURL = stagingURL
        } catch {
            downloadError = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        defer {
            continuation = nil
            progressHandler = nil
            downloadedURL = nil
            downloadError = nil
            stagingURL = nil
            session.invalidateAndCancel()
        }

        if let error {
            continuation?.resume(throwing: error)
            return
        }

        if let downloadError {
            continuation?.resume(throwing: downloadError)
            return
        }

        if let response = task.response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            continuation?.resume(throwing: DictationServiceError.configuration("Download failed with HTTP \(response.statusCode)."))
            return
        }

        guard let downloadedURL else {
            continuation?.resume(throwing: DictationServiceError.configuration("The download completed without a file to install."))
            return
        }

        continuation?.resume(returning: downloadedURL)
    }
}

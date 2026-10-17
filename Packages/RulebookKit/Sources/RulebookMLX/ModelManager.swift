import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Observation
import Tokenizers

/// Downloads, stores, loads and unloads the Qwen3-4B weights.
///
/// The weights (~2.3 GB) are downloaded once from Hugging Face into Application
/// Support (excluded from backup, not purged by iOS). After that the model loads
/// from that folder with no network access.
@MainActor
@Observable
public final class ModelManager {
    public enum State: Equatable, Sendable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case loading
        case ready
        case failed(String)
    }

    public static let repositoryID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    public static let approximateDownloadSize = "2.3 GB"

    /// Qwen3-4B needs about 3 GB of RAM while running; below this, use Apple's model instead.
    public static let minimumMemory: UInt64 = 6 * 1_073_741_824

    public private(set) var state: State
    private var container: ModelContainer?
    private var loadTask: Task<Void, Never>?

    private let storageDirectory: URL
    private static let snapshotPathKey = "mlx.snapshotRelativePath"

    public init() {
        let support = URL.applicationSupportDirectory.appending(path: "Models", directoryHint: .isDirectory)
        storageDirectory = support
        state = .notDownloaded
        if localSnapshot != nil { state = .downloaded }
    }

    public static var deviceIsCapable: Bool {
        ProcessInfo.processInfo.physicalMemory >= minimumMemory
    }

    public var isDownloaded: Bool { localSnapshot != nil }

    /// The backend, once the model is loaded.
    public var backend: MLXBackend? {
        container.map { MLXBackend(container: $0) }
    }

    /// Downloads if needed, then loads the model into memory.
    public func prepare() {
        guard loadTask == nil, container == nil else { return }
        loadTask = Task {
            defer { loadTask = nil }
            do {
                if let directory = localSnapshot {
                    state = .loading
                    container = try await LLMModelFactory.shared.loadContainer(
                        from: directory, using: #huggingFaceTokenizerLoader())
                } else {
                    container = try await download()
                }
                state = .ready
            } catch is CancellationError {
                state = isDownloaded ? .downloaded : .notDownloaded
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    public func cancel() {
        loadTask?.cancel()
    }

    /// Frees the ~3 GB the model uses (e.g. when the app moves to the background on iPhone).
    public func unload() {
        container = nil
        if state == .ready { state = .downloaded }
    }

    public func deleteDownload() {
        cancel()
        unload()
        try? FileManager.default.removeItem(at: storageDirectory)
        UserDefaults.standard.removeObject(forKey: Self.snapshotPathKey)
        state = .notDownloaded
    }

    // MARK: Storage

    private var localSnapshot: URL? {
        guard let relative = UserDefaults.standard.string(forKey: Self.snapshotPathKey) else { return nil }
        let url = storageDirectory.appending(path: relative, directoryHint: .isDirectory)
        let hasWeights = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?
            .contains { $0.hasSuffix(".safetensors") } ?? false
        return hasWeights ? url : nil
    }

    /// First-run path: downloads the weights and returns the loaded model.
    private func download() async throws -> ModelContainer {
        state = .downloading(progress: 0)
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = storageDirectory
        try? directory.setResourceValues(values)

        let hub = HubClient(cache: HubCache(cacheDirectory: storageDirectory))
        let recorder = SnapshotRecorder(upstream: #hubDownloader(hub))
        let container = try await LLMModelFactory.shared.loadContainer(
            from: recorder,
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: Self.repositoryID)
        ) { progress in
            Task { @MainActor [weak self = self] in
                self?.state = .downloading(progress: progress.fractionCompleted)
            }
        }
        guard let snapshot = recorder.snapshotURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let relative = snapshot.path.replacingOccurrences(of: storageDirectory.path + "/", with: "")
        UserDefaults.standard.set(relative, forKey: Self.snapshotPathKey)
        return container
    }
}

/// Forwards to the Hugging Face downloader and remembers where the snapshot landed,
/// so later launches can load from disk without touching the network.
private final class SnapshotRecorder: MLXLMCommon.Downloader, @unchecked Sendable {
    let upstream: any MLXLMCommon.Downloader
    private let lock = NSLock()
    private var _snapshotURL: URL?

    init(upstream: any MLXLMCommon.Downloader) {
        self.upstream = upstream
    }

    var snapshotURL: URL? { lock.withLock { _snapshotURL } }

    func download(
        id: String, revision: String?, matching patterns: [String], useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let url = try await upstream.download(
            id: id, revision: revision, matching: patterns, useLatest: useLatest,
            progressHandler: progressHandler)
        lock.withLock { if _snapshotURL == nil { _snapshotURL = url } }
        return url
    }
}

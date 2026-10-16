import Foundation
import Observation
import RulebookKit
import RulebookMLX

/// Owns the rulebook index, the search stack and the language-model engines.
@MainActor
@Observable
final class AppModel {
    enum Engine: Equatable {
        case mlx
        case apple
        case searchOnly(reason: String)
    }

    let store: RulebookStore?
    let loadError: String?
    let answerService: AnswerService?
    let semanticIndex: SemanticIndex?
    let modelManager = ModelManager()
    private(set) var semanticProgress: Double?

    var preference: EnginePreference {
        didSet { UserDefaults.standard.set(preference.rawValue, forKey: "enginePreference") }
    }

    /// Race context, role and rule sets that new conversations start with (Settings).
    var defaultContext: AnswerContext {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(defaultContext), forKey: "defaultContext") }
    }

    init() {
        preference = UserDefaults.standard.string(forKey: "enginePreference")
            .flatMap(EnginePreference.init(rawValue:)) ?? .automatic
        defaultContext = UserDefaults.standard.data(forKey: "defaultContext")
            .flatMap { try? JSONDecoder().decode(AnswerContext.self, from: $0) } ?? .default

        do {
            guard let url = Bundle.main.url(forResource: "rulebook", withExtension: "sqlite") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let store = try RulebookStore(url: url)
            let semantic = ContextualTextEmbedder().map {
                SemanticIndex(
                    embedder: $0,
                    cacheDirectory: URL.applicationSupportDirectory.appending(path: "Embeddings"),
                    indexVersion: store.indexVersion)
            }
            self.store = store
            self.semanticIndex = semantic
            self.answerService = AnswerService(retriever: HybridRetriever(store: store, semantic: semantic))
            self.loadError = nil
        } catch {
            store = nil
            semanticIndex = nil
            answerService = nil
            loadError = "The rulebook index is missing or damaged (\(error.localizedDescription)). Rebuild it with ingest/build_index.py."
        }
    }

    /// Starts background work: embedding the rules and, if wanted, loading the MLX model.
    func start() {
        if let store, let semanticIndex {
            Task.detached(priority: .utility) {
                guard let chunks = try? store.allChunks() else { return }
                await semanticIndex.build(chunks: chunks) { progress in
                    Task { @MainActor in self.semanticProgress = progress < 1 ? progress : nil }
                }
            }
        }
        if wantsMLX, modelManager.isDownloaded {
            modelManager.prepare()
        }
    }

    private var wantsMLX: Bool {
        switch preference {
        case .automatic: ModelManager.deviceIsCapable
        case .mlx: true
        case .apple, .searchOnly: false
        }
    }

    /// The engine questions are answered with right now.
    var engine: Engine {
        switch preference {
        case .searchOnly:
            return .searchOnly(reason: "Search-only mode is selected in Settings.")
        case .mlx:
            if modelManager.backend != nil { return .mlx }
            return .searchOnly(reason: mlxStatusText)
        case .apple:
            if FoundationModelsBackend.isAvailable { return .apple }
            return .searchOnly(reason: FoundationModelsBackend.unavailableReason ?? "Apple Intelligence is unavailable.")
        case .automatic:
            if modelManager.backend != nil { return .mlx }
            if FoundationModelsBackend.isAvailable { return .apple }
            return .searchOnly(reason: mlxStatusText)
        }
    }

    var backend: (any LLMBackend)? {
        switch engine {
        case .mlx: modelManager.backend
        case .apple: FoundationModelsBackend()
        case .searchOnly: nil
        }
    }

    var engineName: String {
        switch engine {
        case .mlx: "Qwen3 4B · on device"
        case .apple: "Apple Intelligence · on device"
        case .searchOnly: "Search only"
        }
    }

    private var mlxStatusText: String {
        switch modelManager.state {
        case .notDownloaded: "Download the Qwen3 4B model in Settings to get written answers."
        case .downloading(let p): "Downloading the model (\(Int(p * 100))%)…"
        case .downloaded, .loading: "Loading the model…"
        case .ready: ""
        case .failed(let message): "The model failed to load: \(message)"
        }
    }

    /// iPhone/iPad: release the model's memory in the background so iOS doesn't terminate the app.
    func didEnterBackground() {
        #if os(iOS)
            modelManager.unload()
        #endif
    }

    func didBecomeActive() {
        if wantsMLX, modelManager.isDownloaded, modelManager.backend == nil {
            modelManager.prepare()
        }
    }
}

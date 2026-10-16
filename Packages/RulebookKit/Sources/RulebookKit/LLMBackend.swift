import Foundation

/// A language model that can turn retrieved rule excerpts into an answer.
public protocol LLMBackend: Sendable {
    /// Shown in the UI, e.g. "Qwen3 4B (on device)".
    var displayName: String { get }
    /// Tokens available for instructions + excerpts + question (excludes the answer).
    var promptTokenBudget: Int { get }
    /// Maximum number of excerpts worth giving this model.
    var maxExcerpts: Int { get }
    /// Streams the answer as text deltas.
    func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error>
}

/// Which engine the user wants. `.automatic` prefers MLX, then Apple, then search-only.
public enum EnginePreference: String, CaseIterable, Identifiable, Sendable, Codable {
    case automatic
    case mlx
    case apple
    case searchOnly

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .automatic: "Automatic"
        case .mlx: "Qwen3 4B (MLX)"
        case .apple: "Apple Intelligence"
        case .searchOnly: "Search only"
        }
    }
}

enum TokenEstimate {
    /// ~4 characters per token for English prose; deliberately conservative.
    static func tokens(in text: String) -> Int { (text.utf8.count + 3) / 4 }
}

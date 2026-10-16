import Foundation
import FoundationModels

/// Apple's on-device model (Apple Intelligence). Small context window (~4K tokens),
/// so it gets fewer excerpts than the MLX model.
public struct FoundationModelsBackend: LLMBackend {
    public let displayName = "Apple Intelligence"
    public let promptTokenBudget = 2_800
    public let maxExcerpts = 5

    public init() {}

    public static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Human-readable reason the model can't be used, or nil when it can.
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This device doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off in Settings."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading."
        case .unavailable:
            return "Apple Intelligence is unavailable."
        }
    }

    public func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    let options = GenerationOptions(temperature: 0.2)
                    var emitted = ""
                    // Snapshots are cumulative; forward only the new text.
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        let text = snapshot.content
                        if text.hasPrefix(emitted) {
                            continuation.yield(String(text.dropFirst(emitted.count)))
                        } else {
                            continuation.yield(text)
                        }
                        emitted = text
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

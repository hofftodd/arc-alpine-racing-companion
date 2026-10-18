import Foundation
import MLXLMCommon
import RulebookKit

/// Gemma 4 E4B running on device through MLX. Its context window is much larger
/// than Apple's model, so it gets more excerpts; the budget scales with device memory.
public struct MLXBackend: LLMBackend {
    public let displayName = "\(ModelManager.displayName) (on device)"
    public let promptTokenBudget: Int
    public let maxExcerpts: Int
    private let container: ModelContainer

    init(container: ModelContainer, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.container = container
        // The KV cache grows with the prompt, so phones get a smaller window than Macs. Reading the
        // excerpts is most of the wait: with 20 on an M4 Mac an answer took about 30 s, and the last
        // excerpts were filler (concussion fact sheets in a re-run answer), so even Macs stop at 12.
        let gigabytes = physicalMemory / 1_073_741_824
        switch gigabytes {
        case ..<9: (promptTokenBudget, maxExcerpts) = (5_000, 8)  // iPhone 15 Pro, 16 Pro (8 GB)
        case ..<17: (promptTokenBudget, maxExcerpts) = (8_000, 10)  // iPhone 17 Pro (12 GB), iPad Pro, 16 GB Mac
        default: (promptTokenBudget, maxExcerpts) = (10_000, 12)
        }
    }

    public func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        let container = container
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // A fresh session per question: excerpts already carry the conversation context.
                    let session = ChatSession(
                        container,
                        instructions: instructions,
                        generateParameters: GenerateParameters(maxTokens: 900, temperature: 0.2, topP: 0.9),
                        // No hidden reasoning before the answer: it was slower and no more accurate.
                        additionalContext: ["enable_thinking": false])
                    for try await chunk in session.streamResponse(to: prompt) {
                        try Task.checkCancellation()
                        continuation.yield(chunk)
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

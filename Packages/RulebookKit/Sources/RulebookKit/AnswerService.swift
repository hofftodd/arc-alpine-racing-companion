import Foundation

/// A previous question and answer, used to resolve follow-ups like "what about in GS?".
public struct ChatTurn: Sendable, Hashable {
    public let question: String
    public let answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

public enum AnswerEvent: Sendable, Equatable {
    /// The numbered excerpts the answer is based on (sent first).
    case sources([Citation])
    /// A piece of the generated answer.
    case text(String)
    /// Generation finished; `cited` are the source indexes the answer actually referenced, and
    /// `unverifiedQuotes` the quotations that aren't word for word in any excerpt.
    case finished(cited: [Int], unverifiedQuotes: [String] = [])
}

/// Retrieval-augmented answering: find relevant rules, have the model answer only
/// from them, and tie every citation back to a real page.
public final class AnswerService: Sendable {
    public let retriever: HybridRetriever

    public init(retriever: HybridRetriever) {
        self.retriever = retriever
    }

    public static let baseInstructions = """
        You are a reference assistant for alpine ski race officials. \
        Answer the question using ONLY the numbered excerpts provided; they come from U.S. Ski & Snowboard, \
        FIS and OISRA rules, manuals and study guides. \
        After each statement, cite the excerpt it comes from with its number in square brackets, like [2]. \
        Quote the exact wording for numbers, times, distances and penalties. \
        Keep each rule's conditions exactly as written: never add or drop words such as "only", "even", "not" or "unless". \
        Numbered items in a rule are separate rules; do not join two of them into one statement or imply one causes the other. \
        When an excerpt cites rule numbers (for example [601.4.1] or ICR 614.2), include them so the official can look them up. \
        If the excerpts do not answer the question, say so plainly and name the sections that came closest; never guess or use outside knowledge. \
        Start with a direct one- or two-sentence answer, then give supporting detail. Keep it brief.
        """

    /// Base instructions plus the race context and role.
    public static func instructions(for context: AnswerContext) -> String {
        let excluded = Jurisdiction.allCases.filter { !context.included.contains($0) }
        let exclusion = excluded.isEmpty ? nil : """
            The official chose to leave out \(excluded.map(\.shortName).joined(separator: " and ")) documents. \
            Do not bring in those rules; if the answer depends on them, say they were excluded.
            """
        return [baseInstructions, context.race.instructions, context.role.instructions, exclusion]
            .compactMap { $0 }
            .joined(separator: "\n\n")
    }

    /// Search-only results, for when no language model is available.
    public func search(_ question: String, limit: Int = 10, context: AnswerContext = .default) async throws -> [Citation] {
        try await retriever.retrieve(question, limit: limit, context: context).enumerated().map { i, hit in
            retriever.store.citation(for: hit.chunk, index: i + 1, governing: context.race.governing)
        }
    }

    public func answer(
        _ question: String, history: [ChatTurn] = [], backend: any LLMBackend, context: AnswerContext = .default
    ) -> AsyncThrowingStream<AnswerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let previous = Self.isFollowUp(question, history: history) ? history.last : nil
                    let query = [previous?.question, question].compactMap { $0 }.joined(separator: " ")
                    let hits = try await retriever.retrieve(query, limit: backend.maxExcerpts, context: context)
                    let instructions = Self.instructions(for: context)
                    let (prompt, citations) = buildPrompt(
                        question: question, previous: previous, hits: hits, context: context,
                        budget: backend.promptTokenBudget - TokenEstimate.tokens(in: instructions))
                    continuation.yield(.sources(citations))

                    guard !citations.isEmpty else {
                        continuation.yield(.text("I couldn't find anything in the bundled documents about that. Try different wording, or browse the Library."))
                        continuation.yield(.finished(cited: []))
                        continuation.finish()
                        return
                    }

                    var full = ""
                    for try await delta in backend.stream(instructions: instructions, prompt: prompt) {
                        full += delta
                        continuation.yield(.text(delta))
                    }
                    let valid = Set(citations.map(\.index))
                    continuation.yield(.finished(
                        cited: Self.citedIndexes(in: full).filter(valid.contains),
                        unverifiedQuotes: QuoteCheck.unverified(in: full, sources: citations.map(\.excerpt))))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Prompt construction

    /// Numbered excerpts that fit in `budget` tokens (instructions already subtracted), then the question.
    func buildPrompt(
        question: String, previous: ChatTurn?, hits: [SearchHit], context: AnswerContext = .default, budget: Int
    ) -> (String, [Citation]) {
        var tail = ""
        if let previous {
            tail += "Previous question: \(previous.question)\nPrevious answer: \(previous.answer.prefix(600))\n\n"
        }
        tail += "Question: \(question)"

        var remaining = budget - TokenEstimate.tokens(in: tail) - 20
        var blocks: [String] = []
        var citations: [Citation] = []
        for hit in hits {
            let index = citations.count + 1
            let citation = retriever.store.citation(for: hit.chunk, index: index, governing: context.race.governing)
            let tag = citation.governing
                ? "\(citation.jurisdiction.shortName), governing" : citation.jurisdiction.shortName
            let header = "[\(index)] (\(tag)) \(citation.documentTitle), \(citation.title) (\(citation.pageDisplay))"
            var body = hit.chunk.documentText
            let cost = TokenEstimate.tokens(in: header) + TokenEstimate.tokens(in: body) + 2
            if cost > remaining {
                // Always include at least one excerpt, trimmed to fit.
                guard citations.isEmpty, remaining > 100 else { break }
                body = String(body.prefix((remaining - TokenEstimate.tokens(in: header)) * 4))
                remaining = 0
            } else {
                remaining -= cost
            }
            blocks.append("\(header)\n\(body)")
            citations.append(citation)
        }
        let prompt = "Excerpts:\n\n" + blocks.joined(separator: "\n\n") + "\n\n" + tail
        return (prompt, citations)
    }

    /// Short or pronoun-led questions after an earlier turn are treated as follow-ups,
    /// so retrieval also uses the earlier question's terms.
    static func isFollowUp(_ question: String, history: [ChatTurn]) -> Bool {
        guard !history.isEmpty else { return false }
        let lower = question.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count <= 6 { return true }
        let leads = ["what about", "how about", "and ", "also", "same", "what if", "does that", "is that", "what happens then"]
        if leads.contains(where: lower.hasPrefix) { return true }
        return words.contains { ["it", "that", "this", "they", "them", "those"].contains(String($0)) }
            && QueryParser.ruleNumbers(in: question).isEmpty && words.count <= 12
    }

    /// Source numbers referenced as [1], [2, 3] or [1][4], in first-mention order.
    static func citedIndexes(in text: String) -> [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for match in text.matches(of: /\[(\d+(?:\s*,\s*\d+)*)\]/) {
            for part in match.output.1.split(separator: ",") {
                if let n = Int(part.trimmingCharacters(in: .whitespaces)), seen.insert(n).inserted {
                    result.append(n)
                }
            }
        }
        return result
    }
}

import Foundation
import RulebookKit
import SwiftData

/// A saved conversation (stored locally with SwiftData).
@Model
final class Conversation {
    var title: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage] = []
    /// Race context, role and included rule sets (JSON-encoded `AnswerContext`).
    var contextData: Data?

    init(title: String = "New question", createdAt: Date = .now, context: AnswerContext = .default) {
        self.title = title
        self.createdAt = createdAt
        self.contextData = try? JSONEncoder().encode(context)
    }

    var context: AnswerContext {
        get { contextData.flatMap { try? JSONDecoder().decode(AnswerContext.self, from: $0) } ?? .default }
        set { contextData = try? JSONEncoder().encode(newValue) }
    }

    var orderedMessages: [ChatMessage] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }

    /// Completed question/answer pairs, for follow-up questions.
    var history: [ChatTurn] {
        var turns: [ChatTurn] = []
        var pendingQuestion: String?
        for message in orderedMessages {
            if message.isUser {
                pendingQuestion = message.text
            } else if let question = pendingQuestion {
                turns.append(ChatTurn(question: question, answer: message.text))
                pendingQuestion = nil
            }
        }
        return turns
    }
}

@Model
final class ChatMessage {
    var isUser: Bool
    var text: String
    var createdAt: Date
    /// Engine that produced the answer, e.g. "Qwen3 4B · on device".
    var engine: String?
    var citationsData: Data?
    var citedIndexes: [Int] = []
    var failed: Bool = false
    var conversation: Conversation?

    init(isUser: Bool, text: String, engine: String? = nil, createdAt: Date = .now) {
        self.isUser = isUser
        self.text = text
        self.engine = engine
        self.createdAt = createdAt
    }

    var citations: [Citation] {
        get { citationsData.flatMap { try? JSONDecoder().decode([Citation].self, from: $0) } ?? [] }
        set { citationsData = try? JSONEncoder().encode(newValue) }
    }

    /// Citations the answer referenced, falling back to all sources (search-only results).
    var citedSources: [Citation] {
        let all = citations
        guard !citedIndexes.isEmpty else { return all }
        return citedIndexes.compactMap { i in all.first { $0.index == i } }
    }
}

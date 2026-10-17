import Foundation

/// Combines exact rule lookups, BM25 keyword search and semantic search with
/// Reciprocal Rank Fusion (RRF), then weights results by document priority,
/// race context (which rule set governs) and the asker's role.
public final class HybridRetriever: Sendable {
    public let store: RulebookStore
    public let semantic: SemanticIndex?

    /// RRF constant; 60 is the standard value from the original paper.
    private let rrfK = 60.0
    private let candidatesPerSource = 40
    /// Passages from the governing rule set kept in the results whenever any are relevant.
    private let pinnedGoverning = 2
    /// Citation following: the top passages' cited rules, inserted right after them.
    private let followTop = 5
    private let followPerPassage = 2
    /// Question echo: passages asking (almost) the user's exact question move to the front.
    private let echoMinimum = 0.6
    private let echoPromote = 2
    /// A heading that contains every topical term of the question ("FIS Homologated Gate Panels").
    private let headingCoverBoost = 1.5
    /// A passage about another discipline than the one asked about: "GS" also searches "slalom",
    /// which matches every slalom passage, and the OISRA weight lifted OISRA's slalom data.
    private let otherDisciplinePenalty = 0.3

    public init(store: RulebookStore, semantic: SemanticIndex?) {
        self.store = store
        self.semantic = semantic
    }

    public func retrieve(_ question: String, limit: Int, context: AnswerContext = .default) async throws -> [SearchHit] {
        var fused: [Int: Double] = [:]
        var chunksByID: [Int: RuleChunk] = [:]

        func add(_ ranked: [RuleChunk], weight: Double) {
            // Rule sets the user unchecked never reach the results.
            let allowed = ranked.filter { context.includes(store.document(id: $0.documentID)) }
            for (rank, chunk) in allowed.enumerated() {
                fused[chunk.id, default: 0] += weight / (rrfK + Double(rank + 1))
                chunksByID[chunk.id] = chunk
            }
        }

        // 1. Explicit rule references ("what does 614.2 say?") go straight to that rule.
        let explicit = try QueryParser.ruleNumbers(in: question).flatMap { try store.chunks(forRule: $0, limit: 6) }
        add(explicit, weight: 3)

        // 2. Keyword search, nudged toward the asker's role.
        let keyword = try store.keywordSearch(
            matchExpression: QueryParser.ftsExpression(for: question, extraTerms: context.role.searchTerms),
            limit: candidatesPerSource)
        add(keyword.map(\.chunk), weight: 1)

        // 3. Precision pass: passages containing every topical term of the question.
        if let allTerms = QueryParser.ftsAllTermsExpression(for: question) {
            add(try store.keywordSearch(matchExpression: allTerms, limit: candidatesPerSource).map(\.chunk), weight: 0.5)
        }

        // 4. Semantic search, if the embedding index is ready.
        if let semantic {
            let ranked = await semantic.search(question, limit: candidatesPerSource)
            let missing = ranked.map(\.chunkID).filter { chunksByID[$0] == nil }
            for chunk in try store.chunks(ids: missing) { chunksByID[chunk.id] = chunk }
            add(ranked.compactMap { chunksByID[$0.chunkID] }, weight: 1)
        }

        let words = QueryParser.terms(in: question)
        let topical = words.filter { !QueryParser.genericWords.contains($0) }.map { $0.prefix(5).lowercased() }
        let asked = QueryParser.disciplines(in: question)
        let ranked = fused
            .compactMap { id, score -> SearchHit? in
                guard let chunk = chunksByID[id], context.includes(store.document(id: chunk.documentID)) else {
                    return nil
                }
                var weight = context.weight(for: store.document(id: chunk.documentID))
                if let heading = chunk.heading?.lowercased(), topical.count > 1,
                    topical.allSatisfy({ heading.contains($0) })
                {
                    weight *= headingCoverBoost
                }
                if !asked.isEmpty {
                    let named = QueryParser.disciplines(in: [chunk.heading, chunk.breadcrumb].compactMap { $0 }.joined(separator: " "))
                    if !named.isEmpty, named.isDisjoint(with: asked) { weight *= otherDisciplinePenalty }
                }
                return SearchHit(chunk: chunk, score: score * weight)
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.chunk.id < $1.chunk.id }

        let echoed = promoteEchoes(ranked, words: words)
        let followed = followCitations(echoed, question: question, context: context)
        return pinGoverning(followed, governing: context.race.governing, limit: limit)
    }

    /// Study guides are full of the exact questions officials ask ("5. Who can submit protests?
    /// [645]"). Move the passages whose question best matches the user's to the front, so the
    /// rule they cite is followed into the top results. Mirrors promote_echoes in eval_retrieval.py.
    func promoteEchoes(_ ranked: [SearchHit], words: [String]) -> [SearchHit] {
        let question = QueryParser.topicalStems(words)
        var echoes: [(score: Double, position: Int)] = []
        for (position, hit) in ranked.prefix(40).enumerated() {
            let score = Self.echoScore(hit.chunk.text, question: question)
            if score >= echoMinimum { echoes.append((score, position)) }
        }
        let promoted = echoes
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.position < $1.position }
            .prefix(echoPromote)
            .map(\.position)
        return promoted.map { ranked[$0] } + ranked.enumerated().filter { !promoted.contains($0.offset) }.map(\.element)
    }

    private static let questionClauseBreak = try! NSRegularExpression(
        pattern: #"(?<=[.!\]])\s+|\s(?=[a-z]\.\s)|\s(?=\d{1,2}\.\s)"#)

    /// Best similarity between the user's question and any question asked in `text`.
    static func echoScore(_ text: String, question: Set<String>) -> Double {
        var best = 0.0
        for segment in text.split(separator: "?", omittingEmptySubsequences: false).dropLast() {
            let clause = String(segment).trimmingCharacters(in: .whitespaces)
            let ns = clause as NSString
            let breaks = questionClauseBreak.matches(in: clause, range: NSRange(location: 0, length: ns.length))
            let last = breaks.last.map { ns.substring(from: $0.range.location + $0.range.length) } ?? clause
            best = max(best, QueryParser.similarity(question, QueryParser.topicalStems(QueryParser.terms(in: last))))
        }
        return best
    }

    /// Study guides and manuals cite rules as "[623.1.1]". Insert each cited rule's own passage
    /// (ACR, or ICR for a FIS race) directly after the passage that cites it, so the model reads
    /// the rule text next to the explanation. Mirrors follow_citations in ingest/eval/eval_retrieval.py.
    func followCitations(_ ranked: [SearchHit], question: String, context: AnswerContext) -> [SearchHit] {
        let words = QueryParser.terms(in: question)
        let prefer: Jurisdiction = context.race == .fis ? .fis : .usss
        var out: [SearchHit] = []
        var seen = Set<Int>()
        for (position, hit) in ranked.enumerated() {
            if seen.insert(hit.chunk.id).inserted { out.append(hit) }
            guard position < followTop else { continue }
            for rule in Self.citedRules(near: words, in: hit.chunk.text, limit: followPerPassage) {
                guard let chunk = try? store.ruleChunk(number: rule, prefer: prefer, included: context.included),
                    seen.insert(chunk.id).inserted
                else { continue }
                out.append(SearchHit(chunk: chunk, score: hit.score * 0.95))
            }
        }
        return out
    }

    // Split at list markers ("c. ", "4. ") and after sentence ends or citations, but never right
    // after "?": study guides put the answer's rule after the question ("…Referees? [601.3]").
    private static let sentenceBreak = try! NSRegularExpression(
        pattern: #"(?<=[.!\]])\s+(?=[A-Z])|\s(?=[a-z]\.\s)|\s(?=\d{1,2}\.\s)"#)
    private static let citation = try! NSRegularExpression(
        pattern: #"\[([^\]]{3,200})\]|\b(?:ICR|ACR|art\.?|[Rr]ule)\s+(U?\d{3}(?:\.\d{1,3}){0,5})"#)
    private static let ruleNumber = try! NSRegularExpression(pattern: #"(?<![\d.])U?\d{3}(?:\.\d{1,3}){0,5}(?![\d])"#)

    /// Rules cited in the sentences of `text` most similar to the question (Jaccard over topical
    /// stems; question sentences win ties). Mirrors cited_rules_near in eval_retrieval.py.
    static func citedRules(near words: [String], in text: String, limit: Int) -> [String] {
        let ns = text as NSString
        var sentences: [String] = []
        var start = 0
        for match in sentenceBreak.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            sentences.append(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = match.range.location + match.range.length
        }
        sentences.append(ns.substring(from: start))

        let question = QueryParser.topicalStems(words)
        var scored: [(similarity: Double, isQuestion: Bool, index: Int, rules: [String])] = []
        for (index, sentence) in sentences.enumerated() {
            let s = sentence as NSString
            let all = NSRange(location: 0, length: s.length)
            var rules: [String] = []
            for m in citation.matches(in: sentence, range: all) {
                if m.range(at: 1).location != NSNotFound {
                    let inner = s.substring(with: m.range(at: 1)) as NSString
                    rules += ruleNumber.matches(in: inner as String, range: NSRange(location: 0, length: inner.length))
                        .map { inner.substring(with: $0.range) }
                } else if m.range(at: 2).location != NSNotFound {
                    rules.append(s.substring(with: m.range(at: 2)))
                }
            }
            rules = rules.filter {
                (100...1499).contains(Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "U")).split(separator: ".")[0]) ?? 0)
            }
            // Similarity of the sentence's own words (citations removed) to the question, so
            // "Protest submittal deadlines depend on the kind of protest [643]" loses to "Who can submit protests? [645]".
            let body = citation.stringByReplacingMatches(in: sentence, range: all, withTemplate: " ")
            let stems = QueryParser.topicalStems(QueryParser.terms(in: body))
            guard !rules.isEmpty, !question.isDisjoint(with: stems) else { continue }
            scored.append((QueryParser.similarity(question, stems), body.contains("?"), index, rules))
        }
        var out: [String] = []
        let ordered = scored.sorted {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            if $0.isQuestion != $1.isQuestion { return $0.isQuestion }
            return $0.index < $1.index
        }
        for entry in ordered {
            for rule in entry.rules where !out.contains(rule) { out.append(rule) }
        }
        return Array(out.prefix(limit))
    }

    /// Takes the top `limit` hits, making sure the governing rule set's best passages are
    /// among them (when any matched at all), so "OISRA supersedes" can actually be applied.
    func pinGoverning(_ ranked: [SearchHit], governing: Jurisdiction?, limit: Int) -> [SearchHit] {
        var top = Array(ranked.prefix(limit))
        guard let governing, limit > pinnedGoverning else { return top }
        func isGoverning(_ hit: SearchHit) -> Bool {
            store.document(id: hit.chunk.documentID)?.jurisdiction == governing
        }
        let present = top.filter(isGoverning).count
        guard present < pinnedGoverning else { return top }
        let extra = ranked.dropFirst(limit).filter(isGoverning).prefix(pinnedGoverning - present)
        for hit in extra {
            // Replace the lowest-ranked non-governing hit.
            if let index = top.lastIndex(where: { !isGoverning($0) }) {
                top.remove(at: index)
            }
            top.append(hit)
        }
        return top.sorted { $0.score > $1.score }
    }
}

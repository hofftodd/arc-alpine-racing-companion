import Foundation
import Testing

@testable import RulebookKit

// Fixture (ingest/make_fixture.py): document 1 "acg" is a numbered-rules U.S. Ski & Snowboard
// guide tagged for referees; document 2 "oisra" is an OISRA outline document (listed first).

private func fixtureStore() throws -> RulebookStore {
    let url = try #require(Bundle.module.url(forResource: "sample", withExtension: "sqlite", subdirectory: "Fixtures"))
    return try RulebookStore(url: url)
}

/// Bag-of-words embedder so semantic search is deterministic in tests.
private struct HashingEmbedder: TextEmbedder {
    let dimension = 512
    func prepare() async throws {}
    func embed(_ text: String) throws -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        for word in QueryParser.terms(in: text) {
            v[Int(UInt(bitPattern: word.hashValue) % UInt(dimension))] += 1
        }
        return VectorMath.normalized(v)
    }
}

private struct MockBackend: LLMBackend {
    let displayName = "Mock"
    let promptTokenBudget = 4_000
    let maxExcerpts = 4
    let reply: String
    func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in
            for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
                c.yield(String(word) + " ")
            }
            c.finish()
        }
    }
}

@Suite struct StoreTests {
    @Test func opensFixture() throws {
        let store = try fixtureStore()
        #expect(store.documents.map(\.slug) == ["oisra", "acg"])
        #expect(store.documents.map(\.jurisdiction) == [.oisra, .usss])
        #expect(store.document(id: 1)?.roles == ["referee"])
        #expect(store.collections.map { $0.name } == ["Oregon High School (OISRA)", "U.S. Ski & Snowboard"])
        #expect(store.indexVersion.count == 16)
        #expect(store.pageLabel(documentID: 1, pageIndex: 2) == "3")
    }

    @Test func ruleLookupFindsMergedSubsections() throws {
        let store = try fixtureStore()
        // 614.2 was merged into the passage that starts at 614; the toc table still finds it.
        #expect(try store.chunks(forRule: "614.2").first?.ruleNumber == "614")
        #expect(try store.chunks(forRule: "601.2.1").first?.ruleNumber == "601")
        #expect(try store.chunks(forRule: "999.9").isEmpty)
    }

    @Test func keywordSearchUsesStemming() throws {
        let hits = try fixtureStore().keywordSearch(
            matchExpression: QueryParser.ftsExpression(for: "skiing through gates while inspecting"), limit: 3)
        #expect(hits.first?.chunk.ruleNumber == "614")
    }

    @Test func tableOfContentsListsEverySection() throws {
        let toc = try fixtureStore().tableOfContents(documentID: 1)
        #expect(toc.first?.number == "600")
        #expect(toc.first(where: { $0.number == "601.2.1" })?.level == 2)
        #expect(toc.first(where: { $0.number == "601.2" })?.title == "601.2 Assistant Referee")
        #expect(toc.first(where: { $0.number == "601.1" })?.title == "Rule 601.1")
        #expect(try fixtureStore().tableOfContents(documentID: 2).map(\.heading).contains("Re-Runs"))
    }
}

@Suite struct QueryParserTests {
    @Test func extractsRuleNumbersButNotMeasurements() {
        #expect(QueryParser.ruleNumbers(in: "What do rule 614 and 614.2 say about 1500 meters?") == ["614", "614.2"])
        #expect(QueryParser.ruleNumbers(in: "Is 2026 a valid season?").isEmpty)
        #expect(QueryParser.ruleNumbers(in: "Compare U601.4.2.3 with §4.2.5 and art. 7.1") == ["U601.4.2.3", "4.2.5", "7.1"])
    }

    @Test func allTermsExpressionSkipsGenericWords() {
        #expect(QueryParser.ftsAllTermsExpression(for: "What supplies does a gate judge need?")
            == "\"supplies\" AND \"gate\" AND \"judge\"")
        #expect(QueryParser.ftsAllTermsExpression(for: "What timing system should be used?") == "\"timing\" AND \"system\"")
        #expect(QueryParser.ftsAllTermsExpression(for: "Is it allowed?") == nil)
    }

    @Test func expandsAbbreviationsAndDropsStopwords() {
        #expect(QueryParser.ftsExpression(for: "Who is the TD?") == "\"td\" OR \"technical\" OR \"delegate\"")
        #expect(QueryParser.ftsExpression(for: "a \"quoted\" OR (weird) query*") == "\"quoted\" OR \"weird\" OR \"query\"")
        #expect(QueryParser.ftsExpression(for: "OSIRA re-run", extraTerms: ["referee"])
            == "\"osira\" OR \"oisra\" OR (\"rerun\" OR \"re run\") OR \"referee\"")
    }

    @Test func reRunAndRerunSearchBothSpellings() {
        for spelling in ["re-run", "rerun", "Re-runs", "re run", "reruns"] {
            #expect(QueryParser.terms(in: "Who grants a \(spelling)?") == ["grants", "rerun"])
        }
        #expect(QueryParser.ftsAllTermsExpression(for: "When is a re-run granted?")
            == "(\"rerun\" OR \"re run\") AND \"granted\"")
        #expect(QueryParser.terms(in: "forerunner rerouted") == ["forerunner", "rerouted"])
    }

    @Test func namesDisciplinesWithoutConfusingGiantSlalomForSlalom() {
        #expect(QueryParser.disciplines(in: "How far apart should GS gates be?") == [.giantSlalom])
        #expect(QueryParser.disciplines(in: "Giant Slalom — Technical Data") == [.giantSlalom])
        #expect(QueryParser.disciplines(in: "Slalom — Technical Data") == [.slalom])
        #expect(QueryParser.disciplines(in: "Kombi SL/GS") == [.slalom, .giantSlalom])
        #expect(QueryParser.disciplines(in: "Gate Panels for Giant Slalom, Super-G and Downhill")
            == [.giantSlalom, .superG, .downhill])
        #expect(QueryParser.disciplines(in: "Inspection of the Course").isEmpty)
    }
}

@Suite struct ContextTests {
    @Test func weightsCombinePriorityJurisdictionAndRole() throws {
        let store = try fixtureStore()
        let acg = store.document(id: 1), oisra = store.document(id: 2)
        #expect(AnswerContext(race: .general, role: .referee).weight(for: acg) == 1.4)
        #expect(AnswerContext(race: .general, role: .timing).weight(for: acg) == 1.0)
        #expect(AnswerContext(race: .oisra).weight(for: oisra) == 2.5)
        #expect(AnswerContext(race: .usss).weight(for: oisra) < 1)
    }

    @Test func oisraContextRanksAndPinsOISRA() async throws {
        let retriever = HybridRetriever(store: try fixtureStore(), semantic: nil)
        let question = "Who is on the jury and can a competitor get a re-run?"
        let oisraFirst = try await retriever.retrieve(question, limit: 3, context: AnswerContext(race: .oisra))
        #expect(oisraFirst.first?.chunk.documentID == 2)

        // Even for a question that mostly matches the U.S. guide, an OISRA passage stays in the results.
        let pinned = try await retriever.retrieve("assistant referee vote jury", limit: 3, context: AnswerContext(race: .oisra))
        #expect(pinned.contains { $0.chunk.documentID == 2 })
    }

    @Test func excludedRuleSetsNeverAppear() async throws {
        let retriever = HybridRetriever(store: try fixtureStore(), semantic: nil)
        let noOISRA = AnswerContext(race: .oisra, included: [.usss, .fis, .reference])
        let hits = try await retriever.retrieve("Who is on the jury and can a competitor get a re-run?", limit: 5, context: noOISRA)
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.chunk.documentID == 1 })
        #expect(noOISRA.summary == "OISRA · no OISRA")
        #expect(AnswerContext(race: .usss, role: .referee, included: [.oisra, .usss, .reference]).summary
            == "USSS · Referee · no FIS")
        #expect(AnswerContext(race: .usss, included: []).summary == "USSS · no rule sets")
    }

    @Test func instructionsIncludeContextAndRole() {
        let text = AnswerService.instructions(for: AnswerContext(race: .oisra, role: .referee))
        #expect(text.contains("supersede"))
        #expect(text.contains("serving as Referee"))
        #expect(!AnswerService.instructions(for: .default).contains("serving as"))
    }
}

@Suite struct CitationFollowingTests {
    @Test func citedRuleFollowsTheCitingPassage() async throws {
        let retriever = HybridRetriever(store: try fixtureStore(), semantic: nil)
        let hits = try await retriever.retrieve("hindered competitor provisional", limit: 4, context: AnswerContext(race: .oisra))
        let citing = try #require(hits.firstIndex { $0.chunk.documentID == 2 })
        #expect(hits.indices.contains(citing + 1))
        #expect(hits[citing + 1].chunk.ruleNumber == "614")  // 614.1 lives in the passage that starts at 614
    }

    @Test func citedRulesComeFromTheMatchingSentence() {
        let text = "a. Who names the Referee? [601.4.1.1] b. Who names the Start and Finish Referees? [601.3] c. Other duties [700]"
        let words = QueryParser.terms(in: "Who names the Start and Finish Referees?")
        #expect(HybridRetriever.citedRules(near: words, in: text, limit: 1) == ["601.3"])
        #expect(HybridRetriever.citedRules(near: words, in: "Nothing cited here.", limit: 2).isEmpty)
    }

    @Test func citedRuleComesFromTheMostSimilarSentence() {
        // "Protest submittal deadlines …" shares words with the question, but the question itself is closer.
        let text = "4. Protest submittal deadlines depend on the kind of protest [643] 5. Who can submit protests? [645] a. Team captains"
        let words = QueryParser.terms(in: "Who can submit protests?")
        #expect(HybridRetriever.citedRules(near: words, in: text, limit: 1) == ["645"])
    }

    @Test func echoScoreMatchesTheSameQuestion() {
        let question = QueryParser.topicalStems(QueryParser.terms(in: "Who can submit protests?"))
        let guide = "4. Deadlines differ [643] 5. Who can submit protests? [645] a. Team captains"
        #expect(HybridRetriever.echoScore(guide, question: question) == 1.0)
        #expect(HybridRetriever.echoScore("Protests must be in writing.", question: question) == 0)
    }

    @Test func echoingPassagesMoveToTheFront() throws {
        let retriever = HybridRetriever(store: try fixtureStore(), semantic: nil)
        func hit(_ id: Int, _ text: String) -> SearchHit {
            SearchHit(
                chunk: RuleChunk(id: id, documentID: 1, ruleNumber: nil, heading: nil, breadcrumb: nil, level: 0,
                                 ruleRefs: [], text: text, pageStart: 0, pageEnd: 0, part: 0),
                score: 1.0 / Double(id))
        }
        let ranked = [hit(1, "Protests in general."), hit(2, "Protest fees apply."), hit(3, "5. Who can submit protests? [645]")]
        let words = QueryParser.terms(in: "Who can submit protests?")
        #expect(retriever.promoteEchoes(ranked, words: words).map(\.chunk.id) == [3, 1, 2])
    }

    @Test func crossReferenceIsFollowedButNotShown() {
        let text = "3. The re-run remains valid if it proves slower than the first (hindered) run, 4. If the claim is"
            + " unjustified, the competitor is disqualified. (ARC cross-reference: Validity of a Re-Run, see ACR 623.3.1 and ACR 623.3.3.)"
        let chunk = RuleChunk(id: 1, documentID: 2, ruleNumber: nil, heading: "Validity of a Re-Run", breadcrumb: nil, level: 0,
                              ruleRefs: [], text: text, pageStart: 0, pageEnd: 0, part: 0)
        #expect(chunk.documentText.hasSuffix("the competitor is disqualified."))
        let words = QueryParser.terms(in: "What happens if a racer gets a re-run?")
        #expect(HybridRetriever.citedRules(near: words, in: text, limit: 2) == ["623.3.1", "623.3.3"])
    }

    @Test func excludedRulebooksAreNotFollowed() throws {
        let store = try fixtureStore()
        #expect(try store.ruleChunk(number: "614.1", prefer: .usss, included: [.usss])?.ruleNumber == "614")
        #expect(try store.ruleChunk(number: "614.1", prefer: .usss, included: [.oisra, .fis]) == nil)
    }
}

@Suite struct RetrievalTests {
    @Test func explicitRuleNumberRanksFirst() async throws {
        let retriever = HybridRetriever(store: try fixtureStore(), semantic: nil)
        let hits = try await retriever.retrieve("what does 614.2 say", limit: 3)
        #expect(hits.first?.chunk.ruleNumber == "614")
    }

    @Test func semanticIndexBuildsCachesAndSearches() async throws {
        let store = try fixtureStore()
        let cache = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }

        let index = SemanticIndex(embedder: HashingEmbedder(), cacheDirectory: cache, indexVersion: store.indexVersion)
        await index.build(chunks: try store.allChunks())
        #expect(await index.state == .ready)
        let top = await index.search("assistant referee vote jury", limit: 1)
        #expect(try store.chunks(ids: top.map(\.chunkID)).first?.ruleNumber == "601")

        // A second index reads the vectors from the cache file.
        let reloaded = SemanticIndex(embedder: HashingEmbedder(), cacheDirectory: cache, indexVersion: store.indexVersion)
        await reloaded.build(chunks: try store.allChunks())
        #expect(await reloaded.search("assistant referee vote jury", limit: 1).map(\.chunkID) == top.map(\.chunkID))
    }
}

@Suite struct CitationTests {
    private func citation(rule: String?, title: String, page: String) -> Citation {
        Citation(
            index: 1, chunkID: 1, documentID: 1, documentTitle: "Doc", filename: "doc.pdf", jurisdiction: .usss,
            ruleNumber: rule, title: title, pageIndex: 0, pageLabel: page, excerpt: "", ruleRefs: [])
    }

    @Test func labels() {
        #expect(citation(rule: "614.2", title: "", page: "87").shortLabel == "Rule 614.2 · p. 87")
        #expect(citation(rule: "4.2.5", title: "", page: "7").shortLabel == "§4.2.5 · p. 7")
        #expect(citation(rule: nil, title: "Composition of the Jury", page: "III/6").shortLabel
            == "Composition of the Jury · p. III/6")
        #expect(citation(rule: nil, title: "Radio Protocol", page: "Slide 4").pageDisplay == "Slide 4")
        #expect(RuleChunk.formatNumber("U601.4") == "Rule U601.4")
    }
}

@Suite struct AnswerTests {
    @Test func citationsAreParsedAndValidated() {
        #expect(AnswerService.citedIndexes(in: "A [2]. B [1, 3][2] c [x]") == [2, 1, 3])
    }

    @Test func streamsSourcesTextAndOnlyValidCitations() async throws {
        let service = AnswerService(retriever: HybridRetriever(store: try fixtureStore(), semantic: nil))
        let backend = MockBackend(reply: "Racers may not ski through gates [1]. See also [9].")
        var events: [AnswerEvent] = []
        for try await event in service.answer("Can racers ski through gates during inspection?", backend: backend) {
            events.append(event)
        }
        guard case .sources(let sources) = events.first else {
            Issue.record("expected sources first")
            return
        }
        #expect(sources.first?.ruleNumber == "614")
        #expect(sources.first?.shortLabel == "Rule 614 · p. 4")
        #expect(events.last == .finished(cited: [1]))
    }

    @Test func promptRespectsBudgetAndTagsJurisdiction() throws {
        let store = try fixtureStore()
        let service = AnswerService(retriever: HybridRetriever(store: store, semantic: nil))
        let hits = try store.allChunks().map { SearchHit(chunk: $0, score: 1) }
        let (_, all) = service.buildPrompt(question: "q", previous: nil, hits: hits, budget: 10_000)
        let (prompt, few) = service.buildPrompt(question: "q", previous: nil, hits: hits, budget: 150)
        #expect(all.count == hits.count)
        #expect(few.count >= 1 && few.count < hits.count)
        #expect(TokenEstimate.tokens(in: prompt) <= 150)

        let (oisraPrompt, oisraCitations) = service.buildPrompt(
            question: "q", previous: nil, hits: hits, context: AnswerContext(race: .oisra), budget: 10_000)
        #expect(oisraPrompt.contains("(OISRA, governing)"))
        #expect(oisraPrompt.contains("(U.S. Ski & Snowboard)"))
        #expect(oisraCitations.filter(\.governing).allSatisfy { $0.jurisdiction == .oisra })
    }

    @Test func followUpDetection() {
        let history = [ChatTurn(question: "How long is inspection?", answer: "…")]
        #expect(AnswerService.isFollowUp("What about in GS?", history: history))
        #expect(!AnswerService.isFollowUp("What about in GS?", history: []))
        #expect(!AnswerService.isFollowUp(
            "Who is responsible for appointing the assistant referee for speed events at a sanctioned race?",
            history: history))
    }
}

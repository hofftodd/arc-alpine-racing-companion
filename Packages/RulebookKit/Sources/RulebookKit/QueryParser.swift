import Foundation

/// Turns a plain-language question into search inputs.
public enum QueryParser {
    /// Rule references: "614.2", "rule 601", "ICR 805.3", "U601.4.2.3", "§4.2.5", "art. 4.2".
    public static func ruleNumbers(in text: String) -> [String] {
        var found: [String] = []
        // ACR/ICR rules: 3-4 digits with optional U prefix and dotted subsections.
        for match in text.matches(of: /(U?)(\d{3,4}(?:\.\d{1,3}){0,5})/) {
            guard isolated(match.range, in: text) else { continue }
            let number = String(match.output.1) + String(match.output.2)
            // Bare 3-4 digit numbers are often distances or years; keep them
            // only when dotted, U-prefixed, or preceded by "rule"/"ICR"/"ACR"/"§".
            let prefix = text[..<match.range.lowerBound].suffix(6).lowercased()
            if number.contains(".") || number.hasPrefix("U")
                || ["rule", "icr", "acr", "§"].contains(where: prefix.contains)
            {
                found.append(number)
            }
        }
        // Numbered sections of FIS documents: "§4.2.5", "art. 4.2", "section 7.1".
        for match in text.matches(of: /(§|[Aa]rt\.?|[Aa]rticle|[Ss]ection)\s*(\d{1,2}(?:\.\d{1,2}){1,4})/) {
            found.append(String(match.output.2))
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    /// Not part of a longer number or word on either side.
    private static func isolated(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if before.isNumber || before == "." || before.isLetter { return false }
        }
        if range.upperBound < text.endIndex, text[range.upperBound].isNumber { return false }
        return true
    }

    /// FTS5 expression: significant terms ORed together, each quoted so user
    /// punctuation can't break FTS syntax. BM25 rewards chunks matching more terms.
    public static func ftsExpression(for text: String, extraTerms: [String] = []) -> String {
        (terms(in: text) + extraTerms.filter { !terms(in: text).contains($0) })
            .map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    /// FTS5 expression requiring every topical term, for the precision pass; nil when the
    /// question has fewer than two topical terms.
    public static func ftsAllTermsExpression(for text: String) -> String? {
        let key = terms(in: text).filter { !genericWords.contains($0) }
        return key.count > 1 ? key.map { "\"\($0)\"" }.joined(separator: " AND ") : nil
    }

    /// First five letters of the question's topical terms: crude stemming ("referees" ~ "referee").
    public static func topicalStems(_ words: [String]) -> Set<String> {
        Set(words.filter { !genericWords.contains($0) }.map { String($0.prefix(5)) })
    }

    /// Shared stems over all stems (Jaccard similarity), 0 when either side is empty.
    static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        a.isEmpty || b.isEmpty ? 0 : Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    /// Words that say nothing about the topic ("What timing system should be used?").
    static let genericWords: Set<String> = [
        "use", "used", "using", "available", "being", "get", "given", "there", "any", "some", "one",
        "need", "needs", "needed", "required", "allowed",
    ]

    static func terms(in text: String) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(raw)
            // Keep the abbreviation itself too: documents use both "GS" and "Giant Slalom".
            let expanded = abbreviations[word].map { [word] + $0.split(separator: " ").map(String.init) } ?? [word]
            for t in expanded
            where t.count > 1 && !stopwords.contains(t) && seen.insert(t).inserted {
                terms.append(t)
            }
        }
        return terms
    }

    /// Common race-office shorthand expanded so it matches the documents' wording.
    static let abbreviations: [String: String] = [
        "td": "technical delegate",
        "dnf": "did not finish",
        "dns": "did not start",
        "dsq": "disqualified",
        "dq": "disqualified",
        "gs": "giant slalom",
        "sl": "slalom",
        "sg": "super",
        "dh": "downhill",
        "ac": "alpine combined",
        "coc": "chief of course",
        "cor": "chief of race",
        "osira": "oisra",
        "hs": "high school",
        "tdtr": "technical report",
        "eet": "equivalent electronic time",
        "maapp": "minor athlete abuse prevention policy",
    ]

    static let stopwords: Set<String> = [
        "a", "about", "an", "and", "are", "as", "at", "be", "by", "can", "could", "do", "does", "for",
        "from", "how", "i", "if", "in", "is", "it", "its", "me", "my", "of", "on", "or", "our",
        "should", "so", "that", "the", "their", "there", "they", "this", "to", "us", "was", "we",
        "what", "when", "where", "which", "who", "why", "will", "with", "would", "you", "your",
        "rule", "rules", "too", "very", "also", "just", "not", "than", "then", "much", "many", "more",
        "most", "all",
    ]

    /// Alpine disciplines, as questions and headings name them.
    public enum Discipline: Sendable, CaseIterable {
        case downhill, superG, giantSlalom, slalom
    }

    private static let disciplinePatterns: [(Discipline, NSRegularExpression)] = [
        (.downhill, #"\b(dh|downhill)\b"#),
        (.superG, #"\b(sg|super[\s-]?g)\b"#),
        (.giantSlalom, #"\b(gs|giant[\s-]slalom)\b"#),
        // "Slalom" on its own, not the end of "Giant Slalom".
        (.slalom, #"\bsl\b|(?<!giant )(?<!giant-)\bslalom\b"#),
    ].map { ($0, try! NSRegularExpression(pattern: $1, options: .caseInsensitive)) }

    /// Disciplines named in `text`: "GS" or "Giant Slalom" is giant slalom, not slalom.
    public static func disciplines(in text: String) -> Set<Discipline> {
        let range = NSRange(text.startIndex..., in: text)
        return Set(disciplinePatterns.filter { $0.1.firstMatch(in: text, range: range) != nil }.map(\.0))
    }
}

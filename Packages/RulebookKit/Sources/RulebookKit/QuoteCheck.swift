import Foundation

/// Checks that text the model puts in quotation marks really appears in the excerpts it was given.
/// Small models sometimes "quote" a paraphrase, and a misquoted rule reads as authoritative.
public enum QuoteCheck {
    /// Quotations in `answer` that aren't word for word in any of `sources`. Case, punctuation and
    /// dashes are ignored, and a quotation may skip words with "..." or "…". Short phrases
    /// (fewer than 4 words) are skipped: they match by chance or are just terms.
    public static func unverified(in answer: String, sources: [String]) -> [String] {
        let sourceWords = sources.map(words)
        var result: [String] = []
        for quote in quotations(in: answer) {
            let pieces = quote.split(separator: /\.\.\.|…/).map { words(String($0)) }.filter { $0.count >= 3 }
            guard pieces.reduce(0, { $0 + $1.count }) >= 4 else { continue }
            let found = pieces.allSatisfy { piece in sourceWords.contains { contains($0, piece) } }
            if !found, !result.contains(quote) { result.append(quote) }
        }
        return result
    }

    /// Text between curly quotes, or straight quotes on one line, 12 to 300 characters long. Text that
    /// starts or ends with a space lies between two quotations (`"a" and "b"`), so it's skipped.
    static func quotations(in text: String) -> [String] {
        text.matches(of: /“([^“”\n]{12,300})”|"([^"\n]{12,300})"/).compactMap { match in
            guard let quote = match.output.1 ?? match.output.2,
                quote.first?.isWhitespace == false, quote.last?.isWhitespace == false
            else { return nil }
            return String(quote)
        }
    }

    /// Lowercased words and numbers, without citation markers like [2].
    static func words(_ text: String) -> [Substring] {
        text.replacing(/\[\d+(?:\s*,\s*\d+)*\]/, with: " ").lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }

    private static func contains(_ haystack: [Substring], _ needle: [Substring]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { start in
            haystack[start..<(start + needle.count)].elementsEqual(needle)
        }
    }
}

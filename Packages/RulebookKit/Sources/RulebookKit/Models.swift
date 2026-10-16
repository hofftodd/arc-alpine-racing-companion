import Foundation

/// Whose rules a document carries. The conversation's race context decides precedence.
public enum Jurisdiction: String, Sendable, Codable, CaseIterable {
    case oisra
    case usss
    case fis
    case reference

    /// Label for the "Include" checkboxes.
    public var includeLabel: String {
        switch self {
        case .oisra: "OISRA (Oregon high school)"
        case .usss: "U.S. Ski & Snowboard"
        case .fis: "FIS"
        case .reference: "Medical & other references"
        }
    }

    public var shortName: String {
        switch self {
        case .oisra: "OISRA"
        case .usss: "U.S. Ski & Snowboard"
        case .fis: "FIS"
        case .reference: "Reference"
        }
    }
}

/// A bundled reference document (e.g. a chapter of the Alpine Officials' Manual).
public struct RuleDocument: Identifiable, Hashable, Sendable {
    public let id: Int
    public let slug: String
    public let title: String
    public let edition: String?
    public let collection: String?
    public let jurisdiction: Jurisdiction
    /// Catalog role ids the document is written for, e.g. ["referee", "technical-delegate"].
    public let roles: [String]
    public let filename: String
    public let priority: Double
    public let sortOrder: Int
    public let pageCount: Int
}

/// A Library section, e.g. "Alpine Officials' Manual".
public struct DocumentCollection: Identifiable, Hashable, Sendable {
    public let name: String
    public let documents: [RuleDocument]
    public var id: String { name }
}

/// A searchable passage: one section of a document, or part of a long one.
public struct RuleChunk: Identifiable, Hashable, Sendable {
    public let id: Int
    public let documentID: Int
    /// "614.2" (numbered rules) or "4.2.5" (numbered sections); nil for unnumbered headings.
    public let ruleNumber: String?
    public let heading: String?
    public let breadcrumb: String?
    public let level: Int
    /// Rules cited in the passage, e.g. ["601.4.1", "U601.4.2.3"].
    public let ruleRefs: [String]
    public let text: String
    /// 0-based PDF page indexes.
    public let pageStart: Int
    public let pageEnd: Int
    public let part: Int

    /// "Rule 614.2 Inspection Time", "§4.2.5 Penalty", or the heading alone.
    public var title: String {
        let number = ruleNumber.map(RuleChunk.formatNumber)
        switch (number, heading?.isEmpty == false ? heading : nil) {
        case let (n?, h?): return "\(n) \(h)"
        case let (n?, nil): return n
        case let (nil, h?): return h
        case (nil, nil): return "Introduction"
        }
    }

    /// ACR/ICR rules (3+ digit numbers) read "Rule 601.4"; document sections read "§4.2.5".
    static func formatNumber(_ number: String) -> String {
        let top = Int(number.trimmingCharacters(in: CharacterSet(charactersIn: "U")).split(separator: ".").first ?? "") ?? 0
        return top >= 100 ? "Rule \(number)" : "§\(number)"
    }

    /// Text used to compute the semantic embedding: context first, then body.
    var embeddingText: String {
        [breadcrumb, title, text].compactMap { $0 }.joined(separator: "\n")
    }
}

/// A chunk returned by retrieval, with the score used to rank it.
public struct SearchHit: Identifiable, Hashable, Sendable {
    public let chunk: RuleChunk
    public let score: Double
    public var id: Int { chunk.id }
}

/// A reference an answer can point to: which document, which section, which page.
public struct Citation: Identifiable, Hashable, Sendable, Codable {
    /// Number used in the answer text, e.g. `[2]`.
    public let index: Int
    public let chunkID: Int
    public let documentID: Int
    public let documentTitle: String
    public let filename: String
    public let jurisdiction: Jurisdiction
    public let ruleNumber: String?
    public let title: String
    /// 0-based PDF page index, for navigation.
    public let pageIndex: Int
    /// Printed page label: "87", "III/6", "Slide 4".
    public let pageLabel: String
    /// Passage text, used to highlight the passage in the PDF viewer.
    public let excerpt: String
    /// Rules the passage cites, e.g. ["601.4.1"].
    public let ruleRefs: [String]
    /// True when the race context makes this document's rules take precedence.
    public var governing: Bool = false

    public var id: Int { chunkID }

    /// "p. 87", "p. III/6", or "Slide 4".
    public var pageDisplay: String {
        pageLabel.first?.isLetter == true && pageLabel.contains(" ") ? pageLabel : "p. \(pageLabel)"
    }

    /// Short label for a citation chip: "Rule 614.2 · p. 87", "Re-Runs · p. 8".
    public var shortLabel: String {
        if let ruleNumber { return "\(RuleChunk.formatNumber(ruleNumber)) · \(pageDisplay)" }
        let name = title.count > 40 ? String(title.prefix(38)) + "…" : title
        return "\(name) · \(pageDisplay)"
    }
}

/// Table-of-contents entry for the library view.
public struct TOCEntry: Identifiable, Hashable, Sendable {
    public let position: Int
    public let number: String?
    public let heading: String
    public let level: Int
    public let pageIndex: Int
    public let chunkID: Int
    public var id: Int { position }

    public var title: String {
        switch (number, heading.isEmpty) {
        case let (n?, true): RuleChunk.formatNumber(n)
        case let (n?, false): "\(n) \(heading)"
        case (nil, _): heading
        }
    }
}

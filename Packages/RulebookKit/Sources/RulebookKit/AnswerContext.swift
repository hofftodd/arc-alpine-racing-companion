import Foundation

/// Which rule set governs the race being asked about.
public enum RaceContext: String, CaseIterable, Identifiable, Sendable, Codable {
    case general
    case usss
    case fis
    case oisra

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .general: "Any race"
        case .usss: "U.S. Ski & Snowboard (non-FIS)"
        case .fis: "FIS race"
        case .oisra: "Oregon High School (OISRA)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .general: "Any race"
        case .usss: "USSS"
        case .fis: "FIS"
        case .oisra: "OISRA"
        }
    }

    /// The rule set that takes precedence, whose passages are always included when relevant.
    public var governing: Jurisdiction? {
        switch self {
        case .general: nil
        case .usss: .usss
        case .fis: .fis
        case .oisra: .oisra
        }
    }

    /// Ranking weight per jurisdiction. Keep in sync with ingest/eval/eval_retrieval.py.
    public func weight(for jurisdiction: Jurisdiction) -> Double {
        switch (self, jurisdiction) {
        case (.oisra, .oisra): 2.5
        case (.oisra, .fis): 0.9
        case (.usss, .usss): 1.2
        case (.usss, .oisra), (.fis, .oisra): 0.3
        case (.fis, .fis): 1.3
        case (.fis, .usss): 0.9
        case (.general, .oisra): 0.6  // high-school rules shouldn't answer general questions by default
        default: 1.0
        }
    }

    /// Added to the model's instructions.
    public var instructions: String? {
        switch self {
        case .general:
            return """
                No specific race type was given. If the answer differs between U.S. Ski & Snowboard, FIS \
                and OISRA (Oregon high school) rules, say which rule set each statement comes from.
                """
        case .usss:
            return """
                This is a U.S. Ski & Snowboard sanctioned (non-FIS) race. The ACR and U.S. Ski & Snowboard \
                documents govern; FIS rules (ICR) apply only to issues the ACR does not address.
                """
        case .fis:
            return """
                This is a FIS race. FIS rules (ICR and FIS documents) govern; mention U.S. Ski & Snowboard \
                guidance only as supporting practice.
                """
        case .oisra:
            return """
                This race is run under OISRA (Oregon Interscholastic Ski Racing Association) rules. OISRA \
                rules supersede U.S. Ski & Snowboard and FIS rules. If an OISRA excerpt addresses the \
                question, answer from it and say that it is the OISRA rule. If an OISRA excerpt conflicts \
                with a U.S. Ski & Snowboard or FIS excerpt, follow OISRA and briefly note the difference. \
                If no OISRA excerpt addresses the question, say so, then answer from the other excerpts.
                """
        }
    }
}

/// The official asking the question. Ids match the `roles` used in ingest/catalog.yaml.
public enum OfficialRole: String, CaseIterable, Identifiable, Sendable, Codable {
    case none
    case competitionOfficial = "competition-official"
    case gateJudge = "gate-judge"
    case chiefOfCourse = "chief-of-course"
    case chiefOfRace = "chief-of-race"
    case referee
    case startFinishReferee = "start-finish-referee"
    case technicalDelegate = "technical-delegate"
    case timing
    case raceAdmin = "race-admin"
    case coach

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: "Any official"
        case .competitionOfficial: "Competition Official"
        case .gateJudge: "Gate Judge"
        case .chiefOfCourse: "Chief of Course"
        case .chiefOfRace: "Chief of Race"
        case .referee: "Referee"
        case .startFinishReferee: "Start / Finish Referee"
        case .technicalDelegate: "Technical Delegate"
        case .timing: "Chief of Timing & Calculations"
        case .raceAdmin: "Race Administrator / Secretary"
        case .coach: "Coach"
        }
    }

    /// Words that steer keyword search toward this official's duties.
    public var searchTerms: [String] {
        switch self {
        case .none: []
        case .competitionOfficial: ["official"]
        case .gateJudge: ["gate", "judge"]
        case .chiefOfCourse: ["chief", "course"]
        case .chiefOfRace: ["chief", "race"]
        case .referee: ["referee"]
        case .startFinishReferee: ["start", "finish", "referee"]
        case .technicalDelegate: ["technical", "delegate"]
        case .timing: ["timing", "calculations"]
        case .raceAdmin: ["administrator", "secretary"]
        case .coach: ["coach"]
        }
    }

    /// Ranking boost for documents written for this role.
    public static let documentBoost = 1.4

    /// Added to the model's instructions.
    public var instructions: String? {
        guard self != .none else { return nil }
        return """
            The person asking is serving as \(label). Focus on what the \(label) must do, check or decide, \
            and the rules that apply to that job. When something is another official's responsibility \
            (for example the Technical Delegate, Referee or Chief of Race), say whose it is.
            """
    }
}

/// Everything about the asker's situation that shapes retrieval and the answer.
public struct AnswerContext: Sendable, Hashable, Codable {
    public var race: RaceContext
    public var role: OfficialRole
    /// Rule sets whose documents may appear in results (the "Include" checkboxes).
    public var included: Set<Jurisdiction>

    public init(race: RaceContext = .general, role: OfficialRole = .none, included: Set<Jurisdiction> = Set(Jurisdiction.allCases)) {
        self.race = race
        self.role = role
        self.included = included
    }

    public static let `default` = AnswerContext()

    public func includes(_ document: RuleDocument?) -> Bool {
        included.contains(document?.jurisdiction ?? .reference)
    }

    /// Combined multiplier for a document's passages.
    func weight(for document: RuleDocument?) -> Double {
        guard let document else { return 1 }
        var weight = document.priority * race.weight(for: document.jurisdiction)
        if role != .none, document.roles.contains(role.rawValue) {
            weight *= OfficialRole.documentBoost
        }
        return weight
    }

    /// "OISRA · Referee · no FIS", "Any race".
    public var summary: String {
        var parts = [race.shortLabel]
        if role != .none { parts.append(role.label) }
        let excluded = Jurisdiction.allCases.filter { !included.contains($0) }
        if !excluded.isEmpty { parts.append("no " + excluded.map(\.shortName).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

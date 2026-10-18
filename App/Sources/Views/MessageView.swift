import RulebookKit
import SwiftUI

struct MessageView: View {
    let message: ChatMessage
    let isStreaming: Bool
    let open: (Citation) -> Void

    @State private var showSources = false

    var body: some View {
        if message.isUser {
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .padding(12)
                    .background(.tint.opacity(0.15), in: .rect(cornerRadius: 16))
                    .textSelection(.enabled)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if message.text.isEmpty && isStreaming {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(message.citations.isEmpty ? "Searching the guide…" : "Reading \(message.citations.count) rules…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(Self.render(message.text))
                        .textSelection(.enabled)
                        .foregroundStyle(message.failed ? Color.red : Color.primary)
                        .environment(\.openURL, OpenURLAction { url in
                            if let index = Self.citationIndex(from: url),
                                let citation = message.citations.first(where: { $0.index == index })
                            {
                                open(citation)
                            }
                            return .handled
                        })
                }

                if !message.unverifiedQuotes.isEmpty, !isStreaming {
                    Label {
                        Text(message.unverifiedQuotes.count == 1
                            ? "This quotation isn't word for word in the sources; check the cited page: “\(message.unverifiedQuotes[0])”"
                            : "These quotations aren't word for word in the sources; check the cited pages: "
                                + message.unverifiedQuotes.map { "“\($0)”" }.joined(separator: " "))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                if !message.citedSources.isEmpty {
                    CitationChips(citations: message.citedSources, open: open)
                }

                if !message.citations.isEmpty, !isStreaming {
                    DisclosureGroup("Sources (\(message.citations.count))", isExpanded: $showSources) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(message.citations) { citation in
                                SourceRow(citation: citation, cited: message.citedIndexes.contains(citation.index)) {
                                    open(citation)
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.callout)
                }

                if let engine = message.engine, !isStreaming {
                    Text(engine).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Renders inline Markdown and turns "[2]" markers into tappable citation links.
    static func render(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let plain = String(attributed.characters)
        for match in plain.matches(of: /\[(\d+)(?:\s*,\s*\d+)*\]/).reversed() {
            guard let index = Int(match.output.1) else { continue }
            let start = plain.distance(from: plain.startIndex, to: match.range.lowerBound)
            let length = plain.distance(from: match.range.lowerBound, to: match.range.upperBound)
            let lower = attributed.characters.index(attributed.startIndex, offsetBy: start)
            let upper = attributed.characters.index(lower, offsetBy: length)
            attributed[lower..<upper].link = URL(string: "citation://\(index)")
            attributed[lower..<upper].font = .caption.bold()
        }
        return attributed
    }

    static func citationIndex(from url: URL) -> Int? {
        url.scheme == "citation" ? url.host().flatMap(Int.init) : nil
    }
}

struct CitationChips: View {
    let citations: [Citation]
    let open: (Citation) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(citations) { citation in
                    Button {
                        open(citation)
                    } label: {
                        Label(citation.shortLabel, systemImage: citation.governing ? "checkmark.seal.fill" : "doc.text.magnifyingglass")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
        }
    }
}

struct SourceRow: View {
    let citation: Citation
    let cited: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("[\(citation.index)] \(citation.title)").bold()
                    Spacer()
                    Text(citation.pageDisplay).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if citation.governing {
                        Text("Governing")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: .capsule)
                    }
                    Text(citation.documentTitle).font(.caption).foregroundStyle(.secondary)
                }
                if !citation.ruleRefs.isEmpty {
                    Text("Cites " + citation.ruleRefs.prefix(6).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(citation.excerpt).lineLimit(4).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cited ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct EngineBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if case .searchOnly(let reason) = model.engine {
                Label {
                    Text("Search only. \(reason)")
                } icon: {
                    Image(systemName: "magnifyingglass")
                }
            } else if let progress = model.semanticProgress {
                Label("Preparing smart search… \(Int(progress * 100))%", systemImage: "sparkles")
            } else {
                Label(model.engineName, systemImage: "lock.shield")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

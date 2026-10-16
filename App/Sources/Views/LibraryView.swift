import RulebookKit
import SwiftUI

/// Browse the bundled documents by collection and section, or search them without the language model.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [Citation] = []

    var body: some View {
        List {
            if query.isEmpty {
                ForEach(model.store?.collections ?? []) { collection in
                    Section(collection.name) {
                        ForEach(collection.documents) { document in
                            NavigationLink {
                                TableOfContentsView(document: document)
                            } label: {
                                DocumentRow(document: document)
                            }
                        }
                    }
                }
            } else {
                ForEach(results) { citation in
                    NavigationLink {
                        DocumentViewer(filename: citation.filename, pageIndex: citation.pageIndex, highlight: citation.excerpt)
                            .navigationTitle(citation.shortLabel)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(citation.title).bold()
                                Spacer()
                                Text(citation.pageDisplay).foregroundStyle(.secondary)
                            }
                            Text(citation.documentTitle).font(.caption).foregroundStyle(.secondary)
                            Text(citation.excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            }
        }
        .navigationTitle("Library")
        .searchable(text: $query, prompt: "Search all documents")
        .task(id: query) {
            // Debounce typing.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let service = model.answerService, !query.isEmpty else { return }
            results = (try? await service.search(query, limit: 25, context: model.defaultContext)) ?? []
        }
    }
}

private struct DocumentRow: View {
    let document: RuleDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(document.title)
            HStack(spacing: 6) {
                if let edition = document.edition { Text(edition) }
                Text("\(document.pageCount) pages")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct TableOfContentsView: View {
    @Environment(AppModel.self) private var model
    let document: RuleDocument

    var body: some View {
        let entries = (try? model.store?.tableOfContents(documentID: document.id)) ?? []
        List(entries) { entry in
            NavigationLink {
                DocumentViewer(filename: document.filename, pageIndex: entry.pageIndex)
                    .navigationTitle(entry.title)
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title)
                        .font(entry.level == 0 ? .body.bold() : .body)
                    Spacer()
                    Text(model.store?.pageLabel(documentID: document.id, pageIndex: entry.pageIndex) ?? "")
                        .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                }
                .padding(.leading, CGFloat(min(entry.level, 3)) * 14)
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No sections", systemImage: "list.bullet",
                                       description: Text("Open the document to read it."))
            }
        }
        .navigationTitle(document.title)
        .toolbar {
            NavigationLink {
                DocumentViewer(filename: document.filename, pageIndex: 0)
                    .navigationTitle(document.title)
            } label: {
                Label("Open PDF", systemImage: "doc.richtext")
            }
        }
    }
}

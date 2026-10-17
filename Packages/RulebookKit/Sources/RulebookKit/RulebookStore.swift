import Foundation
import SQLite3

public enum RulebookStoreError: Error, LocalizedError {
    case openFailed(String)
    case queryFailed(String)
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let m): "Could not open the rulebook index: \(m)"
        case .queryFailed(let m): "Rulebook query failed: \(m)"
        case .unsupportedSchema(let v): "Rulebook index schema \(v) is not supported by this app version."
        }
    }
}

/// Read-only access to the bundled `rulebook.sqlite` built by `ingest/build_index.py`.
///
/// The connection is opened with `SQLITE_OPEN_FULLMUTEX`, so it is safe to use from any thread.
public final class RulebookStore: @unchecked Sendable {
    public static let supportedSchemaVersion = 1

    private let db: OpaquePointer
    public let documents: [RuleDocument]
    /// Changes whenever the source PDFs change; used to invalidate cached embeddings.
    public let indexVersion: String
    private let pageLabels: [Int: [String]]

    public init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? url.path
            sqlite3_close(handle)
            throw RulebookStoreError.openFailed(message)
        }
        db = handle

        let meta = Dictionary(
            uniqueKeysWithValues: try Self.query(handle, "SELECT key, value FROM meta") {
                ($0.string(0) ?? "", $0.string(1) ?? "")
            })
        let schema = Int(meta["schema_version"] ?? "") ?? 0
        guard schema == Self.supportedSchemaVersion else {
            sqlite3_close(handle)
            throw RulebookStoreError.unsupportedSchema(schema)
        }
        indexVersion = meta["index_version"] ?? "unknown"

        documents = try Self.query(
            handle,
            """
            SELECT id, slug, title, edition, collection, jurisdiction, roles, filename, priority, sort_order, page_count
            FROM documents ORDER BY sort_order, id
            """
        ) {
            RuleDocument(
                id: $0.int(0), slug: $0.string(1) ?? "", title: $0.string(2) ?? "",
                edition: $0.string(3), collection: $0.string(4),
                jurisdiction: Jurisdiction(rawValue: $0.string(5) ?? "") ?? .reference,
                roles: Self.words($0.string(6)), filename: $0.string(7) ?? "", priority: $0.double(8),
                sortOrder: $0.int(9), pageCount: $0.int(10))
        }

        var labels: [Int: [String]] = [:]
        for (doc, label) in try Self.query(
            handle, "SELECT doc_id, page_label FROM pages ORDER BY doc_id, page_index",
            map: { ($0.int(0), $0.string(1) ?? "") })
        {
            labels[doc, default: []].append(label)
        }
        pageLabels = labels
    }

    deinit {
        sqlite3_close(db)
    }

    public func document(id: Int) -> RuleDocument? {
        documents.first { $0.id == id }
    }

    /// Printed page label for a 0-based PDF page index.
    public func pageLabel(documentID: Int, pageIndex: Int) -> String {
        guard let labels = pageLabels[documentID], labels.indices.contains(pageIndex) else {
            return String(pageIndex + 1)
        }
        return labels[pageIndex]
    }

    // MARK: Chunks

    private static let chunkColumns =
        "c.id, c.doc_id, c.rule_number, c.heading, c.breadcrumb, c.level, c.rule_refs, c.text, c.page_start, c.page_end, c.part"

    private static func chunk(_ row: Row) -> RuleChunk {
        RuleChunk(
            id: row.int(0), documentID: row.int(1), ruleNumber: row.string(2), heading: row.string(3),
            breadcrumb: row.string(4), level: row.int(5), ruleRefs: words(row.string(6)),
            text: row.string(7) ?? "", pageStart: row.int(8), pageEnd: row.int(9), part: row.int(10))
    }

    /// Space-padded lists (" referee timing ") stored by the indexer.
    private static func words(_ text: String?) -> [String] {
        text?.split(separator: " ").map(String.init) ?? []
    }

    public func allChunks() throws -> [RuleChunk] {
        try Self.query(db, "SELECT \(Self.chunkColumns) FROM chunks c ORDER BY c.id", map: Self.chunk)
    }

    public func chunks(ids: [Int]) throws -> [RuleChunk] {
        guard !ids.isEmpty else { return [] }
        let list = ids.map(String.init).joined(separator: ",")
        let found = try Self.query(
            db, "SELECT \(Self.chunkColumns) FROM chunks c WHERE c.id IN (\(list))", map: Self.chunk)
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    /// Passages for a rule: the rule itself and its subsections ("614.2" also finds "614.2.1"),
    /// then passages that cite it (study guides cite rules as "[614.2]"), including the
    /// U.S.-specific "U614.2" form.
    public func chunks(forRule rule: String, limit: Int = 8) throws -> [RuleChunk] {
        let bare = rule.hasPrefix("U") ? String(rule.dropFirst()) : rule
        return try Self.query(
            db,
            """
            WITH numbered AS (   -- sections merged into a larger passage are still listed in toc
                SELECT chunk_id FROM toc WHERE number IN (?1, ?2) OR number LIKE ?2 || '.%'
            )
            SELECT \(Self.chunkColumns) FROM chunks c
            WHERE c.id IN numbered
               OR c.rule_refs LIKE '% ' || ?1 || ' %' OR c.rule_refs LIKE '% ' || ?1 || '.%'
               OR c.rule_refs LIKE '% ' || ?2 || ' %' OR c.rule_refs LIKE '% U' || ?2 || ' %'
            ORDER BY c.id IN numbered DESC, c.id
            LIMIT ?3
            """,
            bind: [.text(rule), .text(bare), .int(limit)], map: Self.chunk)
    }

    /// The passage that states a rule (not one that merely cites it), preferring the given
    /// rulebook: "623.1" -> ACR 623.1, or ICR 623.1 for a FIS race. Nil if the rule is in no
    /// included rulebook.
    public func ruleChunk(number rule: String, prefer: Jurisdiction, included: Set<Jurisdiction>) throws -> RuleChunk? {
        let bare = rule.hasPrefix("U") ? String(rule.dropFirst()) : rule
        let rows = try Self.query(
            db,
            """
            SELECT \(Self.chunkColumns), d.jurisdiction FROM toc t
            JOIN chunks c ON c.id = t.chunk_id JOIN documents d ON d.id = c.doc_id
            WHERE t.number IN (?1, ?2, 'U' || ?2)
            ORDER BY d.jurisdiction = ?3 DESC, t.number = ?1 DESC, c.id
            LIMIT 6
            """,
            bind: [.text(rule), .text(bare), .text(prefer.rawValue)]
        ) { row in (Self.chunk(row), Jurisdiction(rawValue: row.string(11) ?? "") ?? .reference) }
        return rows.first { included.contains($0.1) }?.0
    }

    /// BM25 full-text search. `matchExpression` is an FTS5 query (see `QueryParser`).
    /// Column weights: rule_number 4, heading 3, breadcrumb 1, rule_refs 2, text 1.
    public func keywordSearch(matchExpression: String, limit: Int) throws -> [SearchHit] {
        guard !matchExpression.isEmpty else { return [] }
        return try Self.query(
            db,
            """
            SELECT \(Self.chunkColumns), bm25(chunks_fts, 4.0, 3.0, 1.0, 2.0, 1.0) AS rank
            FROM chunks_fts JOIN chunks c ON c.id = chunks_fts.rowid
            WHERE chunks_fts MATCH ?1 ORDER BY rank LIMIT ?2
            """,
            bind: [.text(matchExpression), .int(limit)]
        ) { row in
            // bm25() is lower-is-better and negative; flip it so higher is better.
            SearchHit(chunk: Self.chunk(row), score: -row.double(11))
        }
    }

    /// Every heading of a document in reading order, including small sections that were
    /// merged into a neighbouring passage.
    public func tableOfContents(documentID: Int) throws -> [TOCEntry] {
        try Self.query(
            db,
            """
            SELECT position, number, heading, level, page_index, chunk_id FROM toc
            WHERE doc_id = ?1 ORDER BY position
            """,
            bind: [.int(documentID)]
        ) {
            TOCEntry(
                position: $0.int(0), number: $0.string(1), heading: $0.string(2) ?? "", level: $0.int(3),
                pageIndex: $0.int(4), chunkID: $0.int(5))
        }
    }

    /// Documents grouped by Library collection, in catalog order.
    public var collections: [DocumentCollection] {
        var order: [String] = []
        var grouped: [String: [RuleDocument]] = [:]
        for doc in documents {
            let name = doc.collection ?? "Other References"
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(doc)
        }
        return order.map { DocumentCollection(name: $0, documents: grouped[$0] ?? []) }
    }

    public func citation(for chunk: RuleChunk, index: Int, governing: Jurisdiction? = nil) -> Citation {
        let doc = document(id: chunk.documentID)
        let jurisdiction = doc?.jurisdiction ?? .reference
        return Citation(
            index: index, chunkID: chunk.id, documentID: chunk.documentID,
            documentTitle: doc?.title ?? "Document", filename: doc?.filename ?? "",
            jurisdiction: jurisdiction, ruleNumber: chunk.ruleNumber, title: chunk.title,
            pageIndex: chunk.pageStart,
            pageLabel: pageLabel(documentID: chunk.documentID, pageIndex: chunk.pageStart),
            excerpt: chunk.documentText, ruleRefs: chunk.ruleRefs, governing: governing == jurisdiction)
    }

    // MARK: SQLite plumbing

    enum Binding {
        case text(String)
        case int(Int)
    }

    struct Row {
        let stmt: OpaquePointer
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func string(_ i: Int32) -> String? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let c = sqlite3_column_text(stmt, i) else {
                return nil
            }
            return String(cString: c)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func query<T>(
        _ db: OpaquePointer, _ sql: String, bind: [Binding] = [], map: (Row) throws -> T
    ) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw RulebookStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in bind.enumerated() {
            let position = Int32(i + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(stmt, position, s, -1, transient)
            case .int(let n): sqlite3_bind_int64(stmt, position, Int64(n))
            }
        }
        var results: [T] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: results.append(try map(Row(stmt: stmt)))
            case SQLITE_DONE: return results
            default: throw RulebookStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }
}

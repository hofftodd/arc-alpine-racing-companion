import Accelerate
import Foundation
import NaturalLanguage

/// Turns text into a unit-length vector. Abstracted so tests can use a deterministic embedder.
public protocol TextEmbedder: Sendable {
    var dimension: Int { get }
    func prepare() async throws
    func embed(_ text: String) throws -> [Float]
}

/// Apple's on-device contextual embedding model (NaturalLanguage framework), mean-pooled.
public final class ContextualTextEmbedder: TextEmbedder, @unchecked Sendable {
    private let model: NLContextualEmbedding
    /// Roughly the model's token limit expressed in characters; longer text is embedded in windows.
    private let windowCharacters = 1_000

    public init?() {
        guard let model = NLContextualEmbedding(language: .english) else { return nil }
        self.model = model
    }

    public var dimension: Int { model.dimension }

    public func prepare() async throws {
        if !model.hasAvailableAssets {
            _ = try await model.requestAssets()
        }
        try model.load()
    }

    public func embed(_ text: String) throws -> [Float] {
        var sum = [Float](repeating: 0, count: model.dimension)
        var count = 0
        for window in windows(of: text).prefix(3) {
            let result = try model.embeddingResult(for: window, language: .english)
            result.enumerateTokenVectors(in: window.startIndex..<window.endIndex) { vector, _ in
                for i in 0..<min(vector.count, sum.count) { sum[i] += Float(vector[i]) }
                count += 1
                return true
            }
        }
        guard count > 0 else { return sum }
        return VectorMath.normalized(sum)
    }

    private func windows(of text: String) -> [String] {
        var result: [String] = []
        var remaining = Substring(text)
        while !remaining.isEmpty {
            var end = remaining.index(remaining.startIndex, offsetBy: windowCharacters, limitedBy: remaining.endIndex)
                ?? remaining.endIndex
            // Break on whitespace so words aren't cut in half.
            if end < remaining.endIndex, let space = remaining[..<end].lastIndex(where: \.isWhitespace) {
                end = space
            }
            result.append(String(remaining[..<end]))
            remaining = remaining[end...].drop(while: \.isWhitespace)
        }
        return result
    }
}

enum VectorMath {
    static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = norm.squareRoot()
        guard norm > 0 else { return v }
        return vDSP.divide(v, norm)
    }
}

/// Brute-force cosine-similarity index over every chunk. A few thousand
/// vectors search in well under a millisecond with Accelerate.
public actor SemanticIndex {
    public enum State: Sendable, Equatable {
        case idle
        case building(progress: Double)
        case ready
        case unavailable(String)
    }

    private let embedder: any TextEmbedder
    private let cacheURL: URL?
    public private(set) var state: State = .idle
    private var chunkIDs: [Int] = []
    private var matrix: [Float] = []  // row-major, chunkIDs.count x dimension
    private var dimension = 0

    /// - Parameter cacheDirectory: where vectors are saved, keyed by the index version.
    public init(embedder: any TextEmbedder, cacheDirectory: URL?, indexVersion: String) {
        self.embedder = embedder
        self.cacheURL = cacheDirectory?.appending(path: "embeddings-\(indexVersion).bin")
    }

    /// Loads cached vectors or computes them. Keyword search works while this runs.
    public func build(chunks: [RuleChunk], onProgress: @Sendable (Double) -> Void = { _ in }) async {
        guard state != .ready else { return }
        do {
            try await embedder.prepare()
            dimension = embedder.dimension
            if let cached = loadCache(expectedIDs: chunks.map(\.id)) {
                (chunkIDs, matrix) = cached
                state = .ready
                return
            }
            var ids: [Int] = []
            var rows: [Float] = []
            rows.reserveCapacity(chunks.count * dimension)
            for (i, chunk) in chunks.enumerated() {
                let vector = try embedder.embed(chunk.embeddingText)
                guard vector.count == dimension else { continue }
                ids.append(chunk.id)
                rows.append(contentsOf: vector)
                if i % 25 == 0 {
                    let progress = Double(i) / Double(max(chunks.count, 1))
                    state = .building(progress: progress)
                    onProgress(progress)
                    await Task.yield()
                }
            }
            chunkIDs = ids
            matrix = rows
            saveCache()
            state = .ready
            onProgress(1)
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }

    /// Top chunks by cosine similarity. Empty until the index is ready.
    public func search(_ text: String, limit: Int) -> [(chunkID: Int, score: Double)] {
        guard state == .ready, !chunkIDs.isEmpty, let query = try? embedder.embed(text),
            query.count == dimension
        else { return [] }
        var scores = [Float](repeating: 0, count: chunkIDs.count)
        // scores = matrix (n x d) * query (d x 1)
        vDSP_mmul(matrix, 1, query, 1, &scores, 1, vDSP_Length(chunkIDs.count), 1, vDSP_Length(dimension))
        return scores.indices
            .sorted { scores[$0] > scores[$1] }
            .prefix(limit)
            .map { (chunkIDs[$0], Double(scores[$0])) }
    }

    // MARK: Cache file: [count: Int64][dimension: Int64][ids: Int64 * count][vectors: Float32 * count * dimension]

    private func loadCache(expectedIDs: [Int]) -> ([Int], [Float])? {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL), data.count >= 16 else { return nil }
        return data.withUnsafeBytes { raw -> ([Int], [Float])? in
            let count = Int(raw.loadUnaligned(fromByteOffset: 0, as: Int64.self))
            let dim = Int(raw.loadUnaligned(fromByteOffset: 8, as: Int64.self))
            guard dim == dimension, data.count == 16 + count * 8 + count * dim * 4 else { return nil }
            let ids = (0..<count).map { Int(raw.loadUnaligned(fromByteOffset: 16 + $0 * 8, as: Int64.self)) }
            guard Set(ids) == Set(expectedIDs) else { return nil }
            let base = 16 + count * 8
            let vectors = (0..<(count * dim)).map { raw.loadUnaligned(fromByteOffset: base + $0 * 4, as: Float.self) }
            return (ids, vectors)
        }
    }

    private func saveCache() {
        guard let cacheURL else { return }
        var data = Data()
        withUnsafeBytes(of: Int64(chunkIDs.count)) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int64(dimension)) { data.append(contentsOf: $0) }
        for id in chunkIDs { withUnsafeBytes(of: Int64(id)) { data.append(contentsOf: $0) } }
        matrix.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        let directory = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Remove vectors from older index versions.
        if let old = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in old where url.lastPathComponent.hasPrefix("embeddings-") && url != cacheURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try? data.write(to: cacheURL, options: .atomic)
    }
}

import Foundation

/// Tunable clustering parameters.
public struct TopicConfiguration: Sendable, Equatable {
    public static let `default` = TopicConfiguration()

    /// Cosine similarity a session needs to join an existing topic (0...1).
    public let similarityThreshold: Double
    /// Weight of structural signals (repo, domain, ticket) against plain words.
    public let structuralWeight: Double
    /// Minutes a session must be idle before it is clustered, so growing sessions are not
    /// assigned too early.
    public let settleMinutes: Double
    public let keywordCount: Int

    public init(
        similarityThreshold: Double = 0.3, structuralWeight: Double = 3, settleMinutes: Double = 25,
        keywordCount: Int = 5
    ) {
        self.similarityThreshold = min(max(similarityThreshold, 0), 1)
        self.structuralWeight = max(structuralWeight, 0)
        self.settleMinutes = max(settleMinutes, 0)
        self.keywordCount = max(keywordCount, 0)
    }
}

/// One session as a clustering document.
public struct TopicDocument: Sendable, Equatable {
    public let id: Int64
    public let time: Date
    /// Plain word counts.
    public let terms: [String: Int]
    /// Structural signals such as `repo:github.com/acme/api`, `domain:acme.example`, `ticket:ABC-12`.
    public let features: [String]

    public init(id: Int64, time: Date, terms: [String: Int], features: [String]) {
        self.id = id
        self.time = time
        self.terms = terms
        self.features = features
    }
}

/// Sparse TF-IDF vector. Feature keys keep their `kind:` prefix, words have none.
struct SparseVector {
    var weights: [String: Double]

    var norm: Double { weights.values.reduce(0) { $0 + $1 * $1 }.squareRoot() }

    func dot(_ other: SparseVector) -> Double {
        let (small, large) = weights.count <= other.weights.count ? (self, other) : (other, self)
        return small.weights.reduce(0) { $0 + $1.value * (large.weights[$1.key] ?? 0) }
    }

    mutating func add(_ other: SparseVector) {
        for (key, value) in other.weights { weights[key, default: 0] += value }
    }
}

/// Why a session landed in a topic.
public struct TopicReason: Sendable, Equatable {
    public let sharedFeatures: [String]
    public let sharedTerms: [String]
    public let similarity: Double

    /// Sentence for the user.
    public var text: String {
        var parts: [String] = []
        let phrases = [
            "repo": "gleiches Repo", "domain": "gleiche Domain", "ticket": "gleiches Ticket",
        ]
        for feature in sharedFeatures {
            let pieces = feature.split(separator: ":", maxSplits: 1).map(String.init)
            if pieces.count == 2 { parts.append("\(phrases[pieces[0]] ?? pieces[0]) \(pieces[1])") }
        }
        if !sharedTerms.isEmpty {
            parts.append("gemeinsame Begriffe: " + sharedTerms.joined(separator: ", "))
        }
        let percent = Int((similarity * 100).rounded())
        return (parts.isEmpty ? "Ähnlicher Text" : parts.joined(separator: "; "))
            + " (Ähnlichkeit \(percent) %)"
    }
}

/// A topic centroid with a cached norm, so comparing it costs one dot product.
struct Centroid {
    private(set) var sum = SparseVector(weights: [:])
    private(set) var norm = 0.0

    init(_ vector: SparseVector) { add(vector) }

    mutating func add(_ vector: SparseVector) {
        sum.add(vector)
        norm = sum.norm
    }
}

/// Where the clusterer put a session.
public enum TopicPlacement: Sendable, Equatable {
    case existing(topicID: Int64, reason: TopicReason)
    /// A topic that does not exist yet. Sessions with the same `group` form one new topic;
    /// `reason` is nil for the first session of the group.
    case new(group: Int, reason: TopicReason?)
}

/// Pure TF-IDF clustering: no database, no randomness, same input gives the same output.
public enum TopicClusterer {
    /// - Parameters:
    ///   - fixed: sessions that already belong to a topic (keys: session id, values: topic id).
    ///     They seed the topic centroids and are never moved.
    ///   - free: sessions to place, in any order; they are processed oldest first.
    ///   - corpus: every document, used for inverse document frequencies.
    public static func place(
        free: [TopicDocument], fixed: [Int64: Int64], corpus: [TopicDocument],
        configuration: TopicConfiguration = .default
    ) -> [Int64: TopicPlacement] {
        let idf = inverseDocumentFrequencies(corpus)
        func vector(_ document: TopicDocument) -> SparseVector {
            vectorize(document, idf: idf, structuralWeight: configuration.structuralWeight)
        }

        var centroids: [Int64: Centroid] = [:]
        var groups: [Int: Centroid] = [:]
        for document in corpus {
            guard let topic = fixed[document.id] else { continue }
            let own = normalized(vector(document))
            if centroids[topic] == nil {
                centroids[topic] = Centroid(own)
            } else {
                centroids[topic]?.add(own)
            }
        }

        var result: [Int64: TopicPlacement] = [:]
        let ordered = free.sorted { ($0.time, $0.id) < ($1.time, $1.id) }
        for document in ordered {
            let own = normalized(vector(document))
            var best: (key: Int64?, group: Int?, similarity: Double, centroid: Centroid)?
            for (topic, centroid) in centroids.sorted(by: { $0.key < $1.key }) {
                let similarity = cosine(own, centroid)
                if similarity > (best?.similarity ?? -1) {
                    best = (topic, nil, similarity, centroid)
                }
            }
            for (group, centroid) in groups.sorted(by: { $0.key < $1.key }) {
                let similarity = cosine(own, centroid)
                if similarity > (best?.similarity ?? -1) {
                    best = (nil, group, similarity, centroid)
                }
            }

            if let best, best.similarity > 0, best.similarity >= configuration.similarityThreshold {
                let reason = explain(own, against: best.centroid.sum, similarity: best.similarity)
                if let topic = best.key {
                    result[document.id] = .existing(topicID: topic, reason: reason)
                    centroids[topic]?.add(own)
                } else if let group = best.group {
                    result[document.id] = .new(group: group, reason: reason)
                    groups[group]?.add(own)
                }
            } else {
                let group = groups.count
                groups[group] = Centroid(own)
                result[document.id] = .new(group: group, reason: nil)
            }
        }
        return result
    }

    /// Strongest words and structural signals of a set of documents, for labels and keywords.
    /// In a topic of several sessions a keyword must occur in at least two of them and a
    /// structural signal in at least half, so a single stray token cannot name a topic.
    public static func keywords(
        of documents: [TopicDocument], idf: [String: Double],
        configuration: TopicConfiguration = .default
    ) -> (features: [String], terms: [String]) {
        var sum = SparseVector(weights: [:])
        var occurrences: [String: Int] = [:]
        for document in documents {
            sum.add(
                normalized(
                    vectorize(document, idf: idf, structuralWeight: configuration.structuralWeight))
            )
            for key in Set(document.terms.keys).union(document.features) {
                occurrences[key, default: 0] += 1
            }
        }
        let count = documents.count
        let ranked = sum.weights.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        // A repo names a topic best, then a ticket, then a website; weight orders within a kind.
        let kindRank = ["repo": 0, "ticket": 1, "domain": 2]
        let features = ranked.enumerated().filter {
            $0.element.key.contains(":")
                && (count < 2 || (occurrences[$0.element.key] ?? 0) * 2 >= count)
        }.sorted {
            func rank(_ key: String) -> Int { kindRank[String(key.prefix { $0 != ":" })] ?? 3 }
            return (rank($0.element.key), $0.offset) < (rank($1.element.key), $1.offset)
        }.prefix(3).map(\.element.key)
        let terms = ranked.filter {
            !$0.key.contains(":") && (count < 2 || (occurrences[$0.key] ?? 0) >= 2)
        }.prefix(configuration.keywordCount).map(\.key)
        return (features, terms)
    }

    static func inverseDocumentFrequencies(_ corpus: [TopicDocument]) -> [String: Double] {
        var frequency: [String: Int] = [:]
        for document in corpus {
            for key in Set(document.terms.keys).union(document.features) {
                frequency[key, default: 0] += 1
            }
        }
        let count = Double(corpus.count)
        return frequency.mapValues { log((count + 1) / (Double($0) + 1)) + 1 }
    }

    static func vectorize(
        _ document: TopicDocument, idf: [String: Double], structuralWeight: Double
    ) -> SparseVector {
        var weights: [String: Double] = [:]
        for (term, count) in document.terms {
            weights[term] = (1 + log(Double(count))) * (idf[term] ?? 1)
        }
        for feature in document.features {
            weights[feature] = structuralWeight * (idf[feature] ?? 1)
        }
        return SparseVector(weights: weights)
    }

    static func normalized(_ vector: SparseVector) -> SparseVector {
        let norm = vector.norm
        guard norm > 0 else { return vector }
        return SparseVector(weights: vector.weights.mapValues { $0 / norm })
    }

    /// Cosine similarity, rounded so that summation order cannot flip ties or the threshold.
    static func cosine(_ lhs: SparseVector, _ rhs: Centroid) -> Double {
        let norms = lhs.norm * rhs.norm
        guard norms > 0 else { return 0 }
        return (lhs.dot(rhs.sum) / norms * 1e9).rounded() / 1e9
    }

    private static func explain(
        _ own: SparseVector, against centroid: SparseVector, similarity: Double
    ) -> TopicReason {
        let shared = own.weights.filter { centroid.weights[$0.key] != nil }
            .map { (key: $0.key, strength: $0.value * (centroid.weights[$0.key] ?? 0)) }
            .sorted { ($0.strength, $1.key) > ($1.strength, $0.key) }
        return TopicReason(
            sharedFeatures: shared.filter { $0.key.contains(":") }.prefix(2).map(\.key),
            sharedTerms: shared.filter { !$0.key.contains(":") }.prefix(3).map(\.key),
            similarity: similarity)
    }
}

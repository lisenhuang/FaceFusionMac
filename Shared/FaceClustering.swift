//
//  FaceClustering.swift
//  Shared between FaceFusionMac (app) and FaceFusionEngine (XPC service).
//
//  Turning "faces seen in 40 sampled frames" into "the people in this video".
//
//  Pure arithmetic over identity vectors, with no image or media types in
//  sight, which is what lets the tests exercise it without models on disk.
//

import Foundation

/// Groups face identities collected across many frames into one entry per
/// person.
///
/// Single-pass and greedy: each identity joins the nearest existing person
/// within `threshold`, or starts a new one. Proper agglomerative clustering
/// would be tidier, but it needs the whole set up front, and this runs while
/// frames are still arriving so the picker can fill in as the scan proceeds.
///
/// Each person keeps a running mean of every identity merged into it, which
/// settles onto something more representative than whichever frame happened to
/// be sampled first — a scan that catches someone mid-blink should not spend
/// the rest of the video matching against a blink.
public struct FaceClusterer {

    public struct Person: Sendable, Identifiable {
        public var id: Int
        /// Mean of every identity merged in so far, re-normalised.
        public var identity: FaceIdentity
        /// How many sampled detections landed here. A stand-in for screen time.
        public var appearances: Int
        public var firstSeen: Double
        public var lastSeen: Double
        /// Best detector confidence seen, used to pick the representative crop.
        public var bestScore: Double
        /// Largest fraction of the frame this face has covered.
        public var largestCoverage: Double

        /// Unnormalised sum of the merged identities. Kept so a merge is an
        /// addition rather than a re-derivation from vectors already dropped.
        var accumulated: [Float]
    }

    /// Cosine distance below which two faces are the same person. Deliberately
    /// tighter than the swap-time match: grouping errors here are permanent
    /// for the session, whereas the swap threshold can be nudged afterwards.
    public var threshold: Double

    public private(set) var people: [Person] = []
    private var nextID = 0

    public init(threshold: Double = 0.5) {
        self.threshold = threshold
    }

    /// The outcome of folding one detection into the set.
    public struct Placement: Sendable {
        public var id: Int
        /// True when this detection started a new person — the only moment
        /// worth the cost of cutting a thumbnail out of the frame.
        public var isNew: Bool
        /// True when this detection is the best look at that person so far,
        /// so an existing thumbnail is worth replacing.
        public var isBestSoFar: Bool
    }

    /// Folds one detection in, returning where it landed.
    ///
    /// - Parameters:
    ///   - time: seconds into the target, for the "appears from … to …" caption.
    ///   - score: detector confidence.
    ///   - coverage: face area as a fraction of the frame, for ordering.
    @discardableResult
    public mutating func add(_ identity: FaceIdentity,
                             at time: Double,
                             score: Double,
                             coverage: Double) -> Placement {
        var bestIndex: Int?
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, person) in people.enumerated() {
            let distance = person.identity.distance(to: identity)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        guard let index = bestIndex, bestDistance <= threshold else {
            let id = nextID
            nextID += 1
            people.append(Person(id: id,
                                 identity: identity,
                                 appearances: 1,
                                 firstSeen: time,
                                 lastSeen: time,
                                 bestScore: score,
                                 largestCoverage: coverage,
                                 accumulated: identity.vector))
            return Placement(id: id, isNew: true, isBestSoFar: true)
        }

        var person = people[index]
        // A better look at someone already known: bigger in frame wins, since
        // that is what makes a legible thumbnail and a clean embedding.
        let isBest = coverage > person.largestCoverage
        person.appearances += 1
        person.firstSeen = min(person.firstSeen, time)
        person.lastSeen = max(person.lastSeen, time)
        person.bestScore = max(person.bestScore, score)
        person.largestCoverage = max(person.largestCoverage, coverage)

        let count = min(person.accumulated.count, identity.vector.count)
        for element in 0 ..< count { person.accumulated[element] += identity.vector[element] }
        person.identity = FaceIdentity(vector: Self.normalized(person.accumulated))

        people[index] = person
        return Placement(id: person.id, isNew: false, isBestSoFar: isBest)
    }

    /// People in the order the picker should show them: whoever is on screen
    /// most and largest first, so the subject of the shot leads and a passer-by
    /// in one frame trails.
    public var byProminence: [Person] {
        people.sorted { a, b in
            let left = Double(a.appearances) * (0.25 + a.largestCoverage)
            let right = Double(b.appearances) * (0.25 + b.largestCoverage)
            if left != right { return left > right }
            return a.id < b.id
        }
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        var magnitude: Float = 0
        for value in vector { magnitude += value * value }
        magnitude = sqrtf(magnitude)
        guard magnitude > .ulpOfOne else { return vector }
        return vector.map { $0 / magnitude }
    }
}

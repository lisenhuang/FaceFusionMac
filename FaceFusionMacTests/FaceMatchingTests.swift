//
//  FaceMatchingTests.swift
//  FaceFusionMacTests
//
//  Identity distance and the clustering that turns "faces in 40 sampled
//  frames" into "the people in this video".
//
//  No models and no media: these are arithmetic over synthetic 512-vectors, so
//  they run everywhere, unlike the integration suite.
//

import Testing
import Foundation

// MARK: - Fixtures

/// A unit vector that leans on one axis, with the rest of its energy spread
/// deterministically. Two identities built from the same axis are close; two
/// built from different axes are far — which is the only property the matcher
/// depends on.
private func identity(axis: Int, jitter: Float = 0, seed: Int = 0) -> FaceIdentity {
    var values = [Float](repeating: 0, count: 512)
    values[axis % 512] = 1
    if jitter > 0 {
        // Deterministic pseudo-noise: a hash would do, but a fixed recurrence
        // keeps the test readable and reproducible across platforms.
        var state = Float(seed + 1)
        for index in 0 ..< 512 {
            state = (state * 1.37).truncatingRemainder(dividingBy: 2) - 1
            values[index] += jitter * state
        }
    }
    var magnitude: Float = 0
    for value in values { magnitude += value * value }
    magnitude = sqrtf(magnitude)
    return FaceIdentity(vector: values.map { $0 / magnitude })
}

// MARK: - Distance

@Suite("Face identity distance")
struct FaceIdentityTests {

    @Test func identicalVectorsAreZeroApart() {
        let face = identity(axis: 3)
        #expect(abs(face.distance(to: face)) < 1e-5)
    }

    /// Orthogonal identities sit at 1, which is the midpoint of the range the
    /// default threshold is chosen against.
    @Test func orthogonalVectorsAreOneApart() {
        let a = identity(axis: 0)
        let b = identity(axis: 1)
        #expect(abs(a.distance(to: b) - 1) < 1e-5)
    }

    @Test func oppositeVectorsAreTwoApart() {
        let a = identity(axis: 0)
        let b = FaceIdentity(vector: a.vector.map { -$0 })
        #expect(abs(a.distance(to: b) - 2) < 1e-5)
    }

    /// Small perturbations have to stay inside the default match distance, or
    /// a person who turns their head stops being themselves mid-clip.
    @Test func jitteredSelfStaysWithinDefaultDistance() {
        let clean = identity(axis: 7)
        for seed in 0 ..< 5 {
            let noisy = identity(axis: 7, jitter: 0.05, seed: seed)
            #expect(clean.distance(to: noisy) < defaultFaceMatchDistance,
                    "seed \(seed) drifted to \(clean.distance(to: noisy))")
        }
    }

    @Test func nearestPicksTheClosestOfSeveral() {
        let probe = identity(axis: 4)
        let others = [identity(axis: 0), identity(axis: 4), identity(axis: 9)]
        #expect(probe.nearestDistance(among: others) < 1e-5)
    }

    /// An empty reference set must not read as "matches everything" — that
    /// would swap every face in the frame the moment the user unticks the last
    /// person.
    @Test func nearestOfNothingIsInfinite() {
        #expect(identity(axis: 1).nearestDistance(among: []) > 1e9)
    }

    /// Mismatched lengths would mean a vector from a different model. Better a
    /// distance nothing can match than a truncated comparison that looks fine.
    @Test func mismatchedLengthsDoNotMatch() {
        let full = identity(axis: 0)
        let stub = FaceIdentity(vector: [])
        #expect(full.distance(to: stub) > 1e9)
    }
}

// MARK: - Clustering

@Suite("Grouping faces into people")
struct FaceClusteringTests {

    @Test func repeatSightingsCollapseToOnePerson() {
        var clusterer = FaceClusterer()
        for second in 0 ..< 10 {
            clusterer.add(identity(axis: 2, jitter: 0.05, seed: second),
                          at: Double(second), score: 0.9, coverage: 0.05)
        }
        #expect(clusterer.people.count == 1)
        #expect(clusterer.people[0].appearances == 10)
        #expect(clusterer.people[0].firstSeen == 0)
        #expect(clusterer.people[0].lastSeen == 9)
    }

    @Test func differentPeopleStaySeparate() {
        var clusterer = FaceClusterer()
        for axis in [0, 40, 200] {
            for second in 0 ..< 4 {
                clusterer.add(identity(axis: axis, jitter: 0.04, seed: second),
                              at: Double(second), score: 0.9, coverage: 0.05)
            }
        }
        #expect(clusterer.people.count == 3)
        #expect(clusterer.people.allSatisfy { $0.appearances == 4 })
    }

    /// The first sighting of someone is the one worth cutting a thumbnail
    /// from; later ones only when they are a better look.
    @Test func reportsWhenAThumbnailIsWorthTaking() {
        var clusterer = FaceClusterer()

        let first = clusterer.add(identity(axis: 5), at: 0, score: 0.9, coverage: 0.02)
        #expect(first.isNew)

        let smaller = clusterer.add(identity(axis: 5, jitter: 0.03), at: 1,
                                    score: 0.9, coverage: 0.01)
        #expect(!smaller.isNew)
        #expect(!smaller.isBestSoFar, "a smaller face should not replace the thumbnail")

        let bigger = clusterer.add(identity(axis: 5, jitter: 0.03), at: 2,
                                   score: 0.9, coverage: 0.20)
        #expect(!bigger.isNew)
        #expect(bigger.isBestSoFar, "a much larger face should replace the thumbnail")
    }

    /// A person's stored identity is the mean of every sighting, so one odd
    /// frame cannot define them for the rest of the video.
    @Test func mergingPullsTheIdentityTowardTheAverage() {
        var clusterer = FaceClusterer()
        let odd = identity(axis: 6, jitter: 0.3, seed: 1)
        clusterer.add(odd, at: 0, score: 0.9, coverage: 0.05)

        let clean = identity(axis: 6)
        let strayDistance = clean.distance(to: odd)

        for seed in 0 ..< 12 {
            clusterer.add(identity(axis: 6, jitter: 0.02, seed: seed),
                          at: Double(seed), score: 0.9, coverage: 0.05)
        }
        let settled = clusterer.people[0].identity
        #expect(clean.distance(to: settled) < strayDistance,
                "identity did not settle: \(clean.distance(to: settled)) vs \(strayDistance)")

        // And it must stay a unit vector, or every distance drifts with it.
        let magnitude = sqrtf(settled.vector.reduce(0) { $0 + $1 * $1 })
        #expect(abs(magnitude - 1) < 1e-4, "magnitude \(magnitude)")
    }

    /// Ordering decides which face the picker shows first, and which one gets
    /// ticked by default after a scan.
    @Test func prominenceOrdersBySubjectFirst() {
        var clusterer = FaceClusterer()

        // A passer-by: one frame, small.
        clusterer.add(identity(axis: 100), at: 3, score: 0.8, coverage: 0.005)
        // The subject: everywhere, large.
        for second in 0 ..< 20 {
            clusterer.add(identity(axis: 0, jitter: 0.03, seed: second),
                          at: Double(second), score: 0.95, coverage: 0.18)
        }

        let ordered = clusterer.byProminence
        #expect(ordered.count == 2)
        #expect(ordered[0].appearances == 20, "the subject should lead")
        #expect(ordered[1].appearances == 1)
    }

    /// A tighter threshold splits what a looser one merges. This is the knob
    /// behind "the wrong person got replaced".
    @Test func thresholdControlsHowReadilyFacesMerge() {
        let a = identity(axis: 0)
        let b = identity(axis: 1)

        var loose = FaceClusterer(threshold: 1.5)
        loose.add(a, at: 0, score: 0.9, coverage: 0.1)
        loose.add(b, at: 1, score: 0.9, coverage: 0.1)
        #expect(loose.people.count == 1)

        var tight = FaceClusterer(threshold: 0.2)
        tight.add(a, at: 0, score: 0.9, coverage: 0.1)
        tight.add(b, at: 1, score: 0.9, coverage: 0.1)
        #expect(tight.people.count == 2)
    }

    @Test func identifiersAreStableAcrossMerges() {
        var clusterer = FaceClusterer()
        let first = clusterer.add(identity(axis: 0), at: 0, score: 0.9, coverage: 0.1)
        let second = clusterer.add(identity(axis: 50), at: 0, score: 0.9, coverage: 0.1)
        let again = clusterer.add(identity(axis: 0, jitter: 0.02), at: 1, score: 0.9, coverage: 0.1)

        #expect(first.id != second.id)
        #expect(again.id == first.id)
    }
}

// MARK: - Selection

@Suite("Face selection")
struct FaceSelectionTests {

    /// Only `.reference` costs an identity pass per detection, and the preview
    /// leans on this to stay cheap while scrubbing.
    @Test func onlyReferenceNeedsIdentities() {
        #expect(!FaceSelection.all.needsIdentities)
        #expect(!FaceSelection.largest.needsIdentities)
        #expect(!FaceSelection.nearestTo(x: 0.5, y: 0.5).needsIdentities)
        #expect(FaceSelection.reference(generation: 1, maxDistance: 0.6).needsIdentities)
    }

    /// The selection crosses to the engine as JSON on every frame, so the
    /// generation and threshold have to survive the round trip intact — a
    /// dropped generation would be read as a stale set and fail the export.
    @Test func referenceSurvivesEncoding() throws {
        var options = SwapOptions()
        options.selection = .reference(generation: 42, maxDistance: 0.55)

        let decoded = try EngineJSON.decode(SwapOptions.self,
                                            from: try EngineJSON.encode(options))
        guard case .reference(let generation, let distance) = decoded.selection else {
            Issue.record("selection decoded as \(decoded.selection)")
            return
        }
        #expect(generation == 42)
        #expect(abs(distance - 0.55) < 1e-9)
    }

    @Test func referenceSetSurvivesEncoding() throws {
        let set = ReferenceFaceSet(generation: 7,
                                   identities: [identity(axis: 1), identity(axis: 2)])
        let decoded = try EngineJSON.decode(ReferenceFaceSet.self,
                                            from: try EngineJSON.encode(set))
        #expect(decoded.generation == 7)
        #expect(decoded.identities.count == 2)
        #expect(decoded.identities[0].vector.count == 512)
        #expect(decoded.identities[0].distance(to: set.identities[0]) < 1e-6)
    }
}

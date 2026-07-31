//
//  FaceScanner.swift
//  FaceFusionMac
//
//  Answering "who is in this video" so the user can tick the ones they want.
//
//  The engine can only see one frame at a time, and it has no access to the
//  file — the app owns decoding. So the scan lives here: sample frames across
//  the duration, ask the engine for the faces and identities in each, and
//  group those identities into people.
//
//  Grouping is what makes the picker mean anything for a video. A checkbox
//  bound to "the second face in this frame" starts swapping someone else the
//  moment two people cross; a checkbox bound to an identity does not.
//

import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics
import CoreMedia

/// Isolation sits on the two `scan` entry points rather than on the enum: they
/// drive `EngineClient`, which is main-actor bound, while the value types and
/// the cropping below are plain functions of their inputs and have no business
/// being tied to an actor.
enum FaceScanner {

    /// One person found in the target.
    struct Person: Identifiable {
        let id: Int
        /// What the engine matches against during the swap.
        var identity: FaceIdentity
        /// The clearest look at them found so far. Nil only if every crop
        /// failed, which would mean the frame itself could not be read.
        var thumbnail: CGImage?
        /// Sampled frames they appeared in — a proxy for screen time.
        var appearances: Int
        var firstSeen: Double
        var lastSeen: Double
        /// Largest share of the frame they have taken up.
        var coverage: Double
    }

    struct ScanProgress {
        var framesScanned: Int
        var totalFrames: Int
        var peopleFound: Int

        var fraction: Double {
            totalFrames > 0 ? min(1, Double(framesScanned) / Double(totalFrames)) : 0
        }
    }

    /// Roughly one sample a second, capped so a feature-length file costs no
    /// more than a short one.
    ///
    /// The cap is a real limit, not a formality: someone on screen for less
    /// than the gap between samples can be missed entirely. That is the price
    /// of a scan that finishes, and it is why the picker also offers whoever
    /// is in the frame on screen right now.
    private static let maximumSamples = 48
    private static let minimumInterval = 1.0
    /// Long edge the scan decodes to. The detector works from a 640px canvas
    /// and the recognizer from a 112px crop, so more than this buys nothing
    /// but a larger thumbnail.
    private static let scanDimension = 1280

    // MARK: - Photos

    /// A photo has one frame, so there is nothing to sample: everyone in it is
    /// visible at once.
    @MainActor
    static func scan(photo buffer: CVPixelBuffer,
                     engine: EngineClient,
                     options: AnalysisOptions) async throws -> [Person] {
        let analysis = try await engine.analyzeFaces(try PixelSurface.surface(of: buffer),
                                                     options: options)
        var collector = Collector()
        collector.absorb(analysis, from: buffer, at: 0)
        return collector.people
    }

    // MARK: - Videos

    @MainActor
    static func scan(video url: URL,
                     duration: Double,
                     engine: EngineClient,
                     options: AnalysisOptions,
                     onProgress: (ScanProgress) -> Void) async throws -> [Person] {

        let times = sampleTimes(duration: duration)
        let generator = VideoPipeline.makeScanGenerator(for: url, maximumDimension: scanDimension)

        var collector = Collector()
        var scanned = 0
        onProgress(ScanProgress(framesScanned: 0, totalFrames: times.count, peopleFound: 0))

        for time in times {
            try Task.checkCancellation()

            // A seek that fails is one sample lost, not a failed scan — a
            // truncated final GOP should not cost the user everything found
            // in the minutes before it.
            if let decoded = try? await generator.image(at: time) {
                let buffer = try PixelSurface.makeBuffer(from: decoded.image)
                let analysis = try await engine.analyzeFaces(try PixelSurface.surface(of: buffer),
                                                             options: options)
                collector.absorb(analysis, from: buffer, at: time.seconds)
            }

            scanned += 1
            onProgress(ScanProgress(framesScanned: scanned,
                                    totalFrames: times.count,
                                    peopleFound: collector.count))
        }

        return collector.people
    }

    /// Sample points, offset by half an interval so the scan does not open on
    /// a fade-in or a title card.
    private static func sampleTimes(duration: Double) -> [CMTime] {
        guard duration > 0 else { return [.zero] }
        let interval = max(duration / Double(maximumSamples), minimumInterval)
        var times: [CMTime] = []
        var seconds = min(interval / 2, duration / 2)
        while seconds < duration && times.count < maximumSamples {
            times.append(CMTime(seconds: seconds, preferredTimescale: 600))
            seconds += interval
        }
        return times.isEmpty ? [.zero] : times
    }

    // MARK: - Thumbnails

    /// A padded square around a face, for the picker grid.
    ///
    /// Square because a grid of detector boxes — taller than they are wide, by
    /// varying amounts — reads as a mess; padded because a face cropped at the
    /// jaw is hard to recognise.
    static func thumbnail(from buffer: CVPixelBuffer, box: FaceBox) -> CGImage? {
        guard let frame = PixelSurface.makeCGImage(from: buffer) else { return nil }
        return crop(frame, to: box)
    }

    static func crop(_ image: CGImage, to box: FaceBox, padding: Double = 0.3) -> CGImage? {
        let centerX = box.x + box.width / 2
        let centerY = box.y + box.height / 2
        let side = max(box.width, box.height) * (1 + padding * 2)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = CGRect(x: centerX - side / 2, y: centerY - side / 2,
                          width: side, height: side)
            .integral
            .intersection(bounds)
        guard rect.width >= 16, rect.height >= 16 else { return nil }
        return image.cropping(to: rect)
    }

    // MARK: - Accumulation

    /// Folds each frame's faces into the running set of people, and keeps the
    /// best crop of each.
    private struct Collector {
        private var clusterer = FaceClusterer()
        private var thumbnails: [Int: CGImage] = [:]

        var count: Int { clusterer.people.count }

        mutating func absorb(_ analysis: FrameAnalysis,
                             from buffer: CVPixelBuffer,
                             at time: Double) {
            // The engine drops any face it could not encode, so a length
            // mismatch means identities were not requested at all.
            guard analysis.identities.count == analysis.faces.count else { return }

            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let frameArea = Double(width * height)

            // Rendering the frame costs a full-size Core Image pass, so it
            // happens at most once per frame and only when a thumbnail is
            // actually going to be cut from it — which, after the first few
            // samples, is almost never.
            var frameImage: CGImage?
            var didRender = false

            for (face, identity) in zip(analysis.faces, analysis.identities) {
                let coverage = frameArea > 0
                    ? (face.box.width * face.box.height) / frameArea
                    : 0
                let placement = clusterer.add(identity, at: time,
                                              score: face.score, coverage: coverage)
                guard placement.isNew || placement.isBestSoFar else { continue }

                if !didRender {
                    didRender = true
                    frameImage = PixelSurface.makeCGImage(from: buffer)
                }
                if let frameImage, let crop = FaceScanner.crop(frameImage, to: face.box) {
                    thumbnails[placement.id] = crop
                }
            }
        }

        var people: [Person] {
            clusterer.byProminence.map { person in
                Person(id: person.id,
                       identity: person.identity,
                       thumbnail: thumbnails[person.id],
                       appearances: person.appearances,
                       firstSeen: person.firstSeen,
                       lastSeen: person.lastSeen,
                       coverage: person.largestCoverage)
            }
        }
    }
}

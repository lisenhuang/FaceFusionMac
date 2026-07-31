//
//  SwapPipeline.swift
//  FaceFusionEngine
//
//  Owns the loaded models and runs one frame end to end:
//
//      detect -> refine landmarks -> align -> swap -> feather -> paste
//                                                             -> restore
//

import Foundation
import CoreGraphics
import os

final class SwapPipeline {

    private var runtime: ORTRuntime?
    private var configuration: EngineConfiguration?

    private var detector: FaceDetector?
    private var landmarker: FaceLandmarker?
    private var recognizer: FaceRecognizer?
    private var swapper: FaceSwapper?
    private var enhancer: FaceEnhancer?

    /// Identity of the user's chosen source face, projected into the swapper's
    /// conditioning space once and reused for every frame.
    private var sourceEmbedding: FaceEmbedding?
    private var projectedSource: [Float]?

    // MARK: - Lifecycle

    func prepare(_ config: EngineConfiguration) throws -> EnginePreparation {
        let started = Date()

        let runtime = try self.runtime ?? ORTRuntime()
        self.runtime = runtime

        // A changed model set or compute policy invalidates every session.
        if let existing = configuration,
           existing.modelPaths != config.modelPaths
            || existing.compute != config.compute
            || existing.tuning != config.tuning {
            runtime.unloadAll()
            detector = nil; landmarker = nil; recognizer = nil
            swapper = nil; enhancer = nil
            sourceEmbedding = nil; projectedSource = nil
        }
        configuration = config

        try FileManager.default.createDirectory(atPath: config.modelCacheDirectory,
                                                withIntermediateDirectories: true)

        for id in ModelID.required {
            guard let path = config.modelPaths[id] else {
                throw makeEngineNSError(.modelMissing, underlying: "no path for \(id.rawValue)")
            }
            try runtime.load(id, path: path, compute: config.compute,
                             cacheDirectory: config.modelCacheDirectory,
                             tuning: config.tuning)
        }
        // Optional models: absence degrades quality, not correctness.
        for id in [ModelID.faceLandmarker, .faceEnhancer] {
            guard let path = config.modelPaths[id],
                  FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try runtime.load(id, path: path, compute: config.compute,
                                 cacheDirectory: config.modelCacheDirectory,
                                 tuning: config.tuning)
            } catch {
                EngineLog.engine.error(
                    "optional model \(id.rawValue, privacy: .public) failed to load: \(error.localizedDescription, privacy: .public)")
            }
        }

        guard let detectorModel = runtime.model(.faceDetector),
              let recognizerModel = runtime.model(.faceRecognizer),
              let swapperModel = runtime.model(.faceSwapper),
              let swapperPath = config.modelPaths[.faceSwapper] else {
            throw makeEngineNSError(.modelLoadFailed, underlying: "core models unavailable")
        }

        detector = FaceDetector(model: detectorModel)
        recognizer = FaceRecognizer(model: recognizerModel)
        swapper = try FaceSwapper(model: swapperModel, modelPath: swapperPath)
        landmarker = runtime.model(.faceLandmarker).map { FaceLandmarker(model: $0) }
        enhancer = runtime.model(.faceEnhancer).map { FaceEnhancer(model: $0) }

        return EnginePreparation(loadedModels: runtime.loadedModels,
                                 usingCoreML: runtime.coreMLActive,
                                 executionProvider: runtime.providerDescription,
                                 warmupSeconds: Date().timeIntervalSince(started))
    }

    func unloadAll() {
        runtime?.unloadAll()
        detector = nil; landmarker = nil; recognizer = nil
        swapper = nil; enhancer = nil
        sourceEmbedding = nil; projectedSource = nil
        configuration = nil
    }

    // MARK: - Source

    /// - Parameter refineLandmarks: must match the setting used for target
    ///   frames — aligning the source and target differently shifts the
    ///   identity vector away from what the swapper was trained on.
    func analyzeSource(_ image: BGRAImage, refineLandmarks: Bool = true) throws -> SourceAnalysis {
        guard let detector, let recognizer, let swapper else {
            throw makeEngineNSError(.notPrepared)
        }

        let faces = try detector.detect(in: image, scoreThreshold: 0.5)
        guard let best = faces.max(by: { $0.box.width * $0.box.height < $1.box.width * $1.box.height }) else {
            sourceEmbedding = nil
            projectedSource = nil
            throw makeEngineNSError(.noSourceFace)
        }

        let landmarks = refinedLandmarks(for: best, in: image, refine: refineLandmarks)
        let embedding = try recognizer.embedding(for: image, landmarks: landmarks)

        sourceEmbedding = embedding
        projectedSource = swapper.projectSource(embedding)

        return SourceAnalysis(face: Self.describe(best, index: 0, landmarks: landmarks),
                              faceCount: faces.count)
    }

    /// The projected source identity, exposed so tests can compare it against
    /// the reference implementation.
    func debugConditioningVector() -> [Float]? { projectedSource }

    // MARK: - Analysis

    func detectFaces(in image: BGRAImage, scoreThreshold: Double = 0.5) throws -> FrameAnalysis {
        guard let detector else { throw makeEngineNSError(.notPrepared) }
        let faces = try detector.detect(in: image, scoreThreshold: Float(scoreThreshold))
            .sorted { $0.box.minX < $1.box.minX }
        return FrameAnalysis(faces: faces.enumerated().map { index, face in
            Self.describe(face, index: index, landmarks: face.landmarks)
        })
    }

    // MARK: - Swapping

    func swap(input: BGRAImage, output: BGRAImage, options: SwapOptions) throws -> SwapResult {
        guard let detector, let recognizer, let swapper else {
            throw makeEngineNSError(.notPrepared)
        }
        guard let projectedSource else {
            throw makeEngineNSError(.noSourceFace)
        }

        let started = Date()
        input.copyContents(into: output)

        var timing = StageSeconds()
        let detectStarted = Date()
        let detected = try detector.detect(in: input, scoreThreshold: Float(options.detectorScore))
            .sorted { $0.box.minX < $1.box.minX }
        timing.detect = Date().timeIntervalSince(detectStarted)
        let chosen = Self.select(detected, using: options.selection,
                                 frameWidth: input.width, frameHeight: input.height)
        guard !chosen.isEmpty else {
            return SwapResult(facesFound: detected.count, facesSwapped: 0,
                              inferenceSeconds: Date().timeIntervalSince(started))
        }

        let needsTarget = FaceSwapper.needsTargetEmbedding(identityStrength: options.identityStrength)
        var swappedLandmarks: [[CGPoint]] = []

        for face in chosen {
            let landmarkStarted = Date()
            let landmarks = refinedLandmarks(for: face, in: input, refine: options.refineLandmarks)
            timing.landmarks += Date().timeIntervalSince(landmarkStarted)

            // Only pay for the target identity pass when it will actually be mixed in.
            let targetEmbedding = needsTarget
                ? try? recognizer.embedding(for: input, landmarks: landmarks)
                : nil

            let conditioning = swapper.blend(projected: projectedSource,
                                             target: targetEmbedding,
                                             identityStrength: options.identityStrength)

            let swapStarted = Date()
            let (crop, transform) = try swapper.swap(image: input,
                                                     landmarks: landmarks,
                                                     conditioning: conditioning)
            timing.swap += Date().timeIntervalSince(swapStarted)

            let pasteStarted = Date()
            let mask = FaceMasker.boxMask(size: FaceSwapper.inputSize, blur: options.maskBlur)
            output.pasteBack(patch: crop, mask: mask, transform: transform)
            timing.paste += Date().timeIntervalSince(pasteStarted)
            swappedLandmarks.append(landmarks)
        }

        // Restoration runs over the composited frame so it can smooth the seam
        // as well as sharpen the face.
        if options.enhanceFace, let enhancer {
            let enhanceStarted = Date()
            for landmarks in swappedLandmarks {
                do {
                    try enhancer.enhance(image: output,
                                         landmarks: landmarks,
                                         maskBlur: options.maskBlur,
                                         blend: options.enhancementBlend)
                } catch {
                    EngineLog.inference.error("enhancement skipped: \(error.localizedDescription, privacy: .public)")
                }
            }
            timing.enhance = Date().timeIntervalSince(enhanceStarted)
        }

        timing.total = Date().timeIntervalSince(started)
        record(timing)

        return SwapResult(facesFound: detected.count,
                          facesSwapped: chosen.count,
                          inferenceSeconds: timing.total,
                          stages: timing)
    }

    // MARK: - Timing

    /// Frames are processed concurrently, so this is shared mutable state.
    private struct TimingAccumulator {
        var totals = StageSeconds()
        var frames = 0
    }
    private let timings = OSAllocatedUnfairLock(initialState: TimingAccumulator())

    private func record(_ timing: StageSeconds) {
        let snapshot: (StageSeconds, Int)? = timings.withLock { state in
            state.totals = state.totals + timing
            state.frames += 1
            guard state.frames >= 50 else { return nil }
            let result = (state.totals, state.frames)
            state.totals = StageSeconds()
            state.frames = 0
            return result
        }
        guard let (accumulated, frames) = snapshot else { return }
        let n = Double(frames)
        EngineLog.inference.notice(
            """
            \(frames) frames, mean ms — \
            detect \(accumulated.detect / n * 1000, format: .fixed(precision: 1)) \
            landmarks \(accumulated.landmarks / n * 1000, format: .fixed(precision: 1)) \
            swap \(accumulated.swap / n * 1000, format: .fixed(precision: 1)) \
            paste \(accumulated.paste / n * 1000, format: .fixed(precision: 1)) \
            enhance \(accumulated.enhance / n * 1000, format: .fixed(precision: 1)) \
            total \(accumulated.total / n * 1000, format: .fixed(precision: 1))
            """)
    }

    // MARK: - Helpers

    /// Upgrades the detector's five coarse points to the five derived from 68
    /// landmarks, when the landmarker is loaded and confident.
    private func refinedLandmarks(for face: FaceObservation,
                                  in image: BGRAImage,
                                  refine: Bool) -> [CGPoint] {
        guard refine, let landmarker else { return face.landmarks }
        do {
            let result = try landmarker.landmarks(in: image, box: face.box)
            // Below this the 68-point fit is less trustworthy than the
            // detector's own key points.
            guard result.score >= 0.5, result.landmarks68.count >= 68 else {
                return face.landmarks
            }
            return Geometry.fivePoints(from: result.landmarks68)
        } catch {
            return face.landmarks
        }
    }

    private static func select(_ faces: [FaceObservation],
                               using selection: FaceSelection,
                               frameWidth: Int,
                               frameHeight: Int) -> [FaceObservation] {
        switch selection {
        case .all:
            return faces
        case .largest:
            guard let largest = faces.max(by: {
                $0.box.width * $0.box.height < $1.box.width * $1.box.height
            }) else { return [] }
            return [largest]
        case .nearestTo(let nx, let ny):
            let point = CGPoint(x: CGFloat(nx) * CGFloat(frameWidth),
                                y: CGFloat(ny) * CGFloat(frameHeight))
            guard let nearest = faces.min(by: {
                hypot($0.box.midX - point.x, $0.box.midY - point.y)
                    < hypot($1.box.midX - point.x, $1.box.midY - point.y)
            }) else { return [] }
            return [nearest]
        }
    }

    private static func describe(_ face: FaceObservation,
                                 index: Int,
                                 landmarks: [CGPoint]) -> DetectedFace {
        DetectedFace(index: index,
                     box: FaceBox(x: Double(face.box.minX), y: Double(face.box.minY),
                                  width: Double(face.box.width), height: Double(face.box.height)),
                     score: Double(face.score),
                     landmarks: landmarks.map { [Double($0.x), Double($0.y)] })
    }
}

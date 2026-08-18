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
    private var occluder: FaceOccluder?

    /// Identity of the user's chosen source face, projected into the swapper's
    /// conditioning space once and reused for every frame.
    private var sourceEmbedding: FaceEmbedding?
    private var projectedSource: [Float]?

    /// Identities of the faces the user checked in the picker. Set once per
    /// change, read by every frame — see `setReferenceFaces`.
    private var referenceFaces: ReferenceFaceSet?

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
            swapper = nil; enhancer = nil; occluder = nil
            sourceEmbedding = nil; projectedSource = nil
            // Reference identities came out of the old recognizer session.
            // Keeping them would compare vectors from two different graphs.
            referenceFaces = nil
        }
        configuration = config

        try FileManager.default.createDirectory(atPath: config.modelCacheDirectory,
                                                withIntermediateDirectories: true)

        for id in ModelID.required {
            guard let path = config.modelPaths[id] else {
                throw makeEngineNSError(.modelMissing, underlying: "no path for \(id.rawValue)")
            }
            do {
                try runtime.load(id, path: path, compute: config.compute(for: id),
                                 cacheDirectory: config.modelCacheDirectory,
                                 tuning: config.tuning)
            } catch {
                // Which model stopped the launch is the first thing anyone
                // diagnosing this wants and the one thing the old error did not
                // say — a required model and an optional one produced the same
                // sentence and the same log line. The id goes in the log and in
                // the debug description; the user still reads exactly the
                // sentence they read before.
                EngineLog.engine.error(
                    "required model \(id.rawValue, privacy: .public) failed to load: \(error.localizedDescription, privacy: .public)")
                throw Self.loadFailure(id, error)
            }
        }
        // Optional models: absence degrades quality, not correctness.
        for id in [ModelID.faceLandmarker, .faceEnhancer, .faceOccluder] {
            guard let path = config.modelPaths[id],
                  FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try runtime.load(id, path: path, compute: config.compute(for: id),
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
            // Reached only when `load` returned without throwing and without a
            // session, which should be impossible — so say which of the three
            // is absent rather than leaving the report as "core models
            // unavailable" for whoever has to work out how it happened.
            let absent = ModelID.required.filter { runtime.model($0) == nil }
                .map(\.rawValue).joined(separator: ",")
            EngineLog.engine.error(
                "required model(s) unavailable after loading: \(absent.isEmpty ? "none" : absent, privacy: .public)")
            throw makeEngineNSError(.modelLoadFailed,
                                    underlying: "unavailable after loading: \(absent.isEmpty ? "swapper path" : absent)")
        }

        detector = FaceDetector(model: detectorModel)
        recognizer = FaceRecognizer(model: recognizerModel)
        swapper = try FaceSwapper(model: swapperModel, modelPath: swapperPath)
        landmarker = runtime.model(.faceLandmarker).map { FaceLandmarker(model: $0) }
        // The enhancer takes every replica the runtime built and picks between
        // them per call, so two frames being restored at once do not queue
        // behind one session.
        let enhancerModels = runtime.models(.faceEnhancer)
        enhancer = enhancerModels.isEmpty ? nil : FaceEnhancer(models: enhancerModels)
        occluder = runtime.model(.faceOccluder).map { FaceOccluder(model: $0) }

        return EnginePreparation(loadedModels: runtime.loadedModels,
                                 usingCoreML: runtime.coreMLActive,
                                 executionProvider: runtime.providerDescription,
                                 warmupSeconds: Date().timeIntervalSince(started))
    }

    /// Names the model in an error a required load threw.
    ///
    /// The engine's own codes are preserved — a file that is not there is
    /// `.modelMissing`, and telling the user to reinstall is the right advice —
    /// while anything ONNX Runtime raised becomes `.modelLoadFailed`, whose
    /// sentence is the one this failure has always shown. Only the debug
    /// description grows: it gains the id, the domain and the code, which is
    /// what turns a support report into something that can be acted on.
    private static func loadFailure(_ id: ModelID, _ error: Error) -> NSError {
        let nsError = error as NSError
        let code = nsError.domain == engineErrorDomain
            ? (EngineError(rawValue: nsError.code) ?? .modelLoadFailed)
            : .modelLoadFailed
        var detail = "\(id.rawValue): \(nsError.domain)/\(nsError.code)"
        if let existing = nsError.userInfo[NSDebugDescriptionErrorKey] as? String {
            detail += " \(existing)"
        } else {
            detail += " \(nsError.localizedDescription)"
        }
        return makeEngineNSError(code, underlying: detail)
    }

    func unloadAll() {
        runtime?.unloadAll()
        detector = nil; landmarker = nil; recognizer = nil
        swapper = nil; enhancer = nil; occluder = nil
        sourceEmbedding = nil; projectedSource = nil
        referenceFaces = nil
        configuration = nil
    }

    // MARK: - Chosen faces

    /// Replaces the identities that `.reference` selection matches against.
    ///
    /// Called on the barrier queue, so no swap is part-way through comparing
    /// against the outgoing set.
    func setReferenceFaces(_ set: ReferenceFaceSet) {
        referenceFaces = set
    }

    // MARK: - Source

    /// - Parameter refineLandmarks: must match the setting used for target
    ///   frames — aligning the source and target differently shifts the
    ///   identity vector away from what the swapper was trained on.
    /// - Parameter index: which of the detected faces to encode, in the
    ///   left-to-right order this call returns, or `nil` for the largest —
    ///   the behaviour every caller had before a choice existed.
    func analyzeSource(_ image: BGRAImage,
                       refineLandmarks: Bool = true,
                       selecting index: Int? = nil) throws -> SourceAnalysis {
        guard let detector, let recognizer, let swapper else {
            throw makeEngineNSError(.notPrepared)
        }

        // Sorted left to right so the index a picker clicks names the same face
        // when the portrait is re-encoded later — detection order is whatever
        // the detector's grid happened to produce, and is not a contract.
        let faces = try detector.detect(in: image, scoreThreshold: 0.5)
            .sorted { $0.box.minX < $1.box.minX }

        let chosenIndex: Int
        if let index {
            // Refusing beats guessing: an index the detection no longer holds
            // means the caller and the engine disagree about what is in the
            // portrait, and quietly encoding someone else is worse than
            // failing the call.
            guard faces.indices.contains(index) else {
                sourceEmbedding = nil
                projectedSource = nil
                throw makeEngineNSError(.noSourceFace,
                                        underlying: "chosen face \(index) not among the \(faces.count) detected")
            }
            chosenIndex = index
        } else {
            guard let largest = faces.indices.max(by: {
                faces[$0].box.width * faces[$0].box.height < faces[$1].box.width * faces[$1].box.height
            }) else {
                sourceEmbedding = nil
                projectedSource = nil
                throw makeEngineNSError(.noSourceFace)
            }
            chosenIndex = largest
        }

        let best = faces[chosenIndex]
        let landmarks = refinedLandmarks(for: best, in: image, refine: refineLandmarks)
        let embedding = try recognizer.embedding(for: image, landmarks: landmarks)

        sourceEmbedding = embedding
        projectedSource = swapper.projectSource(embedding)

        // The chosen entry carries the refined landmarks that were actually
        // encoded; the rest keep the detector's five points — nobody aligned
        // them, and describing them as more than detections would be a lie.
        var described = faces.enumerated().map { position, face in
            Self.describe(face, index: position, landmarks: face.landmarks)
        }
        described[chosenIndex] = Self.describe(best, index: chosenIndex, landmarks: landmarks)

        return SourceAnalysis(face: described[chosenIndex],
                              faceCount: faces.count,
                              faces: described)
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

    /// Detection plus an identity per face, for the scan that populates the
    /// face picker.
    ///
    /// The alignment settings have to be the caller's swap settings: an
    /// identity encoded from the detector's raw key points and one encoded
    /// from refined landmarks are not the same vector, and comparing across
    /// the two would put a floor under every distance.
    func analyzeFaces(in image: BGRAImage, options: AnalysisOptions) throws -> FrameAnalysis {
        guard let detector else { throw makeEngineNSError(.notPrepared) }
        let faces = try detector.detect(in: image, scoreThreshold: Float(options.detectorScore))
            .sorted { $0.box.minX < $1.box.minX }

        var described: [DetectedFace] = []
        var identities: [FaceIdentity] = []
        described.reserveCapacity(faces.count)

        for face in faces {
            let landmarks = refinedLandmarks(for: face, in: image, refine: options.refineLandmarks)
            if options.includeIdentities {
                guard let recognizer,
                      let embedding = try? recognizer.embedding(for: image, landmarks: landmarks) else {
                    // A face the recognizer cannot encode is one the picker
                    // could never match again, so leave it out entirely rather
                    // than offer a checkbox that does nothing.
                    continue
                }
                identities.append(FaceIdentity(vector: embedding.normalized))
            }
            // Numbered over what survives, so `faces` and `identities` stay
            // index-for-index parallel for the caller.
            described.append(Self.describe(face, index: described.count, landmarks: landmarks))
        }

        return FrameAnalysis(faces: described, identities: identities)
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

        let chosen = try resolve(detected, in: input, options: options, timing: &timing)
        guard !chosen.isEmpty else {
            timing.total = Date().timeIntervalSince(started)
            return SwapResult(facesFound: detected.count, facesSwapped: 0,
                              inferenceSeconds: timing.total, stages: timing)
        }

        let needsTarget = FaceSwapper.needsTargetEmbedding(identityStrength: options.identityStrength)
        var swappedLandmarks: [[CGPoint]] = []

        for candidate in chosen {
            let landmarks = candidate.landmarks

            // Only pay for the target identity pass when it will actually be
            // mixed in — and never twice, since matching by identity has
            // already encoded this face.
            let targetEmbedding = needsTarget
                ? (candidate.identity ?? (try? recognizer.embedding(for: input, landmarks: landmarks)))
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
            var mask = FaceMasker.boxMask(size: FaceSwapper.inputSize, blur: options.maskBlur)
            if options.maskOcclusion, let occluder {
                do {
                    // Computed on the *input* frame with the swap's own
                    // transform, so the mask sees the hand exactly where the
                    // patch is about to land. The combine is an element-wise
                    // minimum, the reference's `numpy.minimum.reduce`, and the
                    // mutation copies the cached box mask rather than editing
                    // it in place.
                    let occlusion = try occluder.occlusionMask(image: input,
                                                               transform: transform,
                                                               cropSize: FaceSwapper.inputSize)
                    mask.intersect(with: occlusion)
                    mask.clamp01()
                } catch {
                    // A face still gets swapped without its occlusion mask —
                    // quality degrades to the box mask rather than the frame
                    // failing.
                    EngineLog.inference.error("occlusion mask skipped: \(error.localizedDescription, privacy: .public)")
                }
            }
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
                                         blend: options.enhancementBlend,
                                         occluder: options.maskOcclusion ? occluder : nil)
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
            match \(accumulated.match / n * 1000, format: .fixed(precision: 1)) \
            swap \(accumulated.swap / n * 1000, format: .fixed(precision: 1)) \
            paste \(accumulated.paste / n * 1000, format: .fixed(precision: 1)) \
            enhance \(accumulated.enhance / n * 1000, format: .fixed(precision: 1)) \
            total \(accumulated.total / n * 1000, format: .fixed(precision: 1))
            """)
    }

    // MARK: - Helpers

    /// A face that is going to be swapped, with the work done to choose it
    /// carried along so none of it is repeated.
    private struct Candidate {
        var face: FaceObservation
        var landmarks: [CGPoint]
        /// Present only when this face was chosen by identity, in which case
        /// the recognizer has already run over it.
        var identity: FaceEmbedding?
    }

    /// Narrows the frame's detections to the faces that should be replaced.
    ///
    /// Split out from `swap` because `.reference` is a different shape of
    /// decision from the others: the geometric selections read boxes and are
    /// free, while matching by identity has to align and encode every
    /// detection before it knows which ones the user meant.
    private func resolve(_ detected: [FaceObservation],
                         in image: BGRAImage,
                         options: SwapOptions,
                         timing: inout StageSeconds) throws -> [Candidate] {

        guard case .reference(let generation, let maxDistance) = options.selection else {
            let landmarkStarted = Date()
            let chosen = Self.select(detected, using: options.selection,
                                     frameWidth: image.width, frameHeight: image.height)
                .map { face in
                    Candidate(face: face,
                              landmarks: refinedLandmarks(for: face, in: image,
                                                          refine: options.refineLandmarks),
                              identity: nil)
                }
            timing.landmarks = Date().timeIntervalSince(landmarkStarted)
            return chosen
        }

        guard let recognizer else { throw makeEngineNSError(.notPrepared) }
        // Refusing beats guessing. A generation the engine does not hold means
        // the app and the engine disagree about which faces were checked, and
        // swapping the wrong person is worse than failing the frame.
        guard let references = referenceFaces, references.generation == generation else {
            let held = referenceFaces.map { String($0.generation) } ?? "none"
            throw makeEngineNSError(.referenceFacesStale,
                                    underlying: "asked for generation \(generation), holding \(held)")
        }
        guard !references.identities.isEmpty else { return [] }

        var chosen: [Candidate] = []
        for face in detected {
            let landmarkStarted = Date()
            let landmarks = refinedLandmarks(for: face, in: image, refine: options.refineLandmarks)
            timing.landmarks += Date().timeIntervalSince(landmarkStarted)

            let matchStarted = Date()
            let embedding = try? recognizer.embedding(for: image, landmarks: landmarks)
            let distance = embedding.map {
                FaceIdentity(vector: $0.normalized).nearestDistance(among: references.identities)
            } ?? Double.greatestFiniteMagnitude
            timing.match += Date().timeIntervalSince(matchStarted)

            guard distance <= maxDistance else { continue }
            chosen.append(Candidate(face: face, landmarks: landmarks, identity: embedding))
        }
        return chosen
    }

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

        case .reference:
            // Answered by `resolve`, which has the recognizer and the pixels.
            // Boxes alone cannot say who anyone is, and quietly returning
            // every face here would replace the whole frame.
            return []
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

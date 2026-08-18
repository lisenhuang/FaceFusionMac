//
//  FaceEnhancer.swift
//  FaceFusionEngine
//
//  GFPGAN restoration. The swapper works at 128x128, so its output is soft on
//  anything but a small face. Running a restorer over the swapped region at
//  512x512 recovers skin texture and eye detail.
//
//  This runs on the already-swapped frame, exactly as the reference does, so
//  the restorer sees the composited face rather than the raw crop.
//
//  Unlike the Mac engine this holds a *list* of sessions rather than one. The
//  restorer is the most expensive stage by a wide margin, and an ORTSession
//  serialises its own `run`: with several frames inside the engine at once —
//  which is the whole point of the export loop's concurrency — every one of
//  them ends up queued behind the same session while the rest of the pipeline
//  sits idle. Handing each caller a different replica lets two restorations
//  overlap. Replicas are not free: each one is roughly 340 MB of resident
//  weights, so the count comes from `EngineTuning.enhancerReplicas` and is 1 on
//  a memory-constrained device.
//

import Foundation
import CoreGraphics
import os

struct FaceEnhancer {
    static let inputSize = 512

    /// One loaded session per replica; all of them are the same graph.
    let models: [ORTModel]

    /// Which replica the next call takes. A lock rather than an atomic because
    /// the contention here is nil — one increment per 300 ms of inference — and
    /// this is the same primitive the mask cache already uses.
    private let cursor = OSAllocatedUnfairLock(initialState: 0)

    /// - Returns: `nil` when the restorer is not loaded, which is a supported
    ///   state: the enhancer is optional and its absence costs quality only.
    init?(models: [ORTModel]) {
        guard !models.isEmpty else { return nil }
        self.models = models
    }

    /// Enhances one face in place.
    /// - Parameter blend: 0...1 opacity of the restored face over the original.
    /// - Parameter occluder: when present, carves hands and hair out of the
    ///   paste mask, exactly as the swap's own paste does. The reference
    ///   applies the occlusion mask in `face_enhancer.py` too — the restorer is
    ///   a face-prior GAN, and left unmasked it will happily repaint the hand
    ///   the swap just preserved.
    func enhance(image: BGRAImage,
                 landmarks: [CGPoint],
                 maskBlur: Double,
                 blend: Double,
                 occluder: FaceOccluder? = nil) throws {
        let model = nextModel()

        let transform = Geometry.alignmentTransform(landmarks: landmarks,
                                                    template: WarpTemplate.ffhq512,
                                                    cropSize: Self.inputSize)
        let input = image.warpedTensor(by: transform,
                                       width: Self.inputSize, height: Self.inputSize,
                                       order: .rgb, mean: 0.5, standardDeviation: 0.5)

        var inputs: [String: FloatTensor] = [model.inputNames[0]: input]
        // Some restorer graphs take a fidelity weight alongside the image;
        // gfpgan_1.4 does not, so only feed it when the graph asks for it.
        if model.inputNames.count > 1 {
            inputs[model.inputNames[1]] = FloatTensor(shape: [1], values: [0.5])
        }

        let outputs = try model.run(inputs)
        guard let result = outputs[model.outputNames[0]] else {
            throw makeEngineNSError(.inferenceFailed, underlying: "enhancer produced no output")
        }

        let restored = BGRAImage.fromTensorCHW(result, order: .rgb,
                                               mean: 0.5, standardDeviation: 0.5)
        var mask = FaceMasker.boxMask(size: Self.inputSize, blur: maskBlur)
        if let occluder {
            do {
                // The occluder reads the composited frame through the
                // *enhancer's* transform — its own 512px crop, not the swap's —
                // matching the reference, which computes a fresh occlusion mask
                // per stage.
                let occlusion = try occluder.occlusionMask(image: image,
                                                           transform: transform,
                                                           cropSize: Self.inputSize)
                mask.intersect(with: occlusion)
                mask.clamp01()
            } catch {
                EngineLog.inference.error("enhancer occlusion mask skipped: \(error.localizedDescription, privacy: .public)")
            }
        }

        image.pasteBack(patch: restored,
                        mask: mask,
                        transform: transform,
                        opacity: Float(min(max(blend, 0), 1)))
    }

    /// Round-robin rather than "first idle session", because the engine has no
    /// way to ask ORT whether a session is busy. Over a video the two are the
    /// same thing: frames arrive at a steady rate and alternate cleanly.
    private func nextModel() -> ORTModel {
        // The replica count is read outside the lock body so nothing but plain
        // integers crosses into it — an ORTSession is not `Sendable` and has no
        // business being captured by a lock closure.
        let count = models.count
        let index = cursor.withLock { next -> Int in
            let chosen = next
            next = (next + 1) % count
            return chosen
        }
        return models[index]
    }
}

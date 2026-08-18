//
//  FaceRecognizer.swift
//  FaceFusionEngine
//
//  ArcFace turns an aligned face into a 512-dimensional identity vector.
//  That vector — not the source pixels — is what the swapper is conditioned on.
//
//  The 112px crop is the pipeline's steepest reduction — a portrait at the
//  2048px import cap shrinks by roughly 18x — so it is also where the
//  box-prefilter inside the warp earns its keep. Fusing the warp into the
//  tensor changes none of that; the prefilter rule lives in the warp itself.
//

import Foundation
import CoreGraphics

struct FaceEmbedding {
    /// Raw network output. The swapper's projection needs this unnormalised.
    var raw: [Float]
    /// L2-normalised, for identity comparison and blending.
    var normalized: [Float]
}

struct FaceRecognizer {
    static let inputSize = 112

    let model: ORTModel

    func embedding(for image: BGRAImage, landmarks: [CGPoint]) throws -> FaceEmbedding {
        let transform = Geometry.alignmentTransform(landmarks: landmarks,
                                                    template: WarpTemplate.arcface112v2,
                                                    cropSize: Self.inputSize)

        // The reference computes `crop / 127.5 - 1`, i.e. normalise to 0...1
        // then centre on 0.5 with a 0.5 spread.
        let input = image.warpedTensor(by: transform,
                                       width: Self.inputSize, height: Self.inputSize,
                                       order: .rgb, mean: 0.5, standardDeviation: 0.5)

        let outputs = try model.run([model.inputNames[0]: input])
        guard let tensor = outputs[model.outputNames[0]] else {
            throw makeEngineNSError(.inferenceFailed, underlying: "recognizer produced no output")
        }

        // One of the few genuine copies out of a tensor: an embedding outlives
        // the inference that produced it by minutes — the source identity is
        // projected once and reused for every frame — so it cannot be a view
        // onto storage the next `run` is free to reclaim.
        let raw = Array(tensor.values)
        var magnitude: Float = 0
        for v in raw { magnitude += v * v }
        magnitude = sqrtf(magnitude)
        guard magnitude > .ulpOfOne else {
            throw makeEngineNSError(.inferenceFailed, underlying: "degenerate identity embedding")
        }
        return FaceEmbedding(raw: raw, normalized: raw.map { $0 / magnitude })
    }
}

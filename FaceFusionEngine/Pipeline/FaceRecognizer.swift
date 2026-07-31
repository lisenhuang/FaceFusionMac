//
//  FaceRecognizer.swift
//  FaceFusionEngine
//
//  ArcFace turns an aligned face into a 512-dimensional identity vector.
//  That vector — not the source pixels — is what the swapper is conditioned on.
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
        let crop = image.warped(by: transform, width: Self.inputSize, height: Self.inputSize)

        // The reference computes `crop / 127.5 - 1`, i.e. normalise to 0...1
        // then centre on 0.5 with a 0.5 spread.
        let input = crop.tensorCHW(order: .rgb, mean: 0.5, standardDeviation: 0.5)

        let outputs = try model.run([model.inputNames[0]: input])
        guard let tensor = outputs[model.outputNames[0]] else {
            throw makeEngineNSError(.inferenceFailed, underlying: "recognizer produced no output")
        }

        let raw = tensor.values
        var magnitude: Float = 0
        for v in raw { magnitude += v * v }
        magnitude = sqrtf(magnitude)
        guard magnitude > .ulpOfOne else {
            throw makeEngineNSError(.inferenceFailed, underlying: "degenerate identity embedding")
        }
        return FaceEmbedding(raw: raw, normalized: raw.map { $0 / magnitude })
    }
}

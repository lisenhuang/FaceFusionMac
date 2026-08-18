//
//  FaceSwapper.swift
//  FaceFusionEngine
//
//  inswapper-128. Two inputs: a 128x128 aligned crop of the *target* face, and
//  a 512-vector describing the *source* identity.
//
//  The identity vector is not the ArcFace embedding directly. The graph carries
//  a 512x512 projection matrix as its final initializer, and the source vector
//  must be pushed through it first:
//
//      source = (embedding · emap) / ‖embedding‖
//
//  Note the divisor is the magnitude of the *original* embedding, not of the
//  projected result — getting that wrong yields a washed-out, low-identity swap.
//

import Foundation
import CoreGraphics
import Accelerate

struct FaceSwapper {
    static let inputSize = 128

    let model: ORTModel
    /// Row-major 512x512 projection pulled out of the ONNX graph.
    let projection: [Float]
    static let embeddingDimension = 512

    init(model: ORTModel, modelPath: String) throws {
        self.model = model
        let tensor = try OnnxInitializerReader.lastInitializer(ofModelAt: URL(fileURLWithPath: modelPath))
        let expected = Self.embeddingDimension * Self.embeddingDimension
        guard tensor.floats.count == expected else {
            throw makeEngineNSError(.modelLoadFailed,
                                    underlying: "expected a \(Self.embeddingDimension)² projection, found \(tensor.floats.count) values in '\(tensor.name)'")
        }
        self.projection = tensor.floats
    }

    /// Projects an ArcFace embedding into the swapper's conditioning space.
    ///
    /// Depends only on the source face, so this runs once when the user picks a
    /// portrait rather than once per frame.
    func projectSource(_ source: FaceEmbedding) -> [Float] {
        let dimension = Self.embeddingDimension

        var magnitude: Float = 0
        for v in source.raw { magnitude += v * v }
        magnitude = max(sqrtf(magnitude), .ulpOfOne)

        // vector = (embedding · emap) / ‖embedding‖
        //
        // `source.raw` is a real array, not a tensor view, which is what
        // vDSP wants here — it reads the whole 512-element row.
        var vector = [Float](repeating: 0, count: dimension)
        vDSP_mmul(source.raw, 1, projection, 1, &vector, 1,
                  1, vDSP_Length(dimension), vDSP_Length(dimension))
        var inverseMagnitude = 1 / magnitude
        vDSP_vsmul(vector, 1, &inverseMagnitude, &vector, 1, vDSP_Length(dimension))
        return vector
    }

    /// How far the conditioning vector is pulled back toward the target's own
    /// identity. Mirrors the reference's `face_swapper_weight`, which maps
    /// 0...1 onto +0.35...-0.35; 0.5 is the neutral midpoint.
    static func blendWeight(identityStrength: Double) -> Float {
        Float(0.35 - identityStrength * 0.7)
    }

    /// True when the target face's own embedding is needed. Skipping this
    /// avoids a per-face ArcFace pass on every frame at the neutral setting.
    static func needsTargetEmbedding(identityStrength: Double) -> Bool {
        abs(blendWeight(identityStrength: identityStrength)) > 1e-4
    }

    /// Mixes a projected source vector toward a target identity.
    func blend(projected: [Float],
               target: FaceEmbedding?,
               identityStrength: Double) -> [Float] {
        guard let target else { return projected }
        let weight = Self.blendWeight(identityStrength: identityStrength)
        guard abs(weight) > 1e-4 else { return projected }

        var vector = projected
        for i in 0 ..< vector.count {
            vector[i] = vector[i] * (1 - weight) + target.normalized[i] * weight
        }
        return vector
    }

    /// Runs the swap on one face and returns the 128x128 result in BGRA.
    func swap(image: BGRAImage,
              landmarks: [CGPoint],
              conditioning: [Float]) throws -> (crop: BGRAImage, transform: CGAffineTransform) {
        let transform = Geometry.alignmentTransform(landmarks: landmarks,
                                                    template: WarpTemplate.arcface128,
                                                    cropSize: Self.inputSize)

        // inswapper wants plain 0...1 RGB: no mean subtraction, unit spread.
        // The aligned crop is never looked at as pixels, only as this tensor,
        // so it is warped straight into one.
        let target = image.warpedTensor(by: transform,
                                        width: Self.inputSize, height: Self.inputSize,
                                        order: .rgb, mean: 0, standardDeviation: 1)
        let source = FloatTensor(shape: [1, Self.embeddingDimension], values: conditioning)

        let outputs = try model.run(["target": target, "source": source])
        guard let result = outputs[model.outputNames[0]] else {
            throw makeEngineNSError(.inferenceFailed, underlying: "swapper produced no output")
        }

        let swapped = BGRAImage.fromTensorCHW(result, order: .rgb, mean: 0, standardDeviation: 1)
        return (swapped, transform)
    }
}

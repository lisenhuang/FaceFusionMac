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

    /// The largest boost factor the pipeline will use, whatever the setting
    /// asks for. 4 generates 512px of face for 16 passes, which is a 1:1 match
    /// for an ordinary close-up in a 1080p frame; beyond it the phases start to
    /// disagree faster than the extra samples are worth.
    static let maximumBoost = 4

    /// How far past a boost level a face may reach before paying for the next
    /// one. See `boost(landmarks:ceiling:)` — the levels cost B² and sit 2×
    /// apart, so where the step falls matters more than the step itself.
    static let boostTolerance: CGFloat = 0.15

    /// The boost factor that would match a face of this footprint, capped by
    /// the user's ceiling and by `maximumBoost`.
    ///
    /// The footprint comes out of the alignment transform rather than the
    /// landmark spread, so it is the same number the warp itself will use: a
    /// similarity transform's uniform scale is `sqrt(|ad − bc|)`, and the crop
    /// is `cropSize / scale` frame pixels across.
    static func boost(landmarks: [CGPoint], ceiling: Int) -> Int {
        let limit = min(ceiling, maximumBoost)
        guard limit > 1 else { return 1 }

        let probe = Geometry.alignmentTransform(landmarks: landmarks,
                                                template: WarpTemplate.arcface128,
                                                cropSize: inputSize)
        let scale = sqrt(abs(probe.a * probe.d - probe.b * probe.c))
        guard scale.isFinite, scale > 0 else { return 1 }

        // `1 / scale` is the footprint in units of the 128 crop. Rounding it
        // straight up would be the literal rule — never generate fewer pixels
        // than the face occupies — but the cost is the *square* of this, and a
        // face 129px across would then pay four passes to avoid an enlargement
        // of 1.008. The tolerance below moves each step to where it is worth
        // paying for: a face up to `1 + tolerance` times a level stays on it,
        // so the worst enlargement anyone sees is 15%, well under the ~50%
        // where an enlarged patch starts reading as soft against its frame.
        // Compared before converting, never after: landmarks that are nearly
        // coincident — a detection collapsing on a blurred or tiny face — give a
        // scale small enough that `1 / scale` overflows `Int`, and `Int(_:)`
        // traps on that rather than saturating.
        let wanted = (1 / scale - Self.boostTolerance).rounded(.up)
        guard wanted.isFinite else { return 1 }
        if wanted <= 1 { return 1 }
        if wanted >= CGFloat(limit) { return limit }
        return Int(wanted)
    }

    /// Runs the swap at `boost` × the graph's native resolution.
    ///
    /// The graph is fixed at 128, so the extra resolution cannot come from it
    /// directly. It comes from *phase*: a `128·boost` crop decomposes exactly
    /// into `boost²` 128px images, sub-frame `(bx, by)` taking every `boost`-th
    /// pixel starting at `(bx, by)`. Each is a complete view of the face, each
    /// carries samples the others do not, and interleaving the swapped results
    /// back together reconstructs the larger crop with real detail rather than
    /// an enlargement of one. This is FaceFusion 3.x's `pixel_boost` and the
    /// decomposition is the same one, `space-to-depth`.
    ///
    /// Every pass shares one conditioning vector — identity does not vary with
    /// phase — so the cost over the plain path is `boost²` swapper runs and
    /// nothing else. `boost == 1` delegates, so the default path keeps its
    /// fused warp-into-tensor and its GPU packing untouched.
    func swap(image: BGRAImage,
              landmarks: [CGPoint],
              conditioning: [Float],
              boost: Int) throws -> (crop: BGRAImage, transform: CGAffineTransform) {
        let factor = max(1, min(boost, Self.maximumBoost))
        guard factor > 1 else {
            return try swap(image: image, landmarks: landmarks, conditioning: conditioning)
        }

        let size = Self.inputSize * factor
        let transform = Geometry.alignmentTransform(landmarks: landmarks,
                                                    template: WarpTemplate.arcface128,
                                                    cropSize: size)

        // Warped as pixels rather than straight into a tensor, because the
        // sub-frames are strided views of one crop and there is only one warp
        // between them. Sampling each sub-frame from the frame separately would
        // be the same geometry, but at this scale `warped` is entitled to run
        // its box prefilter — which averages precisely the neighbouring pixels
        // the phases exist to keep apart.
        let crop = image.warped(by: transform, width: size, height: size)
        let output = BGRAImage(width: size, height: size)
        let source = FloatTensor(shape: [1, Self.embeddingDimension], values: conditioning)

        for by in 0 ..< factor {
            for bx in 0 ..< factor {
                // One frame is up to sixteen inference passes now, so a
                // cancelled export or a backgrounded app would otherwise keep a
                // frame running long after everything above it stopped caring.
                // The unboosted path is a single pass and never needed this.
                try Task.checkCancellation()

                let target = Self.subFrame(of: crop, boost: factor, x: bx, y: by)
                let outputs = try model.run(["target": target, "source": source])
                guard let result = outputs[model.outputNames[0]] else {
                    throw makeEngineNSError(.inferenceFailed,
                                            underlying: "swapper produced no output")
                }
                Self.write(result, into: output, boost: factor, x: bx, y: by)
            }
        }
        return (output, transform)
    }

    /// One phase of `crop`, packed into the swapper's `1 x 3 x 128 x 128` input.
    ///
    /// Same normalisation as the plain path — RGB, values 1/255, no mean — just
    /// read with a stride. Sub-frame pixel `(x, y)` is crop pixel
    /// `(x·boost + bx, y·boost + by)`.
    static func subFrame(of crop: BGRAImage, boost: Int, x bx: Int, y by: Int) -> FloatTensor {
        let size = inputSize
        let plane = size * size
        let tensor = FloatTensor(shape: [1, 3, size, size])
        let values = tensor.values
        let invScale: Float = 1.0 / 255.0
        // RGB out of BGRA, matching `tensorCHW(order: .rgb)`.
        let offsets = [2, 1, 0]

        for y in 0 ..< size {
            let src = crop.row(y * boost + by)
            for x in 0 ..< size {
                let pixel = (x * boost + bx) * 4
                let index = y * size + x
                for c in 0 ..< 3 {
                    values[c * plane + index] = Float(src[pixel + offsets[c]]) * invScale
                }
            }
        }
        return tensor
    }

    /// Writes a swapped sub-frame back into its phase of `crop`, denormalising
    /// exactly as `BGRAImage.fromTensorCHW` does at mean 0, deviation 1.
    static func write(_ tensor: FloatTensor, into crop: BGRAImage,
                      boost: Int, x bx: Int, y by: Int) {
        let size = inputSize
        let plane = size * size
        let values = tensor.values
        let offsets = [2, 1, 0]

        for y in 0 ..< size {
            let dst = crop.row(y * boost + by)
            for x in 0 ..< size {
                let pixel = (x * boost + bx) * 4
                let index = y * size + x
                for c in 0 ..< 3 {
                    let v = values[c * plane + index]
                    dst[pixel + offsets[c]] = UInt8(min(max(v, 0), 1) * 255 + 0.5)
                }
                dst[pixel + 3] = 255
            }
        }
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

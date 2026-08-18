//
//  FaceLandmarker.swift
//  FaceFusionEngine
//
//  2DFAN-4 refines the detector's five coarse key points into 68 landmarks.
//  Re-deriving the five points from those 68 gives a noticeably steadier
//  alignment across a video than the detector's own output, which jitters.
//
//  The crop is a pure scale-and-translate that puts the face box into a
//  256x256 frame at a fixed 195px working size. It exists only to be packed
//  into a tensor, so it is warped straight into one — a saving of one 256x256
//  BGRA buffer per face per frame, and nothing else changes: the fused path
//  runs the same warp with the same prefilter rule.
//

import Foundation
import CoreGraphics

struct LandmarkResult {
    var landmarks68: [CGPoint]
    /// 0...1 confidence, derived from peak heatmap response.
    var score: Float
}

struct FaceLandmarker {
    static let inputSize = 256
    /// The face box is normalised to this many pixels inside the crop.
    static let workingSize: CGFloat = 195

    let model: ORTModel

    func landmarks(in image: BGRAImage, box: CGRect) throws -> LandmarkResult {
        let extent = max(box.width, box.height)
        let scale = Self.workingSize / max(extent, 1)

        // Centre the box in the crop: the reference computes the translation
        // from the summed box edges, which is the midpoint doubled.
        let translation = CGPoint(
            x: (CGFloat(Self.inputSize) - (box.minX + box.maxX) * scale) * 0.5,
            y: (CGFloat(Self.inputSize) - (box.minY + box.maxY) * scale) * 0.5
        )
        let transform = Geometry.translationTransform(scale: scale, translation: translation)

        let input = image.warpedTensor(by: transform,
                                       width: Self.inputSize, height: Self.inputSize,
                                       order: .bgr)

        let outputs = try model.run([model.inputNames[0]: input])

        // Two outputs: the landmark grid and the heatmaps behind it.
        guard let landmarkTensor = outputs["landmarks"] ?? outputs[model.outputNames[0]] else {
            throw makeEngineNSError(.inferenceFailed, underlying: "landmarker produced no output")
        }

        // [1, 68, 3] where x and y live on a 64-unit grid.
        let stride = landmarkTensor.shape.last ?? 3
        let pointCount = min(68, landmarkTensor.values.count / stride)
        let gridToCrop = CGFloat(Self.inputSize) / 64.0

        let inverse = transform.inverted()
        // A tensor's `values` is a pointer into its storage, not an array, so
        // the tensor is pinned for the whole read rather than trusted to
        // survive to the end of the loop.
        let points = withExtendedLifetime(landmarkTensor) { () -> [CGPoint] in
            let values = landmarkTensor.values
            var collected: [CGPoint] = []
            collected.reserveCapacity(pointCount)
            for i in 0 ..< pointCount {
                let cropPoint = CGPoint(x: CGFloat(values[i * stride]) * gridToCrop,
                                        y: CGFloat(values[i * stride + 1]) * gridToCrop)
                collected.append(Geometry.apply(inverse, to: cropPoint))
            }
            return collected
        }

        var score: Float = 1
        if let heatmaps = outputs["heatmaps"], heatmaps.shape.count == 4 {
            let count = heatmaps.shape[1]
            let cells = heatmaps.shape[2] * heatmaps.shape[3]
            let total = withExtendedLifetime(heatmaps) { () -> Float in
                let values = heatmaps.values
                var sum: Float = 0
                for k in 0 ..< count {
                    var peak: Float = -.greatestFiniteMagnitude
                    for c in 0 ..< cells {
                        peak = max(peak, values[k * cells + c])
                    }
                    sum += peak
                }
                return sum
            }
            // The reference maps a mean peak of 0.9 to full confidence.
            score = min(max((total / Float(count)) / 0.9, 0), 1)
        }

        return LandmarkResult(landmarks68: points, score: score)
    }
}

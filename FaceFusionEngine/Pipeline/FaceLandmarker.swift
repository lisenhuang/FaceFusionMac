//
//  FaceLandmarker.swift
//  FaceFusionEngine
//
//  2DFAN-4 refines the detector's five coarse key points into 68 landmarks.
//  Re-deriving the five points from those 68 gives a noticeably steadier
//  alignment across a video than the detector's own output, which jitters.
//
//  The crop is a pure scale-and-translate that puts the face box into a
//  256x256 frame at a fixed 195px working size.
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

        let crop = image.warped(by: transform,
                                width: Self.inputSize, height: Self.inputSize)
        let input = crop.tensorCHW(order: .bgr)

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
        var points: [CGPoint] = []
        points.reserveCapacity(pointCount)
        for i in 0 ..< pointCount {
            let cropPoint = CGPoint(x: CGFloat(landmarkTensor.values[i * stride]) * gridToCrop,
                                    y: CGFloat(landmarkTensor.values[i * stride + 1]) * gridToCrop)
            points.append(Geometry.apply(inverse, to: cropPoint))
        }

        var score: Float = 1
        if let heatmaps = outputs["heatmaps"], heatmaps.shape.count == 4 {
            let count = heatmaps.shape[1]
            let cells = heatmaps.shape[2] * heatmaps.shape[3]
            var total: Float = 0
            for k in 0 ..< count {
                var peak: Float = -.greatestFiniteMagnitude
                for c in 0 ..< cells {
                    peak = max(peak, heatmaps.values[k * cells + c])
                }
                total += peak
            }
            // The reference maps a mean peak of 0.9 to full confidence.
            score = min(max((total / Float(count)) / 0.9, 0), 1)
        }

        return LandmarkResult(landmarks68: points, score: score)
    }
}

//
//  FaceDetector.swift
//  FaceFusionEngine
//
//  YOLO-face detection. The graph takes a 640x640 canvas and emits, for each
//  of 8400 anchors, a box, a confidence and five key points:
//
//      output[1, 20, 8400] -> transposed to 8400 rows of
//      [cx, cy, w, h, score, (x, y, conf) x 5]
//
//  The frame is downscaled to fit 640x640 and pasted at the canvas origin
//  rather than letterboxed, so undoing it is a single uniform scale.
//

import Foundation
import CoreGraphics

struct FaceObservation {
    var box: CGRect
    var score: Float
    /// Five points in original-frame pixels.
    var landmarks: [CGPoint]
}

struct FaceDetector {
    static let inputSize = 640

    let model: ORTModel

    func detect(in image: BGRAImage, scoreThreshold: Float) throws -> [FaceObservation] {
        let (restricted, _) = image.restricted(to: Self.inputSize)

        // `restricted` never upscales, so recover the exact ratio from the
        // dimensions rather than trusting a float scale factor.
        let ratioX = CGFloat(image.width) / CGFloat(restricted.width)
        let ratioY = CGFloat(image.height) / CGFloat(restricted.height)

        // The reference pipeline feeds this model BGR, not RGB.
        let input = restricted.tensorCHW(order: .bgr,
                                         padTo: (Self.inputSize, Self.inputSize))

        let outputs = try model.run([model.inputNames[0]: input])
        guard let detection = outputs[model.outputNames[0]] else {
            throw makeEngineNSError(.inferenceFailed, underlying: "detector produced no output")
        }

        // Shape is [1, 20, 8400]: attribute-major, so stride between rows is
        // the anchor count.
        let dims = detection.shape
        guard dims.count == 3, dims[1] >= 15 else {
            throw makeEngineNSError(.inferenceFailed,
                                    underlying: "unexpected detector shape \(dims)")
        }
        let attributes = dims[1]
        let anchors = dims[2]
        let values = detection.values

        var observations: [FaceObservation] = []
        observations.reserveCapacity(16)

        @inline(__always) func at(_ attribute: Int, _ anchor: Int) -> Float {
            values[attribute * anchors + anchor]
        }

        for anchor in 0 ..< anchors {
            let score = at(4, anchor)
            guard score > scoreThreshold else { continue }

            let cx = CGFloat(at(0, anchor)), cy = CGFloat(at(1, anchor))
            let w = CGFloat(at(2, anchor)), h = CGFloat(at(3, anchor))

            let box = CGRect(x: (cx - w / 2) * ratioX,
                             y: (cy - h / 2) * ratioY,
                             width: w * ratioX,
                             height: h * ratioY)

            // Key points start at attribute 5, three values each.
            var landmarks: [CGPoint] = []
            landmarks.reserveCapacity(5)
            for k in 0 ..< 5 {
                let base = 5 + k * 3
                guard base + 1 < attributes else { break }
                landmarks.append(CGPoint(x: CGFloat(at(base, anchor)) * ratioX,
                                         y: CGFloat(at(base + 1, anchor)) * ratioY))
            }
            guard landmarks.count == 5 else { continue }

            observations.append(FaceObservation(box: box, score: score, landmarks: landmarks))
        }

        return Self.nonMaximumSuppression(observations, iouThreshold: 0.4)
    }

    /// Greedy NMS. The detector fires on several neighbouring anchors per face.
    static func nonMaximumSuppression(_ faces: [FaceObservation],
                                      iouThreshold: CGFloat) -> [FaceObservation] {
        let sorted = faces.sorted { $0.score > $1.score }
        var kept: [FaceObservation] = []

        for candidate in sorted {
            var overlaps = false
            for existing in kept where intersectionOverUnion(candidate.box, existing.box) > iouThreshold {
                overlaps = true
                break
            }
            if !overlaps { kept.append(candidate) }
        }
        return kept
    }

    private static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = a.width * a.height + b.width * b.height - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }
}

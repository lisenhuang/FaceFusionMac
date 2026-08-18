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
//  One thing differs from the Mac engine: the fit and the canvas are a single
//  operation here. `restricted(to:)` is itself an affine warp, so warping
//  straight into the padded tensor drops a whole full-frame BGRA buffer per
//  frame — which on a phone is both the allocation and the memory traffic that
//  matters. The numbers are untouched: the same transform, the same sampling,
//  and the ratios below are still recovered from the integer output size
//  rather than from the float scale, because the two disagree by a fraction of
//  a pixel and boxes are reported in original-frame coordinates.
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
        let fit = Self.fit(width: image.width, height: image.height, limit: Self.inputSize)

        // `restricted` never upscales, so recover the exact ratio from the
        // dimensions rather than trusting a float scale factor.
        let ratioX = CGFloat(image.width) / CGFloat(fit.width)
        let ratioY = CGFloat(image.height) / CGFloat(fit.height)

        // The reference pipeline feeds this model BGR, not RGB.
        let input: FloatTensor
        if let transform = fit.transform {
            input = image.warpedTensor(by: transform,
                                       width: fit.width, height: fit.height,
                                       order: .bgr,
                                       padTo: (Self.inputSize, Self.inputSize))
        } else {
            // Already inside the canvas. Warping by the identity would be a
            // pixel-exact no-op, but it would also copy the frame for nothing,
            // which is precisely the case `restricted` short-circuits.
            input = image.tensorCHW(order: .bgr,
                                    padTo: (Self.inputSize, Self.inputSize))
        }

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

        // `values` is a pointer into the tensor's storage rather than an array,
        // so the tensor has to be held for as long as the pointer is read —
        // otherwise ARC is free to release the buffer at the last mention of
        // `detection`, which is several thousand iterations too early.
        let observations = withExtendedLifetime(detection) { () -> [FaceObservation] in
            let values = detection.values

            @inline(__always) func at(_ attribute: Int, _ anchor: Int) -> Float {
                values[attribute * anchors + anchor]
            }

            var found: [FaceObservation] = []
            found.reserveCapacity(16)

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

                found.append(FaceObservation(box: box, score: score, landmarks: landmarks))
            }
            return found
        }

        return Self.nonMaximumSuppression(observations, iouThreshold: 0.4)
    }

    /// The downscale `BGRAImage.restricted(to:)` would apply, expressed as a
    /// transform so the fit and the tensor packing can be one warp.
    ///
    /// Reproduced here rather than called because the two have to agree
    /// exactly: the integer output size — not the float scale — is what the
    /// ratios above undo, and rounding the size twice would shift every box by
    /// up to a pixel. A `nil` transform means the frame already fits.
    private static func fit(width: Int, height: Int, limit: Int)
        -> (width: Int, height: Int, transform: CGAffineTransform?) {
        guard width > limit || height > limit else { return (width, height, nil) }
        let scale = min(CGFloat(limit) / CGFloat(width), CGFloat(limit) / CGFloat(height))
        let newWidth = max(1, Int(CGFloat(width) * scale))
        let newHeight = max(1, Int(CGFloat(height) * scale))
        let transform = CGAffineTransform(scaleX: CGFloat(newWidth) / CGFloat(width),
                                          y: CGFloat(newHeight) / CGFloat(height))
        return (newWidth, newHeight, transform)
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

//
//  FaceOccluder.swift
//  FaceFusionEngine
//
//  dfl_xseg. Segments what is actually face in an aligned crop, so that a hand,
//  a strand of hair or a microphone crossing the face keeps its own pixels
//  instead of being painted over by the swap.
//
//  The output is a mask in crop space — 1 where the swapped pixels may land,
//  falling to 0 over anything sitting in front of the face — and it is combined
//  with the feathered box mask by element-wise minimum, exactly the reference's
//  `numpy.minimum.reduce`. The pre- and post-processing here mirror
//  `create_occlusion_mask` in FaceFusion 3.0's `face_masker.py` step for step;
//  none of the constants are free parameters.
//

import Foundation
import CoreGraphics

struct FaceOccluder {
    /// The graph's fixed input resolution. The crop is resized to this, and the
    /// mask comes back at it.
    static let inputSize = 256

    let model: ORTModel

    init(model: ORTModel) {
        self.model = model
    }

    /// The occlusion mask for one face, in the coordinate space of a
    /// `cropSize` × `cropSize` crop aligned by `transform`.
    ///
    /// The crop is warped from the frame exactly as the swapper's own crop is —
    /// same transform, same sampling — so the mask lines up with the patch it
    /// will gate.
    func occlusionMask(image: BGRAImage,
                       transform: CGAffineTransform,
                       cropSize: Int) throws -> FloatMask {
        let crop = image.warped(by: transform, width: cropSize, height: cropSize)
        let input = Self.inputTensor(from: crop)

        let outputs = try model.run([model.inputNames[0]: input])
        guard let result = outputs[model.outputNames[0]] else {
            throw makeEngineNSError(.inferenceFailed, underlying: "occluder produced no output")
        }
        return Self.postprocess(result, cropSize: cropSize)
    }

    /// Packs a crop into the occluder's `1 × H × W × 3` input.
    ///
    /// Channels-last because the graph was exported from TensorFlow and keeps
    /// that layout, and **BGR** deliberately: the reference feeds the OpenCV
    /// frame straight in with no channel reverse, so the in-memory byte order
    /// of a BGRA pixel is already the right one. Values are plain 1/255, no
    /// mean subtraction.
    static func inputTensor(from crop: BGRAImage) -> FloatTensor {
        let size = inputSize
        let resized = (crop.width == size && crop.height == size)
            ? crop
            : crop.warped(by: CGAffineTransform(scaleX: CGFloat(size) / CGFloat(crop.width),
                                                y: CGFloat(size) / CGFloat(crop.height)),
                          width: size, height: size)

        var values = [Float](repeating: 0, count: size * size * 3)
        let invScale: Float = 1.0 / 255.0
        for y in 0 ..< size {
            let src = resized.row(y)
            for x in 0 ..< size {
                let pixel = x * 4
                let out = (y * size + x) * 3
                values[out] = Float(src[pixel]) * invScale
                values[out + 1] = Float(src[pixel + 1]) * invScale
                values[out + 2] = Float(src[pixel + 2]) * invScale
            }
        }
        return FloatTensor(shape: [1, size, size, 3], values: values)
    }

    /// The reference's post-processing, step for step: clip the raw output to
    /// 0...1, resize to the crop, Gaussian blur at σ5, then keep only the upper
    /// half of the range — `(clip(0.5...1) − 0.5) × 2` — so anything the model
    /// is less than half sure is face drops out of the paste entirely and the
    /// transition band is softened rather than a hard segmentation edge.
    ///
    /// σ5 is in crop pixels and fixed, as in the reference, not scaled with the
    /// crop. The blur is `FloatMask.blurred`, the same primitive the box mask's
    /// feathering is validated with.
    static func postprocess(_ output: FloatTensor, cropSize: Int) -> FloatMask {
        let size = inputSize
        var mask = FloatMask(width: size, height: size)
        let count = min(output.values.count, mask.values.count)
        for i in 0 ..< count {
            mask.values[i] = min(max(output.values[i], 0), 1)
        }

        if cropSize != size {
            mask = mask.warped(by: CGAffineTransform(scaleX: CGFloat(cropSize) / CGFloat(size),
                                                     y: CGFloat(cropSize) / CGFloat(size)),
                               width: cropSize, height: cropSize)
        }

        var blurred = mask.blurred(sigma: 5)
        for i in 0 ..< blurred.values.count {
            blurred.values[i] = (min(max(blurred.values[i], 0.5), 1) - 0.5) * 2
        }
        return blurred
    }
}

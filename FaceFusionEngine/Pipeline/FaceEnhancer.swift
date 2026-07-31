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

import Foundation
import CoreGraphics

struct FaceEnhancer {
    static let inputSize = 512

    let model: ORTModel

    /// Enhances one face in place.
    /// - Parameter blend: 0...1 opacity of the restored face over the original.
    func enhance(image: BGRAImage,
                 landmarks: [CGPoint],
                 maskBlur: Double,
                 blend: Double) throws {
        let transform = Geometry.alignmentTransform(landmarks: landmarks,
                                                    template: WarpTemplate.ffhq512,
                                                    cropSize: Self.inputSize)
        let crop = image.warped(by: transform, width: Self.inputSize, height: Self.inputSize)

        let input = crop.tensorCHW(order: .rgb, mean: 0.5, standardDeviation: 0.5)

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
        let mask = FaceMasker.boxMask(size: Self.inputSize, blur: maskBlur)

        image.pasteBack(patch: restored,
                        mask: mask,
                        transform: transform,
                        opacity: Float(min(max(blend, 0), 1)))
    }
}

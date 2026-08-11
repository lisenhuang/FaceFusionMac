//
//  FaceOccluderTests.swift
//  FaceFusionMacTests
//
//  The occluder's pre- and post-processing, checked without the model. The
//  graph itself needs weights on disk, but every number on either side of it
//  can be checked here: the input packing (channels-last BGR at 1/255) and the
//  output mapping (clip, resize, σ5 blur, then `(clip(0.5...1) − 0.5) × 2`)
//  are ported from FaceFusion 3.0's `create_occlusion_mask` and must not drift
//  from it.
//

import Testing
import CoreGraphics
import Foundation

struct FaceOccluderTests {

    // MARK: - Input packing

    @Test func inputTensorIsChannelsLastBGROver255() {
        let size = FaceOccluder.inputSize
        let crop = BGRAImage(width: size, height: size)
        // One known pixel; everything else stays zero.
        let x = 3, y = 2
        let row = crop.row(y)
        row[x * 4] = 10       // blue
        row[x * 4 + 1] = 20   // green
        row[x * 4 + 2] = 30   // red
        row[x * 4 + 3] = 255

        let tensor = FaceOccluder.inputTensor(from: crop)
        #expect(tensor.shape == [1, size, size, 3])

        // The reference feeds the OpenCV frame with no channel reverse, so the
        // tensor must read B, G, R in that order.
        let base = (y * size + x) * 3
        #expect(abs(tensor.values[base] - 10.0 / 255.0) < 1e-6)
        #expect(abs(tensor.values[base + 1] - 20.0 / 255.0) < 1e-6)
        #expect(abs(tensor.values[base + 2] - 30.0 / 255.0) < 1e-6)

        // And an untouched pixel is exactly zero, not a normalised mean.
        #expect(tensor.values[0] == 0)
    }

    @Test func inputTensorResizesTheCropToTheModelSize() {
        // A 128px crop — the swapper's — must arrive at the graph as 256.
        let crop = BGRAImage(width: 128, height: 128)
        for y in 0 ..< 128 {
            let row = crop.row(y)
            for x in 0 ..< 128 {
                row[x * 4] = 100; row[x * 4 + 1] = 100
                row[x * 4 + 2] = 100; row[x * 4 + 3] = 255
            }
        }
        let tensor = FaceOccluder.inputTensor(from: crop)
        #expect(tensor.shape == [1, FaceOccluder.inputSize, FaceOccluder.inputSize, 3])
        // A constant image resizes to the same constant, whatever the filter.
        #expect(abs(tensor.values[0] - 100.0 / 255.0) < 1e-3)
        #expect(abs(tensor.values[tensor.count - 1] - 100.0 / 255.0) < 1e-3)
    }

    // MARK: - Output mapping

    @Test func constantMasksMapThroughTheClipWindow() {
        // Blurring a constant leaves it alone, so the whole post-process
        // collapses to the documented mapping `(clip(0.5...1) − 0.5) × 2` —
        // including the initial clip of raw model output to 0...1.
        let size = FaceOccluder.inputSize
        let cases: [(raw: Float, expected: Float)] = [
            (1.5, 1), (1, 1), (0.75, 0.5), (0.5, 0), (0.4, 0), (-0.25, 0),
        ]
        for c in cases {
            let output = FloatTensor(shape: [1, size, size, 1], repeating: c.raw)
            let mask = FaceOccluder.postprocess(output, cropSize: 128)
            #expect(mask.width == 128)
            #expect(mask.height == 128)
            for value in [mask.values[0], mask.values[128 * 64 + 64], mask.values[128 * 128 - 1]] {
                #expect(abs(value - c.expected) < 1e-4)
            }
        }
    }

    @Test func occlusionCarvesTheCombinedMask() {
        // A 64px hole in an otherwise-certain mask: after the resize and the
        // σ5 blur it must still be fully open deep inside and fully closed far
        // away, and the minimum against the box mask must keep the carve.
        let size = FaceOccluder.inputSize
        var output = FloatTensor(shape: [1, size, size, 1], repeating: 1)
        for y in 96 ..< 160 {
            for x in 96 ..< 160 {
                output.values[y * size + x] = 0
            }
        }

        let mask = FaceOccluder.postprocess(output, cropSize: 128)
        // The hole lands at 48..<80 in crop space. (64, 64) is 16px — 3.2σ —
        // from every edge, so what the blur gathers from outside the hole is
        // a fraction of a percent, and the clip window floors it to zero.
        // (10, 10) is 38px outside the hole, far beyond the 20px kernel radius.
        #expect(mask.values[64 * 128 + 64] < 0.01)
        #expect(mask.values[10 * 128 + 10] > 0.99)

        var combined = FaceMasker.boxMask(size: 128, blur: 0.3)
        combined.intersect(with: mask)
        combined.clamp01()
        #expect(combined.values[64 * 128 + 64] < 0.01)
    }
}

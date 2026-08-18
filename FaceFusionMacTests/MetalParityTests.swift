//
//  MetalParityTests.swift
//  FaceFusionMacTests
//
//  The agreement between the CPU implementation and the Metal kernels that
//  replaced it on the hot path.
//
//  Every warp, tensor pack and paste-back in the engine now has two
//  implementations. The CPU one is the validated reference: it is what the
//  OpenCV ground-truth numbers in `FaceFusionMacTests` were captured against.
//  The GPU one is what actually runs. If they disagree, the engine silently
//  produces different pixels than the numbers everyone reasoned about — and
//  because a kernel may decline any single frame and fall through, a
//  disagreement shows up in a video as a flicker at the moment it falls back.
//  So they are compared here, directly, on the same inputs.
//
//  A one-unit-in-255 tolerance is the right bar: both paths do the same
//  arithmetic in float and round at the end, so they differ only where a value
//  lands within half a bit of a rounding boundary.
//
//  These are the iOS app's tests, ported alongside the code they cover. The two
//  platforms run the same kernels over the same pixel code, and the point of
//  keeping both suites is that each one proves it on its own hardware.
//
//  The engine sources are compiled directly into this test bundle, so these
//  exercise the same code the XPC service runs.
//

import Testing
import CoreGraphics
import Foundation
import os

// MARK: - Fixtures

/// A deterministic image with structure at several frequencies, so a warp that
/// is subtly wrong has somewhere to show it. A flat or smoothly ramped image
/// hides half-pixel errors; a chequer with a gradient underneath does not.
private func testImage(width: Int, height: Int) -> BGRAImage {
    let image = BGRAImage(width: width, height: height)
    for y in 0 ..< height {
        let row = image.row(y)
        for x in 0 ..< width {
            let chequer = ((x >> 2) ^ (y >> 2)) & 1
            row[x * 4 + 0] = UInt8((x * 7 + chequer * 90) % 256)
            row[x * 4 + 1] = UInt8((y * 5 + chequer * 40) % 256)
            row[x * 4 + 2] = UInt8(((x + y) * 3 + chequer * 160) % 256)
            row[x * 4 + 3] = 255
        }
    }
    return image
}

/// Largest per-channel difference between two images of the same size.
private func maximumDifference(_ a: BGRAImage, _ b: BGRAImage) -> Int {
    guard a.width == b.width, a.height == b.height else { return 255 }
    var worst = 0
    for y in 0 ..< a.height {
        let left = a.row(y), right = b.row(y)
        for i in 0 ..< a.width * 4 {
            worst = max(worst, abs(Int(left[i]) - Int(right[i])))
        }
    }
    return worst
}

/// A spread of transforms covering the cases the pipeline actually produces:
/// identity, the real arcface alignment, a heavy downscale that trips the box
/// prefilter, a rotation, and an upscale.
private var representativeTransforms: [(name: String, transform: CGAffineTransform, size: Int)] {
    let alignment = Geometry.similarityTransform(
        from: Reference.targetLandmarks,
        to: WarpTemplate.scaled(WarpTemplate.arcface128, to: 128))
    return [
        ("identity", .identity, 64),
        ("arcface128", alignment, 128),
        ("shrink 8x", CGAffineTransform(scaleX: 0.125, y: 0.125), 32),
        ("shrink 3x", CGAffineTransform(scaleX: 1.0 / 3, y: 1.0 / 3), 48),
        ("rotate 20deg", CGAffineTransform(rotationAngle: 0.35)
            .concatenating(CGAffineTransform(translationX: 40, y: -10)), 96),
        ("upscale 2x", CGAffineTransform(scaleX: 2, y: 2), 128),
    ]
}

// MARK: - Tensor packing

@Suite("Tensor packing")
struct TensorPackingTests {

    /// Packing then unpacking has to be the identity to within rounding, or
    /// every model in the pipeline sees a slightly different image than the one
    /// that was aligned.
    @Test func packUnpackRoundTrips() {
        let source = testImage(width: 64, height: 48)
        let tensor = source.tensorCHW(order: .rgb, mean: 0.5, standardDeviation: 0.5)
        #expect(tensor.shape == [1, 3, 48, 64])

        let restored = BGRAImage.fromTensorCHW(tensor, order: .rgb,
                                               mean: 0.5, standardDeviation: 0.5)
        #expect(restored.width == 64 && restored.height == 48)

        // Alpha is not carried by a three-channel tensor, so compare colour only.
        var worst = 0
        for y in 0 ..< 48 {
            let a = source.row(y), b = restored.row(y)
            for x in 0 ..< 64 {
                for c in 0 ..< 3 {
                    worst = max(worst, abs(Int(a[x * 4 + c]) - Int(b[x * 4 + c])))
                }
            }
        }
        #expect(worst <= 1, "round trip drifted by \(worst)")
    }

    /// The detector pastes a fitted frame at the canvas origin rather than
    /// letterboxing it, which is what makes undoing the fit a single uniform
    /// scale. The padding must therefore be zero, not edge-replicated.
    @Test func paddingIsZeroed() {
        let source = testImage(width: 40, height: 20)
        let tensor = source.tensorCHW(order: .bgr, padTo: (64, 64))
        #expect(tensor.shape == [1, 3, 64, 64])

        let plane = 64 * 64
        #expect(tensor.values[plane - 1] == 0, "bottom-right of the canvas should be padding")
        #expect(tensor.values[0] != 0 || tensor.values[1] != 0,
                "the image itself should be at the origin")
    }

    /// Channel order is the difference between a face and a blue smear: the
    /// detector wants BGR, everything downstream wants RGB.
    @Test func channelOrderSelectsTheRightBytes() {
        let image = BGRAImage(width: 1, height: 1)
        let pixel = image.row(0)
        pixel[0] = 10; pixel[1] = 20; pixel[2] = 30; pixel[3] = 255   // B, G, R, A

        let bgr = image.tensorCHW(order: .bgr)
        #expect(abs(bgr.values[0] - 10.0 / 255) < 1e-5)
        #expect(abs(bgr.values[2] - 30.0 / 255) < 1e-5)

        let rgb = image.tensorCHW(order: .rgb)
        #expect(abs(rgb.values[0] - 30.0 / 255) < 1e-5)
        #expect(abs(rgb.values[2] - 10.0 / 255) < 1e-5)
    }
}

/// A mask with a hard edge and a ramp, so a blur that is subtly wrong has
/// somewhere to show it and a warp cannot hide a half-pixel shift.
private func testMask(width: Int, height: Int) -> FloatMask {
    var mask = FloatMask(width: width, height: height)
    for y in 0 ..< height {
        for x in 0 ..< width {
            let inside = x > width / 5 && x < width * 4 / 5
                      && y > height / 5 && y < height * 4 / 5
            mask.values[y * width + x] = inside
                ? Float(x + y) / Float(width + height)
                : 0
        }
    }
    return mask
}

/// Largest element difference between two masks of the same size.
private func maximumDifference(_ a: FloatMask, _ b: FloatMask) -> Float {
    guard a.width == b.width, a.height == b.height else { return .greatestFiniteMagnitude }
    var worst: Float = 0
    for i in 0 ..< min(a.values.count, b.values.count) {
        worst = max(worst, abs(a.values[i] - b.values[i]))
    }
    return worst
}

// MARK: - GPU agreement

/// Every one of these is skipped rather than failed when Metal is unavailable:
/// the CPU path is a supported configuration, not a broken one.
///
/// The comparison runs the *same* call twice — once normally, once inside
/// `MetalImageOps.withGPUDisabled` — so what is being checked is exactly what
/// the engine would get if a kernel declined a frame halfway through a video.
@Suite("Metal kernels agree with the CPU reference")
struct MetalParityTests {

    private var ops: MetalImageOps? { MetalImageOps.shared }

    @Test func warpMatchesTheCPUAcrossRepresentativeTransforms() throws {
        try #require(ops != nil, "Metal unavailable; the CPU path is what runs here")
        let source = testImage(width: 256, height: 192)

        for scenario in representativeTransforms {
            let gpu = source.warped(by: scenario.transform,
                                    width: scenario.size, height: scenario.size)
            let cpu = MetalImageOps.withGPUDisabled {
                source.warped(by: scenario.transform,
                              width: scenario.size, height: scenario.size)
            }
            let delta = maximumDifference(gpu, cpu)
            #expect(delta <= 1, "\(scenario.name): GPU and CPU differ by \(delta)")
        }
    }

    /// The box prefilter is the fiddliest part to reproduce, because it is two
    /// steps — reduce by an integer factor, then bilinear-sample the reduced
    /// image — and a single-pass approximation would be close enough to look
    /// right and wrong enough to fail the ground-truth comparison.
    @Test func boxReduceMatchesTheCPU() throws {
        try #require(ops != nil, "Metal unavailable")
        let source = testImage(width: 256, height: 256)
        for factor in [2, 3, 4, 8, 16] {
            let gpu = source.boxReduced(by: factor)
            let cpu = MetalImageOps.withGPUDisabled { source.boxReduced(by: factor) }
            #expect(gpu.width == cpu.width && gpu.height == cpu.height,
                    "factor \(factor): \(gpu.width)x\(gpu.height) vs \(cpu.width)x\(cpu.height)")
            #expect(maximumDifference(gpu, cpu) <= 1,
                    "factor \(factor): differ by \(maximumDifference(gpu, cpu))")
        }
    }

    @Test func tensorPackingMatchesTheCPU() throws {
        try #require(ops != nil, "Metal unavailable")
        let source = testImage(width: 100, height: 60)

        for (order, mean, deviation) in [(ChannelOrder.bgr, Float(0), Float(1)),
                                         (ChannelOrder.rgb, Float(0.5), Float(0.5))] {
            let gpu = source.tensorCHW(order: order, mean: mean, standardDeviation: deviation)
            let cpu = MetalImageOps.withGPUDisabled {
                source.tensorCHW(order: order, mean: mean, standardDeviation: deviation)
            }
            #expect(gpu.shape == cpu.shape)

            var worst: Float = 0
            for index in 0 ..< min(gpu.count, cpu.count) {
                worst = max(worst, abs(gpu.values[index] - cpu.values[index]))
            }
            // One 8-bit level is 1/255; agreement should be far tighter than that.
            #expect(worst < 1.0 / 255, "order \(order): worst element difference \(worst)")
        }
    }

    /// The detector's padded canvas is the one place a kernel writes less than
    /// the whole tensor, so it is the one place a stale or non-zero pad would
    /// hide — and the detector would then see phantom structure in the corner.
    @Test func paddedTensorPackingMatchesTheCPU() throws {
        try #require(ops != nil, "Metal unavailable")
        let source = testImage(width: 640, height: 338)

        let gpu = source.tensorCHW(order: .bgr, padTo: (640, 640))
        let cpu = MetalImageOps.withGPUDisabled {
            source.tensorCHW(order: .bgr, padTo: (640, 640))
        }
        #expect(gpu.shape == cpu.shape)
        var worst: Float = 0
        for index in 0 ..< min(gpu.count, cpu.count) {
            worst = max(worst, abs(gpu.values[index] - cpu.values[index]))
        }
        #expect(worst < 1.0 / 255, "padded pack differs by \(worst)")
    }

    /// The fused warp-to-tensor is what actually runs per model invocation, and
    /// it has to equal the two separate steps it replaces — otherwise the crop
    /// the swapper sees is not the crop the alignment maths described.
    @Test func fusedWarpToTensorEqualsWarpThenPack() throws {
        try #require(ops != nil, "Metal unavailable")
        let source = testImage(width: 320, height: 240)
        let alignment = Geometry.similarityTransform(
            from: Reference.targetLandmarks,
            to: WarpTemplate.scaled(WarpTemplate.arcface112v2, to: 112))

        let fused = source.warpedTensor(by: alignment, width: 112, height: 112,
                                        order: .rgb, mean: 0.5, standardDeviation: 0.5)
        // Not just the CPU's fused path — the two *separate* operations it
        // replaces, which is the thing the reference implementation actually did.
        let separate = MetalImageOps.withGPUDisabled {
            source.warped(by: alignment, width: 112, height: 112)
                .tensorCHW(order: .rgb, mean: 0.5, standardDeviation: 0.5)
        }

        #expect(fused.shape == separate.shape)
        var worst: Float = 0
        for index in 0 ..< min(fused.count, separate.count) {
            worst = max(worst, abs(fused.values[index] - separate.values[index]))
        }
        #expect(worst <= 2.0 / 255, "fused and separate paths differ by \(worst)")
    }

    /// Unpacking is the swapper's and enhancer's output path, so an error here
    /// is a visibly wrong face rather than a subtly wrong alignment.
    @Test func tensorUnpackingMatchesTheCPU() throws {
        try #require(ops != nil, "Metal unavailable")
        let source = testImage(width: 128, height: 128)
        let tensor = MetalImageOps.withGPUDisabled {
            source.tensorCHW(order: .rgb, mean: 0.5, standardDeviation: 0.5)
        }

        let gpu = BGRAImage.fromTensorCHW(tensor, order: .rgb, mean: 0.5, standardDeviation: 0.5)
        let cpu = MetalImageOps.withGPUDisabled {
            BGRAImage.fromTensorCHW(tensor, order: .rgb, mean: 0.5, standardDeviation: 0.5)
        }
        #expect(maximumDifference(gpu, cpu) <= 1,
                "unpack differs by \(maximumDifference(gpu, cpu))")
    }

    @Test func pasteBackMatchesTheCPU() throws {
        try #require(ops != nil, "Metal unavailable")
        let alignment = Geometry.similarityTransform(
            from: Reference.targetLandmarks,
            to: WarpTemplate.scaled(WarpTemplate.arcface128, to: 128))
        let patch = testImage(width: 128, height: 128)
        let mask = FaceMasker.boxMask(size: 128, blur: 0.3)

        let gpu = testImage(width: 360, height: 280)
        let cpu = testImage(width: 360, height: 280)
        gpu.pasteBack(patch: patch, mask: mask, transform: alignment)
        MetalImageOps.withGPUDisabled {
            cpu.pasteBack(patch: patch, mask: mask, transform: alignment)
        }

        #expect(maximumDifference(gpu, cpu) <= 1,
                "paste-back differs by \(maximumDifference(gpu, cpu))")
    }

    /// Restoring a small face means a 512px patch collapsing into a much
    /// smaller region — a shrink, which trips the prefilter on the paste-back
    /// path too. That branch is easy to leave out of the GPU version because
    /// the common case is an upscale.
    @Test func pasteBackOfAShrunkPatchMatchesTheCPU() throws {
        try #require(ops != nil, "Metal unavailable")
        // Maps a 512px patch down onto roughly a 64px region.
        let alignment = CGAffineTransform(scaleX: 8, y: 8)
            .concatenating(CGAffineTransform(translationX: -160, y: -120))
        let patch = testImage(width: 512, height: 512)
        let mask = FaceMasker.boxMask(size: 512, blur: 0.3)

        let gpu = testImage(width: 360, height: 280)
        let cpu = testImage(width: 360, height: 280)
        gpu.pasteBack(patch: patch, mask: mask, transform: alignment, opacity: 0.8)
        MetalImageOps.withGPUDisabled {
            cpu.pasteBack(patch: patch, mask: mask, transform: alignment, opacity: 0.8)
        }

        #expect(maximumDifference(gpu, cpu) <= 1,
                "shrinking paste-back differs by \(maximumDifference(gpu, cpu))")
    }

    /// The engine runs several frames at once, so the ops are called from
    /// several threads at the same time. Shared command-buffer or scratch state
    /// would show up here as a torn result rather than as a crash.
    @Test func opsAreSafeToCallConcurrently() throws {
        try #require(ops != nil, "Metal unavailable")
        let source = testImage(width: 256, height: 256)
        let transform = CGAffineTransform(scaleX: 0.25, y: 0.25)
        let expected = source.warped(by: transform, width: 64, height: 64)

        let results = OSAllocatedUnfairLock(initialState: [Int]())
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            let actual = source.warped(by: transform, width: 64, height: 64)
            let delta = maximumDifference(expected, actual)
            results.withLock { $0.append(delta) }
        }
        let worst = results.withLock { $0.max() ?? 255 }
        #expect(worst <= 1, "concurrent warps disagreed by up to \(worst)")
    }

    /// The separable Gaussian is the largest single piece of arithmetic in a
    /// frame and the one most likely to drift, because it accumulates a
    /// hundred-and-fifty terms into one running float. Both paths run the taps
    /// in ascending order over identical weights, so what is left is a
    /// contracted multiply-add and nothing else.
    @Test func maskBlurMatchesTheCPU() throws {
        try #require(ops != nil, "Metal unavailable")
        for (size, sigma) in [(128, Float(5)), (256, Float(5)), (512, Float(19))] {
            let mask = testMask(width: size, height: size)
            let gpu = mask.blurred(sigma: sigma)
            let cpu = MetalImageOps.withGPUDisabled { mask.blurred(sigma: sigma) }
            #expect(gpu.width == cpu.width && gpu.height == cpu.height)
            let delta = maximumDifference(gpu, cpu)
            #expect(delta < 1e-5, "\(size)px at sigma \(sigma) differs by \(delta)")
        }
    }

    /// The occluder resizes its mask to the crop before feathering it, so this
    /// runs on the path that decides where a hand stops being painted over.
    @Test func maskWarpMatchesTheCPU() throws {
        try #require(ops != nil, "Metal unavailable")
        let mask = testMask(width: 256, height: 256)

        for (name, size) in [("upscale to 512", 512), ("downscale to 128", 128)] {
            let transform = CGAffineTransform(scaleX: CGFloat(size) / 256,
                                              y: CGFloat(size) / 256)
            let gpu = mask.warped(by: transform, width: size, height: size)
            let cpu = MetalImageOps.withGPUDisabled {
                mask.warped(by: transform, width: size, height: size)
            }
            let delta = maximumDifference(gpu, cpu)
            #expect(delta < 1e-5, "\(name) differs by \(delta)")
        }
    }

    /// Channels-last packing is the same multiply per value as the CHW kernel
    /// and only writes it somewhere else, so unlike the warps this one should
    /// agree exactly rather than nearly.
    @Test func occluderTensorPackMatchesTheCPU() throws {
        try #require(ops != nil, "Metal unavailable")
        let crop = testImage(width: FaceOccluder.inputSize, height: FaceOccluder.inputSize)

        let gpu = FaceOccluder.inputTensor(from: crop)
        let cpu = MetalImageOps.withGPUDisabled { FaceOccluder.inputTensor(from: crop) }

        #expect(gpu.shape == cpu.shape)
        var worst: Float = 0
        for index in 0 ..< min(gpu.count, cpu.count) {
            worst = max(worst, abs(gpu.values[index] - cpu.values[index]))
        }
        #expect(worst == 0, "channels-last pack differs by \(worst); it should be exact")
    }

    /// The frame copy is a blit rather than a kernel, so unlike everything else
    /// here it must agree exactly. It is also the one path that runs on a
    /// full-size frame, where a stride mismatch between a padded owned buffer
    /// and a borrowed surface would show up as a shear rather than as noise.
    @Test func frameCopyIsExact() throws {
        try #require(ops != nil, "Metal unavailable")
        // Above `minimumCopyPixels`, or the blit declines and this proves
        // nothing about it.
        let source = testImage(width: 1920, height: 1080)

        let gpu = BGRAImage(width: 1920, height: 1080)
        let cpu = BGRAImage(width: 1920, height: 1080)
        source.copyContents(into: gpu)
        MetalImageOps.withGPUDisabled { source.copyContents(into: cpu) }

        #expect(maximumDifference(gpu, cpu) == 0, "blit and memcpy disagree")
        #expect(maximumDifference(gpu, source) == 0, "the copy is not the original")
    }
}

// MARK: - Zero-copy tensor storage

/// The port's central performance claim is that a tensor's bytes are written by
/// a Metal kernel and read by ONNX Runtime without ever being copied, which
/// rests on an `NSMutableData` subclass that borrows foreign memory. Foundation
/// is entitled to copy instead — several of its "no copy" constructors do —
/// and if it did, everything would still work and simply be slower and wrong
/// about it. So the borrow is asserted rather than assumed.
@Suite("Tensor storage")
struct TensorStorageTests {

    @Test func dataViewBorrowsRatherThanCopies() {
        let tensor = FloatTensor(shape: [1, 3, 8, 8])
        let data = tensor.storage.data

        #expect(data.length == tensor.count * MemoryLayout<Float>.stride)
        #expect(data.mutableBytes == UnsafeMutableRawPointer(tensor.storage.pointer),
                "the data view has its own buffer — the zero-copy path is not zero-copy")

        // A write through one has to be visible through the other.
        tensor.values[5] = 0.25
        let readBack = data.bytes.assumingMemoryBound(to: Float.self)[5]
        #expect(readBack == 0.25)
    }

    @Test func shapeAndCountAgree() {
        let tensor = FloatTensor(shape: [1, 3, 640, 640])
        #expect(tensor.count == 3 * 640 * 640)
        #expect(tensor.values.count == tensor.count)
    }

    /// The warp-into-tensor kernel writes only the region it covers and relies
    /// on the rest already being zero, which is what lets the detector's
    /// 640x640 canvas hold a fitted frame at the origin and nothing else.
    @Test func freshStorageIsZeroed() {
        let tensor = FloatTensor(shape: [1, 3, 64, 64])
        #expect(tensor.values.allSatisfy { $0 == 0 })
    }

    @Test func copyingInitialiserPreservesValues() {
        let source: [Float] = (0 ..< 32).map { Float($0) * 0.5 }
        let tensor = FloatTensor(shape: [1, 32], values: source)
        #expect(tensor.count == 32)
        #expect(Array(tensor.values) == source)
    }
}

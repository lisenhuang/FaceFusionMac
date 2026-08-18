//
//  MetalImageOps.swift
//  FaceFusionEngine
//
//  The Swift side of `ImageOps.metal`: one method per kernel, each of which
//  either does the work on the GPU or returns nothing so the caller falls
//  through to the CPU implementation in `ImageBuffer.swift`.
//
//  Two decisions worth understanding before changing anything here.
//
//  **Every method waits.** Each call builds its own command buffer, encodes,
//  commits and then `waitUntilCompleted`. The callers are synchronous — they
//  are in the middle of a warp or a paste and need the pixels — so there is no
//  asynchrony to win. What is won is the kernel's parallelism: a 1080p warp is
//  two million independent taps and the GPU does them all at once, while the
//  CPU version walks rows across a handful of cores that the export loop also
//  wants for decode and encode. And because several frames are inside the
//  engine at once on different threads, the GPU stays fed regardless.
//
//  **Nothing here is allowed to fail a frame.** Every entry point returns
//  `nil`/`false` on any problem — no buffer, no pipeline, a command buffer that
//  errored — and the caller does it on the CPU instead. That is also why the
//  numbers have to agree: the two paths are interchangeable at runtime and a
//  video that switched between them mid-clip would visibly flicker if they did
//  not.
//
//  Thread safety: command buffers are per call, pipeline lookup is locked
//  inside `MetalContext`, and there is no shared mutable scratch.
//
//  Ported from the iOS app, where it was written and validated first. The
//  numbers are the same numbers — `ImageOps.metal` is a byte-for-byte copy and
//  the entry points below are line-for-line the same — because the two
//  platforms are checked against each other. The one deliberate difference is
//  in `run`, which honours `supportsNonUniformThreadgroups` rather than
//  assuming it: this target also builds for x86_64.
//

import Foundation
import CoreGraphics
import Metal
import os

final class MetalImageOps {

    static let shared: MetalImageOps? = MetalContext.shared.flatMap(MetalImageOps.init(context:))

    /// What the pixel code actually asks for: `shared`, unless the GPU has been
    /// switched off.
    ///
    /// The switch exists for one reason, and it is not configurability. The CPU
    /// and GPU implementations are interchangeable at runtime — any kernel may
    /// decline a frame and fall through — so a video that ran partly on each
    /// would visibly flicker if the two disagreed by more than a rounding step.
    /// The only way to keep them honest is to run both over the same input and
    /// compare, and that needs a way to ask for the CPU on a machine that has a
    /// perfectly good GPU. See `MetalParityTests`.
    static var active: MetalImageOps? { isEnabled.withLock { $0 } ? shared : nil }

    private static let isEnabled = OSAllocatedUnfairLock(initialState: true)

    /// Runs `body` with the GPU paths disabled, then restores the previous
    /// setting. Not re-entrant and not something to call while frames are in
    /// flight: it is a test affordance, and the engine never touches it.
    static func withGPUDisabled<T>(_ body: () throws -> T) rethrows -> T {
        let previous = isEnabled.withLock { state -> Bool in
            defer { state = false }
            return state
        }
        defer { isEnabled.withLock { $0 = previous } }
        return try body()
    }

    let context: MetalContext

    /// Below this many destination pixels the round trip to the GPU — encode,
    /// commit, wait — costs more than the work itself, so the CPU keeps it.
    /// Measured in destination pixels rather than source pixels because that is
    /// what every kernel here is dispatched over.
    private static let minimumPixels = 4096

    /// `copy` has a much higher bar than the compute kernels. It replaces a
    /// `memcpy`, which is already close to memory bandwidth, so the only thing
    /// won is the CPU time — and that is not worth a command buffer until the
    /// frame is a real frame. A megapixel is roughly where 4 MB of copying
    /// starts to matter beside the round trip.
    private static let minimumCopyPixels = 1 << 20

    init?(context: MetalContext) {
        // No library means no kernels, and a `MetalImageOps` that can never run
        // anything is worse than an absent one: callers would pay for the
        // guards on every pixel operation for nothing.
        guard context.library != nil else { return nil }
        self.context = context
    }

    // MARK: - box_reduce

    /// Averages each `factor` x `factor` block, matching `BGRAImage.boxReduced`.
    func boxReduce(_ source: BGRAImage, factor: Int) -> BGRAImage? {
        guard factor >= 2,
              source.width > 0, source.height > 0,
              let sourceBuffer = source.mtlBuffer else { return nil }

        let outWidth = max(1, source.width / factor)
        let outHeight = max(1, source.height / factor)
        guard outWidth * outHeight >= Self.minimumPixels else { return nil }

        let out = BGRAImage(width: outWidth, height: outHeight)
        guard let outBuffer = out.mtlBuffer else { return nil }

        let params = BoxReduceParams(srcWidth: UInt32(source.width),
                                     srcHeight: UInt32(source.height),
                                     srcRowBytes: UInt32(source.rowBytes),
                                     dstWidth: UInt32(outWidth),
                                     dstHeight: UInt32(outHeight),
                                     dstRowBytes: UInt32(out.rowBytes),
                                     factor: UInt32(factor),
                                     inverseArea: 1.0 / Float(factor * factor))

        let ok = run("box_reduce", gridWidth: outWidth, gridHeight: outHeight) { encoder in
            encoder.setBuffer(sourceBuffer, offset: 0, index: 0)
            encoder.setBuffer(outBuffer, offset: 0, index: 1)
            setBytes(params, on: encoder, index: 2)
        }
        return ok ? out : nil
    }

    /// `BGRAImage.warped`'s prefilter rule, applied on the GPU.
    ///
    /// This is a second copy of the decision inside `warped(by:width:height:)`,
    /// and it is a copy on purpose: `warped` is the function that was compared
    /// against the Python ground truth and it stays byte-for-byte as it was
    /// written. Change one and you must change the other. A warp that shrinks by
    /// more than half is box-reduced by an integer factor first, and the caller
    /// then samples the reduced image with the returned, rescaled transform.
    func boxPrefiltered(_ image: BGRAImage,
                        for transform: CGAffineTransform) -> (image: BGRAImage, transform: CGAffineTransform) {
        let scale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
        guard scale < 0.5, scale > 0 else { return (image, transform) }

        let factor = min(max(Int((1.0 / scale).rounded(.down)), 2), 16)
        guard image.width / factor >= 2, image.height / factor >= 2 else { return (image, transform) }

        // `boxReduced` picks its own GPU or CPU path; either way the result has
        // shared storage when Metal is available, so the warp that follows can
        // still run on the GPU.
        let reduced = image.boxReduced(by: factor)
        // Points now arrive pre-divided by `factor`, so scale back up before
        // applying the original mapping.
        let adjusted = CGAffineTransform(scaleX: CGFloat(factor), y: CGFloat(factor))
            .concatenating(transform)
        return (reduced, adjusted)
    }

    // MARK: - warp_bgra

    /// Destination-driven bilinear warp with edge clamp, matching
    /// `BGRAImage.drawWarped`. `transform` maps source to destination, as on the
    /// CPU; it is inverted here in double precision so both paths start from
    /// identical coefficients.
    func warp(_ source: BGRAImage,
              into destination: BGRAImage,
              transform: CGAffineTransform) -> Bool {
        guard source.width > 0, source.height > 0,
              destination.width > 0, destination.height > 0,
              destination.width * destination.height >= Self.minimumPixels,
              let sourceBuffer = source.mtlBuffer,
              let destinationBuffer = destination.mtlBuffer else { return false }

        let params = WarpParams(srcWidth: UInt32(source.width),
                                srcHeight: UInt32(source.height),
                                srcRowBytes: UInt32(source.rowBytes),
                                dstWidth: UInt32(destination.width),
                                dstHeight: UInt32(destination.height),
                                dstRowBytes: UInt32(destination.rowBytes),
                                inverse: Affine(transform.inverted()))

        return run("warp_bgra", gridWidth: destination.width, gridHeight: destination.height) { encoder in
            encoder.setBuffer(sourceBuffer, offset: 0, index: 0)
            encoder.setBuffer(destinationBuffer, offset: 0, index: 1)
            setBytes(params, on: encoder, index: 2)
        }
    }

    // MARK: - warp_to_tensor

    /// Warps straight into a normalised CHW tensor, skipping the intermediate
    /// BGRA crop. The caller is responsible for having applied
    /// `boxPrefiltered` first when the warp shrinks.
    func warpToTensor(_ source: BGRAImage,
                      transform: CGAffineTransform,
                      width: Int,
                      height: Int,
                      order: ChannelOrder,
                      mean: Float,
                      standardDeviation: Float,
                      padTo padded: (width: Int, height: Int)?) -> FloatTensor? {
        guard source.width > 0, source.height > 0,
              let sourceBuffer = source.mtlBuffer else { return nil }

        let tensorWidth = padded?.width ?? width
        let tensorHeight = padded?.height ?? height
        // The CPU writes only the overlap of the warp and the padded canvas;
        // the rest of the tensor stays at the zero it was allocated with.
        let spanWidth = min(width, tensorWidth)
        let spanHeight = min(height, tensorHeight)
        guard spanWidth > 0, spanHeight > 0,
              tensorWidth > 0, tensorHeight > 0,
              spanWidth * spanHeight >= Self.minimumPixels else { return nil }

        let tensor = FloatTensor(shape: [1, 3, tensorHeight, tensorWidth])
        guard let tensorBuffer = tensor.storage.mtlBuffer else { return nil }

        let channels = Self.channelOffsets(order)
        let params = WarpTensorParams(srcWidth: UInt32(source.width),
                                      srcHeight: UInt32(source.height),
                                      srcRowBytes: UInt32(source.rowBytes),
                                      spanWidth: UInt32(spanWidth),
                                      spanHeight: UInt32(spanHeight),
                                      tensorWidth: UInt32(tensorWidth),
                                      tensorHeight: UInt32(tensorHeight),
                                      c0: channels.0, c1: channels.1, c2: channels.2,
                                      mean: mean,
                                      standardDeviation: standardDeviation,
                                      inverse: Affine(transform.inverted()))

        let ok = run("warp_to_tensor", gridWidth: spanWidth, gridHeight: spanHeight) { encoder in
            encoder.setBuffer(sourceBuffer, offset: 0, index: 0)
            encoder.setBuffer(tensorBuffer, offset: 0, index: 1)
            setBytes(params, on: encoder, index: 2)
        }
        return ok ? tensor : nil
    }

    // MARK: - pack_tensor

    /// `BGRAImage.tensorCHW` for an image that is already the right size.
    func packTensor(_ source: BGRAImage,
                    order: ChannelOrder,
                    mean: Float,
                    standardDeviation: Float,
                    padTo padded: (width: Int, height: Int)?) -> FloatTensor? {
        guard source.width > 0, source.height > 0,
              let sourceBuffer = source.mtlBuffer else { return nil }

        let tensorWidth = padded?.width ?? source.width
        let tensorHeight = padded?.height ?? source.height
        let spanWidth = min(source.width, tensorWidth)
        let spanHeight = min(source.height, tensorHeight)
        guard spanWidth > 0, spanHeight > 0,
              tensorWidth > 0, tensorHeight > 0,
              spanWidth * spanHeight >= Self.minimumPixels else { return nil }

        let tensor = FloatTensor(shape: [1, 3, tensorHeight, tensorWidth])
        guard let tensorBuffer = tensor.storage.mtlBuffer else { return nil }

        let channels = Self.channelOffsets(order)
        let params = PackParams(srcWidth: UInt32(source.width),
                                srcHeight: UInt32(source.height),
                                srcRowBytes: UInt32(source.rowBytes),
                                spanWidth: UInt32(spanWidth),
                                spanHeight: UInt32(spanHeight),
                                tensorWidth: UInt32(tensorWidth),
                                tensorHeight: UInt32(tensorHeight),
                                c0: channels.0, c1: channels.1, c2: channels.2,
                                mean: mean,
                                standardDeviation: standardDeviation)

        let ok = run("pack_tensor", gridWidth: spanWidth, gridHeight: spanHeight) { encoder in
            encoder.setBuffer(sourceBuffer, offset: 0, index: 0)
            encoder.setBuffer(tensorBuffer, offset: 0, index: 1)
            setBytes(params, on: encoder, index: 2)
        }
        return ok ? tensor : nil
    }

    // MARK: - unpack_tensor

    /// `BGRAImage.fromTensorCHW`, writing opaque BGRA.
    func unpackTensor(_ tensor: FloatTensor,
                      order: ChannelOrder,
                      mean: Float,
                      standardDeviation: Float) -> BGRAImage? {
        // Shape is [1, 3, H, W]; tolerate a missing batch dimension, and hand
        // anything else back to the CPU rather than guessing.
        let dims = tensor.shape.count == 4 ? Array(tensor.shape.dropFirst()) : tensor.shape
        guard dims.count == 3, dims[0] >= 3 else { return nil }
        let height = dims[1], width = dims[2]
        guard width > 0, height > 0,
              width * height >= Self.minimumPixels,
              tensor.count >= 3 * width * height,
              let tensorBuffer = tensor.storage.mtlBuffer else { return nil }

        let image = BGRAImage(width: width, height: height)
        guard let imageBuffer = image.mtlBuffer else { return nil }

        let channels = Self.channelOffsets(order)
        let params = UnpackParams(width: UInt32(width),
                                  height: UInt32(height),
                                  dstRowBytes: UInt32(image.rowBytes),
                                  c0: channels.0, c1: channels.1, c2: channels.2,
                                  mean: mean,
                                  standardDeviation: standardDeviation)

        let ok = run("unpack_tensor", gridWidth: width, gridHeight: height) { encoder in
            encoder.setBuffer(tensorBuffer, offset: 0, index: 0)
            encoder.setBuffer(imageBuffer, offset: 0, index: 1)
            setBytes(params, on: encoder, index: 2)
        }
        return ok ? image : nil
    }

    // MARK: - paste_back

    /// Warps `patch` and `mask` back through the inverse of `transform` and
    /// blends into `destination`, matching `BGRAImage.pasteBack`.
    ///
    /// Returns `true` when the destination is in its final state — which
    /// includes the case where the patch lands entirely outside the frame and
    /// there is nothing to do. Returning `false` means the caller must redo the
    /// whole blend on the CPU, so nothing may have been written yet: the single
    /// kernel dispatch is the only thing that touches destination pixels, and
    /// everything that can fail is checked before it is encoded.
    func pasteBack(into destination: BGRAImage,
                   patch: BGRAImage,
                   mask: FloatMask,
                   transform: CGAffineTransform,
                   opacity: Float) -> Bool {
        guard patch.width > 0, patch.height > 0,
              mask.width > 0, mask.height > 0,
              mask.values.count >= mask.width * mask.height,
              patch.mtlBuffer != nil,
              let destinationBuffer = destination.mtlBuffer else { return false }

        let inverse = transform.inverted()
        let bounds = Geometry.transformedBounds(width: patch.width,
                                                height: patch.height,
                                                by: inverse)

        let x1 = max(0, Int(bounds.minX.rounded(.down)))
        let y1 = max(0, Int(bounds.minY.rounded(.down)))
        let x2 = min(destination.width, Int(bounds.maxX.rounded(.up)))
        let y2 = min(destination.height, Int(bounds.maxY.rounded(.up)))
        // The CPU returns without touching anything here, so this is a success.
        guard x2 > x1, y2 > y1 else { return true }

        let regionWidth = x2 - x1, regionHeight = y2 - y1
        guard regionWidth * regionHeight >= Self.minimumPixels else { return false }

        // Shift the inverse so it renders directly into the region's origin.
        var pasteTransform = inverse
        pasteTransform.tx -= CGFloat(x1)
        pasteTransform.ty -= CGFloat(y1)

        // `patch.warped(by:)` prefilters when it shrinks, so this must too —
        // enhancing a small face means a 512px patch collapsing into a much
        // smaller region, which is exactly the case the prefilter exists for.
        // The mask is never prefiltered, so the two end up with different
        // mappings and the kernel takes both.
        let (sourcePatch, patchTransform) = boxPrefiltered(patch, for: pasteTransform)
        guard let patchBuffer = sourcePatch.mtlBuffer,
              let maskBuffer = maskBuffer(for: mask) else { return false }

        let params = PasteParams(dstRowBytes: UInt32(destination.rowBytes),
                                 originX: UInt32(x1),
                                 originY: UInt32(y1),
                                 regionWidth: UInt32(regionWidth),
                                 regionHeight: UInt32(regionHeight),
                                 patchWidth: UInt32(sourcePatch.width),
                                 patchHeight: UInt32(sourcePatch.height),
                                 patchRowBytes: UInt32(sourcePatch.rowBytes),
                                 maskWidth: UInt32(mask.width),
                                 maskHeight: UInt32(mask.height),
                                 opacity: opacity,
                                 patchInverse: Affine(patchTransform.inverted()),
                                 maskInverse: Affine(pasteTransform.inverted()))

        return run("paste_back", gridWidth: regionWidth, gridHeight: regionHeight) { encoder in
            encoder.setBuffer(destinationBuffer, offset: 0, index: 0)
            encoder.setBuffer(patchBuffer, offset: 0, index: 1)
            encoder.setBuffer(maskBuffer, offset: 0, index: 2)
            setBytes(params, on: encoder, index: 3)
        }
    }

    /// Uploads a mask's floats into shared storage, once.
    ///
    /// `FaceMasker` caches the mask itself and hands out copies that share this
    /// mirror, so the enhancer's 512x512 mask — a megabyte of floats — is copied
    /// at most once per session rather than once per face per frame.
    func maskBuffer(for mask: FloatMask) -> MTLBuffer? {
        if let existing = mask.gpuBuffer { return existing }

        let byteCount = mask.values.count * MemoryLayout<Float>.stride
        guard byteCount > 0, let buffer = context.makeBuffer(length: byteCount) else { return nil }
        mask.values.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            memcpy(buffer.contents(), base, byteCount)
        }
        mask.gpuBuffer = buffer
        return buffer
    }


    // MARK: - pack_tensor_hwc

    /// `FaceOccluder.inputTensor`: channels-last BGR over 1/255.
    ///
    /// The occluder is the one graph that wants NHWC, so it cannot share
    /// `packTensor`. It is also called twice per face per frame — once for the
    /// swap's paste mask and once for the restorer's — which is what makes a
    /// 196k-iteration scalar loop worth moving.
    func packTensorHWC(_ source: BGRAImage) -> FloatTensor? {
        guard source.width > 0, source.height > 0,
              source.width * source.height >= Self.minimumPixels,
              let sourceBuffer = source.mtlBuffer else { return nil }

        let tensor = FloatTensor(shape: [1, source.height, source.width, 3])
        guard let tensorBuffer = tensor.storage.mtlBuffer else { return nil }

        let params = PackHWCParams(width: UInt32(source.width),
                                   height: UInt32(source.height),
                                   srcRowBytes: UInt32(source.rowBytes))

        let ok = run("pack_tensor_hwc", gridWidth: source.width, gridHeight: source.height) { encoder in
            encoder.setBuffer(sourceBuffer, offset: 0, index: 0)
            encoder.setBuffer(tensorBuffer, offset: 0, index: 1)
            setBytes(params, on: encoder, index: 2)
        }
        return ok ? tensor : nil
    }

    // MARK: - mask_warp

    /// `FloatMask.warped` on the GPU.
    func warpMask(_ mask: FloatMask,
                  transform: CGAffineTransform,
                  width outWidth: Int,
                  height outHeight: Int) -> FloatMask? {
        guard mask.width > 0, mask.height > 0,
              mask.values.count >= mask.width * mask.height,
              outWidth > 0, outHeight > 0,
              outWidth * outHeight >= Self.minimumPixels,
              let sourceBuffer = maskBuffer(for: mask),
              let destination = context.makeBuffer(length: outWidth * outHeight * MemoryLayout<Float>.stride)
        else { return nil }

        let params = MaskWarpParams(srcWidth: UInt32(mask.width),
                                    srcHeight: UInt32(mask.height),
                                    dstWidth: UInt32(outWidth),
                                    dstHeight: UInt32(outHeight),
                                    inverse: Affine(transform.inverted()))

        let ok = run("mask_warp", gridWidth: outWidth, gridHeight: outHeight) { encoder in
            encoder.setBuffer(sourceBuffer, offset: 0, index: 0)
            encoder.setBuffer(destination, offset: 0, index: 1)
            setBytes(params, on: encoder, index: 2)
        }
        guard ok else { return nil }
        return Self.mask(width: outWidth, height: outHeight, from: destination)
    }

    // MARK: - mask_blur

    /// Both passes of `FloatMask.blurred`'s separable Gaussian.
    ///
    /// `weights` is computed by the caller so that the two implementations use
    /// bit-identical coefficients rather than each deriving its own. The
    /// intermediate stays on the GPU, so a blur costs one upload and one
    /// download however wide the kernel is.
    func blurMask(_ mask: FloatMask, weights: [Float], radius: Int) -> FloatMask? {
        let count = mask.width * mask.height
        guard mask.width > 0, mask.height > 0,
              mask.values.count >= count,
              count >= Self.minimumPixels,
              radius >= 1, weights.count == radius * 2 + 1,
              let source = maskBuffer(for: mask),
              let weightBuffer = context.makeBuffer(length: weights.count * MemoryLayout<Float>.stride),
              let intermediate = context.makeBuffer(length: count * MemoryLayout<Float>.stride),
              let destination = context.makeBuffer(length: count * MemoryLayout<Float>.stride)
        else { return nil }

        weights.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(weightBuffer.contents(), base, raw.count)
        }

        func pass(_ input: MTLBuffer, _ output: MTLBuffer, horizontal: Bool) -> Bool {
            let params = MaskBlurParams(width: UInt32(mask.width),
                                        height: UInt32(mask.height),
                                        radius: UInt32(radius),
                                        horizontal: horizontal ? 1 : 0)
            return run("mask_blur", gridWidth: mask.width, gridHeight: mask.height) { encoder in
                encoder.setBuffer(input, offset: 0, index: 0)
                encoder.setBuffer(output, offset: 0, index: 1)
                encoder.setBuffer(weightBuffer, offset: 0, index: 2)
                setBytes(params, on: encoder, index: 3)
            }
        }

        // Horizontal then vertical, in that order, because the CPU does — a
        // separable blur is order-independent in exact arithmetic and not quite
        // in floating point.
        guard pass(source, intermediate, horizontal: true),
              pass(intermediate, destination, horizontal: false) else { return nil }

        return Self.mask(width: mask.width, height: mask.height, from: destination)
    }

    /// Copies a result buffer back into a `FloatMask`.
    ///
    /// A copy rather than a borrow: `FloatMask.values` is a Swift array and the
    /// masks are small beside the work that produced them — a megabyte against
    /// twenty million multiply-adds.
    private static func mask(width: Int, height: Int, from buffer: MTLBuffer) -> FloatMask {
        var out = FloatMask(width: width, height: height)
        let byteCount = width * height * MemoryLayout<Float>.stride
        out.values.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(base, buffer.contents(), min(byteCount, raw.count))
        }
        return out
    }


    // MARK: - Frame copy

    /// A byte-for-byte copy of one image into another of the same size, run on
    /// the GPU's copy engine.
    ///
    /// Every swapped frame starts by copying the input over the output, because
    /// the paste is a read-modify-write over the original pixels. At 4K that is
    /// 33 MB of `memcpy` per frame on a core the export loop also wants for
    /// decode and encode. A blit is the same bytes — this is a copy, not
    /// arithmetic, so there is nothing here to round differently — moved off
    /// the CPU.
    ///
    /// Only for frames large enough to pay for the command buffer; below the
    /// threshold `memcpy` wins outright and the CPU path keeps it.
    func copy(_ source: BGRAImage, into destination: BGRAImage) -> Bool {
        guard source.width == destination.width,
              source.height == destination.height,
              source.width * source.height >= Self.minimumCopyPixels,
              let sourceBuffer = source.mtlBuffer,
              let destinationBuffer = destination.mtlBuffer else { return false }

        let rowLength = source.width * 4
        guard rowLength > 0, source.height > 0 else { return false }

        guard let commandBuffer = context.queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeBlitCommandEncoder() else { return false }

        if source.rowBytes == destination.rowBytes, source.rowBytes == rowLength {
            // No padding on either side, so the whole plane is one contiguous
            // run and the copy is a single command.
            let total = rowLength * source.height
            guard sourceBuffer.length >= total, destinationBuffer.length >= total else {
                encoder.endEncoding()
                return false
            }
            encoder.copy(from: sourceBuffer, sourceOffset: 0,
                         to: destinationBuffer, destinationOffset: 0, size: total)
        } else {
            // Padded rows, or two different strides. Copy only the live bytes
            // of each row, exactly as the CPU does — the pad is not part of the
            // image and must not be carried across.
            let lastSource = (source.height - 1) * source.rowBytes + rowLength
            let lastDestination = (source.height - 1) * destination.rowBytes + rowLength
            guard sourceBuffer.length >= lastSource,
                  destinationBuffer.length >= lastDestination else {
                encoder.endEncoding()
                return false
            }
            for y in 0 ..< source.height {
                encoder.copy(from: sourceBuffer, sourceOffset: y * source.rowBytes,
                             to: destinationBuffer, destinationOffset: y * destination.rowBytes,
                             size: rowLength)
            }
        }

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            EngineLog.metal.error(
                "frame copy failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return true
    }

    // MARK: - Encoding

    /// Builds a command buffer for one kernel, dispatches it over a 2-D grid of
    /// destination pixels, and waits.
    private func run(_ function: String,
                     gridWidth: Int,
                     gridHeight: Int,
                     _ configure: (MTLComputeCommandEncoder) -> Void) -> Bool {
        guard gridWidth > 0, gridHeight > 0 else { return false }
        do {
            let state = try context.pipeline(function)
            guard let commandBuffer = context.queue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }

            encoder.setComputePipelineState(state)
            configure(encoder)

            // One SIMD group wide, then as many rows as the threadgroup budget
            // allows.
            let groupWidth = max(1, min(state.threadExecutionWidth, gridWidth))
            let groupHeight = max(1, min(state.maxTotalThreadsPerThreadgroup / groupWidth, gridHeight))
            let group = MTLSize(width: groupWidth, height: groupHeight, depth: 1)

            if context.supportsNonUniformThreadgroups {
                // The grid does not have to be padded: Metal trims the last
                // threadgroup in each dimension for us.
                encoder.dispatchThreads(MTLSize(width: gridWidth, height: gridHeight, depth: 1),
                                        threadsPerThreadgroup: group)
            } else {
                // Round the grid up to whole threadgroups and let the kernels'
                // own bounds checks discard the overhang. Every kernel in
                // `ImageOps.metal` opens with one, which is what makes the two
                // dispatch styles interchangeable rather than merely similar.
                let groupsWide = (gridWidth + groupWidth - 1) / groupWidth
                let groupsHigh = (gridHeight + groupHeight - 1) / groupHeight
                encoder.dispatchThreadgroups(MTLSize(width: groupsWide, height: groupsHigh, depth: 1),
                                             threadsPerThreadgroup: group)
            }
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            if let error = commandBuffer.error {
                EngineLog.metal.error(
                    "\(function, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
            return true
        } catch {
            EngineLog.metal.error(
                "\(function, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Which byte of a BGRA pixel each tensor plane reads. Memory order is
    /// B, G, R, so `.bgr` is the identity and `.rgb` is a swap.
    private static func channelOffsets(_ order: ChannelOrder) -> (UInt32, UInt32, UInt32) {
        order == .bgr ? (0, 1, 2) : (2, 1, 0)
    }
}

// MARK: - Kernel arguments

/// Mirrors of the parameter structs in `ImageOps.metal`.
///
/// Every field is a 4-byte scalar and the order matches the shader exactly.
/// That is the whole reason there are no `SIMD` types here: without a bridging
/// header the two compilers have to be made to agree by construction, and
/// homogeneous 4-byte fields lay out identically under both.

private struct Affine {
    var a: Float
    var b: Float
    var c: Float
    var d: Float
    var tx: Float
    var ty: Float

    init(_ t: CGAffineTransform) {
        a = Float(t.a); b = Float(t.b); c = Float(t.c)
        d = Float(t.d); tx = Float(t.tx); ty = Float(t.ty)
    }
}

private struct BoxReduceParams {
    var srcWidth: UInt32
    var srcHeight: UInt32
    var srcRowBytes: UInt32
    var dstWidth: UInt32
    var dstHeight: UInt32
    var dstRowBytes: UInt32
    var factor: UInt32
    var inverseArea: Float
}

private struct WarpParams {
    var srcWidth: UInt32
    var srcHeight: UInt32
    var srcRowBytes: UInt32
    var dstWidth: UInt32
    var dstHeight: UInt32
    var dstRowBytes: UInt32
    var inverse: Affine
}

private struct WarpTensorParams {
    var srcWidth: UInt32
    var srcHeight: UInt32
    var srcRowBytes: UInt32
    var spanWidth: UInt32
    var spanHeight: UInt32
    var tensorWidth: UInt32
    var tensorHeight: UInt32
    var c0: UInt32
    var c1: UInt32
    var c2: UInt32
    var mean: Float
    var standardDeviation: Float
    var inverse: Affine
}

private struct PackParams {
    var srcWidth: UInt32
    var srcHeight: UInt32
    var srcRowBytes: UInt32
    var spanWidth: UInt32
    var spanHeight: UInt32
    var tensorWidth: UInt32
    var tensorHeight: UInt32
    var c0: UInt32
    var c1: UInt32
    var c2: UInt32
    var mean: Float
    var standardDeviation: Float
}

private struct UnpackParams {
    var width: UInt32
    var height: UInt32
    var dstRowBytes: UInt32
    var c0: UInt32
    var c1: UInt32
    var c2: UInt32
    var mean: Float
    var standardDeviation: Float
}

private struct PasteParams {
    var dstRowBytes: UInt32
    var originX: UInt32
    var originY: UInt32
    var regionWidth: UInt32
    var regionHeight: UInt32
    var patchWidth: UInt32
    var patchHeight: UInt32
    var patchRowBytes: UInt32
    var maskWidth: UInt32
    var maskHeight: UInt32
    var opacity: Float
    var patchInverse: Affine
    var maskInverse: Affine
}

private struct PackHWCParams {
    var width: UInt32
    var height: UInt32
    var srcRowBytes: UInt32
}

private struct MaskWarpParams {
    var srcWidth: UInt32
    var srcHeight: UInt32
    var dstWidth: UInt32
    var dstHeight: UInt32
    var inverse: Affine
}

private struct MaskBlurParams {
    var width: UInt32
    var height: UInt32
    var radius: UInt32
    var horizontal: UInt32
}

/// Uniforms travel by value through `setBytes` rather than in a buffer: they
/// are under a hundred bytes and allocating an `MTLBuffer` per dispatch would
/// cost more than the dispatch.
private func setBytes<T>(_ value: T, on encoder: MTLComputeCommandEncoder, index: Int) {
    withUnsafeBytes(of: value) { raw in
        guard let base = raw.baseAddress else { return }
        encoder.setBytes(base, length: raw.count, index: index)
    }
}

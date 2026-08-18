//
//  ImageBuffer.swift
//  FaceFusionEngine
//
//  Pixel plumbing: affine warps, tensor packing, mask blurring and blending.
//
//  Everything works on 32-bit BGRA, which is what the video pipeline hands us
//  and what IOSurface carries across the XPC boundary. Byte order in memory is
//  B, G, R, A at ascending addresses, so "channel 0" is blue. The reference
//  Python pipeline is built on OpenCV and is likewise BGR-first, which keeps
//  the channel bookkeeping below identical to it.
//
//  Every routine here exists twice. The scalar Swift implementation is the one
//  that was validated against the Python/OpenCV ground truth, and it is kept
//  exactly as it was written; the Metal fast path in front of it is an
//  optimisation that has to agree with it, not a replacement for it. When they
//  disagree, the CPU is right. A Mac without a usable Metal library — or a
//  frame the GPU cannot address, which is any borrowed surface that failed the
//  page-alignment test in `withSurface` — simply falls through and still works.
//
//  This file and the iOS app's copy are the same pixel code deliberately. Only
//  the bridging differs: frames reach this process as an `IOSurface` over XPC
//  rather than as a `CVPixelBuffer` from a decoder. Everything below that
//  boundary — every warp, every tensor pack, every blend — stays identical,
//  because the two platforms are verified against each other.
//

import Foundation
import CoreGraphics
import CoreVideo
import IOSurface
import Metal
import os

/// A mutable 8-bit BGRA image. Either owns its storage or borrows an
/// IOSurface's, in which case the caller keeps the surface locked.
final class BGRAImage {
    let width: Int
    let height: Int
    let rowBytes: Int
    let base: UnsafeMutableRawPointer
    /// Present when the GPU can address these exact bytes. Owned storage always
    /// has one while Metal is available; borrowed storage has one only when the
    /// underlying surface happened to be page-aligned.
    let mtlBuffer: MTLBuffer?
    private let ownsStorage: Bool

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        // Rows are padded to 64 bytes so each one starts on a cache line and
        // the GPU's stores coalesce. Nothing in the pixel code assumes a stride
        // of `width * 4` — it all goes through `rowBytes` — so this is
        // invisible above.
        self.rowBytes = ((width * 4) + 63) / 64 * 64
        let byteCount = max(1, rowBytes * height)

        // Shared storage means the kernels that fill this and the CPU that
        // reads it are looking at the same physical pages: no upload, no
        // download. Without Metal it is a plain aligned allocation.
        if let buffer = MetalContext.shared?.makeBuffer(length: byteCount) {
            self.mtlBuffer = buffer
            self.base = buffer.contents()
            self.ownsStorage = false
        } else {
            self.mtlBuffer = nil
            self.base = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
            self.ownsStorage = true
        }
        memset(base, 0, byteCount)
    }

    init(borrowing base: UnsafeMutableRawPointer, width: Int, height: Int, rowBytes: Int) {
        self.width = width
        self.height = height
        self.rowBytes = rowBytes
        self.base = base
        self.mtlBuffer = nil
        self.ownsStorage = false
    }

    /// As above, but with a GPU view onto the borrowed bytes. Only
    /// `withSurface` builds one of these, because only it knows the surface
    /// stays locked and alive for exactly as long as the image does.
    private init(borrowing base: UnsafeMutableRawPointer,
                 width: Int, height: Int, rowBytes: Int,
                 mtlBuffer: MTLBuffer?) {
        self.width = width
        self.height = height
        self.rowBytes = rowBytes
        self.base = base
        self.mtlBuffer = mtlBuffer
        self.ownsStorage = false
    }

    deinit {
        if ownsStorage { base.deallocate() }
    }

    @inline(__always)
    func row(_ y: Int) -> UnsafeMutablePointer<UInt8> {
        base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
    }

    func copy() -> BGRAImage {
        let out = BGRAImage(width: width, height: height)
        for y in 0 ..< height {
            memcpy(out.row(y), row(y), width * 4)
        }
        return out
    }

    func copyContents(into destination: BGRAImage) {
        precondition(destination.width == width && destination.height == height)

        // A copy, not arithmetic: the blit moves the same bytes the `memcpy`
        // below would, so there is nothing here for the two paths to disagree
        // about. What it buys is the CPU time — 33 MB a frame at 4K — on a core
        // the export loop wants for decode and encode.
        if let ops = MetalImageOps.active, ops.copy(self, into: destination) {
            return
        }

        let bytes = min(width, destination.width) * 4
        for y in 0 ..< height {
            memcpy(destination.row(y), row(y), bytes)
        }
    }
}

// MARK: - IOSurface bridging

extension BGRAImage {

    /// Runs `body` with an image view onto a locked IOSurface.
    ///
    /// Frames arrive here as surfaces sent over XPC, so the pages are already
    /// shared with the app rather than copied. When the surface's base address
    /// is page-aligned and its allocation covers the plane, Metal can be handed
    /// those same pages with `makeBuffer(bytesNoCopy:)` and a frame reaches the
    /// GPU without being copied at all. When the alignment does not hold — and
    /// it is not guaranteed by anything — the image simply has no `mtlBuffer`
    /// and every operation on it takes the CPU path. That is a slower frame,
    /// never a failed one.
    ///
    /// The returned image must not escape `body`: the surface is unlocked on
    /// the way out and the Metal view over it dies with it.
    static func withSurface<T>(_ surface: IOSurface,
                               readOnly: Bool,
                               _ body: (BGRAImage) throws -> T) rethrows -> T {
        let options: IOSurfaceLockOptions = readOnly ? .readOnly : []
        surface.lock(options: options, seed: nil)
        defer { surface.unlock(options: options, seed: nil) }

        let base = surface.baseAddress
        let shared = gpuView(over: base,
                             in: surface,
                             byteCount: surface.bytesPerRow * surface.height)
        return try body(BGRAImage(borrowing: base,
                                  width: surface.width,
                                  height: surface.height,
                                  rowBytes: surface.bytesPerRow,
                                  mtlBuffer: shared))
    }

    private static func gpuView(over base: UnsafeMutableRawPointer,
                                in surface: IOSurface,
                                byteCount: Int) -> MTLBuffer? {
        guard byteCount > 0, let device = MetalContext.shared?.device else { return nil }

        let pageSize = Int(getpagesize())
        guard pageSize > 0, UInt(bitPattern: base) % UInt(pageSize) == 0 else { return nil }

        // Two separate conditions, and conflating them costs the fast path on
        // exactly the frames worth having it for. What must be true is that the
        // surface's allocation covers the plane — that is the memory the kernels
        // read and write. What `bytesNoCopy` wants is a whole number of pages,
        // and `allocationSize` reports the surface's size, not its mapping: a
        // 1080p BGRA surface comes back as the plane plus 64 bytes, which is not
        // page-rounded, while the mapping behind it always is. Rounding the
        // length up is therefore safe, and testing the *rounded* length against
        // the alloc size would reject nearly every real frame.
        guard surface.allocationSize >= byteCount else { return nil }
        let length = (byteCount + pageSize - 1) / pageSize * pageSize

        // No deallocator: the surface owns these pages and outlives the buffer,
        // which lives only for the duration of `withSurface`.
        return device.makeBuffer(bytesNoCopy: base,
                                 length: length,
                                 options: .storageModeShared,
                                 deallocator: nil)
    }

    /// A fresh surface for the engine to render a swapped frame into.
    ///
    /// Left to IOSurface's own allocator rather than routed through
    /// `MetalContext`: this one has to cross back to the app, and a surface is
    /// the only thing that does. It comes back page-aligned in practice, so
    /// `withSurface` hands it to the GPU anyway.
    static func makeSurface(width: Int, height: Int) -> IOSurface? {
        IOSurface(properties: [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ])
    }
}

// MARK: - Warping

extension BGRAImage {

    /// Renders this image into a new buffer under `transform`, which maps
    /// source coordinates to destination coordinates — the same convention as
    /// `cv2.warpAffine`. Sampling is bilinear with edge replication.
    ///
    /// Face crops are a large downscale — aligning a 1024px portrait to a
    /// 112px ArcFace input is a ~7x reduction — and a bare bilinear tap reads
    /// only 2x2 source pixels, so it aliases badly: neighbouring frames sample
    /// different high-frequency detail and the result shimmers. Anything
    /// shrinking by more than half is therefore box-reduced first, which is
    /// the standard mipmap prefilter.
    ///
    /// Left exactly as it was written, because this is the function whose
    /// output was compared against the Python reference. Its two steps —
    /// `boxReduced` and `drawWarped` — each take the GPU on their own when they
    /// can, so this gets the fast path without any of it being restructured.
    func warped(by transform: CGAffineTransform,
                width outWidth: Int,
                height outHeight: Int) -> BGRAImage {
        let scale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))

        if scale < 0.5, scale > 0 {
            let factor = min(max(Int((1.0 / scale).rounded(.down)), 2), 16)
            if width / factor >= 2, height / factor >= 2 {
                let reduced = boxReduced(by: factor)
                // Points now arrive pre-divided by `factor`, so scale back up
                // before applying the original mapping.
                let adjusted = CGAffineTransform(scaleX: CGFloat(factor), y: CGFloat(factor))
                    .concatenating(transform)
                let out = BGRAImage(width: outWidth, height: outHeight)
                reduced.drawWarped(into: out, transform: adjusted)
                return out
            }
        }

        let out = BGRAImage(width: outWidth, height: outHeight)
        drawWarped(into: out, transform: transform)
        return out
    }

    /// Averages each `factor` x `factor` block into one pixel.
    func boxReduced(by factor: Int) -> BGRAImage {
        precondition(factor >= 2)

        if let ops = MetalImageOps.active, mtlBuffer != nil,
           let reduced = ops.boxReduce(self, factor: factor) {
            return reduced
        }

        let outWidth = max(1, width / factor)
        let outHeight = max(1, height / factor)
        let out = BGRAImage(width: outWidth, height: outHeight)
        let inverseArea = 1.0 / Float(factor * factor)

        DispatchQueue.concurrentPerform(iterations: outHeight) { oy in
            let dst = out.row(oy)
            for ox in 0 ..< outWidth {
                var sums = SIMD4<Float>(repeating: 0)
                for dy in 0 ..< factor {
                    let src = self.row(min(oy * factor + dy, self.height - 1))
                    for dx in 0 ..< factor {
                        let sx = min(ox * factor + dx, self.width - 1) * 4
                        sums += SIMD4<Float>(Float(src[sx]), Float(src[sx + 1]),
                                             Float(src[sx + 2]), Float(src[sx + 3]))
                    }
                }
                sums *= inverseArea
                for c in 0 ..< 4 {
                    dst[ox * 4 + c] = UInt8(min(max(sums[c].rounded(), 0), 255))
                }
            }
        }
        return out
    }

    /// As `warped(by:width:height:)` but writes into an existing buffer.
    func drawWarped(into out: BGRAImage, transform: CGAffineTransform) {
        if let ops = MetalImageOps.active, mtlBuffer != nil, out.mtlBuffer != nil,
           ops.warp(self, into: out, transform: transform) {
            return
        }

        // Sampling is destination-driven, so invert to go dst -> src.
        let inverse = transform.inverted()
        let srcMaxX = Float(width - 1)
        let srcMaxY = Float(height - 1)

        let ia = Float(inverse.a), ib = Float(inverse.b)
        let ic = Float(inverse.c), id = Float(inverse.d)
        let itx = Float(inverse.tx), ity = Float(inverse.ty)

        let srcBase = base
        let srcRowBytes = rowBytes
        let outRowBytes = out.rowBytes
        let outBase = out.base
        let outWidth = out.width

        let work = { (y: Int) in
            let fy = Float(y) + 0.5
            let dst = outBase.advanced(by: y * outRowBytes)
                .assumingMemoryBound(to: UInt8.self)

            for x in 0 ..< outWidth {
                let fx = Float(x) + 0.5
                // Pixel centres: sample at (x+0.5) then shift back by half a
                // pixel, matching OpenCV's integer-grid convention.
                var sx = ia * fx + ic * fy + itx - 0.5
                var sy = ib * fx + id * fy + ity - 0.5

                sx = min(max(sx, 0), srcMaxX)
                sy = min(max(sy, 0), srcMaxY)

                let x0 = Int(sx), y0 = Int(sy)
                let x1 = min(x0 + 1, Int(srcMaxX))
                let y1 = min(y0 + 1, Int(srcMaxY))
                let wx = sx - Float(x0)
                let wy = sy - Float(y0)

                let r0 = srcBase.advanced(by: y0 * srcRowBytes).assumingMemoryBound(to: UInt8.self)
                let r1 = srcBase.advanced(by: y1 * srcRowBytes).assumingMemoryBound(to: UInt8.self)
                let i00 = x0 * 4, i01 = x1 * 4

                let w00 = (1 - wx) * (1 - wy)
                let w10 = wx * (1 - wy)
                let w01 = (1 - wx) * wy
                let w11 = wx * wy

                for c in 0 ..< 4 {
                    let v = Float(r0[i00 + c]) * w00
                          + Float(r0[i01 + c]) * w10
                          + Float(r1[i00 + c]) * w01
                          + Float(r1[i01 + c]) * w11
                    dst[x * 4 + c] = UInt8(min(max(v.rounded(), 0), 255))
                }
            }
        }

        if out.height >= 64 {
            DispatchQueue.concurrentPerform(iterations: out.height, execute: work)
        } else {
            for y in 0 ..< out.height { work(y) }
        }
    }

    /// Proportional downscale so the result fits inside `limit`. Never upscales,
    /// mirroring the reference pipeline's `restrict_frame`.
    func restricted(to limit: Int) -> (image: BGRAImage, scale: CGFloat) {
        guard width > limit || height > limit else { return (self, 1) }
        let scale = min(CGFloat(limit) / CGFloat(width), CGFloat(limit) / CGFloat(height))
        let newWidth = max(1, Int(CGFloat(width) * scale))
        let newHeight = max(1, Int(CGFloat(height) * scale))
        let transform = CGAffineTransform(scaleX: CGFloat(newWidth) / CGFloat(width),
                                          y: CGFloat(newHeight) / CGFloat(height))
        return (warped(by: transform, width: newWidth, height: newHeight), scale)
    }
}

// MARK: - Tensor packing

/// Which order the three colour channels are written into a tensor.
enum ChannelOrder {
    /// Blue, green, red — the in-memory order.
    case bgr
    /// Red, green, blue — what most ImageNet-lineage models expect.
    case rgb
}

extension BGRAImage {

    /// Packs the image into a `1 x 3 x H x W` float tensor.
    /// Each channel becomes `(value / 255 - mean) / standardDeviation`.
    func tensorCHW(order: ChannelOrder,
                   mean: Float = 0,
                   standardDeviation: Float = 1,
                   padTo padded: (width: Int, height: Int)? = nil) -> FloatTensor {
        if let ops = MetalImageOps.active, mtlBuffer != nil,
           let tensor = ops.packTensor(self, order: order, mean: mean,
                                       standardDeviation: standardDeviation, padTo: padded) {
            return tensor
        }

        let outWidth = padded?.width ?? width
        let outHeight = padded?.height ?? height
        let plane = outWidth * outHeight
        var values = [Float](repeating: 0, count: 3 * plane)

        // Channel c of the tensor reads byte offset `offsets[c]` of each pixel.
        let offsets: [Int] = (order == .bgr) ? [0, 1, 2] : [2, 1, 0]
        let invScale: Float = 1.0 / 255.0

        values.withUnsafeMutableBufferPointer { out in
            for y in 0 ..< min(height, outHeight) {
                let src = row(y)
                for x in 0 ..< min(width, outWidth) {
                    let pixel = x * 4
                    for c in 0 ..< 3 {
                        let raw = Float(src[pixel + offsets[c]]) * invScale
                        out[c * plane + y * outWidth + x] = (raw - mean) / standardDeviation
                    }
                }
            }
        }
        return FloatTensor(shape: [1, 3, outHeight, outWidth], values: values)
    }

    /// Warps straight into a normalised CHW tensor, which is what every model
    /// in the pipeline actually wants. Fusing the two steps skips a full BGRA
    /// crop per model invocation — five of them per face per frame.
    ///
    /// The GPU path is one kernel, preceded by the same integer box-prefilter
    /// `warped` applies when a transform shrinks by more than half. Two steps,
    /// same factor, same numbers. The CPU path is literally `warped` followed by
    /// `tensorCHW`, so the fused version has something exact to be checked
    /// against.
    func warpedTensor(by transform: CGAffineTransform,
                      width outWidth: Int,
                      height outHeight: Int,
                      order: ChannelOrder,
                      mean: Float = 0,
                      standardDeviation: Float = 1,
                      padTo padded: (width: Int, height: Int)? = nil) -> FloatTensor {
        if let ops = MetalImageOps.active, mtlBuffer != nil {
            let (source, adjusted) = ops.boxPrefiltered(self, for: transform)
            if let tensor = ops.warpToTensor(source, transform: adjusted,
                                             width: outWidth, height: outHeight,
                                             order: order, mean: mean,
                                             standardDeviation: standardDeviation,
                                             padTo: padded) {
                return tensor
            }
        }

        let crop = warped(by: transform, width: outWidth, height: outHeight)
        return crop.tensorCHW(order: order, mean: mean,
                              standardDeviation: standardDeviation, padTo: padded)
    }

    /// Inverse of `tensorCHW`. Values are denormalised, clamped to 0...1 and
    /// written as opaque BGRA.
    static func fromTensorCHW(_ tensor: FloatTensor,
                              order: ChannelOrder,
                              mean: Float = 0,
                              standardDeviation: Float = 1) -> BGRAImage {
        if let ops = MetalImageOps.active,
           let image = ops.unpackTensor(tensor, order: order, mean: mean,
                                        standardDeviation: standardDeviation) {
            return image
        }

        // Shape is [1, 3, H, W]; tolerate a missing batch dimension.
        let dims = tensor.shape.count == 4 ? Array(tensor.shape.dropFirst()) : tensor.shape
        let height = dims[1], width = dims[2]
        let plane = width * height
        let image = BGRAImage(width: width, height: height)
        let offsets: [Int] = (order == .bgr) ? [0, 1, 2] : [2, 1, 0]

        // `FloatTensor.values` is an `UnsafeMutableBufferPointer` now, so the
        // reference's `withUnsafeBufferPointer` wrapper has nothing to attach
        // to; the loop it wrapped is otherwise unchanged.
        let src = tensor.values
        for y in 0 ..< height {
            let dst = image.row(y)
            for x in 0 ..< width {
                let pixel = x * 4
                for c in 0 ..< 3 {
                    let v = src[c * plane + y * width + x] * standardDeviation + mean
                    dst[pixel + offsets[c]] = UInt8(min(max(v, 0), 1) * 255 + 0.5)
                }
                dst[pixel + 3] = 255
            }
        }
        return image
    }
}

// MARK: - Masks

/// Somewhere for a mask's GPU mirror to live.
///
/// A reference, so that a mask handed out of `FaceMasker`'s cache — by value,
/// as a struct — carries the upload it already paid for instead of copying a
/// megabyte of floats for every face of every frame. `@unchecked Sendable` with
/// a lock inside, because `FloatMask` has to stay `Sendable` for that cache to
/// compile and several export frames touch the same mask at once.
final class MaskGPUStorage: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<MTLBuffer?>(uncheckedState: nil)

    var buffer: MTLBuffer? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// A single-channel float mask in 0...1.
struct FloatMask {
    var width: Int
    var height: Int
    var values: [Float]

    /// Replaced rather than emptied whenever `values` changes, so a copy taken
    /// before the change keeps its own mirror and cannot be blended from the
    /// wrong floats. The trap this leaves is writing through `values` from
    /// outside — only the mask builder does that, and only before anything has
    /// been uploaded.
    private var storage = MaskGPUStorage()

    /// The mask's floats in GPU-addressable memory, filled in on first use by
    /// `MetalImageOps`. Masks themselves stay on the CPU: they are built at
    /// most a handful of times per session and then cached.
    var gpuBuffer: MTLBuffer? {
        get { storage.buffer }
        nonmutating set { storage.buffer = newValue }
    }

    init(width: Int, height: Int, repeating value: Float = 0) {
        self.width = width
        self.height = height
        self.values = [Float](repeating: value, count: width * height)
    }

    /// Element-wise minimum, used to combine independently computed masks.
    mutating func intersect(with other: FloatMask) {
        guard other.width == width, other.height == height else { return }
        for i in 0 ..< values.count { values[i] = min(values[i], other.values[i]) }
        storage = MaskGPUStorage()
    }

    mutating func clamp01() {
        for i in 0 ..< values.count { values[i] = min(max(values[i], 0), 1) }
        storage = MaskGPUStorage()
    }

    /// Separable Gaussian blur. Kernel radius follows OpenCV's rule for a
    /// float image when `ksize` is zero: `round(sigma * 4 * 2 + 1) | 1`.
    func blurred(sigma: Float) -> FloatMask {
        guard sigma > 0 else { return self }
        var size = Int((sigma * 8 + 1).rounded())
        if size % 2 == 0 { size += 1 }
        let radius = size / 2
        guard radius >= 1 else { return self }

        var kernel = [Float](repeating: 0, count: size)
        let denominator = 2 * sigma * sigma
        var total: Float = 0
        for i in 0 ..< size {
            let d = Float(i - radius)
            let v = expf(-(d * d) / denominator)
            kernel[i] = v
            total += v
        }
        for i in 0 ..< size { kernel[i] /= total }

        // Comfortably the most expensive thing left on the CPU per frame: the
        // restorer's 512x512 mask at the default feather is a ~150-tap kernel
        // in each direction. The weights are handed over rather than recomputed
        // so both paths use the same coefficients to the bit.
        if let ops = MetalImageOps.active,
           let fast = ops.blurMask(self, weights: kernel, radius: radius) {
            return fast
        }

        var horizontal = [Float](repeating: 0, count: values.count)
        for y in 0 ..< height {
            for x in 0 ..< width {
                var sum: Float = 0
                for k in 0 ..< size {
                    let sx = min(max(x + k - radius, 0), width - 1)
                    sum += values[y * width + sx] * kernel[k]
                }
                horizontal[y * width + x] = sum
            }
        }

        var out = FloatMask(width: width, height: height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                var sum: Float = 0
                for k in 0 ..< size {
                    let sy = min(max(y + k - radius, 0), height - 1)
                    sum += horizontal[sy * width + x] * kernel[k]
                }
                out.values[y * width + x] = sum
            }
        }
        return out
    }

    /// Warps the mask with the same conventions as `BGRAImage.drawWarped`,
    /// sampling bilinearly and clamping at the edges.
    func warped(by transform: CGAffineTransform, width outWidth: Int, height outHeight: Int) -> FloatMask {
        if let ops = MetalImageOps.active,
           let fast = ops.warpMask(self, transform: transform,
                                   width: outWidth, height: outHeight) {
            return fast
        }

        var out = FloatMask(width: outWidth, height: outHeight)
        let inverse = transform.inverted()
        let maxX = Float(width - 1), maxY = Float(height - 1)
        let ia = Float(inverse.a), ib = Float(inverse.b)
        let ic = Float(inverse.c), id = Float(inverse.d)
        let itx = Float(inverse.tx), ity = Float(inverse.ty)

        for y in 0 ..< outHeight {
            let fy = Float(y) + 0.5
            for x in 0 ..< outWidth {
                let fx = Float(x) + 0.5
                var sx = ia * fx + ic * fy + itx - 0.5
                var sy = ib * fx + id * fy + ity - 0.5
                sx = min(max(sx, 0), maxX)
                sy = min(max(sy, 0), maxY)

                let x0 = Int(sx), y0 = Int(sy)
                let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
                let wx = sx - Float(x0), wy = sy - Float(y0)

                let v = values[y0 * width + x0] * (1 - wx) * (1 - wy)
                      + values[y0 * width + x1] * wx * (1 - wy)
                      + values[y1 * width + x0] * (1 - wx) * wy
                      + values[y1 * width + x1] * wx * wy
                out.values[y * outWidth + x] = v
            }
        }
        return out
    }
}

// MARK: - Compositing

extension BGRAImage {

    /// Warps `patch` back into this image through the inverse of `transform`,
    /// blending with `mask` (defined in patch space).
    ///
    /// Only the region the patch actually lands in is touched, so cost scales
    /// with face size rather than frame size.
    func pasteBack(patch: BGRAImage,
                   mask: FloatMask,
                   transform: CGAffineTransform,
                   opacity: Float = 1.0) {
        // The one read-modify-write in the pipeline, so the GPU path is written
        // to leave the destination untouched unless it can finish the whole
        // blend; a half-applied composite followed by the CPU redoing it would
        // blend the same patch in twice.
        if let ops = MetalImageOps.active, mtlBuffer != nil, patch.mtlBuffer != nil,
           ops.pasteBack(into: self, patch: patch, mask: mask,
                         transform: transform, opacity: opacity) {
            return
        }

        let inverse = transform.inverted()
        let bounds = Geometry.transformedBounds(width: patch.width,
                                                height: patch.height,
                                                by: inverse)

        let x1 = max(0, Int(bounds.minX.rounded(.down)))
        let y1 = max(0, Int(bounds.minY.rounded(.down)))
        let x2 = min(width, Int(bounds.maxX.rounded(.up)))
        let y2 = min(height, Int(bounds.maxY.rounded(.up)))
        guard x2 > x1, y2 > y1 else { return }

        let regionWidth = x2 - x1, regionHeight = y2 - y1

        // Shift the inverse so it renders directly into the region's origin.
        var pasteTransform = inverse
        pasteTransform.tx -= CGFloat(x1)
        pasteTransform.ty -= CGFloat(y1)

        let warpedPatch = patch.warped(by: pasteTransform,
                                       width: regionWidth, height: regionHeight)
        let warpedMask = mask.warped(by: pasteTransform,
                                     width: regionWidth, height: regionHeight)

        for ry in 0 ..< regionHeight {
            let dst = row(y1 + ry)
            let src = warpedPatch.row(ry)
            for rx in 0 ..< regionWidth {
                let alpha = min(max(warpedMask.values[ry * regionWidth + rx], 0), 1) * opacity
                guard alpha > 0.001 else { continue }
                let di = (x1 + rx) * 4
                let si = rx * 4
                for c in 0 ..< 3 {
                    let blended = Float(dst[di + c]) * (1 - alpha) + Float(src[si + c]) * alpha
                    dst[di + c] = UInt8(min(max(blended.rounded(), 0), 255))
                }
            }
        }
    }
}

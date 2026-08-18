//
//  MetalContext.swift
//  FaceFusionEngine
//
//  The one Metal device, queue and shader library for the process.
//
//  Everything that touches the GPU goes through this: the compute kernels in
//  `MetalImageOps`, the shared-storage buffers behind `BGRAImage` and the ones
//  behind `TensorBuffer`. Having a single owner matters less for tidiness than
//  for memory — an `MTLDevice` and its command queue are process-wide resources
//  and building a second one per frame would be both slow and pointless.
//
//  This lives in the XPC service, not the app. The service is where the pixels
//  are, and a sandboxed XPC service reaches the GPU without any entitlement of
//  its own — Metal is not one of the things the sandbox takes away. What it
//  does take away is the window server, so nothing here may ever touch a
//  drawable or a layer; compute only.
//
//  `shared` is optional, and `nil` is not an error. A Mac with no usable Metal,
//  or a build where the shader library failed to make it into the bundle, falls
//  back to the CPU implementations in `ImageBuffer.swift`, which are the
//  validated ones anyway. The engine still works; it is just slower.
//

import Foundation
import Metal
import os

final class MetalContext {

    /// Built once, lazily, on first use. `let` on a `static` in Swift is
    /// initialised atomically, so several frames racing in here get one context.
    static let shared: MetalContext? = MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue

    /// Optional on purpose. If `default.metallib` is missing the buffers are
    /// still worth having — a shared-storage allocation costs nothing extra and
    /// keeps `TensorBuffer` zero-copy — even though no kernel can run.
    let library: MTLLibrary?

    /// Whether `dispatchThreads` may be used instead of a padded threadgroup
    /// count. Every Mac that runs macOS 14 should say yes; the fallback exists
    /// because this target also builds for x86_64 and the kernels bounds-check
    /// either way, so honouring the answer costs one branch per dispatch and
    /// removes a whole class of "works on my Apple Silicon" failure.
    let supportsNonUniformThreadgroups: Bool

    /// Compiling a compute pipeline takes milliseconds, so they are built once
    /// and kept. Several export frames encode concurrently, hence the lock;
    /// `MTLComputePipelineState` is not `Sendable`, hence `uncheckedState`.
    private let pipelines = OSAllocatedUnfairLock(uncheckedState: [String: MTLComputePipelineState]())

    /// Buffers are rounded up to this so `contents()` comes back page-aligned.
    /// Metal is free to sub-allocate anything smaller out of a heap, and a
    /// borrowed pointer that is not page-aligned cannot be wrapped with
    /// `makeBuffer(bytesNoCopy:)` later.
    private static let pageSize = Int(getpagesize())

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.library = Self.loadLibrary(device)
        self.supportsNonUniformThreadgroups =
            device.supportsFamily(.apple4) || device.supportsFamily(.mac2)

        if library == nil {
            EngineLog.metal.error("Metal shader library unavailable — pixel work stays on the CPU")
        } else {
            EngineLog.metal.notice("Metal ready on \(device.name, privacy: .public)")
        }
    }

    /// The shader library that shipped beside this class.
    ///
    /// `makeDefaultLibrary()` resolves against `Bundle.main`, which is the
    /// wrong bundle in exactly one situation and it is the one that matters:
    /// under `xcodebuild test` the main bundle is the
    /// *host app*, while the compiled kernels are in the test bundle beside the
    /// engine sources — so every parity test would find no library, fall back
    /// to the CPU on both sides of the comparison, and pass without ever having
    /// run a kernel. So the bundle is named
    /// explicitly, from the class itself, and `makeDefaultLibrary()` is kept
    /// only as a fallback for anything that manages to load this code from
    /// somewhere without a resource bundle of its own.
    private static func loadLibrary(_ device: MTLDevice) -> MTLLibrary? {
        if let library = try? device.makeDefaultLibrary(bundle: Bundle(for: MetalContext.self)) {
            return library
        }
        return device.makeDefaultLibrary()
    }

    /// Shared storage: on Apple Silicon the CPU and GPU address the same
    /// physical pages, so a buffer written by a kernel needs no download before
    /// ONNX Runtime or a `memcpy` reads it.
    ///
    /// On an Intel Mac with a discrete GPU "shared" means system memory the GPU
    /// reaches over PCIe rather than the same pages, so the copy the design
    /// exists to avoid comes back as bus traffic. That is still correct, and
    /// still no worse than the CPU path it replaces, which is why there is no
    /// second allocation strategy here.
    func makeBuffer(length: Int) -> MTLBuffer? {
        guard length > 0 else { return nil }
        let page = Self.pageSize
        let rounded = (length + page - 1) / page * page
        return device.makeBuffer(length: rounded, options: .storageModeShared)
    }

    /// Cached compute pipeline for a kernel in `ImageOps.metal`.
    ///
    /// Two threads asking for the same uncached function will both compile it;
    /// that is a wasted millisecond once, not a correctness problem, and it is
    /// cheaper than holding the lock across a compile.
    func pipeline(_ function: String) throws -> MTLComputePipelineState {
        if let cached = pipelines.withLock({ $0[function] }) { return cached }

        guard let library, let kernel = library.makeFunction(name: function) else {
            throw makeEngineNSError(.inferenceFailed,
                                    underlying: "no Metal function named '\(function)'")
        }
        let state = try device.makeComputePipelineState(function: kernel)
        pipelines.withLock { $0[function] = state }
        return state
    }
}

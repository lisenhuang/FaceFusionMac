//
//  ORTRuntime.swift
//  FaceFusionEngine
//
//  A thin, Swift-shaped wrapper over the ONNX Runtime Objective-C API.
//
//  ONNX Runtime is linked statically into this XPC service, so nothing has to
//  be installed on the user's machine. Inference is dispatched to the Core ML
//  execution provider, which in turn hands work to the Neural Engine or GPU;
//  whatever Core ML cannot absorb falls back to ORT's own CPU kernels.
//
//  Where a tensor's bytes live is the thing to understand here, and everything
//  downstream depends on it. A `FloatTensor` used to be a `[Float]` that got
//  memcpy'd into a fresh `NSMutableData` on every `run`, and the result copied
//  back out into another array. Now the bytes are allocated once, out of a
//  shared-storage `MTLBuffer` whenever Metal is available — so the compute
//  kernel that fills a tensor and ONNX Runtime that reads it address the same
//  physical pages. On Apple Silicon there is no upload, no download and no copy
//  anywhere on the hot path, only a pointer handed from one consumer to the
//  next. This is the iOS app's design ported back; the two are one pipeline.
//

import Foundation
import Metal
import OnnxRuntimeBindings
import os

// MARK: - Tensor storage

/// An `NSMutableData` that borrows bytes it does not own.
///
/// This exists because ONNX Runtime's Objective-C surface only accepts tensor
/// data as `NSMutableData`, and none of Foundation's constructors will wrap
/// foreign memory in a *mutable* data without copying it: both
/// `init(bytesNoCopy:length:freeWhenDone:)` and the deallocator variant hand
/// back an object whose `mutableBytes` is a different address, because a
/// resizable data has to own its buffer. Verified, not assumed — the copy is
/// silent, and discovering it by way of a session reading stale pixels would
/// be a bad afternoon.
///
/// `NSMutableData` is a class cluster and is explicitly documented as
/// subclassable by overriding its primitives, which is all this does. ORT asks
/// for `length` and `mutableBytes` and nothing else.
private final class BorrowedTensorData: NSMutableData {
    private let base: UnsafeMutableRawPointer
    private let byteCount: Int

    init(bytes: UnsafeMutableRawPointer, byteCount: Int) {
        self.base = bytes
        self.byteCount = byteCount
        super.init()
    }

    required init?(coder: NSCoder) { nil }   // never archived

    override var length: Int {
        get { byteCount }
        // The buffer is fixed size and outlives this object; resizing it is
        // not something any caller on this path does, so refuse quietly rather
        // than reallocate behind the owner's back.
        set { }
    }

    override var bytes: UnsafeRawPointer { UnsafeRawPointer(base) }

    override var mutableBytes: UnsafeMutableRawPointer { base }
}

/// Backing store for a dense float tensor.
///
/// Allocated out of an `MTLBuffer` with shared storage whenever Metal is
/// available, which on Apple Silicon means the GPU kernels that fill it and the
/// CPU that hands it to ONNX Runtime address the *same* physical pages — no
/// upload, no download, no copy. Falls back to a plain aligned allocation when
/// Metal is not usable, in which case the pipeline's CPU paths fill it instead
/// and nothing else changes.
///
/// The bytes are always zeroed on allocation. That is not tidiness: the GPU
/// warp-into-tensor kernel relies on it, writing only the region it covers and
/// leaving a letterbox pad at zero, which is what the detector expects.
final class TensorBuffer {
    let count: Int
    let pointer: UnsafeMutablePointer<Float>
    let mtlBuffer: MTLBuffer?
    /// A zero-copy `NSMutableData` view, retained so ORT can borrow it.
    let data: NSMutableData

    /// 64 bytes is a cache line and matches the row alignment `BGRAImage` uses
    /// for its own storage, so vectorised fills stay aligned.
    private static let fallbackAlignment = 64

    init(count: Int) {
        // A zero-element tensor has no legal Metal allocation and no useful
        // pointer, so one element is always reserved; `count` still reports
        // what the caller asked for.
        let elements = max(count, 1)
        let byteCount = elements * MemoryLayout<Float>.stride

        if let buffer = MetalContext.shared?.makeBuffer(length: byteCount),
           buffer.length >= byteCount {
            self.mtlBuffer = buffer
            self.pointer = buffer.contents().initializeMemory(as: Float.self,
                                                              repeating: 0, count: elements)
        } else {
            self.mtlBuffer = nil
            let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount,
                                                       alignment: Self.fallbackAlignment)
            self.pointer = raw.initializeMemory(as: Float.self, repeating: 0, count: elements)
        }

        self.count = count
        self.data = BorrowedTensorData(bytes: UnsafeMutableRawPointer(pointer),
                                       byteCount: count * MemoryLayout<Float>.stride)
    }

    deinit {
        // Metal owns the pages it lent us; only the fallback allocation is
        // ours to give back. `Float` is trivial, so there is nothing to
        // deinitialise first.
        if mtlBuffer == nil {
            UnsafeMutableRawPointer(pointer).deallocate()
        }
    }
}

/// A dense float tensor moving in or out of a session.
///
/// A struct with reference storage, deliberately: passing a `FloatTensor`
/// around is cheap and never duplicates several megabytes of pixels, but two
/// copies of the same value share their bytes. Nothing in the pipeline mutates
/// a tensor someone else is still reading, and making this a value type would
/// mean copying the very buffer the whole design exists to avoid copying.
struct FloatTensor {
    var shape: [Int]
    let storage: TensorBuffer

    /// The tensor's elements. An `UnsafeMutableBufferPointer` rather than an
    /// `[Float]` so that the storage can be the Metal buffer; it still
    /// subscripts, iterates, counts and maps like an array, and code that
    /// genuinely needs an `Array` writes `Array(tensor.values)`.
    var values: UnsafeMutableBufferPointer<Float> {
        UnsafeMutableBufferPointer(start: storage.pointer, count: storage.count)
    }

    var count: Int { storage.count }

    /// Zero-filled, sized from the shape.
    init(shape: [Int]) {
        self.shape = shape
        self.storage = TensorBuffer(count: shape.reduce(1, *))
    }

    /// Copies an existing array in. Sized from `values`, so a shape that does
    /// not describe the data is caught by `ORTModel.run` rather than being
    /// handed to ORT as a length mismatch.
    init(shape: [Int], values source: [Float]) {
        self.shape = shape
        self.storage = TensorBuffer(count: source.count)
        source.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            storage.pointer.update(from: base, count: source.count)
        }
    }

    init(shape: [Int], repeating value: Float) {
        self.shape = shape
        self.storage = TensorBuffer(count: shape.reduce(1, *))
        if value != 0 {
            storage.pointer.update(repeating: value, count: storage.count)
        }
    }
}

/// The stdlib gives `Array` a `withUnsafeBufferPointer` but does not give one
/// to `UnsafeMutableBufferPointer`, which is the only thing standing between
/// the ported pixel code and compiling unchanged against `FloatTensor.values`.
/// It is a pure re-wrapping of a pointer the caller already holds.
extension UnsafeMutableBufferPointer {
    @inlinable
    func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<Element>) throws -> R) rethrows -> R {
        try body(UnsafeBufferPointer(self))
    }

    @inlinable
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(self))
    }
}

// MARK: - One loaded graph

/// One loaded ONNX graph.
final class ORTModel {
    let id: ModelID
    let session: ORTSession
    let inputNames: [String]
    let outputNames: [String]

    init(id: ModelID, session: ORTSession) throws {
        self.id = id
        self.session = session
        self.inputNames = try session.inputNames()
        self.outputNames = try session.outputNames()
    }

    /// Runs the graph.
    ///
    /// Inputs are **borrowed, not copied**: `ORTValue(tensorData:…)` calls
    /// `mutableBytes` on the data and hands that raw pointer to ORT, which
    /// reads through it for the whole of `run`. The `NSMutableData` here owns
    /// nothing — the pages belong to the `TensorBuffer`, and the `ORTValue`
    /// retaining the data is therefore *not* enough to keep them alive. Hence
    /// `withExtendedLifetime(inputs)` around the call: without it, ARC is free
    /// to release the last reference to a temporary tensor after the last
    /// mention of it, which is before ORT has read a single byte.
    func run(_ inputs: [String: FloatTensor],
             outputs requested: [String]? = nil) throws -> [String: FloatTensor] {
        var ortInputs: [String: ORTValue] = [:]
        ortInputs.reserveCapacity(inputs.count)

        for (name, tensor) in inputs {
            let volume = tensor.shape.reduce(1, *)
            guard volume == tensor.count else {
                throw makeEngineNSError(.inferenceFailed,
                                        underlying: "input \(name) shape \(tensor.shape) describes \(volume) elements but the buffer holds \(tensor.count)")
            }
            ortInputs[name] = try ORTValue(tensorData: tensor.storage.data,
                                           elementType: .float,
                                           shape: tensor.shape.map { NSNumber(value: $0) })
        }

        let wanted = requested ?? outputNames
        let results = try withExtendedLifetime(inputs) {
            try session.run(withInputs: ortInputs,
                            outputNames: Set(wanted),
                            runOptions: nil)
        }

        var decoded: [String: FloatTensor] = [:]
        for name in wanted {
            guard let value = results[name] else { continue }
            decoded[name] = try Self.floats(from: value)
        }
        return decoded
    }

    /// Reads an output tensor back as float32, widening float16 when a graph
    /// hands one back.
    ///
    /// Outputs are the one place a copy is unavoidable: the bytes belong to
    /// ORT's allocator and die with the `ORTValue`, so they move once into a
    /// fresh `TensorBuffer` that the pipeline — and the GPU — can then use
    /// directly.
    private static func floats(from value: ORTValue) throws -> FloatTensor {
        let info = try value.tensorTypeAndShapeInfo()
        let shape = info.shape.map(\.intValue)
        let data = try value.tensorData()
        let elementCount = shape.reduce(1, *)

        // ONNX TensorProto.DataType: 1 = FLOAT, 10 = FLOAT16. The Objective-C
        // enum has no float16 case, so compare raw values.
        let onnxFloat16: Int32 = 10

        if info.elementType == .float {
            let tensor = FloatTensor(shape: shape)
            memcpy(tensor.storage.pointer, data.bytes,
                   min(data.length, elementCount * MemoryLayout<Float>.size))
            return tensor
        }

        if info.elementType.rawValue == onnxFloat16 {
            // Staged through an array rather than read in place: `data.bytes`
            // carries no alignment guarantee for a 16-bit load, and this is
            // the shape the Mac implementation was validated in.
            var halves = [UInt16](repeating: 0, count: elementCount)
            halves.withUnsafeMutableBytes {
                guard let destination = $0.baseAddress else { return }
                _ = memcpy(destination, data.bytes, min(data.length, elementCount * 2))
            }
            let tensor = FloatTensor(shape: shape)
            let out = tensor.values
            for index in 0 ..< min(elementCount, out.count) {
                out[index] = Float(float16Bits: halves[index])
            }
            return tensor
        }

        throw makeEngineNSError(.inferenceFailed,
                                underlying: "unsupported output element type \(info.elementType.rawValue)")
    }
}

// MARK: - The runtime

/// Owns the ORT environment and every loaded model.
final class ORTRuntime {

    /// ONNX Runtime treats its environment as a process-wide singleton — it
    /// owns the shared thread pools and logging sink. Constructing more than
    /// one per process is unsupported and misbehaves, so all runtimes share it.
    private static let sharedEnv: Result<ORTEnv, Error> = {
        do { return .success(try ORTEnv(loggingLevel: ProcessInfo.processInfo.arguments.contains("--profile") ? .verbose : .warning)) }
        catch { return .failure(error) }
    }()

    private let env: ORTEnv

    /// Sessions per model. A list rather than one session because the enhancer
    /// is replicated: see `load`.
    private var models: [ModelID: [ORTModel]] = [:]

    private(set) var coreMLActive = false
    private(set) var providerDescription = "CPU"

    private var announcedCacheDirectory = false

    init() throws {
        env = try Self.sharedEnv.get()
    }

    /// The first session for a model, which is all any single-threaded caller
    /// needs.
    func model(_ id: ModelID) -> ORTModel? { models[id]?.first }

    /// Every session loaded for a model, so a caller that runs several frames
    /// at once can spread them across replicas instead of queueing on one.
    func models(_ id: ModelID) -> [ORTModel] { models[id] ?? [] }

    func isLoaded(_ id: ModelID) -> Bool { models[id]?.isEmpty == false }

    var loadedModels: [ModelID] { Array(models.keys) }

    func unloadAll() {
        models.removeAll()
    }

    /// Drops one model's sessions, releasing both the ORT graph and the Core ML
    /// model behind it. Nothing in this engine asks for that today — the service
    /// is a separate process and the system reclaims it wholesale — but it is
    /// the counterpart of `load`, and the iOS app's memory-pressure path is
    /// built on the same call, so the two runtimes keep the same surface.
    func unload(_ id: ModelID) {
        guard models.removeValue(forKey: id) != nil else { return }
        EngineLog.engine.notice("unloaded \(id.rawValue, privacy: .public)")
    }

    /// Loads a model, reusing the existing sessions when the path is unchanged.
    func load(_ id: ModelID, path: String, compute: ComputePolicy,
              cacheDirectory: String, tuning: EngineTuning = EngineTuning()) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw makeEngineNSError(.modelMissing, underlying: "missing \(id.rawValue) at \(path)")
        }

        // Only the enhancer is replicated. It is by far the slowest stage, so
        // two frames being restored at once is the difference between the
        // second one starting and the second one waiting; every other model is
        // fast enough that a second copy of its weights would cost more
        // resident memory than it buys in overlap.
        let wanted = id == .faceEnhancer ? max(1, tuning.enhancerReplicas) : 1
        if let existing = models[id], existing.count >= wanted { return }

        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        try options.setLogSeverityLevel(tuning.profileComputePlan ? .verbose : .warning)
        if tuning.intraOpThreads > 0 {
            try options.setIntraOpNumThreads(Int32(tuning.intraOpThreads))
        }

        if compute != .cpu, ORTIsCoreMLExecutionProviderAvailable() {
            // The V2 dictionary API is the only way to reach MLComputeUnits,
            // the MLProgram format and the on-disk compile cache. Core ML
            // compiles each ONNX subgraph the first time it sees it; caching
            // that turns a slow first launch into a fast every-other launch.
            var providerOptions: [String: String] = [
                "MLComputeUnits": compute.mlComputeUnits,
                "ModelFormat": tuning.modelFormat,
                "ModelCacheDirectory": cacheDirectory,
                // Every graph here has fully static shapes. Saying so lets the
                // EP absorb regions it would otherwise leave on the CPU, which
                // measured as a free 35%.
                "RequireStaticInputShapes": tuning.requireStaticInputShapes ? "1" : "0",
                "AllowLowPrecisionAccumulationOnGPU": "1",
            ]
            if tuning.profileComputePlan {
                providerOptions["ProfileComputePlan"] = "1"
            }
            // Pinning these graphs to `CPUAndNeuralEngine` measured 17×
            // *slower* here than letting Core ML choose — they are convolutional
            // generators the ANE largely rejects, so the run degenerates into
            // constant fallback. `ALL` is therefore the default, and
            // `Benchmark`'s sweep is how to revisit that: the balance differs by
            // machine, and per-model policy makes it a question with more than
            // one answer.
            do {
                try options.appendCoreMLExecutionProvider(withOptionsV2: providerOptions)
                coreMLActive = true
                providerDescription = "Core ML (\(compute.mlComputeUnits))"
                if !announcedCacheDirectory {
                    announcedCacheDirectory = true
                    // Worth a line in the log: the cache lives in Application
                    // Support, and if it is ever cleared or excluded the first
                    // launch after that pays the whole compile cost again.
                    EngineLog.engine.notice(
                        "Core ML compile cache at \(cacheDirectory, privacy: .public)")
                }
            } catch {
                // A graph Core ML will not take is not fatal; ORT's CPU kernels
                // still produce a correct result, just slower.
                EngineLog.engine.error(
                    "Core ML EP unavailable for \(id.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        let started = Date()
        var built = models[id] ?? []
        do {
            // Built one after another rather than in parallel: the first
            // session pays the Core ML compile, the rest hit the cache it just
            // wrote.
            while built.count < wanted {
                let session = try ORTSession(env: env, modelPath: path, sessionOptions: options)
                built.append(try ORTModel(id: id, session: session))
            }
        } catch {
            // Failing to build the *first* session is a real failure. Failing
            // to build a replica is not — one session still restores every
            // frame, it just cannot overlap two of them.
            guard !built.isEmpty else { throw error }
            let made = built.count
            models[id] = built
            EngineLog.engine.error(
                "\(id.rawValue, privacy: .public) replica \(made + 1) failed, continuing with \(made): \(error.localizedDescription, privacy: .public)")
            return
        }

        models[id] = built
        EngineLog.engine.info(
            "loaded \(id.rawValue, privacy: .public) x\(built.count) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s inputs=\(built.first?.inputNames.joined(separator: ",") ?? "", privacy: .public)")
    }
}

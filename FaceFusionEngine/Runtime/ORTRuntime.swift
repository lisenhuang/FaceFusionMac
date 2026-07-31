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

import Foundation
import OnnxRuntimeBindings
import os

/// A dense float tensor moving in or out of a session.
struct FloatTensor {
    var shape: [Int]
    var values: [Float]

    var count: Int { values.count }

    init(shape: [Int], values: [Float]) {
        self.shape = shape
        self.values = values
    }

    init(shape: [Int], repeating value: Float = 0) {
        self.shape = shape
        self.values = [Float](repeating: value, count: shape.reduce(1, *))
    }
}

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

    /// Runs the graph. `inputs` are copied into ORT-owned buffers that stay
    /// alive for the duration of the call.
    func run(_ inputs: [String: FloatTensor],
             outputs requested: [String]? = nil) throws -> [String: FloatTensor] {
        var ortInputs: [String: ORTValue] = [:]
        // ORTValue does not copy: these must outlive `run`.
        var retained: [NSMutableData] = []

        for (name, tensor) in inputs {
            let byteCount = tensor.values.count * MemoryLayout<Float>.size
            let data = NSMutableData(length: byteCount)!
            tensor.values.withUnsafeBytes { src in
                memcpy(data.mutableBytes, src.baseAddress!, byteCount)
            }
            retained.append(data)
            ortInputs[name] = try ORTValue(tensorData: data,
                                           elementType: .float,
                                           shape: tensor.shape.map { NSNumber(value: $0) })
        }

        let wanted = requested ?? outputNames
        let results = try session.run(withInputs: ortInputs,
                                      outputNames: Set(wanted),
                                      runOptions: nil)

        var decoded: [String: FloatTensor] = [:]
        for name in wanted {
            guard let value = results[name] else { continue }
            decoded[name] = try Self.floats(from: value)
        }
        withExtendedLifetime(retained) {}
        return decoded
    }

    /// Reads an output tensor back as float32, widening float16 when a graph
    /// hands one back.
    private static func floats(from value: ORTValue) throws -> FloatTensor {
        let info = try value.tensorTypeAndShapeInfo()
        let shape = info.shape.map(\.intValue)
        let data = try value.tensorData()
        let elementCount = shape.reduce(1, *)

        // ONNX TensorProto.DataType: 1 = FLOAT, 10 = FLOAT16. The Objective-C
        // enum has no float16 case, so compare raw values.
        let onnxFloat16: Int32 = 10

        if info.elementType == .float {
            var out = [Float](repeating: 0, count: elementCount)
            out.withUnsafeMutableBytes { dst in
                memcpy(dst.baseAddress!, data.bytes, min(data.length, elementCount * 4))
            }
            return FloatTensor(shape: shape, values: out)
        }

        if info.elementType.rawValue == onnxFloat16 {
            var halves = [UInt16](repeating: 0, count: elementCount)
            halves.withUnsafeMutableBytes { dst in
                memcpy(dst.baseAddress!, data.bytes, min(data.length, elementCount * 2))
            }
            return FloatTensor(shape: shape, values: halves.map { Float(Float16(bitPattern: $0)) })
        }

        throw makeEngineNSError(.inferenceFailed,
                                underlying: "unsupported output element type \(info.elementType.rawValue)")
    }
}

/// Owns the ORT environment and every loaded model.
final class ORTRuntime {

    /// ONNX Runtime treats its environment as a process-wide singleton — it
    /// owns the shared thread pools and logging sink. Constructing more than
    /// one per process is unsupported and misbehaves, so all runtimes share it.
    private static let sharedEnv: Result<ORTEnv, Error> = {
        do { return .success(try ORTEnv(loggingLevel: .warning)) }
        catch { return .failure(error) }
    }()

    private let env: ORTEnv
    private var models: [ModelID: ORTModel] = [:]
    private(set) var coreMLActive = false
    private(set) var providerDescription = "CPU"

    init() throws {
        env = try Self.sharedEnv.get()
    }

    func model(_ id: ModelID) -> ORTModel? { models[id] }

    func isLoaded(_ id: ModelID) -> Bool { models[id] != nil }

    var loadedModels: [ModelID] { Array(models.keys) }

    func unloadAll() {
        models.removeAll()
    }

    /// Loads a model, reusing the existing session when the path is unchanged.
    func load(_ id: ModelID, path: String, compute: ComputePolicy, cacheDirectory: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw makeEngineNSError(.modelMissing, underlying: "missing \(id.rawValue) at \(path)")
        }
        if models[id] != nil { return }

        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        try options.setLogSeverityLevel(.warning)

        if compute != .cpu, ORTIsCoreMLExecutionProviderAvailable() {
            // The V2 dictionary API is the only way to reach MLComputeUnits,
            // the MLProgram format and the on-disk compile cache. Core ML
            // compiles each ONNX subgraph the first time it sees it; caching
            // that turns a slow first launch into a fast every-other launch.
            let computeUnits: String
            switch compute {
            case .automatic: computeUnits = "ALL"
            case .gpu:       computeUnits = "CPUAndGPU"
            case .cpu:       computeUnits = "CPUOnly"
            }
            let providerOptions: [String: String] = [
                "MLComputeUnits": computeUnits,
                "ModelFormat": "MLProgram",
                "ModelCacheDirectory": cacheDirectory,
                "RequireStaticInputShapes": "0",
                "AllowLowPrecisionAccumulationOnGPU": "1",
            ]
            do {
                try options.appendCoreMLExecutionProvider(withOptionsV2: providerOptions)
                coreMLActive = true
                providerDescription = "Core ML (\(computeUnits))"
            } catch {
                // A graph Core ML will not take is not fatal; ORT's CPU kernels
                // still produce a correct result, just slower.
                NSLog("[engine] Core ML EP unavailable for \(id.rawValue): \(error.localizedDescription)")
            }
        }

        let started = Date()
        let session = try ORTSession(env: env, modelPath: path, sessionOptions: options)
        let model = try ORTModel(id: id, session: session)
        models[id] = model
        EngineLog.engine.info(
            "loaded \(id.rawValue, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s inputs=\(model.inputNames.joined(separator: ","), privacy: .public)")
    }
}

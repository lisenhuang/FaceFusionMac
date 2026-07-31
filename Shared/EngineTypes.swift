//
//  EngineTypes.swift
//  Shared between FaceFusionMac (app) and FaceFusionEngine (XPC service).
//
//  Everything crossing the IPC boundary as JSON.
//

import Foundation

// MARK: - Model catalogue

/// The models the engine knows how to load. Raw values match the file stem of
/// the corresponding FaceFusion asset, and are the keys used in `models.json`.
public enum ModelID: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case faceDetector   = "yoloface_8n"
    case faceLandmarker = "2dfan4"
    case faceRecognizer = "arcface_w600k_r50"
    case faceSwapper    = "inswapper_128_fp16"
    case faceEnhancer   = "gfpgan_1.4"

    /// Models without which no swap can run at all.
    public static let required: [ModelID] = [.faceDetector, .faceRecognizer, .faceSwapper]

    // Conformance to CodingKeyRepresentable (declared above) comes free for a
    // String-backed enum, and makes `[ModelID: String]` encode as a JSON
    // object rather than a flat alternating key/value array — which keeps the
    // IPC payloads readable when debugging.

    public var displayName: String {
        switch self {
        case .faceDetector:   return "Face Detector"
        case .faceLandmarker: return "Landmark Refiner"
        case .faceRecognizer: return "Identity Encoder"
        case .faceSwapper:    return "Face Swapper"
        case .faceEnhancer:   return "Face Enhancer"
        }
    }

    public var purpose: String {
        switch self {
        case .faceDetector:   return "Finds faces and their five key points in every frame."
        case .faceLandmarker: return "Refines alignment with 68 landmarks for a steadier result."
        case .faceRecognizer: return "Encodes the identity of your source face."
        case .faceSwapper:    return "Performs the actual face replacement."
        case .faceEnhancer:   return "Restores detail and sharpness in the swapped face."
        }
    }
}

// MARK: - Configuration

public enum ComputePolicy: String, Codable, Sendable {
    /// Core ML picks between ANE, GPU and CPU.
    case automatic
    /// Excludes the Neural Engine; sometimes better for fp32 graphs.
    case gpu
    /// Prefers the Neural Engine, falling back to CPU.
    case neuralEngine
    /// Reference path. Slow, but never depends on Core ML op coverage.
    case cpu

    /// The string the Core ML execution provider expects.
    public var mlComputeUnits: String {
        switch self {
        case .automatic:    return "ALL"
        case .gpu:          return "CPUAndGPU"
        case .neuralEngine: return "CPUAndNeuralEngine"
        case .cpu:          return "CPUOnly"
        }
    }
}

/// Lower-level execution knobs. Defaults are what ships; the benchmark mode
/// sweeps them to find what actually helps on a given machine.
public struct EngineTuning: Codable, Sendable, Equatable {
    /// Every model here has fully static shapes, and telling Core ML so lets
    /// it take graph regions it would otherwise leave to the CPU.
    public var requireStaticInputShapes: Bool
    /// "MLProgram" or "NeuralNetwork".
    public var modelFormat: String
    /// Logs which unit each operator landed on. Expensive; diagnostics only.
    public var profileComputePlan: Bool
    /// 0 leaves ORT's default.
    public var intraOpThreads: Int

    public init(requireStaticInputShapes: Bool = true,
                modelFormat: String = "MLProgram",
                profileComputePlan: Bool = false,
                intraOpThreads: Int = 0) {
        self.requireStaticInputShapes = requireStaticInputShapes
        self.modelFormat = modelFormat
        self.profileComputePlan = profileComputePlan
        self.intraOpThreads = intraOpThreads
    }
}

public struct EngineConfiguration: Codable, Sendable {
    /// Absolute paths to each `.onnx` file, keyed by model.
    public var modelPaths: [ModelID: String]
    /// Where Core ML may cache the models it compiles from the ONNX graphs.
    public var modelCacheDirectory: String
    public var compute: ComputePolicy
    public var tuning: EngineTuning

    public init(modelPaths: [ModelID: String],
                modelCacheDirectory: String,
                compute: ComputePolicy = .automatic,
                tuning: EngineTuning = EngineTuning()) {
        self.modelPaths = modelPaths
        self.modelCacheDirectory = modelCacheDirectory
        self.compute = compute
        self.tuning = tuning
    }
}

public struct EnginePreparation: Codable, Sendable {
    public var loadedModels: [ModelID]
    /// True when Core ML accepted at least one graph; false means pure CPU.
    public var usingCoreML: Bool
    public var executionProvider: String
    public var warmupSeconds: Double

    public init(loadedModels: [ModelID], usingCoreML: Bool,
                executionProvider: String, warmupSeconds: Double) {
        self.loadedModels = loadedModels
        self.usingCoreML = usingCoreML
        self.executionProvider = executionProvider
        self.warmupSeconds = warmupSeconds
    }
}

// MARK: - Faces

public struct FaceBox: Codable, Sendable, Hashable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct DetectedFace: Codable, Sendable, Hashable {
    /// Stable within one frame: index in detection order (left to right).
    public var index: Int
    public var box: FaceBox
    public var score: Double
    /// Five key points in image pixels: left eye, right eye, nose, mouth L, mouth R.
    public var landmarks: [[Double]]

    public init(index: Int, box: FaceBox, score: Double, landmarks: [[Double]]) {
        self.index = index; self.box = box; self.score = score; self.landmarks = landmarks
    }
}

public struct FrameAnalysis: Codable, Sendable {
    public var faces: [DetectedFace]
    public init(faces: [DetectedFace]) { self.faces = faces }
}

public struct SourceAnalysis: Codable, Sendable {
    public var face: DetectedFace?
    public var faceCount: Int
    public init(face: DetectedFace?, faceCount: Int) {
        self.face = face; self.faceCount = faceCount
    }
}

// MARK: - Swapping

/// Which face(s) in the target frame get replaced.
public enum FaceSelection: Codable, Sendable, Equatable {
    case all
    case largest
    /// Nearest to a point in normalised (0...1) frame coordinates. Survives
    /// resolution changes and frame-to-frame detector jitter better than an index.
    case nearestTo(x: Double, y: Double)
}

public struct SwapOptions: Codable, Sendable {
    public var selection: FaceSelection
    /// 0 keeps more of the target's identity, 1 pushes fully to the source.
    /// Mirrors FaceFusion's `face_swapper_weight`.
    public var identityStrength: Double
    public var enhanceFace: Bool
    /// 0...1, how much of the enhanced face is blended back in.
    public var enhancementBlend: Double
    /// Feathering of the paste-back mask. Mirrors `face_mask_blur`.
    public var maskBlur: Double
    /// Minimum detector confidence.
    public var detectorScore: Double
    /// Use the 68-point landmarker to refine alignment when available.
    public var refineLandmarks: Bool

    public init(selection: FaceSelection = .all,
                identityStrength: Double = 0.5,
                enhanceFace: Bool = true,
                enhancementBlend: Double = 0.8,
                maskBlur: Double = 0.3,
                detectorScore: Double = 0.5,
                refineLandmarks: Bool = true) {
        self.selection = selection
        self.identityStrength = identityStrength
        self.enhanceFace = enhanceFace
        self.enhancementBlend = enhancementBlend
        self.maskBlur = maskBlur
        self.detectorScore = detectorScore
        self.refineLandmarks = refineLandmarks
    }
}

/// Per-stage cost of one frame, in seconds. Used by the benchmark and the
/// engine's periodic timing log.
public struct StageSeconds: Codable, Sendable {
    public var detect: Double = 0
    public var landmarks: Double = 0
    public var swap: Double = 0
    public var paste: Double = 0
    public var enhance: Double = 0
    public var total: Double = 0

    public init() {}

    public static func + (a: StageSeconds, b: StageSeconds) -> StageSeconds {
        var out = StageSeconds()
        out.detect = a.detect + b.detect
        out.landmarks = a.landmarks + b.landmarks
        out.swap = a.swap + b.swap
        out.paste = a.paste + b.paste
        out.enhance = a.enhance + b.enhance
        out.total = a.total + b.total
        return out
    }

    public func scaled(by factor: Double) -> StageSeconds {
        var out = StageSeconds()
        out.detect = detect * factor
        out.landmarks = landmarks * factor
        out.swap = swap * factor
        out.paste = paste * factor
        out.enhance = enhance * factor
        out.total = total * factor
        return out
    }
}

public struct SwapResult: Codable, Sendable {
    public var facesFound: Int
    public var facesSwapped: Int
    public var inferenceSeconds: Double
    public var stages: StageSeconds

    public init(facesFound: Int, facesSwapped: Int,
                inferenceSeconds: Double, stages: StageSeconds = StageSeconds()) {
        self.facesFound = facesFound
        self.facesSwapped = facesSwapped
        self.inferenceSeconds = inferenceSeconds
        self.stages = stages
    }
}

// MARK: - Errors

public enum EngineError: Int, Codable, Sendable {
    case modelMissing = 1
    case modelLoadFailed = 2
    case noSourceFace = 3
    case inferenceFailed = 4
    case invalidSurface = 5
    case notPrepared = 6
    case cancelled = 7

    public var message: String {
        switch self {
        case .modelMissing:    return "A required AI model is missing. Reinstall the models from Settings."
        case .modelLoadFailed: return "A model could not be loaded. The file may be incomplete."
        case .noSourceFace:    return "No face was found in the source image. Try a clearer, front-facing photo."
        case .inferenceFailed: return "The engine failed while processing a frame."
        case .invalidSurface:  return "An internal image buffer was invalid."
        case .notPrepared:     return "The engine has not finished loading its models."
        case .cancelled:       return "Cancelled."
        }
    }
}

public let engineErrorDomain = "com.lisenhuang.FaceFusionMac.EngineError"

public func makeEngineNSError(_ code: EngineError, underlying: String? = nil) -> NSError {
    var info: [String: Any] = [NSLocalizedDescriptionKey: code.message]
    if let underlying { info[NSDebugDescriptionErrorKey] = underlying }
    return NSError(domain: engineErrorDomain, code: code.rawValue, userInfo: info)
}

// MARK: - JSON helpers

public enum EngineJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

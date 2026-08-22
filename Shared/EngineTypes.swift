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
///
/// `nonisolated` because the app target defaults its types to the main actor
/// and the engine target does not, and this one is read from both sides of the
/// XPC link — including the app's model library pass, which runs off the main
/// actor. The engine already saw it this way; this only says so out loud.
public nonisolated enum ModelID: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case faceDetector   = "yoloface_8n"
    case faceLandmarker = "2dfan4"
    case faceRecognizer = "arcface_w600k_r50"
    case faceSwapper    = "inswapper_128_fp16"
    case faceEnhancer   = "gfpgan_1.4"
    case faceOccluder   = "dfl_xseg"

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
        case .faceOccluder:   return "Occlusion Mask"
        }
    }

    public var purpose: String {
        switch self {
        case .faceDetector:   return "Finds faces and their five key points in every frame."
        case .faceLandmarker: return "Refines alignment with 68 landmarks for a steadier result."
        case .faceRecognizer: return "Encodes the identity of your source face."
        case .faceSwapper:    return "Performs the actual face replacement."
        case .faceEnhancer:   return "Restores detail and sharpness in the swapped face."
        case .faceOccluder:   return "Keeps hands, hair and objects that cross the face from being painted over."
        }
    }
}

// MARK: - Configuration

/// `nonisolated` for the same reason `ModelID` is: the app target defaults its
/// types to the main actor and the engine target does not, and both of these are
/// read from places that are neither — the compile-cache fingerprint, which runs
/// on the launch pass's detached task, and a default argument, which is always
/// evaluated outside any actor.
public nonisolated enum ComputePolicy: String, Codable, Sendable {
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
public nonisolated struct EngineTuning: Codable, Sendable, Equatable {
    /// Every model here has fully static shapes, and telling Core ML so lets
    /// it take graph regions it would otherwise leave to the CPU.
    public var requireStaticInputShapes: Bool
    /// "MLProgram" or "NeuralNetwork".
    public var modelFormat: String
    /// Logs which unit each operator landed on. Expensive; diagnostics only.
    public var profileComputePlan: Bool
    /// 0 leaves ORT's default.
    public var intraOpThreads: Int
    /// How many independent `ORTSession`s to build for the face enhancer, so
    /// two frames can be restored at once instead of queueing on one.
    ///
    /// An `ORTSession` serialises its own `run`, and the export loop keeps
    /// several frames inside the engine at once — so without a second replica
    /// every one of them queues behind the same session while the rest of the
    /// pipeline sits idle. The enhancer is both the slowest stage and the
    /// largest model, which is why it is the only one replicated: a second copy
    /// of any other model's weights would cost more resident memory than it
    /// buys in overlap.
    ///
    /// Defaulted inline as well as in the initialiser so that an
    /// `EngineConfiguration` encoded by an older build still decodes.
    public var enhancerReplicas: Int = 1

    public init(requireStaticInputShapes: Bool = true,
                modelFormat: String = "MLProgram",
                profileComputePlan: Bool = false,
                intraOpThreads: Int = 0,
                enhancerReplicas: Int = 1) {
        self.requireStaticInputShapes = requireStaticInputShapes
        self.modelFormat = modelFormat
        self.profileComputePlan = profileComputePlan
        self.intraOpThreads = intraOpThreads
        self.enhancerReplicas = enhancerReplicas
    }
}

public struct EngineConfiguration: Codable, Sendable {
    /// Absolute paths to each `.onnx` file, keyed by model.
    public var modelPaths: [ModelID: String]
    /// Where Core ML may cache the models it compiles from the ONNX graphs.
    public var modelCacheDirectory: String
    public var compute: ComputePolicy
    /// Per-model exceptions to `compute`, empty by default.
    ///
    /// One `MLComputeUnits` for all six graphs is a single answer to a question
    /// that has more than one: the detector and the identity encoder are small
    /// and land well on the Neural Engine, while the swapper and the restorer
    /// are convolutional generators it largely rejects. Splitting them lets two
    /// units work at once instead of contending for one.
    ///
    /// Shipping empty is deliberate. Which model wants which unit is a
    /// measurement, not a deduction — `Benchmark` is the instrument — and an
    /// empty dictionary reproduces exactly the behaviour of the single policy
    /// it generalises.
    public var computeOverrides: [ModelID: ComputePolicy] = [:]
    public var tuning: EngineTuning
    /// The manifest's SHA-256 for each model, so the engine can find out
    /// whether a file it cannot load is still the file it was verified as.
    ///
    /// Sent even though nothing reads it on a healthy launch: the one moment it
    /// is wanted — preparation having already failed twice — is a moment the
    /// engine cannot ask the app anything, because it is inside the barrier
    /// that is holding the reply. Carrying the answer in the question costs a
    /// few hundred bytes of JSON.
    public var modelDigests: [ModelID: String]

    public init(modelPaths: [ModelID: String],
                modelCacheDirectory: String,
                compute: ComputePolicy = .automatic,
                computeOverrides: [ModelID: ComputePolicy] = [:],
                tuning: EngineTuning = EngineTuning(),
                modelDigests: [ModelID: String] = [:]) {
        self.modelPaths = modelPaths
        self.modelCacheDirectory = modelCacheDirectory
        self.compute = compute
        self.computeOverrides = computeOverrides
        self.tuning = tuning
        self.modelDigests = modelDigests
    }

    /// The policy one model should load under.
    public func compute(for id: ModelID) -> ComputePolicy {
        computeOverrides[id] ?? compute
    }
}

/// Paths around the compiled-graph cache that both processes have to agree on.
///
/// The cache directory itself travels in `EngineConfiguration`; this is the one
/// piece of it that does not, because the two sides use it at times when they
/// are not talking to each other — the engine raises the marker as it starts
/// compiling, and the app reads it at the next launch, possibly after the
/// engine process was killed and never got to lower it.
public nonisolated enum CompileCache {

    /// The marker held for as long as a Core ML compile may be in flight.
    ///
    /// ORT decides to reuse a compiled artifact by existence alone — there is
    /// no integrity check — and an `.mlmodelc` is a directory tree written item
    /// by item, so a process killed part-way through compilation leaves behind
    /// something that passes ORT's only test and is not a model. The marker is
    /// what makes that state visible: present at the next launch means a
    /// compile did not finish, and the cache is wiped rather than trusted.
    ///
    /// Beside the cache directory rather than inside it, so that wiping the
    /// cache does not also erase the evidence that it needed wiping.
    public static func markerURL(forCacheDirectory directory: URL) -> URL {
        directory.deletingLastPathComponent()
            .appendingPathComponent(directory.lastPathComponent + ".compiling",
                                    isDirectory: false)
    }

    /// The record that the cache has already been rebuilt once here and the
    /// rebuild did not help.
    ///
    /// The engine's own "once" is a process-wide flag, and a process is one
    /// launch: the service exits with the app. That closes the loop inside a
    /// launch and nothing more, so a machine whose failure neither repair
    /// reaches would pay a full recompile — and a full re-hash of the library —
    /// every time the app opened, for ever. This file is that verdict written
    /// down, and it is removed the moment the ground it was reached on moves:
    /// by a preparation that succeeds, and by the app whenever it wipes the
    /// cache itself or the installed model set changes.
    ///
    /// Beside the cache directory, like the marker, so a wipe does not erase
    /// the reason for it.
    public static func rebuildReceiptURL(forCacheDirectory directory: URL) -> URL {
        directory.deletingLastPathComponent()
            .appendingPathComponent(directory.lastPathComponent + ".rebuilt",
                                    isDirectory: false)
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
    /// Parallel to `faces`, and empty unless the caller asked for identities.
    /// The per-frame overlay does not need them; the "who is in this video"
    /// scan does, and paying for them there only is the difference between one
    /// extra model pass per face and none.
    public var identities: [FaceIdentity]

    public init(faces: [DetectedFace], identities: [FaceIdentity] = []) {
        self.faces = faces
        self.identities = identities
    }
}

/// What `analyzeFaces` should do beyond detecting. Alignment has to match the
/// settings the swap will run with, or the identities compared at swap time
/// are not the ones the picker collected.
public struct AnalysisOptions: Codable, Sendable {
    public var detectorScore: Double
    public var refineLandmarks: Bool
    /// Skips the recognizer when only boxes are wanted.
    public var includeIdentities: Bool

    public init(detectorScore: Double = 0.5,
                refineLandmarks: Bool = true,
                includeIdentities: Bool = true) {
        self.detectorScore = detectorScore
        self.refineLandmarks = refineLandmarks
        self.includeIdentities = includeIdentities
    }
}

// MARK: - Identity

/// An L2-normalised ArcFace vector — the same 512 numbers the swapper is
/// conditioned on, reused here for a different purpose: deciding whether two
/// faces in different frames are the same person.
public struct FaceIdentity: Codable, Sendable, Equatable {
    public var vector: [Float]

    public init(vector: [Float]) { self.vector = vector }

    /// Cosine distance: 0 for identical, 1 for unrelated, 2 for opposite.
    /// Both operands are already unit length, so the dot product *is* the
    /// cosine and no division is needed.
    ///
    /// For scale, with this model two photos of one person typically land
    /// between 0.2 and 0.5, and two different people above 0.7.
    /// Vectors of different lengths came from different models, so they are
    /// reported as unmatchable rather than compared over their common prefix —
    /// a truncated dot product looks like a perfectly ordinary distance.
    public func distance(to other: FaceIdentity) -> Double {
        guard !vector.isEmpty, vector.count == other.vector.count else {
            return .greatestFiniteMagnitude
        }
        var dot: Float = 0
        for index in 0 ..< vector.count { dot += vector[index] * other.vector[index] }
        return 1 - Double(dot)
    }

    /// Nearest distance to any of `others`, or infinity when there are none.
    public func nearestDistance(among others: [FaceIdentity]) -> Double {
        var best = Double.greatestFiniteMagnitude
        for other in others { best = min(best, distance(to: other)) }
        return best
    }
}

/// The identities of the faces the user checked.
///
/// Sent to the engine once per change rather than riding in `SwapOptions`,
/// which is re-encoded for every frame — 512 floats per face at 60fps is a lot
/// of JSON to write and throw away. `generation` rises on each send, and a
/// swap naming a generation the engine no longer holds is refused rather than
/// quietly swapping against a stale set.
public struct ReferenceFaceSet: Codable, Sendable {
    public var generation: Int
    public var identities: [FaceIdentity]

    public init(generation: Int, identities: [FaceIdentity]) {
        self.generation = generation
        self.identities = identities
    }
}

public struct SourceAnalysis: Codable, Sendable {
    /// The face whose identity the engine is now conditioned on.
    public var face: DetectedFace?
    public var faceCount: Int
    /// Every face found in the portrait, left to right, so the app can offer a
    /// choice. `face` is always one of these; its `index` says which.
    public var faces: [DetectedFace]
    public init(face: DetectedFace?, faceCount: Int, faces: [DetectedFace] = []) {
        self.face = face; self.faceCount = faceCount; self.faces = faces
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
    /// Only faces matching one of the identities in the reference set the
    /// engine currently holds, within `maxDistance` cosine distance.
    ///
    /// This is the only selection that means the same thing throughout a
    /// video. An index is left-to-right order within a single frame, so two
    /// people crossing reassigns it; a fixed point stops naming anyone as soon
    /// as the subject moves. An identity keeps pointing at the person.
    case reference(generation: Int, maxDistance: Double)

    /// True when choosing faces costs an identity pass over every detection.
    public var needsIdentities: Bool {
        if case .reference = self { return true }
        return false
    }
}

/// Default cosine distance for calling two faces the same person.
///
/// Mirrors FaceFusion's `reference_face_distance`. Loose enough to hold a
/// person across a turn of the head or a change of lighting, tight enough to
/// keep two different people apart.
public let defaultFaceMatchDistance = 0.6

/// How much detail the swapper is allowed to generate for a large face.
///
/// The swapper's graph is fixed at 128x128, so a face occupying more than that
/// in the frame is enlarged on the way back in and arrives softer than the
/// pixels around it. Pixel boost buys real detail by running the same graph
/// over several sub-pixel phases of a larger crop and interleaving the results
/// — see `FaceSwapper.swap(image:landmarks:conditioning:boost:)`.
///
/// This is a **ceiling, not a fixed cost**. The factor actually used is chosen
/// per face from its footprint, so a face already smaller than 128 costs one
/// pass at every setting and a wide shot is untouched by the choice.
public enum CloseUpDetail: String, Codable, Sendable, CaseIterable {
    /// One pass. Bit-for-bit what every build before this one did.
    case standard
    /// Up to 4 passes, generating at most 256px of face.
    case high
    /// Up to 16 passes, generating at most 512px of face.
    case maximum

    /// The largest boost factor this level permits. Passes cost the square.
    public var boostCeiling: Int {
        switch self {
        case .standard: return 1
        case .high:     return 2
        case .maximum:  return 4
        }
    }
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
    /// Carve occluding objects — hands, hair — out of the paste mask, when the
    /// occluder model is loaded. Mirrors `occlusion` in `face_mask_types`.
    public var maskOcclusion: Bool
    /// Minimum detector confidence.
    public var detectorScore: Double
    /// Use the 68-point landmarker to refine alignment when available.
    public var refineLandmarks: Bool
    /// Ceiling on the swapper's pixel boost. See `CloseUpDetail`.
    public var closeUpDetail: CloseUpDetail

    public init(selection: FaceSelection = .all,
                identityStrength: Double = 0.5,
                enhanceFace: Bool = true,
                enhancementBlend: Double = 0.8,
                maskBlur: Double = 0.3,
                maskOcclusion: Bool = true,
                detectorScore: Double = 0.5,
                refineLandmarks: Bool = true,
                closeUpDetail: CloseUpDetail = .high) {
        self.selection = selection
        self.identityStrength = identityStrength
        self.enhanceFace = enhanceFace
        self.enhancementBlend = enhancementBlend
        self.maskBlur = maskBlur
        self.maskOcclusion = maskOcclusion
        self.detectorScore = detectorScore
        self.refineLandmarks = refineLandmarks
        self.closeUpDetail = closeUpDetail
    }

    /// Decoded field by field rather than by synthesis, so that JSON written by
    /// a build without `closeUpDetail` still decodes instead of throwing
    /// `keyNotFound`. Swift's synthesised decoder ignores a property's default
    /// and requires every key to be present.
    ///
    /// This matters more here than in the iOS app, where the same type only has
    /// to survive a settings blob. These options are the IPC contract: the app
    /// encodes them and the XPC service decodes them, and the two are separate
    /// executables that an interrupted update can leave at different versions.
    /// A missing key must degrade to the default, not fail the frame.
    ///
    /// Every key is optional for the same reason, so the next field added needs
    /// only a default and not another rewrite of this initialiser.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SwapOptions()
        selection = try container.decodeIfPresent(FaceSelection.self, forKey: .selection)
            ?? fallback.selection
        identityStrength = try container.decodeIfPresent(Double.self, forKey: .identityStrength)
            ?? fallback.identityStrength
        enhanceFace = try container.decodeIfPresent(Bool.self, forKey: .enhanceFace)
            ?? fallback.enhanceFace
        enhancementBlend = try container.decodeIfPresent(Double.self, forKey: .enhancementBlend)
            ?? fallback.enhancementBlend
        maskBlur = try container.decodeIfPresent(Double.self, forKey: .maskBlur)
            ?? fallback.maskBlur
        maskOcclusion = try container.decodeIfPresent(Bool.self, forKey: .maskOcclusion)
            ?? fallback.maskOcclusion
        detectorScore = try container.decodeIfPresent(Double.self, forKey: .detectorScore)
            ?? fallback.detectorScore
        refineLandmarks = try container.decodeIfPresent(Bool.self, forKey: .refineLandmarks)
            ?? fallback.refineLandmarks
        closeUpDetail = try container.decodeIfPresent(CloseUpDetail.self, forKey: .closeUpDetail)
            ?? fallback.closeUpDetail
    }
}

/// Per-stage cost of one frame, in seconds. Used by the benchmark and the
/// engine's periodic timing log.
public struct StageSeconds: Codable, Sendable {
    public var detect: Double = 0
    public var landmarks: Double = 0
    /// Recognising which detections are the faces the user checked. Zero for
    /// every selection except `.reference`.
    public var match: Double = 0
    public var swap: Double = 0
    public var paste: Double = 0
    public var enhance: Double = 0
    public var total: Double = 0

    public init() {}

    public static func + (a: StageSeconds, b: StageSeconds) -> StageSeconds {
        var out = StageSeconds()
        out.detect = a.detect + b.detect
        out.landmarks = a.landmarks + b.landmarks
        out.match = a.match + b.match
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
        out.match = match * factor
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
    case referenceFacesStale = 8

    public var message: String {
        switch self {
        case .modelMissing:    return "A required AI model is missing. Reinstall the models from Settings."
        case .modelLoadFailed: return "A model could not be loaded. The file may be incomplete."
        case .noSourceFace:    return "No face was found in the source image. Try a clearer, front-facing photo."
        case .inferenceFailed: return "The engine failed while processing a frame."
        case .invalidSurface:  return "An internal image buffer was invalid."
        case .notPrepared:     return "The engine has not finished loading its models."
        case .cancelled:       return "Cancelled."
        case .referenceFacesStale:
            return "The chosen faces are no longer loaded. Scan the target again and reselect them."
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

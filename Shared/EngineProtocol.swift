//
//  EngineProtocol.swift
//  Shared between FaceFusionMac (app) and FaceFusionEngine (XPC service).
//
//  The IPC contract. Control messages travel as JSON-encoded `Data` (so the
//  Codable types in EngineTypes.swift are the single source of truth), while
//  pixels travel as `IOSurface`, which XPC hands across the process boundary
//  by reference rather than by copy.
//

import Foundation
import IOSurface

/// Identity of the XPC service bundle embedded in the app. Must match the
/// engine target's `PRODUCT_BUNDLE_IDENTIFIER`.
public enum EngineServiceIdentity {
    public static let name = "com.lisenhuang.FaceFusionMac.Engine"
}

@objc public protocol FaceFusionEngineProtocol {

    /// Loads the ONNX models named in the configuration and warms up the
    /// execution providers. Safe to call repeatedly; only changed models reload.
    /// - Parameter configJSON: JSON-encoded ``EngineConfiguration``.
    /// - Parameter reply: JSON-encoded ``EnginePreparation`` on success.
    func prepare(configJSON: Data,
                 withReply reply: @escaping (Data?, Error?) -> Void)

    /// Analyzes a source portrait and caches the identity embedding used for
    /// every subsequent swap.
    /// - Parameter surface: BGRA8 image.
    /// - Parameter reply: JSON-encoded ``SourceAnalysis``.
    func analyzeSource(surface: IOSurface,
                       withReply reply: @escaping (Data?, Error?) -> Void)

    /// Detects faces in a frame without modifying it. Used to drive the face
    /// picker and to show the user what the engine can see.
    /// - Parameter reply: JSON-encoded ``FrameAnalysis``.
    func detectFaces(surface: IOSurface,
                     withReply reply: @escaping (Data?, Error?) -> Void)

    /// Detects faces *and* encodes each one's identity. This is what the scan
    /// over a whole video runs; `detectFaces` stays free of the recognizer so
    /// the per-frame overlay does not pay for it.
    /// - Parameter optionsJSON: JSON-encoded ``AnalysisOptions``.
    /// - Parameter reply: JSON-encoded ``FrameAnalysis``, identities included.
    func analyzeFaces(surface: IOSurface,
                      optionsJSON: Data,
                      withReply reply: @escaping (Data?, Error?) -> Void)

    /// Caches the identities of the faces the user checked, for
    /// ``FaceSelection/reference(generation:maxDistance:)`` to match against.
    ///
    /// A barrier, like ``analyzeSource``: no swap may be comparing against the
    /// old set while it is replaced.
    /// - Parameter setJSON: JSON-encoded ``ReferenceFaceSet``.
    func setReferenceFaces(setJSON: Data,
                           withReply reply: @escaping (Error?) -> Void)

    /// Swaps faces from `surface` into `output`. Both surfaces must be BGRA8
    /// and the same size. `output` is always fully written, so the caller can
    /// recycle surfaces from a pool.
    /// - Parameter optionsJSON: JSON-encoded ``SwapOptions``.
    /// - Parameter reply: JSON-encoded ``SwapResult``.
    func swap(surface: IOSurface,
              into output: IOSurface,
              optionsJSON: Data,
              withReply reply: @escaping (Data?, Error?) -> Void)

    /// Releases every loaded model. The service stays alive but idle.
    func unloadModels(withReply reply: @escaping () -> Void)
}

/// Builds the `NSXPCInterface` with the class allow-lists XPC requires for
/// `IOSurface` arguments. Both sides must configure this identically.
public func makeEngineInterface() -> NSXPCInterface {
    let interface = NSXPCInterface(with: FaceFusionEngineProtocol.self)
    let allowed = NSSet(array: [IOSurface.self, NSNumber.self, NSData.self]) as! Set<AnyHashable>

    interface.setClasses(allowed,
                         for: #selector(FaceFusionEngineProtocol.analyzeSource(surface:withReply:)),
                         argumentIndex: 0, ofReply: false)
    interface.setClasses(allowed,
                         for: #selector(FaceFusionEngineProtocol.detectFaces(surface:withReply:)),
                         argumentIndex: 0, ofReply: false)
    interface.setClasses(allowed,
                         for: #selector(FaceFusionEngineProtocol.analyzeFaces(surface:optionsJSON:withReply:)),
                         argumentIndex: 0, ofReply: false)
    interface.setClasses(allowed,
                         for: #selector(FaceFusionEngineProtocol.swap(surface:into:optionsJSON:withReply:)),
                         argumentIndex: 0, ofReply: false)
    interface.setClasses(allowed,
                         for: #selector(FaceFusionEngineProtocol.swap(surface:into:optionsJSON:withReply:)),
                         argumentIndex: 1, ofReply: false)
    return interface
}

//
//  EngineService.swift
//  FaceFusionEngine
//
//  The XPC-facing surface. Everything here runs out-of-process from the app,
//  which keeps hundreds of megabytes of model weights — and any crash inside
//  ONNX Runtime — away from the UI.
//

import Foundation
import IOSurface
import os

final class EngineService: NSObject, FaceFusionEngineProtocol {

    private let pipeline = SwapPipeline()

    /// Concurrent, with barriers for anything that mutates engine state.
    ///
    /// ONNX Runtime allows concurrent `Run` calls on one session, and the
    /// stages of a frame land on different hardware — the swapper and enhancer
    /// on the GPU, the surrounding pixel work on the CPU. Letting several
    /// frames overlap keeps those units busy at the same time instead of
    /// leaving each idle while the other works.
    ///
    /// `prepare`, `analyzeSource` and `unloadModels` replace the loaded models
    /// or the cached source identity, so they run as barriers: no swap can be
    /// in flight while the ground shifts under it.
    private let queue = DispatchQueue(label: "com.lisenhuang.FaceFusionMac.engine",
                                      qos: .userInitiated,
                                      attributes: .concurrent)

    // MARK: - Lifecycle

    func prepare(configJSON: Data, withReply reply: @escaping (Data?, Error?) -> Void) {
        queue.async(flags: .barrier) {
            do {
                let config = try EngineJSON.decode(EngineConfiguration.self, from: configJSON)
                EngineLog.engine.info("preparing with \(config.modelPaths.count) model(s), compute=\(config.compute.rawValue, privacy: .public)")

                let preparation = try self.pipeline.prepare(config)
                EngineLog.engine.info("ready via \(preparation.executionProvider, privacy: .public) in \(preparation.warmupSeconds, format: .fixed(precision: 2))s")
                reply(try EngineJSON.encode(preparation), nil)
            } catch {
                EngineLog.engine.error("prepare failed: \(error.localizedDescription, privacy: .public) [\(String(describing: error), privacy: .public)]")
                reply(nil, Self.transportable(error))
            }
        }
    }

    func unloadModels(withReply reply: @escaping () -> Void) {
        queue.async(flags: .barrier) {
            self.pipeline.unloadAll()
            reply()
        }
    }

    // MARK: - Analysis

    func analyzeSource(surface: IOSurface, withReply reply: @escaping (Data?, Error?) -> Void) {
        queue.async(flags: .barrier) {
            do {
                let analysis = try BGRAImage.withSurface(surface, readOnly: true) { image in
                    try self.pipeline.analyzeSource(image)
                }
                reply(try EngineJSON.encode(analysis), nil)
            } catch {
                reply(nil, Self.transportable(error))
            }
        }
    }

    func detectFaces(surface: IOSurface, withReply reply: @escaping (Data?, Error?) -> Void) {
        queue.async {
            do {
                let analysis = try BGRAImage.withSurface(surface, readOnly: true) { image in
                    try self.pipeline.detectFaces(in: image)
                }
                reply(try EngineJSON.encode(analysis), nil)
            } catch {
                reply(nil, Self.transportable(error))
            }
        }
    }

    func analyzeFaces(surface: IOSurface,
                      optionsJSON: Data,
                      withReply reply: @escaping (Data?, Error?) -> Void) {
        queue.async {
            do {
                let options = try EngineJSON.decode(AnalysisOptions.self, from: optionsJSON)
                let analysis = try BGRAImage.withSurface(surface, readOnly: true) { image in
                    try self.pipeline.analyzeFaces(in: image, options: options)
                }
                reply(try EngineJSON.encode(analysis), nil)
            } catch {
                reply(nil, Self.transportable(error))
            }
        }
    }

    /// A barrier: the set it replaces is read by every in-flight swap.
    func setReferenceFaces(setJSON: Data, withReply reply: @escaping (Error?) -> Void) {
        queue.async(flags: .barrier) {
            do {
                let set = try EngineJSON.decode(ReferenceFaceSet.self, from: setJSON)
                EngineLog.engine.info(
                    "reference faces: generation \(set.generation) with \(set.identities.count) identity(s)")
                self.pipeline.setReferenceFaces(set)
                reply(nil)
            } catch {
                reply(Self.transportable(error))
            }
        }
    }

    // MARK: - Swapping

    func swap(surface: IOSurface,
              into output: IOSurface,
              optionsJSON: Data,
              withReply reply: @escaping (Data?, Error?) -> Void) {
        queue.async {
            do {
                let options = try EngineJSON.decode(SwapOptions.self, from: optionsJSON)
                guard surface.width == output.width, surface.height == output.height else {
                    throw makeEngineNSError(.invalidSurface,
                                            underlying: "size mismatch \(surface.width)x\(surface.height) vs \(output.width)x\(output.height)")
                }

                let result = try BGRAImage.withSurface(surface, readOnly: true) { input in
                    try BGRAImage.withSurface(output, readOnly: false) { destination in
                        try self.pipeline.swap(input: input, output: destination, options: options)
                    }
                }
                reply(try EngineJSON.encode(result), nil)
            } catch {
                reply(nil, Self.transportable(error))
            }
        }
    }

    // MARK: - Errors

    /// XPC can only carry errors whose userInfo is plist-representable, so
    /// rebuild anything exotic as a plain NSError.
    private static func transportable(_ error: Error) -> NSError {
        let nsError = error as NSError
        if nsError.domain == engineErrorDomain { return nsError }
        return NSError(domain: engineErrorDomain,
                       code: EngineError.inferenceFailed.rawValue,
                       userInfo: [
                        NSLocalizedDescriptionKey: nsError.localizedDescription,
                        NSDebugDescriptionErrorKey: "\(nsError.domain)/\(nsError.code)",
                       ])
    }
}

/// Hands each incoming connection its own exported object.
final class EngineServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = makeEngineInterface()
        connection.exportedObject = EngineService()
        connection.resume()
        return true
    }
}

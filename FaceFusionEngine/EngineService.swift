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
    /// ORT sessions tolerate concurrent inference, but the pipeline holds
    /// mutable state (the cached source identity), so calls are serialised.
    private let queue = DispatchQueue(label: "com.lisenhuang.FaceFusionMac.engine",
                                      qos: .userInitiated)

    // MARK: - Lifecycle

    func prepare(configJSON: Data, withReply reply: @escaping (Data?, Error?) -> Void) {
        queue.async {
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
        queue.async {
            self.pipeline.unloadAll()
            reply()
        }
    }

    // MARK: - Analysis

    func analyzeSource(surface: IOSurface, withReply reply: @escaping (Data?, Error?) -> Void) {
        queue.async {
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

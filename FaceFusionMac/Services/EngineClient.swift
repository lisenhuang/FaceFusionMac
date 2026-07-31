//
//  EngineClient.swift
//  FaceFusionMac
//
//  The app's half of the IPC link to the embedded engine.
//
//  Inference lives in a separate process so that half a gigabyte of model
//  weights never lands in the UI's address space, and so a fault inside ONNX
//  Runtime takes down a restartable helper instead of the app. Frames cross as
//  IOSurfaces, which XPC passes by reference — a 1080p frame moves without
//  being copied.
//

import Foundation
import IOSurface
import Observation
import os

@MainActor
@Observable
final class EngineClient {

    enum State: Equatable {
        case idle
        case preparing
        case ready(EnginePreparationSummary)
        case failed(String)
    }

    struct EnginePreparationSummary: Equatable {
        var executionProvider: String
        var usingCoreML: Bool
        var loadedModels: [String]
    }

    private(set) var state: State = .idle
    private var connection: NSXPCConnection?

    // MARK: - Connection

    private func proxy() throws -> FaceFusionEngineProtocol {
        if connection == nil {
            let created = NSXPCConnection(serviceName: EngineServiceIdentity.name)
            created.remoteObjectInterface = makeEngineInterface()
            created.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.handleDisconnect("The engine connection was invalidated.") }
            }
            created.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.handleDisconnect("The engine stopped unexpectedly.") }
            }
            created.resume()
            connection = created
        }
        guard let remote = connection?.remoteObjectProxy as? FaceFusionEngineProtocol else {
            throw makeEngineNSError(.notPrepared, underlying: "could not reach the engine service")
        }
        return remote
    }

    /// Throwing proxy so a dropped connection surfaces as an error on the
    /// awaiting call rather than hanging it forever.
    private func proxy(onError handler: @escaping (Error) -> Void) throws -> FaceFusionEngineProtocol {
        _ = try proxy()
        guard let remote = connection?.remoteObjectProxyWithErrorHandler({ error in
            handler(error)
        }) as? FaceFusionEngineProtocol else {
            throw makeEngineNSError(.notPrepared, underlying: "could not reach the engine service")
        }
        return remote
    }

    private func handleDisconnect(_ message: String) {
        connection = nil
        if case .ready = state { state = .failed(message) }
    }

    func disconnect() {
        connection?.invalidate()
        connection = nil
        state = .idle
    }

    // MARK: - Calls

    func prepare(modelPaths: [ModelID: String],
                 cacheDirectory: URL,
                 compute: ComputePolicy) async throws {
        state = .preparing
        do {
            let config = EngineConfiguration(modelPaths: modelPaths,
                                             modelCacheDirectory: cacheDirectory.path,
                                             compute: compute)
            let payload = try EngineJSON.encode(config)
            let result: EnginePreparation = try await call { engine, reply in
                engine.prepare(configJSON: payload, withReply: reply)
            }
            state = .ready(EnginePreparationSummary(
                executionProvider: result.executionProvider,
                usingCoreML: result.usingCoreML,
                loadedModels: result.loadedModels.map(\.rawValue)))
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func analyzeSource(_ surface: IOSurface) async throws -> SourceAnalysis {
        try await call { engine, reply in
            engine.analyzeSource(surface: surface, withReply: reply)
        }
    }

    func detectFaces(_ surface: IOSurface) async throws -> FrameAnalysis {
        try await call { engine, reply in
            engine.detectFaces(surface: surface, withReply: reply)
        }
    }

    func swap(_ surface: IOSurface,
              into output: IOSurface,
              options: SwapOptions) async throws -> SwapResult {
        let payload = try EngineJSON.encode(options)
        return try await call { engine, reply in
            engine.swap(surface: surface, into: output, optionsJSON: payload, withReply: reply)
        }
    }

    func unloadModels() async {
        guard connection != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard let engine = try? proxy() else { return continuation.resume() }
            engine.unloadModels { continuation.resume() }
        }
    }

    // MARK: - Bridging

    /// Wraps a reply-block XPC call as an async throwing call returning a
    /// decoded payload.
    private func call<T: Decodable>(
        _ body: (FaceFusionEngineProtocol, @escaping (Data?, Error?) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            // XPC guarantees at most one of the reply block or the error
            // handler fires, but a resumed continuation must never be resumed
            // again, so guard it explicitly.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            func finish(_ result: Result<T, Error>) {
                let alreadyResumed = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return done
                }
                guard !alreadyResumed else { return }
                continuation.resume(with: result)
            }

            do {
                let engine = try proxy(onError: { error in finish(.failure(error)) })
                body(engine) { data, error in
                    if let error { return finish(.failure(error)) }
                    guard let data else {
                        return finish(.failure(makeEngineNSError(.inferenceFailed,
                                                                 underlying: "empty reply")))
                    }
                    do { finish(.success(try EngineJSON.decode(T.self, from: data))) }
                    catch { finish(.failure(error)) }
                }
            } catch {
                finish(.failure(error))
            }
        }
    }
}

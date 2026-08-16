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

    /// - Parameter modelDigests: what each file was verified as when it was
    ///   installed. The engine only reads them after preparation has failed
    ///   twice, to work out which model to throw away; see
    ///   `EngineService.discardCorruptModels`.
    func prepare(modelPaths: [ModelID: String],
                 modelDigests: [ModelID: String] = [:],
                 cacheDirectory: URL,
                 compute: ComputePolicy,
                 tuning: EngineTuning = EngineTuning()) async throws {
        state = .preparing
        do {
            let config = EngineConfiguration(modelPaths: modelPaths,
                                             modelCacheDirectory: cacheDirectory.path,
                                             compute: compute,
                                             tuning: tuning,
                                             modelDigests: modelDigests)
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

    func analyzeSource(_ surface: IOSurface,
                       selecting index: Int? = nil) async throws -> SourceAnalysis {
        let selected = index.map(NSNumber.init(value:))
        return try await call { engine, reply in
            engine.analyzeSource(surface: surface, selectedFace: selected, withReply: reply)
        }
    }

    func detectFaces(_ surface: IOSurface) async throws -> FrameAnalysis {
        try await call { engine, reply in
            engine.detectFaces(surface: surface, withReply: reply)
        }
    }

    func analyzeFaces(_ surface: IOSurface,
                      options: AnalysisOptions) async throws -> FrameAnalysis {
        let payload = try EngineJSON.encode(options)
        return try await call { engine, reply in
            engine.analyzeFaces(surface: surface, optionsJSON: payload, withReply: reply)
        }
    }

    func setReferenceFaces(_ set: ReferenceFaceSet) async throws {
        let payload = try EngineJSON.encode(set)
        try await callVoid { engine, reply in
            engine.setReferenceFaces(setJSON: payload, withReply: reply)
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

    /// Closes every ONNX session in the engine process and waits for it to be
    /// done.
    ///
    /// This is the one call that makes deleting a model file safe. The engine
    /// runs `unloadAll` on its barrier queue and replies only afterwards, so by
    /// the time this returns no session — and therefore no mapping of any
    /// weight file — is left in that process. Deleting first and unloading
    /// afterwards would leave the engine reading from an unlinked inode, which
    /// keeps the disk space the user asked for back and hands the next swap
    /// weights that no longer exist.
    ///
    /// The error handler is not decoration. Without it a connection that dies
    /// between the proxy being fetched and the reply arriving means no reply
    /// ever comes, and the removal that awaited this would hang forever with
    /// the user's models still on disk.
    func unloadModels() async {
        defer {
            // The sessions are gone, so `ready` — and the summary of loaded
            // models behind it — is no longer true. Leaving it would show a
            // green engine badge over an engine holding nothing, and let
            // `startEngineIfPossible` return early on the way back up.
            state = .idle
        }
        guard connection != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            func finish() {
                let alreadyResumed = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return done
                }
                guard !alreadyResumed else { return }
                continuation.resume()
            }

            guard let engine = try? proxy(onError: { _ in finish() }) else { return finish() }
            engine.unloadModels { finish() }
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

    /// The same bridging for calls that answer with nothing but success or
    /// failure. Separate rather than generic because XPC reply blocks are
    /// concretely typed, so `(Error?) -> Void` cannot be fed to the decoding
    /// version above.
    private func callVoid(
        _ body: (FaceFusionEngineProtocol, @escaping (Error?) -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            func finish(_ result: Result<Void, Error>) {
                let alreadyResumed = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return done
                }
                guard !alreadyResumed else { return }
                continuation.resume(with: result)
            }

            do {
                let engine = try proxy(onError: { error in finish(.failure(error)) })
                body(engine) { error in
                    if let error { finish(.failure(error)) } else { finish(.success(())) }
                }
            } catch {
                finish(.failure(error))
            }
        }
    }
}

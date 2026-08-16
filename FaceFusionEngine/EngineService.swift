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

                let preparation = try self.prepareRepairingIfNeeded(config)
                EngineLog.engine.info("ready via \(preparation.executionProvider, privacy: .public) in \(preparation.warmupSeconds, format: .fixed(precision: 2))s")
                reply(try EngineJSON.encode(preparation), nil)
            } catch {
                EngineLog.engine.error("prepare failed: \(error.localizedDescription, privacy: .public) [\(String(describing: error), privacy: .public)]")
                reply(nil, Self.transportable(error))
            }
        }
    }

    // MARK: - Preparing, and repairing what stopped it

    /// One preparation attempt, then — if it throws — a second one against an
    /// empty compiled-graph cache.
    ///
    /// This is the cure for a failure that otherwise never ends. ORT reuses a
    /// compiled Core ML artifact because the directory exists, with no integrity
    /// check, and its cache key covers the graph and the EP options but neither
    /// the OS nor the runtime that produced the artifact. So an artifact that
    /// has stopped being loadable — compiled by an older Core ML, or left torn
    /// by a process killed mid-write — is handed back identically on every
    /// launch, and "A model could not be loaded" survives restarts, reinstalls
    /// and everything except deleting the library by hand. Nothing anywhere
    /// deleted that artifact on failure; now something does.
    ///
    /// Deliberately blind to *why* the load failed. Every candidate cause has
    /// the same repair, and a repair that only fires for the cause we happen to
    /// have guessed is a repair that does not ship.
    ///
    /// It has to run here, in the service, inside the barrier that `prepare`
    /// already holds. The app cannot do it: this process owns the sessions that
    /// have the artifacts mapped, and the cache directory in the group container
    /// would be deleted underneath them from the other side of the XPC link.
    /// Inside the barrier, no swap is in flight and no session outlives the
    /// `unloadAll` below.
    private func prepareRepairingIfNeeded(_ config: EngineConfiguration) throws -> EnginePreparation {
        let cacheDirectory = URL(fileURLWithPath: config.modelCacheDirectory, isDirectory: true)
        let marker = CompileCache.markerURL(forCacheDirectory: cacheDirectory)
        let receipt = CompileCache.rebuildReceiptURL(forCacheDirectory: cacheDirectory)

        // Raised across the whole attempt, retry included, and lowered however
        // it ends. What it records is not failure but *interruption*: if this
        // process is killed while Core ML is writing an `.mlmodelc`, nobody
        // lowers it, and the app's next launch wipes the cache instead of
        // trusting a directory tree that was only half copied.
        Self.raiseFlag(marker)
        defer { Self.lowerFlag(marker) }

        do {
            let preparation = try pipeline.prepare(config)
            // Whatever a previous launch could not fix is fixed now, so the
            // rebuild allowance goes back. Usually this unlinks nothing.
            Self.lowerFlag(receipt)
            return preparation
        } catch {
            let first = error as NSError
            EngineLog.engine.error(
                "prepare failed: \(first.localizedDescription, privacy: .public) [\(first.domain, privacy: .public)/\(first.code) \((first.userInfo[NSDebugDescriptionErrorKey] as? String) ?? "-", privacy: .public)]")

            // Once per process, which is the cheap half of the guard and the
            // only half that closes the loop *within* a launch: the app
            // re-prepares as soon as the set of loadable models moves, and a
            // second rebuild in the same process would buy nothing the first
            // did not.
            guard Self.claimRecoveryAttempt() else {
                EngineLog.engine.error("not retrying: this process has already rebuilt the compiled graph cache once")
                throw error
            }

            // And once per install, which is the half that matters. This is an
            // XPC service: it exits with the app, so every launch is a new
            // process with a new allowance, and a process-wide flag alone would
            // still spend a full recompile — plus a full re-hash of the library
            // below — on every launch, for ever, to arrive at the same error.
            // The receipt is what makes "we already tried this and it did not
            // help" outlive the process. It is cleared by a preparation that
            // succeeds, and by the app whenever it wipes the cache itself or
            // the set of installed models changes — i.e. whenever the ground
            // this verdict was reached on has moved.
            guard !FileManager.default.fileExists(atPath: receipt.path) else {
                EngineLog.engine.error(
                    "not retrying: rebuilding the compiled graph cache has already been tried here and did not help; nothing has changed since")
                throw error
            }
            // Written before the wipe, not after, so a process that dies
            // part-way through the rebuild is still recorded as having spent
            // its turn.
            Self.raiseFlag(receipt)

            // Before the delete, not after: these sessions have the artifacts
            // mapped, and unlinking a directory tree out from under them leaves
            // this process reading files with no names.
            pipeline.unloadAll()
            Self.emptyCompiledGraphs(at: cacheDirectory)

            do {
                let preparation = try pipeline.prepare(config)
                EngineLog.engine.notice(
                    "recovered: preparation succeeded after rebuilding the compiled graph cache (first attempt: \(first.localizedDescription, privacy: .public))")
                Self.lowerFlag(receipt)
                return preparation
            } catch {
                let second = error as NSError
                EngineLog.engine.error(
                    "recovery failed: \(second.localizedDescription, privacy: .public) [\(second.domain, privacy: .public)/\(second.code) \((second.userInfo[NSDebugDescriptionErrorKey] as? String) ?? "-", privacy: .public)]")

                // Only now is re-reading the library worth what it costs. Two
                // failed preparations have already ruled out the cache, so the
                // remaining suspect is the weights themselves — and this is the
                // one moment where seconds of I/O buy something.
                pipeline.unloadAll()
                let discarded = Self.discardCorruptModels(config)

                throw Self.annotated(second, with: Self.recoveryNote(first: first,
                                                                     discarded: discarded))
            }
        }
    }

    /// The one recovery this process is allowed, claimed atomically.
    ///
    /// Process-wide rather than per-instance: every incoming connection gets its
    /// own `EngineService`, so a flag on `self` would hand a reconnecting app a
    /// fresh allowance within a single launch. It says nothing about the next
    /// launch — the receipt beside the cache directory is what does that.
    private static let recoverySpent = OSAllocatedUnfairLock(initialState: false)

    private static func claimRecoveryAttempt() -> Bool {
        recoverySpent.withLock { spent in
            if spent { return false }
            spent = true
            return true
        }
    }

    /// Both flags beside the cache directory are zero-byte files whose whole
    /// content is whether they exist, so one pair of helpers serves both.
    private static func raiseFlag(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data().write(to: url, options: .atomic)
    }

    private static func lowerFlag(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes the compiled graphs and puts the empty directory back, so the
    /// retry compiles into somewhere that exists.
    private static func emptyCompiledGraphs(at directory: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            EngineLog.engine.notice("rebuilding the compiled graph cache and preparing again")
        } catch {
            EngineLog.engine.error(
                "could not recreate the compiled graph cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-hashes the installed models and unlinks the ones that no longer match
    /// the manifest.
    ///
    /// The app's install check is a name and a size, which is sound for files
    /// only ever written after being hashed — and says nothing about a file
    /// that rotted afterwards. Deleting only what actually fails its digest is
    /// what keeps the repair proportionate: the user re-downloads one model
    /// rather than the whole 900 MB library, and a model that verifies is not
    /// touched.
    ///
    /// The app publishes install states from `stat`, so an unlinked file reads
    /// as missing the next time it looks and the ordinary download path picks
    /// it up. Nothing here talks to the network; this process has no
    /// entitlement to.
    private static func discardCorruptModels(_ config: EngineConfiguration) -> [ModelID] {
        let fileManager = FileManager.default
        var discarded: [ModelID] = []

        for id in config.modelPaths.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let path = config.modelPaths[id],
                  let expected = config.modelDigests[id]?.lowercased(), !expected.isEmpty,
                  fileManager.fileExists(atPath: path) else { continue }

            guard let actual = try? FileDigest.sha256(ofFileAt: URL(fileURLWithPath: path)) else {
                // Unreadable says nothing about the contents — a disk that
                // errored and a stale set of weights are different discoveries,
                // and deleting on the strength of the first costs a download to
                // correct a guess.
                EngineLog.engine.error(
                    "could not re-read \(id.rawValue, privacy: .public) to check it; left in place")
                continue
            }
            guard actual != expected else { continue }

            try? fileManager.removeItem(atPath: path)
            discarded.append(id)
            EngineLog.engine.error(
                "discarded \(id.rawValue, privacy: .public): its bytes no longer match the digest it was installed under")
        }
        return discarded
    }

    /// What both attempts and the repair amounted to, for the log and for
    /// `NSDebugDescriptionErrorKey`. Never for the user.
    private static func recoveryNote(first: NSError, discarded: [ModelID]) -> String {
        var note = "first attempt: \(first.domain)/\(first.code)"
        if let detail = first.userInfo[NSDebugDescriptionErrorKey] as? String {
            note += " \(detail)"
        }
        note += "; retried against an empty compiled graph cache"
        note += discarded.isEmpty
            ? "; every installed model still matches its digest"
            : "; discarded \(discarded.map(\.rawValue).joined(separator: ","))"
        return note
    }

    /// Rebuilds an error with the whole recovery attempt in its debug
    /// description.
    ///
    /// `localizedDescription` is carried across untouched. That string is what
    /// the user reads, and no surface a user can read names a model — the ids
    /// belong in the log line and in the debug description, which is where
    /// support looks and nothing renders.
    private static func annotated(_ error: NSError, with note: String) -> NSError {
        var detail = note
        if let existing = error.userInfo[NSDebugDescriptionErrorKey] as? String {
            detail = "\(existing); \(note)"
        }
        return NSError(domain: error.domain, code: error.code, userInfo: [
            NSLocalizedDescriptionKey: error.localizedDescription,
            NSDebugDescriptionErrorKey: detail,
        ])
    }

    func unloadModels(withReply reply: @escaping () -> Void) {
        queue.async(flags: .barrier) {
            self.pipeline.unloadAll()
            reply()
        }
    }

    // MARK: - Analysis

    func analyzeSource(surface: IOSurface,
                       selectedFace: NSNumber?,
                       withReply reply: @escaping (Data?, Error?) -> Void) {
        queue.async(flags: .barrier) {
            do {
                let analysis = try BGRAImage.withSurface(surface, readOnly: true) { image in
                    try self.pipeline.analyzeSource(image, selecting: selectedFace?.intValue)
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

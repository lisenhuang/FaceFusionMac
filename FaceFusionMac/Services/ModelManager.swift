//
//  ModelManager.swift
//  FaceFusionMac
//
//  Owns the on-disk model library: what is installed, what is missing, the
//  one-time download that closes the gap, and the removal that gives the disk
//  back.
//
//  Downloads stream to a `.partial` file and resume with a Range request if
//  they are interrupted, then are verified against the SHA-256 in the bundled
//  manifest before being moved into place. A model that fails verification is
//  discarded rather than installed.
//
//  This is the only component in the app that touches the network at all.
//
//  Files are named for their contents: `<id>-<first 16 hex of sha256>.onnx`.
//  The install question is therefore answered by the name, not by a size that
//  two different sets of weights can share — the failure the old scheme could
//  not even detect was a manifest whose digest changed but whose byte count did
//  not, after which the wrong weights were served forever with nothing able to
//  discover it. The cost of that correctness is paid once, by the adoption pass
//  in `reconcileLibrary`, which renames what is already on disk rather than
//  making anyone fetch 900 MB again.
//
//  All of it lives in the App Group container, which is the only ground the app
//  and the separately sandboxed engine process share. That second process is
//  what makes the ordering here matter more than it does on a single-process
//  build: a rename or a delete this file makes lands under an engine that may
//  have the old path memory-mapped, leaving it reading from a file with no
//  name. Two rules keep that from happening, and both are load-bearing —
//  nothing moves while the engine is loaded, which is why the launch pass
//  finishes before `isPreparingLibrary` drops and why `AppModel` does not start
//  the engine until it has; and every removal goes through `AppModel`, which
//  unloads across XPC and waits for the reply before anything is unlinked.
//

import Foundation
import CryptoKit
import Observation
import os

/// `nonisolated`, along with the manifest and the install state below, because
/// the target defaults its types to the main actor and all three are read by
/// the reconcile pass — which runs off it, so that hashing a 900 MB library
/// does not hold up the screen.
nonisolated struct ModelDescriptor: Codable, Identifiable, Sendable {
    var id: String
    var url: URL
    var sha256: String
    var bytes: Int64
    var required: Bool
    // Provenance, kept because the manifest carries it and dropping fields from
    // a decoded shape is how a manifest and its reader stop agreeing. It is
    // data, not copy: nothing renders these, and nothing should.
    var vendor: String
    var license: String

    var modelID: ModelID? { ModelID(rawValue: id) }

    /// The first 16 hex characters — 64 bits — of the manifest digest.
    ///
    /// Long enough that two generations of a model colliding is not something
    /// that happens by accident, and short enough that the file is still
    /// recognisable as a model in a log line, a crash report or a file listing,
    /// which a 64-character digest would drown out.
    var digestPrefix: String { String(sha256.lowercased().prefix(16)) }

    /// Content-addressed, so the name itself answers "are these the right
    /// weights?". Nothing writes to this name without having hashed what it
    /// wrote first, which is what makes the cheap name-and-size check in
    /// `publishInstallStates` sound.
    var fileName: String { "\(id)-\(digestPrefix).onnx" }

    /// What every build before this one wrote. Read exactly once, by the
    /// adoption pass, and never written again.
    var legacyFileName: String { "\(id).onnx" }

    /// Where a download accumulates until it has been verified.
    var partialFileName: String { "\(fileName).partial" }

    /// Identifies the transfer to `Downloader`.
    ///
    /// The digest is in it for the same reason it is in the partial file's
    /// name: a resume payload left over from an older manifest must never be
    /// matched to this descriptor and `Range`-resumed against a different URL,
    /// which would splice the head of one model onto the tail of another and
    /// produce a file that only the checksum could catch — after the whole
    /// download had been paid for.
    var downloadKey: String { "\(id)-\(digestPrefix)" }

    /// What the user is shown. Never `id`: that is the weight file's own name,
    /// and no surface a user can read names a model or where it came from. A
    /// manifest entry the engine does not recognise still has to render as
    /// something, so it renders as what it is.
    var displayName: String { modelID?.displayName ?? "Pipeline Component" }

    var purpose: String { modelID?.purpose ?? "Part of the face swap pipeline." }
}

nonisolated struct ModelManifest: Codable, Sendable {
    var manifestVersion: Int
    var release: String
    var models: [ModelDescriptor]
}

nonisolated enum ModelInstallState: Equatable, Sendable {
    /// The launch pass has not decided yet whether the bytes on disk are these
    /// weights. Deliberately not `missing`: a user who already has the model
    /// must never be shown a download for it, not even for the second it takes
    /// to hash what they have.
    case checking
    case missing
    case downloading(received: Int64, total: Int64)
    case verifying
    case installed
    case failed(String)
}

@MainActor
@Observable
final class ModelManager {

    private(set) var manifest: ModelManifest?
    private(set) var states: [String: ModelInstallState] = [:]
    private(set) var isWorking = false
    private(set) var lastError: String?

    /// True until the launch pass has finished deciding what is on disk.
    ///
    /// Everything that could offer the user a download waits on this, and so
    /// does the engine — see `isReadyToLoad`. The pass takes milliseconds for a
    /// library that is already in the digest-named scheme and seconds for one
    /// that has to be hashed and adopted, and during those seconds "not
    /// installed yet" would be a lie.
    private(set) var isPreparingLibrary = true

    /// Bytes moved during the current download session, for the aggregate bar.
    private(set) var sessionReceived: Int64 = 0
    private(set) var sessionTotal: Int64 = 0

    private var activeTask: Task<Void, Never>?

    /// Partial files this process is in the middle of writing or verifying.
    /// The sweep refuses to touch them; see `sweep`.
    private var inFlightPartials: Set<String> = []

    /// Legacy files the adoption pass deliberately left where they were.
    ///
    /// Adoption spares a file it could not read, or could not move, so that the
    /// next launch can look at it again. That decision is worth nothing if the
    /// sweep — which runs seconds later, and by name — reclaims it on the
    /// grounds that the manifest does not claim that name. Sparing it there is
    /// what turns "try again next launch" back into what it says.
    private var preservedLegacy: Set<String> = []

    private let downloader = Downloader()

    // MARK: - Locations

    /// The App Group both the app and the engine can reach. The two processes
    /// are separately sandboxed, so this shared container is the only place
    /// they can both see the model files.
    nonisolated static let appGroupIdentifier = "HPL74FCW8E.com.lisenhuang.FaceFusionMac"

    /// Resolved once rather than per call: the path cannot change for the
    /// lifetime of the process, and the reconcile pass runs off the main actor,
    /// where a `@MainActor` computed property would not be reachable at all.
    nonisolated static let containerDirectory: URL = {
        if let shared = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return shared
        }
        // Falls back to the app's private container, which still works for
        // downloading and inspecting models even if the group is unavailable —
        // the engine simply will not be able to read them.
        return FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask)[0]
            .appendingPathComponent("FaceFusionMac", isDirectory: true)
    }()

    nonisolated static var modelsDirectory: URL {
        containerDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    /// Where Core ML keeps the graphs it compiles from the ONNX models. Also
    /// in the group container, because the engine is the one writing to it.
    nonisolated static var compileCacheDirectory: URL {
        containerDirectory.appendingPathComponent("CoreMLCompiled", isDirectory: true)
    }

    /// The list of model files the compiled graphs were last reconciled
    /// against. Kept beside the two directories rather than inside either, so
    /// neither the sweep nor a cache wipe has to know about it.
    nonisolated static var compiledFromFile: URL {
        containerDirectory.appendingPathComponent("CompiledFrom.json")
    }

    func location(of descriptor: ModelDescriptor) -> URL {
        Self.modelsDirectory.appendingPathComponent(descriptor.fileName)
    }

    // MARK: - Loading

    init() {
        Self.prepareContainer()
        loadManifest()
        // Two steps, in this order, and the order is the whole point: publish
        // what a `stat` can prove immediately so an up-to-date library shows no
        // flicker at all, then let the launch pass resolve the rest off the
        // main actor before anything is called missing.
        publishInstallStates(unresolved: .checking)
        prepareLibrary()
    }

    /// The download path used to be the only thing that created these, which
    /// left the adoption pass and the sweep reading a directory that need not
    /// exist yet. Cheap enough to do unconditionally.
    private static func prepareContainer() {
        for directory in [modelsDirectory, compileCacheDirectory] {
            do {
                try FileManager.default.createDirectory(at: directory,
                                                        withIntermediateDirectories: true)
            } catch {
                EngineLog.models.error(
                    "Could not create \(directory.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func loadManifest() {
        guard let url = Bundle.main.url(forResource: "models", withExtension: "json") else {
            lastError = "The bundled model manifest is missing from the app."
            return
        }
        do {
            let data = try Data(contentsOf: url)
            manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        } catch {
            lastError = "The model manifest could not be read: \(error.localizedDescription)"
        }
    }

    /// Marks a model installed only when the *digest-named* file is present and
    /// its size matches, so a truncated file is treated as missing rather than
    /// trusted.
    ///
    /// Deliberately not a hash. The name carries the digest, and the only two
    /// things that ever write to that name — a verified download and the
    /// adoption pass — hash before they do, so name plus size says everything
    /// re-reading 900 MB would say and says it in microseconds. Startup is the
    /// worst possible place to spend seconds re-learning what the file is
    /// already called.
    func refreshInstallStates() {
        publishInstallStates(unresolved: .missing)
    }

    /// The shared body of `refreshInstallStates` and the seeding done in
    /// `init`, which differ only in what they call a model they cannot prove is
    /// installed: missing once the launch pass has looked, still being checked
    /// before that.
    private func publishInstallStates(unresolved: ModelInstallState) {
        guard let manifest else { return }
        for descriptor in manifest.models {
            let size = Self.fileSize(at: location(of: descriptor))
            states[descriptor.id] = (size == descriptor.bytes) ? .installed : unresolved
        }
    }

    // MARK: - The launch pass

    /// Reconciles the library with the manifest once, before anything acts on
    /// an install state.
    ///
    /// The work is dispatched rather than awaited: `init` returns immediately
    /// and the first frame of UI draws while the disk is being read.
    private func prepareLibrary() {
        guard let manifest else {
            isPreparingLibrary = false
            return
        }
        let descriptors = manifest.models

        Task { [weak self] in
            guard let self else { return }
            let protected = await self.protectedPartialNames()

            // Hashing a 900 MB library is seconds of `read`, and the actor this
            // object lives on is the one drawing the screen — so all of it goes
            // to a detached task and only the verdicts cross back.
            let outcome = await Task.detached(priority: .utility) {
                Self.reconcileLibrary(descriptors: descriptors,
                                      protectedPartials: protected)
            }.value

            // Every verdict lands in one step, and `isPreparingLibrary` drops
            // in the same one. Reporting them as they were reached would have
            // shown the library filling in, at the cost of publishing a state
            // nothing else in the app is prepared for: `isReady` counts only
            // the required models, so it flips the moment the third of five is
            // adopted, and `ContentView` starts the engine on that. The engine
            // would then snapshot `installedPaths()` on the spot — leaving the
            // landmarker and the enhancer simply absent from a session the UI
            // reports as having them, for the rest of the launch — and it would
            // begin compiling Core ML graphs into a directory this same pass is
            // about to empty, from a second process that has no idea the
            // ground is moving. Deciding the whole library in one move is what
            // makes both impossible.
            // Before the verdicts, because the sweep that runs after the next
            // download reads it and a name arriving late is a name that file
            // was not spared under.
            self.preservedLegacy = outcome.preserved
            for (id, state) in outcome.verdicts { self.states[id] = state }
            self.isPreparingLibrary = false
        }
    }

    /// Adoption, then the sweep, then the compiled graphs — off the main actor,
    /// returning the verdict for every model rather than publishing any of them
    /// itself. The caller publishes the lot at once; see `prepareLibrary` for
    /// why a half-decided library must never be visible.
    ///
    /// Idempotent by construction: every branch is guarded by what is on disk,
    /// so the second run finds the digest-named files already there and does
    /// nothing at all.
    nonisolated private static func reconcileLibrary(
        descriptors: [ModelDescriptor],
        protectedPartials: Set<String>)
    -> (verdicts: [String: ModelInstallState], preserved: Set<String>) {

        var verdicts: [String: ModelInstallState] = [:]
        var preserved: Set<String> = []
        var installed: Set<String> = []
        for descriptor in descriptors {
            let state = adopt(descriptor, preserving: &preserved)
            if state == .installed { installed.insert(descriptor.id) }
            verdicts[descriptor.id] = state
        }

        // Rule two of the sweep: a half-finished migration means the previous
        // generation is the only working copy the user has, and reclaiming it
        // would leave them with an app that cannot swap a face. Waiting costs
        // disk until the download that completes the set; not waiting costs
        // them the app.
        // Counted from the required set alone. `installed` holds the optional
        // models too, so subtracting its size from the required count reports a
        // negative number on exactly the library this line exists to explain.
        let outstanding = descriptors.filter { $0.required && !installed.contains($0.id) }
        if outstanding.isEmpty {
            sweep(keeping: descriptors,
                  protecting: protectedPartials,
                  sparing: preserved)
        } else {
            EngineLog.models.notice(
                "deferred the model sweep: \(outstanding.count) required model(s) still missing")
        }

        reconcileCompileCache()
        return (verdicts, preserved)
    }

    /// Decides what one model's bytes on disk are worth, adopting the legacy
    /// file when they turn out to be exactly the weights the manifest asks for.
    ///
    /// This is the part of the change that exists so that nobody re-downloads
    /// anything: an existing library is ~900 MB written under the old names,
    /// and looking only for digest-named files would make every byte of it
    /// invisible.
    ///
    /// A legacy file is deleted only where its bytes have been *shown* to be
    /// the wrong ones. Where the pass could not find that out — it could not
    /// read the file, or could not rename it — the name goes into `preserving`
    /// instead, which spares it from the sweep and leaves it for the next
    /// launch to try again.
    nonisolated private static func adopt(_ descriptor: ModelDescriptor,
                                          preserving preserved: inout Set<String>) -> ModelInstallState {
        let fileManager = FileManager.default
        let destination = modelsDirectory.appendingPathComponent(descriptor.fileName)
        if fileSize(at: destination) == descriptor.bytes { return .installed }

        let legacy = modelsDirectory.appendingPathComponent(descriptor.legacyFileName)
        guard let legacySize = fileSize(at: legacy) else { return .missing }

        guard legacySize == descriptor.bytes else {
            // The size-only scheme this replaces would have called it missing
            // too, so nothing usable is being thrown away.
            try? fileManager.removeItem(at: legacy)
            return .missing
        }

        guard let digest = try? sha256(of: legacy) else {
            // The file could not be read through, which says nothing at all
            // about whether it is the right file — a disk that returned an
            // error and a stale set of weights are not the same discovery, and
            // collapsing the two costs the user a 300 MB download to correct a
            // guess. It stays where it is, and the sweep is told to leave it.
            preserved.insert(descriptor.legacyFileName)
            EngineLog.models.error(
                "could not read \(descriptor.id, privacy: .public) to check it; left for the next launch")
            return .missing
        }

        guard digest == descriptor.sha256.lowercased() else {
            // Right size, wrong bytes: stale or corrupt, and the old scheme had
            // no way to notice. These are precisely the weights that would
            // otherwise have been served to the engine forever.
            try? fileManager.removeItem(at: legacy)
            EngineLog.models.notice(
                "discarded \(descriptor.id, privacy: .public): it was the expected size but not the expected weights")
            return .missing
        }

        do {
            // A truncated file may already sit under the new name; the verified
            // legacy copy is strictly better than whatever that is.
            try? fileManager.removeItem(at: destination)
            // A rename, not a copy: same directory, same volume, so this is
            // `rename(2)` — instant, atomic, and needing no second 300 MB of
            // free space to hold a duplicate while it runs.
            try fileManager.moveItem(at: legacy, to: destination)
            EngineLog.models.notice(
                "adopted \(descriptor.id, privacy: .public) under its digest name; no download needed")
            return .installed
        } catch {
            // The bytes are verified and it is only the rename that failed, so
            // this is the last file on disk the sweep should be reclaiming.
            preserved.insert(descriptor.legacyFileName)
            EngineLog.models.error(
                "could not adopt \(descriptor.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .missing
        }
    }

    /// Deletes everything in the models directory the current manifest does not
    /// claim: earlier generations of a model whose digest moved, ids that were
    /// renamed or dropped, and partial downloads nobody is waiting for. Nothing
    /// else ever reclaims those bytes, so without this they leak for the life
    /// of the install.
    ///
    /// The caller decides *when* it is safe to run — see the completeness rule
    /// in `reconcileLibrary`. This function enforces the other rule: a partial
    /// belonging to a live transfer is not litter.
    ///
    /// A legacy file `adopt` could not settle is spared as well. Adoption
    /// leaving it for the next launch and the sweep deleting it on this one
    /// cannot both be the policy, and of the two only one ever costs a
    /// re-download.
    nonisolated private static func sweep(keeping descriptors: [ModelDescriptor],
                                          protecting protectedPartials: Set<String>,
                                          sparing preserved: Set<String>) {
        let fileManager = FileManager.default
        let claimed = Set(descriptors.map(\.fileName))
        guard let entries = try? fileManager.contentsOfDirectory(
            at: modelsDirectory, includingPropertiesForKeys: nil) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            // Content-addressed names are what make it safe to be this blunt:
            // anything the manifest still wants is named after a digest the
            // manifest still lists, so two generations could sit here side by
            // side if a future build ever wanted them to.
            if claimed.contains(name)
                || protectedPartials.contains(name)
                || preserved.contains(name) { continue }
            try? fileManager.removeItem(at: entry)
            EngineLog.models.notice("swept \(name, privacy: .public)")
        }
    }

    /// Throws away compiled graphs that nothing can ask for any more.
    ///
    /// ORT names each entry in that directory from a hash of its own —
    /// `COREML_<hash>_<n>` — and nothing in the name says which model produced
    /// it, so an entry cannot be mapped back to a file. The hash covers the
    /// model ORT compiled, its file name included, which means the adoption
    /// rename gives the very same weights a new key. That is correct, and worth
    /// the recompile it costs on the first launch after adoption: a graph built
    /// from the old file must never be handed back for a file that only happens
    /// to share an id. But it also leaves the old entry unreachable, and
    /// unreachable entries here are hundreds of megabytes.
    ///
    /// So the model file names are tracked instead. A name that was present at
    /// the last reconcile and is gone now means whatever was compiled from it
    /// is dead weight, and since the entries cannot be told apart the cache goes
    /// wholesale. Names that only *appear* change nothing — a new model simply
    /// compiles and adds an entry — so they do not trigger a wipe.
    ///
    /// The directory belongs to the engine process, which is the reason this
    /// runs where it does rather than anywhere more convenient: it is the one
    /// moment in the app's life when no engine exists to be compiling into it.
    nonisolated private static func reconcileCompileCache() {
        let fileManager = FileManager.default
        let present = Set(((try? fileManager.contentsOfDirectory(atPath: modelsDirectory.path)) ?? [])
            .filter { $0.hasSuffix(".onnx") })

        // No record at all is the update to this scheme itself: whatever is in
        // there was compiled by a build that named its models the old way, and
        // the adoption pass has just renamed every one of them. A record of
        // *nothing* is different — that is a library that has never compiled
        // anything — so the two cases must not be collapsed.
        let entries = (try? fileManager.contentsOfDirectory(atPath: compileCacheDirectory.path)) ?? []
        let stale = compiledFromNames().map { !$0.isSubset(of: present) } ?? !entries.isEmpty

        if stale {
            try? fileManager.removeItem(at: compileCacheDirectory)
            try? fileManager.createDirectory(at: compileCacheDirectory,
                                             withIntermediateDirectories: true)
            EngineLog.models.notice(
                "cleared the compiled graph cache: the models it was built from are gone")
        }
        recordCompiledFrom(present)
    }

    /// The recorded file names, or `nil` when nothing has ever been recorded.
    nonisolated private static func compiledFromNames() -> Set<String>? {
        guard let data = try? Data(contentsOf: compiledFromFile),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return Set(names)
    }

    nonisolated private static func recordCompiledFrom(_ names: Set<String>) {
        guard let data = try? JSONEncoder().encode(names.sorted()) else { return }
        try? data.write(to: compiledFromFile, options: .atomic)
    }

    /// Size in bytes, or `nil` when there is no file there at all — a
    /// distinction `attributesOfItem` collapses and both callers need.
    nonisolated private static func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    /// The partial files no sweep may touch: one for every transfer this
    /// process is writing or verifying, and one for every transfer the
    /// downloader still has work for, including a resume payload waiting to be
    /// picked up again.
    private func protectedPartialNames() async -> Set<String> {
        var names = inFlightPartials
        for key in await downloader.activeKeys() {
            // The key is the digest-named file without its extension, which is
            // exactly what `download` stages under.
            names.insert("\(key).onnx.partial")
        }
        return names
    }

    // MARK: - Queries

    var requiredModels: [ModelDescriptor] { manifest?.models.filter(\.required) ?? [] }
    var optionalModels: [ModelDescriptor] { manifest?.models.filter { !$0.required } ?? [] }

    func isInstalled(_ descriptor: ModelDescriptor) -> Bool {
        states[descriptor.id] == .installed
    }

    /// True once every required model is present — the point at which the app
    /// becomes fully usable offline.
    var isReady: Bool {
        !requiredModels.isEmpty && requiredModels.allSatisfy(isInstalled)
    }

    /// True once the library is both complete *and* decided.
    ///
    /// The engine waits on this rather than on `isReady`. A library already in
    /// the digest-named scheme satisfies `isReady` from the seeded publish in
    /// `init`, before the pass has run — and starting the engine there would
    /// put a second process to work compiling graphs into a directory
    /// `reconcileCompileCache` is still entitled to empty.
    var isReadyToLoad: Bool { isReady && !isPreparingLibrary }

    /// Exactly which models the engine ought to be running on, or `nil` while
    /// the library is still being decided or is missing something required.
    ///
    /// The set, not a flag, because `isReadyToLoad` cannot see an *optional*
    /// model arriving or leaving — it counts only the required three. A user who
    /// reclaims the enhancer's disk and later downloads it again from Settings
    /// would otherwise leave the engine running the session it built without
    /// one, and the pipeline skips a stage it has no model for rather than
    /// complaining: the toggle stays on, the result never changes, and nothing
    /// says why until the app is relaunched.
    var loadableModels: Set<ModelID>? {
        guard isReadyToLoad else { return nil }
        return Set(installedPaths().keys)
    }

    /// Waits for the launch pass to finish.
    ///
    /// The UI never needs this — it observes `isPreparingLibrary` and redraws.
    /// The headless modes do: `--selftest`, `--benchmark` and `--profile` run
    /// straight off `applicationDidFinishLaunching`, and reading an install
    /// state there would catch the library mid-decision and report a model that
    /// is about to be adopted as one that has to be downloaded.
    func waitUntilLibraryPrepared() async {
        while isPreparingLibrary {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    var missingRequired: [ModelDescriptor] { requiredModels.filter { !isInstalled($0) } }

    /// Total bytes still to fetch for the given set.
    func downloadSize(for descriptors: [ModelDescriptor]) -> Int64 {
        descriptors.filter { !isInstalled($0) }.reduce(0) { $0 + $1.bytes }
    }

    /// What the given set currently occupies.
    ///
    /// Taken from the manifest rather than from `stat`, which costs nothing and
    /// is exact: a model only counts as installed when its size already matches
    /// the manifest to the byte.
    func installedBytes(of descriptors: [ModelDescriptor]) -> Int64 {
        descriptors.filter(isInstalled).reduce(0) { $0 + $1.bytes }
    }

    /// What the whole library occupies, for the Settings window.
    var installedBytes: Int64 { installedBytes(of: manifest?.models ?? []) }

    /// Absolute paths of everything installed, keyed for the engine.
    func installedPaths() -> [ModelID: String] {
        guard let manifest else { return [:] }
        var paths: [ModelID: String] = [:]
        for descriptor in manifest.models where isInstalled(descriptor) {
            if let id = descriptor.modelID {
                paths[id] = location(of: descriptor).path
            }
        }
        return paths
    }

    // MARK: - Installing

    func install(_ descriptors: [ModelDescriptor]) {
        // Nothing is fetched until the launch pass has finished: a model it is
        // about to adopt still looks uninstalled while it is being hashed, and
        // downloading it again would be exactly the 900 MB this change exists
        // to save.
        guard !isWorking, !isPreparingLibrary else { return }
        let pending = descriptors.filter { !isInstalled($0) }
        guard !pending.isEmpty else { return }

        isWorking = true
        lastError = nil
        sessionReceived = 0
        sessionTotal = pending.reduce(0) { $0 + $1.bytes }

        activeTask = Task { [weak self] in
            guard let self else { return }
            for descriptor in pending {
                if Task.isCancelled { break }
                do {
                    try await self.download(descriptor)
                    self.states[descriptor.id] = .installed
                } catch is CancellationError {
                    self.states[descriptor.id] = .missing
                    break
                } catch {
                    self.states[descriptor.id] = .failed(error.localizedDescription)
                    self.lastError = "\(descriptor.displayName): \(error.localizedDescription)"
                }
            }
            self.isWorking = false
            self.refreshInstallStates()
            await self.sweepIfComplete()
        }
    }

    /// Retries the sweep the launch pass may have deferred.
    ///
    /// This is the moment a half-finished migration finishes: the download that
    /// completes the required set is also the download after which the previous
    /// generation stops being anybody's only working copy.
    ///
    /// The compiled graphs are left alone here even though some of them have
    /// just been orphaned — the engine process may be running on the others,
    /// and `reconcileCompileCache` will notice the files that went away at the
    /// next launch, before anything is loaded.
    private func sweepIfComplete() async {
        guard let manifest, isReady else { return }
        let descriptors = manifest.models
        let protected = await protectedPartialNames()
        let preserved = preservedLegacy
        await Task.detached(priority: .utility) {
            Self.sweep(keeping: descriptors, protecting: protected, sparing: preserved)
        }.value
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        isWorking = false
    }

    // MARK: - Removing

    /// Removes one model from disk.
    ///
    /// The caller unloads the engine first — `AppModel.removeModels` is the
    /// only route in, and it is where the XPC ordering lives. The compiled
    /// graphs built from this file are left behind on purpose: they cannot be
    /// told apart from the ones the remaining models are still using, and the
    /// next launch's `reconcileCompileCache` reclaims them wholesale once it
    /// sees the file name has gone.
    func remove(_ descriptor: ModelDescriptor) {
        try? FileManager.default.removeItem(at: location(of: descriptor))
        // The staging file too, if one is sitting there awaiting verification:
        // it is the same weights, and a user reclaiming disk did not mean "all
        // but 300 MB of it". Any resume payload the downloader still holds is
        // left alone deliberately — it is keyed by the digest, so it can only
        // ever be applied to these exact weights, and re-downloading after a
        // removal should pick up where it stopped rather than start over.
        try? FileManager.default.removeItem(
            at: Self.modelsDirectory.appendingPathComponent(descriptor.partialFileName))
        states[descriptor.id] = .missing
        EngineLog.models.notice("removed \(descriptor.id, privacy: .public)")
    }

    /// Reclaims the whole library.
    ///
    /// The compiled Core ML graphs go with it: they are derived from the files
    /// being deleted, they are a large fraction of the container, and leaving
    /// them behind would mean "remove all models" did not free what the user
    /// was shown. The caller is expected to have unloaded the engine first —
    /// deleting a graph a live session has memory-mapped leaves that session,
    /// in another process, working from a file with no name.
    func removeAll() {
        let fileManager = FileManager.default
        // The directories, not the manifest's list of names: a generation the
        // manifest has moved on from still occupies the user's disk, and a
        // "remove all models" that leaves 300 MB of it behind is a lie told to
        // the number on the Settings window.
        for directory in [Self.modelsDirectory, Self.compileCacheDirectory] {
            try? fileManager.removeItem(at: directory)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        Self.recordCompiledFrom([])
        // Nothing is being kept for a later adoption attempt now that the user
        // has asked for all of it gone, and a name left here would have the next
        // sweep sparing a file that no longer exists.
        preservedLegacy.removeAll()
        refreshInstallStates()
        lastError = nil
        EngineLog.models.notice("removed the model library and the compiled graph cache")
    }

    // MARK: - Download

    private func download(_ descriptor: ModelDescriptor) async throws {
        let destination = location(of: descriptor)
        let staged = destination.appendingPathExtension("partial")
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: Self.modelsDirectory,
                                        withIntermediateDirectories: true)

        states[descriptor.id] = .downloading(received: 0, total: descriptor.bytes)
        let baseline = sessionReceived

        // Claim the staging file for as long as it is ours, so a sweep running
        // alongside this download reads it as work in progress rather than as
        // an orphan.
        inFlightPartials.insert(descriptor.partialFileName)
        defer { inFlightPartials.remove(descriptor.partialFileName) }

        try await downloader.download(key: descriptor.downloadKey,
                                      from: descriptor.url,
                                      to: staged) { [weak self] written, _ in
            // URLSession calls this from its own queue.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.states[descriptor.id] = .downloading(received: written,
                                                          total: descriptor.bytes)
                self.sessionReceived = baseline + written
            }
        }

        // Verify before installing. A mismatch means a corrupted or substituted
        // file, and installing it would hand unverified weights to the engine.
        states[descriptor.id] = .verifying
        let path = staged
        let digest = try await Task.detached(priority: .userInitiated) {
            try ModelManager.sha256(of: path)
        }.value

        guard digest == descriptor.sha256.lowercased() else {
            try? fileManager.removeItem(at: staged)
            await downloader.discardResumeData(for: descriptor.downloadKey)
            throw ModelError.checksum(expected: descriptor.sha256, actual: digest)
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staged, to: destination)
        sessionReceived = baseline + descriptor.bytes
    }

    /// Streaming SHA-256 so a 300 MB model never lands in memory whole.
    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 4 << 20)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum ModelError: LocalizedError {
    case transport(String)
    case checksum(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .transport(let message):
            return message
        case .checksum:
            return "The downloaded file did not match its expected checksum and was discarded."
        }
    }
}

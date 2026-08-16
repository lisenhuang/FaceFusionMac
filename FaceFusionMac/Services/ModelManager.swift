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
import Observation
import os

/// `nonisolated`, along with the manifest and the install state below, because
/// the target defaults its types to the main actor and all three are read by
/// the reconcile pass — which runs off it, so that hashing a 900 MB library
/// does not hold up the screen.
nonisolated struct ModelDescriptor: Codable, Identifiable, Sendable {
    var id: String
    var url: URL
    /// Further hosts carrying the identical file, tried in order after `url`.
    ///
    /// Optional rather than a defaulted array because a synthesised `Decodable`
    /// has no notion of a default: a plain `[URL]` would make every entry that
    /// lists no alternate fail to decode, which is the one thing a manifest
    /// field added to a shipped reader must not do.
    ///
    /// Every source is one host we do not own, and any of them can be deleted,
    /// retagged or made private without notice. Existing installs survive that
    /// because their weights are already on disk; a fresh install has nothing,
    /// so a single source is a single point at which the app stops working for
    /// everybody who has not run it yet.
    var mirrors: [URL]?
    var sha256: String
    var bytes: Int64
    var required: Bool
    // Provenance, kept because the manifest carries it and dropping fields from
    // a decoded shape is how a manifest and its reader stop agreeing. It is
    // data, not copy: nothing renders these, and nothing should.
    var vendor: String
    var license: String

    var modelID: ModelID? { ModelID(rawValue: id) }

    /// Everywhere these exact bytes can be fetched from, in the order to try.
    ///
    /// The digest and the byte count sit on the model rather than on any one of
    /// these deliberately: they are properties of the file, and the whole reason
    /// a second host is safe to add is that it has to produce the same file or
    /// its download is thrown away. Adding a source therefore cannot weaken what
    /// gets installed — it can only change who answered.
    var sources: [URL] { [url] + (mirrors ?? []) }

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
    ///
    /// The key alone stopped being enough once a model could name more than one
    /// source: two entries in `sources` share this key by construction, so the
    /// payload also has to remember which of them it came from. `Downloader`
    /// holds that half of the rule.
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

/// What the compiled Core ML graphs were last built from, and on.
///
/// The shipped build recorded the model file names alone, which answers exactly
/// one question: has a model these graphs were compiled from gone away? Every
/// other question ORT answers by *existence* — it reuses a compiled artifact
/// because the directory is there, with no integrity check, and its own cache
/// key covers the graph, the partition ordinal and the EP options while
/// containing neither an OS version nor a runtime version. So an artifact
/// compiled by an older Core ML is handed straight to a newer one, which is the
/// shape of failure that bricks an install: the same load error on every launch,
/// indefinitely, over a library the app correctly reports as complete.
///
/// Everything ORT's key leaves out is therefore recorded here, and any change to
/// it wipes. The names keep their own, weaker rule — see `reconcileCompileCache`
/// — because a manifest that grows must not cost a full recompile.
nonisolated struct CompileFingerprint: Codable, Equatable, Sendable {
    /// Sorted, so the record is stable and diffable.
    var modelFileNames: [String]
    var osVersion: String
    var hardware: String
    var appBuild: String
    /// The three provider options that appear in ORT's own cache path. Recorded
    /// even though ORT keys on them, because a build that changes what it asks
    /// for leaves the previous artifacts unreachable rather than invalid, and
    /// unreachable artifacts here are hundreds of megabytes.
    var computeUnits: String
    var modelFormat: String
    var staticInputShapes: Bool

    /// Everything except the names, which are compared by the subset rule
    /// instead. Any difference here means the artifacts were built under
    /// conditions that no longer hold.
    func matchesEnvironment(of other: CompileFingerprint) -> Bool {
        osVersion == other.osVersion
            && hardware == other.hardware
            && appBuild == other.appBuild
            && computeUnits == other.computeUnits
            && modelFormat == other.modelFormat
            && staticInputShapes == other.staticInputShapes
    }

    /// The conditions this launch would compile under.
    ///
    /// The shipping settings, not whatever the benchmark is about to sweep:
    /// `--benchmark` prepares under seven configurations in one run, and letting
    /// the last of them write the record would describe the machine as
    /// permanently running a configuration it was measured in for ten seconds.
    ///
    /// Including the app build means an update wipes the cache and recompiles.
    /// That is the intended price: an update is exactly when the runtime, the
    /// options or the graphs may have moved, and a recompile a user waits
    /// through once is cheaper than the failure this exists to prevent.
    static func current(modelFileNames: Set<String>) -> CompileFingerprint {
        let tuning = EngineTuning()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return CompileFingerprint(
            modelFileNames: modelFileNames.sorted(),
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            hardware: hardwareIdentifier(),
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            computeUnits: ComputePolicy.automatic.mlComputeUnits,
            modelFormat: tuning.modelFormat,
            staticInputShapes: tuning.requireStaticInputShapes)
    }

    /// `hw.model` — "Mac15,3" and the like. The Neural Engine, the GPU and what
    /// Core ML will compile for differ across these, and a Group Container can
    /// move between two Macs by restore or migration with the compiled graphs
    /// inside it.
    private static func hardwareIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }
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

    /// The marker the engine holds while it may be compiling. Written and
    /// deleted by the other process; read here, at the one moment no engine
    /// exists. See `CompileCache.markerURL`.
    nonisolated static var compileMarkerFile: URL {
        CompileCache.markerURL(forCacheDirectory: compileCacheDirectory)
    }

    /// The engine's record that rebuilding the cache has already been tried
    /// here and did not help. Written by the other process; cleared here
    /// whenever what it was decided on has changed. See
    /// `CompileCache.rebuildReceiptURL`.
    nonisolated static var compileRebuildReceiptFile: URL {
        CompileCache.rebuildReceiptURL(forCacheDirectory: compileCacheDirectory)
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
    /// The names are necessary and were never sufficient. They say nothing about
    /// the *machine* the graphs were compiled for, and ORT's own cache key says
    /// nothing about it either, so this also compares the fingerprint recorded
    /// beside them — see `CompileFingerprint` — and honours the marker the
    /// engine leaves behind when a compile is cut short. Either of those is a
    /// wipe on its own.
    ///
    /// The directory belongs to the engine process, which is the reason this
    /// runs where it does rather than anywhere more convenient: it is the one
    /// moment in the app's life when no engine exists to be compiling into it.
    /// That ordering is still what it was — the whole launch pass finishes
    /// before `isPreparingLibrary` drops, `loadableModels` is nil until it does,
    /// and every route that starts an engine waits on one or the other.
    nonisolated private static func reconcileCompileCache() {
        let fileManager = FileManager.default
        let present = installedFileNames()
        let entries = (try? fileManager.contentsOfDirectory(atPath: compileCacheDirectory.path)) ?? []

        var reason: String?
        // Whether the library itself has moved since the record was written, in
        // either direction. Not a reason to wipe — a name that only *appears*
        // costs nothing — but it is a reason to let the engine try rebuilding
        // again, because a graph it could not compile before may be one it has
        // never seen. Unknown counts as changed.
        var namesChanged = true
        switch readCompiledFrom() {
        case .fingerprint(let recorded):
            namesChanged = Set(recorded.modelFileNames) != present
            if !Set(recorded.modelFileNames).isSubset(of: present) {
                // The original rule, and still deliberately a subset test:
                // names that only *appear* change nothing, so downloading an
                // optional model adds an entry rather than costing the whole
                // library a recompile.
                reason = "the models it was built from are gone"
            } else if !recorded.matchesEnvironment(of: .current(modelFileNames: present)) {
                reason = "it was built on a different system, device or build"
            }
        case .legacyNames:
            // The plain array of names every build up to this one wrote. The
            // names are still true; nothing else about the machine that
            // compiled those graphs is knowable, and unknown has to mean wipe —
            // an artifact built under conditions that cannot be seen is
            // precisely the one that cannot be trusted. It costs one recompile,
            // once, because the record written below is the new shape.
            reason = "it was built by a version that did not record what it was built on"
        case .none:
            // No record at all against a directory that holds something: the
            // graphs in there were compiled by something that never said what
            // from. A record of *nothing* is a different thing — a library that
            // has never compiled anything — and the two must not be collapsed,
            // which is why this asks the directory rather than the record.
            reason = entries.isEmpty ? nil : "there is no record of what it was built from"
        }

        // Independent of everything above, and checked separately because it
        // means something different: the engine was compiling when it stopped.
        // An `.mlmodelc` is a directory tree written item by item and ORT's only
        // reuse test is that it exists, so a half-written one is indistinguishable
        // from a finished one — except by this.
        let interrupted = fileManager.fileExists(atPath: compileMarkerFile.path)

        // An interrupted compile outranks the rest as an explanation: it is the
        // one that says the directory may contain something that is not a model
        // at all.
        let cause: String? = interrupted ? "a compile did not finish" : reason
        if let cause {
            try? fileManager.removeItem(at: compileCacheDirectory)
            try? fileManager.createDirectory(at: compileCacheDirectory,
                                             withIntermediateDirectories: true)
            EngineLog.models.notice(
                "cleared the compiled graph cache: \(cause, privacy: .public)")
        }
        // Whether or not it fired: a marker whose engine died is spent once it
        // has been acted on, and leaving it would wipe again at every launch.
        try? fileManager.removeItem(at: compileMarkerFile)
        // The engine's "rebuilding this did not help" verdict was reached
        // against a particular cache and a particular library. Both of those
        // are what just changed, so the verdict no longer applies and the
        // engine gets its one rebuild back.
        if cause != nil || namesChanged {
            try? fileManager.removeItem(at: compileRebuildReceiptFile)
        }
        recordCompiledFrom(present)
    }

    /// The `.onnx` files currently in the models directory.
    nonisolated private static func installedFileNames() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path)) ?? [])
            .filter { $0.hasSuffix(".onnx") })
    }

    /// What is on disk at `compiledFromFile`, in either shape it can take.
    nonisolated private enum CompiledFromRecord {
        case fingerprint(CompileFingerprint)
        /// The bare JSON array of file names written by every build before this
        /// one. Present on every existing install at its first launch after the
        /// update, which is why decoding has to *accept* it rather than throw
        /// or, worse, read it as an empty fingerprint that matches everything.
        case legacyNames(Set<String>)
    }

    /// Reads the record, tolerating the old format.
    ///
    /// Order matters only in that the two shapes are mutually exclusive: a JSON
    /// array cannot decode into a keyed struct and an object cannot decode into
    /// `[String]`, so neither branch can claim the other's file. Anything that
    /// is neither — truncated, or written by a build from the future — reads as
    /// no record at all, which is the conservative answer.
    nonisolated private static func readCompiledFrom() -> CompiledFromRecord? {
        guard let data = try? Data(contentsOf: compiledFromFile) else { return nil }
        if let record = try? JSONDecoder().decode(CompileFingerprint.self, from: data) {
            return .fingerprint(record)
        }
        if let names = try? JSONDecoder().decode([String].self, from: data) {
            return .legacyNames(Set(names))
        }
        return nil
    }

    nonisolated private static func recordCompiledFrom(_ names: Set<String>) {
        guard let data = try? JSONEncoder().encode(CompileFingerprint.current(modelFileNames: names)) else {
            return
        }
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

    /// The manifest digest of everything installed, sent alongside the paths.
    ///
    /// The engine cannot ask for these when it needs them — it needs them
    /// inside the barrier that is holding a reply — and it has no manifest of
    /// its own. Nothing reads them on a healthy launch; see
    /// `EngineService.discardCorruptModels` for the one case that does.
    func installedDigests() -> [ModelID: String] {
        guard let manifest else { return [:] }
        var digests: [ModelID: String] = [:]
        for descriptor in manifest.models where isInstalled(descriptor) {
            if let id = descriptor.modelID {
                digests[id] = descriptor.sha256.lowercased()
            }
        }
        return digests
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
    /// only route in, and it is where the XPC ordering lives. It also calls
    /// `discardCompiledGraphs` once the loop is done, which is what keeps the
    /// record and the directory agreeing; see there for why leaving that to the
    /// next launch was wrong.
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

    /// Throws away the compiled graphs after a removal and re-records what is
    /// left.
    ///
    /// A removal used to leave the record naming a file it had just deleted,
    /// which is not harmless: `reconcileCompileCache` then finds recorded ⊄
    /// present and wipes — at some later cold launch, as an unexplained slow
    /// start with nothing on screen to connect it to what the user did. The
    /// recompile is owed either way, because the entries here cannot be mapped
    /// back to the model that produced them and so cannot be pruned selectively.
    /// Paying it now puts it under the user's own action, next to a Settings
    /// window that has already said the compiled graphs go too.
    ///
    /// Safe only in this order: every removal goes through
    /// `AppModel.removeModels`, which has unloaded the engine across XPC and
    /// waited for the reply, so no session in the other process has any of these
    /// artifacts mapped.
    func discardCompiledGraphs() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: Self.compileCacheDirectory)
        try? fileManager.createDirectory(at: Self.compileCacheDirectory,
                                         withIntermediateDirectories: true)
        try? fileManager.removeItem(at: Self.compileMarkerFile)
        try? fileManager.removeItem(at: Self.compileRebuildReceiptFile)
        Self.recordCompiledFrom(Self.installedFileNames())
        EngineLog.models.notice("cleared the compiled graph cache after a removal")
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
        // Both flags sit beside the cache rather than inside it, so emptying the
        // directory does not clear them — and a marker left here would have the
        // next launch wiping a cache built after the user asked for a clean
        // start, while a rebuild receipt left here would deny the engine the one
        // repair it is allowed over a library that is about to be re-downloaded
        // from scratch.
        try? fileManager.removeItem(at: Self.compileMarkerFile)
        try? fileManager.removeItem(at: Self.compileRebuildReceiptFile)
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
                                      from: descriptor.sources,
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
    ///
    /// The implementation moved to `Shared/` when the engine gained a reason to
    /// hash the same files from the other process: two copies of a digest is
    /// two ways to disagree about whether a file is the one the manifest names.
    nonisolated static func sha256(of url: URL) throws -> String {
        try FileDigest.sha256(ofFileAt: url)
    }
}

enum ModelError: LocalizedError {
    case transport(String)
    /// Every source for a model failed. Only `Downloader` throws it, and only
    /// after it has tried all of them.
    case noSourceReachable
    case checksum(expected: String, actual: String)

    /// What the user is told. `lastError` and `.failed` both end up on screen,
    /// which is why the download failure says nothing about *where* the app was
    /// downloading from: the app does not name the hosts it fetches weights
    /// from, and a message quoting the one that refused would do exactly that.
    /// The system's own `URLError` descriptions are not safe here for the same
    /// reason — several of them are written by quoting the server.
    var errorDescription: String? {
        switch self {
        case .transport(let message):
            return message
        case .noSourceReachable:
            return "The download could not be completed. Check your internet connection and try again."
        case .checksum:
            return "The downloaded file did not match its expected checksum and was discarded."
        }
    }
}

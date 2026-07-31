//
//  ModelManager.swift
//  FaceFusionMac
//
//  Owns the on-disk model library: what is installed, what is missing, and the
//  one-time download that closes the gap.
//
//  Downloads stream to a `.partial` file and resume with a Range request if
//  they are interrupted, then are verified against the SHA-256 in the bundled
//  manifest before being moved into place. A model that fails verification is
//  discarded rather than installed.
//
//  This is the only component in the app that touches the network at all.
//

import Foundation
import CryptoKit
import Observation

struct ModelDescriptor: Codable, Identifiable, Sendable {
    var id: String
    var url: URL
    var sha256: String
    var bytes: Int64
    var required: Bool
    var vendor: String
    var license: String

    var modelID: ModelID? { ModelID(rawValue: id) }
    var fileName: String { "\(id).onnx" }
}

struct ModelManifest: Codable, Sendable {
    var manifestVersion: Int
    var release: String
    var models: [ModelDescriptor]
}

enum ModelInstallState: Equatable, Sendable {
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

    /// Bytes moved during the current download session, for the aggregate bar.
    private(set) var sessionReceived: Int64 = 0
    private(set) var sessionTotal: Int64 = 0

    private var activeTask: Task<Void, Never>?
    private let downloader = Downloader()

    // MARK: - Locations

    /// The App Group both the app and the engine can reach. The two processes
    /// are separately sandboxed, so this shared container is the only place
    /// they can both see the model files.
    static let appGroupIdentifier = "HPL74FCW8E.com.lisenhuang.FaceFusionMac"

    static var containerDirectory: URL {
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
    }

    static var modelsDirectory: URL {
        containerDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    /// Where Core ML keeps the graphs it compiles from the ONNX models. Also
    /// in the group container, because the engine is the one writing to it.
    static var compileCacheDirectory: URL {
        containerDirectory.appendingPathComponent("CoreMLCompiled", isDirectory: true)
    }

    func location(of descriptor: ModelDescriptor) -> URL {
        Self.modelsDirectory.appendingPathComponent(descriptor.fileName)
    }

    // MARK: - Loading

    init() {
        loadManifest()
        refreshInstallStates()
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

    /// Marks a model installed only when the file is present *and* its size
    /// matches, so a truncated file is treated as missing rather than trusted.
    func refreshInstallStates() {
        guard let manifest else { return }
        for descriptor in manifest.models {
            let path = location(of: descriptor)
            let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            states[descriptor.id] = (size == descriptor.bytes) ? .installed : .missing
        }
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

    var missingRequired: [ModelDescriptor] { requiredModels.filter { !isInstalled($0) } }

    /// Total bytes still to fetch for the given set.
    func downloadSize(for descriptors: [ModelDescriptor]) -> Int64 {
        descriptors.filter { !isInstalled($0) }.reduce(0) { $0 + $1.bytes }
    }

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
        guard !isWorking else { return }
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
                    self.lastError = "\(descriptor.id): \(error.localizedDescription)"
                }
            }
            self.isWorking = false
            self.refreshInstallStates()
        }
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        isWorking = false
    }

    /// Removes an installed model from disk.
    func remove(_ descriptor: ModelDescriptor) {
        try? FileManager.default.removeItem(at: location(of: descriptor))
        states[descriptor.id] = .missing
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

        try await downloader.download(key: descriptor.id,
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
            await downloader.discardResumeData(for: descriptor.id)
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

//
//  DeviceCapabilities.swift
//  FaceFusionMac
//
//  How hard to push this particular Mac.
//
//  The export depth used to be the constant 3 — measured once on one machine
//  and shipped to every machine. That number is right in the middle of a range
//  that runs from an 8 GB M1 Air to a Mac Studio with a twenty-core GPU, so it
//  is simultaneously too deep for the bottom of the range and a long way short
//  of the top. This derives it instead.
//
//  Two rules govern everything below, and they exist so that no Mac that runs
//  the app today gets slower:
//
//   * **Three is the floor.** It is what shipped, it was measured, and nothing
//     here is allowed to go under it except thermal throttling — which is not
//     an optimisation but a brake, and one that makes a throttled machine
//     faster rather than slower: once the SoC is limiting itself the work
//     queues anyway, and every queued frame holds its buffers resident while it
//     waits.
//   * **Four is the ceiling, and only the large machines reach it.** Past that
//     the sessions simply queue on the same GPU.
//
//  The statics are `nonisolated` because the export loop re-reads them from a
//  background task and hopping to the main actor to ask how warm the machine is
//  would be absurd. The observable instance exists for the UI, which wants to
//  redraw when the answer changes.
//

import Foundation
import Observation
import os

/// How many frames the export should keep inside the engine at once, and why.
struct PerformanceProfile: Sendable, Equatable {
    /// Frames inside the engine at once.
    var concurrentFrames: Int
    /// Diagnostic, e.g. "10 performance cores, 32 GB, nominal". English only
    /// and deliberately so: it goes in the log, and two machines' logs have to
    /// be comparable whatever language either is set to.
    var reason: String
}

@MainActor
@Observable
final class DeviceCapabilities {

    /// One observer for the process. The export loop uses the statics below,
    /// because it is not on the main actor and does not want to be.
    static let shared = DeviceCapabilities()

    /// Republished on the main actor whenever the system says it changed.
    private(set) var thermalState: ProcessInfo.ThermalState

    /// A block observer is never taken away for you, so the token has to
    /// survive until `deinit` — and `deinit` is not main-actor isolated, hence
    /// `nonisolated(unsafe)`. It is written once during `init` and read once
    /// during `deinit`, so there is no race for the compiler to protect.
    @ObservationIgnored
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    init() {
        thermalState = ProcessInfo.processInfo.thermalState
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshThermalState() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func refreshThermalState() {
        let current = Self.thermalState
        guard current != thermalState else { return }
        // Worth a line in the log: "the export got slower halfway through" is
        // otherwise indistinguishable from a bug in the pipeline.
        EngineLog.engine.notice(
            "Thermal state \(Self.thermalDescription(self.thermalState), privacy: .public) → \(Self.thermalDescription(current), privacy: .public)")
        thermalState = current
    }

    /// The profile as it stands right now.
    ///
    /// Touching the observable property is what registers the caller with the
    /// observation machinery: the static below reads `ProcessInfo` directly, so
    /// a view that called it would never be told to redraw when the machine
    /// starts throttling.
    func profile(enhancing: Bool) -> PerformanceProfile {
        _ = thermalState
        return Self.recommendedProfile(enhancing: enhancing)
    }

    // MARK: - Process-wide facts

    /// Performance cores, which on Apple silicon is a different number from the
    /// core count and the one that matters.
    ///
    /// `activeProcessorCount` counts efficiency cores, and the split is not a
    /// constant: an M1 is 4+4, an M3 Max is 12+4, and treating those as 8 and
    /// 16 gets the ratio between them badly wrong. `hw.perflevel0.logicalcpu`
    /// is the performance cluster's size and exists on every Apple silicon Mac;
    /// Intel has no clusters, so it is absent there and the physical core count
    /// is the right answer instead.
    nonisolated static var performanceCoreCount: Int {
        if let cluster = sysctlInt("hw.perflevel0.logicalcpu"), cluster > 0 {
            return cluster
        }
        if let physical = sysctlInt("hw.physicalcpu"), physical > 0 {
            return physical
        }
        return ProcessInfo.processInfo.activeProcessorCount
    }

    nonisolated static var physicalMemoryBytes: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    /// True below 16 GB, where a second enhancer replica is 340 MB the machine
    /// would rather have back.
    ///
    /// A Mac swaps rather than being jetsammed, so this is a performance
    /// judgement and not a survival one — which is why the threshold sits well
    /// above the point where the allocation would actually fail. Swapping model
    /// weights to disk mid-export costs far more than the overlap a second
    /// session buys.
    ///
    /// Rounded up to whole gibibytes first because `physicalMemory` reports
    /// what the kernel makes available rather than what is on the box.
    nonisolated static var isMemoryConstrained: Bool {
        let gibibyte: UInt64 = 1 << 30
        let rounded = (physicalMemoryBytes + gibibyte - 1) / gibibyte
        return rounded < 16
    }

    nonisolated static var thermalState: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    /// e.g. "Mac15,3". What a support log needs; the marketing name is not
    /// available offline.
    nonisolated static var deviceModelIdentifier: String {
        sysctlString("hw.model") ?? "unknown"
    }

    // MARK: - Export depth

    /// How many frames the export should keep inside the engine at once.
    ///
    /// - **Three unless there is a reason.** That is the measured, shipped
    ///   value and the floor for everything except thermal throttling.
    /// - **Four on a machine with at least eight performance cores and at
    ///   least 16 GB**, and only when the restorer is off. With it on, the
    ///   enhancer is the bottleneck and a deeper queue in front of it buys
    ///   nothing but resident 512×512 tensors.
    /// - **Thermal `.serious` caps at two, `.critical` at one.** Caps, never
    ///   increases.
    nonisolated static func recommendedProfile(enhancing: Bool) -> PerformanceProfile {
        let cores = performanceCoreCount
        let constrained = isMemoryConstrained
        var notes = ["\(cores) performance cores"]

        var depth = 3
        if cores >= 8, !constrained, !enhancing {
            depth = 4
        }
        if enhancing { notes.append("enhancing") }
        if constrained { notes.append("under 16 GB") }

        let thermal = thermalState
        switch thermal {
        case .serious:  depth = min(depth, 2)
        case .critical: depth = min(depth, 1)
        default:        break
        }

        notes.append(thermalDescription(thermal))
        return PerformanceProfile(concurrentFrames: max(1, depth),
                                  reason: notes.joined(separator: ", "))
    }

    /// How many enhancer sessions to build.
    ///
    /// Two is worth roughly the enhancer's share of a frame when two frames are
    /// in flight — but it is another ~340 MB of resident weights, which is a
    /// trade only a machine with room to spare should make.
    nonisolated static var enhancerReplicas: Int {
        isMemoryConstrained ? 1 : 2
    }

    /// The English name, for the log. Never translated: a log line has to mean
    /// the same thing whichever language the machine happens to be set to, and
    /// two machines' logs have to be comparable.
    nonisolated static func thermalDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        default:        return "unknown"
        }
    }

    // MARK: - sysctl

    private nonisolated static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private nonisolated static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

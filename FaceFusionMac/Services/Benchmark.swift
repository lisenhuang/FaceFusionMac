//
//  Benchmark.swift
//  FaceFusionMac
//
//  Sweeps execution-provider settings and reports where each frame's time
//  actually goes, so tuning decisions are made from measurements rather than
//  from assumptions about what the Neural Engine "should" do.
//
//  Run with `--benchmark`; reads the same SelfTest/ fixtures.
//

import Foundation
import CoreMedia

enum Benchmark {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--benchmark")
    }

    /// Loads the models with Core ML's compute-plan profiling turned on, which
    /// logs how many subgraphs each ONNX graph was cut into and which unit each
    /// operator landed on. Heavy fragmentation is the usual reason a small
    /// model is unexpectedly slow.
    static var isProfileRequested: Bool {
        CommandLine.arguments.contains("--profile")
    }

    @MainActor
    static func profile(model: AppModel) async -> Never {
        await model.models.waitUntilLibraryPrepared()
        guard model.models.isReady else {
            emit("PROFILE FAILED: models not installed")
            exit(2)
        }
        do {
            try await model.engine.prepare(
                modelPaths: model.models.installedPaths(),
                modelDigests: model.models.installedDigests(),
                cacheDirectory: ModelManager.compileCacheDirectory,
                compute: .automatic,
                tuning: EngineTuning(requireStaticInputShapes: true,
                                     profileComputePlan: true))
            emit("PROFILE prepared — see the engine's log for partition counts")
        } catch {
            emit("PROFILE FAILED: \(error.localizedDescription)")
            exit(2)
        }
        exit(0)
    }

    struct Configuration {
        var name: String
        var compute: ComputePolicy
        /// Per-model exceptions to `compute`. Empty reproduces the single
        /// policy exactly, which is what every entry that predates this did.
        var computeOverrides: [ModelID: ComputePolicy] = [:]
        var tuning: EngineTuning
        var enhance: Bool
    }

    /// Each entry isolates one variable against the shipping default.
    static let sweep: [Configuration] = [
        Configuration(name: "ALL + static shapes",
                      compute: .automatic,
                      tuning: EngineTuning(requireStaticInputShapes: true),
                      enhance: true),
        Configuration(name: "ALL + dynamic shapes",
                      compute: .automatic,
                      tuning: EngineTuning(requireStaticInputShapes: false),
                      enhance: true),
        Configuration(name: "CPU+GPU only",
                      compute: .gpu,
                      tuning: EngineTuning(requireStaticInputShapes: true),
                      enhance: true),
        Configuration(name: "CPU+ANE only",
                      compute: .neuralEngine,
                      tuning: EngineTuning(requireStaticInputShapes: true),
                      enhance: true),
        Configuration(name: "NeuralNetwork format",
                      compute: .automatic,
                      tuning: EngineTuning(requireStaticInputShapes: true,
                                           modelFormat: "NeuralNetwork"),
                      enhance: true),
        Configuration(name: "ALL + static, no enhancer",
                      compute: .automatic,
                      tuning: EngineTuning(requireStaticInputShapes: true),
                      enhance: false),
        Configuration(name: "CPU only (baseline)",
                      compute: .cpu,
                      tuning: EngineTuning(requireStaticInputShapes: true),
                      enhance: true),

        // Split policies. `CPUAndNeuralEngine` across the board measured 17x
        // slower than `ALL`, and the reason was never that the ANE is slow —
        // it is that the swapper and the restorer are convolutional generators
        // it largely rejects, so those two runs degenerate into constant
        // fallback and drag the small graphs down with them. These entries ask
        // the question the single policy could not: whether the detector, the
        // landmarker and the identity encoder are faster on the ANE while the
        // generators keep the GPU, so that two units work at once instead of
        // contending for one.
        //
        // Nothing ships from this until it is measured. `EngineConfiguration`
        // defaults to an empty override map precisely so that the answer has to
        // be put there deliberately.
        Configuration(name: "small models on ANE",
                      compute: .automatic,
                      computeOverrides: [.faceDetector: .neuralEngine,
                                         .faceLandmarker: .neuralEngine,
                                         .faceRecognizer: .neuralEngine],
                      tuning: EngineTuning(requireStaticInputShapes: true),
                      enhance: true),
        Configuration(name: "small ANE, generators GPU",
                      compute: .gpu,
                      computeOverrides: [.faceDetector: .neuralEngine,
                                         .faceLandmarker: .neuralEngine,
                                         .faceRecognizer: .neuralEngine],
                      tuning: EngineTuning(requireStaticInputShapes: true),
                      enhance: true),
        Configuration(name: "occluder on ANE",
                      compute: .automatic,
                      computeOverrides: [.faceOccluder: .neuralEngine],
                      tuning: EngineTuning(requireStaticInputShapes: true),
                      enhance: true),
    ]

    private static func emit(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    @MainActor
    static func run(model: AppModel, iterations: Int = 12) async -> Never {
        let source = SelfTest.directory.appendingPathComponent("source.jpg")
        let target = SelfTest.directory.appendingPathComponent("target.mp4")

        guard FileManager.default.fileExists(atPath: source.path),
              FileManager.default.fileExists(atPath: target.path) else {
            emit("BENCH FAILED: fixtures missing in \(SelfTest.directory.path)")
            exit(2)
        }
        await model.models.waitUntilLibraryPrepared()
        guard model.models.isReady else {
            emit("BENCH FAILED: models not installed")
            exit(2)
        }

        // One decoded frame, reused for every configuration so the only
        // variable is the execution settings.
        guard let frame = try? await VideoPipeline.frame(
                at: CMTime(seconds: 4, preferredTimescale: 600), in: target),
              let sourceBuffer = try? PixelSurface.loadImage(at: source) else {
            emit("BENCH FAILED: could not decode fixtures")
            exit(2)
        }
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        emit("BENCH frame \(width)x\(height), \(iterations) iterations per configuration\n")

        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text
                : text + String(repeating: " ", count: width - text.count)
        }
        func padLeft(_ text: String, _ width: Int) -> String {
            text.count >= width ? text
                : String(repeating: " ", count: width - text.count) + text
        }

        emit(pad("configuration", 26)
             + ["detect", "landmk", "match", "swap", "paste", "enhance", "total"]
                .map { padLeft($0, 8) }.joined())
        emit(String(repeating: "-", count: 98))

        for configuration in sweep {
            do {
                try await model.engine.prepare(modelPaths: model.models.installedPaths(),
                                               modelDigests: model.models.installedDigests(),
                                               cacheDirectory: ModelManager.compileCacheDirectory,
                                               compute: configuration.compute,
                                               computeOverrides: configuration.computeOverrides,
                                               tuning: configuration.tuning)

                let sourceSurface = try PixelSurface.surface(of: sourceBuffer)
                _ = try await model.engine.analyzeSource(sourceSurface)

                var options = model.swapOptions
                options.enhanceFace = configuration.enhance

                let output = try PixelSurface.makeBuffer(width: width, height: height)
                let inputSurface = try PixelSurface.surface(of: frame)
                let outputSurface = try PixelSurface.surface(of: output)

                // Discard the first two: Core ML lazily specialises on the
                // first real inference, so they are not representative.
                for _ in 0 ..< 2 {
                    _ = try await model.engine.swap(inputSurface, into: outputSurface,
                                                    options: options)
                }

                var total = StageSeconds()
                for _ in 0 ..< iterations {
                    let result = try await model.engine.swap(inputSurface, into: outputSurface,
                                                             options: options)
                    total = total + result.stages
                }
                let mean = total.scaled(by: 1.0 / Double(iterations))

                let columns = [mean.detect, mean.landmarks, mean.match, mean.swap,
                               mean.paste, mean.enhance, mean.total]
                    .map { padLeft(String(format: "%.1f", $0 * 1000), 8) }
                    .joined()
                emit(pad(configuration.name, 26) + columns
                     + String(format: "   (%.2f fps)", mean.total > 0 ? 1 / mean.total : 0))
            } catch {
                emit(pad(configuration.name, 26) + "  FAILED: \(error.localizedDescription)")
            }
        }

        emit("\nBENCH DONE")
        exit(0)
    }
}

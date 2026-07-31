//
//  SelfTest.swift
//  FaceFusionMac
//
//  A headless end-to-end run, for development and CI.
//
//  Launch with `--selftest` and the app skips the UI, reads `source.jpg` and
//  `target.mp4` from `SelfTest/` in the shared container, exports
//  `output.mp4` beside them, and exits with a non-zero status on failure.
//
//  It reads from the group container rather than from paths on the command
//  line because the app is sandboxed: without a user selecting them through
//  the open panel, arbitrary paths are not readable.
//

import Foundation
import AppKit
import os

enum SelfTest {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest")
    }

    static var directory: URL {
        ModelManager.containerDirectory.appendingPathComponent("SelfTest", isDirectory: true)
    }

    /// Writes to stderr, which is unbuffered — stdout is block-buffered when
    /// the output is a pipe, so progress would be lost if the run is killed.
    private static func emit(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    @MainActor
    static func run(model: AppModel) async -> Never {
        let log = EngineLog.client
        let source = directory.appendingPathComponent("source.jpg")
        let target = directory.appendingPathComponent("target.mp4")
        let output = directory.appendingPathComponent("output.mp4")

        func fail(_ message: String) -> Never {
            log.error("selftest FAILED: \(message, privacy: .public)")
            emit("SELFTEST FAILED: \(message)")
            exit(2)
        }

        guard FileManager.default.fileExists(atPath: source.path) else {
            fail("missing \(source.path)")
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            fail("missing \(target.path)")
        }

        // Exercises the real first-run path: download, checksum, install.
        if !model.models.isReady {
            let missing = model.models.missingRequired
            emit("SELFTEST installing \(missing.count) model(s), "
                 + ByteCountFormatter.string(fromByteCount: model.models.downloadSize(for: missing),
                                             countStyle: .file))
            model.models.install(missing)

            while model.models.isWorking {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let progress = model.models.sessionTotal > 0
                    ? Double(model.models.sessionReceived) / Double(model.models.sessionTotal)
                    : nil {
                    emit(String(format: "SELFTEST downloading %.0f%%", progress * 100))
                }
            }
            guard model.models.isReady else {
                fail("install failed: \(model.models.lastError ?? "unknown")")
            }
            emit("SELFTEST models installed and verified")
        }

        await model.startEngineIfPossible()
        guard case .ready(let summary) = model.engine.state else {
            fail("engine did not start: \(String(describing: model.engine.state))")
        }
        emit("SELFTEST engine ready via \(summary.executionProvider)")

        await model.setSource(source)
        guard let face = model.sourceFace else {
            fail("no face detected in the source image")
        }
        emit(String(format: "SELFTEST source face score %.3f at (%.0f, %.0f) %.0fx%.0f",
                     face.score, face.box.x, face.box.y, face.box.width, face.box.height))

        await model.setTarget(target)
        guard let info = model.targetInfo else { fail("could not read the target video") }
        emit("SELFTEST target \(Int(info.displaySize.width))x\(Int(info.displaySize.height)) "
              + String(format: "%.1fs", info.durationSeconds)
              + " \(info.codecDescription) audio=\(info.hasAudio)")

        // Exercise the same path the Export button drives, minus the save panel.
        let started = Date()
        do {
            let request = VideoPipeline.ExportRequest(source: target,
                                                      destination: output,
                                                      options: model.swapOptions,
                                                      useHEVC: true)
            var lastLogged = 0
            try await VideoPipeline.export(request, engine: model.engine) { progress in
                if progress.framesWritten - lastLogged >= 25 {
                    lastLogged = progress.framesWritten
                    emit(String(format: "SELFTEST %d/%d frames  %.1f fps",
                                 progress.framesWritten, progress.totalFrames,
                                 progress.framesPerSecond))
                }
            }
        } catch {
            fail("export threw: \(error.localizedDescription)")
        }

        let elapsed = Date().timeIntervalSince(started)
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: output.path)[.size] as? Int64, size > 0 else {
            fail("no output file was produced")
        }

        // Confirm the result is a real, readable video rather than a stub.
        guard let written = try? await VideoPipeline.inspect(output) else {
            fail("the exported file could not be read back")
        }
        guard written.estimatedFrameCount > 1 else {
            fail("the exported video has \(written.estimatedFrameCount) frame(s)")
        }

        emit(String(format: "SELFTEST OK  %.1fs  %@  %dx%d  %.1fs of video  audio=%@",
                     elapsed, ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                     Int(written.displaySize.width), Int(written.displaySize.height),
                     written.durationSeconds, written.hasAudio ? "yes" : "no"))
        exit(0)
    }
}

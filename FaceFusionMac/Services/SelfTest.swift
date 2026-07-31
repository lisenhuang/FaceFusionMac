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
        // The export used to come out mute and nothing noticed, because the
        // fixture had no sound to lose. Assert the carry-over explicitly, and
        // say so loudly when the fixture cannot test it.
        if info.hasAudio {
            guard written.hasAudio else { fail("the exported video lost its audio track") }
        } else {
            emit("SELFTEST NOTE  target.mp4 has no audio track, so audio carry-over is untested."
                 + " Stage a fixture with sound to cover it.")
        }

        emit(String(format: "SELFTEST OK  %.1fs  %@  %dx%d  %.1fs of video  audio=%@",
                     elapsed, ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                     Int(written.displaySize.width), Int(written.displaySize.height),
                     written.durationSeconds, written.hasAudio ? "yes" : "no"))

        await checkPhotoExport(model: model, source: source, fail: fail)
        checkRememberedFolders(source: source, target: target, fail: fail)

        emit("SELFTEST ALL OK")
        exit(0)
    }

    /// The photo path: the same engine, but one frame in and an ImageIO write
    /// out. The source portrait doubles as the target, which is a real face at
    /// a real resolution.
    @MainActor
    private static func checkPhotoExport(model: AppModel,
                                         source: URL,
                                         fail: (String) -> Never) async {
        let output = directory.appendingPathComponent("output.png")
        try? FileManager.default.removeItem(at: output)

        await model.setTarget(source)
        guard model.targetIsImage else { fail("a photo target was read back as a video") }
        guard let size = model.target?.displaySize, size.width > 0 else {
            fail("the photo target has no size")
        }

        do {
            try await model.exportStillImage(to: output)
        } catch {
            fail("photo export threw: \(error.localizedDescription)")
        }

        // Read it back with a fresh decode: a file that cannot be reopened at
        // the right size is not an export, whatever its byte count.
        guard let bytes = try? FileManager.default
            .attributesOfItem(atPath: output.path)[.size] as? Int64, bytes > 0 else {
            fail("no photo was produced")
        }
        guard let reloaded = try? PixelSurface.loadImage(at: output, maximumDimension: .max) else {
            fail("the exported photo could not be read back")
        }
        let reloadedSize = CGSize(width: CVPixelBufferGetWidth(reloaded),
                                  height: CVPixelBufferGetHeight(reloaded))
        guard reloadedSize == size else {
            fail("the exported photo is \(reloadedSize) but the target was \(size)")
        }
        guard let faces = model.progress?.facesSwappedInLastFrame, faces > 0 else {
            fail("the photo export swapped no faces")
        }

        emit(String(format: "SELFTEST PHOTO OK  %@  %dx%d  %d face(s)",
                     ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                     Int(reloadedSize.width), Int(reloadedSize.height), faces))
    }

    /// The three panel folders are stored separately. The panels themselves
    /// need a click, so what is checked here is the part that has logic in it:
    /// each role keeps its own folder, and only the folder, across a reload.
    private static func checkRememberedFolders(source: URL, target: URL,
                                               fail: (String) -> Never) {
        let suite = "com.lisenhuang.FaceFusionMac.selftest.locations"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fail("could not open a scratch preferences domain")
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let exportURL = directory.appendingPathComponent("elsewhere/output.mp4")
        let locations = RecentLocations(defaults: defaults)
        locations.remember(source, for: .face)
        locations.remember(target, for: .target)
        locations.remember(exportURL, for: .export)

        // A second reader sees what the first wrote, which is what makes the
        // folders survive a relaunch.
        let reloaded = RecentLocations(defaults: defaults)
        let expected: [(RecentLocations.Slot, URL)] = [
            (.face, source), (.target, target), (.export, exportURL),
        ]
        for (slot, url) in expected {
            let stored = reloaded.directory(for: slot)
            guard stored?.path == url.deletingLastPathComponent().path else {
                fail("\(slot.rawValue) came back as \(stored?.path ?? "nil"), "
                     + "expected \(url.deletingLastPathComponent().path)")
            }
        }
        guard reloaded.directory(for: .export)?.path != reloaded.directory(for: .face)?.path else {
            fail("the export folder was not kept separate from the face folder")
        }
        emit("SELFTEST FOLDERS OK  face, target and export tracked separately")
    }
}

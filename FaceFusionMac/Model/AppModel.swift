//
//  AppModel.swift
//  FaceFusionMac
//
//  Application state and the actions the UI can take.
//

import Foundation
import Observation
import os
import CoreVideo
import CoreMedia
import AVFoundation
import AppKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {

    enum Phase: Equatable {
        case choosingMedia
        case ready
        case rendering
        case finished(URL)
        case failed(String)
    }

    /// What the face is being swapped into. A photo is the same pipeline as a
    /// video with exactly one frame, so the two differ only at the edges:
    /// there is nothing to scrub, and the result is written by ImageIO rather
    /// than by an encoder.
    enum TargetMedia: Equatable {
        case video(VideoInfo)
        case image(size: CGSize, format: String)

        var isImage: Bool {
            if case .image = self { return true }
            return false
        }

        var displaySize: CGSize {
            switch self {
            case .video(let info): return info.displaySize
            case .image(let size, _): return size
            }
        }
    }

    // MARK: Services

    let models = ModelManager()
    let engine = EngineClient()

    // MARK: Media

    private(set) var sourceURL: URL?
    private(set) var sourceBuffer: CVPixelBuffer?
    private(set) var sourceFace: DetectedFace?
    private(set) var sourceFaceCount = 0

    private(set) var targetURL: URL?
    private(set) var target: TargetMedia?

    /// Present only for video targets, so the scrubber and the frame-count
    /// progress simply do not appear for a photo.
    var targetInfo: VideoInfo? {
        if case .video(let info) = target { return info }
        return nil
    }

    var targetIsImage: Bool { target?.isImage ?? false }

    /// The frame currently shown, before any swap.
    private(set) var previewFrame: CVPixelBuffer?
    /// The same frame after swapping, when a preview has been generated.
    private(set) var previewResult: CVPixelBuffer?
    private(set) var previewFaces: [DetectedFace] = []
    private(set) var isPreviewing = false
    /// Toggles the canvas between the original and the swapped frame.
    var showsOriginal = false

    /// Scrub position in seconds.
    var previewTime: Double = 0 {
        didSet { schedulePreviewFrameReload() }
    }

    // MARK: Options

    var enhanceFace = true
    var identityStrength: Double = 0.5
    var maskBlur: Double = 0.3
    var useHEVC = true
    /// One face by default. Most clips have a single subject, and replacing
    /// every face in a crowd is the surprising outcome, not the expected one.
    var faceSelection: FaceSelection = .largest

    // MARK: Job

    private(set) var phase: Phase = .choosingMedia
    private(set) var progress: ExportProgress?
    private(set) var statusMessage: String?

    private var exportTask: Task<Void, Never>?
    private var previewFrameTask: Task<Void, Never>?
    private var previewSwapTask: Task<Void, Never>?

    // MARK: - Derived

    var canRender: Bool {
        sourceFace != nil && targetURL != nil && models.isReady && phase != .rendering
    }

    var isRendering: Bool { phase == .rendering }

    /// Options the engine should use, assembled from the UI state.
    var swapOptions: SwapOptions {
        SwapOptions(selection: faceSelection,
                    identityStrength: identityStrength,
                    enhanceFace: enhanceFace && models.isInstalledModel(.faceEnhancer),
                    enhancementBlend: 0.8,
                    maskBlur: maskBlur,
                    detectorScore: 0.5,
                    // Kept on for both source and target. The source identity is
                    // encoded once at selection time, so flipping this per job
                    // would align the two differently and weaken the match.
                    refineLandmarks: true)
    }

    // MARK: - Engine lifecycle

    func startEngineIfPossible() async {
        guard models.isReady else {
            EngineLog.client.notice(
                "engine not started: manifest=\(self.models.manifest == nil ? "missing" : "loaded", privacy: .public) required=\(self.models.requiredModels.count) missing=\(self.models.missingRequired.map(\.id).joined(separator: ","), privacy: .public) dir=\(ModelManager.modelsDirectory.path, privacy: .public)")
            return
        }
        EngineLog.client.notice("starting engine with \(self.models.installedPaths().count) model(s)")
        if case .ready = engine.state { return }
        do {
            try await engine.prepare(modelPaths: models.installedPaths(),
                                     cacheDirectory: ModelManager.compileCacheDirectory,
                                     compute: .automatic)
            statusMessage = nil
            // A source chosen before the engine was up still needs encoding.
            if sourceBuffer != nil, sourceFace == nil { await analyzeSource() }
        } catch {
            EngineLog.client.error("engine prepare failed: \(error.localizedDescription, privacy: .public)")
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Choosing media

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the face you want to use."
        panel.prompt = "Use Face"
        panel.directoryURL = RecentLocations.shared.directory(for: .face)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await useSource(url) }
    }

    func chooseTarget() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the video or photo to put that face into."
        panel.prompt = "Use Media"
        panel.directoryURL = RecentLocations.shared.directory(for: .target)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await useTarget(url) }
    }

    // A file the user picked or dropped, as opposed to one supplied
    // programmatically. Only these record where to open the next panel, so a
    // headless run does not rewrite the user's remembered folders.

    func useSource(_ url: URL) async {
        RecentLocations.shared.remember(url, for: .face)
        await setSource(url)
    }

    func useTarget(_ url: URL) async {
        RecentLocations.shared.remember(url, for: .target)
        await setTarget(url)
    }

    func setSource(_ url: URL) async {
        do {
            let buffer = try PixelSurface.loadImage(at: url)
            sourceURL = url
            sourceBuffer = buffer
            sourceFace = nil
            sourceFaceCount = 0
            statusMessage = nil
            await analyzeSource()
            invalidatePreviewResult()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func analyzeSource() async {
        guard let buffer = sourceBuffer else { return }
        guard case .ready = engine.state else { return }
        do {
            let surface = try PixelSurface.surface(of: buffer)
            let analysis = try await engine.analyzeSource(surface)
            sourceFace = analysis.face
            sourceFaceCount = analysis.faceCount
            statusMessage = nil
            await refreshPreview()
        } catch {
            sourceFace = nil
            statusMessage = error.localizedDescription
        }
    }

    func setTarget(_ url: URL) async {
        if Self.isImage(url) {
            await setImageTarget(url)
        } else {
            await setVideoTarget(url)
        }
    }

    private func setVideoTarget(_ url: URL) async {
        do {
            let info = try await VideoPipeline.inspect(url)
            targetURL = url
            target = .video(info)
            previewTime = min(1.0, max(0, info.durationSeconds / 4))
            statusMessage = nil
            phase = .choosingMedia
            await loadPreviewFrame()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func setImageTarget(_ url: URL) async {
        do {
            // Full resolution: unlike the source portrait — which only ever
            // feeds a 112px crop — this is what gets written back out, so
            // shrinking it would quietly downgrade the export.
            let buffer = try PixelSurface.loadImage(at: url, maximumDimension: .max)
            targetURL = url
            target = .image(size: CGSize(width: CVPixelBufferGetWidth(buffer),
                                         height: CVPixelBufferGetHeight(buffer)),
                            format: url.pathExtension.uppercased())
            previewTime = 0
            previewFrame = buffer
            statusMessage = nil
            phase = .choosingMedia
            invalidatePreviewResult()
            await detectPreviewFaces()
            await refreshPreview()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private static func isImage(_ url: URL) -> Bool {
        // Fall back to the extension when the metadata cannot be read, which
        // is exactly when the first answer is least trustworthy.
        let declared = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        guard let type = declared ?? UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .image) && !type.conforms(to: .movie)
    }

    /// A drop onto the window as a whole, where the file has to speak for
    /// itself. Videos are unambiguous; a photo could be either role, so it
    /// fills the empty slot and otherwise replaces the face — swapping in a
    /// different face is the far more common second move.
    func handleDrop(_ url: URL) async {
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if let type, type.conforms(to: .movie) || type.conforms(to: .video) {
            await useTarget(url)
        } else if let type, type.conforms(to: .image) {
            if sourceBuffer != nil, target == nil {
                await useTarget(url)
            } else {
                await useSource(url)
            }
        } else {
            statusMessage = "That file type is not supported."
        }
    }

    func clearSource() {
        sourceURL = nil; sourceBuffer = nil; sourceFace = nil; sourceFaceCount = 0
        invalidatePreviewResult()
    }

    func clearTarget() {
        targetURL = nil; target = nil; previewFrame = nil
        previewFaces = []
        invalidatePreviewResult()
        phase = .choosingMedia
    }

    // MARK: - Preview

    /// Debounces scrubbing so dragging the slider does not queue a decode per
    /// pixel of travel.
    private func schedulePreviewFrameReload() {
        previewFrameTask?.cancel()
        previewFrameTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await self?.loadPreviewFrame()
        }
    }

    private func loadPreviewFrame() async {
        // A photo target has no timeline: its single frame is decoded once,
        // when it is chosen.
        guard let url = targetURL, !targetIsImage else { return }
        do {
            let time = CMTime(seconds: previewTime, preferredTimescale: 600)
            let frame = try await VideoPipeline.frame(at: time, in: url)
            guard !Task.isCancelled else { return }
            previewFrame = frame
            invalidatePreviewResult()
            await detectPreviewFaces()
            await refreshPreview()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func detectPreviewFaces() async {
        guard let frame = previewFrame, case .ready = engine.state else { return }
        do {
            let surface = try PixelSurface.surface(of: frame)
            previewFaces = try await engine.detectFaces(surface).faces
        } catch {
            previewFaces = []
        }
    }

    private func invalidatePreviewResult() {
        previewResult = nil
        showsOriginal = false
    }

    /// Runs the swap on just the visible frame. This is the fast feedback loop:
    /// it takes about as long as one frame of an export, so settings can be
    /// judged before committing to a full render.
    func refreshPreview() async {
        guard sourceFace != nil, let frame = previewFrame, !isRendering else { return }
        guard case .ready = engine.state else { return }

        previewSwapTask?.cancel()
        let options = swapOptions
        previewSwapTask = Task { [weak self] in
            guard let self else { return }
            self.isPreviewing = true
            defer { self.isPreviewing = false }
            do {
                let width = CVPixelBufferGetWidth(frame)
                let height = CVPixelBufferGetHeight(frame)
                let output = try PixelSurface.makeBuffer(width: width, height: height)
                let inputSurface = try PixelSurface.surface(of: frame)
                let outputSurface = try PixelSurface.surface(of: output)
                _ = try await self.engine.swap(inputSurface, into: outputSurface, options: options)
                guard !Task.isCancelled else { return }
                self.previewResult = output
                self.phase = .ready
            } catch is CancellationError {
                // Superseded by a newer preview.
            } catch {
                self.statusMessage = error.localizedDescription
            }
        }
        await previewSwapTask?.value
    }

    /// Picks whichever detected face is nearest the click, in normalised
    /// coordinates so it survives the canvas being resized.
    func selectFace(atNormalized point: CGPoint) {
        faceSelection = .nearestTo(x: Double(point.x), y: Double(point.y))
        Task { await refreshPreview() }
    }

    func selectAllFaces() {
        faceSelection = .all
        Task { await refreshPreview() }
    }

    /// Switches to single-face mode. Defaults to the largest face, which is
    /// almost always the subject, until the user clicks a different one.
    func selectSingleFace() {
        faceSelection = .largest
        Task { await refreshPreview() }
    }

    // MARK: - Export

    func export() {
        guard let targetURL, sourceFace != nil else { return }
        let isImage = targetIsImage

        let panel = NSSavePanel()
        panel.allowedContentTypes = isImage ? [.png, .jpeg] : [.mpeg4Movie]
        panel.nameFieldStringValue = suggestedFileName(for: targetURL, isImage: isImage)
        panel.message = isImage
            ? "Choose where to save the finished photo."
            : "Choose where to save the finished video."
        panel.prompt = "Export"
        panel.directoryURL = RecentLocations.shared.directory(for: .export)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        RecentLocations.shared.remember(destination, for: .export)

        phase = .rendering
        progress = ExportProgress(framesWritten: 0,
                                  totalFrames: isImage ? 1 : (targetInfo?.estimatedFrameCount ?? 0),
                                  framesPerSecond: 0,
                                  facesSwappedInLastFrame: 0)
        statusMessage = nil

        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                if isImage {
                    try await self.exportStillImage(to: destination)
                } else {
                    let request = VideoPipeline.ExportRequest(source: targetURL,
                                                              destination: destination,
                                                              options: self.swapOptions,
                                                              useHEVC: self.useHEVC)
                    try await VideoPipeline.export(request, engine: self.engine) { update in
                        self.progress = update
                    }
                }
                self.phase = .finished(destination)
            } catch is CancellationError {
                self.phase = .ready
                self.statusMessage = "Export cancelled."
                try? FileManager.default.removeItem(at: destination)
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// The photo path. The frame is swapped again rather than reusing what the
    /// preview produced, so the exported file always reflects the settings as
    /// they stand now and is written at the image's own resolution.
    ///
    /// Not private: `--selftest` drives it directly, the same way it calls
    /// `VideoPipeline.export` to exercise the video path without a save panel.
    func exportStillImage(to destination: URL) async throws {
        guard let frame = previewFrame else {
            throw MediaError.decode("The photo is no longer loaded.")
        }
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        let output = try PixelSurface.makeBuffer(width: width, height: height)

        let result = try await engine.swap(try PixelSurface.surface(of: frame),
                                           into: try PixelSurface.surface(of: output),
                                           options: swapOptions)
        try Task.checkCancellation()
        try PixelSurface.write(output, to: destination)

        previewResult = output
        progress = ExportProgress(framesWritten: 1,
                                  totalFrames: 1,
                                  framesPerSecond: 0,
                                  facesSwappedInLastFrame: result.facesSwapped)
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
    }

    func dismissResult() {
        phase = .ready
        progress = nil
    }

    private func suggestedFileName(for target: URL, isImage: Bool) -> String {
        let stem = target.deletingPathExtension().lastPathComponent
        // PNG rather than the original format: a re-encoded JPEG would lose a
        // second generation of detail. The panel still offers JPEG.
        return "\(stem)-faceswap.\(isImage ? "png" : "mp4")"
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

extension ModelManager {
    /// Convenience for checking a single optional model by id.
    func isInstalledModel(_ id: ModelID) -> Bool {
        states[id.rawValue] == .installed
    }
}

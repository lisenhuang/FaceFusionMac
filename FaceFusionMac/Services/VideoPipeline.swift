//
//  VideoPipeline.swift
//  FaceFusionMac
//
//  Video decode, per-frame processing and encode, built on AVFoundation.
//
//  This is what replaces FFmpeg: AVFoundation already speaks the container and
//  codec formats, and routes both decode and encode through VideoToolbox, so
//  there is nothing for the user to install.
//

import Foundation
import AVFoundation
import CoreVideo
import CoreMedia

// MARK: - Description of a source video

struct VideoInfo: Equatable, Sendable {
    /// Size after the track's rotation metadata is applied.
    var displaySize: CGSize
    var duration: CMTime
    var nominalFrameRate: Float
    var estimatedFrameCount: Int
    var hasAudio: Bool
    var codecDescription: String

    var durationSeconds: Double { duration.seconds }
}

// MARK: - Progress

struct ExportProgress: Sendable {
    var framesWritten: Int
    var totalFrames: Int
    var framesPerSecond: Double
    var facesSwappedInLastFrame: Int

    var fraction: Double {
        totalFrames > 0 ? min(1, Double(framesWritten) / Double(totalFrames)) : 0
    }

    /// Nil until there is enough throughput history to be meaningful.
    var estimatedTimeRemaining: TimeInterval? {
        guard framesPerSecond > 0.01, totalFrames > framesWritten else { return nil }
        return Double(totalFrames - framesWritten) / framesPerSecond
    }
}

// MARK: - Pipeline

enum VideoPipeline {

    // MARK: Inspection

    static func inspect(_ url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.noVideoTrack
        }

        let (naturalSize, transform, duration, frameRate) = try await track.load(
            .naturalSize, .preferredTransform, .timeRange, .nominalFrameRate)

        // Rotation metadata means the stored pixels may be transposed relative
        // to how the video should appear.
        let displaySize = naturalSize.applying(transform)
        let corrected = CGSize(width: abs(displaySize.width), height: abs(displaySize.height))

        let assetDuration = try await asset.load(.duration)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        var codec = "Video"
        if let description = try await track.load(.formatDescriptions).first {
            let subType = CMFormatDescriptionGetMediaSubType(description)
            codec = fourCCString(subType)
        }

        let seconds = assetDuration.seconds.isFinite ? assetDuration.seconds : 0
        let effectiveRate = frameRate > 0 ? Double(frameRate) : 30
        return VideoInfo(displaySize: corrected,
                         duration: assetDuration,
                         nominalFrameRate: frameRate,
                         estimatedFrameCount: max(1, Int(seconds * effectiveRate)),
                         hasAudio: !audioTracks.isEmpty,
                         codecDescription: codec)
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        switch text.lowercased() {
        case "avc1", "h264": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        default: return text.uppercased()
        }
    }

    // MARK: Single frames

    /// Decodes one upright frame, for the preview canvas.
    static func frame(at time: CMTime, in url: URL) async throws -> CVPixelBuffer {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        // Applies the rotation metadata, so faces arrive the right way up.
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = .zero

        let (cgImage, _) = try await generator.image(at: time)
        return try PixelSurface.makeBuffer(from: cgImage)
    }

    /// A generator tuned for the face scan rather than for display.
    ///
    /// The scan is deciding who is in the video, not rendering anything, so it
    /// can accept the nearest frame the decoder already has and a bounded size.
    /// Exact seeks at full resolution across dozens of samples is most of the
    /// difference between a scan that takes seconds and one that takes minutes.
    static func makeScanGenerator(for url: URL, maximumDimension: Int) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        generator.maximumSize = CGSize(width: maximumDimension, height: maximumDimension)
        return generator
    }

    // MARK: Export

    struct ExportRequest {
        var source: URL
        var destination: URL
        var options: SwapOptions
        /// HEVC keeps the file small; H.264 plays everywhere.
        var useHEVC: Bool = true
        /// Roughly 0.2 bits per pixel per frame at 1x.
        var qualityMultiplier: Double = 1.0
        /// How many frames may be inside the engine at once.
        ///
        /// A frame alternates between the GPU (four model invocations) and the
        /// CPU (warps, masking, compositing), and decode and encode sit either
        /// side of it. Processed strictly one at a time, whichever unit is not
        /// currently busy sits idle. Overlapping a few frames keeps them all
        /// fed. Beyond about four the units are saturated and the only effect
        /// is more resident frame buffers.
        var concurrentFrames: Int = 3
    }

    /// Reads every frame, hands it to `transform`, and writes the result.
    ///
    /// - Parameter transform: given an input surface and an output surface of
    ///   the same size, fills the output. Runs once per frame, in order.
    static func export(_ request: ExportRequest,
                       engine: EngineClient,
                       progress: @escaping @MainActor (ExportProgress) -> Void) async throws {

        let asset = AVURLAsset(url: request.source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.noVideoTrack
        }

        let (naturalSize, preferredTransform, nominalRate) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate)
        let rotated = naturalSize.applying(preferredTransform)
        let displaySize = CGSize(width: abs(rotated.width).rounded(),
                                 height: abs(rotated.height).rounded())

        // The engine expects upright faces. Rather than rotating every frame
        // ourselves, hand the reader a video composition and let AVFoundation
        // bake the rotation in on the GPU.
        let needsComposition = !preferredTransform.isIdentity

        let reader = try AVAssetReader(asset: asset)
        let videoOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]

        let videoOutput: AVAssetReaderOutput
        if needsComposition {
            let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack],
                                                             videoSettings: videoOutputSettings)
            output.videoComposition = composition
            videoOutput = output
        } else {
            videoOutput = AVAssetReaderTrackOutput(track: videoTrack,
                                                   outputSettings: videoOutputSettings)
        }
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw MediaError.readerFailed("Could not read this video's frames.")
        }
        reader.add(videoOutput)

        // Writer
        if FileManager.default.fileExists(atPath: request.destination.path) {
            try FileManager.default.removeItem(at: request.destination)
        }
        let writer = try AVAssetWriter(outputURL: request.destination, fileType: .mp4)

        let pixelCount = Double(displaySize.width * displaySize.height)
        let frameRate = nominalRate > 0 ? Double(nominalRate) : 30
        let bitrate = Int(pixelCount * frameRate * 0.15 * request.qualityMultiplier)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: max(1_500_000, min(bitrate, 120_000_000)),
            AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
        ]
        if request.useHEVC {
            compression[AVVideoQualityKey] = 0.9
        } else {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: request.useHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(displaySize.width),
            AVVideoHeightKey: Int(displaySize.height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        writerInput.expectsMediaDataInRealTime = false
        // Rotation is already baked into the pixels, so the output needs no
        // transform of its own — setting one here would rotate it twice.
        writerInput.transform = .identity

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(displaySize.width),
                kCVPixelBufferHeightKey as String: Int(displaySize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ])

        guard writer.canAdd(writerInput) else {
            throw MediaError.writerFailed("Could not set up the video encoder.")
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw MediaError.writerFailed(writer.error?.localizedDescription
                                          ?? "The encoder refused to start.")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            throw MediaError.readerFailed(reader.error?.localizedDescription
                                          ?? "The decoder refused to start.")
        }

        let totalFrames = try await inspect(request.source).estimatedFrameCount
        var framesWritten = 0
        var lastReport = Date()
        var framesSinceReport = 0
        var throughput: Double = 0

        // Frames in the engine, oldest first. Submitting several keeps the GPU
        // and CPU stages of different frames overlapping; draining in FIFO
        // order keeps what reaches the writer strictly monotonic in time,
        // which AVAssetWriter requires.
        struct InFlight {
            var task: Task<SwapResult, Error>
            var output: CVPixelBuffer
            var time: CMTime
            /// Retained so the decoder cannot recycle the input underneath us.
            var sample: CMSampleBuffer
        }
        var inFlight: [InFlight] = []
        let depth = max(1, request.concurrentFrames)

        defer {
            // On cancellation or a thrown error, stop the decoder and let go of
            // any frames still inside the engine.
            for item in inFlight { item.task.cancel() }
            if reader.status == .reading { reader.cancelReading() }
        }

        /// Waits for the oldest frame and writes it.
        func drainOldest() async throws {
            guard !inFlight.isEmpty else { return }
            let item = inFlight.removeFirst()
            let result = try await item.task.value

            while !writerInput.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            if !adaptor.append(item.output, withPresentationTime: item.time) {
                throw MediaError.writerFailed(writer.error?.localizedDescription
                                              ?? "A frame could not be encoded.")
            }

            framesWritten += 1
            framesSinceReport += 1

            let elapsed = Date().timeIntervalSince(lastReport)
            if elapsed >= 0.4 {
                let instantaneous = Double(framesSinceReport) / elapsed
                // Smooth the rate so the estimate does not jitter per frame.
                throughput = throughput == 0 ? instantaneous
                                             : throughput * 0.7 + instantaneous * 0.3
                lastReport = Date()
                framesSinceReport = 0

                let snapshot = ExportProgress(framesWritten: framesWritten,
                                              totalFrames: totalFrames,
                                              framesPerSecond: throughput,
                                              facesSwappedInLastFrame: result.facesSwapped)
                await MainActor.run { progress(snapshot) }
            }
        }

        while let sample = videoOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()

            guard let input = CMSampleBufferGetImageBuffer(sample) else { continue }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)

            let width = CVPixelBufferGetWidth(input)
            let height = CVPixelBufferGetHeight(input)

            // Each in-flight frame needs its own destination.
            //
            // These come from the adaptor's own pool rather than being
            // recycled by hand: `append` retains the buffer and the encoder
            // reads it asynchronously, so a buffer handed straight back to the
            // engine gets overwritten while it is still being encoded. The
            // pool only vends a buffer once the encoder has released it.
            let output: CVPixelBuffer
            if let pool = adaptor.pixelBufferPool {
                var pooled: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pooled)
                guard status == kCVReturnSuccess, let pooled else {
                    throw MediaError.pixelBuffer("The encoder ran out of frame buffers.")
                }
                output = pooled
            } else {
                output = try PixelSurface.makeBuffer(width: width, height: height)
            }

            let inputSurface = try PixelSurface.surface(of: input)
            let outputSurface = try PixelSurface.surface(of: output)
            let options = request.options

            let task = Task { try await engine.swap(inputSurface, into: outputSurface,
                                                    options: options) }
            inFlight.append(InFlight(task: task, output: output,
                                     time: presentationTime, sample: sample))

            if inFlight.count >= depth {
                try await drainOldest()
            }
        }

        while !inFlight.isEmpty {
            try Task.checkCancellation()
            try await drainOldest()
        }

        if reader.status == .failed {
            throw MediaError.readerFailed(reader.error?.localizedDescription
                                          ?? "Decoding stopped unexpectedly.")
        }
        writerInput.markAsFinished()

        // Audio is copied afterwards with its own reader, which sidesteps the
        // interleaving rules a single reader with two outputs imposes.
        try await copyAudio(from: asset, into: writer)

        await writer.finishWriting()
        if writer.status == .failed {
            throw MediaError.writerFailed(writer.error?.localizedDescription
                                          ?? "The file could not be finished.")
        }

        let finalProgress = ExportProgress(framesWritten: framesWritten,
                                           totalFrames: max(totalFrames, framesWritten),
                                           framesPerSecond: throughput,
                                           facesSwappedInLastFrame: 0)
        await MainActor.run { progress(finalProgress) }
    }

    /// Passes the original audio through untouched — no decode, no re-encode.
    private static func copyAudio(from asset: AVURLAsset, into writer: AVAssetWriter) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return }
        guard let formatDescription = try await track.load(.formatDescriptions).first else { return }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return }
        reader.add(output)

        let input = AVAssetWriterInput(mediaType: .audio,
                                       outputSettings: nil,
                                       sourceFormatHint: formatDescription)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { return }
        writer.add(input)

        guard reader.startReading() else { return }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            if !input.append(sample) { break }
        }
        input.markAsFinished()
        if reader.status == .reading { reader.cancelReading() }
    }
}

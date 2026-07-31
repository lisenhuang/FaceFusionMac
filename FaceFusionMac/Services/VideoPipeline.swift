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

        let buffer = try PixelSurface.makeBuffer(width: cgImage.width, height: cgImage.height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base,
                                      width: cgImage.width, height: cgImage.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw MediaError.pixelBuffer("Could not draw the video frame.")
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return buffer
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
        var outputBuffer: CVPixelBuffer?

        defer {
            if reader.status == .reading { reader.cancelReading() }
        }

        while let sample = videoOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()

            guard let input = CMSampleBufferGetImageBuffer(sample) else { continue }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)

            let width = CVPixelBufferGetWidth(input)
            let height = CVPixelBufferGetHeight(input)

            // One reusable output buffer: the engine fully overwrites it each
            // frame, and the adaptor copies on append.
            if outputBuffer == nil
                || CVPixelBufferGetWidth(outputBuffer!) != width
                || CVPixelBufferGetHeight(outputBuffer!) != height {
                outputBuffer = try PixelSurface.makeBuffer(width: width, height: height)
            }
            guard let output = outputBuffer else { break }

            let inputSurface = try PixelSurface.surface(of: input)
            let outputSurface = try PixelSurface.surface(of: output)

            let result = try await engine.swap(inputSurface, into: outputSurface,
                                               options: request.options)

            while !writerInput.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            if !adaptor.append(output, withPresentationTime: presentationTime) {
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

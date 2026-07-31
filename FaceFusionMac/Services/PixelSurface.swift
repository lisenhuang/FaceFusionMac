//
//  PixelSurface.swift
//  FaceFusionMac
//
//  IOSurface-backed pixel buffers, plus decoding still images into them.
//
//  IOSurface is the currency of this app: it is what Core Video hands back
//  from the video decoder, what Core Image renders into, and what XPC can pass
//  to the engine by reference instead of copying.
//

import Foundation
import CoreVideo
import CoreImage
import CoreGraphics
import ImageIO
import IOSurface
import UniformTypeIdentifiers
import AppKit

enum PixelSurface {

    /// Creates an IOSurface-backed BGRA pixel buffer.
    static func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw MediaError.pixelBuffer("Could not allocate a \(width)x\(height) frame buffer.")
        }
        return buffer
    }

    /// The IOSurface behind a pixel buffer. Buffers created above always have
    /// one; decoder output does too, which is why frames need no copy.
    static func surface(of buffer: CVPixelBuffer) throws -> IOSurface {
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else {
            throw MediaError.pixelBuffer("Frame buffer is not backed by an IOSurface.")
        }
        return unsafeBitCast(surface, to: IOSurface.self)
    }

    // MARK: - Still images

    /// Decodes an image file into a BGRA pixel buffer, honouring EXIF
    /// orientation so a portrait shot from a phone arrives upright.
    static func loadImage(at url: URL, maximumDimension: Int = 2048) throws -> CVPixelBuffer {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw MediaError.decode("That image could not be read.")
        }

        var extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else {
            throw MediaError.decode("That image is empty.")
        }

        // Very large portraits cost detection time without improving the
        // identity embedding, which is computed from a 112px crop anyway.
        var working = image
        let longest = max(extent.width, extent.height)
        if longest > CGFloat(maximumDimension) {
            let scale = CGFloat(maximumDimension) / longest
            working = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            extent = working.extent
        }
        // Move the image onto the origin: CIImage extents can be offset.
        working = working.transformed(by: CGAffineTransform(translationX: -extent.minX,
                                                            y: -extent.minY))

        let width = Int(extent.width.rounded()), height = Int(extent.height.rounded())
        let buffer = try makeBuffer(width: width, height: height)
        let context = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
        context.render(working, to: buffer,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        return buffer
    }

    /// Writes a frame out as a still image, in whichever format the file
    /// extension names — the save panel's format popup rewrites the extension,
    /// so following it is what makes that popup mean anything.
    static func write(_ buffer: CVPixelBuffer, to url: URL, quality: Double = 0.95) throws {
        guard let image = makeCGImage(from: buffer) else {
            throw MediaError.pixelBuffer("The finished frame could not be read back.")
        }
        let type = UTType(filenameExtension: url.pathExtension) ?? .png
        guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, type.identifier as CFString, 1, nil) else {
            throw MediaError.writerFailed(
                "\(url.pathExtension.uppercased()) images cannot be written.")
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaError.writerFailed("The image could not be saved.")
        }
    }

    // MARK: - Display

    /// Wraps a pixel buffer as an NSImage for SwiftUI, without copying pixels
    /// until the CGImage is actually rasterised.
    static func makeNSImage(from buffer: CVPixelBuffer) -> NSImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static func makeCGImage(from buffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(ciImage, from: ciImage.extent)
    }

    /// Copies one buffer's pixels into another of the same size.
    static func copy(_ source: CVPixelBuffer, into destination: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let src = CVPixelBufferGetBaseAddress(source),
              let dst = CVPixelBufferGetBaseAddress(destination) else { return }

        let height = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(destination))
        let srcStride = CVPixelBufferGetBytesPerRow(source)
        let dstStride = CVPixelBufferGetBytesPerRow(destination)
        let bytes = min(srcStride, dstStride)
        for y in 0 ..< height {
            memcpy(dst.advanced(by: y * dstStride), src.advanced(by: y * srcStride), bytes)
        }
    }
}

enum MediaError: LocalizedError {
    case decode(String)
    case pixelBuffer(String)
    case noVideoTrack
    case readerFailed(String)
    case writerFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .decode(let m), .pixelBuffer(let m), .readerFailed(let m),
             .writerFailed(let m), .unsupported(let m):
            return m
        case .noVideoTrack:
            return "That file does not contain a video track."
        }
    }
}

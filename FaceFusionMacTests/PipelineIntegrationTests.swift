//
//  PipelineIntegrationTests.swift
//  FaceFusionMacTests
//
//  End-to-end check of the real inference chain against output captured from
//  the reference FaceFusion pipeline.
//
//  These need the ONNX models and example media on disk, so they are skipped
//  unless FACEFUSION_TEST_ASSETS points at a directory laid out as:
//
//      <assets>/models/{yoloface_8n,arcface_w600k_r50,inswapper_128_fp16}.onnx
//      <assets>/media/source.jpg
//      <assets>/out/{target_frame.png,result.png,crop128.png,swapped128.png}
//      <assets>/out/{landmarks5.txt,conditioning.txt}
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Fixtures

struct TestAssets {
    let root: URL

    /// The test host is the sandboxed app, so assets have to live inside its
    /// container. `Tools/stage-test-assets.sh` puts them there.
    static var available: TestAssets? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let candidates = [
            support.appendingPathComponent("FaceFusionMac/TestAssets"),
            ProcessInfo.processInfo.environment["FACEFUSION_TEST_ASSETS"]
                .map { URL(fileURLWithPath: $0) },
        ].compactMap { $0 }

        for candidate in candidates
        where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("models").path) {
            return TestAssets(root: candidate)
        }
        return nil
    }

    var modelPaths: [ModelID: String] {
        var paths: [ModelID: String] = [:]
        for id in ModelID.allCases {
            let url = root.appendingPathComponent("models/\(id.rawValue).onnx")
            if FileManager.default.fileExists(atPath: url.path) { paths[id] = url.path }
        }
        return paths
    }

    func image(_ relativePath: String) throws -> BGRAImage {
        try loadBGRA(root.appendingPathComponent(relativePath))
    }

    func floats(_ relativePath: String) throws -> [Float] {
        let text = try String(contentsOf: root.appendingPathComponent(relativePath),
                             encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
    }
}

/// Decodes an image file into the engine's BGRA layout.
func loadBGRA(_ url: URL) throws -> BGRAImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let width = cgImage.width, height = cgImage.height
    let image = BGRAImage(width: width, height: height)

    // premultipliedFirst + byteOrder32Little gives B, G, R, A in memory.
    guard let context = CGContext(data: image.base,
                                  width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: image.rowBytes,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return image
}

/// Mean absolute per-channel difference over RGB, ignoring alpha.
func meanAbsoluteDifference(_ a: BGRAImage, _ b: BGRAImage) -> Double {
    precondition(a.width == b.width && a.height == b.height)
    var total = 0.0
    for y in 0 ..< a.height {
        let rowA = a.row(y), rowB = b.row(y)
        for x in 0 ..< a.width {
            for c in 0 ..< 3 {
                total += abs(Double(rowA[x * 4 + c]) - Double(rowB[x * 4 + c]))
            }
        }
    }
    return total / Double(a.width * a.height * 3)
}

// MARK: - Tests

/// Serialized: each case loads roughly half a gigabyte of weights, and running
/// them concurrently just thrashes memory for no extra coverage.
@Suite("Engine integration", .enabled(if: TestAssets.available != nil), .serialized)
struct PipelineIntegrationTests {

    /// The 512x512 projection has to come out of the ONNX graph byte-for-byte,
    /// or every swap is conditioned on a garbage identity vector.
    @Test func extractsProjectionMatrixFromGraph() throws {
        let assets = try #require(TestAssets.available)
        let path = try #require(assets.modelPaths[.faceSwapper])

        let tensor = try OnnxInitializerReader.lastInitializer(ofModelAt: URL(fileURLWithPath: path))
        #expect(tensor.dims == [512, 512], "dims \(tensor.dims)")
        #expect(tensor.dataType == 1, "expected float32, got \(tensor.dataType)")
        #expect(tensor.floats.count == 512 * 512)

        // First values of `emap`, read independently with the onnx package.
        let expected: [Float] = [0.124847, -0.008458, 0.080384, -0.122000, 0.640718, 0.006046]
        for (index, value) in expected.enumerated() {
            #expect(abs(tensor.floats[index] - value) < 1e-5,
                    "emap[\(index)] = \(tensor.floats[index]), expected \(value)")
        }
    }

    /// The detector must find the same face, in the same place, as the
    /// reference — landmark drift propagates straight into misalignment.
    @Test func detectsSameLandmarksAsReference() throws {
        let assets = try #require(TestAssets.available)
        let pipeline = SwapPipeline()
        _ = try pipeline.prepare(EngineConfiguration(
            modelPaths: assets.modelPaths,
            modelCacheDirectory: NSTemporaryDirectory() + "ff-test-cache",
            compute: .cpu))

        let frame = try assets.image("out/target_frame.png")
        let analysis = try pipeline.detectFaces(in: frame)
        #expect(!analysis.faces.isEmpty, "no face detected in the target frame")

        let expected = Reference.targetLandmarks
        let face = try #require(analysis.faces.max(by: {
            $0.box.width * $0.box.height < $1.box.width * $1.box.height
        }))
        for (index, point) in face.landmarks.enumerated() {
            let distance = hypot(point[0] - Double(expected[index].x),
                                 point[1] - Double(expected[index].y))
            #expect(distance < 1.0,
                    "landmark \(index) off by \(distance)px: \(point) vs \(expected[index])")
        }
    }

    /// The whole chain, compared against the reference's final frame.
    ///
    /// An exact match is not expected: Core ML and ORT's CPU kernels differ in
    /// float ordering, and our warp is not bit-identical to OpenCV's. What
    /// matters is that the composited result is visually the same image.
    @Test func fullSwapMatchesReferenceOutput() throws {
        let assets = try #require(TestAssets.available)
        let pipeline = SwapPipeline()
        _ = try pipeline.prepare(EngineConfiguration(
            modelPaths: assets.modelPaths,
            modelCacheDirectory: NSTemporaryDirectory() + "ff-test-cache",
            compute: .cpu))

        let source = try assets.image("media/source.jpg")
        _ = try pipeline.analyzeSource(source, refineLandmarks: false)

        let frame = try assets.image("out/target_frame.png")
        let output = BGRAImage(width: frame.width, height: frame.height)

        // The reference ran without landmark refinement, enhancement or
        // occlusion masking, so match that configuration exactly — occlusion
        // defaults on and would otherwise switch itself into this comparison
        // the moment dfl_xseg.onnx appears in the assets directory.
        var options = SwapOptions()
        options.selection = .largest
        options.enhanceFace = false
        options.maskOcclusion = false
        options.refineLandmarks = false
        options.identityStrength = 0.5
        options.maskBlur = 0.3

        let result = try pipeline.swap(input: frame, output: output, options: options)
        #expect(result.facesSwapped == 1)

        let reference = try assets.image("out/result.png")
        let difference = meanAbsoluteDifference(output, reference)
        #expect(difference < 4.0, "mean abs difference vs reference: \(difference)")

        // Guard against a no-op: the output must differ from the input.
        let changed = meanAbsoluteDifference(output, frame)
        #expect(changed > 1.0, "output is indistinguishable from the input frame")
    }

    /// Localises any identity drift: if the source key points already differ,
    /// every downstream embedding difference follows from that rather than
    /// from the projection maths.
    @Test func detectsSameSourceLandmarks() throws {
        let assets = try #require(TestAssets.available)
        let pipeline = SwapPipeline()
        _ = try pipeline.prepare(EngineConfiguration(
            modelPaths: assets.modelPaths,
            modelCacheDirectory: NSTemporaryDirectory() + "ff-test-cache",
            compute: .cpu))

        let source = try assets.image("media/source.jpg")
        let analysis = try pipeline.detectFaces(in: source)
        let face = try #require(analysis.faces.max(by: {
            $0.box.width * $0.box.height < $1.box.width * $1.box.height
        }))

        // Printed by the reference run on examples-3.0.0/source.jpg (1024x1024).
        let expected: [CGPoint] = [
            CGPoint(x: 382.68265, y: 486.78732),
            CGPoint(x: 642.30164, y: 487.20530),
            CGPoint(x: 493.47028, y: 645.12103),
            CGPoint(x: 394.67697, y: 713.11646),
            CGPoint(x: 629.91156, y: 712.65400),
        ]
        for (index, point) in face.landmarks.enumerated() {
            let distance = hypot(point[0] - Double(expected[index].x),
                                 point[1] - Double(expected[index].y))
            #expect(distance < 2.0,
                    "source landmark \(index) off by \(distance)px: \(point) vs \(expected[index])")
        }
    }

    /// The conditioning vector is the subtlest part of the port: the reference
    /// divides by the magnitude of the *pre-projection* embedding.
    @Test func conditioningVectorMatchesReference() throws {
        let assets = try #require(TestAssets.available)
        let pipeline = SwapPipeline()
        _ = try pipeline.prepare(EngineConfiguration(
            modelPaths: assets.modelPaths,
            modelCacheDirectory: NSTemporaryDirectory() + "ff-test-cache",
            compute: .cpu))

        // The reference aligned the source from the detector's key points, so
        // refinement has to be off for the vectors to be comparable.
        let source = try assets.image("media/source.jpg")
        _ = try pipeline.analyzeSource(source, refineLandmarks: false)

        let expected = try assets.floats("out/conditioning.txt")
        #expect(expected.count == 512)

        let actual = try #require(pipeline.debugConditioningVector())
        #expect(actual.count == 512)

        // What matters is direction, not exact magnitude: the swapper is
        // conditioned on where this vector points in identity space.
        //
        // An exact match is not achievable, and chasing one would be a
        // mistake. Aligning a 1024px portrait to ArcFace's 112px input is a
        // ~6.7x reduction, and the reference samples it with a bare bilinear
        // tap, so its crop aliases — individual pixels differ from a correctly
        // prefiltered crop by up to 183/255. We box-reduce before sampling,
        // which removes that aliasing and moved this similarity from 0.956 to
        // 0.966: the remaining gap is noise in the reference, not error here.
        //
        // For scale: two photos of the same person typically score 0.5-0.8,
        // and different people 0.0-0.3. Anything above 0.95 is the same face
        // with sub-pixel sampling differences.
        var dot: Float = 0, normA: Float = 0, normB: Float = 0, maxDelta: Float = 0
        for i in 0 ..< 512 {
            dot += actual[i] * expected[i]
            normA += actual[i] * actual[i]
            normB += expected[i] * expected[i]
            maxDelta = max(maxDelta, abs(actual[i] - expected[i]))
        }
        let cosine = dot / (sqrtf(normA) * sqrtf(normB))
        let magnitudeRatio = sqrtf(normA) / sqrtf(normB)

        #expect(cosine > 0.95,
                "conditioning cosine similarity \(cosine) (max element delta \(maxDelta))")
        #expect(abs(magnitudeRatio - 1) < 0.05, "magnitude ratio \(magnitudeRatio)")
    }
}

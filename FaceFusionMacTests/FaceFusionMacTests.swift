//
//  FaceFusionMacTests.swift
//  FaceFusionMacTests
//
//  Numerical checks of the alignment and masking maths against ground truth
//  captured from the reference FaceFusion pipeline (OpenCV + ONNX Runtime).
//
//  The engine sources are compiled directly into this test bundle, so these
//  exercise the same code the XPC service runs.
//

import Testing
import CoreGraphics
import Foundation

// MARK: - Ground truth
//
// Produced by running the reference implementation on the published example
// media (examples-3.0.0/source.jpg, target-360p.mp4 frame 100).

enum Reference {
    /// Detector key points for the target face, in frame pixels.
    static let targetLandmarks: [CGPoint] = [
        CGPoint(x: 144.33728, y: 104.56253),
        CGPoint(x: 207.01996, y: 104.015366),
        CGPoint(x: 167.29865, y: 147.43419),
        CGPoint(x: 152.12074, y: 181.09818),
        CGPoint(x: 205.94629, y: 180.78137),
    ]

    /// `cv2.estimateAffinePartial2D` onto the arcface_128 template at 128px.
    ///   [[ 0.532836794, -0.0132571138, -27.5004521 ],
    ///    [ 0.0132571138,  0.532836794,  -6.9275969 ]]
    static let affine128 = CGAffineTransform(a: 0.532836794, b: 0.0132571138,
                                             c: -0.0132571138, d: 0.532836794,
                                             tx: -27.5004521, ty: -6.9275969)
}

// MARK: - Alignment

@Suite("Face alignment geometry")
struct GeometryTests {

    /// The closed-form similarity solve must reproduce what OpenCV's
    /// RANSAC-based partial affine estimator converges to. Alignment error
    /// here shows up directly as a misplaced or mis-scaled swapped face.
    @Test func similarityTransformMatchesOpenCV() {
        let template = WarpTemplate.scaled(WarpTemplate.arcface128, to: 128)
        let transform = Geometry.similarityTransform(from: Reference.targetLandmarks,
                                                     to: template)
        let expected = Reference.affine128
        let tolerance: CGFloat = 1e-5

        #expect(abs(transform.a - expected.a) < tolerance, "a: \(transform.a) vs \(expected.a)")
        #expect(abs(transform.b - expected.b) < tolerance, "b: \(transform.b) vs \(expected.b)")
        #expect(abs(transform.c - expected.c) < tolerance, "c: \(transform.c) vs \(expected.c)")
        #expect(abs(transform.d - expected.d) < tolerance, "d: \(transform.d) vs \(expected.d)")
        // Translation is in pixels, so judge it on a pixel scale.
        #expect(abs(transform.tx - expected.tx) < 1e-3, "tx: \(transform.tx) vs \(expected.tx)")
        #expect(abs(transform.ty - expected.ty) < 1e-3, "ty: \(transform.ty) vs \(expected.ty)")
    }

    /// A similarity transform has no shear and uniform scale, so the rotation
    /// block must stay in the (a, b, -b, a) form.
    @Test func transformIsShearFree() {
        let template = WarpTemplate.scaled(WarpTemplate.arcface128, to: 128)
        let t = Geometry.similarityTransform(from: Reference.targetLandmarks, to: template)
        #expect(abs(t.a - t.d) < 1e-9)
        #expect(abs(t.b + t.c) < 1e-9)
    }

    /// Mapping a point set onto itself must be the identity.
    @Test func identityMapping() {
        let t = Geometry.similarityTransform(from: Reference.targetLandmarks,
                                             to: Reference.targetLandmarks)
        #expect(abs(t.a - 1) < 1e-6)
        #expect(abs(t.b) < 1e-6)
        #expect(abs(t.tx) < 1e-4)
        #expect(abs(t.ty) < 1e-4)
    }

    /// Landmarks pushed through the alignment must land on the template with
    /// the *same* residual the reference implementation leaves behind.
    ///
    /// A similarity transform has four degrees of freedom fitted to ten
    /// constraints, so a real face never lands exactly on the template — the
    /// reference itself is off by up to 4.8px at the nose. The invariant worth
    /// asserting is that we reproduce its residual, not that the residual is
    /// small.
    @Test func landmarksLandOnTemplate() {
        let template = WarpTemplate.scaled(WarpTemplate.arcface128, to: 128)
        let t = Geometry.similarityTransform(from: Reference.targetLandmarks, to: template)
        let mapped = Geometry.apply(t, to: Reference.targetLandmarks)

        let referenceResiduals: [CGFloat] = [1.993, 0.281, 4.824, 1.785, 1.111]
        for (index, (actual, expected)) in zip(mapped, template).enumerated() {
            let residual = hypot(actual.x - expected.x, actual.y - expected.y)
            #expect(abs(residual - referenceResiduals[index]) < 0.01,
                    "point \(index): residual \(residual), reference \(referenceResiduals[index])")
        }
    }

    /// The 68-point reduction must pick the documented indices.
    @Test func fivePointReduction() {
        var points = [CGPoint](repeating: .zero, count: 68)
        for i in 36 ..< 42 { points[i] = CGPoint(x: 10, y: 20) }
        for i in 42 ..< 48 { points[i] = CGPoint(x: 30, y: 20) }
        points[30] = CGPoint(x: 20, y: 30)
        points[48] = CGPoint(x: 12, y: 40)
        points[54] = CGPoint(x: 28, y: 40)

        let five = Geometry.fivePoints(from: points)
        #expect(five.count == 5)
        #expect(abs(five[0].x - 10) < 1e-6 && abs(five[0].y - 20) < 1e-6)
        #expect(abs(five[1].x - 30) < 1e-6)
        #expect(abs(five[2].x - 20) < 1e-6 && abs(five[2].y - 30) < 1e-6)
        #expect(abs(five[3].x - 12) < 1e-6)
        #expect(abs(five[4].x - 28) < 1e-6)
    }
}

// MARK: - Masking

@Suite("Paste-back masking")
struct MaskTests {

    /// Values sampled from the reference `create_box_mask(128, blur=0.3)`.
    /// The feather profile controls how visible the seam is, so drift here is
    /// a real quality regression even though nothing crashes.
    @Test func boxMaskMatchesReference() {
        let mask = FaceMasker.boxMask(size: 128, blur: 0.3)
        #expect(mask.width == 128 && mask.height == 128)

        func value(_ y: Int, _ x: Int) -> Float { mask.values[y * 128 + x] }

        let samples: [(y: Int, x: Int, expected: Float)] = [
            (0, 0, 0.005325),
            (9, 9, 0.293859),
            (19, 19, 0.973431),
            (32, 32, 1.0),
            (64, 64, 1.0),
            (64, 9, 0.542088),
            (127, 127, 0.005325),
            (118, 118, 0.293859),
        ]
        for sample in samples {
            let actual = value(sample.y, sample.x)
            #expect(abs(actual - sample.expected) < 0.02,
                    "mask[\(sample.y),\(sample.x)] = \(actual), expected \(sample.expected)")
        }

        // Total energy is a good global check on the feather width.
        let total = mask.values.reduce(0, +)
        #expect(abs(total - 12116.06) < 200, "mask sum \(total)")
    }

    @Test func maskStaysInUnitRange() {
        for blur in [0.0, 0.1, 0.3, 0.6, 1.0] {
            let mask = FaceMasker.boxMask(size: 128, blur: blur)
            #expect(mask.values.allSatisfy { $0 >= 0 && $0 <= 1.0001 }, "blur \(blur)")
        }
    }
}

// MARK: - Warping

@Suite("Image warping")
struct WarpTests {

    /// Warping by the identity must be a faithful copy — this catches
    /// off-by-half-pixel errors in the sampler.
    @Test func identityWarpPreservesPixels() {
        let source = BGRAImage(width: 32, height: 32)
        for y in 0 ..< 32 {
            let row = source.row(y)
            for x in 0 ..< 32 {
                row[x * 4 + 0] = UInt8(x * 8 % 256)
                row[x * 4 + 1] = UInt8(y * 8 % 256)
                row[x * 4 + 2] = UInt8((x + y) * 4 % 256)
                row[x * 4 + 3] = 255
            }
        }

        let warped = source.warped(by: .identity, width: 32, height: 32)
        var maxDelta = 0
        for y in 0 ..< 32 {
            let a = source.row(y), b = warped.row(y)
            for i in 0 ..< 32 * 4 {
                maxDelta = max(maxDelta, abs(Int(a[i]) - Int(b[i])))
            }
        }
        #expect(maxDelta <= 1, "identity warp drifted by \(maxDelta)")
    }

    /// A round trip through a transform and its inverse should land back on
    /// the original geometry.
    @Test func warpRoundTrip() {
        let template = WarpTemplate.scaled(WarpTemplate.arcface128, to: 128)
        let t = Geometry.similarityTransform(from: Reference.targetLandmarks, to: template)
        let back = Geometry.apply(t.inverted(), to: Geometry.apply(t, to: Reference.targetLandmarks))
        for (a, b) in zip(back, Reference.targetLandmarks) {
            #expect(hypot(a.x - b.x, a.y - b.y) < 1e-6)
        }
    }

    /// Downscaling must preserve aspect ratio and never upscale.
    @Test func restrictNeverUpscales() {
        let small = BGRAImage(width: 320, height: 200)
        let (result, scale) = small.restricted(to: 640)
        #expect(result.width == 320 && result.height == 200)
        #expect(scale == 1)

        let large = BGRAImage(width: 1920, height: 1080)
        let (shrunk, _) = large.restricted(to: 640)
        #expect(shrunk.width == 640)
        #expect(shrunk.height == 360)
    }
}
